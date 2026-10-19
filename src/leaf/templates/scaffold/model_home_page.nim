## Component page entry: dependencies are shared by the page's logic and Views.
import std/strutils
import leaf
import leaf/model
import ../../models/task
import ../../components/empty_state

include logic
include views/list
include views/search
include views/settings
include views/index

proc definition*(): ComponentPageDefinition =
  let page = defineComponent[int, State[HomeState]]("ScaffoldModelHomePage",
    proc(ctx: MountContext, p: int): State[HomeState] =
      ctx.state(HomeState(), snapshot = snapshotHome),
    proc(ctx: ComponentContext, p: int, model: State[HomeState]): UiDescription =
      let state = ctx.value(model)
      state.model = model
      let node =
        case p
        of 0: renderHome(state)
        of 1: renderSearch(state)
        of 2: renderSettings(state)
        else: raise newException(UiError, "Unknown home View")
      host(node))
  ComponentPageDefinition(name: "home", views: @["index", "search", "settings"],
    build: proc(view: string): UiDescription =
      component(page, (if view == "search": 1 elif view == "settings": 2 else: 0)))
