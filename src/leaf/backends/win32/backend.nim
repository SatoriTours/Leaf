## Owned Unicode controls, incremental updates and native event capture.
import std/[tables, options, algorithm, widestrs, sets]
import ../../[core, styles, backend, backend_session, native_layout, native_edit, native_measure_cache]
import ./[api, calls, host, capabilities, measure, control_ids]

type
  Win32Diagnostics* = object
    creates*, destroys*, setTexts*, measures*, layouts*, callbackErrors*: uint64
    liveWindows*, liveFonts*, liveSubclasses*, liveRoots*: int
  NativeControl = ref object
    window: HWND
    cookie: uint
    commandId: uint16
    parentWindow: HWND
    entity: MountedEntity
    editor: EditorState
    armed, subclassed: bool
    setterDepth: int
    binding: uint64
    capture: proc(control: NativeControl, message: UINT, wp: WPARAM, lp: LPARAM): LRESULT {.closure.}
  Win32Backend* = ref object
    host: Win32Host
    calls: Win32Calls
    owner: DWORD
    lease: HostBackendLease
    protocol: Backend
    session: BackendSession
    closed, rebound, bound, dirty, fontDirty: bool
    retiredMeasures: seq[NativeMeasure]
    depth: int
    measurement: NativeMeasure
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
    sessionId, generation, sequence, revision, nextBinding: uint64
    stats: Win32Diagnostics
    pendingError: ref CatchableError

var controlsByCookie {.threadvar.}: Table[uint, NativeControl]
var nextCookie {.threadvar.}: uint

proc checkOwner(win: Win32Backend) =
  if win == nil or win.owner != GetCurrentThreadId(): fail("Win32 backend owner thread required")
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
    raise error

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
      control.window = nil
      control.armed = false
      control.subclassed = false
      controlsByCookie.del(data)
  # capture owns the exception boundary and invokes DefSubclassProc exactly once.
  {.cast(raises: []).}:
    return control.capture(control, message, wp, lp)

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

proc destroy(win: Win32Backend, control: NativeControl) =
  control.armed = false
  if control.window != nil:
    if control.subclassed:
      if win.calls.removeSubclass(control.window, controlProc, control.cookie) == 0:
        nativeError("RemoveWindowSubclass")
      control.subclassed = false
    if win.calls.destroyWindow(control.window) == 0: nativeError("DestroyWindow control")
    control.window = nil
    inc win.stats.destroys
  controlsByCookie.del(control.cookie)
  control.capture = nil
proc clear(win: Win32Backend, items: var Table[NodeHandle, NativeControl]) =
  # Children before parents; a failed release retains the exact owned resource.
  var keys: seq[NodeHandle]
  for handle in items.keys: keys.add(handle)
  var depths: Table[NodeHandle, int]
  for handle in keys:
    var parent = items[handle].entity.parent
    var depth = 0
    while parent in items:
      inc depth
      if depth > MaxNodes: fail("cyclic native resource tree")
      parent = items[parent].entity.parent
    depths[handle] = depth
  keys.sort(proc(a,b: NodeHandle): int =
    let byDepth = cmp(depths[b], depths[a])
    if byDepth == 0: cmp(uint64(b), uint64(a)) else: byDepth)
  var first: ref CatchableError
  var blocked: HashSet[NodeHandle]
  for handle in keys:
    if handle in blocked: continue
    try:
      win.destroy(items[handle])
      items.del(handle)
    except CatchableError as error:
      if first == nil: first = error
      # Destroying an ancestor would implicitly destroy a retained child HWND.
      var parent = items[handle].entity.parent
      while parent in items:
        blocked.incl(parent)
        parent = items[parent].entity.parent
  if first != nil: raise first

proc captureControl(win: Win32Backend, control: NativeControl, message: UINT,
                    wp: WPARAM, lp: LPARAM): LRESULT =
  try:
    if message == WM_COMMAND and win.command(control.window, wp, lp): return 0
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
    win.markError(error)
    return 0

proc makeControl(win: Win32Backend, entity: MountedEntity): NativeControl =
  var className = "STATIC"
  var exStyle = 0'u32
  var style = WS_CHILD or WS_CLIPSIBLINGS
  case entity.kind
  of NodeKind.column, NodeKind.row:
    style = style or WS_CLIPCHILDREN
    exStyle = 0x00010000'u32 # WS_EX_CONTROLPARENT: recursive native tab traversal
  of NodeKind.text, NodeKind.tag: style = style or SS_NOPREFIX
  of NodeKind.button: className = "BUTTON"; style = style or WS_TABSTOP
  of NodeKind.input: className = "EDIT"; style = style or WS_TABSTOP or WS_BORDER or 0x80'u32
  of NodeKind.checkbox, NodeKind.toggle:
    className = "BUTTON"; style = style or WS_TABSTOP or BS_AUTOCHECKBOX
  of NodeKind.progress: className = "msctls_progress32"
  of NodeKind.spinner: className = "msctls_progress32"; style = style or PBS_MARQUEE
  of NodeKind.separator: style = style or SS_ETCHEDHOR
  else: fail("unsupported native control kind")
  var parent = win.host.windowHandle
  if entity.parent != NoHandle:
    if entity.parent in win.prepared: parent = win.prepared[entity.parent].window
    elif entity.parent in win.controls: parent = win.controls[entity.parent].window
    else: fail("native control parent not prepared")
  inc nextCookie
  if nextCookie == 0: fail("native control cookie space exhausted")
  let control = NativeControl(cookie: nextCookie, commandId: win.controlIds.allocate(),
    parentWindow: parent, entity: entity,
    editor: newEditorState(entity.value))
  control.capture = proc(c: NativeControl, msg: UINT, wp: WPARAM, lp: LPARAM): LRESULT =
    win.captureControl(c, msg, wp, lp)
  let cls = checkedWide(className)
  let title = checkedWide(entity.label)
  control.window = win.calls.createWindow(exStyle, unsafeAddr cls[0], unsafeAddr title[0], style,
    0, 0, 0, 0, parent, cast[HMENU](uint(control.commandId)), GetModuleHandleW(nil), nil)
  if control.window == nil: nativeError("CreateWindowExW control")
  inc win.stats.creates
  # Ledger/root before any later operation can fail.
  win.prepared[entity.handle] = control
  controlsByCookie[control.cookie] = control
  if win.calls.setSubclass(control.window, controlProc, control.cookie, control.cookie) == 0:
    nativeError("SetWindowSubclass")
  control.subclassed = true
  discard win.calls.send(control.window, WM_SETFONT, cast[WPARAM](win.measurement.ensureFont()), 0)
  win.arm(control)
  control.armed = false
  if entity.kind == NodeKind.input and entity.props.control.resetToken.isSome:
    control.editor.acceptModel(entity.value, 0, entity.props.control.resetToken)
    control.editor.completeReset(entity.props.control.resetToken.get)
  result = control

proc properties(win: Win32Backend, control: NativeControl, entity: MountedEntity) =
  let old = control.entity
  inc control.setterDepth
  defer: dec control.setterDepth
  if entity.kind == NodeKind.input:
    # Native edits pending settlement and active IME are never overwritten by
    # an earlier accepted event. Settlement handles no-diff rejection too.
    if control.editor.phase in {compositionNone, compositionEnd} and
        control.editor.latestObserved <= control.editor.lastSettled and
        control.editor.native.text != entity.label:
      win.applyEffects(control, @[EditEffect(kind: setText, value: entity.value,
        selection: control.selection())])
    let cue = checkedWide(entity.props.control.placeholder.get(""))
    discard win.calls.send(control.window, EM_SETCUEBANNER, 0, cast[LPARAM](unsafeAddr cue[0]))
  elif entity.kind notin {NodeKind.column, NodeKind.row, NodeKind.progress, NodeKind.spinner, NodeKind.separator}:
    if old.label != entity.label:
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
    if control.editor.latestObserved <= control.editor.lastSettled:
      discard win.calls.send(control.window, BM_SETCHECK, WPARAM(ord(entity.props.control.checked.get(false))), 0)
      control.editor.native = entity.value
  of NodeKind.progress:
    discard win.calls.send(control.window, PBM_SETRANGE32, 0, 100)
    discard win.calls.send(control.window, PBM_SETPOS, WPARAM(int(entity.props.control.progress.get(0.0))), 0)
  of NodeKind.spinner: discard win.calls.send(control.window, PBM_SETMARQUEE, 1, 30)
  else: discard
  control.entity = entity

proc measureControl*(win: Win32Backend, entity: MountedEntity, available: DipSize): DipSize =
  win.checkLive()
  if win.measurement == nil: win.measurement = newNativeMeasure(win.host.windowHandle, win.calls)
  let label = entity.label
  let hint = entity.props.control.placeholder.get("")
  let checked = entity.props.control.checked.get(false)
  let enabled = entity.props.control.enabled.get(true)
  let key: MeasureKey = (entity.kind, label, hint,
    uint8(ord(checked) or (ord(enabled) shl 1)), available.width, available.height)
  let cached = win.cache.get(key)
  if cached.isSome: return cached.get
  inc win.stats.measures
  case entity.kind
  of NodeKind.column, NodeKind.row: result = DipSize()
  of NodeKind.input:
    let control = win.controls.getOrDefault(entity.handle, win.prepared.getOrDefault(entity.handle))
    result = win.measurement.measureInput(label, hint,
      if control == nil: nil else: control.window)
  of NodeKind.checkbox, NodeKind.toggle:
    result = win.measurement.measureCheckbox(label, checked, not enabled)
  of NodeKind.progress, NodeKind.spinner: result = win.measurement.measureProgress()
  of NodeKind.separator: result = win.measurement.measureSeparator()
  of NodeKind.button:
    result = win.measurement.measureButton(label, enabled)
  else:
    result = win.measurement.measureText(if label.len == 0: "Mg" else: label,
      if entity.kind == NodeKind.text: available.width else: 0.0)
  win.cache.put(key, result)

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
  inc win.stats.layouts
  win.dirty = false

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
  win.clear(win.prepared)
  win.candidate.clear()
  win.preparedModels.clear()
proc prepare(win: Win32Backend, batch: UpdateBatch) =
  win.checkLive()
  if win.prepared.len != 0: win.discardPrepared()
  if batch.isDelta:
    win.candidate.clear()
    if win.measurement==nil:win.measurement=newNativeMeasure(win.host.windowHandle,win.calls)
    inc win.depth
    defer:dec win.depth
    for op in batch.ops:
      case op.kind
      of opCreate:
        if op.handle in win.current:fail("duplicate native handle")
        let entity=MountedEntity(handle:op.handle,parent:op.parent,index:op.index,
          nodeId:op.nodeId,kind:op.nodeKind,props:op.props)
        win.candidate[op.handle]=entity
        discard win.makeControl(entity)
      of opUpdate,opMove:
        if op.handle notin win.current:fail("unknown native handle")
        var entity=win.candidate.getOrDefault(op.handle,win.current.getOrDefault(op.handle))
        if op.kind==opUpdate:
          discard checkedWide(op.props.control.label.get(""))
          discard checkedWide(op.props.control.value.get(""))
          entity.props=op.props
        else:entity.parent=op.parent;entity.index=op.index
        win.candidate[op.handle]=entity
      of opRemove:
        if op.handle notin win.current:fail("unknown native handle")
    win.prepareModels()
    return
  win.candidate = win.current
  if win.measurement == nil: win.measurement = newNativeMeasure(win.host.windowHandle, win.calls)
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
          kind: op.nodeKind, nodeId: op.nodeId, props: op.props)
        win.candidate[op.handle] = entity
        discard win.makeControl(entity)
      else:
        win.candidate[op.handle].parent = op.parent
        win.candidate[op.handle].index = op.index
    of opUpdate:
      if op.handle notin win.candidate: fail("update of absent native control")
      discard checkedWide(op.props.control.label.get(""))
      discard checkedWide(op.props.control.value.get(""))
      win.candidate[op.handle].props = op.props
    of opRemove:
      if op.handle notin win.candidate: fail("remove of absent native control")
      let old = win.candidate[op.handle]
      win.candidate.del(op.handle)
      for handle, entity in win.candidate.mpairs:
        if entity.parent == old.parent and entity.index > old.index: dec entity.index
  if win.candidate.len > MaxNodes: fail("native entity budget exceeded")
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
      win.destroy(win.controls[op.handle])
      win.controls.del(op.handle)
    of opMove: discard
  for handle, entity in win.candidate:
    win.controls[handle].entity = entity
  if batch.isDelta:
    for op in batch.ops:
      if op.kind==opRemove:win.current.del(op.handle)
    for handle,entity in win.candidate:win.current[handle]=entity
    win.candidate.clear()
  else:win.current=win.candidate
  if batch.ops.len > 0:
    let ctx = win.host.context
    win.relayout(DipSize(width: ctx.contentWidth, height: ctx.contentHeight), int(ctx.scale * 96))
  win.reportError()
proc accept(win: Win32Backend, entities: Table[NodeHandle, MountedEntity], revision: uint64) {.raises: [].} =
  win.revision = revision
  for handle, control in win.controls.mpairs:
    if handle notin entities: continue
    let entity = entities.getOrDefault(handle)
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
      var preparedAccept=false
      win.preparedModels.withValue(entity.handle,prepared):
        control.editor.acceptPreparedModel(prepared[],delta.revision,entity.props.control.resetToken)
        preparedAccept=true
      if not preparedAccept:
        control.editor.acceptModel(entity.value,delta.revision,entity.props.control.resetToken)
      if control.editor.pendingReset.isSome:control.armed=false
      elif win.bound:control.armed=true
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
  var watermarks: Table[NodeHandle, uint64]
  for handle, control in win.controls: watermarks[handle] = control.editor.consumedResetToken
  win.discardPrepared()
  win.clear(win.controls)
  win.current.clear()
  var ordered: seq[MountedEntity]
  for entity in entities.values: ordered.add(entity)
  ordered.sort(proc(a,b: MountedEntity): int = cmp(uint64(a.handle),uint64(b.handle)))
  var batch = UpdateBatch(revision: win.revision)
  for entity in ordered:
    batch.ops.add UpdateOp(kind: opCreate, handle: entity.handle, parent: entity.parent,
      index: entity.index, nodeKind: entity.kind, nodeId: entity.nodeId, props: entity.props)
  win.prepare(batch)
  win.apply(batch)
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
proc nativeTurn(win: Win32Backend) =
  win.checkLive()
  win.reportError()
  if win.fontDirty:
    let fresh = newNativeMeasure(win.host.windowHandle, win.calls)
    let font = fresh.ensureFont()
    win.retiredMeasures.add(win.measurement)
    win.measurement = fresh
    for control in win.controls.values:
      discard win.calls.send(control.window, WM_SETFONT, cast[WPARAM](font), 1)
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
    let ctx = win.host.context
    win.relayout(DipSize(width: ctx.contentWidth, height: ctx.contentHeight), int(ctx.scale * 96))
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
  win.discardPrepared()
  win.clear(win.controls)
  if win.measurement != nil: win.measurement.close()
  for old in win.retiredMeasures:
    if old != nil: old.close()
  win.retiredMeasures.setLen(0)
  win.current.clear(); win.preparedModels.clear(); win.cache.clear()
  win.closed = true
proc newWin32Backend*(host: Win32Host, calls: Win32Calls = systemWin32Calls()): Win32Backend =
  discard host.context
  let win = Win32Backend(host: host, calls: calls, owner: GetCurrentThreadId())
  win.protocol = Backend(capabilities: win32Capabilities())
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
  win.protocol.settle = proc(value: EventSettlement) = win.settle(value)
  win.lease = host.claimBackendOwner(HostBackendBridge(
    capture: proc(window: HWND, message: UINT, wp: WPARAM, lp: LPARAM): bool {.raises: [].} =
      try:
        {.cast(raises: [CatchableError]).}:
          return win.command(window, wp, lp)
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
  result.liveRoots = ord(win.host.backendOwnerActive(win.lease))
  for control in win.controls.values:
    result.liveRoots += ord(controlsByCookie.getOrDefault(control.cookie) == control)
  for control in win.prepared.values:
    result.liveRoots += ord(controlsByCookie.getOrDefault(control.cookie) == control)
