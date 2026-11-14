## Single-line native EDIT with text-only prefix/suffix groups.
import leaf
import leaf/ui as standard

type InputGroupModel=object
  address,amount:string
  dark,invalid,disabled:bool
  submissions:int
let Demo=defineComponent[int,State[InputGroupModel]]("StandardInputGroupDemo",
  proc(ctx:MountContext,p:int):State[InputGroupModel]=ctx.state(InputGroupModel(address:"leaf",amount:"25")),
  proc(ctx:ComponentContext,p:int,state:State[InputGroupModel]):UiDescription =
    let m=ctx.value(state)
    host(standard.theme((if m.dark:UiColorMode.dark else:UiColorMode.light),column(@[
      text("输入组合",variant="primary"),
      standard.cardDescription("点击前后缀聚焦原生输入框；Tab 只停留在可交互控件。"),
      standard.card(@[
        standard.cardHeader(@[standard.cardTitle("发布信息")]),
        standard.cardContent(@[
          standard.field(@[standard.label("站点地址"),
            standard.inputGroup(standard.input(m.address,key="address",invalid=m.invalid,disabled=m.disabled,
              onChange=proc(e:Event)=discard state.update(proc(old:InputGroupModel):InputGroupModel =
                result=old;result.address=e.value),
              onSubmit=proc(e:Event)=discard state.update(proc(old:InputGroupModel):InputGroupModel =
                result=old;inc result.submissions)),prefix="https://",suffix=".dev",key="address-group",label="站点地址组合"),
            (if m.invalid:standard.fieldError("请输入有效的站点名称。") else:standard.fieldDescription("仅内存草稿，不发起网络请求。"))]),
          standard.field(@[standard.label("预算"),
            standard.inputGroup(standard.input(m.amount,key="amount",
              onChange=proc(e:Event)=discard state.update(proc(old:InputGroupModel):InputGroupModel =
                result=old;result.amount=e.value)),prefix="$",suffix="USD",key="amount-group",label="预算组合")]),
          standard.label("提交次数：" & $m.submissions,key="submissions")])]),
      standard.button((if m.invalid:"清除错误" else:"显示错误"),key="invalid",variant=UiVariant.outline,
        onClick=proc(e:Event)=discard state.update(proc(old:InputGroupModel):InputGroupModel =
          result=old;result.invalid=not old.invalid)),
      standard.button((if m.disabled:"启用地址" else:"禁用地址"),key="disabled",variant=UiVariant.outline,
        onClick=proc(e:Event)=discard state.update(proc(old:InputGroupModel):InputGroupModel =
          result=old;result.disabled=not old.disabled)),
      standard.button((if m.dark:"切换到浅色" else:"切换到深色"),key="mode",variant=UiVariant.outline,
        onClick=proc(e:Event)=discard state.update(proc(old:InputGroupModel):InputGroupModel =
          result=old;result.dark=not old.dark)),
      standard.fieldDescription("当前仅单行输入与文字前后缀；不含组合内按钮、图标或多行布局。")
    ],styles=style({"padding":"24","gap":"16","width":"full"})),key="theme")))
quit run(componentApplication(component(Demo,0),"Leaf — 输入组合",640,680).withNativeTheme(shadcnLight))
