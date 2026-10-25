## Opt-in native appearance. Tokens are logical RGB/DIP, never OS resources.
## The default deliberately remains the platform's system controls.
type
  NativeTheme* = enum systemTheme, matsuLight, matsuDark
  NativePalette* = object
    canvas*, surface*, panel*, ink*, muted*, line*, controlLine*: uint32
    accent*, accentHover*, accentSoft*, onAccent*, danger*: uint32
  NativeButtonColors* = object
    fill*, border*, text*: uint32

const
  NativeButtonWidth* = 96.0
  NativeButtonHeight* = 32.0
  NativeButtonRadius* = 5.0
  NativeButtonInset* = 8.0
  NativeInputHeight* = 40.0
  NativeActionGap* = 8.0

proc themeEnabled*(theme: NativeTheme, highContrast: bool): bool =
  theme != systemTheme and not highContrast

proc palette*(theme: NativeTheme): NativePalette =
  case theme
  of systemTheme:
    raise newException(ValueError, "system theme has no fixed brand palette")
  of matsuLight:
    NativePalette(canvas: 0xeef1ef, surface: 0xffffff, panel: 0xf7f9f7,
      ink: 0x202923, muted: 0x647168, line: 0xdfe6e0, controlLine: 0x89978d,
      accent: 0x23634d, accentHover: 0x194e3b, accentSoft: 0xe8f0ea,
      onAccent: 0xffffff, danger: 0xad3939)
  of matsuDark:
    NativePalette(canvas: 0x121614, surface: 0x1c211e, panel: 0x222925,
      ink: 0xedf2ee, muted: 0xacb8af, line: 0x37433b, controlLine: 0x74867a,
      accent: 0x9dd5b5, accentHover: 0xb8e5ca, accentSoft: 0x283e30,
      onAccent: 0x142b1e, danger: 0xffaaa4)

proc buttonColors*(theme: NativeTheme, primary=false, hot=false,
                   pressed=false, disabled=false): NativeButtonColors =
  let p = palette(theme)
  if disabled:
    return NativeButtonColors(fill: p.panel, border: p.line, text: p.muted)
  if primary:
    let fill = if hot or pressed: p.accentHover else: p.accent
    return NativeButtonColors(fill: fill, border: fill, text: p.onAccent)
  NativeButtonColors(fill: (if hot or pressed: p.accentSoft else: p.surface),
    border: (if hot or pressed: p.accent else: p.controlLine), text: p.ink)

proc colorRef*(rgb: uint32): uint32 =
  ## Win32 uses 0x00BBGGRR, not CSS's 0xRRGGBB.
  ((rgb and 0xff) shl 16) or (rgb and 0xff00) or ((rgb shr 16) and 0xff)
