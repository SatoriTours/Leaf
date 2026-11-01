## Regression for an outside EDIT -> list button mouse click. USER32 can loop
## in IsDialogMessage before WM_SETFOCUS when the target's viewport does not
## permit recursive traversal. Reject that known unsafe premise in the RED
## test; GREEN still delegates to real USER32 and verifies focus/traversal.
## Posted messages do not prove a physical click; the SDK desktop journey owns
## the actual mouse -> business action -> persistence regression.
when not defined(windows):
  {.error: "Win32 list mouse regression requires Windows".}

import std/[unittest, widestrs]
import ../fixture_app
import leaf/[backend, backend_session, native_layout, ui_thread]
import leaf/backends/win32/[api, calls, host, backend]

var windows: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  windows.add(window)
  1

proc findWindow(parent: HWND, caption: string): HWND =
  windows.setLen(0)
  discard EnumChildWindows(parent, collect, 0)
  for window in windows:
    let value = newWideCString(128)
    discard GetWindowTextW(window, cast[WidePtr](unsafeAddr value[0]), 128)
    if $value == caption: return window

proc deadline(window: HWND, message: UINT, timer: UINT_PTR,
              time: DWORD) {.stdcall, raises: [].} =
  discard KillTimer(nil, timer)
  PostQuitMessage(97)

suite "Win32 list mouse focus traversal":
  test "outside editor routes mouse input to a restored list through the real dialog pump":
    var clicked, routed, unsafeRouting: int
    var mouseQueueFinished = false
    var target, viewport, editor: HWND
    var showList = true
    let activity = newUiScopeActivity()
    let app = fixtureApplication(proc(): Node =
      var children = @[input("outside", key = "outside")]
      if showList:
        children.add(virtualList("list", @["row"], proc(index: int): Node =
          row(@[button("Delete", key = "delete", onClick = proc(e: Event) =
            inc clicked)], key = "row"),
          rowHeight = 48, styles = style({"height": "96"})))
      else: children.add(text("No matching tasks", key = "empty"))
      children.add(button("after", key = "after"))
      column(children, key = "root"), "List mouse", 480, 320)
    let runtime = newRuntime(guardUiApplication(app,
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    var c = systemWin32Calls()
    let nativeDialog = c.dialogMessage
    c.dialogMessage = proc(window: HWND, message: ptr MSG): BOOL =
      if message.message == 0x8123'u32: mouseQueueFinished = true
      if message.hwnd == target and message.message == 0x0201'u32:
        # Do not let the original regression hang the test process. This is a
        # failing precondition, not a fabricated successful native dispatch.
        if (GetWindowLongW(viewport, -20) and 0x00010000) == 0:
          inc unsafeRouting
          return 1
        result = nativeDialog(window, message)
        inc routed
      elif unsafeRouting > 0 and message.hwnd == target:
        return 1
      else: result = nativeDialog(window, message)
    let h = createHost("List mouse", DipSize(width: 480, height: 320), c)
    h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate)
    let win = newWin32Backend(h, c)
    let session = win.attachWin32Backend(runtime)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    defer:
      h.destroyHost()
      runtime.closeRuntime()
    var phase = 0
    h.setSafeTick(proc() =
      if phase == 0:
        editor = findWindow(h.windowHandle, "outside")
        require editor != nil
        discard SetFocus(editor)
        # Reproduce the search empty -> nonempty structural transition while
        # retaining focus in the outside editor, without pre-focusing a row.
        showList = false
        discard runtime.refresh()
        win.safeListTurn()
        showList = true
        discard runtime.refresh()
        win.safeListTurn()
        target = findWindow(h.windowHandle, "Delete")
        require target != nil
        viewport = GetParent(GetParent(target))
        require viewport != nil
        require GetFocus() == editor
        require (GetWindowLongW(viewport, -20) and 0x00010000) == 0
        phase = 1
        require PostMessageW(target, 0x0201, 1, LPARAM(8 or (8 shl 16))) != 0
        require PostMessageW(target, 0x0202, 0, LPARAM(8 or (8 shl 16))) != 0
        require PostMessageW(h.windowHandle, 0x8123, 0, 0) != 0
        require PostMessageW(h.windowHandle, WM_HOST_TICK, 0, 0) != 0
      elif phase == 1 and mouseQueueFinished:
        echo "mouse-route: unsafe=", unsafeRouting, " routed=", routed,
          " clicked=", clicked, " targetFocus=", GetFocus() == target
        check unsafeRouting == 0
        check routed == 1
        if unsafeRouting == 0:
          check GetFocus() == target
          check (GetWindowLongW(viewport, -20) and 0x00010000) != 0
          discard SetFocus(editor)
          check GetFocus() == editor
          check (GetWindowLongW(viewport, -20) and 0x00010000) == 0
        phase = 2
        h.requestClose())
    let timer = SetTimer(nil, 0, 10_000, deadline)
    require timer != 0
    try: check h.pump() == 0
    finally: discard KillTimer(nil, timer)
    check phase == 2
