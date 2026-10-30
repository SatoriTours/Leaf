## UI-owned Direct2D/DirectWrite resources. Preparation can fail; publication
## only moves prepared pointers and values. Painting never invokes application code.
when not defined(windows): {.error: "Direct2D Canvas requires Windows".}
import std/[os, strutils, options, unicode]
import ../../[core, graphics, canvas_hit, canvas_input, canvas_bindings]
import ./api
when defined(leafCanvasMeasure): import std/[monotimes, times]
when defined(leafCanvasFixedDiagnostic):
  import ./canvas_cpu_probe
  {.passC:"-DLEAF_CANVAS_CYCLE_PROBE".}

const BridgeHeader = (currentSourcePath.parentDir / "canvas_bridge.h").replace('\\', '/')
{.compile: "canvas_bridge.c".}
{.passL: "-ld2d1 -ldwrite -lole32 -luuid".}

type
  NativeSurface {.importc: "LeafCanvasSurface", header: BridgeHeader, incompleteStruct.} = object
  NativeScene {.importc: "LeafCanvasScene", header: BridgeHeader, incompleteStruct.} = object
  CommandData {.importc: "LeafCanvasCommandData", header: BridgeHeader, bycopy.} = object
    kind, flags: int32
    values: array[8, cfloat]
    fill, stroke: array[4, cfloat]
    strokeWidth: cfloat
    matrix: array[6, cfloat]
  NativeSegment {.importc: "LeafCanvasPathSegment", header: BridgeHeader, bycopy.} = object
    kind: int32
    points: array[6, cfloat]
  CanvasResourceCounts* {.importc: "LeafCanvasCounts", header: BridgeHeader, bycopy.} = object
    surfaces*, scenes*, geometries*, textLayouts*, layers*, brushes*, targets*, factories*: int32
  CanvasDiagnostics* = object
    renderer*: CanvasRenderer
    frameId*, drawAttempts*, successfulDraws*: uint64
    ownedDataBytes*: int
    rebuildPending*, faulted*: bool
    when defined(leafCanvasMeasure):
      resourcePreparationNs*, drawSubmitNs*: int64
    when defined(leafCanvasFixedDiagnostic):
      resourcePreparationCycles*, drawSubmitCycles*: uint64
      drawRecordCycles*, endDrawCycles*: uint64
  GeometryLease = ref object
    scene: ptr NativeScene
    owner: DWORD
  Presentation = object
    canvasFromClient: Matrix3x2
    valid: bool
  CanvasSurface* = ref object
    native: ptr NativeSurface
    window: HWND
    owner: DWORD
    renderer: CanvasRenderer
    accepted, pending, retired: ptr NativeScene
    acceptedFrame, pendingFrame, retiredFrame, drawnFrame: CanvasFrame
    acceptedHit, pendingHit, retiredHit, drawnHit: CanvasHitSnapshot
    acceptedLease, pendingLease, retiredLease, drawnLease: GeometryLease
    acceptedBindings, pendingBindings, retiredBindings, drawnBindings: CanvasBindingSnapshot
    nextInputSlot: uint64
    attemptedPresentation, pendingPresentation, drawnPresentation: Presentation
    acceptedBytes, pendingBytes, retiredBytes: int
    pendingDrawn, rebuildPending, faulted: bool
    frameId, attempts, successes: uint64
    when defined(leafCanvasMeasure):
      resourcePreparationNs, drawSubmitNs: int64
    when defined(leafCanvasFixedDiagnostic):
      resourcePreparationCycles, drawSubmitCycles: uint64
    when defined(leafProtocolProbes):
      nextDrawFailure, nextRebuildFailure: int32

proc nativeNew(window: pointer, software: int32, output: ptr ptr NativeSurface): int32 {.importc: "leaf_canvas_new", header: BridgeHeader.}
proc nativeRelease(surface: ptr NativeSurface) {.importc: "leaf_canvas_release", header: BridgeHeader.}
proc sceneBytes(count: int32): uint64 {.importc: "leaf_canvas_scene_bytes", header: BridgeHeader.}
proc sceneNew(surface: ptr NativeSurface, count: int32, output: ptr ptr NativeScene): int32 {.importc: "leaf_canvas_scene_new", header: BridgeHeader.}
proc sceneRelease(scene: ptr NativeScene) {.importc: "leaf_canvas_scene_release", header: BridgeHeader.}
proc sceneSet(scene: ptr NativeScene, index: int32, data: ptr CommandData): int32 {.importc: "leaf_canvas_scene_set", header: BridgeHeader.}
proc scenePath(scene: ptr NativeScene, index: int32, data: ptr NativeSegment, count, evenOdd: int32): int32 {.importc: "leaf_canvas_scene_path", header: BridgeHeader.}
proc sceneText(scene: ptr NativeScene, index: int32, text: ptr uint16, count: int32, font: ptr uint16, size: cfloat): int32 {.importc: "leaf_canvas_scene_text", header: BridgeHeader.}
proc sceneReady(scene: ptr NativeScene): int32 {.importc: "leaf_canvas_scene_ready", header: BridgeHeader.}
proc sceneContains(scene: ptr NativeScene, index: int32, x, y: cfloat, inside: ptr int32): int32 {.importc: "leaf_canvas_scene_contains", header: BridgeHeader.}
proc nativeDraw(surface: ptr NativeSurface, scene: ptr NativeScene, width, height: int32, dpi: cfloat,
  matrix, background: ptr cfloat, designWidth, designHeight: cfloat): int32 {.importc: "leaf_canvas_draw", header: BridgeHeader.}
proc nativeRebuild(surface: ptr NativeSurface): int32 {.importc: "leaf_canvas_rebuild", header: BridgeHeader.}
proc validatePaint(surface: ptr NativeSurface) {.importc: "leaf_canvas_validate_paint", header: BridgeHeader.}
proc nativeCounts(output: ptr CanvasResourceCounts) {.importc: "leaf_canvas_counts", header: BridgeHeader.}
when defined(leafCanvasFixedDiagnostic):
  proc nativeDrawCycleCounts(surface:ptr NativeSurface,record,ending:ptr uint64):int32 {.importc:"leaf_canvas_draw_cycle_counts",header:BridgeHeader.}

proc checkStatus(status: int32, operation: string) =
  if status < 0: fail(operation & " failed: HRESULT 0x" & toHex(cast[uint32](status), 8))
proc checkOwner(surface: CanvasSurface) =
  if surface == nil or surface.owner != GetCurrentThreadId(): fail("Canvas requires its owning UI thread")
  if surface.native == nil: fail("Canvas is closed")
proc nativeFloat(value: float64): cfloat =
  # high(cfloat) is Inf in Nim, not FLT_MAX. Ordered range checks reject
  # NaN/infinities and finite double overflow before conversion/SDK publication.
  const MaxNativeFloat = 3.4028234663852886e38
  if not (value >= -MaxNativeFloat and value <= MaxNativeFloat):
    fail("Canvas coordinate cannot be represented by Direct2D")
  cfloat(value)
proc nativeColor(value: Color): array[4, cfloat] = [value.r, value.g, value.b, value.a]
proc nativeMatrix(value: Matrix3x2): array[6, cfloat] =
  [nativeFloat(value.xx), nativeFloat(value.yx), nativeFloat(value.xy), nativeFloat(value.yy), nativeFloat(value.dx), nativeFloat(value.dy)]
proc wide(value: string): seq[uint16] =
  for rune in value.runes:
    let code = int(rune)
    if code <= 0xffff: result.add(uint16(code))
    else:
      result.add(uint16(0xd800 + ((code - 0x10000) shr 10)))
      result.add(uint16(0xdc00 + ((code - 0x10000) and 0x3ff)))
  result.add(0)
proc commandData(command: CanvasCommand): CommandData =
  result.kind = int32(ord(command.kind))
  let paint = command.paint
  if paint.fill.isSome:
    result.flags = result.flags or 1
    result.fill = nativeColor(paint.fill.get)
  if paint.stroke.isSome:
    result.flags = result.flags or 2
    result.stroke = nativeColor(paint.stroke.get)
  result.strokeWidth = nativeFloat(paint.strokeWidth)
  case command.kind
  of DrawKind.rectangle:
    if command.needsRendererInternal: result.flags = result.flags or 8
    result.values[0] = nativeFloat(command.position.x)
    result.values[1] = nativeFloat(command.position.y)
    result.values[2] = nativeFloat(command.size.x)
    result.values[3] = nativeFloat(command.size.y)
    result.values[4] = nativeFloat(command.radius)
  of DrawKind.circle:
    result.values[0] = nativeFloat(command.center.x)
    result.values[1] = nativeFloat(command.center.y)
    result.values[2] = nativeFloat(command.radius)
  of DrawKind.line:
    result.values[0] = nativeFloat(command.start.x)
    result.values[1] = nativeFloat(command.start.y)
    result.values[2] = nativeFloat(command.finish.x)
    result.values[3] = nativeFloat(command.finish.y)
  of DrawKind.text:
    result.values[0] = nativeFloat(command.position.x)
    result.values[1] = nativeFloat(command.position.y)
  of DrawKind.beginGroup:
    result.matrix = nativeMatrix(command.transform)
    if command.clip.isSome:
      let clip = command.clip.get
      result.flags = result.flags or 4
      result.values[0] = nativeFloat(clip.x)
      result.values[1] = nativeFloat(clip.y)
      result.values[2] = nativeFloat(clip.width)
      result.values[3] = nativeFloat(clip.height)
  else: discard

proc canvasResourceCounts*(): CanvasResourceCounts = nativeCounts(addr result)
proc newCanvasSurface*(window: HWND, renderer = CanvasRenderer.hardware): CanvasSurface =
  var native: ptr NativeSurface
  checkStatus(nativeNew(cast[pointer](window), int32(renderer == CanvasRenderer.software), addr native), "Direct2D Canvas creation (" & $renderer & ")")
  CanvasSurface(native: native, window: window, owner: GetCurrentThreadId(), renderer: renderer)
when defined(leafProtocolProbes):
  proc failNextDrawForTest*(surface: CanvasSurface, status: int32) =
    ## Inject one native HRESULT; subsequent reconstruction uses the real SDK.
    surface.checkOwner()
    if status >= 0: fail("Canvas failure probe requires a failing HRESULT")
    surface.nextDrawFailure = status
  proc failNextRebuildForTest*(surface: CanvasSurface, status: int32) =
    surface.checkOwner()
    if status >= 0: fail("Canvas failure probe requires a failing HRESULT")
    surface.nextRebuildFailure = status

proc retirePrepared(surface: CanvasSurface) =
  if surface.retiredLease != nil:
    surface.retiredLease.scene = nil
    if surface.drawnLease == surface.retiredLease:
      surface.drawnHit = default(CanvasHitSnapshot)
      surface.drawnLease = nil
      surface.drawnFrame = default(CanvasFrame)
  surface.retiredBindings = default(CanvasBindingSnapshot)
  if surface.drawnLease == nil:
    surface.drawnBindings = default(CanvasBindingSnapshot)
    surface.drawnPresentation = default(Presentation)
  surface.retiredHit = default(CanvasHitSnapshot)
  surface.retiredLease = nil
  if surface.retired != nil: sceneRelease(surface.retired)
  surface.retired = nil
  surface.retiredFrame = default(CanvasFrame)
  surface.retiredBytes = 0
proc maintain*(surface: CanvasSurface) =
  surface.checkOwner()
  surface.retirePrepared()
proc discardPrepared*(surface: CanvasSurface) =
  surface.checkOwner()
  if surface.pendingLease != nil: surface.pendingLease.scene = nil
  surface.pendingBindings = default(CanvasBindingSnapshot)
  surface.pendingPresentation = default(Presentation)
  surface.pendingHit = default(CanvasHitSnapshot)
  surface.pendingLease = nil
  if surface.pending != nil: sceneRelease(surface.pending)
  surface.pending = nil
  surface.pendingFrame = default(CanvasFrame)
  surface.pendingBytes = 0
  surface.pendingDrawn = false
proc prepareFrame*(surface: CanvasSurface, frame: CanvasFrame,
    inputSession = 0'u64, inputMount = 0'u64) =
  surface.checkOwner()
  if surface.faulted: fail("Canvas renderer is faulted")
  if frame.isNil: fail("Canvas frame is missing")
  if (inputSession == 0) != (inputMount == 0): fail("incomplete Canvas input namespace")
  if surface.frameId == high(uint64): fail("Canvas frame identity exhausted")
  when defined(leafCanvasFixedDiagnostic):
    let resourceCpuStarted = queryUiCycles()
  when defined(leafCanvasMeasure):
    let resourceStarted = getMonoTime()
  surface.retirePrepared()
  surface.discardPrepared()
  # Charge an upper bound for every native segment key, even when equal paths
  # intern to fewer entries; pools remain inside the existing 64 MiB owner quota.
  let ownBytes = uint64(frame.ownedBytes) + sceneBytes(int32(frame.commandCount)) +
    uint64(frame.pathSegmentCount) * uint64(sizeof(NativeSegment))
  if ownBytes > uint64(MaxCanvasOwnedBytes - surface.acceptedBytes): fail("Canvas owned data exceeds 64 MiB")
  var scene: ptr NativeScene
  checkStatus(sceneNew(surface.native, int32(frame.commandCount), addr scene), "Canvas scene allocation")
  try:
    var index = 0'i32
    for command in frame.commands:
      var data = commandData(command)
      checkStatus(sceneSet(scene, index, addr data), "Canvas command preparation")
      if command.kind == DrawKind.path:
        var segments = newSeq[NativeSegment](command.path.segmentCount)
        var j = 0
        for segment in command.path.segments:
          segments[j] = NativeSegment(kind: int32(ord(segment.kind)), points: [
            nativeFloat(segment.first.x), nativeFloat(segment.first.y), nativeFloat(segment.second.x),
            nativeFloat(segment.second.y), nativeFloat(segment.third.x), nativeFloat(segment.third.y)])
          inc j
        checkStatus(scenePath(scene, index, addr segments[0], int32(segments.len),
          int32(command.path.fillRule == FillRule.evenOdd)), "Direct2D path preparation")
      elif command.kind == DrawKind.text:
        let text = wide(command.text)
        let font = wide(command.font)
        checkStatus(sceneText(scene, index, unsafeAddr text[0], int32(text.len-1), unsafeAddr font[0],
          nativeFloat(command.fontSize)), "DirectWrite text preparation")
      inc index
    checkStatus(sceneReady(scene), "Canvas scene validation")
    when defined(leafCanvasMeasure):
      surface.resourcePreparationNs += (getMonoTime()-resourceStarted).inNanoseconds
    when defined(leafCanvasFixedDiagnostic):
      surface.resourcePreparationCycles += cycleDelta(queryUiCycles(),resourceCpuStarted)
    var bindings: seq[HitBinding]
    var interactive = false
    var rootIgnored = false
    for entry in frame.interactions:
      if entry.commandIndex == -1: rootIgnored = not entry.hitTest
      interactive = interactive or entry.eventMask != 0
      if entry.commandIndex >= 0:
        bindings.add(HitBinding(commandIndex: entry.commandIndex,
          key: (if entry.eventMask != 0: entry.key else: ""),
          policy: (if entry.hitTest: HitPolicy.automatic else: HitPolicy.ignore)))
    if rootIgnored: bindings.setLen(0)
    var snapshot: CanvasHitSnapshot
    var lease: GeometryLease
    var hitBytes = 0
    if interactive:
      lease = GeometryLease(scene: scene, owner: surface.owner)
      let queryLease = lease # Freeze the ref; moving the publication var must not empty the closure.
      let geometry: GeometryContains = proc(index: int, position: Vec2): bool =
        if queryLease.owner != GetCurrentThreadId(): fail("Canvas hit query requires its UI owner")
        if queryLease.scene == nil: return false
        let command = frame.commandAt(index)
        if not command.needsRendererInternal:
          return command.primitiveContainsInternal(position)
        var inside: int32
        checkStatus(sceneContains(queryLease.scene, int32(index), nativeFloat(position.x), nativeFloat(position.y), addr inside),
          "Canvas SDK geometry containment")
        inside != 0
      let remaining = MaxCanvasOwnedBytes - surface.acceptedBytes - int(ownBytes) - sizeof(lease[])
      if remaining <= 0: fail("Canvas owned hit data exceeds 64 MiB")
      snapshot = prepareHitSnapshot(frame, bindings, geometryContains = geometry, maxBytes = remaining)
      hitBytes = snapshot.ownedBytes + sizeof(lease[])
    var input: CanvasBindingSnapshot
    if inputSession != 0:
      input = prepareCanvasBindings(frame, inputSession, inputMount, surface.nextInputSlot,
        surface.acceptedBindings, maxBytes=MaxCanvasOwnedBytes-surface.acceptedBytes-int(ownBytes)-hitBytes)
    surface.pendingBindings = move(input)
    surface.pendingHit = move(snapshot)
    surface.pendingLease = move(lease)
    surface.pending = scene
    surface.pendingFrame = frame
    surface.pendingBytes = int(ownBytes) + hitBytes + surface.pendingBindings.ownedBytes
  except:
    sceneRelease(scene)
    raise
proc draw(surface: CanvasSurface, scene: ptr NativeScene, frame: CanvasFrame): bool =
  surface.checkOwner()
  if surface.faulted: fail("Canvas renderer is faulted")
  if scene == nil or IsWindowVisible(surface.window) == 0: return false
  var client: RECT
  if GetClientRect(surface.window, addr client) == 0: fail("Canvas GetClientRect failed")
  let width = int64(client.right) - int64(client.left)
  let height = int64(client.bottom) - int64(client.top)
  if width <= 0 or height <= 0: return false
  if width > MaxCanvasAxisPixels or height > MaxCanvasAxisPixels or width*height > MaxCanvasPixels:
    fail("Canvas pixel surface quota exceeded")
  let dpi = GetDpiForWindow(surface.window)
  if dpi == 0: fail("Canvas DPI is unavailable")
  let transform = canvasTransform(frame.viewBox, vec2(float64(width)*96/float64(dpi), float64(height)*96/float64(dpi)))
  var matrix = nativeMatrix(transform)
  var background = nativeColor(frame.background)
  let box = frame.viewBox.get(vec2(0, 0))
  inc surface.attempts
  var status = 0'i32
  when defined(leafProtocolProbes):
    status = surface.nextDrawFailure
    surface.nextDrawFailure = 0
  when defined(leafCanvasFixedDiagnostic):
    let drawCpuStarted = queryUiCycles()
  when defined(leafCanvasMeasure):
    let drawStarted = getMonoTime()
  if status == 0:
    status = nativeDraw(surface.native, scene, int32(width), int32(height), cfloat(dpi),
      addr matrix[0], addr background[0], nativeFloat(box.x), nativeFloat(box.y))
  when defined(leafCanvasMeasure):
    surface.drawSubmitNs += (getMonoTime()-drawStarted).inNanoseconds
  when defined(leafCanvasFixedDiagnostic):
    surface.drawSubmitCycles += cycleDelta(queryUiCycles(),drawCpuStarted)
  if status < 0:
    if cast[uint32](status) == 0x8899000C'u32: surface.rebuildPending = true
    else: surface.faulted = true
    checkStatus(status, "Canvas EndDraw/resize")
  if frame.focusable and GetFocus() == surface.window:
    let dc = GetDC(surface.window)
    if dc == nil: fail("Canvas focus cue DC is unavailable")
    try:
      let inset = max(2'i32, int32(dpi div 48))
      var bounds = RECT(left: inset, top: inset, right: int32(width)-inset, bottom: int32(height)-inset)
      if bounds.right > bounds.left and bounds.bottom > bounds.top and DrawFocusRect(dc, addr bounds) == 0:
        fail("Canvas focus cue drawing failed")
    finally: discard ReleaseDC(surface.window, dc)
  inc surface.successes
  surface.attemptedPresentation = Presentation(valid: true,
    canvasFromClient: transform.inverse.get * groupTransform(scale=vec2(96/float64(dpi), 96/float64(dpi))))
  true
proc presentPrepared*(surface: CanvasSurface): bool =
  surface.pendingDrawn = surface.draw(surface.pending, surface.pendingFrame)
  if surface.pendingDrawn: surface.pendingPresentation = surface.attemptedPresentation
  surface.pendingDrawn
proc acceptPrepared*(surface: CanvasSurface) {.raises: [].} =
  ## Called only after the whole native apply succeeds. No C/OS call, no
  ## allocation, and old scene/frame storage is pinned until ordinary retirement.
  if surface == nil or surface.pending == nil: return
  surface.retired = surface.accepted
  surface.retiredBytes = surface.acceptedBytes
  surface.retiredFrame = move(surface.acceptedFrame)
  surface.retiredBindings = move(surface.acceptedBindings)
  surface.acceptedBindings = move(surface.pendingBindings)
  surface.retiredHit = move(surface.acceptedHit)
  surface.retiredLease = move(surface.acceptedLease)
  surface.acceptedHit = move(surface.pendingHit)
  surface.acceptedLease = move(surface.pendingLease)
  surface.accepted = surface.pending
  surface.acceptedFrame = move(surface.pendingFrame)
  surface.acceptedBytes = surface.pendingBytes
  surface.pending = nil
  surface.pendingBytes = 0
  if surface.pendingDrawn:
    inc surface.frameId
    surface.drawnFrame = surface.acceptedFrame
    surface.drawnHit = surface.acceptedHit
    surface.drawnLease = surface.acceptedLease
    surface.drawnBindings = surface.acceptedBindings
    surface.drawnPresentation = surface.pendingPresentation
  surface.pendingDrawn = false
proc frameId*(surface: CanvasSurface): uint64 = surface.frameId
proc acceptedFrame*(surface: CanvasSurface): CanvasFrame = surface.acceptedFrame
proc lastDrawnFrame*(surface: CanvasSurface): CanvasFrame = surface.drawnFrame
proc hitDrawn*(surface: CanvasSurface, canvasPosition: Vec2): Option[CanvasHit] =
  ## Design coordinates after DPI/viewBox removal. Candidate draws are invisible
  ## here until whole-tree accept; retired SDK pointers cannot be queried.
  surface.checkOwner()
  if surface.drawnLease == nil or surface.drawnLease.scene == nil or surface.rebuildPending or surface.faulted:
    return none(CanvasHit)
  surface.drawnHit.hitTest(canvasPosition)
proc needsRebuild*(surface: CanvasSurface): bool = surface.rebuildPending
proc paintAccepted*(surface: CanvasSurface): bool =
  surface.checkOwner()
  if surface.frameId == high(uint64): fail("Canvas frame identity exhausted")
  result = surface.draw(surface.accepted, surface.acceptedFrame)
  if result:
    inc surface.frameId
    surface.drawnFrame = surface.acceptedFrame
    surface.drawnHit = surface.acceptedHit
    surface.drawnLease = surface.acceptedLease
    surface.drawnBindings = surface.acceptedBindings
    surface.drawnPresentation = surface.attemptedPresentation
proc present*(surface: CanvasSurface): bool =
  if surface.pending != nil: surface.presentPrepared()
  else: surface.paintAccepted()
proc handlePaint*(surface: CanvasSurface, busy: bool) =
  surface.checkOwner()
  validatePaint(surface.native)
  if busy or surface.rebuildPending: return
  try: discard surface.paintAccepted()
  except UiError:
    if not surface.rebuildPending: raise
proc recoverOnce*(surface: CanvasSurface) =
  surface.checkOwner()
  if not surface.rebuildPending: return
  # One ordinary-turn reconstruction. A failed rebuild or retry freezes this
  # owner; WM_PAINT never loops or silently selects a different renderer.
  try:
    var status = 0'i32
    when defined(leafProtocolProbes):
      status = surface.nextRebuildFailure
      surface.nextRebuildFailure = 0
    if status == 0: status = nativeRebuild(surface.native)
    checkStatus(status, "Canvas target rebuild")
    surface.rebuildPending = false
    discard surface.paintAccepted()
    surface.rebuildPending = false
  except CatchableError:
    surface.rebuildPending = false
    surface.faulted = true
    raise
proc diagnostics*(surface: CanvasSurface): CanvasDiagnostics =
  result = CanvasDiagnostics(renderer: surface.renderer, frameId: surface.frameId,
    drawAttempts: surface.attempts, successfulDraws: surface.successes,
    ownedDataBytes: surface.acceptedBytes + surface.pendingBytes + surface.retiredBytes,
    rebuildPending: surface.rebuildPending, faulted: surface.faulted)
  when defined(leafCanvasMeasure):
    result.resourcePreparationNs = surface.resourcePreparationNs
    result.drawSubmitNs = surface.drawSubmitNs
  when defined(leafCanvasFixedDiagnostic):
    result.resourcePreparationCycles = surface.resourcePreparationCycles
    result.drawSubmitCycles = surface.drawSubmitCycles
    if surface.native != nil:
      checkStatus(nativeDrawCycleCounts(surface.native,addr result.drawRecordCycles,addr result.endDrawCycles),"Canvas draw cycle diagnostics")
proc releaseCanvasInternal*(surface: CanvasSurface) {.raises: [].} =
  if surface == nil or surface.native == nil: return
  # Irreversible HWND teardown may call this too. All pointers belong to this
  # owner and COM release invokes no Leaf/business callbacks.
  for lease in [surface.acceptedLease, surface.pendingLease, surface.retiredLease]:
    if lease != nil: lease.scene = nil
  nativeRelease(surface.native)
  surface.native = nil
  surface.acceptedHit = default(CanvasHitSnapshot); surface.pendingHit = default(CanvasHitSnapshot)
  surface.retiredHit = default(CanvasHitSnapshot); surface.drawnHit = default(CanvasHitSnapshot)
  surface.acceptedLease = nil; surface.pendingLease = nil; surface.retiredLease = nil; surface.drawnLease = nil
  surface.acceptedBindings = default(CanvasBindingSnapshot); surface.pendingBindings = default(CanvasBindingSnapshot)
  surface.retiredBindings = default(CanvasBindingSnapshot); surface.drawnBindings = default(CanvasBindingSnapshot)
  surface.drawnPresentation = default(Presentation)
  surface.accepted = nil; surface.pending = nil; surface.retired = nil
  surface.acceptedFrame = default(CanvasFrame); surface.pendingFrame = default(CanvasFrame)
  surface.retiredFrame = default(CanvasFrame); surface.drawnFrame = default(CanvasFrame)
proc close*(surface: CanvasSurface) =
  if surface == nil: return
  if surface.owner != GetCurrentThreadId(): fail("Canvas close requires its owning UI thread")
  surface.releaseCanvasInternal()


proc inputReady(surface: CanvasSurface): bool =
  surface.drawnPresentation.valid and surface.drawnLease != nil and surface.drawnLease.scene != nil and
    not surface.rebuildPending and not surface.faulted and IsWindowVisible(surface.window) != 0
proc inputMatrix(surface: CanvasSurface): Option[Matrix3x2] =
  surface.checkOwner()
  if not surface.inputReady: return none(Matrix3x2)
  var origin: POINT
  if ClientToScreen(surface.window, addr origin) == 0: fail("Canvas client origin is unavailable")
  some(surface.drawnPresentation.canvasFromClient * groupTransform(translate=vec2(-float64(origin.x), -float64(origin.y))))
proc inputBindingAlive*(surface: CanvasSurface, id: CanvasBindingId): bool =
  surface.checkOwner()
  surface.acceptedBindings.binding(id).isSome
proc inputTarget*(surface: CanvasSurface, id: CanvasBindingId, includeRoute = true): Option[PointerTarget] =
  let matrix = surface.inputMatrix()
  if matrix.isNone or not surface.inputBindingAlive(id): return none(PointerTarget)
  surface.drawnBindings.pointerTarget(id, surface.frameId, matrix.get, includeRoute)
proc pointerAtScreen*(surface: CanvasSurface, point: Vec2): Option[PointerTarget] =
  let matrix = surface.inputMatrix()
  if matrix.isNone or not surface.drawnBindings.rootHitEnabled: return none(PointerTarget)
  var origin: POINT
  var client: RECT
  if ClientToScreen(surface.window, addr origin) == 0 or GetClientRect(surface.window, addr client) == 0:
    fail("Canvas pointer bounds are unavailable")
  if point.x < float64(origin.x) or point.y < float64(origin.y) or
      point.x >= float64(origin.x)+float64(client.right) or point.y >= float64(origin.y)+float64(client.bottom):
    return none(PointerTarget)
  let hit = surface.hitDrawn(matrix.get.transformPoint(point))
  let key = if hit.isSome: hit.get.target.key else: surface.drawnBindings.rootKey
  let record = surface.drawnBindings.binding(key)
  if record.isNone: return none(PointerTarget)
  surface.inputTarget(record.get.id)
proc rootInputTarget*(surface: CanvasSurface): Option[PointerTarget] =
  let record = surface.drawnBindings.binding(surface.drawnBindings.rootKey)
  if record.isSome: surface.inputTarget(record.get.id) else: none(PointerTarget)
proc hoverAtScreen*(surface: CanvasSurface, point: Vec2): seq[PointerTarget] =
  let target = surface.pointerAtScreen(point)
  if target.isNone: return
  # Source route is an owned keyless token path, never a frame/SDK/callback ref.
  for token in target.get.targetRouteInternal:
    let current = surface.inputTarget(token.id)
    if current.isSome: result.add(current.get)
proc projectInput*(surface: CanvasSurface, source: CanvasPointerEvent): Option[CanvasDelivery] =
  surface.checkOwner()
  if source.frameId == 0 or source.frameId > surface.frameId or not surface.inputBindingAlive(source.id):
    return none(CanvasDelivery)
  var route: seq[CanvasRouteTarget]
  var projected: Option[CanvasPointerEvent]
  for token in source.sourceRouteInternal:
    if not surface.inputBindingAlive(token.id):
      if token.id == source.id: return none(CanvasDelivery)
      continue # Do not invent a newly-interactive ancestor or call a dead owner.
    var current = surface.inputTarget(token.id, includeRoute=false)
    if current.isNone:
      if token.id == source.id and source.kind in {PointerEventKind.dragCancel, PointerEventKind.leave}:
        current = some(source.pointerTargetInternal)
      elif token.id == source.id: return none(CanvasDelivery)
      else: continue
    if token.id == source.id:
      projected = source.project(current.get)
      if projected.isNone:
        if source.kind notin {PointerEventKind.dragCancel, PointerEventKind.leave}: return none(CanvasDelivery)
        # Cleanup of a now singular live owner carries its last valid coordinates.
        current = some(source.pointerTargetInternal)
        projected = some(source)
    let key = surface.acceptedBindings.bindingKey(token.id)
    if key.isSome: route.add(CanvasRouteTarget(key: key.get, target: current.get))
  if projected.isNone or route.len == 0: return none(CanvasDelivery)
  some(canvasDeliveryInternal(projected.get, route))
