## Test-only application for cross-process UIA gating with a real safe-turn fence.
##
## The page mirrors the Dialog demo surface (background action + EDIT, Dialog,
## nested Dialog, AlertDialog) and adds a monotonic safe-turn sequence plus a
## fence handshake. The fence is serviced inside the production safe tick
## (`setSafeTick` + `h.pump()`); a test-only window subclass only records the
## request id, it never acknowledges or runs business work.
when not defined(windows):
  {.error: "dialog_fence_app requires Windows".}
import std/[os, widestrs]
import leaf
import leaf/ui as standard
import leaf/backend
import leaf/native_layout
import leaf/backends/win32/[api, host, backend, calls]
import leaf/[ui_thread, native_theme, styles, backend_session]

const
  FenceMessage = 0x8000'u32 + 0x2A
  FenceAckProp = "leafFenceAck"
  FenceTurnProp = "leafFenceTurn"
  TurnSeqProp = "leafTurnSeq"

type
  Model = object
    open, inner, alert, renamed, dark: bool
    name: string
    pageNote: string
    saved, cancelled, deleted: int

proc SetPropW(window: HWND, name: WidePtr, value: HANDLE): BOOL
  {.stdcall, dynlib: "user32.dll", importc, raises: [].}

var renderCount = 0

proc GetPropW(window: HWND, name: WidePtr): HANDLE
  {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc RemovePropW(window: HWND, name: WidePtr): HANDLE
  {.stdcall, dynlib: "user32.dll", importc, raises: [].}

proc page(m: Model, state: State[Model]): Node =
  inc renderCount
  var content: seq[Node]
  content.add(standard.button("打开对话框", key = "open",
    onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.open = true)))
  content.add(standard.button("切换浅色/深色", key = "theme", variant = UiVariant.outline,
    onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.dark = not result.dark)))
  content.add(standard.button("打开危险确认", key = "alert-trigger",
    onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.alert = true)))
  content.add(standard.field(@[standard.label("页面备注"),
    standard.input(m.pageNote, key = "page-note", onChange = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.pageNote = e.value))]))
  content.add(standard.fieldDescription("已保存 " & $m.saved & " 次 · 已取消 " &
    $m.cancelled & " 次 · 已删除 " & $m.deleted & " 次", key = "counters"))
  content.add(standard.dialog((if m.renamed: "编辑联系人（已重命名）" else: "编辑联系人"), m.open,
    description = "名称会写入临时草稿。", key = "dialog",
    onDismiss = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.open = false),
    content = @[standard.field(@[standard.label("名称"),
      standard.input(m.name, key = "name", onChange = proc(e: Event) = discard state.update(proc(old: Model): Model =
        result = old; result.name = e.value))])],
    footer = @[
      standard.button("取消", key = "cancel", variant = UiVariant.outline,
        onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.open = false; inc result.cancelled)),
      standard.button("重命名标题", key = "rename", variant = UiVariant.outline,
        onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.renamed = not result.renamed)),
      standard.button("打开内层对话框", key = "open-inner",
        onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.inner = true)),
      standard.button("保存", key = "save",
        onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.open = false; inc result.saved))]))
  content.add(standard.dialog("内层对话框", m.inner, key = "dialog-inner",
    onDismiss = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.inner = false),
    content = @[standard.fieldDescription("内层说明")],
    footer = @[standard.button("关闭内层", key = "close-inner",
      onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.inner = false))]))
  content.add(standard.alertDialog("删除联系人",
    standard.alertDialogCancel("保留", key = "alert-cancel",
      onClick = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.alert = false)),
    m.alert,
    standard.alertDialogAction("删除", proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; inc result.deleted; result.alert = false), key = "alert-delete",
      variant = UiVariant.destructive),
    description = "不能撤销。", key = "alert",
    onDismiss = proc(e: Event) = discard state.update(proc(old: Model): Model =
      result = old; result.alert = false)))
  standard.theme((if m.dark: UiColorMode.dark else: UiColorMode.light),
    column(content, key = "root"),
    key = "theme")

let FenceRoot = defineComponent[int, State[Model]]("DialogFence",
  proc(ctx: MountContext, p: int): State[Model] = ctx.state(Model(name: "Ada")),
  proc(ctx: ComponentContext, p: int, state: State[Model]): UiDescription =
    host(page(ctx.value(state), state)))

var
  pendingFence = 0
  ackedFence = 0
  ackedTurn = 0
  turnSeq = 0
  hostRef: Win32Host
  tickRef: proc() {.closure.}
  callbackFailure: string

type SUBCLASSPROC = proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM,
  id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall.}

proc SetWindowSubclass(window: HWND, callback: SUBCLASSPROC, id: UINT_PTR,
  data: DWORD_PTR): BOOL {.stdcall, dynlib: "comctl32.dll", importc, raises: [].}
proc RemoveWindowSubclass(window: HWND, callback: SUBCLASSPROC,
  id: UINT_PTR): BOOL {.stdcall, dynlib: "comctl32.dll", importc, raises: [].}
proc DefSubclassProc(window: HWND, message: UINT, wp: WPARAM,
  lp: LPARAM): LRESULT {.stdcall, dynlib: "comctl32.dll", importc, raises: [].}

proc publish(window: HWND) =
  ## Data first, acknowledgement id last: a reader that sees the new id can
  ## trust the pair it reads with it.
  let renders = newWideCString("leafRenderCount")
  if SetPropW(window, cast[WidePtr](unsafeAddr renders[0]), cast[HANDLE](renderCount)) == 0: raise newException(IOError, "fence property publication failed")
  let turnName = newWideCString("leafFenceTurn")
  let seqName = newWideCString("leafTurnSeq")
  let ackName = newWideCString("leafFenceAck")
  if SetPropW(window, cast[WidePtr](unsafeAddr turnName[0]), cast[HANDLE](ackedTurn + 1)) == 0: raise newException(IOError, "fence property publication failed")
  if SetPropW(window, cast[WidePtr](unsafeAddr seqName[0]), cast[HANDLE](turnSeq + 1)) == 0: raise newException(IOError, "fence property publication failed")
  let ackWindow = if pendingFence != 0 and getEnv("LEAF_FENCE_TEST_FAULT") == "property": nil else: window
  if SetPropW(ackWindow, cast[WidePtr](unsafeAddr ackName[0]), cast[HANDLE](ackedFence + 1)) == 0: raise newException(IOError, "fence property publication failed")

proc subclass(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM,
    id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall, raises: [].} =
  if message == 0x0082'u32: # WM_NCDESTROY: detach only this fixture's hook/data.
    for name in [FenceAckProp, FenceTurnProp, TurnSeqProp, "leafRenderCount"]:
      let wide = newWideCString(name)
      let key = cast[WidePtr](unsafeAddr wide[0])
      if GetPropW(window, key) != nil and RemovePropW(window, key) == nil:
        callbackFailure = "fence property removal failed"
    if RemoveWindowSubclass(window, subclass, 0x4C46) == 0:
      callbackFailure = "fence subclass removal failed"
  if message == FenceMessage:
    # Record only. The safe tick publishes the acknowledgement after it really
    # ran; the window procedure must never acknowledge business work.
    if wp == 0 or uint64(wp) > uint64(high(int32)) or int(wp) <= ackedFence or pendingFence != 0:
      callbackFailure = "invalid, repeated or overlapping fence request"
    else:
      pendingFence = int(wp)
    if hostRef != nil:
      try:
        hostRef.setSafeTick(tickRef)  # the existing setter wakes the pump
      except CatchableError as error:
        callbackFailure = error.msg
    return 0
  DefSubclassProc(window, message, wp, lp)

proc main(): int =
  let activity = newUiScopeActivity()
  let runtime = newRuntime(guardUiApplication(
    componentApplication(component(FenceRoot, 0), "Leaf — 模态对话框", 640, 600),
    proc(): uint64 = uint64(GetCurrentThreadId()), activity))
  var exitCode = 1
  var h: Win32Host
  var win: Win32Backend
  var session: BackendSession
  try:
    h = createHost("Leaf — 模态对话框", DipSize(width: 640, height: 600),
      theme = shadcnLight)
    hostRef = h
    h.setStartupScope(proc(): bool = activity.busy or
      runtime.installingUpdate or runtime.installingHook)
    win = newWin32Backend(h)
    session = win.attachWin32Backend(runtime)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    tickRef = proc() =
      if callbackFailure.len != 0: raise newException(IOError, callbackFailure)
      if pendingFence != 0 and getEnv("LEAF_FENCE_TEST_FAULT") == "turn":
        raise newException(IOError, "injected safe-turn failure")
      # Match runNative: exactly one safeListTurn, no forced root refresh.
      win.safeListTurn()
      inc turnSeq
      if pendingFence != 0:
        ackedFence = pendingFence
        ackedTurn = turnSeq
      publish(h.windowHandle)
      pendingFence = 0
    h.setSafeTick(tickRef)
    if SetWindowSubclass(h.windowHandle, subclass, 0x4C46, 0) == 0:
      raise newException(IOError, "fence subclass installation failed")
    exitCode = h.pump()
    if callbackFailure.len != 0: raise newException(IOError, callbackFailure)
  except CatchableError as error:
    stderr.writeLine("fence app error: " & error.msg)
    exitCode = 1
  finally:
    if h != nil:
      try: h.destroyHost()
      except CatchableError as error:
        stderr.writeLine("fence cleanup error: " & error.msg)
        exitCode = 1
    try: runtime.closeRuntime()
    except CatchableError as error:
      stderr.writeLine("runtime cleanup error: " & error.msg)
      exitCode = 1
  if callbackFailure.len != 0:
    stderr.writeLine("fence callback/cleanup error: " & callbackFailure)
    exitCode = 1
  hostRef = nil
  tickRef = nil
  exitCode

when isMainModule: quit(main())
