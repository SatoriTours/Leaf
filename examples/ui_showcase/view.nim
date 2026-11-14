## Pure native account-page composition, separate from component ownership.
import leaf/[core, widgets]
import leaf/ui as standard
import ./model

proc settingsView*(m: SettingsModel, onName, onBio, onSave, onCancel: Callback): Node =
  column(@[
    column(@[
      text("账户设置",styles=style({"width":"full"}),
        variant="primary"),
      standard.cardDescription("管理你的公开资料与账户偏好。")
    ],styles=style({"gap":"7","width":"full"})),
    standard.card(@[
      standard.cardHeader(@[
        standard.cardTitle("公开资料"),
        standard.cardDescription("更新其他人看到的个人信息。")]),
      standard.cardContent(@[
        standard.field(@[
          standard.label("显示名称",key="name-label"),
          standard.input(m.name,key="name",placeholder="输入显示名称",invalid=m.nameInvalid,
            resetToken=m.reset,onChange=onName),
          (if m.nameInvalid:standard.fieldError("显示名称不能为空，草稿已保留。",key="name-message")
           else:standard.fieldDescription("这个名称将显示在你的个人资料中。",key="name-message"))
        ],key="name-field"),
        standard.field(@[
          standard.label("个人简介（选填）",key="bio-label"),
          standard.textarea(m.bio,key="bio",height=96,invalid=m.bioInvalid,
            resetToken=m.reset,onChange=onBio),
          (if m.bioInvalid:standard.fieldError("个人简介不能超过 160 字，草稿已保留。",key="bio-message")
           else:standard.fieldDescription("简短介绍一下你自己。最多 160 字。",key="bio-message"))
        ],key="bio-field")]),
      standard.cardFooter(@[
        column(@[text(if m.dirty:"有未保存的更改"
          elif m.saveCount>0:"更改已保存" else:"没有未保存的更改",
          variant="secondary")],styles=style({"width":"full"})),
        standard.button("取消",key="cancel",variant=UiVariant.outline,
          disabled=not m.dirty,onClick=onCancel),
        standard.button("保存更改",key="save",disabled=not m.dirty,onClick=onSave)])
    ],key="profile-card"),
    text("此示例仅保存内存状态，不写入磁盘或网络。",
      styles=style({"width":"full"}),variant="secondary")
  ],key="settings",styles=style({"padding":"32","gap":"24","width":"full"}))
