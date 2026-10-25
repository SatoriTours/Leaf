import std/[unittest, options]
import leaf/[core, widgets, styles, backend, native_theme, host_protocol]
import leaf/backends/win32/capabilities

suite "Win32 theme capabilities are opt-in and kind-scoped":
  test "legacy system controls still reject required brand variants":
    expect UiError:
      discard checkTypedCapabilities("save", NodeKind.button,
        normalizeProps(button("Save")), win32Capabilities(), strict)

  test "themed push buttons support primary and secondary in strict mode":
    for theme in [matsuLight, matsuDark]:
      for variant in ["primary", "secondary", "default"]:
        check checkTypedCapabilities("save", NodeKind.button,
          normalizeProps(button("Save", variant=variant)),
          win32Capabilities(theme), strict).len == 0

  test "themed buttons do not falsely enable tag variants or decorations":
    expect UiError:
      discard checkTypedCapabilities("tag", NodeKind.tag,
        normalizeProps(tag("Tag")), win32Capabilities(matsuLight), strict)
    expect UiError:
      discard checkTypedCapabilities("save", NodeKind.button,
        normalizeProps(button("Save", styles=style({"radius": "12"}))),
        win32Capabilities(matsuLight), strict)

  test "effective native props preserve only the kind-scoped variants":
    let caps = win32Capabilities(matsuLight)
    let props = normalizeProps(button("Save"))
    check effectiveProps(caps, props, some(NodeKind.button)).control.variant == some(variantPrimary)
    check effectiveProps(caps, props, some(NodeKind.tag)).control.variant.isNone
    check effectiveProps(caps, props).control.variant.isNone

  test "themed semantic text and invalid input retain their variants":
    let caps = win32Capabilities(matsuLight)
    for variant in ["primary", "secondary", "danger"]:
      let node = ui(NodeKind.text, text="Status", attributes=style({"variant":variant}))
      let props = normalizeProps(node)
      check normalizeHostProps(node, hostCompatible).normalized.control.variant == props.control.variant
      check checkTypedCapabilities("status", NodeKind.text, props, caps, strict).len == 0
      check effectiveProps(caps, props, some(NodeKind.text)).control.variant == props.control.variant
    let invalid = normalizeProps(ui(NodeKind.input, text="", attributes=style({"variant":"danger"})))
    check checkTypedCapabilities("name", NodeKind.input, invalid, caps, strict).len == 0
    check effectiveProps(caps, invalid, some(NodeKind.input)).control.variant == some(variantDanger)
    expect UiError:
      discard checkTypedCapabilities("name", NodeKind.input,
        normalizeProps(ui(NodeKind.input, text="", attributes=style({"variant":"primary"}))), caps, strict)

  test "global variant support remains backwards compatible":
    var caps = win32Capabilities()
    caps.variants.incl variantPrimary
    check checkTypedCapabilities("tag", NodeKind.tag,
      normalizeProps(tag("Tag")), caps, strict).len == 0
