# Leaf Windows 实测问题修复计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 方案阶段用户只要求定位和方案，后续已授权“继续修改”；尚未授权合并或推送。

**Goal:** 修复 2026-10-11 Windows 实测暴露的构建失败契约、诊断捕获和测试兼容性问题，建立可复现的普通用户回归基线。

**Architecture:** 保留现有 BuildJob、ManagedProcess、Win32 Host 和迁移路径保护；优先复用现有进程监督及测试辅助模块。测试修复保留原安全和行为断言；工具链与换行配置由仓库承担，不依赖修改用户的编译器安装。

**Tech Stack:** Nim 2.2.6、std/unittest、MinGW GCC 11.1.0/windres 2.36.1、Windows 11 x64；Linux 用于平台无关验证。

**Spec:** 用户本会话提供的《Leaf Windows 实测报告 — 2026-10-11（Asia/Shanghai）》；平台支持与人工验收边界沿用 `docs/native-win32-validation.md` 和 `docs/superpowers/plans/2026-10-08-native-controls-a2-plan.md`。

## Global Constraints

- 基线：`a00191bcf702c1ef39ad5d06cc57431a03605e4c`，本地 `main`。计划生成时源码和测试无改动。
- 报告通用/发布套件为 70 套、63 套通过、7 套失败，656/7/4；Win32 另为 5 套、4 套通过、1 套失败，77/1/0。它们是多次执行的最近结果，不能称为一次全量成功。
- Windows 本批原生目标仍为 x86_64、Windows 10 1703+ / Windows 11；编译头文件宏不扩大运行时支持清单。
- 不提高用户权限、不要求开启开发者模式、不修改全局 PATH 或官方 Nim 安装目录。
- 不删除 `invalid.nim`/具体错误文本断言，不通过减少安全测试或跳过整个混合测试来消除失败。
- 保留原编译器配置、MinGW 选择、manifest、复杂路径和 GPUI/native 隔离行为；不借修复新增后端或跨编译支持。
- NotRun、NotSupported、SKIP、FAIL 分别记录；Rust、真实 IME、跨屏 DPI 和无障碍验收未执行时不宣布全平台通过。
- 实施使用隔离目录；本机 Paseo 守护进程不可用，已明确告知后采用临时 Git worktree `/tmp/leaf-windows-report-fixes`，分支 `fix/windows-test-report`，不声称为 Paseo 托管空间。

## 定位结果与证据边界

| 问题 | 本轮定位 | 尚需验证 |
| --- | --- | --- |
| diagnostics | `src/leaf/build.nim` 的非 SDK GCC 分支运行 `--compileOnly`；非零直接 `fail()`，所以源码错误无法返回 BuildJob | Windows 原失败环境下的修复前后对照 |
| 三套 model 诊断 | `test_model_declarations.nim` 和 `model_compile_support.nim` 使用 `outputStream.readAll()`；本机 Nim 2.2.6 的 `streams.nim` 在非零短读后退出，而 Windows `osproc.nim` 的 ReadFile 流只有零字节才标记结束 | Windows 真实编译器分批输出的捕获对照；仍不能仅凭探针宣称三套已修复 |
| migration generator/integration | 无条件创建符号链接，分别混在普通路径拒绝和元数据验证测试中；用户报告的权限错误发生于 fixture 创建，早于产品断言 | 具备/缺少链接能力的普通用户环境分别验证 |
| watch | fixture 的 `static: sleep(350)` 调到 Windows importc sleep；此外 Windows 同步 discovery 会先解释该 static 块 | 替代 fixture 在 Linux/Windows 均证明取消旧构建和保留旧进程 |
| Win32 DPI | Host 初始 320 DIP，测试将外框固定设成 420×300 像素，却断言客户端 DIP 增长；150% 下该推论不成立 | 100%、150%、200% 实际桌面验证；跨屏另验 |
| ABI 头文件 | 测试要求 `NONCLIENTMETRICSW.iPaddedBorderWidth`，runner/仓库未显式指定 Windows 头文件版本 | 原 MinGW 11 默认配置及新版 MinGW 均能直接执行 runner |
| CRLF | 仓库无 `.gitattributes`，模板使用 staticRead，vendored ORM 校验原始字节哈希；core.autocrlf 可改变二者 | 新检出在 autocrlf=true/false 下均保持受保护字节 |

本轮实际执行：使用 `/tmp/nim-2.2.6/bin/nim` 编译并运行自定义 Stream 探针；输入两段短数据，分别为 stack trace 标题及 `invalid.nim ... Error`。`readAll()` 只返回第一段，读至零字节的循环保留两段，退出 0。探针在 `/tmp/leaf-windows-report-investigation/short_read_probe.nim`，不是产品修复或 Windows 测试证据。

仓库内已有对照：`scripts/smoke_sdk.nim:readCommandOutput(Stream): string` 读至真实 EOF；`tests/release/test_sdk.nim` 已有短读和延迟/大输出/尾部保留测试。`tests/nim/migration_compile_support.nim:runManagedBounded` 已提供基于 ManagedProcess 的有界执行。

注意：NIM 指向 SDK 中的 nim.exe 不代表 `sdkGcc()` 一定命中；SDK 根目录按当前测试/CLI 可执行文件位置判断。因此报告中的 discovery 路径与使用 SDK Nim 并不矛盾。

## Review Focus

- 编译器发现失败后的 job 重复 poll/close、取消和输出保留，以及前一次成功二进制不被替换：任务 1。
- 小于 1024 字节的多次输出、stderr 合并、非零退出及诊断尾部：任务 2。
- 无符号链接权限时普通路径与其他非法元数据仍运行；其他 OSError 不能误报跳过：任务 3。
- Windows 同步 discovery 不被测试屏障阻塞，旧构建结果不能发布：任务 4。
- 150%/200% DPI、MinGW 11 默认头文件及 autocrlf=true 新检出的组合：任务 5、6 和最终验收。

## 任务 1：统一 Windows 源码失败的 BuildJob 契约

**Files:** 修改 `src/leaf/build.nim`；扩充 `tests/nim/test_diagnostics.nim`；验证 `tests/nim/test_watch.nim`、`tests/windows/test_win32_toolchain.nim`。

**Interfaces:** 保留 `startBuild(...): BuildJob`、`pollBuild(job): bool`、`code(job): int`、`output(job): string`、`close(job)`；沿用 `startManaged()` 和已完成 ManagedProcess 的输出/退出状态。

- [ ] 在真实 Windows 非 bundledGcc 分支复现现有非法源码测试：当前会抛 UiError，而不是返回 job。增加 `pollBuild == true`、非零 code、包含源码文件名和 Error、重复 poll/close 安全、旧二进制内容不变的断言。
- [ ] discovery 编译子进程返回非零时，将完成的进程作为失败 job 的结果；转移所有权后不由局部 finally 提前关闭或清空。成功 discovery 仍关闭自己的进程后继续 manifest 和正式编译。
- [ ] 工具缺失、toolchain/manifest 无效等前置配置错误仍保留明确异常；ProcessInterruptedError 仍保留取消语义，不吞成普通源码错误。
- [ ] 验证非法源码 job，随后同一项目修复后成功构建；同时覆盖 SDK GCC 和源码 discovery 两条路径，确认成功 EXE manifest 正确。
- [ ] 运行 diagnostics、watch 和 Windows toolchain 套件；预期该 diagnostics 失败消失且旧成功产物保留。

## 任务 2：修复模型编译测试的诊断捕获

**Files:** 修改 `tests/nim/model_compile_support.nim`、`tests/nim/test_model_declarations.nim`；按需扩充 `tests/nim/test_process_io.nim`。不直接改 Model 宏或 Nim 标准库。

**Interfaces:** 保留 `compileModelFailure(declaration: string): tuple[code: int, output: string]`；复用 `migration_compile_support.runManagedBounded(exe, args, cwd, seconds)`，明确设定 120 秒编译期限。

- [ ] 在 Windows 对同一非法源码比较终端直接输出、重定向文件、现有 readAll 捕获和 ManagedProcess 捕获。确认截断发生在读取边界，若原始编译器输出本身不完整，停止按短读假设修改并继续定位编译器。
- [ ] 增加实际子进程分段输出回归：先写并 flush 标题，短暂停顿，再写 stderr 的 `invalid.nim ... Error` 和最后标记，退出 23；断言完整文本和 code=23。
- [ ] helper 改用已有有界执行辅助函数，保留编译参数和 Compiler 选择；declarations 的重复子进程逻辑统一走 compileModelFailure，额外 fixture import 作为 declaration 内容传入。
- [ ] 对错误的声明、查询和 validator 继续要求非零退出、`invalid.nim` 和对应错误语义；合法 business field 编译仍退出 0。
- [ ] 运行 model_declarations、model_query、model_validation、process_io；复验 release SDK 原有短读测试。预期三套原失败项均通过，输出不是单独一个 stack trace 标题。

## 任务 3：拆开符号链接能力与产品路径保护

**Files:** 新增 `tests/nim/symlink_support.nim`；修改 `tests/nim/test_migration_generator.nim` 和 `tests/nim/test_migration_integration.nim`。

**Interfaces:** 测试辅助 `canCreateSymlink(root: string, directory: bool): bool`；在自有临时目录创建并清理对应类型的探针。仅 Windows 错误码 1314 代表能力不足并返回 false；其他错误照常抛出。不触碰生产路径保护。

- [ ] generator 将普通 blocked db 断言与 symlinked migrations/target 断言拆为独立 test；integration 将 up_symlink 从 missing_up、bad_schema2_metadata、noncanonical_model、wrong_fields_kind 循环中拆出。
- [ ] 无链接能力时仅相应链接 test 调用 `skip()`，checkpoint 记录原因；普通阻塞路径和全部非链接元数据拒绝断言仍执行。文件和目录链接分别探测。
- [ ] 在有能力的环境执行真实 symlink 保护断言：拒绝越界、外部目录无新增文件、dry-run 也拒绝、失败前后快照一致。
- [ ] 在普通无权限 Windows 和可创建链接的现有 Linux/Windows 环境运行两套；分别记录通过数与跳过数。不得修改整机权限以取得绿色结果，也不将 SKIP 标成安全验收通过。

## 任务 4：让 watch 取消测试使用可移植的确定性屏障

**Files:** 修改 `tests/nim/test_watch.nim`；任务 1 是前置依赖。生产 WatchSupervisor 不新增测试专用接口。

**Interfaces:** 测试二进制支持真实 compiler wrapper 子进程模式；使用临时 NIM 和测试专属环境变量传递真实 Nim 路径与 entered/release 标记，结束后完整还原环境。

- [ ] 移除 stale fixture 的 `static: sleep(350)`。先用最小程序确认该报错来自 Windows 编译期调用，不把编译错误解释为 reload 超时。
- [ ] wrapper 对 `--compileOnly` 原样执行真实 Nim，不设置等待；对正式编译先写 entered，再等 release，最后以原 argv/cwd/环境执行真实 Nim并转发退出状态。等待有 5 秒超时，子进程由既有监督路径清理。
- [ ] supervisor 观察到 buildJob 且 entered 标记存在后，修改源码并释放屏障。断言旧 PID 在新候选 ready 前存活、过期 generation 不发布、最终候选对应最新源码、generation 增长至少 2。
- [ ] 保留非法源码、启动退出 9、ready 超时、取消构建和 close 清理的现有断言；不要只增加整体超时时间。
- [ ] 在 Linux 和 Windows 重复运行 watch 套件 3 次，均退出 0；确认无 wrapper/编译器残留及 sessionDir 残留。Windows discovery 阶段不等待屏障。

## 任务 5：修复 DPI 测试和 Windows 头文件基线

**Files:** 修改 `tests/windows/test_win32_host.nim`、`scripts/test_win32.nim`、`src/leaf/build.nim`、`docs/native-win32-validation.md`；扩充 `tests/windows/test_win32_toolchain.nim`。仅在复现证明必要时修改 Win32 API 模块的编译选项。

**Interfaces:** 不改变 Host API。测试使用现有 GetWindowRect/GetClientRect/SetWindowPos；runner 和 CLI 的 Windows C 编译参数显式设置 `_WIN32_WINNT=0x0A00`、`WINVER=0x0A00`。

- [ ] 保留 150% 下固定外框会缩小 DIP 的复现数据；用 GetWindowRect 的当前外框宽高分别增加 100 像素，再 SetWindowPos。随后断言实际客户端像素增大，contentWidth/contentHeight 与实际像素除 scale 一致，并在相同 scale 下 DIP 增大。
- [ ] 同屏 WM_DPICHANGED 消息测试继续只验证同屏协议，不计为跨屏验收。
- [ ] 使用未修改全局 config 的官方 MinGW 11 复现 ABI 编译失败；runner 和 CLI 正式/发现编译统一传入 Windows 10 头文件宏。先核实失败仅发生于 ABI 测试还是直接使用 API 模块的应用也受影响，避免不必要的全局 pragma。
- [ ] 在相同源码、100%/150%/200% 桌面缩放分别跑五套 Win32 测试；另用新版 MinGW 复验。实际记录 DPI、GCC、宏参数和 manifest，不修改用户的 Nim config.nims。
- [ ] 验证复杂 Unicode/空格/$ 路径 native build、manifest、默认 GPUI build 和 headless 行为仍通过；人工跨屏任务仍单独待验。

## 任务 6：固定哈希敏感源码和模板的换行

**Files:** 新增 `.gitattributes`；更新 `docs/development.md`。验证 `tests/nim/test_db_cli.nim`、`test_scaffold_model.nim`、`test_migration_integration.nim`、`tests/release/test_model_dependencies.nim`。

**Interfaces:** 限定路径规则 `src/leaf/templates/** text eol=lf`、`src/leaf/vendor/orm/** text eol=lf`、`tests/fixtures/** text eol=lf`。先枚举这些目录的二进制文件并为实际存在的二进制单独标记 `-text`，不对整个仓库执行 renormalize。

- [ ] 在独立临时 checkout 以 autocrlf=true 复现模板/ORM 字节差异；记录 git check-attr、工作树 EOL 和锁定哈希。
- [ ] 添加精确属性，保留 ORM lock 中现有哈希和模板字节断言；不把完整性校验改成忽略 CRLF。
- [ ] 分别新建 autocrlf=true/false 的独立 checkout，运行上述四套；两者均不得因换行出现失败。migration_integration 若无链接能力，按任务 3 单独记录 SKIP。
- [ ] 对无 .git 的 Git archive 副本复验 model-only；若是当前未提交的候选树，先构造包含全部候选修改的临时导出，不能用 git archive HEAD 假装已包含新属性。

## 最终回归与交付门槛

以下命令在正式实施后的执行目录运行；这里记录待执行命令，不是已通过证据。

```powershell
# 当前源码对应 GPUI DLL 如为预编译 SDK，记录 SDK commit 和差异，另记 Rust NotRun。
& $env:NIM c -r --out:target/nim/test_runner.exe scripts/test.nim
if ($LASTEXITCODE -ne 0) { throw 'Common/release suites failed' }
& $env:NIM c -r --threads:on --path:src --out:target/nim/test_win32.exe scripts/test_win32.nim
if ($LASTEXITCODE -ne 0) { throw 'Win32 suites failed' }
```

- [ ] 单独复验每个任务的红绿对照后，在同一最终提交和固定环境执行一次完整通用/发布 runner 与五套 Windows runner；suite 数随新增测试动态统计，不用旧的 70 作硬编码。
- [ ] runner 当前遇失败即停止。若最终仍失败，记录其余未运行套件；续跑结果作为补充，不能拼成一次全量通过。改善 runner 的聚合报告属于后续可选工作，不作为本修复必要改动。
- [ ] 普通用户、150% DPI、MinGW 11、autocrlf=true 新 checkout 为必要回归组合；符号链接有能力环境单独验证安全断言。
- [ ] 有完整 MSVC/Rust 环境时执行 `cargo test --workspace --locked --target x86_64-pc-windows-msvc`；没有则明确 NotRun。`scripts/native_test.nim` 的 X11 桌面路径在 Windows 仍记 NotSupported。
- [ ] 五个 demo 编译、--check、状态回调与重新定位打包验证保留；不将 headless 命令计入完整 GUI 人工验收。
- [ ] 更新 `docs/native-win32-validation.md`，追加用户普通桌面实测及修复后证据，不删除之前开发桌面的历史结果；真实 IME、双屏 DPI、Narrator/Accessibility Insights 保留人工验收状态。
- [ ] 交付实际通过/失败/跳过/未执行清单、日志位置和剩余限制。实施与本机验证已获用户授权；本地合并及主分支推送需另行授权。推送验证后的空间归档仍按既有安全检查执行。

## 执行顺序与方案阶段记录

建议顺序：2 → 1 → 4 → 3 → 5 → 6 → 最终回归。模型诊断先修以恢复后续定位证据；watch 依赖 BuildJob 失败契约；其他任务按文件边界独立验收。跨任务对 `build.nim` 的修改顺序集成，避免覆盖。

方案阶段已完成源码和 Nim 标准库核对、最小短读机制探针及本文自审；未实施任何修复、未执行产品回归、未运行 Windows 测试、未调度子 Agent、未创建工作区、未提交或推送。原 Windows logs/test-results.json 未提供到此 Linux 文件系统，因此原始失败日志仍以用户报告为证据，实施阶段需在失败环境补做捕获对照。


## 实施记录（用户后续授权“继续修改”）

六项代码/测试/属性修改已在 `fix/windows-test-report` 的临时 worktree 实现。源码和测试变更未写入主目录；Paseo daemon 不可用，因此本空间不声称为 Paseo 托管空间，也未派发独立验收 Agent。

本机验证包括：模型三套、diagnostics、迁移两套、进程输出和工具链/manifest 等定向回归；watch 连续三次；autocrlf=true/false 候选新检出各四套；无 .git 候选源码归档的 model-only 全部 17 套；11 项 Windows x64/threads:on Nim 静态检查。原提交 CRLF 新检出的 ORM 哈希断言实际失败，候选检出通过；未改动原有哈希。

Windows 运行及 100%/150%/200% DPI、链接权限、MinGW 11 组合仍为 NotRun。Linux 上实际调用 Win32 runner 输出 NotRun、退出 2。Windows 编译器分段输出的原失败环境对照仍需补验，不将 Linux 机制探针和静态检查计作 Windows 通过。独立评审未执行，已完成单独的作者自审。

本轮 Linux 同一候选代码的完整 `scripts/test.nim` 回归：70 套，710 项通过、0 失败、5 项平台相关跳过，进程退出 0。日志与摘要保存于主目录 `target/nim/windows-report-fixes/`；包含 CRLF 红绿对照、两种 checkout 回归、无 Git 的 17 套 model 回归及 11 项 Windows 目标静态检查。上述结果不替代真实 Windows 运行或独立验收。
