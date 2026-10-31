import std/[unittest, options]
import leaf/[core, styles, backend, graphics]
import leaf/backends/win32/layout_state

proc entity(kind = NodeKind.text, fixed = false): MountedEntity =
  result = MountedEntity(kind: kind, handle: NodeHandle(2), parent: NodeHandle(1))
  result.props.control.label = some("old")
  if fixed:
    result.props.layout.width = some(Dimension(kind: dkFixed, value: 80))
    result.props.layout.height = some(Dimension(kind: dkFixed, value: 24))

suite "Win32 layout invalidation":
  test "fixed leaf content changes do not invalidate geometry":
    for kind in [NodeKind.text, NodeKind.button, NodeKind.input, NodeKind.checkbox,
        NodeKind.toggle, NodeKind.progress, NodeKind.canvasHost]:
      let old = entity(kind, true)
      var next = old
      next.props.control.label = some("a much longer 中文 label")
      next.props.control.value = some("new")
      next.props.control.checked = some(true)
      next.props.control.progress = some(42.0)
      check not layoutAffected(old, next)

  test "auto content is measured but progress and callback changes are paint only":
    let old = entity()
    var next = old
    next.props.control.label = some("longer")
    check layoutAffected(old, next)
    next = old
    next.props.accessibility.label = some("fallback")
    check layoutAffected(old, next)
    next = old
    next.props.control.hasClick = true
    check not layoutAffected(old, next)
    let progress = entity(NodeKind.progress)
    next = progress
    next.props.control.progress = some(50.0)
    check not layoutAffected(progress, next)

  test "Canvas frames retain the transactional draw path even at fixed dimensions":
    for fixed in [false, true]:
      var old = entity(NodeKind.canvasHost, fixed)
      old.canvas = some(newCanvasBuilder(background = color("#000000")).finishFrame())
      var next = old
      next.canvas = some(newCanvasBuilder(background = color("#FFFFFF")).finishFrame())
      check layoutAffected(old, next)
      check not layoutAffected(old, old)

  test "layout, font role, structure and list metadata remain conservative":
    let old = entity(NodeKind.text, true)
    var next = old
    next.props.layout.width = some(Dimension(kind: dkFixed, value: 100))
    check layoutAffected(old, next)
    next = old
    next.parent = NodeHandle(3)
    check layoutAffected(old, next)
    next = old
    next.props.control.variant = some(variantPrimary)
    check layoutAffected(old, next)
    let list = entity(NodeKind.virtualList, true)
    next = list
    next.props.control.label = some("changed list")
    check layoutAffected(list, next)
