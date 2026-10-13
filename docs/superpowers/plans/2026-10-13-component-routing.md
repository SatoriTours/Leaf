# Leaf 托管组件路由实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 用户已于2026-10-14审阅认可，按既有Paseo分工连续执行。

**Goal:** 多页面应用使用托管 State 导航，框架自动维护页面保留与释放，提交失败时地址、组件和宿主保持一致。

**Architecture:** Router 持有不可变地址配置和所属组件的 State[int]；专用 pageOutlet 描述管理当前页面及保留页。未显示页保留 Nim 组件模型和 State，移除宿主与活动事件，恢复时分配新宿主句柄。Rust/C ABI 仍只消费当前页面的普通类型化增量。

**Tech Stack:** Nim 2.2.6 / ORC；既有 Rust workspace 和锁定 GPUI 依赖；无新增依赖，不升级 Cargo.lock。

**Spec:** [已确认规格](../specs/2026-10-13-component-routing-design.md)。用户已明确要求框架自动维护生命周期。

## Global Constraints

- 基线产品提交 `f427bad02ae799a6169008975d505ee00e3d28be`；已存在规格提交 `cdbab282a4f7b1b61bd629188dc4e793762d3604`。
- 复用 `/home/jimxl/.paseo/worktrees/1c1rvoii/leaf-react-runtime`、`feat/leaf-react-runtime`、workspace `wks_e1f5c0b7b800feb2`；原会话持续协调，不新增工作区。
- 默认 PageRetention.retainState；可选 disposeOnLeave。未显示页不占宿主或活动事件索引，恢复不承诺光标、选区、焦点、滚动位置或 IME 组合。
- 活动与保留实例、描述、配置及列表暖行全部计入 MaxNodes=10000、组件实例上限10000、MaxDepth=64、MaxStringBytes=1048576、MaxTreeBytes=16777216；列表 MaxListItems=100000 不变。
- 预算不足拒绝目标导航并保留旧页面，不暗中淘汰用户 State；业务不手动维护页面缓存。
- 旧 Router/PageGroup 和 Application API 不改义；不改 NodeKind/C ABI/ABI1符号，不在 Rust 保存路由或组件 State。
- DescriptionKind.pageOutlet 是新增的可见枚举值；全部描述遍历显式处理它，文档说明低层穷尽 case 的源码迁移。
- 地址/页面/State/事件/宿主/revision 一起接受。publish 不分配、不执行用户代码或平台调用；候选只在覆盖层修改。
- 不加入异步任务 API、URL参数、浏览器历史、嵌套路由、动画、通用KeepAlive、模板自动迁移或Win32布局重构。
- Windows/macOS真实窗口、系统IME、跨屏DPI没有实际证据时记NotRun，SDK安装成功不代替它们。

## Review Focus

1. 业务修改原始 routes/pages/views 或 routes() 返回值后，已创建 router 的配置不变；任务1。
2. 一个 router 被两个出口使用、换出口key、父组件移除 router，不能留重叠事件或孤立保留页；任务2、3、4。
3. 隐藏页在同一次导航前后排队更新，保留 State 可接受但不 render，销毁策略不使句柄复活；任务2、4。
4. 目标页 build/列表恢复/预算失败及scope收尾失败，按接受前/后分别处理，不能提前改地址或重放事件；任务4。
5. 保留页中嵌套router/虚拟列表，整体卸载释放全部暖实例；包含中文的配置按UTF-8字节计预算；任务1、4。

## 文件责任与执行方式

| 文件 | 责任 |
| --- | --- |
| `src/leaf/component_routing.nim`（新） | 配置、controller State、公开导航及出口构造 |
| `src/leaf/component_description.nim` | PageRetention/pageOutlet描述、上下文owner检查 |
| `src/leaf/component_state.nim` | 内部State有效性/owner查询，写入语义不变 |
| `src/leaf/managed_runtime.nim` | 出口协调、保留映射、递归生命周期、索引与预算 |
| `src/leaf/components.nim` | 新公共API导出，不导入桌面模块 |
| `tests/nim/test_component_routing_*.nim`（新） | controller、出口、集成、故障和预算测试 |
| `examples/component_pages.nim`（新） | 两页计数/草稿、同页多view、可选销毁示例 |
| `tests/nim/gpui_native.nim`、新页面fixture | 复用真实窗口驱动验证导航 |
| API/架构/验收文档 | 用法、自动维护、兼容及实际平台证据 |

主会话承担方案/集成/验收；常规编码复用「日常工作」会话；独立审查复用「方案设计，架构思考」审查会话。依赖任务顺序执行，禁止同时修改共享运行时文件。普通问题交回编码会话；重复无法解决才升级高消耗配置。以上以派发前重新读取的真实 profiles 为准。

所有任务先写失败测试再实现，提交限功能分支；每次记录起止SHA、测试命令/退出码和审查结论。不得把后续任务尚未实现的接口作为当前任务必须通过的测试。

## Task 1：不可变配置与托管导航 State

**Files:** Create `src/leaf/component_routing.nim`, `tests/nim/test_component_routing_state.nim`; Modify `component_description.nim`, `component_state.nim`, `components.nim`（仅排除新内部查询导出）。

**Interfaces:**

- 在component_description定义 `PageRetention {.pure.} = enum retainState, disposeOnLeave`；ComponentPageDefinition/ComponentRouter在component_routing定义，字段合同遵照规格。
- 实现 `newComponentRouter(ctx:MountContext,routes:seq[Route],pages:seq[ComponentPageDefinition],initial=""):ComponentRouter`、`routes(router):seq[Route]`、`navigate(router,target:string):StateWriteResult`、`currentRoute(router):Route`、`currentRoute(ctx:ComponentContext,router):Route`；此任务不添加renderPage占位函数。
- State内部查询 `stateAlive[T](state:State[T]):bool`、`stateOwnerMatches[T](state:State[T],store:StateStore,owner:uint64):bool`；上下文提供 `ownsState[T](ctx:ComponentContext,state:State[T]):bool`。仅用于内部校验，不导出到components公共汇总。
- controller保存不可变配置、State[int]和线程本地单调非零router token；溢出明确拒绝。route/page/view声明条目总数不超过MaxNodes；配置按固定元数据与UTF-8字符串保守计量，包含definitions/names/paths自有键并在累加时检查上限；Task3将该值计入所属组件预算。配置无单独、无界的缓存账本。

- [x] **1.1 失败测试**：直接用StateStore/MountContext夹具验证配置与队列，不依赖尚未实现的出口。`configuration_is_validated_before_mount` 覆盖空路由、重复name/path/page/view、无build、未知page/view/initial、非绝对path、名称以/开头、非法UTF-8、单字段超过MaxStringBytes、条目超过MaxNodes、总配置超过MaxTreeBytes；factory调用数保持0。
- [x] **1.2 失败测试**：`configuration_is_detached_from_callers` 修改原始配置和返回seq后，`check router.currentRoute.path == "/"`；`navigation_joins_state_attempt` 中navigate到B后accepted仍A、candidate是B，reject后accepted仍A；两次navigate最终接受最后地址；同地址不产生dirty owner；disposeOwner后 `check router.navigate("missing") == StateWriteResult.disposed`。渲染期写入与跨Runtime/owner读取拒绝。
- [x] **1.3 RED**：`nim c -r --path:src --out:target/nim/test_component_routing_state tests/nim/test_component_routing_state.nim`，确认新接口缺失/断言失败而非工具链故障。
- [x] **1.4 实现**：配置深复制与索引、State[int]导航、owner查询和ctx候选读取。未知地址不排队，disposed优先返回；State引用snapshot政策不改变。
- [x] **1.5 GREEN**：重复1.3并执行 `tests/nim/test_component_state.nim`、`tests/nim/test_components.nim`、`tests/nim/test_routing.nim`，各用 `nim c -r --path:src --out:target/nim/<name> <file>`，全部退出0。
- [x] **1.6 提交与窄审查**：`feat: add transactional component route state`；审查配置隔离、队列和owner，不提前验收出口。

## Task 2：页面出口与自动保留生命周期

**Files:** Modify `component_description.nim`, `managed_runtime.nim`, `components.nim`（仅排除新内部出口导出）; Create `tests/nim/test_component_routing_outlet.nim`。

**Interfaces:**

- 新增DescriptionKind.pageOutlet；`PageOutletSpec`含 `routerId:uint64`、`page,view:string`、`retention:PageRetention`、`configurationBytes:int`、`build:proc():UiDescription {.closure.}`。
- 描述内部入口 `pageOutlet(spec:PageOutletSpec,key:string):UiDescription`、`outletSpec(description:UiDescription):PageOutletSpec`。非出口调用outletSpec拒绝；这些低层入口不从components汇总导出。
- 出口实例维护按page key定位的保留记录与当前子实例；候选变更使用覆盖层，重复routerId出口在接受前拒绝。保留映射容量在接受前准备。
- 正常返回已访问页不复制整套已保留组件/State图；首次登记可能需要扩容轻量页面索引，需记录成本，不承诺所有导航O(1)。

- [x] **2.1 失败测试**：低层出口夹具使用现有defineComponent和State选择A/B；`retention_remounts_hosts_without_reinitializing_state` 断言A计数为3后离开再返回仍3、初始化次数不增、宿主句柄更换、旧事件拒绝；`dispose_on_leave_reinitializes` 断言旧State.set返回disposed、返回初值。
- [x] **2.2 失败测试**：`inactive_state_accepts_without_rendering` 离开A后写A State并flush，值接受且A render计数不变；恢复显示新值。`outlet_walkers_export_only_active_page` 验证Snapshot/find/祖先根变更/hostRoot/retainedDescription；两页相同局部key不会混淆。
- [x] **2.3 RED**：`nim c -r --path:src --out:target/nim/test_component_routing_outlet tests/nim/test_component_routing_outlet.nim`。
- [x] **2.4 实现**：补齐所有host/component二分遍历，建立专用出口分支；复用停用底层逻辑，列表暖行128策略不改。保留页宿主、边界和活动索引撤销；恢复重建宿主。卸载遍历当前children及保留页/暖行去重全集。
- [x] **2.5 GREEN**：重复2.3；跑test_components、test_component_view、test_component_lists、test_component_compat、test_component_commit，各退出0。包括逻辑出口根嵌套、当前页根kind更换及同页view换组件type/key。
- [x] **2.6 提交与窄审查**：`feat: retain inactive component pages without host controls`；核对生命周期、活动索引和所有第三类描述分支。

## Task 3：公共出口 API 与完整组件导航

**Files:** Modify `component_routing.nim`, `components.nim`, `component_state.nim`, `component_description.nim`, `managed_runtime.nim`; Create `tests/nim/test_component_routing.nim`。

**Interfaces:** `renderPage(ctx:ComponentContext,router:ComponentRouter,key="page-outlet"):UiDescription`；消费Task1候选route/owner与Task2出口，不在构造时执行页面build。内部增加`requireInitializing(store:StateStore)`、`accountOwnedDescriptionBytes(ctx:MountContext,bytes:int)`、`ownedDescriptionBytes(ctx:MountContext):int`；只供组件初始化与运行时计量，不从components导出。

- [ ] **3.1 失败测试**：真实Runtime夹具由专门Router组件持有controller，页面返回计数/文本；`public_navigation_preserves_page_state`覆盖name/path导航、同page两view、两次导航合并、同地址不刷新。`owner_and_single_outlet_are_enforced`覆盖跨Runtime、错误owner、同router两个出口；错误发生后原页面和State不变。
- [ ] **3.2 失败测试**：`router_key_change_and_parent_removal_dispose_all_pages` 更换出口key使旧页实例释放；随后父移除router时当前及保留页State均disposed；同事件先navigate再移除不会复活旧页。
- [ ] **3.3 RED**：`nim c -r --path:src --out:target/nim/test_component_routing tests/nim/test_component_routing.nim`。
- [ ] **3.4 实现**：renderPage校验controller/ctx归属，创建包含候选page/view与惰性build的出口；newComponentRouter在MountContext中登记配置字节，Managed Instance把它计入所属组件bytes并在保留/恢复中维持、销毁时扣除；renderPage的configurationBytes设0以避免重计。补同owner和不同owner已初始化但未显示的多controller总预算、重复render只计一次及销毁释放的测试。components只导出规格公开类型/API，避免加载桌面模块。
- [ ] **3.5 GREEN**：重复3.3；旧test_routing和test_component_compat退出0；加入ABI1的已接受Snapshot仅含当前页对照。
- [ ] **3.6 提交与窄审查**：`feat: expose managed page navigation and outlets`；核对公开行为与既有Router兼容。

## Task 4：拒绝、预算与嵌套页面回归

**Files:** Create `tests/nim/test_component_routing_faults.nim`, `tests/nim/test_component_routing_limits.nim`; Modify `managed_runtime.nim`/`component_routing.nim` only where这些测试发现本功能缺口。

**Interfaces:** 不新增公开API；沿用HostConsumer、StateWriteResult、Runtime acceptedRevision/updateStats及现有fault fixture。

- [ ] **4.1 失败测试**：`navigation_rejection_preserves_all_accepted_state` 注入build、validator、prepare、apply、scope入场失败；对每项断言 `check router.currentRoute.name == "a"`、地址/旧State/宿主revision不变、新候选Statedisposed、旧页面事件仍有效。先写隐藏页State再切页/销毁的组合也覆盖。
- [ ] **4.2 失败测试**：`accepted_scope_error_does_not_replay_navigation` 断言scope收尾失败后route已B、revision推进一次、callback次数为1；恢复失败冻结后不再执行业务事件。`nested_router_and_warm_rows_are_disposed` 建嵌套路由及100000项列表，仅物化50行并产生暖行，卸载外router后所有持有句柄disposed。
- [ ] **4.3 失败测试**：`retained_pages_and_catalog_share_runtime_budgets` 分别触发节点/组件/描述字节/深度上限，中文按UTF-8字节计；候选超限拒绝且旧页面/保留状态仍有效。连续导航/失败/卸载不累积候选链或失效回调。
- [ ] **4.4 RED**：两新suite分别 `nim c -r --path:src --out:target/nim/<name> tests/nim/<name>.nim`，记录真实失败；已经GREEN的约束无需人为改坏实现，只记录回归通过。
- [ ] **4.5 修复与GREEN**：只修对应归属模块；重复4.4并跑全部test_component_routing*、test_component_faults、test_component_lists、test_host_reconcile。任何接受后副作用不倒退revision，不把数据库/普通变量纳入State回滚。
- [ ] **4.6 提交与窄审查**：`test: verify routing rollback retention budgets and disposal`；所有重大问题修复后进入出口验收。

## Task 5：可运行示例、结构性性能与发布兼容

**Files:** Create `examples/component_pages.nim`, `tests/nim/component_pages_native_app.nim`, `tests/nim/test_component_routing_performance.nim`; Modify `tests/nim/gpui_native.nim`, `docs/nim-api.md`, `docs/architecture.md`, `docs/verification.md`; Create `docs/superpowers/reviews/2026-10-13-component-routing-verification.md`。

**Interfaces:** 原生fixture复用LEAF_TEST_APP/ABI/CACHE选择及key定位；新性能suite用现有updateStats/HostConsumer捕获真实batch，不修改测量schema来凑通过。

- [ ] **5.1 失败测试**：`navigation_work_is_independent_of_static_siblings` 设100/1000/5000个无关兄弟，导航后静态组件render次数不增、句柄稳定、snapshotExports不增，捕获ops只涉及进出页/必要祖先关系；来回导航100次校验保留计数。显式Snapshot在计时和计数检查之外。
- [ ] **5.2 RED/GREEN**：运行 `nim c -r --path:src --out:target/nim/test_component_routing_performance tests/nim/test_component_routing_performance.nim`；若结构性计数失败，只优化本次出口路径后重复验证，不新增无依据时间阈值。
- [ ] **5.3 示例与窗口fixture**：两页分别展示计数/中文草稿、同页view及disposeOnLeave；按钮用稳定key。扩展已有harness的页面分支，用key定位执行A编辑→B→A、重置、未知地址错误和关闭；原计数fixture分支继续可用。
- [ ] **5.4 主会话集成验证**：`nim c -r --out:target/nim/test_runner scripts/test.nim`、`cargo test --workspace --locked`、`cargo fmt --all --check`、`cargo clippy --workspace --all-targets --locked -- -D warnings`、`nim c -r --out:target/nim/check_gpui_v2_abi scripts/check_gpui_v2_abi.nim`、git diff-check。上述Nim/ABI检查针对最终代码实际执行；Rust检查执行一次，或在Rust源码/锁文件/工具链身份一致且已有成功证据时复用最近结果，明确记录哪些未重跑及准确来源。
- [ ] **5.5 真实窗口矩阵**：使用单独native-test-support桥接构建和显式LEAF_GPUI_LIBRARY，分别ABI=1/2、CACHE=0/1运行 `LEAF_TEST_APP=tests/nim/component_pages_native_app.nim nim c -r --out:target/nim/native_test scripts/native_test.nim`；配置现有Xvfb/xdotool依赖。发行SDK前恢复默认桥接，测试专用probe不进入包。
- [ ] **5.6 SDK与文档**：跑 `scripts/test.nim --release-only` 并核对包内含component_routing模块；对移动SDK中的页面示例做headless/构建回归。文档讲清自动维护、隐藏State、销毁策略、不可保留控件编辑态、低层枚举case迁移和各平台实际结果；SDK发布只沿用既有授权与流程。
- [ ] **5.7 验收记录与最终审查**：证据保存原目录 `target/verification/component-routing/<run-id>/`，含提交/源和库hash、命令/退出码、结构性计数与未执行项。全分支审查后修复并重复受影响验证，提交 `feat: document and verify managed page routing`。

## 规格覆盖与完成判定

| 规格 | 任务 |
| --- | --- |
| 目标/方案/兼容范围 | 全局约束、1、3、5 |
| 公共API和不可变配置 | 1、3 |
| 出口身份及第三类描述遍历 | 2、3 |
| 自动停用/恢复/销毁/隐藏State | 2、4 |
| 事务/失败/预算/后续生命周期边界 | 4 |
| 示例/性能/ABI/发布与迁移 | 5 |

代码实现、运行时回归、真实窗口、SDK搬迁与真实IME/DPI分别报告。缺真实平台证据不声称全平台验收完成；当前旧计划13.4仍未关闭。不得按技能通用清理语句手工删除Paseo工作区；仅在主分支推送及所有归档检查满足时由原协调会话通过Paseo归档。

## 计划审阅与交付

本计划已获用户认可。Task1及Task2实现和修复已独立审查通过；后续按复用的Paseo角色与相关会话连续实施。范围裁定、命令/退出码与任务进度见本计划独立SDD ledger，常规实现选择不重复询问。
