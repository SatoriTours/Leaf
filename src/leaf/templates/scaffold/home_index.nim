proc renderHome(state: HomeState): Node =
  view:
    column:
      styles: (when defined(android): style({"gap": "16", "flex_grow": "1"})
               elif defined(windows): style({"gap": "16", "flex_grow": "1", "width": "full"})
               else: style({"gap": "16", "flex_grow": "1", "min_height": "0", "width": "full"}))
      text "Home":
        variant: "primary"
        styles: (when defined(windows): style([])
                 else: style({"font_size": "28", "weight": "bold"}))
      row:
        styles: (when defined(android): style({"gap": "8", "align": "center"})
                 else: style({"gap": "8", "align": "center", "width": "full"}))
        input state.draft:
          key: "task_draft"
          placeholder: "Add a task"
          styles: (when defined(android): style({"height": "40", "flex_grow": "1"})
                   else: style({"height": "40", "flex_grow": "1", "width": "full"}))
          onChange(e): state.setDraft(e.value)
          onSubmit(e): state.addTask()
        button "Add":
          key: "task_add"
          styles: {"width": "96", "height": "32"}
          onClick(e): state.addTask()
      renderTasks(state)
