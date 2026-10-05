import std/[strutils, sequtils]
import leaf

type
  Task = object
    id: int
    title: string
    done: bool
  Todo = ref object
    draft: string
    nextId: int
    items: seq[Task]

proc add(state: Todo) =
  let title = state.draft.strip()
  if title.len == 0: return
  state.items.add(Task(id: state.nextId, title: title))
  inc state.nextId
  state.draft = ""

proc taskRow(state: Todo, task: Task): Node =
  let id = task.id
  row(@[
    button((if task.done: "撤销" else: "完成"), key = "toggle_" & $id,
      onClick = proc(e: Event) =
        for item in state.items.mitems:
          if item.id == id: item.done = not item.done),
    text(task.title, key = "task_" & $id, styles = style({"flex_grow": "1",
      "color": (if task.done: "#9CA3AF" else: "#E5E7EB")})),
    button("删除", key = "remove_" & $id,
      onClick = proc(e: Event) = state.items.keepItIf(it.id != id))
  ], key = "row_" & $id, styles = style({"gap": "12", "padding": "12",
    "width": "full", "align": "center", "background": "#1F2937", "radius": "8"}))

proc todoApp*(): Application =
  let state = Todo(nextId: 1)
  Application(title: "Leaf · Todo", width: 720, height: 560,
    render: proc(ctx: BuildContext): Node =
      var tasks: seq[Node]
      if state.items.len == 0:
        tasks.add(text("还没有事项。添加第一项吧。", styles = style({"padding": "16"})))
      else:
        for task in state.items: tasks.add(state.taskRow(task))
      column(@[
        text("待办事项", styles = style({"font_size": "30", "weight": "bold"})),
        text("用 Nim 编写的原生应用"),
        row(@[
          input(state.draft, key = "entry", placeholder = "输入事项，按 Enter 添加",
            styles = style({"flex_grow": "1"}),
            onChange = proc(e: Event) = state.draft = e.value,
            onSubmit = proc(e: Event) = state.add()),
          button("添加", key = "add", disabled = state.draft.strip.len == 0,
            onClick = proc(e: Event) = state.add())], styles = style({"gap": "12", "width": "full"})),
        column(tasks, key = "tasks", styles = style({"gap": "10", "width": "full",
          "min_height": "0", "flex_grow": "1", "overflow": "scroll"})),
        text("已完成 " & $state.items.countIt(it.done) & " / " & $state.items.len,
          key = "summary", styles = style({"color": "#93C5FD"}))
      ], styles = style({"padding": "28", "gap": "16", "width": "full", "height": "full"})))

when isMainModule: quit(run(todoApp()))
