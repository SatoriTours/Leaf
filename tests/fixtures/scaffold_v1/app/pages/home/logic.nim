import leaf
## State and user actions for the home page group. Dependencies come from page.nim.
type HomeState = ref object
  service: TaskService
  draft, query, error: string
  hideCompleted: bool
  model: leaf.State[HomeState]


proc snapshotHome(state: HomeState): HomeState =
  HomeState(service: state.service, draft: state.draft, query: state.query,
    error: state.error, hideCompleted: state.hideCompleted)

proc edit(state: HomeState, change: proc(v: var HomeState)) =
  ## Queue UI fields from the State updater's current value; the accepted
  ## render copy is never mutated by handlers.
  discard state.model.update(proc(current: HomeState): HomeState =
      result = snapshotHome(current)
      change(result))

proc setDraft(state: HomeState, value: string) =
  state.edit(proc(v: var HomeState) = v.draft = value)

proc setQuery(state: HomeState, value: string) =
  state.edit(proc(v: var HomeState) = v.query = value)

proc setHideCompleted(state: HomeState, value: bool) =
  state.edit(proc(v: var HomeState) = v.hideCompleted = value)

proc addTask(state: HomeState) =
  let current = state.model.read()
  var draft = current.draft
  var error = ""
  try:
    discard current.service.save(Task(title: draft))
    draft = ""
  except ValueError as caught:
    error = caught.msg
  state.edit(proc(v: var HomeState) = (v.draft = draft; v.error = error))

proc toggleTask(state: HomeState, id: int, done: bool) =
  let current = state.model.read()
  var error = ""
  try:
    var item = current.service.find(id)
    item.done = done
    discard current.service.save(item)
  except ValueError as caught:
    error = caught.msg
  state.edit(proc(v: var HomeState) = v.error = error)

proc removeTask(state: HomeState, id: int) =
  let current = state.model.read()
  var error = ""
  try:
    current.service.delete(id)
  except ValueError as caught:
    error = caught.msg
  state.edit(proc(v: var HomeState) = v.error = error)

proc visibleTasks(state: HomeState, query: string): seq[Task] =
  for item in state.service.all():
    if state.hideCompleted and item.done: continue
    if query.toLowerAscii() notin item.title.toLowerAscii(): continue
    result.add(item)
