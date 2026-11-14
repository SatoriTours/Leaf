## Pure Win32 capability table. No Win32 API import: this module compiles and
## is validated on Linux, and only declares what the native backend can honour.
##
## Deliberately unsupported (required values are rejected, never approximated):
## min/max, flex_shrink, justify around/evenly, scroll/visible overflow. A
## virtual list is a real scrollable viewport child window (T2), so it is
## declared as a supported kind. No arbitrary colour/font decoration is claimed: the first batch
## uses backend-selected native fonts (shadcn opts into a CJK-capable sans serif).
## With an opt-in skin, push buttons support
## primary/secondary; other non-default variants still degrade or reject.
import ../../[core, styles, backend, native_theme, overlay_protocol]

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
    controls: {cfInputReset, cfInputMultiline})
  if theme.isShadcn:
    result.standardUi = {low(UiRole)..high(UiRole)}
    # A real owned modal window with the in-application scrim is only available
    # with the shadcn surface; the system theme rejects it instead of drawing a
    # plain container in the page flow.
    result.overlays = {overlayDialog, overlayAlertDialog}
    # The anchored non-modal popup is a real owned window of the trigger owner;
    # the system theme keeps refusing it instead of drawing an inline list.
    result.selects = {sfSingle}
    # The anchored non-modal panel is a real owned popup window; the system
    # theme keeps rejecting it instead of drawing an inline panel.
    result.popovers = {pfNonModal}
  if theme != systemTheme:
    result.kindVariants[NodeKind.button] = {variantPrimary, variantSecondary, variantGhost}
    result.kindVariants[NodeKind.column] = {variantPrimary, variantSecondary}
    result.kindVariants[NodeKind.row] = {variantPrimary, variantSecondary}
    result.kindVariants[NodeKind.text] = {variantPrimary, variantSecondary, variantDanger}
    result.kindVariants[NodeKind.input] = {variantDanger, variantPrimary, variantGhost}
