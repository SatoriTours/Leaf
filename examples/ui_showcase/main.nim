## Native account settings. -d:leafDarkTheme selects dark Neutral.
import leaf
import ./[model, view]

const showcaseTheme = when defined(leafDarkTheme): shadcnDark else: shadcnLight

let Showcase=defineComponent[int,State[SettingsModel]]("StandardUiShowcase",
  proc(ctx: MountContext,p: int): State[SettingsModel] =
    # Start with an explicit unsaved example biography, as in the approved mock.
    ctx.state(SettingsModel(name:"Leaf 用户",savedName:"Leaf 用户",
      bio:"用简单的工具，认真做点有意思的事。",savedBio:"")),
  proc(ctx: ComponentContext,p: int,model: State[SettingsModel]): UiDescription =
    host(settingsView(ctx.value(model),
      onName=(proc(e: Event) = discard model.update(
        proc(v: SettingsModel): SettingsModel = v.editName(e.value))),
      onBio=(proc(e: Event) = discard model.update(
        proc(v: SettingsModel): SettingsModel = v.editBio(e.value))),
      onSave=(proc(e: Event) = discard model.update(
        proc(v: SettingsModel): SettingsModel = v.saveSettings)),
      onCancel=(proc(e: Event) = discard model.update(
        proc(v: SettingsModel): SettingsModel = v.cancelSettings)))))

let app=componentApplication(component(Showcase,0),"Leaf — 设置",640,720)
  .withNativeTheme(showcaseTheme)
quit run(app)
