import leaf/[core, components, component_description, component_state, widgets, native_ffi]
import leaf/backends/android/ffi
export native_ffi

var router:ComponentRouter
var factories,disposals:int
var initializations:array[3,int]
var states:array[3,State[int]]
let names=["首页 中文😀","详情 中文😀","第三页 中文😀"]
let Page=defineComponent[int,State[int]]("AndroidNavigationPage",
  proc(ctx:MountContext,index:int):State[int] =
    inc initializations[index]
    result=ctx.state(0)
    states[index]=result,
  proc(ctx:ComponentContext,index:int,s:State[int]):UiDescription =
    host(column(@[
      text(names[index] & " 状态=" & $ctx.value(s),key="content",styles=style({"height":"48"})),
      button("增加状态",key="increment",styles=style({"height":"48"}),
        onClick=proc(e:Event) = discard s.update(proc(v:int):int=v+1)),
      button("打开下一页",key="push",styles=style({"height":"48"}),
        onClick=proc(e:Event) = discard router.push(if index==0:"detail" elif index==1:"third" else:"home"))
    ],key="page",styles=style({"width":"full"}))))
proc application():Application =
  inc factories
  let Root=defineComponent[int,int]("AndroidNavigationRoot",
    proc(ctx:MountContext,p:int):int =
      ctx.onDispose(proc(e:LifecycleContext) = inc disposals)
      router=newComponentRouter(ctx,@[
        Route(name:"home",path:"/",page:"home",view:"main"),
        Route(name:"detail",path:"/detail",page:"detail",view:"main"),
        Route(name:"third",path:"/third",page:"third",view:"main")],@[
        ComponentPageDefinition(name:"home",views: @["main"],build:proc(v:string):UiDescription=component(Page,0)),
        ComponentPageDefinition(name:"detail",views: @["main"],build:proc(v:string):UiDescription=component(Page,1)),
        ComponentPageDefinition(name:"third",views: @["main"],build:proc(v:string):UiDescription=component(Page,2))])
      0,
    proc(ctx:ComponentContext,p,s:int):UiDescription=renderNavigation(ctx,router,key="navigation"))
  componentApplication(component(Root,0),"Navigation",400,600)
registerAndroidApplication(application)
proc leaf_navigation_probe*(which:cint):cint {.exportc,dynlib,cdecl,raises:[].} =
  try:
    case which
    of 0:cint(factories)
    of 1:cint(disposals)
    of 2:cint(router.history.len)
    of 3:cint(initializations[0])
    of 4:cint(initializations[1])
    of 5:cint(initializations[2])
    of 6:cint(states[0].read())
    else: -1
  except Exception: -2
