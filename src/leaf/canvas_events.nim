## Canvas DSL construction and one typed managed-event entry. Callbacks belong
## to the accepted Node, never to draw commands or native paint callbacks.
import std/[tables, sets, unicode]
import ./[core, graphics, canvas_input, animation]
export canvas_input

type
  CanvasHandler = proc(event: CanvasPointerEvent) {.closure.}
  HandlerSet = array[PointerEventKind, CanvasHandler]
  CanvasElementInternal* = object
    identity*, parentIdentity*: string
    commandIndex*: int
  CanvasDslBuilderInternal* = ref object
    drawing: CanvasBuilder
    scopes: seq[string]
    identities: HashSet[string]
    handlers: Table[string, HandlerSet]
    bindings, identityBytes: int

proc canvasKeyInternal*(value: string): string = value
proc canvasKeyInternal*[T: SomeInteger](value: T): string = $value
proc newCanvasDslBuilderInternal*(viewBox: Option[Vec2], background: Color): CanvasDslBuilderInternal =
  CanvasDslBuilderInternal(drawing: newCanvasBuilder(viewBox, background), scopes: @["r"],
    identities: initHashSet[string](), handlers: initTable[string, HandlerSet]())
proc frameBuilderInternal*(builder: CanvasDslBuilderInternal): CanvasBuilder = builder.drawing
proc elementInternal*(builder: CanvasDslBuilderInternal, site, key: string,
    explicitKey, needsIdentity: bool): CanvasElementInternal =
  let segment = if explicitKey: "k" & $key.len & ":" & key else: "s" & $site.len & ":" & site
  if segment.len > 1_048_576 - builder.scopes[^1].len - 1 or validateUtf8(segment) != -1 or '\0' in segment:
    raise newException(GraphicsError, "invalid or oversized Canvas key")
  result.identity = builder.scopes[^1] & "/" & segment
  result.parentIdentity = builder.scopes[^1]
  result.commandIndex = builder.drawing.commandCount
  if explicitKey or needsIdentity:
    if result.identity in builder.identities: raise newException(GraphicsError, "duplicate sibling Canvas key")
    let bytes = result.identity.len + sizeof(string)
    if bytes > MaxCanvasFrameBytes - builder.identityBytes:
      raise newException(GraphicsError, "Canvas construction identity budget exceeded")
    builder.identities.incl(result.identity)
    builder.identityBytes += bytes
proc transitionInternal*(builder: CanvasDslBuilderInternal, element: CanvasElementInternal,
    properties: set[CanvasProperty], duration: AnimationDuration, easing: Easing,
    translation=vec2(0,0), rotation=0.deg, scaling=vec2(1,1)) =
  builder.drawing.addTransitionInternal(CanvasTransitionDefinition(commandIndex:element.commandIndex,
    identity:element.identity, properties:properties, durationMs:duration.milliseconds,
    easingId:ord(easing), translation:translation, rotation:rotation, scaling:scaling))
proc pushScopeInternal*(builder: CanvasDslBuilderInternal, element: CanvasElementInternal) =
  builder.scopes.add(element.identity)
proc popScopeInternal*(builder: CanvasDslBuilderInternal) = builder.scopes.setLen(builder.scopes.len-1)
proc registerElementInternal*(builder: CanvasDslBuilderInternal, element: CanvasElementInternal,
    mask: uint32, hitTest: bool) =
  if mask == 0 and hitTest: return
  if mask != 0:
    if builder.bindings >= MaxCanvasInteractionBindings: raise newException(GraphicsError, "Canvas interaction binding quota exceeded")
    inc builder.bindings
  builder.drawing.addInteractionInternal(CanvasInteraction(commandIndex: element.commandIndex,
    key: element.identity, parentIdentity: element.parentIdentity, eventMask: mask, hitTest: hitTest))
proc handlerInternal*(builder: CanvasDslBuilderInternal, element: CanvasElementInternal,
    kind: PointerEventKind, callback: CanvasHandler) =
  if callback == nil: raise newException(GraphicsError, "Canvas event handler is nil")
  var handlers = builder.handlers.getOrDefault(element.identity)
  if handlers[kind] != nil: raise newException(GraphicsError, "duplicate Canvas event handler")
  handlers[kind] = callback
  builder.handlers[element.identity] = handlers
proc rootElementInternal*(): CanvasElementInternal = CanvasElementInternal(identity: "r", commandIndex: -1)
proc finishCanvasNodeInternal*(builder: CanvasDslBuilderInternal, key: string, styles: Styles,
    focusable = false, accessibleLabel = ""): Node =
  if accessibleLabel.len > MaxStringBytes or validateUtf8(accessibleLabel) != -1 or '\0' in accessibleLabel:
    raise newException(GraphicsError, "invalid Canvas accessible label")
  builder.drawing.setFocusableInternal(focusable)
  let frame = builder.drawing.finishFrame()
  let handlers = builder.handlers # Owned accepted callback registry, not builder alias.
  let callback: Callback = if handlers.len == 0: nil else:
    proc(event: Event) =
      if event.kind != EventKind.canvasInput or event.canvas.isNil or event.canvas.needsProjectionInternal:
        raise newException(GraphicsError, "Canvas event payload or channel is invalid")
      # A removed target/ancestor invalidates the packet before any callback can
      # write a draft; it must not fall through to a new or surviving ancestor.
      for entry in event.canvas.routeInternal:
        if not handlers.hasKey(entry.key): return
      let source = event.canvas.sourceInternal.beginDeliveryInternal
      let bubbles = source.kind in {PointerEventKind.click, PointerEventKind.pointerDown,
        PointerEventKind.pointerMove, PointerEventKind.pointerUp, PointerEventKind.wheel}
      for entry in event.canvas.routeInternal:
        # Stable identity, never a command index after reorder.
        let callback = handlers[entry.key][source.kind]
        if callback != nil and source.sourceAllowsInternal(entry.target.id):
          callback(source.atTargetInternal(entry.target))
        if not bubbles or source.propagationStoppedInternal: break
  ui(NodeKind.canvasHost, key = key, text = accessibleLabel, styles = styles, canvas = some(frame), onCanvasInput = callback)
