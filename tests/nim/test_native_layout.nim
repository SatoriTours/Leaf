import ../fixture_app
import std/[unittest, tables, options, math, unicode]
import leaf/[core, widgets, styles, backend, backend_session, native_layout, graphics]
import leaf/backends/headless
import leaf/backends/win32/capabilities

proc ent(handle: uint64, parent: uint64, kind: NodeKind, index: int,
         layout: LayoutProps = default(LayoutProps)): MountedEntity =
  MountedEntity(handle: NodeHandle(handle), parent: NodeHandle(parent),
    nodeId: "n" & $handle, kind: kind, index: index,
    props: NormalizedProps(layout: layout))

proc fixedDim(value: float64): Option[Dimension] =
  some(Dimension(kind: dkFixed, value: value))

proc fillDim(): Option[Dimension] = some(Dimension(kind: dkFill))

proc autoDim(): Option[Dimension] = some(Dimension(kind: dkAuto))

proc zeroMeasure(entity: MountedEntity, available: DipSize): DipSize =
  DipSize(width: 0, height: 0)

proc makeHost(): HostContext =
  HostContext(sessionId: 7, mountGeneration: 1, contentWidth: 300,
    contentHeight: 200, scale: 1.0)

suite "Bounded DIP linear layout":
  test "row allocation with fixed and weighted fills":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0,
      LayoutProps(padding: some(5.0), gap: some(5.0)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(10)))
    entities[NodeHandle(3)] = ent(3, 1, text, 1,
      LayoutProps(width: fillDim(), flexGrow: some(2.0)))
    entities[NodeHandle(4)] = ent(4, 1, text, 2, LayoutProps(width: fillDim()))
    let boxes = layoutTree(entities, DipSize(width: 120, height: 40), zeroMeasure)
    check boxes.len == 4
    check boxes[0].handle == NodeHandle(1)
    check boxes[0].rect == DipRect(x: 0, y: 0, width: 120, height: 40)
    check boxes[1].rect.width == 10
    check boxes[2].rect.width == 60
    check boxes[3].rect.width == 30
    check boxes[1].rect.x == 5
    check boxes[2].rect.x == 20
    check boxes[3].rect.x == 85

  test "nested column inside a row":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0,
      LayoutProps(padding: some(4.0), gap: some(6.0)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(50)))
    entities[NodeHandle(3)] = ent(3, 1, column, 1,
      LayoutProps(width: fillDim(), gap: some(2.0)))
    entities[NodeHandle(4)] = ent(4, 3, text, 0, LayoutProps(height: fixedDim(10)))
    entities[NodeHandle(5)] = ent(5, 3, text, 1, LayoutProps(height: fixedDim(20)))
    let boxes = layoutTree(entities, DipSize(width: 200, height: 100), zeroMeasure)
    check boxes.len == 5
    check boxes[1].rect.x == 4
    check boxes[1].rect.width == 50
    check boxes[2].rect.x == 60
    check boxes[2].rect.width == 136
    check boxes[2].rect.height == 32
    check boxes[3].rect.y == 4
    check boxes[3].rect.height == 10
    check boxes[4].rect.y == 16
    check boxes[4].rect.height == 20

  test "empty and single child containers":
    var empty: Table[NodeHandle, MountedEntity]
    empty[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(padding: some(3.0)))
    let emptyBoxes = layoutTree(empty, DipSize(width: 50, height: 20), zeroMeasure)
    check emptyBoxes.len == 1
    check emptyBoxes[0].rect == DipRect(x: 0, y: 0, width: 50, height: 20)

    var single: Table[NodeHandle, MountedEntity]
    single[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(padding: some(3.0)))
    single[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(30)))
    let singleBoxes = layoutTree(single, DipSize(width: 50, height: 20), zeroMeasure)
    check singleBoxes.len == 2
    check singleBoxes[1].rect.x == 3
    check singleBoxes[1].rect.width == 30

  test "gap larger than the space does not shrink children":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0,
      LayoutProps(padding: some(2.0), gap: some(30.0)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(10)))
    entities[NodeHandle(3)] = ent(3, 1, text, 1, LayoutProps(width: fixedDim(10)))
    let boxes = layoutTree(entities, DipSize(width: 20, height: 10), zeroMeasure)
    check boxes[1].rect.width == 10
    check boxes[2].rect.width == 10
    check boxes[1].rect.x == 2
    check boxes[2].rect.x == 42

  test "negative remainder does not shrink":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(20)))
    entities[NodeHandle(3)] = ent(3, 1, text, 1, LayoutProps(width: fixedDim(20)))
    let boxes = layoutTree(entities, DipSize(width: 30, height: 10), zeroMeasure)
    check boxes[1].rect.width == 20
    check boxes[2].rect.width == 20
    check boxes[1].rect.x == 0
    check boxes[2].rect.x == 20

  test "justify between uses positive remainder only":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(justify: some(justifyBetween)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(10)))
    entities[NodeHandle(3)] = ent(3, 1, text, 1, LayoutProps(width: fixedDim(10)))
    entities[NodeHandle(4)] = ent(4, 1, text, 2, LayoutProps(width: fixedDim(10)))
    let boxes = layoutTree(entities, DipSize(width: 100, height: 10), zeroMeasure)
    check boxes[1].rect.x == 0
    check boxes[2].rect.x == 45
    check boxes[3].rect.x == 90

    # A single child never divides by zero.
    var one: Table[NodeHandle, MountedEntity]
    one[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(justify: some(justifyBetween)))
    one[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(10)))
    let oneBoxes = layoutTree(one, DipSize(width: 100, height: 10), zeroMeasure)
    check oneBoxes[1].rect.x == 0

  test "cross fixed and stretch":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(align: some(alignStretch)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0,
      LayoutProps(width: fixedDim(10), height: fixedDim(20)))
    entities[NodeHandle(3)] = ent(3, 1, text, 1, LayoutProps(width: fixedDim(10)))
    let boxes = layoutTree(entities, DipSize(width: 100, height: 50), zeroMeasure)
    check boxes[1].rect.height == 20
    check boxes[2].rect.height == 50

  test "cross align end and center":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(align: some(alignEnd)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0,
      LayoutProps(width: fixedDim(10), height: fixedDim(20)))
    let boxes = layoutTree(entities, DipSize(width: 100, height: 50), zeroMeasure)
    check boxes[1].rect.y == 30
    var center: Table[NodeHandle, MountedEntity]
    center[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(align: some(alignCenter)))
    center[NodeHandle(2)] = ent(2, 1, text, 0,
      LayoutProps(width: fixedDim(10), height: fixedDim(20)))
    let centerBoxes = layoutTree(center, DipSize(width: 100, height: 50), zeroMeasure)
    check centerBoxes[1].rect.y == 15

  test "auto uses recursive preferred measurement":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: autoDim()))
    var sizes: Table[uint64, DipSize]
    sizes[2] = DipSize(width: 42, height: 12)
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      sizes.getOrDefault(uint64(entity.handle), DipSize(width: 0, height: 0))
    let boxes = layoutTree(entities, DipSize(width: 200, height: 50), measure)
    check boxes[1].rect.width == 42
    check boxes[1].rect.height == 12

  test "zero sized content keeps identity and finite geometry":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(gap: some(4.0)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(10)))
    let boxes = layoutTree(entities, DipSize(width: 0, height: 0), zeroMeasure)
    # The zero-size result must still contain both entities in identity order.
    check boxes.len == 2
    check boxes[0].handle == NodeHandle(1)
    check boxes[1].handle == NodeHandle(2)
    check boxes[0].rect == DipRect(x: 0, y: 0, width: 0, height: 0)
    check boxes[0].clip.width == 0
    check boxes[0].clip.height == 0
    check boxes[1].rect.width == 10
    for box in boxes:
      check box.rect.width >= 0
      check box.rect.height >= 0
      check box.clip.width >= 0
      check box.clip.height >= 0
      check classify(box.rect.x) notin {fcNan, fcInf, fcNegInf}
      check classify(box.rect.y) notin {fcNan, fcInf, fcNegInf}
      check classify(box.rect.width) notin {fcNan, fcInf, fcNegInf}
      check classify(box.rect.height) notin {fcNan, fcInf, fcNegInf}

  test "10000 large fixed children accumulate without overflow":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(gap: some(1000.0)))
    for index in 0..<10_000:
      entities[NodeHandle(uint64(index + 2))] = ent(uint64(index + 2), 1, text,
        index, LayoutProps(width: fixedDim(1_000_000)))
    let boxes = layoutTree(entities, DipSize(width: 1000, height: 100), zeroMeasure)
    check boxes.len == 10_001
    for box in boxes:
      check classify(box.rect.x) notin {fcNan, fcInf, fcNegInf}
      check classify(box.rect.width) notin {fcNan, fcInf, fcNegInf}
    # The clip stays bounded by the finite content.
    check boxes[10_000].clip.width == 1000
    check boxes[10_000].clip.height == 100

  test "measure is cached per distinct effective constraint":
    var keys: seq[(uint64, float64, float64)]
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(gap: some(2.0)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: autoDim()))
    entities[NodeHandle(3)] = ent(3, 1, text, 1, LayoutProps(width: autoDim()))
    entities[NodeHandle(4)] = ent(4, 1, column, 2, LayoutProps(width: autoDim()))
    entities[NodeHandle(5)] = ent(5, 4, text, 0, LayoutProps(height: autoDim()))
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      keys.add((uint64(entity.handle), available.width, available.height))
      DipSize(width: 5, height: 3)
    let boxes = layoutTree(entities, DipSize(width: 100, height: 50), measure)
    # The same effective constraint is measured once within one layout call.
    var seen: seq[(uint64, float64, float64)]
    for key in keys:
      check key notin seen
      seen.add(key)
    check keys.len >= 3
    check boxes[1].rect.width == 5
    check boxes[2].rect.width == 5
    check boxes[3].rect.width == 5

  test "layout order follows the authoritative sibling index":
    proc render(): Node =
      column(@[
        button("a", key = "a", styles = style({"width": "40", "height": "20"})),
        button("b", key = "b", styles = style({"width": "40", "height": "20"})),
        button("c", key = "c", styles = style({"width": "40", "height": "20"}))], key = "root")
    let runtime = newRuntime(fixtureApplication(render, "layout", 300, 200))
    let recording = newRecordingBackend(fullCapabilities())
    let session = attachBackend(runtime, recording.backend, makeHost())
    let rootHandle = session.handleFor(runtime.find("root").id)
    let boxes = layoutTree(session.acceptedEntities,
      DipSize(width: 300, height: 200), zeroMeasure)
    check boxes.len == 4
    let childHandles = recording.childrenOf(rootHandle)
    check childHandles.len == 3
    for index in 0..<3:
      check boxes[index + 1].handle == childHandles[index]
      if index > 0:
        # A column stacks children vertically in authoritative sibling order.
        check boxes[index].rect.y < boxes[index + 1].rect.y
    dispose(session)

  test "pixel edges round shared boundaries without gaps":
    check pixelEdges(DipRect(x: 0, y: 0, width: 120, height: 40), 96) ==
      (left: 0, top: 0, right: 120, bottom: 40)
    check pixelEdges(DipRect(x: 0, y: 0, width: 120, height: 40), 144) ==
      (left: 0, top: 0, right: 180, bottom: 60)
    check pixelEdges(DipRect(x: 0, y: 0, width: 120, height: 40), 192) ==
      (left: 0, top: 0, right: 240, bottom: 80)
    let first = pixelEdges(DipRect(x: 0, y: 0, width: 1.5, height: 1), 96)
    let second = pixelEdges(DipRect(x: 1.5, y: 0, width: 1.5, height: 1), 96)
    check first.right == second.left
    check first.right == 2

  test "pixel edges reject non-finite and out of range values":
    expect UiError:
      discard pixelEdges(DipRect(x: 0, y: 0, width: NaN, height: 1), 96)
    expect UiError:
      discard pixelEdges(DipRect(x: 0, y: 0, width: 1e12, height: 1), 96)

suite "Win32 capability boundary":
  test "win32 declares the bounded supported set":
    let caps = win32Capabilities()
    check cfInputReset in caps.controls
    check caps.kinds == {column, row, text, button, input, checkbox, toggle,
      progress, tag, separator, spinner, virtualList, navigation, canvasHost}
    check NodeKind.virtualList in caps.kinds
    check NodeKind.navigation in caps.kinds
    check caps.layouts == {lfGap, lfPadding, lfWidth, lfHeight, lfFlexGrow,
      lfAlign, lfJustify, lfOverflow}
    check lfMinMax notin caps.layouts
    check lfFlexShrink notin caps.layouts
    check caps.alignments == {alignStart, alignEnd, alignCenter, alignStretch}
    check caps.justifications == {justifyStart, justifyEnd, justifyCenter,
      justifyBetween}
    check caps.overflows == {overflowHidden}
    check caps.decorations == {}
    check caps.variants == {variantDefault}

  test "Canvas capability accepts a typed frame without claiming extra decorations":
    let frame = newCanvasBuilder().finishFrame()
    let drawing = canvasNodeInternal(frame, styles = style({"height": "200", "width": "full"}))
    check checkCapabilities(mount(drawing), win32Capabilities(), strict).len == 0

  test "win32 accepts native lists and rejects unsupported required layout values":
    let caps = win32Capabilities()
    check checkCapabilities(mount(virtualList("l", @["a"],
      proc(index: int): Node = text("r"))), caps, compatible).len == 0
    expect UiError:
      discard checkCapabilities(mount(column(@[], styles = style({"min_width": "10"}))),
        caps, compatible)
    expect UiError:
      discard checkCapabilities(mount(column(@[], styles = style({"flex_shrink": "1"}))),
        caps, compatible)
    expect UiError:
      discard checkCapabilities(mount(row(@[], styles = style({"justify": "around"}))),
        caps, compatible)
    expect UiError:
      discard checkCapabilities(mount(row(@[], styles = style({"justify": "evenly"}))),
        caps, compatible)
    expect UiError:
      discard checkCapabilities(mount(row(@[], styles = style({"overflow": "scroll"}))),
        caps, compatible)
    expect UiError:
      discard checkCapabilities(mount(row(@[], styles = style({"overflow": "visible"}))),
        caps, compatible)
    let supported = mount(row(@[button("b", key = "b", variant = "default")], styles = style({
      "gap": "4", "padding": "2", "justify": "between", "overflow": "hidden",
      "width": "full", "flex_grow": "1", "align": "stretch"})))
    check checkCapabilities(supported, caps, strict).len == 0

  test "win32 decorations degrade in compatible and reject in strict":
    let caps = win32Capabilities()
    let node = mount(column(@[], styles = style({
      "background": "#ffffff", "radius": "4"})))
    let issues = checkCapabilities(node, caps, compatible)
    check issues.len == 2
    check issues[0].property == "background"
    check issues[1].property == "radius"
    expect UiError:
      discard checkCapabilities(node, caps, strict)

  test "win32 variant boundary and switch checkbox mapping":
    let caps = win32Capabilities()
    check checkCapabilities(mount(button("b", key = "b", variant = "default")),
      caps, strict).len == 0
    # The widget default variant is `primary`, which Win32 does not specially
    # support: it degrades with a structured issue in compatible mode.
    let primaryIssues = checkCapabilities(mount(button("b", key = "b")),
      caps, compatible)
    check primaryIssues.len == 1
    check primaryIssues[0].property == "variant"
    expect UiError:
      discard checkCapabilities(mount(button("b", key = "b")), caps, strict)
    expect UiError:
      discard checkCapabilities(mount(button("b", key = "b", variant = "danger")),
        caps, strict)
    let issues = checkCapabilities(mount(button("b", key = "b", variant = "danger")),
      caps, compatible)
    check issues.len == 1
    check issues[0].property == "variant"
    # A switch is the native checkbox/check mapping, not a decoration.
    check checkCapabilities(mount(switch("s", true, key = "s")), caps,
      strict).len == 0
    check checkCapabilities(mount(checkbox("c", true, key = "c")), caps,
      strict).len == 0
suite "MeasureProc local constraint and finite geometry":
  proc entityOf(handle, parent: uint64, index: int, node: Node): MountedEntity =
    MountedEntity(handle: NodeHandle(handle), parent: NodeHandle(parent),
      nodeId: "n" & $handle, kind: node.kind, index: index,
      props: normalizeProps(node))

  proc widthHeightMeasure(widths: ref seq[float64],
                          narrowLimit = 20.0): MeasureProc =
    result = proc(entity: MountedEntity, available: DipSize): DipSize =
      widths[].add(available.width)
      let label = entity.props.accessibility.label.get("")
      let natural = float64(runeLen(label)) * 10.0
      let height = if available.width <= narrowLimit: 30.0 else: 10.0
      DipSize(width: min(natural, available.width), height: height)

  test "fixed width column measures its text under the local width":
    var widths = new(seq[float64])
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.column, styles = style({"width": "20"})))
    entities[NodeHandle(3)] = entityOf(3, 2, 0,
      ui(NodeKind.text, text = "你好😀世界"))
    let boxes = layoutTree(entities, DipSize(width: 100, height: 100),
      widthHeightMeasure(widths))
    check boxes.len == 3
    check boxes[1].rect.width == 20
    check boxes[1].rect.height == 30
    check boxes[2].rect.height == 30
    check 20.0 in widths[]
    check 100.0 notin widths[]

  test "nested padding narrows the measured constraint":
    var widths = new(seq[float64])
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.column, styles = style({"width": "20", "padding": "5"})))
    entities[NodeHandle(3)] = entityOf(3, 2, 0,
      ui(NodeKind.text, text = "你好😀世界"))
    let boxes = layoutTree(entities, DipSize(width: 100, height: 100),
      widthHeightMeasure(widths))
    check 10.0 in widths[]
    check 20.0 notin widths[]
    # 30 content + 2 * 5 padding.
    check boxes[1].rect.height == 40

  test "fill allocated width re-measures the leaf height":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(80)))
    entities[NodeHandle(3)] = entityOf(3, 1, 1,
      ui(NodeKind.text, text = "你好😀世界", styles = style({"width": "full"})))
    let narrow = layoutTree(entities, DipSize(width: 100, height: 100),
      widthHeightMeasure(new(seq[float64])))
    check narrow[2].rect.width == 20
    check narrow[2].rect.height == 30
    let wide = layoutTree(entities, DipSize(width: 200, height: 100),
      widthHeightMeasure(new(seq[float64])))
    check wide[2].rect.width == 120
    check wide[2].rect.height == 10

  test "fixed height is not overridden by measurement":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.text, text = "x", styles = style({"width": "full", "height": "50"})))
    let boxes = layoutTree(entities, DipSize(width: 100, height: 100),
      widthHeightMeasure(new(seq[float64])))
    check boxes[1].rect.height == 50

  test "stretch never shrinks a larger intrinsic cross":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(align: some(alignStretch)))
    entities[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.text, text = "你好😀世界", styles = style({"width": "full"})))
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      DipSize(width: available.width, height: 30.0)
    let boxes = layoutTree(entities, DipSize(width: 100, height: 10), measure)
    check boxes[1].rect.height == 30

  test "explicit zero grow is distinct from default fill":
    var zero: Table[NodeHandle, MountedEntity]
    zero[NodeHandle(1)] = ent(1, 0, row, 0)
    zero[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.text, text = "x", styles = style({"width": "full", "flex_grow": "0"})))
    check layoutTree(zero, DipSize(width: 100, height: 20), zeroMeasure)[1].rect.width == 0

    var default: Table[NodeHandle, MountedEntity]
    default[NodeHandle(1)] = ent(1, 0, row, 0)
    default[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.text, text = "x", styles = style({"width": "full"})))
    check layoutTree(default, DipSize(width: 100, height: 20), zeroMeasure)[1].rect.width == 100

    var fixed: Table[NodeHandle, MountedEntity]
    fixed[NodeHandle(1)] = ent(1, 0, row, 0)
    fixed[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.text, text = "x", styles = style({"width": "10", "flex_grow": "0"})))
    check layoutTree(fixed, DipSize(width: 100, height: 20), zeroMeasure)[1].rect.width == 10

    var growFixed: Table[NodeHandle, MountedEntity]
    growFixed[NodeHandle(1)] = ent(1, 0, row, 0)
    growFixed[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.text, text = "x", styles = style({"width": "10", "flex_grow": "2"})))
    check layoutTree(growFixed, DipSize(width: 100, height: 20), zeroMeasure)[1].rect.width == 100

    var justify: Table[NodeHandle, MountedEntity]
    justify[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(justify: some(justifyEnd)))
    justify[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.text, text = "x", styles = style({"width": "10", "flex_grow": "0"})))
    check layoutTree(justify, DipSize(width: 100, height: 20), zeroMeasure)[1].rect.x == 90

  test "huge finite weighted fill stays finite":
    var huge: Table[NodeHandle, MountedEntity]
    huge[NodeHandle(1)] = ent(1, 0, row, 0)
    huge[NodeHandle(2)] = ent(2, 1, text, 0,
      LayoutProps(width: fillDim(), flexGrow: some(2.0)))
    let boxes = layoutTree(huge, DipSize(width: 1e308, height: 20), zeroMeasure)
    check boxes.len == 2
    for box in boxes:
      check classify(box.rect.width) notin {fcNan, fcInf, fcNegInf}
      check classify(box.rect.x) notin {fcNan, fcInf, fcNegInf}
    check boxes[1].rect.width == 1e308

  test "derived placement that cannot be represented raises UiError":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, column, 0, LayoutProps(align: some(alignEnd)))
    entities[NodeHandle(2)] = ent(2, 1, column, 0, LayoutProps(
      width: fixedDim(1.7e308), padding: some(1e308), align: some(alignEnd)))
    entities[NodeHandle(3)] = ent(3, 2, column, 0, LayoutProps(
      width: fixedDim(1.7e308), align: some(alignEnd)))
    entities[NodeHandle(4)] = ent(4, 3, text, 0)
    expect UiError:
      discard layoutTree(entities, DipSize(width: 100, height: 20), zeroMeasure)

  test "nested fill and explicit positive grow matrix":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(gap: some(10.0)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(20)))
    entities[NodeHandle(3)] = ent(3, 1, column, 1,
      LayoutProps(width: fillDim(), height: fillDim(), flexGrow: some(1.0),
        gap: some(4.0)))
    entities[NodeHandle(4)] = ent(4, 3, text, 0, LayoutProps(height: fixedDim(5)))
    entities[NodeHandle(5)] = ent(5, 3, text, 1,
      LayoutProps(height: fillDim(), flexGrow: some(3.0)))
    let boxes = layoutTree(entities, DipSize(width: 120, height: 60), zeroMeasure)
    # 120 - 20(fixed) - 10(gap) = 90 remainder, single weight 1 -> column width 90.
    check boxes[2].rect.width == 90
    # Column content height 60: 5 fixed + 4 gap leaves 51 for the grow-3 fill.
    check boxes[3].rect.height == 5
    check boxes[4].rect.height == 51

  test "auto height ancestor follows the final allocated width":
    var widths = new(seq[float64])
    var labels = new(seq[string])
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, column, 0)
    entities[NodeHandle(2)] = ent(2, 1, row, 0, LayoutProps(width: fillDim()))
    entities[NodeHandle(3)] = ent(3, 2, text, 0, LayoutProps(width: fixedDim(80)))
    entities[NodeHandle(4)] = entityOf(4, 2, 1,
      ui(NodeKind.text, text = "你好😀世界", styles = style({"width": "full"})))
    entities[NodeHandle(5)] = ent(5, 1, text, 1, LayoutProps(height: fixedDim(5)))
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      if entity.handle == NodeHandle(4):
        labels[].add(entity.props.accessibility.label.get(""))
        widths[].add(available.width)
        DipSize(width: min(50.0, available.width),
          height: (if available.width <= 20.0: 30.0 else: 10.0))
      else:
        DipSize()
    let boxes = layoutTree(entities, DipSize(width: 100, height: 100), measure)
    check boxes.len == 5
    check labels[].len > 0
    for label in labels[]: check label == "你好😀世界"
    # root column, auto-height row, fixed80 text, fill text, trailing sibling
    check boxes[1].handle == NodeHandle(2)
    check boxes[1].rect.width == 100
    check boxes[1].rect.height == 30
    check boxes[3].rect.width == 20
    check boxes[3].rect.height == 30
    check boxes[3].clip.height == 30
    # The trailing sibling sits below the real row height, not the stale 10.
    check boxes[4].handle == NodeHandle(5)
    check boxes[4].rect.y == 30
    check 20.0 in widths[]

  test "fixed width constraint is normalized before measuring and caching auto height":
    var constraints: seq[(uint64, float64, float64)]
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.text, text = "x", styles = style({"width": "20"})))
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      constraints.add((uint64(entity.handle), available.width, available.height))
      DipSize(width: 5, height: 3)
    let boxes = layoutTree(entities, DipSize(width: 100, height: 100), measure)
    check boxes[1].rect.width == 20
    check boxes[1].rect.height == 3
    # Auto height still needs measurement under the effective local width.
    check constraints.len == 1
    check constraints[0] == (2'u64, 20.0, 100.0)

  test "a new layout call does not reuse the previous cache":
    var calls = 0
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = entityOf(2, 1, 0,
      ui(NodeKind.text, text = "x", styles = style({"width": "20"})))
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      inc calls
      DipSize(width: 5, height: 3)
    discard layoutTree(entities, DipSize(width: 100, height: 100), measure)
    check calls == 1
    discard layoutTree(entities, DipSize(width: 200, height: 100), measure)
    check calls == 2

  test "column stretch expands auto and fill but never shrinks intrinsic":
    let small = proc(entity: MountedEntity, available: DipSize): DipSize =
      DipSize(width: 5, height: 3)
    var auto: Table[NodeHandle, MountedEntity]
    auto[NodeHandle(1)] = ent(1, 0, column, 0, LayoutProps(align: some(alignStretch)))
    auto[NodeHandle(2)] = ent(2, 1, text, 0)
    check layoutTree(auto, DipSize(width: 100, height: 100), small)[1].rect.width == 100

    var fill: Table[NodeHandle, MountedEntity]
    fill[NodeHandle(1)] = ent(1, 0, column, 0, LayoutProps(align: some(alignStretch)))
    fill[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fillDim()))
    check layoutTree(fill, DipSize(width: 100, height: 100), small)[1].rect.width == 100

    var fixed: Table[NodeHandle, MountedEntity]
    fixed[NodeHandle(1)] = ent(1, 0, column, 0, LayoutProps(align: some(alignStretch)))
    fixed[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(20)))
    check layoutTree(fixed, DipSize(width: 100, height: 100), small)[1].rect.width == 20

    var large: Table[NodeHandle, MountedEntity]
    large[NodeHandle(1)] = ent(1, 0, column, 0, LayoutProps(align: some(alignStretch)))
    large[NodeHandle(2)] = ent(2, 1, text, 0)
    let largeMeasure = proc(entity: MountedEntity, available: DipSize): DipSize =
      DipSize(width: 150, height: 3)
    check layoutTree(large, DipSize(width: 100, height: 100),
      largeMeasure)[1].rect.width == 150

    # Row stretch control remains intact.
    var rowAuto: Table[NodeHandle, MountedEntity]
    rowAuto[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(align: some(alignStretch)))
    rowAuto[NodeHandle(2)] = ent(2, 1, text, 0)
    check layoutTree(rowAuto, DipSize(width: 100, height: 100), small)[1].rect.height == 100


suite "Preferred bases and allocated width measurement phases":
  test "auto column height excludes allocated fill while explicit dimensions opt in":
    let small = proc(entity: MountedEntity, available: DipSize): DipSize =
      DipSize(width: 5, height: 3)
    for height in [autoDim(), fillDim(), fixedDim(10)]:
      var entities: Table[NodeHandle, MountedEntity]
      entities[NodeHandle(1)] = ent(1, 0, row, 0)
      entities[NodeHandle(2)] = ent(2, 1, column, 0, LayoutProps(height: height))
      entities[NodeHandle(3)] = ent(3, 2, text, 0, LayoutProps(height: fixedDim(10)))
      entities[NodeHandle(4)] = ent(4, 2, text, 1, LayoutProps(height: fillDim()))
      let boxes = layoutTree(entities, DipSize(width: 100, height: 100), small)
      check boxes.len == 4
      check boxes[1].handle == NodeHandle(2)
      check boxes[2].rect.height == 10
      if height.get.kind == dkFill:
        check boxes[1].rect.height == 100
        check boxes[3].rect.height == 90
      else:
        check boxes[1].rect.height == 10
        check boxes[3].rect.height == 0

  test "internal stretch cannot enlarge an auto column preferred width":
    let small = proc(entity: MountedEntity, available: DipSize): DipSize =
      DipSize(width: 5, height: 3)
    for width in [autoDim(), fillDim()]:
      var entities: Table[NodeHandle, MountedEntity]
      entities[NodeHandle(1)] = ent(1, 0, row, 0)
      entities[NodeHandle(2)] = ent(2, 1, column, 0,
        LayoutProps(width: width, align: some(alignStretch)))
      entities[NodeHandle(3)] = ent(3, 2, text, 0)
      let boxes = layoutTree(entities, DipSize(width: 100, height: 100), small)
      check boxes.len == 3
      let expectedWidth = if width.get.kind == dkFill: 100.0 else: 5.0
      check boxes[1].rect.width == expectedWidth
      check boxes[2].rect.width == expectedWidth
      check boxes[1].rect.height == 3

  test "grown fixed text uses allocated width and caches each effective constraint once":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = MountedEntity(handle: NodeHandle(2), parent: NodeHandle(1),
      nodeId: "utf", kind: text, index: 0, props: normalizeProps(ui(NodeKind.text,
        text = "你好😀世界", styles = style({"width": "10", "flex_grow": "2"}))))
    var keys: seq[(uint64, float64, float64)]
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      check entity.props.accessibility.label.get("") == "你好😀世界"
      keys.add((uint64(entity.handle), available.width, available.height))
      DipSize(width: min(50.0, available.width),
        height: (if available.width <= 20: 30.0 else: 10.0))
    let boxes = layoutTree(entities, DipSize(width: 100, height: 100), measure)
    check boxes.len == 2
    check boxes[1].rect.width == 100
    check boxes[1].rect.height == 10
    check keys == @[(2'u64, 10.0, 100.0), (2'u64, 100.0, 100.0)]
    keys.setLen(0)
    let second = layoutTree(entities, DipSize(width: 100, height: 100), measure)
    check second[1].rect.height == 10
    check keys == @[(2'u64, 10.0, 100.0), (2'u64, 100.0, 100.0)]

  test "fixed-size leaves never enter native intrinsic measurement":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = ent(2, 1, text, 0,
      LayoutProps(width: fixedDim(20), height: fixedDim(50)))
    var keys: seq[(uint64, float64, float64)]
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      keys.add((uint64(entity.handle), available.width, available.height))
      DipSize(width: 5, height: 3)
    let boxes = layoutTree(entities, DipSize(width: 100, height: 100), measure)
    check boxes[1].rect.width == 20
    check boxes[1].rect.height == 50
    check keys.len == 0

  test "grown fixed container propagates its allocated width to UTF preferred height":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0)
    entities[NodeHandle(2)] = ent(2, 1, column, 0,
      LayoutProps(width: fixedDim(10), flexGrow: some(2.0), align: some(alignStretch)))
    entities[NodeHandle(3)] = MountedEntity(handle: NodeHandle(3), parent: NodeHandle(2),
      nodeId: "utf", kind: text, index: 0, props: normalizeProps(ui(NodeKind.text,
        text = "你好😀世界")))
    var keys: seq[(uint64, float64, float64)]
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      check entity.props.accessibility.label.get("") == "你好😀世界"
      let key = (uint64(entity.handle), available.width, available.height)
      check key notin keys
      keys.add(key)
      DipSize(width: min(50.0, available.width),
        height: (if available.width <= 20: 30.0 else: 10.0))
    let boxes = layoutTree(entities, DipSize(width: 100, height: 100), measure)
    check boxes.len == 3
    check boxes[1].rect.width == 100
    check boxes[1].rect.height == 10
    check boxes[2].rect.width == 100
    check boxes[2].rect.height == 10
    check (3'u64, 100.0, 100.0) in keys
