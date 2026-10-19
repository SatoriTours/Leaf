## Public launch boundaries must keep accepted owners reachable until cleanup.
import std/[unittest, os, options, atomics, strutils, osproc]
import leaf/[core, widgets, components, headless, runner, desktop, gpui_errors,
  managed_runtime, task_service, task_contracts, task_worker]
var workerCalls: Atomic[int]
proc work(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.} =
  discard workerCalls.fetchAdd(1)
  input
proc threadCount(): int =
  when defined(linux):
    for kind, path in walkDir("/proc/self/task"):
      if kind == pcDir: inc result

suite "public accepted construction cleanup":
  test "accepted scope exit failure closes once or transfers retry owner without entering":
    for bridge in [false]:
      for refuseCleanup in [false, true]:
        workerCalls.store(0)
        var state: State[int]
        var disposed, entered, entries: int
        var refuse = refuseCleanup
        let original = newException(UiError, "initial accepted scope exit")
        let execution: ExecutionScope = proc(body: proc()) =
          inc entries
          if entries > 1 and refuse: fail("cleanup entry refused")
          body()
          if entries == 1: raise original
        let Owner = defineComponent[int, State[int]]("PublicConstructionOwner",
          proc(ctx: MountContext, p: int): State[int] =
            let scope = ctx.taskScope()
            result = ctx.state(0); state = result
            ctx.onMount(proc(e: LifecycleContext) =
              inc entered
              discard startTask(scope, "must-not-start", "copied", work, proc(value: string) = discard))
            ctx.onActivate(proc(e: LifecycleContext) = inc entered)
            ctx.onDispose(proc(e: LifecycleContext) = inc disposed),
          proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription = host(text($ctx.value(s))))
        var owner: Runtime
        var caught = false
        try:
          let app = componentApplication(component(Owner, 0), "constructor", executionScope = execution)
          discard newRuntime(app)
        except UiError as error:
          caught = true
          check error.msg == original.msg
          if refuseCleanup:
            when declared(RuntimeCleanupError):
              check error of RuntimeCleanupError
              if error of RuntimeCleanupError:
                let failure = cast[ref RuntimeCleanupError](error)
                check failure.parent == original
                check failure.exitStatus.isNone
                owner = failure.cleanupRuntime
            else: check false # The accepted owner is currently lost.
          else: check error == original
        check caught and entries == 2 and entered == 0
        check workerCalls.load() == 0
        check state.set(1) == StateWriteResult.disposed
        check disposed == (if refuseCleanup: 0 else: 1)
        if refuseCleanup:
          check owner != nil
          if owner != nil:
            refuse = false
            owner.closeRuntime(); owner.closeRuntime()
            check disposed == 1 and entered == 0
            owner = nil

  test "unaccepted validator failure never disposes or enters the rejected candidate":
    var disposed, entered: int
    let Owner = defineComponent[int, int]("RejectedConstructionOwner",
      proc(ctx: MountContext, p: int): int =
        ctx.onDispose(proc(e: LifecycleContext) = inc disposed)
        ctx.onMount(proc(e: LifecycleContext) = inc entered)
        p,
      proc(ctx: ComponentContext, p, m: int): UiDescription = host(text("rejected")))
    expect UiError:
      discard newRuntime(componentApplication(component(Owner, 0), "rejected"),
        validator = proc(snapshot: Snapshot) = fail("initial validator refused"))
    check disposed == 0 and entered == 0

suite "public headless final ownership":
  test "repeated event check help and error exits dispose without running queued work":
    let baseline = threadCount()
    workerCalls.store(0)
    for args in [@["--headless", "--click", "load"], @["--check"],
        @["--headless", "--help"], @["--headless", "--click", "load", "--invalid"]]:
      for repetition in 0..<3:
        var state: State[int]
        var scope: TaskScope
        var disposed: int
        let Owner = defineComponent[int, State[int]]("HeadlessFinalOwner",
          proc(ctx: MountContext, p: int): State[int] =
            scope = ctx.taskScope()
            result = ctx.state(0); state = result
            ctx.onDispose(proc(e: LifecycleContext) = inc disposed),
          proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
            host(button($ctx.value(s), key = "load", onClick = proc(e: Event) =
              discard startTask(scope, "request", "copied", work, proc(value: string) = discard))))
        check runHeadless(componentApplication(component(Owner, 0), "headless"), args) ==
          (if "--invalid" in args: 1 else: 0)
        check disposed == 1
        check state.set(1) == StateWriteResult.disposed
        let service = TaskService(scope.taskDomainInternal)
        check service.taskRetiredInternal()
        check service.cleanupPendingInternal() == 0
        let stats = service.taskWorkerStatsInternal()
        check stats.reservedTasks == 0 and stats.inputBytes == 0 and stats.resultBytes == 0
        check workerCalls.load() == 0
    when defined(linux): check threadCount() == baseline

proc launcherLibrary(status: int): string =
  let directory = getTempDir() / ("leaf-public-launcher-" & $getCurrentProcessId())
  createDir(directory)
  let source = directory / ("launcher" & $status & ".c")
  let framework = currentSourcePath().parentDir.parentDir.parentDir
  writeFile(source, readFile(framework / "tests/ffi/gpui_v2_library.c")
    .replace("../../include/leaf_gpui_v2.h", framework / "include/leaf_gpui_v2.h")
    .replace("LeafGpuiApiV2 api={sizeof(api),2,0,run};", "LeafGpuiApiV2 api={sizeof(api),2,LEAF_CAP_TASK_PUMP,run};")
    .replace("(void)ctx;return 0;", "(void)ctx;return " & $status & ";")
    .replace("h->detach(ctx);return status;", "h->detach(ctx);return status==0 ? " & $status & " : status;"))
  result = source.changeFileExt("so")
  doAssert execCmd("gcc -shared -fPIC " & quoteShell(source) & " -o " & quoteShell(result)) == 0

suite "public runner retry ownership":
  test "both ABI integer results keep pending owner reachable through run":
    let previousLibrary = getEnv("LEAF_GPUI_LIBRARY")
    let previousAbi = getEnv("LEAF_GPUI_ABI")
    defer:
      if previousLibrary.len == 0: delEnv("LEAF_GPUI_LIBRARY")
      else: putEnv("LEAF_GPUI_LIBRARY", previousLibrary)
      if previousAbi.len == 0: delEnv("LEAF_GPUI_ABI")
      else: putEnv("LEAF_GPUI_ABI", previousAbi)
    for status in [0, 5]:
      putEnv("LEAF_GPUI_LIBRARY", launcherLibrary(status))
      for abi in ["2"]:
        putEnv("LEAF_GPUI_ABI", abi)
        var entries, disposed: int
        var refuse = true
        let execution: ExecutionScope = proc(body: proc()) =
          inc entries
          if entries > 2 and refuse: fail("public launcher cleanup refused")
          body()
        let Owner = defineComponent[int, int]("PublicRunnerOwner",
          proc(ctx: MountContext, p: int): int =
            ctx.onDispose(proc(e: LifecycleContext) = inc disposed)
            p,
          proc(ctx: ComponentContext, p, m: int): UiDescription = host(text("runner")))
        var caught = false
        var owner: Runtime
        try: discard run(componentApplication(component(Owner, 0), "runner", executionScope = execution), @[])
        except GpuiRunError as failure:
          caught = true
          check failure.msg == "public launcher cleanup refused"
          check failure.exitStatus == some(status)
          check failure.parent != nil and failure.parent.msg == failure.msg
          owner = failure.cleanupRuntime
        check caught and owner != nil and disposed == 0
        if owner != nil:
          refuse = false
          owner.closeRuntime(); owner.closeRuntime()
          check disposed == 1
          owner = nil

suite "headless pending cleanup transfer":
  test "normal status and original event error use out or explicit exception without retrying":
    for withOut in [false, true]:
      for businessError in [false, true]:
        var state: State[int]
        var scope: TaskScope
        var refuse: bool
        var disposed, beforeCleanup, entries: int
        let original = newException(UiError, "headless event failed")
        let execution: ExecutionScope = proc(body: proc()) =
          inc entries
          if refuse: fail("headless cleanup refused")
          body()
        let Owner = defineComponent[int, State[int]]("HeadlessTransferOwner",
          proc(ctx: MountContext, p: int): State[int] =
            scope = ctx.taskScope()
            result = ctx.state(0); state = result
            ctx.onDispose(proc(e: LifecycleContext) = inc disposed),
          proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
            host(button("refuse", key = "refuse", onClick = proc(e: Event) =
              beforeCleanup = entries
              refuse = true
              discard startTask(scope, "request", "queued", work, proc(value: string) = discard)
              if businessError: raise original)))
        var owner: Runtime
        var caught = false
        let app = componentApplication(component(Owner, 0), "headless cleanup", executionScope = execution)
        try:
          let status = runHeadless(app, @["--headless", "--click", "refuse"],
            cleanupOwner = (if withOut: addr owner else: nil))
          check withOut and not businessError and status == 0
        except RuntimeCleanupError as error:
          caught = true
          check businessError or not withOut
          check error.cleanupRuntime != nil
          if withOut: check owner == error.cleanupRuntime
          else: owner = error.cleanupRuntime
          if businessError:
            check error.msg == original.msg and error.parent == original
            check error.exitStatus.isNone
          else:
            check error.msg == "headless cleanup refused"
            check error.exitStatus == some(0)
        check caught == (businessError or not withOut)
        check entries == beforeCleanup + 1 and disposed == 0
        check state.set(1) == StateWriteResult.disposed
        check owner != nil
        if owner != nil:
          refuse = false
          owner.closeRuntime(); owner.closeRuntime()
          check disposed == 1
          let stats = TaskService(scope.taskDomainInternal).taskWorkerStatsInternal()
          check stats.reservedTasks == 0 and stats.inputBytes == 0 and stats.resultBytes == 0
          owner = nil

suite "construction transfer through launchers":
  test "constructor retry owner crosses each public launcher with one cleanup attempt":
    let previousLibrary = getEnv("LEAF_GPUI_LIBRARY")
    let previousAbi = getEnv("LEAF_GPUI_ABI")
    defer:
      if previousLibrary.len == 0: delEnv("LEAF_GPUI_LIBRARY")
      else: putEnv("LEAF_GPUI_LIBRARY", previousLibrary)
      if previousAbi.len == 0: delEnv("LEAF_GPUI_ABI")
      else: putEnv("LEAF_GPUI_ABI", previousAbi)
    putEnv("LEAF_GPUI_LIBRARY", launcherLibrary(0))
    for abi in ["2"]:
      putEnv("LEAF_GPUI_ABI", abi)
      for boundary in ["headless", "desktop", "runner-headless", "runner-desktop"]:
        var entries, entered, disposed: int
        var refuse = true
        var state: State[int]
        let original = newException(UiError, "launcher constructor exit")
        let execution: ExecutionScope = proc(body: proc()) =
          inc entries
          if entries > 1 and refuse: fail("constructor cleanup refused")
          body()
          if entries == 1: raise original
        let Owner = defineComponent[int, State[int]]("LauncherConstructionOwner",
          proc(ctx: MountContext, p: int): State[int] =
            result = ctx.state(0); state = result
            ctx.onMount(proc(e: LifecycleContext) = inc entered)
            ctx.onDispose(proc(e: LifecycleContext) = inc disposed),
          proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription = host(text("constructor")))
        let app = componentApplication(component(Owner, 0), boundary, executionScope = execution)
        var owner: Runtime
        var caught = false
        try:
          case boundary
          of "headless": discard runHeadless(app, @["--check"], addr owner)
          of "desktop": discard runDesktop(app, cleanupOwner=addr owner)
          of "runner-headless": discard run(app, @["--check"], addr owner)
          else: discard run(app, @[], addr owner)
        except RuntimeCleanupError as error:
          caught = true
          check error.parent == original and error.msg == original.msg
          check error.exitStatus.isNone
          check owner == error.cleanupRuntime
        check caught and owner != nil and entries == 2
        check disposed == 0 and entered == 0
        check state.set(1) == StateWriteResult.disposed
        if owner != nil:
          refuse = false
          owner.closeRuntime(); owner.closeRuntime()
          check disposed == 1 and entered == 0
          owner = nil

  test "nonempty out is rejected before creating another owner at every public level":
    var initialized: int
    let Owner = defineComponent[int, int]("NonemptyLauncherOwner",
      proc(ctx: MountContext, p: int): int = inc initialized; p,
      proc(ctx: ComponentContext, p, m: int): UiDescription = host(text("owner")))
    let app = componentApplication(component(Owner, 0), "existing")
    var owner = newRuntime(app)
    let original = owner
    try:
      expect UiError: discard runHeadless(app, @["--check"], addr owner)
      expect UiError: discard run(app, @["--check"], addr owner)
      expect UiError: discard run(app, @[], addr owner)
      check initialized == 1 and owner == original
    finally: owner.closeRuntime()

suite "runner integer output and ordinary errors":
  test "both ABI statuses with an output still require caller retry even for zero":
    let previousLibrary = getEnv("LEAF_GPUI_LIBRARY")
    let previousAbi = getEnv("LEAF_GPUI_ABI")
    defer:
      if previousLibrary.len == 0: delEnv("LEAF_GPUI_LIBRARY")
      else: putEnv("LEAF_GPUI_LIBRARY", previousLibrary)
      if previousAbi.len == 0: delEnv("LEAF_GPUI_ABI")
      else: putEnv("LEAF_GPUI_ABI", previousAbi)
    for status in [0, 5]:
      putEnv("LEAF_GPUI_LIBRARY", launcherLibrary(status))
      for abi in ["2"]:
        putEnv("LEAF_GPUI_ABI", abi)
        var entries, disposed: int
        var refuse = true
        let execution: ExecutionScope = proc(body: proc()) =
          inc entries
          if entries > 2 and refuse: fail("runner output cleanup refused")
          body()
        let Owner = defineComponent[int, int]("RunnerOutputOwner",
          proc(ctx: MountContext, p: int): int =
            ctx.onDispose(proc(e: LifecycleContext) = inc disposed)
            p,
          proc(ctx: ComponentContext, p, m: int): UiDescription = host(text("runner output")))
        var owner: Runtime
        check run(componentApplication(component(Owner, 0), "output", executionScope=execution), @[], addr owner) == status
        check owner != nil and disposed == 0 and entries == 3
        if owner != nil:
          refuse = false
          owner.closeRuntime(); owner.closeRuntime()
          check disposed == 1
          owner = nil
  test "ordinary errors without a pending owner keep the diagnostic integer contract":
    var initialized: int
    let Owner = defineComponent[int, int]("OrdinaryRunnerError",
      proc(ctx: MountContext, p: int): int = inc initialized; p,
      proc(ctx: ComponentContext, p, m: int): UiDescription = host(text("unused")))
    check run(componentApplication(component(Owner, 0), "unused"), @["--invalid"]) == 1
    check initialized == 0

  test "both ABI original capability rejection survives high level run with pending cleanup":
    let directory = getTempDir() / ("leaf-public-old-" & $getCurrentProcessId())
    createDir(directory)
    let framework = currentSourcePath().parentDir.parentDir.parentDir
    let source = directory / "old.c"
    writeFile(source, readFile(framework / "tests/ffi/gpui_v2_library.c")
      .replace("../../include/leaf_gpui_v2.h", framework / "include/leaf_gpui_v2.h"))
    let library = source.changeFileExt("so")
    doAssert execCmd("gcc -shared -fPIC " & quoteShell(source) & " -o " & quoteShell(library)) == 0
    let previousLibrary = getEnv("LEAF_GPUI_LIBRARY")
    let previousAbi = getEnv("LEAF_GPUI_ABI")
    defer:
      if previousLibrary.len == 0: delEnv("LEAF_GPUI_LIBRARY")
      else: putEnv("LEAF_GPUI_LIBRARY", previousLibrary)
      if previousAbi.len == 0: delEnv("LEAF_GPUI_ABI")
      else: putEnv("LEAF_GPUI_ABI", previousAbi)
    putEnv("LEAF_GPUI_LIBRARY", library)
    for abi in ["2"]:
      putEnv("LEAF_GPUI_ABI", abi)
      var entries, disposed, entered: int
      var refuse = true
      var state: State[int]
      let execution: ExecutionScope = proc(body: proc()) =
        inc entries
        if entries > 1 and refuse: fail("old capability cleanup refused")
        body()
      let Owner = defineComponent[int, State[int]]("HighLevelOldCapability",
        proc(ctx: MountContext, p: int): State[int] =
          discard ctx.taskScope()
          result = ctx.state(0); state = result
          ctx.onMount(proc(e: LifecycleContext) = inc entered)
          ctx.onDispose(proc(e: LifecycleContext) = inc disposed),
        proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription = host(text("old")))
      var owner: Runtime
      var caught = false
      try: discard run(componentApplication(component(Owner, 0), "old", executionScope=execution), @[])
      except GpuiRunError as error:
        caught = true
        check "host does not support task pumping" in error.msg
        check error.parent != nil and error.parent.msg == error.msg
        check error.exitStatus.isNone
        owner = error.cleanupRuntime
      check caught and owner != nil and entries == 2
      check disposed == 0 and entered == 0 and state.set(1) == StateWriteResult.disposed
      if owner != nil:
        refuse = false
        owner.closeRuntime(); owner.closeRuntime()
        check disposed == 1 and entered == 0
        owner = nil
