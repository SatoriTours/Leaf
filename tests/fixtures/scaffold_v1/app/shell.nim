import leaf

proc navigation(router: Router, destination: Route): Node =
  view:
    button destination.name:
      key: "nav_" & destination.name
      variant: (if router.currentRoute.name == destination.name: "primary" else: "ghost")
      onClick(e): router.navigate(destination.name)

proc renderShell*(router: Router, ctx: BuildContext): Node =
  view:
    row:
      styles: {"height": "full", "width": "full", "gap": "20", "padding": "24"}
      column:
        key: "navigation"
        styles: {"gap": "12", "width": "160"}
        text "Leaf"
        for destination in router.routes:
          navigation(router, destination)
      column:
        key: "page"
        styles: {"gap": "12", "flex_grow": "1", "min_width": "0"}
        router.renderPage(ctx)
