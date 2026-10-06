import std/strutils
import ../ui
type
  Signup* = ref object
    name, email, workspace: string
    accepted, attempted, created: bool
proc newSignup*(): Signup =
  Signup()

proc submit(state: Signup) =
  state.attempted = true
  if not state.accepted or state.name.strip.len == 0 or
      not validEmail(state.email) or
      state.workspace.strip.len == 0:
    return
  state.name = state.name.strip
  state.email = state.email.strip
  state.workspace = state.workspace.strip
  state.created = true

proc field(state: Signup; label, key, value, placeholder, error: string;
           change: Callback): Node =
  var children = views:
    ui.label(label)
    input(value):
      key: key
      placeholder: placeholder
      onChange: change
      onSubmit(e): state.submit()
  if state.attempted and error.len > 0:
    let fieldError = view:
      text(error):
        key: "error_" & key
        styles: {"color": "#FCA5A5", "font_size": "12"}
    children.add(fieldError)
  view:
    stack:
      key: "field_" & key
      gap: 8
      children: children

proc render*(state: Signup; ctx: BuildContext): Node =
  var form: seq[Node]
  if state.created:
    form = views:
      tag("创建成功"):
        variant: "success"
      title("欢迎，" & state.name):
        size: 28
      title(state.workspace):
        key: "created_workspace"
        size: 22
      label("联系邮箱：" & state.email)
      label("这是本地演示，未发送邮件或创建在线账号。")
      button("返回表单"):
        key: "signup_back"
        onClick(e):
          state.created = false
          state.attempted = false
  else:
    proc changeName(e: Event) =
      state.name = e.value

    proc changeEmail(e: Event) =
      state.email = e.value

    proc changeWorkspace(e: Event) =
      state.workspace = e.value

    form = views:
      title("开始你的协作空间"):
        size: 22
      label("填写以下信息，预览注册流程。")
      state.field("姓名", "signup_name", state.name, "如何称呼你？", (if state.name.strip.len == 0: "请填写姓名。" else: ""), changeName)
      state.field("邮箱", "signup_email", state.email, "name@example.com", (if validEmail(state.email): "" else: "请输入有效的邮箱地址。"), changeEmail)
      state.field("工作区名称", "signup_workspace", state.workspace, "例如：设计实验室", (if state.workspace.strip.len == 0: "请填写工作区名称。" else: ""), changeWorkspace)
      checkbox("我已了解并同意演示使用条款", state.accepted):
        key: "signup_accept"
        onChange(e): state.accepted = e.checked
    if state.attempted and not state.accepted:
      let termsError = view:
        text("请先同意演示使用条款。"):
          key: "error_signup_accept"
      form.add(termsError)
    let submitButton = view:
      button("创建工作区"):
        key: "signup_submit"
        disabled: not state.accepted
        onClick(e): state.submit()
    form.add(submitButton)
    let demoButton = view:
      button("填入示例信息"):
        key: "signup_demo"
        variant: "ghost"
        onClick(e):
          state.name = "林晓"
          state.email = "linxiao@example.com"
          state.workspace = "设计实验室"
          state.attempted = false
    form.add(demoButton)
    let divider = view:
      separator()
    form.add(divider)
    let hint = view:
      label("无需密码，所有信息仅用于本地界面演示。")
    form.add(hint)
  view:
    page("创建工作区", "一个常见的注册与引导页面，包含逐项校验和成功反馈。"):
      height: (if state.attempted and not state.created: 760 else: 700)
      line:
        card:
          key: "signup_intro"
          styles: {"width": "310", "background": "#123639"}
          tag("STUDIO / START"):
            variant: "success"
          title("让想法\n变成作品。"):
            size: 36
          text("把团队、任务和灵感放在一起，开始一段更专注的协作。")
          separator()
          title("01 / 清晰的项目视图")
          label("从全局进展到每一项任务。")
          title("02 / 恰到好处的通知")
          label("让信息跟上你的工作节奏。")
          title("03 / 属于团队的空间")
          label("为下一件好作品留出位置。")
        card:
          key: "signup_form"
          styles: grow()
          children: form
