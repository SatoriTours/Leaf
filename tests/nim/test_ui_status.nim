import std/[unittest,options]
import leaf/[core,styles,host_protocol,backend,native_theme]
import leaf/backends/win32/capabilities
import leaf/ui as standard

suite "standard Progress and keyboard hints":
  test "progress preserves explicit integer percent in strict and compatible modes":
    for value in [0,1,50,99,100]:
      let n=standard.progress(value,key="progress")
      check n.kind==NodeKind.progress
      for policy in [nativeStrict,hostCompatible]:
        let p=normalizeHostProps(n,policy).normalized
        check p.standardUi.get.role==UiRole.progress
        check p.control.progress.get==float64(value)
        check p.layout.height.get.value==8
        check p.layout.width.get.kind==dkFill
    for value in [-1,101]:
      expect UiError:discard standard.progress(value)

  test "compatible normalization cannot clamp required standard progress semantics":
    for value in ["bad","NaN","-1","101","1.5"]:
      for policy in [nativeStrict,hostCompatible]:
        expect UiError:discard normalizeHostProps(core.ui(NodeKind.progress,
          attributes=style({"ui_role":"progress","value":value})),policy)
    for policy in [nativeStrict,hostCompatible]:
      expect UiError:discard normalizeHostProps(core.ui(NodeKind.progress,
        attributes=style({"ui_role":"progress"})),policy)
    # Legacy compatible progress keeps its documented coercion.
    check normalizeHostProps(core.ui(NodeKind.progress,attributes=style({"value":"101"})),hostCompatible).normalized.control.progress.get==100

  test "KbdGroup is real row layout and Kbd is noninteractive literal text":
    let n=standard.kbdGroup(@[standard.kbd("Ctrl"),standard.kbd("K")])
    let p=normalizeProps(n)
    check n.kind==NodeKind.row
    check p.layout.gap.get==4
    check p.standardUi.get.role==UiRole.kbdGroup
    let hint=normalizeProps(n.children[0])
    check hint.standardUi.get.role==UiRole.kbd
    check hint.control.label.get=="Ctrl"
    check hint.layout.height.get.value==20
    check n.children[0].handler(click)==nil
    expect UiError:discard checkTypedCapabilities("hint",NodeKind.row,p,win32Capabilities(systemTheme))

  test "display roles cannot smuggle actions, unsupported variant or required semantics":
    for (kind,attrs) in [
      (NodeKind.progress,style({"ui_role":"progress","value":"50","ui_indeterminate":"true"})),
      (NodeKind.progress,style({"ui_role":"progress","value":"50","ui_variant":"destructive"})),
      (NodeKind.tag,style({"ui_role":"kbd","ui_size":"lg"}))]:
      for policy in [nativeStrict,hostCompatible]:
        expect UiError:discard normalizeHostProps(core.ui(kind,attributes=attrs),policy)
    expect UiError:discard normalizeProps(core.ui(NodeKind.tag,text="K",
      attributes=style({"ui_role":"kbd"}),onClick=proc(e:Event)=discard))
