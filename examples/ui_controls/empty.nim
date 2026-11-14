## Empty-state composition with real native child actions.
import leaf
import leaf/ui as standard

type EmptyModel=object
  dark,created:bool
  creates:int

let EmptyDemo=defineComponent[int,State[EmptyModel]]("StandardEmptyDemo",
  proc(ctx:MountContext,p:int):State[EmptyModel]=ctx.state(EmptyModel()),
  proc(ctx:ComponentContext,p:int,state:State[EmptyModel]):UiDescription =
    let m=ctx.value(state)
    host(standard.theme((if m.dark:UiColorMode.dark else:UiColorMode.light),column(@[
      text("空状态",variant="primary"),
      standard.cardDescription("原生居中文字与真实操作按钮，不自动播报。"),
      standard.card(@[standard.cardContent(@[
        standard.empty(@[
          standard.emptyHeader(@[
            standard.emptyTitle((if m.created:"第一个项目已创建" else:"还没有项目"),key="title"),
            standard.emptyDescription((if m.created:"项目已保存在本次演示的内存中。你可以返回空状态，再次体验创建流程。"
              else:"从一个小目标开始。创建第一个项目，把想法和待办事项整理到一起，稍后还可以继续补充内容。"),key="description")]),
          standard.emptyContent(@[
            standard.button((if m.created:"返回空状态" else:"创建项目"),key="action",
              onClick=proc(e:Event)=discard state.update(proc(old:EmptyModel):EmptyModel =
                result=old
                result.created=not old.created
                if not old.created:inc result.creates)),
            standard.emptyDescription("创建次数：" & $m.creates,key="count")])
        ],key="empty")])]),
      standard.button((if m.dark:"切换到浅色" else:"切换到深色"),key="mode",variant=UiVariant.outline,
        onClick=proc(e:Event)=discard state.update(proc(old:EmptyModel):EmptyModel =
          result=old;result.dark=not old.dark)),
      standard.fieldDescription("固定 24 DIP 内距；不包含媒体图标、链接或 CSS 自动平衡。")
    ],styles=style({"padding":"24","gap":"20","width":"full"})),key="theme")))
quit run(componentApplication(component(EmptyDemo,0),"Leaf — 空状态",640,600)
  .withNativeTheme(shadcnLight))
