import std/[unittest, options, tables, math]
import leaf/[core, styles, host_protocol, backend, native_theme]
import leaf/backends/win32/capabilities
import leaf/ui as standard

suite "standard UI typed facade and host contract":
  test "button variants and sizes are explicit without changing legacy button defaults":
    let node = standard.button("Save", key="save", variant=UiVariant.outline, size=UiSize.sm)
    let props = normalizeProps(node)
    require props.standardUi.isSome
    check props.standardUi.get.role == UiRole.button
    check props.standardUi.get.variant == UiVariant.outline
    check props.standardUi.get.size == UiSize.sm
    check props.layout.height.get.value == 32
    let normal = normalizeProps(standard.button("Save"))
    check normal.layout.height.get.value == 36
    check normal.control.variant.isNone

  test "loading prevents activation and leaves the visible label stable":
    var clicks = 0
    let node = standard.button("Save", loading=true,
      onClick=proc(e: Event) = inc clicks)
    check node.disabled
    check node.text == "Save"
    check node.handler(click) == nil
    check normalizeProps(node).standardUi.get.loading

  test "input keeps system EDIT behavior and reset token while exposing invalid state":
    let node = standard.input("草稿", key="name", invalid=true,
      placeholder="姓名", resetToken=42)
    let props = normalizeProps(node)
    check node.kind == NodeKind.input
    check props.control.value.get == "草稿"
    check props.control.resetToken.get == 42
    check props.standardUi.get.invalid
    check props.layout.height.get.value == 36

  test "card composition uses real container and text nodes":
    let node = standard.card(@[
      standard.cardHeader(@[
        standard.cardTitle("账户"), standard.cardDescription("管理公开信息")]),
      standard.cardContent(@[standard.input("叶")]),
      standard.cardFooter(@[standard.button("保存")])], key="account")
    check node.kind == NodeKind.column
    check normalizeProps(node).standardUi.get.role == UiRole.card
    check node.children.len == 3
    check node.children[0].children[1].children[1].children[0].kind == NodeKind.text

  test "compatible host normalization retains required standard semantics":
    let node = standard.button("Delete", variant=UiVariant.destructive)
    let compatible = normalizeHostProps(node, hostCompatible).normalized
    let strict = normalizeHostProps(node, nativeStrict).normalized
    check compatible.standardUi == strict.standardUi
    check compatible.standardUi.get.variant == UiVariant.destructive

  test "unsupported backends reject required standard semantics even in compatible mode":
    let p = normalizeProps(standard.button("Save"))
    expect UiError:
      discard checkTypedCapabilities("save", NodeKind.button, p, win32Capabilities(systemTheme))
    expect UiError:
      discard checkTypedCapabilities("save", NodeKind.button, p, win32Capabilities(matsuLight))
    check checkTypedCapabilities("save", NodeKind.button, p, win32Capabilities(shadcnLight), strict).len == 0

  test "malformed raw metadata cannot claim another kind or silently downgrade":
    for attrs in [
      style({"ui_role":"card", "ui_variant":"outline"}),
      style({"ui_role":"input"}),
      style({"ui_role":"button", "ui_size":"unknown"}),
      style({"ui_invalid":"true"}),
      style({"ui_role":"button", "ui_loading":"maybe"}),
      style({"ui_role":"button", "ui_invalid":"true"}),
      style({"ui_typo":"button"})]:
      expect UiError:
        discard normalizeProps(core.ui(NodeKind.button, attributes=attrs))
      expect UiError:
        discard normalizeHostProps(core.ui(NodeKind.button, attributes=attrs),hostCompatible)

  test "textarea is explicit multiline EDIT with minimum height and reset semantics":
    let node=standard.textarea("第一行\nemoji 😀",key="bio",invalid=true,
      disabled=true,resetToken=9,height=96)
    let props=normalizeProps(node)
    check node.kind==NodeKind.input
    check props.standardUi.get.role==UiRole.textarea
    check props.standardUi.get.invalid
    check props.control.multiline.get
    check props.control.resetToken.get==9
    check not props.control.enabled.get
    check props.layout.height.get.value==96
    check normalizeProps(standard.textarea("")).layout.height.get.value==64
    expect UiError: discard standard.textarea("",height=63)
    expect UiError: discard standard.textarea("",height=NaN)
    for (role,multiline) in [("input","true"),("textarea","false")]:
      expect UiError:
        discard normalizeProps(core.ui(NodeKind.input,
          attributes=style({"ui_role":role,"multiline":multiline})))

  test "field groups labels and messages without misusing CardTitle":
    let node=standard.field(@[standard.label("简介"),standard.textarea(""),
      standard.fieldDescription("选填"),standard.fieldError("过长")])
    check normalizeProps(node).standardUi.get.role==UiRole.field
    check normalizeProps(node).layout.gap.get==8
    check normalizeProps(node.children[0]).standardUi.get.role==UiRole.label
    check normalizeProps(node.children[2]).standardUi.get.role==UiRole.fieldDescription
    check normalizeProps(node.children[3]).standardUi.get.role==UiRole.fieldError
    for child in node.children:
      check checkTypedCapabilities("field-child",child.kind,normalizeProps(child),
        win32Capabilities(shadcnDark),strict).len==0
