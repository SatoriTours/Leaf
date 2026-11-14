import std/[unittest,options,tables]
import leaf/[core,styles,host_protocol]
import leaf/ui as standard

suite "standard single-line input groups":
  test "group and addon require real group semantics under both policies":
    for role in ["inputGroup","inputGroupAddon"]:
      for policy in [nativeStrict,hostCompatible]:
        let p=normalizeHostProps(core.ui(NodeKind.row,text="Address",
          attributes=style({"ui_role":role})),policy).normalized
        check $p.standardUi.get.role==role
        check p.accessibility.label.get=="Address"
  test "addon text stays static and rejects unsupported states":
    for policy in [nativeStrict,hostCompatible]:
      let p=normalizeHostProps(core.ui(NodeKind.text,text="https://",
        attributes=style({"ui_role":"inputGroupText"})),policy).normalized
      check $p.standardUi.get.role=="inputGroupText"
      for attrs in [style({"ui_role":"inputGroupText","ui_invalid":"true"}),
          style({"ui_role":"inputGroup","ui_size":"sm"})]:
        expect UiError:discard normalizeHostProps(core.ui(NodeKind.row,attributes=attrs),policy)
  test "composition preserves controlled edit contract without mutating the input":
    var seen=""
    let change:Callback=proc(e:Event)=seen=e.value
    let submit:Callback=proc(e:Event)=seen="submitted"
    let input=standard.input("draft",key="edit",placeholder="Host",onChange=change,
      onSubmit=submit,invalid=true,resetToken=9)
    let group=standard.inputGroup(input,prefix="https://",suffix=".dev",key="address",label="Address")
    check group.children.len==3
    let editor=group.children[1]
    check input.styles["height"]=="36"
    check editor.styles["height"]=="34"
    check editor.key=="edit" and editor.text=="draft" and editor.placeholder=="Host"
    check normalizeProps(editor).control.resetToken.get==9
    check normalizeProps(editor).standardUi.get.invalid
    editor.handler(EventKind.change)(Event(kind:EventKind.change,value:"new"))
    check seen=="new"
    editor.handler(EventKind.submit)(Event(kind:EventKind.submit))
    check seen=="submitted"
    expect UiError:discard standard.inputGroup(standard.textarea("multiline"))
    expect UiError:discard standard.inputGroup(standard.button("Not an editor"))
