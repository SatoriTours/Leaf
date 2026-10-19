# Nim + GPUI 架构

Nim 管理应用状态、组件闭包、不可变描述、稳定身份、缓存、事件回调和虚拟列表。Rust 动态库通过 GPUI 创建窗口，使用 GPUI Kit 的控件和资源完成绘制、布局、输入与焦点管理。

```mermaid
flowchart LR
    A[Nim 应用状态] --> B[Nim Runtime / Node 描述]
    B --> C[C ABI / UTF-8 JSON]
    C --> D[GPUI 窗口与布局]
    D --> E[GPUI Kit 控件]
    E -->|同步事件与视口请求| B
    B --> F[headless 验证]
```

`core.nim` 校验和发布完整候选树，`gpui_styles.nim` 校验桌面样式。`gpui_bridge.nim` 保留 Runtime 与返回缓冲区；`gpui_api.nim` 延迟加载 `leaf-gpui` 动态库。`desktop.rs` 协调控件，`styles.rs` 转换 GPUI 样式，`lists.rs` 使用 GPUI 原生虚拟列表按需请求 Nim 行描述。

C ABI 版本为 1。`leaf_gpui_run` 同步运行主循环，Nim owner 在整个调用期间存活。回调请求和响应均为 UTF-8 JSON；Rust 在下次请求前完成响应复制与反序列化。Nim 异常在回调内捕获；Rust 导出入口捕获 panic 并返回非零状态。双方在同一 UI 线程运行，后台线程不访问 Nim 闭包。

业务 render 在初始化与事件更新时执行。GPUI 重绘读取缓存描述；视口变更只构建所需列表行。输入实体按稳定 ID 保存，模型值不变时避免 `set_value`，保留选区、撤销与输入法组合状态。过时、禁用及无处理器的事件不执行回调。更新失败保留成功描述和回调，并展示错误信息。

CLI 通过 Cargo 增量构建桥接库，再通过 Nim 编译业务程序。桥接库放在应用可执行文件旁，发布包使用相同布局。headless 路径不初始化 GPUI、不加载桥接库。图形系统、驱动与字体属于平台运行依赖。

## A1 原生公共边界（已实现并通过 Nim 测试）

以下范围由 `scripts/test.nim` 中的 Nim 套件实际验证，不代表任何原生平台已验收：

- `styles.nim`：旧字符串 Styles 的后端中立语法校验与有类型转换（`Dimension` auto/fixed/fill、RGBA、layout/control/accessibility props；`Option` 区分未指定与显式值）。
- `core.nim` 提交门：`setCommitter` / `acceptedRevision` / `proposedRevision` / `stagingChanged` / `freezeEvents`。顺序为构建 → 校验 → preparer → committer → 发布；后端拒绝时不发布树、索引、缓存或 revision，业务对象不回滚。
- `backend.nim`：能力表、不透明 `NodeHandle`、`MountedEntity`、create/update/move/remove 批次、同步 Backend 契约与 `HostContext`；`checkCapabilities` / `effectiveProps` 区分必需能力与可降级装饰。
- `reconcile.nim`：纯差异协调器。身份按父子结构复用，祖先换类型会重建全部后代；同父变序生成可顺序应用的 handle 索引；过期或外来 plan 被拒绝（私有 owner 与 accepted-state generation）。
- `backend_session.nim` + `backends/headless.nim`：记录型 Backend 与会话。事件队列只在显式 `drainEvents` 处理；setter 通知被抑制；apply 失败恢复旧 accepted 实体并推进 mount generation，恢复失败则冻结 Runtime 业务 dispatch。列表按 handle + source generation 请求，视口按 item key 跨 source 恢复。会话关闭若发生在 Runtime 更新中会以可捕获 `UiError` 明确拒绝，host 应在安全 tick 重试；一旦开始 teardown 即进入 event-ineligible，旧队列失效，`enqueue`/`drainEvents`/`requestRows` 不再触达业务，`backend.dispose` 失败仍可重试。hook 按所有权 token 卸载，`clearCommitter`/`clearPreparer` 与安装同样经过 executionScope 和更新期 guard，不误清他人 hook。
- `-d:leafHeadlessOnly`：runner 不导入 desktop；无参数明确返回非零，不静默打开窗口。headless 构建不链接 GPUI / Vulkan。

安装 hook 时，候选与 hook/owner 在 executionScope 成功退出后才发布，安装期 guard 包含 Scope 退出阶段。`installCommitter` 的可选 `RuntimeInstallLifecycle`（confirm/abort）与 committer owner 一起保存和卸载；原二参数调用和 RuntimeCommitter 签名保持兼容。正式 BackendSession 自动注册该生命周期，因此直接调用 Runtime 的 `installPreparer` / `setPreparer` 也会将 Native apply 后的 plan 保持 pending，Scope 成功后才确认 Session/reconciler 和 Runtime 的接受状态。Scope 后置错误在合法 Scope 中恢复旧 Native 描述、推进监听代际；恢复失败或恢复 Scope 拒绝执行 body 时 fault/freeze。后者仅执行 framework 故障标记，不绕过 Scope 恢复 Native 或卸载 hook。confirm 只发布 framework metadata，不调用业务/Native；任意旧式外部 committer 的业务副作用不属于补偿合同。

Backend 实例通过私有资源占用 token 拒绝跨 Runtime 的同时使用。占用拒绝不 prepare/apply/dispose 输入实例；attach 只清理本次实际取得的资源。清理错误附加到 primary 异常；若合法 Scope 未能移除本次 hook，则保留仍被引用的 Backend 并报告失败。成功 Session dispose 后释放占用，失败关闭仍可重试。

输入法 / composition、导航历史、移动生命周期与 SQLite、Canvas、原生构建与实机验收不在 A1 范围。

## A2 T1：平台消费最小协议与受控编辑状态机（additive）

以下为 Native 平台消费所需的最小可选协议，已由 Nim 测试验证；不代表任何原生平台已验收。

- `core.nim`：`Event.composition: CompositionPhase`（默认 `compositionNone`）。不新增 `EventKind`，旧 `value`/`checked` 与 snapshot 事件 JSON 形状不变。
- `styles.nim` / `widgets.nim`：`input(..., resetToken = 0)` 仅在末尾追加可选参数；非零时在 attributes 输出 `input_reset_token` 十进制字符串，0/省略不产生属性。`ControlProps.resetToken: Option[uint64]` 只接受 input 的无符号十进制 0..high(uint64)，负数/溢出/浮点/错 kind 均报错，不走 float style 路径。
- `backend.nim`：`ControlFeature`/`BackendCapabilities.controls` 为必需能力，`cfInputReset` 由 `fullCapabilities` 声明；非零 reset token 在 compatible 也不降级，缺失直接拒绝。新增可选 hook `accepted`（纯 framework metadata）、`rebind`、`bindingValid`、`settle`，原五必需字段与旧调用保持兼容。
- `backend_session.nim`：`EventEnvelope.bindingGeneration` 默认 0；`bindingValid` 非 nil 时 enqueue 与 process 均复查。`accepted` 仅在成功 accept 后通知（install confirm 无额外 Native apply）。restore 后推进 generation、清队列/sequence 并 `rebind`，失败与 restore 失败同样 fault+freeze。事件处理后、Runtime Scope 完全返回且实体/绑定仍有效时通过 `settle` 结算最新 accepted props；settle 失败 fault+freeze 并停止剩余批。
- `native_edit.nim`：纯 `EditorState` 状态机（无原生资源）。`settleEditor` 处理普通 ack（同文本不 setText、保留选区/组合；拒绝/格式化同步 accepted 值；组合期不写冲突，`compositionEnd` 按最终模型同步）。`resetEffects` 为显式同值 ack 例外，输出 ForceCancel→forced setText→末尾选区；`completeReset` 仅在 Native 效果全部成功后消费 token。
- `gpui_bridge.nim`：旧桥接在独立 validator 分支拒绝显式非零 reset token；`gpui_styles` 保持 style-only，不全面强验旧 control 属性。

## A2 T2：有限 DIP 线性布局与 Win32 能力边界

- `native_layout.nim`：纯几何的 row/column 布局。`layoutTree(entities, content, measure)` 以有限 content 为根，递归计算 intrinsic（auto 来自 measure；容器 preferred intrinsic 由子声明基数/天然 preferred + gap/padding 得出；fill 主基数为 0，不吸收已分配的 fill/grow 余量；交叉 preferred 不吸收内部 fill/stretch 消费的空间，不递归到无限）。主轴分配 `max(0, 可用 - padding - gaps - bases)`，负余量不 shrink、按 clip 裁剪；缺省 `fill` 权重 1，**显式 `flexGrow`（含 0）优先**；`justify` 仅消费正余量，`between` 单子不除零；交叉 `stretch` 只扩未显式 fixed 的 auto/fill，不压小 intrinsic。**测量约束**：`MeasureProc` 收到的是实体自身的**有效**有限局部约束（preferred/base 阶段声明 fixed 轴对叶与容器统一生效，padding 从局部 content 扣除），不是祖先尺寸。测量与排列共享同一套宽度/主轴分配决策：先按有限宽度与 auto/fixed/fill 决定子宽度（column 的 align stretch 扩 auto/fill、不扩 fixed、不压小更大 intrinsic），再在该最终宽度下测 preferred height；此阶段最终宽度优先于声明 fixed 宽基数（如 fixed width 10 + grow 2 分得 100，应按 100 测高），auto 高度与祖先 auto intrinsic（含嵌套 row）以及后续 sibling 位移都按该结果更新，fixed 高度不被覆盖。结果以 `(handle, 有效局部宽, 有效局部高)` 为 key 在单次 layout 内缓存，同一有效 key 跨阶段只测一次（无 grow 的 fixed 20×50 仍只测有效 20×50），真实不同的 10/100 宽约束各测一次；每次 `layoutTree` 使用独立 cache，不复用上一次调用。派生权重/坐标/clip 保持有限，无法表示时明确 `UiError`。`pixelEdges(rect, dpi)` 用共享边界 round（right/bottom round 累加 extent），并先检查非有限值与 int32 越界。`LayoutBox.rect` 为分配框，`clip` 为继承的可见区域；完全在 clip 外的实体由调用方按身份跳过，不传越界坐标给平台。真实字体测量仍属 T4，本模块只消费注入的 measure。
- `backends/win32/capabilities.nim`：纯 Linux 可验证的 `win32Capabilities()`。支持 column/row/text/button/input/checkbox/toggle/progress/tag/separator/spinner、gap/padding/width/height/flex_grow/align/justify/overflow、全部四种 align、start/end/center/between、仅 hidden overflow、仅 default variant、`cfInputReset`；不声明 virtualList、min/max、flex_shrink、around/evenly、scroll/visible，也不声明颜色/字体等装饰。required 值缺失在挂载前拒绝，装饰与 variant 按 compatible 结构化诊断 / strict 拒绝。switch 映射原生 checkbox 语义，不是装饰。
- 权威结构顺序来自 Session acceptedEntities 的 `index`；`Recording.entities.index` 是历史镜像，不作 layout 坐标权威，只用 `Recording.childrenOf` 作结构对照。
- 本任务不含 Win32 API、真实字体测量、窗口/DPI 宿主：真实测量属 T4，Linux 测试不声明原生测量通过。

## A2 T3-L：UI 线程 guard 与 close 状态（L 子门，非 W 验收）

- `ui_thread.nim`：`guardUiApplication(app, currentThread)` 在调用时捕获 owner 线程，返回 `app` 的值副本并包装 `executionScope`；包装 scope 先检查 owner，再把带 body-entry 检查的 guarded body 交给原 scope（原 scope 为 nil 时直接执行）。只支持同步恰一次 scope：异线程入口、0 次 body、重复 body 都被拒绝。每次调用使用原子 latch：任一退出路径（正常返回、原 primary 异常、0 次 body、worker 违规）都会撤销该次调用的 body 授权，被 scope 保存的 guarded body 之后在 owner 执行会被拒绝，违规后的 owner fallback 也不执行业务；即使原 scope 吞掉 worker 异常，owner 返回时仍抛 `UiError`，不会让未 render 的 Runtime 初始化成功。原 primary/post-body 异常保留类型与消息，guard 违规作为附加 secondary 信息；不 import Win32、不改 ORM scope 参数/context、不改 Runtime 安装与发布顺序。
- `backends/win32/host_state.nim`：`CloseState(pending, posted, complete)` 与 `requestClose` / `markClosePosted` / `closeOnTick` / `closeSucceeded` / `closeFailed`。重复请求合并为单个 pending；`posted` 合并 WM_APP/timer 安全 tick；busy tick 返回 false 且不消费请求、不自旋；失败保持 pending 并可重试；只有真正 dispose 成功才 `complete`，完成后幂等、不再重开。
- `scripts/test_win32.nim`：非 Windows 明确输出 `NotRun` 并 exit 2；Windows 上扫描 `tests/windows/test_*.nim` 逐套 compile/run 且要求 exit 0，空目录/无测试明确失败——没有实际运行的 Windows host 测试就不报成功。
- W 实现与实际开发测试见下节；独立产品验收和平台支持状态由 Task3-W 报告/独立 review 判定，L 本身不能证明 W。


## A2 T3-W：owned Unicode Win32 Host

`backends/win32/api.nim` 仅包含固定宽度/指针宽度的 W ABI 和少量系统入口，opaque handle 使用 Windows header 类型；`calls.nim` 是内部 Nim closure 转发表，系统默认全转发真实调用（closure 不是 stdcall callback）。产品没有 C shim。`WndProc`/声明的 `SUBCLASSPROC` 是 stdcall、raises:[]；CatchableError 记录后在普通 Nim pump 边界交付，Defect 不宣称可恢复。窗口 userdata 仅存非零数字 cookie，owner-thread registry 强持 Host，不存 Nim ref 地址。

保留 `createHost(title, DipSize, calls=systemWin32Calls())`、`context`、`setSafeTick`、`requestClose`、`pump`、`destroyHost`。增加 native-only `bindSession(host, actual BackendSession, scopeBusy: proc():bool {.closure,raises:[].})` 和 borrowed `windowHandle(host):HWND`。所有方法/观测先检查真实 GetCurrentThreadId；HWND/context 还要求 live。HWND 不进入 DSL/JSON/HostContext；借用者不得销毁父 HWND。绑定要求 context.sessionId 匹配、唯一 active binding，mountGeneration 仍以 Session 为准。

`ui_thread.nim` 新增 `UiScopeActivity`、`newUiScopeActivity()`、owner-only `busy(activity):bool {.raises:[].}`，以及 `guardUiApplication(app,currentThread,activity)` 重载；原二参数调用保留。两者共用原 body guard，capture 在任何 newRuntime 前，depth 在原 Scope 入口前增加、完整 post-body/异常返回后 finally 清除；不改 ORM context、业务/SQL 或同步 exactly-once 合同。Win32 装配先以真实 GetCurrentThreadId guard Application，再 newRuntime，随后创建 Host、attach BackendSession、bindSession(activity.busy)。Host 不以 Runtime.inUpdate 单独推断 Scope 已退出。

`BackendSession.requestClose` 只置 closing 并使队列/已捕获事件不再 eligible；不卸 hooks、不调用 backend.dispose、不永久 freeze。WM_CLOSE 观察即应用此意图；当前合法候选仍走原 confirm/abort。安全 turn 必须绑定完成、完整 Scope 空闲、无 update/hook-install/native dispatch/tick/release 递归；pending close 跳过普通业务 tick，先实际 Session.dispose，并确认 disposed=true，再 timer→window→root→class 清理。dispose/DestroyWindow 失败保留 pending 与资源所有权，按一发 timer 延后重试；窗口已销毁而 class 清理失败向 owner 抛错，必须显式 destroyHost 重试，不在死 HWND 排 timer。完成后清 tick/Scope query/Session/calls 引用并切断闭环；不依赖 ORC/进程退出释放 OS 资源。

WM_NCDESTROY 是不可逆的 native lifetime 边界：即使 userdata 清除抛 CatchableError，finally 仍撤销 HWND、窗口计数与 registry root，borrowed getter 随即拒绝死句柄。普通 Nim cleanup 保留 callback 原异常引用/类型/parent，class 清理失败仅追加 secondary 并保留该 class 的显式 owner 重试资格；报告异常时不提前 complete，成功重试后才断开回调闭环。Host 仅保留必要 pending 异常与累计诊断计数，不保留无消费者的强引用错误历史。

WndProc 只记录关闭/几何/错误及通知；业务 tick 和实际 release 都在 DispatchMessage 返回后的普通 Nim 边界。nested/busy pump 有界 PeekMessage 后返回，不阻塞或自旋；WM_APP/timer 消费会清 posted，重试 timer 显式持有并清理。GetMessage -1 抛 UiError、0 返回 WM_QUIT 的退出值且不表示 Session 已释放；Host 销毁不向同线程其它窗口发全局 WM_QUIT。

DPI policy 在 HWND 前初始化，保留宿主已选 awareness。标题先检查 UTF8、NUL、原预算与 UTF16/整数界限；创建与读取均用 W API。HostContext 使用真实 client rect/scale 的有限 DIP；WM_SIZE/WM_DPICHANGED 更新几何并安排安全布局，不直接 render/重建 input。`HostDiagnostics` 返回值副本：liveWindows/liveRoots 是当前 owner 线程全部 Host registry 总数，callbackErrors/pendingClose 属当前 Host；不把 T4 child/font/subclass 计入这些数字。

`tests/windows/test_win32_host.nim` 实际 Windows 窗口/Session 测试用 Recording Backend 验证 generic lease 集成，Recording 不是 Native 子控件后端。测试内 windows.h/commctrl.h 对 sizeof/alignment/offsetof/WNDPROC/SUBCLASSPROC 做真实 GCC 编译断言；EDIT/BUTTON 仅导航 fixture，由测试显式销毁。Windows runner 的子 suite threads:on、forceBuild 和独立 `LEAF_WIN32_TEST_OUT` cache/out；非 Windows仍明确 NotRun exit2。

Task3-W 当前仅获授权的 elevated DEVELOPMENT 执行证据：真实 Session/Token 值记录在报告，不据此宣布 NativeReady、标准权限或完整 Windows 支持。E3 non-elevated 与真实 IME/多显示器 DPI/accessibility(H) 仍开放；T4–T6 的实际控件和编辑实现见下节；Native Backend 已取得资源、尚未 bind 的 startup 窗口现由确切租约持有，不能拿父窗口销毁替代子资源释放。原 T1M2/T5/final 集成义务由真实控件回归核对，不能仅由 Host 测试结案。


## A2 T4–T6：Win32 表单实现与构建入口

`backends/win32/backend.nim` 统一持有 stock HWND、subclass、编辑绑定和批次资源，`measure.nim` 持有系统字体与临时 DC。prepare 只创建隐藏候选，apply 消费候选，accepted 仅发布框架元数据；失败由 Session restore/rebind 恢复。宿主通过 `host_bridge.nim` 的确切启动租约管理尚未返回的 provisional Session，失败清理可重试，不误清其他 owner。

原生回调只捕获完整值与绑定代际并入队；安全 turn 在完整 executionScope 退出后 drain 和结算，不在系统回调里执行业务。per-control setterDepth 只抑制该控件同步 setter 通知，另一控件的真实通知仍可进入队列。EDIT 同值响应不写回；组合冲突延后，已接受的递增 resetToken 在 native tick 执行显式取消和强制同步。容器具有子对话导航语义，重排同步系统 tab 顺序。布局消费真实 GDI 测量及当前字体/DPI的有限缓存，主题/字体/尺寸变化只重新布局，不触发业务 render。

`targets.nim` 统一 backend/target/纯 headless 决策，命令行优先于 leaf.json，未配置默认 GPUI。`runner.nim` 在编译期选择 GPUI、Win32 或纯 headless；`build.nim` 在 native/headless 路径跳过 GPUI 构建和 staging，Windows EXE 仍嵌入 v6/PMv2 manifest。native doctor 不探测 Cargo/GPUI，native pack 在发布实现前明确拒绝。

开发 Windows VM 已用于真实 HWND/输入/宿主/构建测试；这与普通用户、真实中日文 IME、跨不同 DPI 屏幕和辅助技术的 H 验收分别记录。[开发与验收指南](native-win32-validation.md) 给出可复现命令、范围与未关闭的 H 门。A3 列表/导航/Canvas/发布及 Android 后端仍在后续阶段。

## 可选组件运行时与类型化 GPUI

`leaf/components` 提供 React 风格的组件身份、State 队列和更新边界。Nim 拥有组件模型及不可变 UI 描述，提交时只计算脏组件和受影响的宿主路径。接受态是平铺实例表和索引；候选保存局部覆盖，拒绝后释放新实例，成功时替换索引记录。组件及宿主各有 10000 上限，描述深度和总字节预算仍统一检查。

Rust 的 HostStore 保留已接受宿主控件、子项顺序和组件边界，用于后续增量更新及 GPUI 渲染。它保存渲染所需数据；业务回调和 State 留在 Nim。ABI2 使用固定宽度 C 结构与借用缓冲区批量传递 create/update/setChildren/remove；Rust 在同步 prepare 返回前复制需要保留的数据。普通局部更新不生成/解析 JSON，不重新传整棵树。

GPUI 为组件边界持有 Entity，普通宿主叶节点直接从平铺表渲染。只有外部宽高确定的边界启用缓存；内容自动测量、百分比尺寸保守渲染。尺寸、继承样式、主题、窗口变化和全局刷新传播失效。输入 Entity 保持独立寿命，同值模型同步不修改选区或组合态；普通重新挂载会建立新 Entity，列表源替换仅在同一列表、逻辑 key 与宿主祖先类型匹配时迁移。变量行高的行 provider 读取已接受节点，缺失行先使用高度估计，当前绘制结束后合并视口请求；相同视口与保护行不重复请求。退出在安全帧先释放平台 IME handler。

虚拟列表按接受的 key/generation 管理活动行和有限暖缓存，离屏行的 State 可能在淘汰后销毁。源替换及 viewport 构建失败保留之前接受的行。Snapshot 是显式诊断/headless 导出，按接受 revision 缓存；调用 Snapshot validator 或诊断整树导出会承担完整导出的成本。Native Backend 消费类型化宿主操作，Win32 当前仍可执行全量布局，不能据局部 Nim 计数宣称 Win32 帧已完全局部化。

## 托管页面路由与保留生命周期

`component_routing.nim` 在组件 initialize 中建立不可变地址配置和归属该组件的 `State[int]`；`renderPage` 依据 render 候选地址返回第三类描述 `DescriptionKind.pageOutlet`。出口实例保存页面名到根实例 id 的共享注册表以及当前活动子实例；注册表写入前复制，候选失败不改动接受态。`managed_runtime` 在 reconcile 中复用既有停用/恢复/递归擦除辅助：`retainState` 离开时停用页面子树并移出活动宿主与事件索引，返回时用原组件身份重建宿主；`disposeOnLeave` 离开被接受后递归擦除；整组保留页、暖行和嵌套 controller 在外部 router 卸载时一并释放。隐藏页只保留 Nim 模型与 State，不建立宿主。

配置字节、registry 键、页面实例和列表暖行全部计入既有 `MaxNodes`/组件上限/`MaxTreeBytes`/`MaxDepth` 预算。router 的 `configurationBytes` 在组件初始化时通过 MountContext 记账并按 owner 保留一次，初始化帧在成功和异常退出时都会关闭，已关闭上下文不能再次计费；renderPage 的出口显式使用 0 以避免重复计费。registry 的字节量缓存在出口实例上，只在登记新增或删除时调整；已有 page 的根 id 替换只更新值，不增加条目费用。正常重访不扫描键。

结构性计数（静态组件 render 次数、宿主操作数、子句柄数组长度）只描述受影响实例范围，不证明恒定 CPU 时间或 FFI 字节。页面根句柄变化时，宽共享父宿主需要一次包含全部未变兄弟句柄的 `setChildren`，其数组体积单独报告；本实现不承诺与兄弟数量无关的 O(1) 布局。快照导出与 validator 仍是显式完整导出；GPUI 仅使用 ABI2 typed 增量。
