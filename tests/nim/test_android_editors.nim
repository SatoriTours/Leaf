import std/[unittest, tables, options]
import leaf/[core, backend, native_edit]
import leaf/backends/android/editors

proc textModel(value: string, reset = none(uint64)): MountedEntity =
  result = MountedEntity(handle:NodeHandle(1),kind:input)
  result.props.control.value = some(value)
  result.props.control.resetToken = reset
proc models(entity: MountedEntity): Table[NodeHandle,MountedEntity] =
  result[entity.handle] = entity
proc initialize(value: string): AndroidEditors =
  result = newAndroidEditors()
  discard result.prepareEditors(models(textModel(value)))
  result.acceptEditors(1)
proc collect(target: ref seq[EditEffect]): AndroidEditEffects =
  result = proc(handle:NodeHandle,effects:seq[EditEffect]) =
    target[].add(effects)
proc textValue(value:string): ControlValue = ControlValue(text:value)

suite "Android controlled editor coordination":
  test "an older event acceptance cannot overwrite a later native edit":
    let e=initialize("7")
    check e.observeEdit(NodeHandle(1),1,textValue("a"),compositionNone,Selection16(caret:1))
    check e.observeEdit(NodeHandle(1),2,textValue("ab"),compositionNone,Selection16(caret:2))
    let p=e.prepareEditors(models(textModel("A")))
    check p.len==1 and p[0].effects.len==0
    e.acceptEditors(2)
    var effects: ref seq[EditEffect];new(effects)
    e.settleEdit(NodeHandle(1),1,collect(effects))
    check effects[].len==0
    discard e.prepareEditors(models(textModel("AB")))
    e.acceptEditors(3)
    e.settleEdit(NodeHandle(1),2,collect(effects))
    check effects[].len==1 and effects[][0].value.text=="AB"
    check effects[][0].selection.caret==2

  test "a rejected candidate cannot replace the last accepted composition conflict":
    let e=initialize("")
    check e.observeEdit(NodeHandle(1),1,textValue("拼"),compositionUpdate,Selection16(caret:1))
    discard e.prepareEditors(models(textModel("accepted")))
    e.acceptEditors(2)
    discard e.prepareEditors(models(textModel("rejected")))
    e.discardEditors()
    check e.observeEdit(NodeHandle(1),2,textValue("拼音"),compositionEnd,Selection16(caret:2))
    var effects: ref seq[EditEffect];new(effects)
    e.settleEdit(NodeHandle(1),2,collect(effects))
    check effects[].len==1 and effects[][0].value.text=="accepted"

  test "reset blocks stale binding until every native effect succeeds":
    let e=initialize("😀")
    check e.observeEdit(NodeHandle(1),1,textValue("😀"),compositionUpdate,Selection16(caret:2))
    discard e.prepareEditors(models(textModel("😀",some(1'u64))))
    e.acceptEditors(2)
    check not e.bindingReady(NodeHandle(1))
    check not e.observeEdit(NodeHandle(1),2,textValue("stale"),compositionNone,Selection16())
    var calls=0
    expect UiError:
      e.flushEditorResets(proc(handle:NodeHandle,effects:seq[EditEffect]) =
        inc calls
        check effects.len==3 and effects[0].kind==forceCancelComposition
        fail("native reset failed after cancel"))
    check not e.bindingReady(NodeHandle(1))
    var effects: ref seq[EditEffect];new(effects)
    e.flushEditorResets(collect(effects))
    check effects[].len==3 and effects[][2].selection.caret==2
    check e.bindingReady(NodeHandle(1))
    e.flushEditorResets(collect(effects))
    check effects[].len==3 and calls==1
    discard e.prepareEditors(models(textModel("😀",some(1'u64))))
    e.acceptEditors(3)
    e.flushEditorResets(collect(effects))
    check effects[].len==3 # Same token cannot fire twice.

  test "no-diff rejection restores accepted value and clamps UTF16 selection":
    let e=initialize("a😀")
    check e.observeEdit(NodeHandle(1),1,textValue("bad"),compositionNone,Selection16(anchor:2,caret:3))
    var effects: ref seq[EditEffect];new(effects)
    e.settleEdit(NodeHandle(1),1,collect(effects))
    check effects[].len==1 and effects[][0].value.text=="a😀"
    check effects[][0].selection.anchor==1 and effects[][0].selection.caret==3
    e.settleEdit(NodeHandle(1),1,collect(effects))
    check effects[].len==1 # Successful setter metadata prevents duplicate calls.

  test "replay resets edit sequences but preserves consumed reset tokens":
    let e=initialize("ok")
    discard e.prepareEditors(models(textModel("ok",some(5'u64))))
    e.acceptEditors(2)
    var effects: ref seq[EditEffect];new(effects)
    e.flushEditorResets(collect(effects))
    check effects[].len==3
    check e.observeEdit(NodeHandle(1),99,textValue("broken"),compositionUpdate,Selection16())
    e.replayEditors()
    check e.observeEdit(NodeHandle(1),1,textValue("ok"),compositionNone,Selection16())
    discard e.prepareEditors(models(textModel("ok",some(5'u64))))
    e.acceptEditors(3)
    e.flushEditorResets(collect(effects))
    check effects[].len==3

  test "a native observation during apply survives candidate acceptance":
    let e=initialize("old")
    discard e.prepareEditors(models(textModel("model")))
    check e.observeEdit(NodeHandle(1),1,textValue("new composition"),compositionStart,Selection16(caret:15))
    e.acceptEditors(2)
    var effects: ref seq[EditEffect];new(effects)
    e.settleEdit(NodeHandle(1),1,collect(effects))
    check effects[].len==0
    check e.observeEdit(NodeHandle(1),2,textValue("new composition"),compositionEnd,Selection16(caret:15))
    e.settleEdit(NodeHandle(1),2,collect(effects))
    check effects[].len==1 and effects[][0].value.text=="model"

  test "removed handles and wrong control types cannot receive native facts":
    let e=initialize("value")
    check not e.observeEdit(NodeHandle(1),1,ControlValue(isCheck:true,checked:true),compositionNone,Selection16())
    discard e.prepareEditors(initTable[NodeHandle,MountedEntity]())
    e.acceptEditors(2)
    check not e.bindingReady(NodeHandle(1))
    check not e.observeEdit(NodeHandle(1),1,textValue("old"),compositionNone,Selection16())

  test "checkbox acknowledgement and unrelated model changes use the shared effects":
    let e=newAndroidEditors()
    var entity=MountedEntity(handle:NodeHandle(2),kind:checkbox)
    entity.props.control.checked=some(false)
    discard e.prepareEditors(models(entity))
    e.acceptEditors(1)
    check e.observeEdit(entity.handle,1,ControlValue(isCheck:true,checked:true),compositionNone,Selection16())
    let pending=e.prepareEditors(models(entity))
    check pending[0].effects.len==0
    e.acceptEditors(2)
    var effects: ref seq[EditEffect];new(effects)
    e.settleEdit(entity.handle,1,collect(effects))
    check effects[].len==1 and effects[][0].kind==setChecked and not effects[][0].value.checked
    entity.props.control.checked=some(true)
    let change=e.prepareEditors(models(entity))
    check change[0].effects.len==1 and change[0].effects[0].value.checked
    e.acceptEditors(3)
    e.settleEdit(entity.handle,1,collect(effects))
    check effects[].len==1

  test "malformed text does not consume an otherwise usable observation sequence":
    let e=initialize("")
    for invalid in ["\xC0\x80","\xE0\x80\x80","\xED\xA0\x80","\xF4\x90\x80\x80","\xFF"]:
      check not e.observeEdit(NodeHandle(1),1,textValue(invalid),compositionNone,Selection16())
    check e.observeEdit(NodeHandle(1),1,textValue("中文\x00😀"),compositionNone,Selection16())
    check not e.observeEdit(NodeHandle(1),1,textValue("duplicate"),compositionNone,Selection16())

  test "discarded reset stays invisible and a fresh control consumes only its installed token":
    let e=initialize("value")
    discard e.prepareEditors(models(textModel("value",some(9'u64))))
    check e.bindingReady(NodeHandle(1))
    e.discardEditors()
    var effects: ref seq[EditEffect];new(effects)
    e.flushEditorResets(collect(effects))
    check effects[].len==0
    let fresh=newAndroidEditors()
    let writes=fresh.prepareEditors(models(textModel("value",some(9'u64))))
    check writes[0].effects.len==1 and writes[0].effects[0].kind==setText
    fresh.acceptEditors(1) # Platform already installed this fresh control.
    fresh.flushEditorResets(collect(effects))
    check effects[].len==0

  test "a reset advances the binding and never revives queued old binding events":
    let e=initialize("old")
    let before=e.bindingGeneration(NodeHandle(1))
    check before==1
    discard e.prepareEditors(models(textModel("reset",some(1'u64))))
    e.acceptEditors(2)
    check e.bindingGeneration(NodeHandle(1))==before+1
    check not e.bindingReady(NodeHandle(1))
    e.flushEditorResets(proc(handle:NodeHandle,effects:seq[EditEffect]) = discard)
    check e.bindingReady(NodeHandle(1))
    discard e.prepareEditors(models(textModel("reset",some(1'u64))))
    e.acceptEditors(3)
    check e.bindingGeneration(NodeHandle(1))==before+1
    discard e.prepareEditors(models(textModel("unused",some(2'u64))))
    e.discardEditors()
    check e.bindingGeneration(NodeHandle(1))==before+1
