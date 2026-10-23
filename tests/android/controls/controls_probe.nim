import leaf/[core, components, component_description, component_state, widgets,
  managed_runtime, native_ffi]
import leaf/backends/android/ffi
export native_ffi

type Model=tuple[checked:State[bool],amount:State[float64]]
var factories,initializations,changes,rejections,disabledChanges,disposals:int
proc application():Application =
  inc factories
  let Page=defineComponent[int,Model]("AndroidControls",
    proc(ctx:MountContext,p:int):Model =
      inc initializations
      result=(ctx.state(false),ctx.state(42.5))
      ctx.onDispose(proc(e:LifecycleContext) = inc disposals),
    proc(ctx:ComponentContext,p:int,m:Model):UiDescription =
      host(column(@[
        text("Leaf · 原生控件 中文😀",key="title"),
        checkbox("接受",ctx.value(m.checked),key="check",onChange=proc(e:Event) =
          inc changes
          discard m.checked.set(e.checked)),
        switch("同步开关",ctx.value(m.checked),key="toggle",onChange=proc(e:Event) =
          inc changes
          discard m.checked.set(e.checked)),
        checkbox("拒绝",false,key="reject",onChange=proc(e:Event) = inc rejections),
        checkbox("禁用",false,key="disabled",disabled=true,
          onChange=proc(e:Event) = inc disabledChanges),
        progress(ctx.value(m.amount),key="progress"),
        spinner(key="spinner",styles=style({"width":"40","height":"40"})),
        tag("标签 中文😀",key="tag"),
        separator(key="separator",styles=style({"height":"2","width":"full"})),
        button("程序更新",key="model",variant="default",onClick=proc(e:Event) =
          discard m.checked.update(proc(old:bool):bool=not old)
          discard m.amount.set(77.25))],key="root",
            styles=style({"padding":"20","gap":"10","width":"full"}))))
  componentApplication(component(Page,0),"Controls",400,700)
registerAndroidApplication(application)
proc leaf_controls_probe*(which:cint):cint {.exportc,dynlib,cdecl,raises:[].} =
  case which
  of 0:cint(factories)
  of 1:cint(initializations)
  of 2:cint(changes)
  of 3:cint(rejections)
  of 4:cint(disabledChanges)
  of 5:cint(disposals)
  else: -1
