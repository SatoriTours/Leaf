proc renderSearch(state: HomeState): Node =
  view:
    column:
      styles: {"gap": "16", "flex_grow": "1", "min_height": "0"}
      text "Search"
      input state.query:
        key: "search_query"
        placeholder: "Search tasks"
        onChange(e): state.query = e.value
      renderTasks(state, state.query)
