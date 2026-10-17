# Leaf 组件异步任务与生命周期实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让托管组件在已接受的生命周期边界启动后台工作，安全回传结果，并自动取消或丢弃过期任务。

**Architecture:** 组件登记生命周期与任务scope；任务意图和State/导航共享候选接受门禁。固定工作线程只收发拥有独立所有权的载荷，UI安全点校验owner与请求代后交付闭包；GPUI与Win32分别接入同一个任务泵。

**Tech Stack:** Nim 2.2.6/ORC、Nim标准库线程/通道/原子操作；现有Rust、GPUI Kit 0.7.0及C ABI；不增加第三方依赖。

**Spec:** `docs/superpowers/specs/2026-10-17-component-async-lifecycle-design.md`（用户在原会话回复“继续”，确认规格后进入本计划阶段）。

状态：计划已获批准并执行中。Task1–3 已实现并独立验收；Task4–7 待执行。实际命令、退出码及审查证据见同日期验证记录和执行 ledger；以下预期断言本身不代表已取得的证据。

## Global Constraints

- work为`proc(input: string, ctx: WorkerContext): string {.nimcall, gcsafe.}`；UI闭包、State、Runtime、Model/Query、数据库连接和GPUI对象不得跨线程。
- 默认2条worker、最多64个未收尾任务；取消但仍在执行的任务仍占用额度，直到真实收尾。
- 单input最多1MiB，key最多256UTF-8字节，全Runtime输入最多8MiB；maxResultBytes默认65536、上限1MiB，总结果预留最多8MiB；错误文本最多4KiB且保持合法UTF-8。
- 每组件最多一个TaskScope、每种生命周期回调一份；默认cancelOnDeactivate，可选keepWhileRetained。
- 一次泵最多64条回调/完成消息、4ms开始下一条的调度预算；不抢占用户回调、不承诺业务work内存或取消即时生效。
- 生命周期只由已接受转换决定；publish/accept/discard/detach不调用业务代码，发布容量在host apply前准备。
- 新typed常量：`LEAF_CAP_TASK_PUMP=1`、`LEAF_CONFIG_TASK_PUMP=2`、`LEAF_REQUEST_TASKS=8`；ABI1可选导出`leaf_gpui_task_pump_version`返回1，严格ready布尔能力协商。
- 不改旧State线程限制和拒绝语义；不改NodeKind、既有结构布局、依赖锁文件或默认脚手架。
- 无消息不render、不Snapshot、不发UI树、不变revision；ABI1真实更新仍允许既有完整活动树成本。
- Windows/macOS窗口、IME、跨屏DPI没有实际执行就记录NotRun；Linux/Xvfb结果不能替代。

## Review Focus

1. 初始页没有任务、事件后来才挂载任务组件：支持的宿主仍能唤醒泵，旧库在候选接受前拒绝（Task5/6）。
2. 任务完成时executionScope拒绝入场：消息保留且泵停止本轮；真正调用过用户闭包的消息不重放（Task4）。
3. 连续latest-wins替换但旧work不响应取消：旧运行任务仍计费，不能无限申请worker/结果槽（Task1/3/4）。
4. 暂时换绑host session与最终窗口关闭：前者保留Runtime，后者关门取消；C detach不执行析构性业务清理（Task4/5/6）。
5. 已保存的MountContext、Scope和Handle在初始化失败、owner重建或跨Runtime时再次使用：拒绝无效使用，不命中新组件（Task2/3/4）。

## 文件与接口边界

| 文件 | 单一职责 |
| --- | --- |
| 新`src/leaf/task_contracts.nim` | 无core/renderer依赖的公共任务类型、owner戳和内部过渡记录 |
| 新`src/leaf/task_worker.nim` | 固定worker、独立载荷、取消信号、预留结果槽与收尾 |
| 新`src/leaf/task_service.nim` | UI线程owner登记、任务意图覆盖层、完成交付和预算 |
| 新`src/leaf/component_lifecycle.nim`、`component_tasks.nim` | MountContext公共API及参数检查；只导出规格中的业务入口 |
| `component_description.nim`、`managed_runtime.nim` | 初始化登记、accepted实例转换、路由/列表/销毁生命周期 |
| `core.nim`、`components.nim` | RuntimeDriver安全点、关闭门禁、任务专用候选及汇总导出 |
| `gpui_api/bridge/session/desktop.nim`，Rust`abi_v2/bridge/bridge_v2/desktop/host_view.rs`，C/Nim/测试布局定义 | 能力协商、UI泵与最后清理；不承担业务调度策略 |
| Win32`host.nim`及`tests/windows/test_component_tasks.nim` | 原生消息唤醒和普通Nim tick；与close重试分离 |
| 新任务测试、示例、SDK/native回归及文档 | 实际业务行为和可复现交付证据 |

依赖方向：`core → task_contracts`；`task_service → core + component_state + task_worker + task_contracts`；`component_description → component_state + task_service`；公共组件模块和`managed_runtime`使用这些底层模块。`task_service`不得导入`component_description/managed_runtime`，避免循环依赖；内部helper在aggregate导出中排除。

各任务保持同一worktree。Task1→2→3→4→5→6→7依次集成；Task5和6虽有独立平台文件，但共享宿主关闭边界，首版顺序执行。每项先RED、再GREEN、再提交，只记录真实命令/退出码；不为搬文件或纯文档另造测试。

## Task 1：线程载荷、取消与有界worker

**Files:** 新`src/leaf/task_contracts.nim`、`task_worker.nim`；新`tests/nim/test_task_worker.nim`、`tests/fixtures/task_work/captured_closure.nim`；按需要修改`scripts/test.nim`，明确新任务套件使用`--threads:on`。

**Interfaces:** `task_contracts`定义规格中的TaskRetention/TaskWork/WorkerContext/TaskFailure/TaskHandle/TaskScope/LifecycleContext/TaskPumpReport及回调类型；opaque scope通过内部TaskDomain基类关联服务，公共字段保持私有。worker提供`newTaskWorkerPool(workerCount=2):TaskWorkerPool`、`reserveWork(pool,id:uint64,input:string,work:TaskWork,maxResultBytes:int):WorkerTicket`、`submitReserved(pool,ticket):bool`、`peekCompletion(pool):Option[WorkerCompletion]`、`ackCompletion(pool,ticket)`、`requestCancel(ticket) {.raises:[].}`、`retirePool(pool) {.raises:[].}`、`joinPool(pool)`；WorkerCompletion含`id:uint64/value:string/failure:Option[TaskFailure]`，UI闭包不进入此类型。

- [x] **Step 1: 写线程所有权和容量RED测试。** fixture使用显式Channel/原子栅栏控制进入与释放，5秒超时只作为失败围栏，不以sleep猜测完成。写`independent payload survives UI mutation`、`queued cancel never invokes work`、`running cancel preserves ticket until acknowledgement`、`reserved result overflow reports resultTooLarge`、`captured closure cannot be TaskWork`；线程启动次数和执行次数由worker独立上报。

```nim
check completion.value == "原始输入"
check completion.id == requestedId
check queuedWorkCalls == 0
check runningTicketStillReserved
check overflow.kind == TaskFailureKind.resultTooLarge
```

- [x] **Step 2: 验证RED。** `/tmp/nim-2.2.6/bin/nim c -r --threads:on --out:target/nim/test_task_worker tests/nim/test_task_worker.nim`因缺失模块/API失败；保存日志。负fixture在接口存在后应因closure/gcsafe类型不匹配编译失败，不能把任何其他编译错误算作通过。
- [x] **Step 3: 实现worker接口。** 验证Nim2.2.6/ORC通道的实际move/copy规则；共享控制块只含明确同步的取消和存活元数据，不共享GC ref。reserve先扣完整输入/结果额度，submit失败保持已接受pending请求；关闭不在worker仍使用内存时free。`--threads:off`保留旧组件导入/生命周期功能，实际启动后台任务明确报错，不偷偷在UI同步执行。
- [x] **Step 4: 验证GREEN。** 重跑Step2；分别测1条worker测试配置和默认2条worker，64个未收尾任务、1MiB边界、8MiB合计、最大结果和4KiB报错截断；重复500轮排队/取消/ack后框架计费回基线。取消的运行任务仍占额度、销毁后收尾不悬空，负fixture失败原因符合预期。
- [x] **Step 5: 提交。** `feat: add bounded component task workers`；仅stage本项文件，保存线程/载荷证据，不声称已接入Runtime。

## Task 2：生命周期登记与已接受转换

**Files:** 新`src/leaf/task_service.nim`、`component_lifecycle.nim`；修改`component_description.nim`、`managed_runtime.nim`、`core.nim`、`components.nim`；新`tests/nim/test_component_lifecycle.nim`，扩展`test_component_lists.nim`、`test_component_routing.nim`。

**Interfaces:** `newTaskService(runtime:Runtime,states:StateStore):TaskService`；`newOwnerRegistration(service,owner:uint64):OwnerRegistration`、`sealOwnerRegistration(registration)`；`newMountContext(store,owner,registration=nil)`保持旧调用兼容。OwnerTransition含stamp、kind、depth、最终active事实及确定遍历序号。`prepareTasks(service,revision:uint64,transitions:seq[OwnerTransition],registrations:seq[OwnerRegistration]):TaskAttempt`、`publishTasks(service,attempt) {.raises:[].}`、`rejectTasks(service,attempt) {.raises:[].}`。公共onMount/onActivate/onDeactivate/onDispose及LifecycleContext.acceptedRevision按规格签名实现。core新增Driver默认方法`pumpDeferred(driver):TaskPumpReport`和公共`pumpTasks(runtime):TaskPumpReport`；ManagedDriver覆盖转交`pumpTaskService(service):TaskPumpReport`，本项先交付生命周期事件，Task4扩展完成消息。

- [x] **Step 1: 写生命周期RED测试。** 初次mount、A→B→A、disposeOnLeave、router卸载和列表暖行淘汰；独立日志记录kind/owner/revision，不由实现返回的事件列表推导预期。保存旧MountContext，在另一个owner初始化时尝试登记；覆盖重复登记、候选失败、同候选创建后删除及回调确定顺序。

```nim
check events == @["mount:parent", "mount:child"]
check returnEvents == @["deactivate:child", "deactivate:parent",
  "activate:parent", "activate:child"]
check rejectedCandidateEvents.len == 0
check disposedState.set(1) == StateWriteResult.disposed
expect UiError: savedClosedMount.onMount(callback)
```

- [x] **Step 2: 验证RED。** `nim c -r --threads:on --out:target/nim/test_component_lifecycle tests/nim/test_component_lifecycle.nim`（本计划后续`nim`均指Task1的已确认编译器）；断言因尚未提供生命周期API/行为失败。
- [x] **Step 3: 实现登记和转换。** 开放帧校验与owned bytes收费共用现有初始化合同；实例保留OwnerRegistration，accepted→candidate差异生成事件，仅受影响子树遍历。登记每hook及scope各计128字节owned bytes；待交付事件每条计128字节并与现有树共享16MiB运行时描述预算，且最多`4*MaxNodes=40000`条，超限候选明确拒绝。事件容量和退出回调引用在host apply前准备，publish不分配业务事件/调用用户代码；不依赖Table迭代。泵入场时要求inUpdate=false；随后回调在uiTask保护体执行，该体自身的inUpdate=true只防重入，不能误判为render/commit而拒绝合法任务API。TaskAttempt暂只承载owner/事件，Task3再加入任务意图。
- [x] **Step 4: 验证GREEN。** 重跑本项测试和`test_component_routing/test_component_lists/test_component_faults`，证明隐藏页/暖行不render、无候选回调泄漏、dispose后State失效；scope持续拒绝导致事件积压时预算仍有界，超限导航拒绝并保留旧页。测试通过普通Nim安全点驱动回调，不把publish方法伪装为安全点。
- [x] **Step 5: 提交。** `feat: publish component lifecycle transitions after acceptance`。

## Task 3：任务意图、latest-wins与共同接受

**Files:** 新`src/leaf/component_tasks.nim`；修改`task_service.nim`、`component_description.nim`、`managed_runtime.nim`、`core.nim`、`components.nim`；新`tests/nim/test_component_tasks.nim`、`test_component_task_faults.nim`。

**Interfaces:** 公共`taskScope(ctx:MountContext,retention=cancelOnDeactivate):TaskScope`、`taskScope(ctx:LifecycleContext):TaskScope`、规格中的`startTask`和`cancel`；内部`hasTaskIntents(service):bool`、`requireTaskAccess(service,scope)`。requireTaskAccess结合执行Runtime身份、TaskService持有StateStore的requireIdle、owner/activity校验，不能只检查core.inUpdate。Task2的prepare/publish/reject接纳封存意图；`ManagedDriver.stage`对task-only工作返回元数据候选，不因State队列为空退出。 本项先增加内部任务泵能力门禁（headless默认允许）及显式pool保活/退役/普通安全点最终回收接缝；Task5/6绑定真实宿主能力，Task4接公开closeRuntime。task-only保留已接受且未变的Snapshot缓存供validator使用，不重复export；真实树更新仍使缓存失效。

- [x] **Step 1: 写意图RED测试。** 在事件内同时更新State、导航和start/cancel；用真实HostConsumer.prepare/apply故障拒绝，worker执行日志独立核对。覆盖同key多次启动、启动后取消、接受后scope收尾报错、scope入场拒绝、owner在同候选移除和无State变化的task-only提交。保存失败初始化scope在新owner中复用，及跨Runtime/线程和render/updater启动，均须明确拒绝。

```nim
check rejectedWorkerStarts == 0
check oldRequestStillCurrent
check routeAfterRejection == routeBefore
check taskOnlyRevision == previousRevision + 1
check taskOnlyStats.componentRenders == previousStats.componentRenders
check taskOnlyStats.snapshotExports == previousStats.snapshotExports
check acceptedFinalKeyWorkCalls == 1
```

- [x] **Step 2: 验证RED。** `nim c -r --threads:on --out:target/nim/test_component_task_faults tests/nim/test_component_task_faults.nim`；先证实缺失意图或无法共同回滚的断言失败。
- [x] **Step 3: 实现意图覆盖层。** 单调id与owner/key请求代分开；候选准备检查64任务/input/result预算、挂载支持能力及启动前worker就绪，接受时才使被替换任务失效。取消仍运行的任务不释放其预留额度；work只由后续安全点submit。task-only保留validator/preparer/host gate且只加一次revision，不改变State无变化本身的旧行为。
- [x] **Step 4: 验证GREEN。** 运行本项两套件、Task1/2及已有组件fault/state/performance回归；将build/snapshot/预算/validator/prepare/apply/scope入场/收尾逐项执行并记录。输入恰好1MiB成功，超一字节拒绝；key256字节UTF-8成功，257及非法UTF-8拒绝；maxResultBytes不在1..1048576拒绝。 独立Snapshot导出可恢复异常目前没有受支持且已prepare候选的可控入口，不新增测试专用生产故障钩子；该注入记NotRun并说明原因，真实导出计数/缓存和validator拒绝单独记录，不能冒充导出异常。
- [x] **Step 5: 提交。** `feat: commit component task intents with state and routing`。

## Task 4：结果交付、保留策略与Runtime关闭

**Files:** 修改`task_service.nim`、`task_worker.nim`、`core.nim`、`managed_runtime.nim`、`component_tasks.nim`；新`tests/nim/test_component_task_delivery.nim`、`test_component_task_retention.nim`、`test_component_task_shutdown.nim`。

**Interfaces:** 复用Task2的pumpDeferred/pumpTasks/pumpTaskService；core新增Driver默认方法`retireDeferred(driver) {.raises:[].}`、`closeDeferred(driver)`及公共`closeRuntime(runtime)`；ManagedDriver覆盖并转交TaskService。内部`retireTaskService(service) {.raises:[].}`、`closeTaskService(service)`；core增加内部`runRuntimeCleanup(runtime,body:proc() {.closure.})`，在关闭态也能进入executionScope，但不触发State提交或开放任务启动。调用路径保留core→contracts的单向依赖。TaskPumpReport字段按规格；退休只关门/原子取消，最终关闭才执行用户清理/join。 合法UI业务体内公共closeRuntime立即关门、使State失效且不接受此前排队意图，返回后由普通close/finally执行未claim清理并在scope退出、执行身份为0时最终回收；受保护阶段拒绝，onDispose递归close幂等返回。

- [x] **Step 1: 写交付/退出RED测试。** 两个可控worker令旧请求后完成；A离开返回分别测默认取消与keepWhileRetained；换key/类型、router卸载、行复用、旧Runtime重开；完成已到达但scope拒绝入场后再允许；onResult/onDispose报错、pump重入、host临时换绑与最终关闭、取消不合作work和挂载清理顺序。最终close时scope拒绝入场必须立即关门/使State失效，但保存未执行的清理；下次显式close在scope可用时只执行尚未claim的清理一次。

```nim
check deliveredValues == @["new"]
check hiddenRenderDelta == 0
check afterRefusedEntry.delivered == 0
check afterAllowedEntry.delivered == 1
check callbackCallsAfterFailureAndRepump == 1
check disposeCallsAfterTwoCloses == 1
check callbacksAfterRuntimeRetirement == 0
```

- [x] **Step 2: 验证RED。** 分别运行三项`nim c -r --threads:on --out:target/nim/<对应文件名> tests/nim/<对应文件名>.nim`，保存未实现泵/代校验/关闭的失败。
- [x] **Step 3: 实现安全交付。** core拒绝busy/hook安装/候选/跨线程泵，服务逐条进入uiTask；scope body真正入场才claim消息，scope入场拒绝保留并结束该轮。已调用回调的失败不重试，清理错误隔离；先处理生命周期退出和owner失效再交付普通结果。取消/替换/关闭/交付失败均在真实收尾后释放额度，关闭先使全部State disposed，随后按child-first清理。
- [x] **Step 4: 验证GREEN。** 跑三套件和Task1–3；用可注入单调时钟测试64项/4ms边界，不要求回调被抢占。无消息泵全部结构计数和revision不变，持续500轮替换/取消/销毁后记录存活槽/字节回基线；非合作work测试先证明关门返回，再释放fixture栅栏证明join和共享控制块释放。
- [x] **Step 5: 提交。** `feat: deliver component task results and close task owners safely`。

## Task 5：GPUI ABI1/ABI2任务泵与兼容

**Files:** 修改`include/leaf_gpui_v2.h`、`src/leaf/gpui_ffi_v2.nim`、`gpui_api.nim`、`gpui_bridge.nim`、`gpui_session.nim`、`desktop.nim`；为只读pending接缝最小修改`core.nim`、`managed_runtime.nim`；Rust`model.rs`（仅默认bool响应字段）、`abi_v2.rs`、`bridge.rs`、`bridge_v2.rs`、`desktop.rs`、`host_view.rs`、`host_ui_tests.rs`；扩展`tests/nim/test_gpui_v2_requests.nim`、`test_gpui_v2_session.nim`、新`test_task_pump_compatibility.nim`；按实际常量断言需求更新`tests/ffi/gpui_v2_layout.{c,nim,rs}`。

**Interfaces:** 使用规格3个typed常量及ABI1导出；为typed reply定义不占既有status位的`LEAF_REPLY_TASKS_PENDING=4`，ABI1新响应字段`tasks_pending`为严格布尔。Rust ABI1新增`TaskTickReply { pending:bool, response:Option<Response> }`及`Bridge::tasks() -> Result<TaskTickReply,String>`，空tick无需Snapshot。core复用内部`configureTaskPumpInternal(runtime,supported:bool)`并新增只读pending driver/facade供宿主使用，managed_runtime转交已有service查询；Rust Response加默认false的严格bool tasks_pending字段，保持Bridge Copy/旧request Snapshot合同；仅task-capable托管Runtime协商泵能力，具体是否排队/计时由pending决定，不把初始页是否已经有work当能力。

- [ ] **Step 1: 写兼容RED测试。** 新库+旧宿主禁止新op；新功能+旧库在调用work前明确失败；ready失败或能力非true不激活ABI1任务op；typed config的frame位1与pump位2可以组合，根view只建一个计时器；status/ready/rendering不消费任务。初始无任务、后来事件挂载组件必须开始收到完成消息，detach不调用业务清理且旧会话不能继续交付。

```nim
check requestsToOldHost.filterIt(it == "tasks").len == 0
check workerStartsWithUnsupportedLibrary == 0
check dynamicComponentResult == "ready"
check lifecycleCallsInsideDetach == 0
check statusRevision == revisionBeforeStatus
```

- [ ] **Step 2: 验证RED。** 跑新compatibility Nim套件和定向Rust任务泵测试，断言现有库不具备新能力/tick。保留新旧组合fixture，不能只检查数值常量相同。
- [ ] **Step 3: 实现双向协商。** ABI2 config允许任务泵后，ready成功或事件reply pending时根view启动16msUI tick；无待处理事件/worker后停止，后续事件可重新唤醒。ABI1 ready能力只授权新op，每个正常响应的pending决定同样调度；旧Rust忽略新增响应字段。新ABI1 tasks空响应只有pending/error元数据；Rust新tasks路径只在响应含实际更新时解析Snapshot，既有Bridge.request的Snapshot校验保持原义。Nim桥在普通tasks请求调用pumpTasks，Rust调用时不持HostStore可变借用。最终desktop finally执行closeRuntime，session重绑不销毁Runtime；旧库动态挂载功能在候选prepare拒绝。
- [ ] **Step 4: 验证GREEN。** 跑相关Nim桥接套件、`nim c -r scripts/check_gpui_v2_abi.nim`、`cargo test --workspace --locked`、`cargo fmt --all --check`、`cargo clippy --workspace --all-targets --locked -- -D warnings`。验证ABI1任务实际更新允许Snapshot，但其status/ready既有合同不变；ABI2空tick无UI树和额外Snapshot。
- [ ] **Step 5: 提交。** `feat: negotiate and drive GPUI component task pumps`。

## Task 6：Win32安全tick与关闭

**Files:** 修改`src/leaf/backends/win32/host.nim`、必要的`host_bridge.nim/api.nim`；新`tests/windows/test_component_tasks.nim`，扩展`tests/windows/test_win32_host.nim`；仅若公共native session需声明泵能力时修改`src/leaf/backend_session.nim`。

**Interfaces:** Win32宿主调用Task4的pumpTasks/closeRuntime和Task5的configureTaskPump/taskPumpPending；新增内部`armTaskTick(host)`、`disarmTaskTick(host)`，使用与close重试不同的timer/message编号；WndProc只设待处理标记。继承现有host拥有线程与session lease检查，不自建后台宿主服务。

- [ ] **Step 1: 写Windows RED测试。** 用户未点击时worker结果可更新界面；WndProc/busy/hook期间不执行回调，普通tick恢复后交付；初始无任务后动态挂载；task timer与close重试同时发生时均不丢失；临时换绑保留任务，final close失效旧结果。

```nim
check callbacksInsideWndProc == 0
check tasksDeliveredAfterSafeTick == 1
check closeTimerId != taskTimerId
check finalCloseCompleted
check deliveredAfterFinalClose == 0
```

- [ ] **Step 2: 验证RED。** 在真实Windows环境运行`nim c -r scripts/test_win32.nim`，新测试必须对缺失行为失败；没有Windows时只完成可用的源码/交叉编译检查并记NotRun，不能宣称已取得Windows RED/GREEN。
- [ ] **Step 3: 实现host集成。** 待任务标记在原有普通Nim安全tick消费；close/busy优先级、消息编号、取消timer和资源lease关闭按既有host协议处理。宿主关闭路径不join worker；最终Runtime清理按Task4普通边界处理。
- [ ] **Step 4: 验证GREEN。** Windows重跑官方runner及已有控件/输入/测量回归；记录实际工具链、系统和提交身份。当前Linux只能跑平台无关任务/host_state测试及可用交叉编译，不把它们记为Windows运行通过。
- [ ] **Step 5: 提交。** `feat: pump component tasks at Win32 safe boundaries`；平台证据不足时任务代码与验收状态分开记录。

## Task 7：示例、SDK搬迁、性能与整体验收

**Files:** 新`examples/component_tasks.nim`、`tests/nim/component_tasks_native_app.nim`、`test_component_task_performance.nim`；扩展`tests/nim/gpui_native.nim`、`tests/release/test_sdk.nim`或`tests/nim/test_sdk.nim`中真正运行SDK的现有路径、`scripts/smoke_sdk.nim`；修改`docs/nim-api.md`、`development.md`、`verification.md`；新`docs/superpowers/reviews/2026-10-17-component-async-lifecycle-verification.md`。

**Interfaces:** 示例导出`tasksApplication(title="Leaf component tasks"):Application`；稳定key为load/retry/status/go-other/go-retained/go-disposed。native harness增加`LEAF_TEST_TASKS=1`分支，继续使用`LEAF_TEST_APP`，不改变pages/counter/list旧分支。CLI普通headless语义不改；SDK任务fixture以自己显式pumpTasks驱动验收。

- [ ] **Step 1: 写用户行为RED测试。** 在100/1000/5000静态兄弟下由真实worker结果更新单个组件；真实窗口加载无需后续点击、错误后重试、离开取消、隐藏继续与返回、关闭均有独立caption/事件断言。新增SDK fixture断言实际result，不只验证模块存在或编译成功。

```nim
check after.componentRenders - before.componentRenders == 1
check after.snapshotExports == before.snapshotExports
check unrelatedHostHandlesAfter == unrelatedHostHandlesBefore
check sdkCompletionCaption == "后台完成"
```

- [ ] **Step 2: 验证RED。** 跑`test_component_task_performance.nim`及SDK/native新增路径；按缺失fixture/行为记录真实失败，平台依赖缺失记NotRun，不能当产品RED。
- [ ] **Step 3: 实现示例与发布接入。** 示例包含loading/error/retry、默认取消与显式保留两种页面；work中自有数据库连接示例放入文档，连接finally释放。SDK沿现有整树复制规则包含新增模块和头文件；移除环境覆盖后实际搬迁编译运行。记录取消不能撤销外部副作用、work超时及窗口/进程退出时间差异。
- [ ] **Step 4: 执行最终验收。** 先跑定向新套件，再跑下列官方命令；最终源码改变后重跑受影响检查，未变的Rust等只在源码/锁文件/工具链身份一致时复用证据。

```sh
NIM=/tmp/nim-2.2.6/bin/nim /tmp/nim-2.2.6/bin/nim c -r --out:target/nim/test_runner scripts/test.nim
NIM=/tmp/nim-2.2.6/bin/nim /tmp/nim-2.2.6/bin/nim c -r --out:target/nim/test_runner scripts/test.nim --release-only
/tmp/nim-2.2.6/bin/nim c -r scripts/check_gpui_v2_abi.nim
cargo test --workspace --locked
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
```

Native依次运行ABI=1/2、CACHE=0/1共四组：`NIM=/tmp/nim-2.2.6/bin/nim LEAF_TEST_TASKS=1 LEAF_TEST_APP=tests/nim/component_tasks_native_app.nim LEAF_GPUI_ABI=<1或2> LEAF_GPUI_CACHE=<0或1> LEAF_GPUI_LIBRARY=<本轮native-test-support库绝对路径> /tmp/nim-2.2.6/bin/nim c -r --out:target/nim/native_test scripts/native_test.nim`。执行时替换尖括号参数并记录完整argv，不复制示意参数直接运行。

SDK使用新CLI、production-feature桥接库及`package_sdk.nim`的真实`--nim-root/--cli/--bridge/--output/--target/--channel/--version/--commit`参数打包，在仓库外中文/空格/`$`目录解包，清除NIM/LEAF_LIBRARY/LEAF_GPUI_ROOT/LEAF_GPUI_LIBRARY/LEAF_SDK覆盖；运行doctor、普通应用build和任务fixture。保存源码/库SHA、编译器/profile、命令/退出码和行为断言。纯CPU计数、真实GPUI帧和软件渲染结果分别报告；证据摘要提交文档，原始产物保留功能workspace的target/verification/component-async-lifecycle，不提交二进制。

- [ ] **Step 5: 提交并交架构验收。** `test: verify component task lifecycle across hosts and SDK`。验收逐条映射规格第10节，包含全部任务RED/GREEN、未运行平台和已知限制；本项结束不自动合并、推送或归档。

## 执行角色、记录与交付

本会话承担方案和协调，无需另建同职责方案Agent。当前功能workspace没有已有Agent，后续执行优先为每个职责创建一个可复用会话，修复继续发送给原实现会话；不为每轮改动创建新workspace。

2026-10-17读取的实际profiles如下，启动前再读取以防配置变化；未配置值均省略，不猜mode或features：

| 用途 | Profile | provider/model | thinking | mode/features |
| --- | --- | --- | --- | --- |
| Task1–7编码、自测、普通修复 | 日常工作 | pi / opencode-go/deepseek-v4.1-flash-free | high | 均未配置；Pi当前无mode/features选项 |
| 每项接口/证据检查及最终验收 | 方案设计，架构思考 | pi / openai-codex/gpt-6.1-sol | high | 均未配置 |
| 常规处理无法解决的复杂问题 | 高消耗工作 | codex / gpt-6.1-sol | high | auto-review；features未配置 |
| 前端绘制/交互（本计划无独立界面设计任务） | opencode deepseek | pi / opencode-go/deepseek-v4.1-flash-free | high | 均未配置；不沿用旧Gemini名称猜模型 |

建议执行方式为依次委派编码、独立架构验收；协调Agent负责集成和进度，已验收接口固定后才推进后续任务。若用户选择本会话直接实现，改用executing-plans并保留最终独立验收。当前仅编写计划，尚未创建编码/验收Agent。

原协调Agent=`22171a3c-32d8-4ff6-baab-8ed6a7a22963`，原workspace=`wks_fd0d6c1dbee5f84c`；执行workspace=`wks_43c47436537996f7`，路径`/home/jimxl/.paseo/worktrees/1c1rvoii/component-async-lifecycle`，分支`feat/component-async-lifecycle`，产品基线`53368cf2a554c52af092d129f0aeb2b592c8d78f`，设计提交`247cda9`。

进入编码前由用户审阅本计划并确认执行方式。实现后在本会话报告实际完成和测试证据；合并/推送仍待授权，验证主分支与GitHub远端包含本批成果、worktree无待保留文件/运行会话后才可安全归档自动执行空间，原会话空间保留。
