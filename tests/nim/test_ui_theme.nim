import std/[unittest,options,tables]
import leaf/[core,styles,host_protocol,backend,native_theme]
import leaf/backends/win32/capabilities
import leaf/ui as standard
import leaf/ui/theme

proc mounted(h,parent:uint64,node:Node):MountedEntity =
  MountedEntity(handle:NodeHandle(h),parent:NodeHandle(parent),kind:node.kind,
    props:normalizeProps(node))
proc tree(items:varargs[MountedEntity]):Table[NodeHandle,MountedEntity] =
  for item in items:result[item.handle]=item

suite "runtime standard theme contract":
  test "explicit root mode remains typed in both host policies":
    let node=standard.theme(UiColorMode.dark,standard.input("Draft",key="edit"),key="theme")
    check node.kind==NodeKind.column
    check node.children.len==1
    for policy in [nativeStrict,hostCompatible]:
      let props=normalizeHostProps(node,policy).normalized
      check props.standardUi.get.role==UiRole.theme
      check props.standardUi.get.colorMode==some(UiColorMode.dark)
      check checkTypedCapabilities("theme",NodeKind.column,props,win32Capabilities(shadcnLight),strict).len==0
      expect UiError:discard checkTypedCapabilities("theme",NodeKind.column,props,win32Capabilities(systemTheme))
      expect UiError:discard checkTypedCapabilities("theme",NodeKind.column,props,win32Capabilities(matsuDark))

  test "root mode overrides only this window and absence restores initial choice":
    let dark=mounted(1,0,standard.theme(UiColorMode.dark,standard.input("A")))
    let light=mounted(1,0,standard.theme(UiColorMode.light,standard.input("B")))
    check resolveTheme(tree(dark),shadcnLight)==shadcnDark
    check resolveTheme(tree(light),shadcnDark)==shadcnLight
    check resolveTheme(tree(mounted(1,0,standard.input("C"))),shadcnDark)==shadcnDark
    check resolveTheme(tree(),systemTheme)==systemTheme
    expect UiError:discard resolveTheme(tree(dark),matsuLight)

  test "nested and competing window modes are rejected rather than applied globally":
    let root=mounted(1,0,standard.theme(UiColorMode.dark,standard.input("A")))
    let nested=mounted(2,1,standard.theme(UiColorMode.light,standard.input("B")))
    let other=mounted(3,0,standard.theme(UiColorMode.light,standard.input("C")))
    expect UiError:discard resolveTheme(tree(root,nested),shadcnLight)
    expect UiError:discard resolveTheme(tree(root,other),shadcnLight)

  test "mode cannot be malformed, omitted or attached to another role":
    for attrs in [style({"ui_role":"theme"}),
        style({"ui_role":"theme","ui_color_mode":"auto"}),
        style({"ui_role":"field","ui_color_mode":"dark"})]:
      for policy in [nativeStrict,hostCompatible]:
        expect UiError:discard normalizeHostProps(ui(NodeKind.column,attributes=attrs),policy)
    let node=ui(NodeKind.input,attributes=style({"ui_role":"theme","ui_color_mode":"dark"}))
    expect UiError:discard normalizeProps(node)
