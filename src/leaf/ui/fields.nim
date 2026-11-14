## Pure, scoped associations over the existing typed Field tree. No HWND or
## provider objects cross the Host protocol. Empty Fields remain layout groups.
import std/[tables,sets,algorithm,options,strutils]
import ../[core,backend,styles]

type
  FieldAssociation* = object
    label*: NodeHandle
    details*: seq[NodeHandle]
    name*, help*: string
    invalid*: bool
  FieldScope = object
    labels,controls,details:seq[NodeHandle]

proc resolveFields*(entities:Table[NodeHandle,MountedEntity]):Table[NodeHandle,FieldAssociation] =
  var children:Table[NodeHandle,seq[NodeHandle]]
  var scopes:Table[NodeHandle,FieldScope]
  for h,e in entities:
    if e.parent!=NoHandle and e.parent notin entities:fail("Field tree has an absent parent")
    children.mgetOrPut(e.parent,@[]).add(h)
  for siblings in children.mvalues:
    siblings.sort(proc(a,b:NodeHandle):int =
      result=cmp(entities[a].index,entities[b].index)
      if result==0:result=cmp(a.raw,b.raw))
  var seen:HashSet[NodeHandle]
  proc visit(h,owner:NodeHandle,depth:int) =
    if depth>MaxDepth or h in seen:fail("Field tree depth or cycle")
    seen.incl(h)
    let e=entities[h]
    var scope=owner
    if e.props.standardUi.isSome and e.props.standardUi.get.role in
        {UiRole.popover, UiRole.popoverContent}:
      # A popover body is a separate owned window: its labels and controls belong
      # to their own scopes, never to a field wrapping the trigger in the page.
      scope=NoHandle
    if e.props.standardUi.isSome:
      case e.props.standardUi.get.role
      of UiRole.field:
        scope=h
        scopes[h]=FieldScope()
      of UiRole.label:
        if scope!=NoHandle:scopes[scope].labels.add(h)
      of UiRole.input,UiRole.textarea,UiRole.checkbox,UiRole.switch:
        if scope!=NoHandle:scopes[scope].controls.add(h)
      of UiRole.fieldDescription,UiRole.fieldError:
        if scope!=NoHandle:scopes[scope].details.add(h)
      else:discard
    for child in children.getOrDefault(h):visit(child,scope,depth+1)
  for root in children.getOrDefault(NoHandle):visit(root,NoHandle,0)
  if seen.len!=entities.len:fail("Field tree has an unrooted cycle")
  for scope in scopes.values:
    if scope.controls.len==0:continue
    if scope.controls.len!=1 or scope.labels.len>1:
      fail("Field accessibility requires at most one label and one control per scope")
    let h=scope.controls[0]
    let control=entities[h]
    var link=FieldAssociation(invalid:control.props.standardUi.get.invalid)
    if scope.labels.len==1:
      link.label=scope.labels[0]
      link.name=entities[link.label].props.accessibility.label.get("")
    if control.kind in {NodeKind.checkbox,NodeKind.toggle} and
        control.props.control.label.get("").len>0:
      link.name=control.props.control.label.get
    var parts:seq[string]
    var helpBytes=0
    for detail in scope.details:
      let e=entities[detail]
      let value=e.props.accessibility.label.get("")
      if value.len==0:continue
      let separator=if parts.len==0:0 else:1
      if value.len>MaxStringBytes-helpBytes-separator:
        fail("Field combined help exceeds native string budget")
      helpBytes+=value.len+separator
      link.details.add(detail)
      parts.add(value)
      if e.props.standardUi.get.role==UiRole.fieldError:link.invalid=true
    link.help=parts.join("\n")
    result[h]=link
