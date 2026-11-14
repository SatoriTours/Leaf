import std/[unittest,options]
import leaf
import leaf/[styles,host_protocol]

suite "standard Alert contract":
  test "alert carries native group name and destructive variant in both host policies":
    for policy in [nativeStrict,hostCompatible]:
      for variant in ["default","destructive"]:
        let n=core.ui(NodeKind.column,text="Warning\nDetails",attributes=style({"ui_role":"alert","ui_variant":variant}))
        let p=normalizeHostProps(n,policy).normalized
        check $p.standardUi.get.role=="alert"
        check p.accessibility.label.get=="Warning\nDetails"
        check $p.standardUi.get.variant==variant

  test "title and description preserve literal text and reject interactions":
    for role in ["alertTitle","alertDescription"]:
      let n=core.ui(NodeKind.text,text="A & 中文",attributes=style({"ui_role":role}))
      check normalizeProps(n).accessibility.label.get=="A & 中文"
      expect UiError:discard core.ui(NodeKind.text,text="Action",attributes=style({"ui_role":role}),onClick=proc(e:Event)=discard)
    for variant in ["outline","secondary","ghost","link"]:
      expect UiError:discard normalizeProps(core.ui(NodeKind.column,text="Warning",attributes=style({"ui_role":"alert","ui_variant":variant})))
    expect UiError:discard normalizeProps(core.ui(NodeKind.column,text="",attributes=style({"ui_role":"alert"})))

import leaf/ui as standard
suite "Alert text composition":
  test "public constructors compose spoken text and fixed horizontal/vertical insets":
    let n=standard.alert(@[standard.alertTitle("Warning"),standard.alertDescription("Details")],key="alert",variant=UiVariant.destructive)
    let p=normalizeProps(n)
    check n.key=="alert"
    check p.accessibility.label.get=="Warning\nDetails"
    check p.layout.padding.get==12
    check p.layout.width.get.kind==dkFill
    check p.standardUi.get.variant==UiVariant.destructive
    expect UiError:discard standard.alert(@[])
    expect UiError:discard standard.alert(@[standard.button("Not supported")])
    expect UiError:discard standard.alert(@[standard.alertTitle("A"),standard.alertTitle("B")])
    expect UiError:discard standard.alert(@[standard.alertDescription("Body"),standard.alertTitle("Title")])
