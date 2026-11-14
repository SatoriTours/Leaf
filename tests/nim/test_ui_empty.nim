import std/[unittest,options]
import leaf/[core,styles,host_protocol,backend,native_theme]
import leaf/backends/win32/capabilities
import leaf/ui as standard

suite "standard Empty native composition":
  test "Empty uses typed native columns, centered text and real child actions":
    var clicks=0
    let button=standard.button("创建",onClick=proc(e:Event)=inc clicks)
    let n=standard.empty(@[
      standard.emptyHeader(@[standard.emptyTitle("暂无项目"),standard.emptyDescription("创建第一个项目。")]),
      standard.emptyContent(@[button])],key="empty")
    let p=normalizeProps(n)
    check n.kind==NodeKind.column
    check p.standardUi.get.role==UiRole.empty
    check p.layout.padding.get==24
    check p.layout.gap.get==24
    check p.layout.align.get==alignCenter
    check normalizeProps(n.children[0]).layout.gap.get==8
    check normalizeProps(n.children[1]).layout.gap.get==16
    check n.children[0].children[0].kind==NodeKind.text
    check normalizeProps(n.children[0].children[0]).standardUi.get.role==UiRole.emptyTitle
    button.handler(click)(Event(kind:click))
    check clicks==1

  test "all Empty parts survive compatible normalization and reject legacy backends":
    for n in [standard.empty(@[]),standard.emptyHeader(@[]),standard.emptyTitle("Title"),
        standard.emptyDescription("Description"),standard.emptyContent(@[])]:
      let p=normalizeProps(n)
      check normalizeHostProps(n,hostCompatible).normalized.standardUi==p.standardUi
      check checkTypedCapabilities("empty",n.kind,p,win32Capabilities(shadcnLight),strict).len==0
      expect UiError:discard checkTypedCapabilities("empty",n.kind,p,win32Capabilities(matsuDark))

  test "unsupported Empty variants, media and direct actions are not silently dropped":
    for (kind,attrs) in [
      (NodeKind.column,style({"ui_role":"emptyTitle"})),
      (NodeKind.text,style({"ui_role":"emptyTitle","ui_variant":"destructive"})),
      (NodeKind.column,style({"ui_role":"empty","ui_size":"lg"})),
      (NodeKind.column,style({"ui_role":"empty","ui_media":"icon"})),
      (NodeKind.column,style({"ui_role":"emptyMedia"}))]:
      for policy in [hostCompatible,nativeStrict]:
        expect UiError:discard normalizeHostProps(core.ui(kind,attributes=attrs),policy)
    for policy in [hostCompatible,nativeStrict]:
      expect UiError:discard normalizeHostProps(core.ui(NodeKind.text,text="click",
        attributes=style({"ui_role":"emptyTitle"}),onClick=proc(e:Event)=discard),policy)
