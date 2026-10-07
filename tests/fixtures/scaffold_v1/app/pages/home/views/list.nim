proc renderTask(state: HomeState, item: Task): Node =
  let id = item.id
  view:
    row:
      key: "task_row_" & $id
      styles: {"gap": "12", "padding": "8", "align": "center"}
      checkbox("Done", item.done):
        key: "task_done_" & $id
        onChange(e): state.toggleTask(id, e.checked)
      text item.title:
        key: "task_title_" & $id
      button "Delete":
        key: "task_delete_" & $id
        onClick(e): state.removeTask(id)

proc renderTasks(state: HomeState, query = ""): Node =
  let items = state.visibleTasks(query)
  view:
    column:
      styles: {"gap": "8", "overflow": "scroll", "flex_grow": "1"}
      text state.error:
        key: "task_error"
      if items.len == 0:
        emptyState("No matching tasks", "home_empty")
      for item in items:
        renderTask(state, item)
