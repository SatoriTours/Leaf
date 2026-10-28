when not defined(windows): {.error: "Canvas transition tests require real Windows".}
import std/[unittest, monotimes, times, os]
import leaf
import leaf/[native_layout, ui_thread]
import leaf/backends/win32/[api, calls, host, backend, canvas]

var evaluations = 0
proc counted(value: float64): float64 =
  inc evaluations
  value

component NativeTransition:
  state:
    expanded = false
  view:
    column:
      canvas:
        key: "canvas"
        height: 120
        viewBox: (200, 120)
        circle:
          key: "dot"
          center: (if expanded: (160, 60) else: (40, 60))
          radius: counted(if expanded: 24.0 else: 12.0)
          fill: (if expanded: "#FFB86C" else: "#5ED5B0")
          transition:
            duration: 240.ms
            easing: linear
      button "grow":
        key: "grow"
        onClick: expanded = true

type Probe = object
  intermediate, hiddenStable, resumedWithoutJump, complete, idle, resourcesReturned: bool
  evaluations, arms, kills: int

proc runProbe(minimize: bool, delayFirstSample = false): Probe =
  evaluations = 0
  let baseline = canvasResourceCounts()
  let activity = newUiScopeActivity()
  let app = componentApplication(component(NativeTransition, ()), "Leaf transition timer", 400, 240)
  let rt = newRuntime(guardUiApplication(app, proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var nativeCalls = systemWin32Calls()
  let getMessage = nativeCalls.getMessage
  let arm = nativeCalls.setTimer
  let kill = nativeCalls.killTimer
  var arms, kills = 0
  nativeCalls.setTimer = proc(hwnd: HWND, id: UINT_PTR, interval: UINT, callback: TIMERPROC): UINT_PTR =
    if interval == 16: inc arms
    arm(hwnd, id, interval, callback)
  nativeCalls.killTimer = proc(hwnd: HWND, id: UINT_PTR): BOOL =
    inc kills
    kill(hwnd, id)
  let constructionStarted = getMonoTime()
  var started: MonoTime
  var window: Win32Host
  var phase = 0
  var phaseStarted, messageReturnedAt, frozenFrameStarted: MonoTime
  var hiddenBoundarySeen = false
  var beforeHiddenAccountingMs: int64
  var frozen = 0.0
  var intermediate, hiddenStable, resumedWithoutJump: bool
  nativeCalls.getMessage = proc(message: ptr MSG, hwnd: HWND, first, last: UINT): BOOL =
    try:
      let elapsed = (getMonoTime() - started).inMilliseconds
      let radius = rt.find("canvas").node.canvasFrame.get.commandAt(0).radius
      if phase == 0 and elapsed >= 60:
        discard rt.dispatch("grow", Event(kind: click)) # Ordinary loop seam, not WndProc.
        phase = 1
        # Deliberate ordinary-loop preemption: an accepted target need not have
        # received its first timer sample before a wall-clock hide deadline.
        if delayFirstSample: sleep(180)
      elif phase == 1:
        if radius > 12 and radius < 24: intermediate = true
        # Hide only after observing actual interpolation, not an assumed timer
        # schedule. Preserve a hidden interval longer than the whole 240ms leg.
        if minimize and intermediate:
          frozen = radius
          frozenFrameStarted = messageReturnedAt
          echo "probe hideElapsedMs=", elapsed, " radius=", frozen
          discard ShowWindow(window.windowHandle, 6) # Real OS minimize.
          phaseStarted = getMonoTime()
          phase = 2
      elif phase == 2:
        if not hiddenBoundarySeen:
          # The preceding real native safe turn has now observed IsIconic.
          # Include the visible last-frame lag and hide-boundary delivery time,
          # not the later hidden interval, in the permitted progress budget.
          beforeHiddenAccountingMs = (getMonoTime() - frozenFrameStarted).inMilliseconds
          hiddenBoundarySeen = true
          phaseStarted = getMonoTime()
        if (getMonoTime() - phaseStarted).inMilliseconds >= 320:
          hiddenStable = radius == frozen
          echo "probe hiddenMs=", (getMonoTime() - phaseStarted).inMilliseconds,
            " frozen=", frozen, " radius=", radius,
            " boundaryBudgetMs=", beforeHiddenAccountingMs
          # Measure from before synchronous ShowWindow, not after its messages.
          phaseStarted = getMonoTime()
          discard ShowWindow(window.windowHandle, 9) # Real OS restore.
          resumedWithoutJump = true
          phase = 3
      elif phase == 3:
        let visibleMs = (getMonoTime() - phaseStarted).inMilliseconds
        # The clock includes elapsed time up to the observed hide boundary.
        # Bound every restored frame by that budget plus new visible time. This
        # permits a legitimately near-end leg to finish without replaying 320ms.
        let budgetMs = beforeHiddenAccountingMs + visibleMs
        let upperBound = min(24.0, frozen + float64(budgetMs) * 0.05 + 0.1)
        resumedWithoutJump = resumedWithoutJump and radius >= frozen and radius <= upperBound
        if visibleMs >= 40: phase = 4
      let finished = radius == 24 and not rt.animationPumpPending
      if elapsed >= 2000 or (finished and (not minimize or phase == 4)):
        window.requestClose()
      result = getMessage(message, hwnd, first, last)
      messageReturnedAt = getMonoTime() # Lower bound for the ensuing frame sample.
    except Exception as error:
      raise newException(UiError, error.msg)
  window = createHost("Leaf transition timer", DipSize(width: 400, height: 240), nativeCalls)
  window.setStartupScope(proc(): bool = activity.busy or rt.installingUpdate or rt.installingHook)
  let native = newWin32Backend(window, renderer=CanvasRenderer.software)
  let session = native.attachWin32Backend(rt)
  native.bindSession(session)
  window.bindSession(session, proc(): bool = activity.busy)
  window.setSafeTick(proc() = native.safeListTurn())
  check SetTimer(window.windowHandle, 65010, 20, nil) != 0 # Bounded wake/watchdog.
  echo "probe constructionMs=", (getMonoTime() - constructionStarted).inMilliseconds
  started = getMonoTime() # Measure live pumping, not backend/window construction.
  check window.pump() == 0
  result = Probe(intermediate: intermediate, hiddenStable: hiddenStable,
    resumedWithoutJump: resumedWithoutJump,
    complete: rt.find("canvas").node.canvasFrame.get.commandAt(0).radius == 24,
    idle: not rt.animationPumpPending, evaluations: evaluations, arms: arms, kills: kills)
  rt.closeRuntime()
  result.resourcesReturned = canvasResourceCounts() == baseline

suite "real Canvas presentation transition timer":
  test "one shared timer paints intermediate properties without executing user view":
    let probe = runProbe(false)
    check probe.intermediate
    check probe.complete
    check probe.idle
    check probe.evaluations == 2
    check probe.arms == 1
    check probe.kills >= 1
    check probe.resourcesReturned
  test "minimize freezes presentation tracks and restore does not replay hidden time":
    let probe = runProbe(true)
    check probe.intermediate
    check probe.hiddenStable
    check probe.resumedWithoutJump
    check probe.complete
    check probe.idle
    check probe.evaluations == 2
    check probe.resourcesReturned

  test "late first sampling still observes interpolation before real minimize":
    let probe = runProbe(true, delayFirstSample = true)
    check probe.intermediate
    check probe.hiddenStable
    check probe.resumedWithoutJump
    check probe.complete
    check probe.idle
    check probe.evaluations == 2
    check probe.resourcesReturned
