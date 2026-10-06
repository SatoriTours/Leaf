## Page-group entry: dependencies are preloaded for logic and every included View.
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

proc definition*(database: storage.Database): PageDefinition =
  PageDefinition(name: "home", views: @["index", "search", "settings"],
    create: proc(): PageGroup =
      let state = HomeState(service: newTaskService(database))
      PageGroup(render: proc(ctx: BuildContext, panel: string): Node =
        case panel
        of "index": renderHome(state)
        of "search": renderSearch(state)
        of "settings": renderSettings(state)
        else: raise newException(UiError, "Unknown home View: " & panel)))
