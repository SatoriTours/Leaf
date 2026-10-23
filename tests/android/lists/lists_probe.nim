import leaf/[core, components, component_description, widgets, managed_runtime, native_ffi]
import leaf/backends/android/ffi
export native_ffi

var factories,initializations,renders,builds,clicks,disposals:int
proc application():Application =
  inc factories
  var items:seq[string]
  for i in 0..<100_000:items.add("item-" & $i)
  let list=virtualList("list",items,proc(index:int):Node =
    inc builds
    column(@[button("行 " & $index & " 中文😀",key="action",onClick=proc(e:Event) = inc clicks)],
      key="row"),rowHeight=48,overscan=1,
      styles=style({"width":"full","height":"192"}))
  let Page=defineComponent[int,int]("AndroidLists",
    proc(ctx:MountContext,p:int):int =
      inc initializations
      ctx.onDispose(proc(e:LifecycleContext) = inc disposals)
      0,
    proc(ctx:ComponentContext,p:int,m:int):UiDescription =
      inc renders
      host(list))
  componentApplication(component(Page,0),"Lists",300,192)
registerAndroidApplication(application)
proc leaf_lists_probe*(which:cint):cint {.exportc,dynlib,cdecl,raises:[].} =
  case which
  of 0:cint(factories)
  of 1:cint(initializations)
  of 2:cint(renders)
  of 3:cint(builds)
  of 4:cint(clicks)
  of 5:cint(disposals)
  else: -1
