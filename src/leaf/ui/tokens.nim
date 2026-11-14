## Platform-independent shadcn Neutral tokens.
## Derived from shadcn-ui/ui@42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9.
## Copyright (c) 2023 shadcn, MIT; see vendor/shadcn-ui/LICENSE.txt.
import std/math

type
  UiColorMode* {.pure.} = enum light, dark
  OklchColor* = object
    l*, c*, h*, a*: float64
  SrgbColor* = object
    r*, g*, b*, a*: float64
  UiColorToken* {.pure.} = enum
    background, foreground, card, cardForeground, popover, popoverForeground,
    primary, primaryForeground, secondary, secondaryForeground,
    muted, mutedForeground, accent, accentForeground, destructive,
    border, input, ring, chart1, chart2, chart3, chart4, chart5,
    sidebar, sidebarForeground, sidebarPrimary, sidebarPrimaryForeground,
    sidebarAccent, sidebarAccentForeground, sidebarBorder, sidebarRing
  UiPalette* = array[UiColorToken, SrgbColor]

const
  ShadcnReferenceCommit* = "42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9"
  UiBaseRadius* = 10.0
  UiControlRadius* = 6.0 # rounded-md = radius - 4px
  UiBodyFontSize* = 14.0
  UiControlHeight* = 36.0
  UiSpacingUnit* = 4.0

proc finite(value: float64): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

proc unit(value: float64) =
  if not finite(value) or value < 0 or value > 1:
    raise newException(ValueError, "color channel/alpha must be finite and in 0..1")

proc srgb*(r, g, b: float64, a = 1.0): SrgbColor =
  for value in [r, g, b, a]: unit(value)
  SrgbColor(r: r, g: g, b: b, a: a)

proc oklch*(l, c, h: float64, a = 1.0): OklchColor =
  unit(l); unit(a)
  if not finite(c) or c < 0 or not finite(h):
    raise newException(ValueError, "OKLCH chroma/hue must be finite; chroma must be nonnegative")
  OklchColor(l: l, c: c, h: h, a: a)

proc encoded(linear: float64): float64 =
  # Explicit per-channel clipping in linear sRGB, then IEC 61966-2-1 transfer.
  let v = clamp(linear, 0.0, 1.0)
  if v <= 0.0031308: 12.92 * v
  else: 1.055 * pow(v, 1.0/2.4) - 0.055

proc oklchToSrgb*(color: OklchColor): SrgbColor =
  discard oklch(color.l, color.c, color.h, color.a) # validate public object input too
  # Limit chroma before cubic intermediates overflow, not after producing NaN.
  if color.c > 100:
    raise newException(ValueError, "OKLCH chroma exceeds conversion budget")
  let angle = floorMod(color.h, 360.0) * PI / 180.0
  let aa = color.c * cos(angle)
  let bb = color.c * sin(angle)
  let ll = color.l + 0.3963377774*aa + 0.2158037573*bb
  let mm = color.l - 0.1055613458*aa - 0.0638541728*bb
  let ss = color.l - 0.0894841775*aa - 1.2914855480*bb
  let l = ll*ll*ll
  let m = mm*mm*mm
  let s = ss*ss*ss
  srgb(encoded(4.0767416621*l - 3.3077115913*m + 0.2309699292*s),
    encoded(-1.2684380046*l + 2.6097574011*m - 0.3413193965*s),
    encoded(-0.0041960863*l - 0.7034186147*m + 1.7076147010*s), color.a)

proc composite*(foreground, background: SrgbColor): SrgbColor =
  discard srgb(foreground.r, foreground.g, foreground.b, foreground.a)
  discard srgb(background.r, background.g, background.b, background.a)
  let alpha = foreground.a + background.a*(1-foreground.a)
  if alpha == 0: return srgb(0, 0, 0, 0)
  srgb((foreground.r*foreground.a + background.r*background.a*(1-foreground.a))/alpha,
    (foreground.g*foreground.a + background.g*background.a*(1-foreground.a))/alpha,
    (foreground.b*foreground.a + background.b*background.a*(1-foreground.a))/alpha, alpha)

proc rgb24*(color: SrgbColor): uint32 =
  ## RGB packing only. Call composite first if alpha must be resolved.
  discard srgb(color.r, color.g, color.b, color.a)
  (uint32(round(color.r*255)) shl 16) or
    (uint32(round(color.g*255)) shl 8) or uint32(round(color.b*255))

proc neutralPalette*(mode: UiColorMode): UiPalette =
  template gray(token: UiColorToken, l: float64) =
    result[token] = oklchToSrgb(oklch(l, 0, 0))
  gray(UiColorToken.background, 1)
  gray(UiColorToken.foreground, 0.145)
  gray(UiColorToken.card, 1)
  gray(UiColorToken.cardForeground, 0.145)
  gray(UiColorToken.popover, 1)
  gray(UiColorToken.popoverForeground, 0.145)
  gray(UiColorToken.primary, 0.205)
  gray(UiColorToken.primaryForeground, 0.985)
  gray(UiColorToken.secondary, 0.97)
  gray(UiColorToken.secondaryForeground, 0.205)
  gray(UiColorToken.muted, 0.97)
  gray(UiColorToken.mutedForeground, 0.556)
  gray(UiColorToken.accent, 0.97)
  gray(UiColorToken.accentForeground, 0.205)
  result[UiColorToken.destructive] = oklchToSrgb(oklch(0.577, 0.245, 27.325))
  gray(UiColorToken.border, 0.922)
  gray(UiColorToken.input, 0.922)
  gray(UiColorToken.ring, 0.708)
  gray(UiColorToken.chart1, 0.87)
  gray(UiColorToken.chart2, 0.556)
  gray(UiColorToken.chart3, 0.439)
  gray(UiColorToken.chart4, 0.371)
  gray(UiColorToken.chart5, 0.269)
  gray(UiColorToken.sidebar, 0.985)
  gray(UiColorToken.sidebarForeground, 0.145)
  gray(UiColorToken.sidebarPrimary, 0.205)
  gray(UiColorToken.sidebarPrimaryForeground, 0.985)
  gray(UiColorToken.sidebarAccent, 0.97)
  gray(UiColorToken.sidebarAccentForeground, 0.205)
  gray(UiColorToken.sidebarBorder, 0.922)
  gray(UiColorToken.sidebarRing, 0.708)
  if mode == UiColorMode.dark:
    gray(UiColorToken.background, 0.145)
    gray(UiColorToken.foreground, 0.985)
    gray(UiColorToken.card, 0.205)
    gray(UiColorToken.cardForeground, 0.985)
    gray(UiColorToken.popover, 0.205)
    gray(UiColorToken.popoverForeground, 0.985)
    gray(UiColorToken.primary, 0.922)
    gray(UiColorToken.primaryForeground, 0.205)
    gray(UiColorToken.secondary, 0.269)
    gray(UiColorToken.secondaryForeground, 0.985)
    gray(UiColorToken.muted, 0.269)
    gray(UiColorToken.mutedForeground, 0.708)
    gray(UiColorToken.accent, 0.269)
    gray(UiColorToken.accentForeground, 0.985)
    result[UiColorToken.destructive] = oklchToSrgb(oklch(0.704, 0.191, 22.216))
    result[UiColorToken.border] = srgb(1, 1, 1, 0.1)
    result[UiColorToken.input] = srgb(1, 1, 1, 0.15)
    gray(UiColorToken.ring, 0.556)
    gray(UiColorToken.sidebar, 0.205)
    gray(UiColorToken.sidebarForeground, 0.985)
    result[UiColorToken.sidebarPrimary] = oklchToSrgb(oklch(0.488, 0.243, 264.376))
    gray(UiColorToken.sidebarPrimaryForeground, 0.985)
    gray(UiColorToken.sidebarAccent, 0.269)
    gray(UiColorToken.sidebarAccentForeground, 0.985)
    result[UiColorToken.sidebarBorder] = result[UiColorToken.border]
    gray(UiColorToken.sidebarRing, 0.556)
