when not defined(windows): {.error: "Focus adornment requires Windows".}
import std/[unittest,widestrs]
import leaf/[core,native_layout,native_theme]
import leaf/backends/win32/[api,calls,host,focus_ring]

proc UpdateWindow(window: HWND): BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
proc GetForegroundWindow(): HWND {.stdcall,dynlib:"user32.dll",importc,raises:[].}

suite "external standard focus adornment":
  test "ring is owned, outside geometry, click-through and reuses one window":
    let h=createHost("Focus adornment",DipSize(width:400,height:240),theme=shadcnLight)
    let cls=newWideCString("BUTTON")
    let title=newWideCString("Save")
    let button=CreateWindowExW(0,cast[WidePtr](unsafeAddr cls[0]),cast[WidePtr](unsafeAddr title[0]),
      0x50010000'u32,20,30,100,36,h.windowHandle,nil,GetModuleHandleW(nil),nil)
    require button!=nil
    var ring: FocusRing
    try:
      let foreground=GetForegroundWindow()
      showFocusRing(ring,h.windowHandle,button,0xabcdef'u32)
      let popup=ring.windowHandle
      require popup!=nil
      var face,outer: RECT
      require GetWindowRect(button,addr face)!=0
      require GetWindowRect(popup,addr outer)!=0
      let scale=float64(GetDpiForWindow(button))/96
      check abs(float64(face.left-outer.left)-3*scale)<=1
      check abs(float64(face.top-outer.top)-3*scale)<=1
      check abs(float64(outer.right-face.right)-3*scale)<=1
      check abs(float64(outer.bottom-face.bottom)-3*scale)<=1
      check SendMessageW(popup,0x0084,0,0) == -1 # HTTRANSPARENT
      check GetForegroundWindow()==foreground
      discard UpdateWindow(popup)
      showFocusRing(ring,h.windowHandle,button,0x123456'u32)
      check ring.windowHandle==popup
      discard ShowWindow(popup,0) # USER32 may hide an owned group independently.
      check IsWindowVisible(popup)==0
      showFocusRing(ring,h.windowHandle,button,0x123456'u32)
      check IsWindowVisible(popup)!=0
      hideFocusRing(ring)
      check IsWindowVisible(popup)==0
      check IsWindow(button)!=0
      closeFocusRing(ring)
      check ring.windowHandle==nil
      check IsWindow(popup)==0
    finally:
      closeFocusRing(ring)
      h.destroyHost()

  test "failed destroy preserves owned handle for a bounded retry":
    let h=createHost("Focus cleanup",DipSize(width:300,height:180))
    var ring: FocusRing
    var injected=systemWin32Calls()
    let destroy=injected.destroyWindow
    var reject=true
    injected.destroyWindow=proc(window: HWND): BOOL =
      if reject: return 0
      destroy(window)
    try:
      showFocusRing(ring,h.windowHandle,h.windowHandle,0x999999'u32,injected)
      let owned=ring.windowHandle
      expect UiError: closeFocusRing(ring)
      check ring.windowHandle==owned
      check IsWindow(owned)!=0
      reject=false
      closeFocusRing(ring)
      check ring.windowHandle==nil
      check IsWindow(owned)==0
    finally:
      reject=false
      closeFocusRing(ring)
      h.destroyHost()

  test "owner destruction after a failed close still ends the owned resource":
    let h=createHost("Focus close failure",DipSize(width:300,height:180))
    var ring: FocusRing
    var injected=systemWin32Calls()
    injected.destroyWindow=proc(window: HWND): BOOL = 0
    showFocusRing(ring,h.windowHandle,h.windowHandle,0x999999'u32,injected)
    expect UiError: closeFocusRing(ring)
    h.destroyHost()
    check ring.windowHandle==nil

  test "owner destruction ends the popup without a stale ownership handle":
    let h=createHost("Focus owner",DipSize(width:300,height:180))
    var ring: FocusRing
    showFocusRing(ring,h.windowHandle,h.windowHandle,0x999999'u32)
    let owned=ring.windowHandle
    h.destroyHost()
    check IsWindow(owned)==0
    check ring.windowHandle==nil
    closeFocusRing(ring)
