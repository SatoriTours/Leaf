import leaf
## Drafts and display preferences belong to the page, persistence to models.
type HomeState = ref object
  draft, query, error: string
  hideCompleted: bool
  model: leaf.State[HomeState]


proc snapshotHome(state: HomeState): HomeState =
  HomeState(draft: state.draft, query: state.query, error: state.error,
    hideCompleted: state.hideCompleted)

proc edit(state: HomeState, change: proc(v: var HomeState)) =
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
    let task = Task.build(title = draft)
    if task.save():
      draft = ""
    else: error = task.errors.fullMessages.join("\n")
  except PostCommitError as caught:
    draft = ""
    error = caught.msg
  except CatchableError as caught: error = caught.msg
  state.edit(proc(v: var HomeState) = (v.draft = draft; v.error = error))

proc toggleTask(state: HomeState, id: int64, done: bool) =
  let current = state.model.read()
  var error = ""
  try:
    let task = Task.find(id)
    task.done = done
    if not task.save(): error = task.errors.fullMessages.join("\n")
  except PostCommitError as caught: error = caught.msg
  except CatchableError as caught: error = caught.msg
  state.edit(proc(v: var HomeState) = v.error = error)

proc removeTask(state: HomeState, id: int64) =
  let current = state.model.read()
  var error = ""
  try:
    Task.find(id).destroyOrRaise()
  except PostCommitError as caught: error = caught.msg
  except CatchableError as caught: error = caught.msg
  state.edit(proc(v: var HomeState) = v.error = error)

proc visibleTasks(state: HomeState, query: string): seq[Task] =
  for item in Task.all:
    if state.hideCompleted and item.done: continue
    if query.toLowerAscii() notin item.title.toLowerAscii(): continue
    result.add(item)
