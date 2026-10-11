import std/[unittest, options]
import leaf/[core, native_edit]

proc textValue(value: string): ControlValue =
  ControlValue(text: value, checked: false, isCheck: false)

proc checkValue(checked: bool): ControlValue =
  ControlValue(text: "", checked: checked, isCheck: true)

proc noSelection(): Selection16 = Selection16(anchor: 0, caret: 0)

suite "Native controlled editor state machine":
  test "zero diff rejection resets editor":
    var state = newEditorState(textValue("7"))
    state.observeEditor(textValue("x"), compositionNone,
      Selection16(anchor: 1, caret: 1), 1)
    state.acceptModel(textValue("7"), 2)
    let effects = state.settleEditor(1)
    check effects.len == 1
    check effects[0].kind == setText
    check effects[0].value.text == "7"
    check not effects[0].force

    var formatted = newEditorState(textValue("7"))
    formatted.observeEditor(textValue(" 7 "), compositionNone,
      Selection16(anchor: 3, caret: 3), 1)
    formatted.acceptModel(textValue("7"), 2)
    let formattedEffects = formatted.settleEditor(1)
    check formattedEffects.len == 1
    check formattedEffects[0].value.text == "7"
    check formattedEffects[0].selection.caret == 1

  test "same text ack preserves selection and composition":
    var state = newEditorState(textValue("a"))
    state.observeEditor(textValue("a"), compositionNone,
      Selection16(anchor: 1, caret: 1), 1)
    state.acceptModel(textValue("a"), 1)
    check state.settleEditor(1).len == 0
    check state.selection.caret == 1

    var queued = newEditorState(textValue(""))
    queued.observeEditor(textValue("a"), compositionNone,
      Selection16(anchor: 1, caret: 1), 1)
    queued.observeEditor(textValue("ab"), compositionNone,
      Selection16(anchor: 2, caret: 2), 2)
    queued.acceptModel(textValue("ab"), 1)
    check queued.settleEditor(1).len == 0
    check queued.settleEditor(2).len == 0

    var check = newEditorState(checkValue(true))
    check.observeEditor(checkValue(false), compositionNone, noSelection(), 1)
    check.acceptModel(checkValue(true), 1)
    let checkEffects = check.settleEditor(1)
    check checkEffects.len == 1
    check checkEffects[0].kind == setChecked
    check checkEffects[0].value.checked

  test "composition keeps only the last successful conflict and syncs at end":
    var state = newEditorState(textValue(""))
    state.observeEditor(textValue("a"), compositionStart,
      Selection16(anchor: 1, caret: 1), 1)
    state.acceptModel(textValue("A"), 1)
    check state.conflict.get.text == "A"
    check state.settleEditor(1).len == 0

    state.observeEditor(textValue("ab"), compositionUpdate,
      Selection16(anchor: 2, caret: 2), 2)
    state.acceptModel(textValue("AB"), 2)
    check state.conflict.get.text == "AB"
    # A failed candidate never calls acceptModel; the last successful value stays.
    check state.conflict.get.text == "AB"
    check state.settleEditor(2).len == 0

    state.observeEditor(textValue("abc"), compositionResult,
      Selection16(anchor: 3, caret: 3), 3)
    state.acceptModel(textValue("ABC"), 3)
    check state.settleEditor(3).len == 0

    state.observeEditor(textValue("abc"), compositionEnd,
      Selection16(anchor: 3, caret: 3), 4)
    state.acceptModel(textValue("ABC"), 4)
    let effects = state.settleEditor(4)
    check effects.len == 1
    check effects[0].kind == setText
    check effects[0].value.text == "ABC"
    check state.conflict.isNone

  test "no conflict leaves the default IME behaviour alone":
    var state = newEditorState(textValue("x"))
    state.observeEditor(textValue("x"), compositionUpdate,
      Selection16(anchor: 1, caret: 1), 1)
    state.acceptModel(textValue("x"), 1)
    check state.conflict.isNone
    check state.settleEditor(1).len == 0

  test "successful same value reset forces cancel and setText once":
    var state = newEditorState(textValue("same"))
    state.observeEditor(textValue("same"), compositionUpdate,
      Selection16(anchor: 1, caret: 1), 1)
    state.acceptModel(textValue("same"), 2, some(1'u64))
    check state.pendingReset.get == 1
    check state.settleEditor(1).len == 0

    let effects = state.resetEffects()
    check effects.len == 3
    check effects[0].kind == forceCancelComposition
    check effects[1].kind == setText
    check effects[1].force
    check effects[1].value.text == "same"
    check effects[2].kind == setSelection
    check effects[2].selection.anchor == 4
    check effects[2].selection.caret == 4
    # Generation alone must not consume the token.
    check state.consumedResetToken == 0
    check state.resetEffects().len == 3

    state.completeReset(1)
    check state.consumedResetToken == 1
    check state.pendingReset.isNone
    check state.resetEffects().len == 0

    # Same token, rollback, zero or removal must not cancel again.
    state.acceptModel(textValue("same"), 3, some(1'u64))
    check state.resetEffects().len == 0
    state.acceptModel(textValue("same"), 4, none(uint64))
    check state.resetEffects().len == 0
    # A higher token may reset again.
    state.acceptModel(textValue("same"), 5, some(2'u64))
    check state.resetEffects().len == 3
    state.completeReset(2)
    check state.consumedResetToken == 2

  test "failed candidate does not record a reset token":
    var state = newEditorState(textValue("x"))
    state.observeEditor(textValue("x"), compositionNone, noSelection(), 1)
    # Candidate failed: acceptModel is never called.
    check state.pendingReset.isNone
    check state.resetEffects().len == 0
    # Retrying the same token after a real success takes effect.
    state.acceptModel(textValue("x"), 2, some(1'u64))
    check state.pendingReset.get == 1
    check state.resetEffects().len == 3

  test "selection clamp keeps the common prefix and never splits surrogates":
    var state = newEditorState(textValue("7"))
    state.observeEditor(textValue(" 7 "), compositionNone,
      Selection16(anchor: 3, caret: 3), 1)
    state.acceptModel(textValue("7"), 2)
    let effects = state.settleEditor(1)
    check effects[0].selection.anchor == 1
    check effects[0].selection.caret == 1

    # "😀a" (2 UTF-16 units for the emoji) rejected back to "😀".
    var emoji = newEditorState(textValue("\u{1F600}"))
    emoji.observeEditor(textValue("\u{1F600}a"), compositionNone,
      Selection16(anchor: 3, caret: 3), 1)
    emoji.acceptModel(textValue("\u{1F600}"), 2)
    let emojiEffects = emoji.settleEditor(1)
    check emojiEffects.len == 1
    check emojiEffects[0].selection.caret == 2
    check emojiEffects[0].selection.anchor == 2
  test "composition end followed by a newer normal edit keeps the latest accepted":
    var state = newEditorState(textValue(""))
    state.observeEditor(textValue("a"), compositionUpdate,
      Selection16(anchor: 1, caret: 1), 1)
    state.acceptModel(textValue("A"), 1)
    check state.conflict.get.text == "A"
    state.observeEditor(textValue("a"), compositionEnd,
      Selection16(anchor: 1, caret: 1), 2)
    state.observeEditor(textValue("ab"), compositionNone,
      Selection16(anchor: 2, caret: 2), 3)
    # The older End candidate is settled first and must not setter.
    state.acceptModel(textValue("A"), 2)
    check state.settleEditor(2).len == 0
    # The newer normal edit is the authoritative accepted value.
    state.acceptModel(textValue("AB"), 3)
    let effects = state.settleEditor(3)
    check state.accepted.text == "AB"
    check effects.len == 1
    check effects[0].kind == setText
    check effects[0].value.text == "AB"

  test "outstanding reset token watermark never regresses":
    var state = newEditorState(textValue("same"))
    state.acceptModel(textValue("same"), 1, some(2'u64))
    check state.pendingReset.get == 2
    # Same, lower, zero and removed tokens never lower an outstanding request.
    state.acceptModel(textValue("same"), 2, some(2'u64))
    check state.pendingReset.get == 2
    state.acceptModel(textValue("same"), 3, some(1'u64))
    check state.pendingReset.get == 2
    state.acceptModel(textValue("same"), 4, some(0'u64))
    check state.pendingReset.get == 2
    state.acceptModel(textValue("same"), 5, none(uint64))
    check state.pendingReset.get == 2
    check state.resetEffects().len == 3
    # Completing a non-outstanding token does not consume it.
    state.completeReset(1)
    check state.consumedResetToken == 0
    check state.resetEffects().len == 3
    state.completeReset(2)
    check state.consumedResetToken == 2
    check state.resetEffects().len == 0
    # A consumed token never repeats; a genuinely higher token resets again.
    state.acceptModel(textValue("same"), 6, some(2'u64))
    check state.resetEffects().len == 0
    state.acceptModel(textValue("same"), 7, some(3'u64))
    check state.resetEffects().len == 3
    state.completeReset(3)
    check state.consumedResetToken == 3

  test "common prefix still clamps surrogate boundaries":
    var state = newEditorState(textValue("\u{1F603}"))
    state.observeEditor(textValue("\u{1F600}x"), compositionNone,
      Selection16(anchor: 1, caret: 1), 1)
    state.acceptModel(textValue("\u{1F603}"), 1)
    let effects = state.settleEditor(1)
    check effects.len == 1
    check effects[0].selection.anchor == 0
    check effects[0].selection.caret == 0


suite "reset binding observation retirement":
  test "successful reset settles the observations invalidated with the old binding":
    var state = newEditorState(ControlValue(text: "old"))
    state.observeEditor(ControlValue(text: "queued"), compositionNone, Selection16(), 7)
    state.acceptModel(ControlValue(text: "reset"), 2, some(1'u64))
    check state.latestObserved > state.lastSettled
    state.completeReset(1)
    check state.lastSettled == state.latestObserved
