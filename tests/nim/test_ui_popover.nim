import std/[unittest, options, math]
import leaf
import leaf/[styles, host_protocol, popover_protocol, select_protocol, backend,
  overlay_protocol,
  ui_contract]
import leaf/ui as standard
import leaf/core as core
import leaf/backends/win32/capabilities

proc sample(isOpen = false, onOpenChange: Callback = nil): Node =
  standard.popover(standard.popoverTrigger("Filters"),
    standard.popoverContent(@[standard.label("Hello")]), open = isOpen,
    name = "Filters", onOpenChange = onOpenChange, key = "popover")

proc props(name = "Filters", isOpen = false, width = 0.0, offset = 4.0,
           side = PopoverSide.bottom, align = PopoverAlign.alignStart): PopoverProps =
  PopoverProps(open: isOpen, side: side, align: align, sideOffset: offset,
    width: width, name: name)

suite "popover description":
  test "defaults follow the pinned upstream content metrics":
    check DefaultPopoverWidth == 288.0
    check props().popoverWidth == 288.0
    check props(width = 320).popoverWidth == 320.0
    check props(offset = 0.0).popoverOffset == DefaultPopoverSideOffset
    check props(offset = 12.0).popoverOffset == 12.0

  test "identity, width and offset are validated instead of coerced":
    check invalidPopoverReason(props()) == ""
    check invalidPopoverReason(props(name = "")) ==
      "popover requires an accessible name"
    check invalidPopoverReason(props(width = 100)) ==
      "popover width must be 0 or in 160.0..720.0"
    check invalidPopoverReason(props(width = 800)) ==
      "popover width must be 0 or in 160.0..720.0"
    check invalidPopoverReason(props(width = NaN)) ==
      "popover width is not finite"
    check invalidPopoverReason(props(offset = -1)) ==
      "popover side offset must be in 0..64.0"
    check invalidPopoverReason(props(offset = Inf)) ==
      "popover side offset is not finite"

  test "every dismissal is only a request":
    for dismiss in PopoverDismiss:
      check dismissAllowed(props(isOpen = true), dismiss)

suite "popover placement":
  test "start-aligned bottom placement honours offset and margin":
    let placed = planPopoverPlacement(
      anchorX = 100, anchorY = 100, anchorWidth = 120, anchorHeight = 32,
      contentWidth = 288, contentHeight = 200,
      workX = 0, workY = 0, workWidth = 1024, workHeight = 768,
      side = PopoverSide.bottom, align = PopoverAlign.alignStart, sideOffset = 8)
    check placed.x == 100.0
    check placed.y == 140.0
    check placed.width == 288.0
    check placed.height == 200.0
    check placed.usedSide == PopoverSide.bottom
    check not placed.flipped

  test "center and end alignment use the anchor extent":
    let centered = planPopoverPlacement(100, 100, 120, 32, 80, 40, 0, 0, 1024,
      768, PopoverSide.bottom, PopoverAlign.alignCenter)
    check centered.x == 120.0
    let ended = planPopoverPlacement(100, 100, 120, 32, 80, 40, 0, 0, 1024, 768,
      PopoverSide.bottom, PopoverAlign.alignEnd)
    check ended.x == 140.0

  test "flips to the opposite side when the requested side overflows":
    let flipped = planPopoverPlacement(100, 700, 120, 32, 288, 200, 0, 0, 1024,
      768, PopoverSide.bottom, PopoverAlign.alignStart)
    check flipped.usedSide == PopoverSide.top
    check flipped.flipped
    check flipped.y == 700.0 - DefaultPopoverSideOffset - 200.0

  test "clamps inside the work area instead of leaving the screen":
    let clamped = planPopoverPlacement(900, 100, 120, 32, 288, 200, 0, 0, 1024,
      768, PopoverSide.bottom, PopoverAlign.alignStart)
    check clamped.x == 1024.0 - PopoverMargin - 288.0
    check clamped.usedSide == PopoverSide.bottom

  test "horizontal sides flip as well":
    let left = planPopoverPlacement(500, 300, 60, 30, 200, 100, 0, 0, 1024, 768,
      PopoverSide.left, PopoverAlign.alignStart)
    check left.x == 500.0 - DefaultPopoverSideOffset - 200.0
    check left.usedSide == PopoverSide.left
    let flippedRight = planPopoverPlacement(30, 300, 60, 30, 200, 100, 0, 0, 1024,
      768, PopoverSide.left, PopoverAlign.alignStart)
    check flippedRight.usedSide == PopoverSide.right

  test "content that cannot fit is refused before publishing":
    expect ValueError:
      discard planPopoverPlacement(10, 10, 40, 20, 2000, 100, 0, 0, 1024, 768,
        PopoverSide.bottom, PopoverAlign.alignStart)
    expect ValueError:
      discard planPopoverPlacement(10, 10, 40, 20, 100, 1000, 0, 0, 1024, 768,
        PopoverSide.bottom, PopoverAlign.alignStart)
    expect ValueError:
      discard planPopoverPlacement(NaN, 10, 40, 20, 100, 100, 0, 0, 1024, 768,
        PopoverSide.bottom, PopoverAlign.alignStart)
    expect ValueError:
      discard planPopoverPlacement(10, 10, 0, 20, 100, 100, 0, 0, 1024, 768,
        PopoverSide.bottom, PopoverAlign.alignStart)

  test "a tiny work area is refused rather than clamped to nothing":
    expect ValueError:
      discard planPopoverPlacement(10, 10, 40, 20, 100, 100, 0, 0, 20, 768,
        PopoverSide.bottom, PopoverAlign.alignStart)

suite "popover public API":
  test "builds a page-flow trigger and a named panel":
    let node = sample()
    let normalized = normalizeProps(node)
    check normalized.standardUi.get.role == UiRole.popover
    let typed = node.popoverProps.get
    check typed.name == "Filters"
    check typed.popoverWidth == DefaultPopoverWidth
    check node.children.len == 2
    check node.children[0].kind == NodeKind.button
    check normalizeProps(node.children[0]).standardUi.get.role ==
      UiRole.popoverTrigger
    check normalizeProps(node.children[1]).standardUi.get.role ==
      UiRole.popoverContent

  test "parts reject business handlers and descriptions":
    expect UiError:
      discard normalizeProps(core.ui(NodeKind.button, text = "Open",
        attributes = style({"ui_role": $UiRole.popoverTrigger}),
        onClick = proc(e: Event) = discard))
    expect UiError:
      discard normalizeProps(core.ui(NodeKind.column,
        children = @[standard.label("x")],
        attributes = style({"ui_role": $UiRole.popoverContent}),
        popover = some(props())))
    expect UiError:
      discard normalizeProps(core.ui(NodeKind.button, text = "x",
        attributes = style({"ui_role": $UiRole.popoverClose}),
        onClick = proc(e: Event) = discard))
    let trigger = core.ui(NodeKind.button, text = "Open",
      attributes = style({"ui_role": $UiRole.popoverTrigger}))
    check normalizeProps(trigger).standardUi.get.role == UiRole.popoverTrigger

  test "invalid and nested shapes are rejected before mounting":
    expect UiError:
      discard standard.popover(standard.button("Open"),
        standard.popoverContent(@[standard.label("x")]), name = "Filters")
    expect UiError:
      discard standard.popover(standard.popoverTrigger("Open"),
        standard.popoverContent(@[standard.label("x")]))
    let inner = sample()
    expect UiError:
      discard standard.popover(standard.popoverTrigger("Open"),
        standard.popoverContent(@[inner]), name = "Outer")
    expect UiError:
      discard standard.popover(standard.popoverTrigger("Open"),
        standard.popoverContent(@[]), name = "Outer")

  test "an existing select is hosted inside the panel body":
    let combo = standard.select(standard.selectTrigger(placeholder = "Colour"),
      standard.selectContent(@[standard.selectItem("red", "Red"),
        standard.selectItem("blue", "Blue")]), label = "Colour")
    let node = standard.popover(standard.popoverTrigger("Filters"),
      standard.popoverContent(@[combo]), name = "Filters")
    check node.children[1].children.len == 1
    check node.children[1].children[0].selectProps.isSome

  test "the accepted state is never written by the component":
    var requests: seq[Event]
    let node = sample(isOpen = true, onOpenChange = proc(e: Event) = requests.add(e))
    check node.popoverProps.get.open
    node.handler(openChange)(Event(kind: openChange, open: false))
    check requests.len == 1
    check not requests[0].open
    check not requests[0].checked
    check node.popoverProps.get.open

suite "popover host wire and capabilities":
  test "host props carry the typed description and re-validate it":
    let node = standard.popover(standard.popoverTrigger("Filters"),
      standard.popoverContent(@[standard.label("Hello")]), name = "Filters",
      open = true, side = PopoverSide.top, align = PopoverAlign.alignCenter,
      width = 320, onOpenChange = proc(e: Event) = discard)
    let wire = normalizeHostProps(node, nativeStrict)
    check wire.popover.isSome
    check wire.popover.get.open
    check wire.popover.get.side == PopoverSide.top
    check wire.popover.get.width == 320.0
    check (wire.eventMask and EventOpenChangeMask) != 0

  test "a backend must declare the non-modal popover feature":
    let node = sample()
    let strictCaps = win32Capabilities(shadcnLight)
    check pfNonModal in strictCaps.popovers
    let issues = checkTypedCapabilities("p1", NodeKind.column,
      normalizeProps(node), strictCaps, strict, none(OverlayProps),
      none(SelectProps), some(node.popoverProps.get))
    check issues.len == 0
    expect UiError:
      discard checkTypedCapabilities("p1", NodeKind.column,
        normalizeProps(node), BackendCapabilities(kinds: {column, button},
          standardUi: {low(UiRole)..high(UiRole)}), strict, none(OverlayProps),
        none(SelectProps), some(node.popoverProps.get))
    # The system theme refuses the owned popup instead of inlining the panel.
    check pfNonModal notin win32Capabilities(systemTheme).popovers

  test "the typed check rejects a non-container host":
    let node = core.ui(NodeKind.column, children = @[
      standard.popoverTrigger("Filters"), standard.popoverContent(@[standard.label("x")])],
      attributes = style({"ui_role": $UiRole.popover}), text = "Filters",
      popover = some(props()))
    expect UiError:
      discard checkTypedCapabilities("p2", NodeKind.button,
        normalizeProps(node), win32Capabilities(shadcnLight), strict,
        none(OverlayProps), none(SelectProps), some(props()))
