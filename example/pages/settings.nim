import std/strutils
import ../ui
type
  Profile = object
    name, email, team: string
    notifications, digest: bool
  Settings* = ref object
    current, saved: Profile
    message: string
    invalid, syncing: bool
    syncCount: int
proc newSettings*(): Settings =
  let profile = Profile(name: "林晓", email: "linxiao@example.com",
                        team: "设计与产品团队", notifications: true)
  Settings(current: profile, saved: profile)

proc edited(state: Settings) =
  state.message = ""
  state.invalid = false

proc save(state: Settings) =
  if state.current.name.strip.len == 0 or state.current.team.strip.len == 0 or
      not validEmail(state.current.email):
    state.invalid = true
    state.message = "请填写姓名、团队和有效的邮箱地址。"
    return
  state.current.name = state.current.name.strip
  state.current.email = state.current.email.strip
  state.current.team = state.current.team.strip
  state.saved = state.current
  state.invalid = false
  state.message = "设置已保存（本次运行内有效）。"

proc render*(state: Settings; ctx: BuildContext): Node =
  let dirty = state.current != state.saved
  var form = views:
    card:
      key: "profile_form"
      line:
        title("基本资料")
        tag((if dirty: "有未保存的修改" else: "已保存")):
          key: "settings_dirty"
          variant: (if dirty: "warning" else: "success")
      separator()
      label("姓名")
      input(state.current.name):
        key: "settings_name"
        onChange(e):
          state.current.name = e.value
          state.edited()
      label("邮箱")
      input(state.current.email):
        key: "settings_email"
        onChange(e):
          state.current.email = e.value
          state.edited()
      label("团队")
      input(state.current.team):
        key: "settings_team"
        onChange(e):
          state.current.team = e.value
          state.edited()
        onSubmit(e): state.save()
      label("当前方案")
      input("Studio / 团队版"):
        key: "settings_plan"
        disabled: true
    card:
      key: "preferences"
      title("通知偏好")
      switch("接收项目通知", state.current.notifications):
        key: "settings_notifications"
        onChange(e):
          state.current.notifications = e.checked
          state.edited()
      checkbox("订阅每周工作摘要", state.current.digest):
        key: "settings_digest"
        disabled: not state.current.notifications
        onChange(e):
          state.current.digest = e.checked
          state.edited()
      label((if state.current.notifications: "每周摘要将发送到你的邮箱。" else: "开启项目通知后，可以修改摘要订阅。"))
    line:
      button("保存设置"):
        key: "settings_save"
        disabled: not dirty
        onClick(e): state.save()
      button("撤销修改"):
        key: "settings_cancel"
        disabled: not dirty
        onClick(e):
          state.current = state.saved
          state.invalid = false
          state.message = "已撤销未保存的修改。"
  if state.message.len > 0:
    let feedback = view:
      text(state.message):
        key: "settings_message"
        styles: {"color": (if state.invalid: "#FCA5A5" else: Accent)}
    form.add(feedback)
  var sync: seq[Node] = views:
    title("工作区同步"):
      size: 17
  if state.syncing:
    let syncIndicator = view:
      line:
        spinner:
          key: "sync_spinner"
        text("模拟同步中…")
    sync.add(syncIndicator)
    let syncProgress = view:
      progress(65):
        key: "sync_progress"
    sync.add(syncProgress)
    let finishSync = view:
      button("完成本次同步"):
        key: "sync_finish"
        onClick(e):
          state.syncing = false
          inc state.syncCount
    sync.add(finishSync)
  else:
    let syncStatus = view:
      tag((if state.syncCount == 0: "等待同步" else: "同步完成")):
        key: "sync_status"
        variant: (if state.syncCount == 0: "secondary" else: "success")
    sync.add(syncStatus)
    let startSync = view:
      button("开始模拟同步"):
        key: "sync_start"
        onClick(e): state.syncing = true
    sync.add(startSync)
  let syncSummary = view:
    label("已完成 " & $state.syncCount & " 次同步"):
      key: "sync_count"
  sync.add(syncSummary)
  view:
    page("个人设置", "管理个人资料与通知偏好，右侧预览会随输入更新。"):
      line:
        stack:
          styles: grow()
          children: form
        stack:
          styles: {"width": "262"}
          card:
            key: "profile_preview"
            title("LX"):
              size: 24
            title((if state.current.name.strip.len == 0: "你的姓名" else: state.current.name)):
              key: "preview_name"
              size: 22
            label(state.current.email):
              key: "preview_email"
            label(state.current.team):
              key: "preview_team"
            tag("团队成员"):
              variant: "info"
            separator()
            label("个人资料预览")
          card:
            key: "sync_panel"
            children: sync
