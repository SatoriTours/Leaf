## Pure semantic paint resolution; native painters never choose their own colors.
import ../ui_contract
import ./tokens

type UiPaintColors* = object
  fill*, border*, text*, ring*: uint32

proc withAlpha(color: SrgbColor, alpha: float64): SrgbColor =
  srgb(color.r, color.g, color.b, color.a * alpha)

proc buttonAppearance*(mode: UiColorMode, variant: UiVariant,
    surface: SrgbColor, hot = false, disabled = false): UiPaintColors =
  let p = neutralPalette(mode)
  var fill = p[UiColorToken.primary]
  var text = p[UiColorToken.primaryForeground]
  var border: SrgbColor
  case variant
  of UiVariant.default:
    if hot: fill = composite(withAlpha(fill, 0.9), surface)
    border = fill
  of UiVariant.destructive:
    fill = p[UiColorToken.destructive]
    text = srgb(1, 1, 1)
    if mode == UiColorMode.dark: fill = composite(withAlpha(fill, 0.6), surface)
    elif hot: fill = composite(withAlpha(fill, 0.9), surface)
    border = fill
  of UiVariant.outline:
    fill = if hot: p[UiColorToken.accent] else: surface
    if mode == UiColorMode.dark and not hot:
      fill = composite(withAlpha(p[UiColorToken.input], 0.3), surface)
    border = composite(p[if mode == UiColorMode.dark: UiColorToken.input else: UiColorToken.border], fill)
    text = p[UiColorToken.foreground]
  of UiVariant.secondary:
    fill = p[UiColorToken.secondary]
    if hot: fill = composite(withAlpha(fill, 0.8), surface)
    border = fill
    text = p[UiColorToken.secondaryForeground]
  of UiVariant.ghost, UiVariant.link:
    fill = if hot and variant == UiVariant.ghost:
        composite(withAlpha(p[UiColorToken.accent], if mode == UiColorMode.dark: 0.5 else: 1.0), surface)
      else: surface
    border = fill
    text = p[if variant == UiVariant.link: UiColorToken.primary else: UiColorToken.foreground]
  if disabled:
    fill = composite(withAlpha(fill, 0.5), surface)
    border = composite(withAlpha(border, 0.5), surface)
    text = composite(withAlpha(text, 0.5), surface)
  UiPaintColors(fill:rgb24(fill), border:rgb24(border), text:rgb24(text),
    ring:rgb24(composite(withAlpha(p[UiColorToken.ring],0.5),surface)))

type UiCheckColors* = object
  fill*, border*, mark*, text*, ring*: uint32

proc checkAppearance*(mode: UiColorMode, role: UiRole, surface: SrgbColor,
    checked = false, disabled = false, invalid = false): UiCheckColors =
  if role notin {UiRole.checkbox,UiRole.switch,UiRole.radioGroupItem} or
      (invalid and role!=UiRole.checkbox):
    raise newException(ValueError,"unsupported check appearance")
  let p=neutralPalette(mode)
  var fill=surface
  var border,mark: SrgbColor
  if role==UiRole.radioGroupItem:
    # Neutral radio: the ring carries the state, the inner dot is the mark.
    # An unchecked radio keeps the input border, a checked one turns primary.
    if mode==UiColorMode.dark: fill=composite(withAlpha(p[UiColorToken.input],0.3),surface)
    border=if checked:p[UiColorToken.primary] else:composite(p[UiColorToken.input],fill)
    mark=p[UiColorToken.primary]
  elif role==UiRole.checkbox:
    if mode==UiColorMode.dark: fill=composite(withAlpha(p[UiColorToken.input],0.3),surface)
    if checked: fill=p[UiColorToken.primary]
    border=if checked:p[UiColorToken.primary] else:composite(p[UiColorToken.input],fill)
    mark=p[UiColorToken.primaryForeground]
    if invalid: border=p[UiColorToken.destructive]
  else:
    fill=if checked:p[UiColorToken.primary]
      else:composite(withAlpha(p[UiColorToken.input],if mode==UiColorMode.dark:0.8 else:1.0),surface)
    border=fill # upstream transparent border, same track face
    mark=if mode==UiColorMode.dark:
        p[if checked:UiColorToken.primaryForeground else:UiColorToken.foreground]
      else:p[UiColorToken.background]
  var text=p[UiColorToken.foreground]
  if disabled:
    fill=composite(withAlpha(fill,0.5),surface)
    border=composite(withAlpha(border,0.5),surface)
    mark=composite(withAlpha(mark,0.5),surface)
    text=composite(withAlpha(text,0.5),surface)
  let ring=p[if invalid:UiColorToken.destructive else:UiColorToken.ring]
  UiCheckColors(fill:rgb24(fill),border:rgb24(border),mark:rgb24(mark),text:rgb24(text),
    ring:rgb24(composite(withAlpha(ring,if invalid:(if mode==UiColorMode.dark:0.4 else:0.2) else:0.5),surface)))

proc badgeAppearance*(mode: UiColorMode, variant: UiVariant,
    surface: SrgbColor): UiPaintColors =
  ## Span badge has neither hover nor button-specific dark outline input fill.
  let p=neutralPalette(mode)
  var fill=surface
  var ink=p[UiColorToken.foreground]
  case variant
  of UiVariant.default:
    fill=p[UiColorToken.primary];ink=p[UiColorToken.primaryForeground]
  of UiVariant.secondary:
    fill=p[UiColorToken.secondary];ink=p[UiColorToken.secondaryForeground]
  of UiVariant.destructive:
    fill=p[UiColorToken.destructive];ink=srgb(1,1,1)
    if mode==UiColorMode.dark:fill=composite(withAlpha(fill,0.6),surface)
  of UiVariant.link:ink=p[UiColorToken.primary]
  else:discard
  let border=if variant==UiVariant.outline:composite(p[UiColorToken.border],surface) else:fill
  UiPaintColors(fill:rgb24(fill),border:rgb24(border),text:rgb24(ink))
