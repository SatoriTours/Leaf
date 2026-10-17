# 组件异步任务与生命周期验证记录

状态：Task1–2 已实现并独立验收；Task3–7 尚未实现。不能据本记录声称整个异步功能已完成。

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

- 首次登记生命周期hook创建一个隐式默认scope，scope与hook各计128字节；后续首次显式`MountContext.taskScope`可配置并返回同一scope，不重复收费。重复显式申请仍拒绝。Task2验证隐式费用，Task3须验证显式申请与hook登记顺序等价、重复申请拒绝及最终retention配置。
- 同一候选可能先materialize一行，再保留为inactive暖行。新owner按最终已接受的active事实登记；不存在→inactive不投递onMount/onActivate，之后inactive→active只投递onActivate，不补发onMount。候选内临时出现不构成已接受的active转换。Task2须补真实双materialize回归，Task7须在公共API文档说明首个可见回调可能是onActivate。
- 上述规则的使用约束：业务不能假设所有保留owner必先收到onMount；首次可见时需要运行的副作用应同时考虑onActivate。最终源码、测试数量及独立审查结论另行记录。

## 环境基线与实际限制

最初官方Nim基线EXIT1：`test_diagnostics`的Cargo multicall-symlink检查会清除桥接库覆盖，真实链接时找不到`-lxkbcommon-x11`。当时仅新增Task1测试，既有源码无改动。利用本机已有 `/tmp/mui-display/usr/lib` 提供开发链接路径后，原诊断套件11项EXIT0；未改系统目录、源码或断言。随后同环境官方92套件全量通过。

现有Rust基线：`cargo test --workspace --locked` EXIT0，43项通过；现有C/Nim/Rust ABI2布局检查EXIT0，157项一致。Rust/头文件/锁文件/工具链身份另存`baseline-rust-identity.json`，只能在输入一致时复用；后续修改桥接协议须重新验证。

未禁用LSan的地址检测运行在退出扫描时报ptrace环境限制；Valgrind在执行测试前因缺glibc loader debuginfo无法建立必需重定向。两者为受限NotRun；关闭LSan后的ASan、框架计费归零及普通allocator计量均不是全进程零泄漏证明。未执行TSan、线程创建失败注入或Windows/macOS真实平台验收。

## 实施决策记录

- 复用一个已配置的实现会话和一个独立验收会话，遵循Paseo角色复用规则；若上下文影响判断，可能增加审查偏差，使用任务简报、固定diff及独立验收缓解。
- 功能空间和原始证据保留至获授权合并/推送并完成安全归档检查；代价是临时存储继续占用，避免提前删除成果。
- 允许Task1仅新增、且无旧模块引用的代码与既有基线测试并行，禁止当时修改既有源码/runner；若归因不清会增加复测成本，最终稳定源码的92套件已补齐。
- 日常配置模型启动即报`Model is unavailable`、无代码改动；改用实际保存的高消耗配置`codex/gpt-6.1-sol/high/auto-review`处理线程复杂工作。代价是更高模型用量；未修改用户profiles。独立验收沿用实际架构配置`pi/openai-codex/gpt-6.1-sol/high`。

本轮未合并、推送或归档；后续任务继续在原协调会话交付。
