import std/strutils
import leaf

type EditMode = enum echoValue, rejectValue, trimValue

type FormModel = object
  name: string
  notifications: bool
  count: int
  reset: uint64
  mode: EditMode
  conflictMode, invalidCandidate: bool

proc updated(m: FormModel, f: proc(v: FormModel): FormModel): FormModel = f(m)

let NativeForms = defineComponent[int, State[FormModel]]("ExampleNativeForms",
  proc(ctx: MountContext, p: int): State[FormModel] =
    ctx.state(FormModel(name: "Leaf 原生控件 😀", notifications: true)),
  proc(ctx: ComponentContext, p: int, model: State[FormModel]): UiDescription =
    let m = ctx.value(model)
    let body = column(@[
      text("Windows 原生表单", key="title"),
      text("输入模式：" & $m.mode, key="mode"),
      input(m.name, key="name", placeholder="输入中文、日文或 emoji", resetToken=m.reset,
        onChange=(proc(e: Event) =
          if m.conflictMode and e.composition in {compositionStart, compositionUpdate, compositionResult}:
            discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
              result = x; result.name = "组合期间的模型冲突值"))
          elif m.mode == echoValue:
            discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
              result = x; result.name = e.value))
          elif m.mode == trimValue:
            discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
              result = x; result.name = e.value.strip()))),
        onSubmit=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; inc result.count)))),
      switch("接收通知", m.notifications, key="notifications",
        onChange=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.notifications = e.checked)))),
      switch("组合期间更新冲突模型", m.conflictMode, key="conflict",
        onChange=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.conflictMode = e.checked)))),
      row(@[
        button("保存", key="save", onClick=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; inc result.count)))),
        button("重置输入", key="reset", onClick=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.name = "Leaf 原生控件 😀"; inc result.reset)))),
        button("切换输入模式", key="nextMode", onClick=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.mode = (if x.mode == trimValue: echoValue else: succ(x.mode))))))],
        key="actions", styles=style({"gap": "12"})),
      row(@[
        button("尝试失败候选并重置", key="failCandidate", onClick=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.invalidCandidate = true; result.name = "失败候选后的重置值"; inc result.reset)))),
        button("恢复候选", key="recoverCandidate", onClick=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.invalidCandidate = false))))],
        key="failureActions", styles=style({"gap": "12"})),
      text("已提交 " & $m.count & " 次", key="count"),
      text("模型：" & m.name, key="model"),
      text("候选校验探针", key="candidate", styles=style({"width": (if m.invalidCandidate: "-1" else: "auto")})),
      progress(float64(m.count mod 101), key="progress")],
      key="form", styles=style({"padding": "20", "gap": "12", "width": "full"}))
    host(body))

let app = componentApplication(component(NativeForms, 0), "Leaf Native Forms", 640, 640)
quit run(app)
