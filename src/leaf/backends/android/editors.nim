## Android-private coordination of the shared native_edit state machine.
## This module has no Runtime, JNI, View or business callback. Prepared model
## values are owned before accept; native effects run only at ordinary bounds.
import std/[tables, options, unicode]
import ../../[core, backend, native_edit]

type
  AndroidEditEffects* = proc(handle:NodeHandle,effects:seq[EditEffect]) {.closure.}
  AndroidEditorWrite* = object
    handle*: NodeHandle
    binding*: uint64
    effects*: seq[EditEffect]
  EditorCell = ref object
    kind: NodeKind
    binding: uint64
    state: EditorState
  PreparedEditor = object
    handle: NodeHandle
    cell: EditorCell
    model: PreparedModelAccept
    token: Option[uint64]
    observed: uint64
    effects: seq[EditEffect]
    binding: uint64
    installed: ControlValue
    selection: Selection16
    phase: CompositionPhase
  EditorFrame = ref object
    cells: Table[NodeHandle,EditorCell]
    models: seq[PreparedEditor]
  AndroidEditors* = ref object
    current, pending, retired: EditorFrame

proc newAndroidEditors*(): AndroidEditors =
  AndroidEditors(current:EditorFrame())

proc model(entity:MountedEntity): ControlValue =
  if entity.kind in {checkbox,toggle}:
    ControlValue(isCheck:true,checked:entity.props.control.checked.get(false))
  else: ControlValue(text:entity.props.control.value.get(""))

proc remember(cell:EditorCell,effects:seq[EditEffect]) =
  # Called only after the complete native effect sequence succeeded. A partial
  # failure keeps the reset unconsumed; the owning Session must fault/freeze.
  for effect in effects:
    case effect.kind
    of forceCancelComposition: cell.state.phase=compositionNone
    of setText,setChecked:
      cell.state.native=effect.value
      cell.state.selection=effect.selection
    of setSelection: cell.state.selection=effect.selection

proc prepareEditors*(editors:AndroidEditors,
    entities:Table[NodeHandle,MountedEntity]): seq[AndroidEditorWrite] =
  if editors.pending!=nil: fail("Android editors already have a pending model")
  editors.retired=nil
  let frame=EditorFrame()
  for handle,entity in entities:
    if entity.kind notin {input,checkbox,toggle}: continue
    let value=entity.model()
    let fresh=not editors.current.cells.hasKey(handle)
    let cell=if fresh: EditorCell(kind:entity.kind,binding:1,state:newEditorState(value))
             else: editors.current.cells.getOrDefault(handle)
    if cell.kind!=entity.kind: fail("Android editor handle changed control kind")
    frame.cells[handle]=cell
    var entry=PreparedEditor(handle:handle,cell:cell,binding:cell.binding,
      token:entity.props.control.resetToken,
      observed:cell.state.latestObserved,
      # Own both potential values now. Accept selects the conflict using the
      # latest observed phase, including genuine reentrant edits during apply.
      model:PreparedModelAccept(accepted:value,conflict:some(value)))
    if fresh:
      entry.effects= @[EditEffect(kind:(if value.isCheck: setChecked else: setText),
        value:value,selection:Selection16())]
      # A newly created native control has no composition to cancel. This cell
      # is private to the candidate and only survives successful installation.
      if entry.token.isSome: cell.state.consumedResetToken=entry.token.get
    else:
      if entry.token.isSome and entry.token.get>cell.state.consumedResetToken and
          (cell.state.pendingReset.isNone or entry.token.get>cell.state.pendingReset.get):
        if entry.binding==high(uint64): fail("Android editor binding exhausted")
        inc entry.binding
      let reset=cell.state.pendingReset.isSome or
        (entry.token.isSome and entry.token.get>cell.state.consumedResetToken)
      if not reset and cell.state.phase in {compositionNone,compositionEnd} and
          cell.state.latestObserved<=cell.state.lastSettled:
        var preview=cell.state
        preview.acceptModel(value,cell.state.acceptedRevision)
        entry.effects=preview.settleEditor(preview.latestObserved)
    if entry.effects.len>0:
      let installed=EditorCell(state:cell.state)
      installed.remember(entry.effects)
      entry.installed=installed.state.native
      entry.selection=installed.state.selection
      entry.phase=installed.state.phase
    frame.models.add(entry)
    result.add(AndroidEditorWrite(handle:handle,binding:entry.binding,effects:entry.effects))
  editors.pending=frame

proc preparedReplayWrites*(editors:AndroidEditors): seq[AndroidEditorWrite] =
  if editors.pending==nil: return
  for entry in editors.pending.models:
    let value=entry.model.accepted
    result.add(AndroidEditorWrite(handle:entry.handle,binding:entry.binding,
      effects: @[EditEffect(kind:(if value.isCheck: setChecked else: setText),value:value)]))

proc acceptEditors*(editors:AndroidEditors,revision:uint64) {.raises:[].} =
  if editors.pending==nil: return
  for entry in editors.pending.models.mitems:
    let cell=entry.cell
    if cell.state.phase==compositionNone or entry.model.accepted==cell.state.native:
      entry.model.conflict=none(ControlValue)
    cell.state.acceptPreparedModel(entry.model,revision,entry.token)
    cell.binding=entry.binding
    # Keep observations that arrived after preparation. Programmatic setters
    # themselves are suppressed per View by the platform adapter.
    if cell.state.latestObserved==entry.observed and entry.effects.len>0:
      cell.state.native=move(entry.installed)
      cell.state.selection=entry.selection
      cell.state.phase=entry.phase
  swap(editors.retired,editors.current)
  swap(editors.current,editors.pending)

proc discardEditors*(editors:AndroidEditors) = editors.pending=nil

proc bindingReady*(editors:AndroidEditors,handle:NodeHandle): bool =
  let cell=editors.current.cells.getOrDefault(handle)
  cell!=nil and cell.state.pendingReset.isNone

proc bindingGeneration*(editors:AndroidEditors,handle:NodeHandle): uint64 =
  let cell=editors.current.cells.getOrDefault(handle)
  if cell==nil: 0'u64 else: cell.binding

proc observeSelection*(editors:AndroidEditors,handle:NodeHandle,selection:Selection16) =
  # A native selection query is a fact, not a candidate model or business event.
  # Keep it even if a later prepared model is rejected. Reset owns its own tail.
  let cell=editors.current.cells.getOrDefault(handle)
  if cell!=nil and selection.anchor>=0 and selection.caret>=0:
    cell.state.selection=selection

proc scalarText(value:string): bool =
  if value.len>MaxStringBytes or validateUtf8(value) != -1: return false
  var canonicalBytes=0
  for rune in value.runes:
    let code=int(rune)
    if code<0 or code>0x10FFFF or code in 0xD800..0xDFFF: return false
    canonicalBytes += (if code<=0x7F: 1 elif code<=0x7FF: 2 elif code<=0xFFFF: 3 else: 4)
  canonicalBytes==value.len # Reject any overlong encoding accepted by stdlib.

proc canObserveEdit*(editors:AndroidEditors,handle:NodeHandle,sequence:uint64,
    value:ControlValue,phase:CompositionPhase,selection:Selection16): bool =
  if not editors.bindingReady(handle): return false
  let cell=editors.current.cells.getOrDefault(handle)
  if sequence<=cell.state.latestObserved or value.isCheck!=(cell.kind in {checkbox,toggle}):
    return false
  if not value.isCheck and not scalarText(value.text): return false
  if selection.anchor<0 or selection.caret<0: return false
  if value.isCheck and phase!=compositionNone: return false
  true

proc observeEdit*(editors:AndroidEditors,handle:NodeHandle,sequence:uint64,
    value:ControlValue,phase:CompositionPhase,selection:Selection16): bool =
  if not editors.canObserveEdit(handle,sequence,value,phase,selection): return false
  editors.current.cells.getOrDefault(handle).state.observeEditor(value,phase,selection,sequence)
  true

proc settleEdit*(editors:AndroidEditors,handle:NodeHandle,sequence:uint64,
    apply:AndroidEditEffects) =
  if not editors.bindingReady(handle): return
  let cell=editors.current.cells.getOrDefault(handle)
  let effects=cell.state.settleEditor(sequence)
  if effects.len>0:
    apply(handle,effects)
    cell.remember(effects)
  if sequence==cell.state.latestObserved and cell.state.phase==compositionEnd:
    cell.state.phase=compositionNone

proc flushEditorResets*(editors:AndroidEditors,apply:AndroidEditEffects) =
  for handle,cell in editors.current.cells:
    if cell.state.pendingReset.isNone: continue
    let token=cell.state.pendingReset.get
    let effects=cell.state.resetEffects()
    apply(handle,effects)
    cell.remember(effects)
    cell.state.completeReset(token)

proc replayEditors*(editors:AndroidEditors) =
  # Invoke only after a successful accepted native replay. Session rebind then
  # rejects the old event epoch independently of these fresh local sequences.
  let replay=EditorFrame()
  for handle,cell in editors.current.cells:
    var state=newEditorState(cell.state.accepted)
    state.acceptedRevision=cell.state.acceptedRevision
    state.consumedResetToken=cell.state.consumedResetToken
    state.pendingReset=cell.state.pendingReset
    replay.cells[handle]=EditorCell(kind:cell.kind,binding:cell.binding,state:state)
  editors.current=replay
  editors.pending=nil
  editors.retired=nil
