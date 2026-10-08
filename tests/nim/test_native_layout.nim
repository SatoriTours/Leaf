import std/[unittest, tables, options, math]
import leaf/[core, widgets, styles, backend, backend_session, native_layout]
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

  test "zero sized content stays finite":
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(gap: some(4.0)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: fixedDim(10)))
    let boxes = layoutTree(entities, DipSize(width: 0, height: 0), zeroMeasure)
    for box in boxes:
      check box.rect.width >= 0
      check box.rect.height >= 0
      check classify(box.rect.x) notin {fcNan, fcInf, fcNegInf}
      check classify(box.rect.y) notin {fcNan, fcInf, fcNegInf}

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

  test "measure is called once per leaf and results drive layout":
    var calls = 0
    var entities: Table[NodeHandle, MountedEntity]
    entities[NodeHandle(1)] = ent(1, 0, row, 0, LayoutProps(gap: some(2.0)))
    entities[NodeHandle(2)] = ent(2, 1, text, 0, LayoutProps(width: autoDim()))
    entities[NodeHandle(3)] = ent(3, 1, text, 1, LayoutProps(width: autoDim()))
    entities[NodeHandle(4)] = ent(4, 1, column, 2, LayoutProps(width: autoDim()))
    entities[NodeHandle(5)] = ent(5, 4, text, 0, LayoutProps(height: autoDim()))
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      inc calls
      DipSize(width: 5, height: 3)
    let boxes = layoutTree(entities, DipSize(width: 100, height: 50), measure)
    check calls == 3
    check boxes[1].rect.width == 5
    check boxes[2].rect.width == 5
    check boxes[3].rect.width == 5

  test "layout order follows the authoritative sibling index":
    proc render(ctx: BuildContext): Node =
      column(@[
        button("a", key = "a", styles = style({"width": "40", "height": "20"})),
        button("b", key = "b", styles = style({"width": "40", "height": "20"})),
        button("c", key = "c", styles = style({"width": "40", "height": "20"}))], key = "root")
    let runtime = newRuntime(Application(title: "layout", width: 300, height: 200,
      render: render))
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
      progress, tag, separator, spinner}
    check NodeKind.virtualList notin caps.kinds
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

  test "win32 rejects unsupported required kinds and layout values":
    let caps = win32Capabilities()
    expect UiError:
      discard checkCapabilities(mount(virtualList("l", @["a"],
        proc(index: int): Node = text("r"))), caps, compatible)
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