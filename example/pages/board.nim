import std/[strutils, sequtils]
import ../ui
type
  Lane = enum
    todo, doing, done
  Task = object
    id: int
    title: string
    lane: Lane
  Board* = ref object
    draft: string
    hideCompleted: bool
    nextId: int
    tasks: seq[Task]
proc newBoard*(): Board =
  result = Board(nextId: 7)
  for i, name in ["整理首页信息架构", "补充表单错误提示",
                  "实现导航与页面切换", "验收中文输入体验",
                  "确定界面配色", "完成组件清单"]:
    result.tasks.add(Task(id: i + 1, title: name, lane: Lane(i div 2)))

proc add(state: Board) =
  let value = state.draft.strip
  if value.len == 0:
    return
  state.tasks.add(Task(id: state.nextId, title: value))
  inc state.nextId
  state.draft = ""

proc advance(state: Board; id: int) =
  for task in state.tasks.mitems:
    if task.id == id:
      task.lane = Lane((ord(task.lane) + 1) mod 3)

proc taskView(state: Board; task: Task): Node =
  let id = task.id
  view:
    stack:
      key: "task_" & $id
      gap: 14
      styles: {"padding": "14", "min_height": "174", "background": Background, "radius": "10"}
      label("TASK / " & align($id, 3, '0'))
      text(task.title):
        key: "task_title_" & $id
      tag(["准备开始", "正在推进", "已交付"][ord(task.lane)]):
        variant: ["warning", "info", "success"][ord(task.lane)]
      line:
        button(["开始", "完成", "重新打开"][ord(task.lane)]):
          key: "advance_" & $id
          onClick(e): state.advance(id)
        button("删除"):
          key: "delete_" & $id
          variant: "ghost"
          onClick(e): state.tasks = state.tasks.filterIt(it.id != id)

proc render*(state: Board; ctx: BuildContext): Node =
  var lanes: seq[Node]
  for lane in Lane:
    var entries: seq[Node]
    var count = 0
    for task in state.tasks:
      if task.lane == lane:
        inc count
        if lane != done or not state.hideCompleted:
          entries.add(state.taskView(task))
    if entries.len == 0:
      let emptyLane = view:
        label((if lane == done and state.hideCompleted: "已完成任务已隐藏" else: "这里还没有任务")):
          key: "empty_" & $lane
      entries.add(emptyLane)
    let laneCard = view:
      card:
        key: "lane_" & $lane
        styles: grow()
        line:
          title(["待开始", "进行中", "已完成"][ord(lane)])
          tag($count):
            variant: ["warning", "info", "success"][ord(lane)]
        separator()
        stack:
          key: "tasks_" & $lane
          styles: {"height": "340", "overflow": "scroll"}
          children: entries
    lanes.add(laneCard)
  let completed = state.tasks.countIt(it.lane == done)
  view:
    page("项目看板", "从想法到交付。添加任务，点击按钮推进状态。"):
      height: 720
      card:
        line:
          input(state.draft):
            key: "task_draft"
            placeholder: "输入新任务，按 Enter 添加"
            styles: grow()
            onChange(e): state.draft = e.value
            onSubmit(e): state.add()
          button("添加任务"):
            key: "task_add"
            disabled: state.draft.strip.len == 0
            onClick(e): state.add()
        checkbox("隐藏已完成的任务", state.hideCompleted):
          key: "hide_completed"
          onChange(e): state.hideCompleted = e.checked
      line:
        children: lanes
      line:
        label("共 " & $state.tasks.len & " 项 · 已完成 " & $completed & " 项"):
          key: "board_summary"
        progress((if state.tasks.len == 0: 0.0 else: float64(completed) * 100 / float64(state.tasks.len))):
          key: "board_progress"
          styles: grow()
