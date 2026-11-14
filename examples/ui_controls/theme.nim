## Window-local, declarative runtime palette demonstration.
## This separate entry leaves the account-settings product page unchanged.
import std/strutils
import leaf
import leaf/ui as standard

type ThemeModel=object
  mode:UiColorMode
  name,bio:string
  updates,notifications:bool
  resets:uint64

const initialMode=when defined(leafDarkTheme):UiColorMode.dark else:UiColorMode.light
proc initial():ThemeModel =
  ThemeModel(mode:initialMode,name:"Leaf 用户",
    bio:"第一行：保留原生编辑状态。\n第二行：试着切换浅色与深色。",updates:true)

let ThemeControls=defineComponent[int,State[ThemeModel]]("StandardRuntimeTheme",
  proc(ctx:MountContext,p:int):State[ThemeModel]=ctx.state(initial()),
  proc(ctx:ComponentContext,p:int,model:State[ThemeModel]):UiDescription =
    let m=ctx.value(model)
    let invalid=m.name.strip.len==0
    host(standard.theme(m.mode,column(@[
      column(@[text("主题切换",variant="primary"),
        standard.cardDescription("同一原生窗口，在浅色与深色 Neutral 之间切换。")],
        styles=style({"gap":"7","width":"full"})),
      standard.card(@[
        standard.cardHeader(@[standard.cardTitle("原生状态保留"),
          standard.cardDescription("编辑后切换主题，再试试撤销和键盘导航。")]),
        standard.cardContent(@[
          standard.field(@[standard.label("名称",key="name-label"),
            standard.input(m.name,key="name",invalid=invalid,resetToken=m.resets,
              onChange=proc(e:Event)=discard model.update(proc(old:ThemeModel):ThemeModel =
                result=old;result.name=e.value)),
            (if invalid:standard.fieldError("名称不能为空。",key="name-help")
             else:standard.fieldDescription("切换主题不会清空草稿、选区或撤销。",key="name-help"))],key="name-field"),
          standard.field(@[standard.label("简介",key="bio-label"),
            standard.textarea(m.bio,key="bio",height=96,resetToken=m.resets,
              onChange=proc(e:Event)=discard model.update(proc(old:ThemeModel):ThemeModel =
                result=old;result.bio=e.value)),
            standard.fieldDescription("原生多行 EDIT，保留 TextPattern 与 Undo。")],key="bio-field"),
          column(@[
            standard.checkbox("接收产品更新",m.updates,key="updates",
              onChange=proc(e:Event)=discard model.update(proc(old:ThemeModel):ThemeModel =
                result=old;result.updates=e.checked)),
            standard.switch("启用通知",m.notifications,key="notifications",
              onChange=proc(e:Event)=discard model.update(proc(old:ThemeModel):ThemeModel =
                result=old;result.notifications=e.checked))],styles=style({"gap":"8","width":"full"}))]),
        standard.cardFooter(@[
          standard.button((if m.mode==UiColorMode.light:"切换到深色" else:"切换到浅色"),
            key="mode",onClick=proc(e:Event)=discard model.update(proc(old:ThemeModel):ThemeModel =
              result=old;result.mode=(if old.mode==UiColorMode.light:UiColorMode.dark else:UiColorMode.light))),
          standard.button("重置文本",key="reset",variant=UiVariant.outline,
            onClick=proc(e:Event)=discard model.update(proc(old:ThemeModel):ThemeModel =
              result=old;result.name=initial().name;result.bio=initial().bio;inc result.resets))])]),
      standard.fieldDescription("仅作用于本窗口；不保存偏好，不更改系统主题。")
    ],key="page",styles=style({"padding":"24","gap":"20","width":"full"})),key="window-theme")))

const appTheme=when defined(leafDarkTheme):shadcnDark else:shadcnLight
quit run(componentApplication(component(ThemeControls,0),"Leaf — 主题切换",640,710)
  .withNativeTheme(appTheme))
