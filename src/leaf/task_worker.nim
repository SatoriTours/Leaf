## A UI-owned reservation registry and bounded POD handoff queue. Managed
## strings and references are never shared: reserve copies bytes into a raw
## envelope; work reconstructs a worker-local string and copies its result
## into the preallocated slot. Completion publication transfers slot access
## back to UI with release/acquire ordering.
import std/[atomics, locks, options]
when compileOption("threads"): import std/unicode
import ./task_contracts

const
  maxTasks = 64
  maxPayloadBytes = 1024 * 1024
  maxPoolBytes = 8 * 1024 * 1024
  maxErrorBytes = 4096

type
  SlotState = enum reserved, queued, running, completed, acknowledged
  WorkSlot = object
    references: Atomic[int]
    state: Atomic[SlotState]
    signal: ptr TaskCancellationSignalInternal
    identity: uint64
    work: TaskWork
    input, output, error: pointer
    inputSize, outputLimit, outputSize, errorSize: int
    hasFailure: bool
    failureKind: TaskFailureKind
  TicketData = object
    slot: ptr WorkSlot
  WorkerTicket* = object
    data: ref TicketData
  SharedQueue = object
    lock: Lock
    ready: Cond
    retired: bool
    items: array[maxTasks, ptr WorkSlot]
    head, count: int
    starts, calls: Atomic[int]
  WorkerPoolData = object
    queue: ptr SharedQueue
    tickets: seq[ref TicketData]
    inputCharge, resultCharge: int
    retired, joined: bool
    when compileOption("threads"):
      ownerThread: int
      threads: seq[Thread[ptr SharedQueue]]
      startedCount: int
  TaskWorkerPool* = ref WorkerPoolData
  WorkerCompletion* = object
    identity: uint64
    payload: string
    taskFailure: Option[TaskFailure]
  WorkerPoolStats* = object
    reservations, inputs, results, starts, calls: int

proc id*(completion: WorkerCompletion): uint64 = completion.identity
proc value*(completion: WorkerCompletion): string = completion.payload
proc failure*(completion: WorkerCompletion): Option[TaskFailure] = completion.taskFailure
proc reservedTasks*(stats: WorkerPoolStats): int = stats.reservations
proc inputBytes*(stats: WorkerPoolStats): int = stats.inputs
proc resultBytes*(stats: WorkerPoolStats): int = stats.results
proc workerStarts*(stats: WorkerPoolStats): int = stats.starts
proc workCalls*(stats: WorkerPoolStats): int = stats.calls

proc clearPayload(slot: ptr WorkSlot) {.raises: [].} =
  if slot.input != nil: deallocShared(slot.input)
  if slot.output != nil: deallocShared(slot.output)
  if slot.error != nil: deallocShared(slot.error)
  slot.input = nil
  slot.output = nil
  slot.error = nil

proc releaseSlot(slot: ptr WorkSlot) {.raises: [].} =
  if slot != nil and slot.references.fetchSub(1, moAcquireRelease) == 1:
    slot.clearPayload()
    slot.signal.releaseCancellationSignalInternal()
    deallocShared(slot)

proc `=destroy`(ticket: TicketData) {.raises: [].} =
  ticket.slot.releaseSlot()

proc requestCancel*(ticket: WorkerTicket) {.raises: [].} =
  if ticket.data != nil:
    ticket.data.slot.signal.requestCancellationInternal()

proc retireData(pool: var WorkerPoolData) {.raises: [].} =
  if pool.retired: return
  pool.retired = true
  for ticket in pool.tickets:
    ticket.slot.signal.requestCancellationInternal()
    if ticket.slot.state.load(moAcquire) == reserved:
      ticket.slot.state.store(completed, moRelease)
  if pool.queue != nil:
    acquire(pool.queue.lock)
    pool.queue.retired = true
    broadcast(pool.queue.ready)
    release(pool.queue.lock)

proc joinData(pool: var WorkerPoolData) {.raises: [].} =
  if pool.joined: return
  pool.retireData()
  when compileOption("threads"):
    for i in 0..<pool.startedCount: joinThread(pool.threads[i])
  pool.joined = true

proc `=destroy`(pool: var WorkerPoolData) =
  # Final disposal is a normal Nim cleanup boundary. Explicit retirePool never
  # joins; final reclamation must wait for the last worker's borrowed storage.
  pool.joinData()
  for ticket in pool.tickets:
    let slot = ticket.slot
    # join has completed every submitted task; retain the acquire handshake
    # before touching payload storage. External tickets keep metadata only.
    if slot.state.load(moAcquire) in {reserved, completed}:
      slot.state.store(acknowledged, moRelease)
      slot.clearPayload()
  reset(pool.tickets)
  when compileOption("threads"):
    reset(pool.threads)
  if pool.queue != nil:
    deinitCond(pool.queue.ready)
    deinitLock(pool.queue.lock)
    deallocShared(pool.queue)

proc requireOwner(pool: TaskWorkerPool) =
  if pool == nil: raise newException(ValueError, "nil task worker pool")
  when compileOption("threads"):
    if getThreadId() != pool.ownerThread:
      raise newException(ValueError, "task worker pool belongs to another UI thread")

proc readBytes(data: pointer, size: int): string =
  result = newString(size)
  if size > 0: copyMem(addr result[0], data, size)

when compileOption("threads"):
  proc writeFailure(slot: ptr WorkSlot, kind: TaskFailureKind, message: string) =
    # Nim's decoder permits surrogate/out-of-range runes. Normalize those too
    # so the bounded message is valid Unicode UTF-8, not just whole byte runs.
    var normalized = ""
    for rune in message.runes:
      let scalar = int(rune)
      let encoded = if scalar < 0 or scalar > 0x10FFFF or
          scalar in 0xD800..0xDFFF: "\xEF\xBF\xBD" else: $rune
      if normalized.len + encoded.len > maxErrorBytes: break
      normalized.add(encoded)
    slot.hasFailure = true
    slot.failureKind = kind
    slot.errorSize = normalized.len
    if normalized.len > 0: copyMem(slot.error, unsafeAddr normalized[0], normalized.len)

  proc runWorker(queue: ptr SharedQueue) {.thread.} =
    discard queue.starts.fetchAdd(1, moRelaxed)
    while true:
      acquire(queue.lock)
      while queue.count == 0 and not queue.retired:
        wait(queue.ready, queue.lock)
      if queue.count == 0:
        release(queue.lock)
        return
      let slot = queue.items[queue.head]
      queue.items[queue.head] = nil
      queue.head = (queue.head + 1) mod maxTasks
      dec queue.count
      release(queue.lock)
      slot.state.store(running, moRelease)
      let ctx = workerContextInternal(slot.signal)
      if not ctx.cancelled:
        discard queue.calls.fetchAdd(1, moRelaxed)
        try:
          let input = readBytes(slot.input, slot.inputSize)
          let output = slot.work(input, ctx)
          if output.len > slot.outputLimit:
            slot.writeFailure(resultTooLarge, "task result exceeds reserved maxResultBytes")
          else:
            slot.outputSize = output.len
            if output.len > 0: copyMem(slot.output, unsafeAddr output[0], output.len)
        except CatchableError as error:
          slot.writeFailure(workFailed, error.msg)
      slot.signal.releaseCancellationSignalInternal()
      # UI retains its registry reference until completed is published, so the
      # worker cannot be the last releaser. ORC allocShared allocations must
      # be freed by their allocating UI thread, including cancellation metadata.
      slot.releaseSlot()
      # No worker accesses the slot after this publication; ack may free it.
      slot.state.store(completed, moRelease)

proc newTaskWorkerPool*(workerCount = 2): TaskWorkerPool =
  when not compileOption("threads"):
    raise newException(ValueError, "background tasks require --threads:on")
  else:
    if workerCount < 1 or workerCount > maxTasks:
      raise newException(ValueError, "workerCount must be between 1 and 64")
    new(result)
    result.ownerThread = getThreadId()
    result.queue = createShared(SharedQueue)
    initLock(result.queue.lock)
    initCond(result.queue.ready)
    # Nim's pthread trampoline borrows addr(Thread). Allocate every handle
    # before starting, then never move or resize this storage until joined.
    result.threads.setLen(workerCount)
    for i in 0..<workerCount:
      createThread(result.threads[i], runWorker, result.queue)
      inc result.startedCount

proc memberIndex(pool: TaskWorkerPool, ticket: WorkerTicket): int =
  if ticket.data == nil: return -1
  for i, member in pool.tickets:
    if member == ticket.data: return i
  -1

proc reserveWork*(pool: TaskWorkerPool, id: uint64, input: string,
    work: TaskWork, maxResultBytes: int): WorkerTicket =
  pool.requireOwner()
  if pool.retired: raise newException(ValueError, "task worker pool is retired")
  if work == nil: raise newException(ValueError, "nil task work")
  if input.len > maxPayloadBytes:
    raise newException(ValueError, "task input exceeds 1 MiB")
  if maxResultBytes < 0 or maxResultBytes > maxPayloadBytes:
    raise newException(ValueError, "maxResultBytes must be between 0 and 1 MiB")
  if pool.tickets.len >= maxTasks or pool.inputCharge + input.len > maxPoolBytes or
      pool.resultCharge + maxResultBytes > maxPoolBytes:
    raise newException(ValueError, "task worker reservation capacity exceeded")
  let slot = createShared(WorkSlot)
  slot.references.store(1)
  slot.state.store(reserved)
  slot.signal = newCancellationSignalInternal()
  slot.identity = id
  slot.work = work
  slot.inputSize = input.len
  slot.outputLimit = maxResultBytes
  if input.len > 0:
    slot.input = allocShared(input.len)
    copyMem(slot.input, unsafeAddr input[0], input.len)
  if maxResultBytes > 0: slot.output = allocShared(maxResultBytes)
  slot.error = allocShared(maxErrorBytes)
  result = WorkerTicket(data: (ref TicketData)(slot: slot))
  pool.tickets.add(result.data)
  pool.inputCharge += input.len
  pool.resultCharge += maxResultBytes

proc submitReserved*(pool: TaskWorkerPool, ticket: WorkerTicket): bool =
  pool.requireOwner()
  if pool.retired or pool.memberIndex(ticket) < 0: return false
  let slot = ticket.data.slot
  if slot.state.load(moAcquire) != reserved: return false
  acquire(pool.queue.lock)
  if pool.queue.retired or pool.queue.count == maxTasks:
    release(pool.queue.lock)
    return false
  # A failed enqueue leaves all charges and the reservation intact. There is
  # no blocking send and at most 64 unacknowledged tasks in the entire pool.
  discard slot.references.fetchAdd(1, moRelaxed)
  slot.signal.retainCancellationSignalInternal()
  slot.state.store(queued, moRelease)
  pool.queue.items[(pool.queue.head + pool.queue.count) mod maxTasks] = slot
  inc pool.queue.count
  signal(pool.queue.ready)
  release(pool.queue.lock)
  true

proc completionReadyInternal*(pool: TaskWorkerPool, ticket: WorkerTicket): bool =
  pool.requireOwner()
  pool.memberIndex(ticket) >= 0 and ticket.data.slot.state.load(moAcquire) == completed

proc peekCompletion*(pool: TaskWorkerPool): Option[WorkerCompletion] =
  pool.requireOwner()
  for ticket in pool.tickets:
    let slot = ticket.slot
    if slot.state.load(moAcquire) == completed:
      var completion = WorkerCompletion(identity: slot.identity,
        payload: readBytes(slot.output, slot.outputSize))
      if slot.hasFailure:
        completion.taskFailure = some(taskFailureInternal(slot.failureKind,
          readBytes(slot.error, slot.errorSize)))
      return some(completion)

proc ackCompletion*(pool: TaskWorkerPool, ticket: WorkerTicket) =
  pool.requireOwner()
  let index = pool.memberIndex(ticket)
  if index < 0: return
  let slot = ticket.data.slot
  if slot.state.load(moAcquire) notin {reserved, completed}: return
  pool.inputCharge -= slot.inputSize
  pool.resultCharge -= slot.outputLimit
  slot.state.store(acknowledged, moRelease)
  slot.clearPayload()
  pool.tickets.delete(index)

proc retirePool*(pool: TaskWorkerPool) {.raises: [].} =
  if pool != nil: pool[].retireData()

proc joinPool*(pool: TaskWorkerPool) =
  pool.requireOwner()
  pool[].joinData()

proc workerPoolStats*(pool: TaskWorkerPool): WorkerPoolStats =
  pool.requireOwner()
  result = WorkerPoolStats(reservations: pool.tickets.len,
    inputs: pool.inputCharge, results: pool.resultCharge)
  if pool.queue != nil:
    result.starts = pool.queue.starts.load(moAcquire)
    result.calls = pool.queue.calls.load(moAcquire)
