# 开发进度与下一步

验收记录日期：2026-10-18。固定代码与 CI 基线：`c207e48af8b33b8e6ecaf4dc1548ec9b2541b737`；本批后续文档、测试及 Win32 重绘修复不包含在该基线提交中。Windows 验证使用该归档加逐文件固定 overlay SHA；下列旧基线 CI 成功不代表后续修复的 CI。后续提交、推送及 CI 状态以实际 Git 历史与对应 head SHA 的运行记录为准。

本页汇总当前状态；日期化的计划、审查和验证记录保留当时输入、失败与限制，不能将其中早期“尚未合并”的描述当作当前 Git 状态。没有实机证据的平台不列为已验收。

## 进行中：单一托管运行时与内存收敛（2026-10-19）

用户已授权只保留托管组件＋类型化增量更新，删除旧整树/ABI1桌面 fallback，迁移模板、示例、工具及测试，并优化内存；不是仅切换默认 ABI。保留 GPUI/Win32 后端及诊断/headless JSON，不扩展平台能力；用户随后明确授权“提交代码，Push到GitHub”；按此授权提交当前分支并推送其真实远端，跟进对应Actions。不额外执行手工SDK发布、PR、合并或部署。

### 当前结论（本任务未提交快照）

- **阶段1内存切片、阶段2-4唯一模式迁移的代码项均通过独立验收**；D-R4生成页ref回调泄漏已关闭，无新增代码阻断。最终复验报告：`target/verification/managed-only-runtime/final-review/review-r1/functional-review.md`，原会话已核对实际diff、32项输入hash与覆盖。
- **整体验收仍受阻／未完成**：Linux真实GPUI窗口缺xkbcomp/xkeyboard-config，临时工具授权待答；不重复催问、不安装/下载、不中断其他已授权独立工作。真实系统IME/DPI/GPU等旧平台门未被本次代码测试关闭。
- 稳定最终快照：官方102个Nim套件实跑exit0，Rust本包30测试/fmt/clippy与ABI161有通过证据；当前源码Windows tag `stage24fix2-1019-074945` 八套97/0/0、accept六窗口0。验收者独立执行代表套件、真实生成页拒绝/重试/DB重开与批处理隔离，其余全量/Windows为日志与输入身份复核，不称独立全量重跑。
- 验收者独立CPU基准100/1000/5000（各600样本）：P50约0.0146–0.0149ms，133 alloc/事件，普通局部更新render/visited/normalized/indexEdits/ops均1、Snapshot0；GC后存活Nim堆713,424 / 6,072,544 / 29,199,584B。原managed基线相应18,548,528 / 23,240,032 / 44,069,216B。仅Runtime+编码，不代表窗口帧率/GPU或长期零泄漏。
- 原开发者与验收者均已停止写入；用户现已授权把本轮已验收代码提交当前main并push到origin/main（SatoriTours/Leaf），远端此前与本地基线一致。该次提交/远端状态与新Actions结论以Git及原会话最终回报为准，不复用旧CI；仓库既有push触发SDK工作流不等于本会话另行手工发布。成本各项仍未知。

### 过程记录（历史轮次，当前状态以上述结论为准）

- 基线：`53dad6325d193fced8d5a7226ced39db9e5ffeae`；当前安全空间串行推进。方案见[单一运行时设计](superpowers/specs/2026-10-19-managed-only-runtime-design.md)。本任务尚未完成实现与独立验收，不能用下面历史 CI/窗口成功证明本轮通过。
- 当前阶段：迁移设计及[实施计划](superpowers/plans/2026-10-19-managed-only-runtime.md)已完成；只读设计角色实测空HostReconciler约9.36MB、单组件Runtime约17.96MB，发现动态字符串/嵌套集合/owner序列导致现有publish仍分配。采用内部CommitMap的prepare按需增长、move/swap发布、完整接受后退役清理及key唯一性摘要。复杂编码角色已提交阶段1自测报告并停止写入；原会话已读实际diff，未接受“阶段1通过”结论：native consumer accept仍分配、backend_session/Win32固定大表缺口属于当前内存切片，不自动延期。功能验收r0结论为不通过：实测D1同键remove+upsert限额绕过、D2/D3空/no-op patch无谓分配/扩容、D4同owner/代数的外来map patch可被接受并静默丢值，另有native accept分配和后端固定表缺口。原复杂编码端修复r1已结束并停止写入；原验收角色r1聚焦复验已确认D1-D4、正常consumer路径、固定大表、keyDeltas和epoch均关闭；仍不通过N1新增capability诊断accept实测5次分配、N2原生编辑值同路径实测3次分配。原开发者集中修复r2已自测提交并停止写入：新增prepare/accept/discard诊断接点与PreparedModelAccept，报告当前源码Windows tag r2-1019-015953为8套97/0/0、6个accept窗口计数0；原验收者r2复验确认生产accept分配0及N2关闭，但新增R1诊断可见性缺陷：prepare预留issues长度被公共getter当已接受列表暴露，apply窗口实测默认占位项、失败后消失。原会话已暂停第三轮同策略并完成根因裁定：原分配根因闭合，剩余是新增的物理容量/已接受逻辑视图混淆；采取明确accepted长度/前缀的定向修复r3，仅backend_session与对应正式测试修改，r3原验收者独立重编译/复跑已通过getter窗口/rollback与accept0alloc；阶段1内存切片通过，原会话核对当前diff、2/2hash及覆盖后继续阶段2-4唯一Runtime/ABI2/模板示例迁移，不重复既有内存验收。阶段2-4首轮开发自测报告已提交，但原会话实查未接受迁移完成：src/core/routing保留leafTestFixtures旧引擎且普通/Windows测试全局启用；模板/样例普遍普通变量+revision根失效包装。定向counter候选拒绝探针实测下一次接受count=2（应1，exit1），证明未迁移UI State的回滚缺陷。阶段2-4修复r1已自测提交：已删除旧引擎与全局fixture define、根revision包装，counter真实State拒绝探针GREEN，官方101套无旧模式；原验收者整体验收r0确认唯一模式/ABI2、fixture边界、生成编译与内存终证，但不通过D-R4：ref-State渲染副本被回调捕获修改，拒绝后State cell虽回滚、下一事件仍继承副本（计数3而非2/草稿泄漏，probe exit1）。原开发者已统一修复模板/生成resource/gallery同一根因（阶段2-4累计修复r2），动作从State.update的current构造candidate，不改Runtime拒绝时重绘。已自测102套/当前源码Windows97项，原验收者整体验收r1已确认D-R4 ADDRESSED、代码项通过；其余不变证据复用，不用重建accepted树掩盖。GUI仍因待授权工具受阻，未重复催问；阶段5GUI必需项未完成。
- 新增环境待答（仅此新增边界，不重复确认重构）：Linux真实GPUI窗口缺xkbcomp/xkeyboard-config，现有Xvfb报硬路径/usr/bin/xkbcomp不存在；主控询问是否允许仅临时目录补齐、不改系统安装/全局配置。未答前不安装/下载，其他独立验收继续；后续通知不重复催问。
- 性能基线：`target/verification/performance-analysis-53dad63/`，Nim 2.2.6 Release/ORC、Linux，managed 100/1000/5000 静态兄弟的局部更新 median 约 0.014ms、118 次分配；GC 后 managed-100 堆 17.69MiB/RSS22.10MiB，managed-5000 堆42.03MiB/RSS120.34MiB。不含 Windows/GPU/帧耗时。
- 记账：任务族为“架构收敛”，新增需求，不与旧 Windows 失败混计；独立验收r0不通过，验收缺陷修复r1已复验，原容器问题关闭、accept分配未全收敛；修复r2已复验；同目标累计两轮已触发暂停判断。Ruling：原会话依据review-r2/R1最小复现与backend_session:70/90源码完成根因诊断，原分配缺陷已关闭、新缺陷为预留长度提前公开；改用接受视图分离策略作定向r3，不同策略盲重试、不重置轮次。现有复杂编码端已落实r3并独立验收通过，继续复用该执行端做阶段2-4；无证据需要另派疑难角色；若判断错误会导致准备期仍泄漏诊断或回滚查询不一致，必须由正式测试和独立复验阻断。设计角色a3a4aa7d（pi/openai-codex/gpt-6.1-sol）已结束；复杂编码75cc1b70（pi/deepseek/deepseek-flash）因实现复杂度选用、不是额度替补；验收f32bcc2c（pi/opencode-go/glm-5.3-flash）r3已结束停写、结论“通过（仅阶段1）”，报告review-r3/functional-review.md；r1 N2的3次分配原探针包含动态构造，验收已更正为预构值本身0，旧报告/探针保留，不能用旧画像触发额外修复；r0报告`target/verification/managed-only-runtime/stage1/review/functional-review.md`，r1新增diff/hash/复验结果归档`target/verification/managed-only-runtime/stage1/review-r1/`。各阶段非缓存输入、缓存输入、输出及估价目前未知；不以未知或零价表示免费。
- 阶段1 r3 修复完成，待独立聚焦复验：r2 复验判定 N2/正常 accept 分配闭合，仅余修复引入的未接受诊断占位可见（R1）。按原会话根因诊断采用“已接受逻辑视图/物理预留分离”：新增 acceptedIssueCount，capabilityIssues 只返回 accepted 前缀（pending 时物化前缀 copy），prepare 只预留私有 pending、accept move+标量推进、discard 只退 pending。正式测试覆盖 0/非 0 初始、prepare/apply 窗口旧列表、失败回滚/重试、strict、accept 0alloc；fix3 R1 正向 probe all_ok，原始 r2 probe 保留历史 RED。Linux 正式+alloc+5 套回归 exit0；当前源码 Windows tag r3-1019-023036，8 套 97/0/0、accept 探针 6 窗口 0。证据 `target/verification/managed-only-runtime/stage1/fix3/`，报告第11节。全量/IME/DPI/像素仍阶段5。
- 阶段1 r2 修复完成，待独立聚焦复验：r1 复验仅余 N1（backend_session accept 内新 capability issue 追加 5 alloc）与 N2（Win32 acceptDelta→acceptModel 动态值 3 alloc）。N1 改为 HostConsumer prepare/accept/discard metadata 接点，去重键与槽位在 prepare 预备、accept 只 move、拒绝回滚；N2 新增 PreparedModelAccept + Win32 prepareModels，accept 只 move accepted/conflict。Linux 聚焦 15 套 exit0、3 套 alloc exit0、production probe all_ok；当前源码 Windows tag r2-1019-015953，8 套 97/0/0，Win32 accept 探针 6 窗口全 0。证据 `target/verification/managed-only-runtime/stage1/fix2/`，报告第10节。D1-D4/容器/keyDeltas/epoch 未改；全量/IME/DPI/像素仍阶段5。
- 阶段1 r1 修复（聚焦复验结论：D1-D4、正常consumer、fixed-map、keyDeltas、epoch 均 ADDRESSED；仅余 N1/N2，已由下条 r2 修复）：独立验收 r0 的 D1-D4（限额重叠计数、空/no-op 扩容、patch 实例身份、静默丢弃）已在 `commit_map` 修正并加正式跟踪测试；native consumer accept 改为 prepare 预备 patch/全量 metadata，accept 实测 0 alloc；`backend_session` 托管 accepted 表改为委托 consumer（attach 堆增量 87KB，旧固定表估算 22MB）；Win32 acceptedDelta 移除死 accepted 表；keyDeltas 加阈值索引（4000/8000 delta 26/96ms→6.8/6.7ms）；editEpoch 改为 apply 前 validate 拒绝。Linux 32 套 exit 0，review 原始 probe 全部 OK，当前源码 Windows 8 套 97/0/0。证据 `target/verification/managed-only-runtime/stage1/fix1/`，报告第9节。全量回归/IME/DPI/像素仍留阶段5。
- 阶段1（内存容器与原子发布）实现自测完成，尚未独立验收：新增内部 `CommitMap`/`KeySummary` 与 sealed patch，HostReconciler、ManagedStore、State owner/candidate、task owners 的 accepted 容器改为 prepare 扩容、publish 仅 move/swap、整体接受后 finish 退役；viewport 重备递增 editEpoch 并丢弃旧 patch。RED：新容器模块缺失无法编译；GREEN：容器 15 项与提交内存 11 项契约测试、定向回归 31 套全部通过（含 GPUI 桥接与 scaffold 子编译）。同旧 probe 对照：空 HostReconciler 9,355,456B→256B，单组件 Runtime 17,959,168B→17,280B；host/managed publish、State 卸载 publish 与 finish 直接分配均为0。同业务 managed 100/1000/5000：GC 后存活堆 18.55/23.24/44.07MB→0.71/6.07/29.20MB，RSS 22.6/43.0/123.2MB→5.9/23.3/94.1MB；同时段成对重跑安静样本中位延迟约 +4~7%（存在 chromium 背景负载，个别组噪声翻倍）；分配 118→133，均来自 prepare 的 sealed delta 构造，publish 窗口0。该条为 r0 历史快照：其中 native consumer accept 1 次分配、Win32 未验证和“通过”结论均已被独立验收否决并由 r1 修复/复测（见上条）；不得作为当前结论。r0 证据仍在 `target/verification/managed-only-runtime/stage1/`。本条仅保留r0历史阶段，当前阶段2-4已续接（见本节当前阶段），本切片不替代唯一模式迁移。


- 阶段2-4修复r2（D-R4 accepted ref 泄漏）完成，待同验收者复验：普通/model scaffold home、普通/model resource 生成器、gallery 全页动作改为页面 `model` + `State.update` current 构造 candidate，render 只读；保留历史 r4 坏模式 probe RED，正向 probe exit0，新增实际生成页拒绝/草稿/错误/panel 与 gallery dashboard/settings 隔离测试；官方102套exit0，逐文件failures=0，当前源码Windows tag stage24fix2-1019-074945 97/0/0，accept六窗口0；Linux真实窗口仍因缺xkbcomp阻塞。证据 `target/verification/managed-only-runtime/stages2-4/fix2/`，报告 R2 节。
- 阶段2-4 修复r1完成，待独立功能验收（阶段5未执行）：已删除生产与测试 define 下的旧 core/routing 引擎及 `leafTestFixtures`/`wrapEventHandlers`/`refreshApplication`，官方稳定快照101套exit0（旧103套fixture结果作废）；counter/模板/scaffold/示例/gallery改为真实组件State，拒绝候选probe exit0且下一次接受count=1，新增拒绝原子性/兄弟组件隔离断言；当前源码Windows tag stage24fix1-1019-062713 8套97/0/0 + accept六窗口0；Rust本包30测试/fmt/clippy/ABI161 exit0；Linux真实窗口仍因缺xkbcomp/xkeyboard-config阻塞。证据 `target/verification/managed-only-runtime/stages2-4/fix1/`，报告 `developer-report.md` R1节。阶段5正式全量/平台/视觉与性能复跑未完成，不得把本自测当验收通过。

## 已提交／发布基线的交付状态（不含本次未提交重构）

| 范围 | 实现与验收状态 |
| --- | --- |
| Nim UI、状态、事件、CLI、watch | 已实现，持续回归；默认桌面后端仍是 GPUI |
| SQLite Model、数据库迁移、CRUD 脚手架 | 已实现，当前提交的 Model 与迁移三平台 CI 成功 |
| 托管组件、State、ABI2 类型化增量宿主 | 已合入主分支；Linux 窗口及 Windows 任务示例 ABI1/2 已有证据，全平台矩阵未关闭 |
| 组件页面路由、保留/销毁策略 | Windows 任务示例的离开取消、隐藏继续和销毁重建已实测；完整路由输入矩阵、macOS、系统 IME 与跨屏 DPI 仍待验 |
| 组件任务与生命周期 | Task1–7 实现、最终修复和固定差异复核已完成，并已合并、推送；Win32 首轮失败已作测试修复，七套开发自测与独立复验均 96/0 通过，平台门仍未关闭 |
| Win32 原生表单 A2 | 标签重绘缺陷已修复；含新回归的八套开发自测及独立复验均 97/0，自然态文字完整，键盘/基础 UIA 通过；完整 H 门未完成 |
| GPUI SDK | Linux x86_64、Windows x86_64、macOS x86_64/aarch64 包及 SHA256 已发布；beta 指向当前代码基线 |
| 原生迁移 A3 | 原生虚拟列表、平台导航、Canvas/图表、完整纵向样例及 native 打包尚未完成 |
| Android B 与后续原生平台 | 尚未落地；不能由 GPUI 桌面 SDK 构建推断支持 |

代码边界：`src/leaf/backends/win32/capabilities.nim` 未声明 virtualList/scroll 能力；`src/leaf/pack.nim` 明确拒绝 native 打包；`src/leaf/targets.nim` 尚无 Android 构建目标。组件页面路由不等于原生导航栈，GPUI SDK 也不等于 native-only SDK。

## 当前提交的验证

2026-10-18 查询 GitHub，以下四个运行均为 completed/success，且 head SHA 与上述基线一致：

| 工作流 | 证据 |
| --- | --- |
| Nim + GPUI 构建与测试 | [39064572133](https://github.com/SatoriTours/Leaf/actions/runs/39064572133)：日志确认 102 个 Nim 套件通过，Rust 55 项通过 |
| Model 三平台回归 | [39064572131](https://github.com/SatoriTours/Leaf/actions/runs/39064572131) |
| 数据库迁移三平台回归 | [39064572140](https://github.com/SatoriTours/Leaf/actions/runs/39064572140) |
| Leaf SDK 发布 | [39064572160](https://github.com/SatoriTours/Leaf/actions/runs/39064572160)：四平台构建和 publish 成功 |

[滚动 beta](https://github.com/SatoriTours/Leaf/releases/tag/beta) 名称为 `Leaf beta.c207e48af8b3`，包含四个 SDK 包和四个校验文件。滚动 tag 后续可能变化；核对时同时使用上述固定提交与 CI 运行号。

同日 Linux 本地定向抽检（Nim 2.2.6、threads:on，不是本地全量重跑）：

| 套件 | 通过 | 跳过 |
| --- | ---: | ---: |
| `test_scaffold` | 18 | 0 |
| `test_migration_integration` | 22 | 0 |
| `test_component_task_shutdown` | 15 | 0 |
| `test_public_task_launchers` | 10 | 0 |
| `test_task_pump_compatibility` | 21 | 1 |

合计 86 项通过；唯一跳过项是未配置的可选真实旧库 integration。ABI2 C/Nim/Rust 布局 161 项与 `cargo fmt --all -- --check` 通过。该次 Linux 抽检未重跑本地全量、真实窗口矩阵或长期内存/硬件性能；后续 Windows 窗口补验另列下节，不混作同一运行。

本机 Nim 不在默认 PATH，使用已有 `/tmp/nim-2.2.6/bin/nim`。兼容性抽检首次无法加载桥接库；`ldd` 确认缺少 `libxkbcommon-x11.so.0`，仅为复测进程设置已有 `/tmp/mui-display/usr/lib` 为动态库目录后通过，没有安装系统软件或修改配置。这是本机环境记录，不是其他机器的路径约定；复现方法见[开发说明](development.md#本地工具链与动态依赖排查)。

## Windows 首轮补验（2026-10-18）

用户授权重建后，已在 worktree 外的持久目录安装 Windows 11 Enterprise Evaluation，验证 SSH、Nim 2.2.6、MinGW GCC 11.1.0/windres 2.36.1，启用 guest UAC 并重启。源码归档内 523 个常规文件经 Windows SHA256 复核，0 个不匹配。

官方 Win32 runner 在 Session 1、elevated=false 下实际运行：编译退出 0，运行退出 1，合计 **12 OK / 4 FAILED / 0 SKIPPED**。`test_component_host` 通过，`test_component_tasks` 失败后 runner 停止，其余五套此次未运行。失败涉及 hook 注入未命中、销毁计数、缺尺寸的测试夹具及带 UI guard 的错误消息断言；未修改产品或测试源码。完整环境、四项失败与日志位置见[Windows 持久环境与首轮结果](windows-environment.md)。该首轮失败不能由 CI 绿色替代或抹去。

后续只修复同一测试文件的观察边界、故障对象、尺寸夹具和异常链断言，Runtime/Host 实现未改。固定 c207e48 基线加测试 overlay 的真实 Windows 七套开发自测为 **96 OK / 0 FAILED / 0 SKIPPED**，Session 1/elevated=false；Linux 相关回归 31 项通过。相同测试 SHA 的独立功能复验也完整执行七套，96/0/0、compile/run=0/0，结论为“通过（仅本批修复）”；原会话已核对实际 diff、原始结果和覆盖边界。独立 Windows 日志位于持久根目录的 `shared/evidence/task-fixes-review/`，详见上述环境记录；Linux 31 项是开发者实跑、验收者日志复核，不称作独立重跑。H 门仍未关闭。

## Windows 真实窗口续验（2026-10-18）

复用同一 VM 和固定版本 SDK，Session 1/elevated=false，实际执行 GPUI ABI1/ABI2 的任务窗口：无后续点击自动完成、错误重试、离开取消、隐藏继续、销毁重建、Tab/Shift+Tab/Space 及在途关闭均通过，两个进程均退出 0。native_forms 的编辑、Enter 单次提交、Tab/Space 和基础 UIA 角色/值也通过；初始 UIA 代理缺失和跨进程旧 caption 读值的问题已纠正并保留原证据；该次初始窗口补验未修改产品实现。

**修复前原生视觉项曾不通过**：模型/EDIT/UIA 值正确，但自然完成态标签缺字，静置 2 秒不恢复，resize 才完整显示。该失败和原图均保留；随后定位到文本更新没有稳定触发完整客户区重绘，以三个 Win32 文件中的局部 InvalidateRect 修复，保持输入/模型契约不变。

新屏幕像素回归在旧源码上实际 RED（空洞 72px、像素差 348），当前实现 GREEN；新增回归令原七套变为 **八套，97 OK/0 FAILED/0 SKIPPED**。开发自测与独立功能验收各实际完整运行，均 compile/run=0/0、Session 1/elevated=false。独立修改源重建的 native_forms 原键盘路径 17 项检查符合预期，文字无需 resize 已完整；验收者与原会话实际查看该次自然态原图。完整输入、命令、证据与范围见[Windows 真实窗口补验](windows-window-validation.md)。独立结论为“通过（仅本批重绘修复）”，不批准整个 A2/H 门。

当前只配置 en-US/US keyboard，中日文基本语言组件均 NotPresent；真实 IME 未执行。仅实测 96 DPI，没有物理混合双屏证据。基础 UIA/键盘不等于完整辅助技术 H 门，全量通用回归及其他未执行项仍开放。

## 下一批执行顺序

| 阶段 | 当前状态 | 交付与验收出口 |
| --- | --- | --- |
| P0 状态同步与复现说明 | 本批文档已更新 | 当前摘要链接到固定代码/CI；历史证据保留；本地依赖排查和 Windows 步骤可查 |
| P1 Windows 平台验收 | 八套97/0与重绘修复独立验收通过；GPUI ABI1/2本批任务窗口通过 | 继续补适用通用回归、真实 IME、不同 DPI 双屏和完整辅助功能 H 门，未执行项不关闭 |
| P2 原生 A3 | 待逐项设计 | 顺序推进虚拟列表、平台导航、Canvas/图表、native 打包；每项独立验收，最终完成带数据库的编辑/滚动/返回/移机运行纵向样例 |
| P3 Android 最小贯通 | 待前置公共边界稳定 | 通用宿主/JNI、表单、资源与 SQLite，真机验证保存重开、中文输入及旋转恢复；再扩展列表和生命周期 |

环境沿革：旧容器因 worktree 下挂载源缺失、storage 仅余 12K 缓存而启动失败，原排查记录保留在 `target/verification/progress-sync-2026-10-18.mz2K3B/windows-start-investigation.md`。用户随后明确授权重建；新 `leaf-a2-windows` 已运行，磁盘位于 `/home/jimxl/.local/share/leaf/windows-acceptance/storage`，旧容器改名保留，未删除原记录。网页控制台只绑定宿主机 `127.0.0.1:18006`，没有创建/切换 Workspace、提交推送或触发远程 CI。此后继续使用该持久环境，不重复安装。普通桌面账户矩阵/真实 IME/双屏/辅助功能证据不全的项仍保持未验收，不能由 VM 自动化或 CI 绿色替代。

本轮在 Linux 实际编译 `scripts/test_win32.nim` 退出 0，直接运行所得二进制退出 2 并输出 NotRun；这是非 Windows 拒绝路径通过，不是 Windows 套件通过。编译、运行日志和退出码保存在 `target/verification/progress-sync-2026-10-18.mz2K3B/`。最初没有 PowerShell/Windows 时只静态核对了示范步骤；随后按授权重建并执行了上面记录的实际 Win32 路径，未声称逐字执行了全部示范命令。文档范围、链接、锚点与格式检查另行执行，不重跑无关全量测试。

相关依据：[异步生命周期合并验收](superpowers/reviews/2026-10-17-component-async-lifecycle-local-merge-verification.md)、[Win32 范围与 H 门](native-win32-validation.md)、[原生迁移总体设计](superpowers/specs/2026-10-07-native-controls-design.md)。本批不扩展产品功能；提交与推送仅按用户明确授权执行，不扩大到平台验收或额外部署。
