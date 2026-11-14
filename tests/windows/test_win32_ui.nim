when not defined(windows): {.error: "Standard UI host tests require Windows".}
import ../fixture_app
import std/[unittest, widestrs]
import leaf/[ui_thread, native_theme, native_layout, styles]
import leaf/backend as protocol
import leaf/backends/win32/[api, host, backend, skin]
import leaf/ui as standard
import leaf/ui/appearance
import leaf/backends/win32/measure

proc GetTextFaceW(dc: HDC, count: int32, name: ptr WCHAR): int32
  {.stdcall, dynlib:"gdi32.dll", importc, raises:[].}

proc GetGlyphIndicesW(dc:HDC,text:ptr WCHAR,count:int32,glyphs:ptr WCHAR,flags:DWORD):DWORD
  {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}

proc GetPixel(dc: HDC, x, y: int32): DWORD {.stdcall, dynlib:"gdi32.dll", importc, raises:[].}
proc GetWindowDC(window: HWND): HDC {.stdcall, dynlib:"user32.dll", importc, raises:[].}
proc UpdateWindow(window: HWND): BOOL {.stdcall, dynlib:"user32.dll", importc, raises:[].}

var children: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises:[].} =
  children.add(window)
  1
proc find(parent: HWND, caption: string): HWND =
  children.setLen(0)
  discard EnumChildWindows(parent, collect, 0)
  for child in children:
    let text = newWideCString(512)
    discard GetWindowTextW(child, cast[WidePtr](unsafeAddr text[0]), 512)
    if $text == caption: return child

suite "shadcn native controls":
  test "real Button Input Card use Neutral tokens and preserve EDIT selection":
    require not highContrastActive()
    for theme in [shadcnLight, shadcnDark]:
      var invalid = false
      let app = fixtureApplication(proc(): Node =
        column(@[standard.card(@[
          standard.cardHeader(@[standard.cardTitle("账户"), standard.cardDescription("公开信息")]),
          standard.cardContent(@[standard.input("原生编辑中文", key="name", invalid=invalid)]),
          standard.cardFooter(@[
            standard.button("保存", key="save"),
            standard.button("删除", key="delete", variant=UiVariant.destructive),
            standard.button("取消", key="cancel", variant=UiVariant.outline)])
        ], key="card")], key="root", styles=style({"width":"full","padding":"24"})),
        "Standard UI", 560, 340).withNativeTheme(theme)
      let activity = newUiScopeActivity()
      let runtime = newRuntime(guardUiApplication(app,
        proc(): uint64 = uint64(GetCurrentThreadId()), activity))
      let h = createHost(app.title, DipSize(width:560,height:340), theme=theme)
      h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
      let win = newWin32Backend(h)
      try:
        let session = win.attachWin32Backend(runtime, protocol.strict)
        win.bindSession(session)
        h.bindSession(session, proc(): bool = activity.busy)
        let save = find(h.windowHandle, "保存")
        let edit = find(h.windowHandle, "原生编辑中文")
        let delete = find(h.windowHandle, "删除")
        require save != nil and edit != nil and delete != nil
        var bounds: RECT
        require GetWindowRect(save, addr bounds) != 0
        check abs(float64(bounds.bottom-bounds.top)/h.context.scale - 36) <= 1
        var font: LOGFONTW
        require GetObjectW(cast[HGDIOBJ](SendMessageW(save,WM_GETFONT,0,0)),int32(sizeof(font)),addr font) != 0
        check abs(float64(font.lfHeight)/h.context.scale + 14) <= 1
        check font.lfWeight == 500
        let mode=if theme==shadcnDark:UiColorMode.dark else:UiColorMode.light
        let cardColor=neutralPalette(mode)[UiColorToken.card]
        let footer=if theme==shadcnDark:composite(srgb(1,1,1,0.012),cardColor)
          else:srgb(250.0/255,250.0/255,250.0/255)
        # Painter consumes packed/quantized COLORREF surfaces.
        let footerRgb=rgb24(footer)
        let actualSurface=srgb(float64((footerRgb shr 16) and 255)/255,
          float64((footerRgb shr 8) and 255)/255,float64(footerRgb and 255)/255)
        for (window, expected) in [(save,palette(theme).accent),
            (delete,buttonAppearance(mode,UiVariant.destructive,actualSurface).fill)]:
          discard refreshSkin(window)
          discard UpdateWindow(window)
          let dc = GetDC(window)
          require dc != nil
          check GetPixel(dc, 6, 10) == colorRef(expected)
          discard ReleaseDC(window, dc)
        # Keyboard focus must not consume three DIP of the button face.
        discard SendMessageW(save,0x0128,2 or (1 shl 16),0) # UIS_CLEAR/UISF_HIDEFOCUS
        discard SetFocus(save)
        discard refreshSkin(save)
        discard UpdateWindow(save)
        let focusedDc=GetDC(save)
        require focusedDc!=nil
        check GetPixel(focusedDc,2,18)==colorRef(palette(theme).accent)
        discard ReleaseDC(save,focusedDc)
        win.safeListTurn()
        let adornment=win.focusAdornmentForTest
        require adornment!=nil
        var focusedBounds,ringBounds: RECT
        require GetWindowRect(save,addr focusedBounds)!=0
        require GetWindowRect(adornment,addr ringBounds)!=0
        check focusedBounds==bounds
        check ringBounds.left<focusedBounds.left and ringBounds.top<focusedBounds.top
        check ringBounds.right>focusedBounds.right and ringBounds.bottom>focusedBounds.bottom
        # Layered presentation is checked in stable actual-window captures,
        # not an instantaneous GetDC sample during native show transitions.
        discard UpdateWindow(adornment)
        var hostBounds: RECT
        require GetWindowRect(h.windowHandle,addr hostBounds)!=0
        require IsWindowVisible(adornment)!=0
        # Z-order/no-op notifications must not hide the owned overlay while
        # USER32 is arranging the popup/IME ownership group.
        require SetWindowPos(h.windowHandle,nil,0,0,0,0,0x0017)!=0
        check IsWindowVisible(adornment)!=0
        require SetWindowPos(h.windowHandle,nil,hostBounds.left+13,hostBounds.top+17,
          0,0,0x0015)!=0 # NOSIZE | NOZORDER | NOACTIVATE
        # Exercise real host WndProc routing: hide synchronously, reposition
        # only in the ensuing ordinary pump, never in WINDOWPOSCHANGING.
        check IsWindowVisible(adornment)==0
        # Bound the lifetime pump after its initial ordinary safe turn.
        PostQuitMessage(0)
        discard h.pump()
        check IsWindowVisible(adornment)!=0
        require GetWindowRect(adornment,addr ringBounds)!=0
        require GetWindowRect(save,addr focusedBounds)!=0
        check ringBounds.left==focusedBounds.left-3
        check ringBounds.top==focusedBounds.top-3
        discard SendMessageW(h.windowHandle,0x0006,0,0) # WA_INACTIVE
        check IsWindowVisible(adornment)==0
        discard SendMessageW(h.windowHandle,0x0006,1,0) # WA_ACTIVE
        discard SetFocus(save)
        PostQuitMessage(0)
        discard h.pump()
        check IsWindowVisible(adornment)!=0
        discard SendMessageW(save,0x0128,0x00010001,0) # UIS_SET/HIDEFOCUS
        win.safeListTurn()
        check IsWindowVisible(adornment)==0
        discard SendMessageW(save,0x0128,0x00010002,0)
        discard SetFocus(edit)
        echo "EDIT native UI state after focus: ",SendMessageW(edit,0x0129,0,0)
        win.safeListTurn()
        # Editable text is focus-visible even on pointer focus: its focus cue
        # is the active editing/caret context, not button-only hidefocus.
        check IsWindowVisible(adornment)!=0
        discard SendMessageW(edit,0x0128,0x00010001,0)
        win.safeListTurn()
        check IsWindowVisible(adornment)!=0
        require GetWindowRect(edit,addr focusedBounds)!=0
        require GetWindowRect(adornment,addr ringBounds)!=0
        check ringBounds.left==focusedBounds.left-3
        check ringBounds.top==focusedBounds.top-3
        discard SendMessageW(edit,EM_SETSEL,1,4)
        invalid = true
        discard runtime.refresh()
        check find(h.windowHandle,"原生编辑中文") == edit
        var first, last: uint32
        discard SendMessageW(edit,EM_GETSEL,cast[WPARAM](addr first),cast[LPARAM](addr last))
        check first == 1 and last == 4
        discard refreshSkin(edit)
        discard UpdateWindow(edit)
        let dc = GetWindowDC(edit)
        require dc != nil
        check GetPixel(dc, 0, 18) == colorRef(palette(theme).danger)
        discard ReleaseDC(edit,dc)
      finally:
        h.destroyHost()
        runtime.closeRuntime()
      check win.diagnostics.liveWindows == 0
      check win.diagnostics.liveFonts == 0
      check win.diagnostics.liveRoots == 0

  test "field typography and multiline EDIT keep native geometry selection and focus":
    require not highContrastActive()
    for theme in [shadcnLight,shadcnDark]:
      var invalid=false
      let app=fixtureApplication(proc(): Node =
        column(@[text("账户设置",variant="primary"),standard.card(@[
          standard.cardHeader(@[standard.cardTitle("公开资料")]),
          standard.cardContent(@[standard.field(@[
            standard.label("个人简介",key="label"),
            standard.textarea("第一行\n第二行 😀",key="bio",height=96,invalid=invalid),
            standard.fieldDescription("最多 160 字。",key="hint")],key="bio-field")])
        ])],styles=style({"padding":"32","width":"full"})),
        "Standard field",600,380).withNativeTheme(theme)
      let activity=newUiScopeActivity()
      let runtime=newRuntime(guardUiApplication(app,
        proc(): uint64 = uint64(GetCurrentThreadId()),activity))
      let h=createHost(app.title,DipSize(width:600,height:380),theme=theme)
      h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
      let win=newWin32Backend(h)
      try:
        let session=win.attachWin32Backend(runtime,protocol.strict)
        win.bindSession(session)
        h.bindSession(session,proc(): bool = activity.busy)
        let heading=find(h.windowHandle,"账户设置")
        let title=find(h.windowHandle,"公开资料")
        let label=find(h.windowHandle,"个人简介")
        let hint=find(h.windowHandle,"最多 160 字。")
        let edit=find(h.windowHandle,"第一行\r\n第二行 😀")
        require heading!=nil and title!=nil and label!=nil and hint!=nil and edit!=nil
        for (window,size,weight) in [(heading,24,700),(title,16,700),(label,14,500),(hint,13,400),(edit,14,400)]:
          var font: LOGFONTW
          require GetObjectW(cast[HGDIOBJ](SendMessageW(window,WM_GETFONT,0,0)),
            int32(sizeof(font)),addr font)!=0
          check abs(float64(font.lfHeight)/h.context.scale+float64(size))<=1
          check font.lfWeight==weight
          check font.lfQuality==4 # grayscale AA, not forced subpixel color fringes
          let expectedFace=checkedWide("Microsoft YaHei UI")
          check font.lfFaceName[0..<expectedFace.len]==expectedFace
          let dc=GetDC(window)
          require dc!=nil
          let previous=SelectObject(dc,cast[HGDIOBJ](SendMessageW(window,WM_GETFONT,0,0)))
          var face:array[64,WCHAR]
          let faceCount=GetTextFaceW(dc,int32(face.len),addr face[0])
          var glyphs:array[4,WCHAR]
          let chinese=checkedWide("账户设置")
          let glyphCount=GetGlyphIndicesW(dc,unsafeAddr chinese[0],4,addr glyphs[0],1)
          discard SelectObject(dc,previous)
          discard ReleaseDC(window,dc)
          require faceCount>0
          check glyphCount==4
          for glyph in glyphs: check glyph!=0xffff

          echo "Realized font face: ",face[0..<int(faceCount)]
          check face[0..<expectedFace.len]==expectedFace
        var bounds,client: RECT
        require GetWindowRect(edit,addr bounds)!=0
        require GetClientRect(edit,addr client)!=0
        check abs(float64(bounds.bottom-bounds.top)/h.context.scale-96)<=1
        check (GetWindowLongW(edit,GWL_STYLE) and 4)!=0
        check (GetWindowLongW(edit,GWL_STYLE) and 0x00100000)==0
        check SendMessageW(edit,0x00ba,0,0)==2 # EM_GETLINECOUNT
        let verticalInset=float64(bounds.bottom-bounds.top-client.bottom)/h.context.scale
        check abs(verticalInset-16)<=2
        discard SetFocus(edit)
        win.safeListTurn()
        check IsWindowVisible(win.focusAdornmentForTest)!=0
        discard SendMessageW(edit,EM_SETSEL,1,4)
        invalid=true
        discard runtime.refresh()
        check find(h.windowHandle,"第一行\r\n第二行 😀")==edit
        var first,last:uint32
        discard SendMessageW(edit,EM_GETSEL,cast[WPARAM](addr first),cast[LPARAM](addr last))
        check first==1 and last==4
      finally:
        h.destroyHost()
        runtime.closeRuntime()
      check win.diagnostics.liveWindows==0
      check win.diagnostics.liveFonts==0
