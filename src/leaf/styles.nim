## Backend-neutral style syntax validation and typed property conversion.
##
## This module owns the public style vocabulary that used to live in the GPUI
## bridge. It parses the legacy string `Styles` tables once, into typed values
## that every backend can consume without re-parsing arbitrary strings. It
## contains no platform capability decisions: whether a given decoration can be
## honoured is declared separately by each backend.
import std/[tables, strutils, math, options]
import ./core

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
    variant*: Option[ControlVariant]
    hasClick*, hasChange*, hasSubmit*: bool

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
  case kind
  of NodeKind.button, NodeKind.tag: name == "variant"
  of NodeKind.checkbox, NodeKind.toggle: name == "checked"
  of NodeKind.progress: name == "value"
  else: false

proc controlFrom(node: Node): ControlProps =
  for name, value in node.attributes:
    if not attributeAllowed(node.kind, name):
      fail("attribute " & name & " does not apply to " & node.kind.kindName)
  result.hasClick = node.handler(click) != nil
  result.hasChange = node.handler(change) != nil
  result.hasSubmit = node.handler(submit) != nil
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
  of NodeKind.input:
    result.value = some(node.text)
    if node.placeholder.len > 0: result.placeholder = some(node.placeholder)
    result.enabled = some(not node.disabled)
  of NodeKind.checkbox, NodeKind.toggle:
    result.label = some(node.text)
    result.enabled = some(not node.disabled)
    if "checked" in node.attributes:
      result.checked = some(styleChecked(node.attributes["checked"]))
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
  of NodeKind.text:
    result.label = some(node.text)
  else:
    discard

proc normalizeProps*(node: Node): NormalizedProps =
  ## Validate and convert one description. Unknown styles/attributes and
  ## illegal values always raise `UiError`; no raw string survives into the
  ## returned properties.
  validateStyleSyntax(node.styles)
  result.layout = layoutFromStyles(node.styles)
  result.decoration = decorationFromStyles(node.styles)
  result.control = controlFrom(node)
  result.accessibility = accessibilityFrom(node, result.control)

proc validateProps*(root: MountedNode) =
  ## Validate a mounted tree with the same rules, including control-attribute
  ## ownership by node kind.
  discard normalizeProps(root.node)
  for child in root.children:
    validateProps(child)
