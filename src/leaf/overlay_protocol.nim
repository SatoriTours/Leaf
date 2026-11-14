## Pure modal overlay contract. Typed description, dismissal matrix, nesting
## budget and the focus policy for the standard Dialog/AlertDialog. No OS
## objects, no message pump, no application callbacks, and no dependency on the
## node/runtime modules: every rejection is a reason string or a typed status so
## the caller raises its own UiError.
import std/[math]

const
  DialogScrollEnabled* = true
    ## Dialog content scrolling (runtime shrink reachability) is implemented but
    ## not enabled: its native wiring still fails the scroll RED contract, so the
    ## accepted layout stays as before until that slice is finished.
  MaxOverlayDepth* = 8
    ## Bounded modal nesting; deeper stacks are rejected, never truncated.
  MinOverlayWidth* = 240.0
  DefaultOverlayWidth* = 512.0
    ## Upstream new-york-v4 DialogContent caps at max-w-lg (32rem).
  MaxOverlayWidth* = 1024.0

type
  OverlayKind* {.pure.} = enum
    overlayDialog = 1, overlayAlertDialog
  OverlayDismiss* {.pure.} = enum
    ## Everything that may only *request* open=false; none of these performs a
    ## business confirmation.
    escapeKey, closeControl, scrim, cancelControl, systemClose
  OverlayActivation* {.pure.} = enum
    overlayActivated, overlayAlreadyOpen, overlayBudgetExceeded
  OverlayProps* = object
    ## Typed overlay sidecar carried next to the ordinary node properties.
    kind*: OverlayKind
    open*: bool
    closable*: bool
      ## The Dialog X control. AlertDialog never renders one.
    scrim*: bool
      ## Host renders the in-application scrim behind the modal surface.
    width*: float64
      ## 0 asks the host for the default width.
    ##
    ## Focus is deliberately not described by keys: the host restores the real
    ## previously focused control after validating that it still exists, is
    ## visible and enabled, and otherwise falls back to the first focusable
    ## control of the owning window. Initial focus is role-driven: the
    ## AlertDialog cancel control, else the first focusable control inside the
    ## content region, else the modal surface itself.

  OverlayStack* = object
    ## Accepted modal nesting, bottom to top. Identity is the overlay root's
    ## opaque native handle; no session or platform object is stored.
    order*: seq[uint64]

proc defaultOverlayProps*(kind: OverlayKind): OverlayProps =
  OverlayProps(kind: kind, open: false,
    closable: kind == overlayDialog, scrim: true, width: 0.0)

proc invalidOverlayReason*(props: OverlayProps): string =
  ## "" when the typed overlay description is internally valid. Pure: the same
  ## rules are enforced on construction, on the host wire and by the tests.
  let width = props.width
  if classify(width) in {fcNan, fcInf, fcNegInf}:
    return "overlay width is not finite"
  if width != 0.0 and (width < MinOverlayWidth or width > MaxOverlayWidth):
    return "overlay width must be 0 or in " & $MinOverlayWidth & ".." & $MaxOverlayWidth
  if props.kind == overlayAlertDialog and props.closable:
    return "alert dialog has no close control"
  if not props.scrim:
    return "modal overlay requires the in-application scrim"
  ""

proc overlayWidth*(props: OverlayProps): float64 =
  if props.width == 0.0: DefaultOverlayWidth else: props.width

proc dismissAllowed*(props: OverlayProps, source: OverlayDismiss): bool =
  ## Dialog dismissal requests are all advisory; AlertDialog must never be
  ## dismissed by clicking outside its surface.
  if source == scrim: props.kind == overlayDialog
  else: true

proc activateOverlay*(stack: var OverlayStack, id: uint64): OverlayActivation =
  ## Re-activating an open overlay is idempotent and changes no other level.
  if id == 0: return overlayBudgetExceeded
  if id in stack.order: return overlayAlreadyOpen
  if stack.order.len >= MaxOverlayDepth: return overlayBudgetExceeded
  stack.order.add(id)
  overlayActivated

proc deactivateOverlay*(stack: var OverlayStack, id: uint64): bool =
  ## Removes exactly this level; returns whether it was the top one. Closing an
  ## unknown overlay is a no-op so a late duplicate cannot unwedge a sibling.
  let index = stack.order.find(id)
  if index < 0: return false
  result = index == stack.order.high
  stack.order.delete(index)

proc topOverlay*(stack: OverlayStack): uint64 =
  if stack.order.len == 0: 0'u64 else: stack.order[^1]

proc overlayIsTop*(stack: OverlayStack, id: uint64): bool =
  id != 0 and stack.topOverlay == id

proc overlayDepth*(stack: OverlayStack): int = stack.order.len

proc chooseInitialFocus*(props: OverlayProps, cancelPresent,
                         firstFocusable: bool): string =
  ## Deterministic initial focus policy: the AlertDialog's safe cancel control,
  ## then the first focusable control in tab order, else the modal surface
  ## itself, so an empty dialog still has a legal focus target.
  if props.kind == overlayAlertDialog and cancelPresent: return "cancel"
  if firstFocusable: return "first"
  "surface"

proc chooseRestoreFocus*(triggerUsable, firstFocusable: bool): string =
  ## Restore the remembered trigger only while it still exists, is visible and
  ## enabled; otherwise fall back to the first focusable control of the owning
  ## window, else the window's own default focus target.
  if triggerUsable: return "trigger"
  if firstFocusable: return "first"
  "owner"
