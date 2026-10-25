import std/unittest
import leaf/[native_theme, core]

suite "native theme tokens and compatibility":
  test "existing applications retain system appearance":
    let app = Application(title: "Legacy", width: 640, height: 480)
    check app.nativeTheme == systemTheme
    let themed = app.withNativeTheme(matsuDark)
    check themed.nativeTheme == matsuDark
    check app.nativeTheme == systemTheme
    check themed.title == app.title
    check themed.width == app.width

  test "latest light and dark semantic colors are independent":
    let light = palette(matsuLight)
    let dark = palette(matsuDark)
    check light.surface == 0xffffff'u32
    check light.canvas == 0xeef1ef'u32
    check light.accent == 0x23634d'u32
    check dark.surface == 0x1c211e'u32
    check dark.ink == 0xedf2ee'u32
    check dark.accent == 0x9dd5b5'u32
    check dark.onAccent == 0x142b1e'u32

  test "system appearance and high contrast never force brand colors":
    check not themeEnabled(systemTheme, false)
    check not themeEnabled(matsuDark, true)
    check themeEnabled(matsuLight, false)
    expect ValueError:
      discard palette(systemTheme)

  test "button state uses hierarchy rather than different sizes":
    let p = palette(matsuLight)
    let primary = buttonColors(matsuLight, primary=true)
    let secondary = buttonColors(matsuLight)
    check primary.fill == p.accent
    check primary.text == p.onAccent
    check secondary.fill == p.surface
    check secondary.text == p.ink
    check buttonColors(matsuLight, primary=true, hot=true).fill == p.accentHover
    check buttonColors(matsuLight, primary=true, disabled=true).fill == p.panel
    check buttonColors(matsuLight, disabled=true).text == p.muted

  test "approved compact dimensions stay in DIP":
    check NativeButtonWidth == 96.0
    check NativeButtonHeight == 32.0
    check NativeButtonRadius == 5.0
    check NativeInputHeight == 40.0
    check NativeActionGap == 8.0

  test "RGB tokens convert to the Win32 COLORREF byte order":
    check colorRef(0x23634d'u32) == 0x4d6323'u32
    check colorRef(0xffffff'u32) == 0xffffff'u32
    check colorRef(0'u32) == 0'u32
