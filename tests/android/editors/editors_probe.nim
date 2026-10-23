import leaf/[core, components, component_description, component_state, widgets, managed_runtime, native_ffi]
import leaf/backends/android/ffi
export native_ffi

type Model=tuple[value:State[string],ticks:State[int],reset:State[uint64]]
var model:Model
var factories,initializations,changes,submits,disposals:int
proc application():Application =
  inc factories
  let Page=defineComponent[int,Model]("AndroidEditors",
    proc(ctx:MountContext,p:int):Model =
      inc initializations
      result=(ctx.state("seed"),ctx.state(0),ctx.state(0'u64))
      model=result
      ctx.onDispose(proc(e:LifecycleContext) = inc disposals),
    proc(ctx:ComponentContext,p:int,m:Model):UiDescription =
      host(column(@[
        text("Leaf · 受控输入 " & $ctx.value(m.ticks),key="title"),
        input(ctx.value(m.value),key="editor",placeholder="中文 / emoji",
          resetToken=ctx.value(m.reset),
          onChange=proc(e:Event) =
            inc changes
            if e.composition==compositionNone and e.value!="reject": discard m.value.set(e.value),
          onSubmit=proc(e:Event) = inc submits),
        button("模型更新",key="model",variant="default",onClick=proc(e:Event) = discard m.value.set("MODEL")),
        button("无关更新",key="unrelated",variant="default",onClick=proc(e:Event) = discard m.ticks.update(proc(x:int):int=x+1)),
        button("重置",key="reset",variant="default",onClick=proc(e:Event) =
          discard m.value.set("RESET😀")
          discard m.reset.update(proc(x:uint64):uint64=x+1))],key="root",
          styles=style({"padding":"20","gap":"12","width":"full"}))))
  componentApplication(component(Page,0),"Editors",400,600)
registerAndroidApplication(application)
proc leaf_editors_probe*(which:cint):cint {.exportc,dynlib,cdecl,raises:[].} =
  try:
    case which
    of 0:cint(factories)
    of 1:cint(initializations)
    of 2:cint(changes)
    of 3:cint(submits)
    of 4:cint(disposals)
    else: -1
  except Exception: -2
