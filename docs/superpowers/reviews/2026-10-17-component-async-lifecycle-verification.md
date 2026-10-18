# 组件异步任务与生命周期验证记录

当前状态（2026-10-18）：Task1–7 实现、整分支修复与固定差异复核已完成，并已合并主分支、推送；Task6 原先缺少 Windows 实跑；2026-10-18 首轮 12 通过/4 失败日志保留，四项测试夹具修复后的七套非提权交互开发自测及独立复验均为 96/0 通过，见[环境记录](../../windows-environment.md)。当前不授予完整平台支持或 H 门通过结论。最终修复复核与合并记录见[合并验收](2026-10-17-component-async-lifecycle-local-merge-verification.md)，`c207e48` 的最新 CI 与待验范围见[开发进度](../../progress.md)。本页各节按时间保留当时冻结 HEAD、失败、待审查与平台限制；不得用后续通过覆盖原证据，也不把早期未合并状态当作当前状态。

## 身份与执行空间

- 产品基线：`53368cf2a554c52af092d129f0aeb2b592c8d78f`；规格 `247cda9`、实施计划 `bf2f967`。
- Task1 实现：`bf90ee52a75d16de91ed5dbff25082dbf3b68ac6`，仅新增 contracts、worker、16项定向测试及两个线程/闭包fixture；既有生产源码、runner、依赖与ABI未修改。
- 原协调Agent：`22171a3c-32d8-4ff6-baab-8ed6a7a22963`，原workspace `wks_fd0d6c1dbee5f84c`。
- 执行workspace：`wks_e30c036ebfafb4d4`，路径 `/home/jimxl/.paseo/worktrees/1c1rvoii/component-async-lifecycle-implementation`，分支 `feat/component-async-lifecycle`。此前规格空间 `wks_43c47436537996f7` 已不在活动列表且目录不存在；分支和文档提交完整，已通过Paseo重新检出原分支。
- 实现Agent：`4a08bb10-9ab0-4a6b-9794-58163ef7a797`；独立验收Agent：`8fdca2e1-7ecb-49c8-9932-eb2ab17fdb9c`。后续复用这些相关会话，不在各阶段另建workspace。

## Task1 实际检查

| 检查 | 结果 |
| --- | --- |
| 普通Nim2.2.6/ORC/threads:on worker定向 | EXIT0，16项通过；含500轮栅栏排队/取消/ack、64任务、单1MiB及合计8MiB边界、合法Unicode错误信息和保留ticket时pool销毁 |
| closure负fixture | 预期EXIT1，精确因closure/nimcall calling convention mismatch，非缺模块或链接错误 |
| threads:off兼容fixture | EXIT0，旧组件真实创建/导出Snapshot；worker启动明确拒绝 |
| ASan最终定向 | EXIT0，15项通过，显式`ASAN_OPTIONS=detect_leaks=0`；默认allocator内存计量项由普通16项覆盖 |
| 官方Nim全量 `scripts/test.nim` | EXIT0，92套件；Windows/PowerShell等平台跳过项保留SKIPPED |
| 独立Task1架构审查 | Spec compliant，Task quality Approved，Critical0/Important0/Minor0 |

官方全量命令：

```sh
NIM=/tmp/nim-2.2.6/bin/nim \
LIBRARY_PATH=/tmp/mui-display/usr/lib LD_LIBRARY_PATH=/tmp/mui-display/usr/lib \
LEAF_GPUI_LIBRARY=/home/jimxl/.paseo/worktrees/1c1rvoii/component-async-lifecycle-implementation/target/debug/libleaf_gpui.so \
/tmp/nim-2.2.6/bin/nim c -r --out:target/nim/test_runner scripts/test.nim
```

回归启动后Task1输入未变，四个主要源码/测试SHA与提交一致；额外threads_off fixture由最终独立命令验证。完整报告、RED/GREEN、审查diff及原始输出在本任务 `.superpowers/sdd/2026-10-17-component-async-lifecycle/`；`task-1-official-nim.log` 为官方结果，`task-1-report.md` 与 `task-1-review.md` 区分实现者声明和独立核查。普通worker和官方runner输出路径不同，默认Nimcache相同；普通编译未并发，ASan/threads-off缓存独立。

worker采用UI预分配的原始byte envelope/结果槽、worker本地string显式复制、UI统一释放原始载荷。ORC Channel特征测试证明不能把sink/raw move误当成独立深拷贝。独立审查核对了worker归还slot/signal引用后release发布completed，以及UI acquire后才peek/ack/释放的顺序。取消运行任务在真实收尾前继续计费；最终pool析构会join，上层必须避免在publish、C detach或用户回调中释放最后pool引用。

## Task2 实际检查

实现范围为 `9eb91e0..38c704b` 九个文件；生命周期登记、已接受转换和普通安全点泵已接入，尚未实现任务启动/交付/关闭或宿主协商。随后 `28a246764b51d3ef8d5e5429e6b5de6f3e498dd6` 仅修复日志编码与新增集成回归两个文件。

| 检查 | 源码身份与结果 |
| --- | --- |
| Task2 定向生命周期/routing/list/fault | `38c704b`：EXIT0，13/11/8/5项；另threads:off生命周期13项EXIT0 |
| 官方Nim全量 | `38c704b`：session94784 EXIT0，93套件；9文件SHA与启动前manifest一致，平台SKIPPED保留 |
| 初次独立审查 | Needs fixes，Critical0/Important1/Minor0；I1为4096字节切片切断UTF-8，两项接口裁定通过 |
| I1真实RED | 新3项实际callback/scope stderr回归失败，EXIT1；原13项通过 |
| I1最终GREEN | `28a2467`：lifecycle threads:on/off各16项EXIT0，覆盖3条异常路径×5种中文/emoji/畸形编码场景 |
| I1局部复审 | I1 resolved，Spec compliant，Quality Approved，Critical0/Important0/Minor0 |

I1将错误消息规范化为合法Unicode标量，并在完整UTF-8字符边界截断至最多4096字节，保留owner/revision/phase。93套全量是在此局部修复前取得，不能表述为`28a2467`全量通过；最终功能全量仍须在Task7执行。此补丁只重跑必要生命周期验证，未重复未受影响的routing/list/fault或官方全量。

完整证据位于执行scratch的 `task-2-report.md`、`task-2-review.md`、`task-2-review-fix-1.md`、`task-2-official-nim.log`、`task-2-official-inputs.json` 和各RED/GREEN日志；源码冻结与原始记录保留。

## Task2 接口裁定

- 首次登记生命周期hook创建一个隐式默认scope，scope与hook各计128字节；后续首次显式`MountContext.taskScope`可配置并返回同一scope，不重复收费。重复显式申请仍拒绝。Task2验证隐式费用，Task3已验证显式申请与hook登记顺序等价、重复申请拒绝及最终retention配置。
- 同一候选可能先materialize一行，再保留为inactive暖行。新owner按最终已接受的active事实登记；不存在→inactive不投递onMount/onActivate，之后inactive→active只投递onActivate，不补发onMount。候选内临时出现不构成已接受的active转换。Task2已补真实双materialize回归，Task7须在公共API文档说明首个可见回调可能是onActivate。
- 上述规则的使用约束：业务不能假设所有保留owner必先收到onMount；首次可见时需要运行的副作用应同时考虑onActivate。最终源码、测试数量及独立审查结论另行记录。

## Task3 实际检查

原实现为`700c29b..b296b58`七个文件，最终七项源码/测试SHA经协调核对。两新套件25项、必要旧回归80项EXIT0；协调另补core16/managed_runtime9/gpui_v2_session7共32项EXIT0，合计137项定向及补充回归，不是官方全量。threads:off专用分支编译/启动拒绝两命令EXIT0，未声称关闭线程执行全部线程用例。

独立审查Needs fixes，Critical0/Important2/Minor1。I1为Nim标准库UTF-8检查遗漏三/四字节过长key编码；I2为独立materialize遭宿主拒绝后外层未reject候选，遗留active StateAttempt而阻塞后续任务/State API。两项均经独立缓存公共API probe证实，由原实现Agent逐项TDD修复，并经下述局部复审关闭。已知标准库BareExcept和未改源码Spacing噪声保留为M1，不为本功能改标准库或扩存量清理范围。

原始有效API缺失、业务权限、预算、Snapshot缓存及净空意图RED均保留；最初两次脚手架诊断日志曾被有效RED覆盖，缺口已记录，不把它们计为RED或重建原始证据。完整记录在`task-3-report.md`与`task-3-review.md`；原实现manifest另保留为`task-3-original-inputs-b296b58.json`，修复验证须使用独立记录且不能复用137项为修复HEAD全量。

I1修复`0f59f5f`提取严格private UTF-8标量解析供key与错误消息共用；I2修复`d3de15a`在未接受独立viewport候选失败时reject driver，保持accepted scope-exit不回滚。两项都有独立真实RED→GREEN。I1验证50项（含lifecycle on/off），属I1身份；I2最终HEAD两新套件29项及必要旧回归51项共80项EXIT0，另threads:off专用启动拒绝两命令EXIT0。三份七文件manifest分别核对原/I1/I2提交，原始日志和manifest完整保留。局部复审已确认I1/I2 resolved、Spec compliant、Quality Approved，Critical0/Important0/新增Minor0；原M1作为已知非阻断警告保留。复审报告为`task-3-review-fix-1.md`，不代表最终HEAD官方全量通过。

## Task3 跨任务接缝与覆盖裁定

- 内部任务泵能力门禁先由core/driver/service提供，headless默认允许；真实GPUI/Win32能力绑定留Task5/6。不得用committer存在推断不支持，拒绝涵盖本功能登记/动态挂载且发生在生命周期/work之前。
- Task3首次持有pool，须明确最终强引用保活、退役及普通UI安全点最终回收接缝，不靠Runtime/Service的ORC引用环或GC确定join时机。定向测试显式finally回收；Task4补公开closeRuntime，Task5/6补宿主finally，功能交付前必须接通。
- task-only仍经过validator/preparer/apply和revision门禁，可保留未变宿主树的accepted Snapshot缓存；真正UI更新仍失效缓存。首次正常初始化的Snapshot可供后续metadata验证复用。
- 独立snapshot-export可恢复异常注入暂记NotRun：导出只遍历prepare已验证的框架记录，没有业务回调或可配置故障入口。exportNode仍有空active page不变量UiError，不能声称导出绝不抛错。实际export计数/缓存、validator拒绝以及更早的非法树/build/budget拒绝分别作为不同证据，不新增专为测试的生产故障钩子。

## Task4 关闭语义裁定（已验收）

合法所属UI业务体内公共closeRuntime采用两阶段关闭：立即关门、失效owner/任务代、请求取消并使全部已接受State disposed后返回，不执行清理/join/解除pin；此前排队State/导航/任务不再接受，剩余普通投递停止。随后普通close/finally处理未claim清理，scope完全退出且执行身份为0后最终回收。render/updater/prepare/apply/host安装及跨Runtime/线程公共关闭拒绝，onDispose递归关闭幂等返回。

ManagedDriver从accepted instances准备含warm/retained的child-first序列，已有pendingdispose按ownerstamp保留且去重；逐owner disposeOwner可复用现有State模块。scope入场拒绝保留未claim清理供再次close，已调用清理不因异常重放。Task4须通过真实onMount/onResult/event busy-close、排队意图作废、非合作work栅栏、递归close和scope拒绝重试回归；本段裁定不是已运行证据。

## Task4 实际检查（含已验收修复）

实现为`dcbe1da..11afa67`八个授权文件，工作树/Git/最终manifest八项SHA一致。结果交付、保留策略、普通安全点泵和两阶段close已实现；新completionReadyInternal仅在ticket membership验证后acquire读取completed，不改变Task1跨线程载荷协议。

threads:on共17套173项EXIT0：三新交付14/保留6/关闭12，共32项；其余为Task1–3及实际受影响旧路径。16套157项与最终validation-inputs-2一致；standaloneworker16项来自inputs-1，其worker/contracts依赖与最终一致。threads:off非worker关闭7项通过，最后退出链变更后受影响清理3项重跑通过，其他4项按未改路径保留原身份；不是关闭线程后运行worker用例。官方全量、Task4内存检查工具和真实新窗口未执行。

真实RED/GREEN包括scope包装器关闭权限、legacy事件合法关闭、cleanup包装器与实际递归body界限、clock抛错后pumping复位，以及40000 backlog退出优先全扫描退化。后者用prepare阶段独立退出批次链修复，publish仅链接，最终lifecycle16项通过，须由独立审查核对顺序、预算和引用回收。

最终三新套件实际覆盖40000未claimdispose+2livecleanup：关闭后40002条全部保存，scope两次拒绝不追加/重复收费，恢复后每owner一次，cleanup引用/计费归零。关闭专用上限50000，活动期仍40000及共享16MiB；记录最多6,400,000字节逻辑清理费用及有界辅助存储。500轮替换/取消/销毁后框架槽和额度逐轮归零，不作为系统零泄漏证明。

TaskPumpReport按规格裁定区分有效完成claim、实际handler调用和交付异常；nil onError真实stderr仍有界合法UTF-8。wrong-thread负编译保留于授权shutdown的`-d:leafTask4ForeignCloseProbe`，预期EXIT1精确nongcsafe；运行时uiThreadId guard动态分支NotRun，需静态核对其在变更/早返之前。既有NotRun及旧警告保留，另新delivery测试有一处Spacing警告待审查。

完整报告`task-4-report.md`、最终manifest`task-4-final-inputs.json`及全部独立RED/GREEN/结果JSON在scratch。独立`task-4-review.md`已完成，结论Needs fixes，Critical0/Important3/Minor1；Task4尚未验收通过。

Task4独立最小probe确认三项Important：受阻enter主链无界保留已消费退出批次；scope入口经合法嵌套uiTask关闭后仍pop旧记录，pending费用变为-128且可能恢复旧退出链；最终onDispose取消失效handle先遭retired拒绝，打断剩余清理。批次计量仅是所有权分析佐证，不作为系统泄漏检测结论。三项已交原实现Agent按真实RED→GREEN修复；需覆盖持续受阻enter与持续成功exit、mount/exit关闭移交、完成/销毁/最终cleanup取消幂等，并保留线程、Runtime身份及保护阶段权限。新增Spacing警告随修复清理。Task5继续冻结，修复后由原验收Agent局部复核。

原始Task4 manifest另存`task-4-original-inputs-11afa67.json`；修复使用独立命名输入与日志，不将原173项或历史全量冒充修复HEAD证据。

Task4三项修复已分提交：I1 `9dc3882`拆开prepare阶段的退出/进入批次和存储，已消费退出不再被受阻进入链持有；I2 `4ff385c`在scope实际body入场后、pop前检查退役与队列归属；I3/M1 `e68e5e3`为失效取消设置专用权限门禁，只允许合法实际cleanup或普通UI闭态无操作，并修新增测试空格。原报告追加逐项真实行为RED→GREEN；completed/disposed取消原本已通过，作为兼容验证保留。

最终修复身份八项SHA与checkout/Git及最终run输入一致。threads:on十套123项、threads:off九项EXIT0；负编译重跑精确nongcsafe EXIT1。I1测试含两种批次模式各64轮受阻进入/成功退出，I2含mount/exit移交，I3含最终清理后续语句、重复取消和保护阶段拒绝；原40002关闭容量、500轮额度归零及40000 backlog亦在必要套件中复测。固定`11afa67..e68e5e3`交原独立验收Agent局部复核，尚不声明修复已验收或最终官方全量通过。

Task4局部复审已确认I1/I2/I3/M1全部resolved：Spec compliant、Quality Approved，Critical0/Important0/Minor0。协调完整读取`task-4-review-fix-1.md`，原Important均关闭，无新增问题；标准库及旧代码警告、未执行项目仍如实保留。Task4任务门禁通过，最终源码身份为`e68e5e33820447db00ddd8eacfc80d3f0e8ab9c1`，并不代表整个功能或最终官方全量验收完成。后续Task5可在已批准文件范围接入真实GPUI协商、唯一根定时泵及普通finally关闭。

## 环境基线与实际限制

最初官方Nim基线EXIT1：`test_diagnostics`的Cargo multicall-symlink检查会清除桥接库覆盖，真实链接时找不到`-lxkbcommon-x11`。当时仅新增Task1测试，既有源码无改动。利用本机已有 `/tmp/mui-display/usr/lib` 提供开发链接路径后，原诊断套件11项EXIT0；未改系统目录、源码或断言。随后同环境官方92套件全量通过。

现有Rust基线：`cargo test --workspace --locked` EXIT0，43项通过；现有C/Nim/Rust ABI2布局检查EXIT0，157项一致。Rust/头文件/锁文件/工具链身份另存`baseline-rust-identity.json`，只能在输入一致时复用；后续修改桥接协议须重新验证。

稳定主分支`53368cf`的Linux X11环境预检已EXIT0，验证现有counter窗口点击、输入、Enter、拒绝/重置、ready、失败viewport和关闭。默认Xvfb因硬编码`/usr/bin/xkbcomp`缺失失败；使用本机已有`Xvfb-mui`及`/tmp/bin/xkbcomp`解决。普通桥接库没有`native-test-support`几何探针，改用此前保留且哈希/Rust输入已核对的测试库后通过。首次两项为环境配置失败，未改产品代码，不能算新任务功能RED/GREEN。后续Task7须为最终源码构建独立测试库并实际运行ABI1/2×CACHE0/1。预检原始记录保存在scratch的`native-environment-preflight/`，主分支未改动，私有Xvfb已finally结束。

未禁用LSan的地址检测运行在退出扫描时报ptrace环境限制；Valgrind在执行测试前因缺glibc loader debuginfo无法建立必需重定向。两者为受限NotRun；关闭LSan后的ASan、框架计费归零及普通allocator计量均不是全进程零泄漏证明。未执行TSan、线程创建失败注入或Windows/macOS真实平台验收。

## 实施决策记录

- 复用一个已配置的实现会话和一个独立验收会话，遵循Paseo角色复用规则；若上下文影响判断，可能增加审查偏差，使用任务简报、固定diff及独立验收缓解。
- 功能空间和原始证据保留至获授权合并/推送并完成安全归档检查；代价是临时存储继续占用，避免提前删除成果。
- 允许Task1仅新增、且无旧模块引用的代码与既有基线测试并行，禁止当时修改既有源码/runner；若归因不清会增加复测成本，最终稳定源码的92套件已补齐。
- 日常配置模型启动即报`Model is unavailable`、无代码改动；改用实际保存的高消耗配置`codex/gpt-6.1-sol/high/auto-review`处理线程复杂工作。代价是更高模型用量；未修改用户profiles。独立验收沿用实际架构配置`pi/openai-codex/gpt-6.1-sol/high`。

本轮未合并、推送或归档；后续任务继续在原协调会话交付。

## Task5 执行空间恢复

原执行空间在2026-10-17T06:26:47通过Paseo客户端归档，目录及Task5未提交修改、原scratch随之移除；协调未执行归档。用户随后明确选择恢复空间并继续开发。已从保留分支`feat/component-async-lifecycle`的`6d6dd32`创建Paseo托管恢复worktree，Task1–4提交完整、主分支保持干净。

找到并保存原实现完整会话归档及Task5片段，含28个工具输入/对应输出，可用于恢复已编辑源码；不据此声称所有独立原始测试日志或历史scratch报告已经找回。原归档SHA256为`587ec8fe8fa5d1b6f9f9b990590479a827ddaab672b87a5179a6520837cd1216`，另存主工作区忽略目录`.superpowers/recovery/component-async-lifecycle/`，不受恢复worktree删除影响。接手实现Agent负责审阅重放授权编辑并重新验证，恢复后证据使用独立命名与输入manifest。

能力拒绝启动的最终清理裁定已写规格：初始owner如已接受，配置/安装失败后仍须在普通UI边界close，使State失效并一次onDispose；未接受候选不获得dispose，正常进入/完成交付与worker启动仍禁止。该异常路径可能执行dispose副作用，测试与文档必须明确其最终清理性质，并保留原始启动错误。

## Task5 实际检查（含已验收修复）

恢复后源码提交`e69b32fc3c1bea5af685670369b5b4e871f32a69`包含20个授权文件。协调已完整阅读实现/恢复报告，核对最终20项源码与测试SHA和Git/checkout/改动集合一致，37份命令日志哈希一致，旧生产桥接库SHA保持不变。恢复采用15条审阅过的确定编辑，历史独立日志缺口如实保留；恢复后typed root/child/borrow、初始能力拒绝清理、malformed typed ready、ABI1 callback错误metadata、attach后安装失败收尾都有新的真实行为RED→GREEN。

必要验证记录为Nim138项、Rust51项、C/Nim/Rust ABI161条及fmt/clippy/build EXIT0，另无线程专用启动拒绝场景EXIT0。最终兼容/bridge/requests/session8/off-startup输入全部匹配提交；Rust检查/构建的Rust输入为最终，ABI最终变化只涉及非布局的gpui_session。早期任务/worker回归发生在最后Nim启动收尾补丁前，完整输入存在gpui_bridge/gpui_session及两个测试差异；不能概括为138项全在最终完整输入运行，需按实际编译依赖区分复用。补充核对确认shutdown直接import host_session，其depfiles未列gpui_session，早期相关任务/worker/layout套件亦如此；协调此前将广域输入差异误判为shutdown import gpui_session，已纠正。旧session7由最终8项替代，不重复计数。

固定提交范围已交独立架构验收，重点协商、根唯一timer与child/list唤醒、HostStore借用边界、临时换绑/迟到detach/终止分界、普通finally关闭与失败清理。Task5尚未通过验收，Task6/7未开始。真实native四组合、官方Nim全量、SDK及内存工具/平台仍未执行；GPUI TestAppContext不等于实际native窗口。提交证据另存主工作区忽略目录的恢复保管区，不受功能worktree归档删除影响。

Task5实现报告已追加“证据复用身份”说明，138项计数不重复旧session7，Rust/ABI与Nim依赖身份分别说明。另如实披露两个未定向覆盖的异常组合：startup cleanup诊断自身抛错后的原始错误保留，以及ABI1同一tick接受UI更新后再发生callback/scope错误的Snapshot+error联合响应。两点已交正在运行的独立验收评估，不提前宣称为缺陷或已验证，也未为报告补充重复测试。源码继续冻结。

Task5独立验收结论Needs fixes，Critical0/Important3/Minor0。I1实际ABI1成功list range/finish仅保存pending，根render开头的timer检查发生在其前，且成功路径不保证notify；原测试人为notify掩盖此边界。I2公共typed runDesktop外层finally在内层失败清理后再次close，真实旧库probe确认原能力错误被cleanup scope错误替代且单失败边界重复尝试。I3 ABI1内部构造失败遇到cleanup scope拒绝，初始已接受Runtime虽State失效，却未返回或转交可达重试owner，真实公开构造probe确认后续无入口完成dispose。三项交接手实现Agent修复，额外授权lists.rs最小响应唤醒；失败ownership接口方案先由协调裁定，Task6保持冻结。

原始审查报告及最小probe源码/日志/审计已保存空间外稳定保管区。另两项coverage缺口由验收静态检查未发现实现缺陷，仍不声称异常诊断分支或Snapshot+error联合场景已动态运行；它们不混同已证实的I2/I3。

Task5 round1修复已冻结：I1 `9e8ac94`在真实list range/finish成功响应后直接arm唯一根timer，真实scroll/provider无额外notify的RED→GREEN保留；I2/I3 `071d3ff`按既定GpuiRunError/cleanupOwner合同一次失败清理并显式移交重试Runtime，公开入口覆盖原msg/parent、整数5、正常0、默认异常与out通道、非空slot拒绝及最终dispose一次。

本轮五个改动文件、累计21个授权文件SHA与checkout/Git一致，22份日志SHA核对。必要Nim42项（compat19/bridge9/typed requests6/session8）、Rust52项、fmt/clippy及新库构建EXIT0；compat最终完整输入一致，其余仅广域manifest内另一个compat测试后增coverage不同，实际套件/Rust依赖不包含它。ABI161按未变布局输入复用，未重跑；旧138不与42相加冒称最终全量。新库SHA已更新，原27a74…只代表历史构建，旧生产库SHA不变。固定`e69b32f..071d3ff`已交同一验收Agent局部复核，Task5仍待门禁通过。

Task5 round1独立局部复核已确认I1/I2/I3全部resolved，Spec compliance/Quality Approved，Critical0/Important0/Minor0。协调完整读取`task-5-review-fix-1.md`，报告及只读审计副本保存空间外保管区。Task5任务门禁通过，最终源码`071d3ffac8f04244e257a838f435e285b4b50273`；这不代表官方Nim全量、真实native四组合、SDK或跨平台验收已完成。Task6在保存本阶段干净基线后接入Win32普通安全tick、独立任务timer及最终关闭。

Task7公共文档须说明GpuiRunError与cleanupOwner两种显式重试方式、out slot必须为空、exitStatus的none/some(0)/some(nonzero)、普通边界重试及成功后释放owner/异常引用。两项未动态覆盖的异常组合继续NotRun，不冒称本轮已运行。

## Task6 接口与环境裁定（代码已静态验收）

只读核对确认公开runNative此前newRuntime后仅defer destroyHost；BackendSession.dispose为可复用卸载，不终结Runtime。因此最小扩展授权backends/win32.nim在native资源退出后的普通边界closeRuntime，错误/status与未完成Host/Runtime owner明确移交。Host失败时必须以Win32RunError保留双owner，不仅输出Runtime后返回整数；caller先destroyHost、再closeRuntime。无GPUI依赖/core扩展，WndProc及通用卸载不join。

工具发现已纠正：残留Linux LLVM-MinGW目录的wrapper --version实际失败127，clang-23目标、windows.h及libuser32.a缺失，不能算可用交叉工具链；PE版gcc当前不能运行。现有Nim2.2.6 Linux及系统LLVM仅支持进一步尝试语义/C生成等检查，完整PE构建尚未确认，真实Windows仍NotRun。不启动停止的Windows容器或安装工具；最终以真实命令/日志身份记录，目录存在不当作工具可用证据。

## Task6 实际检查（静态Approved，Windows NotRun）

源码提交`6d3ea46b57ccfa55af4f13a60dd9ab13a5bc6028`仅含五个授权Win32源码/测试文件。协调完整读报告，核对五文件checkout/Git/改动集合、30日志SHA、110备份产物SHA及467个生成文件归档身份。Linux host_state6/delivery15/shutdown15共36项实际通过，不能证明Win32新行为；最终六Windows套件仅Nim目标语义及C生成EXIT0，未编译C SDK ABI断言、未链接PE、未执行Windows用例。新任务/公开入口最终全输入一致，其他五目标套件只差未导入的新测试；Linux广域输入差异为三Windows文件，按实际未改Linux依赖复用记录。

已编写15个任务/公开入口及一个构造失败用例，覆盖timer、busy/hook、换绑、双owner、整数/异常与重试；真实USER32 CBT veto仅存在测试中，均尚未执行。官方Windows runner在Linux包装1/直接2明确NotRun；clang Windows C探针缺目标CRT退出1、残留MinGW wrapper127属于环境失败，不是行为RED。旧库SHA不变，完整证据已空间外稳定保存。固定范围交同一架构验收Agent，Task6尚未通过门禁，Task7未开始实现。

Task6独立验收已确认静态Spec compliance/Quality Approved，Critical0/Important0/Minor0，未发现固定五文件明确缺陷；Windows平台行为验收明确NotRun，不授予平台通过结论。协调完整读取`task-6-review.md`，审查报告与独立只读审计另存空间外保管区。验收核对103项artifact-index、110项备份与467个生成文件逐SHA，不只依据文件数量；WindowsC生成depfiles为空时用源import、生成模块列表及输入字节判断复用，没有把空depfiles当完整依赖证明。

Task6代码门禁通过，最终源码`6d3ea46b57ccfa55af4f13a60dd9ab13a5bc6028`。计划保留Step2/4真实Windows执行未勾选，Task7按既定无Windows分支推进；取得可用Windows环境后仍需另行跑官方runner、平台ABI断言及实际timer/关闭/双owner用例。后续Linux/native/SDK验收不能消除这一限制。

## Task7 实际检查与独立验收

精确范围`40b514ad97742a565d33e875229f257b8b0f6315..7abb798054eeeef9de7ba6b8811b4a762e36da02`，4提交、11文件；最后产品/测试身份与真实SDK --commit均为`a3c63c710611ec1bad7ef3663bcccbf210166223`，7abb仅一般验证文档。两项SDK路径局部例外已同步规格/计划；原f088及4e1完整migration smoke失败包/日志保留，最终a3才完整成功。

| 检查 | 真实记录及身份 |
| --- | --- |
| 官方Nim normal | EXIT0，100 suites；957 OK、0 FAILED、5 SKIPPED；785.2806766秒，最终a3产品/测试输入 |
| 独立release-only | EXIT0，4 suites；42 OK、0 FAILED、5 SKIPPED；22.8402121秒，非借用normal内发布套件 |
| Rust test/fmt/clippy及两库构建 | 本Task7实际EXIT0，test52；最终20项Cargo/crates输入未变、记录工具/库匹配，非复用旧Task5数字 |
| C/Nim/Rust ABI | 本轮实际161条EXIT0，后续scaffold/test不改布局输入 |
| Linux native ABI1/2×CACHE0/1 | f088四组真实窗口EXIT0，无后续点击完成、error/retry、取消/keep/重建/terminal断言，后续复用范围如下 |
| 搬迁SDK | a3新包完整migration/rollback/CRUD/持久化/任务smoke与独立bundled Nim task均EXIT0，输出“后台完成” |
| 实际scaffold配置 | include与generateScaffold产物普通/中文空格/$/$$实际RED→GREEN；非path定义/deepcopy不变，现有scaffold18项EXIT0 |

5个SKIPPED为PowerShell/Windows专属项，不计平台通过。normal保留117条既有代码/依赖Warning，四native各有MESA-EGL/DRI3提示，退出0不代表无警告；本Task7改动源码没有新增指向自身的Warning。SDK生产桥接为default features/dev debug=0，SHA05b6112f0c371f17726566ea75cf484b0cf12805f155ed654c49451defadd599；native-test-support独立库SHA25e3213182a4b616cd22a484c47ab8e8115a580e5e3a2d5026d6c1846a2e0bd0，不能称生产库是release profile。

SDK真实路径`/tmp/Leaf SDK 搬迁 $ Task7 a3c63c71/leaf-sdk`，包SHA7fbe8ef270190248e6c68d87e67e176427f775579aa3ea22f6e11454665b851b；210源码/header与checkout、解包根三方SHA一致。五项NIM/LEAF覆盖变量已清，OS库路径/tmp/mui-display/usr/lib与外部GCC保留，不声称无任何系统依赖。数据库示例仅Nim check通过，不声称实际执行DB worker。

性能样本100/1000/5000兄弟均仅目标render1、额外Snapshot0、worker1、无关handles逐一不变；完成墙钟样本2.308106/2.328006/2.322388ms，不是恒定复杂度、GPU帧或FFI总量结论。四native窗口消失观测34.03–34.09ms、进程退出34.07–44.19ms，包含xdotool/轮询开销，不证明任意非合作work的join上界。本轮没有独立采样具体renderer型号、FPS或GPUI帧耗时。

复用范围：native实际f088执行，最终nims依赖bytes确有差异；只改path中$转义，当前无$绝对repo路径有效选项不变、普通配置探针通过、运行应用/宿主/harness/lib未变，因此保留原窗口证据，不称a3重跑或全部输入bytes相同。scaffold/SDK测试不是窗口runtime依赖；Rust/Cargo/工具和ABI布局分别按final-input-comparison判定，早期未记录rustc SHA不倒填。末尾纯文档变更不触发重复全量。

协调核对最终11文件Git/checkout/集合、262证据及5库/包SHA、304空间外payload逐SHA；独立审查再次核对71条命令的实际argv/exit/log/input身份和原始关键正文。report SHA8315ea3d7cff469c731f7fdb0b83f3df743c3d42dbeaebc17744c2246efe864f，final-manifest SHA17719b98ce3c166febc0d7a64d157ddb88644a10d773bbfc2d67179db312b4e0。完整304payload约1.15GB另存主工作区忽略目录`.superpowers/recovery/component-async-lifecycle/task-7-final-7abb798/`，不会随执行worktree归档删除。原Task1–4全部独立原始输出仍未找回，不能用本轮封存覆盖该历史限制。

独立task-7-review判定Spec compliance/Quality Approved，Critical0/Important0/Minor2：M1新增native close fallback等待没有deadline且异常未保证probe.close；M2继承编译与显示环境告警。M1不是本次四组成功运行的失败，静态缺口仍真实，交最终全分支审查分级；M2按已披露噪声保留，不越界清旧代码。Task1–6内部跨任务语义由冻结任务审查及本次normal回归保留，Task7不冒称独立重验全部实现；最终全分支审查将另行覆盖跨任务接口。

继续NotRun：真实Windows/macOS、PE/Windows SDK ABI断言、IME/DPI、内存工具/长期RSS/系统零泄漏、独立Snapshot-export注入、diagnostic再抛异常、同tick Snapshot+error联合响应、动态wrongthread、renderer型号/帧/FPS。所有裁定及代价详见[实施裁定记录](2026-10-17-component-async-lifecycle-rulings.md)。当前无合并/推送/归档授权，整分支最终结论尚待审查。
