import leaf

proc emptyState*(message, key: string): Node =
  view:
    text message:
      key: key
      styles: {"padding": "16", "color": "#64748B"}
