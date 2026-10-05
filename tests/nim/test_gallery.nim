import std/[unittest, tables]
import leaf
import ../../example/main

proc click(runtime: Runtime, key: string) = discard runtime.dispatch(key, Event(kind: click))
proc change(runtime: Runtime, key, value: string) = discard runtime.dispatch(key, Event(kind: change, value: value))
proc checked(runtime: Runtime, key: string, value: bool) = discard runtime.dispatch(key, Event(kind: change, checked: value))
proc enter(runtime: Runtime, key: string) = discard runtime.dispatch(key, Event(kind: submit))
proc value(runtime: Runtime, key: string): string = runtime.find(key).node.text
proc disabled(runtime: Runtime, key: string): bool = runtime.find(key).node.disabled

suite "Seven-page Nim application UI behavior":
  test "dashboard changes period and refreshes data":
    let rt = newRuntime(galleryApp())
    rt.click("period_month"); rt.click("refresh")
    check rt.value("metric_value_0") == "487"
    check rt.value("period_label") == "本月"
    check rt.find("goal_progress").node.attributes["value"] == "84.0"
  test "project search and empty state":
    let rt = newRuntime(galleryApp())
    rt.change("project_search", "林晓")
    check rt.value("dashboard_status") == "已刷新 0 次 · 筛选后 2 个项目"
    rt.change("project_search", "不存在的项目")
    check rt.value("project_empty") == "没有匹配的项目，试试其他关键词。"
  test "task Enter trims and navigation retains task state":
    let rt = newRuntime(galleryApp())
    rt.click("nav_board"); rt.change("task_draft", "  中文输入测试  "); rt.enter("task_draft")
    rt.click("nav_dashboard"); rt.click("nav_board")
    check rt.value("task_title_7") == "中文输入测试"
    check rt.value("task_draft") == ""
    check rt.value("board_summary") == "共 7 项 · 已完成 2 项"
    check rt.disabled("task_add")
  test "whitespace task is disabled and Enter adds nothing":
    let rt = newRuntime(galleryApp("board"))
    rt.change("task_draft", "   "); rt.enter("task_draft")
    check rt.disabled("task_add")
    check rt.value("board_summary") == "共 6 项 · 已完成 2 项"
  test "task advances through three lanes":
    let rt = newRuntime(galleryApp("board"))
    rt.click("advance_1"); rt.click("advance_1")
    check rt.find("tasks_done").children[0].children[1].node.text == "整理首页信息架构"
    rt.click("advance_1")
    check rt.find("tasks_todo").children[0].children[1].node.text == "整理首页信息架构"
  test "deleting every task handles empty progress":
    let rt = newRuntime(galleryApp("board"))
    for i in 1..6: rt.click("delete_" & $i)
    check rt.value("board_summary") == "共 0 项 · 已完成 0 项"
    check rt.find("board_progress").node.attributes["value"] == "0.0"
    check rt.value("empty_todo") == "这里还没有任务"
  test "hiding completed tasks preserves their data":
    let rt = newRuntime(galleryApp("board"))
    rt.checked("hide_completed", true)
    check rt.value("empty_done") == "已完成任务已隐藏"
    expect UiError: discard rt.find("task_title_5")
    check rt.value("board_summary") == "共 6 项 · 已完成 2 项"
    rt.checked("hide_completed", false)
    check rt.value("task_title_5") == "确定界面配色"
  test "settings preview and save":
    let rt = newRuntime(galleryApp("settings"))
    rt.change("settings_name", "新名字")
    check rt.value("preview_name") == "新名字"
    check not rt.disabled("settings_save")
    rt.click("settings_save")
    check rt.value("settings_dirty") == "已保存"
    check rt.disabled("settings_save")
    check rt.value("settings_message") == "设置已保存（本次运行内有效）。"
  test "cancel restores last saved settings":
    let rt = newRuntime(galleryApp("settings"))
    rt.change("settings_name", "保存的名字"); rt.click("settings_save")
    rt.change("settings_name", "未保存的名字"); rt.checked("settings_notifications", false); rt.click("settings_cancel")
    check rt.value("settings_name") == "保存的名字"
    check rt.find("settings_notifications").node.attributes["checked"] == "true"
    check rt.disabled("settings_cancel")
  test "invalid settings remain dirty":
    let rt = newRuntime(galleryApp("settings"))
    rt.change("settings_email", "not-an-email"); rt.click("settings_save")
    check rt.value("settings_dirty") == "有未保存的修改"
    check rt.value("settings_message") == "请填写姓名、团队和有效的邮箱地址。"
  test "notifications control digest availability":
    let rt = newRuntime(galleryApp("settings"))
    rt.checked("settings_notifications", false)
    check rt.disabled("settings_digest")
    check rt.disabled("settings_plan")
  test "sync starts spinner and finishes with count":
    let rt = newRuntime(galleryApp("settings"))
    rt.click("sync_start")
    check rt.find("sync_spinner").node.kind == NodeKind.spinner
    rt.click("sync_finish")
    check rt.value("sync_status") == "同步完成"
    check rt.value("sync_count") == "已完成 1 次同步"
  test "signup acceptance and individual validation":
    let rt = newRuntime(galleryApp("signup"))
    check rt.disabled("signup_submit")
    rt.checked("signup_accept", true); rt.click("signup_submit")
    check rt.value("error_signup_name") == "请填写姓名。"
    check rt.value("error_signup_email") == "请输入有效的邮箱地址。"
    check rt.value("error_signup_workspace") == "请填写工作区名称。"
  test "signup success returns to populated form":
    let rt = newRuntime(galleryApp("signup"))
    rt.click("signup_demo"); rt.checked("signup_accept", true); rt.enter("signup_workspace")
    check rt.value("created_workspace") == "设计实验室"
    rt.click("signup_back")
    check rt.value("signup_email") == "linxiao@example.com"
    check rt.value("signup_workspace") == "设计实验室"
  test "selected period and status badges follow page state":
    let rt = newRuntime(galleryApp())
    check rt.find("period_week").node.attributes["variant"] == "primary"
    check rt.find("period_month").node.attributes["variant"] == "outline"
    rt.click("period_month")
    check rt.find("period_week").node.attributes["variant"] == "outline"
    rt.click("nav_board")
    check rt.find("task_1").children[2].node.attributes["variant"] == "warning"
    check rt.find("task_3").children[2].node.attributes["variant"] == "info"
    check rt.find("task_5").children[2].node.attributes["variant"] == "success"
    rt.click("nav_settings")
    check rt.find("settings_dirty").node.attributes["variant"] == "success"
    rt.change("settings_name", "修改")
    check rt.find("settings_dirty").node.attributes["variant"] == "warning"
    check rt.find("sync_status").node.attributes["variant"] == "secondary"
    rt.click("sync_start"); rt.click("sync_finish")
    check rt.find("sync_status").node.attributes["variant"] == "success"
  test "scroll pages preserve their minimum content heights":
    let rt = newRuntime(galleryApp())
    for (id, height) in [("dashboard", "1060"), ("board", "720"), ("settings", "850"),
      ("signup", "700"), ("stocks", "1030"), ("reports", "1260"), ("chat", "870")]:
      rt.click("nav_" & id)
      check rt.find("page_content").node.styles["min_height"] == height
