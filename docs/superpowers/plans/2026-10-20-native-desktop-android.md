# 桌面三端与 Android 原生迁移实施计划

> 执行方式：按已确认协作规则，当前 Workspace 内分切片开发、自测、独立功能验收；复用相关 Agent，不创建 worktree、不自动 Git 提交。使用 writing-plans / subagent-driven-development 的任务拆解和 TDD，用户已批准的方案不再逐文稿审批。

**Goal:** Windows、Linux、macOS 与 Android 使用各自原生控件，迁移应用/SDK/工具链并最终移除 GPUI；iOS 后置，不是本阶段交付门。

**Architecture:** 保留唯一 managed component Runtime、State 候选提交、HostBatch/HostSession 和 nativeHostConsumer/BackendSession。平台后端分别为 Win32、GTK4、AppKit、Android Views；跨语言适配器采用中立 C ABI，业务闭包只在平台 UI 线程进入 Nim。

**Tech Stack:** Nim 2.2.6/ORC；Win32 Unicode；GTK4 C API；AppKit Objective-C/C ABI；Kotlin Views/JNI/NDK。SQLite/ORM 保持同一目标的单一链接策略。

**Spec:** 复用 `../specs/2026-10-07-native-controls-design.md` 的原生控件方向；当前实现差异及详细平台切片见 `target/verification/native-five-platform/design-gap-report.md`。旧设计的 raw-root Runtime、PageGroup、ABI1 和长期 GPUI 默认不适用。

## 当前授权与全局约束

- 用户于 2026-10-20 确认“ok，先搞定桌面端和安卓”：批准上述阶段实施及前述本机开发依赖补齐、现有 Windows VM/Android 模拟器测试。macOS 尚无可用 Mac/Xcode；缺证据时保留阻塞，不能用静态桩/headless 声称完成。不重复催问同一待答 Mac 环境问题。
- 当前 Workspace `wks_7f53976fa3f9199c`，cwd `/home/jimxl/projects/leaf`，现有 `main`、`.git/index`；基线 `83fc6c42f7593048a49840d3ca2bb04871acfca5`。本轮既有 docs/progress 修改归协调者；不覆盖或收编无关改动。
- 开发阶段不创建新 Workspace/worktree、不并行写公共文件，未获交付口令前不 Git commit/merge/push/发布/归档。2026-10-23 用户明确要求“提交代码”，授权按全局交付流程提交本阶段已验成果、整合主分支、推送及跟进对应 CI；不代表完整迁移门已通过。无签名、商店上传或改认证授权；Android 测试 APK 安装/运行仅限本任务获准模拟器。
- 不退回整树 JSON/ABI1、旧 render 引擎或另一套 Router。headless 仅保留为无窗口工具/测试模式。
- 保留节点/深度/字符串/逻辑字节和 100000 数据项预算；必需能力未实现必须拒绝，装饰遵循已有 compatible/strict 诊断，不缩能力上限凑绿。
- prepare 可以分配；publish/accept 仍只发布预备状态，不能触发业务、平台 setter/异常、隐藏分配或提前析构。
- Native UI 不是数据库事务；apply 中途失败用 accepted 描述恢复，恢复再失败则 fault/freeze 并保留 cleanup owner。
- GPUI 仅在迁移期间保留既有对照，不新增功能、不作为新平台 fallback。四端应用及工具链替代门通过后清除；iOS 后置不应阻止本阶段清除。某桌面平台未验证时不得宣称整个阶段完成。
- 不夹带 CommitMap 性能修复，不新增 Canvas/图表库。先覆盖现有控件、原生滚动/复合列表、导航、输入、生命周期、资源/数据库和实际 build/run/pack。

## Review Focus

1. 只改变 list generation/count/height 而 normalized props 不变时，metadata 仍须更新；restore 必须重现完整 accepted 元数据。
2. 原生列表 factory/bind 回调只能登记视口事实/读取 accepted 行，不能递归 materialize/render/commit；safe-turn 才提交。
3. 新 host/复用行接管后，旧 session/mount/source/binding 的通知必须失效，但无关更新不能废掉全部旧 revision 监听。
4. 转屏/Scene/UI detach 不等于关闭业务 Runtime/数据库；Android 进程重启只能恢复显式持久化状态。
5. 真正的原生窗口/安装包/输入验证与纯记录测试分开；环境缺失、NotRun、签名缺失不能计通过。

---

## S0：中立列表元数据与 safe-turn 视口契约（已通过）

最终快照 backend_session `25935283…`、list_protocol `89a015c9…`；独立本机8套120OK/0FAILED及oracle通过，主控正式Windows新快照S0三套39OK＋Win32八套97OK、0FAILED/0SKIP、531hash一致。报告 `target/verification/native-five-platform/s0/review-dw1/functional-review.md` 已补Windows外部证据并确认门满足；不是S1/UI或整迁移通过。

**Files:**
- Create: `src/leaf/list_protocol.nim`（纯中立 list 类型）；`tests/nim/test_native_list_metadata.nim`、`tests/nim/test_native_row_requests.nim`。
- Modify: `src/leaf/host_protocol.nim`（转导出原有 list 类型）、`src/leaf/backend.nim`、`src/leaf/native_host_adapter.nim`、`src/leaf/backend_session.nim`。
- Necessary regression only: `src/leaf/backends/headless.nim`、`tests/nim/test_native_accepted_commit.nim`、`test_native_backend.nim`、`test_component_lists.nim`。
- 不修改 core/managed_runtime 发布算法、平台实现、GPUI ABI、CLI/build/pack/SDK/CI 或协调者文档；确需越界先带具体证据交协调者。

**Interfaces:**
- `HostHeightMode`、`HostListProps` 从 host_protocol 移到纯 list_protocol，由 host_protocol 转导出，保持旧 import 调用、字段、枚举值含义不变。backend 导入同一类型，避免循环依赖。
- `MountedEntity.list*: Option[HostListProps]`、`UpdateOp.list*: Option[HostListProps]`：create/update/acceptedDelta/restore 一致保留完整类型化列表描述，普通控件为 none。仅 list 变化也应产生 update。
- `RowViewportRequest*`：sessionId/mountGeneration/listHandle/sourceGeneration/first/finish/protected 的拥有型值；不含 Node、闭包或平台指针。
- `queueRows*(session: BackendSession, request: RowViewportRequest): bool`：UI 线程记录请求，不执行 materialize；拒绝不合法身份/范围及失效列表。每 list 当前 token 的最新请求替代旧视口，保护行以最新事实为准；队列必须有界。
- `pendingRowRequests*(session: BackendSession): int`。
- `drainRowRequests*(session: BackendSession): int`：仅普通安全 UI turn 执行 requestRows，返回实际成功消费数量。安装/提交中或重入时保留请求不执行；处理前再次校验 session/mount/source/list 生存状态；新入队请求留下一轮，不无限自旋；失败遵循既有错误/accepted 状态契约。
- 现有 `requestRows` 仍为显式同步接口，不静默改变其语义；新平台 factory 只用 queueRows。dispose/close/fault/恢复重挂载时不得让旧请求进入新 Runtime。
- accepted 行查询若本切片确需补充，由开发者先写测试/在报告固定精确接口；只读 accepted 事实，不渲染业务，不扩为通用新框架。

- [x] 写 metadata 回归：create/update/仅 list 变化/removal/restore；generation/count/uniform/variable/rowHeight/estimate/overscan 完整且受预算校验；无 list 的普通节点不受影响。
- [x] 写请求队列回归：enqueue 不 render；apply 中 drain 不重入且请求保留；latest viewport 合并；无效范围/过期 source/重挂载/卸载/关闭/跨 Runtime 不执行业务；失败后 accepted viewport 不变；有界队列与新请求延后。
- [x] 运行 RED，记录真实失败断言；类型缺失编译失败只作为接口缺失证据，不把平台环境错误记 RED。
- [x] 实现最小变更，运行 GREEN 与受影响回归；accept/publish 分配围栏仍为 0。
- [x] 自测完成写 `target/verification/native-five-platform/s0/developer-report.md`，含文件 SHA、diff、命令/退出码/失败与剩余项，停止写入。
- [x] 独立功能验收依据上述接口/断言实际执行，原会话核对 diff 与证据；普通缺陷回原开发者，同根因两轮未收敛第三轮前裁定升级。

**Commands:** `NIM=/tmp/nim-2.2.6/bin/nim`；在仓库 cwd 编译 `--path:src`，输出到 `target/verification/native-five-platform/s0/`：

```sh
$NIM c -r --path:src --out:target/verification/native-five-platform/s0/test_native_list_metadata tests/nim/test_native_list_metadata.nim
$NIM c -r --path:src --out:target/verification/native-five-platform/s0/test_native_row_requests tests/nim/test_native_row_requests.nim
$NIM c -r --path:src --out:target/verification/native-five-platform/s0/test_native_backend tests/nim/test_native_backend.nim
$NIM c -r --path:src -d:leafProtocolProbes -d:nimAllocStats --out:target/verification/native-five-platform/s0/test_native_accepted_commit tests/nim/test_native_accepted_commit.nim
$NIM c -r --path:src --out:target/verification/native-five-platform/s0/test_component_lists tests/nim/test_component_lists.nim
```

稳定后一次运行现有官方 `scripts/test.nim` 全套；不为相同快照重复全套。Windows 原生回归由协调者在当前内容 hash 上传后使用现有 runner 执行，不把旧 VM 日志当本轮通过。

## 后续依赖切片（执行到该切片前固定平台接口和测试命令，不以此表冒称已实现）

| 切片 | 依赖与文件边界 | 可验收交付物 |
|---|---|---|
| S1 Windows | S0；`backends/win32/**` 的 scroll/行池，native_layout；必要 widgets/DSL 公共变更串行；pack/targets/native_binary 的 Windows 分支 | 现有控件＋真实滚动复合列表＋SQLite 保存重开，native ZIP 移位可运行；实体池按视口增长，焦点/组合输入/旧绑定失效有证据 |
| S2 Android | S0；`native/android/**`、`backends/android/**`、中立 C ABI、mobile host/application factory；project/targets/build/doctor/SQLite/资源服务串行集成 | Kotlin Views 的可安装 APK；Nim UI 主线程/UTF-8↔UTF-16/JNI 引用受测；转屏 Runtime 保留、前后台/键盘、资源/数据库与进程重开验证 |
| S3 导航 | S1/S2 对应平台；ComponentRouter/State 历史、native typed payload、Win32/Android adapters | push/replace/pop、系统返回/取消提案、单次 request id；失败不推进 accepted history，原生异步动画不能等待阻塞同步 apply |
| S4 Linux GTK4 | S0/S3 契约；`backends/gtk4/**`、runner 和 toolchain/pack 的 Linux 分支 | 真实 GTK4 表单/复合列表/导航，IME/辅助技术分列，tar.gz 移位启动、无 Cargo/GPUI；X11/Wayland 按实际覆盖记录 |
| S5 macOS AppKit | S0/S3；`backends/appkit/**`、`native/apple/{common,appkit}/**`、macOS build/pack | 原生 AppKit 控件/列表/导航、field editor/marked text、SQLite、可运行 .app；必须 Mac/Xcode，当前环境阻塞，不能仅源码交付算完成 |
| S6 清除与统一工具 | 本阶段四端必需门；runner/SDK/install/CI/示例/两套 scaffold/performance/watch/licenses/Cargo/GPUI 入口 | 四端默认原生；无 GPUI fallback；源码、包、构建与实际加载均不依赖 GPUI/Rust；历史文稿保留真实记录。桌面 watch 迁移保留，Android 仅 build/install/run，不承诺热重载 |

每切片由开发角色自测后交独立功能验收；UI 行为/视觉/实际产物入口必需证据单列。不提前将未来目标设为 fullCapabilities，不新增空后端占位。Android arm64 设备与 x86_64 模拟器分列；首批先模拟器可执行纵向链路，真机缺口保留。iOS 后续复用中立 ABI/mobile host，不为预留而新增空 UIKit backend。

## S1 细化：三个串行任务

已由方案角色对照当前实现给出164行brief：`target/verification/native-five-platform/s1-implementation-brief.md`。原会话已读全文，接受以下技术取舍；属于已批准原生迁移范围，不再要求用户审批文稿。完整平台输入/池化/失败清理细节按brief执行；此处固化下一可验收接口，防止后续依赖忽略候选发布边界。

### T1：typed row sidecar 与纯列表几何（已通过）

独立门族r0→r1→r2已收敛，报告 `target/verification/native-five-platform/s1/t1/review-r2/functional-review.md`（含Windows外部核对）。最终host_reconcile `4b79e08c…`、row测试`b9562450…`；独立受影响81OK及同快照Windows81OK＋Win32八文件97OK、534hash/14overlay一致、exit0。r1干净单次107套/1006OK/5既有平台skip按未变范围复用，r2未重跑全量，不称1007已执行。仅公共协议/几何通过，不代表T2/T3或四端完成；adapter O(accepted)/prepare索引成本为后续机会。

沿用 HostRecord/CommitMap 发布，不建独立行事务表。`backend.nim` 新增：

```nim
NativeRowBinding* = object
  listHandle*: NodeHandle
  sourceGeneration*: uint64
  itemIndex*: int
  itemKey*: string
```

`HostRecord`、Nim `HostOp`、`MountedEntity`、`UpdateOp` 各增加 `row*: Option[NativeRowBinding]`；root handle 为记录本身handle，row只表示列表直接行根，不把活动兄弟index当数据index。Nim-only sidecar不加HostOpKind、不改GPUI C头/ABI/codec/Rust；旧encoder只编码既有字段。

`managed_runtime.prepareHost` 在coalesce后、planDelta前调用私有 `prepareRowBindings(d, upserts)`：由d.edits及祖先链收集受影响列表，枚举candidate active children，经hostRoot取得真实行根、rowIndex和source itemKey；缺根upsert时从accepted record补充按差异touch，不导出snapshot/不扫描全store/不在backend读业务Node。覆盖component/pageOutlet根替换、局部State、warm重激活、protected不连续行及嵌套列表。list metadata和row必须在prepare/apply候选视图已一致，不能等accepted后查询补布局。

HostReconciler和native adapter校验candidate list存在/kind/list元数据、root.parent与最终membership、source generation/index预算、同list key/index唯一性；list source变化时检查活动孩子不能遗留旧绑定。itemKey UTF-8/MaxStringBytes及HostRecord.bytes/MaxTreeBytes计费。row-only变更产生update；fullBatch/acceptedDelta/compat accepted/restore完整保留；accept/publish仍0alloc。

保留 `layoutTree` 既有接口，新增 `native_layout.measureSubtree(entities, root, available, measure): DipSize`、`layoutSubtree(entities, root, rect, clip, measure): seq[LayoutBox]`；root不要求parent=NoHandle。新增纯模块 `native_list_layout.nim`：

```nim
proc clampListOffset*(total, viewport, requested: float64): float64
proc listVisible*(heights: HeightIndex, offset, viewport: float64): VisibleRange
proc listRowRect*(heights: HeightIndex, binding: NativeRowBinding,
  viewport: DipRect, offset: float64): DipRect
```

复用HeightIndex，visible不预加overscan（Runtime只加一次）；row y用prefix(itemIndex)-offset，不用活动兄弟序号。outer list为有限viewport leaf，内部分行子树测量/裁剪，嵌套list交各自viewport。避免逐行重复构建全实体索引，不借此重写布局引擎。

允许修改：`backend/host_protocol/host_reconcile/managed_runtime/native_host_adapter/backends/headless/native_layout`，新`native_list_layout`及`test_native_row_bindings`/`test_native_list_layout`；必要list metadata/accepted/component lists/protocol/commit memory回归。不得改backend_session/core发布算法、GPUI/Rust/ABI、平台实现、CLI/pack/SDK/CI/协调文稿。

- [x] TDD：候选row在prepare/apply可读但accepted revision旧值；含斜线/中文/emoji/空key不解析nodeId；component/pageOutlet根替换、source-only/row-only变化、warm/protected/嵌套；malformed membership/源/重复key/index/预算在平台prepare前拒绝；失败/restore/fullBatch/0alloc围栏。
- [x] 几何：fixed/variable、首尾/空/0viewport、部分行、offset clamp/超大total/非有限值、protected不挤普通行、宽度变化测高，普通form布局不变。
- [x] Linux新两套＋accepted_commit/commit_memory探针＋受影响回归；稳定快照官方回归按风险一次，不为同快照换摘要反复全量。Windows当前hash对应新两套及两分配围栏＋现有host回归由协调者串行取证。
- [x] 开发报告 `target/verification/native-five-platform/s1/t1/developer-report.md` 含RED/GREEN、文件hash/精确API/实际命令exit/未完成；独立验收后再进入T2。

### T2：真实 Win32 复合行池与滚动（T1已通过，进入实施）

文件限定Win32 api/calls/backend/capabilities/host/host_bridge、新list_host/row_pool、必要safeTick接线、native_list真实10k复合行/SQLite fixture、Windows列表/故障测试。真实WS_VSCROLL/WM_VSCROLL/thumb32位/高精度wheel/实际client宽度；候选row映射布局，safe turn登记+drain处理false背压；fixed/variable测高复用HeightIndex并保持anchor；prepared frame/accepted frame与事务一致、accept只swap/move。有限隐藏原生行池独立于managed warm State，保护焦点/IME，重绑cookie/commandId/binding/source，不回收当前可见候选将移除的行冒充prepare安全。资源失败保留owner，Defect fault后关闭/重建。不改pack。

真窗口验收必须滚动首尾、复合EDIT/checkbox/button、多行文本、选择/真实IME分列、稳定HWND/复用池有界、排序增删/旧事件、SQLite保存重开、真实rect/clip、prepare/partialapply/restore/destroy故障；官方Windows runner新旧套件和实际GUI入口，不用纯几何替代。

#### T2 RED08后的内部根因裁定

实测报告 `target/verification/native-five-platform/s1/t2/windows-red-08/coordinator-result.md`：A子控件隐藏0×0、B2新绑定继承旧selection(2,4)、C右侧跨池后为空，B1空属性与B3活动交集通过。fresh家族两轮后的同策略已暂停，由原主会话按明确反例裁定：新绑定初始化使用冷新EDIT基准(0,0)及全新transient/reset水位，稳定同绑定更新继续保留selection/IME，不再沿旧selection强制写值；行子树按已有LayoutScope/layoutSubtree完整布局；池优先按所属viewport/list隔离但维持backend全局8行预算，viewport删除/restore/close不留死槽。真实SetParent是可选替代，须证明失败cleanup owner。仅Win32私有实现，不改T1/core/预算或测试期望。这是根因与策略已确认后的续接，不重置历史；实现无法证明则停相应边界升级。

#### dev09释放挂起：已取证的资源协议切片

同冻结22overlay的唯一有界closeprobe02已实测：viewport remover成功→parked父Destroy成功→3孩子Destroy失败1400；下一次同viewport/id/callback重复remover BOOL0且无reinstall，Session未disposed、host/viewport仍活。实际trace/编译与自然exit4见 `target/verification/native-five-platform/s1/t2/diagnosis-hang09/probe-run01/coordinator-probe-report.md`。原run-a未取栈，不冒称采到旧现场栈；多槽/借槽等仍先RED。原开发者上下文容量不足后只续接短快照，不当额度问题切模型；具体计划不是实施批准或T2通过。

原开发者提出逐窗逆序attach并用`released=true`移交prepared的方案，**不能据此开始实现**：`released`混淆“已销毁”和“交给另一owner”；剩余槽父仍可能销毁prepared拥有的已移交孩子，逆序本身不建立跨owner祖先阻断。内部落地裁定：优先使用稳定引用/稳定token的原生树group，在整个attach成功前仍由该group唯一拥有全部HWND；prefix/current/suffix的控制器/cookie阶段进度持久记录，prepared中的未完成view不拥有HWND，失败统一按完整拓扑清理。整组准备和元数据插入具备成功条件后才一次移交owner；不能用会随slots删除移动的seq下标当slot身份。若仍选择逐窗分割owner，必须先给出跨owner拓扑阻断的实际RED与完整协议，不能把“父仍归槽”当天然安全。此为Win32私有资源记账，不新建业务row事务表、不改Runtime/T1/host。

统一cleanup必须子先父、失败阻所有祖先、继续独立兄弟，成功即更新权威HWND/阶段；清理失败与尚未处理槽持久可枚举且不可复用。viewport remover成功立即落`subclassed=false`并撤销回调路由，cleanup身份/列表owner保留至后代和自身释放；slot清理独立于subclass标记，remove/restore/dispose/retiring/fallback走同套原语。parked+未完成borrow+failed的全局8槽计数不绕过，失败按既有fault机制冻结扩张，不吞BOOL、不用IsWindow归零、不修改Host重试掩盖缺口。含viewport子树的callback类型不能统一错用controlProc；本切片不冒称嵌套列表门完成。

下一步先仅编写聚焦正式RED：parked活子拒绝/祖先与兄弟、同owner至少2槽首槽失败及另一viewport隔离、viewport remover两阶段失败与幂等重试、借槽首/中间setter失败并再次cleanup失败、retiring/fallback、直接remove/restore/dispose。只通过calls包裹与真实HWND观察断言，不为让RED可写而先改产品或新建公开业务API；本地codegen通过后由主控安排有界native RED，才允许实现相应切片。自然close已有上述实际RED，不重复未变探针。第三同策略止损历史保留，完整矩阵/run-b/T3尚未解锁。

#### plain parked 槽异常展开：2026-10-20补证后裁定

owner-r2产品4e2b已独立关闭正确scope退出/42窗祖先/失败borrow同callback-id重试三个反例，原15case通过保留。但“takeSlots/clearOwnerSlots后持久表未变且图构造无分配”不实，独立验收按主控指出已更正并保留原报告；唯一诊断probe2beb8ed8实际证明合法destroy wrapper抛UiError后parkedRows归0，57窗仅41有自己成功destroy凭证，16由重试close的祖先隐式杀死。程序exit0/OK是诊断，不冒充正确需求的runtime RED。资源协议仍不通过，全T2/T3不前移。

暂停沿“出池到局部→最后补余量”的同策略小修，不因改轮次名/换Tab重置历史。本次落实：plain槽同样原位保持持久owner，或在移出前所有可失败准备完毕、以不可失败步骤进入backend持久cleanup carrier；构图/排序/metadata快照只为非owning视图。BOOL0与契约CatchableError在每次call处保存原错误/secondary、阻所有祖先并继续独立兄弟；成功先即时落权威window/subclass/cookie进度，再做辅助记账。Defect原样fault/close/rethrow、不在unwind分配恢复，不能仅catch/finally重新入队来掩盖此前owner缺口。全局8含所有cleanup组，不增业务事务表/公开API/Host/core改动。

复用原开发者85bc；先4e2b加正确正式异常断言native RED（destroy/remover抛出），再最多一个新产品快照；任一包装/fixture/native未收敛保全后停止，不自动第三/第四attempt。新异常2+原owner3+冻结原15与受影响controls/host只在稳定新快照各一次；不重跑旧hang/baseline/未知视觉。现行VM归85bc独占，主控/验收不并发操作；验收最终仍按实际证据，动态OOM/compound restore/预算fault/alloc及其他剩余门不能随此切片省略。

#### durable-progress裁定：统一稳定carrier而非局部补账

d2b的正式异常2RED→5+15+20+24 GREEN保留，但主控/既有疑难角色定点只读确认A局部成功凭证与末尾slot深复制未立即持久、B park prefix在第二/中间showWindow抛错后失持久owner。C局部复制确会分配，但实际sink-add后delete没有所指内部copy失败边，部分counted副本/双owner怀疑已反证；只更正文案，不为C造动态缺陷。诊断`s1/t2/diagnosis-durable-progress/diagnosis.md`未新编译/VM/OOM/probe。

下一实现采用稳定group引用/token＋逐窗权威entry，park在首次撤cookie/map前publishOwner，pool/borrow/NativeControl/工作集指同一entry或明确非owning；成功BOOL/NCDESTROY后第一条不可失败标量阶段写早于集合/计数/表删/诊断字符串/压缩。pool只是可复用phase/引用，finish仅整理；私有载体必要时可拆一个Win32内部模块，不能改业务事务权威/Host/core/public API。跨park/release的持久记录解决安全性，不捕Defect补账；逐窗完整父链/失败阻全祖先/独立兄弟/全局8继续。

原85bc实现，先一页接口/phase方案落已有report再产品修改；一个d2b+B正式native RED输入（第2/中间SW_HIDE预建异常、raw证明真实prefix，不误用ShowWindow返回值）＋一个新产品GREEN输入。实际carrier状态序列测A ended/B失败/工作集重建只剩未结束项，并用真实C/helper证明所有成功边即时持久；A未动态OOM不造旧RED。按新风险回归新B+旧owner5/fault15/controls/host各一次，不重复旧hang/全项目；fixture/包装/未收敛保全即停，累积修复不因名字归零。现85bc独占写者/VM，诊断和验收均停写；自测后主控核diff与独立验收，T2/T3仍未解锁。

#### stable-carrier未收敛：冻结与ORC根因门

有效B RED在d2b+case6上已执行exit1（park-red4，前两oracle/一次工具错分别保留）。但实施者违反1次GREEN边界自行5个新产品矩阵，均有ORC/释放SIGSEGV且再次晚补方案，不能称遵守有界规则；已止损，不授权第六次试补。活backend回退d2b，保留未import的carrier与case6 RED；最后45156e49完整attempt/1118行diff/各批guest源/C/raw均保全。旧64绿、纯carrier2OK保留，不等于集成成功。

当前仅既有疑难角色只读诊断实际RC/RootRef/raw/cursor/lifetime数据流，不编译/VM/新probe/改GC；需区分实证/推断并给类型安全最小路线。开发者末栈“只差typed owner/模型本身没错”不作已证根因。报告`s1/t2/diagnosis-carrier-orc/diagnosis.md`后由主控再裁定，不自动恢复实现。后续Native集中由协调者按冻结hash/明确最小case单次安排，不再授实现者自行多快照迭代；不是声称工具隔离。T2/T3仍不推进，累计失败/越界/成本不随轮名或回退归零。

#### ORC诊断后：仅本地typed binding store候选

只读诊断证实park后typed表/cookie清掉，group只有entry强ref、control仍raw，临时lease结束后悬空；P3非RootObj cast RootRef另为RTTI布局错误。P1/2/5 actual C有计数lease，不能说都无lease；每次SIGSEGV首个坏地址未确认。P1没有RootRef，P3 controls实际4OK后exit1崩（此前每批20OK摘要作废）。报告`s1/t2/diagnosis-carrier-orc/diagnosis.md`，旧证据保留。

选carrier纯资源状态＋backend稳定resource token→typed NativeControl store：每个装/待撤callback binding先强root；lease先于删root、覆盖最后C.owner访问后drop；park解绑成功后在lease中退役旧capture/store，不给活HWND记ended且不再留可解引用旧C地址；borrow新建typedbinding先入store，entry仍唯一native权威；真实结束第一条noteWindowEnded，ended-but-bindingPending仍可枚举清理。正常scope出口无cookie/store残留，不改GC/RootObj冒充/故意留capture。

原85bc仅本地一次候选，先写短方案再实现、保留45156e49attempt，编译目标C/必要纯数据单测不冒充Native。开发者无VM/guest/Native授权，主控核冻结hash/diff后只集中执行一个故障case pilot，之后再按证据扩回归/独立验收；不重跑旧G5观测来确认已足够明确的源码错误，也不声称具体坏地址已证。T2/T3仍未通过，越界与修复累计不归零。

typed本地6d95候选静态预检未过，未启动Native：通用release remover成功即清entry/token/store错误套用park退binding，会令非group控件失owner/跳finalize；endedPending与create-only-store路径未全枚举。按同一typed方案返原作者本地修正，不另造Native RED或扩测试；消除阻断后才由主控按冻结候选跑一个owner3 pilot。详`s1/t2/cleanup-typed-binding/coordinator-preflight.md`。

修订84e127b5已由主控集中执行一次owner3 Native pilot：541 manifest102c9f31…/binary310052a1…，compile0/native0/1OK/stderr0，原借槽清理崩溃本例未复现，真实拒绝→同identity重试→自己Destroy及自然close均通过，无超时/强杀/残留。只限pilot，不重跑矩阵，不认定全部资源/T2通过。扩验前releasePrepared nil-window分支的边迭代边删及漏cookie静态缺陷返原作者仅本地小修；旧84快照/证据保留，未来Native仍仅协调者安排。详`s1/t2/typed-binding-pilot/coordinator-result.md`。

创建失败清理abc修订（72行）后主控单次受影响回归owner1/2/4/5/6＋原15＋controls20/host24=64OK，各exit0/stderr0，无超时/强杀/SIGSEGV；541 manifest3d1f37b6…、同Session1/headers/v6-PMv2、结束Ready/进程空，完整raw/C已空间外保全。没有重复owner3，不拼为abc单次65（84 pilot证据另列）。当前b732只读独立验收源/C/raw+独立纯状态工具测，不新probe/VM/矩阵，精确评估未变证据复用；必需缺证据不通过。详`s1/t2/typed-binding-regression/coordinator-result.md`与待交`review-typed-binding/functional-review.md`，T2/T3仍未通过。

#### known owner/typed lifetime验收通过，推进A几何（资源全部/T2仍open）

独立review-typed-binding已核源/C/raw/hash并独立工具2OK，主控接受限定切片；84 owner3＋abc64的跨输入复用明确、不拼成单次65。scope beacon只据B owner1、全图函数实际depthIn/blockAncestorsOf两处报告笔误在主控result附注更正，不抹掉原文。

下一A以主控当前abc/a464正式filter A:*复查已有有效RED：compile0/nativeexit1、4个row/viewport intersection断言失败，其它可见/尺寸/顺序前提过，无崩溃/超时，raw已空间外保全。原开发者仅本地找Native测量/布局根因，修backend relayout/必要win32 measure私有逻辑，不改T1/core/已验resource生命周期；两pool模型只纠正owner输入不改断言/隔离语义，先短根因方案落report，不新Native/VM输入。主控核冻结候选后针对A/B/reuse/模型复验，不默认资源64重跑；真实上下文不足停报，不自动换Tab/模型。详`s1/t2/geometry-check/coordinator-result.md`与后续`geometry-fix-local/developer-report.md`。全资源门/T2/T3仍未通过。

A本地a27候选只15行virtualList私有测量（auto宽取父有限宽、高偏好0），两模型只改owner输入。主控一次编译、复用同binary：A/两fixture/B1B2B3C/reuse及按原共享初始化上下文其余项均有成功记录；16唯一case跨批有成功，但有一次多星0case工具错与fresh独立cold USER4>3/GDI10>2失败原样保留。旧abc/a464隔离cold同数值失败，shared子集8OK，说明非本width修复新增、运行上下文影响基线；不宣称具体对象OS归属或资源预算全部闭合，不叫单次16/0。当前review-geometry只读源/C/raw＋本地桩模型，预算条件单列，未证不得整体通过。所有tag核Ready/进程空、空间外保全，详`s1/t2/geometry-verification/coordinator-result.md`；T2/T3仍open。

#### A/fixture限定验收通过，下一门实际Win32列表alloc围栏

review-geometry已完成：A与两fixture通过，fresh USER/GDI预算阻塞/未证，水平并排auto宽风险未Native验证；不能扩大到资源全部/T2。主控附注新3tag同C004、旧abc对照3D1F，旧RED raw无每child identity/rect，模型不作原生实测，原报告保留。

下一只由原85bc本地新增realWin32 list allocation probe（不改产品、现fence/公共API/其它tests），唯一managed Runtime/真实Host/BackendSession、10k列表有界复合行。按既有managedPublishAllocations/hostPublishAllocations/nativeAcceptAllocations每commit置-1后必须0，带revision/实际accept计数/row元数据等witness；不被多commit最后0覆盖，不把prepare分配/模型/OS资源当同指标。初attach、row create/换页-remove/source代数更新覆盖，现probe_accept_alloc六输入窗口基线原样复用。只local release/orc/probes/nimAllocStats codegen预检，Native由主控后续冻结hash/flags执行两个program各一次；实际fail才有相应产品RED，不为加覆盖捏造早RED。预算/fault/复合拒绝与其它T2门继续open，T3不推进。report`s1/t2/allocation-check-local/developer-report.md`。

#### allocation首次Native：实际计数全0，probe整体仍exit1

主控静态preflight先纠正probe方法：Runtime revision只证publish，实际native accept用现acceptedDelta薄标量wrapper；attach confirm-only允许pub0，managed/host -1标N/A不叫0。原871稿/report保留。冻结3ea4683d/产品a27，主控tag`native-s1t2-alloc-probes-1021-3ea4683d`、542 manifest98b79b08，同官方header/v6-PMv2/Session1非提升，release/ORC/allocstats/probes flags；各program只一次compile/link与执行。原input0e六accept0/自然exit0。新list attach calls1/pub0/native0与5次row窗calls1/pub1/三counter0实际成立，但自然exit1/stderr0，唯一source1→2 parent State update断言要求HWND no-create失败（新增10、复用+3、idle3→5、live5）；不能叫整体PASS，也不是分配RED。原作者只本地追踪generation/row identity/idle借槽、不偷accepted-visible契约判定及最小验证源修正，不预授权产品或Native修复，不仅删断言凑绿。原raw/失败与两个binary/C/source均保全空间外，Ready/进程空无超时/强杀。详`s1/t2/allocation-native/coordinator-result.md`；同源row-local State no-churn、fresh资源预算、独立alloc验收与全T2仍open，T3不前移。

allocation r3源码追踪确认是新source重建row身份，不是同binding违规；仅probe77行修订phase为source-generation update，实际source变化premise、5rows×5windows推导上界25、rows5/idle≤8，单accept/pub/sentinel读取不变。e468候选主控tag`native-s1t2-alloc-list-r3-1021-e4687c68`只一次C/link22.433秒exit0与process1.007秒自然exit0/stderr0，新542 manifest55743e19/binary8ffb55be；attach calls1/pub0/native0与五row窗calls1/pub1/三计数0、source1→2、shrink3实际成立。原input跨首batch复用未重跑；旧3ea run1仍保留，产品a27未改、两guest542仅probe不同。21:23:22Z Ready/进程空，后完整source仅证据复制逐hash保存，不算重跑；liveWindows未枚举所有parked/OS预算，setTexts增加不等于值/视觉验收。b732当前仅review-allocation独立限定验收源/C/raw/哈希/口径及跨batch复用，不新Native/oracle/矩阵；作者停写，不称alloc门已独立接受，full T2/T3仍open。

#### allocation限定独立验收通过，下一仅只读冷资源预算诊断

review-allocation已落盘并经主控全文核对/针对性证据复核，接受本次真实Win32列表5row-publish＋6native-accept围栏及旧input回归切片；不重复Native/全套，不把原3ea exit1改写PASS。原报告保留，coordinator-result附注更正零HWND创建/构造器名/旧A及两fixture非open/无另存命令附件四处文案，均不改fence0实际证据。源/产品a27保持冻结，范围不扩大为全T2/资源故障/OOM/prepare或OS分配0/同源State/IME/visual。

下一只由原作者85bc做本地report-only fresh冷USER/GDI预算根因分析：读原cold用例/host-measure-dispose与既有三组raw，分清baseline在createHost之前、首次初始化对象、backend/host释放、诊断liveWindows不计parked等测量边界；必须保留新旧孤立USER4>3/GDI10>2失败及shared成功，不归因OS缓存/阈值错误而无对象证据。只可在既有geometry-fix-local报告追加分析/必要验证工件，不改产品/旧tests/分配probe/阈值、不编译/Native/VM/新oracle；给主控最小追加取证建议后停报。T2/T3仍open，Native仍仅主控逐冻结输入调度。

冷预算只读§9已收到，未证根因。主控校正：abc已含typed-lifetime不能靠old/new同值排除早期共同实现；shared仅上下文相关不证一次性OS成本；release site存在/close记账不反证全部保留；后续轮总计数增长不能直接定产品泄漏，原freshFAIL不预定oracle错误。下一授权仅本地新probe_win32_gui_resources.nim与既有报告工件：第一轮不预热、固定3次原完整cold滚动/关闭场景，阶段counts加透明Win32Calls的有界per-handle/epoch与成功释放/转交/借用归还凭证；observer不污染原返回/LastError、不在成功后分配/抛异常，缺观测标未完成。正常exit0仅诊断完成，不budget PASS/产品RED。产品/原tests/两allocprobe/阈值不变；作者只Windows compileOnly，Native仍无权，主控先核候选后至多单进程120s编译/30s执行。T2/T3仍open。

GUI资源probe首版104074（568行）C生成成功但主控静态不通过，未Native：原始事件未输出、epoch与对应lease未关联/DC无epoch/class无卸载身份/aggregate冒充匹配、font/region delete漏移live假残留、transfer未追window终结、pump后读所谓close前diag、缺viewport跳scroll仍完整/失败不停/未采0参与分类。所有方法缺陷合并交原作者，仅同probe+报告本地返修保留旧source/C/失败编译，observer成功后不分配/抛/改LastError，可靠身份与实际阶段路径核实后才主控决定Native；当前该probe Native0次，非产品RED或Native修复轮。原预算FAIL和其它未完T2仍open，T3不提前。

GUI资源0228（833行）首次局部返修有进步但仍静态不通过：acquire双ID导致release原始引用与region汇总断链；多借theme假精确matched；region owner仅裸HWND、unmatched destroy也作间接成功；失败DeleteObject身份反选；异常/secondary证据丢失及无真实trace完整性验证。第2次且同策略最后局部修复交原作者，保持单新probe/报告、本地compileOnly、产品/tests/阈值不动、Native0次。若再同类未收敛则第三次修复派发前暂停诊断/升级，不改名归零；不把静态方法拒绝当产品RED或Native修复轮。T2/T3仍open。

GUI资源55071（943行）第2次方法修复修正ID/owner/失败收据/完整性门，仍待裁定共享borrow先ambiguous清任取条目后又matched的认识边界。已暂停第3次同策略派发，85bc已idle，Native0次；现复用d4 codex/gpt-6.1-sol/auto-review/high，仅只读ledger-method-diagnosis，判断该疑点是否实质阻断raw API与阶段OS计数采集，或应简化raw-only/handle-group避免无限扩900行；不编码/编译/Native/新probe/VM/Git，不是额度替补或默认最终复核。未Native发生的假设序列不当产品RED，旧失败/三候选与C/report均保留。原主控待报告决定，产品/tests/阈值冻结，full T2/T3仍未通过。

d4方法报告已落盘并主控接受其边界：5507匹配/残留误证不用于ownership，可不再微补丁而冻结做一次raw-only采集。事先契约排除所有派生matching/epochs/owner-id/tally/残留/分类，完整原输出保留。主控tag native-s1t2-gui-raw-1021-55071f85：543manifest6ce2a049/binary964871b1，同a27/non-release/官方SDK+manifest/Session1非提权；一次C-link8.314秒exit0、fresh进程1.921秒exit0/stderr0，3cycle15stage/3018raw、完整scroll/close路径。before→after USER/GDI分别+3/+10、0/0、0/0；stage初Host13/9但不能归属关闭后的4/10，API次数/原font handle DeleteObject BOOL1不证明全部OS对象释放。22:07:36Z Ready/进程空，原始/C/源543/flags/hash/方法报告/排除契约/重算JSON全空间外保全。正常退出仅diagnostic_completed，原fresh预算FAIL仍阻塞未证；到raw事实停止，不自动第二对照/矩阵或第三原策略补丁、不改产品/tests/阈值。全T2/T3仍未通过。

用户本轮明确“继续”：不再微补丁5507，而以最小bare Win32宿主新对照推进。85bc只本地新probe_win32_bare_resources.nim/既有报告，完全无Leaf模块/fixture，仅stdlib+官方Win32 FFI，一进程3次同style/size/SDK/manifest窗口register/create/geometry/show/destroy/unregister，分阶段counts/API返回与即时error，WndProc仅DefWindowProc，无预热/主动pump/GC/策略setter或新ledger。先新probe codegen，原主控预检后至多单候选120s编译/30s执行；作者不Native。相同读数只证直接Win32足以触发样本，不系统归属/无漏；不同也不预判Leaf漏。原产品/正式tests/旧probe/阈值保持，预算与fullT2/T3仍open。

bare9905已主控一次真实Native：544manifestdc41e5aa/binary68389bca，compile4.043秒0/process1.071秒自然0/stderr0，24stage/PMv2/96DPI/三own Destroy+Unregister1，compiled模块无Leaf。首轮1/0→create3/0→show13/9→close4/9（+3/+9），后2轮4/9→4/9；不运行Leaf也足以触发此样本，不证系统owner或产品无漏。11:37:56Z Ready/进程空、全部证据空间外保全。与Leaf末4/10差1仅计数差，下一单变量新bare_dc probe仅加GetDC(host)/ReleaseDC同dc与两stage，依据measure112–119/63，不加font/theme/ledger/预热/DestroyDC/改阈值。作者本地codegen后主控审单候选一次Native，旧coldFAIL/产品/test冻结，fullT2/T3仍open。

bare DC修正7eef仅小修真实借用flag/失败owner guard/DWORD后主控一次Native：545manifest e8bd67fd/binary c3d3a5f6，compile1.377秒0/process1.441秒自然0/stderr0，30stage/三ReleaseDC1+Destroy1+Unregister1/borrowed=false。每轮show13/9→get13/10→release13/9→close4/9，首次+3/+9后2次0；单独DC借还不支持Leaf额外GDI1的解释。11:47:23Z Ready/进程空，完整源/C/命令/raw/hash空间外保全。下一新bare_font只复现measure104–143消息字体create/select/metrics/restore/DC归还/Delete私有font，原作者本地codegen、主控审单候选一次，不加Leaf/控件/theme/ledger/预热/改阈值。旧budgetFAIL保持，fullT2/T3仍open。

bare字体60e7也已一次Native：546manifest52382c6c，compile1.519秒0/process1.318秒自然0/stderr0，48stage/完整restore原font及Release/Delete/Destroy/Unregister1，无Leaf；font使GDI9→10、DC→11、restore后Release→10、Delete→9，末USER4/GDI9，后2cycle增量0。11:54:01Z Ready/进程空/完整证据空间外保全。下一本轮最后bare_theme：直接对应measureCheckbox250–280的text extent、host BUTTON theme open/part/margins/close后原font/DC/host释放，各步采样，不新控件/ledger/配置变体；作者本地codegen、主控审单候选一次。若仍不复制Leaf差1即停新增变量汇总；旧coldFAIL/产品原tests阈值不动，fullT2/T3未过。

最后bare_theme f9e0已单次主控构建：547manifestb3c987d2，C/link1.806秒exit1；[Link]的`__imp_OpenThemeDataForDpi`未解析，命令已有-luxtheme，不是头声明缺失/产品资源RED。没有EXE/Native进程/63stage数据，不能称假设被证伪。12:04:37Z Ready/进程空，全部源/C/objects/args/失败日志空间外保全，产品/tests/阈值未变。按单候选边界不自动改SDK/动态导入或重试，本轮停止新增比较，差1归属未知/cold预算FAIL/fullT2与T3均未过。

用户随后“好的，继续”授权续接：仅按现有api.nim uxtheme.dll动态导入修正bare_theme静态importlib链接方法，作者本地codegen保留f9e0/原失败，21stage/3cycle/API参数及预算不动。主控审核后修正候选至多一次编译120s/进程30s，核对加载发生于before之前与否，不扩新变量或SDK/产品修改。未实跑前链接/主题假设仍未验证。

b6c8 DLL修正后唯一实跑已完成：547manifestb6d917db/binaryf4ab1b9b，C/link4.368秒0/process1.111秒自然0/stderr0，63stage错误全0/三轮text extent28x15/theme part13x13/margins0/close HRESULT0、原font恢复/Release/Delete/Destroy/Unregister均1、flags false。每轮末4/9/首次+3/+9后0/0，与bare/DC/font一致，未复制Leaf4/10差1；不能据此推广产品漏/无漏或OS归属。实际DLL由C main后PreMain/DatInit加载，在Nim用户main/before前，未覆盖加载前后取样；原报告过强“加载不增资源”已撤回。18:21:32Z Ready/进程空，完整源/C/二进制/raw/manifest/hash空间外保全。该原始资源调查累计6次C/link（5成功1失败）/5Native进程，f9未运行不抹去；现按有界计划停止追加API/控件/配置比较，不改变原budgetFAIL/产品/tests/阈值，完整T2/T3仍未过。

用户再“继续”后转策略：停止追加bare API/控件变体，原疑难角色d4同profile/cwd/Workspace仅只读实际Leaf测量/控件/裁剪路径与已有raw，唯一既有分析稿末补至多一个有区分力下一实验设计，先辨证缺陷/假设/OS隐式对象不可枚举边界。latest规则/profiles已核，原作者85bc停写；不新probe/编译/Native/SDK/阈值/产品，等待真实诊断完成。不是重复验收盖章或换模型试错，coldFAIL与fullT2/T3保持。

d4新诊断已返回未定位：真实measureText限宽走DrawTextW，bare只有textExtent、5507无实际SelectObject恢复凭证；隐式OS对象不能用总量枚举。唯一下一实验已由主控交原85bc本地新probe/既有报告：原真实cold fixture一cycle/5rows/7scroll8settle，只6个font/DC/draw seam和5stage，512定容原始区间收据/参数/RECT/返回/异常/前后USER-GDI即时errors，完整保存恢复LastError，无分配observer/owner匹配推导/预热/新调用。候选预检后主控单次编译120s/进程30s；缺DrawText/路径/容量/采样或末值不复制/运行失败即保全停，成功也仅动态区间而非对象身份或budgetPASS。产品/旧tests/probes/阈值仍冻结，不扩bare矩阵，原coldFAIL/T2/T3未过。

cf58唯一Leaf观测已实跑：compile11.575秒0/process1.775秒自然0/stderr0/548manifestc9932840，5stage路径完整末4/10/236receipt无溢出。26DrawText前后GDI全不增、52真实相邻font恢复/DC归还组参数正确；差1在font创建9→10返回后与首GetDC入站11之间已存在，USER14→35，不支持H但对象未定位。最终私有font Delete1为11→10，成功GetDC的TLS6不当失败。01:12:07Z Ready/进程空/全sourceC+raw+binary/argv/hash空间外保全；按界停止继续拆总量，原cold预算FAIL保持。

接着推进原已批准且独立的T2 10k首尾/大range读回：原85bc只新test_win32_list_navigation.nim/既有报告本地codegen，2case10k×24可见首尾+合法高行使投影units>65535(不假造trackPos或称物理thumbdrag)，真实GetScrollInfo须对应相同applied offset/至多一单位量化。产品/旧tests/probes/阈值不动，主控预检后一次编译120s/新测试程序30s；静态nMax+nPage重复扣viewport疑点须真实RED才可最小修。资源门仍FAIL不因独立门通过覆盖，fullT2/T3未解锁。

navigation f39已真实RED：549manifest7a45e547，C/link9.379秒0/进程3.998秒自然1/stderr0，完整2cases1OK1FAIL；10k首尾通过，高行Native nMax319997/page4/pos319994比独立Wanted319996差2>1，唯一失败且尾根/超16bit/回top/正常close前提全成立。01:21:17Z Ready/进程空/证据空间外保全。仅原85bc可修list_host.syncScrollbar范围映射(int64中间/32bit界)，全部tests/probes/其它产品冻结；稳定候选主控导航2case一次GREEN后旧line/wheel精确两filter风险回归，再独立验收，不重跑cold/hang/资源矩阵。不把产品范围RED与冷资源FAIL混为一因，T2/T3未解锁。

导航修正3084已实际GREEN：syncScrollbar单文件13增3删，f39测试未改；549manifest3e0f721f，导航编译9.303秒0/进程2.502秒自然0/stderr0/2OK，case2 nMax320000/page4/pos319996/Wanted319996/delta0。串行旧lists只line/wheel两个完整精确过滤器：compile10.744秒0/进程3.469秒0/stderr0/2OK，未跑旧cold/hang/其它14。01:25:36Z Ready/进程空，全源C/bin/raw/argv/hash空间外保全、两个549唯一源差list_host。b732同profile只独立review-navigation有限验收，不新Native/改源；作者停写。page0/empty/超大total静态证明不当额外Native覆盖，原资源预算FAIL/T2/T3/物理thumb/真实IME仍未过。

review-navigation已独立通过并由主控实读证据后接受10k首尾/原生大range读回修复+已执行line/wheel限定切片，不扩fullT2/资源/真实thumb。主控附报告口径纠正与具名postchecks：total1e11/viewport120的page1/nMax2^30，极端viewport5e10才nMax2^31−1，均静态非Native；先前alloc限定接受保留，本导航未重跑不等于重开它。

下一原定漏项仅新row_state_alloc probe/既有报告：原85bc沿行独立State fixture、父10k源一次，row0自己的State两hot更新；要求source/父render/typed binding/HWND集合不变、creates0/真实Native值更新，逐窗实际accept1/pub1/三Nim围栏0，attach confirm-only N/A照旧。release/ORC/allocstats/probes精确计量，新file codegen→主控审单次Native(120s/30s)，所有产品/旧tests/probes冻结，不因新增覆盖臆造旧RED或修改产品。cold预算FAIL/完整资源/T2/T3/真实IME仍未过。

row-state4b7f已主控一次Native：550manifestdc88a92d/binb8af31f0、compile15.458秒0/process3.136秒自然0/stderr0，release/ORC/probes/allocstats；4测量窗attach actualaccept1/pub0/managed-host−1 N/A/native0，initial与两次row0自己State更新各actualaccept1/pub1/三Nim0/rev2..4。父render1/source1/root2不变，后端行creates26不增、26窗口集稳定/live5/idle0，真Native label v1/v2+checkbox1/0+EDIT空及其它4bindings/label无变。01:45:08Z Ready/进程空，全源C/raw/bin/argv/hash保全；与旧549唯一新probe，无产品修复/旧probe重跑，原初d7方法缺口/错误attempt保留。b732只独立review-row-state限定验收中，不把一program4window当4程序、Nim0当所有Native0、或覆盖资源预算/fullT2/T3。

review-row-state已独立通过并经主控核source/C/raw/hash/flags/前提后接受same-source行内State＋本4window Nim围栏限定覆盖，无产品修复/不捏造RED。主控附报告口径澄清：只两hot指纹打印相同，与初始靠真实集合断言；具名postcheck/summary实际在geometry-verification父目录与空间外；Nim0不代表OS0，但不因此另造未获批OS分配0要求或重开旧已接收围栏。

下一仅原方案角色8c同profile/Workspace在既有brief末设计实际变高行/锚点：先数据流/HeightIndex候选隔离与失败恢复/accept0分配/safe-turn有界，再最小首Native RED与实现文件范围，依赖分片测高→key+delta anchor/resize/source。当前不编码/编译/Native/派发实施/Git/新空间，方案返回主控判断；85bc/b732/d4停写，所有代码/tests/probes冻结，原cold预算FAIL与fullT2/T3/GPUI不变。

8c已补brief166+变高行/锚点方案并停：主控采纳私有accepted/prepared native frame、显式HeightIndex clone、旧frame rollback pin/预留retire、accept0alloc move/swap及geometry-only一致事务；实际clientWidth已接、测高未入index为静态缺口，不当运行根因。当前只准原85bc新variable probe+backend probe-only只读rowWindowForTest（typed store索引，无rawRoot/owner改动）和report/codegen，未准接测高产品修复。首Native RED固定20key/estimate24/交替24-48根height/viewport120/overscan0、两显式safeTurn后精确typed4行及实际rect/clip，编译120s/程序30s单候选。实现要等Runtime RED，首片须有基础候选隔离/同源热变placement失败恢复/围栏证据；anchor/resize/font/source后续依赖分片，不因设计跳过事务或预算。coldFAIL/fullT2/T3/IME不变。

variable首e5已主控真实RED：551manifest121f282c/binf123d0d3，C/link15.013秒0/process1.274秒自然1/stderr0，463x120/DPI96/typed-row采样有效、两显式safeTurn仍5行全24且位置按estimate、8断言失败/正常close。clip一项为错误rowtop的派生不独立clip bug，诊断scroll_ticks4是scrollbars不是turn次数。02:23:59Z Ready/进程空/全证据保全。原e5冻结，现原85bc仅backend/list_host私有accepted-prepared frame/height_index clone+必要新测试本地实施，report§20先计划；不得改公共协议/owner/core/旧tests/probes或GC。必须基础事务隔离和accept0alloc/restore旧frame，先本地clone测试/codegen→主控e5单pilot120s/30s；首屏GREEN后串行测后placement失败/同源热变/必要围栏回归/独立验收，未有GREEN不称完成。cold预算FAIL/fullT2/T3/IME继续open。

frame首本地候选de09/a410静态预检未过，未Native：apply内逐list早发布/清pin，真正accept无frame publication，HeightIndex赋值C实际eqcopy/setLen潜在分配不是swap，restore先重测后装pin，失败DTO丢失，exact集合误拒合法overscan/protected且geometry-only先改applied。新txn预期错误窗口会自动计失败、注入缺现场测后凭证等已合并一次返原85bc原范围本地修，先§20.2；纯clone3OK/4codegen0与全部尝试保留，不是Native通过。修后再主控原定唯一pilot，不因首屏可绿忽略完整事务，coldFAIL/T2/T3仍未过。

本地R1 a085/60fa实读后仍未Native：accept publication/ref交换已有进展，restore旧pin却被清空且unused local未回装，geometry-only/候选scrollbar与失败诊断/txn采样收口仍缺。原候选/报告已外存，已交原作者第二轮R2原范围修正，先§20.3；R2后同根因第三轮前暂停按止损判断诊断。四codegen0/clone3OK不能替代Native或事务接受，原e5唯一pilot仍待稳定候选，coldFAIL/T2/T3不变。

R2 eea447d2/5663f758/06eb492a后的原e5唯一pilot已实际FAIL（tag `native-s1t2-variable-pilot-1022-eea447d2`）：C/link0、Native自然1，第一turn空、第二仍5行，前四实际高度/位置与clip正确但typed fifth未裁，3FAIL/close正常，Ready/owned[]；源551仅三产品变、全证据外存。未追加turn/txn/回归；同目标两轮修复后停止普通第三轮，d4只读诊断bootstrap事实与Native replay/scrollbar完整事务路径，主控读结果再交实现，不当GPT验收盖章。首片尚未接受，coldFAIL/T2/T3不变。

d4只读诊断f3619e1a定位bootstrap publication清want误吞首facts，并给出统一typed投影plan apply/replay整改；主控核验采纳，不是验收。85bc在§21交接后因自报上下文承载不足未动产品即停，核idle/基线不变；最新复杂编码profile同DeepSeek high在当前Workspace新Agent Tab 0ecc5ed9接§22，无新空间/branch/Native/模型通道替换，历史失败次数不重置。仅原三文件/限定新test与local artifacts，完整诊断实施后主控审单e5再按依赖验收；不微修want交局部。Native累计2/2仍红，coldFAIL/T2/T3未过。

R4(6791/a36a/06eb/3604)已有5次同product Native GREEN：原e5两turn正确、A/B事务及逐commit三Nim fence/实际旧plan重放、原4b/f39与3精确旧焦点几何选择回归；全源/C/bin/raw与Ready/owned[]已保全。首片独立验收b732遭实际429 GoUsageLimitError未出报告，最新profiles无验收角色已授权备用，故独立验收受阻而非首片已接受。主控将只补问本次GPT只读验收备用授权，不静默改模型/配置或重试，等待期间不推进依赖后续门。完整T2/T3/coldFAIL不变。

用户已更新profiles并要求继续，最新功能验收为MiniMax-M3.1-Flash/high；旧GLM端停止/无报告，未自动变model。主控按新配置在原Workspace新Tab a5447d7b短快照独立验收R4，避免迁入533k旧史，不改配置/既有session、不重跑Native/新空间；不再等待GPT备用批准。独立完成主控核报告后继续后续门，尚未宣称首片接受；既有5NativeGREEN与coldFAIL/T2/T3边界不变。

variable首片MiniMax独立报告58d2f4b8已由主控全文核验并限定接受（offset0/same-source/fixed环境/overscan0、State成功与测后placement失败恢复、fences及实跑回归）。口径校正保存主控台账，不重跑。下一同rowset纯geometry滚动是anchor前提，复用8c按最新常规编码GPT配置只写新Native probe：overscan1保同五行/真实lineDown intent24/2prime+2scroll；不先修产品、不改旧e5，当前新门Native0。完成本地冻结后主控再单次Native取RED/coverage，再决定实现。coldFAIL/fullT2/T3不因首片接受而通过。

同rowset scroll新门已首次实际Native，但停在overscan1 prime契约：冻结501probe、B1742只读11行hook；C/link0/程序自然1，2prime仍6根而非5、trimPendingtrue，close正常/Ready/owned[]，未发WM_VSCROLL。它是overscan trim实际RED，不是scroll/anchor RED；源码定位expanded needed范围与裸lastfact混域抑制了trim。返8c仅最小B/L ack域修正，旧probe冻结/不加turn/不改Runtime/先不修未到达scroll；本地稳定后主控再单跑同501。新门1/1，首片限定接受和coldFAIL/fullT2/T3边界不动。

### T3：Windows native pack（待T2通过）

保留pack公共签名，限定Windows native分支和相应测试；生成无GPUI/Cargo前提的EXE/manifest/resources/config/backend/许可证/ZIP/SHA256。保留路径边界、架构校验、无覆盖与失败原子发布；不同cwd/中文空格路径/无桥库环境实际解包开窗口、资产和SQLite重开；--check仅包自检一部分。不顺带迁移全部SDK/安装器/CI或提前删GPUI。

## 执行台账

阶段变更和 Agent/快照/验收结果统一记录在 `docs/progress.md`。原会话负责文档、环境安装与 Windows 测试串行协调；开发者只写派发范围，验收者默认只读。当前不执行提交/合并/推送/发布/归档。

### S2 设备 TaskService 后续验收片

在已验4-kind Views/JNI/mobile_host上加独立 tests/android/tasks fixture，不复制业务Runtime、不改产品协议。以真实按钮启动TaskWork，记录worker/UI线程号；真实HOME触发onPause后释放worker，断言callback与accepted/native值仍pending；回前台立即recreate，结果只写新挂载的TextView且factory/init均1。再启动阻塞任务，finish后取消被worker观察、无额外onResult/onError、组件dispose1。所有等待为fixture有界postDelayed检查；达到return不单独当queue完成证明，完整onResult才证完成。原API36 AVD实跑并核实际APK/so/hash/截图，未知API26/arm64/16KiB/资源预算仍未验；有产品缺陷交回主控普通修复，再独立验收。

### S2 受控编辑器接线顺序（继续原批准范围）

下一步以现有native_edit为唯一组合输入/受控值/reset状态机：先实现Android私有多控件协调层与失败/排队/候选回滚测试，再接AndroidBackend prepared模型/只移动accept、普通settle与reset effects；最后扩展显式长度UTF8 JNI facts、每View setter-depth、EditText/InputConnectionWrapper及真实设备验证。普通属性写值不得覆盖未settle的更晚编辑或composition，显式reset只在全部nativeeffects成功后consume，失败由既有faultBackendEffects冻结保owner。后台IME结束facts与pause顺序须单列；TextWatcher不能单独代表finishComposingText。未贯通前不声明input/reset capabilities。TaskService验收期间只新增未被旧片导入的私有协调模块/测试，不改其冻结产品输入。

### S2 剩余基础控件片（输入片验收后串行接入）

沿用现有typed frame、native_edit和BackendSession，不增业务树。checkbox映射CheckBox，toggle映射平台Switch，progress映射确定ProgressBar，spinner映射不确定ProgressBar，tag映射原生TextView，separator映射带平台listDivider drawable的View。variant仍按已有compatible/strict诊断，不声称未实现的装饰能力；virtualList仍明确不支持，留下一独立片。

- ABI1四基础kind/LAV1与ABI2输入/LAV2保持；ABI3显式启用剩余基础控件，LAV3增加checked/progress字段。旧callbacks不因新实现自动声明能力。checkbox/toggle沿用EditorState的isCheck/setChecked，无输入选区查询与composition；resetToken仍仅input合法。
- 新checked C/JNI事实携带同一组八个身份字段和0/1值，校验后enqueue，再记native事实；不把toggle当click冒充，不在原生监听内执行业务。每CompoundButton自己的setter-depth抑制自身回声，不能屏蔽另一控件的真实变化；旧View/旧epoch/paused/disabled事实不得进入业务，paused事实按既有前台快照原则处理。
- model checked只通过预备editor effects和普通settle写入；拒绝/no-diff更改必须还原accepted值。props只改label/enabled/progress等普通字段，不能抢写尚未settle的checked。准备/回放所有typed元数据完整，失败沿用accepted replay与fault清理owner。
- 先本机测试能力分层、混合input/check身份与无diff拒绝、双控件序列/暂停/旧绑定、进度字段和三代wire；再真实C caller；最后独立APK设备验证真实tap CheckBox/Switch、拒绝还原、disabled无业务、稳定View、程序写无回声、另一控件重入、进度/不确定条/标签/分隔线UI和失败回放。原输入fixture作为受影响回归，不重跑不变Windows矩阵。
- 文件限定Android backend/ffi/wire、include/leaf_android.h、Android JNI/Kotlin，新增独立controls fixture/tests；共享Runtime/Session/native_edit不改。输入验收未返回前只固定本边界，不写其冻结产品文件。

### S2 Android 列表几何基础与后续 RecyclerView 接线

先以未被现有产品导入的 Android 私有 list_geometry 模块验证：复用共享 HeightIndex/listVisible/NativeRowBinding，candidate 深拷贝并在 publish 只交换引用，failed/discard 不改 accepted；宽/DPI scale/fontEpoch/source/count/mode/estimate 任一上下文变化使离屏测量失效；同源无新用户意图时按已知稳定 key 保持首行 intra-row delta（行缩短则截到新行尾），新意图优先，prepare/apply 期间新意图不能被旧 publish 覆盖。visible 始终裸范围，Runtime 加 overscan 一次；不在此模块 materialize 或调用业务。空列表、10万项/大 logical total、无效测量与 typed row 身份均受测。新模块未导入前不改变当前控件快照或声明 virtualList 能力。

随后串行接 Android typed list/row metadata、native RecyclerView 的 accepted-row 复用与 viewport facts、safe-turn materialization；factory/bind 只读 accepted 行/登记事实，禁止递归业务。RecyclerView 相关依赖先核本机缓存及官方接口，缺工具包不冒称运行；真实滚动/复合行/事件旧绑定/失败回放/输入保护/100k预算/生命周期分别验证。此基础通过也不是 Android list 或完整 S2 通过。

列表接线实现约束：RecyclerView 采用自定义 LayoutManager 投影唯一 accepted geometry；触摸/惯性回调只登记 desired DIP offset，并由当前 Activity 的普通 frame safe-turn 完成 row request/候选投影，不从 bind/layout 调业务。Adapter只持 accepted materialized typed rows，ViewHolder 包装原生复合行；逻辑itemCount/total与物理行槽数分开，Scrollbar/无障碍按逻辑范围投影，不序列化100k heights或启动创建100k Views。prepare后新intent保留，几何-only turn不得引起父组件render/业务revision，失败回放固定accepted geometry/metadata；重复fact以frame/intent身份ack避免失败自旋。共享LayoutScope测量/布局行子树，typed list/row metadata须进入每次create/update/replay，protected焦点/IME行保留，旧View/source/session/binding拒绝。native LayoutManager 读accepted box且不另建冲突HeightIndex；官方接口参考 https://developer.android.com/reference/androidx/recyclerview/widget/RecyclerView.LayoutManager 与固定依赖release页。

接线分层采用 Android 私有 list_layout（多列表候选/共享子树布局/typed 身份/裸 viewport receipt）和 list_delivery（把 receipt 交给已有 BackendSession.queueRows，成功入队才 ack）。整个候选布局完成才可发布，任一后续列表测量失败须 discard 已准备的前序列表；publish 只交换预备引用。变量行用有限 MaxListDimension 作为 intrinsic 高度约束，固定行按声明高度；宽 0 是合法折叠上下文，恢复宽度重新测量。list_delivery 只记录事实，业务仍由 retained MobileHost 普通 safeTurn 在 resumed 时执行；失败事实已 ack，不因空闲帧自动重复，新的 intent 可显式再试。该内部桥接由 ABI 先核 UI owner/所属 adapter-session；不把它当对外身份校验入口。模块未接 Android Backend/RecyclerView 前只宣称 Linux 基础覆盖。

### S3 ComponentRouter 历史与返回提案接线顺序

沿用已批准的共享 ComponentRouter，不新增第二套 Router/PageGroup。先加入独立 owned NavigationState 值层，再将现有 route State[int] 改为 State[NavigationState]：navigate 只选择当前地址、不增长历史、同地址不改值；push 即使同地址也追加身份不同的条目；replace 替换栈顶；pop 在根保持原值。历史最多 MaxNodes 条，条目只存路由索引与单调身份，不复制闭包/路由字符串。快照显式复制 seq，多个 queueUpdate 在同一候选中按顺序折叠；失败不发布历史，不自动重试。

系统返回先从 accepted history 生成只读提案，包含 router/request/revision/from/to/depth；历史已变或重复完成不得再 pop，根返回交 Host。取消的原生请求还必须在 Host/Router 请求生命周期中失效，单纯丢弃值提案不当作取消回调防护已完成。session/mount/owner/sequence 门、typed native navigation payload、Android/Win32 原生容器和异步动画确认后续串行接线；值层与 headless 通过不等于原生导航完成。先验证现有路由兼容、保留页 State、candidate/consumer 故障与重复/过期返回，再验证真实平台链路。

当前共享 Controller 已加入独立请求账本，cancelBack 在 confirmBack 成功入队前使请求失效；confirmBack 只表示入队，失败后新请求才可再试。副本共享账本并核 UI/正在执行 Runtime；这不替代尚未实现的原生 session/mount/owner/sequence 门与动画生命周期。


### S3 原生 typed 宿主接线（共享状态验收后串行执行）

保留 renderPage 的透明出口；新增显式 renderNavigation，生成独立 navigation NodeKind（旧 kind ordinal 不变）与单个当前 pageOutlet 子树，不把普通 column 当作平台导航支持。纯 navigation_protocol 保存 router/history/current/previous/depth，native_navigation 只收有界事实；动画完成是另一类型，不作为 pop。Node/HostProps/HostRecord/HostOp/MountedEntity/UpdateOp/replay 均保留完整 typed 元数据；只有历史变而普通 props 不变也必须发送 update。candidate 校验必须拒绝缺失/错位元数据和非单子树导航容器，原生能力未声明前拒绝；旧 GPUI wire 明确拒绝新 native kind/字段，不扩旧 ABI。

新增 back 事件仅属于原生 navigation 节点，携带 requestId；renderNavigation 的回调通过同一 Controller/普通 Runtime 事务生成并确认提案，不改写栈或在 native 回调执行业务。Session 对 typed begin/cancel/confirm 做 session/mount/handle/binding/sequence/accepted revision/history 双重核验；confirm 必须与普通点击共用有序事件队列，不能先 drain 独立 back 队列而颠倒点击顺序。取消在普通消费前可撤销已排 confirm；消费/失败不自动重试，恢复/移除/重绑定 retire 旧请求。原生 accepted metadata 发布不新增业务或 setter；每次普通 drain 再校验。

Android 新能力仅 ABI5/LAV5 显式启用，ABI1–4保持原门与布局。先接无动画的真实单栈容器/系统 back 纵向片；异步平台动画、取消可视预览与并发请求调度分别覆盖，不能凭事实模块宣称完成。API33平台 OnBackInvokedDispatcher、API34 OnBackAnimationCallback 才有 start/progress/cancel；API26–32使用兼容入口并单列未运行矩阵。根没有可 pop 项时不拦系统返回；不使用 overlay 优先级抢占输入法。参考已核官方页面：[OnBackAnimationCallback](https://developer.android.com/reference/android/window/OnBackAnimationCallback)、[OnBackInvokedDispatcher](https://developer.android.com/reference/android/window/OnBackInvokedDispatcher)、[predictive back](https://developer.android.com/guide/navigation/custom-back/predictive-back-gesture)。

Windows 在 capability/真实 HWND 容器与键盘返回接线和 Native 证据前不声明新 navigation 支持；共享 typed/headless 通过不代表 Win32/Android 已通过。自测先覆盖元数据单独更新/完整 replay/原子失败/拒绝旧 wire，再新 C ABI/JNI/设备与受影响旧 ABI 回归；独立验收仍按实际快照。


### Android 导航 ABI5/LAV5 接线约束（共享宿主验收期间固定接口测试）

- 保持 callback struct 大小与 command tags。仅 abiVersion=5 开启 navigation；1–4 旧能力不变。LAV5 保留 LAV4 字段及尾段，在每 op 的 list/row 之后追加 u32 hasBack / u32 hasNavigation；有导航时追加 u64 router/history/current/previous、u32 depth、u64 binding。初始原生绑定为1，旧事件仍同时受 session/mount/handle 与历史身份约束；不增加平台业务栈。
- V5 create/update 验 kind↔metadata、深度/端点；旧版本遇导航sidecar/kind/back标志明确拒绝。measure/full replay 必须保留相同字段；native apply 中观察到的候选事实不能作为 accepted completion。
- MobileHost.queueNavigation 与普通 enqueue 同用生命周期门，拒绝 paused/stale/closed。JNI 只转固定整数事实到 C ABI，begin/cancel/confirm 不执行同步业务；safeTurn 继续走 Session 原普通队列。
- 新 adapter/wire 测试覆盖元数据-only更新、partial apply后完整回放、新request显式重试、paused取消/恢复、detach旧facts拒绝以及LAV1–4隔离。平台测试另覆盖单活动页真实View、系统返回、root不拦截、Activity重建保业务、accepted-only注册与失败后不重复pop；首片不宣称动画或API26运行。

## S2 后续：Android 项目工具链接入（资源片接受后实施）

当前仅固定后续接口与验收，不在 SQLite/资源的独立验收期间修改 targets/build/CLI 或提前实现依赖入口。继续复用当前 Workspace，主控内联实现与自测，原功能验收 Agent 复验；不另建分支或 Workspace。

### 项目与入口

- `leaf build --target android [--backend native]` 输出 debug APK；`leaf run --target android --device SERIAL` 构建、安装并启动；`leaf pack --target android [--binary APK]` 验证并交付 APK + checksum/licenses。Android 不接受 GPUI 或 headless/watch，不回落桌面进程。
- 保留桌面 `entry`、现有 JSON 严格校验与默认行为；新增 `platforms.android`，包含显式 Nim `entry`、`minSdk`（默认26）、`targetSdk`（默认36）、`versionCode`（默认1）、`abis`（初始只 arm64-v8a/x86_64，默认两者）。Android entry 必须被 include 覆盖且是项目内真实 Nim 文件，不从桌面 factory 名称猜测注册函数。
- Android entry 导入同一业务组件并注册 ApplicationFactory 或 ResourceApplicationFactory；新 `leaf/mobile` 导出组件与工厂/资源入口，避免导入桌面 runner。普通 `import leaf` 的 Android 分支也不得隐式 import GPUI/Win32；桌面 run 在移动目标须给明确使用移动工厂的诊断。
- CLI 生成薄 Kotlin MainActivity/manifest/Gradle glue，Nim entry 仍在主 UI 线程 NimMain 时初始化一次。应用 identifier 使用 Kotlin-safe 的 Android 包名校验；不把当前允许的 identifier 连字符直接嵌入 Kotlin package。版本/label 需独立转义，不拼接任意源码。
- assets 仅从显式包含且通过现有 canonical/symlink 校验的项目 assets 目录复制；必要迁移可由业务 catalog 静态编译，也可使用 HostResources 读 APK assets。源码/资源/许可证必须从项目配置与 SDK 根解析，不能依赖主控 target/fixture 路径。

### 工具链与进程

- 发现已有 ANDROID_HOME（兼容 ANDROID_SDK_ROOT但冲突拒绝）、NDK、JDK、Gradle、Nim；doctor 报实际路径/版本/缺项。不自动下载 SDK/接受许可证、不改系统配置、不写入绝对本机开发路径。AGP9.0.1/Gradle9.1.0/BuildTools36.0.0/现有 Kotlin 插件为当前已验证组合；本机 JDK21 已实跑，不把 AGP最低17写成必须21。
- NDK API使用minSdk，线程/ORC/noMain与SQLite同一链接策略；各架构独立cache/out，JNI附加 -landroid/16KiB LOAD对齐。Nim路径开关沿用现有美元转义，不将shell quoting用于结构化argv。
- AndroidBuildJob 维护有限 NDK→Gradle→制品校验阶段，复用 ManagedProcess 的有界输出与进程组清理；poll推进一个已完成子进程，非UI消息循环内同步等待。取消/失败保原日志，不生成“完成APK”；不以shell脚本串联替代现有跨平台process owner。
- run 仅对显式 --device 或唯一可用设备执行；多设备必须拒绝而不是选择第一台。adb argv结构化，安装-r保留已有数据；不clear、不卸载、不改变签名/认证。debug APK不是商店发布/AAB。build与pack不需要连接设备。
- doctor Android分支不探Rust/GPUI/显示会话。缺工具、离线依赖缺失、架构不匹配明确诊断；旧doctor/build/headless路径保留。

### 制品与验证

- 库 ELF 检查目标架构、LOAD对齐、无GPUI/动态SQLite；APK 检查manifest包名/版本、目标ABI库、资源与license。复用现有archive/package/no-overwrite发布机制；--binary误传桌面ELF/so或别的package APK均拒绝。debug APK需可安装启动，不能仅so/ZIP存在算成功。
- 单元先测CLI/JSON/target选择与错误前置、stage argv/取消/有界输出、APK校验和输出不覆盖；模拟工具只验证流程控制，不能当真实SDK/Android运行。
- 实际从新leaf.json项目、共用组件与资源/数据库工厂，经**已编译的leaf CLI** build→pack→移动输出→run --device emulator-5560；在不含Cargo/Rust的受控PATH下，核APK/安装包/库哈希一致，真实tap输入/保存、HOME/recreate/force-stop恢复。新项目entry/pack下载入口是必验，不用现有fixture Gradle成功替代。
- 两套 scaffold 分后续受影响片：init生成共享业务工厂+移动注册；完整scaffold向工厂传私有DB路径并在Runtime终态关闭，保留executionScope。先明确现有业务DB调用者所有权，不自动关闭调用者传入的连接。生成→迁移→CRUD→退出重开实际验证后才称移动scaffold支持。
- API26–35/arm64真机/16KiB运行、签名商店发布、Windows native pack/T2、cold旧FAIL及完整目标继续独立列门；不由CLI切片通过覆盖。

接口依据：Android AGP9.0.1官方兼容表 https://developer.android.com/build/releases/agp-9-0-0-release-notes （Gradle9.1.0、JDK17最低）；SDK环境变量 https://developer.android.com/tools/variables 。当前已装JDK21是实跑配置，不代表支持任意更高JDK。
