## State and user actions for the home page group. Dependencies come from page.nim.
type HomeState = ref object
  service: TaskService
  draft, query, error: string
  hideCompleted: bool

proc addTask(state: HomeState) =
  try:
    discard state.service.save(Task(title: state.draft))
    state.draft = ""
    state.error = ""
  except ValueError as error:
    state.error = error.msg

proc toggleTask(state: HomeState, id: int, done: bool) =
  try:
    var item = state.service.find(id)
    item.done = done
    discard state.service.save(item)
    state.error = ""
  except ValueError as error:
    state.error = error.msg

proc removeTask(state: HomeState, id: int) =
  try:
    state.service.delete(id)
    state.error = ""
  except ValueError as error:
    state.error = error.msg

proc visibleTasks(state: HomeState, query: string): seq[Task] =
  for item in state.service.all():
    if state.hideCompleted and item.done: continue
    if query.toLowerAscii() notin item.title.toLowerAscii(): continue
    result.add(item)
