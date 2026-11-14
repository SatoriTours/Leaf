when not defined(windows): {.error:"Native Field tests require Windows".}
import ../fixture_app
import std/[unittest,widestrs,options]
import leaf/[ui_thread,native_layout,native_theme,styles,backend_session]
import leaf/backend as protocol
import leaf/backends/win32/[api,host,backend,skin,row_pool]
import leaf/ui as standard

var children:seq[HWND]
proc collect(w:HWND,data:LPARAM):BOOL {.stdcall,raises:[].} =
  children.add(w);1
proc find(parent:HWND,name:string):HWND =
  children.setLen(0)
  discard EnumChildWindows(parent,collect,0)
  for w in children:
    let s=newWideCString(128)
    discard GetWindowTextW(w,cast[WidePtr](unsafeAddr s[0]),128)
    if $s==name:return w

type Fixture=tuple[h:Win32Host,win:Win32Backend,s:BackendSession,runtime:Runtime]
proc mounted(build:FixtureBuild,theme=shadcnLight):Fixture =
  let activity=newUiScopeActivity()
  let app=fixtureApplication(build,"Standard Fields",480,360).withNativeTheme(theme)
  let runtime=newRuntime(guardUiApplication(app,
    proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=createHost(app.title,DipSize(width:480,height:360),theme=theme)
  h.setStartupScope(proc():bool=activity.busy or runtime.installingUpdate or runtime.installingHook)
  let win=newWin32Backend(h)
  let s=win.attachWin32Backend(runtime,protocol.strict)
  win.bindSession(s);h.bindSession(s,proc():bool=activity.busy)
  (h,win,s,runtime)
proc close(f:Fixture) =
  f.h.destroyHost();f.runtime.closeRuntime()
  check f.win.diagnostics.liveWindows==0
  check f.win.diagnostics.liveFonts==0
  check f.win.diagnostics.liveRoots==0
  check f.win.fieldAnnotationCountsForTest==(0,0)

proc UpdateWindow(w:HWND):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
proc GetPixel(dc:HDC,x,y:int32):DWORD {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}

suite "standard horizontal button group native semantics":
  test "GroupBox owns buttons and updates its accessible caption without replacing HWNDs":
    for theme in [shadcnLight,shadcnDark]:
      var name="Actions"
      let f=mounted(proc():Node=column(@[standard.buttonGroup(@[
        standard.button("Save",key="save",variant=UiVariant.outline),
        standard.button("Cancel",key="cancel",variant=UiVariant.outline)],
        key="actions",label=name)],styles=style({"padding":"24"})),theme)
      try:
        let group=find(f.h.windowHandle,"Actions")
        let save=find(f.h.windowHandle,"Save")
        let cancel=find(f.h.windowHandle,"Cancel")
        require group!=nil and save!=nil and cancel!=nil
        var cls:array[64,WCHAR]
        discard GetClassNameW(group,addr cls[0],64)
        check cls[0]==WCHAR(ord('B'))
        check (GetWindowLongW(group,GWL_STYLE) and 0xf)==7
        check (GetWindowLongW(group,GWL_STYLE) and int32(WS_TABSTOP))==0
        check GetParent(save)==group and GetParent(cancel)==group
        var a,b:RECT
        require GetWindowRect(save,addr a)!=0 and GetWindowRect(cancel,addr b)!=0
        check a.right==b.left
        check a.top==b.top and a.bottom==b.bottom
        discard refreshSkin(save);discard refreshSkin(cancel)
        discard UpdateWindow(save);discard UpdateWindow(cancel)
        let dc=GetDC(cancel)
        # Joined left edge must not retain a rounded cutout or duplicate border.
        # White input at 15% * 30% over background #0a gives #15.
        check GetPixel(dc,0,1)==colorRef(if theme==shadcnLight:0xffffff'u32 else:0x151515'u32)
        discard ReleaseDC(cancel,dc)
        name="Updated actions";discard f.runtime.refresh()
        check find(f.h.windowHandle,name)==group
        check find(f.h.windowHandle,"Save")==save
        check find(f.h.windowHandle,"Cancel")==cancel
      finally:f.close()

  test "stable row identity cannot silently change the native group class":
    var grouped=false
    let f=mounted(proc():Node =
      if grouped: standard.buttonGroup(@[standard.button("Save")],key="row",label="Actions")
      else: row(@[standard.button("Save")],key="row"))
    try:
      let old=f.win.diagnostics.creates
      grouped=true
      expect UiError: discard f.runtime.refresh()
      check f.win.diagnostics.creates==old
      check find(f.h.windowHandle,"Save")!=nil
    finally:f.close()

  test "removing a neighbor restores the surviving button outer corner":
    for theme in [shadcnLight,shadcnDark]:
      var pair=true
      let f=mounted(proc():Node =
        var buttons= @[standard.button("Save",key="save")]
        if pair:buttons.add(standard.button("Cancel",key="cancel"))
        column(@[standard.buttonGroup(buttons,key="group",label="Actions")],
          styles=style({"padding":"24"})),theme)
      try:
        let save=find(f.h.windowHandle,"Save")
        var bounds:RECT
        require GetClientRect(save,addr bounds)!=0
        discard refreshSkin(save);discard UpdateWindow(save)
        pair=false;discard f.runtime.refresh()
        check find(f.h.windowHandle,"Save")==save
        # No forced refresh: the product must invalidate a changed joined edge.
        discard UpdateWindow(save)
        let dc=GetDC(save)
        check GetPixel(dc,bounds.right-1,0)==colorRef(if theme==shadcnLight:0xffffff'u32 else:0x0a0a0a'u32)
        discard ReleaseDC(save,dc)
      finally:f.close()

  test "row pool cannot exchange STATIC rows with native GroupBox rows":
    let plain=rowSignature([NodeKind.row,NodeKind.button],[-1,0],
      groups=[false,false])
    let grouped=rowSignature([NodeKind.row,NodeKind.button],[-1,0],
      groups=[true,false])
    check plain!=grouped
    var pool:RowPool
    check pool.park(RowSlot(owner:1,signature:plain))
    var slot:RowSlot
    check not pool.take(1,grouped,slot)
    check pool.take(1,plain,slot)

  test "stretched groups retain last-child outer corners regardless of spare space":
    for theme in [shadcnLight,shadcnDark]:
      for pair in [false,true]:
        let f=mounted(proc():Node =
          var buttons= @[standard.button("First",key="first")]
          if pair:buttons.add(standard.button("Last",key="last"))
          column(@[standard.buttonGroup(buttons,key="group",label="Stretched")],
            styles=style({"padding":"24","width":"full","align":"stretch"})),theme)
        try:
          let w=find(f.h.windowHandle,if pair:"Last" else:"First")
          var own,group:RECT
          require GetWindowRect(w,addr own)!=0
          require GetWindowRect(GetParent(w),addr group)!=0
          require own.right<group.right
          discard refreshSkin(w);discard UpdateWindow(w)
          let dc=GetDC(w)
          check GetPixel(dc,own.right-own.left-1,0)==colorRef(if theme==shadcnLight:0xffffff'u32 else:0x0a0a0a'u32)
          discard ReleaseDC(w,dc)
        finally:f.close()
