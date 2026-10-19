## Component page entry: dependencies are preloaded for logic and every View.
import std/strutils
import leaf
import leaf/sqlite as storage
import ../../models/task
import ../../services/task_service
import ../../components/empty_state

include logic
include views/list
include views/search
include views/settings
include views/index

proc definition*(database: storage.Database): ComponentPageDefinition =
  let page = defineComponent[int, State[HomeState]]("ScaffoldHomePage",
    proc(ctx: MountContext, p: int): State[HomeState] =
      ctx.state(HomeState(service: newTaskService(database)), snapshot = snapshotHome),
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
