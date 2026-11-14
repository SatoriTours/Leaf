when not defined(windows): {.error:"Native radio group tests require Windows".}
import ../fixture_app
import std/[unittest,widestrs,strutils]
import leaf/[ui_thread,native_layout,native_theme,styles,backend_session,graphics,core]
import leaf/backend as protocol
import leaf/backends/win32/[api,host,backend,skin]
import leaf/ui as standard
import leaf/ui/appearance

proc UpdateWindow(w:HWND):BOOL {.stdcall,dynlib:"user32.dll",importc,raises:[].}
proc GetPixel(dc:HDC,x,y:int32):DWORD {.stdcall,dynlib:"gdi32.dll",importc,raises:[].}
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
proc mounted(build:FixtureBuild,theme:NativeTheme):Fixture =
  let activity=newUiScopeActivity()
  let app=fixtureApplication(build,"Standard radio group",520,420).withNativeTheme(theme)
  let runtime=newRuntime(guardUiApplication(app,
    proc():uint64=uint64(GetCurrentThreadId()),activity))
  let h=createHost(app.title,DipSize(width:520,height:420),theme=theme)
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

proc styleOf(w:HWND):int32 = GetWindowLongW(w,GWL_STYLE)
proc tabStop(w:HWND):bool = (styleOf(w) and int32(WS_TABSTOP))!=0
proc radioType(w:HWND):bool = (styleOf(w) and 0xf)==int32(BS_RADIOBUTTON)
proc checked(w:HWND):bool = SendMessageW(w,BM_GETCHECK,0,0)==1

proc group(accepted:string, disabledItem="", onChange:Callback=nil,
    prefix="g", captions:array[3,string]=["标准","加急","自取"]):Node =
  standard.radioGroup(@[
    standard.radioGroupItem("standard",captions[0],key=prefix&"-standard",
      disabled=disabledItem=="standard"),
    standard.radioGroupItem("express",captions[1],key=prefix&"-express",
      disabled=disabledItem=="express"),
    standard.radioGroupItem("pickup",captions[2],key=prefix&"-pickup",
      disabled=disabledItem=="pickup")], accepted, key=prefix, label="配送方式",
    onChange=onChange)

suite "shadcn native radio group":
  test "items are stock radio buttons with one tab stop per group":
    let f=mounted(proc():Node=column(@[
      group("express", prefix="one"),
      group("", prefix="two", captions=["平邮","挂号","面交"])],
      styles=style({"padding":"24","gap":"16","width":"full"})),shadcnLight)
    try:
      let standard1=find(f.h.windowHandle,"标准")
      let express=find(f.h.windowHandle,"加急")
      let pickup=find(f.h.windowHandle,"自取")
      require standard1!=nil and express!=nil and pickup!=nil
      for w in [standard1,express,pickup]:
        check radioType(w)
        # BS_RADIOBUTTON, not BS_AUTORADIOBUTTON: the OS never clears siblings
        # behind the controlled accept transaction.
        check not ((styleOf(w) and 0xf)==int32(0x9))
      check checked(express)
      check not checked(standard1)
      check not checked(pickup)
      # Exactly one Tab entry into this group: the accepted, enabled item.
      var stops=0
      for w in [standard1,express,pickup]:
        if tabStop(w):inc stops
      check stops==1
      check tabStop(express)
      # An unselected group has one Tab entry too: its first enabled item.
      let post=find(f.h.windowHandle,"平邮")
      let registered=find(f.h.windowHandle,"挂号")
      let meet=find(f.h.windowHandle,"面交")
      require post!=nil and registered!=nil and meet!=nil
      stops=0
      for w in [post,registered,meet]:
        if tabStop(w):inc stops
      check stops==1
      check tabStop(post)
      for w in [post,registered,meet]: check not checked(w)
    finally:f.close()

  test "an accepted click moves selection and a refused click restores it":
    var model="standard"
    var events=0
    var accept=true
    let cb:Callback=proc(e:Event)=
      inc events
      if accept:model=e.value
    let f=mounted(proc():Node=column(@[group(model,onChange=cb)],
      styles=style({"padding":"24","width":"full"})),shadcnLight)
    try:
      let standard1=find(f.h.windowHandle,"标准")
      let express=find(f.h.windowHandle,"加急")
      require standard1!=nil and express!=nil
      check checked(standard1)
      discard SendMessageW(express,BM_CLICK,0,0)
      check events==0
      f.s.drainEvents();discard f.runtime.refresh()
      check events==1
      check model=="express"
      check checked(express)
      check not checked(standard1)
      # Activating the already accepted item is not a new submission.
      discard SendMessageW(express,BM_CLICK,0,0)
      f.s.drainEvents();discard f.runtime.refresh()
      check events==1
      # A refused request is delivered once and the accepted state is restored.
      accept=false
      discard SendMessageW(standard1,BM_CLICK,0,0)
      f.s.drainEvents();discard f.runtime.refresh()
      check events==2
      check model=="express"
      check checked(express)
      check not checked(standard1)
      # The rejected candidate never pollutes the next accepted turn.
      accept=true
      discard SendMessageW(standard1,BM_CLICK,0,0)
      f.s.drainEvents();discard f.runtime.refresh()
      check events==3
      check model=="standard"
      check checked(standard1)
      check not checked(express)
      check find(f.h.windowHandle,"标准")==standard1
    finally:f.close()

  test "two sibling groups never share accepted state":
    var shipping="express"
    var payment=""
    let shipCb:Callback=proc(e:Event)=shipping=e.value
    let payCb:Callback=proc(e:Event)=payment=e.value
    let f=mounted(proc():Node=column(@[
      group(shipping,onChange=shipCb,prefix="ship"),
      group(payment,onChange=payCb,prefix="pay",
        captions=["平邮","挂号","面交"])],
      styles=style({"padding":"24","gap":"16","width":"full"})),shadcnDark)
    try:
      let a=find(f.h.windowHandle,"加急")
      let b=find(f.h.windowHandle,"面交")
      require a!=nil and b!=nil
      discard SendMessageW(b,BM_CLICK,0,0)
      f.s.drainEvents();discard f.runtime.refresh()
      check shipping=="express"
      check payment=="pickup"
      check checked(a)
      check checked(b)
      check find(f.h.windowHandle,"加急")==a
      check find(f.h.windowHandle,"面交")==b
    finally:f.close()

  test "arrows and Home/End move focus inside one group and skip disabled items":
    let f=mounted(proc():Node=column(@[group("standard",disabledItem="express")],
      styles=style({"padding":"24","width":"full"})),shadcnLight)
    try:
      let standard1=find(f.h.windowHandle,"标准")
      let express=find(f.h.windowHandle,"加急")
      let pickup=find(f.h.windowHandle,"自取")
      require standard1!=nil and express!=nil and pickup!=nil
      discard SetFocus(standard1)
      f.win.safeListTurn()
      check GetFocus()==standard1
      discard SendMessageW(standard1,WM_KEYDOWN,VK_DOWN,0)
      check GetFocus()==pickup
      discard SendMessageW(pickup,WM_KEYDOWN,VK_DOWN,0)
      check GetFocus()==standard1
      discard SendMessageW(standard1,WM_KEYDOWN,VK_UP,0)
      check GetFocus()==pickup
      discard SendMessageW(pickup,WM_KEYDOWN,VK_HOME,0)
      check GetFocus()==standard1
      discard SendMessageW(standard1,WM_KEYDOWN,VK_END,0)
      check GetFocus()==pickup
      check GetFocus()!=express
      check IsWindowEnabled(express)==0
      # Arrow focus movement alone never submits a selection request.
      check checked(standard1)
      check not checked(pickup)
    finally:f.close()

  test "the accepted option paints a Neutral ring and inner dot in both themes":
    for theme in [shadcnLight,shadcnDark]:
      let f=mounted(proc():Node=column(@[group("express")],
        styles=style({"padding":"24","width":"full"})),theme)
      try:
        let off=find(f.h.windowHandle,"标准")
        let on=find(f.h.windowHandle,"加急")
        require off!=nil and on!=nil
        discard refreshSkin(off);discard UpdateWindow(off)
        discard refreshSkin(on);discard UpdateWindow(on)
        # Expected pixels come from the declared Neutral appearance of the same
        # surface, not from a guessed constant.
        let canvas=palette(theme).canvas
        let surface=srgb(float64((canvas shr 16) and 255)/255,
          float64((canvas shr 8) and 255)/255,float64(canvas and 255)/255)
        let mode=if theme==shadcnDark: UiColorMode.dark else: UiColorMode.light
        let offColors=checkAppearance(mode,UiRole.radioGroupItem,surface)
        let onColors=checkAppearance(mode,UiRole.radioGroupItem,surface,checked=true)
        let offDC=GetDC(off)
        require offDC!=nil
        check GetPixel(offDC,0,10)==colorRef(offColors.border)
        discard ReleaseDC(off,offDC)
        let onDC=GetDC(on)
        require onDC!=nil
        check GetPixel(onDC,8,10)==colorRef(onColors.mark)
        discard ReleaseDC(on,onDC)
        let s=newWideCString(64)
        require GetWindowTextW(on,cast[WidePtr](unsafeAddr s[0]),64)>0
        check $s=="加急"
      finally:f.close()

  test "focus never selects and never clears a sibling group":
    var shipping="standard"
    var payment="standard"
    let shipCb:Callback=proc(e:Event)=shipping=e.value
    let payCb:Callback=proc(e:Event)=payment=e.value
    let f=mounted(proc():Node=column(@[
      group(shipping,onChange=shipCb,prefix="ship"),
      group(payment,onChange=payCb,prefix="pay",
        captions=["平邮","挂号","面交"])],
      styles=style({"padding":"24","gap":"16","width":"full"})),shadcnLight)
    try:
      let standard1=find(f.h.windowHandle,"标准")
      let pickup=find(f.h.windowHandle,"自取")
      let post=find(f.h.windowHandle,"平邮")
      let meet=find(f.h.windowHandle,"面交")
      require standard1!=nil and pickup!=nil and post!=nil and meet!=nil
      check checked(standard1) and not checked(pickup)
      check checked(post) and not checked(meet)
      # USER32 checks a stock radio on focus; the accepted value must win.
      discard SetFocus(pickup)
      f.win.safeListTurn()
      check GetFocus()==pickup
      check checked(standard1)
      check not checked(pickup)
      # The sibling group keeps its own accepted option too.
      check checked(post)
      check not checked(meet)
      # A group boundary starts at the group's first option only.
      check (GetWindowLongW(standard1,GWL_STYLE) and int32(WS_GROUP))!=0
      check (GetWindowLongW(pickup,GWL_STYLE) and int32(WS_GROUP))==0
      check (GetWindowLongW(post,GWL_STYLE) and int32(WS_GROUP))!=0
      check (GetWindowLongW(meet,GWL_STYLE) and int32(WS_GROUP))==0
      # Focus alone sends no business event.
      f.s.drainEvents();discard f.runtime.refresh()
      check shipping=="standard"
      check payment=="standard"
    finally:f.close()

  test "a disabled group keeps its accepted state without a tab stop":
    var events=0
    let cb:Callback=proc(e:Event)=inc events
    let f=mounted(proc():Node=column(@[
      standard.radioGroup(@[
        standard.radioGroupItem("standard","标准",key="off-a"),
        standard.radioGroupItem("express","加急",key="off-b")], "express",
        key="off", label="配送方式", disabled=true, onChange=cb)],
      styles=style({"padding":"24","width":"full"})),shadcnLight)
    try:
      var stops=0
      for caption in ["标准","加急"]:
        let w=find(f.h.windowHandle,caption)
        require w!=nil
        check IsWindowEnabled(w)==0
        check radioType(w)
        if tabStop(w):inc stops
        discard SendMessageW(w,BM_CLICK,0,0)
      check stops==0
      check checked(find(f.h.windowHandle,"加急"))
      f.s.drainEvents();discard f.runtime.refresh()
      check events==0
    finally:f.close()

  test "changing a checkbox to a radio role at the same key is refused":
    # Both renders keep the same mounted identity; the native BUTTON style is
    # fixed at creation, so the role may not be patched in place.
    var asRadio=false
    let f=mounted(proc():Node=column(@[
      (if asRadio:standard.radioGroupItem("a","身份稳定",key="fixed")
       else:standard.checkbox("身份稳定",false,key="fixed"))],
      styles=style({"padding":"24","width":"full"})),shadcnLight)
    try:
      let window=find(f.h.windowHandle,"身份稳定")
      require window!=nil
      check (GetWindowLongW(window,GWL_STYLE) and 0xf)==int32(BS_AUTOCHECKBOX)
      asRadio=true
      var refusal=""
      try: discard f.runtime.refresh()
      except UiError as error: refusal=error.msg
      check refusal.contains("requires a new key")
      check find(f.h.windowHandle,"身份稳定")==window
      # The refused candidate leaves a usable tree: the old role still works.
      asRadio=false
      discard f.runtime.refresh()
      check find(f.h.windowHandle,"身份稳定")==window
      check (GetWindowLongW(window,GWL_STYLE) and 0xf)==int32(BS_AUTOCHECKBOX)
    finally:f.close()

  test "a radio option cannot become a plain checkbox or column at the same key":
    # Built as a raw group so the constructor cannot hide the prepare-level rule;
    # the accepted value is empty, so both options are legitimately unchecked.
    proc rawGroup(item: Node): Node =
      core.ui(NodeKind.column, key = "grp", children = @[
        standard.radioGroupItem("standard","标准",key="keep"), item],
        attributes=style({"ui_role":"radioGroup","radio_value":""}))
    for asColumn in [false, true]:
      var demoted=false
      let f=mounted(proc():Node=column(@[
        (if demoted:
          (if asColumn:rawGroup(column(@[], key="fixed"))
           else:rawGroup(core.ui(NodeKind.checkbox,text="加急",key="fixed")))
         else:rawGroup(standard.radioGroupItem("express","加急",key="fixed")))],
        styles=style({"padding":"24","width":"full"})),shadcnLight)
      try:
        let keep=find(f.h.windowHandle,"标准")
        let fixed=find(f.h.windowHandle,"加急")
        require keep!=nil and fixed!=nil
        check radioType(fixed)
        check not checked(fixed)
        discard SetFocus(fixed);f.win.safeListTurn()
        demoted=true
        var refusal=""
        try: discard f.runtime.refresh()
        except UiError as error: refusal=error.msg
        # A checkbox keeps the same native identity, so the role-change guard is
        # the rule that must fire. A column is a different native node identity
        # in this runtime, so the group's structural rule refuses the candidate
        # instead; both refusals happen before any native effect.
        if asColumn: check refusal.contains("radio group only supports")
        else: check refusal.contains("requires a new key")
        # Accepted tree, HWND identity, role and focus are untouched.
        check find(f.h.windowHandle,"标准")==keep
        check find(f.h.windowHandle,"加急")==fixed
        check not checked(fixed)
        check GetFocus()==fixed
        check radioType(fixed)
        # A later legal candidate still applies on the same identity.
        demoted=false
        discard f.runtime.refresh()
        check find(f.h.windowHandle,"加急")==fixed
        check radioType(fixed)
      finally:f.close()

  test "a radio group role cannot silently become a plain column":
    var grouped=true
    let f=mounted(proc():Node=column(@[
      (if grouped:standard.radioGroup(@[
          standard.radioGroupItem("standard","标准",key="g-a"),
          standard.radioGroupItem("express","加急",key="g-b")],"standard",
          key="grp",label="配送方式")
       else:column(@[text("标准"),text("加急")],key="grp"))],
      styles=style({"padding":"24","width":"full"})),shadcnLight)
    try:
      let accepted=find(f.h.windowHandle,"标准")
      require accepted!=nil
      check radioType(accepted)
      check checked(accepted)
      grouped=false
      var refusal=""
      try: discard f.runtime.refresh()
      except UiError as error: refusal=error.msg
      check refusal.contains("requires a new key")
      check find(f.h.windowHandle,"标准")==accepted
      check checked(accepted)
      grouped=true
      discard f.runtime.refresh()
      check find(f.h.windowHandle,"标准")==accepted
    finally:f.close()

  test "removing the accepted option is refused and keeps the accepted tree":
    var dropAccepted=false
    var model="express"
    let cb:Callback=proc(e:Event)=model=e.value
    let f=mounted(proc():Node=column(@[standard.radioGroup(@[
      standard.radioGroupItem("standard","标准",key="d-a"),
      (if dropAccepted:standard.radioGroupItem("pickup","自取",key="d-c")
       else:standard.radioGroupItem("express","加急",key="d-b"))],
      model,key="drop",label="配送方式",onChange=cb)],
      styles=style({"padding":"24","width":"full"})),shadcnLight)
    try:
      let standard1=find(f.h.windowHandle,"标准")
      let express=find(f.h.windowHandle,"加急")
      require standard1!=nil and express!=nil
      check checked(express)
      check not checked(standard1)
      discard SetFocus(express);f.win.safeListTurn()
      # The candidate no longer contains the accepted value: prepare refuses it
      # instead of silently selecting the first option.
      dropAccepted=true
      var refusal=""
      try: discard f.runtime.refresh()
      except UiError as error: refusal=error.msg
      check refusal.contains("accepted radio value is not an option")
      # The accepted tree is still the previous one, with identity and focus.
      check find(f.h.windowHandle,"标准")==standard1
      check find(f.h.windowHandle,"加急")==express
      check checked(express)
      check not checked(standard1)
      check GetFocus()==express
      # A later legal candidate applies on the same identity.
      dropAccepted=false
      model="standard"
      discard f.runtime.refresh()
      check find(f.h.windowHandle,"标准")==standard1
      check checked(standard1)
      check not checked(express)
      # And the next accepted interaction still works.
      discard SendMessageW(express,BM_CLICK,0,0)
      f.s.drainEvents();discard f.runtime.refresh()
      check model=="express"
      check checked(express)
    finally:f.close()
