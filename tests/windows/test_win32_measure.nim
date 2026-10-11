when not defined(windows): {.error: "Real Win32 measurement tests require Windows".}
import std/[unittest, strutils]
import leaf/[core, native_layout]
import leaf/backends/win32/[api, calls, host, measure]

proc owner(): Win32Host =
  createHost("Native font/theme measurement owner", DipSize(width: 400, height: 300))

proc clean(m: NativeMeasure): bool =
  m.liveDCs == 0 and m.liveThemes == 0 and m.liveMeasureWindows == 0

proc same(a, b: float64): bool = abs(a - b) < 0.00001

suite "W-MEASURE real system font theme and resource retry":
  test "owned font metrics equal GDI at the actual owner DPI":
    let h = owner()
    defer: h.destroyHost()
    let baseline = GetGuiResources(GetCurrentProcess(), 0)
    var c = systemWin32Calls()
    let realDelete = c.deleteObject
    var deleted: HGDIOBJ
    var deletionResult: BOOL
    var deletions = 0
    c.deleteObject = proc(obj: HGDIOBJ): BOOL =
      inc deletions
      deleted = obj
      result = realDelete(obj)
      deletionResult = result
    let m = newNativeMeasure(h.windowHandle, c)
    defer: m.close()
    let fm = m.fontMetrics()
    let font = m.ensureFont()
    check GetObjectType(cast[HGDIOBJ](font)) == 6 # OBJ_FONT
    var actualFont: LOGFONTW
    check GetObjectW(cast[HGDIOBJ](font), int32(sizeof(actualFont)), addr actualFont) == int32(sizeof(actualFont))
    var ncm: NONCLIENTMETRICSW
    ncm.cbSize = UINT(sizeof(ncm))
    check SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, ncm.cbSize,
      addr ncm, 0, GetDpiForWindow(h.windowHandle)) != 0
    check actualFont == ncm.lfMessageFont
    let dc = GetDC(h.windowHandle)
    require dc != nil
    let old = SelectObject(dc, cast[HGDIOBJ](font))
    require old != nil and cast[int](old) != -1
    var actual: TEXTMETRICW
    check GetTextMetricsW(dc, addr actual) != 0
    check actual == fm
    check SelectObject(dc, old) == cast[HGDIOBJ](font)
    check ReleaseDC(h.windowHandle, dc) != 0
    check fm.tmAveCharWidth > 0 and fm.tmHeight > 0
    check m.clean()
    m.close()
    check m.liveFonts == 0
    check deletions == 1 and deleted == cast[HGDIOBJ](font) and deletionResult != 0
    # Actual Windows run 15a504b1: retired fonts can still return OBJ_FONT from
    # GetObjectType. GetObjectW, native deletion acknowledgement and resource
    # counts jointly verify lifetime without that invalid type-query oracle.
    var retired: LOGFONTW
    check GetObjectW(cast[HGDIOBJ](font), int32(sizeof(retired)), addr retired) == 0
    check GetGuiResources(GetCurrentProcess(), 0) == baseline
    m.close()
    check deletions == 1 # closing an already released owner never deletes twice

  test "push button size exactly matches a real same-font BUTTON ideal size":
    let h = owner()
    defer: h.destroyHost()
    var c = systemWin32Calls()
    let realSend = c.send
    var seen: HWND
    var seenFont: LRESULT
    var seenEnabled, seenVisible: BOOL
    var beforeSize: SIZE
    var queries = 0
    c.send = proc(window: HWND, msg: UINT, wp: WPARAM, lp: LPARAM): LRESULT =
      if msg == BCM_GETIDEALSIZE:
        inc queries
        seen = window
        seenFont = SendMessageW(window, WM_GETFONT, 0, 0)
        seenEnabled = IsWindowEnabled(window)
        seenVisible = IsWindowVisible(window)
        beforeSize = cast[ptr SIZE](lp)[]
      realSend(window, msg, wp, lp)
    let m = newNativeMeasure(h.windowHandle, c)
    defer: m.close()
    let font = m.ensureFont()
    let dpi = float64(GetDpiForWindow(h.windowHandle))
    let cls = checkedWide("BUTTON")
    for enabled in [true, false]:
      for label in ["", "OK", "中文 😀", "&Open a substantially longer document"]:
        let title = checkedWide(label)
        let button = CreateWindowExW(0, unsafeAddr cls[0], unsafeAddr title[0],
          WS_CHILD or WS_TABSTOP, 0, 0, 0, 0, h.windowHandle, nil, GetModuleHandleW(nil), nil)
        require button != nil
        try:
          discard SendMessageW(button, WM_SETFONT, cast[WPARAM](font), 0)
          discard EnableWindow(button, BOOL(ord(enabled)))
          var ideal: SIZE # zero cx/cy asks for both ideal dimensions
          require SendMessageW(button, BCM_GETIDEALSIZE, 0, cast[LPARAM](addr ideal)) != 0
          let measured = m.measureButton(label, enabled)
          check same(measured.width, float64(ideal.cx) * 96.0 / dpi)
          check same(measured.height, float64(ideal.cy) * 96.0 / dpi)
          check seenFont == cast[LRESULT](font)
          check (seenEnabled != 0) == enabled
          check seenVisible == 0
          check beforeSize == SIZE()
          check IsWindow(seen) == 0
          check m.clean()
        finally:
          check DestroyWindow(button) != 0
    check queries == 8

  test "push button creation and ideal-size failures clean up and allow retry":
    let h = owner()
    defer: h.destroyHost()
    for createFailure in [true, false]:
      var c = systemWin32Calls()
      let realCreate = c.createWindow
      let realSend = c.send
      var fail = true
      var probe: HWND
      c.createWindow = proc(exStyle: DWORD, cls, title: WidePtr, style: DWORD,
                           x, y, width, height: int32, parent: HWND, menu: HMENU,
                           instance: HINSTANCE, param: pointer): HWND =
        if fail and createFailure: setLastError(5); return nil
        result = realCreate(exStyle, cls, title, style, x, y, width, height, parent, menu, instance, param)
        probe = result
      c.send = proc(window: HWND, msg: UINT, wp: WPARAM, lp: LPARAM): LRESULT =
        if fail and not createFailure and msg == BCM_GETIDEALSIZE:
          setLastError(5)
          return 0
        realSend(window, msg, wp, lp)
      let m = newNativeMeasure(h.windowHandle, c)
      expect UiError: discard m.measureButton("retry")
      check m.clean() and m.liveFonts == 1
      if probe != nil: check IsWindow(probe) == 0
      fail = false
      check m.measureButton("retry").height > 0
      check m.clean()
      m.close()
      check m.liveFonts == 0

  test "push button destruction failure retains HWND and font until close retry":
    let h = owner()
    defer: h.destroyHost()
    var c = systemWin32Calls()
    let realCreate = c.createWindow
    let realDestroy = c.destroyWindow
    let realDelete = c.deleteObject
    var fail = true
    var probe: HWND
    var creations, nativeDestructions, nativeFontDeletes: int
    c.createWindow = proc(exStyle: DWORD, cls, title: WidePtr, style: DWORD,
                         x, y, width, height: int32, parent: HWND, menu: HMENU,
                         instance: HINSTANCE, param: pointer): HWND =
      inc creations
      result = realCreate(exStyle, cls, title, style, x, y, width, height, parent, menu, instance, param)
      probe = result
    c.destroyWindow = proc(window: HWND): BOOL =
      if fail: setLastError(5); return 0
      inc nativeDestructions
      realDestroy(window)
    c.deleteObject = proc(obj: HGDIOBJ): BOOL =
      inc nativeFontDeletes
      realDelete(obj)
    let m = newNativeMeasure(h.windowHandle, c)
    let font = m.ensureFont()
    expect UiError: discard m.measureButton("retained", enabled=false)
    check m.liveMeasureWindows == 1 and m.liveFonts == 1
    check IsWindow(probe) != 0 and IsWindowVisible(probe) == 0
    check IsWindowEnabled(probe) == 0
    check SendMessageW(probe, WM_GETFONT, 0, 0) == cast[LRESULT](font)
    expect UiError: m.close()
    check m.liveMeasureWindows == 1 and m.liveFonts == 1
    check nativeDestructions == 0 and nativeFontDeletes == 0
    expect UiError: discard m.measureButton("blocked by retained cleanup")
    check creations == 1 and m.liveMeasureWindows == 1
    fail = false
    m.close()
    check IsWindow(probe) == 0 and m.clean() and m.liveFonts == 0
    check nativeDestructions == 1 and nativeFontDeletes == 1
    m.close()
    check nativeDestructions == 1 and nativeFontDeletes == 1

  test "push button query primary survives a secondary destruction failure":
    let h = owner()
    defer: h.destroyHost()
    var c = systemWin32Calls()
    let realSend = c.send
    let realDestroy = c.destroyWindow
    let primary = newException(IOError, "button ideal-size primary")
    let cause = newException(ValueError, "button cause")
    primary.parent = cause
    var fail = true
    c.send = proc(window: HWND, msg: UINT, wp: WPARAM, lp: LPARAM): LRESULT =
      if fail and msg == BCM_GETIDEALSIZE: raise primary
      realSend(window, msg, wp, lp)
    c.destroyWindow = proc(window: HWND): BOOL =
      if fail: setLastError(5); return 0
      realDestroy(window)
    let m = newNativeMeasure(h.windowHandle, c)
    var caught: ref CatchableError
    try: discard m.measureButton("query failure")
    except CatchableError as e: caught = e
    check caught == primary and caught.parent == cause
    check "DestroyWindow" in caught.msg
    check m.liveMeasureWindows == 1 and m.liveFonts == 1
    fail = false
    # A new measurement first retries retained cleanup; no second probe is
    # acquired while the previous owner is unresolved.
    check m.measureButton("retry").height > 0
    check m.clean()
    m.close()
    check m.liveFonts == 0

  test "input uses real EDIT margins value placeholder and twenty average widths":
    let h = owner()
    defer: h.destroyHost()
    let m = newNativeMeasure(h.windowHandle, systemWin32Calls())
    defer: m.close()
    let fm = m.fontMetrics()
    let short = m.measureInput("", "x")
    let label = "a much longer placeholder with 中文 and 😀 and enough characters to exceed twenty averages"
    let long = m.measureInput("", label)
    let valued = m.measureInput(label, "")
    check short.width >= m.pixelsToDip(20.0 * float64(fm.tmAveCharWidth))
    check long.width > short.width
    check long.width >= m.measureText(label).width
    check same(long.width, valued.width)
    check same(short.height, long.height)
    check short.height >= m.pixelsToDip(float64(fm.tmHeight))
    let cls = checkedWide("EDIT")
    let edit = CreateWindowExW(0, unsafeAddr cls[0], nil, WS_CHILD or WS_BORDER or 0x80'u32,
      0, 0, 0, 0, h.windowHandle, nil, GetModuleHandleW(nil), nil)
    require edit != nil
    defer: discard DestroyWindow(edit)
    discard SendMessageW(edit, WM_SETFONT, cast[WPARAM](m.ensureFont()), 0)
    let margin = cast[uint](SendMessageW(edit, EM_GETMARGINS, 0, 0))
    var border: RECT
    check AdjustWindowRectExForDpi(addr border, WS_CHILD or WS_BORDER or 0x80'u32,
      0, 0, GetDpiForWindow(h.windowHandle)) != 0
    let expected = m.pixelsToDip(20.0 * float64(fm.tmAveCharWidth) +
      float64((margin and 0xffff) + ((margin shr 16) and 0xffff)) + float64(border.right - border.left))
    check same(short.width, expected)
    check m.measureInput("", "x", edit) == short
    check m.clean()

  test "checkbox calls actual DPI-aware theme glyph measurement and balances handles":
    let h = owner()
    defer: h.destroyHost()
    var c = systemWin32Calls()
    let realOpen = c.openTheme
    let realPart = c.themePartSize
    let realClose = c.closeTheme
    var opens, parts, closes: int
    var observed: SIZE
    var observedWindow: HWND
    var observedDpi: UINT
    var observedPart, observedState, observedMode: int32
    c.openTheme = proc(window: HWND, cls: WidePtr, dpi: UINT): HTHEME =
      observedWindow = window
      observedDpi = dpi
      inc opens
      realOpen(window, cls, dpi)
    c.themePartSize = proc(theme: HTHEME, dc: HDC, part, state: int32,
                          rect: ptr RECT, mode: int32, size: ptr SIZE): int32 =
      observedPart = part
      observedState = state
      observedMode = mode
      inc parts
      result = realPart(theme, dc, part, state, rect, mode, size)
      if result >= 0: observed = size[]
    c.closeTheme = proc(theme: HTHEME): int32 =
      inc closes
      realClose(theme)
    let m = newNativeMeasure(h.windowHandle, c)
    defer: m.close()
    let measured = m.measureCheckbox("中文 native", checked=true)
    check opens == 1
    check observedWindow == h.windowHandle
    check observedDpi == GetDpiForWindow(h.windowHandle)
    if parts > 0:
      check observedPart == 3 and observedState == 5 and observedMode == 1
    else:
      echo "NOTRUN themed glyph measurement: Windows returned no BUTTON theme"
    check parts == closes # classic/no-theme environment is also supported
    if observed.cx > 0:
      check measured.width >= m.pixelsToDip(float64(observed.cx)) + m.measureText("中文 native").width
      check measured.height >= m.pixelsToDip(float64(observed.cy))
    check measured.width > 0 and measured.height > 0
    check m.clean()

  test "unavailable or invalid checkbox theme falls back to real system check metrics":
    let h = owner()
    defer: h.destroyHost()
    for invalidPart in [false, true]:
      var c = systemWin32Calls()
      let realOpen = c.openTheme
      c.openTheme = proc(window: HWND, cls: WidePtr, dpi: UINT): HTHEME =
        if invalidPart: realOpen(window, cls, dpi) else: nil
      c.themePartSize = proc(theme: HTHEME, dc: HDC, part, state: int32,
                            rect: ptr RECT, mode: int32, size: ptr SIZE): int32 = -1
      let m = newNativeMeasure(h.windowHandle, c)
      let size = m.measureCheckbox("")
      let dpi = GetDpiForWindow(h.windowHandle)
      check same(size.width, m.pixelsToDip(float64(GetSystemMetricsForDpi(71, dpi)) +
        2.0 * float64(GetSystemMetricsForDpi(SM_CXBORDER, dpi))))
      check size.height >= m.pixelsToDip(float64(GetSystemMetricsForDpi(72, dpi)))
      check m.clean()
      m.close()

  test "progress and separator dimensions track system metrics rather than fixed DIPs":
    let h = owner()
    defer: h.destroyHost()
    let m = newNativeMeasure(h.windowHandle, systemWin32Calls())
    defer: m.close()
    let dpi = GetDpiForWindow(h.windowHandle)
    let fm = m.fontMetrics()
    let progress = m.measureProgress()
    let separator = m.measureSeparator()
    check same(progress.width, m.pixelsToDip(20.0 * float64(fm.tmAveCharWidth)))
    check same(separator.width, progress.width)
    check same(progress.height, m.pixelsToDip(float64(GetSystemMetricsForDpi(SM_CYHSCROLL, dpi))))
    check same(separator.height, m.pixelsToDip(float64(GetSystemMetricsForDpi(46, dpi))))
    check m.clean()

  test "font and DC acquisition failures retain only acquired owners and can retry":
    let h = owner()
    defer: h.destroyHost()
    for stage in 0..3:
      var c = systemWin32Calls()
      let parameters = c.systemParameters
      let create = c.createFont
      let get = c.getDC
      let select = c.selectObject
      var fail = true
      c.systemParameters = proc(action, param: UINT, value: pointer, flags, dpi: UINT): BOOL =
        if fail and stage == 0: setLastError(5); return 0
        parameters(action, param, value, flags, dpi)
      c.createFont = proc(font: ptr LOGFONTW): HFONT =
        if fail and stage == 1: setLastError(5); return nil
        create(font)
      c.getDC = proc(window: HWND): HDC =
        if fail and stage == 2: setLastError(5); return nil
        get(window)
      c.selectObject = proc(dc: HDC, obj: HGDIOBJ): HGDIOBJ =
        if fail and stage == 3: setLastError(5); return nil
        select(dc, obj)
      let m = newNativeMeasure(h.windowHandle, c)
      expect UiError: discard m.fontMetrics()
      check m.clean()
      check m.liveFonts == ord(stage >= 2)
      fail = false
      check m.fontMetrics().tmHeight > 0
      m.close()
      check m.liveFonts == 0 and m.clean()

  test "restore and release failures preserve exact DC ownership for close retry":
    let h = owner()
    defer: h.destroyHost()
    for failRestore in [false, true]:
      var c = systemWin32Calls()
      let select = c.selectObject
      let release = c.releaseDC
      var selections, releases: int
      var fail = true
      c.selectObject = proc(dc: HDC, obj: HGDIOBJ): HGDIOBJ =
        inc selections
        if fail and failRestore and selections > 1: setLastError(5); return nil
        select(dc, obj)
      c.releaseDC = proc(window: HWND, dc: HDC): int32 =
        inc releases
        if fail and not failRestore: setLastError(5); return 0
        release(window, dc)
      let m = newNativeMeasure(h.windowHandle, c)
      expect UiError: discard m.fontMetrics()
      check m.liveDCs == 1 and m.liveFonts == 1
      if failRestore: check releases == 0
      expect UiError: m.close()
      check m.liveDCs == 1 and m.liveFonts == 1
      fail = false
      m.close()
      check m.clean() and m.liveFonts == 0
      # A successful restore must not be performed again after ReleaseDC fails.
      if not failRestore: check selections == 2

  test "DeleteObject failure retains the same real font for retry":
    let h = owner()
    defer: h.destroyHost()
    var c = systemWin32Calls()
    let delete = c.deleteObject
    let baseline = GetGuiResources(GetCurrentProcess(), 0)
    var fail = true
    var attempts, actualDeletes: int
    var deleted: HGDIOBJ
    var deletionResult: BOOL
    c.deleteObject = proc(obj: HGDIOBJ): BOOL =
      inc attempts
      if fail: setLastError(5); return 0
      inc actualDeletes
      deleted = obj
      result = delete(obj)
      deletionResult = result
    let m = newNativeMeasure(h.windowHandle, c)
    let font = m.ensureFont()
    expect UiError: m.close()
    check m.liveFonts == 1
    check m.ensureFont() == font
    check GetObjectType(cast[HGDIOBJ](font)) == 6
    fail = false
    m.close()
    check m.liveFonts == 0 and m.clean()
    check attempts == 2 and actualDeletes == 1
    check deleted == cast[HGDIOBJ](font) and deletionResult != 0
    var retired: LOGFONTW
    check GetObjectW(cast[HGDIOBJ](font), int32(sizeof(retired)), addr retired) == 0
    check GetGuiResources(GetCurrentProcess(), 0) == baseline
    m.close()
    check attempts == 2 and actualDeletes == 1

  test "primary exception and parent survive simultaneous DC and theme cleanup failures":
    let h = owner()
    defer: h.destroyHost()
    var c = systemWin32Calls()
    let realClose = c.closeTheme
    let release = c.releaseDC
    var fail = true
    let primary = newException(ValueError, "theme query primary")
    let cause = newException(IOError, "retained cause")
    primary.parent = cause
    c.themePartSize = proc(theme: HTHEME, dc: HDC, part, state: int32,
                          rect: ptr RECT, mode: int32, size: ptr SIZE): int32 = raise primary
    c.closeTheme = proc(theme: HTHEME): int32 =
      if fail: return -1
      realClose(theme)
    c.releaseDC = proc(window: HWND, dc: HDC): int32 =
      if fail: setLastError(5); return 0
      release(window, dc)
    let m = newNativeMeasure(h.windowHandle, c)
    var caught: ref CatchableError
    try: discard m.measureCheckbox("theme")
    except CatchableError as e: caught = e
    if m.liveThemes != 0:
      check caught == primary and caught.parent == cause
      check "ReleaseDC" in caught.msg and "CloseThemeData" in caught.msg
      check m.liveThemes == 1 and m.liveDCs == 1
      expect UiError: m.close()
      check m.liveThemes == 1 and m.liveDCs == 1 and m.liveFonts == 1
    else:
      # Classic Windows can legitimately have no HTHEME to inject a failure into.
      check caught != nil and "ReleaseDC" in caught.msg
      echo "NOTRUN theme query failure: Windows returned no BUTTON theme"
    fail = false
    m.close()
    check m.clean() and m.liveFonts == 0

  test "theme close alone retains its actual handle and preserves HRESULT for retry":
    let h = owner()
    defer: h.destroyHost()
    var c = systemWin32Calls()
    let realClose = c.closeTheme
    var fail = true
    var retained, retried: HTHEME
    c.closeTheme = proc(theme: HTHEME): int32 =
      if fail:
        retained = theme
        return -2147467259'i32 # E_FAIL, not a GetLastError result
      retried = theme
      realClose(theme)
    let m = newNativeMeasure(h.windowHandle, c)
    var caught: ref CatchableError
    try: discard m.measureCheckbox("theme")
    except CatchableError as e: caught = e
    if retained != nil:
      check caught != nil
      check "HRESULT: -2147467259" in caught.msg
      check m.liveThemes == 1 and m.liveDCs == 0
      fail = false
      m.close()
      check retried == retained
    else:
      echo "NOTRUN theme close failure: Windows returned no BUTTON theme"
      m.close()
    check m.clean() and m.liveFonts == 0

  test "font metric and open-theme exceptions clean up the acquired real DC":
    let h = owner()
    defer: h.destroyHost()
    for failMetrics in [false, true]:
      var c = systemWin32Calls()
      let realMetrics = c.textMetrics
      let realOpen = c.openTheme
      var fail = true
      let primary = newException(IOError, "measurement acquisition failed")
      c.textMetrics = proc(dc: HDC, metric: ptr TEXTMETRICW): BOOL =
        if fail and failMetrics: raise primary
        realMetrics(dc, metric)
      c.openTheme = proc(window: HWND, cls: WidePtr, dpi: UINT): HTHEME =
        if fail and not failMetrics: raise primary
        realOpen(window, cls, dpi)
      let m = newNativeMeasure(h.windowHandle, c)
      var caught: ref CatchableError
      try: discard m.measureCheckbox("acquire")
      except CatchableError as e: caught = e
      check caught == primary
      check m.clean() and m.liveFonts == 1
      fail = false
      check m.measureCheckbox("retry").width > 0
      m.close()
      check m.clean() and m.liveFonts == 0

  test "repeated real font DC theme EDIT and BUTTON measurement returns to GDI baseline":
    let h = owner()
    defer: h.destroyHost()
    # Warm lazy Windows theme/font caches before taking the process baseline.
    let warm = newNativeMeasure(h.windowHandle, systemWin32Calls())
    discard warm.measureInput("中文", "placeholder")
    discard warm.measureCheckbox("checkbox")
    discard warm.measureButton("button")
    warm.close()
    let baseline = GetGuiResources(GetCurrentProcess(), 0) # GR_GDIOBJECTS
    for iteration in 0..<16:
      let m = newNativeMeasure(h.windowHandle, systemWin32Calls())
      discard m.measureInput("中文", "placeholder")
      discard m.measureCheckbox("checkbox")
      discard m.measureButton("button")
      discard m.measureProgress()
      discard m.measureSeparator()
      m.close()
      check m.clean() and m.liveFonts == 0
    check GetGuiResources(GetCurrentProcess(), 0) == baseline

  test "hidden measurement EDIT creation and destruction failures are retryable":
    let h = owner()
    defer: h.destroyHost()
    var c = systemWin32Calls()
    let create = c.createWindow
    let destroy = c.destroyWindow
    var failCreate = true
    var failDestroy = false
    var probe: HWND
    c.createWindow = proc(exStyle: DWORD, cls, title: WidePtr, style: DWORD,
                         x, y, width, height: int32, parent: HWND, menu: HMENU,
                         instance: HINSTANCE, param: pointer): HWND =
      if failCreate: setLastError(5); return nil
      result = create(exStyle, cls, title, style, x, y, width, height, parent, menu, instance, param)
      probe = result
    c.destroyWindow = proc(window: HWND): BOOL =
      if failDestroy: setLastError(5); return 0
      destroy(window)
    let m = newNativeMeasure(h.windowHandle, c)
    expect UiError: discard m.measureInput("", "hint")
    check m.clean()
    failCreate = false
    failDestroy = true
    expect UiError: discard m.measureInput("", "hint")
    check m.liveMeasureWindows == 1 and m.liveFonts == 1
    check IsWindow(probe) != 0 and IsWindowVisible(probe) == 0
    expect UiError: m.close()
    check m.liveMeasureWindows == 1 and m.liveFonts == 1
    failDestroy = false
    m.close()
    check IsWindow(probe) == 0
    check m.clean() and m.liveFonts == 0

  test "invalid text and widths acquire no native resources":
    let h = owner()
    defer: h.destroyHost()
    let m = newNativeMeasure(h.windowHandle, systemWin32Calls())
    defer: m.close()
    expect UiError: discard m.measureText("bad\0text")
    expect UiError: discard m.measureText("text", NaN)
    expect UiError: discard m.measureText("text", Inf)
    expect UiError: discard m.measureText("text", -1)
    expect UiError: discard m.measureInput("", "\xff")
    expect UiError: discard m.measureButton("bad\0button")
    check m.liveFonts == 0 and m.clean()
