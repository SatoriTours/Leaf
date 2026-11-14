## Noninteractive display primitives; real native text, not web links/actions.
import leaf
import leaf/ui as standard

type DisplayModel=object
  dark,changed:bool

let Display=defineComponent[int,State[DisplayModel]]("StandardDisplayPrimitives",
  proc(ctx:MountContext,p:int):State[DisplayModel]=ctx.state(DisplayModel()),
  proc(ctx:ComponentContext,p:int,state:State[DisplayModel]):UiDescription =
    let m=ctx.value(state)
    host(standard.theme((if m.dark:UiColorMode.dark else:UiColorMode.light),column(@[
      text("徽章与分隔线",variant="primary"),
      standard.cardDescription("非交互文字徽章与装饰性原生分隔线。"),
      standard.card(@[
        standard.cardHeader(@[standard.cardTitle("状态与分类"),
          standard.cardDescription("徽章不进入 Tab 顺序，链接配色不代表超链接。")]),
        standard.cardContent(@[
          row(@[standard.badge((if m.changed:"已更新" else:"默认徽章"),key="primary"),
            standard.badge("次要徽章",variant=UiVariant.secondary),
            standard.badge("危险提示",variant=UiVariant.destructive)],styles=style({"gap":"8"})),
          standard.separator(key="horizontal"),
          row(@[standard.badge("描边徽章",variant=UiVariant.outline),
            standard.badge("幽灵徽章",variant=UiVariant.ghost),
            standard.badge("链接配色",variant=UiVariant.link)],styles=style({"gap":"8"})),
          row(@[standard.badge("A & 中文",variant=UiVariant.outline),
            standard.separator(vertical=true,length=28,key="vertical"),
            standard.badge("完整原生文字",variant=UiVariant.secondary)],styles=style({"gap":"12","align":"center"}))]),
        standard.cardFooter(@[
          standard.button((if m.dark:"切换到浅色" else:"切换到深色"),key="mode",
            onClick=proc(e:Event)=discard state.update(proc(old:DisplayModel):DisplayModel =
              result=old;result.dark=not old.dark)),
          standard.button("更新徽章",key="update",variant=UiVariant.outline,
            onClick=proc(e:Event)=discard state.update(proc(old:DisplayModel):DisplayModel =
              result=old;result.changed=not old.changed))])]),
      standard.fieldDescription("仅展示，不提供点击、自动播报或非装饰性分隔语义。")
    ],styles=style({"padding":"24","gap":"20","width":"full"})),key="theme")))
quit run(componentApplication(component(Display,0),"Leaf — 展示组件",640,560)
  .withNativeTheme(shadcnLight))
