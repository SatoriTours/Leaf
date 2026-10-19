import leaf

proc navButton(ctx: ComponentContext, router: ComponentRouter,
    destination: Route): UiDescription =
  componentView:
    button destination.name:
      key: "nav_" & destination.name
      variant: (if currentRoute(ctx, router).name == destination.name: "primary" else: "ghost")
      onClick(e): discard navigate(router, destination.name)

proc renderShell*(ctx: ComponentContext, router: ComponentRouter,
    outletKey = "page-outlet"): UiDescription =
  componentView:
    row:
      styles: {"height": "full", "width": "full", "gap": "20", "padding": "24"}
      column:
        key: "navigation"
        styles: {"gap": "12", "width": "160"}
        text "Leaf"
        for i in 0 ..< router.routes.len:
          navButton(ctx, router, router.routes[i])
      column:
        key: "page"
        styles: {"gap": "12", "flex_grow": "1", "min_width": "0"}
        renderPage(ctx, router, outletKey)
