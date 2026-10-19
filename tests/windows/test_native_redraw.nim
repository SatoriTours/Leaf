import ../fixture_app
## Regression: a bound native label must show its complete text on the settled
## screen after real keystrokes update its model, without any resize, forced
## repaint or extra redraw from the application.
##
## Observed on `examples/native_forms`: after typing into the EDIT with real
## keyboard input, the accepted model, the EDIT text and the label's WM_GETTEXT
## were all correct, but the screen only showed the unchanged prefix plus the
## last typed glyph ("模型：" + "d"). It never recovered while idle and only a
## window resize revealed the full text.
##
## Root cause this suite pins down: the stock label control does not invalidate
## its client area for the WM_SETTEXT Leaf sends, so after a text change the
## visible pixels are only refreshed where the window region grows. The suite
## therefore asserts the real screen pixels of the label and compares them with
## the same control's own fresh paint.
##
## With LEAF_WIN32_TEST_OUT set (the Win32 runner sets it) a message trace of the
## label is appended to `<evidence>/redraw-trace.log` for diagnosis.
when not defined(windows): {.error: "Win32 redraw regression requires Windows".}
import std/[unittest, os, strutils, tables, typedthreads, widestrs, algorithm]
import leaf/[core, widgets, view, styles, backend, backend_session, native_layout, ui_thread]
import leaf/backends/win32/[api, calls, host, backend]

const
  WM_PAINT* = 0x000F'u32
  WM_ERASEBKGND* = 0x0014'u32
  WM_WINDOWPOSCHANGED* = 0x0047'u32
  WM_SHOWWINDOW* = 0x0018'u32
  wmGetText* = 0x000D'u32
  KEYEVENTF_KEYUP* = 0x0002'u32
  KEYEVENTF_UNICODE* = 0x0004'u32
  background* = 0x00F0F0F0'u32

type
  KEYBDINPUT = object
    wVk: uint16
    wScan: uint16
    dwFlags: uint32
    time: uint32
    dwExtraInfo: uint
  MOUSEINPUT = object
    dx, dy: int32
    mouseData: uint32
    dwFlags: uint32
    time: uint32
    dwExtraInfo: uint
  HARDWAREINPUT = object
    uMsg: uint32
    wParamL: uint16
    wParamH: uint16
  INPUTUNION {.union.} = object
    ki: KEYBDINPUT
    mi: MOUSEINPUT
    hi: HARDWAREINPUT
  INPUT = object
    theType: uint32
    u: INPUTUNION
  Pixel = tuple[x, y: int32, color: DWORD]

proc SendInput(count: UINT, inputs: pointer, size: int32): UINT {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc MapVirtualKeyW(code, mapType: UINT): UINT {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetTickCount(): DWORD {.stdcall, dynlib: "kernel32.dll", importc, raises: [].}
proc GetPixel(dc: HDC, x, y: int32): DWORD {.stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc GetRegionData(region: HRGN, size: DWORD, data: pointer): DWORD {.stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc GetUpdateRgn(window: HWND, region: HRGN, erase: BOOL): int32 {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetWindowRgn(window: HWND, region: HRGN): int32 {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc SetFocus(window: HWND): HWND {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetFocus(): HWND {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc SetForegroundWindow(window: HWND): BOOL {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetForegroundWindow(): HWND {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc InvalidateRect(window: HWND, rect: pointer, erase: BOOL): BOOL {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc UpdateWindow(window: HWND): BOOL {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc IsWindowVisible(window: HWND): BOOL {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc Sleep(milliseconds: DWORD) {.stdcall, dynlib: "kernel32.dll", importc, raises: [].}

# --- optional diagnosis trace -------------------------------------------------
var traceEnabled = false
var tracePath = ""
var traceStart: DWORD = 0

proc traceLine(line: string) {.raises: [].} =
  if not traceEnabled: return
  try:
    var file: File
    if open(file, tracePath, fmAppend):
      file.writeLine(line)
      file.close()
  except CatchableError:
    discard

proc windowText(window: HWND): string =
  let length = GetWindowTextLengthW(window)
  if length <= 0: return ""
  let wide = newWideCString(int(length) + 1)
  discard GetWindowTextW(window, cast[WidePtr](unsafeAddr wide[0]), length + 1)
  $wide

proc textMessage(window: HWND): string =
  ## WM_GETTEXT asks the control itself, not the cached caption.
  var wide = newWideCString(1024)
  let read = SendMessageW(window, wmGetText, WPARAM(1024), LPARAM(cast[int](unsafeAddr wide[0])))
  if read <= 0: return ""
  ($wide)[0 ..< min(int(read), ($wide).len)]

proc className(window: HWND): string =
  var buffer: array[64, WCHAR]
  discard GetClassNameW(window, addr buffer[0], 64)
  $cast[WideCString](addr buffer[0])

proc frames(window: HWND): string {.raises: [].} =
  try:
    var screen: RECT
    var client: RECT
    discard GetWindowRect(window, addr screen)
    discard GetClientRect(window, addr client)
    "win=" & $screen.left & "," & $screen.top & "," &
      $(screen.right - screen.left) & "," & $(screen.bottom - screen.top) &
      " client=" & $client.right & "x" & $client.bottom
  except CatchableError:
    "frames-error"

proc regionText(window: HWND, update: bool): string {.raises: [].} =
  try:
    let region = CreateRectRgn(0, 0, 0, 0)
    if region == nil: return "rgn-nil"
    defer: discard DeleteObject(cast[HGDIOBJ](region))
    let kind = if update: GetUpdateRgn(window, region, 0) else: GetWindowRgn(window, region)
    if kind == 0: return "none"
    if kind < 0: return "err" & $kind
    let size = int(GetRegionData(region, 0, nil))
    if size <= 32: return "empty"
    var buffer = newSeq[byte](size)
    discard GetRegionData(region, DWORD(size), addr buffer[0])
    let words = cast[ptr UncheckedArray[int32]](addr buffer[0])
    let count = int(words[2])
    var text = ""
    for index in 0 ..< count:
      let base = 8 + index * 4
      if index > 0: text.add(";")
      text.add($words[base] & "," & $words[base + 1] & "," & $words[base + 2] & "," & $words[base + 3])
    if count == 0: "empty" else: text
  except CatchableError:
    "region-error"

const mappedMessages = [WM_PAINT, WM_ERASEBKGND, WM_SETTEXT, WM_WINDOWPOSCHANGED, WM_SHOWWINDOW]

proc labelLogProc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM,
                  id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall, raises: [].} =
  if traceEnabled and message in mappedMessages:
    traceLine("@" & $(GetTickCount() - traceStart) & " msg=0x" & toHex(int(message), 4) &
      " wp=" & $wp & " lp=" & $lp & " " & frames(window) &
      " wregion=" & regionText(window, false) & " uregion=" & regionText(window, true) &
      " text=[" & windowText(window) & "]")
  DefSubclassProc(window, message, wp, lp)

# --- real screen pixels -------------------------------------------------------
proc screenPixels(window: HWND): seq[Pixel] {.raises: [].} =
  ## Actual on-screen pixels of the window rectangle; never a forced repaint.
  result = @[]
  try:
    var rect: RECT
    if GetWindowRect(window, addr rect) == 0: return
    let screen = GetDC(nil)
    if screen == nil: return
    defer: discard ReleaseDC(nil, screen)
    for y in rect.top ..< rect.bottom:
      for x in rect.left ..< rect.right:
        result.add((x, y, GetPixel(screen, x, y)))
  except CatchableError:
    discard

proc pixelsText(pixels: seq[Pixel], width: int): string {.raises: [].} =
  if pixels.len == 0 or width <= 0: return "<no-pixels>"
  result = ""
  for index, pixel in pixels:
    result.add(if pixel.color == DWORD(background): '.' else: '#')
    if (index + 1) mod width == 0: result.add("\n")
  result.add("(width=" & $width & ")\n")

proc pixelDiff(a, b: seq[Pixel]): int {.raises: [].} =
  ## Number of differing pixels; -1 when the captures have different shapes.
  if a.len != b.len: return -1
  result = 0
  for index in 0 ..< a.len:
    if a[index] != b[index]: inc result

proc inkRanges(pixels: seq[Pixel]): seq[tuple[first, last: int]] {.raises: [].} =
  ## Contiguous column ranges holding any pixel that differs from the label
  ## background, aggregated over every row of the control rectangle.
  result = @[]
  if pixels.len == 0: return
  let origin = pixels[0].x
  var inked: seq[int32]
  for pixel in pixels:
    if pixel.color != DWORD(background): inked.add(pixel.x)
  inked.sort()
  var start = -1
  var previous = -1
  for column in inked:
    let offset = int(column - origin)
    if offset == previous: continue
    if start < 0:
      start = offset
    elif offset != previous + 1:
      result.add((start, previous))
      start = offset
    previous = offset
  if start >= 0: result.add((start, previous))

proc largestGap(ranges: seq[tuple[first, last: int]]): int {.raises: [].} =
  result = 0
  for index in 1 ..< ranges.len:
    let gap = ranges[index].first - ranges[index - 1].last - 1
    if gap > result: result = gap

proc renderRanges(ranges: seq[tuple[first, last: int]]): string {.raises: [].} =
  result = ""
  for item in ranges:
    if result.len > 0: result.add(" ")
    result.add($item.first & ".." & $item.last)

# --- real injected input ------------------------------------------------------
proc sendInput(entries: openArray[INPUT]) {.raises: [].} =
  if entries.len == 0: return
  discard SendInput(UINT(entries.len), cast[pointer](unsafeAddr entries[0]), int32(sizeof(INPUT)))

proc keyInput(vk: uint16, flags: uint32): INPUT {.raises: [].} =
  INPUT(theType: 1, u: INPUTUNION(ki: KEYBDINPUT(wVk: vk,
    wScan: uint16(MapVirtualKeyW(UINT(vk), 0)), dwFlags: flags, time: 0, dwExtraInfo: 0)))

proc sendCtrlA() {.raises: [].} =
  ## Real Ctrl+A chord: Ctrl down, A down, A up, Ctrl up.
  var chord: array[4, INPUT]
  chord[0] = keyInput(0x11'u16, 0)
  chord[1] = keyInput(0x41'u16, 0)
  chord[2] = keyInput(0x41'u16, KEYEVENTF_KEYUP)
  chord[3] = keyInput(0x11'u16, KEYEVENTF_KEYUP)
  sendInput(chord)

proc sendUnicodeChar(ch: char) {.raises: [].} =
  var packet: array[2, INPUT]
  packet[0] = INPUT(theType: 1, u: INPUTUNION(ki: KEYBDINPUT(wVk: 0,
    wScan: uint16(ord(ch)), dwFlags: KEYEVENTF_UNICODE, time: 0, dwExtraInfo: 0)))
  packet[1] = INPUT(theType: 1, u: INPUTUNION(ki: KEYBDINPUT(wVk: 0,
    wScan: uint16(ord(ch)), dwFlags: KEYEVENTF_UNICODE or KEYEVENTF_KEYUP, time: 0, dwExtraInfo: 0)))
  sendInput(packet)

var typingSent: int
var typingTarget: HWND
var typingText = ""
var tickStop: bool
var tickCount: int

proc inputLoop() {.thread.} =
  ## Types with real injected input, then keeps the pump awake for the settle.
  {.cast(gcsafe).}:
    sendCtrlA()
    Sleep(120)
    for ch in typingText:
      sendUnicodeChar(ch)
      inc typingSent
      Sleep(60)
    while not tickStop:
      discard PostMessageW(typingTarget, WM_HOST_TICK, 0, 0)
      inc tickCount
      Sleep(20)

# --- fixture ------------------------------------------------------------------
type Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession, runtime: Runtime]

var modelName = "Leaf 原生控件 😀"
var submits = 0
type RedrawModel = object
  name: string
  submits: int
let RedrawRoot = defineComponent[int, State[RedrawModel]]("NativeRedrawRoot",
  proc(ctx: MountContext, p: int): State[RedrawModel] =
    ctx.state(RedrawModel(name: "Leaf 原生控件 😀")),
  proc(ctx: ComponentContext, p: int, model: State[RedrawModel]): UiDescription =
    let m = ctx.value(model)
    modelName = m.name
    submits = m.submits
    host(column(@[
      text("Windows 原生表单", key = "title"),
      text("输入模式：echoValue", key = "mode"),
      input(m.name, key = "name", placeholder = "输入中文、日文或 emoji",
        onChange = proc(e: Event) = discard model.update(proc(v: RedrawModel): RedrawModel =
          (result = v; result.name = e.value)),
        onSubmit = proc(e: Event) = discard model.update(proc(v: RedrawModel): RedrawModel =
          (result = v; inc result.submits))),
      switch("接收通知", true, key = "notifications"),
      switch("组合期间更新冲突模型", false, key = "conflict"),
      row(@[
        button("保存", key = "save", onClick = proc(e: Event) =
          discard model.update(proc(v: RedrawModel): RedrawModel = (result = v; inc result.submits))),
        button("重置输入", key = "reset", onClick = proc(e: Event) = discard),
        button("切换输入模式", key = "nextMode", onClick = proc(e: Event) = discard)],
        key = "actions", styles = style({"gap": "12"})),
      text("已提交 " & $m.submits & " 次", key = "count"),
      text("模型：" & m.name, key = "model"),
      text("候选校验探针", key = "candidate"),
      progress(0.0, key = "progress")],
      key = "form", styles = style({"padding": "20", "gap": "12", "width": "full"}))))

proc mounted(): Fixture =
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    componentApplication(component(RedrawRoot, 0), "Native redraw", 640, 640),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost("Native redraw", DipSize(width: 640, height: 640))
  h.setStartupScope(proc(): bool = activity.busy or runtime.installingHook or runtime.installingUpdate)
  let win = newWin32Backend(h)
  let session = win.attachWin32Backend(runtime)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime)

var collected: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  collected.add(window)
  1

proc children(window: HWND): seq[HWND] {.raises: [].} =
  collected.setLen(0)
  discard EnumChildWindows(window, collect, 0)
  collected

proc findControl(window: HWND, class, prefix: string): HWND {.raises: [].} =
  for child in children(window):
    if className(child) == class and windowText(child).startsWith(prefix):
      return child

type
  Outcome = object
    typingSent: int
    typingTimedOut: bool
    pumpResult: int
    foreground: bool
    visible: bool
    focused: bool
    narrow: bool
    naturalWidth: int
    naturalPixels: seq[Pixel]
    freshPixels: seq[Pixel]
    naturalRanges: seq[tuple[first, last: int]]
    freshRanges: seq[tuple[first, last: int]]
    editText: string
    labelText: string
    modelText: string
    editTextAtTimeout: string
    labelTextAtTimeout: string

proc inspectLabelRefresh(h: Win32Host, session: BackendSession, label, edit: HWND): Outcome =
  ## Drives real input and reports what the settled screen actually showed.
  let state = new(Outcome)
  discard SetWindowSubclass(label, labelLogProc, 0xC0FFEE'u, 0)
  discard SetForegroundWindow(h.windowHandle)
  Sleep(300)
  state.visible = IsWindowVisible(h.windowHandle) != 0
  discard SetFocus(edit)
  Sleep(100)
  state.focused = GetFocus() == edit
  state.foreground = GetForegroundWindow() == h.windowHandle
  if not (state.visible and state.focused and state.foreground):
    return state[]
  let typed = "Leaf-keyboard"
  typingText = typed
  typingTarget = h.windowHandle
  typingSent = 0
  tickCount = 0
  tickStop = false
  var inputThread: Thread[void]
  createThread(inputThread, inputLoop)
  var stage = 0
  var matchedAt: DWORD = 0
  let stageStart = GetTickCount()
  h.setSafeTick(proc() =
    session.drainEvents()
    case stage
    of 0:
      if windowText(label) == "模型：" & typed:
        stage = 1
        matchedAt = GetTickCount()
      elif GetTickCount() - stageStart > 12000:
        # Bounded failure instead of a hanging suite; the capture still runs so the
        # report shows what the screen held.
        state.typingTimedOut = true
        state.editTextAtTimeout = textMessage(edit)
        state.labelTextAtTimeout = windowText(label)
        traceLine("=== typing timeout: sent=" & $typingSent & " edit=[" &
          state.editTextAtTimeout & "] label=[" & state.labelTextAtTimeout & "]")
        stage = 1
        matchedAt = GetTickCount()
    of 1:
      if GetTickCount() - matchedAt >= 2000:
        if GetForegroundWindow() != h.windowHandle: state.foreground = false
        var client: RECT
        discard GetClientRect(label, addr client)
        state.naturalWidth = int(client.right)
        state.naturalPixels = screenPixels(label)
        state.naturalRanges = inkRanges(state.naturalPixels)
        state.editText = textMessage(edit)
        state.labelText = windowText(label)
        state.modelText = modelName
        traceLine("=== settled capture width=" & $state.naturalWidth & " ink=" &
          renderRanges(state.naturalRanges))
        traceLine(pixelsText(state.naturalPixels, state.naturalWidth))
        stage = 2
    of 2:
      # Oracle: the same control's own fresh paint, without any resize.
      discard InvalidateRect(label, nil, BOOL(1))
      discard UpdateWindow(label)
      Sleep(200)
      state.freshPixels = screenPixels(label)
      state.freshRanges = inkRanges(state.freshPixels)
      traceLine("=== fresh capture ink=" & renderRanges(state.freshRanges))
      stage = 3
    else:
      h.requestClose())
  state.pumpResult = h.pump()
  tickStop = true
  joinThread(inputThread)
  state.typingSent = typingSent
  state.narrow = typingSent != typed.len
  return state[]

suite "W-REDRAW native text label refresh":
  test "settled screen shows the complete bound label text after real typing":
    let testOutput = getEnv("LEAF_WIN32_TEST_OUT", "")
    traceEnabled = testOutput.len > 0
    if traceEnabled: tracePath = testOutput / ".." / "redraw-trace.log"
    traceStart = GetTickCount()
    traceLine("=== suite start")
    let f = mounted()
    let label = findControl(f.h.windowHandle, "Static", "模型")
    let edit = findControl(f.h.windowHandle, "Edit", "")
    check label != nil
    check edit != nil
    if label != nil and edit != nil:
      let outcome = inspectLabelRefresh(f.h, f.s, label, edit)
      f.h.destroyHost()
      checkpoint("injected " & $outcome.typingSent & " real keystrokes; pump=" &
        $outcome.pumpResult & "; typingTimedOut=" & $outcome.typingTimedOut &
        "; editAtTimeout=[" & outcome.editTextAtTimeout & "]")
      check outcome.visible
      check outcome.focused
      check not outcome.typingTimedOut
      check outcome.typingSent == "Leaf-keyboard".len
      check outcome.pumpResult == 0
      # The value path was already correct in the failing case: accepted model,
      # EDIT text and the label's own WM_GETTEXT all followed the real input.
      check outcome.editText == "Leaf-keyboard"
      check outcome.labelText == "模型：Leaf-keyboard"
      check outcome.modelText == "Leaf-keyboard"
      checkpoint("settled label ink columns: " & renderRanges(outcome.naturalRanges))
      checkpoint("fresh label ink columns: " & renderRanges(outcome.freshRanges))
      check outcome.foreground
      check outcome.naturalPixels.len > 0
      check outcome.naturalRanges.len > 0
      # A complete single line has no wide interior hole. The stale screen left
      # an empty middle of ~73 columns between the prefix and the last glyph.
      check largestGap(outcome.naturalRanges) <= 20
      # The bound text must reach the width measured for it.
      if outcome.naturalRanges.len > 0:
        check outcome.naturalRanges[^1].last >= (outcome.naturalWidth * 4) div 5
      # ... and the settled screen must equal the control's own fresh paint.
      check outcome.naturalRanges == outcome.freshRanges
      check pixelDiff(outcome.naturalPixels, outcome.freshPixels) == 0
    else:
      f.h.destroyHost()
