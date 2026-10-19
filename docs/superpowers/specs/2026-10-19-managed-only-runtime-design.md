# 单一托管运行时与内存收敛设计

## 需求、授权与基线

用户在性能分析后明确要求：只保留“托管组件＋类型化增量协议”，执行一次重构，并优化内存占用。不再以兼容旧应用/旧 GPUI 库为保留另两套执行模式的理由。初始重构授权不包含提交、合并、推送、发布、系统依赖安装或扩大平台支持。后续用户明确要求“提交代码，Push到GitHub”，因此仅追加当前任务commit/push及对应CI收尾授权，不追加手工发布、依赖安装或平台支持。

代码基线为 `53dad6325d193fced8d5a7226ced39db9e5ffeae`。本任务开始时当前 `/home/jimxl/projects/leaf`、`main`、`.git/index` 干净；这是一个功能的串行重构，优先复用当前 Workspace `wks_b4cfd9300404f8ee`，不创建额外空间或并行写同组文件。原会话协调、复核实际 diff 与交付；内存设计角色只读分析，复杂编码角色实现和自测，功能验收角色在同功能空间只读独立验收。角色来源为派发时最新 Paseo profiles，不硬编码路由。

### 已有实测

`target/verification/performance-analysis-53dad63/` 保存当前提交新构建的 CPU 基准、日志和原始 JSON。Linux i5-13500H、Nim 2.2.6 Release/ORC，组件基准启用 `nimAllocStats`，预热 50、3×200 样本：

| 静态兄弟 | legacy-json median ms | legacy-typed median ms | managed-typed median/P95 ms | managed 每操作分配 |
| --- | --- | --- | --- | --- |
| 100 | 0.404405 | 0.386818 | 0.014055 / 0.014473 | 118 |
| 1000 | 4.031839 | 4.047242 | 0.014013 / 0.014414 | 118 |
| 5000 | 26.198689 | 23.318551 | 0.013917 / 0.014385 | 118 |

managed 每次 render/visited/normalized/indexEdits/ops 均 1，Snapshot 导出 0。GC 后 managed-100 RSS 22.10 MiB、存活 Nim 堆 17.69 MiB；managed-5000 RSS 120.34 MiB、存活堆 42.03 MiB。对应 legacy-typed 为 RSS 12.95/60.77 MiB、存活堆 9.37/27.70 MiB。不同模式的表示/保留状态不同，不能把全部差异归因于预分配，更不能据此声称泄漏。该数据不含 Windows、GPUI/GPU/帧节奏，不能用来宣布窗口 60FPS。

## 目标架构与唯一执行路径

1. `Runtime` 必须具有托管组件 driver。`newRuntime` 不再接受只有 `Application.render: RenderProc` 的旧应用，不允许内部自动包装一个全局 root renderer 来假装托管迁移完成。
2. 公开应用入口统一使用 `componentApplication(root: UiDescription, title, width, height, executionScope)`；可保留现有名称，是否补统一的便捷导出以不形成另一种运行时为准。`leaf` 的默认导入应让模板能够使用唯一组件 API，不再把它描述成可选性能模式。
3. 保留 `Node`/widgets/样式和组件内部纯描述构建的价值；`host`/`hostShell`/`componentView` 可继续使用。组件 render 可以构建其负责的宿主子树，但可变 UI 状态必须通过其 `State`/props/显式 invalidation 触发托管提交，不保留旧整树 Runtime、BuildContext 缓存/事件索引/RowCache 的并行执行分支。
4. GPUI 只加载并使用 ABI2 query/run/typed callbacks。删除 ABI1 的启动、JSON 事件往返、自动 fallback、ABI1 旧库 capability 探测和当前工作流矩阵。仅支持 ABI1 的库明确拒绝；不得静默降级。ABI2 必需能力协商仍保留。
5. Win32 原生控件后端保留，直接消费同一托管 driver 的类型化增量批次。统一模型不等于强制所有平台走 GPUI，也不新增 Win32 原生虚拟列表/打包等未实现能力。
6. JSON 保留给 CLI/headless、诊断、显式 Snapshot 和可视化证据，不作为第二套桌面主更新通道。显式导出可产生完整树，普通局部提交不得因此隐藏整树导出/传输。
7. 路由统一使用组件 router/outlet/State，保留具名地址、懒挂载、同页面多 view、retainState/disposeOnLeave 和生命周期任务语义；删除旧 Router/PageGroup 的可变非事务运行模型。`Route` 等纯配置数据可保留。避免同时保留两组语义不同的 page factory。

## 应用及工具迁移边界

必须迁移的不只是 SDK：

- `src/leaf/templates/app.nim`、scaffold application/shell/home 页面和 model 版本。
- `src/leaf/scaffold.nim`、`scaffold_templates.nim`、`scaffold_model_pages.nim` 生成代码和 registry 类型。
- `examples/`、`example/` 展示应用及 `examples/project`，不破坏原业务功能/稳定测试 key/中文显示。
- 普通/原生/发布测试 fixture、CLI/watch/doctor/build/run/pack smoke、性能 producer/验证器和 CI 矩阵。
- C/Nim/Rust ABI fixture、loader/launcher 清理和兼容性测试，删除已废弃 ABI1 专属测试，以 ABI2 缺失/错误契约拒绝替代，不通过跳过当前行为测试来获得全绿。
- README、开发/API/性能/脚手架当前说明。日期化的旧性能/验收记录原样保留，加当前说明链接，不批量改写历史证据和数值。

应用迁移必须实用而非表面：计数器/编辑器用 State；导航经事务 State；页面内 CRUD 保留数据库绑定和 executionScope。不得让每个按键无条件刷新所有不相关页面。普通列表生成逻辑不顺带做新的 SQL/分页产品设计；能使用现有组件虚拟列表的既有虚拟场景须保持虚拟化，Win32 不支持的能力仍明确拒绝。

## 内存优化约束

主要已知固定开销来自 `managed_runtime` 的 instances/index/keys/outlets、`host_reconcile` 的 records/ids/boundaries、`task_service` 的 owners 对 MaxNodes×2/×4 的预分配；此外还存在组件描述、State/回调、路径/索引、暖行和显式 Snapshot 的保留成本。

### 必须保持的事务合同

- 候选计算/校验/prepare 可以分配、报错、拒绝；后端 apply 成功后的 accept/publish 不能引入哈希表扩容、嵌套集合分配、用户回调或新的失败点。
- 不能仅把 `initTable(MaxNodes*4)` 改为较小 initialSize，让 `publish` 的 `[]=`/`mgetOrPut`/`incl` 触发隐式扩容。
- 容量增长只能在接受前准备。若增长改变 accepted 容器的物理容量但不改变逻辑内容，拒绝后允许保留该容量；已接受内容、State、revision、索引和路由绝不部分发布。
- 任何按需方案都不能每个局部提交复制全表、遍历所有无关组件或保留无界候选链。只有跨容量阈值的增长允许摊销的重建成本，需单独测量该尖峰。
- 主表之外，重复 key 的 `HashSet`、owner 注册、outlet、State 发布及后端 acceptedDelta 的插入路径一并审计。测试不能只证明 `.raises:[]` 声明而不观测实际分配。
- 不为降 RSS 丢弃活跃 State、IME/焦点保护行、合法 retained 页面或失败重试 owner。不存在“为了内存优化提前 dispose”的隐式行为。

### 实施顺序与取舍

第一优先是去除按最大规模一次性分配的固定开销，采用内部平坦 `CommitMap`、prepare 几何级数增长、owned patch 和 move/swap 发布，而不是分段哈希/arena。无增长只准备 Δ；仅阈值增长允许 O(N) 重建及短暂双桶峰值。空表不分配，初次最小8桶；容量覆盖先删除再新增时的 `max(L, L-D+A)`，按 `nextPowerOfTwo(max(8,P+P div 2+4))` 保守增长，所有加法/乘法检查溢出。初期不加入自动缩容/缓存清理新机制，关闭/卸载释放语义保持；只有实测滞留需要时才在非发布阶段补有滞回的缩容。

发布接口必须由 prepare 产生且验证 owner/generation/revision/editEpoch 的 sealed patch；可用 `preparePatch`、`validatePrepared`、`publishPrepared`、`finishPublished`、`discardPrepared` 分责。prepare 拥有新字符串/序列及预备退役槽，publish 不调用标准 `Table[string,...][]=` 引发键复制，不把旧值中途析构；整体 Runtime/State/host/revision 全部接受后，仍在重入保护内清理退役对象。viewport 扩展候选后必须使旧 patch 失效并重备；普通提交和安装延迟 confirm 使用同一规则。

`ManagedStore.keys` 改为 `KeySummary { count, xorId }`：prepare 对旧/新活动宿主精确扣减/增加，0 删除、1 的 xorId 是唯一实例、超过1保持歧义查询拒绝。该摘要只替换原先仅用于唯一性判定的集合，不用于需要枚举全部成员的结构。rows/retained 等仍需要枚举的映射按所属实例准备 patch，避免每次复制全注册表。

只读设计探针 `target/verification/managed-only-design/{capacity_probe.nim,probe.log}` 在基线代码实测：空 HostReconciler 堆增量 9,355,456B；单组件 Runtime 含初始化 17,959,168B；动态 ID 初次 host publish/纯文本 host publish 各1次分配、managed 局部 publish 3次、一个State的 disposeOwner 1次；单元素 HashSet 增量2064B。因此除了容量，还必须审计字符串键复制、嵌套集合、owner序列复制、标题、State/闭包/模型析构和后端 accept 的分配。只读探针最终退出0，不是新方案通过证据。

保留现有 10000 节点/组件、64 深度、1 MiB 字符串、16 MiB 逻辑树/配置预算，以及 100000 数据项上限，不以缩小能力上限伪造内存收益。内存安全约束是预算拒绝、可注入预留失败及普通异常可回滚；沿用 Nim 默认真实 OOM fail-stop，不新增 fallible allocator 或承诺整个进程 OOM 可恢复。

第二优先是在证据支持时移除重复的候选/旧快照/回调保留；不默认加入字符串全局 intern、复杂 arena、自定义 GC 或每次更新 fullCollect。暖缓存仍有既有上限，生命周期和关闭应释放不再需要的数据。

降低表容量可能引入首次增长尖峰；需要冷启动、阈值增长、稳定局部更新和卸载后四种测量，不能只比较稳态最小 RSS。Rust/GPUI 原生内存与 Nim 管理堆分别记录，不把 `MaxTreeBytes` 的逻辑计费当作真实堆上限。

## 验收标准

### 唯一模式与功能

- 静态审计与负向测试证明：生产无旧 `refreshImpl`/row-cache Runtime 分支、ABI1 run/fallback 或 `LEAF_TEST_MODE=legacy` 的活跃桌面路径。纯序列化结构、release API 中名为 legacy 的无关字段不机械删除。
- `init`、非 model scaffold、model scaffold、增量生成资源均实际生成、编译、headless 驱动并重开数据库，不能只比字符串快照。
- 组件 State 相等/批处理/嵌套 scope、候选拒绝、后端 apply/restore 故障、迟到事件/代数、重复 key、路由切换、retain/dispose、任务完成/取消/关闭重试保持。
- GPUI ABI2 cache=0/1 与 Win32 的实际可运行窗口覆盖本轮新构建输入。旧 ABI1 兼容路径不作为新矩阵保留。
- 官方 Nim 普通/发布回归、Rust workspace/format/受影响 lint、C/Nim/Rust ABI布局通过。允许删除仅验证被移除模式的专属 case，但要清点原因与保留行为的替代覆盖，不大面积删测试掩盖功能损失。

### 内存与性能

- 至少 100/1000/5000 静态兄弟的相同业务，保留原始样本/二进制 hash/源码身份/编译器/GC/机器与参数。普通局部更新仍 render/visited/normalized/indexEdits/ops=1，Snapshot=0。
- 与冻结的第三种基线比较，不只与旧整树比较。小应用 GC 后存活 Nim 堆必须有明确下降；RSS 单独报告，阈值和较大场景记录波动/峰值，不凭一次 RSS 观测宣称百分比达标。
- 分别报告初始化、容量阈值增长、稳态 P50/P95、分配次数、GC 后存活堆/RSS/峰值；若降低内存伴随明显稳态退化，先定位，不能以“更省内存”直接通过。
- 反复挂载/卸载、页面 retain/dispose、虚拟列表暖缓存淘汰和 Runtime 最终关闭有释放证据；短循环不增长不等于证明零泄漏。
- prepare 失败、apply 失败、扩容阈值和 key 摘要增长有 rollback 与无发布期新分配断言。冷/热启动、动态字符串 ID/key/title、State-only/零宿主操作、卸载、歧义恢复唯一、页面/列表和安装 confirm 的 publish 分配计数应为0；测量窗不含 prepare/整体接受后的 finish。不能靠字面量、预热、禁用计数、关闭ORC或改变业务来规避。
- 含析构计数器的 State/模型/闭包应证明发布临界区不执行用户代码/析构；新旧状态与revision全部接受后在普通保护域内才清理退役值。ORC根缓冲区增长若仍导致发布分配必须定位并明确阻塞，不以 `.raises:[]` 冒充证据。

### 平台与证据边界

本机 Nim 现有路径 `/tmp/nim-2.2.6/bin/nim`。Linux 已知桥接依赖 `libxkbcommon-x11.so.0` 不在系统路径，历史可用 `/tmp/mui-display/usr/lib` 只可用于相应子进程；Xvfb/xdotool 若不在 PATH，应查已有安装而非安装系统软件。Windows 持久验证控制器在 `/home/jimxl/.local/share/leaf/windows-acceptance/control/`，已有固定归档/SDK不能冒充本轮源码。必须核对实际源码、EXE/库身份和交付入口，不修改共享固定源码或覆盖既有证据。

用户本轮说暂不处理的 Windows 夹具覆盖锁、前台/像素前提失败单独记账；若旧夹具因 ABI1 移除被替代，新的夹具不得重现重复覆盖已加载库。不能靠忽略前台或删像素断言掩盖视觉未验项。缺失平台、图形环境/交互桌面/IME/DPI 能力如实报告阻塞，不用 CPU 基准替代窗口验收。

## 不在本任务内

不新增数据库业务/分页产品接口，不重写 GPUI/线程池/高度索引，不扩大原生 A3/Android/Canvas/原生打包；Windows 全树布局的增量优化作为独立后续热点，除非唯一模式迁移本身需要修正接口，不混入本轮算法重写。未经用户明确授权不 Git commit/merge/push，不发布 SDK，不安装系统依赖或改认证/权限。
