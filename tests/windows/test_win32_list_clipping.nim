## Real HWND clipping at a negative, partially exposed compound row.
## SB_BOTTOM on 8 x 96 DIP rows in an 80 DIP viewport gives offset 688,
## leaving row 7 partially visible and overscan row 6 completely clipped.
## A centred 95 DIP child in a 96 DIP row forces a half-pixel parent origin.
## No physical input or visual-acceptance claim: inspect installed OS regions.
when not defined(windows) or not defined(leafProtocolProbes):
  {.error: "Requires Windows and leafProtocolProbes".}
import std/[tables, options]
import ../fixture_app
import leaf/[core, widgets, backend, backend_session, native_layout, ui_thread]
import leaf/backends/win32/[api, host, backend]
proc GetWindowRgnBox(window: HWND, rect: ptr RECT): int32 {.
  stdcall, dynlib: "user32.dll", importc, raises: [].}
type TestFailure = object of CatchableError
proc require(ok: bool, why: string) =
  if not ok: raise newException(TestFailure, why)
var descendants: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  descendants.add(window)
  1
proc render(): Node =
  var keys: seq[string]
  for i in 0..<8: keys.add($i)
  virtualList("clip-list", keys, proc(index: int): Node =
    row(@[
      column(@[text("row " & $index, key="label"), input("", key="edit",
        styles=style({"height":"40"}))], key="fields",
        styles=style({"height":"95", "width":"200", "gap":"2"})),
      button("save", key="save", styles=style({"height":"32", "width":"60"}))],
      key="row", styles=style({"height":"96", "align":"center"})),
    rowHeight=96, overscan=1, styles=style({"height":"80", "width":"300"}))
proc deadline(window: HWND, message: UINT, timer: UINT_PTR,
              time: DWORD) {.stdcall, raises: [].} =
  discard KillTimer(nil, timer)
  PostQuitMessage(97)
proc run() =
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(fixtureApplication(render, "List clipping", 400, 240),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var h: Win32Host
  var timer: UINT_PTR
  try:
    h = createHost("List clipping", DipSize(width:400, height:240))
    h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
    let win = newWin32Backend(h)
    let session = win.attachWin32Backend(runtime)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    var list = NoHandle
    var port: HWND
    var phase, ticks: int
    var complete: bool
    proc inspect() =
      var view: RECT
      require(GetClientRect(port, addr view) != 0, "viewport client")
      discard MapWindowPoints(port, nil, cast[ptr POINT](addr view), 2)
      var partial, fullyClipped: bool
      var checks: int
      for entity in session.acceptedEntities().values:
        if entity.row.isNone: continue
        let root = win.rowWindowForTest(entity.handle)
        if root == nil: continue
        var bounds: RECT
        require(GetWindowRect(root, addr bounds) != 0, "row bounds")
        partial = partial or (bounds.top < view.top and bounds.bottom > view.top)
        fullyClipped = fullyClipped or bounds.bottom <= view.top
        descendants.setLen(0)
        discard EnumChildWindows(root, collect, 0)
        for window in @[root] & descendants:
          var rect, region: RECT
          require(GetWindowRect(window, addr rect) != 0, "subtree bounds")
          if rect.right <= rect.left or rect.bottom <= rect.top: continue
          let left = max(rect.left, view.left)
          let top = max(rect.top, view.top)
          let right = min(rect.right, view.right)
          let bottom = min(rect.bottom, view.bottom)
          let kind = GetWindowRgnBox(window, addr region)
          echo "clip row=", entity.row.get.itemIndex, " rect=", rect,
            " region_kind=", kind, " region=", region
          if right <= left or bottom <= top:
            require(kind == 1, "fully clipped subtree must have NULLREGION")
          else:
            require(kind == 2 and region.left == left-rect.left and
              region.top == top-rect.top and region.right == right-rect.left and
              region.bottom == bottom-rect.top, "region must match actual HWND viewport intersection")
          inc checks
      require(partial and fullyClipped, "fixture contains partial row and fully clipped overscan")
      echo "clipping_checks=", checks
    h.setSafeTick(proc() =
      inc ticks
      require(ticks <= 12, "bounded ordinary turns")
      win.safeListTurn()
      if phase == 0:
        for entity in session.acceptedEntities().values:
          if entity.kind == NodeKind.virtualList: list = entity.handle
          if entity.row.isSome and entity.row.get.itemIndex == 0:
            let root = win.rowWindowForTest(entity.handle)
            if root != nil: port = GetParent(root)
        if list == NoHandle or port == nil: return
        phase = 1
        discard SendMessageW(port, WM_VSCROLL, SB_BOTTOM, 0)
      elif phase == 1:
        if win.listIntentForTest(list).appliedOffset != 688: return
        inspect()
        phase = 2
        discard SendMessageW(port, WM_VSCROLL, SB_TOP, 0)
      else:
        if win.listIntentForTest(list).appliedOffset != 0: return
        complete = true
        h.requestClose())
    timer = SetTimer(nil, 0, 10_000, deadline)
    require(timer != 0, "deadline armed")
    require(h.pump() == 0 and complete, "clipping and return-top completed")
  finally:
    if timer != 0: discard KillTimer(nil, timer)
    try:
      if h != nil:
        h.destroyHost()
        require(h.resourcesReleasedInternal(), "host resources released")
    finally: runtime.closeRuntime()
try:
  run()
  echo "test_win32_list_clipping status=PASS"
except CatchableError as error:
  echo "test_win32_list_clipping status=FAIL reason=", error.msg
  quit(1)
