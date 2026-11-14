when not defined(windows): {.error: "dialog visual diagnostics need Windows".}
import std/[unittest, widestrs, strutils]
import leaf
import ../fixture_app
import leaf/[ui_thread, native_layout, native_theme, styles, backend_session]
import leaf/backend as protocol
import leaf/backends/win32/[api, host, backend, calls]
import leaf/ui as standard

const
  GaRoot = 2'u32
  GwOwner = 4'u32
  GwlStyle = -16'i32

{.push stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetWindowRgn(window: HWND, region: HRGN): int32
proc GetAncestor(window: HWND, flags: UINT): HWND
proc GetWindow(window: HWND, command: DWORD): HWND
proc UpdateWindow(window: HWND): BOOL
proc SetForegroundWindow(window: HWND): BOOL
proc WindowFromPoint(point: POINT): HWND
{.pop.}
{.push stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc GetPixel(dc: HDC, x, y: int32): uint32
{.pop.}
{.push stdcall, dynlib: "kernel32.dll", importc, raises: [].}
proc Sleep(milliseconds: DWORD) {.stdcall, dynlib: "kernel32.dll", importc, raises: [].}
{.pop.}

type
  LogBrush = object
    kind: UINT
    color: DWORD
    hatch: UINT_PTR
  ProbeState = ref object
    open, inner: bool
    dark: bool
    title: string

var descend: seq[HWND]
proc collect(w: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  descend.add(w)
  1

proc textOf(h: HWND): string =
  if h == nil: return ""
  let t = newWideCString(200)
  discard GetWindowTextW(h, cast[WidePtr](unsafeAddr t[0]), 200)
  $t

proc classOf(h: HWND): string =
  if h == nil: return "-"
  let t = newWideCString(120)
  discard GetClassNameW(h, cast[WidePtr](unsafeAddr t[0]), 120)
  $t

proc rectOf(h: HWND): RECT =
  var r: RECT
  discard GetWindowRect(h, addr r)
  r

proc pixelAt(dc: HDC, x, y: int32): uint32 =
  if dc == nil: return 0
  cast[uint32](GetPixel(dc, x, y))

proc pixel(x, y: int32): uint32 =
  let dc = GetDC(nil)
  if dc == nil: return 0
  result = pixelAt(dc, x, y)
  discard ReleaseDC(nil, dc)

proc brushColor(h: HWND): string =
  let dc = GetDC(h)
  if dc == nil: return "dc-none"
  let brush = SendMessageW(GetParent(h), 0x0138, cast[WPARAM](dc), cast[LPARAM](h))
  discard ReleaseDC(h, dc)
  if brush == 0: return "brush-null"
  var info: LogBrush
  if GetObjectW(cast[HGDIOBJ](brush), int32(sizeof(LogBrush)), addr info) == 0:
    return "brush-handle-" & $cast[uint](brush)
  "0x" & info.color.toHex(6)

proc settle(host, surface: HWND) =
  ## Let the real paint happen; never fake it with a forced repaint.
  discard SetForegroundWindow(host)
  discard UpdateWindow(host)
  if surface != nil: discard UpdateWindow(surface)
  Sleep(200)

proc describe(tag: string, h: HWND) =
  if h == nil:
    echo tag, ": <nil>"
    return
  let r = rectOf(h)
  echo tag, ": hwnd=", cast[uint](h), " class=", classOf(h), " text='", textOf(h),
    "' parent=", cast[uint](GetParent(h)), " owner=", cast[uint](GetWindow(h, GwOwner)),
    " visible=", IsWindowVisible(h), " enabled=", IsWindowEnabled(h),
    " rect=", r.left, ",", r.top, " ", (r.right - r.left), "x", (r.bottom - r.top),
    " style=0x", GetWindowLongW(h, GwlStyle).uint32.toHex(8),
    " ctlcolor=", brushColor(h)

proc probePixels(tag: string, surface: HWND) =
  let r = rectOf(surface)
  let points = [
    (r.left + 10, r.top + 10), (r.left + 70, r.top + 16),
    (r.left + 24, r.top + 70), (r.left + 24, r.bottom - 34),
    (r.left + (r.right - r.left) div 2, r.top + (r.bottom - r.top) div 2),
    (r.left + (r.right - r.left) div 2, r.bottom - 22),
    (r.right - 26, r.bottom - 26)]
  for index, point in points:
    let hit = WindowFromPoint(POINT(x: point[0], y: point[1]))
    echo tag, " pixel", index, " at ", point[0], ",", point[1],
      " color=0x", pixel(point[0], point[1]).toHex(6),
      " hit=", cast[uint](hit), " hitClass=", classOf(hit),
      " hitText='", textOf(hit), "'"

proc stripStats(surface: HWND, top, height: int32): tuple[maxValue, brightPixels: int] =
  ## Brightness statistics for a horizontal strip of the surface client area.
  ## A painted caption produces bright glyph pixels; a clean theme background
  ## does not.
  let r = rectOf(surface)
  var peak = 0
  var bright = 0
  let dc = GetDC(nil)
  if dc == nil: return (0, 0)
  defer: discard ReleaseDC(nil, dc)
  var x = r.left + 8
  while x < r.left + 208:
    var y = r.top + top
    while y < r.top + top + height:
      let value = pixelAt(dc, x, y)
      let level = int(max(value and 0xFF, max((value shr 8) and 0xFF, (value shr 16) and 0xFF)))
      if level > peak: peak = level
      if level > 0x60: inc bright
      inc y, 2
    inc x, 3
  (peak, bright)

proc summarize(tag: string, surface: HWND) =
  let r = rectOf(surface)
  let caption = stripStats(surface, 4, 18)
  let body = stripStats(surface, 60, 18)
  let centerX = r.left + (r.right - r.left) div 2
  let footerY = r.bottom - 26
  echo tag, " captionPeak=", caption.maxValue, " captionBright=", caption.brightPixels,
    " bodyPeak=", body.maxValue, " bodyBright=", body.brightPixels,
    " centerPixel=0x", pixel(centerX, r.top + 40).toHex(6),
    " footerPixel=0x", pixel(centerX, footerY).toHex(6)

suite "dialog visual diagnostics":
  test "light then dark switch and title change":
    let state = ProbeState(open: true, dark: false)
    let app = fixtureApplication(proc(): Node =
      standard.theme((if state.dark: UiColorMode.dark else: UiColorMode.light),
        column(@[
          standard.button("打开", key = "open",
            onClick = proc(e: Event) = state.open = true),
          standard.dialog((if state.title.len == 0: "编辑联系人" else: state.title), state.open, key = "dialog",
            description = "名称写入临时草稿。",
            onDismiss = proc(e: Event) = state.open = false,
            content = @[standard.field(@[standard.label("名称"),
              standard.input("Ada", key = "name")])],
            footer = @[
              standard.button("取消", key = "cancel", variant = UiVariant.outline),
              standard.button("保存", key = "save")])],
          key = "root"), key = "theme"), "Dialog diagnostics", 640, 520)
      .withNativeTheme(shadcnLight)
    let activity = newUiScopeActivity()
    let runtime = newRuntime(guardUiApplication(app,
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    let h = createHost(app.title, DipSize(width: 640, height: 520), theme = shadcnLight)
    h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
    let win = newWin32Backend(h)
    let session = win.attachWin32Backend(runtime, protocol.strict)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    try:
      win.safeListTurn()
      discard runtime.refresh()
      win.safeListTurn()
      var surface = win.overlayStateForTest.top
      echo "== light, freshly created level =="
      describe("surface", surface)
      settle(h.windowHandle, surface)
      summarize("light-fresh", surface)
      # Switch the theme while the level stays open: every surface/child must
      # repaint from the shared skin protocol, not keep stale light pixels.
      state.dark = true
      discard runtime.refresh()
      win.safeListTurn()
      surface = win.overlayStateForTest.top
      echo "== dark, after a live theme switch =="
      describe("surface", surface)
      settle(h.windowHandle, surface)
      summarize("dark-switched", surface)
      # Rename while open: the surface name must follow and the top-left strip
      # must not keep painting a container caption.
      state.title = "编辑联系人（已重命名）"
      state.open = true
      discard runtime.refresh()
      win.safeListTurn()
      surface = win.overlayStateForTest.top
      echo "== renamed =="
      describe("surface", surface)
      settle(h.windowHandle, surface)
      summarize("renamed", surface)
      echo "surfaceText='", textOf(surface), "'"
    finally:
      h.destroyHost()
      runtime.closeRuntime()
      check win.diagnostics.liveWindows == 0

proc clientSize1(h: HWND): string =
  var c: RECT
  if GetClientRect(h, addr c) == 0: return "0x0"
  $(c.right - c.left) & "x" & $(c.bottom - c.top)

proc findWindow(root: HWND, label: string): HWND =
  descend.setLen(0)
  discard EnumChildWindows(root, collect, 0)
  for child in descend:
    if textOf(child) == label: return child
  nil

proc rectStr(r: RECT): string =
  $r.left & "," & $r.top & " " & $(r.right - r.left) & "x" & $(r.bottom - r.top)

proc regionStr(h: HWND): string =
  let region = CreateRectRgn(0, 0, 0, 0)
  if region == nil: return "rgn-unavailable"
  let kind = GetWindowRgn(h, region)
  discard DeleteObject(cast[HGDIOBJ](region))
  case kind
  of 0: "rgn-none"
  of 1: "rgn-null"
  of 2: "rgn-simple"
  of 3: "rgn-complex"
  of 4: "rgn-error"
  else: "rgn-" & $kind

proc zChain(h: HWND, steps: int): string =
  var next = GetWindow(h, 2)
  var count = 0
  result = ""
  while next != nil and count < steps:
    result.add(" below" & $count & "=" & classOf(next) & "/" & textOf(next))
    next = GetWindow(next, 2)
    inc count
  var above = GetWindow(h, 3)
  count = 0
  while above != nil and count < steps:
    result.add(" above" & $count & "=" & classOf(above) & "/" & textOf(above))
    above = GetWindow(above, 3)
    inc count

proc dumpTree(tag: string, root: HWND, limit = 60) =
  descend.setLen(0)
  discard EnumChildWindows(root, collect, 0)
  echo tag & " descendants=" & $descend.len
  var count = 0
  for child in descend:
    if count >= limit: break
    describe("  " & tag, child)
    inc count

suite "nested visibility root cause":
  test "inner surface geometry z order and painted ownership":
    let state = ProbeState(open: true)
    let app = fixtureApplication(proc(): Node =
      standard.theme(UiColorMode.dark,
        column(@[
          standard.button("open", key = "open", onClick = proc(e: Event) = state.open = true),
          standard.dialog("编辑联系人", state.open, key = "dialog",
            description = "外层说明",
            onDismiss = proc(e: Event) = state.open = false,
            content = @[standard.field(@[standard.label("外层名称"),
              standard.input("Ada", key = "name")])],
            footer = @[standard.button("外层保存", key = "save")]),
          standard.dialog("内层对话框", state.inner, key = "dialog-inner",
            onDismiss = proc(e: Event) = state.inner = false,
            content = @[standard.fieldDescription("内层说明")],
            footer = @[standard.button("关闭内层", key = "close-inner")])],
          key = "root"), key = "theme"), "nested probe", 640, 520)
      .withNativeTheme(shadcnLight)
    let activity = newUiScopeActivity()
    let runtime = newRuntime(guardUiApplication(app,
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    let h = createHost(app.title, DipSize(width: 640, height: 520), theme = shadcnLight)
    h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
    let win = newWin32Backend(h)
    let session = win.attachWin32Backend(runtime, protocol.strict)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    try:
      win.safeListTurn()
      discard runtime.refresh()
      win.safeListTurn()
      let outer = win.overlayStateForTest.top
      let outerRect = rectOf(outer)
      let outerStyle = GetWindowLongW(outer, GwlStyle)
      state.inner = true
      discard runtime.refresh()
      win.safeListTurn()
      let st = win.overlayStateForTest
      let inner = st.top
      let innerScrim = st.scrim
      echo "OUTER rect=" & rectStr(outerRect) & " style=0x" & outerStyle.uint32.toHex(8)
      echo "INNER rect=" & rectStr(rectOf(inner)) & " style=0x" &
        GetWindowLongW(inner, GwlStyle).uint32.toHex(8) & " exstyle=0x" &
        GetWindowLongW(inner, -20).uint32.toHex(8) & " region=" & regionStr(inner)
      echo "SCRIM rect=" & rectStr(rectOf(innerScrim)) & " owner=" &
        $cast[uint](GetWindow(innerScrim, 4))
      echo "ZCHAIN inner:" & zChain(inner, 4)
      dumpTree("inner", inner)
      let innerRect = rectOf(inner)
      descend.setLen(0)
      discard EnumChildWindows(outer, collect, 0)
      var crossing = 0
      for child in descend:
        let r = rectOf(child)
        if r.left < innerRect.right and r.right > innerRect.left and
            r.top < innerRect.bottom and r.bottom > innerRect.top:
          inc crossing
          echo "OUTER-CHILD-OVERLAPS-INNER class=" & classOf(child) & " text=" &
            textOf(child) & " parent=" & $cast[uint](GetParent(child)) &
            " rect=" & rectStr(r)
      echo "outerChildrenCrossingInner=" & $crossing
    finally:
      h.destroyHost()
      runtime.closeRuntime()

suite "nested paint and shrink invariant":
  test "pixels inside the inner surface and outer-control overlap":
    let state = ProbeState(open: true)
    let app = fixtureApplication(proc(): Node =
      standard.theme(UiColorMode.dark,
        column(@[
          standard.button("open", key = "open", onClick = proc(e: Event) = state.open = true),
          standard.dialog("编辑联系人", state.open, key = "dialog",
            description = "外层说明",
            onDismiss = proc(e: Event) = state.open = false,
            content = @[standard.field(@[standard.label("外层名称"),
              standard.input("Ada", key = "name")])],
            footer = @[standard.button("外层保存", key = "save")]),
          standard.dialog("内层对话框", state.inner, key = "dialog-inner",
            onDismiss = proc(e: Event) = state.inner = false,
            content = @[standard.fieldDescription("内层说明")],
            footer = @[standard.button("关闭内层", key = "close-inner")])],
          key = "root"), key = "theme"), "nested paint probe", 640, 520)
      .withNativeTheme(shadcnLight)
    let activity = newUiScopeActivity()
    let runtime = newRuntime(guardUiApplication(app,
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    let h = createHost(app.title, DipSize(width: 640, height: 520), theme = shadcnLight)
    h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
    let win = newWin32Backend(h)
    let session = win.attachWin32Backend(runtime, protocol.strict)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    try:
      win.safeListTurn()
      discard runtime.refresh()
      win.safeListTurn()
      let outer = win.overlayStateForTest.top
      let outerEdit = findWindow(outer, "Ada")
      state.inner = true
      discard runtime.refresh()
      win.safeListTurn()
      let inner = win.overlayStateForTest.top
      settle(h.windowHandle, inner)
      let innerRect = rectOf(inner)
      if outerEdit != nil:
        let editRect = rectOf(outerEdit)
        echo "outerEdit rect=" & rectStr(editRect) & " innerRect=" & rectStr(innerRect)
        # Scan the outer EDIT's vertical band *inside the inner surface*.
        let dc = GetDC(nil)
        var bright = 0
        var samples = 0
        if dc != nil:
          var x = max(innerRect.left, editRect.left) + 2
          while x < min(innerRect.right, editRect.right) - 2:
            var y = max(innerRect.top, editRect.top)
            while y < min(innerRect.bottom, editRect.bottom):
              let value = pixelAt(dc, x, y)
              let level = int(max(value and 0xFF, max((value shr 8) and 0xFF,
                (value shr 16) and 0xFF)))
              inc samples
              if level > 0x40: inc bright
              inc y, 2
            inc x, 4
          discard ReleaseDC(nil, dc)
        echo "editBandInsideInner samples=" & $samples & " bright=" & $bright
      echo "innerClient=" & $clientSize1(inner)
    finally:
      h.destroyHost()
      runtime.closeRuntime()

type
  FillRecord = object
    window: HWND
    rect: RECT
    color: uint32
    kind: int  # 0 fill, 1 brushColor, 2 stockBrush
  FillTrace = ref object
    records: array[256, FillRecord]
    count: int

proc tracedCalls(trace: FillTrace): Win32Calls =
  result = systemWin32Calls()
  let system = result
  result.setDCBrushColor = proc(dc: HDC, color: DWORD): DWORD =
    if trace.count < trace.records.len:
      trace.records[trace.count] = FillRecord(color: uint32(color), kind: 1)
      inc trace.count
    system.setDCBrushColor(dc, color)
  result.fillRect = proc(dc: HDC, rect: ptr RECT, brush: HBRUSH): int32 =
    if trace.count < trace.records.len and rect != nil:
      trace.records[trace.count] = FillRecord(rect: rect[], kind: 0)
      inc trace.count
    system.fillRect(dc, rect, brush)
  result.getStockObject = proc(index: int32): HGDIOBJ =
    if trace.count < trace.records.len:
      trace.records[trace.count] = FillRecord(kind: 2, color: uint32(index))
      inc trace.count
    system.getStockObject(index)

proc dumpTrace(trace: FillTrace, tag: string) =
  echo tag & " fillTraceRecords=" & $trace.count
  for index in 0..<min(trace.count, 24):
    let record = trace.records[index]
    case record.kind
    of 0: echo "  " & $index & " fill rect=" & $record.rect.left & "," &
        $record.rect.top & " " & $(record.rect.right - record.rect.left) & "x" &
        $(record.rect.bottom - record.rect.top)
    of 1: echo "  " & $index & " brushColor=0x" & record.color.toHex(6)
    else: echo "  " & $index & " stockObject=" & $record.color

suite "nested paint order trace":
  test "bounded fill trace around an outer repaint":
    let state = ProbeState(open: true)
    let trace = FillTrace()
    let app = fixtureApplication(proc(): Node =
      standard.theme(UiColorMode.dark,
        column(@[
          standard.button("open", key = "open", onClick = proc(e: Event) = state.open = true),
          standard.dialog("编辑联系人", state.open, key = "dialog",
            description = "外层说明",
            onDismiss = proc(e: Event) = state.open = false,
            content = @[standard.field(@[standard.label("外层名称"),
              standard.input("Ada", key = "name")])],
            footer = @[standard.button("外层保存", key = "save")]),
          standard.dialog("内层对话框", state.inner, key = "dialog-inner",
            onDismiss = proc(e: Event) = state.inner = false,
            content = @[standard.fieldDescription("内层说明")],
            footer = @[standard.button("关闭内层", key = "close-inner")])],
          key = "root"), key = "theme"), "paint trace probe", 640, 520)
      .withNativeTheme(shadcnLight)
    let activity = newUiScopeActivity()
    let runtime = newRuntime(guardUiApplication(app,
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    let h = createHost(app.title, DipSize(width: 640, height: 520), theme = shadcnLight)
    h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
    let win = newWin32Backend(h, tracedCalls(trace))
    let session = win.attachWin32Backend(runtime, protocol.strict)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    try:
      win.safeListTurn()
      discard runtime.refresh()
      win.safeListTurn()
      trace.count = 0
      state.inner = true
      discard runtime.refresh()
      win.safeListTurn()
      echo "trace-after-inner-show=" & $trace.count
      dumpTrace(trace, "show")
      # One bounded outer repaint to see whether an outer child paints again.
      trace.count = 0
      let hostWindow = h.windowHandle
      discard InvalidateRect(hostWindow, nil, 1)
      discard UpdateWindow(hostWindow)
      win.safeListTurn()
      echo "trace-after-outer-repaint=" & $trace.count
      dumpTrace(trace, "repaint")
      let st = win.overlayStateForTest
      echo "z-after-repaint inner=" & classOf(st.top) & " scrim=" & classOf(st.scrim)
    finally:
      h.destroyHost()
      runtime.closeRuntime()
