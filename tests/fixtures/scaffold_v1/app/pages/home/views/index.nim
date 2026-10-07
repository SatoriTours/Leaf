proc renderHome(state: HomeState): Node =
  view:
    column:
      styles: {"gap": "16", "flex_grow": "1", "min_height": "0"}
      text "Home":
        styles: {"font_size": "28", "weight": "bold"}
      row:
        styles: {"gap": "12"}
        input state.draft:
          key: "task_draft"
          placeholder: "Add a task"
          onChange(e): state.draft = e.value
          onSubmit(e): state.addTask()
        button "Add":
          key: "task_add"
          onClick(e): state.addTask()
      renderTasks(state)
