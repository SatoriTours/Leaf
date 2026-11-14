## Determinate native progress and noninteractive keyboard hints.
import leaf
import leaf/ui as standard

type StatusModel=object
  value:int
  dark:bool
let StatusDemo=defineComponent[int,State[StatusModel]]("StandardStatusDemo",
  proc(ctx:MountContext,p:int):State[StatusModel]=ctx.state(StatusModel()),
  proc(ctx:ComponentContext,p:int,state:State[StatusModel]):UiDescription =
    let m=ctx.value(state)
    host(standard.theme((if m.dark:UiColorMode.dark else:UiColorMode.light),column(@[
      text("进度与键盘提示",variant="primary"),
      standard.cardDescription("真实系统进度控件；键帽仅用于提示，不注册快捷键。"),
      standard.card(@[
        standard.cardHeader(@[standard.cardTitle("处理进度"),
          standard.cardDescription("确定进度 0–100%，原生 RangeValue 保留同一数值。")]),
        standard.cardContent(@[
          standard.progress(m.value,key="progress"),
          standard.label("当前进度：" & $m.value & "%",key="value"),
          standard.kbdGroup(@[standard.kbd("Ctrl"),standard.kbd("K")]),
          standard.fieldDescription("以上键帽为静态文字，Tab 会直接跳到操作按钮。")]),
        standard.cardFooter(@[
          standard.button("增加 25%",key="advance",disabled=m.value==100,
            onClick=proc(e:Event)=discard state.update(proc(old:StatusModel):StatusModel =
              result=old;result.value=min(100,old.value+25))),
          standard.button("重置",key="reset",variant=UiVariant.outline,
            onClick=proc(e:Event)=discard state.update(proc(old:StatusModel):StatusModel =
              result=old;result.value=0))])]),
      standard.button((if m.dark:"切换到浅色" else:"切换到深色"),key="mode",variant=UiVariant.outline,
        onClick=proc(e:Event)=discard state.update(proc(old:StatusModel):StatusModel =
          result=old;result.dark=not old.dark)),
      standard.fieldDescription("暂不含不确定进度、分数百分比、动画或快捷键绑定。")
    ],styles=style({"padding":"24","gap":"20","width":"full"})),key="theme")))
quit run(componentApplication(component(StatusDemo,0),"Leaf — 进度与键盘提示",640,600)
  .withNativeTheme(shadcnLight))
