import std/strutils
import ../ui
type Signup* = ref object
  name, email, workspace: string
  accepted, attempted, created: bool
proc newSignup*(): Signup = Signup()
proc submit(state: Signup) =
  state.attempted = true
  if not state.accepted or state.name.strip.len == 0 or not validEmail(state.email) or state.workspace.strip.len == 0: return
  state.name = state.name.strip; state.email = state.email.strip; state.workspace = state.workspace.strip; state.created = true
proc field(state: Signup, label, key, value, placeholder, error: string, change: Callback): Node =
  var children = @[ui.label(label), input(value, key = key, placeholder = placeholder, onChange = change, onSubmit = proc(e: Event) = state.submit())]
  if state.attempted and error.len > 0: children.add(text(error, "error_" & key, style({"color": "#FCA5A5", "font_size": "12"})))
  stack(children, "field_" & key, gap = 8)
proc render*(state: Signup, ctx: BuildContext): Node =
  var form: seq[Node]
  if state.created:
    form = @[tag("创建成功", variant = "success"), title("欢迎，" & state.name, size = 28), title(state.workspace, "created_workspace", 22),
      label("联系邮箱：" & state.email), label("这是本地演示，未发送邮件或创建在线账号。"),
      button("返回表单", key = "signup_back", onClick = proc(e: Event) = state.created = false; state.attempted = false)]
  else:
    form = @[title("开始你的协作空间", size = 22), label("填写以下信息，预览注册流程。"),
      state.field("姓名", "signup_name", state.name, "如何称呼你？", (if state.name.strip.len == 0: "请填写姓名。" else: ""), proc(e: Event) = state.name = e.value),
      state.field("邮箱", "signup_email", state.email, "name@example.com", (if validEmail(state.email): "" else: "请输入有效的邮箱地址。"), proc(e: Event) = state.email = e.value),
      state.field("工作区名称", "signup_workspace", state.workspace, "例如：设计实验室", (if state.workspace.strip.len == 0: "请填写工作区名称。" else: ""), proc(e: Event) = state.workspace = e.value),
      checkbox("我已了解并同意演示使用条款", state.accepted, key = "signup_accept", onChange = proc(e: Event) = state.accepted = e.checked)]
    if state.attempted and not state.accepted: form.add(text("请先同意演示使用条款。", "error_signup_accept"))
    form.add(button("创建工作区", key = "signup_submit", disabled = not state.accepted, onClick = proc(e: Event) = state.submit()))
    form.add(button("填入示例信息", key = "signup_demo", variant = "ghost", onClick = proc(e: Event) =
      state.name = "林晓"; state.email = "linxiao@example.com"; state.workspace = "设计实验室"; state.attempted = false))
    form.add(separator()); form.add(label("无需密码，所有信息仅用于本地界面演示。"))
  page("创建工作区", "一个常见的注册与引导页面，包含逐项校验和成功反馈。", @[
    line(@[card(@[tag("STUDIO / START", variant = "success"), title("让想法\n变成作品。", size = 36),
      text("把团队、任务和灵感放在一起，开始一段更专注的协作。"), separator(),
      title("01 / 清晰的项目视图"), label("从全局进展到每一项任务。"), title("02 / 恰到好处的通知"), label("让信息跟上你的工作节奏。"),
      title("03 / 属于团队的空间"), label("为下一件好作品留出位置。")], "signup_intro", style({"width": "310", "background": "#123639"})),
      card(form, "signup_form", grow())])], height = (if state.attempted and not state.created: 760 else: 700))
