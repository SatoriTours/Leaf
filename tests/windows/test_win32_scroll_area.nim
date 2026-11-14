when not defined(windows): {.error: "Native scroll area tests require Windows".}
import std/[unittest, tables, options, strutils, os]
import leaf
import ../fixture_app
import leaf/[ui_thread, native_theme, backend_session, native_layout]
import leaf/core as core
import leaf/scroll_area_protocol
import leaf/backend as protocol
import leaf/backends/win32/[api, host, backend, calls, scroll_area_host]
import leaf/ui as standard

const
  GwlStyle = -16'i32
  WsVScroll = 0x00200000'i32
  SbLineDown = 1
  SbEndScroll = 8

{.push stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetWindowLongW(window: HWND, index: int32): int32
proc SendMessageW(window: HWND, message: uint32, wp: WPARAM, lp: LPARAM): LRESULT
proc GetParent(window: HWND): HWND
{.pop.}

type
  MouseInput = object
    dx, dy: int32
    mouseData, flags, time: uint32
    extra: uint
  KeyboardInput = object
    vk, scan: uint16
    flags, time: uint32
    extra: uint
  HardwareInput = object
    message: uint32
    paramL, paramH: uint16
  InputUnion {.union.} = object
    mouse: MouseInput
    keyboard: KeyboardInput
    hardware: HardwareInput
  InputEvent = object
    kind: uint32
    payload: InputUnion
  ScrollState = ref object
    drafts: string
    applyDraft: proc(value: string) {.closure.}
    renders: int
    short, wide, invalidBody, nested, plain, dialog, dark, innerDialog, popup: bool

  Fixture = tuple[h: Win32Host, win: Win32Backend, s: BackendSession,
    runtime: Runtime]

proc SendInput(count: uint32, inputs: pointer, size: int32): uint32 {.stdcall, dynlib: "user32.dll", importc.}
proc SetForegroundWindow(window: HWND): BOOL {.stdcall, dynlib: "user32.dll", importc.}
proc SetCursorPos(x, y: int32): BOOL {.stdcall, dynlib: "user32.dll", importc.}
proc GetWindowTextW(window: HWND, buffer: pointer, size: int32): int32 {.stdcall, dynlib: "user32.dll", importc.}

proc readText(window: HWND): string =
  var buffer: array[256, uint16]
  let count = GetWindowTextW(window, addr buffer[0], 256)
  for i in 0..<count: result.add(char(buffer[i]))

proc formPage(state: ScrollState): Node =
  inc state.renders
  var fields: seq[Node] = @[]
  for index in 1 .. (if state.short: 1 else: 12):
    fields.add(standard.field(@[standard.label("字段 " & $index),
      standard.input(state.drafts, key = "sa-field-" & $index,
        placeholder = "草稿 " & $index,
        onChange = proc(e: Event) =
          state.drafts = e.value
          if state.applyDraft != nil: state.applyDraft(e.value))], key = "sa-row-" & $index))
  if state.innerDialog: fields.add(standard.dialog("Unsupported nested host", true,
    content = @[standard.label("body")], key = "inner-dialog"))
  if state.wide: fields.add(column(@[text("wide")], styles = style({"width": "2000"})))
  if state.nested:
    fields.add(column(@[standard.scrollArea(standard.scrollAreaContent(@[text("nested")]), 100)]))
  let body = if state.invalidBody: column(fields, key = "sa-content")
    else: standard.scrollAreaContent(fields, key = "sa-content")
  let area = if state.plain: column(@[body], key = "sa", styles = style({"height": "200"}))
    elif state.invalidBody:
      core.ui(NodeKind.column, key = "sa", children = @[body], styles = style({"height": "200"}),
        attributes = {"ui_role": "scrollArea"}.toTable)
    else: standard.scrollArea(body, 200, key = "sa")
  let content = if state.popup:
    column(@[standard.popover(standard.popoverTrigger("Open", key = "trigger"),
      standard.popoverContent(@[area], key = "panel-body"), open = true,
      name = "Scrolling panel", width = 360, key = "popover")], styles = style({"width": "full"}))
    elif state.dialog:
    column(@[standard.dialog("Long form", true, content = @[area],
      footer = @[standard.button("Save", key = "save")], key = "dialog")],
      styles = style({"width": "full"}))
    else: column(@[area], styles = style({"padding": "16", "gap": "12", "width": "full"}))
  standard.theme((if state.dark: UiColorMode.dark else: UiColorMode.light), content, key = "theme")

let ReactiveForm = defineComponent[ScrollState, State[string]]("ScrollEditFixture",
  proc(ctx: MountContext, p: ScrollState): State[string] = ctx.state(""),
  proc(ctx: ComponentContext, p: ScrollState, value: State[string]): UiDescription =
    p.drafts = ctx.value(value)
    p.applyDraft = proc(text: string) = discard value.update(proc(old: string): string = text)
    host(formPage(p)))

proc mounted(state: ScrollState, width = 420, height = 320, reactive = false, calls = systemWin32Calls()): Fixture =
  let activity = newUiScopeActivity()
  let base = if reactive:
    componentApplication(component(ReactiveForm, state), "Scroll area", width, height)
    else: fixtureApplication(proc(): Node = formPage(state), "Scroll area", width, height)
  let app = base.withNativeTheme(shadcnLight)
  let runtime = newRuntime(guardUiApplication(app,
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  let h = createHost(app.title, DipSize(width: float64(width),
    height: float64(height)), calls = calls, theme = shadcnLight)
  h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or
    runtime.installingHook)
  let win = newWin32Backend(h, calls = calls)
  let session = win.attachWin32Backend(runtime, protocol.strict)
  win.bindSession(session)
  h.bindSession(session, proc(): bool = activity.busy)
  (h, win, session, runtime)

proc settle(f: Fixture) =
  f.win.safeListTurn()
  discard f.runtime.refresh()
  f.win.safeListTurn()

proc close(f: Fixture) =
  f.h.destroyHost()
  f.runtime.closeRuntime()
  check f.win.diagnostics.liveWindows == 0
  check f.win.diagnostics.liveFonts == 0
  check f.win.diagnostics.liveRoots == 0

proc windowOf(f: Fixture, key: string): HWND =
  f.win.nativeWindowForTest(f.s.handleFor(f.runtime.find(key).id))

proc frameOf(window: HWND): RECT =
  if window == nil or GetWindowRect(window, addr result) == 0:
    result = RECT()

suite "native vertical scroll area":
  test "content taller than the viewport scrolls without rebuilding controls":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let viewport = f.windowOf("sa")
    let content = f.windowOf("sa-content")
    let edit = f.windowOf("sa-field-1")
    check viewport != nil
    check content != nil
    check edit != nil
    # The scroll root is a real viewport window that owns its content window.
    check GetParent(content) == viewport
    check (GetWindowLongW(viewport, GwlStyle) and WsVScroll) != 0
    let viewportFrame = frameOf(viewport)
    let contentFrame = frameOf(content)
    check viewportFrame.bottom - viewportFrame.top > 0
    check contentFrame.bottom - contentFrame.top >
      viewportFrame.bottom - viewportFrame.top
    # One real scroll through the native scrollbar message: only geometry moves.
    let topBefore = contentFrame.top
    discard SendMessageW(viewport, 0x0115'u32, WPARAM(SbLineDown), 0)
    discard SendMessageW(viewport, 0x0115'u32, WPARAM(SbEndScroll), 0)
    f.win.safeListTurn()
    let topAfter = frameOf(content).top
    check topAfter < topBefore
    # Control identity and business state are untouched by scrolling.
    check f.windowOf("sa-field-1") == edit
    check IsWindow(edit) != 0
    check state.drafts == ""
    check f.runtime.find("sa-field-1").node.text == ""

  test "scrollbar bottom matches inclusive extent and does not render":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let viewport = f.windowOf("sa")
    let body = f.windowOf("sa-content")
    let renders = state.renders
    discard SendMessageW(viewport, 0x0115, WPARAM(7), 0)
    f.win.safeListTurn()
    var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: 7)
    check GetScrollInfo(viewport, 1, addr info) != 0
    check info.nPos == info.nMax - int32(info.nPage) + 1
    check info.nPos > 500
    check frameOf(body).top == frameOf(viewport).top - info.nPos
    check state.renders == renders
    discard SendMessageW(viewport, 0x0115, WPARAM(6), 0)
    f.win.safeListTurn()
    check frameOf(body).top == frameOf(viewport).top

  test "two queued line inputs accumulate before the ordinary turn":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let viewport = f.windowOf("sa")
    let before = frameOf(f.windowOf("sa-content")).top
    discard SendMessageW(viewport, 0x0115, WPARAM(1), 0)
    discard SendMessageW(viewport, 0x0115, WPARAM(1), 0)
    f.win.safeListTurn()
    check before - frameOf(f.windowOf("sa-content")).top == 48

  test "focus reveals an initially offscreen EDIT without hiding its HWND":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let last = f.windowOf("sa-field-12")
    let view = f.windowOf("sa")
    check IsWindowVisible(last) != 0
    discard SetFocus(last)
    f.win.safeListTurn()
    check GetFocus() == last
    let field = frameOf(last)
    let viewport = frameOf(view)
    check field.top >= viewport.top
    check field.bottom <= viewport.bottom
    check f.windowOf("sa-field-12") == last

  test "viewport keyboard scroll does not take EDIT navigation keys":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let view = f.windowOf("sa")
    let body = f.windowOf("sa-content")
    discard SendMessageW(view, WM_KEYDOWN, WPARAM(VK_NEXT), 0)
    f.win.safeListTurn()
    check frameOf(body).top < frameOf(view).top
    let before = frameOf(body).top
    discard SendMessageW(f.windowOf("sa-field-1"), WM_KEYDOWN, WPARAM(VK_HOME), 0)
    f.win.safeListTurn()
    check frameOf(body).top == before

  test "content shrink clamps the accepted offset and preserves first EDIT":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let first = f.windowOf("sa-field-1")
    discard SendMessageW(f.windowOf("sa"), 0x0115, WPARAM(7), 0)
    f.win.safeListTurn()
    state.short = true
    settle(f)
    check frameOf(f.windowOf("sa-content")).top == frameOf(f.windowOf("sa")).top
    check f.windowOf("sa-field-1") == first

  test "invalid nested candidate is refused before changing accepted controls":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let first = f.windowOf("sa-field-1")
    state.nested = true
    expect UiError: discard f.runtime.refresh()
    check f.windowOf("sa-field-1") == first
    check IsWindow(first) != 0

  test "horizontal overflow candidate is refused before native destruction":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let first = f.windowOf("sa-field-1")
    let creates = f.win.diagnostics.creates
    state.wide = true
    expect UiError: discard f.runtime.refresh()
    check f.windowOf("sa-field-1") == first
    check f.win.diagnostics.creates == creates

  test "viewport role cannot silently morph into a plain column":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let view = f.windowOf("sa")
    state.plain = true
    expect UiError: discard f.runtime.refresh()
    check f.windowOf("sa") == view

  test "a bounded scrolling form fits in a modal and keeps its footer visible":
    let state = ScrollState(dialog: true)
    let f = mounted(state, 640, 600)
    defer: close(f)
    settle(f)
    let view = f.windowOf("sa")
    let footer = f.windowOf("save")
    check IsWindowVisible(view) != 0
    check IsWindowVisible(footer) != 0
    check IsWindowEnabled(f.h.windowHandle) == 0
    let before = frameOf(footer)
    discard SendMessageW(view, 0x0115, WPARAM(7), 0)
    f.win.safeListTurn()
    check frameOf(footer).top == before.top
    check frameOf(f.windowOf("sa-field-12")).bottom <= frameOf(view).bottom

  test "short content removes the vertical bar after monotonic width measurement":
    let state = ScrollState(short: true)
    let f = mounted(state)
    defer: close(f)
    settle(f)
    check (GetWindowLongW(f.windowOf("sa"), GWL_STYLE) and WS_VSCROLL) == 0

  test "EDIT draft selection and native Undo survive scrolling":
    let state = ScrollState()
    let f = mounted(state, reactive = true)
    defer: close(f)
    settle(f)
    let edit = f.windowOf("sa-field-1")
    discard SetFocus(edit)
    discard SendMessageW(edit, 0x0102, WPARAM(ord('x')), 0) # WM_CHAR enters real EDIT undo state
    f.win.safeListTurn()
    require SendMessageW(edit, 0x00c6, 0, 0) != 0 # EM_CANUNDO
    let textBefore = readText(edit)
    discard SendMessageW(edit, 0x00b1, 0, 1) # EM_SETSEL
    let selection = SendMessageW(edit, 0x00b0, 0, 0)
    let renders = state.renders
    discard SendMessageW(f.windowOf("sa"), 0x0115, WPARAM(7), 0)
    f.win.safeListTurn()
    check f.windowOf("sa-field-1") == edit
    check readText(edit) == textBefore
    check SendMessageW(edit, 0x00b0, 0, 0) == selection
    check SendMessageW(edit, 0x00c6, 0, 0) != 0
    check state.renders == renders
    check SendMessageW(edit, 0x00c7, 0, 0) != 0 # EM_UNDO
    check readText(edit) == ""

  test "real mouse wheel input reaches the viewport through the production pump":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    discard SetForegroundWindow(f.h.windowHandle)
    let viewport = f.windowOf("sa")
    discard SetFocus(viewport)
    let frame = frameOf(viewport)
    require SetCursorPos(frame.left + 40, frame.top + 100) != 0
    var input: InputEvent
    input.kind = 0
    input.payload.mouse = MouseInput(mouseData: cast[uint32](-120'i32), flags: 0x0800)
    require SendInput(1, addr input, int32(sizeof(input))) == 1
    for i in 0..<10:
      sleep(20)
      discard f.h.pumpQueued()
      f.win.safeListTurn()
    check frameOf(f.windowOf("sa-content")).top < frame.top

  test "Tab through the production pump reveals successive offscreen fields":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    discard SetForegroundWindow(f.h.windowHandle)
    discard SetFocus(f.windowOf("sa-field-1"))
    f.win.safeListTurn()
    for i in 0..<11:
      var input: array[2, InputEvent]
      input[0].kind = 1
      input[0].payload.keyboard.vk = 9
      input[1] = input[0]
      input[1].payload.keyboard.flags = 2
      require SendInput(2, addr input[0], int32(sizeof(InputEvent))) == 2
      let expected = f.windowOf("sa-field-" & $(i + 2))
      for attempt in 0..<20:
        sleep(20)
        discard f.h.pumpQueued()
        f.win.safeListTurn()
        if GetFocus() == expected: break
      for index in 1..12:
        if GetFocus() == f.windowOf("sa-field-" & $index): echo "SCROLLTAB step=", i + 1, " field=", index
      check GetFocus() == expected
    let last = f.windowOf("sa-field-12")
    check GetFocus() == last
    check frameOf(last).bottom <= frameOf(f.windowOf("sa")).bottom


  test "failed native movement never publishes an offset or range":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    var calls = systemWin32Calls()
    let realMove = calls.windowPos
    var refuse, throwing: bool
    calls.windowPos = proc(window, after: HWND, x, y, width, height: int32, flags: UINT): BOOL =
      if refuse:
        if throwing: raise newException(IOError, "injected scroll movement exception")
        setLastError(5)
        return 0
      realMove(window, after, x, y, width, height, flags)
    let scroll = newScrollArea(calls, f.windowOf("sa"))
    scroll.attachContent(f.windowOf("sa-content"))
    let plan = ScrollAreaPlan(viewportWidth: 300, viewportHeight: 200,
      contentHeight: 800, range: 600)
    scroll.applyPlan(plan, 1)
    refuse = true
    expect UiError: scroll.scrollTo(100)
    check scroll.offset == 0
    check scroll.range == 600
    var info = SCROLLINFO(cbSize: UINT(sizeof(SCROLLINFO)), fMask: 7)
    require GetScrollInfo(scroll.viewport, 1, addr info) != 0
    check info.nPos == 0
    throwing = true
    expect IOError: scroll.scrollTo(120)
    check scroll.offset == 0
    require GetScrollInfo(scroll.viewport, 1, addr info) != 0
    check info.nPos == 0
    var changed = plan
    changed.range = 800
    changed.contentHeight = 1000
    expect IOError: scroll.applyPlan(changed, 1)
    check scroll.offset == 0
    check scroll.range == 600
    refuse = false
    scroll.scrollTo(150)
    check scroll.offset == 150
    scroll.close()


  test "native turn failure propagates and existing lifecycle releases controls":
    var calls = systemWin32Calls()
    let realMove = calls.windowPos
    var target: HWND
    var failures = 0
    calls.windowPos = proc(window, after: HWND, x, y, width, height: int32, flags: UINT): BOOL =
      if target != nil and window == target and y < 0:
        inc failures
        setLastError(5)
        return 0
      realMove(window, after, x, y, width, height, flags)
    let f = mounted(ScrollState(), calls = calls)
    defer: close(f)
    settle(f)
    target = f.windowOf("sa-content")
    discard PostMessageW(f.windowOf("sa"), 0x0115, WPARAM(1), 0)
    expect UiError: discard f.h.pump()
    check failures == 1


  test "a popup domain inside scrolling content is rejected before native creation":
    let state = ScrollState()
    let f = mounted(state)
    defer: close(f)
    settle(f)
    let before = f.windowOf("sa-field-1")
    let creates = f.win.diagnostics.creates
    state.innerDialog = true
    expect UiError: discard f.runtime.refresh()
    check f.windowOf("sa-field-1") == before
    check f.win.diagnostics.creates == creates


  test "popover body uses its own viewport domain rather than page layout":
    let f = mounted(ScrollState(popup: true), 640, 600)
    defer: close(f)
    settle(f)
    let view = f.windowOf("sa")
    require IsWindowVisible(view) != 0
    let before = frameOf(f.windowOf("sa-content")).top
    discard SendMessageW(view, 0x0115, WPARAM(1), 0)
    f.win.safeListTurn()
    check frameOf(f.windowOf("sa-content")).top < before
