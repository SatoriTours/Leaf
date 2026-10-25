proc renderTask(state: HomeState, item: Task): Node =
  let id = item.id
  let children = @[
    checkbox("Done", item.done, key = "task_done_" & $id,
      onChange = proc(e: Event) = state.toggleTask(id, e.checked)),
    text(item.title, key = "task_title_" & $id),
    button("Delete", key = "task_delete_" & $id, variant = "secondary",
      onClick = proc(e: Event) = state.removeTask(id))]
  when defined(android):
    column(children, key = "task_row_" & $id,
      styles = style({"gap": "8", "padding": "8"}))
  else:
    row(children, key = "task_row_" & $id,
      styles = style({"gap": "12", "padding": "8", "align": "center"}))

proc renderTasks(state: HomeState, query = ""): Node =
  let items = state.visibleTasks(query)
  when defined(android) or defined(windows):
    var keys: seq[string]
    for item in items: keys.add($item.id)
    let rows = virtualList("task_list", keys,
      proc(index: int): Node = renderTask(state, items[index]),
      rowHeight = 0, estimatedHeight = 64, overscan = 1,
      styles = style({"flex_grow": "1", "width": "full"}))
    view:
      column:
        styles: {"gap": "8", "flex_grow": "1"}
        text state.error:
          key: "task_error"
          variant: "danger"
        if items.len == 0:
          emptyState("No matching tasks", "home_empty")
        else:
          rows
  else:
    view:
      column:
        styles: {"gap": "8", "overflow": "scroll", "flex_grow": "1"}
        text state.error:
          key: "task_error"
          variant: "danger"
        if items.len == 0:
          emptyState("No matching tasks", "home_empty")
        for item in items:
          renderTask(state, item)
