proc renderHome(state: HomeState): Node =
  view:
    column:
      styles: (when defined(android) or defined(windows): style({"gap": "16", "flex_grow": "1"})
               else: style({"gap": "16", "flex_grow": "1", "min_height": "0"}))
      text "Home":
        variant: "primary"
        styles: (when defined(windows): style([])
                 else: style({"font_size": "28", "weight": "bold"}))
      row:
        styles: {"gap": "8", "align": "center"}
        input state.draft:
          key: "task_draft"
          placeholder: "Add a task"
          styles: {"height": "40", "flex_grow": "1"}
          onChange(e): state.setDraft(e.value)
          onSubmit(e): state.addTask()
        button "Add":
          key: "task_add"
          styles: {"width": "96", "height": "32"}
          onClick(e): state.addTask()
      renderTasks(state)
