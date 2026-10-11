import std/[unittest, typedthreads, strutils]
import leaf/[core, widgets, ui_thread]

proc app(scope: ExecutionScope = nil,
         render: RenderProc = nil): Application =
  var actual = render
  if actual == nil:
    actual = proc(ctx: BuildContext): Node = text("x", key = "x")
  Application(title: "ui thread", width: 320, height: 200,
    render: actual, executionScope: scope)

proc transferringScope(current: ptr uint64, worker: uint64,
                       transfer: ptr bool): ExecutionScope =
  result = proc(body: proc() {.closure.}) =
    if transfer[]:
      let saved = current[]
      current[] = worker
      try:
        body()
      except CatchableError:
        discard
      finally:
        current[] = saved
    else:
      body()

suite "UI thread guard":
  test "owner is captured before wrapping":
    var current = 100'u64
    let threadId = proc(): uint64 = current
    var renders = 0
    let guarded = guardUiApplication(
      app(proc(body: proc() {.closure.}) = body(),
        proc(ctx: BuildContext): Node = (inc renders; text("x", key = "x"))),
      threadId)
    check renders == 0
    current = 200'u64
    expect UiError:
      guarded.executionScope(proc() = discard)

  test "original scope context is preserved and body runs once":
    var current = 5'u64
    let threadId = proc(): uint64 = current
    var scopeCalls = 0
    var postBodyRan = false
    let original = proc(body: proc() {.closure.}) =
      inc scopeCalls
      body()
      postBodyRan = true
    let guarded = guardUiApplication(app(original), threadId)
    var count = 0
    guarded.executionScope(proc() = inc count)
    check count == 1
    check scopeCalls == 1
    check postBodyRan

  test "post-body exception keeps its type and message":
    var current = 7'u64
    let threadId = proc(): uint64 = current
    let original = proc(body: proc() {.closure.}) =
      body()
      raise newException(UiError, "post body failed")
    let guarded = guardUiApplication(app(original), threadId)
    var message = ""
    try:
      guarded.executionScope(proc() = discard)
    except UiError as error:
      message = error.msg
    check message == "post body failed"

  test "a scope that never runs the body is rejected":
    var current = 1'u64
    let threadId = proc(): uint64 = current
    let guarded = guardUiApplication(
      app(proc(body: proc() {.closure.}) = discard), threadId)
    expect UiError:
      guarded.executionScope(proc() = discard)

  test "a scope that runs the body twice is rejected":
    var current = 1'u64
    let threadId = proc(): uint64 = current
    let guarded = guardUiApplication(
      app(proc(body: proc() {.closure.}) = (body(); body())), threadId)
    expect UiError:
      guarded.executionScope(proc() = discard)

  test "a swallowed off-owner body still fails on the owner":
    var current = 1'u64
    var transfer = false
    let threadId = proc(): uint64 = current
    let guarded = guardUiApplication(app(transferringScope(addr current, 2'u64,
      addr transfer)), threadId)
    transfer = true
    var actions = 0
    expect UiError:
      guarded.executionScope(proc() = inc actions)
    check actions == 0
    check current == 1'u64

  test "wrong-thread initialization does not render":
    var current = 1'u64
    var transfer = false
    let threadId = proc(): uint64 = current
    var renders = 0
    let guarded = guardUiApplication(
      app(transferringScope(addr current, 2'u64, addr transfer),
        proc(ctx: BuildContext): Node = (inc renders; text("x", key = "x"))),
      threadId)
    transfer = true
    expect UiError:
      discard newRuntime(guarded)
    check renders == 0

  test "wrong-thread dispatch does not run the handler":
    var current = 1'u64
    var transfer = false
    let threadId = proc(): uint64 = current
    var clicks = 0
    let guarded = guardUiApplication(
      app(transferringScope(addr current, 2'u64, addr transfer),
        proc(ctx: BuildContext): Node =
          column(@[button("go", key = "go", onClick = proc(e: Event) = inc clicks)],
            key = "root")),
      threadId)
    let runtime = newRuntime(guarded)
    transfer = true
    expect UiError:
      discard runtime.dispatch("go", Event(kind: click))
    check clicks == 0

  test "wrong-thread materialize does not run the row builder":
    var current = 1'u64
    var transfer = false
    let threadId = proc(): uint64 = current
    var builds = 0
    let items = @["a", "b"]
    let guarded = guardUiApplication(
      app(transferringScope(addr current, 2'u64, addr transfer),
        proc(ctx: BuildContext): Node =
          column(@[virtualList("list", items, proc(index: int): Node =
            (inc builds; text(items[index], key = "row")))], key = "root")),
      threadId)
    let runtime = newRuntime(guarded)
    check builds == 0
    transfer = true
    expect UiError:
      discard runtime.materialize("list", 0, 1)
    check builds == 0

  test "a body saved by a failed scope cannot run later on the owner":
    var current = 1'u64
    let threadId = proc(): uint64 = current
    var lateBody: proc() {.closure.}
    var renders = 0
    let original = proc(body: proc() {.closure.}) = lateBody = body
    let guarded = guardUiApplication(app(original,
      proc(ctx: BuildContext): Node = (inc renders; text("x", key = "x"))),
      threadId)
    var initialRejected = false
    try:
      discard newRuntime(guarded)
    except UiError:
      initialRejected = true
    check initialRejected
    check renders == 0
    check lateBody != nil
    # The saved body belongs to the finished, failed call: it must never run.
    expect UiError:
      lateBody()
    check renders == 0

  test "primary identity, dynamic type and parent chain survive with secondary":
    let cause = newException(IOError, "cause")
    let primary = newException(ValueError, "primary")
    primary.parent = cause
    var current = 1'u64
    let threadId = proc(): uint64 = current
    let original = proc(body: proc() {.closure.}) = raise primary
    let guarded = guardUiApplication(app(original), threadId)
    var caught: ref CatchableError
    try:
      guarded.executionScope(proc() = discard)
    except CatchableError as error:
      caught = error
    check caught == primary
    check caught of ValueError
    check caught.parent == cause
    check "primary" in caught.msg
    check "body invoked 0" in caught.msg

when compileOption("threads"):
  var sharedBody: proc() {.closure.}
  var sharedCaught = false
  proc bodyWorker() {.thread.} =
    ## Borrowed body: the owner keeps the closure alive until join returns,
    ## so this one-thread-at-a-time call is safe.
    {.cast(gcsafe).}:
      try:
        sharedBody()
      except CatchableError:
        sharedCaught = true

  proc realTrampoline(body: proc() {.closure.}) =
    ## Run the body on a real worker thread, keep it alive via join, swallow
    ## the worker rejection: the owner must still fail on return.
    sharedBody = body
    sharedCaught = false
    var thread: Thread[void]
    createThread(thread, bodyWorker)
    joinThread(thread)
    if sharedCaught: discard

  test "a real worker thread body is rejected and runs no action":
    var actions = 0
    let threadId = proc(): uint64 = uint64(getThreadId())
    let guarded = guardUiApplication(app(realTrampoline), threadId)
    var message = ""
    try:
      guarded.executionScope(proc() = inc actions)
    except UiError as error:
      message = error.msg
    check "UI guard" in message
    check actions == 0
    check sharedCaught
  test "an owner fallback after a rejected real worker body runs no action":
    var borrowed: proc() {.closure.}
    var workerCaught = false
    proc workerFallback() {.thread.} =
      {.cast(gcsafe).}:
        try:
          borrowed()
        except CatchableError:
          workerCaught = true
    var actions = 0
    let threadId = proc(): uint64 = uint64(getThreadId())
    let original = proc(body: proc() {.closure.}) =
      borrowed = body
      var thread: Thread[void]
      createThread(thread, workerFallback)
      joinThread(thread)
      # A call already rejected on the worker is retried on its owner.
      body()
    let guarded = guardUiApplication(app(original), threadId)
    expect UiError:
      guarded.executionScope(proc() = inc actions)
    check workerCaught
    check actions == 0
    borrowed = nil

suite "Full UI scope activity":
  test "activity covers original scope entry body and post body with context":
    let activity = newUiScopeActivity()
    var stages: seq[bool]
    var inContext = false
    let source = app(proc(body: proc() {.closure.}) =
      stages.add(activity.busy)
      inContext = true
      body()
      stages.add(activity.busy)
      inContext = false)
    let guarded = guardUiApplication(source, proc(): uint64 = 1, activity)
    check not activity.busy
    guarded.executionScope(proc() =
      check inContext
      stages.add(activity.busy))
    check stages == @[true, true, true]
    check not activity.busy

  test "post scope primary identity and chain survive and activity clears":
    let activity = newUiScopeActivity()
    let cause = newException(IOError, "cause")
    let primary = newException(ValueError, "post")
    primary.parent = cause
    var postBusy = false
    let source = app(proc(body: proc() {.closure.}) =
      body()
      postBusy = activity.busy
      raise primary)
    let guarded = guardUiApplication(source, proc(): uint64 = 1, activity)
    var caught: ref CatchableError
    try: guarded.executionScope(proc() = discard)
    except CatchableError as e: caught = e
    check caught == primary
    check caught.parent == cause
    check postBusy
    check not activity.busy

  test "activity nests and wrong owner never enters original scope":
    let activity = newUiScopeActivity()
    var current = 1'u64
    var entries = 0
    let guarded = guardUiApplication(app(proc(body: proc() {.closure.}) =
      inc entries
      body()), proc(): uint64 = current, activity)
    guarded.executionScope(proc() =
      guarded.executionScope(proc() = check activity.busy)
      check activity.busy)
    check not activity.busy
    current = 2
    expect UiError: guarded.executionScope(proc() = discard)
    check entries == 2
    check not activity.busy
