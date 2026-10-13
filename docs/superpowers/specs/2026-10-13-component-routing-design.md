# Leaf 托管组件路由设计草案

状态：待用户审阅；未开始产品实现。基线 `f427bad02ae799a6169008975d505ee00e3d28be`。

## 1. 目标与本轮范围

用户要求继续完善 React 式 Leaf 运行时。下一项交付是让多页面应用使用组件 State 和类型化增量宿主更新，导航失败时保持原页面与状态一致。默认保留已访问页面的组件 State，并为页面提供离开即销毁的显式策略。默认值是本草案的推荐，用户可调整。

本轮只实现组件路由及其所需的页面保留机制。异步任务和生命周期将在此后单独设计；Win32 局部布局另按测量结果立项。旧 Router/PageGroup、旧 Application、ABI1/ABI2、GPUI/Win32 的已有行为继续兼容。

不加入 URL 参数、浏览器历史、嵌套路由、过渡动画、通用 KeepAlive 缓存或完整 Hooks。现有 Route 的静态 name/path/page/view 足够作为第一版地址模型。

## 2. 现有实现与方案选择

`routing.nim` 的旧 Router 使用普通 active 字段，在 renderPage 中惰性建立 PageGroup；旧应用依赖事件后的根刷新。把它直接接入新应用不能让导航自动进入 State 队列，普通 active 也不会随宿主拒绝撤销。

`managed_runtime.nim` 已为虚拟列表提供 inactive 实例、宿主移除、暖行 State 保留及恢复；普通描述从树中移除仍会递归 disposeOwner。列表缓存的128行限制与页面生命周期不同，不能把页面伪装成列表行。

可选方案：

1. 只把旧页面返回类型改为 UiDescription：改动少，但不能自然处理托管导航的提交与子组件 State 保留。
2. 所有页面宿主常驻、隐藏未选页面：保留控件的代价较高，还需要处理隐藏布局、焦点及事件隔离。
3. 在 Nim 托管描述与运行时中加入专用页面出口：保留组件模型/State，未显示页移除宿主，返回时重建宿主。

推荐方案3。它保持跨语言协议不变，Rust 只得到当前页面的普通宿主增量。

## 3. 公共 API 合同

新模块 `leaf/component_routing` 通过 `leaf/components` 导出。旧 `leaf/routing` 的公开接口不改义；静态 Route 地址规则保持一致。

建议接口：

```nim
type
  PageRetention = enum retainState, disposeOnLeave
  ComponentPageDefinition = object
    name: string
    views: seq[string]
    build: proc(view: string): UiDescription {.closure.}
    retention: PageRetention # 默认 retainState
  ComponentRouter = object # 字段私有，持有所属 Runtime 的 State 句柄

proc newComponentRouter(ctx: MountContext,
  routes: seq[Route], pages: seq[ComponentPageDefinition],
  initial = ""): ComponentRouter
proc routes(router: ComponentRouter): seq[Route]
proc navigate(router: ComponentRouter, target: string): StateWriteResult
proc currentRoute(router: ComponentRouter): Route
proc currentRoute(ctx: ComponentContext, router: ComponentRouter): Route
proc renderPage(ctx: ComponentContext, router: ComponentRouter,
  key = "page-outlet"): UiDescription
```

上述类型字段及函数实施时按 Nim 公开符号规则加 `*`；此处省略标记便于阅读。API 仍待本草案批准，不提前写占位模块。

- 在组件 initialize 中创建 router；其 active route 为 State[int]，归创建它的组件所有。
- navigate 校验 name/path 后排队修改 State；与现有事件、uiTask、batch 和 flush 共用接受门禁。在router仍有效时，未知地址抛UiError且不排队；已销毁router优先按StateWriteResult.disposed返回，不访问已释放页面资源。
- currentRoute(router) 读已接受地址；render 中使用带 ctx 的重载读当前候选。不把排队中的地址暴露为已接受地址。
- renderPage 在拥有 router 的组件 render 中使用；一个 router 只有一个出口。跨 Runtime、重复出口及不同 owner 的错误用法明确拒绝。
- 页面 build 只构造描述，遵守 render 纯计算约束；候选失败时可再次调用，不保证候选初始化恰好执行一次。
- routes/pages/views 在创建时复制并验证，之后配置不可变。routes 返回值不能修改内部配置。
- 默认建议应用将 router 放在专门的页面区域组件中；导航不使它的父组件和无关兄弟重新执行。业务需要同步更新导航栏时可把导航栏放在同一个区域组件，或显式传递相应 Props。

第一版没有独立页面重置接口。销毁选项为每页 disposeOnLeave，整个 router 组件卸载也会释放所有保留页。后续若需要关闭标签页或定点重置，再设计可事务化的失效命令。

## 4. 页面出口与身份

增加供内部出口使用的 `DescriptionKind.pageOutlet`，不修改公开 NodeKind，不增加任何 C ABI tag。DescriptionKind 当前已导出，新增枚举值是可见的；直接对它写穷尽 case 的外部描述检查代码需处理新值，不能声称这类低层检查完全无源码迁移。普通 view/host/component 使用方式保持兼容。页面出口有稳定 key、当前 page/view、当前页 build 描述及保留策略；在 Runtime 中保存已访问页面的实例映射。

- 页面缓存 key 是该出口内的 page name；同 PageDefinition 的不同 view 共用一个页面入口。
- 页内组件依然按 parent/type/key 协调。页面 build 返回同类型、同 key 根组件时，它的 State 在 view 切换时保留；业务显式更换类型或 key 则按现有规则重建。
- 各页有不同逻辑身份路径；未选页不进入活动 key 索引、Snapshot 或宿主图，两个页面可以使用相同的局部控件 key。
- 页面出口只提供当前页的宿主根，不引入额外可见控件。根变化时更新实际宿主父级的 setChildren 及组件边界。
- 页面出口不是组件 State owner；页面中的真实组件保持各自 owner。出口元数据计入描述预算，不能形成无预算的第三类实例。
- hostRoot、segment、描述字节统计、retainedDescription、递归擦除/停用、祖先修复、Snapshot/find导出等遍历必须明确区分三个描述类别，不能让新增类别落入旧的非component即host分支。
- 相同地址的导航不产生页面重建、宿主操作或全树导出。

## 5. 停用、恢复与销毁

页面有 active、retained、disposed 三种框架状态。

**retainState：**离开时保存模型、State 槽及局部描述记录，移除该页宿主节点、边界和活动事件索引。Rust/GPUI 输入 Entity 不保留。返回时复用组件身份/State，但分配新的宿主句柄；旧控件事件不能击中新控件。

**disposeOnLeave：**离开并接受后递归卸载页面组件与暖列表行，旧 State 句柄返回 disposed；返回时重新初始化。

**隐藏页更新：**仍有效的 State 句柄可以在所属 UI 线程排队；flush 接受其值，但不执行隐藏页 render、不建立宿主。恢复页面时使用最新已接受/本次候选 State。隐藏期间不得派发它的旧宿主事件。

**退出整个 router：**递归释放活动页和全部保留页；页面内虚拟列表的活动行、暖行也一并释放。不能只遍历出口当前 children 而漏掉保留映射。

**预算：**活动与保留页面的组件、描述和列表暖行全部计入现有 MaxNodes/组件实例/MaxTreeBytes/MaxDepth 限制。初始化时路由配置有有界条目数及 UTF-8 字节校验，配置本身计入所属运行时的描述预算。默认保留所有已访问页直到 router 卸载；预算不足拒绝目标导航并保留旧页面，不暗中淘汰用户状态。需要限制内存的页面选择 disposeOnLeave。

此策略不承诺保留光标选区、焦点、滚动位置或未完成的 IME 组合。离开的控件按现有安全边界处理组合取消/销毁；回到页面后依据已接受模型建新控件，不将候选输入作为已提交业务值。

## 6. 提交、失败和后续生命周期

导航 route State、出口当前页、保留映射、活动索引、宿主根和 revision 在同一次候选中更新。实现沿用受影响实例覆盖层，不能在 stage 时直接修改 accepted 的保留表、页面配置或生命周期标记。

- 目标 build、State snapshot、预算、validator、prepare、apply 或作用域入场失败：保留原地址、原活动页、原保留页和事件；释放候选新 State；不重放导航回调。
- 后端恢复失败：沿用 Runtime 故障冻结机制。
- 提交已接受、scope 收尾再失败：保持新地址和页面，报告实际接受版本；不重试事件。
- 页面类型/key 改变、父组件移除 router、有导航排队的页面被移除，均遵循现有处置与代数校验。
- publish 只发布框架元数据，不执行页面 build、用户清理函数、异步任务、GPUI 调用或额外内存分配。所需映射容量在接受前预留。

后续异步生命周期须区分“停用”和“销毁”，在同一接受事实基础上安排安全点回调与取消。第一版不提前增加未实现的 onMount/useEffect/后台任务 API，也不在 render 中启动请求。

## 7. 文件范围与迁移

- 新增 `src/leaf/component_routing.nim`：不可变地址配置、router State、公共 API 与出口构造。
- 修改 `component_description.nim`：私有 pageOutlet 描述及只读访问器；现有 host/component 合同不改义。
- 修改 `managed_runtime.nim`：出口协调、保留子树、停用/恢复/删除、预算与活动索引；能复用的底层停用/递归访问辅助统一维护，但列表策略不改。
- 必要时扩展 StateStore 的内部 owner 查询，用于 Runtime/owner 校验；不改变 State 写入和拒绝语义。
- `routing.nim` 如需抽取纯配置校验，必须让旧行为测试继续通过；旧 navigate 不偷偷变为新 State API。
- 修改 `components.nim` 导出新入口；增加 `examples/component_pages.nim` 展示跨页计数/草稿和销毁策略。
- 新增 `tests/nim/test_component_routing.nim`，扩展故障/预算/列表保留/窗口测试；更新 API 与迁移文档。
- 不增加依赖，不升级 Cargo.lock，不改 GPUI C ABI；SDK 打包规则需确认自动包含新模块。

旧项目无需自动迁移。模板改为新组件路由是后续明确变更，不随本次隐式改写用户应用。

## 8. 验收标准

1. 配置错误在页面初始化前拒绝：重复 page/name/path/view、未知 page/view、无路由及无效 initial。
2. 惰性实例化：只创建首次进入的页面；A计数后到B再回A，State保留；disposeOnLeave 对照返回初始值。
3. 同 page 切换 view 复用同类型/key 根组件；换类型/key 按既有规则重建；不同页同名控件 key 不混淆。
4. 同事件多次 navigate 只接受最终地址；同地址不产生多余计算；父移除 router 时不复活排队页面。
5. 隐藏页 State 可接受但不 render/导出；恢复后读到最新值。隐藏页旧宿主事件被拒绝，恢复后新句柄有效。
6. 对 build/预算/validator/prepare/apply/scope 入场与收尾注入失败，核对 route、State、宿主、索引和 acceptedRevision。
7. 页面含十万项虚拟列表时，保留的是已实例化行及有界暖行；router卸载后其旧State全部disposed，内存不积累候选层。
8. 增加100/1000/5000个无关兄弟时，导航不执行它们的组件render；FFI只含离开/进入页面及必要父关系变化。导航成本按变化页规模报告，不承诺O(1)。
9. 旧 routing/core/components/list/fault 回归通过；ABI1兼容Snapshot只含活动页，ABI2常规导航不生成整树JSON。
10. headless与fake host故障矩阵、Linux真实窗口导航和中文输入对照通过；Windows/macOS未实际执行的窗口/IME/DPI检查单独记NotRun，不用SDK安装成功代替。

## 9. 发布与执行顺序

先完成现有 SDK Intel macOS 网络失败的重试；运行时主干已有三组CI通过。真实系统IME、跨不同DPI显示器和普通用户桌面仍是独立验收缺口。

本规格经用户审阅后，再写逐文件实施计划，沿用现有 Paseo 工作区与原会话协调入口。编码交日常工作配置，主会话负责架构与集成，独立验收复用现有审查会话。前端若只增加功能示例、不涉及独立界面设计，不另派样式Agent。

异步任务与生命周期是下一份规格，依赖本轮明确的页面停用/恢复/销毁语义；不把它混入组件路由实现。
