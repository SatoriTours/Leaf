## Pure controlled-editor state machine. This module owns no native resources,
## no Runtime and no platform imports: it maps observed native edits and
## accepted model values to explicit edit effects (force cancel composition,
## set text, set checked, set selection).
##
## The state machine is deliberately additive: callers that never observe a
## composition or reset token keep the previous controlled-input behaviour.
import std/[options, unicode]
import ./core

type
  ControlValue* = object
    ## Backend-neutral control value. `isCheck` selects checkbox/toggle mode.
    text*: string
    checked*, isCheck*: bool

  Selection16* = object
    ## UTF-16 code unit selection range.
    anchor*, caret*: int

  EditorState* = object
    accepted*, native*: ControlValue
    phase*: CompositionPhase
    latestObserved*, lastSettled*, acceptedRevision*, consumedResetToken*: uint64
    conflict*: Option[ControlValue]
    pendingReset*: Option[uint64]
    selection*: Selection16

  EditEffectKind* = enum
    forceCancelComposition, setText, setChecked, setSelection

  EditEffect* = object
    kind*: EditEffectKind
    value*: ControlValue
    selection*: Selection16
    force*: bool

proc toUnits(text: string): seq[uint16] =
  ## UTF-16 code units for a Nim UTF-8 string.
  for rune in text.runes:
    let code = uint32(rune.int)
    if code <= 0xFFFF'u32:
      result.add(uint16(code))
    else:
      let value = code - 0x10000'u32
      result.add(uint16(0xD800'u32 or (value shr 10)))
      result.add(uint16(0xDC00'u32 or (value and 0x3FF'u32)))

proc utf16Len(text: string): int = toUnits(text).len

proc clampPos(pos, limit: int, units: seq[uint16]): int =
  ## Clamp a UTF-16 position to the new text boundary without splitting a
  ## surrogate pair. Applied to every position, including ones inside the
  ## common prefix, so a shared high surrogate can never leave the caret in
  ## the middle of a pair.
  result = max(0, min(pos, limit))
  if result > 0 and result < units.len and
      units[result] >= 0xDC00'u16 and units[result] <= 0xDFFF'u16:
    dec result

proc clampSelection(selection: Selection16, fromText, toText: string): Selection16 =
  ## Positions inside the common prefix are preserved; the rest clamp to the
  ## new text boundary. Every position still passes the UTF-16 boundary check.
  discard fromText
  let units = toUnits(toText)
  let limit = units.len
  Selection16(anchor: clampPos(selection.anchor, limit, units),
    caret: clampPos(selection.caret, limit, units))

proc newEditorState*(accepted: ControlValue): EditorState =
  ## Fresh editor state: native mirrors the accepted value, no composition,
  ## no observed sequence, no conflict and no pending reset.
  result.accepted = accepted
  result.native = accepted
  result.phase = compositionNone
  result.latestObserved = 0
  result.lastSettled = 0
  result.acceptedRevision = 0
  result.consumedResetToken = 0
  result.conflict = none(ControlValue)
  result.pendingReset = none(uint64)
  result.selection = Selection16(anchor: 0, caret: 0)

proc observeEditor*(s: var EditorState, value: ControlValue,
                    phase: CompositionPhase, selection: Selection16,
                    sequence: uint64) =
  ## Record one observed native edit. Conflicts are never written here: only a
  ## successful `acceptModel` may update the conflict.
  s.native = value
  s.phase = phase
  s.selection = selection
  if sequence > s.latestObserved: s.latestObserved = sequence

proc acceptModel*(s: var EditorState, value: ControlValue, revision: uint64,
                  resetToken: Option[uint64] = none(uint64)) =
  ## Record only a successfully accepted model value. A failed candidate never
  ## calls this, so the previous conflict and reset token are preserved.
  s.accepted = value
  s.acceptedRevision = revision
  # A successful accept outside composition makes the latest accepted value
  # authoritative: any older composition conflict must not override it.
  if s.phase == compositionNone:
    s.conflict = none(ControlValue)
  elif value != s.native:
    s.conflict = some(value)
  else:
    s.conflict = none(ControlValue)
  # The outstanding reset request is monotonic too: a lower, same, zero or
  # removed token must never lower a token that was already accepted but not
  # yet executed.
  if resetToken.isSome and resetToken.get > s.consumedResetToken and
      (s.pendingReset.isNone or resetToken.get > s.pendingReset.get):
    s.pendingReset = resetToken

proc settleEditor*(s: var EditorState, sequence: uint64): seq[EditEffect] =
  ## Handle a normal acknowledgement. Old or future sequences produce no
  ## setter; an unfinished composition produces none either. Same text keeps
  ## the selection and composition untouched.
  if sequence > s.latestObserved: return
  if sequence < s.latestObserved: return
  s.lastSettled = sequence
  if s.phase in {compositionStart, compositionUpdate, compositionResult}:
    return
  if s.phase == compositionEnd and s.conflict.isSome:
    let value = s.conflict.get
    s.conflict = none(ControlValue)
    if value.isCheck or s.native.isCheck:
      if s.native.checked != value.checked:
        result.add EditEffect(kind: setChecked, value: value,
          selection: s.selection, force: false)
    elif s.native.text != value.text:
      result.add EditEffect(kind: setText, value: value,
        selection: clampSelection(s.selection, s.native.text, value.text),
        force: false)
    return
  if s.native.isCheck or s.accepted.isCheck:
    if s.native.checked != s.accepted.checked:
      result.add EditEffect(kind: setChecked, value: s.accepted,
        selection: s.selection, force: false)
    return
  if s.native.text != s.accepted.text:
    result.add EditEffect(kind: setText, value: s.accepted,
      selection: clampSelection(s.selection, s.native.text, s.accepted.text),
      force: false)

proc resetEffects*(s: EditorState): seq[EditEffect] =
  ## Emit the explicit composition-cancel sequence for a pending reset token.
  ## Generation alone never consumes the token: only `completeReset` does.
  if s.pendingReset.isSome and s.pendingReset.get > s.consumedResetToken:
    let tail = utf16Len(s.accepted.text)
    let selection = Selection16(anchor: tail, caret: tail)
    result.add EditEffect(kind: forceCancelComposition, value: s.accepted,
      selection: selection, force: true)
    result.add EditEffect(kind: setText, value: s.accepted,
      selection: selection, force: true)
    result.add EditEffect(kind: setSelection, value: s.accepted,
      selection: selection, force: true)

proc completeReset*(s: var EditorState, token: uint64) =
  ## Consume the token only after every native effect has fully succeeded.
  if s.pendingReset.isSome and s.pendingReset.get == token and
      token > s.consumedResetToken:
    # A reset invalidates old binding events; none may keep the editor pending.
    s.lastSettled = s.latestObserved
    s.consumedResetToken = token
    s.pendingReset = none(uint64)
