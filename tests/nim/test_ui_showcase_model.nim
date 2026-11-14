import std/unittest
import ../../examples/ui_showcase/model

suite "standard UI settings example":
  test "editing never saves until explicitly submitted":
    let initial=SettingsModel(name:"Leaf",savedName:"Leaf")
    let edited=initial.editName("中文 😀")
    check edited.dirty
    check edited.savedName=="Leaf"
    let saved=edited.saveSettings
    check not saved.dirty
    check saved.saveCount==1
    check saved.savedName=="中文 😀"

  test "invalid submit preserves draft and cancel resets native input":
    let initial=SettingsModel(name:"Leaf",savedName:"Leaf")
    let invalid=initial.editName("  ").saveSettings
    check invalid.nameInvalid
    check invalid.name=="  "
    check invalid.saveCount==0
    check invalid.savedName=="Leaf"
    let cancelled=invalid.cancelSettings
    check not cancelled.dirty
    check not cancelled.nameInvalid
    check cancelled.name=="Leaf"
    check cancelled.reset==1

  test "biography is a separate saved draft and cancel restores both fields":
    let initial=SettingsModel(name:"Leaf",savedName:"Leaf",bio:"旧简介",savedBio:"旧简介")
    let edited=initial.editBio("新简介\r\n😀").editName("新名字")
    check edited.dirty
    check edited.bio=="新简介\n😀"
    check edited.savedBio=="旧简介"
    let saved=edited.saveSettings
    check not saved.dirty
    check saved.savedBio=="新简介\n😀"
    let cancelled=edited.cancelSettings
    check cancelled.bio=="旧简介"
    check cancelled.name=="Leaf"
    check not cancelled.dirty
    check cancelled.reset==1

  test "optional bio accepts 160 Unicode code points but rejects 161 preserving draft":
    var text=""
    for i in 0..<160: text.add("😀")
    let initial=SettingsModel(name:"Leaf",savedName:"Leaf")
    let valid=initial.editBio(text).saveSettings
    check not valid.bioInvalid
    check valid.savedBio==text
    check valid.saveCount==1
    let invalid=valid.editBio(text & "中").editName("Changed").saveSettings
    check invalid.bioInvalid
    check invalid.bio==text & "中"
    check invalid.savedBio==text
    check invalid.savedName=="Leaf"
    check invalid.saveCount==1
    check not invalid.cancelSettings.bioInvalid
    check not initial.editBio("").saveSettings.bioInvalid
