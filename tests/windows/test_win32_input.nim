import ../fixture_app
when not defined(windows): {.error: "Win32 input tests require Windows".}
import std/[unittest, widestrs, os, tables, strutils]
import leaf/[core, widgets, backend, backend_session, native_layout, ui_thread, styles]
import leaf/backends/win32/[api, calls, host, backend]
type Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession, runtime: Runtime]
proc mounted(render: proc(): Node, c = systemWin32Calls()): Fixture =
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(fixtureApplication(render, "Native input", 400, 300),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("Native input", DipSize(width: 400, height: 300))
  h.setStartupScope(proc(): bool = activity.busy or runtime.installingHook or runtime.installingUpdate)
  let win = newWin32Backend(h, c)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime)
proc mountedApp(app: Application, c = systemWin32Calls()): Fixture =
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(app,
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("Native input", DipSize(width: 400, height: 300))
  h.setStartupScope(proc(): bool = activity.busy or runtime.installingHook or runtime.installingUpdate)
  let win = newWin32Backend(h, c)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime)
var windows: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  windows.add(window)
  1
proc editor(f: Fixture): HWND =
  windows.setLen(0)
  discard EnumChildWindows(f.h.windowHandle, collect, 0)
  for window in windows:
    var cls: array[32, WCHAR]
    discard GetClassNameW(window, addr cls[0], 32)
    if cls[0] == WCHAR(ord('E')): return window
proc nativeText(window: HWND): string =
  let size = GetWindowTextLengthW(window) + 1
  let wide = newWideCString(int(size))
  discard GetWindowTextW(window, cast[WidePtr](unsafeAddr wide[0]), size)
  $wide
proc typeText(window: HWND, value: string) =
  let wide = newWideCString(value)
  doAssert SetWindowTextW(window, cast[WidePtr](unsafeAddr wide[0])) != 0
proc turns(f: Fixture, action, checkAfter: proc() {.closure.}) =
  var stage = 0
  f.h.setSafeTick(proc() =
    if stage == 0:
      inc stage
      action()
      discard PostMessageW(f.h.windowHandle, WM_HOST_TICK, 0, 0)
    else:
      checkAfter()
      f.h.requestClose())
  check f.h.pump() == 0

suite "real Win32 controlled input and composition messages":
  test "zero diff model rejection writes the accepted text exactly once":
    var calls = 0
    let f = mounted(proc(): Node = input("7", key="i", onChange=proc(e: Event) = inc calls))
    defer: f.h.destroyHost()
    let e = f.editor()
    let before = f.win.diagnostics.setTexts
    typeText(e, "x")
    check calls == 0
    f.s.drainEvents()
    check calls == 1
    check nativeText(e) == "7"
    check f.win.diagnostics.setTexts == before + 1
  test "echo ack preserves the Unicode editor handle and selection":
    var value = "a😀b"
    type EchoModel = object
      value: string
    let EchoRoot=defineComponent[int,State[EchoModel]]("InputEcho",
      proc(ctx: MountContext,p:int):State[EchoModel]=ctx.state(EchoModel(value:"a😀b")),
      proc(ctx: ComponentContext,p:int,m:State[EchoModel]):UiDescription =
        let v=ctx.value(m)
        host(input(v.value,key="i",onChange=proc(e: Event)=
          (value=e.value; discard m.set(EchoModel(value:e.value))))))
    let f = mountedApp(componentApplication(component(EchoRoot,0),"Native input",400,300))
    defer: f.h.destroyHost()
    let e = f.editor()
    typeText(e, "a😀bc")
    discard SendMessageW(e, EM_SETSEL, 1, 3)
    let before = f.win.diagnostics.setTexts
    f.s.drainEvents()
    check f.editor() == e
    check value == "a😀bc"
    check f.win.diagnostics.setTexts == before
    check SendMessageW(e, EM_GETSEL, 0, 0) == LRESULT(1 or (3 shl 16))
  test "two native edits captured before drain never reset the newer text":
    var value = ""
    var seen: seq[string]
    type EditModel = object
      value: string
    let EditRoot=defineComponent[int,State[EditModel]]("InputEdits",
      proc(ctx: MountContext,p:int):State[EditModel]=ctx.state(EditModel(value:"")),
      proc(ctx: ComponentContext,p:int,m:State[EditModel]):UiDescription =
        let v=ctx.value(m)
        host(input(v.value,key="i",onChange=proc(e: Event)=
          (seen.add(e.value); value=e.value;
           discard m.set(EditModel(value:e.value))))))
    let f = mountedApp(componentApplication(component(EditRoot,0),"Native input",400,300))
    defer: f.h.destroyHost()
    let e = f.editor()
    typeText(e, "a")
    typeText(e, "ab")
    let before = f.win.diagnostics.setTexts
    f.s.drainEvents()
    check seen == @["a", "ab"]
    check nativeText(e) == "ab"
    check f.win.diagnostics.setTexts == before
  test "composition conflict waits for the end message and then settles":
    var phase: seq[CompositionPhase]
    let f = mounted(proc(): Node = input("accepted", key="i", onChange=proc(e: Event) = phase.add(e.composition)))
    defer: f.h.destroyHost()
    let e = f.editor()
    discard SendMessageW(e, WM_IME_STARTCOMPOSITION, 0, 0)
    typeText(e, "draft")
    f.s.drainEvents()
    check nativeText(e) == "draft"
    discard SendMessageW(e, WM_IME_ENDCOMPOSITION, 0, 0)
    f.s.drainEvents()
    check nativeText(e) == "accepted"
    check compositionStart in phase and compositionEnd in phase
  test "explicit accepted reset executes once at the safe native boundary":
    var token: uint64
    let f = mounted(proc(): Node = input("accepted", key="i", resetToken=token))
    defer: f.h.destroyHost()
    let e = f.editor()
    let before = f.win.diagnostics.setTexts
    let action = proc() =
      token = 1
      check f.runtime.refresh()
    let after = proc() =
      check nativeText(e) == "accepted"
      check f.win.diagnostics.setTexts == before + 1
      check f.runtime.refresh()
      check f.win.diagnostics.setTexts == before + 1
    f.turns(action, after)
  test "enter queues a submit and programmatic setters never trigger it":
    var submits = 0
    let f = mounted(proc(): Node = input("x", key="i", onSubmit=proc(e: Event) = inc submits))
    defer: f.h.destroyHost()
    let e = f.editor()
    discard SendMessageW(e, WM_IME_STARTCOMPOSITION, 0, 0)
    discard SendMessageW(e, WM_KEYDOWN, 13, 0)
    f.s.drainEvents()
    check submits == 0
    discard SendMessageW(e, WM_IME_ENDCOMPOSITION, 0, 0)
    f.s.drainEvents()
    discard SendMessageW(e, WM_KEYDOWN, 13, 0)
    check submits == 0
    f.s.drainEvents()
    check submits == 1
    typeText(e, "y")
    f.s.drainEvents()
    check submits == 1

  test "reset retires undrained input and new binding accepts ordinary model changes":
    var model = "old"
    var token: uint64
    var actions = 0
    let f = mounted(proc(): Node = input(model, key="i", resetToken=token,
      onChange=proc(e: Event) =
        inc actions
        model = e.value))
    defer: f.h.destroyHost()
    let e = f.editor()
    let action = proc() =
      typeText(e, "queued")
      model = "reset"
      token = 1
      check f.runtime.refresh()
    let after = proc() =
      f.s.drainEvents()
      check actions == 0
      check nativeText(e) == "reset"
      model = "next"
      check f.runtime.refresh()
      check nativeText(e) == "next"
      typeText(e, "fresh")
      f.s.drainEvents()
      check actions == 1
      check model == "fresh"
    f.turns(action, after)

  test "reset setter failure freezes business and preserves the token for native retry":
    var c = systemWin32Calls()
    let realSet = c.setText
    var reject = false
    c.setText = proc(window: HWND, text: WidePtr): BOOL =
      if reject: setLastError(5); return 0
      realSet(window, text)
    var token: uint64
    var actions = 0
    let f = mounted(proc(): Node = input("accepted", key="i", resetToken=token,
      onChange=proc(e: Event) = inc actions), c)
    defer: f.h.destroyHost()
    let before = f.win.diagnostics.setTexts
    var stage = 0
    f.h.setSafeTick(proc() =
      if stage == 0:
        inc stage
        token = 1
        check f.runtime.refresh()
        reject = true
      else: f.h.requestClose())
    expect UiError: discard f.h.pump()
    check f.s.faulted
    check f.runtime.eventsFrozen
    expect UiError: discard f.runtime.dispatch("i", Event(kind: change, value: "business"))
    check actions == 0
    check f.win.diagnostics.setTexts == before
    reject = false
    check f.h.pump() == 0
    check f.win.diagnostics.setTexts == before + 1

  test "composition result default EN_CHANGE is dispatched once":
    var c = systemWin32Calls()
    let realDefault = c.defaultSubclass
    c.defaultSubclass = proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT =
      result = realDefault(window, message, wp, lp)
      if message == WM_IME_COMPOSITION and (lp and 0x800) != 0:
        # Actual EDIT's synchronous EN_CHANGE models its default IME result path.
        typeText(window, "result")
    var phases: seq[CompositionPhase]
    let f = mounted(proc(): Node = input("result", key="i",
      onChange=proc(e: Event) = phases.add(e.composition)), c)
    defer: f.h.destroyHost()
    discard SendMessageW(f.editor(), WM_IME_STARTCOMPOSITION, 0, 0)
    f.s.drainEvents()
    phases.setLen(0)
    discard SendMessageW(f.editor(), WM_IME_COMPOSITION, 0, 0x800)
    f.s.drainEvents()
    check phases == @[compositionResult]

  test "notifications sent to the wrong direct parent cannot enter business":
    var actions = 0
    let f = mounted(proc(): Node = column(@[
      input("nested", key="i", onChange=proc(e: Event) = inc actions)], key="root"))
    defer: f.h.destroyHost()
    let e = f.editor()
    let command = WPARAM(GetDlgCtrlID(e)) or (WPARAM(0x300) shl 16)
    discard SendMessageW(f.h.windowHandle, WM_COMMAND, command, cast[LPARAM](e))
    f.s.drainEvents()
    check actions == 0
    discard SendMessageW(GetParent(e), WM_COMMAND, command, cast[LPARAM](e))
    f.s.drainEvents()
    check actions == 1

  test "IMM cancel failure preserves primary and cleanup ownership and freezes business":
    var c = systemWin32Calls()
    let realContext = c.immContext
    let realRelease = c.immRelease
    var acquired: HIMC
    var notified, releases: int
    var notifyContext: HIMC
    var notifyArguments: array[3, DWORD]
    var failRelease = true
    c.immContext = proc(window: HWND): HIMC =
      acquired = realContext(window)
      acquired
    c.immNotify = proc(context: HIMC, action,index,value: DWORD): BOOL =
      notifyContext = context
      notifyArguments = [action,index,value]
      inc notified
      setLastError(5)
      0
    c.immRelease = proc(window: HWND, context: HIMC): BOOL =
      inc releases
      if failRelease:
        failRelease = false
        setLastError(5)
        return 0
      realRelease(window, context)
    var token: uint64
    let f = mounted(proc(): Node = input("accepted", key="i", resetToken=token), c)
    defer: f.h.destroyHost()
    let e = f.editor()
    discard SendMessageW(e, WM_IME_STARTCOMPOSITION, 0, 0)
    f.s.drainEvents()
    var stage = 0
    f.h.setSafeTick(proc() =
      if stage == 0:
        inc stage
        token = 1
        check f.runtime.refresh()
      else: f.h.requestClose())
    try:
      discard f.h.pump()
      check false
    except UiError as error:
      if acquired != nil:
        check "ImmNotifyIME cancel" in error.msg
        check "IMM cleanup secondary" in error.msg
      else:
        check "no native input context" in error.msg
        echo "NotRun: IMM cancel trace requires a real HIMC; no-context failure verified"
    check f.s.faulted and f.runtime.eventsFrozen
    if acquired != nil:
      check notified == 1 and releases == 1
      check notifyContext == acquired
      check notifyArguments == [0x15'u32, 4'u32, 0'u32]
    discard SendMessageW(e, WM_IME_ENDCOMPOSITION, 0, 0)
    check f.h.pump() == 0
    check f.win.diagnostics.setTexts == 1
    if acquired != nil: check releases == 2

  test "failed final reset selection does not consume the token after successful text":
    var c = systemWin32Calls()
    let realSend = c.send
    var failSelection = false
    c.send = proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT =
      if message == EM_SETSEL and failSelection:
        failSelection = false
        raise newException(UiError, "selection-reset-primary")
      realSend(window, message, wp, lp)
    var token: uint64
    let f = mounted(proc(): Node = input("accepted", key="i", resetToken=token), c)
    defer: f.h.destroyHost()
    var stage = 0
    f.h.setSafeTick(proc() =
      if stage == 0:
        inc stage
        token = 1
        check f.runtime.refresh()
        failSelection = true
      else: f.h.requestClose())
    expect UiError: discard f.h.pump()
    check f.s.faulted and f.runtime.eventsFrozen
    check f.win.diagnostics.setTexts == 1
    check f.h.pump() == 0
    check f.win.diagnostics.setTexts == 2

  test "checkbox and toggle rejection or absent handlers restore accepted check state":
    for toggle in [false, true]:
      for hasHandler in [false, true]:
        var actions = 0
        let handler: Callback = if hasHandler: (proc(e: Event) = inc actions) else: nil
        let f = mounted(proc(): Node =
          if toggle: switch("toggle", false, key="c", onChange=handler)
          else: checkbox("check", false, key="c", onChange=handler))
        windows.setLen(0)
        discard EnumChildWindows(f.h.windowHandle, collect, 0)
        require windows.len == 1
        let box = windows[0]
        discard SendMessageW(box, BM_CLICK, 0, 0)
        check SendMessageW(box, BM_GETCHECK, 0, 0) == 1
        check actions == 0
        f.s.drainEvents()
        check actions == ord(hasHandler)
        check SendMessageW(box, BM_GETCHECK, 0, 0) == 0
        f.h.destroyHost()

  test "failed candidate leaves reset unconsumed until the same token is accepted":
    var model = "old"
    var token: uint64
    var invalid = false
    var actions = 0
    let f = mounted(proc(): Node = column(@[
      input(model, key="i", resetToken=token, onChange=proc(e: Event) =
        inc actions
        model = e.value),
      text("candidate", key="candidate", styles=style({"width": (if invalid: "-1" else: "auto")}))], key="root"))
    defer: f.h.destroyHost()
    let e = f.editor()
    let before = f.win.diagnostics.setTexts
    let action = proc() =
      token = 1
      model = "reset accepted later"
      invalid = true
      expect UiError: discard f.runtime.refresh()
      check nativeText(e) == "old"
      check f.win.diagnostics.setTexts == before
      check not f.s.faulted and not f.runtime.eventsFrozen
      invalid = false
      check f.runtime.refresh()
    let after = proc() =
      check f.editor() == e
      check nativeText(e) == "reset accepted later"
      check f.win.diagnostics.setTexts == before + 2 # accepted value, then explicit reset
      let settled = f.win.diagnostics.setTexts
      check f.runtime.refresh()
      check f.win.diagnostics.setTexts == settled
      typeText(e, "fresh binding")
      f.s.drainEvents()
      check actions == 1 and model == "fresh binding"
    f.turns(action, after)

  test "restore rejects retired command IDs cookies and queued binding envelopes":
    var c = systemWin32Calls()
    let realPosition = c.windowPos
    let realSubclass = c.setSubclass
    let realDefault = c.defaultSubclass
    var fail = false
    var retiredCallback: SUBCLASSPROC
    var retiredId: UINT_PTR
    var retiredCookie: DWORD_PTR
    var latestCookie: DWORD_PTR
    var probeRetired = false
    var retiredCalls = 0
    c.windowPos = proc(window, after:HWND, x,y,width,height:int32, flags:UINT): BOOL =
      if fail:
        fail = false
        setLastError(5)
        return 0
      realPosition(window, after, x,y,width,height,flags)
    c.setSubclass = proc(window:HWND, callback:SUBCLASSPROC,
                         id:UINT_PTR, data:DWORD_PTR): BOOL =
      latestCookie = data
      if retiredCallback == nil:
        retiredCallback = callback
        retiredId = id
        retiredCookie = data
      realSubclass(window, callback, id, data)
    c.defaultSubclass = proc(window:HWND, message:UINT, wp:WPARAM, lp:LPARAM): LRESULT =
      if probeRetired and message == WM_GETDLGCODE:
        probeRetired = false
        inc retiredCalls
        # Invoke the retired listener inside a real current subclass chain.
        # The HWND is real: this forces the stale-cookie path for a live window.
        return retiredCallback(window, message, wp, lp, retiredId, retiredCookie)
      realDefault(window, message, wp, lp)
    var model = "old"
    var actions = 0
    let f = mounted(proc():Node = input(model, key="i",
      onChange=proc(e:Event) =
        inc actions
        model = e.value), c)
    defer: f.h.destroyHost()
    let oldWindow = f.editor()
    let oldId = GetDlgCtrlID(oldWindow)
    let oldGeneration = f.s.mountGeneration
    typeText(oldWindow, "queued before restore") # real captured old-binding envelope
    check f.s.queuedEvents == 1
    model = "candidate"
    fail = true
    expect UiError: discard f.runtime.refresh()
    require not f.s.faulted
    let current = f.editor()
    let currentId = GetDlgCtrlID(current)
    check f.s.mountGeneration == oldGeneration + 1
    check currentId > oldId
    check latestCookie != retiredCookie
    check nativeText(current) == "old"
    f.s.drainEvents()
    check actions == 0
    # An old command's HWND bits may now name a current live object. Force that
    # routing input with the real current HWND; do not claim OS numeric reuse.
    let retiredCommand = WPARAM(oldId) or (WPARAM(0x300) shl 16)
    discard SendMessageW(GetParent(current), WM_COMMAND, retiredCommand, cast[LPARAM](current))
    discard SendMessageW(GetParent(current), WM_COMMAND, retiredCommand, cast[LPARAM](oldWindow))
    f.s.drainEvents()
    check actions == 0
    let expected = SendMessageW(current, WM_GETDLGCODE, 0, 0)
    probeRetired = true
    check SendMessageW(current, WM_GETDLGCODE, 0, 0) == expected
    check retiredCalls == 1
    check f.s.queuedEvents == 0
    typeText(current, "fresh after restore")
    f.s.drainEvents()
    check actions == 1 and model == "fresh after restore"
