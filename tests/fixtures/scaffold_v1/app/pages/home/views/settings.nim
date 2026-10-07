proc renderSettings(state: HomeState): Node =
  view:
    column:
      styles: {"gap": "16"}
      text "Settings"
      checkbox("Hide completed tasks", state.hideCompleted):
        key: "hide_completed"
        onChange(e): state.hideCompleted = e.checked
      text "Task records are saved in SQLite. View settings apply to this session."
