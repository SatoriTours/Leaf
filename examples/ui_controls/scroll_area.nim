## Finite native forms. Scroll moves a persistent content HWND, not application state.
import leaf
import leaf/ui as standard

type Model = object
  values: array[12, string]
  open, dark, reject: bool
  status: string

let Demo = defineComponent[int, State[Model]]("ScrollAreaDemo",
  proc(ctx: MountContext, p: int): State[Model] = ctx.state(Model()),
  proc(ctx: ComponentContext, p: int, state: State[Model]): UiDescription =
    let m = ctx.value(state)
    let update = proc(f: proc(old: Model): Model {.closure.}) = discard state.update(f)
    proc field(index: int, prefix: string): Node =
      standard.field(@[standard.label("Field " & $(index + 1)),
        standard.input(m.values[index], key = prefix & "-field-" & $(index + 1),
          placeholder = "Draft " & $(index + 1),
          onChange = proc(e: Event) = update(proc(old: Model): Model =
            result = old
            result.values[index] = e.value))], key = prefix & "-row-" & $(index + 1))
    proc form(prefix: string): Node =
      var fields: seq[Node]
      for index in 0..<12: fields.add(field(index, prefix))
      fields.add(standard.button("Last action", key = prefix & "-last",
        onClick = proc(e: Event) = update(proc(old: Model): Model =
          result = old
          result.status = "Last action reached")))
      standard.scrollArea(standard.scrollAreaContent(fields, key = prefix & "-content"),
        240, key = prefix & "-viewport")
    let save = proc(e: Event) = update(proc(old: Model): Model =
      result = old
      if old.reject: result.status = "Save refused; draft retained"
      else:
        result.status = "Saved in memory"
        result.open = false)
    let dialog = standard.dialog("Scrollable form", m.open, key = "dialog",
      description = "Header and footer stay outside the 240 DIP viewport.",
      content = @[form("dialog")],
      footer = @[standard.button("Save", key = "save", onClick = save)],
      onDismiss = proc(e: Event) = update(proc(old: Model): Model =
        result = old
        result.open = false))
    let page = column(@[
      standard.label("Native ScrollArea"),
      row(@[standard.button("Open dialog", key = "open",
        onClick = proc(e: Event) = update(proc(old: Model): Model =
          result = old
          result.open = true)),
        standard.button("Toggle theme", key = "theme-toggle",
          onClick = proc(e: Event) = update(proc(old: Model): Model =
            result = old
            result.dark = not old.dark))], styles = style({"gap": "12"})),
      standard.checkbox("Refuse save", m.reject, key = "reject",
        onChange = proc(e: Event) = update(proc(old: Model): Model =
          result = old
          result.reject = e.checked)),
      form("page"), standard.label(m.status, key = "status"), dialog],
      styles = style({"padding": "20", "gap": "12", "width": "full"}))
    hostShell(standard.theme((if m.dark: UiColorMode.dark else: UiColorMode.light),
      column(@[], key = "theme"), key = "theme"), @[host(page)]))

quit run(componentApplication(component(Demo, 0), "Leaf - ScrollArea", 560, 480)
  .withNativeTheme(shadcnLight))
