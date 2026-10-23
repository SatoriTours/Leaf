## Real managed counter; Kotlin never owns the business State or callbacks.
import leaf/[core, components, component_description, component_state, widgets, managed_runtime, native_ffi]
import leaf/backends/android/ffi
export native_ffi
var factories, initializations, disposals: int
var count: State[int]
proc application(): Application =
  inc factories
  let Page = defineComponent[int,State[int]]("AndroidViewsCounter",
    proc(ctx:MountContext,p:int):State[int] =
      inc initializations
      result = ctx.state(0)
      count = result
      ctx.onDispose(proc(event:LifecycleContext) = inc disposals),
    proc(ctx:ComponentContext,p:int,value:State[int]):UiDescription =
      host(column(@[
        text("Leaf · 原生 Views",key="title"),
        text("计数 " & $ctx.value(value) & " · 😀",key="count"),
        button("增加 +1",variant="default",key="increment",
          onClick=proc(event:Event) = discard value.update(proc(old:int):int = old+1))],
        key="root",styles=style({"padding":"24","gap":"16","width":"full"}))))
  componentApplication(component(Page,0),"Leaf Views",400,600)
registerAndroidApplication(application)
proc leaf_views_probe*(which:cint):cint {.exportc,dynlib,cdecl,raises:[].} =
  try:
    case which
    of 0: cint(factories)
    of 1: cint(initializations)
    of 2: cint(count.readAccepted())
    of 3: cint(disposals)
    else: -1
  except Exception: -2
