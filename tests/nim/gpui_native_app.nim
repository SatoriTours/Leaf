import leaf
import std/os

type SmokeModel = object
  count: int
  value: string
  submissions: int
  reset: uint64

let Root = defineComponent[int, State[SmokeModel]]("GpuiNativeSmokeRoot",
  proc(ctx: MountContext, p: int): State[SmokeModel] =
    ctx.state(SmokeModel(value: "中文输入")),
  proc(ctx: ComponentContext, p: int, model: State[SmokeModel]): UiDescription =
    let m = ctx.value(model)
    if getEnv("LEAF_TEST_FAIL_LIST")=="1":
      raise newException(UiError,"initial row failed")
    host(column(@[
      input(m.value, key="entry",
        onChange=proc(e:Event) = discard model.update(proc(v: SmokeModel): SmokeModel =
          (result = v; result.value = e.value)),
        onSubmit=(proc(e:Event) = discard model.update(proc(v: SmokeModel): SmokeModel =
          (result = v; inc result.submissions))),
        styles=style({"height":"36","width":"full"}), resetToken=m.reset),
      button("GPUI Kit → Nim", key="add",
        onClick=(proc(e:Event) = discard model.update(proc(v: SmokeModel): SmokeModel =
          (result = v; inc result.count))),
        styles=style({"height":"36","width":"200"})),
      text($m.count & ":" & m.value & ":" & $m.submissions, key="status"),
      button("reset", key="reset", onClick=proc(e:Event) =
        discard model.update(proc(v: SmokeModel): SmokeModel =
          (result = v; result.value = "中文输入"; inc result.reset))),
      button("reject", key="reject", onClick=proc(e:Event)=fail("injected rejection"))
    ], styles=style({"padding":"24","gap":"12","width":"full","height":"full"}))))

let app* = componentApplication(component(Root, 0), "Leaf GPUI native smoke", 640, 480)
when isMainModule: quit(run(app))
