import std/[unittest, options, monotimes, times, strutils, unicode]
import leaf/[task_contracts, task_worker]

var entered, released: Channel[int]

proc echoWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  input

proc gatedWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  entered.send(1)
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    if released.tryRecv().dataAvailable:
      return (if ctx.cancelled: "cancel observed" else: input)
  raise newException(ValueError, "worker release gate exceeded failure fence")

proc overflowWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  repeat('x', 1025)

proc failingWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  raise newException(ValueError, repeat("界", 2000))

proc malformedFailureWork(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  raise newException(ValueError, input)

proc awaitEntered() =
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    if entered.tryRecv().dataAvailable: return
  raise newException(ValueError, "worker did not enter before failure fence")

proc awaitCompletion(pool: TaskWorkerPool): WorkerCompletion =
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    let completion = pool.peekCompletion()
    if completion.isSome: return completion.get
  raise newException(ValueError, "worker did not finish before failure fence")

proc openGates() =
  entered.open(1)
  released.open(1)
  # ORC allocShared uses a thread-local allocator. Allocate the POD channel
  # buffers on UI, which also closes them; the worker only reads/writes ints.
  entered.send(0)
  discard entered.recv()
  released.send(0)
  discard released.recv()

proc closeGates() =
  entered.close()
  released.close()
  # Nim 2.2.6 Channel.close does not zero the freed ring pointer; reopening
  # requires a fresh value rather than calling open on that stale storage.
  entered = default(Channel[int])
  released = default(Channel[int])

suite "bounded component task worker":
  test "ORC Channel transfers string storage rather than independently copying it":
    var channel: Channel[string]
    channel.open(1)
    var input = repeat('x', 40)
    let storage = unsafeAddr input[0]
    channel.send(move(input))
    let received = channel.recv()
    check input.len == 0
    check received == repeat('x', 40)
    let sameStorage = unsafeAddr(received[0]) == storage
    check sameStorage
    channel.close()

  test "cancelled unsubmitted work never executes and repeated ack is harmless":
    let pool = newTaskWorkerPool(1)
    let ticket = pool.reserveWork(100, "pending", echoWork, 64)
    ticket.requestCancel()
    require pool.submitReserved(ticket)
    check pool.awaitCompletion().id == 100
    check pool.workerPoolStats.reservedTasks == 1
    check pool.peekCompletion().isSome
    check pool.workerPoolStats.reservedTasks == 1
    pool.ackCompletion(ticket)
    pool.ackCompletion(ticket)
    ticket.requestCancel()
    check not pool.submitReserved(ticket)
    check pool.workerPoolStats.reservedTasks == 0
    pool.retirePool()
    pool.joinPool()
    check pool.workerPoolStats.workCalls == 0

  test "independent payload survives UI mutation":
    openGates()
    let pool = newTaskWorkerPool(1)
    var input = "原始输入"
    let ticket = pool.reserveWork(42, input, gatedWork, 1024)
    # Mutating the same allocation catches ORC string aliases across threads.
    input[0] = 'X'
    require pool.submitReserved(ticket)
    awaitEntered()
    released.send(1)
    let completion = pool.awaitCompletion()
    check completion.id == 42'u64
    check completion.value == "原始输入"
    check completion.failure.isNone
    check pool.peekCompletion().get.value == "原始输入"
    pool.ackCompletion(ticket)
    check pool.peekCompletion().isNone
    pool.retirePool()
    pool.joinPool()
    closeGates()

  test "queued cancel never invokes work":
    openGates()
    let pool = newTaskWorkerPool(1)
    let running = pool.reserveWork(1, "one", gatedWork, 64)
    require pool.submitReserved(running)
    awaitEntered()
    let queued = pool.reserveWork(2, "two", echoWork, 64)
    require pool.submitReserved(queued)
    queued.requestCancel()
    released.send(1)
    for i in 0..<2:
      let completion = pool.awaitCompletion()
      if completion.id == 1: pool.ackCompletion(running)
      else:
        check completion.id == 2
        pool.ackCompletion(queued)
    pool.retirePool()
    pool.joinPool()
    check pool.workerPoolStats.workCalls == 1
    check pool.workerPoolStats.workerStarts == 1
    closeGates()

  test "running cancel preserves ticket until acknowledgement":
    openGates()
    let pool = newTaskWorkerPool(1)
    let ticket = pool.reserveWork(3, "busy", gatedWork, 128)
    require pool.submitReserved(ticket)
    awaitEntered()
    ticket.requestCancel()
    pool.ackCompletion(ticket) # Must not free a borrowed running payload.
    check pool.workerPoolStats.reservedTasks == 1
    check pool.workerPoolStats.inputBytes == 4
    check pool.workerPoolStats.resultBytes == 128
    released.send(1)
    check pool.awaitCompletion().value == "cancel observed"
    check pool.workerPoolStats.reservedTasks == 1
    pool.ackCompletion(ticket)
    check pool.workerPoolStats.reservedTasks == 0
    check pool.workerPoolStats.inputBytes == 0
    check pool.workerPoolStats.resultBytes == 0
    ticket.requestCancel() # An acknowledged handle remains a safe no-op.
    pool.retirePool()
    pool.joinPool()
    closeGates()

  test "reserved result overflow reports resultTooLarge":
    let pool = newTaskWorkerPool()
    let ticket = pool.reserveWork(4, "", overflowWork, 1024)
    require pool.submitReserved(ticket)
    let completion = pool.awaitCompletion()
    check completion.value == ""
    require completion.failure.isSome
    check completion.failure.get.kind == TaskFailureKind.resultTooLarge
    pool.ackCompletion(ticket)
    pool.retirePool()
    pool.joinPool()
    check pool.workerPoolStats.workerStarts == 2

  test "work failures truncate UTF-8 messages to 4 KiB":
    let pool = newTaskWorkerPool(1)
    let ticket = pool.reserveWork(5, "", failingWork, 1)
    require pool.submitReserved(ticket)
    let completion = pool.awaitCompletion()
    require completion.failure.isSome
    check completion.failure.get.kind == TaskFailureKind.workFailed
    check completion.failure.get.message.len == 4095
    check validateUtf8(completion.failure.get.message) == -1
    check completion.value.len == 0
    pool.ackCompletion(ticket)
    pool.retirePool()
    pool.joinPool()

  test "failure messages replace surrogate and out-of-range Unicode scalars":
    let pool = newTaskWorkerPool(1)
    let ticket = pool.reserveWork(6, "\xED\xA0\x80\xF4\x90\x80\x80", malformedFailureWork, 0)
    require pool.submitReserved(ticket)
    let completion = pool.awaitCompletion()
    require completion.failure.isSome
    check completion.failure.get.message == "\xEF\xBF\xBD\xEF\xBF\xBD"
    pool.ackCompletion(ticket)
    pool.retirePool()
    pool.joinPool()

  test "default two workers enter independent tasks before either is released":
    openGates()
    let pool = newTaskWorkerPool()
    let first = pool.reserveWork(200, "first", gatedWork, 5)
    let second = pool.reserveWork(201, "second", gatedWork, 6)
    require pool.submitReserved(first)
    require pool.submitReserved(second)
    awaitEntered()
    awaitEntered()
    check pool.workerPoolStats.workCalls == 2
    check pool.workerPoolStats.workerStarts == 2
    released.send(1)
    released.send(1)
    for i in 0..<2:
      let completion = pool.awaitCompletion()
      if completion.id == 200:
        check completion.value == "first"
        pool.ackCompletion(first)
      else:
        check completion.id == 201
        check completion.value == "second"
        pool.ackCompletion(second)
    pool.retirePool()
    pool.joinPool()
    closeGates()

  test "retired pool final reclamation leaves retained ticket cancellation safe":
    openGates()
    var pool = newTaskWorkerPool(1)
    let ticket = pool.reserveWork(202, "last", gatedWork, 32)
    require pool.submitReserved(ticket)
    awaitEntered()
    pool.retirePool()
    released.send(1)
    # Destructor joins a still in-flight worker before dropping registry refs.
    pool = nil
    ticket.requestCancel()
    closeGates()

  when not defined(useMalloc):
    test "final pool disposal frees payloads even while a ticket remains retained":
      var pool = newTaskWorkerPool(1)
      let baseline = getOccupiedMem()
      var input = repeat('a', 1024*1024)
      let ticket = pool.reserveWork(203, input, echoWork, 1024*1024)
      reset(input)
      check getOccupiedMem() >= baseline + 2*1024*1024
      pool = nil
      check getOccupiedMem() < baseline + 1024*1024
      ticket.requestCancel()

  test "64 unacknowledged reservations reject the 65th and recover after ack":
    let pool = newTaskWorkerPool(1)
    var tickets: seq[WorkerTicket]
    for i in 0..<64:
      tickets.add pool.reserveWork(uint64(i), "a", echoWork, 1)
    expect ValueError: discard pool.reserveWork(65, "a", echoWork, 1)
    check pool.workerPoolStats.reservedTasks == 64
    # Unsubmitted reservations can be acknowledged to roll back preparation.
    for ticket in tickets: pool.ackCompletion(ticket)
    check pool.workerPoolStats.reservedTasks == 0
    let ticket = pool.reserveWork(66, "b", echoWork, 1)
    require pool.submitReserved(ticket)
    check pool.awaitCompletion().value == "b"
    pool.ackCompletion(ticket)
    pool.retirePool()
    pool.joinPool()

  test "1 MiB payload and result boundaries plus separate 8 MiB budgets":
    let pool = newTaskWorkerPool(1)
    let mib = 1024 * 1024
    expect ValueError: discard pool.reserveWork(1, repeat('a', mib+1), echoWork, 1)
    expect ValueError: discard pool.reserveWork(1, "", echoWork, mib+1)
    expect ValueError: discard pool.reserveWork(1, "", echoWork, -1)
    var inputs: seq[WorkerTicket]
    for i in 0..<8: inputs.add pool.reserveWork(uint64(i), repeat('a', mib), echoWork, 0)
    expect ValueError: discard pool.reserveWork(9, "a", echoWork, 0)
    check pool.workerPoolStats.inputBytes == 8*mib
    for ticket in inputs: pool.ackCompletion(ticket)
    var results: seq[WorkerTicket]
    for i in 0..<8: results.add pool.reserveWork(uint64(i), "", echoWork, mib)
    expect ValueError: discard pool.reserveWork(9, "", echoWork, 1)
    check pool.workerPoolStats.resultBytes == 8*mib
    for ticket in results: pool.ackCompletion(ticket)
    let ticket = pool.reserveWork(10, repeat('z', mib), echoWork, mib)
    require pool.submitReserved(ticket)
    check pool.awaitCompletion().value == repeat('z', mib)
    pool.ackCompletion(ticket)
    check pool.workerPoolStats.inputBytes == 0
    check pool.workerPoolStats.resultBytes == 0
    pool.retirePool()
    pool.joinPool()

  test "retire is nonblocking and running work finishes against live storage":
    openGates()
    let pool = newTaskWorkerPool(1)
    let ticket = pool.reserveWork(11, "input", gatedWork, 64)
    require pool.submitReserved(ticket)
    awaitEntered()
    pool.retirePool()
    pool.retirePool()
    check pool.workerPoolStats.reservedTasks == 1
    expect ValueError: discard pool.reserveWork(12, "", echoWork, 1)
    released.send(1)
    pool.joinPool()
    check pool.awaitCompletion().value == "cancel observed"
    pool.ackCompletion(ticket)
    pool.joinPool()
    check pool.workerPoolStats.reservedTasks == 0
    closeGates()

  test "failed submit preserves reservation and foreign tickets are rejected":
    let pool = newTaskWorkerPool(1)
    let other = newTaskWorkerPool(1)
    let ticket = pool.reserveWork(13, "pending", echoWork, 7)
    check not other.submitReserved(ticket)
    other.ackCompletion(ticket)
    check pool.workerPoolStats.reservedTasks == 1
    pool.retirePool()
    check not pool.submitReserved(ticket)
    check pool.workerPoolStats.reservedTasks == 1
    pool.ackCompletion(ticket)
    other.retirePool()
    other.joinPool()
    pool.joinPool()

  test "500 gated queue cancel acknowledge rounds restore framework charges":
    openGates()
    let pool = newTaskWorkerPool(1)
    for round in 0..<500:
      let running = pool.reserveWork(uint64(round*2), "a", gatedWork, 32)
      require pool.submitReserved(running)
      awaitEntered()
      let queued = pool.reserveWork(uint64(round*2+1), "b", echoWork, 32)
      require pool.submitReserved(queued)
      queued.requestCancel()
      released.send(1)
      for i in 0..<2:
        let completion = pool.awaitCompletion()
        if completion.id == uint64(round*2): pool.ackCompletion(running)
        else: pool.ackCompletion(queued)
      check pool.workerPoolStats.reservedTasks == 0
      check pool.workerPoolStats.inputBytes == 0
      check pool.workerPoolStats.resultBytes == 0
    pool.retirePool()
    pool.joinPool()
    check pool.workerPoolStats.workCalls == 500
    check pool.workerPoolStats.workerStarts == 1
    closeGates()
