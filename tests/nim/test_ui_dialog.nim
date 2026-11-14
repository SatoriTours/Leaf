import std/[unittest, options, sets, sequtils]
import leaf
import leaf/[styles, host_protocol, backend, host_reconcile, overlay_protocol]
import leaf/ui as standard

proc snap(node: Node): Snapshot =
  Snapshot(title: "t", width: 640, height: 480, root: mount(node))

proc overlay(n: Node): OverlayProps =
  let props = n.overlayProps
  check props.isSome
  props.get

proc sampleDialog(open = true, onDismiss: Callback = nil,
                  footer: seq[Node] = @[]): Node =
  standard.dialog("Edit contact", open,
    content = @[standard.field(@[standard.label("Name"),
      standard.input("Ada", key = "name")])],
    description = "Update the stored name.",
    footer = footer, onDismiss = onDismiss, key = "dialog")

suite "standard Dialog contract":
  test "dialog composes the typed overlay description in both host policies":
    let n = sampleDialog()
    check n.kind == NodeKind.column
    let props = normalizeProps(n)
    check $props.standardUi.get.role == "dialog"
    check props.accessibility.label.get == "Edit contact"
    for policy in [nativeStrict, hostCompatible]:
      let wire = normalizeHostProps(n, policy)
      check wire.overlay.isSome
      let carried = wire.overlay.get
      check carried.kind == overlayDialog
      check carried.open
      check carried.closable
      check carried.scrim
      check $wire.normalized.standardUi.get.role == "dialog"

  test "open is caller state and dismiss is a typed request":
    var opened = true
    var requests = 0
    let node = sampleDialog(open = opened, onDismiss = proc(event: Event) =
      check event.kind == dismiss
      inc requests)
    check node.overlayProps.get.open
    # A dismiss request is only a request: the accepted description is reused
    # until the caller renders open=false.
    node.handler(dismiss)(Event(kind: dismiss))
    check requests == 1
    check node.overlayProps.get.open
    let closed = sampleDialog(open = false, onDismiss = proc(event: Event) = discard)
    check not closed.overlayProps.get.open
    expect UiError:
      discard core.ui(NodeKind.column, onDismiss = proc(event: Event) = discard)

  test "overlay description requires a dialog role and a container":
    var props = defaultOverlayProps(overlayDialog)
    props.open = true
    expect UiError:
      discard normalizeProps(core.ui(NodeKind.column, attributes = style({"ui_role": "card"}),
        overlay = some(props)))
    expect UiError:
      discard core.ui(NodeKind.text, text = "x", overlay = some(props))
    expect UiError:
      discard normalizeProps(core.ui(NodeKind.column, attributes = style({"ui_role": "dialog"})))

  test "alert dialog requires a standard cancel control and has no close control":
    let cancel = standard.alertDialogCancel("Cancel")
    let n = standard.alertDialog("Delete file", cancel, true,
      standard.alertDialogAction("Delete", proc(event: Event) = discard,
        variant = UiVariant.destructive))
    let props = normalizeProps(n)
    check $props.standardUi.get.role == "alertDialog"
    check n.overlayProps.get.kind == overlayAlertDialog
    check not n.overlayProps.get.closable
    expect UiError:
      discard standard.alertDialog("Delete file", standard.button("Cancel"), true)
    expect UiError:
      discard standard.alertDialog("Delete file",
        standard.alertDialogCancel("Cancel"), true,
        standard.alertDialogAction("Delete", proc(event: Event) = discard,
          variant = UiVariant.outline))
    var closable = defaultOverlayProps(overlayAlertDialog)
    closable.closable = true
    check invalidOverlayReason(closable).len != 0

  test "focus policy is role driven and needs no cross-layer keys":
    let dialogProps = OverlayProps(kind: overlayDialog)
    check dialogProps.chooseInitialFocus(false, true) == "first"
    check dialogProps.chooseInitialFocus(false, false) == "surface"
    let alertProps = OverlayProps(kind: overlayAlertDialog)
    check alertProps.chooseInitialFocus(true, true) == "cancel"
    check alertProps.chooseInitialFocus(false, true) == "first"
    check alertProps.chooseInitialFocus(false, false) == "surface"
    check chooseRestoreFocus(true, true) == "trigger"
    check chooseRestoreFocus(false, true) == "first"
    check chooseRestoreFocus(false, false) == "owner"

  test "overlay width is bounded":
    expect UiError: discard standard.dialog("Too narrow", true, width = 100)
    expect UiError: discard standard.dialog("Too wide", true, width = 4096)
    expect UiError: discard standard.dialog("Nan", true, width = NaN)
    check standard.dialog("Default", true).overlayProps.get.overlayWidth == DefaultOverlayWidth
    check standard.dialog("Wide", true, width = 768.0).overlayProps.get.overlayWidth == 768.0
    expect UiError: discard standard.dialog("", true)

suite "modal overlay pure rules":
  test "dismissal matrix separates Dialog from AlertDialog":
    let dialog = OverlayProps(kind: overlayDialog, closable: true, scrim: true)
    let alert = OverlayProps(kind: overlayAlertDialog, closable: false, scrim: true)
    for source in [escapeKey, closeControl, scrim, cancelControl, systemClose]:
      check dismissAllowed(dialog, source)
    check dismissAllowed(alert, escapeKey)
    check dismissAllowed(alert, cancelControl)
    check dismissAllowed(alert, systemClose)
    check not dismissAllowed(alert, scrim)

  test "nesting keeps inner levels and only the top closes":
    var stack: OverlayStack
    check stack.activateOverlay(1) == overlayActivated
    check stack.activateOverlay(2) == overlayActivated
    check stack.activateOverlay(3) == overlayActivated
    check stack.activateOverlay(2) == overlayAlreadyOpen
    check stack.topOverlay == 3
    check stack.overlayDepth == 3
    check stack.deactivateOverlay(2) == false
    check stack.topOverlay == 3
    check stack.deactivateOverlay(3) == true
    check stack.topOverlay == 1
    check stack.overlayIsTop(1)
    check stack.deactivateOverlay(99) == false
    check stack.deactivateOverlay(1) == true
    check stack.overlayDepth == 0
    check stack.topOverlay == 0'u64

  test "nesting budget is bounded instead of truncated":
    var stack: OverlayStack
    for id in 1'u64..uint64(MaxOverlayDepth):
      check stack.activateOverlay(id) == overlayActivated
    check stack.activateOverlay(uint64(MaxOverlayDepth) + 1) == overlayBudgetExceeded
    check stack.overlayDepth == MaxOverlayDepth
    check stack.activateOverlay(0) == overlayBudgetExceeded

  test "initial focus prefers cancel, then the first focusable, then the surface":
    let dialog = OverlayProps(kind: overlayDialog)
    check dialog.chooseInitialFocus(true, false) == "surface"
    check dialog.chooseInitialFocus(false, true) == "first"
    check dialog.chooseInitialFocus(true, true) == "first"
    let alert = OverlayProps(kind: overlayAlertDialog)
    check alert.chooseInitialFocus(true, true) == "cancel"
    check alert.chooseInitialFocus(false, true) == "first"
    check alert.chooseInitialFocus(false, false) == "surface"

  test "restore focus falls back when the trigger is gone":
    check chooseRestoreFocus(true, true) == "trigger"
    check chooseRestoreFocus(false, true) == "first"
    check chooseRestoreFocus(false, false) == "owner"

suite "modal overlay capability gate":
  test "a backend without overlay support rejects the description":
    var props = OverlayProps(kind: overlayDialog, open: true, scrim: true, closable: true)
    let caps = fullCapabilities()
    discard checkTypedCapabilities("dialog", NodeKind.column, normalizeProps(sampleDialog()),
      caps, compatible, some(props))
    var limited = caps
    limited.overlays = {}
    expect UiError:
      discard checkTypedCapabilities("dialog", NodeKind.column,
        normalizeProps(sampleDialog()), limited, compatible, some(props))
    let alertProps = OverlayProps(kind: overlayAlertDialog, open: true, scrim: true)
    var dialogOnly = caps
    dialogOnly.overlays = {overlayDialog}
    expect UiError:
      discard checkTypedCapabilities("alert", NodeKind.column,
        normalizeProps(sampleDialog()), dialogOnly, compatible, some(alertProps))

  test "checkCapabilities walks mounted overlay nodes":
    var limited = fullCapabilities()
    limited.overlays = {}
    expect UiError:
      discard checkCapabilities(mount(sampleDialog()), limited, compatible)
    discard checkCapabilities(mount(sampleDialog()), fullCapabilities(), compatible)

suite "typed host wire":
  test "overlay sidecar reaches the native batch intact":
    let reconciler = newHostReconciler(11)
    let plan = reconciler.planSnapshot(snap(column(@[sampleDialog()], key = "root")), 1,
      hostCompatible)
    let creates = plan.batch.ops.filterIt(it.kind == HostOpKind.create)
    var found = 0
    for op in creates:
      if op.props.overlay.isSome:
        inc found
        check op.props.overlay.get.kind == overlayDialog
        check op.props.overlay.get.open
        check op.nodeKind == NodeKind.column
        check (op.props.eventMask and EventDismissMask) == 0
    check found == 1
