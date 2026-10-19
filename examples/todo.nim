import std/[strutils, sequtils]
import leaf

type
  Task = object
    id: int
    title: string
    done: bool
  TodoModel = object
    draft: string
    nextId: int
    items: seq[Task]

proc addTask(model: var TodoModel) =
  let title = model.draft.strip()
  if title.len == 0: return
  model.items.add(Task(id: model.nextId, title: title))
  inc model.nextId
  model.draft = ""

proc added(m: TodoModel): TodoModel =
  result = m
  addTask(result)

proc drafted(m: TodoModel, text: string): TodoModel =
  result = m
  result.draft = text

proc toggled(m: TodoModel, id: int): TodoModel =
  result = m
  for item in result.items.mitems:
    if item.id == id: item.done = not item.done

proc removed(m: TodoModel, id: int): TodoModel =
  result = m
  result.items.keepItIf(it.id != id)

proc taskRow(model: State[TodoModel], task: Task): Node =
  let id = task.id
  row(@[
    button((if task.done: "撤销" else: "完成"), key="toggle_" & $id,
      onClick=(proc(e: Event) = discard model.update(proc(m: TodoModel): TodoModel = toggled(m, id)))),
    text(task.title, key="task_" & $id,
      styles=style({"flex_grow": "1", "color": (if task.done: "#9CA3AF" else: "#E5E7EB")})),
    button("删除", key="remove_" & $id,
      onClick=(proc(e: Event) = discard model.update(proc(m: TodoModel): TodoModel = removed(m, id))))],
    key="row_" & $id,
    styles=style({"gap": "12", "padding": "12", "width": "full", "align": "center",
      "background": "#1F2937", "radius": "8"}))

proc snapshotTodo(m: TodoModel): TodoModel =
  result = TodoModel(draft: m.draft, nextId: m.nextId)
  for item in m.items: result.items.add(item)

let Todo = defineComponent[int, State[TodoModel]]("ExampleTodo",
  proc(ctx: MountContext, p: int): State[TodoModel] =
    ctx.state(TodoModel(nextId: 1), snapshot = snapshotTodo),
  proc(ctx: ComponentContext, p: int, model: State[TodoModel]): UiDescription =
    let current = ctx.value(model)
    var rows: seq[Node]
    if current.items.len == 0:
      rows.add(text("还没有事项。添加第一项吧。", styles=style({"padding": "16"})))
    else:
      for task in current.items:
        rows.add(taskRow(model, task))
    let body = column(@[
      text("待办事项", styles=style({"font_size": "30", "weight": "bold"})),
      text("用 Nim 编写的原生应用"),
      row(@[
        input(current.draft, key="entry", placeholder="输入事项，按 Enter 添加",
          styles=style({"flex_grow": "1"}),
          onChange=(proc(e: Event) = discard model.update(proc(m: TodoModel): TodoModel = drafted(m, e.value))),
          onSubmit=(proc(e: Event) = discard model.update(proc(m: TodoModel): TodoModel = added(m)))),
        button("添加", key="add", disabled=current.draft.strip.len == 0,
          onClick=(proc(e: Event) = discard model.update(proc(m: TodoModel): TodoModel = added(m))))],
        styles=style({"gap": "12", "width": "full"})),
      column(rows, key="tasks", styles=style({"gap": "10", "width": "full",
        "min_height": "0", "flex_grow": "1", "overflow": "scroll"})),
      text("已完成 " & $current.items.countIt(it.done) & " / " & $current.items.len,
        key="summary", styles=style({"color": "#93C5FD"}))],
      key="todo-root", styles=style({"padding": "28", "gap": "16", "width": "full", "height": "full"}))
    host(body))

proc todoApp*(): Application =
  componentApplication(component(Todo, 0), "Leaf · Todo", 720, 560)

when isMainModule: quit(run(todoApp()))
