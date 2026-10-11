import std/unittest
import leaf/[core,widgets,components,component_description,view]
let Child=defineComponent[int,int]("Child",
  proc(ctx:MountContext,props:int):int=props,
  proc(ctx:ComponentContext,props,model:int):UiDescription=host(text($props)))
proc ordinary():Node=text("ordinary")
suite "mixed componentView DSL":
  test "layouts hold host and explicit component children with Nim control flow":
    let root=componentView:
      column:
        key:"root"
        styles:{"gap":"2"}
        text("host",key="text")
        if true:
          component(Child,1,key="child")
        for i in 0..<3:
          text($i)
        case 2
        of 2:
          row:
            ordinary()
        else:
          text("other")
    check root.kind==DescriptionKind.host
    check root.children.len==6
    check root.children[1].kind==DescriptionKind.component
    check root.children[5].children[0].kind==DescriptionKind.host
    check root.hostNode.key=="root"
  test "legacy view and empty column constructor keep their types":
    let legacy=view:
      column:
        text("legacy")
    check legacy.kind==NodeKind.column
    check column(@[]).kind==NodeKind.column
    let nested=componentView:
      host(legacy)
    check nested.children.len==1
  test "event and style properties keep the existing syntax":
    var clicks=0
    let root=componentView:
      button("run"):
        key:"button"
        onClick(e):
          inc clicks
    root.hostNode.handler(click)(Event(kind:click))
    check clicks==1
