import std/[unittest, options]
import leaf/[core, widgets, styles, host_protocol]

suite "Typed host properties":
  test "host_props_preserve_absence_unicode_and_list_metadata":
    check normalizeHostProps(text("你好"), hostCompatible).text == "你好"
    let empty = normalizeHostProps(text(""), hostCompatible)
    check empty.text == ""
    let decorated = normalizeHostProps(text("a", styles=style({"opacity":"0.5"})), hostCompatible)
    check decorated.normalized.decoration.opacity.get == 0.5
    check empty.normalized.decoration.opacity.isNone
    let editor = normalizeHostProps(input("中文", placeholder="搜索", resetToken=7), hostCompatible)
    check editor.normalized.control.resetToken.get == 7
    check editor.placeholder == "搜索"
    var keys: seq[string]
    for i in 0..<100000: keys.add($i)
    let rows = virtualList("items", keys, proc(i:int):Node = text($i), rowHeight=30, overscan=2)
    let props = normalizeHostProps(rows, hostCompatible)
    check props.list.isSome
    check props.list.get.itemCount == 100000
    check props.list.get.sourceGeneration == rows.listSource.generation
    check props.list.get.heightMode == HostHeightMode.uniform
    check props.list.get.rowHeight == 30
    check props.list.get.overscan == 2
  test "style_policies_preserve_platform_semantics":
    let full = normalizeHostProps(text("a", styles=style({"width":"full"})), hostCompatible)
    check full.normalized.layout.width.get.kind == dkFill
    let legacy = ui(NodeKind.text, text="legacy", attributes=style({"unknown_legacy":"ignored"}))
    check normalizeHostProps(legacy, hostCompatible).text == "legacy"
    expect UiError: discard normalizeHostProps(legacy, nativeStrict)
    expect UiError:
      discard normalizeHostProps(text("x",styles=style({"opacity":"nan"})),hostCompatible)
  test "event flags are typed and do not transport callbacks":
    let n = input("a", onChange=proc(e:Event)=discard, onSubmit=proc(e:Event)=discard)
    let props = normalizeHostProps(n,hostCompatible)
    check props.eventMask == (EventChangeMask or EventSubmitMask)
    check props.normalized.control.hasChange
    check props.normalized.control.hasSubmit
