## Leaf public entry selects the platform at compile time.
when defined(android):
  import leaf/mobile
  export mobile
  template run*(args:varargs[untyped]):untyped =
    {.error: "Android uses registerAndroidApplication(factory), not desktop run".}
else:
  ## Leaf's native Nim API. Headless mode does not load the GPUI desktop bridge.
  import leaf/[core, widgets, height_index, view, routing]
  import leaf/components
  export core, widgets, height_index, view, routing
  export components
  import leaf/runner
  export runner
