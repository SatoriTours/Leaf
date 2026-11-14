import std/[unittest,options,math]
import leaf/[core,styles,host_protocol,backend,native_theme]
import leaf/backends/win32/capabilities
import leaf/ui as standard
import leaf/ui/appearance

suite "standard noninteractive badge and separator":
  test "badge variants retain native text and never acquire button actions":
    for variant in UiVariant:
      let n=standard.badge("A & 中文",variant=variant,key="badge")
      let p=normalizeProps(n)
      check n.kind==NodeKind.tag
      check p.control.label.get=="A & 中文"
      check p.standardUi.get.role==UiRole.badge
      check p.standardUi.get.variant==variant
      check p.layout.height.get.value==22
      check n.handler(click)==nil
      for policy in [hostCompatible,nativeStrict]:
        check normalizeHostProps(n,policy).normalized.standardUi==p.standardUi
      expect UiError:discard checkTypedCapabilities("badge",n.kind,p,win32Capabilities(systemTheme))

  test "separators have one DIP thickness and explicit finite vertical extent":
    let h=normalizeProps(standard.separator())
    check h.standardUi.get.role==UiRole.separator
    check h.layout.height.get.value==1
    check h.layout.width.get.kind==dkFill
    let v=normalizeProps(standard.separator(vertical=true,length=32))
    check v.layout.width.get.value==1
    check v.layout.height.get.value==32
    for length in [0.0,-1.0,NaN,Inf,1000001.0]:
      expect UiError:discard standard.separator(vertical=true,length=length)
    expect UiError:discard standard.separator(decorative=false)

  test "required unsupported interaction and metadata are rejected":
    for (kind,attrs) in [
      (NodeKind.button,style({"ui_role":"badge"})),
      (NodeKind.tag,style({"ui_role":"badge","ui_size":"sm"})),
      (NodeKind.tag,style({"ui_role":"badge","ui_invalid":"true"})),
      (NodeKind.tag,style({"ui_role":"badge","ui_loading":"true"})),
      (NodeKind.separator,style({"ui_role":"separator","ui_variant":"outline"})),
      (NodeKind.separator,style({"ui_role":"separator","ui_decorative":"false"}))]:
      for policy in [nativeStrict,hostCompatible]:
        expect UiError:discard normalizeHostProps(core.ui(kind,attributes=attrs),policy)
    for policy in [nativeStrict,hostCompatible]:
      expect UiError:discard normalizeHostProps(core.ui(NodeKind.tag,text="action",
        attributes=style({"ui_role":"badge"}),onClick=proc(e:Event)=discard),policy)

  test "badge outline is transparent on dark cards rather than an Input face":
    let surface=srgb(23.0/255,23.0/255,23.0/255)
    let outline=badgeAppearance(UiColorMode.dark,UiVariant.outline,surface)
    check outline.fill==0x171717'u32
    check outline.border==0x2e2e2e'u32
    check outline.text==0xfafafa'u32
    let normal=badgeAppearance(UiColorMode.light,UiVariant.default,srgb(1,1,1))
    check normal.fill==0x171717'u32
    check normal.text==0xfafafa'u32
    let ghost=badgeAppearance(UiColorMode.light,UiVariant.ghost,srgb(1,1,1))
    check ghost.fill==0xffffff'u32 and ghost.border==0xffffff'u32
