## Frames keep both SQLite writes and Leaf's framework-owned object state atomic.
import ./[context, record, errors, callbacks]
import ../sqlite

type
  RestoreProc = proc() {.closure.}
  JournalEntry = object
    record: Record
    restore: RestoreProc
  PendingEvent = object
    record: Record
    event: ModelEvent
    notifyCommit, notifyRollback: RestoreProc
  TransactionFrame* = ref object
    context: ModelContext
    name: string
    journal: seq[JournalEntry]
    events: seq[PendingEvent]
    active: bool

var frames {.threadvar.}: seq[TransactionFrame]
var frameSequence {.threadvar.}: uint64

proc isActive*(frame: TransactionFrame): bool = frame.active

proc beginFrame*(): TransactionFrame =
  let ctx = currentContext()
  if ctx.rollingBack: raise newException(ModelUsageError, "cannot write during rollback callbacks")
  if frames.len > 0 and frames[^1].context != ctx:
    raise newException(ModelUsageError, "transaction connection context changed")
  inc frameSequence
  result = TransactionFrame(context: ctx, name: "leaf_model_" & $frameSequence)
  if frames.len == 0: discard ctx.database.execute("BEGIN IMMEDIATE")
  else: discard ctx.database.execute("SAVEPOINT " & result.name)
  result.active = true
  frames.add(result)
  inc ctx.transactionDepth

proc requireTop(frame: TransactionFrame) =
  if not frame.active or frames.len == 0 or frames[^1] != frame:
    raise newException(ModelUsageError, "transaction frames must finish in nesting order")

proc enlist*(record: Record, restore: RestoreProc) =
  record.requireRecord()
  if frames.len == 0: raise newException(ModelUsageError, "record journal requires a transaction")
  for frame in frames:
    var present = false
    for entry in frame.journal:
      if entry.record == record: present = true
    if not present: frame.journal.add(JournalEntry(record: record, restore: restore))

proc queueEvent*(record: Record, event: ModelEvent, notifyCommit, notifyRollback: RestoreProc) =
  if frames.len == 0: raise newException(ModelUsageError, "model events require a transaction")
  frames[^1].events.add(PendingEvent(record: record, event: event,
    notifyCommit: notifyCommit, notifyRollback: notifyRollback))

proc popFrame(frame: TransactionFrame) =
  frames.setLen(frames.len-1)
  dec frame.context.transactionDepth
  frame.active = false

proc rollbackFrame*(frame: TransactionFrame) =
  frame.requireTop()
  var sqlFailure: ref CatchableError
  try:
    if frames.len == 1: discard frame.context.database.execute("ROLLBACK")
    else:
      discard frame.context.database.execute("ROLLBACK TO SAVEPOINT " & frame.name)
      discard frame.context.database.execute("RELEASE SAVEPOINT " & frame.name)
  except CatchableError as error: sqlFailure = error
  frame.popFrame()
  let ctx = frame.context
  ctx.rollingBack = true
  try:
    for i in countdown(frame.journal.high, 0): frame.journal[i].restore()
    for pending in frame.events:
      try: pending.notifyRollback()
      except CatchableError: discard # Preserve the operation error and restore all records.
  finally: ctx.rollingBack = false
  if sqlFailure != nil: raise sqlFailure

proc commitFrame*(frame: TransactionFrame) =
  frame.requireTop()
  try:
    if frames.len == 1: discard frame.context.database.execute("COMMIT")
    else: discard frame.context.database.execute("RELEASE SAVEPOINT " & frame.name)
  except Exception:
    try: frame.rollbackFrame()
    except CatchableError: discard
    raise
  frame.popFrame()
  if frames.len > 0:
    for pending in frame.events: frames[^1].events.add(pending)
    return
  var failures: seq[string]
  for pending in frame.events:
    try: pending.notifyCommit()
    except CatchableError as error: failures.add(error.msg)
  if failures.len > 0: raise newPostCommitError(failures)

template transaction*(body: untyped): untyped =
  block:
    let frame = beginFrame()
    try:
      body
    except Exception:
      if frame.isActive:
        try: rollbackFrame(frame)
        except CatchableError: discard
      raise
    finally:
      if frame.isActive: commitFrame(frame)

template transaction*(db: Database, body: untyped): untyped =
  withDatabase(db):
    transaction:
      body
