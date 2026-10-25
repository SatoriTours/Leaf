import std/strutils
import leaf
import ./model

proc updated(m: FormModel, f: proc(v: FormModel): FormModel): FormModel = f(m)

proc modeLabel(mode: EditMode): string =
  case mode
  of echoValue: "即时回写"
  of rejectValue: "拒绝更改"
  of trimValue: "去除首尾空格"

let compactAction = style({"width": "96", "height": "32"})
let auxiliaryAction = style({"height": "32"})
const formTheme = when defined(leafSystemTheme): systemTheme
                  elif defined(leafDarkTheme): matsuDark
                  else: matsuLight

let NativeForms = defineComponent[int, State[FormModel]]("ExampleNativeForms",
  proc(ctx: MountContext, p: int): State[FormModel] =
    ctx.state(FormModel(name: "Leaf 原生控件 😀", notifications: true)),
  proc(ctx: ComponentContext, p: int, model: State[FormModel]): UiDescription =
    let m = ctx.value(model)
    let body = column(@[
      text("Windows 原生表单", key="title", variant="primary"),
      text("真实系统控件 · 草稿保留 · 键盘可操作", key="description", variant="secondary"),
      text("显示名称 · " & m.mode.modeLabel, key="mode"),
      input(m.name, key="name", placeholder="输入中文、日文或 emoji", resetToken=m.reset,
        variant=(if m.nameInvalid: "danger" else: "default"),
        styles=style({"width": "full", "height": "40"}),
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
        onSubmit=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = v.saveForm()))),
      text((if m.nameInvalid: "显示名称不能为空，请输入后重试。" else: "支持中文与 emoji；保存仅记录本页状态。"),
        key="nameHint", variant=(if m.nameInvalid: "danger" else: "secondary"),
        styles=style({"height":"32"})),
      switch("接收通知", m.notifications, key="notifications",
        onChange=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.notifications = e.checked)))),
      switch("组合期间更新冲突模型", m.conflictMode, key="conflict",
        onChange=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.conflictMode = e.checked)))),
      row(@[
        button("保存", key="save", styles=compactAction, onClick=(proc(e: Event) =
          discard model.update(proc(v: FormModel): FormModel = v.saveForm()))),
        button("重置输入", key="reset", styles=compactAction, variant="secondary", onClick=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.name = "Leaf 原生控件 😀"; result.attempted = false; inc result.reset)))),
        button("切换输入模式", key="nextMode", styles=auxiliaryAction, variant="secondary", onClick=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.mode = (if x.mode == trimValue: echoValue else: succ(x.mode))))))],
        key="actions", styles=style({"gap": "8"})),
      row(@[
        button("尝试失败候选并重置", key="failCandidate", styles=auxiliaryAction, variant="secondary", onClick=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.invalidCandidate = true; result.name = "失败候选后的重置值"; inc result.reset)))),
        button("恢复候选", key="recoverCandidate", styles=auxiliaryAction, variant="secondary", onClick=(proc(e: Event) = discard model.update(proc(v: FormModel): FormModel = updated(v, proc(x: FormModel): FormModel =
          result = x; result.invalidCandidate = false))))],
        key="failureActions", styles=style({"gap": "8"})),
      text("已提交 " & $m.count & " 次 · " &
        (if m.nameInvalid: "尚未保存，请补全名称"
         elif not m.formDirty: "当前状态已记录"
         elif m.hasSaved: "更改尚未保存" else: "尚未提交"), key="count"),
      text("模型：" & m.name, key="model", variant="secondary"),
      text("候选校验探针", key="candidate", styles=style({"width": (if m.invalidCandidate: "-1" else: "auto")})),
      progress(float64(m.count mod 101), key="progress")],
      key="form", styles=style({"padding": "24", "gap": "8", "width": "full"}))
    host(body))

let app = componentApplication(component(NativeForms, 0), "Leaf Native Forms", 640, 720)
  .withNativeTheme(formTheme)
quit run(app)
