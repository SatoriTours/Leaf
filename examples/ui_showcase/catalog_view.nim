## Unified native component catalog. State survives page switches; HWND/Undo do not.
## This is an in-memory demonstration, not a persistence or complete-M1 claim.
import leaf
import leaf/ui as standard
import ./model

type
  CatalogPage = enum formPage, groupsPage, feedbackPage, emptyPage, animationPage
  CatalogModel = object
    page: CatalogPage
    dark, checked, enabled, created, loaded: bool
    address: string
    count, progress: int
    settings: SettingsModel

proc pageTitle(page:CatalogPage):string =
  case page
  of formPage:"基础表单"
  of groupsPage:"组合控件"
  of feedbackPage:"展示与反馈"
  of emptyPage:"空状态"
  of animationPage:"加载与动画"

let Catalog = defineComponent[int,State[CatalogModel]]("StandardComponentCatalog",
  proc(ctx:MountContext,p:int):State[CatalogModel] =
    ctx.state(CatalogModel(address:"leaf",enabled:true,
      settings:SettingsModel(name:"Leaf 用户",savedName:"Leaf 用户"))),
  proc(ctx:ComponentContext,p:int,state:State[CatalogModel]):UiDescription =
    let m=ctx.value(state)
    proc action(change:proc(value:var CatalogModel,event:Event)):Callback =
      result=proc(event:Event)=
        discard state.update(proc(old:CatalogModel):CatalogModel =
          result=old;change(result,event))
    proc nav(page:CatalogPage,key,caption:string):Node =
      standard.button(caption,key=key,size=UiSize.sm,
        variant=(if m.page==page:UiVariant.secondary else:UiVariant.outline),
        onClick=action(proc(v:var CatalogModel,e:Event)=v.page=page))
    var content:seq[UiDescription]
    case m.page
    of formPage:
      content.add(host(standard.card(@[
        standard.cardTitle("资料与偏好"),
        column(@[
          standard.field(@[standard.label("显示名称"),
            standard.input(m.settings.name,key="catalog-name",invalid=m.settings.nameInvalid,
              resetToken=m.settings.reset,onChange=action(proc(v:var CatalogModel,e:Event)=
                v.settings=v.settings.editName(e.value))),
            (if m.settings.nameInvalid:standard.fieldError("名称不能为空。",key="catalog-name-error")
             else:standard.fieldDescription("切换目录后保留草稿。",key="catalog-name-error"))]),
          standard.field(@[standard.label("个人简介"),
            standard.textarea(m.settings.bio,key="catalog-bio",height=64,
              invalid=m.settings.bioInvalid,resetToken=m.settings.reset,
              onChange=action(proc(v:var CatalogModel,e:Event)=v.settings=v.settings.editBio(e.value))),
            (if m.settings.bioInvalid:standard.fieldError("简介不能超过160字。",key="catalog-bio-error")
             else:standard.fieldDescription("最多160字，保留原生换行与撤销。",key="catalog-bio-error"))]),
          standard.checkbox("接收更新",m.checked,key="catalog-check",
            onChange=action(proc(v:var CatalogModel,e:Event)=v.checked=e.checked)),
          standard.switch("启用通知",m.enabled,key="catalog-switch",
            onChange=action(proc(v:var CatalogModel,e:Event)=v.enabled=e.checked))],styles=style({"gap":"12","width":"full"})),
        standard.cardFooter(@[
          standard.button("取消",key="catalog-cancel",variant=UiVariant.outline,
            disabled=not m.settings.dirty,onClick=action(proc(v:var CatalogModel,e:Event)=v.settings=v.settings.cancelSettings)),
          standard.button("保存",key="catalog-save",disabled=not m.settings.dirty,
            onClick=action(proc(v:var CatalogModel,e:Event)=v.settings=v.settings.saveSettings))])],key="catalog-form-card")))
      content.add(host(standard.fieldDescription((if m.settings.dirty:"有未保存的更改"
        elif m.settings.saveCount>0:"已保存到内存" else:"没有未保存的更改"),key="catalog-save-state")))
    of groupsPage:
      content.add(host(standard.card(@[
        standard.cardHeader(@[standard.cardTitle("输入与按钮组合"),
          standard.cardDescription("前后缀点击聚焦输入；每个按钮独立参与Tab导航。")]),
        standard.cardContent(@[
          standard.field(@[standard.label("站点地址"),
            standard.inputGroup(standard.input(m.address,key="catalog-address",
              onChange=action(proc(v:var CatalogModel,e:Event)=v.address=e.value)),
              prefix="https://",suffix=".dev",key="catalog-address-group",label="站点地址组合"),
            standard.fieldDescription("仅编辑示例，不发起网络请求。")]),
          standard.buttonGroup(@[
            standard.button("减少",key="catalog-decrease",variant=UiVariant.outline,
              onClick=action(proc(v:var CatalogModel,e:Event)=dec v.count)),
            standard.button("重置",key="catalog-count-reset",variant=UiVariant.outline,
              onClick=action(proc(v:var CatalogModel,e:Event)=v.count=0)),
            standard.button("增加",key="catalog-increase",variant=UiVariant.outline,
              onClick=action(proc(v:var CatalogModel,e:Event)=inc v.count))],label="计数操作"),
          standard.label("计数：" & $m.count,key="catalog-count"),
          standard.separator(),
          standard.kbdGroup(@[standard.kbd("Tab"),standard.kbd("Space")]),
          standard.fieldDescription("键帽只是提示，不注册额外快捷键。")])],key="catalog-groups-card")))
    of feedbackPage:
      content.add(host(standard.card(@[
        standard.cardHeader(@[standard.cardTitle("进度与提示"),
          standard.cardDescription("操作改变真实示例状态，不启动后台任务。")]),
        standard.cardContent(@[
          standard.badge((if m.progress==100:"已完成" else:"进行中")),
          standard.progress(m.progress,key="catalog-progress"),
          standard.label("进度：" & $m.progress & "%",key="catalog-progress-label"),
          standard.alert(@[standard.alertTitle("示例进度"),
            standard.alertDescription(if m.progress==100:"全部完成。" else:"点击推进，每次增加25%。")],key="catalog-alert"),
          row(@[standard.button("推进25%",key="catalog-progress-next",disabled=m.progress==100,
            onClick=action(proc(v:var CatalogModel,e:Event)=v.progress=min(100,v.progress+25))),
            standard.button("重置进度",key="catalog-progress-reset",variant=UiVariant.outline,
              onClick=action(proc(v:var CatalogModel,e:Event)=v.progress=0))],styles=style({"gap":"8"}))
        ])],key="catalog-feedback-card")))
    of emptyPage:
      content.add(host(standard.card(@[
        standard.cardHeader(@[standard.cardTitle("空状态组合"),
          standard.cardDescription("按钮改变内存示例状态，不写入数据库。")]),
        standard.cardContent(@[standard.empty(@[
          standard.emptyHeader(@[standard.emptyTitle((if m.created:"已创建示例项目" else:"还没有项目"),key="catalog-empty-state"),
            standard.emptyDescription("创建第一个示例，观察空状态如何变化。")]),
          standard.emptyContent(@[standard.button("创建示例",key="catalog-create",disabled=m.created,
            onClick=action(proc(v:var CatalogModel,e:Event)=v.created=true))])])])],key="catalog-empty-card")))
    of animationPage:
      var pieces = @[host(standard.label((if m.loaded:"内容已加载" else:"正在加载示例"),key="catalog-animation-state"))]
      if not m.loaded:
        pieces.add(standard.spinner(label="正在加载示例",key="catalog-spinner"))
        pieces.add(standard.skeleton(240,24,key="catalog-skeleton"))
      pieces.add(host(standard.button((if m.loaded:"重新加载" else:"加载完成"),key="catalog-loaded",
        onClick=action(proc(v:var CatalogModel,e:Event)=v.loaded=not v.loaded))))
      pieces.add(host(standard.button("执行中",disabled=true,loading=true,key="catalog-busy")))
      content.add(hostShell(standard.card(@[],key="catalog-animation-card"),@[
        host(standard.cardHeader(@[standard.cardTitle("共享时钟动画"),
          standard.cardDescription("离开此页会卸载动画；reduced-motion使用静止画面。")])),
        hostShell(column(@[],styles=style({"padding":"8","gap":"16","width":"full"})),pieces)]))
    let body=hostShell(column(@[],key="catalog-body",styles=style({"padding":"20","gap":"12","width":"full"})),@[
      host(row(@[
        column(@[text("标准组件目录",key="catalog-title",variant="primary")],styles=style({"width":"full"})),
        standard.button((if m.dark:"切换到浅色" else:"切换到深色"),key="catalog-mode",variant=UiVariant.outline,
          onClick=action(proc(v:var CatalogModel,e:Event)=v.dark=not v.dark))],styles=style({"width":"full","gap":"12","align":"center"}))),
      host(standard.cardDescription("Windows原生 · 受限组件子集 · 不等于完整shadcn")),
      host(row(@[standard.buttonGroup(@[
        nav(formPage,"nav-form","表单"),nav(groupsPage,"nav-groups","组合"),
        nav(feedbackPage,"nav-feedback","反馈"),nav(emptyPage,"nav-empty","空态"),nav(animationPage,"nav-animation","动画")],label="组件分类")],styles=style({"width":"full"}))),
      host(standard.label(pageTitle(m.page),key="catalog-page")),
      hostShell(column(@[],key="catalog-content",styles=style({"gap":"12","width":"full"})),content)])
    hostShell(standard.theme((if m.dark:UiColorMode.dark else:UiColorMode.light),column(@[]),key="catalog-theme"),@[body]))

proc catalogDescription*():UiDescription = component(Catalog,0)
