## Shared editable controls expressed with declared model parameters.
import ./[component_dsl, component_state, widgets]

proc textField*(value: string, placeholder = "", disabled = false, key = "",
    onChange: proc(value: string) {.closure.} = nil, styles: Styles = default(Styles)): Node =
  let notify: Callback = if onChange == nil: nil else:
    proc(e: Event) = onChange(e.value)
  input(value, key = key, placeholder = placeholder, disabled = disabled,
    styles = styles, onChange = notify)

template leafModels_textField*(): untyped = ["value", "", "", ""]

proc textField*(value: ModelBindingInternal[string], placeholder = "",
    disabled = false, key = ""): Node =
  input(value.sample, key = key, placeholder = placeholder, disabled = disabled,
    onChange = proc(e: Event) = value.slot.writeDraft(e.value))
