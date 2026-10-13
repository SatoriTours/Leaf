## Managed component pages: a counter page, a Chinese-draft page with two views
## and a disposeOnLeave scratch page. `leaf --headless --click go-draft` drives
## the stable keys without opening a window.
import leaf
import leaf/components

var router: ComponentRouter

type PagesModel = object
  count: State[int]
  draft: State[string]
  errors: State[int]

proc reportUnknown(m: PagesModel) =
  ## Demonstrate that an unknown address is rejected without breaking the page.
  try:
    discard navigate(router, "missing")
  except UiError:
    discard m.errors.update(proc(v: int): int = v + 1)

let MainPage = defineComponent[int, PagesModel]("ExamplePagesMain",
  proc(ctx: MountContext, p: int): PagesModel =
    PagesModel(count: ctx.state(0), draft: ctx.state("中文草稿"), errors: ctx.state(0)),
  proc(ctx: ComponentContext, p: int, m: PagesModel): UiDescription =
    hostShell(column(@[]), @[
      host(text("main:" & $ctx.value(m.count) & ":" & ctx.value(m.draft) & ":" &
        $ctx.value(m.errors), key="status")),
      host(button("增加 +1", onClick=proc(e: Event) = discard m.count.update(proc(v: int): int = v + 1),
        key="add")),
      host(button("重置", onClick=proc(e: Event) =
        discard m.count.set(0)
        discard m.draft.set("中文草稿"), key="reset")),
      host(button("草稿页", onClick=proc(e: Event) = discard navigate(router, "draft"),
        key="go-draft")),
      host(button("临时页", onClick=proc(e: Event) = discard navigate(router, "scratch"),
        key="go-scratch")),
      host(button("未知地址", onClick=proc(e: Event) = reportUnknown(m), key="go-unknown"))]))

let DraftPage = defineComponent[int, State[string]]("ExamplePagesDraft",
  proc(ctx: MountContext, p: int): State[string] = ctx.state("中文草稿"),
  proc(ctx: ComponentContext, p: int, s: State[string]): UiDescription =
    let value = ctx.value(s)
    if p == 1:
      hostShell(column(@[]), @[
        host(text("draft-edit:" & value, key="status")),
        host(input(value, onChange=proc(e: Event) = discard s.set(e.value), key="draft-input")),
        host(button("返回", onClick=proc(e: Event) = discard navigate(router, "main"), key="go-main"))])
    else:
      hostShell(column(@[]), @[
        host(text("draft:" & value, key="status")),
        host(button("编辑", onClick=proc(e: Event) = discard navigate(router, "draft-edit"),
          key="go-edit")),
        host(button("返回", onClick=proc(e: Event) = discard navigate(router, "main"), key="go-main"))]))

let ScratchPage = defineComponent[int, State[int]]("ExamplePagesScratch",
  proc(ctx: MountContext, p: int): State[int] = ctx.state(0),
  proc(ctx: ComponentContext, p: int, s: State[int]): UiDescription =
    hostShell(column(@[]), @[
      host(text("scratch:" & $ctx.value(s), key="status")),
      host(button("加一", onClick=proc(e: Event) = discard s.update(proc(v: int): int = v + 1),
        key="scratch-add")),
      host(button("返回", onClick=proc(e: Event) = discard navigate(router, "main"), key="go-main"))]))

let pagesRoutes = @[
  Route(name: "main", path: "/", page: "main", view: "main"),
  Route(name: "draft", path: "/draft", page: "draft", view: "list"),
  Route(name: "draft-edit", path: "/draft/edit", page: "draft", view: "edit"),
  Route(name: "scratch", path: "/scratch", page: "scratch", view: "main")]
let pagesPages = @[
  ComponentPageDefinition(name: "main", views: @["main"],
    build: proc(view: string): UiDescription = component(MainPage, 0)),
  ComponentPageDefinition(name: "draft", views: @["list", "edit"],
    build: proc(view: string): UiDescription = component(DraftPage, (if view == "edit": 1 else: 0))),
  ComponentPageDefinition(name: "scratch", views: @["main"], retention: PageRetention.disposeOnLeave,
    build: proc(view: string): UiDescription = component(ScratchPage, 0))]

let PagesHost = defineComponent[int, int]("ExamplePagesHost",
  proc(ctx: MountContext, p: int): int =
    router = newComponentRouter(ctx, pagesRoutes, pagesPages, "main")
    p,
  proc(ctx: ComponentContext, p: int, m: int): UiDescription =
    renderPage(ctx, router))

proc pagesApplication*(title = "Leaf 组件页面"): Application =
  componentApplication(component(PagesHost, 0), title)

when isMainModule: quit(run(pagesApplication()))
