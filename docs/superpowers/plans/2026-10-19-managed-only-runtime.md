# 单一托管运行时与内存收敛实施计划

> 执行方式：按用户已确认的 Paseo 协作约定，由复杂编码角色串行实现和自测，功能验收角色独立验证，原会话核对实际 diff/证据；不另问执行方式，不调用原生 subagent 替代 Paseo。读本计划及设计后执行，同功能复用当前空间与各角色 Agent Tab。未经授权不提交/合并/推送。

**Goal:** 只保留托管组件运行时和类型化增量主更新路径，完整迁移默认应用与工具，消除按最大节点数预分配的固定内存开销。

**Architecture:** 唯一 managed driver＋GPUI ABI2/Win32 增量消费者；显式 JSON Snapshot 只作诊断/headless。内部小容量 CommitMap 在 prepare 准备桶、owned delta 和退役槽，发布只 move/swap，整体接受后清理；不每次复制全表。

**Tech Stack:** Nim 2.2.6/ORC/threads:on，C ABI2，Rust/GPUI，Win32，现有 SQLite/Model/CLI 工具。

**Spec:** `docs/superpowers/specs/2026-10-19-managed-only-runtime-design.md`

## Global Constraints

- 基线 `53dad6325d193fced8d5a7226ced39db9e5ffeae`，当前 `/home/jimxl/projects/leaf`、`main`、`.git/index`；非并行功能，Workspace `wks_b4cfd9300404f8ee`。派发核实身份后只有一个产品写入端。
- 旧模式不再兼容。不可把旧 render 包在一个总根组件中保留并行运行时，或保留 ABI1 fallback。保留 Node/widgets 纯描述构建、GPUI/Win32 后端和诊断/headless JSON。
- 保留现有节点/深度/字符串/逻辑预算与任务/路由/IME/事件代数契约；真实 OOM 沿用 Nim fail-stop，不引入系统级 fallible allocator。
- publish/confirm 不新分配、不运行用户代码或析构、不因容量不足失败；prepare/普通异常可回滚，finish 在完整接受后且仍保持重入保护。
- 不改认证/权限、装系统依赖、启动新后台调度、不提交/合并/push/发布。保留历史证据，不 stash/reset 或搬移他人改动。
- 全量回归只在稳定快照执行；阶段先测影响范围。旧模式专属case可删除但须列清单，当前行为须有替代覆盖，不能删失败断言凑全绿。

## Review Focus

1. 动态字符串 ID/key/title 与嵌套集合在桶未增长时仍复制分配；字面量探针不能覆盖。
2. apply 后 State/模型/闭包/ORC 的隐式析构或根缓冲区增长会破坏原子发布，需要退役与直接分配计数。
3. 候选 viewport 扩展、安装延迟 confirm、foreign/stale/重复候选不能使用旧 prepared patch。
4. 脚手架生成代码与数据库 executionScope/导航/页内State不能被根包装迁移掩盖，必须实际编译驱动。
5. Windows 当前源码和GPUI库身份/前台条件不能由历史SDK、CPU基准或内部树快照替代；环境缺口是阻塞不是通过。

## 阶段 1：内存容器与原子发布（第一个可验收切片，r3独立验收通过）

**Files:** 新增 `src/leaf/commit_map.nim`、`tests/nim/test_commit_map.nim`、`tests/nim/test_component_commit_memory.nim`；修改 `core.nim` driver清理接点、`host_reconcile.nim`、`managed_runtime.nim`、`component_state.nim`、`task_service.nim`，以及实际发布路径需要的 `host_session.nim`/`backend_session.nim`/Win32 acceptedDelta。现有外部API和旧模式在这个中间切片暂不拆，阶段完成不代表总任务完成。

**Internal interfaces:** 最终命名允许与本模块现有类型风格一致，但以下职责和语义不变：

- `CommitMap[K,V]`：本地实例拥有的内部容器，K限定已使用的string/uint64/NodeHandle等框架键，不运行应用提供的hash/equality；无全局注册表。
- `CommitEntry[K,V]` 与 `PreparedMapPatch[K,V]` 拥有新键值和预备退役槽；`preparePatch(map, removals, ownedUpserts, limit)` 校验重复/限额/溢出、按阈值准备容量；`validatePrepared(map,patch)` 校验身份/代数；`publishPrepared(map,patch)` move/swap；`finishPublished(patch)` 完整接受后清理；`discardPrepared(patch)` 拒绝时清理，不改已接受内容。
- RuntimeDriver 增加相应已接受后清理职责，普通commit与延迟安装confirm都在 revision/State/host 全部接受后调用；clear/reject 不触发业务重放。若现有 seam 需要不同准确签名，在首次代码报告列出并保持调用点一致，不自行改变公开生命周期合同。
- key唯一性用 `KeySummary(count:int,xorId:uint64)`，只在 count=1 返回xorId，其他仍拒绝歧义；不需要每key一个HashSet。

- [ ] 写容器失败测试：空表容量0；首次最小8桶；跨装载阈值prepare增长；无增长patch只与Δ有关；动态string键插入/替换/删除、碰撞链、重复键拒绝、极限预算/溢出拒绝、foreign/stale/重复发布拒绝、discard后accepted内容完全一致。
- [ ] 在旧实现可探测点复现RED：空reconciler堆9,355,456B、动态host publish有1alloc、managed局部publish有3alloc、State owner释放有1alloc（小探针见 `target/verification/managed-only-design/`，仅基线，不把数值写成跨平台必等值）。正式测试以行为/边界为断言。
- [ ] 实现窄用途CommitMap。空表惰性；`S(P)=nextPowerOfTwo(max(8,P+P div 2+4))`，先删后加容量peak=max(L,F)，检查算术；跨阈值才O(N)重建，暂不加自动缩容；不能依赖标准Table私有布局或只改initialSize。
- [ ] 接入HostReconciler和ManagedStore的accepted表；避免纯文本更新删除/重插未变ID。keys摘要在prepare按旧/新活动宿主恰好一次扣减/增加，测试歧义→唯一→删除、重复key同批移动、inactive/retained页面不误计。
- [ ] 接入task owners、State owner卸载和候选/accepted值swap；审计rows/retained registry按实例patch。旧内容延迟释放，不能在publish中调用用户析构；new State在准备期创建，拒绝disposed且ID不复用。
- [ ] 形成sealed PreparedCommit；viewport再改递增editEpoch并重备；外部apply前校验，安装confirm复用，容量阈值下prepare/backend prepare/apply故障回滚，跨Runtime/迟到候选拒绝。
- [ ] 测直接分配计数0：冷/热/阈值、动态ID/key/title、State-only/零host ops、卸载、路由/列表/安装confirm；带析构计数器证明仅整体接受后清理。Nim ORC根缓冲增长和后端acceptedDelta若仍分配须定位，不预热规避。
- [ ] 定向回归并保存命令/exit/hash：容器、状态、组件、host_reconcile、host_session、backend_session、路由、列表、生命周期、任务/关闭。先发现实际现有测试文件名，不猜一个不存在suite成功。
- [ ] 在同旧组件benchmark业务下跑100/1000/5000，与冻结managed第三种基线比存活heap/RSS/peak/P50/P95/alloc；分别记录首次增长和稳态。小场景存活堆应明确下降，非阈值操作不扫描静态规模。整个事件不要求0alloc。
- [ ] 阶段报告含文件/diff摘要、内容hash、全部失败断言、已验证/未验证、实际命令/退出码、内存拆分/风险。**完成阶段1后停止写入，交回原会话组织独立验收；不要自行进入阶段2或声称重构完成。** 普通缺陷仍交本执行端修复。

## 阶段 2：唯一组件Runtime与消费者（与阶段3/4整合代码项已独立验收通过）

依赖阶段1验收，继续复用原复杂编码Agent与空间，不新建执行端。

**Files:** `core.nim`、`components.nim`、`src/leaf.nim`、`routing.nim`、`component_routing.nim`、`headless.nim`、`host_session.nim`、`gpui_session.nim`、`backend_session.nim`、Win32 backend和相关tests。

- [ ] 负向测试固定仅render的Application不再可构建或newRuntime明确拒绝；有效componentApplication是唯一入口，单纯切换ABI不能满足。
- [ ] 删除旧RenderProc/BuildContext Runtime缓存/RowCache/refreshImpl/materializeInto/旧索引和driver=nil执行分支。保留Node/ListSource/MountedNode/Snapshot等仍供组件与显式导出使用的纯数据和构建，不为删名破坏其用途。
- [ ] 明确Application必须有托管factory；公开导出唯一组件API，清理“opt-in”说明。refresh作为显式forceRoot仍走托管driver，不是旧路径。
- [ ] 路由仅保留组件router与Route纯配置；所有State/任务/cleanupOwner/accepted-scope错误移交/committer/preparer owner契约保持。删除planSnapshot在主提交中的适配分支；初次fullBatch同步仍可保留，不算普通整树更新。
- [ ] 将被移除模式的tests逐一列清，迁移仍有效的行为断言，补headless快照只按请求导出、局部更新不导出、no-op不增revision。不能大面积disable。

## 阶段 3：GPUI ABI2唯一协议与Rust宿主（代码项已独立验收通过）

**Files:** `gpui_api.nim`、`desktop.nim`、`gpui_session.nim`、`gpui_bridge.nim`和对应C夹具；`crates/leaf-gpui/src/{lib,bridge,desktop,bridge_v2,host_view,model}.rs`及ABI/窗口测试；`include/leaf_gpui_v2.h`按实际需要。

- [ ] 加ABI2缺入口/错大小/错版本/无必需能力的loader失败测试，删除ABI1必需run符号；仅ABI1库不fallback。
- [ ] 以query_v2为唯一加载合同，不通过要求ABI1入口来判断有效；环境LEAF_GPUI_ABI若保留只允许unset/auto/2指向同一路径，1明确报已移除，不悄悄忽略。
- [ ] 删除Rust legacy JSON桌面入口/Bridge/Desktop/Snapshot主更新实现及活跃导出；共用错误/诊断/probe代码先迁移再删，不保留未调用的整套老引擎。
- [ ] typed task泵、frame/渲染诊断、watch外部状态、输入选区/IME代数、list viewport/finish/protected row契约保留。C/Nim/Rust布局和callback验证跟随当前协议，不通过旧ABI1兼容入口来通过布局测试。
- [ ] launcher/夹具按每种输入一次构建、独立临时路径，不重复覆盖已加载模块；这是新协议夹具正确性，不扩大到用户暂缓的前台抢焦点修复。

## 阶段 4：默认应用、模板、样例和工具完整迁移（D-R4修复后代码项已独立验收通过）

**Files:** `templates/`、`scaffold*.nim`、`examples/`、`example/`、`tests/nim/`、`tests/windows/`、`tests/release/`、`benchmarks/`、`scripts/`、`.github/workflows/ci.yml`及其他实际引用模式的workflow。

- [ ] init默认计数器使用State；scaffold shell/导航/页面使用ComponentRouter与outlet；home与生成resource页面局部State驱动，registry改成ComponentPageDefinition，保留数据库上下文与事务失败/重开行为。
- [ ] 普通/model scaffold、g新增resource、真实业务例、native_forms、SDK示例、native/发布fixture实际迁移；原业务和稳定测试key保持，页面保留/销毁和在途任务关闭继续测试。
- [ ] view DSL可在组件内通过componentView/host构建，不能以全局mutable render＋每事件forceRoot作为迁移终点；只读静态案例不必为每个标签强行拆一个组件。
- [ ] benchmarks只保留managed执行模式；冻结旧JSON作为历史对照，不为了比较再次带回旧运行时。性能schema兼容按工具实际需要清楚升级/拒绝，仍保留原始样本、checks与身份。
- [ ] CI/native脚本只测托管＋ABI2×cache0/1；不扩大安装/权限。CLI watch/pack/doctor、源码/SDK路径含空格/中文/$等现有发布边界保留。
- [ ] 逐个修复迁移后测试，先受影响再全量；未稳定前不重复跑整套。不得删除系统重绘/IME/错误链测试来规避移植困难。

## 阶段 5：最终回归、窗口、内存证据及交付（代码/CPU证据通过，Linux真实GUI待环境授权）

- [ ] 用 `/tmp/nim-2.2.6/bin/nim` 和现有工具执行官方 `scripts/test.nim`（普通、release），Rust workspace locked tests、fmt及受影响lint，ABI布局；保留完整日志和exit。
- [ ] 定向真实生成/编译/headless/CRUD数据库重开、生成模型和资源、watch/pack/SDK smoke，记录实际产物身份，不发布SDK。
- [ ] 图形子进程仅使用已有 `/tmp/mui-display/usr/bin/{Xvfb,xdotool}` 与相应动态库，先确认依赖，不安装系统工具。新typed库单独路径/hash，native任务/路由/输入/列表 cache0/1实际运行并正常关闭。
- [ ] Windows使用已有持久环境，核对当前源码/库/EXE。控制器固定旧归档不能冒充新输入；需要完整当前源码时按现有安全入口准备新目录。记录前台受阻/像素未测；不要用内部树替代自然态视觉结果。
- [ ] 按同业务同机器同编译参数重复100/1000/5000内存/latency及冷启动/增长/挂卸/retained页面/暖行释放检查，报告存活heap、RSS、峰值和ORC保留差异，不承诺全平台零泄漏。
- [ ] 静态清点无活跃legacy模式/ABI1 fallback、旧router、旧默认模板，保留日期化历史记录。当前README/开发/API/脚手架/性能说明同步。
- [ ] 更新 `docs/progress.md` 同任务阶段、修复轮次、命令/快照/实际模型与已知成本（未知分列），不扫描全量会话账单或新建后台服务。新验证证据放 `target/verification/managed-only-runtime/`。
- [ ] 开发者完成自测后停止写入，返回准确快照、diff、验证日志、遗留/阻塞和测试移除/替代清单。原会话读实际diff→功能验收角色只读独立验收→缺陷回原开发者修复并聚焦复验→原会话最终交付。

## 失败与停止条件

权限/认证/工具/环境故障报告真实错误，不换模型绕过；模型不存在不冒充额度耗尽。普通缺陷同类两轮仍不收敛，第三次同策略前交最小复现、已改/未完/差异，原会话判断诊断或实现升级。阶段等待超时不触发重新派发/全量重测。

出现发布分配/析构、候选/安装confirm身份契约不明、需要提高节点/预算、功能丢失或对外行为新增产品取舍时先报告。只有系统OOM恢复、全新平台能力、共享发布、依赖安装等超授权边界需用户决策；既定迁移/普通修复/阶段验收由原会话继续推进，不反复要求用户批准文稿。
