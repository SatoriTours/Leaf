## Shared editable controls expressed with declared model parameters.
import ./[component_dsl, component_state, widgets]

template leafModels_textField*(): untyped = ["value", "", "", ""]

proc textField*(value: ModelBindingInternal[string], placeholder = "",
    disabled = false, key = ""): Node =
  input(value.sample, key = key, placeholder = placeholder, disabled = disabled,
    onChange = proc(e: Event) = value.slot.writeDraft(e.value))
