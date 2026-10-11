# Leaf React 式运行时与增量宿主实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execution method requires user selection; do not start implementation from this document alone.

**Goal:** 在保留旧应用的前提下，实现组件级计算、无 JSON 的增量宿主通路及可靠的 GPUI 子视图复用。

**Architecture:** Nim 管理组件身份、State 队列、局部协调和接受版本；Rust 仅保存渲染所需的宿主结构与 GPUI 控件状态。旧应用先接入 ABI 2，再逐步开放托管组件入口，最后启用经验证的缓存。三批共用同一功能工作区和分支，接口存在先后依赖，不拆为互不关联的项目。

**Tech Stack:** Nim 2.2.6+ / ORC；Rust 1.92+ / edition 2024；锁定的 gpui-kit 0.7.0、gpui-pre 0.3.7；同进程同步 C ABI；现有 Win32 Native Backend。不得无故升级依赖或替换 Cargo.lock。

**Spec:** [已确认的架构规格](../specs/2026-10-12-react-runtime-design.md)。执行者先读规格，再读本计划。

## Global Constraints

- 应用继续使用 Nim，不引入 JavaScript 运行时。
- 先实现同步、可验证的组件级更新；不复制 React 的 Fiber、并发调度、Suspense 和完整 Hooks 系统。
- 首次挂载之后，跨语言只传变化的宿主操作和必要元数据。
- Rust 不保存 Nim 组件状态、业务模型、闭包或另一套组件协调树。
- 现有公开 NodeKind 不增加 component 枚举，现有 Node 和控件构造函数保持兼容。
- 保留 ABI 1 的符号及 `leaf_gpui_abi_version() == 1`，新协议通过独立 ABI 2 查询入口协商。
- 字符串区只在调用期间借用；Rust/GPUI Element 和事件闭包不能保留指向 Nim 对象的指针。
- 普通更新在 executionScope 内的提交点接受；安装在作用域成功退出后确认，不混同两种时机。
- 回调的普通变量、数据库和文件副作用不在托管 State 回滚范围内。
- 保留 MaxNodes=10000、MaxDepth=64、MaxStringBytes=1048576、MaxTreeBytes=16777216、MaxListItems=100000。
- 新增组件实例上限 10000，计入同一候选/描述字节预算；暖行上限沿用 128，活动行不因暖缓存上限被卸载。
- 不预先宣称所有更新 O(1) 或最佳性能；Linux 测试不能代替 Windows 实机验收。

## Review Focus

这五类容易在正常路径外出错，已补到对应任务的测试中：

1. 空文本、中文及最大字节数边界；按 UTF-8 字节而非字符计预算，空 pointer/length 合同明确（任务 1、2）。
2. 回调换闭包但外观不变；宿主零操作也必须使下一事件读取新回调（任务 9）。
3. prepare 之后关闭窗口或更换后端 owner；旧 token 不得提交到新会话（任务 3、5、13）。
4. 父组件移除正在排队更新的子组件；不调用已卸载 render，不让 State 句柄复活（任务 8、9）。
5. 隐藏窗口、缩放/主题和输入法保护行；缓存与离屏淘汰不能冻结尺寸或销毁正在组合的编辑状态（任务 11、12、13）。

## 执行准备与文件责任

当前计划基线为 `96a2e035b57c8683c73957506c9a4f2a63c9141a`，两份设计文档尚未提交。
执行前重新核对 HEAD、工作树和工具链；不覆盖其他会话的修改。
用户选择执行方式后，按 Paseo 托管流程创建/复用 `【自动】Leaf组件与增量渲染`，
建议分支 `feat/leaf-react-runtime`。创建前在原会话报告名称、实际基线、分支和执行去向；
没有可用 Paseo 管理能力时先报告，不假装已创建或调度。

编码、修复、审查和测试复用该工作区。原会话持续协调。提交限功能分支；
本地合并与推送需另有授权，未获授权不执行。未完成所有平台验收不宣称整个功能已验收。

| 文件/目录 | 责任 |
| --- | --- |
| `src/leaf/host_protocol.nim` | 后端中立宿主属性、操作、变化统计；不导入 GPUI |
| `src/leaf/host_reconcile.nim` | 宿主句柄与已接受记录、候选增量、兄弟顺序；不执行用户代码 |
| `include/leaf_gpui_v2.h` | ABI 2 唯一结构合同与数值 tag |
| `src/leaf/gpui_ffi_v2.nim`、Rust `abi_v2.rs` | 两端 C 布局、借用缓冲和状态码 |
| Rust `host_store.rs`、`bridge_v2.rs` | 宿主候选/接受存储；类型化请求与入口 |
| `src/leaf/host_session.nim`、`gpui_session.nim` | Runtime 提交适配与 GPUI 会话归属 |
| `src/leaf/component_state.nim` | 状态槽、队列、快照策略和失效句柄 |
| `src/leaf/component_description.nim`、`component_view.nim` | 类型化组件定义、描述和 DSL |
| `src/leaf/managed_runtime.nim`、`components.nim` | 组件调度、局部记录、公共 API 汇总 |
| `src/leaf/core.nim` | 保留旧分支，新增不依赖组件模块的内部 driver 接缝 |
| Rust `host_view.rs`、`host_styles.rs` | 直接从宿主存储渲染、边界缓存与类型化样式 |
| 现有 `desktop.rs`、`lists.rs`、`backend_session.nim` | 复用输入、列表和原生生命周期，按需接入新路径 |
| `tests/ffi/`、`tests/nim/test_*`、Rust unit/UI tests | 合同、局部更新、事务和平台交互证据 |

下文 API 是本次固定的实现合同；未出现的私有辅助函数由实现者选择。
不要求为凑接口而提前创建空模块。每个任务先写能执行的失败测试，再实现、验证和提交。
纯文档更新不额外写测试。
文件表中的 Rust 短文件名均位于 `crates/leaf-gpui/src/`，Nim 短模块名均位于 `src/leaf/`；
回归短文件名均位于 `tests/nim/`。每个 Nim suite 用 `nim c -r --path:src --out:target/nim/对应文件名 tests/nim/对应文件名.nim`
运行，退出码 0 且 suite 断言全通过才算 PASS。Windows 输出加 `.exe`。

## 批次 A：旧应用使用类型化增量宿主

### Task 1: 后端中立宿主合同与属性转换

**Files:** Create `src/leaf/host_protocol.nim`, `tests/nim/test_host_protocol.nim`; Modify `src/leaf/styles.nim`（复用现有样式解析，保留 normalizeProps 合同）。

**Interfaces:**

- 复用现有 `NodeHandle`/`NoHandle`，不另造第二种宿主句柄。
- `HostProps` 包含 `NormalizedProps`、显式 text/placeholder、事件 mask、`HostListProps`；list 字段为 sourceGeneration:uint64、itemCount:int、heightMode:HostHeightMode、rowHeight/estimate:float64、overscan:int；`HostHeightMode = uniform | variable`。
- `HostOpKind = create | update | setChildren | remove | boundary | window`；`HostOp` 按 tag 保存完整属性/子句柄/边界/窗口数据；`HostBatch` 保存 sessionId/baseRevision/nextRevision/ops。
- `normalizeHostProps(node: Node, policy: HostStylePolicy): HostProps`；`HostStylePolicy = gpuiCompatible | nativeStrict`，保留现有两端属性容忍差异。
- `UpdateStats` 记录 componentRenders、visitedHosts、normalizedHosts、indexEdits、ops、ffiBytes、snapshotExports；计数均 uint64。

- [x] **1.1 写失败测试**：`host_props_preserve_absence_unicode_and_list_metadata`：空文本与 `"你好"` 不混同 absence；删除 opacity 后 presence 消失；input resetToken=7；100000 项列表 rowHeight=30/overscan=2 正确保留。`style_policies_preserve_platform_semantics`：同一 full 值保留可供后端区分的语义，未知控件属性沿用各自策略；非有限数拒绝。
  核心断言：`check normalizeHostProps(text("你好"), gpuiCompatible).text == "你好"`。
- [x] **1.2 运行**：`nim c -r --path:src --out:target/nim/test_host_protocol tests/nim/test_host_protocol.nim`；新增类型缺失导致 FAIL，确认不是工具链错误。
- [x] **1.3 实现**上述类型与转换；JSON 不参与此模块，完整属性携带 presence，回调只保留事件 mask。
- [x] **1.4 验证**：重复 1.2，并运行 `tests/nim/test_native_styles.nim`；全部 PASS。
- [x] **1.5 提交**：仅本任务文件，message `feat: define typed host update protocol`。

### Task 2: ABI 2 合同、缓冲区和三端布局验证

**Files:** Create `include/leaf_gpui_v2.h`, `src/leaf/gpui_ffi_v2.nim`, `crates/leaf-gpui/src/abi_v2.rs`, `tests/ffi/gpui_v2_layout.c`, `tests/ffi/gpui_v2_layout.rs`, `tests/nim/test_gpui_v2_layout.nim`, `scripts/check_gpui_v2_abi.nim`; Modify Rust `lib.rs`（注册模块）。

**Interfaces:**

- header 固定 ABI=2；状态码 OK=0、invalid=1、incompatible=2、stale=3、faulted=4、rejected=5、acceptedScopeError=6。
- 定义 `LeafBytes { const uint8_t *ptr; uint64_t len; }`、`LeafError { uint8_t *ptr; uint64_t capacity; uint64_t written; }`；空数据允许 null+0，非零长度拒绝 null；错误截断按容量返回实际写入字节，不依赖 NUL。
- struct/tag/flags 用 uint32_t/uint64_t、double；option 用 presence mask。header 列齐任务 1 的所有属性与控件字段，Rust/Nim 不自定额外 wire 字段。
- `LeafBatch` 使用长度明确的操作、子句柄、边界和 UTF-8 区；内部偏移 checked arithmetic。create/update/setChildren/remove/boundary/window 的 tag 分别为 1..6。
- `LeafRendererApi`：prepare(ctx,batch,error) / apply(ctx,error) 返回 int32；accept(ctx,revision) / discard(ctx) 为无失败 void；包含 struct_size/abi。暂存与恢复保持 Rust 已接受图不变。
- `LeafHostCallbacks`：attach(nimCtx,rendererApi,rendererCtx,error)、request(nimCtx,request,result,error)、detach(nimCtx)；`LeafRequest` tag 固定 event=1、viewport=2、status=3、ready=4、locate=5、rendering=6、frame=7，字段逐项类型化，不用 JSON 字符串作为 payload。
- `LeafGpuiApiV2`：struct_size/abi/capabilities，以及 run(config,callbacks,nimCtx,error)；`leaf_gpui_query_v2(requestedAbi,outApi,outSize,error): int32`。
- Nim `encodeBatch(batch: HostBatch): OwnedFfiBatch` 与 `borrow(batch: var OwnedFfiBatch): ptr LeafBatch`；OwnedFfiBatch 在同步调用结束前持有数组与字符串。

- [x] **2.1 写失败测试**：C/Nim/Rust 对所有 struct 的 sizeof/alignment/每个字段 offset/数组 stride 相等；测试 callback 实际调用约定。Rust 测试 `decode_rejects_bad_ranges_and_preserves_empty_utf8` 覆盖 null+0、null+1、偏移溢出、1MiB 边界、错误截断、中文字节长度和非法 UTF-8。
  每个布局字段的断言为 `check cValue == nimValue`、`check cValue == rustValue`；三值由各自独立编译的 probe 取得，不能都来自同一份手写数字表。
- [x] **2.2 运行**：`nim c -r --path:src --out:target/nim/check_gpui_v2_abi scripts/check_gpui_v2_abi.nim`；脚本缺失或新 ABI 缺失 FAIL。脚本之后应分别编译 C/Nim/Rust layout probe 并比较，不启动 GPUI。
- [x] **2.3 实现** header、两端绑定、owned buffer 与检查脚本；裸声明模块不依赖 GPUI，可供 Rust standalone probe 引用。不增加 bindgen 或其他生成器依赖。
- [x] **2.4 验证**：重复 2.2；`cargo test -p leaf-gpui --locked abi_v2::tests`，全部 PASS。Windows 使用同脚本 `.exe` 结果，不把 Linux 布局报告当 Windows 证据。
- [x] **2.5 提交**：本任务文件，message `feat: add versioned GPUI C ABI contract`。

### Task 3: Rust 宿主存储及可拒绝批次

**Files:** Create Rust `host_store.rs`; Modify `abi_v2.rs`, `lib.rs`。

**Interfaces:** `HostStore::new(session_id: u64)`；`prepare(&mut self, batch: &DecodedBatch) -> Result<(), HostError>`；`apply(&mut self) -> Result<(), HostError>`；`accept(&mut self, revision: u64)`；`discard(&mut self)`；`node(handle: u64) -> Option<&HostNode>`；`revision() -> u64`；`take_dirty_boundaries() -> Vec<u64>`。`HostNode` 保存种类、owned props、父/有序子句柄和最近边界，不存 JSON Node 或 Nim 状态。DecodedBatch 是任务 2 校验后的临时借用视图，HostStore 不延长其生命周期。

- [x] **3.1 写失败测试** `host_store::tests`：create 根和文本，update 后输入缓冲释放仍读到 `"你好"`；prepare/apply 不改变 accepted revision；accept 后 revision 递增；discard 保留旧节点。拒绝 foreign session、stale base、多父、图环、未知句柄、重复 create、kind 就地改变、悬空边界；5000 子项逆序结果正确。会话 dispose 后旧 prepared token 不可 accept。
  apply 后、accept 前：`assert_eq!(store.revision(), before_revision)`；accept 后：`assert_eq!(store.revision(), before_revision + 1)`。
- [x] **3.2 运行**：`cargo test -p leaf-gpui --locked host_store::tests`；新增模块缺失/断言失败 FAIL。
- [x] **3.3 实现** affected-node overlay 与预留空间；prepare 校验变化关系/祖先链，apply 仅应用到候选；accept 不分配/调用 GPUI/失败。不得 clone 整张图或为每次接受保留一层 overlay。属性更新不扫描全图。
- [x] **3.4 验证**：重复 3.2；新增分配/访问计数断言，5000 静态节点加一个文本 update 的访问量与 100 节点版本一致，允许固定祖先路径差异。
- [x] **3.5 提交**：message `feat: retain transactional GPUI host state`。

### Task 4: Nim 宿主协调器与最终子项顺序

**Files:** Create `src/leaf/host_reconcile.nim`, `tests/nim/test_host_reconcile.nim`; Modify `src/leaf/reconcile.nim`（仅复用/抽取可共享身份辅助，不改变旧 plan 入口）。

**Interfaces:** `newHostReconciler(sessionId: uint64): HostReconciler`；`reserveHandle(r): NodeHandle`；`planSnapshot(r, snapshot: Snapshot, nextRevision: uint64, policy: HostStylePolicy): HostCandidate`；`planDelta(r, changes: HostChanges, nextRevision: uint64): HostCandidate`；`batch(candidate): HostBatch`；`accept(r, candidate)`；`discard(r, candidate)`。HostChanges 包含变化记录、删除句柄、最终子项序列、边界和窗口变化；HostCandidate 带私有 owner/base generation。句柄分配单调，拒绝也不复用；reserve 在耗尽时明确失败。

`HostRecord` 字段为 handle/parent:NodeHandle、nodeId:string、kind:NodeKind、props:HostProps、boundaryId:uint64；
HostChanges 的 upserts 为 seq[HostRecord]，removals 为 seq[NodeHandle]，children 为父句柄与最终有序句柄序列。
增加 `validate(r,candidate)` 与 `publish(r,candidate)`（raises:[]）：前者在后端 prepare/apply 前校验归属和代数，
后者只发布已校验且被 Runtime 重入守卫保护的候选；accept 是验证+发布的测试/独立调用便利入口。
后端已经接受后不能再调用一个可能报 stale 的发布函数。

- [x] **4.1 写失败测试**：同身份 update 保留句柄；换宿主祖先 kind 重建后代；丢弃 candidate 后旧 plan 不可复用；foreign/stale 拒绝；属性删除恢复默认；5000 key 逆序输出一个父级 setChildren，不输出 4999 次模拟 seq 搬移；受影响计数正确。
  逆序 fixture 导入 sequtils，断言 `check candidate.batch.ops.countIt(it.kind == HostOpKind.setChildren) == 1`；全体句柄前后集合相等。
- [x] **4.2 运行**：`nim c -r --path:src --out:target/nim/test_host_reconcile tests/nim/test_host_reconcile.nim`，FAIL。
- [x] **4.3 实现** 持久宿主记录与增量索引，legacy planSnapshot 允许全树访问；planDelta 仅访问变化记录/关系，接受前预留索引容量。两种入口共享同一身份账本，不平行维护两套句柄。
- [x] **4.4 验证**：重复 4.2，加跑 `tests/nim/test_native_reconcile.nim`；所有用例 PASS。记录 snapshot 路径仍全树，不误报局部计算完成。
- [x] **4.5 提交**：message `feat: reconcile host changes without quadratic reordering`。

### Task 5: 版本协商、会话生命周期与类型化请求

**Files:** Create `src/leaf/host_session.nim`, `src/leaf/gpui_session.nim`, Rust `bridge_v2.rs`, `tests/nim/test_gpui_v2_session.nim`, `tests/ffi/gpui_v2_library.c`; Modify `src/leaf/gpui_api.nim`, Rust `lib.rs`。

**Interfaces:** `openGpuiSession(runtime: Runtime, api: GpuiApi): GpuiSession`；`attachHostSession(runtime: Runtime, consumer: HostConsumer): HostSession`；`close(session)`；`HostConsumer` 使用 prepare/apply/accept/discard 以及 session/owner，接受只发布元数据。新 `GpuiApi.v2` 可选；测试选择器 `LEAF_GPUI_ABI=auto|1|2`，2 缺入口时失败，auto 仅缺入口时退回。Rust query 输出任务 2 的函数表；run 创建空 HostStore，再经 attach 安装初始批次，随后启动窗口。detach 必须在 run 返回前清理 Nim hooks，关闭后不使用 rendererCtx。

- [x] **5.1 写失败测试**：C fixture 分别提供 old-only、valid-v2、incompatible-v2；auto/1/2 选择准确，旧 ABI 查询恒为 1。初始 attach 失败不启动窗口/ready；成功安装接受版本与 Runtime 一致；scope 收尾拒绝安装时 discard 并移除未安装 token；旧 owner 关闭不得卸载新 session。
  各 fixture 均断言 `check api.abi() == 1`；初始安装失败的回调计数断言 `check readyCalls == 0`。
- [x] **5.2 运行**：`nim c -r --path:src --out:target/nim/test_gpui_v2_session tests/nim/test_gpui_v2_session.nim`；`cargo test -p leaf-gpui --locked bridge_v2::tests`，预期新增合同 FAIL。
- [x] **5.3 实现** 协商、Nim cdecl trampoline 与错误捕获、HostConsumer 事务适配；先 validate Nim candidate，再后端 prepare/apply，接受路径只执行无失败发布。request 返回实际 accepted revision 与拒绝/已接受后 scope 错误状态；event 用句柄/来源代数/序列，viewport 用 source generation/key；status/ready/locate/frame 不返回树。
- [x] **5.4 验证**：重复 5.2；`tests/nim/test_native_commit.nim` 原例 PASS，Rust 验证 callback/context 在 detach 后不可访问。请求/回调不持有 HostStore 借用跨 FFI。
- [x] **5.5 提交**：message `feat: negotiate typed GPUI sessions and commit ownership`。

### Task 6: GPUI 从宿主记录渲染并接通旧应用 ABI 2

**Files:** Create Rust `host_view.rs`, `host_styles.rs`, `host_ui_tests.rs`; Modify Rust `lib.rs`, `desktop.rs`, `lists.rs`, `ui_tests.rs`, `bridge_v2.rs`；Nim `desktop.nim`, `gpui_session.nim`；Create `tests/nim/test_gpui_v2_requests.nim`; Modify `tests/nim/gpui_native.nim`, `gpui_native_app.nim`。

**Interfaces:** `HostView::new(store: Rc<RefCell<HostStore>>, boundary_id: u64, bridge: TypedBridge)`；`TypedBridge::request(&self, request: &LeafRequest) -> Result<HostReply, BridgeError>`；`apply_host_styles(element, props: &HostProps)`（按现有 GPUI element 类型返回）。Desktop 持有 legacy 或 typed renderer，typed 不访问 `model::Snapshot`；保留旧 Bridge/Node 给 ABI 1。InputSlot 按宿主句柄保存，事件内容在 Nim 同步调用期间有效；列表先复用当前行为但请求改成范围批量。

- [x] **6.1 写失败测试**：两种 ABI 同一计数器点击结果一致；中文输入/Enter/disabled、同值不重置选区、resetToken=7、拒绝后编辑恢复。100000 行仅请求 first=5000/finish=5050；首屏行失败不能 ready；status/ready/locate/rendering/frame 不 render/export Snapshot。测试计数器保证 typed 路径未调用 JSON parser/serializer。
  typed 请求测试安装编码/解析探针并断言 `check jsonCalls == 0`、`check statusSnapshotExports == 0`；这些探针不计入性能样本。
- [x] **6.2 运行**：`cargo test -p leaf-gpui --locked host_ui_tests`；`nim c -r --path:src --out:target/nim/test_gpui_v2_requests tests/nim/test_gpui_v2_requests.nim`，FAIL。
- [x] **6.3 实现** typed renderer 和控件同步安全点；属性不转回 string Styles；在 FFI 返回后创建/sync GPUI entities。暂不开 cached，先用持久句柄保证行为正确；ABI 1 继续原实现，ABI 2 支持旧 Application.render。
- [x] **6.4 验证**：重复 6.2；`cargo build --locked -p leaf-gpui`；分别设 ABI=1/2 运行 `nim c -r --out:target/nim/native_test scripts/native_test.nim`。两次真实窗口均 PASS 才通过批次 A；缺窗口工具明确 NotRun。
- [x] **6.5 提交**：message `feat: render GPUI from typed host updates`。批次 A 报告只宣称桥接增量，旧根刷新仍可能全树计算。

## 批次 B：托管组件、State 与局部协调

### Task 7: State 槽、快照策略和同步更新队列

**Files:** Create `src/leaf/component_state.nim`, `tests/nim/test_component_state.nim`。

**Interfaces:** `State[T]` 为 runtime/owner/slot/generation 的不透明句柄；`StateWriteResult = queued | disposed`；`StateEqual[T] = proc(a,b:T):bool`；`StateSnapshot[T] = proc(value:T):T`。内部 `StateStore` 提供 `beginAttempt(): StateAttempt`、`accept(attempt)`、`reject(attempt)`、`disposeOwner(owner)`。公开 set/update 在任务 8 导出；State 的 `read` 读取 accepted 值，候选值只能通过 ComponentContext.value 读取。

低层接口固定为 `newStateStore(runtimeId:uint64):StateStore`、
`allocateState[T](store:StateStore, owner:uint64, initial:T, equal:StateEqual[T]=nil, snapshot:StateSnapshot[T]=nil):State[T]`、
`queueSet[T](s:State[T], value:T):StateWriteResult`、`queueUpdate[T](s:State[T], f:proc(previous:T):T):StateWriteResult`、
`readAccepted[T](s:State[T]):T`、`readCandidate[T](attempt:StateAttempt,s:State[T]):T`。
最后一个接口只供实现层及测试访问，应用从 ComponentContext.value 读取候选值。

- [x] **7.1 写失败测试**：初值 0，三次 set(1) 后为 1，三次 update(+1) 后为 3；封存失败保持 0 且队列不重放；disposed 不能影响后挂载组件。跨 runtime、非 UI 线程、render/init/updater 期间写入拒绝。缺少安全 snapshot 策略的可变引用类型拒绝创建；提供深快照后拒绝 candidate 不污染 accepted 值。
  同一 StateAttempt 内断言 `check acceptedValue == 0`、`check candidateValue == 3`；reject 后再次尝试断言 `check candidateValue == 0`。变量由本任务的低层 StateStore 测试夹具读取，不依赖尚未完成的组件 DSL。
- [x] **7.2 运行**：`nim c -r --threads:on --path:src --out:target/nim/test_component_state tests/nim/test_component_state.nim`，FAIL。
- [x] **7.3 实现** 有类型槽与擦除后的队列桥接；默认 scalar/string/不含可变引用的值对象可用；复杂共享对象需显式 snapshot 或外部模型。相等比较缺省 nil 时保守计算，不对任意 ref 使用地址相等。
- [x] **7.4 验证**：重复 7.2，覆盖更新函数抛错和多 owner 批次的整体拒绝，全部 PASS。
- [x] **7.5 提交**：message `feat: add transactional component state queues`。

### Task 8: 组件定义、UiDescription 与 componentView DSL

**Files:** Create `src/leaf/component_description.nim`, `src/leaf/component_view.nim`, `src/leaf/components.nim`, `tests/nim/test_components.nim`, `tests/nim/test_component_view.nim`; Modify `src/leaf/view.nim`（只抽共享 AST 处理到新 `src/leaf/view_ast.nim`）。

**Interfaces:**

- `ComponentDef[P,M]`，`MountContext`，`ComponentContext`，`UiDescription`；`defineComponent[P,M](name: static[string], init: proc(ctx:MountContext, props:P):M, render: proc(ctx:ComponentContext, props:P, model:M):UiDescription): ComponentDef[P,M]`。
- `state[T](ctx:MountContext, initial:T, equal:StateEqual[T]=nil, snapshot:StateSnapshot[T]=nil): State[T]`；`set[T](s:State[T], value:T):StateWriteResult`；`update[T](s:State[T], f:proc(previous:T):T):StateWriteResult`；`value[T](ctx:ComponentContext, s:State[T]):T`；`read[T](s:State[T]):T`。
- `component[P,M](definition:ComponentDef[P,M], props:P, key="", revision:Option[uint64]=none(uint64)):UiDescription`；`memo[P,M](definition, compare:StateEqual[P]):ComponentDef[P,M]` 不改变组件类型身份。
- `host(node:Node):UiDescription`；`componentView(body:untyped):UiDescription`。内部 row/column 构建 host shell + UiDescription children，避免新增返回类型相同参数的公共重载造成 `column(@[])` 歧义。
- type ID 使用编译期的声明模块+name；同模块重复 name 的不同定义拒绝。不使用 proc/闭包地址。组件只能返回一个根。

- [x] **8.1 写失败测试**：DSL 生成宿主/组件混合树，支持 if/for/case，旧 view/column(@[]) 不歧义。普通 proc 不自动建实例；同类型/key 身份可匹配，重复 key 提前拒绝；同 name 不同模块不冲突，复制 ComponentDef 不变 type ID；props 版本和 memo 比较记录保留。
  静态断言 `doAssert typeof(column(@[])) is Node`；复制定义断言 `check originalTypeId == copiedTypeId`，两个模块同名定义断言 `check firstTypeId != secondTypeId`。
- [x] **8.2 运行**：分别编译运行 `tests/nim/test_components.nim`、`tests/nim/test_component_view.nim`，FAIL。
- [x] **8.3 实现** 描述与类型擦除；抽共享宏 AST 时不改变旧错误信息及 NodeKind。`components.nim` 只汇总公共 API，不自动导入桌面。
- [x] **8.4 验证**：重复 8.2，并跑 `tests/nim/test_view.nim`、`tests/nim/test_core.nim`，PASS。
- [x] **8.5 提交**：message `feat: describe managed component boundaries in Nim`。

### Task 9: Runtime driver、局部协调和统一接受点

**Files:** Create `src/leaf/managed_runtime.nim`, `tests/nim/test_managed_runtime.nim`, `tests/nim/test_component_commit.nim`; Modify `src/leaf/core.nim`, `components.nim`, `host_session.nim`, `host_reconcile.nim`。

**Interfaces:**

- 公共 `componentApplication(root:UiDescription, title:string, width=640, height=480, executionScope:ExecutionScope=nil):Application`；`invalidate(ctx:ComponentContext)` 与 `invalidateRoot(runtime:Runtime)`；`batch(runtime:Runtime, body:proc())`；`flush(runtime:Runtime):bool`；`updateStats(runtime:Runtime):UpdateStats`。
- core 新增内部 `RuntimeDriver` 基类和 `newDriverApplication(title:string, width,height:int, factory:proc(owner:Runtime):RuntimeDriver, executionScope:ExecutionScope=nil):Application`。跨模块所需类型/方法使用 Nim 导出标记，但作为内部接口文档化；managed_runtime 导入 core 并实现 driver，core 不反向 import components/host_protocol。
- driver hooks：`stage(forceRoot:bool):RuntimeDriver`、`stageViewport(key:string,first,finish:int,protected:seq[int]):RuntimeDriver`、`invokeAccepted(key:string,event:Event):bool`、`exportSnapshot():Snapshot`、`find(key:string):MountedNode`、`stats():PerformanceStats`、`publish()`/`reject()`（最后两者 raises:[]）。hooks 处理组件数据；外部 executionScope、重入守卫、committer/preparer owner 和 revision 仍由 core 负责。
- `hostCandidate(candidate:Runtime):HostCandidate` 由 managed_runtime 暴露给 host_session；legacy 走任务 4 的 planSnapshot，managed 直接使用 planDelta，不调用 candidate.snapshot。
- core 的 public refresh 在 managed 模式 forceRoot=true；事件结束 flush 为 false，仅处理队列/失效。Snapshot/find 显式查询才物化；事件查找直接走已接受回调索引。

- [x] **9.1 写失败测试**：Counter 加 100/1000/5000 静态节点，每次点击 componentRenders=1，visitedHosts/indexEdits 不随静态数增长；同事件三次 update 只有一次提交，两个点击分别提交；无显式 batch 的 UI 任务只在安全边界 flush。
- [x] **9.2 写失败测试**：同 key 重排保留 State；换 key/type/parent 重建；父子同时更新只执行一次子 render；memo 父跳过仍处理脏后代；父移除排队子后 render 次数=0、State.write=disposed。只换回调时宿主 ops=0，但下一点击调用新闭包。只改 State 而输出相同仍推进 revision。
- [x] **9.3 写失败测试**：callback/render/prepare/apply 失败保留 accepted State、回调、索引与 revision；普通变量副作用保留。scope body 已接受后收尾失败，State 和 revision 保持新值且 outcome=acceptedScopeError；安装收尾失败不安装 hook。节点/深度/字节与组件实例预算不能被局部增长绕过。

  Counter fixture 的核心断言固定为以下代码；`rt` 是已经挂载的 managed Runtime，测量不包含首屏：

  ```nim
  let before = rt.updateStats()
  discard rt.dispatch("increment", Event(kind: click))
  let after = rt.updateStats()
  check after.componentRenders - before.componentRenders == 1'u64
  check after.normalizedHosts - before.normalizedHosts <= 3'u64
  check after.snapshotExports == before.snapshotExports
  check after.ops - before.ops == 1'u64
  ```

  此 fixture 的 Counter 固定为 column/text/button 三个宿主，无嵌套组件；其它静态组件是 sibling。
  函数式队列测试的最终断言为 `check counter.read() == 3`；拒绝后为 `check counter.read() == 0`。
- [x] **9.4 运行**：分别编译运行 `tests/nim/test_managed_runtime.nim`、`tests/nim/test_component_commit.nim`，确认 FAIL。
- [x] **9.5 实现** driver 分支、脏 owner/后代路径、key 映射、候选 overlay、增量 key 多义索引和预算汇总；发布前预留，发布后不累积 overlay 链。保留旧 refreshImpl 主体，不借此全面拆 core。host_session 接受宿主版本后 core.publish 同时接受 State/回调；这段期间不运行用户代码。
- [x] **9.6 验证**：重复 9.4，并跑 `tests/nim/test_native_commit.nim`、`test_model_postcommit_ui.nim`、`test_model_transactions.nim`；PASS。对 UI 任务边界使用可控调度器测试，headless 必须显式 flush，不靠睡眠碰运气。
- [x] **9.7 提交**：message `feat: update managed components without full-tree refresh`。

### Task 10: 旧 API、Snapshot 与 Win32 适配

**Files:** Modify `src/leaf/core.nim`, `headless.nim`, `runner.nim`, `backend.nim`, `backend_session.nim`, `backends/win32/backend.nim`, `backends/win32/host.nim`, `components.nim`, `host_session.nim`; Create `src/leaf/native_host_adapter.nim`, `tests/nim/test_component_compat.nim`; Modify `tests/nim/test_native_backend.nim`。

**Interfaces:** managed application 返回现有 Application，因此 newRuntime/run/headless 不新增另一套应用类型。`exportSnapshot` 按 revision 缓存，旧 validator/custom committer 显式触发完整导出。`nativeHostConsumer(backend:Backend):HostConsumer` 将 HostBatch 映射为 Native UpdateBatch；为 Backend 增加可选 `acceptedDelta` 元数据入口（HostAcceptedDelta 只含变更实体、删除句柄与最终顺序），旧 accepted 保留兼容。Win32 新适配使用 delta 更新持久事件/实体索引，不为每次组件更新复制整表。

- [x] **10.1 写失败测试**：旧普通变量回调仍根刷新且失败后变量不回滚；managed 普通变量需 invalidate；旧 view/cached/Router 行为不变。legacy/managed × ABI1/2 四种路径输出一致，ABI1 兼容导出成本计入统计。相同 revision 两次 Snapshot 查询只导出一次，下一更新失效；安装 SnapshotValidator 产生显式 export 计数，内置后端不产生该计数。
  连续显式导出前后计数断言 `check after.snapshotExports - before.snapshotExports <= 1'u64`；兼容输出按树内容比较，不比较进程内句柄数值。
- [x] **10.2 写失败测试**：fake native backend 接到局部 create/update/setChildren/remove 的准确结果；5000 逆序最终 index 正确，无二次方 Nim seq 模拟；旧 Backend.accepted 插件仍得到完整兼容元数据，Win32 acceptedDelta 不重建全表。事件代数和 settlement 规则保持现有测试结果。
- [x] **10.3 运行**：`nim c -r --path:src --out:target/nim/test_component_compat tests/nim/test_component_compat.nim`，FAIL。
- [x] **10.4 实现** 兼容导出与 Native 适配；setChildren 对原生控件顺序可逐控件调用，但在 Nim 使用最终顺序直接赋值，不逐项搜索/搬移；保留 Win32 现有全布局策略并如实计数。首次 managed 支持使用显式 import leaf/components，不改变旧 import leaf 的初始化。
- [x] **10.5 验证**：重复 10.3，并跑 `test_routing.nim`、`test_native_backend.nim`、`test_native_reconcile.nim`、`test_native_edit.nim`。编译 `-d:leafHeadlessOnly` fixture，确认不加载 GPUI/user32；真实 Windows 检查留任务 13。
- [x] **10.6 提交**：message `feat: adapt managed updates to legacy and Win32 hosts`。批次 B 用 headless 和 fake backends 验收局部计算，不以此宣称桌面交互已验收。

## 批次 C：列表、缓存与平台性能验收

### Task 11: 托管虚拟列表及行组件生命周期

**Files:** Modify `managed_runtime.nim`, `component_description.nim`, `components.nim`, `gpui_session.nim`, Rust `lists.rs`, `host_view.rs`; Create `tests/nim/test_component_lists.nim`; Modify Rust `list_tests.rs`。

**Interfaces:** `componentList(key:string, keys:seq[string], builder:proc(index:int):UiDescription, rowHeight=0.0, estimatedHeight=40.0, overscan=2):UiDescription`；builder 版本由新 source generation 标识。视口请求带列表句柄/source generation/first/finish/protected keys，高度结果带相同 source generation；响应只含已接受行句柄/范围/版本，不附 Snapshot。普通 host(virtualList(...)) 保持旧 RowBuilder 行为。

- [x] **11.1 写失败测试**：100000 项首视口 [5000,5050) 只初始化 50 行（overscan=0 fixture）；同视口重复请求不重建；同源重排保留 key 的 State，新源代数重建。旧代数高度/行结果拒绝；新源 key 锚点恢复正确。
  首次和同视口重复请求后均断言 `check initializedRows == 50`；移出再淘汰的行句柄写入断言 `check writeResult == StateWriteResult.disposed`。
- [x] **11.2 写失败测试**：活动+受保护行超过128仍保持活动；离屏暖缓存最终淘汰释放 State/回调；焦点/IME 行受保护不卸载，取消保护后可淘汰。行构建失败保留旧行/回调/高度，源替换失败不能发布部分候选。componentList 在 ABI1 的快照/列表适配路径与 ABI2 行结果一致。
- [x] **11.3 运行**：`nim c -r --path:src --out:target/nim/test_component_lists tests/nim/test_component_lists.nim`；`cargo test -p leaf-gpui --locked list_tests`，FAIL。
- [x] **11.4 实现** 行 owner=(列表实例,source generation,item key)，预算/事件激活分离；范围合并，先释放 Rust store 借用再调用 Nim，返回后建 GPUI view。不得在 render 中调用业务 callback。
- [x] **11.5 验证**：重复 11.3，并跑 `test_lists.nim`、`test_gpui_bridge.nim`；PASS。统计活动实例、暖行、事件数，不以 GC 后总内存代替生命周期断言。
- [x] **11.6 提交**：message `feat: retain bounded component state in virtual lists`。

### Task 12: GPUI HostView 缓存和失效传播

**Files:** Modify Rust `host_store.rs`, `host_view.rs`, `host_styles.rs`, `desktop.rs`, `host_ui_tests.rs`。

**Interfaces:** `BoundaryState { root_handle, layout_style, revision, dirty_reason }`，`DirtyReason` 明确区分内容/子项/外部布局/继承样式/全局刷新。`take_dirty_boundaries` 输出待通知边界；边界存在对应持久 Entity；边界内普通叶节点无独立 Entity。GPUI cached 仅使用可明确提供外部布局样式的边界，其他边界保守 render。

- [x] **12.1 写失败测试**：Counter 改变不执行静态 sibling HostView render；尺寸由 9→10 变宽时父布局正确；祖先尺寸、窗口 scale、主题/继承 text style 改变使相关 cached 失效；内容测量边界保守路径与无缓存结果相同。隐藏后显示、全局 refresh 不显示过期帧。
  固定外部布局的 sibling fixture 断言 `assert_eq!(sibling_render_count, before_sibling_render_count)`；内容自动测量 fixture 不要求该计数不变，要求缓存开关两边的 bounds 相等。
- [x] **12.2 运行**：`cargo test -p leaf-gpui --locked host_ui_tests`，新增失效断言 FAIL。
- [x] **12.3 实现** Entity/AnyView.cached 边界、通知去重及 GPUI 安全点；直接读取 HostStore，不能为渲染临时重建完整嵌套 Node。保留可关闭缓存的测试开关 `LEAF_GPUI_CACHE=0|1` 用于行为对照。
- [x] **12.4 验证**：重复 12.2；真实窗口分别 CACHE=0/1 执行脚本，交互和几何结果一致。报告 HostView render/layout/frame 三类成本，缓存不可证明安全时不默认开启该类边界。
- [x] **12.5 提交**：message `perf: cache GPUI component host boundaries safely`。

### Task 13: 跨语言故障和真实平台回归

**Files:** Create `tests/nim/test_component_faults.nim`, `tests/nim/component_native_app.nim`; Modify `tests/nim/gpui_native.nim`, `scripts/native_test.nim`, Rust `host_ui_tests.rs`; Create `tests/windows/test_component_host.nim`; Modify `docs/verification.md`（记录新命令与实际状态）。

**Interfaces:** native fixture 使用同一业务场景，可选择 legacy/managed、ABI=1/2、CACHE=0/1；测试通过已有定位接口点击/编辑，不靠固定屏幕坐标或前台窗口猜测。fault fixture 仅测试构建导出注入点，发行 API 不暴露任意故障开关。

- [x] **13.1 写失败测试**：候选 build/prepare/apply、恢复失败、scope 入场/收尾、安装确认、窗口关闭、旧 session/序列事件的故障矩阵；验收 State/Runtime/HostStore revision 一致。恢复失败冻结后不再执行业务回调；已接受 scope 错误不自动重复事件。
  恢复成功的各拒绝路径断言 `check rt.acceptedRevision == beforeRevision`、`check storeRevision == beforeRevision`；恢复失败后再次派发断言 `check callbackCalls == callsBeforeFreeze`。
- [x] **13.2 运行**：`nim c -r --path:src --out:target/nim/test_component_faults tests/nim/test_component_faults.nim`，新故障路径 FAIL。
- [x] **13.3 实现/修复** 各自归属模块的问题；扩展真实窗口 fixture 到中文输入、Enter、reset、拒绝恢复、光标/选区、IME 开始/结果/结束、滚动焦点行、resize/隐藏/显示。保留 DPI 和 watch ready/receipt 现有契约。
- [ ] **13.4 验证**：Linux 上运行 full Nim runner、Rust workspace tests 与 native_test 的兼容矩阵；Windows 上运行 `nim c -r --out:target/nim/test_win32 scripts/test_win32.nim` 并执行 ABI2 GPUI fixture。macOS 未执行时单独标记 NotRun；Win32 runner 在 Linux 返回2只能记 NotRun。没有真实 Windows 环境则保留平台验收阻塞，不签全平台通过。
- [x] **13.5 提交**：message `test: verify component commits and native interaction failures`；保存每个命令、退出码、工具链和 fixture 来源，不只保存最终截图。

### Task 14: 结构性性能验收、发布兼容与文档

**Files:** Create `benchmarks/components.nim`, `scripts/verify_component_performance.nim`, `tests/nim/test_component_performance.nim`, `examples/component_counter.nim`; Modify `benchmarks/performance_native.nim`, `src/leaf/performance_report.nim`, `performance_protocol.nim`, `tests/nim/test_performance_protocol.nim`, `test_performance_report.nim`, `test_performance_workloads.nim`, `scripts/package_sdk.nim`, `tests/release/test_sdk.nim`, `docs/architecture.md`, `docs/nim-api.md`, `docs/development.md`; Create `docs/superpowers/reviews/2026-10-12-react-runtime-verification.md`。

**Interfaces:** 新独立结构性基准 `components.nim` 提供 `--mode legacy-json|legacy-typed|managed-typed --static N --iterations N --warmup N --rounds N --output PATH`；所有模式相同业务与正确性检查，输出含 mode/ABI/cache、commit、硬件、工具链、原始样本与任务1计数。`verify_component_performance` 读取该报告并验证计数约束；JSON 仅用于落盘报告，计时区间不生成报告。现有测量 schema 不静默改义，新增计数兼容读取；需改 schema 时同步严格解析器及 fixtures。

`src/leaf/performance_report.nim` 新增 `verifyComponentReport(report:JsonNode):seq[string]`，返回空序列才通过；脚本调用此函数并以非零退出报告所有失败项。报告不得接受计数缺失作为零值。

- [ ] **14.1 写失败测试**：构造报告验证计数不随 static=100/1000/5000 增长；故意注入 full Snapshot 导出、额外静态 render、每次分配线性增长时 verifier 必须失败。5000 逆序、100000/50列表、只换callback、连续拒绝/挂卸载都必须有行为校验；缺样本/元数据不能通过。
  断言 `check verifyComponentReport(validReport).len == 0`、`check verifyComponentReport(reportWithFullTreeExport).len > 0`；另外两种 legacy mode 报告不套用 managed 的计数上限。
- [ ] **14.2 运行**：编译运行 `tests/nim/test_component_performance.nim`，FAIL。
- [ ] **14.3 实现** 基准、原生帧计数和严格 verifier；基准模式记录总耗时以及 component/render、FFI/Rust apply、GPUI layout/frame 的分段。计时区间不启动编译器、不序列化日志，不用模拟 backend 的吞吐量替代真实帧。SDK 包含新 Nim 模块及 ABI2 合同，安装后的应用用随包 DLL；不删 ABI1 支持。
- [ ] **14.4 微基准验证**：`nim c -d:release --mm:orc --path:src --out:target/nim/component_bench benchmarks/components.nim`；同机器每模式 static=100/1000/5000，warmup=50、rounds=3、iterations=200。用相同业务验证结果，计数约束必须通过；报告 median/P95，不用时间阈值掩盖正确性失败。
- [ ] **14.5 完整验证**：`cargo test --workspace --locked`；`cargo clippy --workspace --all-targets --locked -- -D warnings`；`cargo fmt --all --check`；`nim c -r --out:target/nim/test_runner scripts/test.nim`；任务13真实窗口矩阵；运行原生帧基准及 SDK 搬迁回归。均记录实际结果；软件 GPU、缺平台或测试工具分别列出。
- [ ] **14.6 写验收记录**：保存 Release 原始样本、平台/编译/commit/库 hash、各分段耗时、稳定内存/峰值、兼容矩阵和未验证项。原始证据放原会话工作区 `/home/jimxl/projects/leaf/target/verification/react-runtime/<run-id>/`，执行 worktree 不删除它；摘要与可复现命令纳入本任务 review 文档。不要把历史 a00191b 的 8.074ms 当当前对照。
- [ ] **14.7 更新用户文档与示例**：说明 State/普通变量、memo、key、离屏 State 淘汰、Snapshot 导出成本、ABI退回诊断和缓存限制；不默认改写 Router/PageGroup 生命周期。新示例须通过 headless 和真实窗口，旧示例继续运行。
- [ ] **14.8 提交**：message `perf: verify incremental runtime and publish migration guidance`；全分支审查后修复对应问题并重复受影响验证。未获合并推送授权时停在已提交、已审查的功能分支，报告证据与阻塞。

## 规格覆盖与完成判定

| 规格章节 | 任务 |
| --- | --- |
| 1–3 分工、目标和流向 | 1–6 与14的工作量计数 |
| 4 组件/State/memo | 7–9 |
| 5 身份和顺序 | 4、8、9、10 |
| 6 局部挂载/索引/预算/Snapshot | 9、10、14 |
| 7 类型化 ABI/所有权/兼容 | 1、2、3、5、6 |
| 8 普通提交/安装/失败恢复 | 3、5、9、13 |
| 9 GPUI/Win32 | 6、10、12、13 |
| 10 虚拟列表 | 6、11、13 |
| 11 迁移与分批边界 | 三批出口、10、14 |
| 12 正确性和性能 | 各任务测试、13、14 |

完成报告必须区分：代码已实现、纯运行时检查通过、平台窗口验收通过、性能对照成立。
缺少任何必需平台证据时不报告整项验收完成；已完成批次可独立报告实测结果。

## 计划审阅与执行方式

本文件只完成计划编写，所有任务均未执行。用户审阅并选择执行方式后再启动编码。

建议**当前主 Agent 按任务顺序实施，批次出口和最终由独立 Agent 审查**：
组件 driver、宿主账本和提交生命周期相互依赖，顺序实施可减少接口交接成本。
如果用户选择逐任务委派，则遵守 Paseo 角色分工与实际 profile 配置，明确文件边界和集成负责人；
编码后由“方案设计，架构思考”验收，复杂阻塞再交“高消耗工作”。
没有可用 profile/工具时不声称调度成功，原会话负责协调和交付。
