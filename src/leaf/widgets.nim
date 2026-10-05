## Typed Nim constructors for GPUI and GPUI Kit controls.
import std/math
import ./core
export core

proc column*(children: seq[Node], key = "", styles: Styles = default(Styles)): Node =
  ui(NodeKind.column, key = key, children = children, styles = styles)
proc row*(children: seq[Node], key = "", styles: Styles = default(Styles)): Node =
  ui(NodeKind.row, key = key, children = children, styles = styles)
proc text*(value: string, key = "", styles: Styles = default(Styles)): Node =
  ui(NodeKind.text, key = key, text = value, styles = styles)
proc button*(label: string, onClick: Callback = nil, key = "", disabled = false,
             styles: Styles = default(Styles), variant = "primary"): Node =
  ui(NodeKind.button, key = key, text = label, onClick = onClick,
     disabled = disabled, styles = styles, attributes = style({"variant": variant}))
proc input*(value: string, onChange: Callback = nil, key = "", placeholder = "",
            onSubmit: Callback = nil, disabled = false,
            styles: Styles = default(Styles)): Node =
  ui(NodeKind.input, key = key, text = value, placeholder = placeholder,
    onChange = onChange, onSubmit = onSubmit, disabled = disabled, styles = styles)
proc checkbox*(label: string, checked: bool, onChange: Callback = nil, key = "",
               disabled = false, styles: Styles = default(Styles)): Node =
  ui(NodeKind.checkbox, key = key, text = label, onChange = onChange,
    disabled = disabled, styles = styles, attributes = style({"checked": $checked}))
proc switch*(label: string, checked: bool, onChange: Callback = nil, key = "",
             disabled = false, styles: Styles = default(Styles)): Node =
  ui(NodeKind.toggle, key = key, text = label, onChange = onChange,
    disabled = disabled, styles = styles, attributes = style({"checked": $checked}))
proc progress*(value: float64, key = "", styles: Styles = default(Styles)): Node =
  if classify(value) in {fcNan, fcInf, fcNegInf}: fail("invalid progress value")
  ui(NodeKind.progress, key = key, styles = styles,
    attributes = style({"value": $clamp(value, 0.0, 100.0)}))
proc tag*(label: string, key = "", variant = "primary",
          styles: Styles = default(Styles)): Node =
  ui(NodeKind.tag, key = key, text = label, styles = styles,
    attributes = style({"variant": variant}))
proc separator*(key = "", styles: Styles = default(Styles)): Node =
  ui(NodeKind.separator, key = key, styles = styles)
proc spinner*(key = "", styles: Styles = default(Styles)): Node =
  ui(NodeKind.spinner, key = key, styles = styles)
