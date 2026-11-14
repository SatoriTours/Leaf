import std/[unittest, options, math, tables]
import leaf
import leaf/ui as ui
import leaf/[styles, backend, ui_contract, scroll_area_protocol, native_layout]
import leaf/backends/win32/capabilities

proc propsOf(node: Node): NormalizedProps = normalizeProps(node)

proc sampleContent(fields = 3): Node =
  var children: seq[Node] = @[]
  for index in 1 .. fields:
    children.add(ui.field(@[ui.label("字段" & $index),
      ui.input("", key = "f" & $index)]))
  ui.scrollAreaContent(children, key = "content")

suite "scroll area construction contract":
  test "a bounded vertical viewport accepts ordinary form content":
    let area = ui.scrollArea(sampleContent(), 320, key = "list")
    let props = propsOf(area)
    require props.standardUi.isSome
    check props.standardUi.get.role == UiRole.scrollArea
    check props.layout.height.isSome
    check props.layout.height.get.kind == dkFixed
    check props.layout.height.get.value == 320.0
    check area.children.len == 1
    let inner = propsOf(area.children[0])
    require inner.standardUi.isSome
    check inner.standardUi.get.role == UiRole.scrollAreaContent

  test "invalid heights are refused at construction":
    expect UiError:
      discard ui.scrollArea(sampleContent(), 0)
    expect UiError:
      discard ui.scrollArea(sampleContent(), -12)
    expect UiError:
      discard ui.scrollArea(sampleContent(), MaxScrollAreaHeight + 1)
    expect UiError:
      discard ui.scrollArea(sampleContent(), Inf)
    expect UiError:
      discard ui.scrollArea(sampleContent(), NaN)

  test "content must be standard, non-empty and not another scroll area":
    expect UiError:
      discard ui.scrollArea(nil, 200)
    expect UiError:
      discard ui.scrollArea(ui.button("not content"), 200)
    expect UiError:
      discard ui.scrollArea(ui.scrollAreaContent(@[]), 200)
    var emptySlot: seq[Node] = @[nil]
    expect UiError:
      discard ui.scrollAreaContent(emptySlot)
    # nested scroll areas are refused instead of silently clipped
    let inner = ui.scrollArea(sampleContent(), 120)
    expect UiError:
      discard ui.scrollArea(ui.scrollAreaContent(@[inner]), 300)

  test "scrollAreaHeightReason states the exact refusal":
    check scrollAreaHeightReason(0).len != 0
    check scrollAreaHeightReason(-1).len != 0
    check scrollAreaHeightReason(Inf).len != 0
    check scrollAreaHeightReason(MaxScrollAreaHeight + 0.5).len != 0
    check scrollAreaHeightReason(120).len == 0

suite "scroll area backend capability":
  test "Win32 declares the wired vertical viewport only for standard themes":
    for theme in [shadcnLight, shadcnDark]:
      let caps = win32Capabilities(theme)
      check saVertical in caps.scrollAreas
      let props = propsOf(ui.scrollArea(sampleContent(), 240))
      check checkTypedCapabilities("area", NodeKind.column, props, caps, strict).len == 0
    check saVertical notin win32Capabilities(systemTheme).scrollAreas

  test "a backend without the axis is rejected in strict mode":
    var capabilities = fullCapabilities()
    capabilities.scrollAreas = {}
    let props = propsOf(ui.scrollArea(sampleContent(), 240))
    expect UiError:
      discard checkTypedCapabilities("area", NodeKind.column, props, capabilities,
        strict)
    capabilities.scrollAreas = {saVertical}
    check checkTypedCapabilities("area", NodeKind.column, props, capabilities,
      strict).len == 0

  test "a scroll area without an explicit height is rejected":
    var capabilities = fullCapabilities()
    var props = propsOf(ui.scrollArea(sampleContent(), 240))
    props.layout.height = none(Dimension)
    expect UiError:
      discard checkTypedCapabilities("area", NodeKind.column, props, capabilities,
        strict)

suite "vertical scroll geometry":
  test "content taller than the viewport produces one bar and a real range":
    var measuredWidths: seq[float64]
    let plan = planVerticalScroll(300, 200, 16, 0,
      proc(width: float64): tuple[width, height: float64] =
        measuredWidths.add(width)
        (width, 640))
    check plan.verticalBar
    check plan.contentOverflowsWidth == false
    check plan.viewportWidth == 284.0
    check plan.viewportHeight == 200.0
    check plan.contentHeight == 640.0
    check plan.range == 440.0
    check plan.offset == 0.0
    # the content is re-measured at the final (bar-reduced) width
    check measuredWidths[^1] == 284.0

  test "content that fits keeps the bar off and the range zero":
    let plan = planVerticalScroll(300, 200, 16, 40,
      proc(width: float64): tuple[width, height: float64] = (width, 180))
    check plan.verticalBar == false
    check plan.range == 0.0
    check plan.offset == 0 # no range, so any requested offset clamps to zero
    check plan.viewportWidth == 300.0

  test "offsets are clamped into the resolved range":
    let measure = proc(width: float64): tuple[width, height: float64] =
      (width, 640)
    let low = planVerticalScroll(300, 200, 16, -50, measure)
    let high = planVerticalScroll(300, 200, 16, 10_000, measure)
    check low.offset == 0
    check high.offset == high.range
    check high.range == 440.0

  test "content wider than the viewport is reported, never silently clipped":
    let plan = planVerticalScroll(240, 200, 16, 0,
      proc(width: float64): tuple[width, height: float64] = (400, 300))
    check plan.contentOverflowsWidth
    check plan.viewportWidth == 224.0

  test "invalid inputs are refused explicitly":
    expect ValueError:
      discard planVerticalScroll(300, 0, 16, 0,
        proc(width: float64): tuple[width, height: float64] = (width, 10))
    expect ValueError:
      discard planVerticalScroll(300, Inf, 16, 0,
        proc(width: float64): tuple[width, height: float64] = (width, 10))
    expect ValueError:
      discard planVerticalScroll(300, 200, -1, 0,
        proc(width: float64): tuple[width, height: float64] = (width, 10))
    let missing: proc(width: float64): tuple[width, height: float64]
      {.closure.} = nil
    expect ValueError:
      discard planVerticalScroll(300, 200, 16, 0, missing)
