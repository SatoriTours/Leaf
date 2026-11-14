## Pure single-select contract: typed option model, validation, candidate
## navigation, popup anchoring and request retirement. No OS objects, no Node
## references, no callbacks: every refusal is a reason string or a ValueError so
## the caller raises its own error type.
import std/[math, strutils]

const
  MaxSelectOptions* = 1000
    ## Bounded candidate list; deeper lists are rejected, never truncated.
  MinSelectWidth* = 80.0
  DefaultSelectWidth* = 180.0
    ## Upstream new-york-v4 SelectTrigger is a fixed 180px control.
  MaxSelectWidth* = 1024.0
  SelectPopupGap* = 4.0
    ## Distance between the trigger and its anchored popup.
  SelectPopupMaxRows* = 8
    ## Upstream viewport caps the list; the popup scrolls instead of growing.
  MinSelectItemHeight* = 16.0
  DefaultSelectItemHeight* = 32.0
    ## Text plus the upstream item 8px insets, in DIP.

type
  SelectOption* = object
    ## One candidate. The key is the stable identity and the controlled value;
    ## the label is display text only, so duplicate labels stay distinct.
    key*: string
    label*: string
    disabled*: bool

  SelectProps* = object
    ## Typed select sidecar carried next to the ordinary node properties.
    ## open and value are the caller's accepted state; nothing in the native
    ## layer changes them on its own.
    open*: bool
    value*: string
      ## Accepted option key; "" asks the trigger to show the placeholder.
    placeholder*: string
    label*: string
      ## Accessible name prefix; "" means the trigger is named by its value.
    options*: seq[SelectOption]
    width*: float64
      ## 0 asks for the default trigger width.

  SelectNoticeKind* {.pure.} = enum
    ## What the native layer may ask for. Navigation is not a notice: a
    ## candidate move is transient and never reaches the business layer.
    snNone = 0, snOpen, snClose, snCommit

  SelectNotice* = object
    ## One recorded native request for one staged revision. The option key makes
    ## the request retire instead of selecting a slot that has been reordered,
    ## replaced or removed in the meantime.
    kind*: SelectNoticeKind
    optionKey*: string
    stage*: uint64

  SelectPlacement* = object
    ## Pure popup geometry in DIP. firstRow/rows describe the visible slice of
    ## the candidate list; nothing downstream re-clamps.
    x*, y*, width*, height*: float64
    flipped*: bool
    rows*: int
    scrollRange*: int
      ## Rows that do not fit; 0 means every candidate is visible.

proc optionIndex*(props: SelectProps, key: string): int =
  ## Stable-key lookup; never by display index or label text.
  if key.len == 0: return -1
  for index, option in props.options:
    if option.key == key: return index
  -1

proc usable*(props: SelectProps, index: int): bool =
  index >= 0 and index < props.options.len and not props.options[index].disabled

proc usableCount*(props: SelectProps): int =
  for option in props.options:
    if not option.disabled: inc result

proc invalidSelectReason*(props: SelectProps): string =
  ## "" when the typed select description is internally valid. The same rules
  ## run on construction, on the host wire and in the tests.
  let width = props.width
  if classify(width) in {fcNan, fcInf, fcNegInf}:
    return "select width is not finite"
  if width != 0.0 and (width < MinSelectWidth or width > MaxSelectWidth):
    return "select width must be 0 or in " & $MinSelectWidth & ".." & $MaxSelectWidth
  if props.options.len == 0:
    return "select requires at least one option"
  if props.options.len > MaxSelectOptions:
    return "select options exceed " & $MaxSelectOptions
  var keys: seq[string]
  for option in props.options:
    if option.key.len == 0: return "select option key must not be empty"
    if option.label.len == 0: return "select option label must not be empty"
    if option.key in keys:
      return "select option keys must be unique: " & option.key
    keys.add(option.key)
  if props.usableCount == 0:
    return "select requires at least one enabled option"
  if props.value.len != 0:
    let index = props.optionIndex(props.value)
    if index < 0:
      return "select value is not one of the options: " & props.value
    if props.options[index].disabled:
      return "select value names a disabled option: " & props.value
  ""

proc selectWidth*(props: SelectProps): float64 =
  if props.width == 0.0: DefaultSelectWidth else: props.width

proc selectedIndex*(props: SelectProps): int =
  props.optionIndex(props.value)

proc displayLabel*(props: SelectProps): string =
  ## Text the trigger shows: the accepted option label, else the placeholder.
  let index = props.selectedIndex
  if props.usable(index): props.options[index].label
  else: props.placeholder

proc accessibleName*(props: SelectProps): string =
  ## Never encodes state in the name: the label and the visible text are the
  ## same strings a sighted user reads.
  let text = props.displayLabel
  if props.label.len == 0: text
  elif text.len == 0: props.label
  else: props.label & ": " & text

proc initialCandidate*(props: SelectProps): int =
  ## The accepted value while it is usable, else the first usable option.
  if props.usable(props.selectedIndex): return props.selectedIndex
  for index, option in props.options:
    if not option.disabled: return index
  -1

proc stepCandidate*(props: SelectProps, current: int, direction: int): int =
  ## One Up/Down step with wraparound, skipping disabled options. Returns -1
  ## only when no option is usable, so a keyboard loop cannot spin forever.
  let count = props.options.len
  if count == 0 or direction == 0: return -1
  var cursor = current
  if cursor < 0 or cursor >= count:
    cursor = if direction > 0: -1 else: count
  for _ in 0 ..< count:
    cursor = (cursor + direction + count) mod count
    if not props.options[cursor].disabled: return cursor
  -1

proc moveCandidate*(props: SelectProps, current, steps: int): int =
  ## Bounded repeated step (PageUp/PageDown and wheel navigation reuse it).
  if steps == 0: return (if props.usable(current): current else: props.initialCandidate)
  let direction = if steps > 0: 1 else: -1
  var candidate = current
  for _ in 0 ..< abs(steps):
    let next = props.stepCandidate(candidate, direction)
    if next < 0: return candidate
    candidate = next
  candidate

proc edgeCandidate*(props: SelectProps, last: bool): int =
  if last:
    for index in countdown(props.options.high, 0):
      if not props.options[index].disabled: return index
  else:
    for index, option in props.options:
      if not option.disabled: return index
  -1

proc typeaheadCandidate*(props: SelectProps, prefix: string, current: int): int =
  ## Case-insensitive label prefix match starting after the current candidate
  ## and wrapping once; disabled options are skipped. The current candidate is
  ## returned unchanged when nothing matches, so the caller may keep typing.
  if prefix.len == 0 or props.options.len == 0: return current
  let needle = prefix.toLowerAscii
  let count = props.options.len
  var cursor = current
  if cursor < 0 or cursor >= count: cursor = count - 1
  for _ in 0 ..< count:
    cursor = (cursor + 1) mod count
    if props.options[cursor].disabled: continue
    if props.options[cursor].label.toLowerAscii.startsWith(needle): return cursor
  current

proc candidateValue*(props: SelectProps, candidate: int): string =
  ## The value a commit request would carry, or "" when the candidate is not a
  ## usable option (empty keys are rejected, so "" is unambiguous).
  if props.usable(candidate): props.options[candidate].key else: ""

proc noticeValue*(props: SelectProps, notice: SelectNotice): string =
  ## A commit notice survives only while its exact option key is still an
  ## enabled option; a removed, reordered or disabled slot drops the request
  ## instead of selecting whatever now occupies that position.
  if notice.kind != snCommit: return ""
  let index = props.optionIndex(notice.optionKey)
  if not props.usable(index): return ""
  props.options[index].key

proc openRequestAllowed*(props: SelectProps): bool =
  props.usableCount > 0

proc planSelectPlacement*(anchorX, anchorY, anchorWidth, anchorHeight: float64,
    itemHeight: float64, itemCount: int,
    workX, workY, workWidth, workHeight: float64,
    maxRows = SelectPopupMaxRows, gap = SelectPopupGap): SelectPlacement =
  ## Pure anchor math: below the trigger when it fits, otherwise flipped above
  ## it, clamped into the monitor work area and capped to the whole rows that
  ## really fit. No OS mutation and no second clamp downstream.
  for value in [anchorX, anchorY, anchorWidth, anchorHeight, itemHeight, workX,
                workY, workWidth, workHeight]:
    if classify(value) in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "select placement requires finite geometry")
  if anchorWidth <= 0.0 or itemHeight < MinSelectItemHeight or itemCount <= 0 or
      workWidth <= 0.0 or workHeight <= 0.0:
    raise newException(ValueError,
      "select placement requires a positive anchor, row and work area")
  if maxRows < 1:
    raise newException(ValueError, "select placement requires at least one row")
  let content = itemHeight * float64(itemCount)
  let desired = min(content, itemHeight * float64(min(maxRows, itemCount)))
  let below = workY + workHeight - (anchorY + anchorHeight + gap)
  let above = anchorY - gap - workY
  let flip = below < desired and above > below
  var available = if flip: above else: below
  if available < itemHeight:
    # Neither side fits one row: keep the larger side and clamp the popup into
    # the work area; one reachable row is always better than a hidden list.
    available = max(itemHeight, if flip: above else: below)
  var height = min(desired, available)
  var rows = max(1, int(floor(height / itemHeight)))
  rows = min(rows, min(maxRows, itemCount))
  height = itemHeight * float64(rows)
  var width = min(anchorWidth, workWidth)
  var x = anchorX
  if x + width > workX + workWidth: x = workX + workWidth - width
  if x < workX: x = workX
  var y = if flip: anchorY - gap - height else: anchorY + anchorHeight + gap
  if y + height > workY + workHeight: y = workY + workHeight - height
  if y < workY: y = workY
  result = SelectPlacement(x: x, y: y, width: width, height: height,
    flipped: flip, rows: rows, scrollRange: max(0, itemCount - rows))

proc visibleRows*(firstRow, rows, itemCount: int): tuple[first, last: int] =
  ## Half-open row range that the current viewport really shows.
  let first = max(0, min(firstRow, max(0, itemCount - 1)))
  (first, min(itemCount, first + max(0, rows)))

proc scrollToCandidate*(candidate, firstRow, rows, itemCount: int): int =
  ## Minimal row offset that makes the candidate reachable, never past the last
  ## full page, so long lists stay reachable without hiding candidates.
  if candidate < 0 or itemCount <= 0 or rows <= 0: return 0
  let maxFirst = max(0, itemCount - rows)
  var first = max(0, min(firstRow, maxFirst))
  if candidate < first: first = candidate
  elif candidate >= first + rows: first = candidate - rows + 1
  max(0, min(first, maxFirst))

proc rowAt*(y, rowStartY, itemHeight: float64, itemCount: int): int =
  ## Row under a client-space point; -1 outside the candidate area.
  if itemCount <= 0 or itemHeight <= 0.0: return -1
  let offset = y - rowStartY
  if offset < 0.0: return -1
  let index = int(floor(offset / itemHeight))
  if index < 0 or index >= itemCount: -1 else: index

proc pageStep*(rows: int): int =
  ## PageUp/PageDown move a whole viewport minus one row so context stays.
  if rows <= 1: 1 else: rows - 1
