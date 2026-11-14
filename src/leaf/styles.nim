## Backend-neutral style syntax validation and typed property conversion.
##
## This module owns the backend-neutral public style vocabulary. It
## parses string `Styles` tables once, into typed values
## that every backend can consume without re-parsing arbitrary strings. It
## contains no platform capability decisions: whether a given decoration can be
## honoured is declared separately by each backend.
import std/[tables, strutils, math, options]
import ./core
import ./overlay_protocol
import ./ui_contract
export ui_contract

const MaxStyleNumber* = 1_000_000.0

type
  DimensionKind* = enum
    dkAuto, dkFixed, dkFill

  Dimension* = object
    ## `full` becomes `dkFill` (remaining space inside the parent), never an
    ## infinite extent. `value` is only meaningful for `dkFixed`; it is 0 for
    ## auto/fill so callers can still read a finite number.
    kind*: DimensionKind
    value*: float64

  Align* = enum
    alignStart, alignEnd, alignCenter, alignStretch

  Justify* = enum
    justifyStart, justifyEnd, justifyCenter, justifyBetween, justifyAround, justifyEvenly

  Overflow* = enum
    overflowScroll, overflowHidden, overflowVisible

  FontWeight* = enum
    weightNormal, weightMedium, weightSemibold, weightBold

  Rgba* = object
    r*, g*, b*, a*: uint8

  LayoutProps* = object
    width*, height*: Option[Dimension]
    gap*, padding*: Option[float64]
    flexGrow*, flexShrink*: Option[float64]
    minWidth*, minHeight*, maxWidth*, maxHeight*: Option[float64]
    align*: Option[Align]
    justify*: Option[Justify]
    overflow*: Option[Overflow]

  DecorationProps* = object
    color*, background*, borderColor*: Option[Rgba]
    radius*, borderWidth*, opacity*, fontSize*: Option[float64]
    weight*: Option[FontWeight]

  ControlVariant* = enum
    variantDefault, variantPrimary, variantDanger, variantSuccess, variantWarning,
    variantInfo, variantOutline, variantGhost, variantSecondary

  ControlProps* = object
    label*: Option[string]
    value*: Option[string]
    placeholder*: Option[string]
    enabled*: Option[bool]
    checked*: Option[bool]
    progress*: Option[float64]
    radioValue*: Option[string]
      ## Declared option value of one radio item, or the accepted value of a
      ## radio group. Absent for every other control.
    variant*: Option[ControlVariant]
    resetToken*: Option[uint64]
    multiline*: Option[bool]
    hasClick*, hasChange*, hasSubmit*, hasBack*: bool

  AccessibilityProps* = object
    label*, hint*, value*: Option[string]
    enabled*: Option[bool]

  NormalizedProps* = object
    ## Typed, backend-neutral description of one node. Absent `Option` fields
    ## mean "not specified", which stays distinct from an explicit zero; a
    ## removed property therefore restores the platform default.
    layout*: LayoutProps
    decoration*: DecorationProps
    control*: ControlProps
    accessibility*: AccessibilityProps
    standardUi*: Option[StandardUiProps]

proc styleNumber(key, value: string): float64 =
  try:
    result = parseFloat(value)
  except ValueError:
    fail("invalid style number for " & key & ": " & value)
  if classify(result) in {fcNan, fcInf, fcNegInf} or result < 0 or
      result > MaxStyleNumber:
    fail("style number out of bounds for " & key & ": " & value)
  if key == "opacity" and result > 1:
    fail("opacity must be between 0 and 1: " & value)

proc styleDimension(value: string): Dimension =
  if value == "full":
    return Dimension(kind: dkFill)
  if value == "auto":
    return Dimension(kind: dkAuto)
  try:
    let number = parseFloat(value)
    if classify(number) in {fcNan, fcInf, fcNegInf} or number < 0 or
        number > MaxStyleNumber:
      fail("dimension out of bounds: " & value)
    result = Dimension(kind: dkFixed, value: number)
  except ValueError:
    fail("invalid dimension: " & value)

proc styleColor(value: string): Rgba =
  if value.len notin [4, 7, 9] or value[0] != '#':
    fail("invalid style color: " & value)
  for c in value[1..^1]:
    if c notin HexDigits: fail("invalid style color: " & value)
  proc byteAt(text: string, index: int): uint8 =
    uint8(parseHexInt(text[index..index]))
  case value.len
  of 4:
    result = Rgba(r: byteAt(value, 1) * 17, g: byteAt(value, 2) * 17,
      b: byteAt(value, 3) * 17, a: 255)
  of 7:
    result = Rgba(r: byteAt(value, 1) * 16 + byteAt(value, 2),
      g: byteAt(value, 3) * 16 + byteAt(value, 4),
      b: byteAt(value, 5) * 16 + byteAt(value, 6), a: 255)
  of 9:
    result = Rgba(r: byteAt(value, 1) * 16 + byteAt(value, 2),
      g: byteAt(value, 3) * 16 + byteAt(value, 4),
      b: byteAt(value, 5) * 16 + byteAt(value, 6),
      a: byteAt(value, 7) * 16 + byteAt(value, 8))
  else:
    fail("invalid style color: " & value)

proc styleAlign(value: string): Align =
  case value
  of "start": alignStart
  of "end": alignEnd
  of "center": alignCenter
  of "stretch": alignStretch
  else: fail("invalid alignment: " & value)

proc styleJustify(value: string): Justify =
  case value
  of "start": justifyStart
  of "end": justifyEnd
  of "center": justifyCenter
  of "between": justifyBetween
  of "around": justifyAround
  of "evenly": justifyEvenly
  else: fail("invalid justification: " & value)

proc styleOverflow(value: string): Overflow =
  case value
  of "scroll": overflowScroll
  of "hidden": overflowHidden
  of "visible": overflowVisible
  else: fail("invalid overflow: " & value)

proc styleWeight(value: string): FontWeight =
  case value
  of "normal": weightNormal
  of "medium": weightMedium
  of "semibold": weightSemibold
  of "bold": weightBold
  else: fail("invalid font weight: " & value)

proc styleVariant(value: string): ControlVariant =
  case value
  of "default": variantDefault
  of "primary": variantPrimary
  of "danger": variantDanger
  of "success": variantSuccess
  of "warning": variantWarning
  of "info": variantInfo
  of "outline": variantOutline
  of "ghost": variantGhost
  of "secondary": variantSecondary
  else: fail("invalid control variant: " & value)

proc styleChecked(value: string): bool =
  case value
  of "true": true
  of "false": false
  else: fail("checked must be true or false: " & value)

proc styleProgress(value: string): float64 =
  try:
    result = parseFloat(value)
  except ValueError:
    fail("invalid progress value: " & value)
  if classify(result) in {fcNan, fcInf, fcNegInf} or result < 0 or result > 100:
    fail("progress must be finite and between 0 and 100: " & value)

proc validateStyleSyntax*(styles: Styles) =
  ## Reject unknown style keys and out-of-range values. This is the single
  ## source of truth for the legacy vocabulary; platform bridges reuse it.
  for key, value in styles:
    case key
    of "gap", "padding", "min_width", "min_height", "max_width", "max_height",
       "font_size", "border_width", "radius", "flex_grow", "flex_shrink", "opacity":
      discard styleNumber(key, value)
    of "width", "height":
      discard styleDimension(value)
    of "color", "background", "border_color":
      discard styleColor(value)
    of "align":
      discard styleAlign(value)
    of "justify":
      discard styleJustify(value)
    of "weight":
      discard styleWeight(value)
    of "overflow":
      discard styleOverflow(value)
    else:
      fail("unknown style: " & key)

proc layoutFromStyles(styles: Styles): LayoutProps =
  if "width" in styles: result.width = some(styleDimension(styles["width"]))
  if "height" in styles: result.height = some(styleDimension(styles["height"]))
  if "gap" in styles: result.gap = some(styleNumber("gap", styles["gap"]))
  if "padding" in styles: result.padding = some(styleNumber("padding", styles["padding"]))
  if "flex_grow" in styles:
    result.flexGrow = some(styleNumber("flex_grow", styles["flex_grow"]))
  if "flex_shrink" in styles:
    result.flexShrink = some(styleNumber("flex_shrink", styles["flex_shrink"]))
  if "min_width" in styles:
    result.minWidth = some(styleNumber("min_width", styles["min_width"]))
  if "min_height" in styles:
    result.minHeight = some(styleNumber("min_height", styles["min_height"]))
  if "max_width" in styles:
    result.maxWidth = some(styleNumber("max_width", styles["max_width"]))
  if "max_height" in styles:
    result.maxHeight = some(styleNumber("max_height", styles["max_height"]))
  if "align" in styles: result.align = some(styleAlign(styles["align"]))
  if "justify" in styles: result.justify = some(styleJustify(styles["justify"]))
  if "overflow" in styles: result.overflow = some(styleOverflow(styles["overflow"]))

proc decorationFromStyles(styles: Styles): DecorationProps =
  if "color" in styles: result.color = some(styleColor(styles["color"]))
  if "background" in styles: result.background = some(styleColor(styles["background"]))
  if "border_color" in styles:
    result.borderColor = some(styleColor(styles["border_color"]))
  if "radius" in styles: result.radius = some(styleNumber("radius", styles["radius"]))
  if "border_width" in styles:
    result.borderWidth = some(styleNumber("border_width", styles["border_width"]))
  if "opacity" in styles: result.opacity = some(styleNumber("opacity", styles["opacity"]))
  if "font_size" in styles:
    result.fontSize = some(styleNumber("font_size", styles["font_size"]))
  if "weight" in styles: result.weight = some(styleWeight(styles["weight"]))

proc attributeAllowed(kind: NodeKind, name: string): bool =
  if name in ["ui_role", "ui_variant", "ui_size", "ui_invalid", "ui_loading", "ui_color_mode", "ui_opacity", "ui_angle"]: return true
  case kind
  of NodeKind.button, NodeKind.tag, NodeKind.text, NodeKind.row: name == "variant"
  of NodeKind.column: name in ["variant", "radio_value"]
  of NodeKind.checkbox: name in ["checked", "radio_value"]
  of NodeKind.toggle: name == "checked"
  of NodeKind.progress: name == "value"
  of NodeKind.input: name in ["input_reset_token", "variant", "multiline"]
  else: false

proc parseResetToken(value: string): uint64 =
  ## Reset tokens are unsigned decimal integers in 0..high(uint64). The raw
  ## attribute grammar is checked digit by digit: `parseBiggestUInt` alone
  ## would also accept `+1`, `1_0` or `1_`, which are not valid decimal text.
  ## They are deliberately not parsed through the float style path either.
  if value.len == 0: fail("invalid input reset token: " & value)
  for c in value:
    if c notin {'0'..'9'}: fail("invalid input reset token: " & value)
  try:
    result = uint64(parseBiggestUInt(value))
  except ValueError:
    fail("invalid input reset token: " & value)

proc controlFrom(node: Node): ControlProps =
  for name, value in node.attributes:
    if not attributeAllowed(node.kind, name):
      fail("attribute " & name & " does not apply to " & node.kind.kindName)
  result.hasClick = node.handler(click) != nil
  result.hasChange = node.handler(change) != nil
  result.hasSubmit = node.handler(submit) != nil
  result.hasBack = node.handler(back) != nil
  case node.kind
  of NodeKind.button:
    result.label = some(node.text)
    result.enabled = some(not node.disabled)
    if "variant" in node.attributes:
      result.variant = some(styleVariant(node.attributes["variant"]))
  of NodeKind.tag:
    result.label = some(node.text)
    if "variant" in node.attributes:
      result.variant = some(styleVariant(node.attributes["variant"]))
  of NodeKind.text, NodeKind.column, NodeKind.row:
    if "variant" in node.attributes:
      result.variant = some(styleVariant(node.attributes["variant"]))
    if "radio_value" in node.attributes:
      result.radioValue = some(node.attributes["radio_value"])
  of NodeKind.input:
    result.value = some(node.text)
    if "multiline" in node.attributes:
      result.multiline = some(styleChecked(node.attributes["multiline"]))
    if "variant" in node.attributes:
      result.variant = some(styleVariant(node.attributes["variant"]))
    if node.placeholder.len > 0: result.placeholder = some(node.placeholder)
    result.enabled = some(not node.disabled)
    if "input_reset_token" in node.attributes:
      result.resetToken = some(parseResetToken(node.attributes["input_reset_token"]))
  of NodeKind.checkbox, NodeKind.toggle:
    result.label = some(node.text)
    result.enabled = some(not node.disabled)
    if "checked" in node.attributes:
      result.checked = some(styleChecked(node.attributes["checked"]))
    if "radio_value" in node.attributes:
      result.radioValue = some(node.attributes["radio_value"])
  of NodeKind.progress:
    if "value" in node.attributes:
      result.progress = some(styleProgress(node.attributes["value"]))
  else:
    discard

proc accessibilityFrom(node: Node, control: ControlProps): AccessibilityProps =
  result.label = control.label
  result.hint = control.placeholder
  result.enabled = control.enabled
  case node.kind
  of NodeKind.input:
    result.value = control.value
  of NodeKind.checkbox, NodeKind.toggle:
    if control.checked.isSome:
      result.value = some(if control.checked.get: "true" else: "false")
  of NodeKind.progress:
    if control.progress.isSome:
      result.value = some($control.progress.get)
  of NodeKind.text, NodeKind.canvasHost:
    result.label = some(node.text)
  else:
    discard

proc standardUiFrom(node: Node): Option[StandardUiProps] =
  var present = false
  for key in node.attributes.keys:
    if key.startsWith("ui_"): present = true
  if not present: return
  if "ui_role" notin node.attributes: fail("standard UI metadata requires ui_role")
  if "variant" in node.attributes: fail("standard UI cannot mix legacy variant metadata")
  var props: StandardUiProps
  try:
    props.role = parseEnum[UiRole](node.attributes["ui_role"])
    props.variant = parseEnum[UiVariant](node.attributes.getOrDefault("ui_variant", "default"))
    props.size = parseEnum[UiSize](node.attributes.getOrDefault("ui_size", "normal"))
  except ValueError: fail("invalid standard UI role, variant or size")
  props.invalid = styleChecked(node.attributes.getOrDefault("ui_invalid", "false"))
  props.loading = styleChecked(node.attributes.getOrDefault("ui_loading", "false"))
  if props.role == UiRole.theme:
    if "ui_color_mode" notin node.attributes: fail("standard theme requires ui_color_mode")
    try: props.colorMode = some(parseEnum[UiColorMode](node.attributes["ui_color_mode"]))
    except ValueError: fail("invalid standard color mode")
  elif "ui_color_mode" in node.attributes:
    fail("color mode only applies to a window-root theme")
  if props.role==UiRole.skeleton:
    if "ui_opacity" notin node.attributes:fail("skeleton requires pulse opacity")
    let raw=node.attributes["ui_opacity"]
    var value:int
    try:value=parseInt(raw)
    except ValueError:fail("invalid skeleton opacity")
    if value<500 or value>1000:fail("skeleton opacity must be 500..1000 permille")
    props.opacityPermille=some(value)
    if node.text.len!=0 or node.children.len!=0:fail("skeleton cannot contain text or children")
  elif "ui_opacity" in node.attributes:fail("opacity only applies to skeleton")
  if props.role==UiRole.spinner:
    if "ui_angle" notin node.attributes:fail("spinner requires rotation angle")
    let raw=node.attributes["ui_angle"]
    var value:int
    try:value=parseInt(raw)
    except ValueError:fail("invalid spinner angle")
    if value<0 or value>360:fail("spinner angle must be 0..360 degrees")
    props.angleDegrees=some(value)
    if node.text.len==0:fail("spinner requires non-empty label")
    if node.children.len!=0:fail("spinner cannot contain children")
  elif "ui_angle" in node.attributes:fail("angle only applies to spinner")
  let expected = case props.role
    of UiRole.button: NodeKind.button
    of UiRole.badge,UiRole.kbd,UiRole.skeleton,UiRole.spinner: NodeKind.tag
    of UiRole.progress: NodeKind.progress
    of UiRole.separator: NodeKind.separator
    of UiRole.checkbox: NodeKind.checkbox
    of UiRole.switch: NodeKind.toggle
    of UiRole.input, UiRole.textarea: NodeKind.input
    of UiRole.alertTitle, UiRole.alertDescription, UiRole.cardTitle, UiRole.cardDescription, UiRole.label,
        UiRole.fieldDescription, UiRole.fieldError,
        UiRole.dialogTitle, UiRole.dialogDescription,
        UiRole.emptyTitle, UiRole.emptyDescription, UiRole.inputGroupText: NodeKind.text
    of UiRole.cardFooter,UiRole.kbdGroup,UiRole.buttonGroup,UiRole.inputGroup,UiRole.inputGroupAddon,
        UiRole.dialogFooter, UiRole.dialogHeader: NodeKind.row
    of UiRole.dialogClose, UiRole.alertDialogCancel, UiRole.alertDialogAction,
        UiRole.selectTrigger: NodeKind.button
    of UiRole.select, UiRole.selectContent: NodeKind.column
    of UiRole.selectItem: NodeKind.row
    of UiRole.radioGroup: NodeKind.column
    of UiRole.radioGroupItem: NodeKind.checkbox
    of UiRole.popover, UiRole.popoverContent: NodeKind.column
    of UiRole.popoverTrigger, UiRole.popoverClose: NodeKind.button
    else: NodeKind.column
  if node.kind != expected: fail("standard UI role does not match native kind")
  if props.role == UiRole.switch and
      (props.variant != UiVariant.default or props.size notin {UiSize.normal,UiSize.sm} or props.loading):
    fail("unsupported standard switch variant, size or loading")
  if props.role == UiRole.alert:
    if node.text.len == 0: fail("alert requires non-empty accessible text")
    if props.variant notin {UiVariant.default,UiVariant.destructive} or
        props.size != UiSize.normal or props.loading:
      fail("unsupported alert variant, size or loading")
  if props.role notin {UiRole.button,UiRole.switch,UiRole.badge,UiRole.alert,
      UiRole.alertDialogCancel,UiRole.alertDialogAction,
      UiRole.popoverTrigger,UiRole.popoverClose} and
      (props.variant != UiVariant.default or props.size != UiSize.normal or props.loading):
    fail("standard UI variant, size or loading does not apply to this role")
  if props.role==UiRole.progress:
    if "value" notin node.attributes:fail("standard progress requires a determinate value")
    let value=styleProgress(node.attributes["value"])
    if value!=floor(value):fail("standard progress requires integer percent")
  if props.role == UiRole.badge and (props.size != UiSize.normal or props.loading):
    fail("unsupported badge size or loading")
  if props.role in {UiRole.alert,UiRole.alertTitle,UiRole.alertDescription,UiRole.inputGroup,UiRole.inputGroupAddon,UiRole.inputGroupText,UiRole.buttonGroup,UiRole.skeleton,UiRole.spinner,UiRole.badge,UiRole.separator,UiRole.progress,UiRole.kbd,UiRole.kbdGroup,UiRole.empty,UiRole.emptyHeader,
      UiRole.emptyTitle,UiRole.emptyDescription,UiRole.emptyContent,UiRole.dialogHeader,UiRole.dialogContent,
      UiRole.dialogFooter,UiRole.dialogTitle,UiRole.dialogDescription,UiRole.selectContent,
      UiRole.popoverContent} and
      (node.disabled or node.handler(click) != nil or node.handler(change) != nil or
       node.handler(submit) != nil or node.handler(back) != nil):
    fail("standard display components are noninteractive")
  if props.invalid and props.role notin {UiRole.input, UiRole.textarea, UiRole.checkbox}:
    fail("invalid state does not apply to this standard UI role")
  if props.role in {UiRole.input, UiRole.textarea} and
      (node.attributes.getOrDefault("multiline", "false") == "true") !=
        (props.role == UiRole.textarea):
    fail("standard input/textarea multiline mode does not match its role")
  if props.loading and (not node.disabled or node.handler(click) != nil):
    fail("loading standard button must disable activation")
  if props.role in {UiRole.selectTrigger, UiRole.selectContent, UiRole.selectItem} and
      (node.handler(click) != nil or node.handler(change) != nil or
       node.handler(submit) != nil or node.handler(back) != nil or
       node.handler(openChange) != nil):
    fail("select parts carry no business handler; requests belong to the select root")
  if props.role == UiRole.selectContent and node.disabled:
    fail("select content cannot be disabled; disable the select or one item")
  if props.role == UiRole.selectItem and node.children.len != 0:
    fail("select item cannot contain children")
  if props.role == UiRole.radioGroup:
    # The accepted value is explicit; "" is the real "nothing selected" state
    # and is never replaced by the first option.
    if "radio_value" notin node.attributes:
      fail("radio group requires its accepted value")
  elif props.role == UiRole.radioGroupItem:
    if "radio_value" notin node.attributes:
      fail("radio option requires its value")
    if node.attributes["radio_value"].len == 0:
      fail("radio option value cannot be empty")
    if node.children.len != 0: fail("radio option cannot contain children")
  elif "radio_value" in node.attributes:
    fail("radio option value requires a radio role")
  if props.role in {UiRole.popoverTrigger, UiRole.popoverContent, UiRole.popoverClose} and
      (node.handler(click) != nil or node.handler(change) != nil or
       node.handler(submit) != nil or node.handler(back) != nil or
       node.handler(openChange) != nil):
    fail("popover parts carry no business handler; requests belong to the popover root")
  if props.role == UiRole.popoverContent and node.disabled:
    fail("popover content cannot be disabled; disable the trigger or one control")
  let overlay = node.overlayProps
  let select = node.selectProps
  let popover = node.popoverProps
  case props.role
  of UiRole.dialog:
    if overlay.isNone or overlay.get.kind != overlayDialog:
      fail("dialog role requires a dialog overlay description")
    if node.text.len == 0: fail("dialog requires an accessible title")
  of UiRole.alertDialog:
    if overlay.isNone or overlay.get.kind != overlayAlertDialog:
      fail("alert dialog role requires an alert dialog overlay description")
    if node.text.len == 0: fail("alert dialog requires an accessible title")
  of UiRole.select:
    if select.isNone: fail("select role requires a typed select description")
    if overlay.isSome: fail("select cannot also be a modal overlay")
    if node.text.len == 0: fail("select requires an accessible name")
  of UiRole.selectTrigger:
    if select.isSome: fail("select description belongs to the select root")
    if overlay.isSome: fail("select trigger cannot be a modal overlay")
  of UiRole.selectContent, UiRole.selectItem:
    if select.isSome: fail("select description belongs to the select root")
    if overlay.isSome: fail("select content cannot be a modal overlay")
  of UiRole.popover:
    if popover.isNone: fail("popover role requires a typed popover description")
    if overlay.isSome: fail("popover cannot also be a modal overlay")
    if node.text.len == 0: fail("popover requires an accessible name")
  of UiRole.popoverTrigger, UiRole.popoverContent, UiRole.popoverClose:
    if popover.isSome: fail("popover description belongs to the popover root")
    if overlay.isSome: fail("popover parts cannot be a modal overlay")
  else:
    if overlay.isSome: fail("overlay description requires a dialog or alert dialog role")
    if select.isSome: fail("select description requires the select role")
    if popover.isSome: fail("popover description requires the popover role")
  some(props)

proc normalizeProps*(node: Node): NormalizedProps =
  ## Validate and convert one description. Unknown styles/attributes and
  ## illegal values always raise `UiError`; no raw string survives into the
  ## returned properties.
  validateStyleSyntax(node.styles)
  result.layout = layoutFromStyles(node.styles)
  result.decoration = decorationFromStyles(node.styles)
  result.control = controlFrom(node)
  result.accessibility = accessibilityFrom(node, result.control)
  result.standardUi = standardUiFrom(node)
  if result.standardUi.isSome and (result.standardUi.get.role in UiGroupRoles or
      result.standardUi.get.role in {UiRole.spinner, UiRole.dialog, UiRole.alertDialog,
        UiRole.select, UiRole.selectTrigger, UiRole.popover, UiRole.radioGroup}):
    result.control.label = some(node.text)
    result.accessibility.label = some(node.text)

proc validateProps*(root: MountedNode) =
  ## Validate a mounted tree with the same rules, including control-attribute
  ## ownership by node kind.
  discard normalizeProps(root.node)
  for child in root.children:
    validateProps(child)
