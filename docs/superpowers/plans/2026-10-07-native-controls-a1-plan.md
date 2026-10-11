# Leaf 原生控件 A1：公共协议与增量提交实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 先交付可在 Linux 上验证、无需 Cargo 的后端中立提交链路，让后续 Windows / Android 原生适配器接入同一份已测试协议。

**Architecture:** 保留 Node、MountedNode、业务闭包及现有 JSON 快照；公共属性转换为有类型的描述，协调器维护独立实体身份。Runtime 在后端提交成功后才发布候选；记录型 Backend 验证增量更新、失败恢复、事件与惰性列表。GPUI 继续使用旧 ABI 和默认桌面入口。

**Tech Stack:** Nim 2.2.6+、ORC、Nim unittest；不新增产品依赖，不修改 Rust。

**Spec:** `docs/superpowers/specs/2026-10-07-native-controls-design.md`

## 状态与范围

用户已要求按总体草案开始编码，视为总体设计方向获准。当前仓库尚无原生后端实施计划；本文件是首个实施批次，**待用户审阅后执行**，不是已经完成的代码或平台支持声明。

A 阶段不能诚实地一次标为完成：它同时包含公共协议、Win32 线性布局、原生复合行池、输入法、导航、Direct2D 和打包。拆成独立可测试批次：

1. **A1（本计划）：** 公共属性、Runtime 提交边界、协调器、记录型 Backend、编译期 headless 隔离。
2. **A2（另行详细计划）：** Win32 Host、Unicode 表单、线性布局、受控输入与组合输入，native 工具链选择。
3. **A3（另行详细计划）：** 原生列表行池、已确认导航历史、Canvas 与 Direct2D、带数据库纵向样例、发布和 Windows 实机验收。
4. B：Android 宿主 / JNI / Views / SQLite / 生命周期，尽早验证公共边界中的移动假设。

A1 不新增 scroll / navigation / canvas 节点，不承诺原生窗口、手机或输入法行为，也不切换默认后端。它不是对总体草案 A 阶段验收条件的削减；未实现项明确留在 A2 / A3。

## Global Constraints

- 首批平台为 **Windows + Android**；完整目标 Windows、Android、iOS、Linux、macOS，未验收的平台不得宣称支持。
- Nim 掌握应用状态、页面、事件和业务逻辑；回调与原生对象不进入可序列化快照。
- 相同父路径、相同 key、相同类型复用实体；跨父移动、类型替换或卸载后重建都是新实体。无 key 按位置匹配，重复 sibling key 拒绝。
- 原生提交不是数据库事务，不回滚事件闭包已发生的业务修改。
- RuntimePreparer 只准备隔离候选，不修改可见控件、不执行业务回调。
- 所有 Runtime 闭包及提交在所属 UI 线程执行；提交中禁止递归业务 dispatch。
- 未知属性、非法值始终错误；仅已知装饰属性可默认降级并报告一次结构化诊断，strict 模式拒绝。必要控件与布局能力缺失直接拒绝。
- 当前上限保持 `MaxNodes = 10_000`、`MaxDepth = 64`、`MaxStringBytes = 1_048_576`、`MaxTreeBytes = 16_777_216`、`MaxListItems = 100_000`；暖行缓存保持最多 128 行及现有字节预算。
- 正常更新不得全量重建实体；绘制、可见行请求不得重跑完整业务 render。
- 过期 revision 不是单独拒绝事件的理由；实体卸载、会话重建和行换绑必须使旧通知失效。
- 旧桌面默认 GPUI，保持公开构造器、DSL、事件与 JSON 快照形状；不移除 Cargo / GPUI 旧路径。
- headless-only 编译不得导入或链接图形工具包；运行时 `--headless` 含义不变。

## Review Focus

- 父节点同 key 换类型时，其所有后代即使字符串 ID 不变也须重建；Task 3 增加覆盖。
- 删除后同 key 再出现、候选失败后的重试都不能复用失效 handle；Task 3 / 4 增加覆盖。
- 可见行 materialize 与完整 refresh 都须经过同一提交门，且准备中的 materialize 不能提前提交；Task 2 / 4 增加覆盖。
- Backend 部分 apply 失败且恢复也失败时，禁止继续派发业务事件；Task 4 增加覆盖（包括直接调用该 Runtime 的 dispatch，不只经过 session 队列）。
- 日志、dump 写入失败发生在后端成功提交后时，不得把已接受提交伪报为“候选被拒绝”，也不得重放业务事件；Task 2 增加覆盖。

## 工作区、工具与分工

实施前用 `using-git-worktrees` 创建独立 `feat/native-controls-a1` 工作区；把本计划和现有未跟踪草案复制进去，保留主工作区原件。不得在 `main` 直接实施或自动合并 / 推送。

当前 shell 的 PATH 没有 Nim；已发现并确认 `/tmp/nim-2.2.6/bin/nim` 可用。执行时先 `export PATH=/tmp/nim-2.2.6/bin:$PATH; export NIM=/tmp/nim-2.2.6/bin/nim`，若路径失效先报告工具链阻塞，不下载替代品冒充验证。

主 Agent 承担方案设计与集成；按照 Paseo 编排规则，方案获准后读取实时 Agent profiles，常规编码用「日常工作」，最终验收用「方案设计，架构思考」。A1 没有界面视觉设计任务，不派 Gemini。所有任务有接口依赖，先顺序执行，避免同改 core.nim；复用同一编码 Agent，不为每个小步骤反复创建会话。

## 文件边界

| 文件 | 职责 |
| --- | --- |
| `src/leaf/styles.nim` | 旧 Styles / attributes 的公共语法校验及有类型转换；不包含平台能力 |
| `src/leaf/backend.nim` | 能力、批次、实体 handle、事件信封及 Backend / Host 契约 |
| `src/leaf/reconcile.nim` | 纯描述差异与实体身份分配；无控件和业务回调调用 |
| `src/leaf/backend_session.nim` | Runtime 与 Backend 的提交、恢复、事件队列及列表请求协调 |
| `src/leaf/backends/headless.nim` | 记录型 Backend，测试失败注入、批次与实体计数 |
| `src/leaf/core.nim` | 唯一候选构建 / 准备 / 提交 / 发布边界，保持旧 API |
| `src/leaf/gpui_styles.nim` | 保留旧入口，委托公共 style 语法校验，不启用 native 能力拒绝 |
| `src/leaf/headless.nim` | 公共属性校验，保持现有命令输出 |
| `src/leaf/runner.nim` | `leafHeadlessOnly` 编译期隔离桌面导入 |
| `tests/nim/test_native_*.nim` | 自动被现有 `scripts/test.nim` 收集的新增测试 |

---

### Task 1: 公共属性描述与语法校验

**Files:** Create `src/leaf/styles.nim`, `tests/nim/test_native_styles.nim`; Modify `src/leaf/gpui_styles.nim`, `src/leaf/headless.nim`。

**Interfaces:**
- Consumes: `Node.styles`, `Node.attributes`, `Node.kind`, `MountedNode.children`。
- Produces: `validateStyleSyntax*(styles: Styles)`；`normalizeProps*(node: Node): NormalizedProps`；`validateProps*(root: MountedNode)`。
- `NormalizedProps` 包含 `LayoutProps`、`ControlProps`、`AccessibilityProps`、有类型的可选装饰值；无任意字符串属性留给 Backend 再解析。
- `Dimension` 区分 auto / fixed / fill，`width=full` / `height=full` 转 fill；未指定与显式指定属性须可区分，以供能力检测及移除属性时还原默认值。
- Layout 包含 gap、padding、width/height、flex_grow、align、justify、overflow，以及语法合法但需能力声明的 min/max 和 flex_shrink。非负有限数不超过 1_000_000，opacity 额外限制不超过 1。
- 颜色规范化为 RGBA，接收现有 `#RGB` / `#RRGGBB` / `#RRGGBBAA`；保留当前 weight、align、justify、overflow 全部合法枚举。
- Control 保留 label、value、placeholder、enabled、checked、progress、variant、事件存在位；checked 只接受 true / false，progress 只接受有限 0..100，variant 接受 default / primary / danger / success / warning / info，并保留已有 outline / ghost / secondary。按节点类型校验属性所属；语法合法的旧外观 variant 不代表 native 已支持该外观，能力表单独声明支持与降级规则。
- Accessibility A1 默认映射原生语义：label、hint、value、enabled；不新增公开可访问属性 DSL。

- [ ] Step 1: 写测试 `full becomes fill`、`defaults differ from explicit zero`、`invalid style always fails`、`known decoration remains typed`、`invalid control attributes fail`、`removed property restores default`。断言 full 不是无限尺寸；`NaN`、`Inf`、负尺寸、opacity=1.1、非法 hex、未知样式 / 属性被拒绝。
- [ ] Step 2: `nim c -r --out:target/nim/test_native_styles tests/nim/test_native_styles.nim`；Expected: FAIL，公共模块 / 接口不存在。
- [ ] Step 3: 实现上述类型和接口；`gpui_styles.validateStyles` 只复用 `validateStyleSyntax` 的旧样式词汇，不给旧桥接额外施加控件属性限制；headless 的 Runtime validator 使用 `validateProps`。
- [ ] Step 4: 运行新增测试，再分别运行 `test_core.nim`、`test_view.nim`、`test_gallery.nim`、`test_gpui_bridge.nim`，统一使用 `nim c -r --out:target/nim/<suite> tests/nim/<suite>.nim`；Expected: 全部 PASS，旧 JSON 和 Gallery 样式合法。
- [ ] Step 5: 仅提交上述文件：`git commit -m "feat: add backend-neutral typed control properties"`。

### Task 2: Runtime 候选提交门与 accepted revision

**Files:** Modify `src/leaf/core.nim`; Create `tests/nim/test_native_commit.nim`。

**Interfaces:**
- Consumes: 现有 SnapshotValidator、RuntimePreparer、refresh、materialize、ExecutionScope。
- Produces: `RuntimeCommitter* = proc(accepted: Runtime, candidate: Runtime) {.closure.}`；`setCommitter*(runtime: Runtime, committer: RuntimeCommitter)`；`acceptedRevision*(runtime: Runtime): uint64`；`freezeEvents*(runtime: Runtime, reason: string)`（阻止业务 dispatch，显式错误，A1 不提供恢复失败后的自动解冻）。
- committer 是应用可见变更的独立阶段；参数只供同步读取 / 候选准备，不允许对 accepted 执行 refresh / dispatch / materialize。候选不带活跃 committer，且其业务 dispatch 一律拒绝。
- 调用顺序为构建 → 校验 → preparer → committer → 发布。committer 抛出时，旧 snapshot、索引、缓存、revision 均不发布；业务对象变化不回滚。
- `setCommitter` 首次调用以 `accepted=nil`、隔离的当前候选挂载当前描述；成功才安装钩子，失败不修改钩子或已接受描述。已有非 nil 钩子不允许静默替换，先明确卸载会话。
- 每次成功发布树 / 可见行增量增加 revision；失败不增加。旧快照 JSON 不新增 revision 字段。`prepare` 无业务 render，只在成功发布实际准备结果时递增。
- 完整 refresh、prepare、已接受界面的 materialize 都走同一门。preparer 内对隔离候选的 materialize 只改变候选，不触发外层 committer。

- [ ] Step 1: 写测试 `commit before callback publication`、`failed commit retains callbacks and caches`、`business state is not rolled back`、`viewport commit failure is isolated`、`preparer materializes without recursive commit`、`candidate cannot dispatch business callbacks`、`postcommit diagnostics failure does not undo acceptance`。
  - 断言 committer 中 accepted 仍是旧树，candidate 是新树；失败后旧回调可恢复，revision 不变；列表失败不改旧可见行和 stats。
  - 现有 Diagnostics 已捕获 log / dump 写入异常，应保留此语义而非新增测试钩子：先在临时目录成功创建 Diagnostics，再删除空目录以使下一次 dump 失败。断言 backend 已提交、refresh 成功、accepted revision 增加，错误仅报告到 stderr，旧业务事件不重放。
- [ ] Step 2: `nim c -r --out:target/nim/test_native_commit tests/nim/test_native_commit.nim`；Expected: FAIL，新提交门不存在。
- [ ] Step 3: 抽取私有候选构建及发布函数，让上述入口共享顺序和 guard；确保 candidate 缓存与描述的隔离，不共享可变 MountedNode 修改。发布后 diagnostics 错误作为独立诊断故障报告，不能让 API 看起来拒绝了已完成提交。
- [ ] Step 4: 运行新增测试、`test_core`、`test_lists`、`test_gpui_bridge`、`test_model_context`、`test_model_postcommit_ui`；Expected: 全部 PASS，executionScope 和旧 GPUI preparer 行为无回归。
- [ ] Step 5: `git commit -m "feat: publish runtime candidates after backend confirmation"`。

### Task 3: Backend 契约与纯增量协调器

**Files:** Create `src/leaf/backend.nim`, `src/leaf/reconcile.nim`, `tests/nim/test_native_reconcile.nim`。

**Interfaces:**
- Consumes: Task 1 `normalizeProps`；现有 MountedNode 身份；Task 2 revision。
- Produces: `BackendCapabilities`、`CapabilityMode = compatible / strict`、`CapabilityIssue(nodeId, property, reason)`、`NodeHandle`（uint64 不透明 ID）、`MountedEntity`（handle、parent handle、node ID、kind、typed props）、`UpdateBatch`。
- `UpdateOp` 为 create / update / move / remove；含 handle、父 handle、目标 sibling index，create/update 的有类型属性。update 使用完整规范化属性覆盖，属性删除能恢复默认值，不携带回调、Node 引用或平台指针。
- `Reconciler` 拥有 accepted 实体表与单调 handle 分配器；`newReconciler*(): Reconciler`、`plan*(r: Reconciler, snapshot: Snapshot, revision: uint64): ReconcilePlan`、`accept*(r: Reconciler, plan: ReconcilePlan)`；plan 内含 batch 和候选实体表。plan 可失败 / 丢弃但已分配 handle 不回收，accept 不执行外部代码。
- `checkCapabilities*(root: MountedNode, capabilities: BackendCapabilities, mode: CapabilityMode): seq[CapabilityIssue]` 返回允许降级的装饰诊断；缺失必需控件 / 布局或 strict 不支持属性直接 UiError。能力明确列出支持的属性与扩展枚举值，不能因为支持 justify 就默默支持 around / evenly。
- Backend 契约以同步 closure 字段表示 `prepare(batch)`、`apply(batch)`、`discardPrepared()`、`restore(acceptedEntities)`、`dispose()`；prepare 不改可见实体，restore 必须重挂载旧描述并重建监听身份。HostContext 提供 session ID、mount generation、逻辑内容尺寸、缩放；A1 不执行平台生命周期。

- [ ] Step 1: 写测试 `unchanged input keeps handle`（刷新无关文本，输入 create/remove 数为零）、`keyed reorder emits move`、`unkeyed nodes match position`、`type replacement recreates descendants`、`cross-parent move recreates entity`、`deleted identity never reuses handle`、`rejected plan leaves accepted map untouched`、`capabilities reject required features and strict decoration`。
  - 同父 reorder 保持 handles，且按批次逐项执行后的 sibling 顺序等于候选顺序；不能只断言 move 操作存在。
  - 父 column 改 row，后代 input 的字符串 ID 不变但 handle 必须改变；重复 key 已由 core 拒绝。
  - compatible 的 radius / background 不支持返回结构化问题；min_width / flex_shrink / around 等非装饰缺失必须拒绝。
- [ ] Step 2: `nim c -r --out:target/nim/test_native_reconcile tests/nim/test_native_reconcile.nim`；Expected: FAIL，新模块不存在。
- [ ] Step 3: 实现类型、能力检查与协调器。祖先替换使整棵后代视为新实体；删除按后序、创建按前序。对同父变序维护中间 sibling 顺序，生成可以顺序应用的索引，不把旧索引直接当新索引。不得用未经段解析的字符串前缀判断祖先关系（key 可以含斜杠）。
- [ ] Step 4: 运行新增测试和 Task 1 / 2 新增套件；Expected: 全部 PASS，无 callback 执行，无全量 JSON diff。
- [ ] Step 5: `git commit -m "feat: add native backend capabilities and incremental reconciliation"`。

### Task 4: 记录型 Backend、会话事件与 headless-only 隔离

**Files:** Create `src/leaf/backend_session.nim`, `src/leaf/backends/headless.nim`, `tests/nim/test_native_backend.nim`, `tests/nim/native_headless_probe.nim`; Modify `src/leaf/runner.nim`；更新 `docs/architecture.md` 说明 A1 的已完成范围（仅实际通过测试后填写）。

**Interfaces:**
- Consumes: Task 1 typed props；Task 2 committer；Task 3 contract / reconciler。
- Produces: `newRecordingBackend*(capabilities: BackendCapabilities): RecordingBackend`（提供 Backend、实体表、操作历史、create/update/move/remove 计数及失败注入）；`attachBackend*(runtime: Runtime, backend: Backend, host: HostContext, mode = compatible): BackendSession`；`dispose*(session: BackendSession)`。
- `EventEnvelope` 含 session、mount generation、handle、sequence、observed revision、Event；`enqueue*(session: BackendSession, envelope: EventEnvelope): bool`；`drainEvents*(session: BackendSession)`；`requestRows*(session: BackendSession, listHandle: NodeHandle, sourceGeneration: uint64, first, finish: int, protected: seq[int] = @[])`。
- enqueue 拒绝错误会话 / 挂载代际、失效 handle、已处理 sequence、未来 revision；不因旧 observed revision 单独拒绝。每次实际处理重新检查实体、最新 handler 与 disabled。sequence 必须单调，提交中排队真实用户事件，Backend setter 通知由源头标记并抑制，不当作用户输入。
- prepare 失败时丢弃候选资源，保持原实体；apply 失败时冻结事件并 restore 旧 accepted 实体；restore 成功增加 mount generation，使旧原生监听通知失效；恢复失败进入明确 faulted 状态，并锁住关联 Runtime 的业务 dispatch。Runtime 提供独立于 inUpdate 的事件冻结状态及明确错误，不以永久卡住重入 guard 实现冻结。初次挂载失败释放已准备资源，不安装会话。dispose 释放资源 / 队列，幂等，不能放任旧事件继续访问 Runtime。
- requestRows 验证列表 handle 和 source generation 后调用 Runtime.materialize；只协调可见行，不 render 全应用。source 换代后，preparer 按 item key 恢复已记录视口（借鉴 gpui_bridge），不得把旧行号回调绑给新项。
- `-d:leafHeadlessOnly` 时 runner 不 import desktop；无参数只提示使用 --headless / --check 并返回非零，明确请求窗口不静默降级。正常编译的默认 GPUI 行为不变。

- [ ] Step 1: 写记录后端测试：
  - `stable input unrelated update creates no entities`：模拟输入选择范围为后端临时状态，刷新其他文本后 handle 与临时状态不变；此项不声称验证原生 IME。
  - `prepare rejection publishes nothing`、`partial apply restores accepted tree`、`failed restore blocks events`、`setter notifications never recurse`、`queued events are revalidated`、`old revision listener remains usable`、`removed handle event is rejected`、`dispose invalidates session`。
  - `100000 rows mount only viewport`：初次行构建为零，请求 20 行只构建 20 行，实体数由 root/list/可见行决定；继续滚动仍受缓存预算约束。
  - `reordered source follows item keys`、`failed row commit keeps accepted callbacks`、`obsolete source generation is rejected`。
  - `capability warning emitted once`：同一 session、node ID、property 重复 refresh 不重复记录结构化装饰问题，新的挂载 session 可以重新报告。
  - 编译探针 `import leaf`，定义一个 Nim 按钮并执行 headless change/click；不得在生成 C 或动态依赖中出现 GPUI / Vulkan 符号或库。
- [ ] Step 2: `nim c -r --out:target/nim/test_native_backend tests/nim/test_native_backend.nim`；Expected: FAIL，RecordingBackend / BackendSession 不存在。
- [ ] Step 3: 实现提交适配与记录实体执行器；重放 batch 验证真实中间状态，不只记录“计划被调用”。记录 Backend 不加载图形工具包。把 UI 队列与通知抑制约束集中在 session，不削弱 core 的重入 guard。
- [ ] Step 4: `nim c -r --out:target/nim/test_native_backend tests/nim/test_native_backend.nim`；Expected: PASS。
- [ ] Step 5: `nim c -d:leafHeadlessOnly --out:target/nim/native_headless_probe tests/nim/native_headless_probe.nim`；执行探针 `--headless` / `--check` / 无参数，并用 `ldd target/nim/native_headless_probe` 及生成 C 导入检查确认隔离；Expected: headless/check 成功，无参数明确拒绝窗口，依赖不含 GPUI / Vulkan。
- [ ] Step 6: `nim c -r --out:target/nim/test_runner scripts/test.nim`；Expected: 所有现有和新增 Nim / release 套件 PASS。若环境缺外部依赖，报告具体失败，不减少套件来声称全通过。A1 不要求 cargo 测试（Rust 无修改），也不声称执行了 Windows / Android 原生测试。
- [ ] Step 7: `git commit -m "feat: verify native backend sessions with a recording host"`。

## 最终验收与交付

- [ ] 主 Agent 检查计划接口一致性、所有 RED→GREEN 记录和偏离裁定。
- [ ] 「方案设计，架构思考」独立检查完整 diff，执行新增测试及必要现有回归；普通问题交还「日常工作」修复，复验，疑难才使用「高消耗工作」。
- [ ] 确认无 main 改动、无默认 GPUI 切换、无半成品 native CLI 宣称；记录实际测试命令、结果和未执行的平台测试。
- [ ] 交付 A1 分支、提交与验收报告，不自动 merge / push；下一步为 A2 详细计划。

## 计划自审记录

- 本批实现总体草案 §3 / §5 / §6 / §7 / §9 / §15 中公共边界的一部分，及 §13 的 headless-only 隔离；不是完整总体架构实现。
- 输入法 / composition (§8)、导航历史 (§10)、移动生命周期与 SQLite (§11)、Canvas (§12)、native build / SDK (§13) 均未列为 A1 完成条件，后续 A2 / A3 / B 必须分别制定可运行计划与原生验收证据。
- 四任务顺序依赖：公共 props → Runtime commit gate → Backend 协调协议 → 会话与记录后端；类型和签名在各自 Interfaces 块定义，最后任务不依赖未实现节点。
- Review Focus 五项均有归属测试；原生错误恢复仅由记录 Backend 注入验证，不等价于 Win32 setter / Direct2D / Android 重建实测。
