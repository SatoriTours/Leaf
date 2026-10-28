## Pure Win32 capability table. No Win32 API import: this module compiles and
## is validated on Linux, and only declares what the native backend can honour.
##
## Deliberately unsupported (required values are rejected, never approximated):
## min/max, flex_shrink, justify around/evenly, scroll/visible overflow. A
## virtual list is a real scrollable viewport child window (T2), so it is
## declared as a supported kind. No arbitrary colour/font decoration is claimed: the first batch
## only uses the native system font. With an opt-in skin, push buttons support
## primary/secondary; other non-default variants still degrade or reject.
import ../../[core, styles, backend, native_theme]

proc win32Capabilities*(theme = systemTheme): BackendCapabilities =
  result = BackendCapabilities(
    kinds: {column, row, text, button, input, checkbox, toggle, progress, tag,
      separator, spinner, virtualList, navigation, canvasHost},
    layouts: {lfGap, lfPadding, lfWidth, lfHeight, lfFlexGrow, lfAlign,
      lfJustify, lfOverflow},
    alignments: {alignStart, alignEnd, alignCenter, alignStretch},
    justifications: {justifyStart, justifyEnd, justifyCenter, justifyBetween},
    overflows: {overflowHidden},
    decorations: {},
    variants: {variantDefault},
    controls: {cfInputReset})
  if theme != systemTheme:
    result.kindVariants[NodeKind.button] = {variantPrimary, variantSecondary}
    result.kindVariants[NodeKind.text] = {variantPrimary, variantSecondary, variantDanger}
    result.kindVariants[NodeKind.input] = {variantDanger}
