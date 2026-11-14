## Managed pulsing placeholders. No custom clock, canvas, or accessibility provider.
import leaf
import leaf/ui as standard

proc fillSlot(n:Node,content:seq[UiDescription]):UiDescription=
  # Preserve the standard CardContent's spacer/inset shells when inserting
  # managed descriptions; replacing its direct children would discard them.
  if n.key=="loading-slot":return hostShell(n,content)
  var children:seq[UiDescription]
  for child in n.children:children.add(fillSlot(child,content))
  hostShell(n,children)

type Model=object
  dark,loaded:bool
let Demo=defineComponent[int,State[Model]]("SkeletonDemo",
  proc(ctx:MountContext,p:int):State[Model]=ctx.state(Model()),
  proc(ctx:ComponentContext,p:int,state:State[Model]):UiDescription=
    let m=ctx.value(state)
    var content:seq[UiDescription]
    if m.loaded:
      content= @[host(standard.label("资料已载入")),host(standard.cardDescription("内容已替换占位，动画不再请求帧。"))]
    else:
      content= @[standard.skeleton(280,24,key="title-placeholder"),
        standard.skeleton(200,16,key="detail-placeholder")]
    let card=hostShell(standard.card(@[]),@[
      host(standard.cardHeader(@[standard.cardTitle("资料预览"),
        standard.cardDescription("占位尺寸固定，载入完成后卸载动画。") ])),
      fillSlot(standard.cardContent(@[column(@[],key="loading-slot",
        styles=style({"gap":"12","width":"full"}))]),content),
      host(standard.cardFooter(@[standard.button((if m.loaded:"重新载入" else:"载入完成"),key="load",
        onClick=proc(e:Event)=discard state.update(proc(old:Model):Model=
          result=old;result.loaded=not old.loaded))]))])
    let body=hostShell(column(@[],styles=style({"padding":"24","gap":"20","width":"full"})),@[
      host(text("骨架占位",variant="primary")),
      host(standard.cardDescription("复用 Runtime 时钟：两秒脉冲，隐藏暂停，卸载停止。")),card,
      host(standard.button((if m.dark:"切换到浅色" else:"切换到深色"),key="mode",variant=UiVariant.outline,
        onClick=proc(e:Event)=discard state.update(proc(old:Model):Model=
          result=old;result.dark=not old.dark))),
      host(standard.fieldDescription("reduced-motion 使用静止占位；本示例不模拟可访问性加载播报。"))])
    hostShell(standard.theme((if m.dark:UiColorMode.dark else:UiColorMode.light),column(@[]),key="theme"),@[body]))
quit run(componentApplication(component(Demo,0),"Leaf — 骨架占位",640,560)
  .withNativeTheme(shadcnLight))
