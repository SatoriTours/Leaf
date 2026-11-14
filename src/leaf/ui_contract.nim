## Required, platform-neutral standard-component semantics. No Node or OS state.
import std/options
from ./ui/tokens import UiColorMode
export UiColorMode

type
  UiRole* {.pure.} = enum
    button, input, card, cardHeader, cardTitle, cardDescription, cardContent, cardFooter,
    textarea, label, field, fieldDescription, fieldError, checkbox, switch, theme, badge, separator,
    empty, emptyHeader, emptyTitle, emptyDescription, emptyContent, progress, kbd, kbdGroup, skeleton, buttonGroup, inputGroup, inputGroupAddon, inputGroupText,
    spinner, alert, alertTitle, alertDescription,
    dialog, dialogHeader, dialogTitle, dialogDescription, dialogContent, dialogFooter, dialogClose,
    alertDialog, alertDialogCancel, alertDialogAction,
    select, selectTrigger, selectContent, selectItem,
    popover, popoverTrigger, popoverContent, popoverClose
  UiVariant* {.pure.} = enum default, destructive, outline, secondary, ghost, link
  UiSize* {.pure.} = enum normal, xs, sm, lg, icon, iconXs, iconSm, iconLg
  StandardUiProps* = object
    role*: UiRole
    variant*: UiVariant
    size*: UiSize
    invalid*, loading*: bool
    colorMode*: Option[UiColorMode]
    opacityPermille*: Option[int]
    angleDegrees*: Option[int]

const UiGroupRoles* = {UiRole.buttonGroup, UiRole.inputGroup, UiRole.inputGroupAddon, UiRole.alert}

proc controlHeight*(size: UiSize): float64 =
  case size
  of UiSize.xs, UiSize.iconXs: 24
  of UiSize.sm, UiSize.iconSm: 32
  of UiSize.lg, UiSize.iconLg: 40
  else: 36

proc horizontalInset*(size: UiSize): float64 =
  case size
  of UiSize.xs: 8
  of UiSize.sm: 12
  of UiSize.lg: 24
  of UiSize.icon, UiSize.iconXs, UiSize.iconSm, UiSize.iconLg: 0
  else: 16

proc iconOnly*(size: UiSize): bool =
  size in {UiSize.icon, UiSize.iconXs, UiSize.iconSm, UiSize.iconLg}

type UiCheckMetrics* = object
  width*, height*, thumb*, radius*: float64

proc checkMetrics*(role: UiRole, size = UiSize.normal): UiCheckMetrics =
  ## Glyph dimensions, not the caption-inclusive native hit target.
  case role
  of UiRole.checkbox:
    if size != UiSize.normal: raise newException(ValueError,"unsupported checkbox size")
    UiCheckMetrics(width:16,height:16,radius:4)
  of UiRole.switch:
    case size
    of UiSize.normal: UiCheckMetrics(width:32,height:18.4,thumb:16,radius:9.2)
    of UiSize.sm: UiCheckMetrics(width:24,height:14,thumb:12,radius:7)
    else: raise newException(ValueError,"unsupported switch size")
  else: raise newException(ValueError,"not a check role")
