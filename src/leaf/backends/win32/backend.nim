## Owned Unicode controls, incremental updates and native event capture.
import std/[tables, options, algorithm, widestrs, sets]
import ../../[core, styles, backend, backend_session, native_layout, native_edit, native_measure_cache,
  height_index, native_list_layout, native_theme, graphics, canvas_input]
import ./[api, calls, host, capabilities, measure, control_ids, list_host, row_pool,
  resource_owner, navigation_input, skin, canvas]

type
  Win32Diagnostics* = object
    creates*, destroys*, setTexts*, measures*, layouts*, callbackErrors*: uint64
    liveWindows*, liveFonts*, liveSubclasses*, liveRoots*: int
    listViewports*, liveRows*, parkedRows*, reusedRows*, scrollTicks*: int
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
    pointerMachine: CanvasPointerMachine
    pointerOwner: Option[CanvasBindingId]
    lastPointer: PointerSample
    trackingMouse: bool
    acceptedNavigation: Option[HostNavigationProps]
    backEnabled: bool
    capture: proc(control: NativeControl, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT {.closure.}
  Win32Backend* = ref object
    host: Win32Host
    theme: NativeTheme
    renderer: CanvasRenderer
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

proc fontRole(win: Win32Backend, entity: MountedEntity): NativeFontRole =
  if win.theme != systemTheme and entity.kind == NodeKind.button: return captionFont
  if win.theme != systemTheme and entity.kind == NodeKind.text:
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

proc label(entity: MountedEntity): string =
  if entity.kind == NodeKind.input: entity.props.control.value.get("")
  else: entity.props.control.label.get(entity.props.accessibility.label.get(""))
proc value(entity: MountedEntity): ControlValue =
  ControlValue(text: entity.props.control.value.get(""),
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
proc sendEvent(win: Win32Backend, control: NativeControl, kind: EventKind,
               phase = compositionNone) =
  if not control.armed or control.setterDepth != 0 or win.session == nil or
      win.session.closing or win.session.disposed or win.session.faulted: return
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
      if code == 0: win.sendEvent(control, click)
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
    if message == 0x0007: win.syncFocusedListTraversal(control.window) # WM_SETFOCUS
    elif message == 0x0008: win.syncFocusedListTraversal(cast[HWND](wp)) # WM_KILLFOCUS
    var paintReply: LRESULT
    if skinMessage(win.theme, control.window, message, wp, lp, paintReply): return paintReply
    if win.captureNavigation(message, wp, lp):
      return if message == BackAppCommand: 1 else: 0
    if message == WM_COMMAND and win.command(control.window, wp, lp): return 0
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
      if message == WM_KEYDOWN and wp == 13 and control.editor.phase == compositionNone:
        win.sendEvent(control, submit)
        return 0
      if message == WM_CHAR and wp == 13: return 0
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
  var seen: Table[NodeHandle, int]
  for handle in order:
    let entity = entities.getOrDefault(handle)
    if entity.handle == NoHandle: continue
    kinds.add(entity.kind)
    parents.add(if entity.parent in seen: seen[entity.parent] else: -1)
    seen[handle] = kinds.len - 1
  rowSignature(kinds, parents)

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
    style = style or WS_TABSTOP or 0x80'u32
    # EDIT snapshots WS_BORDER into internal state at creation, then clears the
    # public bit. Removing it later does not remove its client-area border.
    if win.theme == systemTheme or highContrastActive(): style = style or WS_BORDER
  of NodeKind.checkbox, NodeKind.toggle:
    className = "BUTTON"; style = style or WS_TABSTOP or BS_AUTOCHECKBOX
  of NodeKind.progress: className = "msctls_progress32"
  of NodeKind.spinner: className = "msctls_progress32"; style = style or PBS_MARQUEE
  of NodeKind.separator: style = style or SS_ETCHEDHOR
  var parent = win.host.windowHandle
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
  let title = checkedWide(entity.label)
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
  inc control.setterDepth
  defer: dec control.setterDepth
  if win.theme != systemTheme and entity.kind in {NodeKind.checkbox, NodeKind.toggle} and
      not checkColorsPrepared(control.window):
    if entity.kind == NodeKind.toggle:
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
  if win.theme != systemTheme and entity.kind in {NodeKind.text, NodeKind.input}:
    let variant = entity.props.control.variant.get(variantDefault)
    if semanticVariant(control.window) != variant:
      if setSemanticVariant(control.window, variant) == 0: nativeError("SetPropW semantic variant")
      discard win.calls.send(control.window, WM_SETFONT,
        cast[WPARAM](win.measurement.ensureFont(win.fontRole(entity))), 1)
      discard refreshSkin(control.window)
  if entity.kind == NodeKind.input:
    # Native edits pending settlement and active IME are never overwritten by
    # an earlier accepted event. Settlement handles no-diff rejection too.
    if control.fresh or (control.editor.phase in {compositionNone, compositionEnd} and
        control.editor.latestObserved <= control.editor.lastSettled and
        control.editor.native.text != entity.label):
      win.applyEffects(control, @[EditEffect(kind: setText, value: entity.value,
        selection: (if control.fresh: Selection16() else: control.selection()))])
    let cue = checkedWide(entity.props.control.placeholder.get(""))
    discard win.calls.send(control.window, EM_SETCUEBANNER, 0, cast[LPARAM](unsafeAddr cue[0]))
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
    win.measurement = newNativeMeasure(win.host.windowHandle, win.calls, win.theme != systemTheme)
  let label = entity.label
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

proc relayout*(win: Win32Backend, content: DipSize, dpi: int)

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

proc applyRowBoxes(win: Win32Backend, boxes: seq[ListRowBox], dpi: int32) =
  ## The only Position/Region/Show path for list row subtrees: commit apply,
  ## geometry apply and rollback replay all come through here. Rect, clip and DPI
  ## come from the selected plan/context, never from live legacy scalars. A FALSE
  ## BOOL blocks the whole attempt and keeps its original error; the single region
  ## owner is released here either way (never swallowed, never leaked).
  for item in boxes:
    let control = win.controls.getOrDefault(item.handle)
    if control == nil: continue
    let local = pixelEdges(item.local, int(dpi))
    if win.calls.windowPos(control.window, nil, int32(local.left), int32(local.top),
        int32(max(0, local.right - local.left)), int32(max(0, local.bottom - local.top)),
        SWP_NOZORDER or SWP_NOACTIVATE) == 0:
      nativeError("SetWindowPos row subtree")
    # Region coordinates are window-local. Subtract the window's viewport
    # rect from the viewport clip, NOT its parent-local placement: descendants
    # of nonzero/partially scrolled rows otherwise receive displaced regions.
    let bp = pixelEdges(item.rect, int(dpi))
    let cp = pixelEdges(item.clip, int(dpi))
    let region = win.calls.rectRegion(int32(max(0, cp.left - bp.left)),
      int32(max(0, cp.top - bp.top)),
      int32(max(0, min(bp.right, cp.right) - bp.left)),
      int32(max(0, min(bp.bottom, cp.bottom) - bp.top)))
    if region == nil: nativeError("CreateRectRgn row subtree")
    win.pendingRegions.add(region)
    var primary: ref CatchableError
    try:
      if win.calls.setRegion(control.window, region, 1) == 0:
        nativeError("SetWindowRgn row subtree")
      win.pendingRegions[^1] = nil # Ownership transfers only on success.
    except CatchableError as error: primary = error
    try: win.releaseRegions()
    except CatchableError as secondary:
      if primary != nil: primary.msg.add("; region cleanup secondary: " & secondary.msg)
      else: raise secondary
    if primary != nil: raise primary
    discard win.calls.showWindow(control.window, SW_SHOW)

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


proc relayout*(win: Win32Backend, content: DipSize, dpi: int) =
  win.checkLive()
  if win.current.len == 0: return
  win.releaseRegions()
  let boxes = layoutTree(win.current, content,
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
      discard win.calls.showWindow(control.window, SW_HIDE)
      continue
    let pixels = pixelEdges(box.rect, dpi)
    var left = pixels.left; var top = pixels.top
    if control.entity.parent != NoHandle:
      let parent = pixelEdges(byHandle[control.entity.parent].rect, dpi)
      left -= parent.left; top -= parent.top
    if win.calls.windowPos(control.window, nil, int32(left), int32(top),
        int32(pixels.right - pixels.left), int32(pixels.bottom - pixels.top),
        SWP_NOZORDER or SWP_NOACTIVATE) == 0: nativeError("SetWindowPos control")
    let clip = pixelEdges(box.clip, dpi)
    let region = win.calls.rectRegion(int32(max(0, clip.left - pixels.left)),
      int32(max(0, clip.top - pixels.top)), int32(max(0, min(pixels.right, clip.right) - pixels.left)),
      int32(max(0, min(pixels.bottom, clip.bottom) - pixels.top)))
    if region == nil: nativeError("CreateRectRgn")
    win.pendingRegions.add(region)
    var primary: ref CatchableError
    try:
      if win.calls.setRegion(control.window, region, 1) == 0: nativeError("SetWindowRgn")
      win.pendingRegions[^1] = nil # Ownership transfers only on successful API return.
    except CatchableError as error: primary = error
    try: win.releaseRegions()
    except CatchableError as secondary:
      if primary != nil: primary.msg.add("; region cleanup secondary: " & secondary.msg)
      else: raise secondary
    if primary != nil: raise primary
    discard win.calls.showWindow(control.window, SW_SHOW)
  var siblings: Table[NodeHandle, seq[MountedEntity]]
  for entity in win.current.values: siblings.mgetOrPut(entity.parent, @[]).add(entity)
  for children in siblings.mvalues:
    children.sort(proc(a,b: MountedEntity): int = cmp(a.index,b.index))
    var previous: HWND
    for entity in children:
      let window = win.controls[entity.handle].window
      if win.calls.windowPos(window, previous, 0, 0, 0, 0,
          0x0001'u32 or 0x0002'u32 or SWP_NOACTIVATE) == 0:
        nativeError("SetWindowPos tab order")
      previous = window
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
    if control.canvas != nil: control.canvas.discardPrepared()
  let first = win.releasePrepared()
  win.candidate.clear()
  win.preparedModels.clear()
  for handle in win.pendingFrames:
    let list = win.lists.getOrDefault(handle)
    if list != nil: list.discardPreparedFrame()
  win.pendingFrames.setLen(0)
  win.rollbackFrames.setLen(0)
  if first != nil: raise first

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
      win.measurement=newNativeMeasure(win.host.windowHandle,win.calls,win.theme != systemTheme)
    inc win.depth
    defer:dec win.depth
    # Pass 1: the complete candidate entity view (a reused row needs its whole
    # subtree before any window is created).
    for op in batch.ops:
      case op.kind
      of opCreate:
        if op.handle in win.current:fail("duplicate native handle")
        win.candidate[op.handle]=MountedEntity(handle:op.handle,parent:op.parent,
          index:op.index,nodeId:op.nodeId,kind:op.nodeKind,props:op.props,
          list:op.list,row:op.row,navigation:op.navigation,canvas:op.canvas)
      of opUpdate,opMove:
        if op.handle notin win.current:fail("unknown native handle")
        var entity=win.candidate.getOrDefault(op.handle,win.current.getOrDefault(op.handle))
        if op.kind==opUpdate:
          discard checkedWide(op.props.control.label.get(""))
          discard checkedWide(op.props.control.value.get(""))
          entity.props=op.props;entity.list=op.list;entity.row=op.row
          entity.navigation=op.navigation
          entity.canvas=op.canvas
        else:
          entity.parent=op.parent;entity.index=op.index
          if op.row.isSome:entity.row=op.row
        win.candidate[op.handle]=entity
      of opRemove:
        if op.handle notin win.current:fail("unknown native handle")
    # Pass 2: create windows; a direct row root first tries to reuse a parked
    # subtree with the same structural signature.
    win.validateNavigation(batch)
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
    return
  win.candidate = win.current
  if win.measurement == nil:
    win.measurement = newNativeMeasure(win.host.windowHandle, win.calls, win.theme != systemTheme)
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
          row: op.row, navigation: op.navigation, canvas: op.canvas)
        win.candidate[op.handle] = entity
      else:
        win.candidate[op.handle].parent = op.parent
        win.candidate[op.handle].index = op.index
    of opUpdate:
      if op.handle notin win.candidate: fail("update of absent native control")
      discard checkedWide(op.props.control.label.get(""))
      discard checkedWide(op.props.control.value.get(""))
      win.candidate[op.handle].props = op.props
      win.candidate[op.handle].list = op.list
      win.candidate[op.handle].row = op.row
      win.candidate[op.handle].navigation = op.navigation
      win.candidate[op.handle].canvas = op.canvas
    of opRemove:
      if op.handle notin win.candidate: fail("remove of absent native control")
      let old = win.candidate[op.handle]
      win.candidate.del(op.handle)
      for handle, entity in win.candidate.mpairs:
        if entity.parent == old.parent and entity.index > old.index: dec entity.index
  if win.candidate.len > MaxNodes: fail("native entity budget exceeded")
  win.validateNavigation(batch)
  for op in batch.ops:
    if op.kind == opCreate: discard win.makeControl(win.candidate[op.handle])
  win.prepareCanvases()
  win.prepareModels()
proc apply(win: Win32Backend, batch: UpdateBatch) =
  win.checkLive()
  inc win.depth
  defer: dec win.depth
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
  if batch.ops.len > 0:
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
  var ordered: seq[MountedEntity]
  for entity in entities.values: ordered.add(entity)
  ordered.sort(proc(a,b: MountedEntity): int = cmp(uint64(a.handle),uint64(b.handle)))
  var batch = UpdateBatch(revision: win.revision)
  for entity in ordered:
    batch.ops.add UpdateOp(kind: opCreate, handle: entity.handle, parent: entity.parent,
      index: entity.index, nodeKind: entity.kind, nodeId: entity.nodeId,
      props: entity.props, list: entity.list, row: entity.row, navigation: entity.navigation, canvas: entity.canvas)
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

proc safeListTurn*(win: Win32Backend) =
  ## Production and test entry for one ordinary native list turn:
  ## genuine events -> this turn's viewport facts -> one bounded drain -> one
  ## bounded geometry pass. Never called from a window callback.
  win.checkLive()
  if win.session == nil: return
  win.reportError()
  win.maintainPointers()
  for list in win.lists.values: list.beginGeometryTurn()
  win.session.drainEvents()
  win.publishListFacts()
  discard win.session.drainRowRequests()
  win.listGeometry()
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
    let fresh = newNativeMeasure(win.host.windowHandle, win.calls, win.theme != systemTheme)
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
proc tick(win: Win32Backend) =
  try: win.nativeTurn()
  except CatchableError as error:
    if win.session != nil and win.session.ownsBackend(win.protocol):
      win.session.faultBackendEffects(win.protocol, "native effects failed: " & error.msg)
    raise error

proc dispose(win: Win32Backend) =
  win.checkOwner()
  if win.closed: return
  win.releaseContexts()
  win.releaseRegions()
  let first = win.releaseResources(0, true, win.controlEntries(true))
  if first != nil: raise first
  win.lists.clear()
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
  let win = Win32Backend(host: host, theme: host.nativeTheme, renderer: renderer,
    calls: calls, owner: GetCurrentThreadId())
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
    capture: proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): bool {.raises: [].} =
      try:
        {.cast(raises: [CatchableError]).}:
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
