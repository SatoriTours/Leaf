import ./ui
import ./pages/[dashboard, board, settings, signup, stocks, reports, chat]

type Gallery = ref object
  active: string
  dashboard: Dashboard
  board: Board
  settings: Settings
  signup: Signup
  stocks: Stocks
  reports: Reports
  chat: Chat
proc navigationButton(state: Gallery, id, name: string): Node =
  view:
    button name:
      key: "nav_" & id
      styles: {"width": "full"}
      variant: (if state.active == id: "primary" else: "ghost")
      onClick(e): state.active = id
proc render(state: Gallery, ctx: BuildContext): Node =
  var navigation: seq[Node] = @[title("Leaf / STUDIO", size = 20), label("常用界面试验台"), separator()]
  for (id, name, detail) in [("dashboard", "01  数据概览", "统计卡片 / 图表 / 列表"),
    ("board", "02  任务看板", "多列布局 / 动态列表"), ("settings", "03  个人设置", "输入 / 开关 / 保存"),
    ("signup", "04  注册表单", "校验 / 反馈 / 禁用状态"), ("stocks", "05  股票 K 线", "密集图元 / 盘口 / 逐帧"),
    ("reports", "06  统计报表", "千行数据 / 排序 / 分页"),
    ("chat", "07  即时聊天", "多会话 / 消息气泡 / 历史")]:
    navigation.add(stack(@[state.navigationButton(id, name), label(detail)], "navigation_" & id, 6))
  navigation.add(tag("交互式示例", variant = "success")); navigation.add(label("Nim 状态 · 原生组件")); navigation.add(label("所有数据仅在内存中保存"))
  let content = case state.active
    of "dashboard": state.dashboard.render(ctx)
    of "board": state.board.render(ctx)
    of "settings": state.settings.render(ctx)
    of "signup": state.signup.render(ctx)
    of "stocks": state.stocks.render(ctx)
    of "reports": state.reports.render(ctx)
    of "chat": state.chat.render(ctx)
    else: raise newException(UiError, "unknown page: " & state.active)
  view:
    line:
      gap: 0
      styles: {"height": "full", "background": Background, "color": Ink}
      stack navigation:
        key: "sidebar"
        gap: 18
        styles: {"width": "218", "height": "full", "padding": "20", "background": Surface, "overflow": "scroll"}
      stack:
        key: "content"
        styles: grow()
        content
proc galleryApp*(startPage = "dashboard"): Application =
  let state = Gallery(active: startPage, dashboard: newDashboard(), board: newBoard(), settings: newSettings(),
    signup: newSignup(), stocks: newStocks(), reports: newReports(), chat: newChat())
  proc render(ctx: BuildContext): Node = state.render(ctx)
  Application(title: "Leaf · 常用界面示例", width: 1240, height: 860, render: render)
when isMainModule: quit(run(galleryApp()))
