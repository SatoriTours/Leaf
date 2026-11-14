# 标准 UI（进行中）

标准库基于固定 shadcn/ui `new-york-v4`／Neutral 参考，不依赖 React、Tailwind 或 WebView。当前实现 Button、Input、Textarea、布尔 Checkbox／Switch、垂直 Label／Field、字段描述／错误、Card、Badge／Separator、Empty、确定 Progress、Kbd 及 managed Skeleton 的受限子集；**M0／M1 尚未整体验收，不是完整 shadcn 组件库**。

## 显式使用

```nim
import leaf
import leaf/ui as standard

# 在 managed 组件的 render 中返回 Node；不要和旧 widgets 同名构造器混用。
let settings = standard.card(@[
  standard.cardHeader(@[
    standard.cardTitle("账户"),
    standard.cardDescription("管理公开信息")]),
  standard.cardContent(@[standard.input("Leaf 用户", key="name")]),
  standard.cardFooter(@[
    standard.button("保存", key="save"),
    standard.button("取消", variant=UiVariant.outline)])])
```

应用必须显式选择 `.withNativeTheme(shadcnLight)` 或 `shadcnDark`；原有默认系统／松石主题不变。未声明标准角色能力的后端会拒绝，而不是降级为旧样式。标准入口暂限 Windows 原生后端。

Button 支持 default／destructive／outline／secondary／ghost／link、normal／xs／sm／lg 及 icon 尺寸。icon 尺寸只约束方形布局，不附带图标资产；link 仍是按钮，不承诺浏览器链接语义。loading 禁止激活，不自动增加动画。Input 继续使用系统 EDIT，支持 controlled onChange、invalid、resetToken；不是自绘输入实现。Textarea 明确使用 multiline EDIT、默认最小64 DIP，`height=96` 可指定本页高度；不是自动内容高度／可拖拽 CSS textarea。它保留原生换行、撤销及选区。Label／Field 提供垂直分组、邻接原生标签及字段消息；受限的原生文字可访问性见下文，不包含完整 orientation／fieldset／ARIA 关系。

## 实际入口

`examples/ui_showcase/main.nim` 是内存设置页：页面标题、公开资料 Card、名称、简介、字段说明和底部状态／取消／保存。初始简介是显式未保存的示例草稿；名称必填、简介最多160个 Unicode code points（非UTF8 bytes，非grapheme clusters）。取消同时恢复两个字段；保存不写入磁盘，输入换行规范化为LF，原生EDIT保持CRLF。按钮测试面板不混入产品设置页。使用项目现有带 v6／PMv2 manifest 的 Windows 构建路径；`-d:leafDarkTheme` 选择深色。

## 当前边界

| 范围 | 状态 |
|---|---|
| Neutral token、OKLCH 转换、透明合成、typed／host 协议 | 有局部自动化测试 |
| Button／Input／Card 原生尺寸、字体、颜色、EDIT HWND／选区保留、释放 | 有 Windows 局部自测 |
| 设置页浅／深键鼠编辑、保存、校验保留草稿、取消、禁用状态 | 实际入口验证及独立证据／浅深视觉复核通过（仅所示状态） |
| UIA 原生角色／Value／Invoke／焦点／显示名称关联 | 独立编译的 CLR UIA 客户端在浅／深实窗通过；不等于所有客户端／读屏器验收 |
| Button／Input 外侧焦点环、主窗移动及资源回收 | 已实现；原生回归、浅／深实窗及独立焦点视觉复核通过（所测状态） |
| 运行期 shadcn 浅／深切换 | 96 DPI 受限路径已验收，保留原生 EDIT 状态；详见下文 |
| 阴影、完整 Label／错误说明可访问性关联、高对比／IME 现场 | 未完成 |
| Textarea／垂直 Label／Field、本页布局 | 本页100%浅深视觉／已测关键路径独立复核通过，150%及完整Field仍未覆盖 |
| 布尔 Checkbox／Switch | 布尔子集在100%真实环境功能／独立浅深视觉通过（不等于完整M1） |
| Status／Alert 实时区域 | 内部基础层已验收；Spinner 已验收，Alert 已接入待本轮独立验收；读屏器现场及 150% DPI 未完成 |
| 完整 Field 及其余 M1 | 未完成 |
| 单选 Select：原生 owned 锚定弹层、受控 value／open、键鼠与 Dialog 内作用域 | 交互、发布边界、锚定、专用 UIA provider（展开／值／选择／禁用项／事件／退役）与真实截图已自测 |
| 非模态 Popover：原生 owned 锚定内容浮层、受控 open、内容内原生控件与 Dialog 内作用域 | 交互、发布边界、锚定／避让、外点／Esc／Tab 请求、故障回执与资源归零、跨进程 UIA（自然树发现／非模态／Invoke／Value／Dialog 作用域）已自测；浅深／窄窗／Dialog 截图已生成但未做视觉复核 |
| M2 浮层、M3 数据、M4 专项复杂组件 | 后续阶段，不宣称支持 |

Button／Input／Textarea 的 3 DIP 外侧焦点环使用单一 owned、非激活、透点装饰窗，不侵占控件本体；Button 遵循系统隐藏焦点提示，Input／Textarea 保留编辑焦点提示。移动／失活先隐藏，普通 native turn 重新定位，释放使用现有资源所有权机制。原生 GDI 尚无 CSS 阴影／动效的等价实现，不宣称完整像素一致性。

旧 PowerShell 动态调用路径曾报告 Pane 并在代理注册时抛异常；同一原生窗口在独立编译的 CLR UIA 客户端中已验证正确角色、模式、焦点、名称与标签。保留该客户端路径差异，不据此断言所有 UIA 消费者通过，也未为此修改系统配置或增加自定义 provider。

参考提交及 MIT 原文保存在 `src/leaf/vendor/shadcn-ui/`，发行包的许可证清单会包含它们。设计及计划见 `docs/superpowers/`。唯一执行状态／证据索引：
``/.local/state/agent-artifacts/leaf/2026-11-07-shadcn-ui-design/status.md`。

## 本页视觉实现与限制

标准主题显式请求 Windows `Microsoft YaHei UI` 无衬线字体，并设置每字体灰阶抗锯齿 quality（非强制子像素 ClearType）；标题／CardTitle 使用该 CJK 字体的实际 Bold700 字重（对认可稿的原生视觉适配，非上游600的逐字重等价）；测量和 HWND 共享同一 HFONT，不改系统字体／缩放设置或旧 system／matsu 字体。验收 VM 已核该字体存在，并在进程内核对实际实现字体与中文 glyph；其它机器的 GDI fallback 不保证与浏览器一致。Card／操作区采用本页获批稿的14 DIP圆角及细分区线；无CSS阴影等价实现。保留系统标题栏。

Windows 将单行 EDIT 暴露为 UIA `Edit + ValuePattern`，本页多行 EDIT 则是 `Document + TextPattern`（可编辑、非只读），不是 ValuePattern；使用系统 provider，不伪造同一种角色。实际 Name／LabeledBy／异步 SetFocus、按钮 Invoke／禁用已用独立编译 CLR 客户端在本次浅深构建自测。错误文案现可通过字段 HelpText 查询；完整关系型错误描述和读屏器现场仍未支持。

本页100% DPI浅深实窗截图与认可稿独立对照已通过，属于合理原生近似而非 Noto 字形／像素逐一等价。最终构建亦通过键鼠、HWND保留及编译CLR UIA客户端复验。150%真实显示缩放尚未验收：当前 VM 仅一个96 DPI显示器，应用为per-monitor aware；不擅改系统缩放，不以合成DPI消息代替。完整 M0／M1、IME／高对比及全项目测试仍未完成。

## Checkbox／Switch（布尔值子集）

```nim
standard.checkbox("接收产品更新", checked, onChange=onChecked, invalid=invalid)
standard.switch("启用通知", enabled, onChange=onEnabled)
standard.switch("自动同步", enabled, size=UiSize.sm)
```

回调使用 `Event.checked`；`checked` 为受控 bool，忽略事件时恢复已接受值，不变成原生失控状态。disabled 同时禁用真实 HWND 和移除回调。Checkbox 指示器16×16 DIP／圆角4，支持invalid；Switch 默认32×18.4、sm24×14 DIP，不支持其它尺寸／invalid／loading。二者含标签的原生点击区域最少20 DIP高，焦点环只围住指示器，标签也可点击。

保留真实 `BUTTON / BS_AUTOCHECKBOX` 的空格、Tab、原生状态和系统 provider；Windows UIA 的两种控件均为 `CheckBox + TogglePattern`，不是伪造 `Switch` ControlType。高对比让系统绘制接管，届时开关可能显示系统复选外观。当前仅布尔值，不支持 mixed／indeterminate，未知 `ui_indeterminate` 不会被静默忽略；不包含阴影、切换动画或完整错误消息关联。

独立演示入口 `examples/ui_controls/main.nim`（浅色默认，`-d:leafDarkTheme` 深色），不向账户设置页添加组件目录。包含启用／禁用／错误、normal／sm、受控拒绝、操作次数与重置；仅内存状态。

本对组件的已测范围：96 DPI／100%，11套共享97项、11套Windows回归116项、浅深真实标签鼠标／Space／Tab／UIA Toggle／禁用拒绝／受控回滚／HWND保持及重置；独立查看14张实窗图（含480宽窗）通过。shadcn根窗用WS_CLIPCHILDREN避免背景擦除覆盖子HWND，旧主题style不变。实窗采样等待有界native paint／DWM present完成，不以强制重绘制造视觉证据。150%真实DPI、现场高对比／IME、完整Field错误关联和全项目脚本／Actions仍未验证。


## Field 文字可访问性（受限子集）

标准 Field 内最近作用域的一个 Input／Textarea／Checkbox／Switch，可关联至最多一个标准 Label 及按界面顺序组合的 FieldDescription／FieldError。嵌套 Field 独立解析，不向相邻字段串联；有多个控件或多个 Label 的歧义作用域在准备阶段明确拒绝（空 Field 仍可用于布局）。布尔控件已有 caption 时保留自己的可访问名称。合并后的说明有原生字符串预算，超限在 native effects 前拒绝。

Windows Dynamic Annotation 为真实 HWND 的系统代理补充 Name／HelpText 和 MSAA 名称／说明；错误文字加入 HelpText，移除或恢复时清理旧注解。不重建 EDIT、不覆盖正文，不改变原生 Value／Text／Toggle 等模式。现有设置页的系统 LabeledBy 路径另行实测，但这不是新增的显式元素关系实现；任意包装／排序下的 LabeledBy 不作保证。

**不支持／未完成：**显式 UIA DescribedBy／错误元素关系、IsDataValidForForm、自动读屏播报与完整读屏器验收。此环境的 stock provider 对 IsDataValidForForm 在忽略默认值查询时明确返回 NotSupported；默认 false 不能当成真实 invalid。Dynamic Annotation 的设置调用成功不代表消费者支持该属性，因此不发布无效的 bool 或关系型注解，也不替换系统 provider。

当前该子集已在浅／深实窗完成开发者 UIA 自测：Name／HelpText、错误更新／恢复／跨字段隔离、取消、原生 HWND／选区／Undo 保留；独立复核与本轮回归结果见唯一外部状态索引。它不等于完整 Field 或整个 M0／M1 完成。

## 运行期窗口主题（shadcn 浅／深受限子集）

`standard.theme(mode: UiColorMode, child: Node, key = "")` 是 Leaf 的显式窗口根配置辅助器，
不是上游 registry 新增组件或局部 ThemeProvider。应用仍须先用
`.withNativeTheme(shadcnLight)` 或 `.withNativeTheme(shadcnDark)` 选择标准组件窗口；
默认 system／旧 matsu 不变，也不能借根声明跨主题族切换。

```nim
# 在组件 render 中用 ctx.value(model).mode 代替这里的固定 dark；
# 回调通过 State.update 仅改变 mode，保持 wrapper 和后代 key 稳定。
standard.theme(UiColorMode.dark,
  standard.input("原生草稿", key="name"), key="window-theme")
```

- 只允许一个处于窗口最外层的 theme；嵌套／竞争声明、缺失／非法 mode、
  将 `ui_color_mode` 放在其他 role 上，均明确拒绝。strict／compatible 不静默丢弃必需语义。
- `UiRole.theme` 尾部追加；模式以 typed `colorMode: Option[UiColorMode]` 跨 Host。
  prepare 合并完整 delta 候选，与 Field 共用一次树解析输入；拒绝发生在候选 HWND 创建前。
- 根模式更新仅影响本窗口的皮肤、可选 DWM 标题栏和既有 owned 焦点环；
  不重建 EDIT，不换字体、不重设文本或选区，不主动抢焦点，保留原生 Undo 和多行滚动。
  鼠标／系统 Button Invoke 自身引起的正常焦点移动仍保留，不强制抢回旧 EDIT 焦点。
- 移除声明后恢复应用最初选择；在同 kind／key 下移除 role 也不需要重建后代。
  apply 失败按既有 restore 路径恢复已接受模式；既有故障恢复可能重建控件，
  不承诺故障时也绝不重建或保留全部编辑历史。
- 独立演示入口 `examples/ui_controls/theme.nim`：真实编辑、错误、Checkbox／Switch、
  浅深按钮和显式重置文本；不修改账户设置页，不保存偏好或修改系统设置。

验收范围：真实 Windows 96 DPI、浅深及 480 DIP 窄窗；运行期颜色切换与编辑状态，
不是完整主题／M0＋M1 验收。真实 150% DPI、IME 组合期、系统高对比切换及完整读屏器
现场验证尚未完成；全项目脚本／Actions 尚未执行。

## Badge／Separator（非交互展示子集）

- `standard.badge(value,key="",variant=UiVariant.default)`：真实STATIC/tag文字，
  default／secondary／destructive／outline／ghost／link六种配色；12 DIP、500字重、
  22 DIP高、水平8 DIP padding＋1 DIP border、胶囊圆角。outline在深色Card上
  使用透明父surface及border token，不套Button的深色input底。旧`tag`不变。
- badge的link仅文本颜色，不是链接、按钮或可激活控件；不进入Tab顺序，
  无InvokePattern。不支持asChild、图标、hover／transition、invalid／loading、
  disabled或回调；原始必需metadata或行为组合明确拒绝，不静默当作有效动作。
- `standard.separator(key="",vertical=false,length=24.0,decorative=true)`：
  仅视觉装饰线，水平full宽／1 DIP高，竖直1 DIP宽／显式正有限length高
  （上限1,000,000 DIP），不是CSS h-full；使用父surface合成Neutral border。
  `decorative=false`明确拒绝，不提供可访问的语义分节／交互式分隔器。
- **系统可访问性限制**：Badge保留stock STATIC Text及动态Name；系统代理会将
  `&`按助记符去除，即使屏幕按字面显示（`A & 中文`实际Name=`A  中文`）。
  现有Dynamic Annotation实测未修正此STATIC代理行为，因此未保留无效注解、
  未新增provider，不承诺任意标点的Name逐字等价。Separator在实测UIA中为
  空Name、不可聚焦的Text，`IsControlElement=true / IsContentElement=false`；
  **decorative只表示视觉用途，不保证从UIA树隐藏，也不等价于Radix ARIA presentation**。
  无自动播报及独立读屏器验收。
- 原生局部GDI用stock brush／pen、SaveDC／RestoreDC和既有共享HFONT，
  支持运行期浅深更新与文字更新，不引入新COM／provider／持久绘制资源。
- 演示：`examples/ui_controls/display.nim`。已实现的受限范围以外部
  `display-result.json`和独立报告为验收依据；不是完整上游组件／整个M0＋M1。

## Empty 空状态（原生文字／操作组合子集）

`standard.empty(children,key)`、`emptyHeader(children,key)`、`emptyTitle(value,key)`、
`emptyDescription(value,key)`、`emptyContent(children,key)` 生成真实原生column／STATIC。
Empty固定24 DIP padding/gap，Header gap8，Content gap16；子布局居中，Title为
18 DIP/500，Description为14 DIP/400/muted。文字用系统STATIC的SS_CENTER居中换行，
测量与绘制共用HFONT；普通Label与Empty文字在同key/kind切换时同步更新/恢复对齐，
不重建HWND。操作作为独立标准Button传入，保留Tab/Space/Invoke，不把文字做成假按钮。

```nim
standard.empty(@[
  standard.emptyHeader(@[standard.emptyTitle("还没有项目"),
    standard.emptyDescription("创建第一个项目，开始整理想法。")]),
  standard.emptyContent(@[standard.button("创建项目", onClick=onCreate)])])
```

这是显式受限原生组合，不含EmptyMedia/图标/媒体资源、富文本链接、自动播报、
CSS text-balance、max-w-sm上限或md断点48 DIP padding；内容使用可用宽度与固定24 DIP
内距，不模拟完整CSS。Empty本身不画虚线框：上游默认仅border-dashed而未给边框宽；
演示中的外框来自外层Card。未支持的ui_media/variant/size/invalid/loading及在Empty
自身挂动作明确拒绝。系统Text名字仍可能按助记符规范化&，沿用已披露的stock限制，
不保证任意标点Name逐字等价，也不承诺标题的ARIA heading语义。

独立入口 `examples/ui_controls/empty.nim`；受限96DPI浅深／480窄窗、动态状态及真实
按钮验收以外部empty-result.json/独立报告为准。实际150%DPI、高对比、读屏器与
全项目scripts/Actions未验；不是整个M0＋M1完成。Alert 的原生 assertive 文字子集见下文；Empty 本身不因此获得播报语义。

## Progress／Kbd（原生确定进度与键帽）

- `standard.progress(value: int,key="")`：确定整数百分比0..100，8 DIP高/full宽，
  Neutral primary填充和primary/20轨道、圆角/裁剪。保留真实msctls_progress32及
  系统ProgressBar/只读RangeValue，native/UIA范围同为0..100，值更新不重建HWND。
  小数/无值/超范围/NaN/自定义max/indeterminate/disabled及交互动作均不支持；
  必需ui_*与非法value严格拒绝，compatible不再为标准progress偷偷clamp。
  旧非标准progress的compatible宽松转换与皮肤不变。无CSS transition或播报保证。
- `standard.kbd(value,key="")`：真实STATIC/tag文字，20 DIP高、最小宽20、
  水平4 DIP、12DIP/500、muted底/mutedForeground字、6DIP圆角。
  `standard.kbdGroup(children,key="")`为gap4居中row；不是UIA Group语义承诺。
  不注册快捷键、不聚焦/Invoke、无图标或Tooltip内反色；未知variant/size/动作拒绝。
  系统STATIC的&助记符Name规范化等既有限制不变。
- 演示`examples/ui_controls/status.nim`含0/25/50/75/100、禁用增加、reset、
  运行期浅深与真实键鼠/UIA操作。原生可访问性和视觉验收只覆盖明确范围，
  完整组件语义/150%DPI/现场验证及全项目验证未完成时不称整个M0＋M1完成。

## Skeleton（managed 原生脉冲）

`standard.skeleton(width,height,key="")`返回`UiDescription`而非`Node`，因为动画
必须归属组件生命周期；用既有`hostShell`组合managed描述。尺寸为正有限DIP，
不超过既有布局预算。不要直接用hostShell替换CardContent等组合组件的内部
spacer/inset；示例`examples/ui_controls/skeleton.nim`演示保留壳层的插槽组合。

- 复用现有Runtime共享时钟及component-owned Animation：两秒1→.5→1循环；
  现有quadratic easeInOut近似CSS cubic-bezier，不承诺逐帧CSS等价。
- MotionPolicy.reduced使用初始全不透明静态块；隐藏暂停、卸载后停止请求帧，
  重挂从初始值开始。无私有timer、Canvas、后台线程或自定义provider。
- 真实STATIC/tag，accent颜色按500..1000整数permille透明度与父surface合成，
  8DIP圆角；纯pulse仅局部InvalidateRect，不发WM_SETFONT、不动相邻EDIT。
- 无children/text/交互/disabled/variant/size；缺失或错误ui_opacity、其它role
  携带该必需metadata均拒绝，hostCompatible不得sanitize。
- stock系统代理可能暴露空Name Text；不承诺UIA隐藏或加载/完成自动播报。
  UI示例提供独立状态文字和真实Button。高对比及150%DPI仍需现场验收。

Skeleton 的96 DPI受限切片已有独立代码／五张实窗图复核通过，记录为
`skeleton-review-agent-output.md` 与 `skeleton-result.json`。共享22套165项、
原生17套131项是该快照的局部回归，不代表全项目测试或整个M1通过。

## ButtonGroup（横向原生组受限子集）

`standard.buttonGroup(children,key="",label="")` 组合直接、同尺寸的标准Button。
横向零间距，首尾保留外圆角、内部直边且outline只画单条接缝；label是组的
可访问名称，不额外绘制标题。真实BUTTON/BS_GROUPBOX提供系统UIA Group，
子按钮保留独立Tab/Space/Invoke及disabled，不是toolbar或方向键导航。
普通row与ButtonGroup不能在同key下互换原生窗口类；准备阶段拒绝，须换key。
行池签名区分STATIC与GroupBox，避免停车/借用混淆。

当前不支持垂直、混合尺寸、直接Input、嵌套组、ButtonGroupText/Separator、
asChild或组级disabled/动作。焦点环可见且不被父容器裁剪，但仍沿用完整圆角，
内部接边焦点形状不完全匹配上游；这是独立验收指出的待完善视觉差异。
高对比回退系统GroupBox，现场未验，不承诺无框外观。
示例：`examples/ui_controls/groups.nim`。本轮96 DPI受限子集已完成独立复核，18共享105项、19原生153项及六张实窗图
有证据；P1拉伸外角已关闭，保留上述P2。不得据此声称整个ButtonGroup或M1已完成。

## InputGroup（单行文字前后缀受限子集）

`standard.inputGroup(control,prefix="",suffix="",key="",label="")` 接收一个未修改布局的
`standard.input(...)`，保留key、草稿、onChange/onSubmit、invalid/disabled、placeholder
及resetToken，不修改传入Node。外框36 DIP、1 DIP内距，实际EDIT高34 DIP；前后缀
采用真实GroupBox/STATIC，组本身也是系统Group，不新增provider。label仅为组的
可访问名称；Field标签/HelpText仍关联真实EDIT。

整组共用边框、背景和外侧焦点环；编辑区不重复画小边框，真实EDIT继续管理光标、
选区、Undo和输入。文字前后缀及附加区空白点击聚焦同一输入框，disabled时不转移
焦点；Tab跳过附加文字和Group，不把文字伪装成Invoke按钮。

当前只提供单行Input与可选文字前后缀：不支持TextArea、block-start/end、组合内
Button/Kbd/图标、嵌套任意children或完整上游部件API；不支持布局已改写的Input，
不静默吞掉调用者的布局。完整Field关系/读屏、真实高对比/DPI/IME仍是既有缺口。
演示：`examples/ui_controls/input_group.nim`。96 DPI受限子集已独立验收通过：19共享108项、20原生157项及七张实窗图有证据。
addon空白命中P1经真实鼠标RED→GREEN闭合；全项目与真实现场缺口仍保留。

## Status／Alert 实时区域（Win32 基础层）

新增（未跟踪）`src/leaf/backends/win32/live_provider.{c,h,nim}` 与
`tests/windows/live_provider_{contract.c,fixture.nim,client.cs}`、
`tests/windows/test_win32_live_provider.nim` 只实现状态／提醒文案的原生可访问性
基础层。**Spinner 与文字 Alert 已接入生产 backend／皮肤；Alert 本轮验收状态见外部索引**。
因此本节不是组件完成声明，也不代表 M0／M1 验收。

- 语义：专用 provider 只暴露 `IRawElementProviderSimple`。状态为
  StatusBar＋LiveSetting=1（Polite），提醒为 Group＋LiveSetting=2（Assertive），
  附 Name／LocalizedControlType 与非交互属性；其余属性交给原生 host provider
  （bounds／HWND），不新增 Pattern、不替换 EDIT、不注册自定义 UIA 控件类型。
- 生命周期（全部在 HWND owner 线程）：`stage` 可分配、`accept` 只移动指针且无副作用、
  `flush` 在普通 native turn 发布并发送 PropertyChanged／LiveRegionChanged、
  `discard` 只丢弃暂存值；同值不重复播报，被拒绝的候选不会吞掉已接受的快照。
- 退役：`detach` 只做墓碑并入队，`drain` 在安全 turn 调用 `UiaDisconnectProvider`；
  可选 `setWake` 用一条自定义消息（0x8000..0xBFFF）把该 turn 限定在本轮消息循环内，
  正常投递时不必等下一次用户输入；这不是必达保证。唤醒窗口失效或
  `PostMessageW` 失败时，调用方仍须在后续安全 turn／关闭前显式 drain，不能以
  `detach` 返回成功推断已释放。退役前先摘链，因此 `UiaDisconnectProvider` 内重入的
  `detach` 不会丢失；重入的 `drain`／`close` 返回 E_UNEXPECTED 而不是重复遍历队列；
  flush 中途被 detach 时快照保持存活到 flush 返回，并停止向已墓碑的 provider 通知。
- 通知本身也把 provider 交给 UIA，因此与 `WM_GETOBJECT` 产生相同的断开义务。
- 通知门控：窗口隐藏或无 UIA 客户端时，`flush` 仍发布快照，但不发送通知，
  也不因这次静默发布新增断开义务。之后显示窗口或出现客户端不会补播旧通知；
  后续语义变化才按门控发送。此前已经取得的断开义务不会被静默发布取消。
- `accept` 的 owner 线程前置条件由调用方保证；为保持纯指针操作，它不做运行时
  线程检查，不能当作线程安全的跨线程提交入口。

已测范围：7 项 C 重入契约 A–G（退役所有权、drain／close 拒绝、通知暴露义务、
Name／LiveSetting／ControlType 通知内 detach）与真实跨进程 CLR UIA 客户端黑盒（四次 LiveRegionChanged；同值／
被拒绝候选不播报；Name／LiveSetting／ControlType／LocalizedControlType 变更通知；
原生子按钮 Invoke 与 EDIT 值／文本／层级保留；移除后 ElementNotAvailable；
最终 owned／objects 为 0）。RED 分别定位到丢失退役节点、缺少重入拒绝、通知未计入
断开义务及逐条属性通知遗漏等真实缺陷，不是编译或报告格式问题。
独立验收另补 H–M 六项契约，覆盖其余通知点、隐藏／无客户端、重入暂存和
owner 线程约束；这些补验探针保存在任务证据中，不冒称仓库测试入口已包含。

**未完成／未覆盖：**Alert 图标/内嵌动作/富内容、真实读屏器
（NVDA／讲述人）现场、150% 高 DPI、高对比与 IME、全项目 scripts／Actions。
本层不改变任何视觉，属性／事件／生命周期结论均来自直接证据而非截图推断。

## Spinner（managed 原生加载指示）

`standard.spinner(label="Loading", key="")` 返回 `UiDescription`，通过 `hostShell`
组合；固定16 DIP、1秒顺时针旋转，使用现有 Runtime 的 component-owned Animation。
Reduced motion 为静止初始角度；隐藏暂停、卸载释放动画需求，不添加私有 timer。
GDI 270度圆弧是对 Loader2 的原生近似，不是 SVG 路径/抗锯齿逐像素一致。
旋转只局部重绘，不逐帧重设字体、重建 HWND 或改相邻 EDIT。

Win32 独立 provider 暴露 StatusBar、LiveSetting=Polite、非空 Name；
不是可聚焦/可激活控件，不替换 EDIT 系统 provider。语义在 native apply 暂存，
accept 只标记，普通安全 turn 发布并通知。同名旋转与换肤不重复 LiveRegionChanged。
卸载/列表停车时退役，安全 turn 断开 UIA；移除后不继续暴露旧状态。
同 key 的普通 tag 与 Spinner 角色互换须换 key，避免复用不匹配的 provider。

目前不支持 size/variant/disabled/invalid/children/交互动作、任意 SVG 图标、
真实读屏播报保证；高对比回退系统 STATIC（可能显示名称而非圆弧），现场未验。
例子 `examples/ui_controls/spinner.nim` 包含状态更新、卸载/重挂、浅深切换与受控输入。
当前仅96 DPI受限切片；独立验收结论以外部 `status.md` 的最新 Spinner 记录为准，
不等于整个 M1 或全项目测试通过。

## Alert（文字实时提醒子集）

```nim
standard.alert(@[
  standard.alertTitle("保存失败"),
  standard.alertDescription("请检查网络连接后再试。")],
  key="save-alert", variant=UiVariant.destructive)
```

提供 `alert(children,key,variant)`、`alertTitle(value,key)`、`alertDescription(value,key)`。
一个提醒至少有一个非空文字部件，至多一个标题再跟一个说明，或仅其中之一。
其它子组件、重复/倒序部件与非 default/destructive variant 明确拒绝。
默认 Card 表面/前景，说明使用 muted；destructive 使用危险色，说明90%合成。
固定横向16、纵向12 DIP内距，部件间距2 DIP，8 DIP圆角；真实系统文本测量与换行。
标题固定20 DIP单行可见区域（不是CSS line-clamp/ellipsis逐像素实现），说明随宽度换行。
不含SVG图标、嵌入按钮/链接、富文本、自动消失/关闭操作，也不是 AlertDialog。

真实 GroupBox 提供容器，专用 provider 暴露 Group、LiveSetting=Assertive、非交互属性。
公开构造器用可见标题和说明按顺序以换行合成一次 Name；内容变化在安全turn发布
LiveRegionChanged，同内容换肤/变色不重复通知。保留Spinner的Polite、EDIT系统provider
与既有stage/accept/discard/退役生命周期，不修改系统设置。
容器从/to普通column或其它非live组同kind/key转换需要换key；不同NodeKind仍按Runtime
既有重建语义处理。系统子STATIC的助记符/标点规范化限制不变，根Name由专用provider保真。

示例 `examples/ui_controls/alert.nim` 覆盖更新、卸载/重挂、浅深、危险配色与受控输入。
本轮自测/独立验收见外部 `status.md` 的 Alert 记录；仅96DPI，不承诺所有读屏器的
实际朗读效果。高对比回退系统GroupBox（可能显示组合caption）、150%DPI、IME及
真实读屏器现场与全项目脚本/Actions未验证，不能称整个M1完成。

## 统一组件目录（独立入口）

`examples/ui_showcase/catalog.nim` 是新增目录入口，不替换 `main.nim` 的账户页。
`catalog_view.nim` 将已有受限组件组合为五类：表单、组合、反馈、空态、动画。
分类使用独立可聚焦的原生按钮，而非 ARIA Tabs／方向键选项卡；Tab／Space／点击可操作。
顶部按钮显式切换浅深 theme，不更改系统主题。默认760×700客户端尺寸，
本轮窄窗契约为480×700（96DPI）；更矮窗口没有自动滚动，不宣称任意尺寸自适应。
沿用项目既有 v6／PMv2 manifest 构建路径，入口无需 `-d:leafDarkTheme`。

- 表单复用 `SettingsModel` 校验、保存与取消；名称/简介为内存草稿。
  勾选和通知开关是独立演示状态，不包含在资料的保存/取消事务内。
- 组合页演示 InputGroup、ButtonGroup、Kbd／Separator；键帽不注册快捷键。
- 反馈页通过真实按钮推进/重置确定进度，并展示 Badge／Alert；不启动后台工作。
- 空态页的创建按钮只改变本地示例状态，不创建文件、数据库或网络资源。
- 动画页挂载 Spinner／Skeleton，加载完成或离页卸载动画需求。
  禁用的“执行中”按钮是独立 loading 外观样本，不表示后台任务仍在执行。
- 同页换肤保留原生EDIT HWND／选区；跨页保留模型值，但会销毁并重建原生控件，
  **不承诺跨页保留Undo／选区／IME会话**。

回归入口：`tests/nim/test_ui_catalog.nim`、`tests/windows/test_win32_catalog.nim`；
跨进程实窗键鼠／UIA／截图客户端：`tests/windows/catalog_client.cs`。
本轮实际证据与独立验收状态见外部 `status.md` 的目录记录。
仅96DPI切片；150% DPI、高对比、IME、实际读屏器、全项目scripts/Actions仍未完成，
不等于M0/M1或完整shadcn组件库已完成。

## Dialog／AlertDialog（原生模态浮层首片）

`examples/ui_controls/dialog.nim` 是独立入口。每个模态层级由**真实 owned 窗口**承载：
一层即一个 `WS_POPUP | WS_CAPTION`（无 `WS_SYSMENU`）对话框表面窗口加一个非置顶分层
50% 黑色遮罩窗口，都不会被页面裁剪，不使用 MessageBox，也不在父容器里画假浮层。
同一 Runtime／BackendSession／普通消息泵。

```nim
page.add(standard.dialog("编辑联系人", open,
  description = "名称写入临时草稿。",
  key = "dialog",
  onDismiss = proc(e: Event) = state.open = false,   # 只提出 open=false
  content = @[standard.field(@[standard.label("名称"),
    standard.input(name, key = "name")])],
  footer = @[standard.button("取消", key = "cancel", variant = UiVariant.outline),
    standard.button("保存", key = "save")]))
page.add(standard.alertDialog("删除联系人",
  standard.alertDialogCancel("保留", key = "alert-cancel"),
  alertOpen,
  action = standard.alertDialogAction("删除", onDelete,
    variant = UiVariant.destructive),
  description = "不能撤销。", key = "alert", onDismiss = proc(e: Event) = alertOpen = false))
```

### 事务与发布

- `prepare`：创建隐藏层级窗口，**整体预检**——层数预算、每层内容测量高度与工作区匹配、
  隐藏控件创建；任何一项不满足都在**显示/禁用 owner/移动焦点之前**拒绝该 revision，
  已接受的旧布局保持不变。
- `apply`：只做几何准备（定位计算、子树布局、控件摆放、标题与主题），窗口仍然隐藏，
  不显示、不禁用 owner、不抢焦点。
- 接收已接受 revision 后的**普通安全 turn**才统一发布：关闭过期层级（自顶向下）、
  打开新层级（自底向上）、禁用直接 owner、设置初始焦点。发布失败是明确的原生错误
  （fault/冻结 + 可重试清理），不会假装撤销已发生的焦点通知。
- 输入门控覆盖原生消息与 UIA 来源：模态层级接受打开期间，只有最顶层内的控件事件能进入
  业务层；背景控件的 `WM_COMMAND`（等价 UIA Invoke）会被丢弃并计入诊断计数。

### 层级、尺寸与焦点

- Z 序严格为「本层遮罩 < 本层表面 < 下一层遮罩 < 下一层表面」，全部非全局置顶；
  遮罩不会盖到其它应用。
- 表面窗口保留 `WS_CAPTION` 样式位（UIA 因此得到 `ControlType.Window` +
  `WindowPattern`），并通过 `WM_NCCALCSIZE` 把整窗矩形作为客户区，系统标题栏不绘制、
  客户区等于窗口区（初始、放大、缩小均验证）。`IsModal` 由真实的 owner 禁用状态产生。
- 超高内容**不钳制、不静默隐藏 footer**：本片无内部滚动原语，内容超过工作区可用高度时
  在显示前明确拒绝（错误信息给出所需/可用高度）。外部尺寸或工作区变化导致已打开层级不再
  放得下时，表面仍被夹在工作区内，Esc 与系统关闭始终是可用退出路径。
- 焦点：AlertDialog 初始焦点为安全取消控件；Dialog 为内容区首个可聚焦控件，空对话框回退到
  对话框表面本身。关闭后恢复打开前的真实焦点控件；该控件已删除／隐藏／禁用时回退到
  所属窗口首个可聚焦控件，再回退到窗口默认目标。`Tab`／`Shift+Tab` 仅在顶层模态内循环。
- 关闭请求：Esc、X 控件、遮罩点击、`alertDialogCancel` 与系统关闭都只投递**类型化**的
  `EventKind.dismiss` 给**其所属层级**；外层在存在内层时不会收到请求，忽略请求则保持已接受状态。
- 动态标题：同 key 渲染新标题时同步 surface 的窗口文本（UIA Name 随之更新）。
- 资源：每个 class 注册／HWND／root 都有独立成功回执；创建中途失败保留可重试所有者，
  destroy/drop 成功后才删表和减 live 计数，失败留下待清理回执并可重试。

与固定上游（`shadcn-ui/ui@42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9` new-york-v4 的
`dialog.tsx`／`alert-dialog.tsx`）的已知差异：X 控件排在标题行尾部而不是绝对定位在右上角；
AlertDialog 取消按钮不使用 outline 变体（原生皮肤无 outline）；没有开闭动画、CSS 阴影与
`data-slot` 语义；表面由系统窗口客户区承载，圆角/描边为自绘内容而非 CSS。

验证入口：`tests/nim/test_ui_dialog.nim`（共享契约／拒绝矩阵／嵌套栈／能力拒绝／typed host 传递）、
`tests/windows/test_win32_dialog.nim`（事务发布边界、caption/Window 语义、整窗客户区与放大/缩小、
非置顶与 Z 序、真实 SendInput 鼠标命中与背景门控、超高拒绝与旧布局保留、层数预算、
层级删除/复用、资源故障回执与重试、动态标题、换肤保留 EDIT 文本/选区/Undo、失效触发器回退）、
`tests/windows/dialog_client.cs`（跨进程 CLR UIA：Window/WindowPattern/IsModal/非置顶/嵌套/动态标题
+ 9 张真实截图）。
仅 96DPI 切片；150% DPI、高对比、IME、真实读屏器与全项目脚本／Actions 仍未完成。

## Select（原生锚定单选下拉首片）

`examples/ui_controls/select.nim` 是独立入口，页面内一处、Dialog 内一处，共用同一受控模型。
弹层是**真实 owned 非模态窗口**（WS_POPUP + WS_EX_TOOLWINDOW，owner 为触发器所在顶层窗口），
不被父容器裁剪、不禁用 owner、不全局置顶、不进入任务栏；与页面／Dialog 共用同一 Runtime／
BackendSession／普通消息泵，没有第二个泵。

    let trigger = standard.selectTrigger(placeholder = "选择一个颜色", key = "colour-trigger")
    let content = standard.selectContent(@[
      standard.selectItem("red", "红色"),
      standard.selectItem("green", "绿色（禁用）", disabled = true),
      standard.selectItem("blue", "蓝色")])
    let node = standard.select(trigger, content,
      value = acceptedValue, open = acceptedOpen, key = "colour", label = "颜色",
      onChange = proc(e: Event) = acceptedValue = e.value,       # 值请求
      onOpenChange = proc(e: Event) = acceptedOpen = e.open)     # 开／关请求

- 复合部件在构造期折叠为**一个** typed sidecar（选项 key／label／disabled、value、open、
  placeholder、label、width）；页面只挂载一个触发器控件，候选行不进入页面布局。同一 sidecar
  在校验后随 HostProps 走现有线格式，未另造 Runtime。
- 值载荷只用 `Event.value`（选项稳定 key）；开关请求是尾追加的 `EventKind.openChange` + typed
  `Event.open` 布尔，**不**复用 `checked`，也不把选项或状态编码进 CSV／字符串。
- 构造期即拒绝：重复 key、空 key／label、空列表、全禁用列表、非法初始值（不在选项内或指向
  禁用项）、非有限或越界宽度。重复 label 合法，选择只按 key 认定。

### 事务、锚定与焦点

- `prepare`／`apply` 只做 typed 状态与几何准备；接收 revision 后的普通 turn 才创建／定位／
  显示／隐藏弹层并移动焦点。创建、定位、显示各自记录 OS 成功回执；显示失败保留可重试 host，
  下一 turn 重试，不写成“已显示”。
- 锚定用纯几何（`select_protocol.planSelectPlacement`）：默认在触发器下方、宽度与触发器一致、
  只显示整行；下方放不下且上方更宽裕时翻转向上；两轴都夹进监视器工作区，行数有上限，超出部分
  用行偏移滚动（滚轮 3 行、PageUp／PageDown 一屏减一行、Home／End 与字符定位都保证候选可见）。
  owner 移动／页面滚动时按新的真实触发器矩形重发几何；owner 最小化时弹层随之消失，恢复后是否
  重开由**已接受 open** 决定。
- 候选（键盘高亮）是临时导航状态：Up／Down 环绕、Home／End、大小写不敏感字符前缀，全部跳过
  禁用项，**从不因此写 value**。Enter／Space／有效行点击各提出一次提交请求；提交同时提出
  `open=false` 请求，两者各自可被拒绝。Esc 只取消候选并请求收起。Tab／Shift+Tab 请求收起，
  收起时按该焦点域（页面或所在 Dialog）的控件顺序移动到合法目标，不形成第二个模态循环；
  Dialog 内第一次 Esc 只关下拉，外层 Dialog 与背景门控保持不变。
- 被忽略的请求不产生漂移：开／关／值都保持调用方接受的状态，不双发事件；删除、重排或禁用当前项
  时按稳定 key 丢弃过期提交（`noticeValue`），不会选到新占位的项。
- 资源：每个 host 的 class 注册／popup HWND／root 发布都有独立回执；关闭时隐藏，触发器或 Select
  退役时销毁；最终 dispose 后 `liveSelects == 0`，无残留窗口／class。

### 已知差异与未验证项

与固定上游（`shadcn-ui/ui@42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9` new-york-v4 的 `select.tsx`）
相比：无搜索／Combobox、多选、分组／分隔符、富内容、NativeSelect、Menu／Popover 与开闭动画；
无 CSS 阴影／圆角（GDI 直角 + 1px 描边）；弹层宽度固定等于触发器宽度（默认 180 DIP，可显式指定
80..1024）；滚动条为自绘细指示条而非独立 SCROLLBAR 子窗口。

**UIA 语义（本轮已实现专用 provider）**：触发器与弹层各有自己的 fragment root，不替换 EDIT
或其它组件的 stock provider（仅 Select 触发器窗口用自有 provider 覆盖其 BUTTON 代理）：
触发器暴露 ControlType.ComboBox、ExpandCollapse（真实展开/收起状态，Expand/Collapse 只提出
open 请求）、只读 Value（当前接受值，SetValue 明确拒绝）、名称、IsEnabled/IsKeyboardFocusable/
HasKeyboardFocus/BoundingRectangle/IsOffscreen；弹层暴露 ControlType.List + Selection（单选、
非必需），每个候选是 ListItem fragment：名称、逐项 IsEnabled（禁用项 false）、IsSelected、
SelectionItem.Select（禁用项/不可见项拒绝、合法项接受、Add/RemoveToSelection 拒绝）、
BoundingRectangle/IsOffscreen（按可见行窗口）与焦点请求（只移动候选，不改变已选）。
事件：展开状态与值用 property-changed，结构与选择用 UIA structure/selection 事件，且只在
provider 已被 UIA 连接且客户端在场时发出。生命周期：弹层关闭即退役其 provider 与窗口，旧元素
按约定返回 ElementNotAvailable；关闭重开、选项重排/同 key 替换后查询的是新实例；Dialog 门控
同样适用于 UIA（模态层级外页面触发器的 IsEnabled=false，Expand 被拒绝）。
接口 IID、vtable 顺序与数值 ID **只**来自本机 Microsoft 签名二进制（UIAutomationProvider.dll /
UIAutomationTypes.dll 4.8.9347.0、UIAutomationCore.dll 7.2.26100.1 的反射与内嵌类型库），
版本与 sha256 记录在外部产物 A/m2-select-uia-definitions.md。learn.microsoft.com、source.dot.net
与 raw.githubusercontent.com 在本执行环境被策略拒绝（未读取正文），因此不声称完成过官方文档
交叉核对。工具链 SDK 不含这些接口声明，故使用项目内最小兼容声明 select_uia.h；未安装或复制
SDK。

快照生命周期（读者保护 + owner 单端回收）：provider 的公开快照在读者与 owner 间并发。读路径统一为
“先计数再原子取指针、用完退出”：`readGuardEnter` 先 `InterlockedIncrement(readers)` 再原子读取
`published`，返回的指针只在该保护区间内使用；`readGuardExit` 只减计数，**从不**释放、交换或修改
退役链；减到 0 的最后一个读者只通过既有唤醒（`PostMessage(WM_HOST_TICK)`）通知 owner，不新增轮询。
owner 是唯一 publish 者、也是唯一把被替换快照压入退役栈（`retireSnapshot`，CAS 压栈）和唯一摘链
回收者（`reclaimRetired`）：在 publish 末尾、普通 turn 的 `reclaimSnapshots`、detach 处调用。
摘链前先观察 readers==0，并且检查与 `InterlockedExchangePointer(retired,NULL)` 之间不插入任何
COM/事件/消息泵调用，因此其间不会发生新的 publish/retire 重入；此时新读者只能原子取到**当前**
（非退役）快照，而退役链只含已被替换的旧快照，所以摘链释放是安全的。最后一次 publish 之后没有新
发布时，最后读者的唤醒会驱动普通 turn 的 `reclaimSnapshots` 完成回收；窗口已关闭无法唤醒时，
退役链保留到最终 Release（COM 引用归零、无活跃调用）统一释放当前/退役/ready/staged，既不会由读者
释放，也不会无限堆积。此设计不等待读者、不抢读者锁，避免历史 UI 线程等锁死锁；事件比较所需的
previous/ready 一直存活到比较结束才退役。所有 `published` 解引用（属性、边界、选择、导航、条目）
都走读保护，原先无保护的 `itemNavigate` 已修正，死代码 `itemSnapshot` 已删除。

peer 对象寿命（trigger 与 popup 的双向关系）：两者的 link 是**弱指针对**，由 context 级
`linkLock` 保护。取 peer 时在同一临界区内读取指针并只做一次内部引用自增（pin），解锁后才判活、
读快照或返回接口；卸载（detach / Release）在同一锁内清双向指针。因此“读到弱指针”与“持有强引用”
之间没有释放窗口：要么先 pin 成功（对象保持存活），要么已被卸载（合法空关系，返回空子节点）。
锁内不调用 SendMessage/UIA/消息泵/事件/COM；一次导航只 pin 一次并把该引用交给调用方（不重复取弱
指针）；item 对 parent 的强引用单独核对（newItem AddRef / itemRelease Release）。link 只允许同
context、同 owner 线程，跨 context 明确返回 E_INVALIDARG。受控交错回归：读者在取得 peer 后暂停，
owner 关闭弹层并让普通 turn 排空退休队列（该对象此时可被 Release）；放行后断言未使用已释放对象
（探针的 freed 登记）、导航为合法空关系、重开得到新对象而非旧对象；旧实现（无 pin、先读弱指针）在
该交错下直接崩溃（RED），pin 后为 GREEN。

owner 普通 turn 回收接线：`selectTurn` 每 turn 对 trigger 与 popup 两个 provider 调用
`reclaimSnapshots`，并排空 select context 的退休队列；最后读者退出只发既有唤醒，普通 turn 即完成
快照回收。严格回归先记录 allocation/publish/generation 与 live/reclaims，再放行最后读者并只消费
一次普通 turn（不刷新 State、不 stage 新值）：断言 `reclaims` 增加、
`published/allocated/generation` 不变、`live` 回落；trigger 与 popup 各覆盖一次，关闭路径另有断言。
旧测试只看 live 下降，保留为历史。

每 turn 重复发布的根因与修复：stage 的条目长度曾把 UTF-16 终止符计入 `LeafSelectItem.length`，导致
`sameSnapshot` 的“条目标签长度”比较（差异码 14）每 turn 都不同，进而每 turn 分配新快照、提升
generation 并发出事件（也掩盖了回收未接线的问题）。修复为条目使用不带终止符的长度、name/value 另
用带终止符的缓冲；严格断言随后证明稳定 turn 的 `published/allocated/generation` 增量为 0。

受控并发回归 `tests/windows/test_win32_select_lifecycle.nim`（探针仅在 `-d:leafProtocolProbes` 编译，
只提供屏障与真实分配/释放计数，不改读/释放算法）：
1) 单读者：真实 Value 读取得旧快照后暂停，owner publish 新值——断言 publish 不阻塞、旧快照存活、
owner 查询看到新值、放行后读者读到的仍是它取得的那份、下一次 publish 回收。
2) 两读者交错（主控反例）：读者 R1 退出（计数归 0）后暂停；R2 进入并取得当前快照；owner publish
   使该快照退役；再放行 R1。旧“读者清链”实现下 R1 会把 R2 仍在使用的快照释放（RED：断言
   `afterExit.live == during.live` 失败、后续回收断言失败）；owner 单端回收实现下 R1 不碰退役链、
   R2 读到的仍是它取得的那份（标签长度 1），最后读者退出后由普通 turn 回收（GREEN）。
3) 另断言服务端 `SetValue` 返回 0x80040204、item 导航路径受保护、销毁后快照 live 计数为 0。

自然发现（必经验收入口）：`tests/windows/select_discovery_client.cs` 对每个 case 起全新 APP 与
客户端进程，只先用进程 id 找到应用的顶层窗口，随后**第一项子树操作**即被测入口：
A = `FindFirst(Descendants, ComboBox+名称)`；B = 先在应用根上注册 `TreeScope.Subtree` 结构/属性
处理器，再 `FindFirst`（之后在同一线程按 API 契约注销）；C = `TreeWalker` 广度优先（深度≤8、
节点≤400）。矩阵 A/B 各 STA 与 MTA、C 一例；正控为同应用的 stock Button，负控是“目标不存在”
的搜索且必须非零退出。正式语义客户端 `select_client.cs` 也以自然发现得到的元素进入（页面
Select、长列表 Select、Dialog 内 Select、弹层 List/ListItem 均按 UIA 身份在各自作用域内发现），
窗口句柄只用于身份交叉核对与鼠标落点；Dialog 表面窗口不是 Select 目标，按应用窗口身份定位后
在内部自然发现内层 Select。冻结正式 EXE（sha256 3C3DF5C9…）上该矩阵与语义客户端均通过；
曾出现的整树挂起只存在于既有失败证据中，其准确阻塞调用因当时无逐调用日志而**未知**，不以
当前结果反推。

已知限制：provider 只对可见窗口发布（隐藏触发器保留 stock 代理）；触发器不提供 Invoke
pattern；不支持多选、搜索/Combobox 与菜单式分组；Value 只读并拒绝 SetValue。仅 96 DPI 切片；
150% 真实缩放、高对比、IME 与真实读屏器仍未验证；STA／MTA 两例通过只说明这两个客户端线程
模型在本机可用，不证明全部 ABI／线程安全已穷尽。

验证入口：`tests/nim/test_ui_select.nim`（typed 契约／导航／锚定数学／构造与 wire 拒绝／能力拒绝／
事件分离）、`tests/windows/test_win32_select.nim`（发布边界、owned 锚定与宽度、真实键鼠提交、
Esc／Tab／外点、禁用项跳过与不可提交、长列表滚动、owner 移动／最小化、Dialog 内作用域与门控、
显示失败回执、退役与资源归零）、`tests/windows/select_client.cs`（跨进程 UIA 与真实截图：
弹层浅色／深色／Dialog 内上下文／页面）。仅 96 DPI 切片；150% 真实缩放、高对比、IME、真实读屏器
与完整上游组件集仍未完成。

## Popover（原生非模态锚定内容浮层首片）

`examples/ui_controls/popover.nim` 是独立入口。面板是**真实 owned 非模态窗口**
（`WS_POPUP|WS_CAPTION`，owner 为触发器所在顶层窗口）：不裁剪父容器、不禁用 owner、不全局置顶、
不进入任务栏、没有第二个消息泵；`WS_CAPTION` 只用于让 stock 代理暴露 `Window`+`WindowPattern
(IsModal=false)`，客户端区仍是整窗。内容用既有标准子树（Button／Input／Label／Select 等），
不是把 Select 列表改造成通用容器，也不是把模态 Dialog 改造成全局宿主。

    let node = standard.popover(
      standard.popoverTrigger("打开", key = "pp-trigger"),
      standard.popoverContent(@[
        standard.label("提示", key = "pp-label"),
        standard.input(acceptedText, key = "pp-edit"),
        standard.popoverClose("关闭", key = "pp-close")], key = "pp-body"),
      open = acceptedOpen, name = "面板", key = "pp",
      onOpenChange = proc(e: Event) = acceptedOpen = e.open)   # 开／关请求


> **重建说明（2026-11-14，用户明确授权）**：自下一节起的 Popover 尾段与整个 ScrollArea 章节是
> **依已验合同与现存证据重建**的内容，**不是**旧原文的逐字恢复。旧文件为 698 行、`sha256=58f5bb66…`，
> 该版本在工具 50KB 有界读取后被回写截断而丢失，未在可达范围内找到权威副本；旧 SHA 不再成立。
>
> 重建依据：Popover 计划与 `popover_protocol.nim`、Popover 原生/共享测试与真实入口、
> `m2-scrollarea-result.json` 与 ScrollArea 计划、独立报告 `m2-scrollarea-independent-review.md`、
> 真实 API（`ui.nim` 的 `popover`/`scrollArea`、`scroll_area_protocol.nim`、
> `backends/win32/scroll_area_host.nim`）以及本任务早期对旧文件的有界读取片段。
> 本文件当前 sha256 记录在外部证据索引；未声称恢复旧 SHA。

### 事务与请求

`open` 完全受控；`openChange`（`Event.open=false`）只是请求。触发器、Esc、外点、关闭部件、Tab
边界与系统关闭都只登记一次请求；调用方忽略时面板与原生 EDIT 保留、accepted 状态不变，不偷偷销毁
窗口，也不把同一请求重复投递。面板发布发生在接受 revision 之后的普通 turn：面板／浮层窗口的创建、显示与焦点效果
不在 `prepare/apply` 中执行；这不表示 prepare 不创建任何控件 HWND。旧实例的排队事件不会更新同 key 的新实例（绑定与 revision 在派发前复核）。

### 键盘、焦点与作用域

面板打开后聚焦首个合法内容控件，没有可聚焦项时聚焦面板本身。Esc、外点与显式关闭后，若仍拥有前台
则恢复到触发器或确定的回退目标；失去应用前台时不抢回。Tab／Shift+Tab 在内容内顺序移动，到边界时
请求关闭并让位给 owner 的合法后继／前驱；调用方若忽略该关闭请求，面板保持显示且不强迫焦点回来
（这是本切片的显式原生非模态策略，不声称与上游逐键等价）。嵌套 Popover 在首片显式拒绝；内容中的
Select 打开时第一次 Esc 只作用于 Select，其关闭后的 Esc 才请求关闭 Popover；Popover 可以位于
Dialog 内，所有目标仍受最顶层模态域约束，外层关闭按后进先出退役，不解除仍存在的外层模态禁用。

### 锚定与几何

默认请求下方、起始边对齐；`sideOffset` 默认 4 DIP（上限 64），宽度 0 表示默认 288 DIP（上游
`w-72`，允许 160..720），面板与工作区保持 16 DIP 边距。请求侧放不下时按可用空间翻转到另一侧；
内容在目标宽度下测量，候选超出预算时整个 revision 被拒绝，不发布半截面板。owner 移动、滚动、
最小化或隐藏时不出现悬空或不可达浮层，也不复用缓存矩形；布局与主题变化保留活跃 EDIT 的
HWND／草稿／选区／Undo（关闭再开不承诺跨销毁 Undo）。

### 失败回执与资源

创建、定位、显示、销毁逐步保留真实回执：创建失败完整回滚（class 与 cookie 回执释放、不跟踪半开
host，恢复路径是新实例），显示失败不计「已显示」；真实消息泵中的显示失败经 tick 使后端
fault／冻结事件，runNative 清理并向应用入口抛出，不能承诺应用内下一 turn 自动恢复。
底层宿主／重绘债的可重试性不等于应用级恢复；销毁失败保留真实失败回执。最终 dispose 后 `livePopovers`、`liveWindows`、`liveFonts`、`liveRoots` 归零。

### 验证入口

`examples/ui_controls/popover.nim` 是独立入口（页面、Dialog 内表单、内容内 Select、接受与拒绝关闭、
浅深／窄窗）；`tests/windows/popover_client.cs` 是独立编译的 CLR UIA 客户端，用自然树发现触发
Button 与命名非模态面板，核对名称／角色／`WindowPattern.IsModal=false`／Invoke／Value 与受控状态；
`tests/windows/test_win32_popover.nim` 现有 35 项原生用例覆盖上述请求、作用域、锚定、故障回执与
资源归零。

### 已知差异与未验证项

只实现非模态首片：不提供 modal 参数、菜单项导航、Tooltip／HoverCard、任意递归 Popover，也没有
动画、CSS 阴影或自绘箭头；Tab 边界策略是 Leaf 的首片取舍，不是上游逐键等价。视觉方面只在
96 DPI 下生成浅／深／窄窗／Dialog 组合截图，本实现端无图像能力、不以像素脚本代替视觉复核；
150% DPI、高对比、IME、真实读屏器、触摸与全平台未验证。清单记录的参考路径为
`apps/v4/registry/new-york-v4/ui/popover.tsx`，参考 hash 为 `sha256=3f99d3ad…0757`；
该记录仅反映清单与保存副本一致，来源与权威性仍未核实，本轮未重新获取，不视为来源核验通过。

## ScrollArea（纵向有限视口首片）

```nim
let form = standard.scrollArea(
  standard.scrollAreaContent(@[
    standard.field(@[standard.label("名称"),
      standard.input(name, key = "name", onChange = onNameChange)]),
    standard.button("保存", onClick = onSave)
  ], key = "form-content"), height = 240, key = "form-viewport")
```

Win32 标准主题声明 `saVertical`：真实带系统纵向滚动条的 HWND viewport，唯一的持久正文 HWND
承载控件。滚动只移动正文，不调用用户 view 或重建 EDIT；支持滚轮、系统拖拽、viewport 聚焦时的
方向／PageUp／PageDown／Home／End，以及 Tab／焦点进入离屏字段时显露。多行 EDIT 保留自身滚轮
处理，编辑器按键不被容器抢占。正文缩短／窗口改变后 offset 夹紧，短内容不显示滚动条。

高度必须有限且在 `(0, 20000]` DIP；必须有且仅有一个非空 `scrollAreaContent`。水平溢出、嵌套
ScrollArea、正文内的 Dialog／Popover／Select 弹出域或 virtualList、虚拟行内的 ScrollArea
在候选阶段明确拒绝。稳定身份不能跨原生父域搬移；改父级时需要新身份。它不是大列表虚拟化替代品，
也不提供水平滚动、惯性触摸或自绘覆盖式滚动条。非 Win32 标准主题或未声明能力的后端拒绝使用。

`examples/ui_controls/scroll_area.nim` 是真实入口：页面表单、浅深切换、Dialog 内显式 240 DIP
正文、常驻标题／页脚、内存保存拒绝与恢复。Dialog 仍保留原有尺寸和超高拒绝策略；不会自动给所有
Dialog 包滚动。外层 Popover 的内容域也可放有限 ScrollArea，不等于支持正文再嵌套弹出域。

失败语义：原生滚动条写入后会读回；内容移动失败时尝试恢复原生滚动条，offset/range 只在效果成功后
发布。回滚失败保留原始错误及 secondary，不伪称原生恢复成功。普通滚动 turn 的错误冻结后端并沿
既有运行边界传播／清理；提交阶段的布局错误沿既有候选 apply／rollback 契约处理。单独 host 用例中
捕获异常并重试，不等于应用会忽略错误继续接受业务事件。

验证仍按证据限定：当前目标为 Windows 96 DPI 的有限表单切片；150% DPI、高对比、IME、真实读屏器、
触摸和全平台尚未验证。截图需有界等待窗口输入空闲及正常绘制，不以强制重绘制造通过图，也不把这一
同步条件当即时首帧性能承诺。受限验收范围记录在外部统一证据索引（独立共享 12/0、布局 39/0、
virtualList 17/0、实际入口 22/0，复用同源原生 18/0、Popover 35/0），不覆盖上述未验证项，
不能据此宣称完整 M2 已完成。

## RadioGroup（原生纵向单选组首片）

```nim
let value = ctx.value(state).shipping            # 调用方持有的已接受值
standard.radioGroup(@[
  standard.radioGroupItem("standard", "标准配送", key = "ship-standard"),
  standard.radioGroupItem("express", "加急配送", key = "ship-express"),
  standard.radioGroupItem("pickup", "自取（暂停）", key = "ship-pickup", disabled = true)
], value, key = "shipping", label = "配送方式",
  onChange = proc(e: Event) = updateAccept(e.value))   # Event.value 是选项值
```

每个选项都是真实 stock `BUTTON` + `BS_RADIOBUTTON`（不是 `BS_AUTORADIOBUTTON`、不是 Checkbox，
也不用普通按钮伪造），因此进程外 UIA 角色是 RadioButton。刻意不用自动互斥类型：系统不得越过受控
接受事务清除兄弟项，`value` 是唯一选择权威。点击／Space／UIA SelectionItem.Select 只投递一次
`change` 请求并带选项值；回调不更新 `value` 时，该轮 apply 依据已接受值恢复原生勾选状态，被拒绝的
候选不会污染下一次选择。重复激活已接受项不重复提交；disabled 选项可以被接受但永不响应用户输入。

键盘与焦点：每个组只有一个 Tab 入口（已接受且可用项，否则第一可用项，全禁用则无 Tab stop）；
Up／Down 在组内循环并跳过禁用项，Home／End 到首尾可用项，方向键只移动焦点、不改变选择，Space
和鼠标才请求选择；Tab／Shift+Tab 照常离组。焦点落入 stock 单选会触发 USER32 的自动勾选，后端在
同一条消息内按已接受值恢复并抑制该伪通知，因此 Tab 到某选项不会改变业务值。组以 `WS_GROUP`
划界，兄弟组互不清除。

稳定身份与角色变化：已接受身份的新角色与旧角色会被比较；只要任一侧是 radioGroup／radioGroupItem
而角色发生变化（含变为"无标准角色"、组角色退出），就在任何原生副作用之前拒绝并要求新 key。
check→radio 与 radio→check 两个方向同样拒绝。NodeKind 改变在本运行时是新的原生身份，由组结构
校验在副作用前拒绝，不当作"保持身份换角色"处理。

约束：非空且唯一的选项值；组 `value` 为 `""` 表示未选择，非空但不在选项中、空组、重复值、把普通
Checkbox 或其他部件当选项、候选里移除已接受选项都会在构造或 prepare 阶段拒绝，不会悄悄选第一项；
prepare 拒绝后仍保持原有接受树、HWND 身份、勾选与焦点，下一次合法候选正常应用。仅纵向单组单值；
不做横向／RTL、非受控模式或整套 Form。

受限项：视觉为 Neutral 近似（16 DIP 圆环，选中为主色圆环加 6 DIP 内点），未逐像素核对上游
`radio-group.tsx`（来源 SHA 仍未解决），因此不声称与上游逐像素一致。`examples/ui_controls/radio_group.nim`
是真实入口（接受／拒绝、禁用项、初始未选择组、浅深切换、窄窗、Dialog＋ScrollArea 组合）。真实入口
客户端在 Dialog 内实际执行点击接受、拒绝保持、方向键焦点与组隔离，并按"主窗∪owned Dialog"的窗口
并集截图（窄主窗下同样完整），关闭后核对外层无额外顶层窗口。当前只在 Windows 96 DPI 验证；
150% DPI、高对比、IME、读屏器、触摸、全平台与完整 M2 未验证。

状态：代码功能已通过 **Windows 96 DPI 受限独立复验**（共享 12/0、原生 11/0、实际入口 75/0）；
主控已目视核查最终自测入口的 9 张截图，并按独立审查清单修正文档措辞。
这是本切片的受限验收，不代表全量测试、完整 M2 或上述未验证项通过。
