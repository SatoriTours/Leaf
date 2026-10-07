import std/[unittest, options, math]
import leaf/[core, widgets, styles, gpui_styles]

proc rejectsStyle(pairs: openArray[(string, string)]): bool =
  try:
    discard normalizeProps(column(@[], styles = style(pairs)))
    false
  except UiError:
    true

proc rejectsNode(node: Node): bool =
  try:
    discard normalizeProps(node)
    false
  except UiError:
    true

suite "Backend-neutral typed control properties":
  test "full becomes fill and is not infinite":
    let props = normalizeProps(column(@[], styles = style({
      "width": "full", "height": "full"})))
    check props.layout.width.isSome
    check props.layout.height.isSome
    check props.layout.width.get.kind == dkFill
    check props.layout.height.get.kind == dkFill
    check classify(props.layout.width.get.value) notin {fcNan, fcInf, fcNegInf}
    check classify(props.layout.height.get.value) notin {fcNan, fcInf, fcNegInf}
    let auto = normalizeProps(column(@[], styles = style({"width": "auto"})))
    check auto.layout.width.get.kind == dkAuto

  test "defaults differ from explicit zero":
    let bare = normalizeProps(column(@[]))
    check bare.layout.gap.isNone
    check bare.layout.width.isNone
    check bare.layout.padding.isNone
    check bare.decoration.opacity.isNone
    let explicit = normalizeProps(column(@[], styles = style({
      "gap": "0", "padding": "0", "width": "0", "opacity": "0"})))
    check explicit.layout.gap.isSome
    check explicit.layout.gap.get == 0.0
    check explicit.layout.padding.isSome
    check explicit.layout.padding.get == 0.0
    check explicit.layout.width.isSome
    check explicit.layout.width.get.kind == dkFixed
    check explicit.layout.width.get.value == 0.0
    check explicit.decoration.opacity.isSome
    check explicit.decoration.opacity.get == 0.0

  test "invalid style always fails":
    check rejectsStyle({"gap": "NaN"})
    check rejectsStyle({"gap": "Inf"})
    check rejectsStyle({"gap": "-Inf"})
    check rejectsStyle({"padding": "-1"})
    check rejectsStyle({"width": "-5"})
    check rejectsStyle({"height": "NaN"})
    check rejectsStyle({"flex_grow": "1000001"})
    check rejectsStyle({"opacity": "1.1"})
    check rejectsStyle({"background": "#12"})
    check rejectsStyle({"background": "#12345"})
    check rejectsStyle({"color": "#GGGGGG"})
    check rejectsStyle({"border_color": "red"})
    check rejectsStyle({"not_a_style": "1"})
    check rejectsStyle({"justify": "sideways"})
    check rejectsStyle({"align": "middle"})
    check rejectsStyle({"weight": "heavy"})
    check rejectsStyle({"overflow": "clip"})

  test "known decoration remains typed":
    let props = normalizeProps(text("hi", styles = style({
      "background": "#11223344", "color": "#abc", "border_color": "#010203",
      "radius": "4", "border_width": "2", "opacity": "0.5", "font_size": "13"})))
    check props.decoration.background.isSome
    let background = props.decoration.background.get
    check (background.r, background.g, background.b, background.a) ==
      (0x11'u8, 0x22'u8, 0x33'u8, 0x44'u8)
    let color = props.decoration.color.get
    check (color.r, color.g, color.b, color.a) ==
      (0xaa'u8, 0xbb'u8, 0xcc'u8, 0xff'u8)
    let border = props.decoration.borderColor.get
    check (border.r, border.g, border.b, border.a) ==
      (0x01'u8, 0x02'u8, 0x03'u8, 0xff'u8)
    check props.decoration.radius.get == 4.0
    check props.decoration.borderWidth.get == 2.0
    check props.decoration.opacity.get == 0.5
    check props.decoration.fontSize.get == 13.0

  test "layout enumerations keep their full legacy vocabulary":
    let props = normalizeProps(row(@[], styles = style({
      "align": "stretch", "justify": "around", "overflow": "scroll",
      "weight": "semibold", "flex_shrink": "1", "min_width": "10",
      "max_height": "200"})))
    check props.layout.align.get == alignStretch
    check props.layout.justify.get == justifyAround
    check props.layout.overflow.get == overflowScroll
    check props.decoration.weight.get == weightSemibold
    check props.layout.flexShrink.get == 1.0
    check props.layout.minWidth.get == 10.0
    check props.layout.maxHeight.get == 200.0
    check props.layout.flexGrow.isNone

  test "invalid control attributes fail":
    check rejectsNode(ui(NodeKind.checkbox, attributes = style({"checked": "maybe"})))
    check rejectsNode(ui(NodeKind.toggle, attributes = style({"checked": "1"})))
    check rejectsNode(ui(NodeKind.progress, attributes = style({"value": "101"})))
    check rejectsNode(ui(NodeKind.progress, attributes = style({"value": "-1"})))
    check rejectsNode(ui(NodeKind.progress, attributes = style({"value": "NaN"})))
    check rejectsNode(ui(NodeKind.button, text = "b",
      attributes = style({"variant": "neon"})))
    check rejectsNode(ui(NodeKind.checkbox, attributes = style({"value": "3"})))
    check rejectsNode(ui(NodeKind.button, text = "b",
      attributes = style({"mystery": "1"})))
    check rejectsNode(ui(NodeKind.text, text = "t",
      attributes = style({"checked": "true"})))
    check not rejectsNode(checkbox("ok", true))
    check not rejectsNode(progress(50.0))
    check not rejectsNode(button("ok"))

  test "control values become typed fields":
    let checkProps = normalizeProps(checkbox("要", true))
    check checkProps.control.label.get == "要"
    check checkProps.control.checked.get == true
    check checkProps.control.enabled.get == true
    let progressProps = normalizeProps(progress(84.0))
    check progressProps.control.progress.get == 84.0
    let inputProps = normalizeProps(input("value", key = "i",
      placeholder = "hint", onChange = proc(e: Event) = discard))
    check inputProps.control.value.get == "value"
    check inputProps.control.placeholder.get == "hint"
    check inputProps.control.hasChange
    let buttonProps = normalizeProps(button("save", onClick = proc(e: Event) = discard))
    check buttonProps.control.label.get == "save"
    check buttonProps.control.variant.get == variantPrimary
    check buttonProps.control.hasClick
    check not buttonProps.control.hasChange

  test "removed property restores default":
    let withGap = normalizeProps(column(@[], styles = style({"gap": "8"})))
    check withGap.layout.gap.get == 8.0
    check withGap.layout.gap == some(8.0)
    let removedGap = normalizeProps(column(@[]))
    check removedGap.layout.gap.isNone
    let checkedProps = normalizeProps(checkbox("x", true))
    check checkedProps.control.checked.get == true
    let plainChecked = normalizeProps(ui(NodeKind.checkbox, text = "x"))
    check plainChecked.control.checked.isNone
    check plainChecked.control.label.get == "x"

  test "validateProps walks mounted children":
    let root = mount(column(@[text("hi"), input("v", key = "i")]))
    validateProps(root)
    let bad = mount(column(@[
      text("hi"),
      ui(NodeKind.checkbox, attributes = style({"checked": "maybe"}))]))
    expect UiError:
      validateProps(bad)

  test "legacy bridge reuses style syntax only":
    validateStyles(mount(button("b", styles = style({"gap": "8"}))))
    validateStyles(mount(column(@[text("hi", styles = style({"color": "#abc"}))])))
    expect UiError:
      validateStyles(mount(button("b", styles = style({"gap": "NaN"}))))
    expect UiError:
      validateStyles(mount(button("b", styles = style({"unknown": "1"}))))
