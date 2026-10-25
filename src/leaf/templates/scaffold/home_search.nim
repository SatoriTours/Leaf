proc renderSearch(state: HomeState): Node =
  view:
    column:
      styles: (when defined(android) or defined(windows): style({"gap": "16", "flex_grow": "1"})
               else: style({"gap": "16", "flex_grow": "1", "min_height": "0"}))
      text "Search":
        variant: "primary"
      input state.query:
        key: "search_query"
        placeholder: "Search tasks"
        styles: {"height": "40", "width": "full"}
        onChange(e): state.setQuery(e.value)
      renderTasks(state, state.query)
