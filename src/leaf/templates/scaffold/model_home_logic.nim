## Drafts and display preferences belong to the page, persistence to models.
type HomeState = ref object
  draft, query, error: string
  hideCompleted: bool

proc addTask(state: HomeState) =
  try:
    let task = Task.build(title = state.draft)
    if task.save():
      state.draft = ""
      state.error = ""
    else: state.error = task.errors.fullMessages.join("\n")
  except PostCommitError as error:
    state.draft = ""
    state.error = error.msg
  except CatchableError as error: state.error = error.msg

proc toggleTask(state: HomeState, id: int64, done: bool) =
  try:
    let task = Task.find(id)
    task.done = done
    if task.save(): state.error = ""
    else: state.error = task.errors.fullMessages.join("\n")
  except PostCommitError as error: state.error = error.msg
  except CatchableError as error: state.error = error.msg

proc removeTask(state: HomeState, id: int64) =
  try:
    Task.find(id).destroyOrRaise()
    state.error = ""
  except PostCommitError as error: state.error = error.msg
  except CatchableError as error: state.error = error.msg

proc visibleTasks(state: HomeState, query: string): seq[Task] =
  for item in Task.all:
    if state.hideCompleted and item.done: continue
    if query.toLowerAscii() notin item.title.toLowerAscii(): continue
    result.add(item)
