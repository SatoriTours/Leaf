when not defined(windows): {.error: "Native skin tests require Windows".}
import ../fixture_app
import std/[unittest, widestrs, strutils]
import leaf/[core, widgets, styles, backend_session, native_layout, native_theme, ui_thread]
import leaf/backend as protocol
import leaf/backends/win32/[api, host, backend, skin]

proc GetBkColor(dc: HDC): DWORD {.stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc GetTextColor(dc: HDC): DWORD {.stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc GetPixel(dc: HDC, x,y: int32): DWORD {.stdcall, dynlib: "gdi32.dll", importc, raises: [].}
proc UpdateWindow(window: HWND): BOOL {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc ClientToScreen(window: HWND, point: ptr POINT): BOOL {.stdcall, dynlib: "user32.dll", importc, raises: [].}
proc GetWindowDC(window: HWND): HDC {.stdcall, dynlib: "user32.dll", importc, raises: [].}

var children: seq[HWND]
proc collect(window: HWND, data: LPARAM): BOOL {.stdcall, raises: [].} =
  children.add(window)
  1
proc find(parent: HWND, caption: string): HWND =
  children.setLen(0)
  discard EnumChildWindows(parent, collect, 0)
  for child in children:
    let buf = newWideCString(256)
    discard GetWindowTextW(child, cast[WidePtr](unsafeAddr buf[0]), 256)
    if $buf == caption: return child

suite "opt-in native Win32 skin":
  test "both themes paint real controls without owning extra GDI resources":
    require not highContrastActive()
    for theme in [matsuLight, matsuDark]:
      let p = palette(theme)
      let activity = newUiScopeActivity()
      let app = fixtureApplication(proc(): Node = column(@[
        ui(NodeKind.text, key="label", text="中文 😀", attributes=style({"variant":"primary"})),
        ui(NodeKind.text, key="hint", text="辅助说明", attributes=style({"variant":"secondary"})),
        ui(NodeKind.text, key="error", text="请填写姓名", attributes=style({"variant":"danger"})),
        ui(NodeKind.input, key="edit", text="编辑 😀", attributes=style({"variant":"danger"}),
          styles=style({"width":"full", "height":"40"})),
        checkbox("通知", true, key="check"),
        switch("现代通知", true, key="toggle"),
        progress(50, key="progress", styles=style({"width":"200", "height":"20"})),
        button("切换输入模式", key="autoButton", variant="secondary"),
        row(@[button("保存", key="save", styles=style({"width":"96", "height":"32"})),
          button("重置", key="reset", variant="secondary", styles=style({"width":"96", "height":"32"}))],
          key="actions", styles=style({"gap":"8"}))],
        key="root", styles=style({"padding":"24", "gap":"12", "width":"full"})),
        "Native skin", 400, 440).withNativeTheme(theme)
      let runtime = newRuntime(guardUiApplication(app,
        proc(): uint64 = uint64(GetCurrentThreadId()), activity))
      let h = createHost(app.title, DipSize(width:400, height:440), theme=theme)
      h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
      let win = newWin32Backend(h)
      let session = win.attachWin32Backend(runtime, protocol.strict)
      win.bindSession(session)
      h.bindSession(session, proc(): bool = activity.busy)
      try:
        let edit = find(h.windowHandle, "编辑 😀")
        let save = find(h.windowHandle, "保存")
        let reset = find(h.windowHandle, "重置")
        require edit != nil and save != nil and reset != nil
        check primaryButton(save)
        check not primaryButton(reset)
        let titleWindow = find(h.windowHandle, "中文 😀")
        let hintWindow = find(h.windowHandle, "辅助说明")
        let errorWindow = find(h.windowHandle, "请填写姓名")
        require titleWindow != nil and hintWindow != nil and errorWindow != nil
        var titleFont, bodyFont: LOGFONTW
        let titleHandle = cast[HGDIOBJ](SendMessageW(titleWindow, WM_GETFONT, 0, 0))
        let bodyHandle = cast[HGDIOBJ](SendMessageW(edit, WM_GETFONT, 0, 0))
        require GetObjectW(titleHandle, int32(sizeof(titleFont)), addr titleFont) != 0
        require GetObjectW(bodyHandle, int32(sizeof(bodyFont)), addr bodyFont) != 0
        check abs(float64(titleFont.lfHeight) / h.context.scale + 24) <= 1
        check abs(float64(bodyFont.lfHeight) / h.context.scale + 14) <= 1
        check titleFont.lfWeight >= 600
        for (child, expected) in [(hintWindow, p.muted), (errorWindow, p.danger)]:
          let labelDc = GetDC(child)
          require labelDc != nil
          discard SendMessageW(GetParent(child), 0x0138, cast[WPARAM](labelDc), cast[LPARAM](child))
          check GetTextColor(labelDc) == colorRef(expected)
          discard ReleaseDC(child, labelDc)
        discard refreshSkin(edit)
        discard UpdateWindow(edit)
        let frameDc = GetWindowDC(edit)
        require frameDc != nil
        check GetPixel(frameDc, 0, 20) == colorRef(p.danger)
        discard ReleaseDC(edit, frameDc)
        let checkWindow = find(h.windowHandle, "通知")
        require checkWindow != nil
        check checkColorsPrepared(checkWindow)
        let toggleWindow = find(h.windowHandle, "现代通知")
        require toggleWindow != nil
        discard InvalidateRect(toggleWindow, nil, 1)
        discard UpdateWindow(toggleWindow)
        let toggleDc = GetDC(toggleWindow)
        require toggleDc != nil
        check GetPixel(toggleDc, 6, 20) == colorRef(p.accent)
        discard ReleaseDC(toggleWindow, toggleDc)
        # Still a real auto-checkbox: native click/Space/UIA semantics remain.
        discard SendMessageW(toggleWindow, BM_CLICK, 0, 0)
        check SendMessageW(toggleWindow, BM_GETCHECK, 0, 0) == 0
        children.setLen(0)
        discard EnumChildWindows(h.windowHandle, collect, 0)
        var progressWindow: HWND
        for child in children:
          let cls = newWideCString(64)
          discard GetClassNameW(child, cast[WidePtr](unsafeAddr cls[0]), 64)
          if ($cls).toLowerAscii == "msctls_progress32": progressWindow = child
        require progressWindow != nil
        discard InvalidateRect(progressWindow, nil, 1)
        discard UpdateWindow(progressWindow)
        let progressDc = GetDC(progressWindow)
        require progressDc != nil
        check GetPixel(progressDc, 20, 10) == colorRef(p.accent)
        check GetPixel(progressDc, 180, 10) == colorRef(p.line)
        discard ReleaseDC(progressWindow, progressDc)
        let autoButton = find(h.windowHandle, "切换输入模式")
        require autoButton != nil
        let autoDc = GetDC(autoButton)
        require autoDc != nil
        let font = cast[HGDIOBJ](SendMessageW(autoButton, WM_GETFONT, 0, 0))
        let oldFont = SelectObject(autoDc, font)
        let caption = newWideCString("切换输入模式")
        var extent: SIZE
        check GetTextExtentPoint32W(autoDc, cast[WidePtr](unsafeAddr caption[0]), 6, addr extent) != 0
        discard SelectObject(autoDc, oldFont)
        discard ReleaseDC(autoButton, autoDc)
        var autoBounds: RECT
        discard GetWindowRect(autoButton, addr autoBounds)
        check float64(autoBounds.right-autoBounds.left) >= float64(extent.cx) + 16.0 * h.context.scale
        let classBuf = newWideCString(64)
        discard GetClassNameW(edit, cast[WidePtr](unsafeAddr classBuf[0]), 64)
        check ($classBuf).toLowerAscii == "edit"
        # Catch a skin that only recolors EDIT but leaves its text at the top:
        # native client/caret area must be centered within the 40 DIP field.
        var editBounds, editClient: RECT
        var origin: POINT
        require GetWindowRect(edit, addr editBounds) != 0
        require GetClientRect(edit, addr editClient) != 0
        require ClientToScreen(edit, addr origin) != 0
        let topInset = origin.y - editBounds.top
        let bottomInset = editBounds.bottom - origin.y - editClient.bottom
        check float64(topInset) >= 6 * h.context.scale
        check abs(topInset - bottomInset) <= 1
        check float64(origin.x - editBounds.left) >= 8 * h.context.scale
        let dc = GetDC(edit)
        require dc != nil
        # Catch the EDIT's internal legacy border painter: after native paint,
        # the client top edge must stay plain surface, not gain a second frame.
        check GetPixel(dc, editClient.right-2, 0) == colorRef(p.surface)
        let brush = SendMessageW(GetParent(edit), SkinCtlColorEdit, cast[WPARAM](dc), cast[LPARAM](edit))
        check brush != 0
        check GetBkColor(dc) == colorRef(p.surface)
        check GetTextColor(dc) == colorRef(p.ink)
        discard ReleaseDC(edit, dc)
        discard SendMessageW(edit, EM_SETSEL, 1, 3)
        var a,b: DWORD
        discard SendMessageW(edit, EM_GETSEL, cast[WPARAM](addr a), cast[LPARAM](addr b))
        check a == 1 and b == 3
        discard InvalidateRect(save, nil, 1)
        discard UpdateWindow(save) # warm native theme caches before leak check
        let before = GetGuiResources(GetCurrentProcess(), 0)
        for i in 0 ..< 100:
          discard InvalidateRect(save, nil, 1)
          discard UpdateWindow(save)
        check GetGuiResources(GetCurrentProcess(), 0) == before
        let buttonDc = GetDC(save)
        require buttonDc != nil
        check GetPixel(buttonDc, 8, 8) == colorRef(p.accent)
        discard ReleaseDC(save, buttonDc)
        var saveRect, resetRect: RECT
        discard GetWindowRect(save, addr saveRect)
        discard GetWindowRect(reset, addr resetRect)
        let scale = h.context.scale
        check abs(float64(saveRect.right-saveRect.left)/scale - 96.0) <= 1.0
        check abs(float64(saveRect.bottom-saveRect.top)/scale - 32.0) <= 1.0
        check saveRect.right-saveRect.left == resetRect.right-resetRect.left
        check win.diagnostics.callbackErrors == 0
      finally:
        h.destroyHost()
        runtime.closeRuntime()
      check win.diagnostics.liveWindows == 0
      check win.diagnostics.liveFonts == 0
      check win.diagnostics.liveRoots == 0

  test "semantic updates retain HWND and selection and invalidate font measurements":
    var invalid = false
    let activity = newUiScopeActivity()
    let app = fixtureApplication(proc(): Node = column(@[
      text("同一段文字", key="title", variant=(if invalid: "primary" else: "secondary")),
      input("中文 😀", key="edit", variant=(if invalid: "danger" else: "default"),
        styles=style({"width":"full", "height":"40"}))], key="root",
        styles=style({"padding":"24", "gap":"12", "width":"full"})),
      "Semantic updates", 400, 240).withNativeTheme(matsuDark)
    let runtime = newRuntime(guardUiApplication(app,
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    let h = createHost(app.title, DipSize(width:400, height:240), theme=matsuDark)
    h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
    let win = newWin32Backend(h)
    let session = win.attachWin32Backend(runtime, protocol.strict)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    try:
      let edit = find(h.windowHandle, "中文 😀")
      let title = find(h.windowHandle, "同一段文字")
      require edit != nil and title != nil
      discard SendMessageW(edit, EM_SETSEL, 1, 3)
      var before, after: RECT
      discard GetWindowRect(title, addr before)
      let creates = win.diagnostics.creates
      invalid = true
      check runtime.refresh()
      check find(h.windowHandle, "中文 😀") == edit
      check semanticVariant(edit) == variantDanger
      check SendMessageW(edit, EM_GETSEL, 0, 0) == LRESULT(1 or (3 shl 16))
      discard GetWindowRect(title, addr after)
      check after.bottom-after.top > before.bottom-before.top
      invalid = false
      check runtime.refresh()
      check semanticVariant(edit) == variantDefault
      check SendMessageW(edit, EM_GETSEL, 0, 0) == LRESULT(1 or (3 shl 16))
      discard GetWindowRect(title, addr after)
      check after.bottom-after.top == before.bottom-before.top
      check win.diagnostics.creates == creates
      check win.diagnostics.callbackErrors == 0
    finally:
      h.destroyHost()
      runtime.closeRuntime()
    check win.diagnostics.liveFonts == 0
    check win.diagnostics.liveWindows == 0
    check win.diagnostics.liveRoots == 0

  test "empty native EDIT cue is readable and disappears for focus or real text":
    require not highContrastActive()
    let activity = newUiScopeActivity()
    let app = fixtureApplication(proc(): Node = column(@[
      input("", key="empty", placeholder="MMMMMMMMMMMM",
        styles=style({"width":"full", "height":"40"}))], key="root",
      styles=style({"padding":"24", "width":"full"})), "Native cue", 400, 200)
      .withNativeTheme(matsuDark)
    let runtime = newRuntime(guardUiApplication(app,
      proc(): uint64 = uint64(GetCurrentThreadId()), activity))
    let h = createHost(app.title, DipSize(width:400, height:200), theme=matsuDark)
    h.setStartupScope(proc(): bool = activity.busy or runtime.installingUpdate or runtime.installingHook)
    let win = newWin32Backend(h)
    let session = win.attachWin32Backend(runtime, protocol.strict)
    win.bindSession(session)
    h.bindSession(session, proc(): bool = activity.busy)
    try:
      children.setLen(0)
      discard EnumChildWindows(h.windowHandle, collect, 0)
      var edit: HWND
      for child in children:
        let cls = newWideCString(64)
        discard GetClassNameW(child, cast[WidePtr](unsafeAddr cls[0]), 64)
        if ($cls).toLowerAscii == "edit": edit = child
      require edit != nil
      proc mutedPixels(): int =
        discard refreshSkin(edit)
        discard UpdateWindow(edit)
        let dc = GetDC(edit)
        doAssert dc != nil
        defer: discard ReleaseDC(edit, dc)
        var bounds: RECT
        doAssert GetClientRect(edit, addr bounds) != 0
        for y in 0 ..< bounds.bottom:
          for x in 0 ..< bounds.right:
            if GetPixel(dc, x, y) == colorRef(palette(matsuDark).muted): inc result
      discard SetFocus(h.windowHandle)
      check mutedPixels() > 20
      let before = GetGuiResources(GetCurrentProcess(), 0)
      for i in 0 ..< 25: discard mutedPixels()
      check GetGuiResources(GetCurrentProcess(), 0) == before
      let cue = newWideCString(64)
      check SendMessageW(edit, 0x1502, cast[WPARAM](unsafeAddr cue[0]), 64) != 0
      check $cue == "MMMMMMMMMMMM"
      check SendMessageW(edit, 0x000e, 0, 0) == 0 # WM_GETTEXTLENGTH
      discard SetFocus(edit)
      check mutedPixels() == 0
      discard SetFocus(h.windowHandle)
      let content = newWideCString("real input")
      discard SendMessageW(edit, WM_SETTEXT, 0, cast[LPARAM](unsafeAddr content[0]))
      check mutedPixels() == 0
      check SendMessageW(edit, 0x000e, 0, 0) == 10
      check win.diagnostics.callbackErrors == 0
    finally:
      h.destroyHost()
      runtime.closeRuntime()
    check win.diagnostics.liveFonts == 0
    check win.diagnostics.liveWindows == 0

  test "themed host requests native dark caption only for the dark palette":
    proc DwmGetWindowAttribute(window: HWND, attr: DWORD, value: pointer,
        size: DWORD): int32 {.stdcall, dynlib: "dwmapi.dll", importc, raises: [].}
    for theme in [matsuLight, matsuDark]:
      let h = createHost("Native caption", DipSize(width:200, height:100), theme=theme)
      try:
        var dark: BOOL
        let status = DwmGetWindowAttribute(h.windowHandle, 20, addr dark, DWORD(sizeof(dark)))
        # Unsupported DWM attributes keep the system caption; not a startup error.
        if status >= 0:
          check (dark != 0) == (theme == matsuDark)
        else:
          checkpoint "DWM dark caption attribute unsupported; system fallback retained"
      finally: h.destroyHost()

  test "system appearance does not intercept native paint messages":
    var reply: LRESULT
    check not skinMessage(systemTheme, nil, SkinCtlColorEdit, 0, 0, reply)
