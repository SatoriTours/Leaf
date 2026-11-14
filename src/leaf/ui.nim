## shadcn-style standard components. Import as a qualified module:
##   import leaf/ui as ui
## Required semantics are validated by the backend; no CSS runtime is involved.
import std/[tables, math, options]
from ./styles import MaxStyleNumber, normalizeProps
import ./[core, ui_contract, overlay_protocol, select_protocol,
  popover_protocol, scroll_area_protocol, radio_group_protocol]
export select_protocol, popover_protocol, scroll_area_protocol, radio_group_protocol
import ./ui/tokens
import ./ui/[skeleton_component, spinner_component]
export skeleton_component, spinner_component
export ui_contract, tokens

proc attributes(role: UiRole, variant = UiVariant.default,
    size = UiSize.normal, invalid = false, loading = false): Styles =
  style({"ui_role": $role, "ui_variant": $variant, "ui_size": $size,
    "ui_invalid": $invalid, "ui_loading": $loading})

proc button*(label: string, onClick: Callback = nil, key = "",
    variant = UiVariant.default, size = UiSize.normal, disabled = false,
    loading = false): Node =
  var layout = style({"height": $controlHeight(size)})
  if size.iconOnly: layout["width"] = $controlHeight(size)
  core.ui(NodeKind.button, key=key, text=label, disabled=disabled or loading,
    onClick=(if disabled or loading: nil else: onClick), styles=layout,
    attributes=attributes(UiRole.button, variant, size, loading=loading))

proc input*(value: string, onChange: Callback = nil, key = "", placeholder = "",
    onSubmit: Callback = nil, disabled = false, invalid = false,
    resetToken: uint64 = 0): Node =
  var attrs = attributes(UiRole.input, invalid=invalid)
  if resetToken != 0: attrs["input_reset_token"] = $resetToken
  core.ui(NodeKind.input, key=key, text=value, placeholder=placeholder,
    disabled=disabled, onChange=onChange, onSubmit=onSubmit,
    styles=style({"width":"full", "height":"36"}), attributes=attrs)

proc space(width = 0, height = 0): Node =
  core.ui(NodeKind.column, styles=style({"width": $width, "height": $height}))

proc sectionBody(children: seq[Node], gap: int): Node =
  # Horizontal insets without adding CSS/edge-padding to the layout engine.
  core.ui(NodeKind.row, children= @[
    space(width=8),
    core.ui(NodeKind.column, children=children,
      styles=style({"gap": $gap, "width":"full"})),
    space(width=8)], styles=style({"width":"full"}))

proc card*(children: seq[Node], key = ""): Node =
  core.ui(NodeKind.column, key=key, children=children,
    styles=style({"padding":"16", "gap":"24", "width":"full"}),
    attributes=attributes(UiRole.card))

proc cardHeader*(children: seq[Node], key = ""): Node =
  core.ui(NodeKind.column, key=key, children= @[space(height=8),sectionBody(children,6)],
    styles=style({"width":"full"}), attributes=attributes(UiRole.cardHeader))

proc cardTitle*(value: string, key = ""): Node =
  core.ui(NodeKind.text, key=key, text=value,
    styles=style({"width":"full"}), attributes=attributes(UiRole.cardTitle))

proc cardDescription*(value: string, key = ""): Node =
  core.ui(NodeKind.text, key=key, text=value, styles=style({"width":"full"}),
    attributes=attributes(UiRole.cardDescription))

proc cardContent*(children: seq[Node], key = ""): Node =
  core.ui(NodeKind.column, key=key, children= @[sectionBody(children,24),space(height=16)],
    styles=style({"width":"full"}), attributes=attributes(UiRole.cardContent))

proc cardFooter*(children: seq[Node], key = ""): Node =
  let body=core.ui(NodeKind.row, children=children,
    styles=style({"gap":"8", "width":"full", "align":"center"}))
  core.ui(NodeKind.row, key=key, children= @[space(width=8),body,space(width=8)],
    styles=style({"width":"full", "align":"center"}),
    attributes=attributes(UiRole.cardFooter))

proc textarea*(value: string, onChange: Callback = nil, key = "", placeholder = "",
    disabled = false, invalid = false, resetToken: uint64 = 0,
    height = 64.0): Node =
  ## Fixed/explicit height, not CSS field-sizing-content. The real multiline
  ## EDIT keeps native selection, clipboard, IME and undo semantics.
  if classify(height) in {fcNan, fcInf, fcNegInf} or height < 64 or height > MaxStyleNumber:
    fail("standard textarea height must be finite and in 64..1000000 DIP")
  var attrs = attributes(UiRole.textarea, invalid=invalid)
  attrs["multiline"] = "true"
  if resetToken != 0: attrs["input_reset_token"] = $resetToken
  core.ui(NodeKind.input, key=key, text=value, placeholder=placeholder,
    disabled=disabled, onChange=onChange, attributes=attrs,
    styles=style({"width":"full", "height": $height}))

proc label*(value: string, key = ""): Node =
  core.ui(NodeKind.text, key=key, text=value,
    styles=style({"height":"20", "width":"full"}),
    attributes=attributes(UiRole.label))

proc field*(children: seq[Node], key = ""): Node =
  ## Vertical subset, with a label immediately before its native editor.
  core.ui(NodeKind.column, key=key, children=children,
    styles=style({"gap":"8", "width":"full"}), attributes=attributes(UiRole.field))

proc fieldDescription*(value: string, key = ""): Node =
  core.ui(NodeKind.text, key=key, text=value, styles=style({"width":"full"}),
    attributes=attributes(UiRole.fieldDescription))

proc fieldError*(value: string, key = ""): Node =
  core.ui(NodeKind.text, key=key, text=value, styles=style({"width":"full"}),
    attributes=attributes(UiRole.fieldError))

proc checkbox*(label: string, checked: bool, onChange: Callback = nil,
    key = "", disabled = false, invalid = false): Node =
  ## Boolean controlled subset; mixed/indeterminate is not implemented.
  var attrs=attributes(UiRole.checkbox,invalid=invalid)
  attrs["checked"] = $checked
  core.ui(NodeKind.checkbox,key=key,text=label,disabled=disabled,
    onChange=(if disabled:nil else:onChange),attributes=attrs,
    styles=style({"height":"20"}))

proc switch*(label: string, checked: bool, onChange: Callback = nil,
    key = "", disabled = false, size = UiSize.normal): Node =
  var attrs=attributes(UiRole.switch,size=size)
  attrs["checked"] = $checked
  core.ui(NodeKind.toggle,key=key,text=label,disabled=disabled,
    onChange=(if disabled:nil else:onChange),attributes=attrs,
    styles=style({"height":"20"}))

proc radioItem(value, label, key: string, disabled, checked: bool,
    handler: Callback): Node =
  var attrs = attributes(UiRole.radioGroupItem)
  attrs["radio_value"] = value
  attrs["checked"] = $checked
  core.ui(NodeKind.checkbox, key=key, text=label, disabled=disabled,
    onChange=(if disabled or handler == nil: nil else: handler),
    attributes=attrs, styles=style({"height":"20"}))

proc radioRequest(value: string, handler: Callback): Callback =
  ## A radio option never owns the business callback: activation becomes one
  ## typed change request carrying the declared option value.
  if handler == nil: return nil
  let target = handler
  result = proc(e: Event) =
    target(Event(kind: change, value: value, checked: true))

proc radioGroupItem*(value, label: string, key = "", disabled = false): Node =
  ## One declared option of the enclosing radio group. The group owns the
  ## accepted value and the single change handler; an option is never
  ## interactive on its own and carries no boolean business callback.
  radioItem(value, label, key, disabled, false, nil)

proc radioGroup*(items: openArray[Node], value: string, label = "", key = "",
    disabled = false, onChange: Callback = nil): Node =
  ## Controlled vertical single selection over real native radio buttons.
  ## The accepted value is state held by the caller; an empty value means
  ## nothing is selected, and a click or Space key only requests a value.
  ## Options must be non-empty and unique, and an accepted value that no longer
  ## exists is refused instead of silently falling back to the first option.
  var states: seq[RadioItem]
  for item in items:
    if item == nil: fail("radio group requires standard options")
    let props = normalizeProps(item)
    if props.standardUi.isNone or props.standardUi.get.role != UiRole.radioGroupItem:
      fail("radio group requires standard radio options")
    let optionValue = props.control.radioValue.get("")
    states.add(RadioItem(value: optionValue, enabled: not (item.disabled or disabled),
      checked: value.len != 0 and optionValue == value))
  let reason = radioSelectionReason(states, value)
  if reason.len != 0: fail(reason)
  var options: seq[Node]
  for index, item in items:
    let optionValue = states[index].value
    options.add(radioItem(optionValue, item.text, item.key,
      item.disabled or disabled, optionValue == value,
      radioRequest(optionValue, onChange)))
  var attrs = attributes(UiRole.radioGroup)
  attrs["radio_value"] = value
  core.ui(NodeKind.column, key=key, text=label, children=options,
    disabled=disabled, styles=style({"gap":"12", "width":"full"}),
    attributes=attrs)

proc theme*(mode: UiColorMode, child: Node, key = ""): Node =
  ## Explicit window-root configuration, not a nested/local theme component.
  ## Keep this wrapper and descendant keys stable across mode changes.
  if child == nil: fail("standard theme requires a child")
  var attrs = attributes(UiRole.theme)
  attrs["ui_color_mode"] = $mode
  core.ui(NodeKind.column, key=key, children= @[child],
    styles=style({"width":"full"}), attributes=attrs)

proc badge*(value: string, key = "", variant = UiVariant.default): Node =
  ## Noninteractive text badge. link is a color variant, not a hyperlink.
  core.ui(NodeKind.tag, key=key, text=value,
    styles=style({"height":"22"}), attributes=attributes(UiRole.badge,variant))

proc separator*(key = "", vertical = false, length = 24.0,
    decorative = true): Node =
  ## Decorative native rule; vertical extent is explicit, not CSS h-full.
  if not decorative: fail("nondecorative standard separator is not supported")
  if classify(length) in {fcNan,fcInf,fcNegInf} or length <= 0 or length > MaxStyleNumber:
    fail("separator length must be finite and in 0..1000000 DIP")
  core.ui(NodeKind.separator,key=key,
    styles=(if vertical:style({"width":"1","height": $length})
      else:style({"width":"full","height":"1"})),
    attributes=attributes(UiRole.separator))

proc empty*(children: seq[Node], key = ""): Node =
  ## Native fixed-padding subset: no CSS breakpoint, media or text-balance.
  core.ui(NodeKind.column,key=key,children=children,
    styles=style({"width":"full","padding":"24","gap":"24",
      "align":"center","justify":"center"}),attributes=attributes(UiRole.empty))

proc emptyHeader*(children: seq[Node], key = ""): Node =
  core.ui(NodeKind.column,key=key,children=children,
    styles=style({"width":"full","gap":"8","align":"center"}),
    attributes=attributes(UiRole.emptyHeader))

proc emptyTitle*(value: string, key = ""): Node =
  core.ui(NodeKind.text,key=key,text=value,styles=style({"width":"full"}),
    attributes=attributes(UiRole.emptyTitle))

proc emptyDescription*(value: string, key = ""): Node =
  core.ui(NodeKind.text,key=key,text=value,styles=style({"width":"full"}),
    attributes=attributes(UiRole.emptyDescription))

proc emptyContent*(children: seq[Node], key = ""): Node =
  core.ui(NodeKind.column,key=key,children=children,
    styles=style({"width":"full","gap":"16","align":"center"}),
    attributes=attributes(UiRole.emptyContent))

proc progress*(value: int, key = ""): Node =
  ## Determinate integer-percent subset; actual stock native range stays 0..100.
  if value<0 or value>100:fail("standard progress requires 0..100 integer percent")
  var attrs=attributes(UiRole.progress)
  attrs["value"] = $value
  core.ui(NodeKind.progress,key=key,styles=style({"width":"full","height":"8"}),
    attributes=attrs)

proc kbd*(value: string, key = ""): Node =
  ## A keyboard hint, not registration of an accelerator or action.
  core.ui(NodeKind.tag,key=key,text=value,styles=style({"height":"20"}),
    attributes=attributes(UiRole.kbd))

proc kbdGroup*(children: seq[Node], key = ""): Node =
  core.ui(NodeKind.row,key=key,children=children,
    styles=style({"gap":"4","align":"center"}),attributes=attributes(UiRole.kbdGroup))

proc buttonGroup*(children: seq[Node], key = "", label = ""): Node =
  ## Horizontal, direct equal-size standard buttons. Native Group, not a toolbar:
  ## each enabled button keeps its own Tab stop, Space and Invoke semantics.
  if children.len == 0: fail("button group requires buttons")
  var firstSize = UiSize.normal
  for i, child in children:
    if child == nil or child.kind != NodeKind.button:
      fail("button group only supports direct standard buttons")
    let button = normalizeProps(child).standardUi
    if button.isNone or button.get.role != UiRole.button:
      fail("button group only supports direct standard buttons")
    if i == 0: firstSize = button.get.size
    elif button.get.size != firstSize: fail("button group requires equal button sizes")
  core.ui(NodeKind.row,key=key,text=label,children=children,
    styles=style({"gap":"0","align":"center"}),
    attributes=attributes(UiRole.buttonGroup))

proc inputGroup*(control: Node, prefix = "", suffix = "", key = "", label = ""): Node =
  ## Horizontal single-line text-addon subset. Preserve the real EDIT's
  ## controlled callbacks, reset token, key, disabled and invalid semantics.
  if control == nil or control.kind != NodeKind.input:
    fail("input group requires a standard single-line input")
  let props=normalizeProps(control).standardUi
  if props.isNone or props.get.role != UiRole.input:
    fail("input group requires a standard single-line input")
  if control.styles.len != 2 or control.styles.getOrDefault("width") != "full" or
      control.styles.getOrDefault("height") != "36":
    fail("input group requires the standard input layout")
  let editor=core.ui(NodeKind.input,key=control.key,text=control.text,
    placeholder=control.placeholder,disabled=control.disabled,
    onChange=control.handler(EventKind.change),onSubmit=control.handler(EventKind.submit),
    attributes=control.attributes,styles=style({"width":"full","height":"34"}))
  proc addon(value:string,leading:bool):Node =
    let caption=core.ui(NodeKind.text,text=value,
      attributes=attributes(UiRole.inputGroupText),styles=style({"height":"20"}))
    core.ui(NodeKind.row,children= @[space(width=(if leading:12 else:8)),caption,
      space(width=(if leading:8 else:12))],styles=style({"height":"34","align":"center"}),
      attributes=attributes(UiRole.inputGroupAddon))
  var children:seq[Node]
  if prefix.len>0:children.add(addon(prefix,true))
  children.add(editor)
  if suffix.len>0:children.add(addon(suffix,false))
  core.ui(NodeKind.row,key=key,text=label,children=children,
    styles=style({"width":"full","height":"36","padding":"1","gap":"0","align":"center"}),
    attributes=attributes(UiRole.inputGroup))

proc alertTitle*(value: string, key = ""): Node =
  ## Single-line native title; the parent Alert supplies its visual variant.
  if value.len == 0: fail("alert title requires text")
  core.ui(NodeKind.text, key=key, text=value,
    styles=style({"height":"20", "width":"full"}), attributes=attributes(UiRole.alertTitle))

proc alertDescription*(value: string, key = ""): Node =
  ## Plain wrapping description, not rich content or nested actions.
  if value.len == 0: fail("alert description requires text")
  core.ui(NodeKind.text, key=key, text=value,
    styles=style({"width":"full"}), attributes=attributes(UiRole.alertDescription))

proc alert*(children: seq[Node], key = "", variant = UiVariant.default): Node =
  ## Text-only subset: at most one title, then at most one description.
  ## Compose one accessible live-region name from the same visible strings.
  if variant notin {UiVariant.default, UiVariant.destructive}:
    fail("unsupported alert variant")
  if children.len == 0 or children.len > 2: fail("alert requires title and/or description")
  var titleSeen, descriptionSeen: bool
  var name = ""
  for child in children:
    let props = normalizeProps(child)
    if props.standardUi.isNone or child.children.len != 0: fail("alert requires plain title/description")
    case props.standardUi.get.role
    of UiRole.alertTitle:
      if titleSeen or descriptionSeen: fail("alert title must be unique and first")
      titleSeen = true
    of UiRole.alertDescription:
      if descriptionSeen: fail("alert description must be unique")
      descriptionSeen = true
    else: fail("unsupported alert child")
    if child.text.len == 0: fail("alert requires text")
    if name.len > 0: name.add('\n')
    name.add(child.text)
  let body=core.ui(NodeKind.row, children= @[
    space(width=4),core.ui(NodeKind.column,children=children,
      styles=style({"gap":"2","width":"full"})),space(width=4)],styles=style({"width":"full"}))
  core.ui(NodeKind.column,key=key,text=name,children= @[body],
    styles=style({"padding":"12","width":"full"}),attributes=attributes(UiRole.alert,variant))

# --- modal overlay composition
# Upstream: dialog.tsx / alert-dialog.tsx at
# shadcn-ui/ui@42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9 new-york-v4.

proc dialogHeader*(children: seq[Node], key = "", trailing: Node = nil): Node =
  ## Title/description block. A trailing control (the X) shares the row because
  ## native layout has no absolutely positioned child; this is the documented
  ## difference from the upstream absolute top-right close control.
  if children.len == 0: fail("dialog header requires title or description")
  var row = @[core.ui(NodeKind.column, children = children,
    styles = style({"gap": "6", "width": "full"}))]
  if trailing != nil:
    if trailing.kind != NodeKind.button: fail("dialog header trailing control must be a button")
    row.add(trailing)
  core.ui(NodeKind.row, key = key, children = row,
    styles = style({"gap": "12", "width": "full", "align": "start"}),
    attributes = attributes(UiRole.dialogHeader))

proc dialogTitle*(value: string, key = ""): Node =
  if value.len == 0: fail("dialog title requires text")
  core.ui(NodeKind.text, key = key, text = value,
    styles = style({"width": "full"}), attributes = attributes(UiRole.dialogTitle))

proc dialogDescription*(value: string, key = ""): Node =
  if value.len == 0: fail("dialog description requires text")
  core.ui(NodeKind.text, key = key, text = value,
    styles = style({"width": "full"}), attributes = attributes(UiRole.dialogDescription))

proc dialogContent*(children: seq[Node], key = ""): Node =
  ## Ordinary body region. This slice has no internal scrolling primitive, so
  ## content taller than the work area is clamped by the host and reported as a
  ## documented limitation instead of being silently clipped mid-control.
  core.ui(NodeKind.column, key = key, children = children,
    styles = style({"gap": "16", "width": "full"}),
    attributes = attributes(UiRole.dialogContent))

proc dialogFooter*(children: seq[Node], key = ""): Node =
  core.ui(NodeKind.row, key = key, children = children,
    styles = style({"gap": "8", "width": "full", "align": "center", "justify": "end"}),
    attributes = attributes(UiRole.dialogFooter))

proc dialogClose*(label = "关闭", key = ""): Node =
  ## The library-supplied X equivalent. It carries no business callback: a click
  ## on this control becomes the overlay's typed dismiss request, which the
  ## caller answers by rendering open=false.
  core.ui(NodeKind.button, key = key, text = label,
    styles = style({"height": "24"}), attributes = attributes(UiRole.dialogClose))

proc alertDialogCancel*(label: string, onClick: Callback = nil, key = ""): Node =
  ## Safe action and the AlertDialog's initial focus target. It requests
  ## dismissal in addition to the caller's own handler; it never runs a
  ## confirmation.
  if label.len == 0: fail("alert dialog cancel requires a label")
  core.ui(NodeKind.button, key = key, text = label,
    styles = style({"height": $controlHeight(UiSize.normal)}),
    onClick = onClick, attributes = attributes(UiRole.alertDialogCancel))

proc alertDialogAction*(label: string, onClick: Callback, key = "",
    variant = UiVariant.default): Node =
  ## Confirmation control. It never dismisses by itself: the caller decides
  ## after its own validation whether the overlay may close.
  if label.len == 0: fail("alert dialog action requires a label")
  if onClick == nil: fail("alert dialog action requires a handler")
  if variant notin {UiVariant.default, UiVariant.destructive}:
    fail("unsupported alert dialog action variant")
  core.ui(NodeKind.button, key = key, text = label, onClick = onClick,
    styles = style({"height": $controlHeight(UiSize.normal)}),
    attributes = attributes(UiRole.alertDialogAction, variant))

proc overlayNode(kind: OverlayKind, title: string, open: bool,
                 children: seq[Node], onDismiss: Callback, key: string,
                 closable: bool, width: float64): Node =
  if title.len == 0: fail("modal overlay requires a title")
  var overlay = defaultOverlayProps(kind)
  overlay.open = open
  overlay.closable = closable
  overlay.width = width
  let reason = invalidOverlayReason(overlay)
  if reason.len != 0: fail(reason)
  core.ui(NodeKind.column, key = key, text = title, children = children,
    styles = style({"padding": "24", "gap": "16", "width": "full"}),
    onDismiss = onDismiss,
    attributes = attributes(if kind == overlayDialog: UiRole.dialog else: UiRole.alertDialog),
    overlay = some(overlay))

proc dialog*(title: string, open: bool, content: seq[Node] = @[],
             description = "", footer: seq[Node] = @[], onDismiss: Callback = nil,
             key = "", closable = true, width = 0.0): Node =
  ## Controlled modal Dialog. The caller owns open and must render open=false
  ## itself; Esc, the X and a scrim click only deliver the dismiss request.
  var header: seq[Node] = @[dialogTitle(title)]
  if description.len > 0: header.add(dialogDescription(description))
  var children = @[dialogHeader(header,
    trailing = (if closable: dialogClose() else: nil))]
  if content.len > 0: children.add(dialogContent(content))
  if footer.len > 0: children.add(dialogFooter(footer))
  overlayNode(overlayDialog, title, open, children, onDismiss, key, closable, width)

proc alertDialog*(title: string, cancel: Node, open: bool, action: Node = nil,
             description = "", content: seq[Node] = @[], onDismiss: Callback = nil,
             key = "", width = 0.0): Node =
  ## Controlled AlertDialog: no X control and no scrim dismissal. Initial focus
  ## is the safe cancel control.
  if cancel == nil or cancel.kind != NodeKind.button:
    fail("alert dialog requires a cancel button")
  let cancelProps = normalizeProps(cancel)
  if cancelProps.standardUi.isNone or cancelProps.standardUi.get.role != UiRole.alertDialogCancel:
    fail("alert dialog requires a standard cancel button")
  if action != nil:
    if action.kind != NodeKind.button: fail("alert dialog action must be a button")
    let actionProps = normalizeProps(action)
    if actionProps.standardUi.isNone or actionProps.standardUi.get.role != UiRole.alertDialogAction:
      fail("alert dialog action must be a standard action button")
  var header: seq[Node] = @[dialogTitle(title)]
  if description.len > 0: header.add(dialogDescription(description))
  var children = @[dialogHeader(header)]
  if content.len > 0: children.add(dialogContent(content))
  var footer: seq[Node] = @[cancel]
  if action != nil: footer.add(action)
  children.add(dialogFooter(footer))
  overlayNode(overlayAlertDialog, title, open, children, onDismiss, key, false, width)

# --- anchored single-select composition
# Upstream: select.tsx at
# shadcn-ui/ui@42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9 new-york-v4.

proc selectTrigger*(placeholder = "", disabled = false, key = ""): Node =
  ## One real focusable control. It carries no business handler: pointer and
  ## keyboard activation only produce open/close requests on the select root.
  core.ui(NodeKind.button, key = key, placeholder = placeholder,
    disabled = disabled,
    styles = style({"width": "full", "height": $controlHeight(UiSize.normal)}),
    attributes = attributes(UiRole.selectTrigger))

proc selectItem*(optionKey, label: string, disabled = false): Node =
  ## Candidate description consumed by select(); it is never mounted in the page
  ## flow and never painted as an inline row.
  if optionKey.len == 0: fail("select item requires a stable key")
  if label.len == 0: fail("select item requires a label")
  core.ui(NodeKind.row, key = optionKey, text = label, disabled = disabled,
    styles = style({"height": $DefaultSelectItemHeight}),
    attributes = attributes(UiRole.selectItem))

proc selectContent*(items: seq[Node], key = ""): Node =
  ## Candidate container. Only direct select items are accepted; ordering here
  ## is display order, never the selection identity.
  if items.len == 0: fail("select content requires at least one item")
  core.ui(NodeKind.column, key = key, children = items,
    styles = style({"width": "full"}),
    attributes = attributes(UiRole.selectContent))

proc select*(trigger: Node, content: Node, value = "", open = false,
    onChange: Callback = nil, onOpenChange: Callback = nil, key = "",
    label = "", width = 0.0): Node =
  ## Controlled single select: value and open are the caller's accepted state.
  ## A commit or an open/close request never rewrites them, so a caller that
  ## ignores a request keeps its accepted state without any drift.
  if trigger == nil or trigger.kind != NodeKind.button:
    fail("select requires a standard trigger")
  let triggerProps = normalizeProps(trigger)
  if triggerProps.standardUi.isNone or triggerProps.standardUi.get.role != UiRole.selectTrigger:
    fail("select requires a standard trigger")
  if trigger.children.len != 0: fail("select trigger cannot contain children")
  if content == nil or content.kind != NodeKind.column:
    fail("select requires standard content")
  let contentProps = normalizeProps(content)
  if contentProps.standardUi.isNone or contentProps.standardUi.get.role != UiRole.selectContent:
    fail("select requires standard content")
  var options: seq[SelectOption]
  for item in content.children:
    if item == nil or item.kind != NodeKind.row: fail("select content holds only items")
    let itemProps = normalizeProps(item)
    if itemProps.standardUi.isNone or itemProps.standardUi.get.role != UiRole.selectItem:
      fail("select content holds only items")
    if item.children.len != 0: fail("select item cannot contain children")
    options.add(SelectOption(key: item.key, label: item.text, disabled: item.disabled))
  let props = SelectProps(open: open, value: value,
    placeholder: trigger.placeholder, label: label, options: options, width: width)
  let reason = invalidSelectReason(props)
  if reason.len != 0: fail(reason)
  let shown = core.ui(NodeKind.button, key = trigger.key, text = props.displayLabel,
    placeholder = props.placeholder, disabled = trigger.disabled,
    styles = trigger.styles, attributes = trigger.attributes)
  core.ui(NodeKind.column, key = key, text = props.accessibleName,
    children = @[shown], styles = style({"width": $props.selectWidth}),
    attributes = attributes(UiRole.select), onChange = onChange,
    onOpenChange = onOpenChange, select = some(props))

proc containsPopoverRoot(node: Node, depth = 0): bool =
  ## Rejects recursive popovers in this first slice instead of silently nesting.
  if node == nil or depth > 32: return false
  let props = normalizeProps(node)
  if props.standardUi.isSome and props.standardUi.get.role == UiRole.popover:
    return true
  for child in node.children:
    if containsPopoverRoot(child, depth + 1): return true
  false

proc popoverTrigger*(label: string, disabled = false, key = ""): Node =
  ## One real focusable control in the page flow. It carries no business
  ## handler: pointer and keyboard activation only produce open/close requests
  ## on the popover root.
  if label.len == 0: fail("popover trigger requires a label")
  core.ui(NodeKind.button, key = key, text = label, disabled = disabled,
    styles = style({"height": $controlHeight(UiSize.normal)}),
    attributes = attributes(UiRole.popoverTrigger))

proc popoverClose*(label = "关闭", disabled = false, key = ""): Node =
  ## A plain button inside the panel. Activation only requests open=false.
  if label.len == 0: fail("popover close requires a label")
  core.ui(NodeKind.button, key = key, text = label, disabled = disabled,
    styles = style({"height": $controlHeight(UiSize.normal)}),
    attributes = attributes(UiRole.popoverClose))

proc popoverContent*(children: seq[Node], key = ""): Node =
  ## The named panel body. Its direct children are ordinary standard controls or
  ## an existing single select; the panel is a real owned window, not an inline
  ## container in the page flow.
  for child in children:
    if child == nil: fail("popover content cannot hold a nil child")
  core.ui(NodeKind.column, key = key, children = children,
    styles = style({"width": "full", "padding": "16", "gap": "8"}),
    attributes = attributes(UiRole.popoverContent))

proc scrollAreaContent*(children: seq[Node], key = ""): Node =
  ## The single scrolling content subtree. Ordinary columns/cards/fields and
  ## native EDIT controls live here; nothing is virtualized, so the whole subtree
  ## stays mounted and scrolling only moves geometry.
  for child in children:
    if child == nil: fail("scroll area content cannot hold a nil child")
  core.ui(NodeKind.column, key = key, children = children,
    styles = style({"width": "full", "gap": "8"}),
    attributes = attributes(UiRole.scrollAreaContent))

proc scrollArea*(content: Node, height: float64, key = ""): Node =
  ## Bounded vertical viewport with a persistent content subtree. First slice:
  ## vertical only, a real native viewport with the system scrollbar, no nested
  ## scroll area (typed refusal, never a silent clip) and no horizontal scroll.
  if content == nil or content.kind != NodeKind.column:
    fail("scroll area requires standard content")
  let contentProps = normalizeProps(content)
  if contentProps.standardUi.isNone or
      contentProps.standardUi.get.role != UiRole.scrollAreaContent:
    fail("scroll area requires standard content")
  if content.children.len == 0:
    fail("scroll area requires non-empty content")
  let reason = scrollAreaHeightReason(height)
  if reason.len != 0: fail(reason)
  for child in content.children:
    let childProps = normalizeProps(child)
    if childProps.standardUi.isSome and childProps.standardUi.get.role in
        {UiRole.scrollArea, UiRole.scrollAreaContent}:
      fail("nested scroll areas are not supported")
  core.ui(NodeKind.column, key = key, children = @[content],
    styles = style({"height": $height, "width": "full"}),
    attributes = attributes(UiRole.scrollArea))

proc popover*(trigger: Node, content: Node, open = false,
    side = PopoverSide.bottom, align = PopoverAlign.alignStart,
    sideOffset = DefaultPopoverSideOffset, width = 0.0, name = "",
    onOpenChange: Callback = nil, key = ""): Node =
  ## Controlled non-modal popover: open is the caller's accepted state and every
  ## trigger click, Esc, outside click, Tab boundary or close control is only a
  ## typed request. Nested popovers are rejected in this slice; a popover may of
  ## course sit inside a dialog and host an existing select.
  if trigger == nil or trigger.kind != NodeKind.button:
    fail("popover requires a standard trigger")
  let triggerProps = normalizeProps(trigger)
  if triggerProps.standardUi.isNone or
      triggerProps.standardUi.get.role != UiRole.popoverTrigger:
    fail("popover requires a standard trigger")
  if trigger.children.len != 0: fail("popover trigger cannot contain children")
  if content == nil or content.kind != NodeKind.column:
    fail("popover requires standard content")
  let contentProps = normalizeProps(content)
  if contentProps.standardUi.isNone or
      contentProps.standardUi.get.role != UiRole.popoverContent:
    fail("popover requires standard content")
  if contentProps.standardUi.get.role == UiRole.popoverContent and
      content.children.len == 0:
    fail("popover content requires at least one control")
  for child in content.children:
    if containsPopoverRoot(child):
      fail("nested popover is not supported in this slice")
  if triggerProps.standardUi.get.role == UiRole.popoverTrigger and
      containsPopoverRoot(trigger):
    fail("nested popover is not supported in this slice")
  let props = PopoverProps(open: open, side: side, align: align,
    sideOffset: sideOffset, width: width, name: name)
  let reason = invalidPopoverReason(props)
  if reason.len != 0: fail(reason)
  core.ui(NodeKind.column, key = key, text = props.name,
    children = @[trigger, content], styles = style({"width": "full"}),
    attributes = attributes(UiRole.popover), onOpenChange = onOpenChange,
    popover = some(props))
