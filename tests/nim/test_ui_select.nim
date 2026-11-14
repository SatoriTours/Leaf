import std/[unittest, options, math]
import leaf
import leaf/[styles, host_protocol, select_protocol, overlay_protocol, backend, ui_contract]
import leaf/backends/win32/capabilities

proc sampleProps(options: seq[SelectOption], accepted = "", isOpen = false,
                 width = 0.0, placeholder = "Choose"): SelectProps =
  SelectProps(open: isOpen, value: accepted, placeholder: placeholder,
    options: options, width: width)

let colour = @[SelectOption(key: "red", label: "Red"),
  SelectOption(key: "green", label: "Green", disabled: true),
  SelectOption(key: "blue", label: "Blue")]

suite "select option model":
  test "valid descriptions accept duplicate labels but never fake state":
    let duplicateLabels = sampleProps(@[
      SelectOption(key: "a", label: "Same"),
      SelectOption(key: "b", label: "Same")], placeholder = "Pick")
    check invalidSelectReason(duplicateLabels) == ""
    check invalidSelectReason(sampleProps(colour, "blue")) == ""
    check invalidSelectReason(sampleProps(colour, isOpen = true, width = 240)) == ""

  test "duplicate and empty identities are rejected explicitly":
    let duplicate = sampleProps(@[
      SelectOption(key: "a", label: "A"), SelectOption(key: "a", label: "B")])
    check invalidSelectReason(duplicate) == "select option keys must be unique: a"
    let emptyKey = sampleProps(@[SelectOption(key: "", label: "A")])
    check invalidSelectReason(emptyKey) == "select option key must not be empty"
    let emptyLabel = sampleProps(@[SelectOption(key: "a", label: "")])
    check invalidSelectReason(emptyLabel) == "select option label must not be empty"

  test "empty and all-disabled lists cannot produce a candidate":
    let empty = sampleProps(@[])
    check invalidSelectReason(empty) == "select requires at least one option"
    let allDisabled = sampleProps(@[SelectOption(key: "a", label: "A", disabled: true)])
    check invalidSelectReason(allDisabled) == "select requires at least one enabled option"
    check initialCandidate(empty) == -1
    check initialCandidate(allDisabled) == -1
    check not openRequestAllowed(allDisabled)
    check candidateValue(empty, 0) == ""

  test "illegal initial values and widths are rejected instead of coerced":
    check invalidSelectReason(sampleProps(colour, "nope")) ==
      "select value is not one of the options: nope"
    check invalidSelectReason(sampleProps(colour, "green")) ==
      "select value names a disabled option: green"
    check invalidSelectReason(sampleProps(colour, width = NaN)) ==
      "select width is not finite"
    let narrow = sampleProps(colour, width = 8)
    let wide = sampleProps(colour, width = 4096)
    check invalidSelectReason(narrow) == "select width must be 0 or in 80.0..1024.0"
    check invalidSelectReason(wide) == "select width must be 0 or in 80.0..1024.0"

  test "labels, placeholder and accessible name stay caller-owned text":
    let empty = sampleProps(colour, placeholder = "Choose a colour")
    check displayLabel(empty) == "Choose a colour"
    check accessibleName(empty) == "Choose a colour"
    check accessibleName(sampleProps(colour, "blue")) == "Blue"
    let labelled = SelectProps(options: colour, value: "blue", placeholder: "Choose",
      label: "Colour")
    check accessibleName(labelled) == "Colour: Blue"
    check displayLabel(sampleProps(colour, "blue")) == "Blue"

suite "select candidate navigation":
  let rows = @[SelectOption(key: "a", label: "Alpha"),
    SelectOption(key: "b", label: "Beta", disabled: true),
    SelectOption(key: "c", label: "Charlie"),
    SelectOption(key: "d", label: "Disabled", disabled: true),
    SelectOption(key: "e", label: "Echo")]

  test "the initial candidate prefers the accepted value":
    check initialCandidate(SelectProps(options: rows, value: "c")) == 2
    check initialCandidate(SelectProps(options: rows)) == 0

  test "Up/Down wrap, skip disabled options and never land on one":
    let props = SelectProps(options: rows, value: "a")
    check stepCandidate(props, -1, 1) == 0
    check stepCandidate(props, 0, 1) == 2
    check stepCandidate(props, 2, 1) == 4
    check stepCandidate(props, 4, 1) == 0
    check stepCandidate(props, 0, -1) == 4
    let allDisabled = SelectProps(options: @[SelectOption(key: "x", label: "X", disabled: true)])
    check stepCandidate(allDisabled, 0, 1) == -1

  test "Home/End and page moves stay on usable candidates":
    let props = SelectProps(options: rows)
    check edgeCandidate(props, false) == 0
    check edgeCandidate(props, true) == 4
    check moveCandidate(props, 0, 2) == 4
    check moveCandidate(props, 4, -2) == 0
    check moveCandidate(props, 0, 0) == 0
    check pageStep(8) == 7
    check pageStep(1) == 1

  test "character navigation matches labels, skips disabled and keeps the candidate on a miss":
    let props = SelectProps(options: rows)
    check typeaheadCandidate(props, "c", 0) == 2
    check typeaheadCandidate(props, "d", 0) == 0
    check typeaheadCandidate(props, "E", 0) == 4
    check typeaheadCandidate(props, "zz", 2) == 2
    check typeaheadCandidate(props, "", 2) == 2

  test "candidate state never becomes the accepted value by itself":
    let props = SelectProps(options: rows, value: "a")
    let candidate = stepCandidate(props, props.selectedIndex, 1)
    check candidate == 2
    check props.value == "a"
    check candidateValue(props, candidate) == "c"
    check candidateValue(props, 1) == ""
    check candidateValue(props, 99) == ""

  test "commit notices retire when the option key disappears or is disabled":
    let props = SelectProps(options: rows, value: "a")
    check noticeValue(props, SelectNotice(kind: snCommit, optionKey: "c")) == "c"
    check noticeValue(props, SelectNotice(kind: snCommit, optionKey: "b")) == ""
    check noticeValue(props, SelectNotice(kind: snCommit, optionKey: "zz")) == ""
    check noticeValue(props, SelectNotice(kind: snClose)) == ""
    let moved = SelectProps(options: @[SelectOption(key: "a", label: "Alpha"),
      SelectOption(key: "c", label: "Charlie")])
    check noticeValue(moved, SelectNotice(kind: snCommit, optionKey: "b")) == ""

suite "select popup placement":
  test "a popup below the trigger keeps whole rows and reports the scroll range":
    let placement = planSelectPlacement(100, 100, 200, 32, 32, 20, 0, 0, 800, 600)
    check not placement.flipped
    check placement.x == 100
    check placement.y == 100 + 32 + SelectPopupGap
    check placement.rows == SelectPopupMaxRows
    check placement.height == 32.0 * float64(SelectPopupMaxRows)
    check placement.scrollRange == 20 - SelectPopupMaxRows

  test "a trigger near the bottom flips above and clamps into the work area":
    let placement = planSelectPlacement(760, 560, 200, 32, 32, 10, 0, 0, 800, 600)
    check placement.flipped
    check placement.y >= 0
    check placement.y + placement.height <= 600
    check placement.x + placement.width <= 800
    check placement.x >= 0

  test "a long list never exceeds the work area even when neither side fits":
    let placement = planSelectPlacement(10, 280, 200, 40, 32, 100, 0, 0, 400, 320)
    check placement.rows >= 1
    check placement.y >= 0
    check placement.y + placement.height <= 320
    check placement.scrollRange == 100 - placement.rows

  test "invalid geometry is refused, not silently coerced":
    expect ValueError:
      discard planSelectPlacement(NaN, 0, 100, 32, 32, 3, 0, 0, 800, 600)
    expect ValueError:
      discard planSelectPlacement(0, 0, 0, 32, 32, 3, 0, 0, 800, 600)
    expect ValueError:
      discard planSelectPlacement(0, 0, 100, 32, 32, 0, 0, 0, 800, 600)
    expect ValueError:
      discard planSelectPlacement(0, 0, 100, 32, 32, 3, 0, 0, 0, 600)

  test "visible rows, scrolling and hit testing agree with the placement":
    let placement = planSelectPlacement(0, 0, 180, 32, 32, 20, 0, 0, 640, 640)
    check visibleRows(0, placement.rows, 20) == (0, placement.rows)
    check scrollToCandidate(12, 0, placement.rows, 20) == 12 - placement.rows + 1
    check scrollToCandidate(2, 9, placement.rows, 20) == 2
    check scrollToCandidate(0, 0, placement.rows, 20) == 0
    check scrollToCandidate(19, 0, placement.rows, 20) == 20 - placement.rows
    check rowAt(0.0, 0.0, 32.0, 20) == 0
    check rowAt(33.0, 0.0, 32.0, 20) == 1
    check rowAt(-1.0, 0.0, 32.0, 20) == -1
    check rowAt(700.0, 0.0, 32.0, 20) == -1

import leaf/ui as standard

proc sampleSelect(accepted = "", isOpen = false): Node =
  standard.select(
    standard.selectTrigger(placeholder = "Choose a colour"),
    standard.selectContent(@[
      standard.selectItem("red", "Red"),
      standard.selectItem("green", "Green", disabled = true),
      standard.selectItem("blue", "Blue")]),
    value = accepted, open = isOpen, label = "Colour", key = "select")

suite "Select composite API":
  test "the composite parts collapse into one typed sidecar":
    let node = sampleSelect("blue", true)
    check node.key == "select"
    check node.kind == NodeKind.column
    check node.children.len == 1
    let trigger = node.children[0]
    check trigger.kind == NodeKind.button
    check trigger.text == "Blue"
    let props = normalizeProps(node)
    check props.standardUi.get.role == UiRole.select
    check props.accessibility.label.get == "Colour: Blue"
    let select = node.selectProps.get
    check select.open
    check select.value == "blue"
    check select.options.len == 3
    check select.options[1].disabled
    let triggerProps = normalizeProps(trigger)
    check triggerProps.standardUi.get.role == UiRole.selectTrigger
    check trigger.disabled == false

  test "placeholder text is shown while no value is accepted":
    let node = sampleSelect()
    check node.children[0].text == "Choose a colour"
    check normalizeProps(node).accessibility.label.get == "Colour: Choose a colour"
    check node.selectProps.get.value == ""

  test "invalid compositions are refused at construction":
    expect UiError:
      discard standard.select(standard.selectTrigger(), standard.selectContent(@[]))
    expect UiError:
      discard standard.select(standard.selectTrigger(), standard.selectContent(@[
        standard.selectItem("a", "A"), standard.selectItem("a", "B")]))
    expect UiError:
      discard standard.select(standard.selectContent(@[standard.selectItem("a", "A")]),
        standard.selectTrigger())
    expect UiError:
      discard standard.select(standard.selectTrigger(), standard.selectContent(@[
        standard.selectItem("a", "A", disabled = true)]))
    expect UiError:
      discard standard.select(standard.selectTrigger(), standard.selectContent(@[
        standard.selectItem("a", "A")]), value = "missing")
    check standard.selectTrigger(placeholder = "x").selectProps.isNone
    expect UiError:
      discard standard.selectItem("", "A")

  test "select props reject an unchecked sidecar on the wire":
    let bad = SelectProps(open: true, value: "a", options: @[
      SelectOption(key: "a", label: "A"), SelectOption(key: "a", label: "B")])
    expect UiError:
      discard core.ui(NodeKind.column, text = "Pick", styles = style({"width": "180"}),
        attributes = style({"ui_role": "select"}), select = some(bad))
    let good = SelectProps(value: "a", label: "Pick", options: @[
      SelectOption(key: "a", label: "A"), SelectOption(key: "b", label: "B")])
    let node = core.ui(NodeKind.column, text = "Pick", styles = style({"width": "180"}),
      attributes = style({"ui_role": "select"}), select = some(good))
    for policy in [hostCompatible, nativeStrict]:
      let wire = normalizeHostProps(node, policy)
      check wire.select.isSome
      check wire.select.get.options.len == 2
      check wire.select.get.value == "a"
      check (wire.eventMask and EventOpenChangeMask) == 0

  test "host wire validates options instead of accepting a stale shape":
    let good = SelectProps(value: "b", label: "Pick", options: @[
      SelectOption(key: "a", label: "A"), SelectOption(key: "b", label: "B")])
    let node = core.ui(NodeKind.column, text = "Pick", styles = style({"width": "180"}),
      attributes = style({"ui_role": "select"}), select = some(good))
    check normalizeHostProps(node, nativeStrict).select.get.value == "b"

  test "a backend without select support refuses it explicitly":
    var capabilities = BackendCapabilities(kinds: {column, button},
      standardUi: {low(UiRole)..high(UiRole)})
    let node = sampleSelect("red")
    expect UiError:
      discard checkTypedCapabilities("select", NodeKind.column,
        normalizeProps(node), capabilities, strict, none(OverlayProps),
        some(node.selectProps.get))
    let win32 = win32Capabilities(shadcnLight)
    check sfSingle in win32.selects
    let issues = checkTypedCapabilities("select", NodeKind.column,
      normalizeProps(node), win32, strict, none(OverlayProps),
      some(node.selectProps.get))
    check issues.len == 0

  test "the open request is a separate typed event from the value commit":
    var commits: seq[Event]
    var opens: seq[Event]
    let node = standard.select(
      standard.selectTrigger(placeholder = "Choose"),
      standard.selectContent(@[standard.selectItem("a", "A"),
        standard.selectItem("b", "B")]),
      value = "a", onChange = proc(event: Event) = commits.add(event),
      onOpenChange = proc(event: Event) = opens.add(event))
    check node.handler(change) != nil
    check node.handler(openChange) != nil
    check node.handler(click) == nil
    node.handler(change)(Event(kind: change, value: "b"))
    node.handler(openChange)(Event(kind: openChange, open: true))
    check commits.len == 1
    check commits[0].value == "b"
    check opens.len == 1
    check opens[0].open
    check not opens[0].checked
