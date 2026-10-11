import std/strutils
import leaf

type EditMode = enum echoValue, rejectValue, trimValue
var name = "Leaf 原生控件 😀"
var notifications = true
var count = 0
var reset: uint64
var mode = echoValue
var conflictMode, invalidCandidate: bool
proc render(ctx: BuildContext): Node =
  view:
    column(key="form", styles=style({"padding":"20", "gap":"12", "width":"full"})):
      text("Windows 原生表单", key="title")
      text("输入模式：" & $mode, key="mode")
      input(name, key="name", placeholder="输入中文、日文或 emoji", resetToken=reset,
        onChange=proc(e: Event) =
          if conflictMode and e.composition in {compositionStart, compositionUpdate, compositionResult}:
            name = "组合期间的模型冲突值"
          elif mode == echoValue: name = e.value
          elif mode == trimValue: name = e.value.strip(),
        onSubmit=proc(e: Event) = inc count)
      switch("接收通知", notifications, key="notifications", onChange=proc(e: Event) = notifications = e.checked)
      switch("组合期间更新冲突模型", conflictMode, key="conflict", onChange=proc(e: Event) = conflictMode = e.checked)
      row(key="actions", styles=style({"gap":"12"})):
        button("保存", key="save", onClick=proc(e: Event) = inc count)
        button("重置输入", key="reset", onClick=proc(e: Event) =
          name = "Leaf 原生控件 😀"
          inc reset)
        button("切换输入模式", key="nextMode", onClick=proc(e: Event) =
          mode = if mode == trimValue: echoValue else: succ(mode))
      row(key="failureActions", styles=style({"gap":"12"})):
        button("尝试失败候选并重置", key="failCandidate", onClick=proc(e: Event) =
          invalidCandidate = true
          name = "失败候选后的重置值"
          inc reset)
        button("恢复候选", key="recoverCandidate", onClick=proc(e: Event) = invalidCandidate = false)
      text("已提交 " & $count & " 次", key="count")
      text("模型：" & name, key="model")
      text("候选校验探针", key="candidate", styles=style({"width":(if invalidCandidate: "-1" else: "auto")}))
      progress(float64(count mod 101), key="progress")
quit run(Application(title: "Leaf Native Forms", width: 640, height: 640, render: render))
