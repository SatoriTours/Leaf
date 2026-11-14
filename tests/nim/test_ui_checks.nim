import std/[unittest, options]
import leaf/[core, styles, host_protocol, backend, native_theme]
import leaf/backends/win32/capabilities
import leaf/ui as standard
import leaf/ui/appearance

suite "standard checkbox and switch contract":
  test "checkbox preserves controlled checked events and native semantics":
    var received=false
    let node=standard.checkbox("接收通知",false,key="notice",invalid=true,
      onChange=proc(e: Event) = received=e.checked)
    let p=normalizeProps(node)
    check node.kind==NodeKind.checkbox
    check p.standardUi.get.role==UiRole.checkbox
    check p.standardUi.get.invalid
    check not p.control.checked.get
    check p.layout.height.get.value==20
    node.handler(change)(Event(kind:change,checked:true))
    check received
    check normalizeHostProps(node,hostCompatible).normalized.standardUi==p.standardUi
    check checkTypedCapabilities("notice",node.kind,p,win32Capabilities(shadcnDark),strict).len==0

  test "switch supports only upstream normal and small sizes":
    for size in [UiSize.normal,UiSize.sm]:
      let node=standard.switch("自动同步",true,size=size)
      let p=normalizeProps(node)
      check node.kind==NodeKind.toggle
      check p.standardUi.get.role==UiRole.switch
      check p.standardUi.get.size==size
      check p.control.checked.get
      check p.layout.height.get.value==20
    for size in [UiSize.xs,UiSize.lg,UiSize.icon]:
      expect UiError: discard normalizeProps(standard.switch("同步",false,size=size))

  test "disabled checks suppress callbacks rather than merely looking disabled":
    var events=0
    let cb:Callback=proc(e:Event)=inc events
    for node in [standard.checkbox("禁用复选",true,onChange=cb,disabled=true),
        standard.switch("禁用开关",false,onChange=cb,disabled=true)]:
      check node.disabled
      check node.handler(change)==nil
      check not normalizeProps(node).control.enabled.get
    check events==0

  test "unsupported check semantics fail in strict and compatible modes":
    for (kind,attrs) in [
      (NodeKind.checkbox,style({"ui_role":"switch"})),
      (NodeKind.toggle,style({"ui_role":"checkbox"})),
      (NodeKind.checkbox,style({"ui_role":"checkbox","ui_size":"sm"})),
      (NodeKind.toggle,style({"ui_role":"switch","ui_invalid":"true"})),
      (NodeKind.toggle,style({"ui_role":"switch","ui_loading":"true"})),
      (NodeKind.checkbox,style({"ui_role":"checkbox","ui_indeterminate":"true"}))]:
      for mode in [nativeStrict,hostCompatible]:
        expect UiError: discard normalizeHostProps(core.ui(kind,text="label",attributes=attrs),mode)
    expect UiError:
      let node=standard.checkbox("旧主题不支持标准语义",false)
      discard checkTypedCapabilities("box",node.kind,normalizeProps(node),win32Capabilities(matsuLight),strict)

  test "check palette follows Neutral and composites disabled opacity once":
    let white=srgb(1,1,1)
    let off=checkAppearance(UiColorMode.light,UiRole.checkbox,white)
    check off.fill==0xffffff'u32
    check off.border==0xe5e5e5'u32
    let on=checkAppearance(UiColorMode.light,UiRole.checkbox,white,checked=true)
    check on.fill==0x171717'u32
    check on.border==0x171717'u32
    check on.mark==0xfafafa'u32
    let dim=checkAppearance(UiColorMode.light,UiRole.checkbox,white,checked=true,disabled=true)
    check dim.fill==0x8b8b8b'u32
    check dim.text==0x858585'u32
    let switchOff=checkAppearance(UiColorMode.dark,UiRole.switch,srgb(10.0/255,10.0/255,10.0/255))
    check switchOff.fill==0x272727'u32
    check switchOff.mark==0xfafafa'u32
    let switchOn=checkAppearance(UiColorMode.dark,UiRole.switch,white,checked=true)
    check switchOn.fill==0xe5e5e5'u32
    check switchOn.mark==0x171717'u32
    let error=checkAppearance(UiColorMode.light,UiRole.checkbox,white,invalid=true)
    check error.border!=off.border
    check error.ring!=off.ring
