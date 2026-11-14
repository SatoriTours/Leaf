import std/[unittest, options]
import leaf/[core, widgets, styles, backend, native_theme, host_protocol, native_edit]
import leaf/backends/win32/capabilities

suite "native notebook control contracts":
  test "Win32 multiline canonicalization preserves blank lines and existing CRLF":
    check nativeMultilineText("中文\n\n😀\r\n尾行\r终") == "中文\r\n\r\n😀\r\n尾行\r\n终"
    check nativeMultilineText("a\r\nb") == "a\r\nb"

  test "multiline remains explicit and a missing platform capability is rejected":
    let props = normalizeProps(input("第一行\n第二行", multiline = true))
    check props.control.multiline == some(true)
    check normalizeProps(input("single")).control.multiline.isNone
    check normalizeHostProps(input("body", multiline=true), hostCompatible).normalized.control.multiline == some(true)
    discard checkTypedCapabilities("body", NodeKind.input, props, win32Capabilities(), strict)
    var unsupported = win32Capabilities()
    unsupported.controls.excl(cfInputMultiline)
    expect UiError:
      discard checkTypedCapabilities("body", NodeKind.input, props, unsupported)

  test "themed surfaces and quiet buttons are declared per control kind":
    let caps = win32Capabilities(matsuLight)
    for node in [column(@[], variant = "primary"), row(@[], variant = "secondary"),
        button("quiet", variant = "ghost"), input("title", variant="primary"),
        input("body", multiline=true, variant="ghost")]:
      discard checkTypedCapabilities("node", node.kind, normalizeProps(node), caps, strict)
      check normalizeHostProps(node, hostCompatible).normalized.control.variant == normalizeProps(node).control.variant
    expect UiError:
      discard checkTypedCapabilities("node", NodeKind.column,
        normalizeProps(column(@[], variant = "primary")), win32Capabilities(), strict)
