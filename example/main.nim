import ./ui
import ./pages/[dashboard, board, settings, signup, stocks, reports, chat]

type GalleryModel = object
  active: State[string]
  dashboard: State[Dashboard]
  board: State[Board]
  settings: State[Settings]
  signup: State[Signup]
  stocks: State[Stocks]
  reports: State[Reports]
  chat: State[Chat]

proc navigationButton(model: GalleryModel, id, name, detail, active: string): Node =
  let navButton = view:
    button name:
      key: "nav_" & id
      styles: {"width": "full"}
      variant: (if active == id: "primary" else: "ghost")
      onClick(e): discard model.active.set(id)
  stack(@[navButton, label(detail)], "navigation_" & id, 6)

let GalleryRoot = defineComponent[string, GalleryModel]("ExampleGalleryRoot",
  proc(ctx: MountContext, startPage: string): GalleryModel =
    GalleryModel(active: ctx.state(startPage),
      dashboard: ctx.state(newDashboard(), snapshot = snapshotDashboard),
      board: ctx.state(newBoard(), snapshot = snapshotBoard),
      settings: ctx.state(newSettings(), snapshot = snapshotSettings),
      signup: ctx.state(newSignup(), snapshot = snapshotSignup),
      stocks: ctx.state(newStocks(), snapshot = snapshotStocks),
      reports: ctx.state(newReports(), snapshot = snapshotReports),
      chat: ctx.state(newChat(), snapshot = snapshotChat)),
  proc(ctx: ComponentContext, startPage: string, model: GalleryModel): UiDescription =
    let active = ctx.value(model.active)
    var navigation: seq[Node] = @[title("Leaf / STUDIO", size = 20), label("常用界面试验台"), separator()]
    for (id, name, detail) in [("dashboard", "01  数据概览", "统计卡片 / 图表 / 列表"),
      ("board", "02  任务看板", "多列布局 / 动态列表"), ("settings", "03  个人设置", "输入 / 开关 / 保存"),
      ("signup", "04  注册表单", "校验 / 反馈 / 禁用状态"), ("stocks", "05  股票 K 线", "密集图元 / 盘口 / 逐帧"),
      ("reports", "06  统计报表", "千行数据 / 排序 / 分页"),
      ("chat", "07  即时聊天", "多会话 / 消息气泡 / 历史")]:
      navigation.add(navigationButton(model, id, name, detail, active))
    navigation.add(tag("交互式示例", variant = "success"))
    navigation.add(label("Nim 状态 · 原生组件"))
    navigation.add(label("所有数据仅在内存中保存"))
    var content: Node
    case active
    of "dashboard":
      let page = ctx.value(model.dashboard)
      page.model = model.dashboard
      content = page.render()
    of "board":
      let page = ctx.value(model.board)
      page.model = model.board
      content = page.render()
    of "settings":
      let page = ctx.value(model.settings)
      page.model = model.settings
      content = page.render()
    of "signup":
      let page = ctx.value(model.signup)
      page.model = model.signup
      content = page.render()
    of "stocks":
      let page = ctx.value(model.stocks)
      page.model = model.stocks
      content = page.render()
    of "reports":
      let page = ctx.value(model.reports)
      page.model = model.reports
      content = page.render()
    of "chat":
      let page = ctx.value(model.chat)
      page.model = model.chat
      content = page.render()
    else: raise newException(UiError, "unknown page: " & active)
    let body = line(@[
      stack(navigation, "sidebar", 18, style({"width": "218", "height": "full",
        "padding": "20", "background": Surface, "overflow": "scroll"})),
      stack(@[content], "content", 12, grow())],
      styles = style({"height": "full", "background": Background, "color": Ink}))
    host(body))

proc galleryApp*(startPage = "dashboard"): Application =
  componentApplication(component(GalleryRoot, startPage), "Leaf · 常用界面示例", 1240, 860)

when isMainModule: quit(run(galleryApp()))
