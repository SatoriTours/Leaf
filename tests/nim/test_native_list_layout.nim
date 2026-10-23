## T1: pure list geometry. No platform objects, no Runtime, no second scroll
## authority: `clampListOffset`, `listVisible` (overscan stays a Runtime
## responsibility) and `listRowRect` reuse `HeightIndex` prefix sums, so a row's
## y is derived from its item index rather than from an active sibling position.
import std/[unittest, math, tables, options, sets, algorithm]
import leaf/[core, styles, backend, height_index, native_layout, native_list_layout]

proc binding(index: int, key = ""): NativeRowBinding =
  NativeRowBinding(listHandle: NodeHandle(1), sourceGeneration: 1,
    itemIndex: index, itemKey: key)

proc fixedIndex(count: int, height: float64): HeightIndex =
  initHeightIndex(count, height)

proc viewport(): DipRect = DipRect(x: 10.0, y: 100.0, width: 300.0, height: 200.0)

proc approx(a, b: float64): bool = abs(a - b) < 1e-9

suite "clampListOffset":
  test "clamps into the reachable range and keeps offsets finite":
    check clampListOffset(1000.0, 100.0, -5.0) == 0.0
    check clampListOffset(1000.0, 100.0, 0.0) == 0.0
    check clampListOffset(1000.0, 100.0, 450.0) == 450.0
    check clampListOffset(1000.0, 100.0, 5000.0) == 900.0
    check clampListOffset(1000.0, 1000.0, 10.0) == 0.0
    check clampListOffset(50.0, 100.0, 10.0) == 0.0
    check clampListOffset(0.0, 100.0, 10.0) == 0.0
    check clampListOffset(1e11, 200.0, 1e11) == 1e11 - 200.0

  test "rejects non-finite or negative geometry":
    expect UiError: discard clampListOffset(NaN, 100.0, 0.0)
    expect UiError: discard clampListOffset(Inf, 100.0, 0.0)
    expect UiError: discard clampListOffset(1000.0, Inf, 0.0)
    expect UiError: discard clampListOffset(1000.0, -1.0, 0.0)
    expect UiError: discard clampListOffset(1000.0, 100.0, NaN)
    expect UiError: discard clampListOffset(1000.0, 100.0, -Inf)
    expect UiError: discard clampListOffset(-1.0, 100.0, 0.0)

suite "listVisible":
  test "derives the row window from prefix sums without adding overscan":
    let heights = fixedIndex(100, 10.0)
    let top = listVisible(heights, 0.0, 25.0)
    check top.first == 0
    check top.finish == 3
    check top.offset == 0.0
    check top.total == 1000.0
    let middle = listVisible(heights, 505.0, 25.0)
    check middle.first == 50
    check middle.finish == 53
    let bottom = listVisible(heights, 990.0, 25.0)
    # The offset clamps to total - viewport, so rows 97..99 stay visible.
    check bottom.first == 97
    check bottom.finish == 100
    # No overscan is added here; the Runtime adds it exactly once.
    check heights.visible(505.0, 25.0, 0).first == middle.first
    check heights.visible(505.0, 25.0, 0).finish == middle.finish

  test "empty and zero-height viewports are empty ranges":
    let empty = fixedIndex(0, 10.0)
    let range = listVisible(empty, 0.0, 100.0)
    check range.first == 0
    check range.finish == 0
    check range.total == 0.0
    let heights = fixedIndex(10, 10.0)
    let none = listVisible(heights, 5.0, 0.0)
    check none.first == 0
    check none.finish == 0
    check none.total == 100.0

  test "rejects non-finite input":
    let heights = fixedIndex(10, 10.0)
    expect UiError: discard listVisible(heights, NaN, 10.0)
    expect UiError: discard listVisible(heights, 0.0, Inf)
    expect UiError: discard listVisible(heights, 0.0, -1.0)

suite "listRowRect":
  test "fixed rows place y from the item index and the offset":
    let heights = fixedIndex(1000, 10.0)
    let rect = listRowRect(heights, binding(5), viewport(), 20.0)
    check rect.x == 10.0
    check rect.width == 300.0
    check rect.height == 10.0
    check rect.y == 130.0            # 100 + 5*10 - 20
    let first = listRowRect(heights, binding(0), viewport(), 0.0)
    check first.y == 100.0
    # A partially visible first row keeps its real y (negative overlap).
    let partial = listRowRect(heights, binding(0), viewport(), 4.0)
    check partial.y == 96.0

  test "variable rows use measured heights, not the estimate":
    var heights = initHeightIndex(4, 20.0)
    heights.measure(0, 30.0)
    heights.measure(1, 5.0)
    let rect = listRowRect(heights, binding(2), viewport(), 10.0)
    check rect.y == 100.0 + 30.0 + 5.0 - 10.0
    check rect.height == 20.0
    let last = listRowRect(heights, binding(3), viewport(), 0.0)
    check last.y == 100.0 + 35.0 + 20.0

  test "protected and non-contiguous item indices are not squeezed":
    var heights = initHeightIndex(200, 10.0)
    heights.measure(100, 40.0)
    let protectedRect = listRowRect(heights, binding(0), viewport(), 0.0)
    let farRect = listRowRect(heights, binding(100), viewport(), 0.0)
    # Item 0 stays at the top; item 100 sits at its own prefix offset.
    check protectedRect.y == 100.0
    check farRect.y == 100.0 + 100.0 * 10.0
    check farRect.height == 40.0
    let afterFar = listRowRect(heights, binding(101), viewport(), 0.0)
    check afterFar.y == 100.0 + 1000.0 + 40.0

  test "huge totals stay finite":
    let heights = initHeightIndex(MaxListItems, 1_000_000.0)
    let total = heights.total
    check total == 1e11
    let last = listRowRect(heights, binding(MaxListItems - 1), viewport(),
      clampListOffset(total, 200.0, 1e11))
    check classify(last.y) notin {fcNan, fcInf, fcNegInf}
    check classify(last.height) notin {fcNan, fcInf, fcNegInf}

  test "rejects out-of-range indices and non-finite viewports":
    let heights = fixedIndex(10, 10.0)
    expect UiError: discard listRowRect(heights, binding(10), viewport(), 0.0)
    expect UiError: discard listRowRect(heights, binding(-1), viewport(), 0.0)
    expect UiError: discard listRowRect(heights, binding(0), viewport(), NaN)
    expect UiError:
      discard listRowRect(heights, binding(0),
        DipRect(x: 0.0, y: 0.0, width: Inf, height: 10.0), 0.0)

suite "measured rows and re-measure on width change":
  test "row heights follow the measured subtree width":
    var measured: Table[int, float64]
    let measureRow = proc(entity: MountedEntity, available: DipSize): DipSize =
      # Height depends on the available width, like a wrapping text row.
      let width = if available.width <= 0.0: 100.0 else: available.width
      let height = width / 4.0
      measured[entity.index] = height
      DipSize(width: width, height: height)
    var entities: Table[NodeHandle, MountedEntity]
    let text = MountedEntity(handle: NodeHandle(9), parent: NodeHandle(8),
      nodeId: "row/text", kind: text, index: 0)
    let rowEntity = MountedEntity(handle: NodeHandle(8), parent: NodeHandle(7),
      nodeId: "row", kind: row, index: 0)
    entities[text.handle] = text
    entities[rowEntity.handle] = rowEntity
    let narrow = measureSubtree(entities, rowEntity.handle,
      DipSize(width: 200.0, height: 100.0), measureRow)
    let wide = measureSubtree(entities, rowEntity.handle,
      DipSize(width: 400.0, height: 100.0), measureRow)
    check narrow.width == 200.0
    check wide.width == 400.0
    check narrow.height < wide.height
    # Feed the real heights back into one HeightIndex; rects use prefix sums.
    var heights = initHeightIndex(2, wide.height)
    heights.measure(0, narrow.height)
    let first = listRowRect(heights, binding(0), viewport(), 0.0)
    let second = listRowRect(heights, binding(1), viewport(), 0.0)
    check first.height == narrow.height
    check approx(second.y, 100.0 + narrow.height)

suite "bounded subtree layout":
  proc boxAt(boxes: seq[LayoutBox], handle: NodeHandle): LayoutBox =
    for box in boxes:
      if box.handle == handle: return box
    LayoutBox(handle: NoHandle)

  test "a subtree root lays out without being the table root":
    var entities: Table[NodeHandle, MountedEntity]
    let column1 = MountedEntity(handle: NodeHandle(1), parent: NoHandle,
      nodeId: "root", kind: column, index: 0,
      props: NormalizedProps(layout: LayoutProps(height: some(
        Dimension(kind: dkFixed, value: 50.0)))))
    let row1 = MountedEntity(handle: NodeHandle(2), parent: NodeHandle(1),
      nodeId: "root/row", kind: row, index: 0,
      props: NormalizedProps(layout: LayoutProps(height: some(
        Dimension(kind: dkFixed, value: 30.0)))))
    let label = MountedEntity(handle: NodeHandle(3), parent: NodeHandle(2),
      nodeId: "root/row/text", kind: text, index: 0,
      props: NormalizedProps(layout: LayoutProps(width: some(
        Dimension(kind: dkFixed, value: 40.0)), height: some(
        Dimension(kind: dkFixed, value: 20.0)))))
    entities[column1.handle] = column1
    entities[row1.handle] = row1
    entities[label.handle] = label
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      DipSize(width: 40.0, height: 20.0)
    # A non-root subtree (the row) is a valid entry point.
    let boxes = layoutSubtree(entities, row1.handle,
      DipRect(x: 5.0, y: 7.0, width: 100.0, height: 30.0),
      DipRect(x: 0.0, y: 0.0, width: 120.0, height: 60.0), measure)
    check boxes.len == 2
    check boxes[0].handle == row1.handle
    check boxes[0].rect.x == 5.0
    check boxes[0].rect.y == 7.0
    check boxAt(boxes, label.handle).rect.x == 5.0
    check boxAt(boxes, label.handle).clip.width == 100.0
    let size = measureSubtree(entities, row1.handle,
      DipSize(width: 120.0, height: 60.0), measure)
    check size.width == 40.0
    check size.height == 30.0

  test "a virtual list stays a finite viewport leaf":
    var entities: Table[NodeHandle, MountedEntity]
    let list = MountedEntity(handle: NodeHandle(20), parent: NoHandle,
      nodeId: "list", kind: virtualList, index: 0,
      props: NormalizedProps(layout: LayoutProps(height: some(
        Dimension(kind: dkFixed, value: 300.0)))))
    let rowRoot = MountedEntity(handle: NodeHandle(21), parent: NodeHandle(20),
      nodeId: "list/item/k:1:0", kind: text, index: 0)
    entities[list.handle] = list
    entities[rowRoot.handle] = rowRoot
    var measureCalls = 0
    let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
      inc measureCalls
      DipSize(width: 200.0, height: 300.0)
    let size = measureSubtree(entities, list.handle,
      DipSize(width: 200.0, height: 400.0), measure)
    check measureCalls == 1
    check size.height == 300.0
    let boxes = layoutSubtree(entities, list.handle,
      DipRect(x: 0.0, y: 0.0, width: 200.0, height: 300.0),
      DipRect(x: 0.0, y: 0.0, width: 200.0, height: 300.0), measure)
    # The list is a leaf: its rows are laid out by their own viewport.
    check boxes.len == 1
    check boxes[0].handle == list.handle

suite "subtree geometry input contract":
  proc layoutEntities(): tuple[entities: Table[NodeHandle, MountedEntity],
                              leaf, parent: NodeHandle] =
    var entities: Table[NodeHandle, MountedEntity]
    let leaf = MountedEntity(handle: NodeHandle(1), parent: NodeHandle(2),
      nodeId: "leaf", kind: text, index: 0)
    let parent = MountedEntity(handle: NodeHandle(2), parent: NoHandle,
      nodeId: "parent", kind: column, index: 0)
    entities[leaf.handle] = leaf
    entities[parent.handle] = parent
    (entities, leaf.handle, parent.handle)

  let measure = proc(entity: MountedEntity, available: DipSize): DipSize =
    DipSize(width: 10.0, height: 10.0)

  test "non-finite or negative rect and clip are refused":
    let (entities, leaf, parent) = layoutEntities()
    let goodRect = DipRect(x: 0.0, y: 0.0, width: 100.0, height: 50.0)
    let goodClip = DipRect(x: 0.0, y: 0.0, width: 200.0, height: 100.0)
    expect UiError:
      discard layoutSubtree(entities, leaf,
        DipRect(x: NaN, y: 0.0, width: 100.0, height: 50.0), goodClip, measure)
    expect UiError:
      discard layoutSubtree(entities, leaf,
        DipRect(x: 0.0, y: Inf, width: 100.0, height: 50.0), goodClip, measure)
    expect UiError:
      discard layoutSubtree(entities, leaf,
        DipRect(x: 0.0, y: 0.0, width: Inf, height: 50.0), goodClip, measure)
    expect UiError:
      discard layoutSubtree(entities, leaf, goodRect,
        DipRect(x: 0.0, y: 0.0, width: NaN, height: 100.0), measure)
    expect UiError:
      discard layoutSubtree(entities, parent, goodRect,
        DipRect(x: 0.0, y: -Inf, width: 200.0, height: 100.0), measure)
    expect UiError:
      discard layoutSubtree(entities, leaf,
        DipRect(x: 0.0, y: 0.0, width: -1.0, height: 50.0), goodClip, measure)
    expect UiError:
      discard layoutSubtree(entities, leaf,
        DipRect(x: 0.0, y: 0.0, width: 100.0, height: -1.0), goodClip, measure)
    expect UiError:
      discard layoutSubtree(entities, leaf, goodRect,
        DipRect(x: 0.0, y: 0.0, width: 200.0, height: -1.0), measure)
    # measureSubtree keeps refusing a non-finite available size.
    expect UiError:
      discard measureSubtree(entities, parent,
        DipSize(width: NaN, height: 100.0), measure)

  test "finite negative offsets and zero extents stay legal":
    let (entities, leaf, parent) = layoutEntities()
    let boxes = layoutSubtree(entities, leaf,
      DipRect(x: -20.0, y: -10.0, width: 0.0, height: 0.0),
      DipRect(x: -50.0, y: -50.0, width: 100.0, height: 100.0), measure)
    check boxes.len == 1
    check boxes[0].handle == leaf
    check boxes[0].rect.x == -20.0
    check boxes[0].rect.y == -10.0
    check boxes[0].rect.width == 0.0
    check boxes[0].clip.width == 100.0
    # Ordinary form layout keeps its existing behaviour.
    let formBoxes = layoutSubtree(entities, parent,
      DipRect(x: 0.0, y: 0.0, width: 100.0, height: 50.0),
      DipRect(x: 0.0, y: 0.0, width: 100.0, height: 50.0), measure)
    check formBoxes.len == 2
    check formBoxes[0].handle == parent
