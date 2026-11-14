import std/[unittest,options]
import leaf
import leaf/styles
import ../../examples/ui_showcase/catalog_view

proc app():Runtime = newRuntime(componentApplication(catalogDescription(),"Catalog"))
proc click(rt:Runtime,key:string) = discard rt.dispatch(key,Event(kind:EventKind.click))
proc change(rt:Runtime,key,value:string) = discard rt.dispatch(key,Event(kind:EventKind.change,value:value))

suite "standard component catalog":
  test "navigation preserves controlled drafts and theme without retaining off-page animation":
    let rt=app();defer:rt.closeRuntime()
    check rt.find("catalog-title").node.text=="标准组件目录"
    rt.change("catalog-name","Draft 中文")
    rt.click("nav-groups")
    check rt.find("catalog-page").node.text=="组合控件"
    rt.change("catalog-address","example")
    rt.click("catalog-mode")
    rt.click("nav-form")
    check rt.find("catalog-name").node.text=="Draft 中文"
    check rt.find("catalog-mode").node.text=="切换到浅色"
    rt.click("nav-groups")
    check rt.find("catalog-address").node.text=="example"
    check not rt.animationPumpPending
    rt.click("nav-animation")
    check rt.animationPumpPending
    rt.click("nav-feedback")
    check not rt.animationPumpPending

  test "form validation preserves draft and save/cancel use in-memory settings":
    let rt=app();defer:rt.closeRuntime()
    rt.change("catalog-name","")
    rt.change("catalog-bio","草稿")
    rt.click("catalog-save")
    check rt.find("catalog-name-error").node.text=="名称不能为空。"
    check rt.find("catalog-bio").node.text=="草稿"
    rt.change("catalog-name","New name")
    rt.click("catalog-save")
    check rt.find("catalog-save-state").node.text=="已保存到内存"
    rt.change("catalog-name","Unsaved")
    rt.click("catalog-cancel")
    check rt.find("catalog-name").node.text=="New name"

  test "feedback and animation actions are actual state changes":
    let rt=app();defer:rt.closeRuntime()
    rt.click("nav-feedback")
    for i in 0..<5:rt.click("catalog-progress-next")
    check normalizeProps(rt.find("catalog-progress").node).control.progress.get==100.0
    check rt.find("catalog-progress-next").node.disabled
    rt.click("nav-empty")
    rt.click("catalog-create")
    check rt.find("catalog-empty-state").node.text=="已创建示例项目"
    rt.click("nav-animation")
    check rt.animationPumpPending
    rt.click("catalog-loaded")
    check not rt.animationPumpPending
    check rt.find("catalog-animation-state").node.text=="内容已加载"
    rt.click("catalog-loaded")
    check rt.animationPumpPending

  test "boolean preferences and grouped actions survive navigation":
    let rt=app();defer:rt.closeRuntime()
    discard rt.dispatch("catalog-check",Event(kind:EventKind.change,checked:true))
    discard rt.dispatch("catalog-switch",Event(kind:EventKind.change,checked:false))
    rt.click("nav-groups")
    rt.click("catalog-increase");rt.click("catalog-increase");rt.click("catalog-decrease")
    check rt.find("catalog-count").node.text=="计数：1"
    rt.click("catalog-count-reset")
    check rt.find("catalog-count").node.text=="计数：0"
    rt.click("nav-form")
    check normalizeProps(rt.find("catalog-check").node).control.checked.get
    check not normalizeProps(rt.find("catalog-switch").node).control.checked.get
