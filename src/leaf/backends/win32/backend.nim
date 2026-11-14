## Owned Unicode controls, incremental updates and native event capture.
import std/[tables, options, algorithm, widestrs, sets, sequtils, strutils, math]
import ../../[core, styles, backend, backend_session, native_layout, native_edit, native_measure_cache,
  height_index, native_list_layout, native_theme, graphics, canvas_input, overlay_protocol,
  select_protocol, popover_protocol]
import ./[api, calls, host, capabilities, measure, control_ids, list_host, row_pool,
  resource_owner, navigation_input, skin, canvas, layout_state, focus_ring, accessibility,
  live_provider, overlay_host, select_host, select_provider, popover_host]
import ../../ui/[fields, theme]
import ../../overlay_geometry

proc GetForegroundWindow(): HWND {.stdcall,dynlib:"user32.dll",importc,raises:[].}

type
  Win32Diagnostics* = object
    creates*, destroys*, setTexts*, measures*, layouts*, callbackErrors*: uint64
    liveWindows*, liveFonts*, liveSubclasses*, liveRoots*: int
    liveOverlays*, overlayShows*, overlayDismissRequests*: int
    liveSelects*, selectShows*, selectRepositions*, selectRequests*: int
    selectCommits*, selectCloses*, selectGateDrops*: int
    livePopovers*, popoverShows*, popoverRepositions*, popoverRequests*: int
    popoverCloses*, popoverGateDrops*, popoverRejects*: int
    listViewports*, liveRows*, parkedRows*, reusedRows*, scrollTicks*: int
  OverlayPlan* = object
    ## Fully prepared per-level geometry. `width`/`height` are the validated
    ## client size in DIP; the pixel placement is filled in during apply so the
    ## publish step performs no arithmetic that could fail.
    open*: bool
    width*, height*: float64
      ## width is the final client width (work area already applied) and height
      ## is the content measured AT that width; nothing downstream re-clamps.
    x*, y*, widthPx*, heightPx*: int32
    scrimRect*: tuple[left, top, right, bottom: int32]
    placed*: bool
    scrollX*, rangeX*, contentW*: float64
      ## Horizontal twin of the vertical scroll fields; both come from the one
      ## pure geometry candidate (`overlay_geometry`).
    barFault*: bool
      ## A bar step failed: the level keeps its accepted plan, the bar keeps its
      ## previous receipts, and the next tick retries instead of pretending the
      ## bar is published.
    geom*: OverlayGeometry
      ## The accepted candidate: viewport, ranges, offsets and bar rectangles.
    contentRects*: Table[NodeHandle, DipRect]
      ## Content-space rect per control, used for focus-into-view math.
    scrollY*, rangeY*, contentH*: float64
      ## Vertical content scroll of this level: natural content height, the
      ## clamped offset and the maximum offset. Zero range means no scrolling.

  NativeControl = ref object
    window: HWND
    cookie: uint
    commandId: uint16
    parentWindow: HWND
    entity: MountedEntity
    editor: EditorState
    armed, subclassed, viewport, fresh: bool
    staged: bool
      ## prepared view still owned by a borrow group (non-owning stage)
    handle: NodeHandle
    entry: ResEntry
      ## stable per-window authority shared with the owning resource group
    bindingToken: uint64
      ## stable key into the backend's typed binding store
    owner: Win32Backend
      ## owner back-pointer for the irreversible NCDESTROY completion
    setterDepth: int
    binding: uint64
    canvas: CanvasSurface
    live: LiveProvider
    pointerMachine: CanvasPointerMachine
    pointerOwner: Option[CanvasBindingId]
    lastPointer: PointerSample
    trackingMouse: bool
    acceptedNavigation: Option[HostNavigationProps]
    backEnabled: bool
    appliedPosition: Option[tuple[x, y, width, height: int]]
    appliedClip: Option[tuple[left, top, right, bottom: int]]
    appliedVisible: Option[bool]
    capture: proc(control: NativeControl, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT {.closure.}
  Win32Backend* = ref object
    host: Win32Host
    theme, initialTheme, preparedTheme: NativeTheme
    renderer: CanvasRenderer
    focusAdornment: FocusRing
    annotations: NativeAnnotations
    liveContext: LiveContext
    selectContext: SelectContext
      ## Dedicated select provider context; owns no window of its own.
    preparedFields: Table[NodeHandle,FieldAssociation]
    calls: Win32Calls
    owner: DWORD
    lease: HostBackendLease
    protocol: Backend
    session: BackendSession
    closed, rebound, bound, dirty, fontDirty: bool
    retiredMeasures: seq[NativeMeasure]
    depth: int
    measurement: NativeMeasure
    fontEpoch: uint64
      ## Advances only after the fresh font is installed on native controls.
    controls: Table[NodeHandle, NativeControl]
    prepared: Table[NodeHandle, NativeControl]
    preparedModels: Table[NodeHandle, PreparedModelAccept]
    # current/candidate are lazy native layout/apply state; there is no
    # MaxNodes preallocation. The old `accepted` copy was never read and was
    # removed: accepted metadata lives in the native consumer's prepared map.
    current, candidate: Table[NodeHandle, MountedEntity]
    cache: MeasureCache
    appliedOrders: Table[NodeHandle, seq[HWND]]
    controlIds: ControlIdPool
    pendingRegions: seq[HRGN]
    pendingContexts: seq[tuple[window: HWND, context: HIMC]]
    lists: Table[NodeHandle, Win32ListHost]
    resources: ResRegistry
      ## Pure native resource state. Every live window has exactly one
      ## `ResEntry` (here or in a group); `gpParked` is the reusable set.
    bindings: Table[uint64, NativeControl]
      ## The only Nim strong root of a native binding: stable resource token ->
      ## typed control. Cookie/control tables above are views/indexes only.
    nextBindingToken: uint64
    borrowGroup: ResGroup
      ## The parked group currently re-keyed for a candidate row.
    reusedBorrows: int
      ## Successful parked-group hand-overs (counted only on the commit).
    retiring: Table[NodeHandle, NativeControl]
    rollbackFrames: seq[tuple[handle: NodeHandle, sourceGeneration: uint64,
      frame: ListFrame, desiredOffset: float64, intentGeneration: uint64]]
      ## Persistent rollback pins: established in prepare, survive teardown and
      ## the recovery prepare/apply, cleared by accept/discard or after restore.
    pendingFrames: seq[NodeHandle]
      ## Lists whose candidate geometry succeeded and waits for the real accept.
    applying, restoring, replaying: bool
    lastFailedFrame: ListFrame
    lastFailedPhase: string
    lastFailedValid: bool
    restoreReplayCount, restoreAppliedCount: int
      ## Recovery receipts, counted separately: how often a pinned accepted plan
      ## was selected, and how often one whole plan apply actually succeeded.
    rowMeasureCount, measureCacheHits: int
      ## Real entry counters: one per row that entered the measurement path, one
      ## per measurement cache hit. Named separately so "row plan not re-measured"
      ## is observed at its own entry instead of a structurally dead branch.
    restoreMeasureBase, restoreCacheBase: int
      ## Counter values captured when the recovery starts.
    nextPlanToken: uint64
      ## Backend-wide frame/plan token, independent of a recreated list host.
    listDirty: bool
    listScope: LayoutScope
    sessionId, generation, sequence, revision, nextBinding: uint64
    stats: Win32Diagnostics
    overlays: Table[NodeHandle, Win32Overlay]
      ## One owned modal level (surface + scrim) per accepted overlay root.
    preparedOverlays: seq[NodeHandle]
      ## Levels whose native windows were created by the current prepare only.
    overlayStack: OverlayStack
      ## Published nesting, bottom to top; the topmost level owns the modality.
    overlayPlans: Table[NodeHandle, OverlayPlan]
      ## Candidate geometry prepared for the revision being installed.
    overlayAcceptedPlans: Table[NodeHandle, OverlayPlan]
      ## Accepted geometry, including the pixel placement used at publish time.
    overlayPublishPending: bool
      ## A revision changed the visible modal set; the OS publish step runs in
      ## the next ordinary turn, never inside apply/accept.
    overlayUnexpectedCompositions, overlayUnsupportedShrinks: int
      ## A shrink that could not be handled as a known header/content/footer
      ## shape, and a shrink below the supported minimum (previous geometry is
      ## kept in both cases).
    overlayShrinkFallbacks: int
      ## Geometry ticks where the accepted size no longer fit and the safe
      ## actions were pinned instead of silently clipped away.
    overlayGateDrops: uint64
      ## Input refused because it came from outside the topmost modal level.
    overlayFocusBefore: Table[NodeHandle, HWND]
    overlayPendingFocus: HashSet[NodeHandle]
      ## Levels whose initial focus is planned after their first real layout;
      ## before that, their controls are not yet placed or visible.
      ## Real previously focused control per level, validated on restore.
    overlayDirty: bool
      ## A level became visible/hidden, so one geometry pass is required even
      ## though no layout property changed.
    selects: Table[NodeHandle, Win32Select]
      ## One owned anchored popup per accepted select root.
    popovers: Table[NodeHandle, Win32Popover]
      ## One owned non-modal panel per accepted popover root.
    popoverRects: Table[NodeHandle, tuple[x, y, width, height: int32]]
    selectRects: Table[NodeHandle, tuple[x, y, width, height: int32]]
      ## Delivered popup rectangle, so a moved or scrolled anchor is republished
      ## only when the accepted geometry really changed.
    pendingError: ref CatchableError
    pendingInputFailure: bool

var controlsByCookie {.threadvar.}: Table[uint, NativeControl]
var listsByCookie {.threadvar.}: Table[uint, Win32ListHost]
var nextCookie {.threadvar.}: uint
var nextBackRequest {.threadvar.}: uint64
  ## UI-owner lifetime, not backend/session lifetime: retained routers reject
  ## reused request identities after a remount or a replay rebind.

proc checkOwner(win: Win32Backend) =
  if win == nil or win.owner != GetCurrentThreadId(): fail("Win32 backend owner thread required")
when defined(leafProtocolProbes):
  proc recordFailedFrame(win: Win32Backend, frame: ListFrame, phase: string) =
    ## Failure path only. It keeps a metadata reference to the one bounded failed
    ## frame (no native handle, no owner, no seq): this runs inside a defer that
    ## may unwind a Defect, so it must not allocate. The probe materialises the
    ## per-index heights later, outside any fence or exception chain.
    win.lastFailedFrame = frame
    win.lastFailedPhase = phase
    win.lastFailedValid = true

proc checkLive(win: Win32Backend) =
  win.checkOwner()
  if win.closed: fail("native backend is closed")
proc nativeError(operation: string) {.noreturn.} =
  fail(operation & " failed: " & $lastError())
proc markError(win: Win32Backend, error: ref CatchableError) {.raises: [].} =
  inc win.stats.callbackErrors
  if win.pendingError == nil: win.pendingError = error
proc reportError(win: Win32Backend) =
  if win.pendingError != nil:
    let error = win.pendingError
    win.pendingError = nil
    if win.pendingInputFailure and win.session != nil:
      win.pendingInputFailure = false
      win.session.faultBackendEffects(win.protocol, "Canvas input failed: " & error.msg)
    raise error

proc finalizeControl(control: NativeControl) {.raises: [].} =
  ## The only success completion for one control: ran on a real successful
  ## DestroyWindow BOOL or an irreversible NCDESTROY. It clears exactly this
  ## control's global identity (never the whole cookie table, never another
  ## host) so no thread-global table keeps a closed graph alive.
  if control == nil: return
  controlsByCookie.del(control.cookie)
  listsByCookie.del(control.cookie)
  control.window = nil
  control.subclassed = false
  control.armed = false
  control.capture = nil

proc forgetControl(win: Win32Backend, control: NativeControl) {.raises: [].} =
  ## Drop the exact owner entry of this control/viewport (idempotent).
  if control == nil: return
  win.controls.del(control.handle)
  win.retiring.del(control.handle)
  win.prepared.del(control.handle)
  if control.viewport: win.lists.del(control.handle)

proc captureNative(operation: string): ref CatchableError {.raises: [].} =
  try: nativeError(operation)
  except CatchableError as error: return error

proc nextBindingToken(win: Win32Backend): uint64 =
  inc win.nextBindingToken
  if win.nextBindingToken == 0: fail("native binding token space exhausted")
  win.nextBindingToken

proc nextPlanToken(win: Win32Backend): uint64 =
  ## Stable plan identity for frames/plans. It never resets with a recreated
  ## list host, so a recovery receipt can be tied to the accepted frame.
  inc win.nextPlanToken
  win.nextPlanToken

proc bindControl(win: Win32Backend, control: NativeControl): uint64 =
  ## Strong typed root. Fail-able preparation: always runs before the native
  ## call that can install a callback or before a handover, never after.
  let token = win.nextBindingToken()
  control.bindingToken = token
  win.bindings[token] = control
  token

proc controlFor(win: Win32Backend, token: uint64): NativeControl =
  ## Strong typed lease from the store; nil when the binding was retired.
  if token == 0: return nil
  win.bindings.getOrDefault(token)

proc unbindControl(win: Win32Backend, token: uint64) =
  ## Last step, after every access to the control: non-failing table delete.
  if token == 0: return
  let control = win.bindings.getOrDefault(token)
  if control != nil and control.canvas != nil:
    control.canvas.releaseCanvasInternal()
    control.canvas = nil
  if control != nil and control.live != nil:
    try:
      control.live.detach()
      control.live = nil
    except CatchableError as error:
      win.markError(error)
      return # retain the binding/receipt for a later safe cleanup attempt
  win.bindings.del(token)

proc retireOrphanBinding(win: Win32Backend, token: uint64) =
  ## A store entry whose resource entry is already gone and whose window never
  ## appeared (a failed creation): only the Nim graph is dropped, no native
  ## credential is claimed.
  let control = win.controlFor(token)
  if control == nil: return
  if control.window != nil: return
  # Record the scalar phase of the never-created entry *before* any identity is
  # dropped; a window that is alive is never marked ended here.
  let entry = control.entry
  if entry != nil and entry.window == nil: noteWindowEnded(entry)
  controlsByCookie.del(control.cookie)
  listsByCookie.del(control.cookie)
  control.subclassed = false
  control.capture = nil
  control.entry = nil
  win.unbindControl(token)
  if entry != nil and entry.token == token: entry.token = 0

proc retireBinding(win: Win32Backend, entry: ResEntry) =
  ## Non-native retirement of a binding under its store root: callback identity
  ## is already gone, so only capture/cookie/reverse-binding and the store entry
  ## are removed. Used for park unlink, abandon and an interrupted Nim cleanup
  ## after the window already ended.
  if entry == nil or entry.token == 0: return
  let control = win.controlFor(entry.token)
  if control != nil:
    controlsByCookie.del(control.cookie)
    listsByCookie.del(control.cookie)
    control.subclassed = false
    control.capture = nil
    control.entry = nil
  win.unbindControl(entry.token)
  entry.token = 0

proc newMeasurement(win: Win32Backend): NativeMeasure =
  newNativeMeasure(win.host.windowHandle,win.calls,win.theme != systemTheme,
    standardFonts=win.theme.isShadcn)

proc fontRole(win: Win32Backend, entity: MountedEntity): NativeFontRole =
  if entity.props.standardUi.isSome:
    let props = entity.props.standardUi.get
    case props.role
    of UiRole.button:
      return if props.size in {UiSize.xs, UiSize.iconXs}: smallControlFont else: controlFont
    of UiRole.emptyTitle: return emptyTitleFont
    of UiRole.badge,UiRole.kbd: return smallControlFont
    of UiRole.cardTitle: return cardTitleFont
    of UiRole.alertTitle,UiRole.label,UiRole.checkbox,UiRole.switch: return labelFont
    of UiRole.alertDescription,UiRole.fieldDescription, UiRole.fieldError, UiRole.inputGroupText: return hintFont
    else: return defaultFont
  if win.theme != systemTheme and entity.kind == NodeKind.button: return captionFont
  if win.theme != systemTheme and entity.kind in {NodeKind.text, NodeKind.input}:
    case entity.props.control.variant.get(variantDefault)
    of variantPrimary: return headingFont
    of variantSecondary: return captionFont
    else: discard
  defaultFont

proc controlProc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM,
                 id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall, raises: [].} =
  let control = controlsByCookie.getOrDefault(data)
  if control == nil or control.window != window:
    return DefSubclassProc(window, message, wp, lp)
  if message == WM_NCDESTROY:
    try:
      # External owner destruction still clears annotations while the exact
      # HWND identity is alive. A callback failure is surfaced at a safe turn.
      try:
        control.live.detach()
        control.owner.annotations.clear(window)
      except CatchableError as error: control.owner.markError(error)
      discard RemoveWindowSubclass(window, controlProc, id)
      return DefSubclassProc(window, message, wp, lp)
    finally:
      # Irreversible notification: the entry is ended *first*, then the
      # (unfailable) bookkeeping runs.
      noteWindowEnded(control.entry)
      finalizeControl(control)
      if control.owner != nil: control.owner.forgetControl(control)
      control.entry = nil
      if control.owner != nil:
        control.owner.unbindControl(control.bindingToken)
      control.bindingToken = 0
  # capture owns the exception boundary and invokes DefSubclassProc exactly once.
  {.cast(raises: []).}:
    return control.capture(control, message, wp, lp)

proc listProc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM,
             id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall, raises: [].} =
  ## Viewport callback: record scroll intent and forward child commands. It never
  ## lays out, materializes or commits; the owner wakes an ordinary safe turn.
  let list = listsByCookie.getOrDefault(data)
  if list == nil or list.window != window:
    return DefSubclassProc(window, message, wp, lp)
  if message == WM_NCDESTROY:
    try:
      discard RemoveWindowSubclass(window, listProc, id)
      return DefSubclassProc(window, message, wp, lp)
    finally:
      list.window = nil
      listsByCookie.del(data)
  {.cast(raises: []).}:
    try:
      let paintControl = controlsByCookie.getOrDefault(data)
      if paintControl != nil:
        var paintReply: LRESULT
        if skinMessage(paintControl.owner.theme, window, message, wp, lp, paintReply):
          return paintReply
      if message == BackSysKeyDown or message == BackAppCommand:
        let control = controlsByCookie.getOrDefault(data)
        if control != nil: return control.capture(control, message, wp, lp)
      case message
      of WM_COMMAND:
        if list.commands != nil and list.commands(window, wp, lp): return 0
        return DefSubclassProc(window, message, wp, lp)
      of 0x0084'u32, 0x00A1'u32: # WM_NCHITTEST, WM_NCLBUTTONDOWN
        # STATIC neither identifies its scrollbar nor starts native tracking.
        # Delegate both non-client entry messages to USER32; it emits the same
        # WM_VSCROLL intents handled below, without adding another authority.
        return DefWindowProcW(window, message, wp, lp)
      of WM_VSCROLL:
        if list.handleScrollCode(int(wp and 0xFFFF)): return 0
        return DefSubclassProc(window, message, wp, lp)
      of WM_MOUSEWHEEL:
        let delta = int32(cast[int16](wp shr 16))
        list.handleWheel(delta, int(GetDpiForWindow(window)))
        return 0
      of WM_GETDLGCODE:
        # Claim arrows/Home/End/PageUp/PageDown so the dialog manager and the host
        # pump route them here instead of treating them as dialog navigation.
        # DLGC_WANTALLKEYS is deliberately NOT claimed: Tab must keep moving focus
        # and Enter must keep submitting, which the row editors already handle.
        return DefSubclassProc(window, message, wp, lp) or DLGC_WANTARROWS
      of WM_KEYDOWN:
        # Translate a key to the *same* scroll codes the scrollbar produces, so the
        # viewport keeps exactly one scroll authority (list.handleScrollCode). This
        # only records intent and wakes an ordinary turn; it never lays out, drains
        # or commits here.
        var code = -1
        case wp
        of VK_UP: code = SB_LINEUP
        of VK_DOWN: code = SB_LINEDOWN
        of VK_PRIOR: code = SB_PAGEUP
        of VK_NEXT: code = SB_PAGEDOWN
        of VK_HOME: code = SB_TOP
        of VK_END: code = SB_BOTTOM
        else: discard
        if code >= 0 and list.handleScrollCode(code): return 0
        return DefSubclassProc(window, message, wp, lp)
      of WM_SIZE:
        list.want = true
        list.requestWake()
        return 0
      else: discard
    except CatchableError:
      return 0
  DefSubclassProc(window, message, wp, lp)

proc inputText(entity: MountedEntity): string =
  let text = entity.props.control.value.get("")
  if entity.props.control.multiline.get(false): nativeMultilineText(text) else: text

proc label(entity: MountedEntity): string =
  if entity.kind == NodeKind.input: entity.inputText
  else: entity.props.control.label.get(entity.props.accessibility.label.get(""))
proc value(entity: MountedEntity): ControlValue =
  ControlValue(text: (if entity.kind == NodeKind.input: entity.inputText else: entity.props.control.value.get("")),
    checked: entity.props.control.checked.get(false),
    isCheck: entity.kind in {NodeKind.checkbox, NodeKind.toggle})
proc readText(control: NativeControl): string =
  let length = GetWindowTextLengthW(control.window)
  if length < 0 or length > MaxStringBytes: fail("native editor string budget exceeded")
  let wide = newWideCString(int(length) + 1)
  let read = GetWindowTextW(control.window, cast[WidePtr](unsafeAddr wide[0]), length + 1)
  if read < 0: nativeError("GetWindowTextW")
  result = $wide
  if result.len > MaxStringBytes: fail("native UTF8 editor budget exceeded")
proc selection(control: NativeControl): Selection16 =
  var first, last: DWORD
  discard SendMessageW(control.window, EM_GETSEL, cast[WPARAM](addr first), cast[LPARAM](addr last))
  Selection16(anchor: int(first), caret: int(last))
proc arm(win: Win32Backend, control: NativeControl) =
  inc win.nextBinding
  control.binding = win.nextBinding
  control.armed = win.bound and control.window != nil
proc standardRoleOf(control: NativeControl): Option[UiRole] =
  if control.entity.props.standardUi.isSome:
    some(control.entity.props.standardUi.get.role)
  else:
    none(UiRole)

proc controlWindowOf(win: Win32Backend, handle: NodeHandle): HWND =
  if handle == NoHandle: return nil
  if win.prepared.hasKey(handle): return win.prepared[handle].window
  if win.controls.hasKey(handle): return win.controls[handle].window
  nil

proc entityOf(win: Win32Backend, handle: NodeHandle): MountedEntity =
  if win.candidate.hasKey(handle): return win.candidate.getOrDefault(handle)
  win.current.getOrDefault(handle)

proc overlayRootOf(win: Win32Backend, handle: NodeHandle): NodeHandle =
  ## The nearest enclosing overlay root, including the node itself.
  var current = handle
  var depth = 0
  while current != NoHandle:
    let entity = win.entityOf(current)
    if entity.handle == NoHandle: return NoHandle
    if entity.overlay.isSome: return current
    current = entity.parent
    inc depth
    if depth > MaxDepth: return NoHandle
  NoHandle

proc ensureOverlayHost(win: Win32Backend, entity: MountedEntity): Win32Overlay =
  ## Creates a hidden level when the candidate first needs it. Nothing is shown,
  ## focused or disabled here. The object is published into the backend table
  ## *before* the first native step, so a failure anywhere leaves a retryable
  ## owner in this exact table instead of an unreachable half-created level.
  if win.overlays.hasKey(entity.handle): return win.overlays[entity.handle]
  if entity.overlay.isNone: fail("overlay host requires an overlay description")
  var owner = win.host.windowHandle
  if entity.parent != NoHandle:
    let parent = win.controlWindowOf(entity.parent)
    if parent != nil: owner = parent
  let props = entity.overlay.get
  let overlay = newOverlay(win.calls, owner, win.host.windowHandle,
    entity.props.control.label.get(""), win.theme, props.kind == overlayDialog)
  win.overlays[entity.handle] = overlay
  if entity.handle notin win.preparedOverlays: win.preparedOverlays.add(entity.handle)
  inc win.stats.liveOverlays
  try:
    overlay.openWindows()
  except CatchableError as error:
    # Keep the receipt: discardPrepared/closeWindows will retry and report the
    # remaining owned steps instead of pretending the level does not exist.
    error.msg.add("; overlay level kept for retry")
    raise error
  overlay

proc childrenOf(win: Win32Backend, parent: NodeHandle): seq[MountedEntity] =
  for handle, entity in win.current:
    if entity.parent == parent: result.add(entity)
  result.sort(proc(a, b: MountedEntity): int = cmp(a.index, b.index))

proc subtreeControls(win: Win32Backend, root: NodeHandle,
                     includeRoot: bool): seq[NativeControl] =
  ## Depth-first tab order: parent before children, siblings by index. Only
  ## accepted, live controls are returned.
  var found: seq[NativeControl]
  proc visit(handle: NodeHandle) =
    if win.controls.hasKey(handle):
      found.add(win.controls[handle])
    let entity = win.current.getOrDefault(handle)
    if entity.handle == NoHandle: return
    for child in win.childrenOf(handle):
      visit(child.handle)
  if root == NoHandle: return
  if includeRoot: visit(root)
  else:
    let entity = win.current.getOrDefault(root)
    if entity.handle == NoHandle: return
    for child in win.childrenOf(root):
      visit(child.handle)
  result = found

proc focusableControl(entity: MountedEntity): bool =
  if entity.kind notin {NodeKind.button, NodeKind.input, NodeKind.checkbox,
      NodeKind.toggle, NodeKind.virtualList}: return false
  if entity.props.control.enabled.isSome and not entity.props.control.enabled.get:
    return false
  true

proc usableFocus(control: NativeControl): bool =
  control != nil and control.window != nil and focusableControl(control.entity) and
    IsWindowVisible(control.window) != 0 and IsWindowEnabled(control.window) != 0

proc firstFocusable(win: Win32Backend, root: NodeHandle,
                    includeRoot: bool): HWND =
  for control in win.subtreeControls(root, includeRoot):
    if usableFocus(control): return control.window
  nil

proc contentRootOf(win: Win32Backend, root: NodeHandle): NodeHandle =
  for control in win.subtreeControls(root, false):
    let role = standardRoleOf(control)
    if role.isSome and role.get == UiRole.dialogContent: return control.handle
  NoHandle

proc cancelControlOf(win: Win32Backend, root: NodeHandle): HWND =
  for control in win.subtreeControls(root, false):
    let role = standardRoleOf(control)
    if role.isSome and role.get == UiRole.alertDialogCancel and usableFocus(control):
      return control.window
  nil

proc planInitialFocus(win: Win32Backend, root: NodeHandle): HWND =
  ## Role-driven policy from the shared contract: the AlertDialog cancel
  ## control, else the first focusable control of the content region, else the
  ## modal surface itself (a legal target even for an empty dialog).
  let entity = win.current.getOrDefault(root)
  if entity.handle == NoHandle or entity.overlay.isNone: return nil
  let props = entity.overlay.get
  let cancel = win.cancelControlOf(root)
  let content = win.contentRootOf(root)
  var first: HWND
  if content != NoHandle: first = win.firstFocusable(content, false)
  if first == nil: first = win.firstFocusable(root, false)
  case chooseInitialFocus(props, cancel != nil, first != nil)
  of "cancel": cancel
  of "first": first
  else:
    let control = win.controls.getOrDefault(root)
    if control != nil: control.window else: nil

proc overlayOpenOrder(win: Win32Backend, source: Table[NodeHandle, MountedEntity]):
    seq[NodeHandle] =
  ## Page order (depth first, siblings by index) of every overlay root.
  var root = NoHandle
  for handle, entity in source:
    if entity.parent == NoHandle: root = handle
  if root == NoHandle: return

  var found: seq[NodeHandle]
  proc visit(handle: NodeHandle) =
    let entity = source.getOrDefault(handle)
    if entity.handle == NoHandle: return
    if entity.overlay.isSome: found.add(handle)
    var children: seq[MountedEntity]
    for candidate in source.values:
      if candidate.parent == handle: children.add(candidate)
    children.sort(proc(a, b: MountedEntity): int = cmp(a.index, b.index))
    for child in children: visit(child.handle)
  visit(root)
  result = found

proc acceptedOverlayTop(win: Win32Backend): NodeHandle =
  ## Topmost *accepted* level, independent of whether the OS publish step has
  ## run yet, so input gating is already correct in the same turn.
  for handle in win.overlayOpenOrder(win.current):
    let entity = win.current.getOrDefault(handle)
    if entity.overlay.isSome and entity.overlay.get.open: result = handle

proc modalAllows(win: Win32Backend, handle: NodeHandle): bool =
  ## Input gate for every source (native messages and UIA patterns alike):
  ## while a modal level is accepted-open, only controls inside the topmost
  ## level may produce events. Background controls never reach the business
  ## layer, even before the publish step has disabled their owner.
  let top = win.acceptedOverlayTop()
  if top == NoHandle: return true
  win.overlayRootOf(handle) == top

proc overlayWorkArea(win: Win32Backend): tuple[width, height: float64, known: bool] =
  ## Work area of the monitor owning the host window, in DIP.
  monitorWorkArea(win.calls, win.host.windowHandle)

proc queueDismiss(win: Win32Backend, root: NodeHandle, source: OverlayDismiss) =
  ## One typed close request for an accepted overlay level. The native callback
  ## only records it here; the business handler runs in the ordinary turn.
  let control = win.controls.getOrDefault(root)
  if control == nil or control.window == nil or not control.armed: return
  if win.session == nil or win.session.closing or win.session.disposed or
      win.session.faulted: return
  let entity = control.entity
  if entity.overlay.isNone: return
  if not win.modalAllows(root): return
  if not dismissAllowed(entity.overlay.get, source): return
  if win.sequence >= high(uint64) - 1: fail("native event sequence exhausted")
  inc win.sequence
  inc win.stats.overlayDismissRequests
  discard win.session.enqueue(EventEnvelope(session: win.sessionId,
    mountGeneration: win.generation, bindingGeneration: control.binding,
    handle: entity.handle, sequence: win.sequence, observedRevision: win.revision,
    event: Event(kind: dismiss), source: sourceUser))
  discard PostMessageW(win.host.windowHandle, WM_HOST_TICK, 0, 0)

# --- anchored single-select popups -----------------------------------------
# The popup is created, positioned, shown and destroyed only in an ordinary
# turn. Window callbacks record one typed request; the accepted props decide
# what is really shown, so a rejected or ignored request never drifts.

proc selectRootOf(win: Win32Backend, handle: NodeHandle): NodeHandle =
  ## The nearest enclosing select root, including the node itself.
  var current = handle
  var depth = 0
  while current != NoHandle:
    let entity = win.entityOf(current)
    if entity.handle == NoHandle: return NoHandle
    if entity.select.isSome: return current
    current = entity.parent
    inc depth
    if depth > MaxDepth: return NoHandle
  NoHandle

proc selectTriggerControl(win: Win32Backend, root: NodeHandle): NativeControl =
  for child in win.childrenOf(root):
    let control = win.controls.getOrDefault(child.handle)
    if control == nil: continue
    let role = standardRoleOf(control)
    if role.isSome and role.get == UiRole.selectTrigger: return control
  nil

proc selectPopupOwner(win: Win32Backend, trigger: NativeControl): HWND =
  ## Strict non-topmost ownership: the popup is owned by the trigger's top-level
  ## window, so a select inside a dialog stays above that dialog and a page-level
  ## select stays above the page. No WS_EX_TOPMOST anywhere.
  if trigger == nil or trigger.window == nil: return nil
  let top = GetAncestor(trigger.window, 2'u32) # GA_ROOT
  if top != nil: top else: win.host.windowHandle

proc queueSelectEvent(win: Win32Backend, root: NodeHandle, event: Event) =
  ## One typed request for an accepted select root. The native callback only
  ## records it; the business handler runs in the ordinary turn.
  let control = win.controls.getOrDefault(root)
  if control == nil or control.window == nil or not control.armed: return
  if win.session == nil or win.session.closing or win.session.disposed or
      win.session.faulted: return
  if not win.modalAllows(root):
    inc win.stats.selectGateDrops
    return
  if win.sequence >= high(uint64) - 1: fail("native event sequence exhausted")
  inc win.sequence
  inc win.stats.selectRequests
  discard win.session.enqueue(EventEnvelope(session: win.sessionId,
    mountGeneration: win.generation, bindingGeneration: control.binding,
    handle: root, sequence: win.sequence, observedRevision: win.revision,
    event: event, source: sourceUser))
  discard PostMessageW(win.host.windowHandle, WM_HOST_TICK, 0, 0)

proc requestSelectState(win: Win32Backend, root: NodeHandle, want: bool) =
  ## One typed open/close request for exactly this wanted state. A disabled or
  ## hidden trigger cannot ask for anything, and an empty/all-disabled list
  ## cannot ask to open; such a request is dropped, never coerced.
  let entity = win.entityOf(root)
  if entity.handle == NoHandle or entity.select.isNone: return
  let props = entity.select.get
  let trigger = win.selectTriggerControl(root)
  if trigger == nil or trigger.window == nil: return
  if IsWindowEnabled(trigger.window) == 0 or IsWindowVisible(trigger.window) == 0:
    return
  if want and not openRequestAllowed(props): return
  win.queueSelectEvent(root, Event(kind: openChange, open: want))

proc requestSelectOpen(win: Win32Backend, root: NodeHandle) =
  ## Trigger activation asks for the opposite of the accepted state.
  let entity = win.entityOf(root)
  if entity.handle == NoHandle or entity.select.isNone: return
  win.requestSelectState(root, not entity.select.get.open)

proc moveSelectFocus(win: Win32Backend, trigger: NativeControl, direction: int) =
  ## Tab after closing moves inside the accepted focus domain only: the enclosing
  ## modal level when the select lives in a dialog, else the whole page. The
  ## order is the backend's own depth-first control order, so a select never
  ## invents a second focus loop and never leaves the dialog scope.
  if trigger == nil or trigger.window == nil: return
  if direction == 0:
    if IsWindowVisible(trigger.window) != 0 and
        IsWindowEnabled(trigger.window) != 0:
      discard SetFocus(trigger.window)
    return
  let domain = win.overlayRootOf(trigger.entity.handle)
  var pageRoot = NoHandle
  for handle, entity in win.current:
    if entity.parent == NoHandle:
      pageRoot = handle
      break
  let orderRoot = if domain != NoHandle: domain else: pageRoot
  if orderRoot == NoHandle: return
  var candidates: seq[NativeControl]
  for control in win.subtreeControls(orderRoot, true):
    if usableFocus(control): candidates.add(control)
  if candidates.len == 0:
    discard SetFocus(trigger.window)
    return
  var index = -1
  for position, control in candidates:
    if control.window == trigger.window:
      index = position
      break
  let target = if index < 0:
      (if direction > 0: candidates[0] else: candidates[^1])
    else:
      candidates[(index + direction + candidates.len) mod candidates.len]
  if target.window != nil: discard SetFocus(target.window)

proc ensureSelectHost(win: Win32Backend, root: NodeHandle): Win32Select =
  ## Creates a hidden popup the first time an accepted select needs it. Nothing is
  ## shown, positioned or focused here; the caller publishes in this same turn.
  if win.selects.hasKey(root): return win.selects[root]
  let entity = win.entityOf(root)
  if entity.handle == NoHandle or entity.select.isNone: return nil
  let trigger = win.selectTriggerControl(root)
  if trigger == nil: return nil
  let owner = win.selectPopupOwner(trigger)
  if owner == nil: return nil
  let host = newSelect(win.calls, owner, win.host.windowHandle, trigger.window,
    win.theme, entity.select.get, win.selectContext)
  win.selects[root] = host
  inc win.stats.liveSelects
  try:
    host.openWindows()
  except CatchableError as error:
    error.msg.add("; select popup kept for retry")
    raise error
  host

proc dropSelectHost(win: Win32Backend, root: NodeHandle) =
  ## Resource-safe teardown: the table entry and the live counter are released
  ## only after the native window and class really went away.
  let host = win.selects.getOrDefault(root)
  if host == nil: return
  try:
    if host.isVisible: host.hidePopup()
  except CatchableError: discard
  let failure = host.closeWindows()
  if failure != nil: raise failure
  win.selects.del(root)
  win.selectRects.del(root)
  dec win.stats.liveSelects

proc selectPixels(win: Win32Backend, host: Win32Select, props: SelectProps):
    tuple[x, y, width, height: int32] =
  ## Pure anchoring from the trigger's real rectangle and the monitor work area:
  ## below when it fits, flipped above when it does not, clamped on both axes.
  var frame: RECT
  if win.calls.windowRect(host.triggerWindow, addr frame) == 0:
    nativeError("GetWindowRect select trigger")
  let dpi = win.calls.dpi(host.triggerWindow)
  if dpi == 0: nativeError("GetDpiForWindow select trigger")
  let scale = float64(dpi) / 96.0
  host.setScale(scale)
  var work = workArea(win.calls, host.triggerWindow)
  if not work.known: work = workArea(win.calls, win.host.windowHandle)
  if not work.known:
    fail("select popup requires a known monitor work area")
  let placement = planSelectPlacement(float64(frame.left) / scale,
    float64(frame.top) / scale, float64(frame.right - frame.left) / scale,
    float64(frame.bottom - frame.top) / scale,
    max(MinSelectItemHeight, host.rowHeightOf), props.options.len,
    work.x, work.y, work.width, work.height)
  host.planPlacement(placement)
  (int32(round(placement.x * scale)), int32(round(placement.y * scale)),
   max(1'i32, int32(round(placement.width * scale))),
   max(1'i32, int32(round(placement.height * scale))))

proc hideSelect(win: Win32Backend, root: NodeHandle, host: Win32Select,
                restore: bool) =
  let trigger = win.selectTriggerControl(root)
  let hadFocus = host.focusInside()
  host.hidePopup()
  let tab = host.takeTab()
  if tab != 0:
    # Tab always moves in the owner focus domain, independent of whether the
    # popup still held focus when it was hidden.
    win.moveSelectFocus(trigger, tab)
  elif restore and hadFocus:
    win.moveSelectFocus(trigger, 0)

proc selectTurn(win: Win32Backend) =
  ## Ordinary-turn select work: drop retired hosts, create what the accepted
  ## state needs, publish open state and geometry, then consume at most one
  ## recorded request per root. Never called from a window callback.
  if win.session == nil: return
  var stale: seq[NodeHandle]
  for root in win.selects.keys:
    let entity = win.current.getOrDefault(root)
    if entity.handle == NoHandle or entity.select.isNone: stale.add(root)
  for root in stale: win.dropSelectHost(root)
  var roots: seq[NodeHandle]
  for handle, entity in win.current:
    if entity.select.isSome: roots.add(handle)
  roots.sort(proc(a, b: NodeHandle): int = cmp(uint64(a), uint64(b)))
  var index = 0
  while index < roots.len:
    let root = roots[index]
    inc index
    let entity = win.current.getOrDefault(root)
    if entity.handle == NoHandle or entity.select.isNone: continue
    let props = entity.select.get
    # The trigger element provider exists while the accepted select root does;
    # the popup window and its List element exist only while it is open.
    let host = win.ensureSelectHost(root)
    when defined(leafProtocolProbes):
      if win.popovers.len != 0:
        let probeTrigger = win.selectTriggerControl(root)
        echo "SELTURN root=", uint64(root), " open=", props.open,
          " host=", host != nil,
          " trigger=", (if probeTrigger == nil: 0'u64 else: uint64(cast[uint](probeTrigger.window))),
          " trigVis=", (if probeTrigger == nil: 0 else: IsWindowVisible(probeTrigger.window)),
          " trigEnabled=", (if probeTrigger == nil: 0 else: IsWindowEnabled(probeTrigger.window)),
          " panel=", (if win.popovers.hasKey(root): uint64(cast[uint](win.popovers[root].panelHandle)) else: 0'u64),
          " panelVis=", (if win.popovers.hasKey(root): IsWindowVisible(win.popovers[root].panelHandle) else: 0)
    if host == nil: continue
    if host.popupWindowDead:
      # A destroyed owner leaves a dead popup handle: retire the receipts so the
      # next accepted open recreates a real window instead of failing.
      let failure = host.closePopupWindow()
      if failure != nil: raise failure
      win.selectRects.del(root)
    let trigger = win.selectTriggerControl(root)
    if trigger == nil or trigger.window == nil: continue
    host.setTheme(win.theme)
    # Ordinary-turn reclamation: snapshots for both provider elements and the
    # retired provider objects of this context (the last reader only wakes us).
    host.reclaimSnapshots()
    win.selectContext.drainRetired()
    if host.triggerWindow != trigger.window:
      # The trigger was recreated; the popup follows the accepted window.
      host.triggerWindow = trigger.window
      win.selectRects.del(root)
    if host.props.options != props.options or host.props.value != props.value or
        host.props.label != props.label or
        host.props.placeholder != props.placeholder:
      host.applyProps(props, win.theme)
    if props.open and IsWindowVisible(trigger.window) == 0 and host.isVisible:
      # Owner minimized or hidden: drop the popup without moving focus.
      host.hidePopup()
      discard host.closePopupWindow()
      win.selectRects.del(root)
    if props.open and IsWindowVisible(trigger.window) != 0:
      if not host.isVisible:
        when defined(leafProtocolProbes):
          if win.popovers.len != 0: echo "SELSHOW root=", uint64(root), " reason=first"
        host.resetCandidate()
        let px = win.selectPixels(host, props)
        host.showPopup(px.x, px.y, px.width, px.height, true)
        win.selectRects[root] = px
        inc win.stats.selectShows
      else:
        let before = win.selectRects.getOrDefault(root)
        let px = win.selectPixels(host, props)
        if px != before:
          host.placePopup(px.x, px.y, px.width, px.height)
          win.selectRects[root] = px
          inc win.stats.selectRepositions
    elif host.isVisible:
      when defined(leafProtocolProbes):
        if win.popovers.len != 0:
          echo "SELHIDE root=", uint64(root), " open=", props.open,
            " trigVis=", IsWindowVisible(trigger.window)
      win.hideSelect(root, host, true)
    if not props.open and host.popupProvider != nil:
      # Publish the final accepted snapshot (now invisible, with the newly
      # accepted selection) before the popup element retires, so an accepted
      # selection still raises its Selection/SelectionItem events.
      var finalItems: seq[SelectItemState]
      for option in props.options:
        finalItems.add(SelectItemState(label: option.label, disabled: option.disabled))
      host.publishState(props.open,
        IsWindowEnabled(trigger.window) != 0 and win.modalAllows(root),
        accessibleName(props),
        (if props.value.len != 0: displayLabel(props) else: ""),
        (if props.label.len == 0: props.placeholder else: props.label),
        finalItems, props.selectedIndex, host.firstRow, max(1, host.rows),
        int(round(host.rowHeightOf)))
    when defined(leafProtocolProbes):
      if win.popovers.len != 0:
        echo "SELPOST root=", uint64(root), " open=", props.open,
          " hostVis=", host.isVisible,
          " popup=", (if host.popupHandle == nil: 0'u64 else: uint64(cast[uint](host.popupHandle))),
          " popupVis=", (if host.popupHandle == nil: 0 else: IsWindowVisible(host.popupHandle)),
          " shows=", win.stats.selectShows, " closes=", win.stats.selectCloses
    if not props.open:
      # A closed select releases its popup window and List element instead of
      # keeping a hidden window; its trigger element stays live.
      let failure = host.closePopupWindow()
      if failure != nil: raise failure
      win.selectRects.del(root)
    # A request belongs to the element the user operated; another select must
    # never consume it just because it shares this turn's context.
    let request = win.selectContext.takeRequest(trigger.window,
      (if host.popupProvider != nil: host.popupHandle else: nil))
    if request.kind != 0:
      # A request recorded against an older published generation is dropped
      # instead of selecting whatever now occupies that slot.
      var fresh = request.generation == host.provider.generation
      if host.popupProvider != nil and
          request.generation == host.popupProvider.generation:
        fresh = true
      if fresh:
        case request.kind
        of 1: win.requestSelectState(root, true)   # Expand
        of 2: win.requestSelectState(root, false)  # Collapse
        of 3:                                      # SelectionItem.Select
          let chosen = candidateValue(props, request.index)
          if chosen.len != 0:
            inc win.stats.selectCommits
            win.queueSelectEvent(root, Event(kind: change, value: chosen))
            win.queueSelectEvent(root, Event(kind: openChange, open: false))
        of 4: host.focusCandidate(request.index)   # legal focus request
        else: discard
    # Publish after the request: the request was recorded against the
    # generation the user saw, and this publish may advance it.
    # Publish the accepted semantics for the trigger and popup elements, then
    # consume at most one bounded UIA request (expand/collapse/select/focus).
    var items: seq[SelectItemState]
    for option in props.options:
      items.add(SelectItemState(label: option.label, disabled: option.disabled))
    # The modal gate is part of the exposed enabled state: a page control under
    # an accepted modal level reports IsEnabled=false even though USER32 keeps
    # the child window's own WS_DISABLED bit clear.
    host.publishState(props.open,
      IsWindowEnabled(trigger.window) != 0 and win.modalAllows(root),
      accessibleName(props),
      (if props.value.len != 0: displayLabel(props) else: ""),
      (if props.label.len == 0: props.placeholder else: props.label),
      items, props.selectedIndex, host.firstRow, max(1, host.rows),
      int(round(host.rowHeightOf)))
    var notice: SelectNotice
    if host.takeNotice(notice):
      case notice.kind
      of snCommit:
        let value = noticeValue(props, notice)
        if value.len != 0:
          inc win.stats.selectCommits
          # Two distinct typed requests: the accepted value and the accepted open
          # state. Each one is individually rejectable by the caller.
          win.queueSelectEvent(root, Event(kind: change, value: value))
          win.queueSelectEvent(root, Event(kind: openChange, open: false))
      of snClose:
        inc win.stats.selectCloses
        win.queueSelectEvent(root, Event(kind: openChange, open: false))
      of snOpen:
        win.queueSelectEvent(root, Event(kind: openChange, open: true))
      else: discard
  # A request that no accepted select root claimed is stale (its element was
  # retired); dropping it keeps the single slot available for real input.
  win.selectContext.clearRequest()

proc disposeSelects(win: Win32Backend) =
  var roots: seq[NodeHandle]
  for root in win.selects.keys: roots.add(root)
  var first: ref CatchableError
  for root in roots:
    try: win.dropSelectHost(root)
    except CatchableError as error:
      if first == nil: first = error
      else: first.msg.add("; select cleanup: " & error.msg)
  win.selectRects.clear()
  if first != nil: raise first

# Geometry helpers that are implemented after this section.
proc measureControl*(win: Win32Backend, entity: MountedEntity,
                     available: DipSize): DipSize
proc placeOverlayBoxes(win: Win32Backend, root: NodeHandle,
                       boxes: seq[LayoutBox], dpi: int,
                       source = "placeLevel")

proc popoverBody(win: Win32Backend, handle: NodeHandle): bool

# --- non-modal popovers -----------------------------------------------------
# The panel is a real owned window of the trigger's top-level window: the owner
# stays enabled, nothing is globally topmost, and only an ordinary turn shows,
# places, focuses or hides it. Every dismissal is one recorded typed request.

proc popoverRootOf(win: Win32Backend, handle: NodeHandle): NodeHandle =
  ## The nearest enclosing popover root, including the node itself.
  var current = handle
  var depth = 0
  while current != NoHandle:
    let entity = win.entityOf(current)
    if entity.handle == NoHandle: return NoHandle
    if entity.popover.isSome: return current
    current = entity.parent
    inc depth
    if depth > MaxDepth: return NoHandle
  NoHandle

proc popoverChildControl(win: Win32Backend, root: NodeHandle,
                         role: UiRole): NativeControl =
  ## Works in prepare as well as in a published turn: children come from the
  ## merged candidate view and their windows from prepared or controls.
  template scan(entities: untyped) =
    for handle, entity in entities:
      if entity.parent != root: continue
      let control = if win.controls.hasKey(handle):
          win.controls[handle] else: win.prepared.getOrDefault(handle)
      if control == nil: continue
      let found = standardRoleOf(control)
      if found.isSome and found.get == role: return control
  scan(win.candidate)
  scan(win.current)
  nil

proc popoverTriggerControl(win: Win32Backend, root: NodeHandle): NativeControl =
  win.popoverChildControl(root, UiRole.popoverTrigger)

proc popoverContentControl(win: Win32Backend, root: NodeHandle): NativeControl =
  win.popoverChildControl(root, UiRole.popoverContent)

proc popoverPanelOwner(win: Win32Backend, trigger: NativeControl): HWND =
  ## Strict non-topmost ownership: the panel is owned by the trigger's top-level
  ## window, so a popover inside a dialog stays above that dialog only.
  if trigger == nil or trigger.window == nil: return nil
  let top = GetAncestor(trigger.window, 2'u32) # GA_ROOT
  if top != nil: top else: win.host.windowHandle

proc queuePopoverEvent(win: Win32Backend, root: NodeHandle, event: Event) =
  let control = win.controls.getOrDefault(root)
  if control == nil or control.window == nil or not control.armed: return
  if win.session == nil or win.session.closing or win.session.disposed or
      win.session.faulted: return
  if not win.modalAllows(root):
    inc win.stats.popoverGateDrops
    return
  if win.sequence >= high(uint64) - 1: fail("native event sequence exhausted")
  inc win.sequence
  inc win.stats.popoverRequests
  discard win.session.enqueue(EventEnvelope(session: win.sessionId,
    mountGeneration: win.generation, bindingGeneration: control.binding,
    handle: root, sequence: win.sequence, observedRevision: win.revision,
    event: event, source: sourceUser))
  discard PostMessageW(win.host.windowHandle, WM_HOST_TICK, 0, 0)

proc requestPopoverState(win: Win32Backend, root: NodeHandle, want: bool,
                          source = "unspecified") =
  let entity = win.entityOf(root)
  if entity.handle == NoHandle or entity.popover.isNone: return
  let props = entity.popover.get
  if want:
    let trigger = win.popoverTriggerControl(root)
    if trigger == nil or trigger.window == nil: return
    if IsWindowEnabled(trigger.window) == 0 or IsWindowVisible(trigger.window) == 0:
      return
    let content = win.popoverContentControl(root)
    if content == nil: return
  if props.open == want: return
  when defined(leafProtocolProbes):
    echo "POPREQ root=", uint64(root), " want=", want, " source=", source
  win.queuePopoverEvent(root, Event(kind: openChange, open: want))

proc popoverPointerButton(win: Win32Backend, target: HWND) =
  ## A real button press outside every visible panel's owned scope asks once for
  ## that panel to close. Clicks inside the panel, its children or an owned popup
  ## (an inner select) are internal and never produce a request.
  if win.popovers.len == 0 or target == nil: return
  for root in win.popovers.keys:
    let host = win.popovers[root]
    if not host.isVisible: continue
    if host.isWithinPanel(target): continue
    win.requestPopoverState(root, false)

proc requestPopoverToggle(win: Win32Backend, root: NodeHandle) =
  let entity = win.entityOf(root)
  if entity.handle == NoHandle or entity.popover.isNone: return
  win.requestPopoverState(root, not entity.popover.get.open)

proc popoverOwnerOfRoot(win: Win32Backend, root: NodeHandle): HWND =
  ## The owning window for a panel whose trigger window is not available yet
  ## (a panel body inside a modal surface is prepared as part of that group).
  var current: NodeHandle = win.entityOf(root).parent
  var depth = 0
  while current != NoHandle and depth <= MaxDepth:
    let entity = win.entityOf(current)
    if entity.handle == NoHandle: break
    if entity.overlay.isSome and win.overlays.hasKey(current):
      return win.overlays[current].surfaceHandle
    current = entity.parent
    inc depth
  win.host.windowHandle

proc ensurePopoverHost(win: Win32Backend, root: NodeHandle): Win32Popover =
  ## Creates a hidden panel the first time an accepted popover needs one.
  if win.popovers.hasKey(root): return win.popovers[root]
  let entity = win.entityOf(root)
  if entity.handle == NoHandle or entity.popover.isNone: return nil
  let trigger = win.popoverTriggerControl(root)
  var owner: HWND
  if trigger != nil and trigger.window != nil:
    owner = win.popoverPanelOwner(trigger)
  else:
    # Prepare may create the body before the trigger control is reachable; the
    # owner then comes from the enclosing modal surface or the page window.
    owner = win.popoverOwnerOfRoot(root)
  if owner == nil: return nil
  let host = newPopover(win.calls, owner, win.host.windowHandle,
    (if trigger != nil: trigger.window else: nil), win.theme, entity.popover.get)
  win.popovers[root] = host
  inc win.stats.livePopovers
  try:
    host.openWindows()
  except CatchableError as error:
    error.msg.add("; popover panel kept for retry")
    raise error
  host

proc dropPopoverHost(win: Win32Backend, root: NodeHandle) =
  when defined(leafProtocolProbes):
    echo "DROPHOST root=", uint64(root)
  let host = win.popovers.getOrDefault(root)
  if host == nil: return
  try:
    if host.isVisible: host.hide()
  except CatchableError: discard
  let failure = host.closeWindows()
  if failure != nil: raise failure
  win.popovers.del(root)
  win.popoverRects.del(root)
  dec win.stats.livePopovers

proc popoverContentParent(win: Win32Backend, entity: MountedEntity): HWND =
  ## A panel body must have a real panel window: a structural miss fails the
  ## prepare instead of silently falling back to the page.
  let root = win.popoverRootOf(entity.handle)
  if root == NoHandle:
    fail("popover content has no enclosing popover root: " & entity.nodeId)
  let host = win.ensurePopoverHost(root)
  if host == nil:
    fail("popover panel window is unavailable: " & entity.nodeId)
  host.panelHandle

proc popoverFocusables(win: Win32Backend, content: NativeControl): seq[NativeControl] =
  ## The panel's own focus order: depth-first over the accepted content subtree
  ## only, so Tab never leaves the panel except at a boundary request.
  if content == nil: return
  for control in win.subtreeControls(content.entity.handle, true):
    if usableFocus(control): result.add(control)

proc popoverPixels(win: Win32Backend, host: Win32Popover, content: NativeControl,
                   props: PopoverProps): tuple[x, y, width, height: int32,
    widthDip, heightDip: float64] =
  ## Measure the panel body, then anchor it from the trigger's real rectangle and
  ## the monitor work area. A body that cannot fit raises before any publish.
  var frame: RECT
  if win.calls.windowRect(host.triggerWindow, addr frame) == 0:
    nativeError("GetWindowRect popover trigger")
  let dpi = win.calls.dpi(host.triggerWindow)
  if dpi == 0: nativeError("GetDpiForWindow popover trigger")
  let scale = float64(dpi) / 96.0
  host.scale = scale
  var work = workArea(win.calls, host.triggerWindow)
  if not work.known: work = workArea(win.calls, win.host.windowHandle)
  if not work.known: fail("popover panel requires a known monitor work area")
  let widthDip = props.popoverWidth
  let available = DipSize(width: widthDip,
    height: max(1.0, work.height - 2.0 * PopoverMargin))
  let natural = measureSubtree(win.current, content.entity.handle, available,
    proc(entity: MountedEntity, available: DipSize): DipSize =
      win.measureControl(entity, available))
  if natural.height < 1.0: fail("popover panel measured an empty body")
  let placement = planPopoverPlacement(
    float64(frame.left) / scale, float64(frame.top) / scale,
    float64(frame.right - frame.left) / scale,
    float64(frame.bottom - frame.top) / scale,
    widthDip, natural.height, work.x, work.y, work.width, work.height,
    props.side, props.align, props.popoverOffset)
  (int32(round(placement.x * scale)), int32(round(placement.y * scale)),
   max(1'i32, int32(round(placement.width * scale))),
   max(1'i32, int32(round(placement.height * scale))),
   placement.width, placement.height)

proc layoutPopoverContent(win: Win32Backend, content: NativeControl,
                          widthDip, heightDip: float64, dpi: int) =
  ## Lay out only the panel body inside the panel's client area. Parent-relative
  ## placement makes the content root start at the client origin.
  let rect = DipRect(x: 0, y: 0, width: widthDip, height: heightDip)
  let boxes = layoutSubtree(win.current, content.entity.handle, rect, rect,
    proc(entity: MountedEntity, available: DipSize): DipSize =
      win.measureControl(entity, available))
  win.placeOverlayBoxes(content.entity.handle, boxes, dpi, "popoverBody")

proc popoverTabFrom(win: Win32Backend, root: NodeHandle): bool =
  ## Tab pressed on a real control inside the panel body: walk the panel's own
  ## order. At a boundary the direction is kept pending and only a typed close
  ## request is sent: focus moves after the caller accepts, never before.
  let content = win.popoverContentControl(root)
  if content == nil: return false
  let candidates = win.popoverFocusables(content)
  if candidates.len == 0: return false
  let current = GetFocus()
  let shift = (GetKeyState(0x10) and 0x8000) != 0
  var index = -1
  for position, control in candidates:
    if control.window == current: index = position
  if index < 0: return false
  let next = index + (if shift: -1 else: 1)
  if next >= 0 and next < candidates.len:
    discard SetFocus(candidates[next].window)
    return true
  let host = win.popovers.getOrDefault(root)
  if host != nil:
    host.pendingTab = (if shift: -1 else: 1)
    # The request below is this input's one request: mark it so the next turn
    # does not send a duplicate for the same pending boundary.
    host.requestPending = true
  win.requestPopoverState(root, false, "body-tab-boundary")
  true

proc popoverContentOwner(win: Win32Backend, handle: NodeHandle): NodeHandle =
  ## The nearest enclosing panel body of a control.
  var current = handle
  var depth = 0
  while current != NoHandle and depth <= MaxDepth:
    let entity = win.entityOf(current)
    if entity.handle == NoHandle: return NoHandle
    if entity.props.standardUi.isSome and
        entity.props.standardUi.get.role == UiRole.popoverContent:
      return current
    current = entity.parent
    inc depth
  NoHandle

proc openSelectPopupIn(win: Win32Backend, body: NodeHandle): HWND =
  ## Innermost real select scope that is accepted open and published. Keyboard
  ## cancel belongs to it first, whatever window happens to hold focus.
  if body == NoHandle: return nil
  for handle, entity in win.current:
    if entity.select.isNone: continue
    if win.popoverContentOwner(handle) != body: continue
    if not win.modalAllows(handle): continue
    let host = win.selects.getOrDefault(handle)
    if host != nil and host.isVisible and host.popupHandle != nil:
      return host.popupHandle
  nil

proc popoverKeyFrom(win: Win32Backend, control: NativeControl, key: int32): bool =
  ## Esc/Tab from a child of a panel body belong to that popover: the panel
  ## window itself only sees keys when it holds focus, so a focused EDIT/BUTTON
  ## inside the body must forward the same typed requests.
  if control == nil or control.entity.handle == NoHandle: return false
  if not win.popoverBody(control.entity.handle): return false
  let root = win.popoverRootOf(control.entity.handle)
  if root == NoHandle: return false
  # Innermost real scope first: a published select popup inside this body owns
  # the cancel. If the caller ignores that request the key must not bubble up and
  # close the panel, so this path always consumes it.
  let body = win.popoverContentOwner(control.entity.handle)
  let inner = win.openSelectPopupIn(body)
  case key
  of 0x1B: # VK_ESCAPE
    if inner != nil:
      # Same channel the popup already handles: its own Esc records one typed
      # close request; nothing here rewrites accepted state.
      discard PostMessageW(inner, 0x0100'u32, WPARAM(0x1B), 0)
      return true
    win.requestPopoverState(root, false)
    true
  of 0x09: # VK_TAB
    # While an inner select is open it owns Tab traversal and its own boundary.
    if inner != nil: return false
    win.popoverTabFrom(root)
  else: false

proc movePopoverFocus(win: Win32Backend, root: NodeHandle, content: NativeControl,
                      trigger: NativeControl, direction: int, fromContent: bool) =
  ## Tab inside the panel walks the panel's own controls; at the boundary it
  ## requests close and moves in the owner's focus domain (never a second loop).
  if direction == 0:
    if trigger != nil and trigger.window != nil and
        IsWindowVisible(trigger.window) != 0 and IsWindowEnabled(trigger.window) != 0:
      discard SetFocus(trigger.window)
    return
  if fromContent:
    let candidates = win.popoverFocusables(content)
    if candidates.len > 0:
      let current = GetFocus()
      var index = -1
      for position, control in candidates:
        if control.window == current: index = position
      if index >= 0:
        let target = index + direction
        if target >= 0 and target < candidates.len:
          discard SetFocus(candidates[target].window)
          return
  if trigger != nil and trigger.window != nil:
    win.moveSelectFocus(trigger, direction)

proc popoverTurn(win: Win32Backend) =
  ## Ordinary-turn panel work. Recorded user intent is delivered first (one
  ## request per input, regardless of temporary owner visibility), then the
  ## accepted state decides show/hide, then pending tab direction is consumed.
  if win.session == nil: return
  var stale: seq[NodeHandle]
  for root in win.popovers.keys:
    let entity = win.current.getOrDefault(root)
    if entity.handle == NoHandle or entity.popover.isNone: stale.add(root)
  for root in stale: win.dropPopoverHost(root)
  var roots: seq[NodeHandle]
  for handle, entity in win.current:
    if entity.popover.isSome: roots.add(handle)
  roots.sort(proc(a, b: NodeHandle): int = cmp(uint64(a), uint64(b)))
  for root in roots:
    let entity = win.current.getOrDefault(root)
    if entity.handle == NoHandle or entity.popover.isNone: continue
    let props = entity.popover.get
    let trigger = win.popoverTriggerControl(root)
    let content = win.popoverContentControl(root)
    if trigger == nil or trigger.window == nil or content == nil: continue
    let host = win.ensurePopoverHost(root)
    if host == nil: continue
    if host.panelDead:
      let failure = host.closePanelWindow()
      if failure != nil: raise failure
      win.popoverRects.del(root)
    host.setTheme(win.theme)
    if host.triggerWindow != trigger.window:
      # The trigger is only the anchor: with the same owning top-level the panel
      # and its live body children are kept and only geometry is invalidated.
      # A cross-owner move is rejected in prepare, never patched here.
      host.triggerWindow = trigger.window
      win.popoverRects.del(root)
    if host.props.name != props.name or host.props.side != props.side or
        host.props.align != props.align or host.props.sideOffset != props.sideOffset or
        host.props.width != props.width:
      host.applyProps(props, win.theme)
    # 1) Deliver recorded user intent exactly once, whatever the current
    #    temporary visibility is (a lifecycle hide must not swallow it).
    if host.hasTab():
      host.pendingTab = host.takeTab()
      host.requestPending = false
    var dismissal: PopoverDismiss
    let hadDismissal = host.takeDismiss(dismissal)
    if hadDismissal:
      host.requestPending = false
    if (host.pendingTab != 0 or hadDismissal) and not host.requestPending:
      host.requestPending = true
      win.requestPopoverState(root, false,
        if hadDismissal: "panel-dismiss:" & $dismissal else: "panel-tab")
    # 2) Accepted state decides publication.
    let allowed = win.modalAllows(root)
    var ownerVisible = true
    if host.ownerWindow != nil:
      let rootOwner = GetAncestor(host.ownerWindow, 3'u32) # GA_ROOTOWNER
      if (rootOwner != nil and IsIconic(rootOwner) != 0) or
          IsWindowVisible(host.ownerWindow) == 0:
        ownerVisible = false
    let publish = props.open and allowed and ownerVisible and
      IsWindowVisible(trigger.window) != 0 and IsWindowEnabled(trigger.window) != 0
    when defined(leafProtocolProbes):
      if win.popovers.len != 0:
        echo "POPSTATE root=", uint64(root), " publish=", publish,
          " acceptedOpen=", props.open, " ownerVisible=", ownerVisible,
          " shown=", host.shown, " visible=", (if host.isVisible: 1 else: 0)
    if not publish:
      if not host.isVisible and host.shown:
        host.noteTemporaryHidden()
      if host.isVisible:
        let hadFocus = host.focusInside()
        host.hide()
        inc win.stats.popoverCloses
        let tabDirection = host.pendingTab
        host.pendingTab = 0
        host.requestPending = false
        if tabDirection != 0:
          win.movePopoverFocus(root, content, trigger, tabDirection, hadFocus)
        elif hadFocus:
          win.movePopoverFocus(root, content, trigger, 0, true)
      continue
    # 3) Publish geometry only after the accepted state allows it.
    var px: tuple[x, y, width, height: int32, widthDip, heightDip: float64]
    try:
      px = win.popoverPixels(host, content, props)
    except ValueError:
      inc win.stats.popoverRejects
      continue
    if not host.isVisible:
      host.place(px.x, px.y, px.width, px.height)
      host.show()
      host.requestPending = false
      win.layoutPopoverContent(content, px.widthDip, px.heightDip,
        int(win.calls.dpi(host.triggerWindow)))
      let candidates = win.popoverFocusables(content)
      if candidates.len > 0:
        discard SetFocus(candidates[0].window)
      elif host.panelHandle != nil:
        discard SetFocus(host.panelHandle)
      win.popoverRects[root] = (px.x, px.y, px.width, px.height)
      inc win.stats.popoverShows
    else:
      let before = win.popoverRects.getOrDefault(root)
      if (px.x, px.y, px.width, px.height) != before:
        host.place(px.x, px.y, px.width, px.height)
        win.popoverRects[root] = (px.x, px.y, px.width, px.height)
        inc win.stats.popoverRepositions
      if host.needsLayoutNow:
        win.layoutPopoverContent(content, px.widthDip, px.heightDip,
          int(win.calls.dpi(host.triggerWindow)))
        host.clearNeedsLayout()

proc disposePopovers(win: Win32Backend) =
  var roots: seq[NodeHandle]
  for root in win.popovers.keys: roots.add(root)
  var first: ref CatchableError
  for root in roots:
    try: win.dropPopoverHost(root)
    except CatchableError as error:
      if first == nil: first = error
      else: first.msg.add("; popover cleanup: " & error.msg)
  win.popoverRects.clear()
  if first != nil: raise first

proc sendEvent(win: Win32Backend, control: NativeControl, kind: EventKind,
               phase = compositionNone) =
  if not control.armed or control.setterDepth != 0 or win.session == nil or
      win.session.closing or win.session.disposed or win.session.faulted: return
  if not win.modalAllows(control.entity.handle):
    # A background or outer-level control can still be reached through UIA
    # Invoke/Value or a stale message; its event never leaves the backend.
    inc win.overlayGateDrops
    return
  inc win.sequence
  var event = Event(kind: kind, composition: phase)
  if control.entity.kind == NodeKind.input:
    event.value = control.readText()
    if kind == change:
      control.editor.observeEditor(ControlValue(text: event.value), phase,
        control.selection(), win.sequence)
  elif control.entity.kind in {NodeKind.checkbox, NodeKind.toggle}:
    event.checked = win.calls.send(control.window, BM_GETCHECK, 0, 0) != 0
    control.editor.observeEditor(ControlValue(isCheck: true, checked: event.checked),
      compositionNone, Selection16(), win.sequence)
  discard win.session.enqueue(EventEnvelope(session: win.sessionId,
    mountGeneration: win.generation, bindingGeneration: control.binding,
    handle: control.entity.handle, sequence: win.sequence,
    observedRevision: win.revision, event: event, source: sourceUser))
  discard PostMessageW(win.host.windowHandle, WM_HOST_TICK, 0, 0)

proc captureNavigation(win: Win32Backend, message: UINT, wp: WPARAM, lp: LPARAM): bool =
  let input = navigationInput(message, wp, lp)
  if input == noNavigationInput or win.session == nil or not win.bound or
      win.session.closing or win.session.disposed or win.session.faulted: return false
  var target: NativeControl
  for control in win.controls.values:
    if control.acceptedNavigation.isSome:
      if target != nil: return false # No implicit choice between stacks.
      target = control
    if control.entity.kind == NodeKind.input and
        control.editor.phase in {compositionStart, compositionUpdate, compositionResult}:
      return false
  if target == nil or not target.armed or not target.backEnabled or
      target.window == nil or target.acceptedNavigation.get.depth <= 1: return false
  if input == repeatedBackKey: return true
  if win.sequence >= high(uint64) - 1: fail("native event sequence exhausted")
  let request = advanceBackRequest(nextBackRequest)
  inc win.sequence
  var fact = NavigationBackFact(sessionId: win.sessionId, mountGeneration: win.generation,
    handle: target.entity.handle.raw, bindingGeneration: target.binding,
    observedRevision: win.revision, sequence: win.sequence, requestId: request,
    navigation: target.acceptedNavigation.get, phase: NavigationBackPhase.begin)
  if not win.session.queueNavigation(fact): return false
  inc win.sequence
  fact.sequence = win.sequence
  fact.phase = NavigationBackPhase.confirm
  result = win.session.queueNavigation(fact)
  if result: discard PostMessageW(win.host.windowHandle, WM_HOST_TICK, 0, 0)

proc command(win: Win32Backend, receiver: HWND, wp: WPARAM, lp: LPARAM): bool =
  if lp == 0: return false
  let window = cast[HWND](lp)
  let code = UINT((wp shr 16) and 0xffff)
  for control in win.controls.values:
    if control.window != window: continue
    if receiver != control.parentWindow or GetParent(window) != control.parentWindow: return false
    if UINT(wp and 0xffff) != UINT(control.commandId) or
        GetDlgCtrlID(window) != int32(control.commandId): return false
    if controlsByCookie.getOrDefault(control.cookie) != control: return false
    case control.entity.kind
    of NodeKind.button:
      if code == 0:
        let role = standardRoleOf(control)
        if role.isSome and role.get == UiRole.popoverTrigger:
          let root = win.popoverRootOf(control.entity.handle)
          if root != NoHandle:
            when defined(leafProtocolProbes): echo "POPSRC toggle key=", control.entity.nodeId
            win.requestPopoverToggle(root)
          return true
        if role.isSome and role.get == UiRole.popoverClose:
          let root = win.popoverRootOf(control.entity.handle)
          if root != NoHandle: win.requestPopoverState(root, false, "close-control")
          return true
        if role.isSome and role.get == UiRole.selectTrigger:
          # A select trigger carries no business click: activation is one typed
          # open/close request on the select root.
          let root = win.selectRootOf(control.entity.handle)
          if root != NoHandle: win.requestSelectOpen(root)
          return true
        if role.isSome and role.get in {UiRole.dialogClose, UiRole.alertDialogCancel}:
          let root = win.overlayRootOf(control.entity.handle)
          if root != NoHandle:
            # The caller's own cancel handler still runs; the typed dismiss
            # request is what actually asks for open=false.
            win.sendEvent(control, click)
            win.queueDismiss(root, if role.get == UiRole.dialogClose:
              closeControl else: cancelControl)
            return true
        win.sendEvent(control, click)
    of NodeKind.checkbox, NodeKind.toggle:
      if code == 0: win.sendEvent(control, change)
    of NodeKind.input:
      if code == 0x300: win.sendEvent(control, change, control.editor.phase)
    else: discard
    return true

proc releaseRegions(win: Win32Backend) =
  for region in win.pendingRegions.mitems:
    if region == nil: continue
    if win.calls.deleteObject(cast[HGDIOBJ](region)) == 0: nativeError("DeleteObject region")
    region = nil
  win.pendingRegions.setLen(0)
proc releaseContexts(win: Win32Backend) =
  for item in win.pendingContexts.mitems:
    if item.context == nil: continue
    if win.calls.immRelease(item.window, item.context) == 0: nativeError("ImmReleaseContext")
    item.context = nil
  win.pendingContexts.setLen(0)

proc applyEffects(win: Win32Backend, control: NativeControl, effects: seq[EditEffect]) =
  inc control.setterDepth
  defer: dec control.setterDepth
  for effect in effects:
    case effect.kind
    of forceCancelComposition:
      if control.editor.phase in {compositionStart, compositionUpdate, compositionResult}:
        win.releaseContexts()
        let context = win.calls.immContext(control.window)
        if context == nil: fail("active composition has no native input context")
        win.pendingContexts.add((control.window, context))
        var primary: ref CatchableError
        try:
          if win.calls.immNotify(context, 0x15, 4, 0) == 0: nativeError("ImmNotifyIME cancel")
        except CatchableError as error: primary = error
        try: win.releaseContexts()
        except CatchableError as secondary:
          if primary != nil: primary.msg.add("; IMM cleanup secondary: " & secondary.msg)
          else: raise secondary
        if primary != nil: raise primary
      control.editor.phase = compositionNone
    of setText:
      when defined(leafProtocolProbes):
        if win.popovers.len != 0:
          echo "APPLY setText hwnd=", uint64(cast[uint](control.window)),
            " handle=", uint64(control.entity.handle),
            " newLen=", effect.value.text.len,
            " oldLen=", control.readText().len,
            " force=", effect.force, " setterDepth=", control.setterDepth,
            " seq=", control.editor.latestObserved
      let wide = checkedWide(effect.value.text)
      if win.calls.setText(control.window, unsafeAddr wide[0]) == 0: nativeError("SetWindowTextW")
      inc win.stats.setTexts
      control.editor.native = effect.value
      control.editor.selection = effect.selection
      discard win.calls.send(control.window, EM_SETSEL, WPARAM(effect.selection.anchor), LPARAM(effect.selection.caret))
    of setChecked:
      discard win.calls.send(control.window, BM_SETCHECK, WPARAM(ord(effect.value.checked)), 0)
      control.editor.native = effect.value
    of setSelection:
      discard win.calls.send(control.window, EM_SETSEL, WPARAM(effect.selection.anchor), LPARAM(effect.selection.caret))
      control.editor.selection = effect.selection




proc ancestorRoot(window: HWND, flags: UINT): HWND {.stdcall, dynlib: "user32.dll",
    importc: "GetAncestor", raises: [].}

proc focusableInWindow(win: Win32Backend, window: HWND): HWND =
  ## First focusable accepted control whose top-level ancestor is this window,
  ## in the same tab order the layout and native sibling pass establish.
  var root = NoHandle
  for handle, entity in win.current:
    if entity.parent == NoHandle: root = handle
  if root == NoHandle: return nil
  for control in win.subtreeControls(root, true):
    if control.window == nil: continue
    if ancestorRoot(control.window, 2) != window: continue
    if usableFocus(control): return control.window
  nil

proc restoreOverlayFocus(win: Win32Backend, owner: HWND, previous: HWND) =
  ## The remembered trigger is reused only while it still exists, is visible and
  ## enabled; otherwise a deterministic fallback inside the level below wins.
  ## The owner is the level that is enabled again after this close.
  if owner == nil: return
  let usable = previous != nil and IsWindow(previous) != 0 and
    IsWindowVisible(previous) != 0 and IsWindowEnabled(previous) != 0 and
    ancestorRoot(previous, 2) == owner
  let first = if usable: nil else: win.focusableInWindow(owner)
  case chooseRestoreFocus(usable, first != nil)
  of "trigger": discard SetFocus(previous)
  of "first": discard SetFocus(first)
  else:
    if IsWindowEnabled(owner) != 0: discard SetFocus(owner)

proc overlayOwnerWindow(win: Win32Backend, handle: NodeHandle): HWND =
  ## Window this level is owned by: the level directly below it in the published
  ## stack, else the Host window. A level that is being opened is not in the
  ## stack yet, so its owner is the current top of the stack.
  let index = win.overlayStack.order.find(handle.raw)
  if index > 0:
    let below = NodeHandle(win.overlayStack.order[index - 1])
    if win.overlays.hasKey(below): return win.overlays[below].surfaceHandle
  elif index < 0 and win.overlayStack.order.len > 0:
    let below = NodeHandle(win.overlayStack.topOverlay)
    if win.overlays.hasKey(below): return win.overlays[below].surfaceHandle
  win.host.windowHandle

proc showControl(win: Win32Backend, control: NativeControl, visible: bool,
                 source = "")
proc placeControl(win: Win32Backend, control: NativeControl,
                  position: tuple[x, y, width, height: int],
                  clip: tuple[left, top, right, bottom: int], rowSubtree = false)

proc mergedEntities(win: Win32Backend): Table[NodeHandle, MountedEntity] =
  ## Candidate view of the whole tree. A delta batch only carries the changed
  ## entities, so measurements and ordering must run on this merge instead of
  ## the sparse batch table.
  result = win.current
  for handle, entity in win.candidate: result[handle] = entity

proc dropPlannedRemovals(merged: var Table[NodeHandle, MountedEntity],
    removed: HashSet[NodeHandle]) =
  ## The candidate merge also carries nodes this transaction plans to remove, so
  ## the preflight would still measure a level that is going away. Only the
  ## explicit removal set and its descendants are excluded: a node that merely
  ## does not appear in a sparse batch is unchanged and stays.
  if removed.len == 0: return
  var doomed: HashSet[NodeHandle]
  var stack: seq[NodeHandle]
  for handle in removed: stack.add(handle)
  while stack.len > 0:
    let current = stack.pop()
    if current in doomed: continue
    doomed.incl(current)
    for handle, entity in merged:
      if entity.parent == current: stack.add(handle)
  for handle in doomed: merged.del(handle)

proc withoutPopoverBodies(entities: Table[NodeHandle, MountedEntity]):
    Table[NodeHandle, MountedEntity] =
  ## A panel body is laid out inside its own owned window; it must never take
  ## part in page flow, modal preflight measurement or modal composition.
  result = entities
  var bodies: HashSet[NodeHandle]
  for handle, entity in entities:
    if entity.props.standardUi.isSome and
        entity.props.standardUi.get.role == UiRole.popoverContent:
      var stack = @[handle]
      while stack.len > 0:
        let current = stack.pop()
        if current in bodies: continue
        bodies.incl(current)
        for child, childEntity in entities:
          if childEntity.parent == current: stack.add(child)
  for handle in bodies: result.del(handle)

proc preparePopoverBodies(win: Win32Backend, removed: HashSet[NodeHandle]) =
  ## Candidate precheck: a body that cannot fit the work area must be refused as
  ## a revision, before anything is accepted or published. This keeps the accepted
  ## tree, geometry, EDIT draft and focus exactly as they were.
  var merged = win.mergedEntities()
  dropPlannedRemovals(merged, removed)
  if merged.len == 0: return
  let area = workArea(win.calls, win.host.windowHandle)
  if not area.known: return
  # Measure the candidate body itself: it lives in its own window, so its own
  # subtree (not the page/modal flow) is the right input.
  var scope = initLayoutScope(merged,
    proc(entity: MountedEntity, available: DipSize): DipSize =
      win.measureControl(entity, available))
  proc logicalOwner(tree: Table[NodeHandle, MountedEntity],
                    handle: NodeHandle): NodeHandle =
    var current = tree.getOrDefault(handle).parent
    var depth = 0
    while current != NoHandle and depth <= MaxDepth:
      let item = tree.getOrDefault(current)
      if item.handle == NoHandle: return NoHandle
      if item.overlay.isSome: return current
      current = item.parent
      inc depth
    NoHandle
  for handle, entity in merged:
    if entity.popover.isNone or not entity.popover.get.open: continue
    # A panel belongs to one owning top-level for its whole lifetime: a candidate
    # whose accepted panel would change owner domain is refused before anything
    # is accepted, so the old tree/owner/body/focus stay intact.
    if win.current.hasKey(handle) and win.popovers.hasKey(handle):
      let before = logicalOwner(win.current, handle)
      let after = logicalOwner(merged, handle)
      if before != after:
        fail("popover owner domain change requires a new popover root: " &
          entity.nodeId)
    var content = NoHandle
    for child, childEntity in merged:
      if childEntity.parent == handle and childEntity.props.standardUi.isSome and
          childEntity.props.standardUi.get.role == UiRole.popoverContent:
        content = child
        break
    if content == NoHandle: continue
    let width = entity.popover.get.popoverWidth
    let available = area.height - 2.0 * PopoverMargin
    if available <= 0: continue
    let measured = scope.measureSubtree(content, DipSize(width: width,
      height: available))
    if measured.height > available:
      fail("popover content does not fit the work area: " & entity.nodeId &
        " needs " & $measured.height & " DIP at width " & $width &
        " but the area offers " & $available & " DIP")

proc prepareOverlays(win: Win32Backend, removed: HashSet[NodeHandle] = initHashSet[NodeHandle]()) =
  ## Whole-candidate preflight, run inside prepare before anything is shown,
  ## disabled or focused: depth budget, hidden native windows, measured content
  ## height per level and the work-area fit rule. A rejection here leaves the
  ## previously accepted layout completely untouched.
  win.preparePopoverBodies(removed)
  win.overlayPlans.clear()
  var merged = win.mergedEntities()
  dropPlannedRemovals(merged, removed)
  if win.popovers.len != 0: merged = withoutPopoverBodies(merged)
  var open: seq[NodeHandle]
  for handle in win.overlayOpenOrder(merged):
    let entity = merged.getOrDefault(handle)
    if entity.overlay.isSome and entity.overlay.get.open: open.add(handle)
  if open.len > MaxOverlayDepth:
    fail("modal overlay nesting exceeds " & $MaxOverlayDepth & " levels")
  # Nothing to validate when this transaction only removes levels: an unrelated
  # work-area size must not block a pure close/removal.
  if open.len == 0: return
  let area = win.overlayWorkArea()
  var scope = initLayoutScope(merged,
    proc(entity: MountedEntity, available: DipSize): DipSize =
      win.measureControl(entity, available))
  for handle in open:
    let entity = merged.getOrDefault(handle)
    if not win.overlays.hasKey(handle): discard win.ensureOverlayHost(entity)
    let props = entity.overlay.get
    var width = props.overlayWidth
    var availableHeight = 100_000.0
    if area.known:
      let availableWidth = area.width - 2 * ModalMargin
      availableHeight = area.height - 2 * ModalMargin
      if availableWidth < width: width = availableWidth
      if width <= 0 or availableHeight <= 0:
        fail("modal overlay has no usable work area")
    let measured = scope.measureSubtree(handle, DipSize(width: width,
      height: availableHeight))
    # Only an already published level may preserve non-growing content when
    # its environment becomes smaller. Do not depend on cached scroll ranges:
    # an edit can arrive before the geometry turn notices the shrink.
    var retainsAcceptedExtent = false
    let constrained = area.known and
      (width < MinOverlayWidth or measured.height > availableHeight)
    if constrained and win.overlayAcceptedPlans.hasKey(handle):
      let overlay = win.overlays.getOrDefault(handle)
      let previousEntity = win.current.getOrDefault(handle)
      if overlay != nil and overlay.isVisible and previousEntity.overlay.isSome and
          previousEntity.overlay.get.open and
          previousEntity.overlay.get.overlayWidth == props.overlayWidth:
        var currentScope = initLayoutScope(withoutPopoverBodies(win.current),
          proc(item: MountedEntity, available: DipSize): DipSize =
            win.measureControl(item, available))
        let previous = currentScope.measureSubtree(handle,
          DipSize(width: width, height: availableHeight))
        retainsAcceptedExtent = measured.height <= previous.height and
          measured.width <= previous.width
    if area.known and width < MinOverlayWidth and not retainsAcceptedExtent:
      fail("modal overlay cannot fit this work area width")
    if area.known and measured.height > availableHeight and not retainsAcceptedExtent:
      fail("modal overlay content needs " & $measured.height &
        " DIP of height at width " & $width & " but the work area offers " &
        $availableHeight & " DIP; candidate increases unsupported overflow")
    win.overlayPlans[handle] = OverlayPlan(open: true, width: width,
      height: (if retainsAcceptedExtent: min(measured.height, availableHeight)
        else: measured.height))

proc placeOverlayBoxes(win: Win32Backend, root: NodeHandle,
                       boxes: seq[LayoutBox], dpi: int,
                       source = "placeLevel") =
  ## Parent-relative placement for one modal subtree. Runs while the level may
  ## still be hidden, so it is a pure geometry step with no focus side effects.
  var byHandle: Table[NodeHandle, LayoutBox]
  for box in boxes: byHandle[box.handle] = box
  for box in boxes:
    if box.handle notin win.controls: continue
    let control = win.controls[box.handle]
    if box.clip.width <= 0 or box.clip.height <= 0 or
        box.rect.x >= box.clip.x + box.clip.width or
        box.rect.y >= box.clip.y + box.clip.height or
        box.rect.x + box.rect.width <= box.clip.x or
        box.rect.y + box.rect.height <= box.clip.y:
      win.showControl(control, false, source)
      continue
    let pixels = pixelEdges(box.rect, dpi)
    var left = pixels.left
    var top = pixels.top
    if box.handle != root and byHandle.hasKey(control.entity.parent):
      let parent = pixelEdges(byHandle[control.entity.parent].rect, dpi)
      left -= parent.left
      top -= parent.top
    let clip = pixelEdges(box.clip, dpi)
    when defined(leafProtocolProbes):
      var winRect: RECT
      discard win.calls.windowRect(control.window, addr winRect)
      echo "BOX h=" & $uint64(box.handle) & " rect=" & $formatFloat(box.rect.x, ffDefault, 1) &
        "," & $formatFloat(box.rect.y, ffDefault, 1) & " " &
        $formatFloat(box.rect.width, ffDefault, 1) & "x" &
        $formatFloat(box.rect.height, ffDefault, 1) &
        " clip=" & $formatFloat(box.clip.x, ffDefault, 1) & "," &
        $formatFloat(box.clip.y, ffDefault, 1) & " " &
        $formatFloat(box.clip.width, ffDefault, 1) & "x" &
        $formatFloat(box.clip.height, ffDefault, 1) &
        " pos=" & $(left) & "," & $(top) & " vis=" & $IsWindowVisible(control.window) &
        " wr=" & $(winRect.left) & "," & $(winRect.top) & " " &
        $(winRect.right - winRect.left) & "x" & $(winRect.bottom - winRect.top)
    win.placeControl(control,
      (left, top, pixels.right - pixels.left, pixels.bottom - pixels.top),
      (max(0, clip.left - pixels.left), max(0, clip.top - pixels.top),
       max(0, min(pixels.right, clip.right) - pixels.left),
       max(0, min(pixels.bottom, clip.bottom) - pixels.top)))
  var siblings: Table[NodeHandle, seq[MountedEntity]]
  var inside: HashSet[NodeHandle]
  for box in boxes: inside.incl(box.handle)
  for handle in inside:
    let entity = win.current.getOrDefault(handle)
    if entity.handle != NoHandle: siblings.mgetOrPut(entity.parent, @[]).add(entity)
  for parent, children in siblings.mpairs:
    children.sort(proc(a, b: MountedEntity): int = cmp(a.index, b.index))
    var order: seq[HWND]
    for child in children:
      if win.controls.hasKey(child.handle):
        order.add(win.controls[child.handle].window)
    var previous: HWND
    for window in order:
      if win.calls.windowPos(window, previous, 0, 0, 0, 0,
          0x0001'u32 or 0x0002'u32 or SWP_NOACTIVATE) == 0:
        nativeError("SetWindowPos overlay tab order")
      previous = window

proc overlayBarThickness(dpi: int): float64 =
  ## Native scrollbar thickness in DIP for this DPI.
  let effective = max(96, dpi)
  let scale = float64(effective) / 96.0
  max(0.0, float64(GetSystemMetricsForDpi(SM_CXVSCROLL, UINT(effective))) / scale)

proc publishOverlayBars(win: Win32Backend, overlay: Win32Overlay,
                        plan: var OverlayPlan, dpi: int) =
  ## Publishes the accepted geometry's bars. Every step is recorded inside the
  ## overlay host, so a failure keeps a retryable receipt instead of pretending
  ## the level has working scrollbars.
  if overlay == nil: return
  let scale = max(1.0, float64(max(96, dpi)) / 96.0)
  overlay.setOverlayPixelScale(scale)
  let g = plan.geom
  let rects = g.barRects()
  let px = g.scrollbarPixels(scale)
  proc edge(value: float64): int32 =
    int32(max(0.0, min(float64(high(int32) - 1), (value * scale) + 0.5)))
  plan.barFault = false
  when defined(leafProtocolProbes):
    echo "BARPUB posY=" & $px.posYPx & " rangeY=" & $px.rangeYPx & " pageY=" &
      $px.pageYPx & " hasV=" & $g.verticalBar & " hasH=" & $g.horizontalBar
  try:
    if g.verticalBar:
      overlay.placeOverlayScrollbar(true, edge(rects.vertical.x), edge(rects.vertical.y),
        max(1'i32, edge(rects.vertical.width)), max(1'i32, edge(rects.vertical.height)))
      overlay.applyOverlayScrollInfo(true, px.rangeYPx, px.pageYPx, px.posYPx)
    else:
      overlay.hideOverlayScrollbar(true)
    if g.horizontalBar:
      overlay.placeOverlayScrollbar(false, edge(rects.horizontal.x),
        edge(rects.horizontal.y), max(1'i32, edge(rects.horizontal.width)),
        max(1'i32, edge(rects.horizontal.height)))
      overlay.applyOverlayScrollInfo(false, px.rangeXPx, px.pageXPx, px.posXPx)
    else:
      overlay.hideOverlayScrollbar(false)
  except CatchableError:
    # Receipts stay as they are and the accepted plan is kept; the next tick
    # retries the failed step instead of dropping the level's geometry.
    plan.barFault = true

proc levelPartRole(win: Win32Backend, handle: NodeHandle): Option[UiRole] =
  let entity = win.current.getOrDefault(handle)
  if entity.props.standardUi.isSome: some(entity.props.standardUi.get.role)
  else: none(UiRole)

proc levelParts(win: Win32Backend, root: NodeHandle):
    tuple[header, content, footer: NodeHandle, exact: bool] =
  ## Exact modal shape: header/content/footer each at most once and no other
  ## accepted child. Anything else (custom composition) is not silently
  ## rearranged - it falls back to the plain subtree layout and is reported.
  let children = win.childrenOf(root)
  var header, content, footer: NodeHandle
  var other = 0
  for child in children:
    let role = win.levelPartRole(child.handle)
    if role.isNone:
      inc other
      continue
    case role.get
    of UiRole.dialogHeader:
      if header != NoHandle: inc other else: header = child.handle
    of UiRole.dialogContent:
      if content != NoHandle: inc other else: content = child.handle
    of UiRole.dialogFooter:
      if footer != NoHandle: inc other else: footer = child.handle
    else:
      inc other
  (header, content, footer, other == 0 and footer != NoHandle)

proc intersectDip(a, b: DipRect): DipRect =
  DipRect(x: max(a.x, b.x), y: max(a.y, b.y),
    width: min(a.x + a.width, b.x + b.width) - max(a.x, b.x),
    height: min(a.y + a.height, b.y + b.height) - max(a.y, b.y))

proc composeLevelBoxes(win: Win32Backend, scope: var LayoutScope, root: NodeHandle,
                       geom: OverlayGeometry, pinFooter: bool,
                       contentRects: var Table[NodeHandle, DipRect]): seq[LayoutBox] =
  ## Level composition. Without pinning it is one subtree layout, which is the
  ## normal case because the content was measured to fit at this width.
  ## With pinning (the runtime work area shrank after acceptance) the header
  ## stays on top and the footer is pinned to the bottom of the *clamped* client
  ## so the safe actions stay fully visible; the content viewport is clipped in
  ## between and every control that ends up outside it is hidden (and therefore
  ## leaves the tab order).
  let clip = DipRect(x: geom.viewportX, y: geom.viewportY,
    width: geom.viewportWidth, height: geom.viewportHeight)
  let clientWidth = clip.width
  let clientHeight = clip.height
  if geom.rangeX > 0.0 or geom.rangeY > 0.0:
    # Vertical scroll: lay the level out at its natural content height, then
    # shift every descendant by the scroll offset and clip it to the viewport.
    # Controls outside the viewport are hidden by the placement pass and the
    # logical focus order still sees them (see tabFocus).
    let contentWidth = max(geom.contentWidth, geom.viewportWidth)
    let natural = scope.layoutSubtree(root,
      DipRect(x: 0.0, y: 0.0, width: contentWidth, height: geom.contentHeight),
      DipRect(x: 0.0, y: 0.0, width: contentWidth, height: geom.contentHeight))
    var scrolled: seq[LayoutBox]
    for box in natural:
      if box.handle == root:
        scrolled.add(LayoutBox(handle: root, rect: clip, clip: clip))
        continue
      var moved = box
      # Both axes: the content rect and its content-space clip move together,
      # then the viewport clips them. Boxes leaving the viewport stay emitted so
      # the placement pass hides them and no native geometry is left stale.
      contentRects[box.handle] = box.rect
      moved.rect = DipRect(x: box.rect.x - geom.scrollX,
        y: box.rect.y - geom.scrollY, width: box.rect.width, height: box.rect.height)
      moved.clip = intersectDip(DipRect(x: box.clip.x - geom.scrollX,
        y: box.clip.y - geom.scrollY, width: box.clip.width, height: box.clip.height), clip)
      scrolled.add(moved)
    return scrolled
  if not pinFooter:
    return scope.layoutSubtree(root, clip, clip)
  let parts = win.levelParts(root)
  if not parts.exact:
    # Unknown composition: keep the plain layout rather than invent a split.
    inc win.overlayUnexpectedCompositions
    return scope.layoutSubtree(root, clip, clip)
  let rootEntity = win.current.getOrDefault(root)
  let padding = rootEntity.props.layout.padding.get(12.0)
  let gap = rootEntity.props.layout.gap.get(8.0)
  let innerWidth = max(1.0, clientWidth - 2 * padding)
  var footerHeight = 0.0
  if parts.footer != NoHandle:
    footerHeight = scope.measureSubtree(parts.footer,
      DipSize(width: innerWidth, height: clientHeight)).height
  var headerHeight = 0.0
  if parts.header != NoHandle:
    headerHeight = scope.measureSubtree(parts.header,
      DipSize(width: innerWidth, height: clientHeight)).height
  # Supported minimum: padding + header + gap + a minimal content strip + gap +
  # footer. Below this the level is not shrunk at all (no negative coordinates
  # and no hidden safe actions); the caller keeps the previous geometry and the
  # keyboard/system close path remains available.
  let minContent = 24.0
  var required = padding * 2 + footerHeight + gap
  if parts.header != NoHandle: required += headerHeight + gap
  if parts.content != NoHandle: required += minContent
  if clientHeight < required:
    inc win.overlayUnsupportedShrinks
    return scope.layoutSubtree(root, clip, clip)
  var result: seq[LayoutBox]
  result.add(LayoutBox(handle: root, rect: clip, clip: clip))
  var cursor = padding
  if parts.header != NoHandle:
    let rect = DipRect(x: padding, y: cursor, width: innerWidth, height: headerHeight)
    for box in scope.layoutSubtree(parts.header, rect, clip): result.add(box)
    cursor += headerHeight + gap
  let footerTop = max(cursor, clientHeight - padding - footerHeight)
  if parts.content != NoHandle:
    let height = max(0.0, footerTop - gap - cursor)
    if height <= 0.0:
      # No room for content: hide its controls instead of drawing them under the
      # footer, and never emit a negative-height rect.
      for control in win.subtreeControls(parts.content, false):
        win.showControl(control, false, "overlayZero")
    else:
      let rect = DipRect(x: padding, y: cursor, width: innerWidth, height: height)
      for box in scope.layoutSubtree(parts.content, rect, rect): result.add(box)
  if parts.footer != NoHandle:
    let rect = DipRect(x: padding, y: footerTop, width: innerWidth,
      height: footerHeight)
    for box in scope.layoutSubtree(parts.footer, rect, clip): result.add(box)
  result

proc applyOverlayGeometry(win: Win32Backend) =
  ## Geometry-only preparation for every accepted open level: placement math,
  ## subtree layout, control placement, surface title and theme. Everything here
  ## still happens on hidden windows; showing, disabling the owner and moving
  ## focus belong to the ordinary-turn publish step.
  var stillOpenHandles: HashSet[NodeHandle]
  for handle in win.overlayOpenOrder(win.current): stillOpenHandles.incl(handle)
  for handle in toSeq(win.overlayAcceptedPlans.keys):
    if handle notin stillOpenHandles: win.overlayAcceptedPlans.del(handle)
  var open: seq[NodeHandle]
  for handle in win.overlayOpenOrder(win.current):
    let entity = win.current.getOrDefault(handle)
    if entity.overlay.isSome and entity.overlay.get.open: open.add(handle)
  if open.len != 0:
    let ctx = win.host.context
    let dpi = int(ctx.scale * 96)
    # Same layout domain as prepareOverlays/layoutOverlays: a popover body is
    # never part of a modal level's measured subtree, including this apply path.
    var applyEntities = win.current
    if win.popovers.len != 0: applyEntities = withoutPopoverBodies(win.current)
    var scope = initLayoutScope(applyEntities,
      proc(entity: MountedEntity, available: DipSize): DipSize =
        win.measureControl(entity, available))
    for index, handle in open:
      let overlay = win.overlays.getOrDefault(handle)
      if overlay == nil: continue
      let entity = win.current.getOrDefault(handle)
      var plan = win.overlayPlans.getOrDefault(handle)
      # Only a level that was already published keeps its offset: a fresh open
      # starts at the origin, and a closed level drops its memory below.
      if overlay.isVisible and win.overlayAcceptedPlans.hasKey(handle):
        let accepted = win.overlayAcceptedPlans[handle]
        plan.scrollX = accepted.scrollX
        plan.scrollY = accepted.scrollY
      if plan.width <= 0:
        plan = OverlayPlan(open: true, width: entity.overlay.get.overlayWidth,
          height: 0.0)
      var owner = win.host.windowHandle
      if index > 0:
        let below = win.overlays.getOrDefault(open[index - 1])
        if below != nil: owner = below.surfaceHandle
      let placement = overlay.placementFor(plan.width, plan.height, owner)
      plan.x = placement.x
      plan.y = placement.y
      plan.widthPx = placement.widthPx
      plan.heightPx = placement.heightPx
      plan.scrimRect = (placement.scrimLeft, placement.scrimTop,
        placement.scrimRight, placement.scrimBottom)
      plan.placed = true
      # Single source of truth: validated width plus the height measured at it.
      let clientWidth = placement.clientWidth
      let clientHeight = placement.clientHeight
      let bar = overlayBarThickness(dpi)
      var measureScope = scope
      let rootHandle = handle
      let measured = planOverlayGeometry(clientWidth, clientHeight, bar, bar,
        proc(width: float64): tuple[width, height: float64] =
          let size = measureScope.measureSubtree(rootHandle,
            DipSize(width: width, height: 100_000.0))
          (size.width, size.height), plan.scrollX, plan.scrollY)
      plan.geom = measured
      plan.contentW = measured.contentWidth
      plan.contentH = measured.contentHeight
      plan.rangeX = measured.rangeX
      plan.rangeY = measured.rangeY
      plan.scrollX = measured.scrollX
      plan.scrollY = measured.scrollY
      let viewport = DipRect(x: measured.viewportX, y: measured.viewportY,
        width: measured.viewportWidth, height: measured.viewportHeight)
      plan.contentRects.clear()
      let boxes = win.composeLevelBoxes(scope, handle, measured, false,
        plan.contentRects)
      win.placeOverlayBoxes(handle, boxes, dpi, "applyLevel")
      overlay.setTitle(entity.props.control.label.get(""))
      overlay.overlayTheme(win.theme)
      # Scroll range: the content height was measured at the final width, so the
      # range is pure data here. A level that fits keeps range 0 and the normal
      # layout; no scrollbar, no offset, no API change.
      overlay.setScrollable(plan.rangeY > 0.0 or plan.rangeX > 0.0)
      win.publishOverlayBars(overlay, plan, dpi)
      win.overlayAcceptedPlans[handle] = plan
    # Only a visible level needs a geometry pass; an ordinary update without
    # modal levels must keep its existing single layout pass.
    win.overlayDirty = true
  win.overlayPublishPending = true

proc showOverlayLevel(win: Win32Backend, root: NodeHandle) =
  let overlay = win.overlays.getOrDefault(root)
  if overlay == nil: return
  let entity = win.current.getOrDefault(root)
  if entity.handle == NoHandle or entity.overlay.isNone: return
  # A visible surface is not a finished publish: a failure between show and the
  # owner/stack commit must be completed by the next turn, never skipped.
  if overlay.isVisible and overlay.published: return
  if win.overlayStack.order.len >= MaxOverlayDepth:
    fail("modal overlay nesting exceeds " & $MaxOverlayDepth & " levels")
  if not win.overlayFocusBefore.hasKey(root):
    win.overlayFocusBefore[root] = GetFocus()
  overlay.overlayTheme(win.theme)
  let plan = win.overlayAcceptedPlans.getOrDefault(root)
  if plan.placed:
    overlay.applyPlacement(OverlayPlacement(x: plan.x, y: plan.y,
      widthPx: plan.widthPx, heightPx: plan.heightPx, owner: win.overlayOwnerWindow(root),
      scrimLeft: plan.scrimRect[0], scrimTop: plan.scrimRect[1],
      scrimRight: plan.scrimRect[2], scrimBottom: plan.scrimRect[3],
      clientWidth: plan.width, clientHeight: plan.height))
  overlay.showOverlay(win.overlayOwnerWindow(root))
  # The stack follows the state that really exists: only a level whose show
  # completed becomes the modal target.
  if activateOverlay(win.overlayStack, root.raw) == overlayBudgetExceeded:
    fail("modal overlay nesting exceeds " & $MaxOverlayDepth & " levels")
  win.overlayPendingFocus.incl(root)
  let target = win.planInitialFocus(root)
  if target != nil: discard SetFocus(target)
  inc win.stats.overlayShows
  win.overlayDirty = true

proc hideOverlayLevel(win: Win32Backend, root: NodeHandle) =
  let overlay = win.overlays.getOrDefault(root)
  if overlay == nil: return
  let wasTop = overlayIsTop(win.overlayStack, root.raw)
  let owner = win.overlayOwnerWindow(root)
  let previous = win.overlayFocusBefore.getOrDefault(root)
  # The step-wise hide may raise; every completed step is already recorded, so a
  # retry continues. The stack, the owner and the focus are committed only after
  # the level really stopped being visible.
  overlay.hideOverlay()
  discard deactivateOverlay(win.overlayStack, root.raw)
  win.overlayFocusBefore.del(root)
  win.overlayPendingFocus.excl(root)
  win.overlayDirty = true
  if wasTop: win.restoreOverlayFocus(owner, previous)

proc dropOverlayLevel(win: Win32Backend, root: NodeHandle) =
  ## Resource-safe teardown: the table entry and the live counter are only
  ## released after the native windows/classes really went away, so a failure
  ## keeps a retry receipt instead of a fake zero.
  let overlay = win.overlays.getOrDefault(root)
  if overlay == nil: return
  win.hideOverlayLevel(root)
  let failure = overlay.closeWindows()
  if failure != nil:
    raise failure
  win.overlays.del(root)
  win.overlayAcceptedPlans.del(root)
  win.overlayPlans.del(root)
  dec win.stats.liveOverlays
  win.overlayDirty = true

proc publishOverlays(win: Win32Backend) =
  ## Ordinary-turn OS publish of the accepted modal state: close levels that are
  ## no longer accepted-open (top-down), then open the accepted ones bottom-up.
  ## Idempotent; a failure here is a real native error with retryable cleanup,
  ## never an attempt to pretend that already delivered focus input rolls back.
  if win.session == nil: return
  if not win.overlayPublishPending and win.overlayStack.order.len == 0 and
      win.overlays.len == 0: return
  var index = win.overlayStack.order.len - 1
  while index >= 0:
    let root = NodeHandle(win.overlayStack.order[index])
    let entity = win.current.getOrDefault(root)
    if entity.handle == NoHandle or entity.overlay.isNone or not entity.overlay.get.open:
      when defined(leafProtocolProbes):
        echo "HIDEREQ root=" & $uint64(root) & " stack=" & $win.overlayStack.order.len
      win.hideOverlayLevel(root)
      when defined(leafProtocolProbes):
        echo "HIDEDONE root=" & $uint64(root) & " stack=" & $win.overlayStack.order.len
    dec index
  for root in win.overlayOpenOrder(win.current):
    let entity = win.current.getOrDefault(root)
    if entity.overlay.isNone or not entity.overlay.get.open: continue
    when defined(leafProtocolProbes):
      try:
        win.showOverlayLevel(root)
      except CatchableError as error:
        echo "PUBFAIL root=" & $uint64(root) & " err=" & error.msg
        raise error
    else:
      win.showOverlayLevel(root)
  var stale: seq[NodeHandle]
  for root in win.overlays.keys:
    let entity = win.current.getOrDefault(root)
    if entity.handle == NoHandle or entity.overlay.isNone: stale.add(root)
  for root in stale: win.dropOverlayLevel(root)
  win.preparedOverlays.setLen(0)
  win.overlayPublishPending = false

proc disposeOverlays(win: Win32Backend) =
  var roots: seq[NodeHandle]
  for root in win.overlays.keys: roots.add(root)
  var first: ref CatchableError
  for root in roots:
    try: win.dropOverlayLevel(root)
    except CatchableError as error:
      if first == nil: first = error
      else: first.msg.add("; overlay cleanup: " & error.msg)
  win.overlayStack = OverlayStack()
  win.overlayAcceptedPlans.clear()
  win.overlayPlans.clear()
  if first != nil: raise first

proc relayout*(win: Win32Backend, content: DipSize, dpi: int)
proc layoutOverlays(win: Win32Backend, dpi: int)

proc focusCandidates(win: Win32Backend, root: NodeHandle): seq[NativeControl] =
  ## Logical focus order inside one level: the accepted tab order, skipping only
  ## business-disabled controls. Viewport clipping is NOT a filter, so a target
  ## that was hidden by scrolling can still be reached and scrolled into view.
  for control in win.subtreeControls(root, false):
    if control.window == nil: continue
    if control.entity.kind notin {NodeKind.button, NodeKind.input,
        NodeKind.checkbox, NodeKind.toggle, NodeKind.virtualList}: continue
    let enabled = control.entity.props.control.enabled
    if enabled.isSome and not enabled.get: continue
    result.add(control)

proc scrollFocusIntoView(win: Win32Backend, root: NodeHandle,
                         control: NativeControl) =
  ## Reveal a focus target on both axes from the accepted layout, never from the
  ## HWND rect: a control hidden by scrolling keeps its stale window position.
  ## The viewport is the candidate's (client minus bars), not the full client.
  let overlay = win.overlays.getOrDefault(root)
  if overlay == nil or control.window == nil: return
  var plan = win.overlayAcceptedPlans.getOrDefault(root)
  let g = plan.geom
  if g.rangeX <= 0.0 and g.rangeY <= 0.0: return
  when defined(leafProtocolProbes):
    echo "REVEAL h=" & $uint64(control.handle) & " hasRect=" &
      $plan.contentRects.hasKey(control.handle) & " sxy=" & $plan.scrollX & "," &
      $plan.scrollY & " range=" & $plan.geom.rangeX & "," & $plan.geom.rangeY &
      " vp=" & $plan.geom.viewportWidth & "x" & $plan.geom.viewportHeight
  if not plan.contentRects.hasKey(control.handle): return
  let content = plan.contentRects[control.handle]
  let vw = g.viewportWidth
  let vh = g.viewportHeight
  var sx = plan.scrollX
  var sy = plan.scrollY
  # Deterministic anchor: a target bigger than the viewport aligns its leading
  # edge; otherwise the trailing edge is revealed first, then the leading one.
  if content.height >= vh: sy = content.y
  elif content.y + content.height > sy + vh: sy = content.y + content.height - vh
  elif content.y < sy: sy = content.y
  if content.width >= vw: sx = content.x
  elif content.x + content.width > sx + vw: sx = content.x + content.width - vw
  elif content.x < sx: sx = content.x
  sy = clamp(sy, 0.0, g.rangeY)
  sx = clamp(sx, 0.0, g.rangeX)
  when defined(leafProtocolProbes):
    echo "REVEALCTRL h=" & $uint64(control.handle) & " rect=" & $content.x & "," &
      $content.y & " " & $content.width & "x" & $content.height & " -> sx=" & $sx &
      " sy=" & $sy & " (was " & $plan.scrollX & "," & $plan.scrollY & ")"
  if sx == plan.scrollX and sy == plan.scrollY: return
  plan.scrollX = sx
  plan.scrollY = sy
  plan.geom.scrollX = sx
  plan.geom.scrollY = sy
  win.overlayAcceptedPlans[root] = plan
  let context = win.host.context
  win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
    int(context.scale * 96))

proc tabFocus(win: Win32Backend, root: NodeHandle, direction: int) =
  ## USER32 cannot cycle to a control that the scroll pass hid, so the modal
  ## keeps its own logical order: pick the next/previous candidate, scroll it
  ## into view, then give it the real native focus.
  let candidates = win.focusCandidates(root)
  if candidates.len == 0: return
  let focus = GetFocus()
  var index = -1
  for position, control in candidates:
    if control.window == focus:
      index = position
      break
  let target = if index < 0:
      (if direction > 0: candidates[0] else: candidates[^1])
    else:
      candidates[(index + direction + candidates.len) mod candidates.len]
  win.scrollFocusIntoView(root, target)
  discard SetFocus(target.window)

proc overlayTurn(win: Win32Backend) =
  ## Ordinary-turn modal work: publish the accepted state, consume at most one
  ## recorded close request per level and keep focus inside the topmost level.
  ## Never called from a window callback.
  when defined(leafProtocolProbes):
    echo "TURN dirty=" & $win.overlayDirty & " stack=" & $win.overlayStack.order.len &
      " overlays=" & $win.overlays.len
  win.publishOverlays()
  # One bounded modal geometry pass per ordinary turn when the accepted state is
  # still dirty (a failed bar step or a pending scroll target). No timers, no
  # self-posted retries: the next external turn is the only retry driver.
  if win.overlayDirty:
    let context = win.host.context
    win.layoutOverlays(int(context.scale * 96))
  if win.overlayStack.order.len == 0: return
  var index = win.overlayStack.order.len - 1
  while index >= 0:
    let root = NodeHandle(win.overlayStack.order[index])
    let overlay = win.overlays.getOrDefault(root)
    if overlay != nil:
      var source: OverlayDismiss
      if overlay.takeRequest(source):
        win.queueDismiss(root, source)
      if overlay.needsLayout: win.dirty = true
    dec index
  let top = NodeHandle(win.overlayStack.topOverlay)
  let overlay = win.overlays.getOrDefault(top)
  if overlay == nil or not overlay.isVisible: return
  let scrollRequest = overlay.takeScroll()
  let barRequest = overlay.takeOverlayScrollbar()
  var plan = win.overlayAcceptedPlans.getOrDefault(top)
  let dpiScale = if win.host.context.scale > 0.0: win.host.context.scale else: 1.0
  var changed = false
  if plan.geom.rangeY > 0.0:
    var requestedY = plan.scrollY
    if barRequest.hasAbsolutePx and barRequest.vertical:
      # Thumb track / Home / End: the 32-bit nTrackPos is the latest intent.
      requestedY = barRequest.absolutePx / dpiScale
    elif barRequest.pageDir != 0 and barRequest.vertical:
      requestedY += float64(barRequest.pageDir) * plan.geom.viewportHeight
    elif barRequest.px != 0.0 and barRequest.vertical:
      requestedY += barRequest.px / dpiScale
    elif scrollRequest.hasAbsolute:
      requestedY = if scrollRequest.absolute < 0.0: 0.0 else: plan.geom.rangeY
    elif scrollRequest.notches != 0.0:
      # Wheel notches accumulate in the host; three 24 DIP lines per notch.
      requestedY += scrollRequest.notches * 72.0
    let movedY = clamp(requestedY, 0.0, plan.geom.rangeY)
    if movedY != plan.scrollY:
      plan.scrollY = movedY
      changed = true
  if plan.geom.rangeX > 0.0:
    var requestedX = plan.scrollX
    if barRequest.hasAbsolutePx and not barRequest.vertical:
      requestedX = barRequest.absolutePx / dpiScale
    elif barRequest.pageDir != 0 and not barRequest.vertical:
      requestedX += float64(barRequest.pageDir) * plan.geom.viewportWidth
    elif barRequest.px != 0.0 and not barRequest.vertical:
      requestedX += barRequest.px / dpiScale
    let movedX = clamp(requestedX, 0.0, plan.geom.rangeX)
    if movedX != plan.scrollX:
      plan.scrollX = movedX
      changed = true
  if changed:
    # The plan carries the requested offset; the geometry mirrors it so the
    # same candidate is used by the commit below.
    plan.geom.scrollX = plan.scrollX
    plan.geom.scrollY = plan.scrollY

    win.overlayAcceptedPlans[top] = plan
    # Commit in this ordinary turn so wheel, keys and bar input are visible
    # immediately through the same single geometry pass.
    let context = win.host.context
    win.relayout(DipSize(width: context.contentWidth, height: context.contentHeight),
      int(context.scale * 96))

  let tabRequest = overlay.takeTab()
  if tabRequest != 0: win.tabFocus(top, tabRequest)
  let surface = overlay.surfaceHandle
  let focus = GetFocus()
  # GetFocus is thread-local. An empty focus is not evidence that our modal
  # group owns the foreground; do not activate it over an unrelated window.
  let reference = if focus != nil: focus else: GetForegroundWindow()
  let focusRoot = if reference != nil: ancestorRoot(reference, 2) else: nil
  if focus != nil and focusRoot == surface: return
  var ours = focusRoot != nil and focusRoot == win.host.windowHandle
  if not ours and focusRoot != nil:
    for _, level in win.overlays:
      if level.surfaceHandle == focusRoot:
        ours = true
        break
  if not ours: return
  let target = win.planInitialFocus(top)
  if target != nil: discard SetFocus(target)

proc listWindow(win: Win32Backend, owner: uint64): HWND =
  ## Parent window of a parked group's root: the viewport that owns it.
  if owner == 0: return nil
  for handle, control in win.controls:
    if handle.raw == owner and control.window != nil: return control.window
  for handle, control in win.retiring:
    if handle.raw == owner and control.window != nil: return control.window
  for handle, list in win.lists:
    if handle.raw == owner: return list.window
  nil

proc depthIn(window: HWND, parents: Table[uint64, uint64],
             limit: int): int {.raises: [].} =
  ## Depth inside the owned entry graph. A parent outside the pass stops the walk
  ## and the limit (entry count) bounds a cycle instead of clamping the depth.
  var current = uint64(cast[uint](window))
  var guard = 0
  while guard <= limit:
    let parent = parents.getOrDefault(current, 0)
    if parent == 0 or parent == current: break
    inc result
    current = parent
    inc guard

proc noteFailure(first: var ref CatchableError, group: ResGroup,
                 failure: ref CatchableError) =
  ## Store the original exception ref and the group's secondary first. No string
  ## concatenation or allocation happens while an authoritative transition may
  ## still be pending.
  if group != nil and group.secondary == nil: group.secondary = failure
  if first == nil: first = failure

proc controlEntries(win: Win32Backend, includeStaged: bool): seq[ResEntry] =
  ## Non-owning view over the entries of controls that are not group-owned.
  var seen: HashSet[uint64]
  for handle, control in win.controls:
    if control.entry == nil or control.entry.window == nil: continue
    let identity = uint64(cast[uint](control.entry.window))
    if identity in seen: continue
    seen.incl(identity)
    result.add(control.entry)
  for handle, control in win.retiring:
    if control.entry == nil or control.entry.window == nil: continue
    let identity = uint64(cast[uint](control.entry.window))
    if identity in seen: continue
    seen.incl(identity)
    result.add(control.entry)
  for handle, control in win.prepared:
    if control.staged and not includeStaged: continue
    if control.entry == nil or control.entry.window == nil: continue
    let identity = uint64(cast[uint](control.entry.window))
    if identity in seen: continue
    seen.incl(identity)
    result.add(control.entry)

proc preparedEntries(win: Win32Backend): seq[ResEntry] =
  var seen: HashSet[uint64]
  for handle, control in win.prepared:
    if control.staged or control.entry == nil or control.entry.window == nil:
      continue
    let identity = uint64(cast[uint](control.entry.window))
    if identity in seen: continue
    seen.incl(identity)
    result.add(control.entry)

proc releaseResources(win: Win32Backend, owner: uint64, allGroups: bool,
                      extra: seq[ResEntry]): ref CatchableError =
  ## Release the entries of the in-scope groups plus `extra` control entries,
  ## child-first. Authority is the entry phase: a successful native BOOL updates
  ## it as the very first step. A BOOL 0 / CatchableError keeps the entry,
  ## records the original ref and blocks every ancestor; independent siblings
  ## continue. Defect is never caught. The finish step only drops groups whose
  ## entries all ended; it never decides that a window was released.
  var first: ref CatchableError
  var entries: seq[ResEntry]
  var entryGroups: seq[ResGroup]
  var indexByWindow: Table[uint64, int]
  var parents: Table[uint64, uint64]
  for group in win.resources.groups:
    if not (allGroups or group.owner == owner): continue
    for entry in group.entries:
      if entry.window == nil: continue
      let identity = uint64(cast[uint](entry.window))
      if indexByWindow.hasKey(identity): continue
      indexByWindow[identity] = entries.len
      parents[identity] = uint64(cast[uint](entry.parent))
      entries.add(entry)
      entryGroups.add(group)
  for entry in extra:
    if entry == nil or entry.window == nil: continue
    let identity = uint64(cast[uint](entry.window))
    if indexByWindow.hasKey(identity): continue
    indexByWindow[identity] = entries.len
    parents[identity] = uint64(cast[uint](entry.parent))
    entries.add(entry)
    entryGroups.add(nil)
  # The typed store is the Nim root: enumerate it (not only the groups) and
  # retire bindings whose native side already ended or never got a window. This
  # covers a general control's interrupted Nim cleanup and a failed creation;
  # a live native entry keeps its binding untouched.
  var endedBindings: seq[ResEntry]
  var windowlessTokens: seq[uint64]
  var orphanTokens: seq[uint64]
  for token, control in win.bindings:
    if control.entry != nil:
      if control.entry.phase == epEnded: endedBindings.add(control.entry)
      elif control.entry.window == nil: windowlessTokens.add(control.bindingToken)
    elif control.window == nil:
      orphanTokens.add(token)
  for entry in endedBindings: win.retireBinding(entry)
  for token in windowlessTokens: win.retireOrphanBinding(token)
  for token in orphanTokens: win.retireOrphanBinding(token)
  for group in win.resources.groups:
    if not (allGroups or group.owner == owner): continue
    for entry in group.entries:
      if entry.phase == epEnded and entry.token != 0: win.retireBinding(entry)
  var blocked = newSeq[bool](entries.len)
  var order = newSeq[int](entries.len)
  for index in 0 ..< entries.len: order[index] = index
  order.sort(proc(a, b: int): int =
    let byDepth = cmp(depthIn(entries[b].window, parents, entries.len),
                      depthIn(entries[a].window, parents, entries.len))
    if byDepth != 0: byDepth
    else: cmp(uint64(cast[uint](entries[b].window)),
              uint64(cast[uint](entries[a].window))))
  proc blockAncestorsOf(entry: ResEntry) =
    var current = uint64(cast[uint](entry.window))
    var guard = 0
    while guard <= entries.len:
      let parent = parents.getOrDefault(current, 0)
      if parent == 0 or parent == current: return
      let parentIndex = indexByWindow.getOrDefault(parent, -1)
      if parentIndex < 0: return
      blocked[parentIndex] = true
      current = parent
      inc guard
  var retirement: seq[int]
  for index in 0 ..< entries.len:
    if entries[index].phase != epEnded and entries[index].subclassed:
      retirement.add(index)
  retirement.sort(proc(a, b: int): int =
    let controlA = win.controlFor(entries[a].token)
    let controlB = win.controlFor(entries[b].token)
    let viewportA = controlA != nil and controlA.viewport
    let viewportB = controlB != nil and controlB.viewport
    let byViewport = cmp(ord(viewportB), ord(viewportA))
    if byViewport != 0: byViewport
    else: cmp(uint64(cast[uint](entries[b].window)),
              uint64(cast[uint](entries[a].window))))
  for index in retirement:
    let entry = entries[index]
    if entry.phase == epEnded or not entry.subclassed: continue
    let lease = win.controlFor(entry.token)
    let remover = if lease != nil and lease.viewport: listProc else: controlProc
    var ok = false
    try:
      ok = win.calls.removeSubclass(cast[HWND](entry.window), remover, entry.cookie) != 0
    except CatchableError as error:
      noteFailure(first, entryGroups[index], error)
      blockAncestorsOf(entry)
      continue
    if not ok:
      noteFailure(first, entryGroups[index], captureNative("RemoveWindowSubclass"))
      blockAncestorsOf(entry)
      continue
    # First authoritative step, then stop routing only. A general (non-park)
    # release keeps the typed binding, its capture and the reverse entry link
    # rooted until the window really ends in stage 2: deleting them here would
    # lose the only enumerable owner when stage 2 fails and would leave a stale
    # window on the typed view when it succeeds.
    noteSubclassRemoved(entry)
    if lease != nil:
      controlsByCookie.del(lease.cookie)
      listsByCookie.del(lease.cookie)
      lease.subclassed = false
      lease.armed = false
  for index in order:
    let entry = entries[index]
    if entry.phase == epEnded: continue
    if blocked[index]: continue
    if entry.subclassed: continue          # remover failed; ancestors blocked
    var ok = false
    try:
      win.annotations.clear(cast[HWND](entry.window))
      ok = win.calls.destroyWindow(cast[HWND](entry.window)) != 0
    except CatchableError as error:
      noteFailure(first, entryGroups[index], error)
      blockAncestorsOf(entry)
      continue
    if not ok:
      noteFailure(first, entryGroups[index], captureNative("DestroyWindow"))
      blockAncestorsOf(entry)
      continue
    # First authoritative step (scalar on the stable entry), then the Nim
    # cleanup under the store lease; the store entry is deleted last.
    noteWindowEnded(entry)
    inc win.stats.destroys
    let lease = win.controlFor(entry.token)
    if lease != nil:
      finalizeControl(lease)
      win.forgetControl(lease)
    win.unbindControl(entry.token)
    entry.token = 0
  # Finish: only groups whose entries all ended leave the registry.
  var groupIndex = 0
  while groupIndex < win.resources.groups.len:
    let group = win.resources.groups[groupIndex]
    if (allGroups or group.owner == owner) and group.allEnded:
      discard win.resources.removeGroup(group)
    else:
      inc groupIndex
  first

proc releasePrepared(win: Win32Backend): ref CatchableError =
  ## Creation views whose window never appeared still hold a typed binding. The
  ## names are collected first: no table/store is mutated while it is iterated
  ## (a Table length change during iteration is an AssertionDefect). Each failed
  ## creation is then closed exactly like an orphan binding: cookie/list-cookie,
  ## capture, reverse entry link, store token and the prepared view together.
  var failedCreations: seq[NodeHandle]
  for handle, control in win.prepared:
    if control.staged: continue
    if control.entry == nil or control.entry.window == nil:
      failedCreations.add(handle)
  for handle in failedCreations:
    let control = win.prepared.getOrDefault(handle)
    if control == nil: continue
    let token = control.bindingToken
    win.retireOrphanBinding(token)
    control.bindingToken = 0
    win.prepared.del(handle)
  win.releaseResources(0, false, win.preparedEntries)

proc releaseControlTree(win: Win32Backend, root: NativeControl): ref CatchableError =
  when defined(leafProtocolProbes):
    if win.popovers.len != 0:
      echo "RELEASETREE handle=", uint64(root.entity.handle), " body=",
        win.popoverBody(root.entity.handle)
  ## Release one control's native subtree child-first; a viewport also hands its
  ## parked and failed groups to the same primitive.
  var extra: seq[ResEntry]
  var seen: HashSet[uint64]
  var wanted: HashSet[uint64]
  if root.window != nil: wanted.incl(uint64(cast[uint](root.window)))
  var all: seq[tuple[handle: NodeHandle, control: NativeControl]]
  for handle, control in win.controls: all.add((handle, control))
  for handle, control in win.retiring: all.add((handle, control))
  for handle, control in win.prepared: all.add((handle, control))
  var changed = true
  while changed:
    changed = false
    for item in all:
      let control = item.control
      if control.window == nil: continue
      let identity = uint64(cast[uint](control.window))
      if identity in wanted: continue
      if uint64(cast[uint](control.parentWindow)) in wanted:
        wanted.incl(identity)
        changed = true
  for item in all:
    let control = item.control
    if control.entry == nil or control.entry.window == nil: continue
    if uint64(cast[uint](control.window)) notin wanted: continue
    let identity = uint64(cast[uint](control.entry.window))
    if identity in seen: continue
    seen.incl(identity)
    extra.add(control.entry)
  var owner = 0'u64
  if root.viewport: owner = root.entity.handle.raw
  win.releaseResources(owner, false, extra)

proc syncFocusedListTraversal(win: Win32Backend, focus: HWND) =
  # WS_EX_CONTROLPARENT makes USER32's dialog/default-button search safe when
  # focus is *inside* a row. Keeping it on globally would skip the viewport's
  # own Tab/arrow entry. Change it before native focus handlers run, using the
  # incoming focus (WM_KILLFOCUS.wParam), not a stale GetFocus() observation.
  for list in win.lists.values:
    var childFocus = false
    var parent = if focus != nil: GetParent(focus) else: nil
    var depth = 0
    while parent != nil and depth <= MaxDepth:
      if parent == list.window:
        childFocus = true
        break
      parent = GetParent(parent)
      inc depth
    let current = GetWindowLongW(list.window, -20)
    let desired = if childFocus: current or 0x00010000
      else: current and not 0x00010000
    if desired != current:
      setLastError(0)
      if win.calls.setWindowData(list.window, -20, int(desired)) == 0 and lastError() != 0:
        nativeError("SetWindowLongPtrW viewport focus traversal")

proc releasePointerCapture(control: NativeControl) =
  if GetCapture() == control.window and ReleaseCapture() == 0:
    nativeError("Canvas ReleaseCapture")

proc queuePointer(win: Win32Backend, control: NativeControl, event: CanvasPointerEvent): bool =
  var listened = false
  for token in event.sourceRouteInternal:
    if (token.mask and (1'u32 shl ord(event.kind))) != 0: listened = true
  if not listened: return false
  inc win.sequence
  result = win.session.enqueue(EventEnvelope(session: win.sessionId,
    mountGeneration: win.generation, bindingGeneration: control.binding,
    handle: control.handle, sequence: win.sequence, observedRevision: win.revision,
    source: sourceUser, event: Event(kind: EventKind.canvasInput,
      canvas: nativeCanvasDeliveryInternal(event))))
  discard PostMessageW(win.host.windowHandle, WM_HOST_TICK, 0, 0)

proc flushPointer(win: Win32Backend, control: NativeControl) =
  for event in control.pointerMachine.drain():
    discard win.queuePointer(control, event)
  if not control.pointerMachine.captureWanted:
    control.pointerOwner = none(CanvasBindingId)
    control.releasePointerCapture()

proc currentPointerTarget(control: NativeControl): Option[PointerTarget] =
  if control.pointerOwner.isNone: return none(PointerTarget)
  let id = control.pointerOwner.get
  if not control.canvas.inputBindingAlive(id):
    control.pointerMachine.retire(id)
    return none(PointerTarget)
  result = control.canvas.inputTarget(id)
  if result.isNone or result.get.parentFromCanvas.inverse.isNone or result.get.localFromCanvas.inverse.isNone:
    control.pointerMachine.cancel(PointerCancelReason.nonInvertible)
    result = none(PointerTarget)

proc pointerModifiers(wp: WPARAM, mouse: bool): set[PointerModifier] =
  if (mouse and (wp and 4) != 0) or (not mouse and GetKeyState(16) < 0): result.incl(PointerModifier.shift)
  if (mouse and (wp and 8) != 0) or (not mouse and GetKeyState(17) < 0): result.incl(PointerModifier.control)
  if GetKeyState(18) < 0: result.incl(PointerModifier.alt)
  if GetKeyState(91) < 0 or GetKeyState(92) < 0: result.incl(PointerModifier.meta)

proc rawPointer(win: Win32Backend, control: NativeControl, target: Option[PointerTarget],
    kind: PointerEventKind, sample: PointerSample, wheelDelta = vec2(0, 0),
    keyCode = 0'u32, keyRepeat = false): bool =
  if target.isSome:
    result = win.queuePointer(control, rawCanvasEventInternal(target.get, kind, sample,
      wheelDelta, keyCode, keyRepeat))

proc capturePointer(win: Win32Backend, control: NativeControl, message: UINT,
    wp: WPARAM, lp: LPARAM): bool =
  if control.pointerMachine == nil or not control.armed or win.session == nil or
      win.session.closing or win.session.disposed or win.session.faulted: return false
  case message
  of 0x0200'u32, 0x0201'u32, 0x0202'u32, 0x0203'u32, 0x0204'u32, 0x0205'u32,
      0x0206'u32, 0x0207'u32, 0x0208'u32, 0x0209'u32:
    var point = POINT(x: int32(cast[int16](lp and 0xffff)), y: int32(cast[int16]((lp shr 16) and 0xffff)))
    if ClientToScreen(control.window, addr point) == 0: nativeError("Canvas ClientToScreen")
    var sample = PointerSample(pointerId: 1, button: PointerButton.primary,
      screenPosition: vec2(float64(point.x), float64(point.y)), modifiers: pointerModifiers(wp, true))
    if (wp and 1) != 0: sample.buttons.incl(PointerButton.primary)
    if (wp and 2) != 0: sample.buttons.incl(PointerButton.secondary)
    if (wp and 16) != 0: sample.buttons.incl(PointerButton.middle)
    if message in [0x0204'u32, 0x0205'u32, 0x0206'u32]: sample.button = PointerButton.secondary
    elif message in [0x0207'u32, 0x0208'u32, 0x0209'u32]: sample.button = PointerButton.middle
    control.lastPointer = sample
    let hit = control.canvas.pointerAtScreen(sample.screenPosition)
    # STATIC uses CS_DBLCLKS: the second down arrives as *_DBLCLK.
    if message in [0x0201'u32, 0x0203'u32, 0x0204'u32, 0x0206'u32, 0x0207'u32, 0x0209'u32]:
      if control.canvas.acceptedFrame.focusable:
        discard SetFocus(control.window)
      discard win.rawPointer(control, hit, PointerEventKind.pointerDown, sample)
      if hit.isSome:
        control.pointerMachine.press(sample, hit.get)
        if control.pointerMachine.captureWanted:
          control.pointerOwner = some(hit.get.id)
          discard SetCapture(control.window)
          if GetCapture() != control.window: fail("Canvas mouse capture failed")
    elif message == 0x0200:
      if not control.trackingMouse:
        var tracking = MouseTracking(cbSize: DWORD(sizeof(MouseTracking)), dwFlags: 2, hwndTrack: control.window)
        if TrackMouseEvent(addr tracking) == 0: nativeError("Canvas TrackMouseEvent")
        control.trackingMouse = true
      let captured = control.currentPointerTarget()
      discard win.rawPointer(control, (if captured.isSome: captured else: hit), PointerEventKind.pointerMove, sample)
      control.pointerMachine.move(sample, captured)
      control.pointerMachine.updateHover(sample, control.canvas.hoverAtScreen(sample.screenPosition))
    else:
      let captured = control.currentPointerTarget()
      discard win.rawPointer(control, (if captured.isSome: captured else: hit), PointerEventKind.pointerUp, sample)
      control.pointerMachine.release(sample, captured,
        (if hit.isSome: some(hit.get.id) else: none(CanvasBindingId)))
    win.flushPointer(control)
    true
  of WM_MOUSEWHEEL, 0x020E'u32:
    var sample = PointerSample(pointerId: 1, screenPosition: vec2(
      float64(cast[int16](lp and 0xffff)), float64(cast[int16]((lp shr 16) and 0xffff))),
      modifiers: pointerModifiers(wp, true))
    if (wp and 1) != 0: sample.buttons.incl(PointerButton.primary)
    if (wp and 2) != 0: sample.buttons.incl(PointerButton.secondary)
    if (wp and 16) != 0: sample.buttons.incl(PointerButton.middle)
    let amount = float64(cast[int16]((wp shr 16) and 0xffff))/120
    let delta = if message == WM_MOUSEWHEEL: vec2(0, amount) else: vec2(amount, 0)
    win.rawPointer(control, control.canvas.pointerAtScreen(sample.screenPosition), PointerEventKind.wheel, sample, delta)
  of WM_KEYDOWN, 0x0104'u32:
    if wp == 9 or (message == 0x0104 and wp == 115): return false # Native Tab / Alt+F4.
    if not control.canvas.acceptedFrame.focusable or GetFocus() != control.window: return false
    var sample = PointerSample(modifiers: pointerModifiers(0, false))
    var point: POINT
    if GetCursorPos(addr point) == 0: nativeError("Canvas keyboard pointer position")
    sample.screenPosition = vec2(float64(point.x), float64(point.y))
    win.rawPointer(control, control.canvas.rootInputTarget(), PointerEventKind.keyDown, sample,
      keyCode=uint32(wp), keyRepeat=(lp and (1 shl 30)) != 0)
  of WM_GETDLGCODE:
    if control.canvas.acceptedFrame.focusable: return false
    false
  of 0x02A3'u32: # WM_MOUSELEAVE
    control.trackingMouse = false
    control.pointerMachine.updateHover(control.lastPointer, [])
    win.flushPointer(control)
    true
  of 0x0215'u32, 0x001F'u32, 0x0008'u32: # CAPTURECHANGED / CANCELMODE / KILLFOCUS
    control.pointerMachine.cancel(if message == 0x0008: PointerCancelReason.focusLost else: PointerCancelReason.captureLost)
    win.flushPointer(control)
    false
  else: false

proc captureControl(win: Win32Backend, control: NativeControl, message: UINT,
                    wp: WPARAM, lp: LPARAM): LRESULT =
  try:
    if message == 0x003D and cast[int32](lp) == -25 and control.live != nil:
      return control.live.objectResult(wp, lp)
    if message == 0x003D and cast[int32](lp) == -25 and
        IsWindowVisible(control.window) != 0:
      # A select trigger answers with the dedicated select provider instead of
      # the stock BUTTON proxy. Every other control keeps its stock provider.
      # A hidden trigger keeps the stock proxy: publishing a provider for a
      # hidden control deadlocks the UI thread inside UiaReturnRawElementProvider.
      let root = win.selectRootOf(control.entity.handle)
      let selectHost = win.selects.getOrDefault(root)
      if selectHost != nil:
        let answer = selectHost.triggerObjectResult(wp, lp)
        if answer != 0: return answer
    if control.canvas != nil:
      if message in [0x0007'u32, 0x0008'u32]:
        if InvalidateRect(control.window, nil, 0) == 0: nativeError("Canvas focus invalidation")
      if message == WM_GETDLGCODE and control.canvas.acceptedFrame.focusable:
        return DLGC_WANTARROWS # Never WANTALLKEYS: Tab belongs to USER32.
      if win.capturePointer(control, message, wp, lp): return 0
      if message == 0x0014: return 1 # WM_ERASEBKGND: Direct2D owns all pixels.
      if message == 0x000F: # WM_PAINT: accepted cache only, never an app render.
        let busy = win.depth != 0 or win.applying or win.restoring or
          (win.session != nil and win.session.runtime.installingUpdate)
        control.canvas.handlePaint(busy)
        if control.canvas.needsRebuild:
          discard PostMessageW(win.host.windowHandle, WM_HOST_TICK, 0, 0)
        return 0
    if message == WM_KEYDOWN and control.armed and
        win.popoverKeyFrom(control, int32(wp)):
      return 0
    if message == WM_KEYDOWN and standardRole(control.window) == some(UiRole.popoverTrigger):
      if int32(wp) in [0x0D]:
        if control.armed:
          let root = win.popoverRootOf(control.entity.handle)
          if root != NoHandle:
            when defined(leafProtocolProbes): echo "POPSRC toggle key=", control.entity.nodeId
            win.requestPopoverToggle(root)
        return 0
    if message == WM_KEYDOWN and standardRole(control.window) == some(UiRole.selectTrigger):
      # Enter/F4/Up/Down open the popup; Space stays with the real BUTTON, whose
      # BN_CLICKED becomes the same typed open/close request.
      let key = int32(wp)
      if key in [0x0D, 0x73, 0x26, 0x28]:
        if control.armed:
          let root = win.selectRootOf(control.entity.handle)
          if root != NoHandle: win.requestSelectOpen(root)
        return 0
    if win.theme.isShadcn and message==0x0201 and control.armed and
        standardRole(control.window) in [some(UiRole.inputGroup),some(UiRole.inputGroupAddon),some(UiRole.inputGroupText)]:
      let editor=inputGroupEditor(inputGroupOf(control.window))
      if editor!=nil and IsWindowEnabled(editor)!=0:discard SetFocus(editor)
      return 0
    if win.theme.isShadcn and message in [0x0007'u32,0x0008'u32,0x0128'u32,0x0047'u32]:
      discard PostMessageW(win.host.windowHandle,WM_HOST_TICK,0,0)
    if message == 0x0007: win.syncFocusedListTraversal(control.window) # WM_SETFOCUS
    elif message == 0x0008: win.syncFocusedListTraversal(cast[HWND](wp)) # WM_KILLFOCUS
    var paintReply: LRESULT
    if skinMessage(win.theme, control.window, message, wp, lp, paintReply): return paintReply
    if win.captureNavigation(message, wp, lp):
      return if message == BackAppCommand: 1 else: 0
    if message == WM_COMMAND and win.command(control.window, wp, lp): return 0
    if message == WM_MOUSEWHEEL or message == WM_KEYDOWN:
      let root = win.overlayRootOf(control.entity.handle)
      let topRoot = NodeHandle(win.overlayStack.topOverlay)
      let host = win.overlays.getOrDefault(root)
      if root != NoHandle and root == topRoot and host != nil and
          host.isScrollable():
        if message == WM_MOUSEWHEEL:
          let raw = cast[int16](uint16((wp shr 16) and 0xffff))
          let notches = -float64(raw) / 120.0
          if notches != 0.0:
            host.addWheel(notches)
            return 0
        else:
          let key = int32(wp)
          if key == 0x09: # Tab: keep cycling inside the modal (logical order)
            host.noteTab((GetKeyState(0x10) and 0x8000'i16) != 0)
            return 0
    if message == WM_MOUSEWHEEL:
      var window = GetParent(control.window)
      var depth = 0
      while window != nil and depth <= MaxDepth:
        for list in win.lists.values:
          if list.window == window:
            list.handleWheel(int32(cast[int16](wp shr 16)),
              int(GetDpiForWindow(window)))
            return 0
        window = GetParent(window)
        inc depth
      return win.calls.defaultSubclass(control.window, message, wp, lp)
    if control.entity.kind == NodeKind.input:
      if message == WM_GETDLGCODE and (wp == 13 or (lp != 0 and cast[ptr MSG](lp).wParam == 13)):
        return win.calls.defaultSubclass(control.window, message, wp, lp) or 4
      if message == WM_KEYDOWN and wp == 13 and control.editor.phase == compositionNone and
          not control.entity.props.control.multiline.get(false):
        win.sendEvent(control, submit)
        return 0
      if message == WM_CHAR and wp == 13 and not control.entity.props.control.multiline.get(false): return 0
      let previousPhase = control.editor.phase
      let observedBefore = control.editor.latestObserved
      case message
      of WM_IME_STARTCOMPOSITION: control.editor.phase = compositionStart
      of WM_IME_COMPOSITION:
        control.editor.phase = if (lp and 0x800) != 0: compositionResult else: compositionUpdate
      else: discard
      result = win.calls.defaultSubclass(control.window, message, wp, lp)
      if message == WM_IME_STARTCOMPOSITION or message == WM_IME_COMPOSITION:
        # Default EDIT processing may already send a synchronous EN_CHANGE.
        # Emit a phase-only observation only when that chain did not observe it.
        if control.editor.latestObserved == observedBefore and
            (previousPhase != control.editor.phase or control.readText() != control.editor.native.text):
          win.sendEvent(control, change, control.editor.phase)
      elif message == WM_IME_ENDCOMPOSITION:
        control.editor.phase = compositionEnd
        win.sendEvent(control, change, compositionEnd)
      return
    return win.calls.defaultSubclass(control.window, message, wp, lp)
  except CatchableError as error:
    if control.pointerMachine != nil:
      win.pendingInputFailure = true
      control.pointerMachine = nil
      control.pointerOwner = none(CanvasBindingId)
      if GetCapture() == control.window: discard ReleaseCapture()
      discard PostMessageW(win.host.windowHandle, WM_HOST_TICK, 0, 0)
    win.markError(error)
    return 0

proc rowRootOf(win: Win32Backend, handle: NodeHandle): NodeHandle =
  ## Nearest row root (self included) according to the typed row sidecar.
  var current = handle
  var depth = 0
  while current != NoHandle:
    let entity = win.current.getOrDefault(current, win.controls.getOrDefault(current).entity)
    if entity.handle == NoHandle: return NoHandle
    if entity.row.isSome: return current
    current = entity.parent
    inc depth
    if depth > MaxDepth: return NoHandle
  NoHandle

proc subtreeOrder(win: Win32Backend, entities: Table[NodeHandle, MountedEntity],
                  root: NodeHandle): seq[NodeHandle] =
  ## Pre-order handles of one row subtree (children in accepted sibling order).
  var children: Table[NodeHandle, seq[MountedEntity]]
  for handle, entity in entities:
    if handle == root: continue
    children.mgetOrPut(entity.parent, @[]).add(entity)
  proc walk(parent: NodeHandle, order: var seq[NodeHandle]) =
    ## The owned output is passed explicitly: capturing the enclosing return
    ## slot from a nested proc violates Nim's memory-safety check.
    var kids = children.getOrDefault(parent)
    kids.sort(proc(a, b: MountedEntity): int = cmp(a.index, b.index))
    for child in kids:
      order.add(child.handle)
      walk(child.handle, order)
  result.add(root)
  walk(root, result)

proc rowSignature(win: Win32Backend, entities: Table[NodeHandle, MountedEntity],
                  root: NodeHandle): string =
  let order = win.subtreeOrder(entities, root)
  var kinds: seq[NodeKind]
  var parents: seq[int]
  var multiline: seq[bool]
  var groups: seq[bool]
  var seen: Table[NodeHandle, int]
  for handle in order:
    let entity = entities.getOrDefault(handle)
    if entity.handle == NoHandle: continue
    kinds.add(entity.kind)
    multiline.add(entity.kind == NodeKind.input and entity.props.control.multiline.get(false))
    groups.add(entity.props.standardUi.isSome and entity.props.standardUi.get.role in UiGroupRoles)
    parents.add(if entity.parent in seen: seen[entity.parent] else: -1)
    seen[handle] = kinds.len - 1
  rowSignature(kinds, parents, multiline, groups)

proc shedRow(win: Win32Backend, handle: NodeHandle) =
  ## Keep a removed row descendant hidden and unbound until its row root decides
  ## between parking and destruction; never leaves a stale cookie/subclass.
  let control = win.controls.getOrDefault(handle)
  if control == nil: return
  control.armed = false
  discard win.calls.showWindow(control.window, SW_HIDE)
  win.retiring[handle] = control
  win.controls.del(handle)

proc destroyRetiring(win: Win32Backend, handle: NodeHandle) =
  ## Release one shed descendant through the same child-first primitive; the
  ## owner entry is removed only when its window really went away.
  let control = win.retiring.getOrDefault(handle)
  if control == nil: return
  let first = win.releaseControlTree(control)
  if first != nil: raise first

proc destroyRowSubtree(win: Win32Backend, root: NodeHandle) =
  ## Explicit cleanup owner for a row that cannot be parked: the root, its live
  ## children and its already-shed descendants are released child-first.
  let control = win.controls.getOrDefault(root, win.retiring.getOrDefault(root))
  if control == nil: return
  let first = win.releaseControlTree(control)
  if first != nil: raise first

proc hasRoomForSlot(win: Win32Backend): bool =
  ## The global bound counts every group that still owns windows: parking,
  ## parked, borrowing and failed groups. A failed group is never reusable.
  win.resources.liveGroups() < MaxParkedRows

proc parkRow(win: Win32Backend, root: NodeHandle): bool =
  ## Move a complete row subtree (root + live descendants + descendants already
  ## shed into `retiring`) into a stable owned group. The group is prepared from
  ## the *same* per-window entries and published before the first cookie or
  ## control-table removal; only then are windows hidden/retired. A raise at any
  ## later step leaves the whole group enumerable (phase `gpFailed`).
  let rootControl = win.controls.getOrDefault(root)
  if rootControl == nil or rootControl.window == nil: return false
  var entities: Table[NodeHandle, MountedEntity]
  for handle, control in win.controls:
    if handle == root or win.rowRootOf(handle) == root:
      entities[handle] = control.entity
  for handle, control in win.retiring:
    if win.rowRootOf(handle) == root: entities[handle] = control.entity
  let order = win.subtreeOrder(entities, root)
  if order.len != entities.len: return false
  # Validate before any ownership change.
  let focused = win.calls.focusWindow()
  for handle in order:
    let control = win.controls.getOrDefault(handle, win.retiring.getOrDefault(handle))
    if control == nil or control.window == nil: return false
    if focused != nil and control.window == focused: return false
    if control.entity.kind == NodeKind.input and
        control.editor.phase != compositionNone: return false
  if not win.hasRoomForSlot(): return false
  # Prepare: the group keeps the same per-window authority entries; nothing is
  # moved or removed yet, so a failure here changes no owner.
  var group = newGroup(rootControl.entity.row.get.listHandle.raw,
                       win.rowSignature(entities, root))
  for handle in order:
    let control = win.controls.getOrDefault(handle, win.retiring.getOrDefault(handle))
    if control == nil or control.window == nil: return false
    var entry = control.entry
    if entry == nil:
      entry = newEntry(cast[pointer](control.window),
        cast[pointer](control.parentWindow), handle, control.cookie, 0'u64,
        control.subclassed, token = control.bindingToken)
      control.entry = entry
    group.attachEntry(entry)
  group.root = group.entries[0].window
  win.resources.reservePublish()
  # Publish the single owner BEFORE the first cookie/control-map removal. This
  # step only stores the phase and the group ref, so it cannot fail.
  if not publishOwner(win.resources, group, gpParking):
    return false
  for handle in order:
    win.controls.del(handle)
    win.retiring.del(handle)
  # Retire subclass identities and hide the windows. ShowWindow returns the
  # *previous* visibility, so only a raised CatchableError is a failure.
  try:
    for entry in group.entries:
      # The store still roots the old control; the lease keeps it alive across
      # every deletion below and is dropped after the last access.
      let lease = win.controlFor(entry.token)
      if lease != nil: lease.armed = false
      if entry.subclassed:
        if win.calls.removeSubclass(cast[HWND](entry.window), controlProc,
            entry.cookie) == 0:
          raise captureNative("RemoveWindowSubclass parked row")
        # First the authoritative native progress, then the old binding is
        # retired: an alive HWND is never marked ended here.
        noteSubclassRemoved(entry)
        if lease != nil:
          controlsByCookie.del(lease.cookie)
          lease.subclassed = false
          lease.capture = nil
          lease.entry = nil
        win.unbindControl(entry.token)
        entry.token = 0
      discard win.calls.showWindow(cast[HWND](entry.window), SW_HIDE)
  except CatchableError as error:
    group.phase = gpFailed
    if group.primary == nil: group.primary = error
    raise error
  group.phase = gpParked
  true

proc abandonBorrow(win: Win32Backend, group: ResGroup,
                   primary: ref CatchableError) {.raises: [].} =
  ## Keep a failed hand-over enumerable and retryable: withdraw only installed
  ## subclass identities that could be removed. A refused remover keeps its exact
  ## cookie/callback/id (and its secondary error) so cleanup retries precisely
  ## that identity; nothing is destroyed here and `primary` keeps its object
  ## identity and text.
  var secondary: ref CatchableError
  for entry in group.entries:
    let lease = win.controlFor(entry.token)
    if lease != nil: lease.armed = false
    if not entry.subclassed: continue
    try:
      if win.calls.removeSubclass(cast[HWND](entry.window), controlProc,
          entry.cookie) != 0:
        noteSubclassRemoved(entry)
        if lease != nil:
          controlsByCookie.del(lease.cookie)
          lease.subclassed = false
          lease.capture = nil
          lease.entry = nil
        win.unbindControl(entry.token)
        entry.token = 0
      else:
        if secondary == nil:
          secondary = captureNative("RemoveWindowSubclass abandoned row")
    except CatchableError as error:
      if secondary == nil: secondary = error
  if group.secondary == nil: group.secondary = secondary
  group.primary = primary
  group.phase = gpFailed

proc attachParkedRow(win: Win32Backend, root: NodeHandle): bool =
  ## Re-key a parked group for the candidate row: fresh command id, GWLP_ID,
  ## subclass and editor state (no transient/selection/IME carry-over).
  ##
  ## The group stays the single owner of every HWND until the whole group is
  ## re-keyed; the controls are progress and point at the same entries. On
  ## failure the group keeps slot identity, cookies, callbacks, remover progress
  ## and the primary/secondary errors, and is never reusable. Success stages the
  ## prepared views (allocating inserts) while the group still owns them; the
  ## commit only flips flags and drops the group record.
  let group = win.borrowGroup
  if group == nil: return false
  let order = win.subtreeOrder(win.candidate, root)
  if order.len != group.entries.len:
    group.phase = gpFailed
    if group.primary == nil:
      group.primary = newException(UiError, "stale parked row topology")
    return false
  try:
    for index, handle in order:
      let entity = win.candidate.getOrDefault(handle)
      if entity.handle == NoHandle:
        raise newException(UiError, "stale parked row entity")
      inc nextCookie
      if nextCookie == 0: fail("native control cookie space exhausted")
      let entry = group.entries[index]
      var control = NativeControl(cookie: nextCookie,
        commandId: win.controlIds.allocate(), window: cast[HWND](entry.window),
        # The reused HWND still holds the *previous* row's OS state. Never seed
        # the editor with the new value as if the OS already showed it; `fresh`
        # forces a complete real setter pass on the next apply.
        parentWindow: cast[HWND](entry.parent), handle: entity.handle, owner: win,
        entry: entry, entity: entity, editor: newEditorState(ControlValue()),
        fresh: true)
      control.capture = proc(c: NativeControl, msg: UINT, wp: WPARAM, lp: LPARAM): LRESULT =
        win.captureControl(c, msg, wp, lp)
      # Root the new binding in the typed store before SetCtrlId/SetSubclass.
      entry.token = win.bindControl(control)
      entry.handle = handle
      controlsByCookie[control.cookie] = control
      # GWLP_ID is a metadata insert: SetWindowLongPtrW returns the previous id
      # (0 is legal), so only a 0 return together with an immediately readable
      # last-error is a failure. Never swallow the BOOL answer.
      setLastError(0)
      let previous = win.calls.setCtrlId(control.window, int(control.commandId))
      if previous == 0 and lastError() != 0:
        fail("SetWindowLongPtrW GWLP_ID failed: " & $lastError())
      if win.calls.setSubclass(control.window, controlProc, control.cookie, control.cookie) == 0:
        nativeError("SetWindowSubclass reused row")
      noteSubclassInstalled(entry, control.cookie, cast[uint](controlProc))
      control.subclassed = true
      discard win.calls.send(control.window, WM_SETFONT,
        cast[WPARAM](win.measurement.ensureFont(win.fontRole(control.entity))), 0)
      # ShowWindow returns the previous visibility; only a raise is a failure.
      discard win.calls.showWindow(control.window, SW_HIDE)
  except CatchableError as error:
    win.abandonBorrow(group, error)
    raise error
  # Whole group ready: stage the prepared views while the group still owns every
  # window, then commit (drop the group record; the controls keep the entries).
  for index, handle in order:
    let control = win.controlFor(group.entries[index].token)
    control.staged = true
    win.prepared[handle] = control
  for entry in group.entries:
    let control = win.controlFor(entry.token)
    if control != nil: control.staged = false
  discard win.resources.removeGroup(group)
  win.borrowGroup = nil
  inc win.reusedBorrows
  true

proc makeControl(win: Win32Backend, entity: MountedEntity): NativeControl =
  if win.prepared.hasKey(entity.handle): return win.prepared[entity.handle]
  var className = "STATIC"
  var exStyle = 0'u32
  var style = WS_CHILD or WS_CLIPSIBLINGS
  case entity.kind
  of NodeKind.column, NodeKind.row, NodeKind.navigation:
    style = style or WS_CLIPCHILDREN
    if entity.overlay.isSome: style = style or WS_TABSTOP
    exStyle = 0x00010000'u32 # WS_EX_CONTROLPARENT: recursive native tab traversal
  of NodeKind.virtualList:
    # A real scrollable viewport: Unicode child window owning its row subtrees.
    # WS_TABSTOP puts it in the native tab order so it can hold real keyboard
    # focus; without it the arrows below could never reach this window.
    style = style or WS_VSCROLL or WS_CLIPCHILDREN or WS_TABSTOP
  of NodeKind.canvasHost:
    style = style or 0x100'u32 # SS_NOTIFY: receive physical mouse input, not HTTRANSPARENT.
    if entity.canvas.isSome and entity.canvas.get.focusable: style = style or WS_TABSTOP
  of NodeKind.text, NodeKind.tag: style = style or SS_NOPREFIX
  of NodeKind.button: className = "BUTTON"; style = style or WS_TABSTOP
  of NodeKind.input:
    className = "EDIT"
    style = style or WS_TABSTOP
    if entity.props.control.multiline.get(false):
      style = style or 4'u32 or 0x40'u32 or 0x1000'u32 or WS_VSCROLL
    else:
      style = style or 0x80'u32
    # EDIT snapshots WS_BORDER into internal state at creation, then clears the
    # public bit. Removing it later does not remove its client-area border.
    if win.theme == systemTheme or highContrastActive(): style = style or WS_BORDER
  of NodeKind.checkbox, NodeKind.toggle:
    className = "BUTTON"; style = style or WS_TABSTOP or BS_AUTOCHECKBOX
  of NodeKind.progress: className = "msctls_progress32"
  of NodeKind.spinner: className = "msctls_progress32"; style = style or PBS_MARQUEE
  of NodeKind.separator:
    if entity.props.standardUi.isNone: style = style or SS_ETCHEDHOR
  if entity.props.standardUi.isSome and entity.props.standardUi.get.role in UiGroupRoles:
    className = "BUTTON"
    style = style or 7'u32 # BS_GROUPBOX: stock UIA Group, retaining native child hierarchy.
  if entity.props.standardUi.isSome and entity.props.standardUi.get.role==UiRole.inputGroupText:
    style=style or 0x100'u32 # SS_NOTIFY: actual addon text receives mouse focus intent.
  # Exactly one native parent is selected here. A popover panel body and a modal
  # surface are never page children, so neither may be overwritten by the generic
  # parent branch below (that was the mount bug: the body was parented to the
  # page even after the panel handle was resolved).
  var parent: HWND
  var parentChosen = false
  if entity.props.standardUi.isSome and
      entity.props.standardUi.get.role == UiRole.popoverContent:
    let hostParent = win.popoverContentParent(entity)
    if hostParent == nil:
      fail("popover content requires its panel window: " & entity.nodeId)
    parent = hostParent
    parentChosen = true
  if entity.overlay.isSome:
    if parentChosen:
      fail("popover content cannot also be a modal surface: " & entity.nodeId)
    # A modal level lives in its own owned window, never inside the page.
    parent = win.ensureOverlayHost(entity).surfaceHandle
    parentChosen = true
  if not parentChosen:
    parent = win.host.windowHandle
    if entity.parent != NoHandle:
      if entity.parent in win.prepared: parent = win.prepared[entity.parent].window
      elif entity.parent in win.controls: parent = win.controls[entity.parent].window
      else: fail("native control parent not prepared")
  inc nextCookie
  if nextCookie == 0: fail("native control cookie space exhausted")
  let entry = newEntry(nil, cast[pointer](parent), entity.handle, nextCookie,
    0'u64, false)
  let control = NativeControl(cookie: nextCookie, commandId: win.controlIds.allocate(),
    parentWindow: parent, entity: entity, handle: entity.handle, owner: win,
    entry: entry, editor: newEditorState(entity.value))
  control.capture = proc(c: NativeControl, msg: UINT, wp: WPARAM, lp: LPARAM): LRESULT =
    win.captureControl(c, msg, wp, lp)
  # The typed binding and the creation view are both rooted before the window
  # (and any callback) exists, so a create failure is enumerable from either.
  entry.token = win.bindControl(control)
  win.prepared[entity.handle] = control
  controlsByCookie[control.cookie] = control
  let cls = checkedWide(className)
  # A modal level's accessible name lives on the surface window (UIA Name); the
  # container STATIC must not also paint it as a stock caption.
  let controlLabel = if entity.overlay.isSome or
      (entity.props.standardUi.isSome and entity.props.standardUi.get.role in
        {UiRole.popover, UiRole.popoverContent}): "" else: entity.label
  let title = checkedWide(controlLabel)
  control.window = win.calls.createWindow(exStyle, unsafeAddr cls[0], unsafeAddr title[0], style,
    0, 0, 0, 0, parent, cast[HMENU](uint(control.commandId)), GetModuleHandleW(nil), nil)
  if control.window == nil: nativeError("CreateWindowExW control")
  setEntryWindow(entry, cast[pointer](control.window), cast[pointer](parent))
  inc win.stats.creates
  if entity.kind == NodeKind.virtualList:
    if entity.list.isNone: fail("virtual list has no list metadata")
    var list = newListHost(entity.handle, control.window, entity.list.get, win.calls)
    list.wake = proc() = discard PostMessageW(win.host.windowHandle, WM_HOST_TICK, 0, 0)
    list.commands = proc(receiver: HWND, wp: WPARAM, lp: LPARAM): bool =
      win.command(receiver, wp, lp)
    win.lists[entity.handle] = list
    listsByCookie[control.cookie] = list
    if win.calls.setSubclass(control.window, listProc, control.cookie, control.cookie) == 0:
      nativeError("SetWindowSubclass viewport")
    noteSubclassInstalled(entry, control.cookie, cast[uint](listProc))
    control.viewport = true
  else:
    if win.calls.setSubclass(control.window, controlProc, control.cookie, control.cookie) == 0:
      nativeError("SetWindowSubclass")
    noteSubclassInstalled(entry, control.cookie, cast[uint](controlProc))
  control.subclassed = true
  discard win.calls.send(control.window, WM_SETFONT,
    cast[WPARAM](win.measurement.ensureFont(win.fontRole(entity))), 0)
  win.arm(control)
  control.armed = false
  if entity.kind == NodeKind.input and entity.props.control.resetToken.isSome:
    control.editor.acceptModel(entity.value, 0, entity.props.control.resetToken)
    control.editor.completeReset(entity.props.control.resetToken.get)
  if entity.kind == NodeKind.canvasHost:
    control.canvas = newCanvasSurface(control.window, win.renderer)
    let dpi = GetDpiForWindow(control.window)
    control.pointerMachine = newCanvasPointerMachine(vec2(
      float64(GetSystemMetricsForDpi(68, dpi)), float64(GetSystemMetricsForDpi(69, dpi))))
  result = control

proc properties(win: Win32Backend, control: NativeControl, entity: MountedEntity) =
  let old = control.entity
  if entity.props.standardUi.isSome and entity.props.standardUi.get.role in {UiRole.spinner,UiRole.alert}:
    let kind = if entity.props.standardUi.get.role == UiRole.alert: LiveKind.alert else: LiveKind.status
    if win.liveContext == nil:
      win.liveContext = newLiveContext()
      win.liveContext.setWake(win.host.windowHandle, WM_HOST_TICK)
    if control.live == nil:
      control.live = win.liveContext.newLiveProvider(control.window, kind, entity.label)
    else:
      control.live.stage(kind, entity.label)
  if entity.kind==NodeKind.text:
    let centered=entity.props.standardUi.isSome and
      entity.props.standardUi.get.role in {UiRole.emptyTitle,UiRole.emptyDescription}
    let wasCentered=old.props.standardUi.isSome and
      old.props.standardUi.get.role in {UiRole.emptyTitle,UiRole.emptyDescription}
    if centered or wasCentered:
      let current=GetWindowLongW(control.window,GWL_STYLE)
      let desired=(current and not 0x1f'i32) or (if centered:1'i32 else:0'i32)
      if current!=desired:
        setLastError(0)
        if win.calls.setWindowData(control.window,GWL_STYLE,int(desired))==0 and lastError()!=0:
          nativeError("SetWindowLongPtrW Empty text alignment")
        if win.calls.invalidate(control.window,nil,1)==0:nativeError("InvalidateRect Empty text")
  inc control.setterDepth
  defer: dec control.setterDepth
  if old.props.standardUi != entity.props.standardUi or
      standardRole(control.window) != (if entity.props.standardUi.isSome:
        some(entity.props.standardUi.get.role) else: none(UiRole)):
    if setStandardUi(control.window,entity.props.standardUi)==0:
      nativeError("SetPropW standard UI metadata")
    let pulseOnly=old.props.standardUi.isSome and entity.props.standardUi.isSome and
      old.props.standardUi.get.role==entity.props.standardUi.get.role and
      entity.props.standardUi.get.role in {UiRole.skeleton,UiRole.spinner}
    if not pulseOnly and (entity.props.standardUi.isNone or entity.props.standardUi.get.role != UiRole.theme):
      discard win.calls.send(control.window,WM_SETFONT,
        cast[WPARAM](win.measurement.ensureFont(win.fontRole(entity))),1)
    if pulseOnly:
      if win.calls.invalidate(control.window,nil,0)==0:nativeError("InvalidateRect Skeleton pulse")
    else:discard refreshSkin(control.window)
    if entity.kind==NodeKind.input:
      let group=inputGroupOf(control.window)
      if group!=nil and invalidateInputGroup(group)==0:nativeError("InvalidateRect input group")
  if win.theme != systemTheme and entity.kind in {NodeKind.checkbox, NodeKind.toggle} and
      not checkColorsPrepared(control.window):
    if entity.kind == NodeKind.toggle or
        (entity.props.standardUi.isSome and entity.props.standardUi.get.role==UiRole.checkbox):
      # Standard checkbox and switch both need v6 NM_CUSTOMDRAW.
      # Keep v6 theming enabled: classic BUTTON does not send NM_CUSTOMDRAW.
      if setToggleSkin(control.window) == 0: nativeError("SetPropW native toggle")
    else:
      let status = useSystemCheckColors(control.window)
      if status < 0: fail("SetWindowTheme check colors failed: " & $status)
  if win.theme != systemTheme and entity.kind == NodeKind.button and
      (entity.props.control.variant.get(variantDefault) == variantPrimary) !=
        primaryButton(control.window):
    if setPrimaryButton(control.window,
        entity.props.control.variant.get(variantDefault) == variantPrimary) == 0:
      nativeError("SetPropW native button variant")
    if win.calls.invalidate(control.window, nil, 1) == 0: nativeError("InvalidateRect button variant")
  if win.theme != systemTheme and entity.kind in {NodeKind.column, NodeKind.row}:
    if setSurfaceVariant(control.window, entity.props.control.variant.get(variantDefault)) == 0:
      nativeError("SetPropW surface variant")
    if old.props.control.variant != entity.props.control.variant or control.fresh:
      discard refreshSkin(control.window)
  if win.theme != systemTheme and entity.kind in {NodeKind.text, NodeKind.input, NodeKind.button}:
    let variant = entity.props.control.variant.get(variantDefault)
    if semanticVariant(control.window) != variant:
      if setSemanticVariant(control.window, variant) == 0: nativeError("SetPropW semantic variant")
      discard win.calls.send(control.window, WM_SETFONT,
        cast[WPARAM](win.measurement.ensureFont(win.fontRole(entity))), 1)
      discard refreshSkin(control.window)
  if entity.kind == NodeKind.input:
    # Native edits pending settlement and active IME are never overwritten by
    # an earlier accepted event. Settlement handles no-diff rejection too.
    when defined(leafProtocolProbes):
      if win.popovers.len != 0 and control.entity.kind == NodeKind.input:
        echo "INPUTWB h=", uint64(control.entity.handle), " fresh=", control.fresh,
          " latest=", control.editor.latestObserved, " settled=", control.editor.lastSettled,
          " nativeLen=", control.editor.native.text.len, " acceptedLen=", entity.label.len,
          " phase=", control.editor.phase
    var windowHoldsAccepted = false
    if not control.fresh and control.editor.phase in {compositionNone, compositionEnd} and
        control.editor.pendingReset.isNone:
      let current = control.readText()
      windowHoldsAccepted = current == entity.label
    if control.fresh or (control.editor.phase in {compositionNone, compositionEnd} and
        control.editor.latestObserved <= control.editor.lastSettled and
        control.editor.native.text != entity.label and not windowHoldsAccepted):
      win.applyEffects(control, @[EditEffect(kind: setText, value: entity.value,
        selection: (if control.fresh: Selection16() else: control.selection()))])
    let cue = checkedWide(entity.props.control.placeholder.get(""))
    discard win.calls.send(control.window, EM_SETCUEBANNER, 0, cast[LPARAM](unsafeAddr cue[0]))
  elif entity.props.standardUi.isSome and entity.props.standardUi.get.role in UiGroupRoles:
    if control.fresh or old.label != entity.label:
      let wide = checkedWide(entity.label)
      if win.calls.setText(control.window, unsafeAddr wide[0]) == 0:
        nativeError("SetWindowTextW button group")
      inc win.stats.setTexts
      # GroupBox WM_SETTEXT can draw its native frame immediately and only
      # invalidate the caption area. Alert owns the whole rounded surface.
      if entity.props.standardUi.get.role == UiRole.alert:
        if win.calls.invalidate(control.window, nil, 1) == 0:
          nativeError("InvalidateRect alert caption")
  elif entity.kind notin {NodeKind.column, NodeKind.row, NodeKind.navigation,
      NodeKind.progress, NodeKind.spinner, NodeKind.separator}:
    if control.fresh or old.label != entity.label:
      let wide = checkedWide(entity.label)
      if win.calls.setText(control.window, unsafeAddr wide[0]) == 0: nativeError("SetWindowTextW")
      inc win.stats.setTexts
      # Stock label controls do not always invalidate their own client area for
      # WM_SETTEXT. Without this the visible text is only repainted where the
      # window region happens to grow, leaving stale glyphs until a resize.
      if win.calls.invalidate(control.window, nil, 1) == 0: nativeError("InvalidateRect")
  discard win.calls.enable(control.window, BOOL(ord(entity.props.control.enabled.get(true))))
  case entity.kind
  of NodeKind.checkbox, NodeKind.toggle:
    if control.fresh or control.editor.latestObserved <= control.editor.lastSettled:
      discard win.calls.send(control.window, BM_SETCHECK, WPARAM(ord(entity.props.control.checked.get(false))), 0)
      control.editor.native = entity.value
  of NodeKind.progress:
    discard win.calls.send(control.window, PBM_SETRANGE32, 0, 100)
    discard win.calls.send(control.window, PBM_SETPOS, WPARAM(int(entity.props.control.progress.get(0.0))), 0)
    if entity.props.standardUi.isSome and entity.props.standardUi.get.role==UiRole.progress:
      if win.calls.invalidate(control.window,nil,0)==0:nativeError("InvalidateRect standard progress")
  of NodeKind.spinner: discard win.calls.send(control.window, PBM_SETMARQUEE, 1, 30)
  else: discard
  if entity.kind == NodeKind.canvasHost:
    let currentStyle = GetWindowLongW(control.window, -16)
    let focusable = entity.canvas.get.focusable
    let desiredStyle = if focusable: currentStyle or int32(WS_TABSTOP) else: currentStyle and not int32(WS_TABSTOP)
    if currentStyle != desiredStyle:
      setLastError(0)
      if win.calls.setWindowData(control.window, -16, int(desiredStyle)) == 0 and lastError() != 0:
        nativeError("Canvas focusability update")
      if not focusable and GetFocus() == control.window: discard SetFocus(win.host.windowHandle)
  # Only after every real setter ran is the OS state the new entity's state.
  control.fresh = false
  control.entity = entity
  if entity.kind == NodeKind.virtualList:
    if entity.list.isNone: fail("virtual list has no list metadata")
    let list = win.lists.getOrDefault(entity.handle)
    if list == nil: fail("virtual list has no native viewport")
    list.updateSource(entity.list.get)

proc measureControl*(win: Win32Backend, entity: MountedEntity, available: DipSize): DipSize =
  win.checkLive()
  if win.measurement == nil:
    win.measurement = win.newMeasurement()
  let label = entity.label
  if entity.props.standardUi.isSome:
    # Standard roles/font/size are not encoded into the legacy byte-sized key.
    # Keep this bounded path uncached rather than aliasing different metrics.
    inc win.stats.measures
    let props=entity.props.standardUi.get
    case props.role
    of UiRole.kbd:
      result=win.measurement.measureText(label,role=win.fontRole(entity))
      result.width=max(20.0,result.width+8)
      result.height=20
    of UiRole.progress: result=DipSize(width:0,height:8)
    of UiRole.badge:
      result=win.measurement.measureText(label,role=win.fontRole(entity))
      result.width+=18 # px-2 plus the two transparent/outline border pixels
      result.height=22
    of UiRole.separator: result=DipSize(width:1,height:1)
    of UiRole.button,UiRole.dialogClose,UiRole.alertDialogCancel,UiRole.alertDialogAction,
        UiRole.popoverTrigger,UiRole.popoverClose:
      result=win.measurement.measureText(label,role=win.fontRole(entity))
      result.width+=2*horizontalInset(props.size)
      result.height=max(controlHeight(props.size),result.height+8)
      if props.size.iconOnly: result.width=controlHeight(props.size)
    of UiRole.checkbox,UiRole.switch:
      let glyph=checkMetrics(props.role,props.size)
      result=win.measurement.measureText(label,role=win.fontRole(entity))
      result.width+=glyph.width+(if label.len>0:8.0 else:0.0)
      result.height=max(20.0,result.height)
    of UiRole.input,UiRole.textarea:
      let control=win.controls.getOrDefault(entity.handle,win.prepared.getOrDefault(entity.handle))
      result=win.measurement.measureInput(label,entity.props.control.placeholder.get(""),
        if control==nil:nil else:control.window)
    of UiRole.alertTitle,UiRole.alertDescription,UiRole.cardTitle,UiRole.cardDescription,UiRole.label,
        UiRole.fieldDescription,UiRole.fieldError,UiRole.emptyTitle,UiRole.emptyDescription,UiRole.inputGroupText,
        UiRole.dialogTitle,UiRole.dialogDescription:
      result=win.measurement.measureText(if label.len==0:"Mg" else:label,
        available.width,role=win.fontRole(entity))
    else: result=DipSize()
    return
  let hint = entity.props.control.placeholder.get("")
  let checked = entity.props.control.checked.get(false)
  let enabled = entity.props.control.enabled.get(true)
  let key: MeasureKey = (entity.kind, label, hint,
    uint8(ord(checked) or (ord(enabled) shl 1) or
      (ord(entity.props.control.variant.get(variantDefault)) shl 2)), available.width, available.height)
  let cached = win.cache.get(key)
  if cached.isSome:
    inc win.measureCacheHits
    return cached.get
  inc win.stats.measures
  case entity.kind
  of NodeKind.column, NodeKind.row, NodeKind.navigation: result = DipSize()
  of NodeKind.canvasHost: result = DipSize(width: available.width, height: 0.0)
  of NodeKind.virtualList:
    # A list is a block-level scrollable viewport, not a text leaf: it takes the
    # finite width offered by its parent (the same value `resolveChildWidth`
    # gives a fill child) so its real client width is not a text-width sliver.
    # The declared viewport height still arrives as a fixed dimension.
    result = DipSize(width: available.width, height: 0.0)
  of NodeKind.input:
    let control = win.controls.getOrDefault(entity.handle, win.prepared.getOrDefault(entity.handle))
    result = win.measurement.measureInput(label, hint,
      if control == nil: nil else: control.window)
  of NodeKind.checkbox, NodeKind.toggle:
    result = win.measurement.measureCheckbox(label, checked, not enabled)
    if win.theme != systemTheme and entity.kind == NodeKind.toggle:
      let caption = win.measurement.measureText(label)
      result.width = max(result.width, caption.width + 48)
      result.height = max(result.height, 40)
  of NodeKind.progress, NodeKind.spinner: result = win.measurement.measureProgress()
  of NodeKind.separator: result = win.measurement.measureSeparator()
  of NodeKind.button:
    if win.theme == systemTheme:
      result = win.measurement.measureButton(label, enabled)
    else:
      # The stock ideal size has different padding from the skinned painter.
      # Measure the same native font, then reserve the painter's insets/border.
      result = win.measurement.measureText(label, role=captionFont)
      result.width += 2 * NativeButtonInset + 2
      result.height = max(NativeButtonHeight, result.height + 8)
  else:
    result = win.measurement.measureText(if label.len == 0: "Mg" else: label,
      if entity.kind == NodeKind.text: available.width else: 0.0,
      role=win.fontRole(entity))
  win.cache.put(key, result)

proc publishPendingFrames(win: Win32Backend) {.raises: [].}

proc listProtected(win: Win32Backend, listHandle: NodeHandle): seq[int]


proc projectRowPlan(win: Win32Backend, entity: MountedEntity, rect, clip: DipRect,
                    into: var seq[ListRowBox]) =
  ## Pure geometry: project one measured row subtree through the existing layout
  ## scope into parent-local window rects and viewport-space clips. Runs once per
  ## affected attempt; a replay applies the stored boxes and never re-projects.
  var boxes = win.listScope.layoutSubtree(entity.handle, rect, clip)
  var byHandle: Table[NodeHandle, DipRect]
  for box in boxes: byHandle[box.handle] = box.rect
  for box in boxes:
    let control = win.controls.getOrDefault(box.handle)
    if control == nil: continue
    var local = box.rect
    if box.handle != entity.handle:
      let parent = control.entity.parent
      if byHandle.hasKey(parent):
        let parentRect = byHandle[parent]
        local.x = box.rect.x - parentRect.x
        local.y = box.rect.y - parentRect.y
    into.add ListRowBox(handle: box.handle, local: local, rect: box.rect,
      clip: box.clip)

proc noteRowsetReadiness(win: Win32Backend, list: Win32ListHost,
                         frame: ListFrame) =
  ## Required typed rowset of this attempt: the visible range, one overscan ring
  ## and the protected rows. Scalars only - no set is built here, and accept never
  ## infers readiness from applied range equality. `frame.rows` is the typed rowset
  ## the attempt actually materialised.
  let overscan = max(0, list.props.overscan)
  let itemCount = max(0, list.props.itemCount)
  frame.neededFirst = max(0, frame.first - overscan)
  frame.neededFinish = min(itemCount, frame.finish + overscan)
  let protected = win.listProtected(list.handle)
  var inside = 0
  var outside = 0
  for binding in frame.rows:
    let index = binding.itemIndex
    if index >= frame.first and index < frame.finish:
      inc inside
    elif index < frame.neededFirst or index >= frame.neededFinish:
      var kept = false
      for item in protected:
        if item == index:
          kept = true
          break
      if not kept: inc outside
  let needed = max(0, frame.finish - frame.first)
  frame.rowsetReady = inside == needed and outside == 0
  frame.rowsPending = inside < needed
  frame.trimPending = outside > 0

proc showControl(win: Win32Backend, control: NativeControl, visible: bool,
                 source = "") =
  when defined(leafProtocolProbes):
    if win.popovers.len != 0 and control != nil and control.window != nil:
      let ws = GetWindowLongW(control.window, -16'i32)
      echo "SHOWCTL h=", uint64(control.entity.handle), " req=", visible,
        " src=", source,
        " applied=", control.appliedVisible,
        " wsVis=", (ws and 0x10000000) != 0,
        " body=", win.popoverBody(control.entity.handle)
  if control.appliedVisible == some(visible): return
  discard win.calls.showWindow(control.window, if visible: SW_SHOW else: SW_HIDE)
  control.appliedVisible = some(visible)

proc placeControl(win: Win32Backend, control: NativeControl,
                  position: tuple[x, y, width, height: int],
                  clip: tuple[left, top, right, bottom: int],
                  rowSubtree = false) =
  # Cache receipts only after the corresponding API succeeds. Partial failure
  # leaves unapplied work due; rollback can compare against what actually ran.
  let positionOperation = if rowSubtree: "SetWindowPos row subtree" else: "SetWindowPos control"
  let regionSuffix = if rowSubtree: " row subtree" else: ""
  if control.appliedPosition != some(position):
    if win.calls.windowPos(control.window, nil, int32(position.x), int32(position.y),
        int32(position.width), int32(position.height),
        SWP_NOZORDER or SWP_NOACTIVATE) == 0: nativeError(positionOperation)
    # Windows preserves valid client pixels on size changes. A rounded Card's
    # former bottom corners remain inside the new client area on growth, so
    # exposed-strip invalidation alone cannot clear them. Invalidate only this
    # resized standard Card; CLIPCHILDREN keeps child HWND painting independent.
    if win.theme.isShadcn and standardRole(control.window)==some(UiRole.card) and
        control.appliedPosition.isSome and
        (control.appliedPosition.get.width!=position.width or
         control.appliedPosition.get.height!=position.height):
      if win.calls.invalidate(control.window,nil,1)==0:
        nativeError("InvalidateRect resized standard Card")
    control.appliedPosition = some(position)
  if control.appliedClip != some(clip):
    let region = win.calls.rectRegion(int32(clip.left), int32(clip.top),
      int32(clip.right), int32(clip.bottom))
    if region == nil: nativeError("CreateRectRgn" & regionSuffix)
    win.pendingRegions.add(region)
    var primary: ref CatchableError
    try:
      if win.calls.setRegion(control.window, region, 1) == 0: nativeError("SetWindowRgn" & regionSuffix)
      win.pendingRegions[^1] = nil # Ownership transfers only on success.
      control.appliedClip = some(clip)
    except CatchableError as error: primary = error
    try: win.releaseRegions()
    except CatchableError as secondary:
      if primary != nil: primary.msg.add("; region cleanup secondary: " & secondary.msg)
      else: raise secondary
    if primary != nil: raise primary
  win.showControl(control, true)

proc applyRowBoxes(win: Win32Backend, boxes: seq[ListRowBox], dpi: int32) =
  ## The only Position/Region/Show path for list row subtrees: commit apply,
  ## geometry apply and rollback replay all come through here. Rect, clip and DPI
  ## come from the selected plan/context, never from live legacy scalars. A FALSE
  ## BOOL blocks the whole attempt and keeps its original error; the single region
  ## owner is released here either way (never swallowed, never leaked).
  for item in boxes:
    let control = win.controls.getOrDefault(item.handle)
    if control == nil: continue
    # Round shared viewport boundaries BEFORE subtracting the parent origin.
    # Rounding a parent-local half pixel separately can move a negative row's
    # child by one pixel relative to the viewport-space region below.
    let bp = pixelEdges(item.rect, int(dpi))
    let parent = pixelEdges(DipRect(x: item.rect.x - item.local.x,
      y: item.rect.y - item.local.y), int(dpi))
    let width = max(0, bp.right - bp.left)
    let height = max(0, bp.bottom - bp.top)
    # Region coordinates are window-local. Subtract the window's viewport
    # rect from the viewport clip, NOT its parent-local placement: descendants
    # of nonzero/partially scrolled rows otherwise receive displaced regions.
    let cp = pixelEdges(item.clip, int(dpi))
    let left = clamp(cp.left - bp.left, 0, width)
    let top = clamp(cp.top - bp.top, 0, height)
    let right = max(left, clamp(cp.right - bp.left, 0, width))
    let bottom = max(top, clamp(cp.bottom - bp.top, 0, height))
    # CreateRectRgn normalizes inverted edges: clamp BOTH ends so completely
    # clipped overscan stays empty instead of becoming a positive rectangle.
    win.placeControl(control, (bp.left - parent.left, bp.top - parent.top, width, height),
      (left, top, right, bottom), rowSubtree = true)

proc applyListPlan(win: Win32Backend, list: Win32ListHost, frame: ListFrame) =
  ## One plan, one native apply: the frame's own scrollbar projection and the exact
  ## row-subtree boxes prepared with it. No measurement and no publication here.
  list.syncScrollbarFrame(frame)
  if not win.restoring and not win.replaying:
    var client: RECT
    if win.calls.clientRect(list.window, addr client) == 0:
      nativeError("GetClientRect list after scrollbar")
    let scale = float64(frame.dpi) / 96.0
    list.noteClientReadback(frame,
      float64(max(0'i32, client.right - client.left)) / scale,
      float64(max(0'i32, client.bottom - client.top)) / scale)
  win.applyRowBoxes(frame.boxes, frame.dpi)
  if win.restoring: inc win.restoreAppliedCount

proc dropPendingCandidates(win: Win32Backend) =
  ## A failed geometry attempt must not leave any candidate that a later accept
  ## could publish. Only this attempt's prepared plans are dropped; accepted plans
  ## and the persistent rollback pins stay untouched.
  for handle in win.pendingFrames:
    let list = win.lists.getOrDefault(handle)
    if list != nil: list.discardPreparedFrame()
  win.pendingFrames.setLen(0)
  for handle, list in win.lists:
    if list.preparedFrame != nil and list.preparedFrame != list.acceptedFrame:
      list.discardPreparedFrame()

proc geometryRelayout(win: Win32Backend) =
  ## One geometry-only pass with a single bounded replay of the accepted plans.
  ## Nothing is published before the whole pass succeeded; a failure discards
  ## every pending candidate and replays the old accepted plans once (no
  ## measurement, no publication, no Runtime revision). A replay failure keeps the
  ## existing fault/close path and the original error as the primary.
  let ctx = win.host.context
  let content = DipSize(width: ctx.contentWidth, height: ctx.contentHeight)
  let dpi = int(ctx.scale * 96)
  try:
    win.relayout(content, dpi)
  except CatchableError as primary:
    win.dropPendingCandidates()
    win.replaying = true
    try:
      try: win.relayout(content, dpi)
      finally: win.replaying = false
    except CatchableError as replayError:
      primary.msg.add("; accepted-plan replay failed: " & replayError.msg)
    # Replaying the old plan restores its geometry; it does not apply the new
    # viewport context. Keep that work due for the next ordinary turn, including
    # a resize with no new scroll intent to trigger a separate geometry pass.
    win.dirty = not (primary of ListGeometryConvergenceError)
    raise primary


proc computeOverlayCandidate(win: Win32Backend, scope: var LayoutScope,
    root: NodeHandle, plan: var OverlayPlan, owner: HWND, dpi: int):
    tuple[placement: OverlayPlacement, pinned: bool, boxes: seq[LayoutBox]] =
  ## One candidate computation used by prepare-time apply and the geometry tick:
  ## placement, the natural content height measured at the *final* client width,
  ## both scroll decisions and the complete box list are derived here and only
  ## then committed by the caller. No show/hide/focus/scrollbar state changes.
  let overlay = win.overlays.getOrDefault(root)
  if overlay == nil: return
  if win.overlayAcceptedPlans.hasKey(root):
    # Single authority: the accepted plan carries this level's offset.
    let accepted = win.overlayAcceptedPlans[root]
    if accepted.open:
      plan.scrollX = accepted.scrollX
      plan.scrollY = accepted.scrollY
  # Prepared width/height may be a constrained client from a controlled edit.
  # Re-derive natural dimensions from the accepted tree so restoring the work
  # area does not permanently retain that smaller client size.
  let entity = win.current.getOrDefault(root)
  let requestedWidth = entity.overlay.get.overlayWidth
  let area = win.overlayWorkArea()
  let measureWidth = if area.known:
      max(1.0, min(requestedWidth, area.width - 2 * ModalMargin))
    else: requestedWidth
  let natural = scope.measureSubtree(root,
    DipSize(width: measureWidth, height: 100_000.0))
  try:
    result.placement = overlay.placementFor(requestedWidth, natural.height, owner)
  except OverlayGeometryError:
    result.placement = overlay.clampedPlacementFor(requestedWidth, natural.height, owner)
    result.pinned = true
  # One pure candidate owns the viewport, both ranges, the clamped offsets and
  # the bar rectangles; nothing downstream recomputes bar space.
  let bar = overlayBarThickness(dpi)
  var measureScope = scope
  let rootHandle = root
  let geom = planOverlayGeometry(result.placement.clientWidth,
    result.placement.clientHeight, bar, bar,
    proc(width: float64): tuple[width, height: float64] =
      let size = measureScope.measureSubtree(rootHandle,
        DipSize(width: width, height: 100_000.0))
      (size.width, size.height), plan.scrollX, plan.scrollY)
  plan.geom = geom
  plan.contentW = geom.contentWidth
  plan.contentH = geom.contentHeight
  plan.rangeX = geom.rangeX
  plan.rangeY = geom.rangeY
  plan.scrollX = geom.scrollX
  plan.scrollY = geom.scrollY
  plan.contentRects.clear()
  when defined(leafProtocolProbes):
    echo "CANDIDATE root=" & $uint64(root) & " dpi=" & $dpi &
      " client=" & $result.placement.clientWidth & "x" &
      $result.placement.clientHeight & " content=" & $geom.contentWidth & "x" &
      $geom.contentHeight & " viewport=" & $geom.viewportWidth & "x" &
      $geom.viewportHeight & " rangeX=" & $geom.rangeX & " rangeY=" &
      $geom.rangeY & " scrollX=" & $geom.scrollX & " scrollY=" & $geom.scrollY
  result.boxes = win.composeLevelBoxes(scope, root, plan.geom, result.pinned,
    plan.contentRects)

proc layoutOverlays(win: Win32Backend, dpi: int) =
  ## Geometry tick for already published levels: re-derive the placement from
  ## the current owning window (owner move/resize, DPI or work-area change) and
  ## re-place the content. Never shows, disables or focuses anything.
  if win.overlayStack.order.len == 0: return
  # A panel body is its own layout root inside the owned panel window: it must
  # never be measured or composed as part of a modal level either, otherwise a
  # growing popover body would inflate the dialog it is anchored in.
  var levelEntities = win.current
  if win.popovers.len != 0: levelEntities = withoutPopoverBodies(win.current)
  var scope = initLayoutScope(levelEntities,
    proc(entity: MountedEntity, available: DipSize): DipSize =
      win.measureControl(entity, available))
  for level, id in win.overlayStack.order:
    let root = NodeHandle(id)
    let overlay = win.overlays.getOrDefault(root)
    if overlay == nil: continue
    let entity = win.current.getOrDefault(root)
    if entity.handle == NoHandle or entity.overlay.isNone: continue
    var plan = win.overlayAcceptedPlans.getOrDefault(root)
    if plan.width <= 0: continue
    var owner = win.host.windowHandle
    if level > 0:
      let below = win.overlays.getOrDefault(NodeHandle(win.overlayStack.order[level - 1]))
      if below != nil: owner = below.surfaceHandle
    let candidate = win.computeOverlayCandidate(scope, root, plan, owner, dpi)
    if candidate.pinned: inc win.overlayShrinkFallbacks
    let placement = candidate.placement
    # Commit only after the whole candidate succeeded.
    overlay.applyPlacement(placement)
    overlay.setScrollable(plan.rangeY > 0.0 or plan.rangeX > 0.0)
    win.publishOverlayBars(overlay, plan, dpi)
    plan.x = placement.x
    plan.y = placement.y
    plan.widthPx = placement.widthPx
    plan.heightPx = placement.heightPx
    plan.scrimRect = (placement.scrimLeft, placement.scrimTop,
      placement.scrimRight, placement.scrimBottom)
    plan.placed = true
    win.overlayAcceptedPlans[root] = plan
    when defined(leafProtocolProbes):
      echo "GEO root=" & $uint64(root) & " scrollX=" & $formatFloat(plan.scrollX, ffDefault, 1) &
        " scrollY=" & $formatFloat(plan.scrollY, ffDefault, 1) &
        " rangeX=" & $formatFloat(plan.rangeX, ffDefault, 1) &
        " rangeY=" & $formatFloat(plan.rangeY, ffDefault, 1) &
        " content=" & $formatFloat(plan.contentW, ffDefault, 1) & "x" &
        $formatFloat(plan.contentH, ffDefault, 1) &
        " viewport=" & $formatFloat(plan.geom.viewportWidth, ffDefault, 1) & "x" &
        $formatFloat(plan.geom.viewportHeight, ffDefault, 1)
    win.placeOverlayBoxes(root, candidate.boxes, dpi, "levelGeometry")
    # A bar step that did not take effect keeps its target in the accepted plan;
    # marking the level dirty retries it on the next ordinary turn instead of
    # waiting for a new user request.
    if plan.barFault: win.overlayDirty = true
  var retry = false
  for _, accepted in win.overlayAcceptedPlans:
    if accepted.barFault: retry = true
  win.overlayDirty = retry

proc popoverBody(win: Win32Backend, handle: NodeHandle): bool =
  ## True when this entity is a popover panel body or one of its descendants.
  var current = handle
  var depth = 0
  while current != NoHandle:
    let entity = win.current.getOrDefault(current)
    if entity.handle == NoHandle: return false
    if entity.props.standardUi.isSome and
        entity.props.standardUi.get.role == UiRole.popoverContent:
      return true
    current = entity.parent
    inc depth
    if depth > MaxDepth: return false
  false

proc relayout*(win: Win32Backend, content: DipSize, dpi: int) =
  win.checkLive()
  if win.current.len == 0: return
  win.releaseRegions()
  # Modal levels are their own layout roots: they never take part in the page
  # flow, and their controls are never ordered against page siblings.
  var page = win.current
  if win.overlays.len != 0:
    var filtered: Table[NodeHandle, MountedEntity]
    for handle, entity in win.current:
      if win.overlayRootOf(handle) == NoHandle: filtered[handle] = entity
    page = filtered
  if win.popovers.len != 0:
    # Same exclusion for the page flow: bodies are laid out only while shown.
    page = withoutPopoverBodies(page)
  let boxes = layoutTree(page, content,
    proc(entity: MountedEntity, available: DipSize): DipSize = win.measureControl(entity, available))
  var byHandle: Table[NodeHandle, LayoutBox]
  for box in boxes: byHandle[box.handle] = box
  for box in boxes:
    if box.handle notin win.controls: continue
    let control = win.controls[box.handle]
    if box.clip.width <= 0 or box.clip.height <= 0 or
        box.rect.x >= box.clip.x + box.clip.width or
        box.rect.y >= box.clip.y + box.clip.height or
        box.rect.x + box.rect.width <= box.clip.x or
        box.rect.y + box.rect.height <= box.clip.y:
      win.showControl(control, false, "relayout")
      continue
    let pixels = pixelEdges(box.rect, dpi)
    var left = pixels.left; var top = pixels.top
    if control.entity.parent != NoHandle:
      let parent = pixelEdges(byHandle[control.entity.parent].rect, dpi)
      left -= parent.left; top -= parent.top
    let clip = pixelEdges(box.clip, dpi)
    win.placeControl(control,
      (left, top, pixels.right - pixels.left, pixels.bottom - pixels.top),
      (max(0, clip.left - pixels.left), max(0, clip.top - pixels.top),
       max(0, min(pixels.right, clip.right) - pixels.left),
       max(0, min(pixels.bottom, clip.bottom) - pixels.top)))
  var siblings: Table[NodeHandle, seq[MountedEntity]]
  for entity in page.values: siblings.mgetOrPut(entity.parent, @[]).add(entity)
  var appliedOrders: Table[NodeHandle, seq[HWND]]
  for parent, children in siblings.mpairs:
    children.sort(proc(a,b: MountedEntity): int = cmp(a.index,b.index))
    var order: seq[HWND]
    for entity in children: order.add(win.controls[entity.handle].window)
    if win.appliedOrders.getOrDefault(parent) != order:
      # An unchanged predecessor alone is insufficient after a rotation: a
      # preceding move may have displaced it. Apply each changed group in full.
      var previous: HWND
      for window in order:
        if win.calls.windowPos(window, previous, 0, 0, 0, 0,
            0x0001'u32 or 0x0002'u32 or SWP_NOACTIVATE) == 0:
          nativeError("SetWindowPos tab order")
        previous = window
    appliedOrders[parent] = order
  win.appliedOrders = appliedOrders
  # List viewports: actual client size (scrollbar excluded) and one bounded row
  # geometry pass per list. Rows are children of the viewport, so their
  # coordinates are viewport-local DIP.
  if win.lists.len > 0:
    win.listScope = initLayoutScope(win.current,
      proc(entity: MountedEntity, available: DipSize): DipSize =
        win.measureControl(entity, available))
    for listHandle, list in win.lists:
      if list.window == nil: continue
      var client: RECT
      if win.calls.clientRect(list.window, addr client) == 0: nativeError("GetClientRect list")
      let listDpi = win.calls.dpi(list.window)
      if listDpi == 0 or listDpi > UINT(high(int32)):
        nativeError("GetDpiForWindow list")
      let scale = float64(listDpi) / 96.0
      let clientWidthDip = float64(max(0'i32, client.right - client.left)) / scale
      let viewportDip = float64(max(0'i32, client.bottom - client.top)) / scale
      var rows: seq[MountedEntity]
      for handle, entity in win.current:
        if entity.row.isSome and entity.row.get.listHandle == listHandle and
            win.controls.hasKey(handle):
          rows.add(entity)
      rows.sort(proc(a, b: MountedEntity): int =
        cmp(a.row.get.itemIndex, b.row.get.itemIndex))
      list.retireFrames()
      if list.props.heightMode != HostHeightMode.variable:
        # Uniform rows keep the legacy projection: the live client size is the
        # frame. Same native helper as the variable plan.
        list.setViewportSize(clientWidthDip, viewportDip)
        list.syncScrollbar()
        let viewport = DipRect(x: 0.0, y: 0.0, width: list.clientWidth,
          height: list.viewport)
        var uniformPlan: seq[ListRowBox]
        for entity in rows:
          win.projectRowPlan(entity, list.rowRect(entity.row.get, viewport),
            viewport, uniformPlan)
        win.applyRowBoxes(uniformPlan, int32(listDpi))
        continue
      # Variable rows: one private plan per list per pass. The candidate owns a
      # cloned height index and the projected row-subtree boxes; the accepted plan
      # stays read-only until every native step of the whole pass succeeded.
      var frame: ListFrame = nil
      var geoPhase = "plan"
      var placed = false
      defer:
        if not placed and frame != nil and frame != list.acceptedFrame:
          list.failedFrame = frame
          list.failedPhase = geoPhase
          list.preparedFrame = nil
          when defined(leafProtocolProbes):
            recordFailedFrame(win, frame, geoPhase)
      if win.restoring:
        # Rollback replay: the persistent pin is read *before* any measurement, so
        # the rejected candidate is never re-measured. A missing pin is an explicit
        # fault, never a fabricated empty old frame.
        var desiredOffset: float64
        var intentGeneration: uint64
        for pin in win.rollbackFrames:
          if pin.handle == listHandle and
              pin.frame.sourceGeneration == list.props.sourceGeneration:
            frame = pin.frame
            desiredOffset = pin.desiredOffset
            intentGeneration = pin.intentGeneration
            inc win.restoreReplayCount
            break
        if frame == nil:
          fail("variable list has no accepted plan for its handle/source")
        list.installFrame(frame, desiredOffset, intentGeneration)
      elif win.replaying:
        # Bounded geometry replay of this list's own accepted plan. Its accepted
        # metadata (and any pending user intent) is already installed, so nothing
        # here may reset it.
        frame = list.acceptedFrame
        if frame == nil:
          fail("variable list has no accepted plan for its handle/source")
      else:
        var typedRows: seq[NativeRowBinding]
        for entity in rows: typedRows.add(entity.row.get)
        if win.measurement == nil or
            win.measurement.pixelsToDip(float64(listDpi)) != 96.0:
          fail("list viewport DPI differs from native measurement DPI")
        frame = list.prepareFrame(list.props, clientWidthDip, viewportDip,
          int32(listDpi), list.desiredOffset, typedRows, win.nextPlanToken(),
          win.fontEpoch)
        list.preparedFrame = frame
        let planViewport = DipRect(x: 0.0, y: 0.0, width: frame.clientWidth,
          height: frame.viewport)
        for entity in rows:
          let preferred = win.listScope.measureSubtree(entity.handle,
            DipSize(width: clientWidthDip, height: viewportDip))
          inc win.rowMeasureCount
          frame.measureRow(entity.row.get.itemIndex, preferred.height)
        list.preserveAnchor(frame)
        frame.refreshRange()
        frame.projectBar()
        for entity in rows:
          let rect = frame.rowRectOf(entity.row.get, planViewport)
          win.projectRowPlan(entity, rect, planViewport, frame.boxes)
        win.noteRowsetReadiness(list, frame)
      geoPhase = "placement"
      win.applyListPlan(list, frame)
      placed = true
      if frame != list.acceptedFrame:
        # Commit candidates stay prepared until the real accept; geometry-only
        # candidates are published only after the *whole* pass succeeded (see the
        # end of relayout), so a later list failing accepts nothing.
        if listHandle notin win.pendingFrames: win.pendingFrames.add(listHandle)

  for control in win.controls.values:
    if control.canvas == nil: continue
    try: discard control.canvas.present()
    except UiError:
      if not win.applying and not win.restoring and control.canvas.needsRebuild:
        discard PostMessageW(win.host.windowHandle, WM_HOST_TICK, 0, 0)
      else: raise
  if not win.applying and not win.restoring and not win.replaying:
    # Geometry-only pass: every list's candidate OS apply succeeded, so the
    # metadata publication may move the prepared frames now (no Runtime revision).
    win.publishPendingFrames()
  if win.overlayStack.order.len != 0:
    # layoutOverlays keeps the flag when a bar step still needs a retry, so this
    # pass must not clear it unconditionally.
    win.layoutOverlays(dpi)
  inc win.stats.layouts
  win.dirty = false
  win.listDirty = false

proc prepareCanvases(win: Win32Backend) =
  for handle, entity in win.candidate:
    if entity.kind != NodeKind.canvasHost: continue
    var control: NativeControl
    if handle in win.prepared: control = win.prepared[handle]
    else: control = win.controls.getOrDefault(handle)
    if control == nil or control.canvas == nil: fail("Canvas owner is missing")
    let reason = canvasMetadataReason(entity.kind, entity.canvas)
    if reason.len != 0: fail(reason)
    if control.canvas.acceptedFrame != entity.canvas.get:
      control.canvas.prepareFrame(entity.canvas.get, inputSession=win.sessionId, inputMount=control.bindingToken)

proc prepareModels(win: Win32Backend) =
  ## Prepare owned editor-model values for every entity this batch may accept.
  ## Accept then moves them into EditorState without copying dynamic text.
  win.preparedModels.clear()
  for handle, entity in win.candidate:
    var control: NativeControl
    if handle in win.prepared: control = win.prepared[handle]
    else: control = win.controls.getOrDefault(handle)
    if control == nil: continue
    win.preparedModels[handle] = prepareModelAccept(control.editor, entity.value)

proc discardPrepared(win: Win32Backend) =
  for control in win.controls.values:
    control.live.discardStage()
    if control.canvas != nil: control.canvas.discardPrepared()
  var staleOverlays = win.preparedOverlays
  win.preparedOverlays.setLen(0)
  var overlayFailure: ref CatchableError
  for handle in staleOverlays:
    # An accepted level keeps its windows; only levels that exist solely for the
    # rejected candidate are withdrawn here.
    if win.current.hasKey(handle): continue
    try: win.dropOverlayLevel(handle)
    except CatchableError as error:
      if overlayFailure == nil: overlayFailure = error
      else: overlayFailure.msg.add("; overlay rollback: " & error.msg)
  let first = win.releasePrepared()
  win.candidate.clear()
  win.preparedModels.clear()
  for handle in win.pendingFrames:
    let list = win.lists.getOrDefault(handle)
    if list != nil: list.discardPreparedFrame()
  win.pendingFrames.setLen(0)
  win.rollbackFrames.setLen(0)
  if first != nil:
    if overlayFailure != nil: first.msg.add("; overlay rollback: " & overlayFailure.msg)
    raise first
  if overlayFailure != nil: raise overlayFailure

iterator navigationCandidates(win: Win32Backend, delta: bool,
    removed: HashSet[NodeHandle]): MountedEntity =
  if delta:
    for handle, entity in win.current:
      if handle notin win.candidate and handle notin removed: yield entity
  for handle, entity in win.candidate:
    if handle notin removed: yield entity

proc validateNavigation(win: Win32Backend, batch: UpdateBatch) =
  # Candidate checks run before any HWND is created. This transient count table
  # is preparation work; accepted publication only copies scalar metadata.
  var removed: HashSet[NodeHandle]
  if batch.isDelta:
    for op in batch.ops:
      if op.kind == opRemove: removed.incl(op.handle)
  var children: Table[NodeHandle, int]
  for entity in win.navigationCandidates(batch.isDelta, removed):
    let canvasReason = canvasMetadataReason(entity.kind, entity.canvas)
    if canvasReason.len != 0: fail(canvasReason)
    if (entity.kind == NodeKind.navigation) != entity.navigation.isSome or
        (entity.props.control.hasBack and entity.kind != NodeKind.navigation):
      fail("Win32 navigation metadata does not match its kind")
    if entity.navigation.isSome:
      let reason = entity.navigation.get.invalidReason(MaxNodes)
      if reason.len != 0: fail(reason)
      children[entity.handle] = 0
  if children.len == 0: return
  for entity in win.navigationCandidates(batch.isDelta, removed):
    children.withValue(entity.parent, count): inc count[]
  for count in children.values:
    if count != 1: fail("Win32 navigation requires one active page")

proc prepareStandardUi(win: Win32Backend,batch:UpdateBatch) =
  win.preparedFields.clear()
  win.preparedTheme=win.initialTheme
  # Legacy windows do not acquire a new full-tree pass. Their capabilities
  # already reject all required standard roles, including a theme root.
  if not win.initialTheme.isShadcn:return
  var removed:HashSet[NodeHandle]
  if batch.isDelta:
    for op in batch.ops:
      if op.kind==opRemove:removed.incl(op.handle)
  var entities:Table[NodeHandle,MountedEntity]
  for entity in win.navigationCandidates(batch.isDelta,removed):entities[entity.handle]=entity
  # Validate both against the whole candidate before any HWND creation.
  # GroupBox cannot morph to/from a STATIC at a stable row identity. Reject
  # before native effects; callers change the group's key for that transition.
  var groups: Table[NodeHandle, seq[MountedEntity]]
  for entity in entities.values:
    let grouped = entity.props.standardUi.isSome and entity.props.standardUi.get.role in UiGroupRoles
    if entity.handle in win.controls:
      let previous = win.controls[entity.handle].entity.props.standardUi
      let wasGrouped = previous.isSome and previous.get.role in UiGroupRoles
      if grouped != wasGrouped: fail("changing a button group role requires a new key")
      let live = entity.props.standardUi.isSome and entity.props.standardUi.get.role in {UiRole.spinner,UiRole.alert}
      let wasLive = previous.isSome and previous.get.role in {UiRole.spinner,UiRole.alert}
      if live != wasLive: fail("changing a live status role requires a new key")
    if grouped and entity.props.standardUi.get.role == UiRole.buttonGroup:
      if entity.kind != NodeKind.row or entity.props.layout.gap.get(0) != 0 or
          entity.props.layout.padding.get(0) != 0:
        fail("button group requires a horizontal zero-gap row")
      groups[entity.handle] = @[]
  for entity in entities.values:
    if entity.parent in groups: groups[entity.parent].add(entity)
  for children in groups.values:
    if children.len == 0: fail("button group requires buttons")
    var size = UiSize.normal
    for i, child in children:
      if child.kind != NodeKind.button or child.props.standardUi.isNone or
          child.props.standardUi.get.role != UiRole.button:
        fail("button group only supports direct standard buttons")
      if i == 0: size = child.props.standardUi.get.size
      elif child.props.standardUi.get.size != size:
        fail("button group requires equal button sizes")
  var members:Table[NodeHandle,seq[MountedEntity]]
  for entity in entities.values:members.mgetOrPut(entity.parent,@[]).add(entity)
  for entity in entities.values:
    if entity.props.standardUi.isNone:continue
    let role=entity.props.standardUi.get.role
    if role==UiRole.inputGroup:
      if entity.kind!=NodeKind.row or entity.props.layout.gap.get(0)!=0 or entity.props.layout.padding.get(0)!=1:
        fail("input group requires horizontal inset layout")
      var editors=0;var addons=0
      for child in members.getOrDefault(entity.handle):
        if child.props.standardUi.isNone:fail("input group requires typed children")
        case child.props.standardUi.get.role
        of UiRole.input:
          if child.kind!=NodeKind.input or child.props.control.multiline.get(false):fail("input group requires single-line EDIT")
          inc editors
        of UiRole.inputGroupAddon:inc addons
        else:fail("unsupported input group child")
      if editors!=1 or addons>2:fail("input group requires one input and at most two text addons")
    elif role in {UiRole.inputGroupAddon,UiRole.inputGroupText}:
      if entity.parent notin entities:fail("input addon requires its group")
      let parent=entities[entity.parent].props.standardUi
      let expected=if role==UiRole.inputGroupAddon:UiRole.inputGroup else:UiRole.inputGroupAddon
      if parent.isNone or parent.get.role!=expected:fail("input addon has an invalid parent")
      if role==UiRole.inputGroupAddon:
        var texts=0
        for child in members.getOrDefault(entity.handle):
          if child.props.standardUi.isSome and child.props.standardUi.get.role==UiRole.inputGroupText:inc texts
          elif child.kind!=NodeKind.column or members.getOrDefault(child.handle).len!=0 or child.props.standardUi.isSome:
            fail("input addon supports text and layout spacers only")
        if texts!=1:fail("input addon requires exactly one text")
  win.preparedTheme=resolveTheme(entities,win.initialTheme)
  win.preparedFields=resolveFields(entities)

proc applyTheme(win: Win32Backend) =
  if win.theme == win.preparedTheme:return
  win.theme=win.preparedTheme
  win.host.setNativeThemeInternal(win.theme)

proc applyFields(win:Win32Backend) =
  if not win.theme.isShadcn:return
  var fields:Table[HWND,FieldAssociation]
  for handle,association in win.preparedFields:
    # A failed prepare may have released a level whose field handles are still
    # listed; retarget only controls that really exist in the accepted view.
    let control = win.controls.getOrDefault(handle)
    if control == nil: continue
    fields[control.window]=association
  win.annotations.retain(fields)
  for window,field in fields:win.annotations.annotate(window,field)

proc prepare(win: Win32Backend, batch: UpdateBatch) =
  win.checkLive()
  if win.prepared.len != 0: win.discardPrepared()
  # Rollback pin: established only for a new attempt. During the recovery path
  # the persistent vector is preserved across teardown and the recovery
  # prepare/apply, so the old frames survive the old host.
  if not win.restoring:
    win.rollbackFrames.setLen(0)
    win.pendingFrames.setLen(0)
    for handle, list in win.lists:
      if list.acceptedFrame != nil:
        win.rollbackFrames.add((handle, list.acceptedFrame.sourceGeneration,
          list.acceptedFrame, list.desiredOffset, list.intentGeneration))
  if batch.isDelta:
    win.candidate.clear()
    if win.measurement==nil:
      win.measurement=win.newMeasurement()
    inc win.depth
    defer:dec win.depth
    # Pass 1: the complete candidate entity view (a reused row needs its whole
    # subtree before any window is created). Entities removed by this batch are
    # recorded so the overlay preflight can exclude them.
    var removedHandles: HashSet[NodeHandle]
    for op in batch.ops:
      case op.kind
      of opCreate:
        if op.handle in win.current:fail("duplicate native handle")
        win.candidate[op.handle]=MountedEntity(handle:op.handle,parent:op.parent,
          index:op.index,nodeId:op.nodeId,kind:op.nodeKind,props:op.props,
          list:op.list,row:op.row,navigation:op.navigation,canvas:op.canvas,
          overlay:op.overlay,select:op.select,popover:op.popover)
      of opUpdate,opMove:
        if op.handle notin win.current:fail("unknown native handle")
        var entity=win.candidate.getOrDefault(op.handle,win.current.getOrDefault(op.handle))
        if op.kind==opUpdate:
          discard checkedWide(op.props.control.label.get(""))
          discard checkedWide(op.props.control.value.get(""))
          if entity.kind == NodeKind.input and
              entity.props.control.multiline.get(false) != op.props.control.multiline.get(false):
            fail("changing input multiline mode requires a new key")
          entity.props=op.props;entity.list=op.list;entity.row=op.row
          entity.navigation=op.navigation
          entity.canvas=op.canvas
          entity.overlay=op.overlay
          entity.select=op.select
          entity.popover=op.popover
        else:
          entity.parent=op.parent;entity.index=op.index
          if op.row.isSome:entity.row=op.row
        win.candidate[op.handle]=entity
      of opRemove:
        if op.handle notin win.current:fail("unknown native handle")
        removedHandles.incl(op.handle)
    # Pass 2: create windows; a direct row root first tries to reuse a parked
    # subtree with the same structural signature.
    win.validateNavigation(batch)
    win.prepareStandardUi(batch)
    for op in batch.ops:
      if op.kind != opCreate: continue
      let entity=win.candidate[op.handle]
      var reuse=false
      if entity.row.isSome:
        let signature=win.rowSignature(win.candidate,op.handle)
        let owner=entity.row.get.listHandle.raw
        # Claim one reusable group; the phase change is scalar and the group is
        # the single owner while it is re-keyed.
        let claimed = win.resources.takeParked(owner, signature)
        if claimed != nil:
          win.borrowGroup = claimed
          reuse = win.attachParkedRow(op.handle)
          if not reuse: win.borrowGroup = nil
      if not reuse: discard win.makeControl(entity)
    win.prepareCanvases()
    win.prepareModels()
    win.prepareOverlays(removedHandles)
    return
  win.candidate = win.current
  if win.measurement == nil:
    win.measurement = win.newMeasurement()
  inc win.depth
  defer: dec win.depth
  for op in batch.ops:
    case op.kind
    of opCreate, opMove:
      if op.kind == opMove:
        if op.handle notin win.candidate: fail("move of absent native control")
        let old = win.candidate[op.handle]
        for handle, entity in win.candidate.mpairs:
          if entity.parent == old.parent and entity.index > old.index: dec entity.index
      elif op.handle in win.candidate: fail("duplicate native handle")
      for handle, entity in win.candidate.mpairs:
        if entity.parent == op.parent and entity.index >= op.index: inc entity.index
      if op.kind == opCreate:
        let entity = MountedEntity(handle: op.handle, parent: op.parent, index: op.index,
          kind: op.nodeKind, nodeId: op.nodeId, props: op.props, list: op.list,
          row: op.row, navigation: op.navigation, canvas: op.canvas,
          overlay: op.overlay, select: op.select, popover: op.popover)
        win.candidate[op.handle] = entity
      else:
        win.candidate[op.handle].parent = op.parent
        win.candidate[op.handle].index = op.index
    of opUpdate:
      if op.handle notin win.candidate: fail("update of absent native control")
      discard checkedWide(op.props.control.label.get(""))
      discard checkedWide(op.props.control.value.get(""))
      if win.candidate[op.handle].kind == NodeKind.input and
          win.candidate[op.handle].props.control.multiline.get(false) != op.props.control.multiline.get(false):
        fail("changing input multiline mode requires a new key")
      win.candidate[op.handle].props = op.props
      win.candidate[op.handle].list = op.list
      win.candidate[op.handle].row = op.row
      win.candidate[op.handle].navigation = op.navigation
      win.candidate[op.handle].canvas = op.canvas
      win.candidate[op.handle].overlay = op.overlay
      win.candidate[op.handle].select = op.select
      win.candidate[op.handle].popover = op.popover
    of opRemove:
      when defined(leafProtocolProbes):
        echo "REMOVE op handle=", uint64(op.handle), " inCandidate=",
          win.candidate.hasKey(op.handle), " inCurrent=", win.current.hasKey(op.handle)
      if op.handle notin win.candidate: fail("remove of absent native control")
      let old = win.candidate[op.handle]
      win.candidate.del(op.handle)
      for handle, entity in win.candidate.mpairs:
        if entity.parent == old.parent and entity.index > old.index: dec entity.index
  if win.candidate.len > MaxNodes: fail("native entity budget exceeded")
  win.validateNavigation(batch)
  win.prepareStandardUi(batch)
  for op in batch.ops:
    if op.kind == opCreate: discard win.makeControl(win.candidate[op.handle])
  win.prepareCanvases()
  win.prepareModels()
  win.prepareOverlays()
proc apply(win: Win32Backend, batch: UpdateBatch) =
  win.checkLive()
  var needsLayout = win.dirty or win.fontDirty
  for op in batch.ops:
    if op.kind != opUpdate:
      needsLayout = true
    elif win.current.hasKey(op.handle) and
        layoutAffected(win.current[op.handle], win.candidate[op.handle]):
      needsLayout = true
  inc win.depth
  defer: dec win.depth
  win.applyTheme()
  for op in batch.ops:
    case op.kind
    of opCreate:
      let control = win.prepared[op.handle]
      win.controls[op.handle] = control
      win.prepared.del(op.handle)
      win.properties(control, win.candidate[op.handle])
    of opUpdate: win.properties(win.controls[op.handle], win.candidate[op.handle])
    of opRemove:
      let control = win.controls.getOrDefault(op.handle)
      when defined(leafProtocolProbes):
        echo "REMOVE control handle=", uint64(op.handle), " nil=", control == nil
      if control == nil: fail("remove of absent native control")
      if control.viewport:
        let first = win.releaseControlTree(control)
        if first != nil: raise first
      else:
        let root = win.rowRootOf(op.handle)
        if root == NoHandle:
          let first = win.releaseControlTree(control)
          if first != nil: raise first
        elif root == op.handle:
          # The root stays owned by `controls` until parkRow detaches the whole
          # subtree; deleting it first would make the claim look up nothing.
          if not win.parkRow(op.handle): win.destroyRowSubtree(op.handle)
        else:
          win.shedRow(op.handle)
    of opMove: discard
  for handle, entity in win.candidate:
    if win.controls.hasKey(handle): win.controls[handle].entity = entity
  var stale: seq[NodeHandle]
  for handle in win.retiring.keys:
    let root = win.rowRootOf(handle)
    if root == NoHandle or not win.controls.hasKey(root): stale.add(handle)
  for handle in stale: win.destroyRetiring(handle)
  if batch.isDelta:
    for op in batch.ops:
      if op.kind==opRemove:win.current.del(op.handle)
    for handle,entity in win.candidate:win.current[handle]=entity
    win.candidate.clear()
  else:win.current=win.candidate
  win.applyOverlayGeometry()
  if win.overlayDirty: needsLayout = true
  win.applyFields()
  if needsLayout and batch.ops.len > 0:
    let ctx = win.host.context
    # Commit-apply entry: candidate frames stay prepared until the real accept.
    win.applying = true
    try:
      win.relayout(DipSize(width: ctx.contentWidth, height: ctx.contentHeight), int(ctx.scale * 96))
    finally:
      win.applying = false
  win.reportError()
proc publishPendingFrames(win: Win32Backend) {.raises: [].} =
  ## Accept-side publication: only frames whose whole native apply already
  ## succeeded are handed over (pointer/scalar move). No OS call, no allocation,
  ## no measurement, and no Runtime revision change here.
  for handle in win.pendingFrames:
    let list = win.lists.getOrDefault(handle)
    if list == nil: continue
    list.publishPreparedFrame()
  win.pendingFrames.setLen(0)
  win.rollbackFrames.setLen(0)

proc accept(win: Win32Backend, entities: Table[NodeHandle, MountedEntity], revision: uint64) {.raises: [].} =
  win.revision = revision
  win.publishPendingFrames()
  for handle, control in win.controls.mpairs:
    if handle notin entities: continue
    let entity = entities.getOrDefault(handle)
    if control.canvas != nil: control.canvas.acceptPrepared()
    control.live.accept()
    control.acceptedNavigation = entity.navigation
    control.backEnabled = entity.props.control.hasBack and entity.props.control.enabled.get(true)
    var preparedAccept = false
    win.preparedModels.withValue(handle, prepared):
      control.editor.acceptPreparedModel(prepared[], revision, entity.props.control.resetToken)
      preparedAccept = true
    if not preparedAccept:
      control.editor.acceptModel(entity.value, revision, entity.props.control.resetToken)
    if control.editor.pendingReset.isSome: control.armed = false
    elif win.bound: control.armed = true
proc acceptDelta(win:Win32Backend,delta:HostAcceptedDelta) {.raises:[].}=
  # Accepted metadata is owned by the native consumer; the backend only
  # settles control editor models here. No table grows in the accept window.
  for entity in delta.upserts:
    let control=win.controls.getOrDefault(entity.handle)
    if control!=nil:
      if control.canvas!=nil:control.canvas.acceptPrepared()
      control.live.accept()
      control.acceptedNavigation=entity.navigation
      control.backEnabled=entity.props.control.hasBack and entity.props.control.enabled.get(true)
      var preparedAccept=false
      win.preparedModels.withValue(entity.handle,prepared):
        control.editor.acceptPreparedModel(prepared[],delta.revision,entity.props.control.resetToken)
        preparedAccept=true
      if not preparedAccept:
        control.editor.acceptModel(entity.value,delta.revision,entity.props.control.resetToken)
      if control.editor.pendingReset.isSome:control.armed=false
      elif win.bound:control.armed=true
  win.publishPendingFrames()
  win.revision=delta.revision
proc rebind(win: Win32Backend, id, generation: uint64) =
  win.checkLive()
  if id == 0 or generation == 0: fail("invalid native binding identity")
  win.sessionId = id; win.generation = generation
  win.sequence = 0
  win.rebound = true
  for control in win.controls.values: win.arm(control)
proc restore(win: Win32Backend, entities: Table[NodeHandle, MountedEntity]) =
  win.checkLive()
  # The persistent rollback vector is intentionally *not* cleared here: it must
  # survive the teardown and the recovery prepare/apply, because the old list
  # hosts (and their frames) are gone after `releaseResources`.
  win.pendingFrames.setLen(0)
  win.restoreReplayCount = 0
  win.restoreAppliedCount = 0
  win.restoreMeasureBase = win.rowMeasureCount
  win.restoreCacheBase = win.measureCacheHits
  # Capture the latest intent before teardown destroys its list host. The frame
  # pin stays immutable, while a genuine scroll may have arrived during apply.
  for pin in win.rollbackFrames.mitems:
    let list = win.lists.getOrDefault(pin.handle)
    if list != nil:
      pin.desiredOffset = list.desiredOffset
      pin.intentGeneration = list.intentGeneration
  var watermarks: Table[NodeHandle, uint64]
  for handle, control in win.controls: watermarks[handle] = control.editor.consumedResetToken
  let teardown = win.releaseResources(0, true, win.controlEntries(true))
  if teardown != nil: raise teardown
  win.lists.clear()
  win.current.clear()
  win.appliedOrders.clear()
  var ordered: seq[MountedEntity]
  for entity in entities.values: ordered.add(entity)
  ordered.sort(proc(a,b: MountedEntity): int = cmp(uint64(a.handle),uint64(b.handle)))
  var batch = UpdateBatch(revision: win.revision)
  for entity in ordered:
    batch.ops.add UpdateOp(kind: opCreate, handle: entity.handle, parent: entity.parent,
      index: entity.index, nodeKind: entity.kind, nodeId: entity.nodeId,
      props: entity.props, list: entity.list, row: entity.row,
      navigation: entity.navigation, canvas: entity.canvas,
      overlay: entity.overlay)
  # Rollback replay entry: the pinned accepted frames are installed by relayout
  # *before* any measurement, so the rejected candidate is never re-measured and
  # no ordinary measure/layout pass runs first.
  win.restoring = true
  try:
    win.prepare(batch)
    win.apply(batch)
  finally:
    win.restoring = false
    win.rollbackFrames.setLen(0)
    win.pendingFrames.setLen(0)
  for handle, control in win.controls.mpairs:
    control.armed = false
    control.editor.consumedResetToken = watermarks.getOrDefault(handle)
  win.accept(entities, win.revision)
  for control in win.controls.values: control.armed = false
proc settle(win: Win32Backend, settlement: EventSettlement) =
  win.checkLive()
  if settlement.handle notin win.controls: return
  let control = win.controls[settlement.handle]
  if settlement.bindingGeneration != control.binding: return
  win.applyEffects(control, control.editor.settleEditor(settlement.sequence))
  if control.editor.phase == compositionEnd: control.editor.phase = compositionNone
  win.reportError()
proc listProtected(win: Win32Backend, listHandle: NodeHandle): seq[int] =
  ## Item indices of rows that must stay materialized: the focused row and any
  ## row with an active composition, found through the native parent chain.
  let focused = win.calls.focusWindow()
  var window = focused
  var depth = 0
  var rowRoot = NoHandle
  while window != nil and depth <= MaxDepth:
    for handle, control in win.controls:
      if control.window != window: continue
      if control.entity.row.isSome and control.entity.row.get.listHandle == listHandle:
        rowRoot = handle
      if control.entity.kind == NodeKind.input and
          control.editor.phase != compositionNone:
        let root = win.rowRootOf(handle)
        if root != NoHandle and win.controls.hasKey(root) and
            win.controls[root].entity.row.isSome and
            win.controls[root].entity.row.get.listHandle == listHandle:
          result.add(win.controls[root].entity.row.get.itemIndex)
      break
    if rowRoot != NoHandle: break
    window = GetParent(window)
    inc depth
  if rowRoot != NoHandle:
    let binding = win.controls[rowRoot].entity.row.get
    if binding.itemIndex notin result: result.add(binding.itemIndex)

proc hasDesiredRowset(win: Win32Backend, list: Win32ListHost): bool =
  ## Geometry may advance without a Runtime transaction only when the accepted
  ## typed rows already equal this intent's visible + overscan + protected set.
  ## A range/offset change alone does not imply that the materialized set changed.
  let frame = list.acceptedFrame
  if frame == nil or frame.sourceGeneration != list.props.sourceGeneration:
    return false
  let visible = list.desiredRange
  let first = max(0, visible.first - max(0, list.props.overscan))
  let finish = min(list.props.itemCount,
    visible.finish + max(0, list.props.overscan))
  let protected = win.listProtected(list.handle)
  var inside = 0
  for binding in frame.rows:
    if binding.sourceGeneration != list.props.sourceGeneration: return false
    if binding.itemIndex >= first and binding.itemIndex < finish:
      inc inside
    elif binding.itemIndex notin protected:
      return false
  if inside != finish - first: return false
  for index in protected:
    if index < 0 or index >= list.props.itemCount: continue
    if index >= first and index < finish: continue
    var present = false
    for binding in frame.rows:
      if binding.itemIndex == index:
        present = true
        break
    if not present: return false
  true

proc publishListFacts(win: Win32Backend) =
  ## One safe-turn step: turn recorded scroll intent into owned viewport facts.
  ## Only one fact per list per turn; a refused fact (backpressure) waits for a
  ## later real turn instead of spinning.
  if win.session == nil: return
  for listHandle, list in win.lists:
    if list.generation == 0: continue
    let range = list.desiredRange
    let moved = list.desiredOffset != list.appliedOffset
    if not (list.want or moved or range.first != list.appliedFirst or
        range.finish != list.appliedFinish): continue
    if list.props.heightMode == HostHeightMode.variable and
        win.hasDesiredRowset(list):
      # The ordinary geometry phase applies this intent to the accepted rows.
      # Re-requesting the identical set would publish empty Runtime revisions.
      continue
    if range.finish <= range.first and list.heights != nil and
        list.heights[].len > 0: continue
    let protected = win.listProtected(listHandle)
    let fact = list.viewportFact(win.sessionId, win.generation, protected)
    if win.session.queueRows(fact):
      list.want = false
      list.noteRowFactRequested(fact.first, fact.finish)
      inc win.stats.scrollTicks

proc listGeometry(win: Win32Backend) =
  ## At most one bounded geometry pass per turn, and only for a list whose applied
  ## typed rows cover the desired viewport (a failed or pending fact never exposes
  ## a half-new rowset). The geometry attempt prepares/applies/publishes its own
  ## measured plan; applied range equality is not a rowset readiness test.
  if win.lists.len == 0: return
  var ready = true
  for listHandle, list in win.lists:
    let range = list.desiredRange
    if list.props.heightMode == HostHeightMode.variable:
      if not win.hasDesiredRowset(list):
        # The pending fact is already recorded by the publication ack (or was
        # refused by backpressure); a geometry pass must not invent applied rows.
        ready = false
      elif list.desiredOffset != list.appliedOffset or
          range.first != list.appliedFirst or range.finish != list.appliedFinish or
          list.correctionDue:
        # Same typed set: use the transactional geometry path without a business
        # commit. It publishes only after every list's native placement succeeds.
        win.listDirty = true
    else:
      var present = 0
      for handle, entity in win.current:
        if entity.row.isSome and entity.row.get.listHandle == listHandle and
            entity.row.get.itemIndex >= range.first and
            entity.row.get.itemIndex < range.finish:
          inc present
      if present < max(0, range.finish - range.first): ready = false
  if not ready: return
  for listHandle, list in win.lists:
    if list.props.heightMode == HostHeightMode.variable:
      # A measured list applies and publishes its own plan inside the pass; no
      # accepted scalar may move here.
      continue
    let range = list.desiredRange
    if list.desiredOffset != list.appliedOffset or
        range.first != list.appliedFirst or range.finish != list.appliedFinish:
      list.confirmOffset(list.desiredOffset, range.first, range.finish)
      win.listDirty = true
  if win.listDirty or win.dirty:
    win.geometryRelayout()

proc maintainPointers(win: Win32Backend) =
  # Acceptance only publishes metadata. Reconcile OS capture at an ordinary
  # boundary, even when the new geometry makes further mouse messages impossible.
  for control in win.controls.values:
    if control.canvas != nil and control.pointerMachine != nil and control.pointerOwner.isSome:
      discard control.currentPointerTarget()
      win.flushPointer(control)

type FocusOwnerPosition = object
  window,insertAfter: HWND
  x,y,width,height: int32
  flags: UINT

proc GetAncestor(window: HWND,flags: UINT): HWND {.stdcall,dynlib:"user32.dll",importc,raises:[].}

proc maintainFocus(win: Win32Backend) =
  let target=GetFocus()
  let role=if target!=nil:standardRole(target) else:none(UiRole)
  # EDIT's active editing/caret context remains focus-visible even when its
  # native UI-state still hides button focus cues (normally query value 3).
  if not win.theme.isShadcn or highContrastActive() or target==nil or
      GetForegroundWindow()!=win.host.windowHandle or
      GetAncestor(target,2)!=win.host.windowHandle or
      role.isNone or role.get notin {UiRole.button,UiRole.input,UiRole.textarea,UiRole.checkbox,UiRole.switch} or
      IsWindowVisible(target)==0 or IsWindowEnabled(target)==0 or
      (role.get in {UiRole.button,UiRole.checkbox,UiRole.switch} and
        (SendMessageW(target,0x0129,0,0) and 1)!=0):
    hideFocusRing(win.focusAdornment)
    return
  if role.get in {UiRole.checkbox,UiRole.switch}:
    let glyph=checkMetrics(role.get,standardSize(target))
    showFocusRing(win.focusAdornment,win.host.windowHandle,target,
      standardFocusColor(win.theme,target),win.calls,radiusDip=glyph.radius,
      anchorWidthDip=glyph.width,anchorHeightDip=glyph.height)
  else:
    let group=if role.get==UiRole.input:inputGroupOf(target) else:nil
    showFocusRing(win.focusAdornment,win.host.windowHandle,(if group!=nil:group else:target),
      standardFocusColor(win.theme,target),win.calls)

proc maintainLive(win: Win32Backend) =
  if win.liveContext == nil: return
  # No outbound UIA calls inside accept, window callbacks or apply. Hold the
  # existing local-busy fence against COM reentry while flushing stable leases.
  inc win.depth
  defer: dec win.depth
  win.liveContext.drainRetired()
  var providers: seq[LiveProvider]
  for control in win.controls.values:
    if control.live != nil: providers.add(control.live)
  for provider in providers: discard provider.flush()

proc safeListTurn*(win: Win32Backend) =
  ## Production and test entry for one ordinary native list turn:
  ## genuine events -> this turn's viewport facts -> one bounded drain -> one
  ## bounded geometry pass. Never called from a window callback.
  win.checkLive()
  if win.session == nil: return
  win.reportError()
  win.maintainPointers()
  # A recorded modal close request becomes one typed event before this turn
  # drains, exactly like the production native turn.
  win.overlayTurn()
  win.selectTurn()
  win.popoverTurn()
  for list in win.lists.values: list.beginGeometryTurn()
  win.session.drainEvents()
  win.publishListFacts()
  discard win.session.drainRowRequests()
  win.listGeometry()
  win.maintainFocus()
  win.maintainLive()
  win.reportError()

proc nativeTurn(win: Win32Backend) =
  win.checkLive()
  win.reportError()
  for control in win.controls.values:
    if control.canvas != nil:
      control.canvas.recoverOnce()
      control.canvas.maintain()
  win.maintainPointers()
  for list in win.lists.values: list.beginGeometryTurn()
  if win.fontDirty:
    let fresh = win.newMeasurement()
    discard fresh.ensureFont()
    win.retiredMeasures.add(win.measurement)
    win.measurement = fresh
    for control in win.controls.values:
      discard win.calls.send(control.window, WM_SETFONT, cast[WPARAM](fresh.ensureFont(win.fontRole(control.entity))), 1)
    inc win.fontEpoch
    win.fontDirty = false
    win.cache.clear()
    for old in win.retiredMeasures:
      if old != nil: old.close()
    win.retiredMeasures.setLen(0)
  for control in win.controls.values:
    if control.editor.pendingReset.isSome:
      let token = control.editor.pendingReset.get
      win.applyEffects(control, control.editor.resetEffects())
      control.editor.completeReset(token)
      win.arm(control)
  if win.dirty and win.current.len > 0:
    win.geometryRelayout()
  else:
    for list in win.lists.values:
      if list.correctionDue:
        win.listGeometry()
        break
  win.overlayTurn()
  win.selectTurn()
  win.popoverTurn()
  win.maintainFocus()
  win.maintainLive()
proc tick(win: Win32Backend) =
  try: win.nativeTurn()
  except CatchableError as error:
    if win.session != nil and win.session.ownsBackend(win.protocol):
      win.session.faultBackendEffects(win.protocol, "native effects failed: " & error.msg)
    raise error

proc dispose(win: Win32Backend) =
  win.checkOwner()
  if win.closed: return
  closeFocusRing(win.focusAdornment)
  win.disposeOverlays()
  win.disposeSelects()
  win.disposePopovers()
  if win.selectContext != nil:
    win.selectContext.drainRetired()
    win.selectContext.close()
    win.selectContext = nil
  win.releaseContexts()
  win.releaseRegions()
  let first = win.releaseResources(0, true, win.controlEntries(true))
  if first != nil: raise first
  win.lists.clear()
  win.annotations.close()
  win.liveContext.close()
  if win.measurement != nil: win.measurement.close()
  for old in win.retiredMeasures:
    if old != nil: old.close()
  win.retiredMeasures.setLen(0)
  win.current.clear(); win.preparedModels.clear(); win.cache.clear()
  # Every binding was retired by the release above; a residue is a bug and must
  # be visible, never silently cleared.
  if win.bindings.len != 0:
    fail("native binding store still owns " & $win.bindings.len &
      " controls after release")
  win.closed = true
proc newWin32Backend*(host: Win32Host, calls: Win32Calls = systemWin32Calls(),
    renderer = CanvasRenderer.hardware): Win32Backend =
  discard host.context
  let win = Win32Backend(host: host, theme: host.nativeTheme, initialTheme: host.nativeTheme,
    preparedTheme: host.nativeTheme, renderer: renderer,
    calls: calls, owner: GetCurrentThreadId())
  win.selectContext = newSelectContext()
  win.selectContext.setWake(host.windowHandle, WM_HOST_TICK)
  win.protocol = Backend(capabilities: win32Capabilities(win.theme))
  win.protocol.prepare = proc(batch: UpdateBatch) = win.prepare(batch)
  win.protocol.apply = proc(batch: UpdateBatch) = win.apply(batch)
  win.protocol.discardPrepared = proc() = win.discardPrepared()
  win.protocol.restore = proc(entities: Table[NodeHandle, MountedEntity]) = win.restore(entities)
  win.protocol.dispose = proc() = win.dispose()
  win.protocol.acceptedDelta=proc(delta:HostAcceptedDelta) {.raises:[].}=win.acceptDelta(delta)
  win.protocol.accepted = proc(entities: Table[NodeHandle, MountedEntity], revision: uint64) {.raises: [].} = win.accept(entities, revision)
  win.protocol.rebind = proc(id, generation: uint64) = win.rebind(id, generation)
  win.protocol.bindingValid = proc(handle: NodeHandle, generation: uint64): bool =
    let control = win.controls.getOrDefault(handle)
    control != nil and control.window != nil and control.armed and control.binding == generation
  win.protocol.projectCanvasInput = proc(handle: NodeHandle, source: CanvasPointerEvent): Option[CanvasDelivery] =
    let control = win.controls.getOrDefault(handle)
    if control == nil or control.canvas == nil: return none(CanvasDelivery)
    control.canvas.projectInput(source)
  win.protocol.settle = proc(value: EventSettlement) = win.settle(value)
  win.lease = host.claimBackendOwner(HostBackendBridge(
    syncFocusTraversal: proc(target: HWND) = win.syncFocusedListTraversal(target),
    modalScrollable: proc(): bool {.raises: [].} =
      {.cast(raises: []).}:
        if win.overlayStack.order.len == 0: return false
        let overlay = win.overlays.getOrDefault(NodeHandle(win.overlayStack.topOverlay))
        if overlay == nil: return false
        let plan = win.overlayAcceptedPlans.getOrDefault(
          NodeHandle(win.overlayStack.topOverlay))
        overlay.isVisible and (plan.rangeY > 0.0 or plan.rangeX > 0.0),
    pointerButton: proc(window: HWND) {.raises: [].} =
      {.cast(raises: []).}:
        win.popoverPointerButton(window),
    modalTarget: proc(): HWND {.raises: [].} =
      {.cast(raises: []).}:
        if win.overlayStack.order.len == 0: return nil
        let overlay = win.overlays.getOrDefault(NodeHandle(win.overlayStack.topOverlay))
        if overlay == nil: return nil
        if overlay.isVisible: overlay.surfaceHandle else: nil,
    capture: proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): bool {.raises: [].} =
      try:
        {.cast(raises: [CatchableError]).}:
          if message==0x0006 and (wp and 0xffff)==0:
            hideFocusRing(win.focusAdornment)
          elif message==0x0046 and lp!=0 and
              (cast[ptr FocusOwnerPosition](lp).flags and 3)!=3:
            # Pure z-order/activation changes while arranging owned windows
            # must not hide the overlay being shown; only geometry hides it.
            hideFocusRing(win.focusAdornment)
          if message == WM_COMMAND: return win.command(window, wp, lp)
          return win.captureNavigation(message, wp, lp)
      except CatchableError as error: win.markError(error),
    invalidate: proc(ctx: HostContext, reasons: set[NativeInvalidation]) {.raises: [].} =
      win.dirty = true
      if fontChanged in reasons or themeChanged in reasons: win.fontDirty = true
      win.cache.clear(),
    nativeTick: proc() = win.tick(),
    localBusy: proc(): bool {.raises: [].} = win.depth != 0,
    resourcesReleased: proc(): bool {.raises: [].} = win.closed and (win.session == nil or win.session.disposed),
    matchesSession: proc(session: BackendSession): bool {.raises: [].} =
      win.bound and win.session == session and session.ownsBackend(win.protocol),
    closeStartup: proc() =
      if win.session != nil: win.session.dispose()
      elif not win.closed and win.rebound: fail("NeedsContext: unobserved retained Session cannot release startup owner")
      else: win.dispose()))
  var common = INITCOMMONCONTROLSEX(dwSize: DWORD(sizeof(INITCOMMONCONTROLSEX)), dwICC: ICC_PROGRESS_CLASS)
  if initControls(addr common) == 0: nativeError("InitCommonControlsEx")
  win
when defined(leafProtocolProbes):
  proc observeCompositionForTest*(win: Win32Backend, handle: NodeHandle,
      text: string) =
    ## Probe-only seam: put the editor into an active composition without
    ## driving OS IME messages, so the prepared conflict path is measurable.
    win.checkLive()
    let control = win.controls.getOrDefault(handle)
    if control == nil: fail("missing editor control")
    control.editor.observeEditor(ControlValue(text: text), compositionStart,
      Selection16(), control.editor.latestObserved + 1)

  proc conflictTextForTest*(win: Win32Backend, handle: NodeHandle): string =
    let control = win.controls.getOrDefault(handle)
    if control == nil or control.editor.conflict.isNone: return ""
    control.editor.conflict.get.text

proc asBackend*(win: Win32Backend): Backend = win.checkOwner(); win.protocol
proc bindSession*(win: Win32Backend, session: BackendSession) =
  win.checkLive()
  if session == nil or not session.ownsBackend(win.protocol): fail("foreign backend session")
  if win.bound or (win.session != nil and win.session != session): fail("native Session already bound")
  if session.sessionId != win.host.context.sessionId: fail("foreign Host Session")
  win.session = session; win.bound = true
  for control in win.controls.values: win.arm(control)
proc attachWin32Backend*(win: Win32Backend, runtime: Runtime, mode: CapabilityMode = compatible): BackendSession =
  win.checkLive()
  attachBackendObserved(runtime, win.protocol, win.host.context, mode,
    proc(session: BackendSession) {.raises: [].} = win.session = session)

when defined(leafProtocolProbes):
  proc selectHostForTest*(win: Win32Backend, handle: NodeHandle): Win32Select =
    ## Test-only access to the accepted select host (provider + geometry).
    win.checkOwner()
    win.selects.getOrDefault(handle)

  proc selectStateForTest*(win: Win32Backend, handle: NodeHandle): tuple[
      live, visible: bool, popup: HWND, candidate, firstRow, rows: int,
      rect: tuple[x, y, width, height: int32], closes, commits, requests,
      gateDrops, liveSelects, shows, repositions: int] =
    ## Test-only read-only observation of the accepted anchored popup.
    win.checkOwner()
    let host = win.selects.getOrDefault(handle)
    result.live = host != nil
    result.visible = host != nil and host.isVisible
    result.popup = if host == nil: nil else: host.popupHandle
    if host != nil:
      result.candidate = host.selectedCandidate
      result.firstRow = host.firstRow
      result.rows = host.rows
    result.rect = win.selectRects.getOrDefault(handle)
    result.closes = win.stats.selectCloses
    result.commits = win.stats.selectCommits
    result.requests = win.stats.selectRequests
    result.gateDrops = win.stats.selectGateDrops
    result.liveSelects = win.stats.liveSelects
    result.shows = win.stats.selectShows
    result.repositions = win.stats.selectRepositions

  proc liveProviderCountsForTest*(win: Win32Backend): tuple[owned,objects:int] =
    win.liveContext.counts()

  proc overlayStateForTest*(win: Win32Backend): tuple[live, open, visible,
      disabledOwners, plans, acceptedPlans, pendingFocus, gateDrops,
      shrinkFallbacks, unexpectedCompositions, unsupportedShrinks: int,
      publishPending: bool, top, scrim: HWND] =
    ## Test-only read-only observation of the accepted modal levels.
    win.checkOwner()
    result.live = win.overlays.len
    result.open = win.overlayStack.order.len
    result.plans = win.overlayPlans.len
    result.acceptedPlans = win.overlayAcceptedPlans.len
    result.pendingFocus = win.overlayPendingFocus.len
    result.gateDrops = int(win.overlayGateDrops)
    result.shrinkFallbacks = win.overlayShrinkFallbacks
    result.unexpectedCompositions = win.overlayUnexpectedCompositions
    result.unsupportedShrinks = win.overlayUnsupportedShrinks
    result.publishPending = win.overlayPublishPending
    for overlay in win.overlays.values:
      if overlay.isVisible:
        inc result.visible
        if overlay.ownsDisabledOwner: inc result.disabledOwners
    if win.overlayStack.order.len != 0:
      let top = win.overlays.getOrDefault(NodeHandle(win.overlayStack.topOverlay))
      if top != nil and top.isVisible:
        result.top = top.surfaceHandle
        result.scrim = top.scrimHandle

  proc overlaySurfaceForTest*(win: Win32Backend, handle: NodeHandle): HWND =
    win.checkOwner()
    let overlay = win.overlays.getOrDefault(handle)
    if overlay == nil: return nil
    overlay.surfaceHandle

  proc overlayPlanForTest*(win: Win32Backend, handle: NodeHandle): OverlayPlan =
    win.checkOwner()
    win.overlayAcceptedPlans.getOrDefault(handle)

  proc overlayHandleForTest*(win: Win32Backend, index: int): NodeHandle =
    ## Published stack entry by level, bottom-up.
    win.checkOwner()
    if index < 0 or index >= win.overlayStack.order.len: return NoHandle
    NodeHandle(win.overlayStack.order[index])

  proc overlayWindowsLiveForTest*(win: Win32Backend, handle: NodeHandle): bool =
    win.checkOwner()
    let overlay = win.overlays.getOrDefault(handle)
    overlay != nil and not overlay.resourcesReleased

  proc focusAdornmentForTest*(win: Win32Backend): HWND =
    win.focusAdornment.windowHandle

  proc popoverCountForTest*(win: Win32Backend): int =
    ## Probe-only receipt: how many owned panel hosts the backend still keeps.
    win.stats.livePopovers

  proc popoverStateForTest*(win: Win32Backend, handle: NodeHandle):
      Win32Popover =
    ## Native test accessor: the live panel host of one accepted popover root.
    win.popovers.getOrDefault(handle)

  proc nativeWindowForTest*(win: Win32Backend, handle: NodeHandle): HWND =
    win.checkLive()
    let control = win.controls.getOrDefault(handle)
    if control != nil and control.entry != nil and
        win.controlFor(control.bindingToken) == control and
        cast[HWND](control.entry.window) == control.window:
      return control.window

  proc canvasWindowForTest*(win: Win32Backend, handle: NodeHandle): HWND =
    let control = win.controls.getOrDefault(handle)
    if control != nil and control.canvas != nil: return win.nativeWindowForTest(handle)

  proc rowWindowForTest*(win: Win32Backend, rootHandle: NodeHandle): HWND =
    ## Test-only read-only observation: the live HWND of a current accepted row
    ## root. It resolves the handle through the existing control index and then
    ## re-checks liveness through the existing typed binding store (the strong
    ## lease must still be this very control, with a matching entry/window and
    ## entity handle). It installs no userdata, reads no raw pointer/RootRef back,
    ## never uses IsWindow to zero ownership, and changes no table, counter or
    ## lifetime. Returns nil when the handle is unknown, not a current row root,
    ## no longer strongly bound, or window-less.
    if win == nil: return nil
    win.checkLive()
    if rootHandle == NoHandle: return nil
    let entity = win.current.getOrDefault(rootHandle)
    if entity.handle != rootHandle or entity.row.isNone: return nil
    let indexed = win.controls.getOrDefault(rootHandle)
    if indexed == nil or indexed.bindingToken == 0'u64: return nil
    let bound = win.controlFor(indexed.bindingToken)
    if bound == nil or bound != indexed: return nil
    if bound.entity.handle != rootHandle: return nil
    if bound.window == nil: return nil
    if bound.entry == nil: return nil
    if cast[HWND](bound.entry.window) != bound.window: return nil
    bound.window

when defined(leafProtocolProbes):
  proc listIntentForTest*(win: Win32Backend, listHandle: NodeHandle):
      tuple[valid: bool, desiredOffset, appliedOffset: float64,
            intentGeneration: uint64] =
    ## RED instrumentation only: scalar reads from the existing typed host.
    ## No pointer readback, mutation, allocation or new lifetime authority.
    win.checkLive()
    let list = win.lists.getOrDefault(listHandle)
    if list != nil:
      result = (true, list.desiredOffset, list.appliedOffset,
        list.intentGeneration)

  type ListFrameFacts* = object
    ## Read-only scalar/per-index view of one list's private frames. Observational
    ## only: no physical identity, no owner claim, no business data.
    hasAccepted*, hasPrepared*, hasFailed*: bool
    acceptedSource*, preparedSource*: uint64
    acceptedOffset*, preparedOffset*: float64
    acceptedFirst*, acceptedFinish*: int
    acceptedMeasured*, preparedMeasured*: int
    acceptedFrameId*, preparedFrameId*, failedFrameId*: uint64
    acceptedToken*, preparedToken*: uint64
      ## Backend-wide plan tokens: they survive a recreated host, so a recovery
      ## receipt can be tied to the very accepted plan, not to a resetting id.
    rowsetReady*, rowsPending*, trimPending*: bool
    neededFirst*, neededFinish*: int
    failedPhase*: string
    acceptedRows*: seq[tuple[index: int, key: string, height, prefix: float64]]
    failedHeights*: seq[tuple[index: int, height: float64]]

  proc listFrameForTest*(win: Win32Backend, listHandle: NodeHandle): ListFrameFacts =
    win.checkLive()
    let list = win.lists.getOrDefault(listHandle)
    if list == nil: return
    if list.acceptedFrame != nil:
      let frame = list.acceptedFrame
      result.hasAccepted = true
      result.acceptedSource = frame.sourceGeneration
      result.acceptedOffset = frame.offset
      result.acceptedFirst = frame.first
      result.acceptedFinish = frame.finish
      result.acceptedMeasured = frame.measuredRows
      result.acceptedFrameId = frame.frameId
      result.acceptedToken = frame.token
      result.rowsetReady = frame.rowsetReady
      result.rowsPending = frame.rowsPending
      result.trimPending = frame.trimPending
      result.neededFirst = frame.neededFirst
      result.neededFinish = frame.neededFinish
      if frame.heights != nil:
        for row in frame.rows:
          if row.itemIndex < 0 or row.itemIndex >= frame.heights[].len: continue
          result.acceptedRows.add((row.itemIndex, row.itemKey,
            frame.heights[].height(row.itemIndex),
            frame.heights[].prefix(row.itemIndex)))
    if list.preparedFrame != nil:
      let frame = list.preparedFrame
      result.hasPrepared = true
      result.preparedSource = frame.sourceGeneration
      result.preparedOffset = frame.offset
      result.preparedMeasured = frame.measuredRows
      result.preparedFrameId = frame.frameId
      result.preparedToken = frame.token
    if list.failedFrame != nil and list.failedFrame.heights != nil:
      let frame = list.failedFrame
      result.hasFailed = true
      result.failedFrameId = frame.frameId
      result.failedPhase = list.failedPhase
      for row in frame.rows:
        if row.itemIndex < 0 or row.itemIndex >= frame.heights[].len: continue
        result.failedHeights.add((row.itemIndex,
          frame.heights[].height(row.itemIndex)))
    elif win.lastFailedValid and win.lastFailedFrame != nil and
        win.lastFailedFrame.heights != nil:
      # The bounded metadata reference survives the old host teardown; the index
      # is materialised here, outside any fence or exception chain.
      let frame = win.lastFailedFrame
      result.hasFailed = true
      result.failedFrameId = frame.frameId
      result.failedPhase = win.lastFailedPhase
      for row in frame.rows:
        if row.itemIndex < 0 or row.itemIndex >= frame.heights[].len: continue
        result.failedHeights.add((row.itemIndex,
          frame.heights[].height(row.itemIndex)))

when defined(leafProtocolProbes):
  proc frameScalarsForTest*(win: Win32Backend, listHandle: NodeHandle):
      tuple[acceptedValid: bool, preparedValid: bool, preparedMeasured: int32,
      preparedRow0, acceptedRow0: float64] =
    ## Allocation-free scalar query used by an injection wrapper: it only reads
    ## refs and scalars, never a sequence.
    win.checkLive()
    let list = win.lists.getOrDefault(listHandle)
    if list == nil: return
    if list.acceptedFrame != nil and list.acceptedFrame.heights != nil:
      result.acceptedValid = true
      if list.acceptedFrame.heights[].len > 0:
        result.acceptedRow0 = list.acceptedFrame.heights[].height(0)
    if list.preparedFrame != nil and list.preparedFrame.heights != nil:
      result.preparedValid = true
      result.preparedMeasured = int32(list.preparedFrame.measuredRows)
      if list.preparedFrame.heights[].len > 0:
        result.preparedRow0 = list.preparedFrame.heights[].height(0)

when defined(leafProtocolProbes):
  proc restoreReceiptsForTest*(win: Win32Backend):
      tuple[replayed, measured, applied, cacheHits: int32] =
    ## Read-only scalars of the recovery window, each named separately: pinned
    ## plans selected (`replayed`), rows that entered the real row-measurement
    ## entry (`measured`), whole plans whose native apply completed (`applied`)
    ## and measurement cache hits (`cacheHits`). No sequence is built here.
    (int32(win.restoreReplayCount),
     int32(win.rowMeasureCount - win.restoreMeasureBase),
     int32(win.restoreAppliedCount),
     int32(win.measureCacheHits - win.restoreCacheBase))

proc canvasDiagnostics*(win: Win32Backend, handle: NodeHandle): CanvasDiagnostics =
  win.checkOwner()
  let control = win.controls.getOrDefault(handle)
  if control == nil or control.canvas == nil: fail("Canvas handle is not live")
  control.canvas.diagnostics

when defined(leafCanvasMeasure):
  proc canvasWindowForMeasurementInternal*(win: Win32Backend, handle: NodeHandle): HWND =
    ## Instrumented standalone producer only; no API/clock cost in default builds.
    win.checkOwner()
    let control = win.controls.getOrDefault(handle)
    if control == nil or control.canvas == nil: fail("Canvas handle is not live")
    control.window

  proc repaintCanvasForMeasurementInternal*(win: Win32Backend, handle: NodeHandle): bool =
    ## Same accepted-frame paint path as WM_PAINT, never a second commit path.
    win.checkOwner()
    let control = win.controls.getOrDefault(handle)
    if control == nil or control.canvas == nil: fail("Canvas handle is not live")
    control.canvas.paintAccepted()

proc diagnostics*(win: Win32Backend): Win32Diagnostics =
  win.checkOwner()
  result = win.stats
  result.liveWindows+=ord(win.focusAdornment.windowHandle!=nil)
  for control in win.controls.values:
    result.liveWindows += ord(control.window != nil)
    result.liveSubclasses += ord(control.subclassed)
  for control in win.prepared.values:
    result.liveWindows += ord(control.window != nil)
    result.liveSubclasses += ord(control.subclassed)
  result.liveFonts = if win.measurement == nil: 0 else: win.measurement.liveFonts
  if win.measurement != nil: result.liveWindows += win.measurement.liveMeasureWindows
  for old in win.retiredMeasures:
    if old != nil:
      result.liveFonts += old.liveFonts
      result.liveWindows += old.liveMeasureWindows
  result.listViewports = win.lists.len
  for list in win.lists.values: result.scrollTicks = list.scrollbars
  result.parkedRows = win.resources.liveGroups()
  result.reusedRows = win.reusedBorrows
  for handle, entity in win.current:
    if entity.row.isSome: inc result.liveRows
  result.liveRoots = ord(win.host.backendOwnerActive(win.lease))
  for control in win.controls.values:
    result.liveRoots += ord(controlsByCookie.getOrDefault(control.cookie) == control)
  for control in win.prepared.values:
    result.liveRoots += ord(controlsByCookie.getOrDefault(control.cookie) == control)

when defined(leafProtocolProbes):
  proc fieldAnnotationCountsForTest*(win:Win32Backend):tuple[services,windows:int] =
    win.checkOwner()
    win.annotations.counts()
