import std/[unittest,options]
import leaf
import leaf/[styles,host_protocol]
import leaf/ui as standard

proc opacity(rt:Runtime):int=normalizeProps(rt.find("shape").node).standardUi.get.opacityPermille.get

suite "managed standard Skeleton":
  test "pulse runs on accepted Runtime time and returns after a two-second cycle":
    let rt=newRuntime(componentApplication(standard.skeleton(160,24,key="shape"),"Skeleton"))
    defer:rt.closeRuntime()
    check rt.animationPumpPending
    check opacity(rt)==1000
    check rt.pumpAnimations(0).sampledAnimations==1
    discard rt.pumpAnimations(500)
    check opacity(rt)==750
    discard rt.pumpAnimations(1000)
    check opacity(rt)==500
    discard rt.pumpAnimations(2000)
    check opacity(rt)==1000
    let p=normalizeProps(rt.find("shape").node)
    check p.layout.width.get.value==160
    check p.layout.height.get.value==24
    check p.standardUi.get.role==UiRole.skeleton

  test "reduced motion requests no frame and hidden elapsed time is not replayed":
    let reduced=newRuntime(componentApplication(standard.skeleton(160,24,key="shape"),"Reduced").withMotionPolicy(MotionPolicy.reduced))
    check not reduced.animationPumpPending
    discard reduced.pumpAnimations(10000)
    check opacity(reduced)==1000
    reduced.closeRuntime()
    let rt=newRuntime(componentApplication(standard.skeleton(160,24,key="shape"),"Hidden"))
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(500)
    discard rt.pumpAnimations(500,visible=false)
    discard rt.pumpAnimations(8000,visible=false)
    check opacity(rt)==750
    discard rt.pumpAnimations(9000)
    check opacity(rt)==750
    rt.closeRuntime()
    check not rt.animationPumpPending

  test "geometry is finite positive and standard pulse metadata cannot be sanitized":
    for size in [0.0,-1.0,Inf,NaN,1000001.0]:
      expect UiError:discard standard.skeleton(size,24)
      expect UiError:discard standard.skeleton(160,size)
    for value in ["bad","NaN","499","1001","750.5"]:
      for policy in [nativeStrict,hostCompatible]:
        expect UiError:discard normalizeHostProps(core.ui(NodeKind.tag,
          attributes=style({"ui_role":"skeleton","ui_opacity":value})),policy)
    for policy in [nativeStrict,hostCompatible]:
      expect UiError:discard normalizeHostProps(core.ui(NodeKind.tag,
        attributes=style({"ui_role":"kbd","ui_opacity":"750"})),policy)
      expect UiError:discard normalizeHostProps(core.ui(NodeKind.tag,
        attributes=style({"ui_role":"skeleton"})),policy)

  test "failed animation candidate preserves accepted opacity then catches up":
    let rt=newRuntime(componentApplication(standard.skeleton(160,24,key="shape"),"Reject"))
    defer:rt.closeRuntime()
    discard rt.pumpAnimations(0)
    rt.setValidator(proc(s:Snapshot)=
      if normalizeProps(s.root.node).standardUi.get.opacityPermille.get==750:
        raise newException(UiError,"reject pulse"))
    expect UiError:discard rt.pumpAnimations(500)
    check opacity(rt)==1000
    discard rt.pumpAnimations(1000)
    check opacity(rt)==500

  test "unmounting releases animation demand and remount creates a fresh sample":
    let Demo=defineComponent[int,State[bool]]("SkeletonLifecycleTest",
      proc(ctx:MountContext,p:int):State[bool]=ctx.state(true),
      proc(ctx:ComponentContext,p:int,show:State[bool]):UiDescription=
        var kids= @[host(standard.button("toggle",key="toggle",onClick=proc(e:Event)=
          discard show.update(proc(old:bool):bool=not old)))]
        if ctx.value(show):kids.add(standard.skeleton(160,24,key="shape"))
        hostShell(column(@[]),kids))
    let rt=newRuntime(componentApplication(component(Demo,0),"Lifecycle"))
    defer:rt.closeRuntime()
    discard rt.pumpAnimations(0)
    discard rt.pumpAnimations(1000)
    check opacity(rt)==500
    discard rt.dispatch("toggle",Event(kind:click))
    check not rt.animationPumpPending
    check rt.pumpAnimations(10000).sampledAnimations==0
    discard rt.dispatch("toggle",Event(kind:click))
    check rt.animationPumpPending
    check opacity(rt)==1000
    discard rt.pumpAnimations(20000)
    check opacity(rt)==1000

  test "skeleton is not an action, text or container":
    for n in [core.ui(NodeKind.tag,text="bad",attributes=style({"ui_role":"skeleton","ui_opacity":"750"})),
      core.ui(NodeKind.tag,disabled=true,attributes=style({"ui_role":"skeleton","ui_opacity":"750"}))]:
      for policy in [nativeStrict,hostCompatible]:
        expect UiError:discard normalizeHostProps(n,policy)
    expect UiError:
      discard core.ui(NodeKind.tag,attributes=style({"ui_role":"skeleton","ui_opacity":"750"}),onClick=proc(e:Event)=discard)
