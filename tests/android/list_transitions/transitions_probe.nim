import leaf/[core, components, component_description, component_state, widgets, managed_runtime, native_ffi]
import leaf/backends/android/ffi
export native_ffi

var factories,initializations,renders,builds,changes,disposals,phase:int
var pageState:State[int]
type RowProps=tuple[id:int]
let Row=defineComponent[RowProps,State[bool]]("TransitionRow",
  proc(ctx:MountContext,p:RowProps):State[bool] = ctx.state(false),
  proc(ctx:ComponentContext,p:RowProps,s:State[bool]):UiDescription =
    let expanded=ctx.value(s)
    let height=(if p.id mod 2==1:96 else:48)+(if expanded:48 else:0)
    host(column(@[button("行 " & $p.id & " 中文😀 " & (if expanded:"大" else:"原"),
      key="action",styles=style({"width":"full","height":"full"}),
      onClick=proc(e:Event) =
        inc changes
        discard s.update(proc(v:bool):bool=not v))],key="row",
      styles=style({"height": $height,"width":"full"}))))

proc application():Application =
  inc factories
  let Page=defineComponent[int,State[int]]("AndroidTransitions",
    proc(ctx:MountContext,p:int):State[int] =
      inc initializations
      ctx.onDispose(proc(e:LifecycleContext) = inc disposals)
      result=ctx.state(0)
      pageState=result,
    proc(ctx:ComponentContext,p:int,s:State[int]):UiDescription =
      inc renders
      phase=ctx.value(s)
      var ids:seq[int]
      case phase
      of 1:
        for i in countdown(19,0):ids.add(i)
      of 2:ids= @[0,1,2]
      of 3:discard
      else:
        for i in 0..<20:ids.add(i)
      var keys:seq[string]
      for id in ids:keys.add("item-" & $id)
      let list=componentList("list",keys,proc(i:int):UiDescription =
        inc builds
        component(Row,(id:ids[i])),estimatedHeight=48,overscan=1,
        styles=style({"width":"full","height":"192"}))
      hostShell(column(@[],key="page",styles=style({"width":"full"})),@[
        host(button("下个数据源",key="next",styles=style({"height":"48"}),
          onClick=proc(e:Event) = discard s.update(proc(v:int):int=(v+1) mod 5))),list]))
  componentApplication(component(Page,0),"Transitions",300,240)
registerAndroidApplication(application)
proc leaf_transitions_probe*(which:cint):cint {.exportc,dynlib,cdecl,raises:[].} =
  try:
    case which
    of 0:cint(factories)
    of 1:cint(initializations)
    of 2:cint(renders)
    of 3:cint(builds)
    of 4:cint(changes)
    of 5:cint(disposals)
    of 6:cint(pageState.read())
    else: -1
  except Exception: -2
