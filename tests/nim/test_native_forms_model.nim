import std/unittest
import ../../examples/native_forms/model

suite "native form validation and saved snapshot":
  test "empty names keep the draft and do not increment submissions":
    let draft = FormModel(name: "  \t ", count: 3, notifications: true)
    let rejected = draft.saveForm()
    check rejected.name == "  \t "
    check rejected.count == 3
    check rejected.nameInvalid
    check not rejected.hasSaved

  test "saving records settings and detects changes and restoration":
    var saved = FormModel(name: "中文 😀", notifications: true).saveForm()
    check saved.count == 1
    check not saved.nameInvalid
    check not saved.formDirty
    saved.notifications = false
    check saved.formDirty
    saved.notifications = true
    check not saved.formDirty
    saved.name = "其他姓名"
    check saved.formDirty
    saved = saved.saveForm()
    check saved.count == 2
    check not saved.formDirty

  test "correcting an invalid name clears the error without losing prior save":
    var draft = FormModel(name: "原姓名").saveForm()
    draft.name = ""
    draft = draft.saveForm()
    check draft.nameInvalid
    check draft.count == 1
    draft.name = "原姓名"
    check not draft.nameInvalid
    check not draft.formDirty
