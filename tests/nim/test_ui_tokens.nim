import std/[unittest, math]
import leaf/ui/tokens
import leaf/native_theme

suite "shadcn Neutral color contract":
  test "neutral light values come from the pinned theme rather than the website":
    let p = neutralPalette(UiColorMode.light)
    check rgb24(p[UiColorToken.background]) == 0xffffff'u32
    check rgb24(p[UiColorToken.foreground]) == 0x0a0a0a'u32
    check rgb24(p[UiColorToken.primary]) == 0x171717'u32
    check rgb24(p[UiColorToken.mutedForeground]) == 0x737373'u32
    check rgb24(p[UiColorToken.destructive]) == 0xe7000b'u32
    check rgb24(p[UiColorToken.border]) == 0xe5e5e5'u32

  test "dark surfaces and transparent borders are not flattened to one gray":
    let p = neutralPalette(UiColorMode.dark)
    check rgb24(p[UiColorToken.background]) == 0x0a0a0a'u32
    check rgb24(p[UiColorToken.card]) == 0x171717'u32
    check abs(p[UiColorToken.border].a - 0.1) < 0.000001
    check rgb24(composite(p[UiColorToken.border], p[UiColorToken.card])) == 0x2e2e2e'u32
    check rgb24(composite(p[UiColorToken.border], p[UiColorToken.background])) == 0x232323'u32

  test "OKLCH uses the sRGB transfer function and clips out of gamut":
    check rgb24(oklchToSrgb(oklch(0, 0, 0))) == 0'u32
    check rgb24(oklchToSrgb(oklch(1, 0, 0))) == 0xffffff'u32
    check rgb24(oklchToSrgb(oklch(0.704, 0.191, 22.216))) == 0xff6467'u32
    let c = oklchToSrgb(oklch(0.8, 0.6, -30))
    for channel in [c.r, c.g, c.b]: check channel >= 0 and channel <= 1

  test "transparent composition preserves alpha and rejects invalid inputs":
    let mixed = composite(srgb(1, 0, 0, 0.5), srgb(0, 0, 1, 0.5))
    check abs(mixed.a - 0.75) < 0.000001
    check abs(mixed.r - 2.0/3.0) < 0.000001
    check abs(mixed.b - 1.0/3.0) < 0.000001
    check composite(srgb(1, 0, 0, 0), srgb(0, 1, 0, 0)).a == 0
    expect ValueError: discard oklchToSrgb(oklch(NaN, 0, 0))
    expect ValueError: discard oklchToSrgb(oklch(0.5, Inf, 0))
    expect ValueError: discard oklchToSrgb(oklch(0.5, -0.1, 0))
    expect ValueError: discard srgb(1, 0, 0, 1.1)
    expect ValueError: discard rgb24(SrgbColor(r: NaN, a: 1))

  test "new themes append without changing legacy defaults or palette":
    check ord(systemTheme) == 0
    check ord(matsuLight) == 1
    check ord(matsuDark) == 2
    check ord(shadcnLight) == 3
    check ord(shadcnDark) == 4
    check palette(matsuLight).accent == 0x23634d'u32
    check palette(shadcnLight).accent == 0x171717'u32
    check palette(shadcnDark).canvas == 0x0a0a0a'u32
    check not themeEnabled(shadcnDark, true)
