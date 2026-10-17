# 组件异步任务与生命周期验证记录

状态：Task1–3 已实现并独立验收；Task4 已提交，独立审查进行中；Task5–7 尚未实现。不能据本记录声称整个异步功能已完成。

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
