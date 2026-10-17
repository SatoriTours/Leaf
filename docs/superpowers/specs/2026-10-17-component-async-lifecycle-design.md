# Leaf 组件异步任务与生命周期设计

状态：用户已在原会话确认本规格；实施计划已形成，待审阅及确认执行方式。尚未实现产品代码。

日期：2026-10-17。基线：`53368cf2a554c52af092d129f0aeb2b592c8d78f`。

## 1. 目标、授权与范围

用户已同意继续开发上一轮提出的组件异步任务与生命周期：挂载/停用/恢复/销毁回调、后台任务与 UI 回传、取消及过期结果处理，以及加载、失败重试、切页返回和清理的完整示例。

成功标准是：耗时工作离开 UI 线程；业务不自行维护页面任务注册表；候选提交失败不启动其任务；旧请求与已销毁页面的结果不能覆盖当前状态；框架可以解释任务在哪个已接受版本启动、取消和交付。

本稿建议首版采用固定工作线程和受组件约束的消息通道。默认离开页面取消任务，显式选择后可在页面保留期间继续。该默认值是本轮设计建议，须随本稿审阅，不将它描述为用户此前逐项指定的行为。

范围包含托管组件、路由保留页、虚拟列表活动/暖行、headless 显式泵和 GPUI ABI1/ABI2 桌面接入。Win32 复用安全 tick 接入并补平台专用测试；未实际运行的 Windows/macOS 验收单列 NotRun。

不提供通用 Hooks、依赖数组 effect、线程间共享 State、强制终止线程、后台定时调度服务、HTTP 客户端封装或数据库分页。脚手架默认迁移、URL 参数和嵌套路由另行开发。旧 Node/Application/Router 的用法保持兼容。

## 2. 现有代码约束与方案选择

- `component_state.nim` 将 State 限定在所属 UI 线程；写队列封存后，由已接受候选发布，拒绝不重放 updater。
- `managed_runtime.nim` 已有组件 owner、active 标记、保留页面、暖列表行以及候选覆盖层；`publish` 不调用用户代码。
- `core.nim` 用同一门禁接受 State 与宿主，`uiTask` 当前是同步 batch，不能充当跨线程投递入口。
- `gpui_session.nim`、`gpui_bridge.nim` 没有任务泵。Rust 目前仅在配置 watch 时轮询外部状态，不能把任务更新混入 status/ready/rendering 查询。
- 现有 C 头文件明确要求 accept/discard/detach 不分配、不调用业务代码；销毁回调必须另设普通 Nim 安全边界。
- Win32 host 已将业务 tick 与窗口过程分离，可沿用这个边界，不在 WndProc 执行用户回调。

比较三个方案：

| 方案 | 优点 | 代价/限制 |
| --- | --- | --- |
| 固定工作线程 + owner 消息通道（推荐） | 同步数据库查询和阻塞 I/O 也可离开 UI；取消和过期校验由框架集中维护 | 需明确 Nim 线程内存所有权、队列预算和退出语义 |
| UI 线程轮询 `asyncdispatch` | 原生异步 I/O 接入较轻 | 同步 SQL、CPU 工作仍阻塞 UI，不能独立覆盖本轮目标 |
| 业务自行创建线程，再调用投递 API | 框架新增代码较少 | 页面生命周期和取消留给业务，不符合自动维护目标 |

首版不混用两个异步调度器，不新增第三方依赖。使用固定 Nim 工作线程；业务可在工作函数内部使用其自己的阻塞客户端和连接。

## 3. 生命周期合同

在 `MountContext` 的开放初始化帧内登记 `onMount`、`onActivate`、`onDeactivate`、`onDispose`。每种回调每个组件最多一份；重复登记、sealed context、其他 owner 或非初始化阶段登记都明确拒绝。回调登记和任务 scope 占用计入组件 owned bytes，初始化失败即随候选丢弃。

生命周期由接受前后实例差异决定，不依据 render 次数：

| 已接受转换 | 回调 | 任务行为 |
| --- | --- | --- |
| 不存在 → active | onMount 一次；不额外调用 onActivate | 允许回调排队首批任务 |
| 不存在 → retained/inactive | 无进入回调；之后恢复只交付 onActivate，不补 onMount | 保留 owner/State；启动权限按最终 retention 与活动态判断 |
| active → retained/inactive | onDeactivate | 默认取消；显式保留的任务继续 |
| retained/inactive → active | onActivate | 不自动重启旧任务；需要重载时在此回调发起 |
| active/retained → disposed | onDispose 一次；不再追加 onDeactivate | 全部任务失效并请求取消 |
| 同一候选中创建又删除，最终未接受 | 无回调 | 不启动任务 |
| 候选失败 | 无候选生命周期回调 | 已接受页及任务保持原样 |

卸载和停用按子组件先于父组件；挂载和恢复按父组件先于子组件。同一深度使用已接受或候选子树的确定顺序，不依赖 Table 迭代顺序。列表暖行也使用停用/恢复语义；淘汰行使用销毁语义。

回调从普通 Nim UI 安全点进入：入场前要求`inUpdate=false`、renderer prepare/apply/accept/discard 已完成，并进入该 Runtime 的 `executionScope`。回调体可处于`uiTask`自身防重入保护中；该保护标记不等同于render/commit阶段，不能拒绝回调中合法的State与任务写入。`publish` 仅发布预先准备的事件记录；C detach 只关闭预分配的投递门和设置取消标记，不执行回调。最终清理在 `runDesktop` 返回后的 Nim finally 或显式 `closeRuntime` 中执行。

事件带 owner generation、接受 revision 和 activity epoch。挂载/恢复回调交付前重新确认 owner 仍处于对应活动代；过期的进入回调不再启动工作。离开/销毁清理仍执行一次，并拿到该次转换的只读事实。销毁回调中的旧 State 已 disposed；它用于释放 UI 线程资源，不能让旧组件复活。

回调报错按 owner/revision/phase 记录，继续清理其他 owner；不回滚已接受 UI、不重放该回调。回调中普通变量、文件写入等副作用仍不提供回滚。一次泵最多交付64条回调/完成消息，另设4ms调度预算；预算只约束是否开始下一条，不能抢占正在执行的用户回调。

## 4. 公共 API 草案

新建 `leaf/component_tasks`，由 `leaf/components` 导出公共入口。生命周期和任务 scope 在组件 initialize 中取得，事件闭包可捕获 scope；scope 不是线程安全的 Runtime 引用。

```nim
type
  TaskRetention = enum cancelOnDeactivate, keepWhileRetained
  TaskScope = object             # 字段私有，UI线程使用
  TaskHandle = object            # 字段私有，单个任务身份
  WorkerContext = object         # 仅work调用期间有效，无UI对象
  TaskWork = proc(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.}
  TaskFailureKind = enum workFailed, resultTooLarge
  TaskFailure = object
    kind: TaskFailureKind
    message: string
  TaskResultHandler = proc(value: string) {.closure.}
  TaskErrorHandler = proc(error: TaskFailure) {.closure.}
  LifecycleContext = object      # 只读phase/revision及有效任务scope
  LifecycleCallback = proc(ctx: LifecycleContext) {.closure.}
  TaskPumpReport = object
    delivered, dropped, callbacks, failed: int
    pending: bool

proc taskScope(ctx: MountContext,
  retention = cancelOnDeactivate): TaskScope
proc onMount(ctx: MountContext, callback: LifecycleCallback)
proc onActivate(ctx: MountContext, callback: LifecycleCallback)
proc onDeactivate(ctx: MountContext, callback: LifecycleCallback)
proc onDispose(ctx: MountContext, callback: LifecycleCallback)
proc taskScope(ctx: LifecycleContext): TaskScope
proc acceptedRevision(ctx: LifecycleContext): uint64

proc startTask(scope: TaskScope, key: string, input: string,
  work: TaskWork, onResult: TaskResultHandler,
  onError: TaskErrorHandler = nil,
  maxResultBytes = 65536): TaskHandle
proc cancel(task: TaskHandle)
proc cancelled(ctx: WorkerContext): bool
proc pumpTasks(runtime: Runtime): TaskPumpReport
proc closeRuntime(runtime: Runtime)
```

实施时补 Nim 导出标记；上述名称、参数和默认值作为设计合同。TaskScope 每个组件最多一个，同一初始化中重复显式申请拒绝。首次生命周期登记可建立一个默认隐式 scope；之后首次显式 taskScope 配置并取得同一 scope，不重复收费，且不受 hook 登记先后影响。没有任务或生命周期登记的组件无需创建 scope；生命周期注册也不自动创建线程。

同一候选可能创建列表行后又将其保留为 inactive 暖行，临时候选宿主不等于已接受的 active 状态。因此存活 owner 的首次可见回调可能是 onActivate，业务不能假设每个 owner 都先收到 onMount。

`startTask` 仅允许所属 Runtime 的普通 UI 事件、生命周期回调、完成回调，或显式 `runtime.uiTask/batch` 内调用；初始化、render、updater、host prepare/apply/publish 中禁止启动或取消任务。对 disposed scope 启动抛 UiError；cancel disposed/已结束 handle 为幂等空操作；跨 Runtime/线程的调用拒绝。空 key、nil work/nil onResult、非法UTF-8 key及超预算输入在登记前拒绝。inactive owner只有keepWhileRetained scope可启动任务，cancelOnDeactivate在停用期间启动会明确拒绝；销毁及过期进入回调都不能取得可写scope。

TaskPumpReport的delivered计成功进入scope业务体后claim的有效完成消息，含work错误；callbacks计实际生命周期、onResult和onError调用；failed计回调/flush/scope交付异常。正常onError交付work错误不增加failed；未配置onError时仍消费有效错误消息并记录有界合法UTF-8诊断，callbacks为0。scope拒绝入场不消费消息；过期完成只计dropped。

每个 owner/key 采用 latest-wins：只有本次被接受的替换才使前一个任务失效。TaskHandle 的身份单调递增、不复用；scope、运行时关闭代和请求 generation 都参加交付校验。任务取消不改变路由地址；导航按现有路由队列执行。

## 5. 任务意图和接受门禁

`startTask/cancel` 首先登记任务意图，不立即投递 worker或修改旧任务有效性。意图与当前 State 队列一同封存、在候选覆盖层准备，并经过现有 validator/preparer/backend gate。返回的 handle 在接受前为 pending，不能被当作已经执行的任务。

- State/导航/任务共同接受：先发布 State、页面身份及任务代，然后由后续安全点将已接受启动意图送入 worker。
- build、snapshot、预算、validator、prepare、apply、scope入场失败：丢弃全部候选意图；旧任务、取消标记、owner generation和页面State不变。失败事件不重放任务。
- 只有任务意图、State无变化：仍走一次轻量元数据候选及后端门禁，接受revision只加一；不重算根组件、不导出Snapshot、不生成全树JSON。若后端有空batch优化，只能跳过物理操作，不能绕过接受/拒绝判定。
- 同一事件同 owner/key 多次启动：仅最终请求进入准备；中间 handle失效。启动后又取消：不投递。最终候选移除 owner：其启动意图丢弃。
- 提交接受后 executionScope 收尾失败：保留已接受意图与生命周期事件，不回滚或重放；待下一次可进入的 UI 安全点处理。它们不能因为调用方看到异常就被再次登记。

在host apply之前预留任务、生命周期记录、结果槽和发布容量。`publish` 不调用work、业务回调、Channel发送或线程创建；这些只在普通安全点执行。工作线程在任务服务首次需要时、进入任何候选host apply之前建立并验证；失败返回明确启动错误，不接受无法兑现的启动意图。

## 6. 工作线程、内存和取消

任务服务由 Runtime 拥有，默认2条工作线程，最多64个未收尾任务。关闭的任务服务与新Runtime隔离，不共享可复用 owner编号。线程关闭/重建不是导航或组件render的一部分。

work必须为无捕获的 `nimcall,gcsafe` 函数，输入/输出为拥有所有权的string字节载荷。JSON、文本或业务编码由应用选择，框架不解析。`onResult/onError`闭包始终存放在UI线程的注册表；跨线程消息只有任务编号、字节载荷、失败信息和受控取消信号。禁止传递Runtime、State、数据库连接、ComponentModel、闭包环境及GPUI对象；不通过cast绕过Nim线程检查。

工作输入在提交前复制为独立载荷；通道传输按Nim2.2.6/ORC实际所有权规则实现并测试，不将普通共享ref当安全消息。取消信号使用独立共享分配及原子标记，有明确的UI/worker引用计数；WorkerContext只在work调用期间借用，不能逃逸。队列关闭和共享内存释放必须等最后worker引用释放，不能因窗口消失提前free。

每个input最多1MiB，key最多256UTF-8字节；全Runtime排队/执行输入最多8MiB。每任务maxResultBytes默认64KiB、上限1MiB；接受前按声明上限预留结果槽，全Runtime预留总额最多8MiB。超容量在候选阶段明确拒绝，不静默丢失最新完成结果，不在UI线程阻塞等待可写通道。报错消息截断为4KiB并保持合法UTF-8。

结果超上限转换为resultTooLarge；work的CatchableError转换为workFailed。不吞掉Defect、不跨线程转移异常对象。onError为空时记录任务错误；回调错误记录为交付错误且不重试。

上述预算限定框架保存的记录和载荷，不承诺限制业务work内部、客户端或数据库的分配。取消是协作式：队列中任务跳过，运行中work通过cancelled检查；无法中断的I/O仍可能完成，但结果必须被丢弃。外部请求/数据库写入已发生的副作用不能撤销，应用应设置超时和自身事务。

数据库work自行打开/关闭连接并使用同步withDatabase，不借用UI连接，也不跨线程传递Model/Query对象。工作结束必须finally释放连接。

## 7. 结果交付与页面保留

worker写入已预留完成槽后通知任务泵。UI线程取出结果时校验runtime关闭代、owner存在性、owner generation、key当前请求generation及retention/activity epoch。失效结果只计dropped并释放载荷，不调用用户闭包。

有效结果的回调进入所属Runtime的executionScope及独立uiTask，可排队State更新或新任务；每条完成消息最多交付一次。在scope成功入场、即将调用用户闭包时才标记消息已消费；scope拒绝入场则保留消息并结束本轮泵，不忙等。交付导致render/宿主失败时，State及该回调登记的新任务按门禁拒绝，但原完成消息已消费，普通业务副作用不重放。需重试时由用户事件显式再次发起。

默认cancelOnDeactivate在已接受停用时立即令旧请求代失效并设置取消信号；返回页面后只有onActivate显式发起的新请求可更新它。keepWhileRetained允许完成回调更新隐藏页已接受State，沿用既有“不render隐藏页、不建立宿主”的合同；owner最终销毁后仍一律丢弃结果。

任务结果不跨页面按局部控件key寻找目标；只绑定所属组件身份。页面同名key、页面重建、列表行key复用和Runtime重开均不能使旧任务命中新owner。

## 8. 宿主泵、兼容与退出

任务泵与status/ready/rendering/frame诊断分离。无消息时不render、不产生宿主操作、不导出Snapshot或UI树，不改变accepted revision。不把worker完成结果直接推入任何C/GPUI调用。

GPUI ABI2增加能力位`LEAF_CAP_TASK_PUMP=1`、配置位`LEAF_CONFIG_TASK_PUMP=2`和独立`LEAF_REQUEST_TASKS=8`，复用现有结构布局，不增加字段。Nim仅在库宣告能力且应用使用本功能时请求泵；Rust仅在配置位启用后启动16msUI计时任务，且仅根view启动一份。任务请求沿用现有同步prepare/apply门禁和accepted-scope-error回报，不在Rust持有HostStore可变借用时回调Nim。

ABI1新增可选导出`leaf_gpui_task_pump_version`返回1供Nim预检；成功ready响应以严格布尔`capabilities.task_pump=true`协商新`tasks`op。Rust只在ready成功且能力为true后发送新op。ABI1任务更新仍承担已有完整活动树Snapshot传输成本；不能套用ABI2增量性能结论。status/ready/rendering既有语义不改。

旧应用可加载新库，Rust不发送未协商的新op。使用本功能的新应用加载不支持任务泵的旧库时，在执行进入生命周期回调、完成交付或worker启动前明确要求重建桥接库；不让应用进入结果永远无法交付的状态。若初始Runtime的owner已经接受，能力配置或桥接安装失败后仍须在普通UI关闭边界使State失效，并执行一次最终onDispose清理；未接受候选不产生清理回调。此最终清理不构成正常进入或任务执行，失败收尾保留原能力/安装错误。运行时在桌面接入时记录泵能力；若事件后来才挂载使用本功能的组件，也在候选准备期间校验并拒绝不支持的配置，不能只检查初始页面。GPUI头文件C/Nim/Rust布局检查继续通过，新增常量和值有跨语言一致性测试。

Win32安全tick调用相同pumpTasks，新增独立任务唤醒/计时来源，不复用close重试timer编号；WndProc只投递标记。关闭、busy、安装hook和native事件派发期间不泵。headless通过pumpTasks显式驱动，测试使用可控制的worker栅栏，避免依赖任意sleep。

closeRuntime在UI线程关闭接收门，失效所有owner/任务代，设置取消标记并清空待交付业务闭包；调用一次onDispose清理后幂等。销毁回调处于关闭态，不能发起任务。宿主session换绑/卸载不自动等同Runtime销毁；只有应用最终退出或显式closeRuntime关闭它。

公共closeRuntime在合法UI业务回调内调用时采用两阶段关闭：立即关门、取消并使所有已接受State失效后返回，不在该回调内执行清理或join；该业务体先前排队的State/导航/任务不再接受。随后普通closeRuntime或宿主finally执行尚未claim的清理并最终回收pool。render、updater、prepare/apply、host安装阶段及跨Runtime/线程调用明确拒绝。onDispose内递归close幂等返回，不递归清理或join；scope入场拒绝留下尚未执行的清理，之后普通close只重试未claim部分。

GPUI失败收尾每个边界只尝试一次普通close，内层已经尝试的清理不由runDesktop外层立即重试。若scope拒绝留下未claim清理，必须向调用者移交可达Runtime，不能仅在失败构造对象内保存。`GpuiRunError of UiError`保留原异常msg/parent，提供`cleanupRuntime: Runtime`和`exitStatus: Option[int]`。`runDesktop`末尾可选`cleanupOwner: ptr Runtime=nil`只同步写出未完成清理owner，传入slot必须为空且不被隐式覆盖。已有整数status时，指定out可保留原status返回；未指定out但清理未完成则抛GpuiRunError并以exitStatus保存原status（含0），由cleanupRuntime显式重试。无原整数返回的主异常仍抛出，exitStatus为none，原错误不能被cleanup异常替代。清理成功时既有返回不变；不得以closed=true推断清理已完成。调用者在普通UI边界重试close并在成功后释放owner，不使用无界全局保留队列或析构重试。

活动期生命周期pending仍最多40000条，树与pending共享16MiB门禁。最终关闭使用独立清理容量，最多50000条（已有未claim dispose最多40000，加最终live owner最多MaxNodes=10000）；只接管已存在的清理引用，关门后没有新producer，不增加活动期event额度。关闭队列准备一次、按owner stamp去重，重试只处理未claim部分，不重复追加或收费；不得为容量丢弃dispose。retireDeferred不分配清理队列，存储在普通close或合法busy-close准备，关闭后普通pump停止投递。

C detach只标记最终投递门关闭和取消，返回后的普通Nimfinally完成生命周期清理。窗口关闭不在UI回调、WndProc、renderer detach内join工作线程。工作函数须设置自己的超时；最终任务服务回收等待worker结束，框架不承诺任意阻塞work立即退出。保存尚在运行的共享控制块直到安全结束，禁止强制释放或遗留可调用的UI闭包。桌面run的最终退出可能等待不合作work；文档和测试必须区分窗口关闭响应与进程退出耗时。

## 9. 文件范围与依赖顺序

| 范围 | 修改目的 |
| --- | --- |
| 新`component_lifecycle.nim`、`component_tasks.nim`、`task_worker.nim` | 生命周期登记/事件队列、任务意图/交付、线程与载荷所有权分离 |
| `component_description.nim`、`component_state.nim` | MountContext开放帧校验、owner关联；State保持UI线程限定 |
| `managed_runtime.nim` | 以accepted实例差异准备生命周期及任务owner变化；列表/路由共同覆盖 |
| `core.nim`、`components.nim` | 普通安全点、task-only候选、泵/关闭入口及公共导出 |
| `gpui_api.nim`、`gpui_bridge.nim`、`gpui_session.nim`、`desktop.nim` | 能力预检、ABI泵与最终清理 |
| GPUI Rust `bridge/bridge_v2/desktop/host_view`及C/Nim/Rust协议定义 | 严格协商、独立tick、增量提交及关闭 |
| Win32 `host.nim`和相关协议适配 | UI安全tick集成、独立timer与关闭测试 |
| 新组件任务/生命周期/fault测试，扩展官方runner和native fixture | 确定性并发、接受/拒绝、跨宿主验收 |
| `examples/component_tasks.nim`、API/开发/验证文档、SDK回归 | 可运行加载/重试/切页样例与包搬迁验证 |

依赖顺序：先线程载荷/取消边界与生命周期事件模型；再接入任务意图和接受门禁；再做路由/列表/退出故障矩阵；之后接入宿主泵及示例，最后整合验收。共享core/managed_runtime文件顺序修改，避免并行覆盖。

## 10. 验收标准

1. 先实际验证Nim2.2.6/ORC工作线程的string所有权、gcsafe无捕获work、trySend失败/取消/关闭释放，证明方案可用；不能靠cast共享GC对象。
2. 首次接受仅mount一次；往返页面deactivate/activate各一次；disposeOnLeave与router卸载正确销毁；候选创建失败、同候选删除不触发已接受回调。列表活动、暖行和淘汰覆盖同样规则。
3. 默认离开取消与显式隐藏继续分别验证；相同key请求反序完成只能交付最新结果；离开返回、删除重建、换Runtime和列表行复用都不能写错owner。
4. build/snapshot/预算/validator/prepare/apply/scope入场失败均不启动或取消旧任务；accepted scope收尾失败仍只执行一次已接受意图。task-only候选经过host门禁且无全树重算。
5. 完成回调失败或其UI更新拒绝不重放消息；一个owner清理报错不跳过其他清理。旧State保持disposed/跨线程拒绝，工作线程不能执行UI闭包。
6. 输入/结果/任务数超预算明确失败；满队列UI不阻塞；取消和运行结束后载荷、结果槽、共享取消信号收回。重复挂载、拒绝、往返、取消循环内存趋稳，无候选链或完成闭包积累。
7. 无任务/空tick不render、不导出Snapshot、不发UI树、不变revision；100/1000/5000无关兄弟场景只更新目标组件，记录实际计数而不承诺恒定时间。
8. ABI1/ABI2新旧组合严格协商：旧应用+新库不收到新op；新功能+旧库在启动work前明确失败。C/Nim/Rust布局及常量校验通过，status/ready/rendering回归保持原义。
9. Linux真实窗口验证无额外点击即可由后台完成更新界面、失败重试、切页取消、保留页返回与正常关闭。ABI1/ABI2和CACHE0/1矩阵记录实际源码/库hash，不能用headless代替。
10. 跑官方Nim全量/发布检查、Rusttest/fmt/clippy及ABI检查；搬迁SDK后编译运行任务示例，验证无需仓库路径或环境覆盖。Windows/macOS实机、系统IME与跨屏DPI未执行时保留NotRun。

## 11. 工作区与后续门禁

原协调Agent：`22171a3c-32d8-4ff6-baab-8ed6a7a22963`；原会话工作区：`wks_fd0d6c1dbee5f84c`（用户本地空间，保留）。

执行workspace：`wks_43c47436537996f7`，标题`【自动】组件异步任务与生命周期`，路径`/home/jimxl/.paseo/worktrees/1c1rvoii/component-async-lifecycle`，分支`feat/component-async-lifecycle`，基线如文首。设计、编码、修复和验收复用此空间。

用户回复“继续”后进入实施计划阶段；计划为`docs/superpowers/plans/2026-10-17-component-async-lifecycle.md`，包含实际profiles配置、编码边界和独立验收。计划阶段仅补充接口、容量及兼容细节，并澄清安全点入场与uiTask保护体的区别；尚未派发实现Agent或执行产品测试。合并/推送另按用户授权执行；尚未获本功能合并/推送授权。成功合并及推送后的归档须先完成仓库、成果及活跃会话检查。
