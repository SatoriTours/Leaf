## Dependencies are shared by the page's logic and Views.
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

proc definition*(): PageDefinition =
  PageDefinition(name: "home", views: @["index", "search", "settings"],
    create: proc(): PageGroup =
      let state = HomeState()
      PageGroup(render: proc(ctx: BuildContext, panel: string): Node =
        case panel
        of "index": renderHome(state)
        of "search": renderSearch(state)
        of "settings": renderSettings(state)
        else: raise newException(UiError, "Unknown home View: " & panel)))
