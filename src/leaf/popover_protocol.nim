## Pure controlled non-modal popover contract: typed properties, rejection
## matrix, dismissal notices and anchored placement math. No OS objects, no Node
## references and no callbacks: every refusal is a reason string or a ValueError
## so the caller raises its own error type.
import std/[math]

const
  MinPopoverWidth* = 160.0
  DefaultPopoverWidth* = 288.0
    ## Upstream new-york-v4 PopoverContent uses w-72 (18rem).
  MaxPopoverWidth* = 720.0
  PopoverMargin* = 16.0
    ## Keeps the panel inside the work area, like the dialog surface margin.
  MaxPopoverSideOffset* = 64.0
  DefaultPopoverSideOffset* = 4.0
    ## Upstream PopoverContent sideOffset default.
  MinPopoverContentHeight* = 1.0

type
  PopoverSide* {.pure.} = enum
    ## Requested side; the planner flips only when the requested side does not
    ## fit and the opposite side fits better.
    bottom, top, left, right

  PopoverAlign* {.pure.} = enum
    alignStart, alignCenter, alignEnd

  PopoverProps* = object
    ## Typed sidecar next to the ordinary node properties. open is the caller's
    ## accepted state; every dismissal or activation is only a request.
    open*: bool
    side*: PopoverSide
    align*: PopoverAlign
    sideOffset*: float64
    width*: float64
      ## 0 asks for the default width.
    name*: string
      ## Required accessible name of the owned content panel (the stock window
      ## title carries it; an empty name is rejected, never silently invented).

  PopoverDismiss* {.pure.} = enum
    ## Everything that may only *request* open=false.
    pdEscape, pdOutside, pdCloseControl, pdTabForward, pdTabBackward, pdSystemClose

  PopoverNotice* = object
    ## One recorded native request for one staged revision.
    dismiss*: PopoverDismiss
    stage*: uint64

  PopoverPlacement* = object
    ## Pure placement result in DIP: pixel position, client size and the side
    ## that was really used. The viewport equals the content size (no scrolling
    ## in this slice).
    x*, y*, width*, height*: float64
    usedSide*: PopoverSide
    flipped*: bool

proc invalidPopoverReason*(props: PopoverProps): string =
  ## "" when the typed description is internally valid. The same rules run on
  ## construction, on the host wire and in the tests.
  if props.name.len == 0:
    return "popover requires an accessible name"
  let width = props.width
  if classify(width) in {fcNan, fcInf, fcNegInf}:
    return "popover width is not finite"
  if width != 0.0 and (width < MinPopoverWidth or width > MaxPopoverWidth):
    return "popover width must be 0 or in " & $MinPopoverWidth & ".." & $MaxPopoverWidth
  let offset = props.sideOffset
  if classify(offset) in {fcNan, fcInf, fcNegInf}:
    return "popover side offset is not finite"
  if offset < 0.0 or offset > MaxPopoverSideOffset:
    return "popover side offset must be in 0.." & $MaxPopoverSideOffset
  ""

proc popoverWidth*(props: PopoverProps): float64 =
  if props.width == 0.0: DefaultPopoverWidth else: props.width

proc popoverOffset*(props: PopoverProps): float64 =
  if props.sideOffset == 0.0: DefaultPopoverSideOffset else: props.sideOffset

proc opposite*(side: PopoverSide): PopoverSide =
  case side
  of bottom: top
  of top: bottom
  of left: right
  of right: left

proc isVertical(side: PopoverSide): bool =
  side in {bottom, top}

proc alignOffset*(anchorExtent, contentExtent: float64, align: PopoverAlign): float64 =
  ## Start/center/end alignment along the anchor's cross axis.
  case align
  of alignStart: 0.0
  of alignCenter: (anchorExtent - contentExtent) / 2.0
  of alignEnd: anchorExtent - contentExtent

proc rawPosition(anchorX, anchorY, anchorWidth, anchorHeight, contentWidth,
                 contentHeight, sideOffset: float64, side: PopoverSide,
                 align: PopoverAlign): tuple[x, y: float64] =
  case side
  of bottom:
    (anchorX + alignOffset(anchorWidth, contentWidth, align),
     anchorY + anchorHeight + sideOffset)
  of top:
    (anchorX + alignOffset(anchorWidth, contentWidth, align),
     anchorY - sideOffset - contentHeight)
  of right:
    (anchorX + anchorWidth + sideOffset,
     anchorY + alignOffset(anchorHeight, contentHeight, align))
  of left:
    (anchorX - sideOffset - contentWidth,
     anchorY + alignOffset(anchorHeight, contentHeight, align))

proc fits(rect: tuple[x, y, width, height: float64], workX, workY, workWidth,
          workHeight: float64): bool =
  rect.x >= workX and rect.y >= workY and
    rect.x + rect.width <= workX + workWidth and
    rect.y + rect.height <= workY + workHeight

proc planPopoverPlacement*(anchorX, anchorY, anchorWidth, anchorHeight: float64,
    contentWidth, contentHeight: float64,
    workX, workY, workWidth, workHeight: float64,
    side: PopoverSide, align: PopoverAlign,
    sideOffset = DefaultPopoverSideOffset,
    margin = PopoverMargin): PopoverPlacement =
  ## Pure anchor math: use the requested side when the panel fits inside the
  ## work area, otherwise flip to the opposite side when that fits better, then
  ## clamp on both axes. No OS mutation and no second clamp downstream.
  for value in [anchorX, anchorY, anchorWidth, anchorHeight, contentWidth,
                contentHeight, workX, workY, workWidth, workHeight, sideOffset,
                margin]:
    if classify(value) in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "popover placement requires finite geometry")
  if anchorWidth <= 0.0 or anchorHeight <= 0.0 or contentWidth <= 0.0 or
      contentHeight < MinPopoverContentHeight or workWidth <= 0.0 or
      workHeight <= 0.0 or sideOffset < 0.0 or margin < 0.0:
    raise newException(ValueError, "popover placement requires a positive anchor, content and work area")
  let left = workX + margin
  let top = workY + margin
  let right = workX + workWidth - margin
  let bottom = workY + workHeight - margin
  let areaWidth = right - left
  let areaHeight = bottom - top
  if areaWidth <= 0.0 or areaHeight <= 0.0:
    raise newException(ValueError, "popover work area is smaller than its margin")
  if contentWidth > areaWidth or contentHeight > areaHeight:
    # The caller must refuse the open before publishing; never clip.
    raise newException(ValueError, "popover content does not fit the work area")
  var width = contentWidth
  var height = contentHeight
  var pos = rawPosition(anchorX, anchorY, anchorWidth, anchorHeight, width,
    height, sideOffset, side, align)
  var usedSide = side
  var flipped = false
  var rect = (x: pos.x, y: pos.y, width: width, height: height)
  if not fits(rect, left, top, areaWidth, areaHeight):
    let other = opposite(side)
    let otherPos = rawPosition(anchorX, anchorY, anchorWidth, anchorHeight,
      width, height, sideOffset, other, align)
    let otherRect = (x: otherPos.x, y: otherPos.y, width: width, height: height)
    if fits(otherRect, left, top, areaWidth, areaHeight):
      pos = otherPos
      usedSide = other
      flipped = true
      rect = otherRect
  var x = pos.x
  var y = pos.y
  if x < left: x = left
  if y < top: y = top
  if x + width > right: x = right - width
  if y + height > bottom: y = bottom - height
  result = PopoverPlacement(x: x, y: y, width: width, height: height,
    usedSide: usedSide, flipped: flipped)

proc dismissAllowed*(props: PopoverProps, dismiss: PopoverDismiss): bool =
  ## Every dismissal is advisory for a controlled popover; the caller decides.
  ## Kept as one typed gate so a future capability cannot bypass the request
  ## path by writing accepted state.
  discard props
  discard dismiss
  true
