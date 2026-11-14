import std/[unittest, options]
import leaf/[core, styles, backend, native_theme, ui_contract, radio_group_protocol]
import leaf/backends/win32/capabilities
import leaf/ui as standard
import leaf/ui/appearance

proc items3(accepted = "b", disabled = false): seq[Node] =
  @[
    standard.radioGroupItem("a", "选项一", key = "i-a", disabled = disabled),
    standard.radioGroupItem("b", "选项二", key = "i-b", disabled = disabled),
    standard.radioGroupItem("c", "选项三", key = "i-c", disabled = disabled)]

suite "standard radio group contract":
  test "appended roles keep every earlier wire ordinal stable":
    # Append-only: the wire/JSON role names may grow but ordinals never move.
    check ord(UiRole.button) == 0
    check ord(UiRole.checkbox) == 13
    check ord(UiRole.switch) == 14
    check ord(UiRole.scrollAreaContent) == ord(UiRole.scrollArea) + 1
    check ord(UiRole.radioGroup) == ord(UiRole.scrollAreaContent) + 1
    check ord(UiRole.radioGroupItem) == ord(UiRole.radioGroup) + 1
    check $UiRole.radioGroup == "radioGroup"
    check $UiRole.radioGroupItem == "radioGroupItem"

  test "a group maps the accepted value onto real radio items":
    var received: seq[string]
    let node = standard.radioGroup(items3(), "b", label = "配送方式", key = "ship",
      onChange = proc(e: Event) = received.add(e.value))
    let p = normalizeProps(node)
    check node.kind == NodeKind.column
    require p.standardUi.isSome
    check p.standardUi.get.role == UiRole.radioGroup
    check p.control.radioValue == some("b")
    check node.children.len == 3
    for i, child in node.children:
      let item = normalizeProps(child)
      require item.standardUi.isSome
      check item.standardUi.get.role == UiRole.radioGroupItem
      check child.kind == NodeKind.checkbox
      check item.control.radioValue == some(["a", "b", "c"][i])
      check item.control.checked == some(i == 1)
      check item.layout.height.get.value == 20
    # Activation of an item delivers exactly the item's value to the group.
    node.children[2].handler(change)(Event(kind: change, checked: true))
    check received == @["c"]

  test "an empty accepted value selects nothing without inventing a choice":
    let node = standard.radioGroup(items3(), "", key = "ship")
    for child in node.children:
      check normalizeProps(child).control.checked == some(false)

  test "a disabled group keeps the accepted value but drops every handler":
    var events = 0
    let cb: Callback = proc(e: Event) = inc events
    let node = standard.radioGroup(items3(disabled = true), "b", key = "ship",
      disabled = true, onChange = cb)
    check node.disabled
    for child in node.children:
      check child.disabled
      check child.handler(change) == nil
      check not normalizeProps(child).control.enabled.get
    check normalizeProps(node.children[1]).control.checked == some(true)
    check events == 0

  test "invalid groups are refused at construction":
    # Empty group.
    expect UiError:
      discard standard.radioGroup(newSeq[Node](), "a")
    # A nil child.
    expect UiError:
      discard standard.radioGroup(@[Node(nil)], "")
    # A plain checkbox is not a radio item.
    expect UiError:
      discard standard.radioGroup(@[standard.checkbox("x", false)], "")
    # A second group nested as an item.
    expect UiError:
      discard standard.radioGroup(@[standard.radioGroup(items3(), "a")], "")
    # Duplicate option values.
    expect UiError:
      discard standard.radioGroup(@[standard.radioGroupItem("a", "one"),
        standard.radioGroupItem("a", "two")], "a")
    # Empty option value.
    expect UiError:
      discard standard.radioGroup(@[standard.radioGroupItem("", "one")], "")
    # Accepted value that is not one of the options: never silently pick first.
    expect UiError:
      discard standard.radioGroup(items3(), "zzz")

  test "a bare radio item carries native kind, role and value metadata":
    let item = standard.radioGroupItem("value-1", "单选一项", key = "one")
    let p = normalizeProps(item)
    check item.kind == NodeKind.checkbox
    check p.standardUi.get.role == UiRole.radioGroupItem
    check p.control.radioValue == some("value-1")
    check p.control.checked == some(false)
    # A plain checkbox cannot smuggle radio metadata.
    expect UiError:
      discard normalizeProps(core.ui(NodeKind.checkbox, text = "plain",
        attributes = style({"ui_role": "checkbox", "radio_value": "x"})))
    # A radio item requires its declared option value.
    expect UiError:
      discard normalizeProps(core.ui(NodeKind.checkbox, text = "item",
        attributes = style({"ui_role": "radioGroupItem"})))

suite "radio group focus and navigation policy":
  test "the single tab stop is the accepted enabled item, else the first enabled":
    let checkedMiddle = @[
      RadioItem(value: "a", enabled: true),
      RadioItem(value: "b", enabled: true, checked: true),
      RadioItem(value: "c", enabled: true)]
    check radioTabStop(checkedMiddle) == 1
    let nothingChecked = @[
      RadioItem(value: "a", enabled: false),
      RadioItem(value: "b", enabled: true),
      RadioItem(value: "c", enabled: true)]
    check radioTabStop(nothingChecked) == 1
    let checkedButDisabled = @[
      RadioItem(value: "a", enabled: true),
      RadioItem(value: "b", enabled: false, checked: true)]
    check radioTabStop(checkedButDisabled) == 0
    check radioTabStop(@[RadioItem(value: "a", enabled: false)]) == -1
    check radioTabStop(newSeq[RadioItem]()) == -1

  test "arrows wrap and skip disabled items while Home and End jump":
    let items = @[
      RadioItem(value: "a", enabled: true),
      RadioItem(value: "b", enabled: false),
      RadioItem(value: "c", enabled: true),
      RadioItem(value: "d", enabled: false),
      RadioItem(value: "e", enabled: true)]
    check radioMove(items, 0, radioDown) == 2
    check radioMove(items, 2, radioDown) == 4
    check radioMove(items, 4, radioDown) == 0
    check radioMove(items, 0, radioUp) == 4
    check radioMove(items, 2, radioUp) == 0
    check radioMove(items, 0, radioHome) == 0
    check radioMove(items, 4, radioEnd) == 4
    check radioMove(items, 2, radioHome) == 0
    check radioMove(items, 2, radioEnd) == 4
    # No enabled neighbour at all: stay on the current item.
    check radioMove(@[RadioItem(value: "a"), RadioItem(value: "b")], 0,
      radioDown) == 0
    check radioMove(items, -1, radioDown) == 0

  test "only one accepted option may be checked in a group":
    check radioSelectionReason(@[
      RadioItem(value: "a", enabled: true),
      RadioItem(value: "b", enabled: true, checked: true)], "b") == ""
    check radioSelectionReason(@[
      RadioItem(value: "a", enabled: true, checked: true),
      RadioItem(value: "b", enabled: true, checked: true)], "a") != ""
    check radioSelectionReason(@[
      RadioItem(value: "a", enabled: true)], "b") != ""
    check radioSelectionReason(@[RadioItem(value: "", enabled: true)], "") != ""

suite "radio group backend contract":
  test "the win32 shadcn backend declares real radio roles and native kinds":
    let capabilities = win32Capabilities(shadcnLight)
    for role in [UiRole.radioGroup, UiRole.radioGroupItem]:
      check role in capabilities.standardUi
    check NodeKind.checkbox in capabilities.kinds
    let group = standard.radioGroup(items3(), "a", key = "g")
    check checkTypedCapabilities("g", group.kind, normalizeProps(group),
      capabilities, strict).len == 0
    check checkTypedCapabilities("i", group.children[0].kind,
      normalizeProps(group.children[0]), capabilities, strict).len == 0

  test "a backend without standard UI refuses the group instead of approximating":
    let system = win32Capabilities(systemTheme)
    let group = standard.radioGroup(items3(), "a", key = "g")
    expect UiError:
      discard checkTypedCapabilities("g", group.kind, normalizeProps(group),
        system, strict)

  test "radio visuals follow Neutral without reusing the checkbox tick":
    let white = srgb(1, 1, 1)
    let unchecked = checkAppearance(UiColorMode.light, UiRole.radioGroupItem, white)
    check unchecked.border == 0xe5e5e5'u32
    let accepted = checkAppearance(UiColorMode.light, UiRole.radioGroupItem, white,
      checked = true)
    check accepted.border == 0x171717'u32
    check accepted.mark == 0x171717'u32
    let darkAccepted = checkAppearance(UiColorMode.dark, UiRole.radioGroupItem,
      srgb(10.0/255, 10.0/255, 10.0/255), checked = true)
    check darkAccepted.border == 0xe5e5e5'u32
    let glyph = checkMetrics(UiRole.radioGroupItem)
    check glyph.width == 16
    check glyph.height == 16
    check glyph.radius == 8
    var rejected = false
    try: discard checkMetrics(UiRole.radioGroupItem, UiSize.sm)
    except ValueError: rejected = true
    check rejected
