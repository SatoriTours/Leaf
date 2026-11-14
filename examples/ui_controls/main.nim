## Separate component demonstration; account settings stays a product page.
import leaf
import leaf/ui as standard

type ControlsModel = object
  updates, agreed, notifications, compact: bool
  events: int

proc initial(): ControlsModel = ControlsModel(compact:true)
proc onCheck(model:State[ControlsModel],field:int):Callback =
  result=proc(e:Event)=
    discard model.update(proc(old:ControlsModel):ControlsModel =
      result=old
      inc result.events
      case field
      of 0:result.updates=e.checked
      of 1:result.agreed=e.checked
      of 2:result.notifications=e.checked
      of 3:result.compact=e.checked
      else:discard) # Deliberate controlled rejection, not an uncontrolled switch.

let Controls=defineComponent[int,State[ControlsModel]]("StandardBooleanControls",
  proc(ctx:MountContext,p:int):State[ControlsModel]=ctx.state(initial()),
  proc(ctx:ComponentContext,p:int,model:State[ControlsModel]):UiDescription =
    let m=ctx.value(model)
    host(column(@[
      column(@[text("复选框与开关",variant="primary"),
        standard.cardDescription("真实原生控件：鼠标、Tab、空格与辅助功能。")],
        styles=style({"gap":"7","width":"full"})),
      standard.card(@[
        standard.cardHeader(@[standard.cardTitle("选择控件"),
          standard.cardDescription("展示布尔值、禁用、错误及两种开关尺寸。")]),
        standard.cardContent(@[
          column(@[standard.label("复选框"),
            standard.checkbox("接收产品更新",m.updates,key="updates",onChange=onCheck(model,0)),
            standard.checkbox("接受使用条款",m.agreed,key="terms",invalid=not m.agreed,onChange=onCheck(model,1)),
            standard.checkbox("已选中（禁用）",true,key="cb-disabled-on",disabled=true),
            standard.checkbox("未选中（禁用）",false,key="cb-disabled-off",disabled=true)],
            styles=style({"gap":"8","width":"full"})),
          column(@[standard.label("开关"),
            standard.switch("启用通知",m.notifications,key="notifications",onChange=onCheck(model,2)),
            standard.switch("自动同步（小号）",m.compact,key="compact",size=UiSize.sm,onChange=onCheck(model,3)),
            standard.switch("已启用（禁用）",true,key="sw-disabled",disabled=true),
            standard.switch("保持关闭（受控拒绝）",false,key="rejected",onChange=onCheck(model,4))],
            styles=style({"gap":"8","width":"full"}))]),
        standard.cardFooter(@[
          standard.cardDescription("操作次数：" & $m.events,key="events"),
          standard.button("重置",key="reset",variant=UiVariant.outline,
            onClick=proc(e:Event)=discard model.update(proc(old:ControlsModel):ControlsModel=initial()))])]),
      standard.fieldDescription("仅内存演示；不保存偏好，不更改系统设置。")
    ],styles=style({"padding":"32","gap":"24","width":"full"}))))

const controlsTheme=when defined(leafDarkTheme):shadcnDark else:shadcnLight
quit run(componentApplication(component(Controls,0),"Leaf — 选择控件",640,680)
  .withNativeTheme(controlsTheme))
