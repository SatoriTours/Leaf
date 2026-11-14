import std/[unittest,options]
import leaf/[core,styles,host_protocol]
import leaf/ui as standard

suite "standard horizontal button groups":
  test "group contract survives both host policies with an accessible name":
    let n=core.ui(NodeKind.row,text="Document actions",children= @[
      standard.button("Save"),standard.button("Cancel")],
      attributes=style({"ui_role":"buttonGroup"}))
    for policy in [nativeStrict,hostCompatible]:
      let p=normalizeHostProps(n,policy).normalized
      check $p.standardUi.get.role=="buttonGroup"
      check p.accessibility.label.get=="Document actions"

  test "groups reject unsupported content and group-level actions":
    for policy in [nativeStrict,hostCompatible]:
      for children in [newSeq[Node](),@[standard.input("draft")],
          @[standard.button("Small",size=UiSize.sm),standard.button("Normal")]]:
        expect UiError:
          discard standard.buttonGroup(children)
      expect UiError:
        discard normalizeHostProps(core.ui(NodeKind.row,disabled=true,
          children= @[standard.button("Save")],attributes=style({"ui_role":"buttonGroup"})),policy)
