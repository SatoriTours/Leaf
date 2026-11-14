## Horizontal native button groups; per-button focus, not a toolbar.
import leaf
import leaf/ui as standard

type GroupModel=object
  clicks:int
  draft:string
  dark,disabled:bool
let GroupDemo=defineComponent[int,State[GroupModel]]("StandardGroupDemo",
  proc(ctx:MountContext,p:int):State[GroupModel]=ctx.state(GroupModel(draft:"原生编辑草稿")),
  proc(ctx:ComponentContext,p:int,state:State[GroupModel]):UiDescription =
    let m=ctx.value(state)
    let advance:Callback=proc(e:Event)=discard state.update(proc(old:GroupModel):GroupModel =
      result=old;inc result.clicks)
    host(standard.theme((if m.dark:UiColorMode.dark else:UiColorMode.light),column(@[
      text("按钮组",variant="primary"),
      standard.cardDescription("原生 Group；每个启用按钮保留 Tab、空格及 Invoke。"),
      standard.card(@[
        standard.cardHeader(@[standard.cardTitle("文档操作")]),
        standard.cardContent(@[
          standard.buttonGroup(@[
            standard.button("新建",key="new",onClick=advance),
            standard.button("复制",key="copy",onClick=advance,disabled=m.disabled),
            standard.button("导出",key="export",onClick=advance)],key="primary",label="文档操作"),
          standard.buttonGroup(@[
            standard.button("上一页",key="previous",variant=UiVariant.outline,onClick=advance),
            standard.button("下一页",key="next",variant=UiVariant.outline,onClick=advance)],key="pages",label="分页操作"),
          standard.input(m.draft,key="draft",onChange=proc(e:Event)=
            discard state.update(proc(old:GroupModel):GroupModel =
              result=old;result.draft=e.value)),
          standard.label("操作次数：" & $m.clicks,key="count")])]),
      standard.button((if m.disabled:"启用复制" else:"禁用复制"),key="disabled",variant=UiVariant.outline,
        onClick=proc(e:Event)=discard state.update(proc(old:GroupModel):GroupModel =
          result=old;result.disabled=not old.disabled)),
      standard.button((if m.dark:"切换到浅色" else:"切换到深色"),key="theme",variant=UiVariant.outline,
        onClick=proc(e:Event)=discard state.update(proc(old:GroupModel):GroupModel =
          result=old;result.dark=not old.dark)),
      standard.fieldDescription("当前仅横向、同尺寸标准按钮；不含输入框、嵌套组或工具栏方向键。")
    ],styles=style({"padding":"24","gap":"20","width":"full"})),key="mode")))
quit run(componentApplication(component(GroupDemo,0),"Leaf — 按钮组",640,600).withNativeTheme(shadcnLight))
