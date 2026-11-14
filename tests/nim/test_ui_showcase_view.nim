import std/[unittest, options, sequtils, tables]
import leaf/[core, styles, host_protocol]
import leaf/ui as standard
import ../../examples/ui_showcase/[model, view]

proc flattened(node: Node): seq[Node] =
  result.add(node)
  for child in node.children: result.add(flattened(child))

suite "native account settings composition":
  test "account page has separate heading fields and no component gallery":
    let m=SettingsModel(name:"Leaf 用户",savedName:"Leaf 用户",bio:"草稿")
    let nodes=flattened(settingsView(m,nil,nil,nil,nil))
    for node in nodes:
      discard normalizeHostProps(node,nativeStrict)
    check nodes.countIt(it.kind==NodeKind.input)==2
    check nodes.countIt(it.kind==NodeKind.button)==2
    check nodes.countIt(it.text=="账户设置")==1
    check nodes.countIt(it.text=="公开资料")==1
    check nodes.countIt(it.text=="按钮变体")==0
    check nodes.filterIt(it.key=="bio")[0].attributes["multiline"]=="true"
    check normalizeProps(nodes.filterIt(it.key=="bio")[0]).layout.height.get.value==96
    check nodes.filterIt(it.key=="cancel")[0].text=="取消"
    check nodes.filterIt(it.key=="save")[0].text=="保存更改"

  test "clean draft disables both actions and invalid messages stay beside editors":
    let clean=SettingsModel(name:"Leaf",savedName:"Leaf")
    let cleanNodes=flattened(settingsView(clean,nil,nil,nil,nil))
    for node in cleanNodes.filterIt(it.kind==NodeKind.button): check node.disabled
    let invalidNodes=flattened(settingsView(clean.editName("").saveSettings,nil,nil,nil,nil))
    let message=invalidNodes.filterIt(it.key=="name-message")[0]
    check normalizeProps(message).standardUi.get.role==UiRole.fieldError
    check invalidNodes.filterIt(it.key=="name")[0].text==""
