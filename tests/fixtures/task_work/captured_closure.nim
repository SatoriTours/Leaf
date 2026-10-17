import leaf/task_contracts

proc captureUiState() =
  var uiState = "UI only"
  let invalidWork: TaskWork = proc(input: string, ctx: WorkerContext): string =
    uiState.add(input)
    uiState
  discard invalidWork

captureUiState()
