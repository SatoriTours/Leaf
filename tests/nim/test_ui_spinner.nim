import std/[unittest,options]
import leaf
import leaf/[styles,host_protocol]
import leaf/ui as standard

proc angle(rt:Runtime):int=normalizeProps(rt.find("spin").node).standardUi.get.angleDegrees.get

suite "managed standard Spinner":
  test "rotation runs on accepted Runtime time and loops across 1000ms cycle":
    let rt=newRuntime(componentApplication(standard.spinner(label="Loading",key="spin"),"Spinner"))
    defer:rt.closeRuntime()
    check rt.animationPumpPending
    check angle(rt)==0
    check rt.pumpAnimations(0).sampledAnimations==1
    discard rt.pumpAnimations(250)
    check angle(rt)==90
    discard rt.pumpAnimations(500)
    check angle(rt)==180
    discard rt.pumpAnimations(750)
    check angle(rt)==270
    discard rt.pumpAnimations(1000)
    check angle(rt)==360 or angle(rt)==0
    let p=normalizeProps(rt.find("spin").node)
    check p.layout.width.get.value==16
    check p.layout.height.get.value==16
    check p.standardUi.get.role==UiRole.spinner

  test "reduced motion requests no frame and hidden elapsed time is not replayed":
    let reduced=newRuntime(componentApplication(standard.spinner(label="Loading",key="spin"),"Reduced").withMotionPolicy(MotionPolicy.reduced))
    check not reduced.animationPumpPending
    discard reduced.pumpAnimations(10000)
    check angle(reduced)==0
    reduced.closeRuntime()
    let rt=newRuntime(componentApplication(standard.spinner(label="Loading",key="spin"),"Hidden"))
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(250)
    discard rt.pumpAnimations(250,visible=false)
    discard rt.pumpAnimations(8000,visible=false)
    check angle(rt)==90
    discard rt.pumpAnimations(8250)
    check angle(rt)==90
    rt.closeRuntime()
    check not rt.animationPumpPending

  test "accessible label is required non-empty and standard rotation metadata cannot be sanitized":
    expect UiError:discard standard.spinner(label="")
    for value in ["bad","NaN","-1","361","90.5"]:
      for policy in [nativeStrict,hostCompatible]:
        expect UiError:discard normalizeHostProps(core.ui(NodeKind.tag,text="Loading",
          attributes=style({"ui_role":"spinner","ui_angle":value})),policy)
    for policy in [nativeStrict,hostCompatible]:
      expect UiError:discard normalizeHostProps(core.ui(NodeKind.tag,text="Loading",
        attributes=style({"ui_role":"kbd","ui_angle":"180"})),policy)
      expect UiError:discard normalizeHostProps(core.ui(NodeKind.tag,text="Loading",
        attributes=style({"ui_role":"spinner"})),policy)
      expect UiError:discard normalizeHostProps(core.ui(NodeKind.tag,text="",
        attributes=style({"ui_role":"spinner","ui_angle":"0"})),policy)

  test "failed animation candidate preserves accepted angle then catches up":
    let rt=newRuntime(componentApplication(standard.spinner(label="Loading",key="spin"),"Reject"))
    defer:rt.closeRuntime()
    discard rt.pumpAnimations(0)
    rt.setValidator(proc(s:Snapshot)=
      if normalizeProps(s.root.node).standardUi.get.angleDegrees.get==180:
        raise newException(UiError,"reject spin"))
    expect UiError:discard rt.pumpAnimations(500)
    check angle(rt)==0
    discard rt.pumpAnimations(750)
    check angle(rt)==270

  test "unmounting releases animation demand and remount creates a fresh sample":
    let Demo=defineComponent[int,State[bool]]("SpinnerLifecycleTest",
      proc(ctx:MountContext,p:int):State[bool]=ctx.state(true),
      proc(ctx:ComponentContext,p:int,show:State[bool]):UiDescription=
        var kids= @[host(standard.button("toggle",key="toggle",onClick=proc(e:Event)=
          discard show.update(proc(old:bool):bool=not old)))]
        if ctx.value(show):kids.add(standard.spinner(label="Loading",key="spin"))
        hostShell(column(@[]),kids))
    let rt=newRuntime(componentApplication(component(Demo,0),"Lifecycle"))
    defer:rt.closeRuntime()
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(250)
    check angle(rt)==90
    discard rt.dispatch("toggle",Event(kind:click))
    check not rt.animationPumpPending
    check rt.pumpAnimations(10000).sampledAnimations==0
    discard rt.dispatch("toggle",Event(kind:click))
    check rt.animationPumpPending
    check angle(rt)==0
    discard rt.pumpAnimations(20000)
    check angle(rt)==0

  test "spinner is not an action, container or childless empty text":
    for n in [core.ui(NodeKind.tag,text="Loading",disabled=true,attributes=style({"ui_role":"spinner","ui_angle":"0"}))]:
      for policy in [nativeStrict,hostCompatible]:
        expect UiError:discard normalizeHostProps(n,policy)
    expect UiError:
      discard core.ui(NodeKind.tag,text="Loading",children= @[core.ui(NodeKind.text,text="child")],attributes=style({"ui_role":"spinner","ui_angle":"0"}))
    expect UiError:
      discard core.ui(NodeKind.tag,text="Loading",attributes=style({"ui_role":"spinner","ui_angle":"0"}),onClick=proc(e:Event)=discard)
