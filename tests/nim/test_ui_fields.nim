import std/[unittest,tables,options,strutils]
import leaf/[core,styles,backend]
import leaf/ui/fields
import leaf/ui as standard

proc item(id,parent:uint64,role:UiRole,label="",index=0,invalid=false):MountedEntity =
  let node=case role
    of UiRole.field:standard.field(@[])
    of UiRole.label:standard.label(label)
    of UiRole.input:standard.input(label,invalid=invalid)
    of UiRole.textarea:standard.textarea(label,invalid=invalid)
    of UiRole.checkbox:standard.checkbox(label,false,invalid=invalid)
    of UiRole.switch:standard.switch(label,false)
    of UiRole.fieldDescription:standard.fieldDescription(label)
    of UiRole.fieldError:standard.fieldError(label)
    else:raise newException(ValueError,"Unsupported test role")
  MountedEntity(handle:NodeHandle(id),parent:NodeHandle(parent),index:index,
    kind:node.kind,props:normalizeProps(node))
proc tree(items:varargs[MountedEntity]):Table[NodeHandle,MountedEntity] =
  for i in items:result[i.handle]=i

suite "standard Field accessible associations":
  test "label and ordered description/error stay with one controlled native input":
    let links=resolveFields(tree(item(1,0,UiRole.field),
      item(2,1,UiRole.label,"Display name"),item(3,1,UiRole.input,index=1),
      item(4,1,UiRole.fieldDescription,"Visible to others",2),
      item(5,1,UiRole.fieldError,"Name is required",3)))
    require NodeHandle(3) in links
    let link=links[NodeHandle(3)]
    check link.name=="Display name"
    check link.label==NodeHandle(2)
    check link.details== @[NodeHandle(4),NodeHandle(5)]
    check link.help=="Visible to others\nName is required"
    check link.invalid

  test "nested fields isolate labels and invalid state; empty fields remain layout":
    let links=resolveFields(tree(item(1,0,UiRole.field),
      item(2,1,UiRole.label,"Outer"),item(3,1,UiRole.input,index=1),
      item(4,1,UiRole.field,index=2),item(5,4,UiRole.label,"Inner"),
      item(6,4,UiRole.textarea,index=1,invalid=true),item(7,4,UiRole.fieldDescription,"Inner help",2),
      item(8,1,UiRole.field,index=3)))
    check links.len==2
    check links[NodeHandle(3)].name=="Outer"
    check links[NodeHandle(3)].help==""
    check not links[NodeHandle(3)].invalid
    check links[NodeHandle(6)].name=="Inner"
    check links[NodeHandle(6)].help=="Inner help"
    check links[NodeHandle(6)].invalid

  test "ambiguous control and label scopes fail rather than guess":
    expect UiError:discard resolveFields(tree(item(1,0,UiRole.field),
      item(2,1,UiRole.input),item(3,1,UiRole.textarea,index=1)))
    expect UiError:discard resolveFields(tree(item(1,0,UiRole.field),
      item(2,1,UiRole.label,"A"),item(3,1,UiRole.label,"B",1),item(4,1,UiRole.input,index=2)))

  test "boolean controls preserve their own caption and unbound controls are untouched":
    let links=resolveFields(tree(item(1,0,UiRole.field),
      item(2,1,UiRole.label,"Preferences"),item(3,1,UiRole.checkbox,"Receive updates",1),
      item(4,0,UiRole.input,index=1)))
    check links.len==1
    check links[NodeHandle(3)].name=="Receive updates"
    check links[NodeHandle(3)].label==NodeHandle(2)

  test "removed messages and labels produce no stale payload":
    let links=resolveFields(tree(item(1,0,UiRole.field),item(3,1,UiRole.input)))
    check links[NodeHandle(3)].name==""
    check links[NodeHandle(3)].label==NoHandle
    check links[NodeHandle(3)].details.len==0
    check links[NodeHandle(3)].help==""
    check not links[NodeHandle(3)].invalid

  test "combined help is bounded before any native annotation effect":
    let part=repeat('x',MaxStringBytes div 2+1)
    expect UiError:discard resolveFields(tree(item(1,0,UiRole.field),item(2,1,UiRole.input),
      item(3,1,UiRole.fieldDescription,part,1),item(4,1,UiRole.fieldDescription,part,2)))

  test "unrooted cycles and missing parents are rejected":
    expect UiError:discard resolveFields(tree(item(1,1,UiRole.field)))
    expect UiError:discard resolveFields(tree(item(1,99,UiRole.field)))
