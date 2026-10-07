# SDK CI 输出与 fixture 独立复审 r3

日期：2026-10-07。base／审核开始及结束 HEAD：`5b4bb0eb0b625f1cbd7e9c5d9683091d765cda17`。

当前两源码修复可由 root commit/push，进入 native CI。未发现阻止提交的实际问题；这个结论不表示 Windows 修复已获原生验证，也不表示 DPI 最终验收完成。

## 范围与独立性

审查当前未提交 diff：`scripts/smoke_sdk.nim`、`tests/release/test_sdk.nim`；完整读取 `execution-r3.md`、`execution-r3-continuation.md`，核对 r1/r2 报告和 Nim 2.2.6 的 Stream、Windows process、symlink、递归删除实现。独立运行当前 checkout 的 release-only 测试及必要读取探针；executor 的 41 项通过声明没有代替本轮验证。

采用 `requesting-code-review` 的 `code-reviewer.md` 模板和 `verification-before-completion`，来源 `/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/`。按用户限制与 reviewer 模板自行审查，未创建 agents。只新增本报告，测试产物、探针、证据位于 `/tmp/leaf-ci-review-e1abf9e-r3`。未改源码、旧文档、index、HEAD、分支或状态文件，未 commit/push、安装或运行无关 Rust/DPI 全量测试。用户最后补充原生状态后，没有新增或复跑测试。

## Strengths

- `scripts/smoke_sdk.nim:13` 的生产 collector 对每次非零 `readData` 原样追加字节，只在实际返回 0 时结束；不会将非零短读误当 EOF。`scripts/smoke_sdk.nim:38` 保留单一合并 stdout/stderr 管道，`:40` 保留 process.close 的 defer，`:41` 排空后才在 `:42` 获取真实退出码。读取异常没有被捕获、吞掉或转为成功。独立探针证明零返回后停止，以及第二次读取抛出的中文 IOError 原样传播。
- `tests/release/test_sdk.nim:28` 提供有效的短读 Stream，每次最多 3 字节；`:126` 直接测试同一生产 collector，覆盖空、中文 UTF-8、NUL 与 17,003 字节跨块内容。`:10` 的真实自子进程先 flush 早期输出、延迟 50ms，再顺序写大段 stdout/stderr 和各自尾标；`:134` 走真实 runCommand，严格要求完整 **262,232 字节**、逐字节顺序和 **exit 23**。本轮该仓库测试实际通过；Linux 原实现的大输出测试曾通过这一事实不能替代短读 RED。
- `tests/release/test_sdk.nim:38` 先用 symlinkExists 拒绝普通路径，Windows `:43` 调用 Unicode RemoveDirectoryW，只解除 junction 自身。Nim Windows symlinkExists 检查 reparse-point 属性，能够识别此 fixture 的 junction；原递归 removeDir 将目录链接交给 removeFile，这与原故障机制相符。`:287`、`:298` 的 defer 在 unittest teardown 前解除链接，原别名接受及逃逸拒绝断言保留。`:313` 检查外部 target sentinel 在解除链接和后续递归清理后仍存在，普通目录和文件都拒绝且内容保持。该 API 的 junction 行为符合 [Microsoft RemoveDirectoryW 说明](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-removedirectoryw)；实际 Windows syscall 仍待 native CI。
- `tests/release/test_sdk.nim:71` 对实际和预期共同调用 GetFullPath，再比较完整位置；错误保留 raw 与规范化的 actual/expected。`:351` 接受等价现存位置，`:357` 明确拒绝错误 mingw64 prefix 与 ucrt64-sibling。环境写入值和显式 GitExecutable 的原样返回继续严格比较，没有被路径归一化替代。已有 [.NET Windows PathHelper 源码](https://raw.githubusercontent.com/dotnet/runtime/main/src/libraries/System.Private.CoreLib/src/System/IO/PathHelper.Windows.cs) 支持存在短名时尝试扩展的机制；它不能证明原失败 assertion 的具体原因。
- `tests/release/test_sdk.nim:59` 的 trap 将完整中文 Exception.Message、位置及根路径保存为 UTF-8，并写入 stderr；`:81` 在进程结束后追加 failure 文件。`:372` 的早期 stdout／延迟中文异常反例要求实际失败、failure 文件及完整 actual/expected。`:503` 保留 OpenSSL 生成过程合并 stderr/stdout，`:504` 在失败时包含真实 exit、executable、中文 cert 路径和原输出，没有再 Out-Null 丢弃诊断。
- r1/r2 业务闭环保留：独立字节检查确认当前 smoke 文件移除新增 collector 并恢复唯一调用后，与 HEAD 完全相同。因此 `scripts/smoke_sdk.nim:55` 的真实路径解析、邻目录／`..`／逃逸拒绝和 OSError 处理未削弱。HTTPS helper 和 workflow 与 HEAD 逐字节相同；真实 OpenSSL 完整转换、PKCS#7 解码、X509 验证及验证后才发布环境的顺序保留。原中文 fixtures、有效 CA 和垃圾／注释／畸形 PEM 的拒绝、PATH/ENV 不创建或不变断言均保留且本轮实际运行。没有 TLS 绕过或 assertion 放宽。

## Issues

### Critical

无已确认问题。

### Important

无已确认问题。

### Minor

无应列为代码发现的实际问题。现有 Windows unused-import warnings 不作为新增回归；未声称 warning-free。

## 独立命令与实际退出码

证据目录：`/tmp/leaf-ci-review-e1abf9e-r3`。`commands.jsonl` 保存实际 argv、局部环境、UTC 时间和退出码；`child-commands.jsonl` 保存三份 release 源码的真实子编译命令；完整输出保存在对应日志中。

| 检查 | 实际 exit／结果 | 证据 |
| --- | --- | --- |
| 当前 release-only runner | **0；3 文件、41 OK / 0 FAILED / 0 SKIPPED** | `release-suite.log` |
| 当前 collector EOF／异常探针 | **0；2 OK** | `collector-probe.log`、`collector_probe.nim` |
| 同一有效短读流调用原 std/streams.readAll | **1，预期 RED；只读回 1/2 字节** | `original-short-read-red.log` |
| 当前 Windows 宏分支 C 生成 | **0；仅 C 生成，未链接／运行** | `windows-cgen.log` |
| Git 空白检查 | **0** | `diff-check.log` |
| 审核前后完整性／r1-r2 字节闭环 | **0** | `integrity-before-report.log`、`final-integrity.log`、`files-before.json`、`files-after.json` |
| 既有工具版本 | 各 **0**；Nim 2.2.6、PowerShell 7.6.6、OpenSSL 3.6.4 | `nim-version.log`、`pwsh-version.log`、`openssl-version.log` |

release 命令实际为：

```sh
PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH \
NIM=/tmp/leaf-ci-review-e1abf9e-r3/nim-wrapper.py CARGO_HOME=/tmp/mui-cargo \
XDG_CACHE_HOME=/tmp/leaf-ci-review-e1abf9e-r3/xdg/cache \
XDG_CONFIG_HOME=/tmp/leaf-ci-review-e1abf9e-r3/xdg/config \
XDG_DATA_HOME=/tmp/leaf-ci-review-e1abf9e-r3/xdg/data \
TMPDIR=/tmp/leaf-ci-review-e1abf9e-r3/tmp \
/tmp/nim-2.2.6/bin/nim c -r \
  --nimcache:/tmp/leaf-ci-review-e1abf9e-r3/runner-cache \
  --out:/tmp/leaf-ci-review-e1abf9e-r3/test_runner scripts/test.nim --release-only
```

为遵守唯一写入范围，相对用户环境只将 XDG/TMPDIR 和产物收拢到证据目录，并用透明 NIM wrapper exec 原 `/tmp/nim-2.2.6/bin/nim`，替换硬编码子进程 `--out`／`--nimcache`；没有更改源码、测试筛选、assertions 或平台分支。runner 中 createDir 所需目录本来存在；已有三个 release 产物的内容、mtime 和 mode 均保持。

其他实际命令由 `run.py` 留证，共享上述局部环境：

```sh
# exit 0
/tmp/nim-2.2.6/bin/nim c -r --path:src \
  --nimcache:/tmp/leaf-ci-review-e1abf9e-r3/probe-cache \
  --out:/tmp/leaf-ci-review-e1abf9e-r3/collector_probe \
  /tmp/leaf-ci-review-e1abf9e-r3/collector_probe.nim
# exit 1，预期 RED
/tmp/leaf-ci-review-e1abf9e-r3/collector_probe --old
# exit 0
/tmp/nim-2.2.6/bin/nim c --os:windows --cpu:amd64 --compileOnly --path:src \
  --nimcache:/tmp/leaf-ci-review-e1abf9e-r3/windows-c \
  --out:/tmp/leaf-ci-review-e1abf9e-r3/test_sdk.exe tests/release/test_sdk.nim
git diff --check
python3 /tmp/leaf-ci-review-e1abf9e-r3/integrity.py
```

辅助命令的失败未被当成代码失败或成功证据：初次只读搜索因 zsh 未匹配 `nimble*` 返回 1，后续用明确路径读取；证据计数脚本初次缺 json import 返回 1，修正后保存 summary。两次 Paseo 列表请求实际 exit 1、`DAEMON_NOT_RUNNING`，详见通知限制。

## SHA 与工作区完整性

本轮开始／结束 HASH 相同，225 个已存在受检文件及三个已有 release 产物的 SHA256、mtime、mode 均不变。无关 model-plan 内容未打开。staged diff 为空，HEAD/index 不变；原两个 modified 源码和两份 untracked execution 记录保留，只新增指定报告。完整快照见证据目录，报告自身 hash 放入 `files-after.json`，避免自引用。

| 对象 | SHA256 |
| --- | --- |
| `scripts/smoke_sdk.nim` | `76f290f300fbda6727d0fb7db47a586e8e38ab4b86d803495c80885222bffcfd` |
| `tests/release/test_sdk.nim` | `f378cb7a858f989e63ff5272eea63c65a1bd13ff13d39d004db0bc141f62765d` |
| `scripts/prepare_windows_https.ps1` | `76ef7e68ed08d03f73647d5d7e42173e43e1c6833ef3b3ccc01067be8cb1af4f` |
| `.github/workflows/release.yml` | `e5866fbff06a63903417ad45bb18b22327a0c3025223986be2bbbd325d9ab5b4` |
| execution-r3 | `4f749ab91f347e62aa96540d46278b122f4ccebbd90042ad30ca0712ad6c54df` |
| execution-r3-continuation | `edf0748fd0cec1d8e74685ea1e993ca3a5ab71c358ef7ef98acff2496e1d5eaf` |
| r1 review | `eba02d74b228ea38a2380e9ce08a76b1e51f3750d308fdcb2a581445e132ad4e` |
| r2 review | `1b347c6ec94db921ef0df2db4938cd9684ac698f50426507eaf402d4a21d6014` |
| Git index | `4d7a4959c4471b5ae7802412e0534f44079e7141a45f188c82517b62a09ea28b` |

## Native 状态与 declined_to_judge

据用户最后补充的 **root `gh run view 37577877931` 最新完成查询**，Linux、macOS ARM、macOS Intel 三个 SDK 矩阵 job 均 success；Windows 仅“发布与安装脚本测试”failure，publish 因矩阵失败 skipped。常规 CI `37577877923` success。本轮没有重新查询 GitHub；这些是既有 run 的已确认状态，不能解释为当前未提交 r3 diff 已获 native 验证。

- **Windows 当前修复的 native 行为：not_verified。** 本机仅 Linux runtime 和 Windows C 生成；RemoveDirectoryW 真正解除 junction／保留外部 target、真实 RUNNER~1 与长名规范化、Windows 大输出管道与退出 23、三个 PS fixture 的完整原生异常及 CA 中文路径仍需 root 提交后真实 CI。
- **原 PS assertion／CA 中文失败的唯一根因：declined_to_judge。** 原异常 Message／CA stderr 缺失；短名与短读机制有源码依据，但不足以证明每个原生失败均由它们造成。新代码保留真实诊断与严格验证，未猜测 CA 修复。
- **DPI P1–P4、真实 150%／144 DPI、同窗口 DPI 变化和 IME：not_verified。** 无原生桌面、截图或输入验收证据，且不在本轮两源码审查范围。
- **无关 Rust/DPI 全量及最终发布验收：declined_to_judge。** 用户明确排除重复测试；publish 已 skipped，不宣称发行或整体任务通过。

上述限制分别保留，不构成拒绝正确代码送 native CI 的理由。

## Root 交接与通知限制

建议 root 提交当前两源码修复并 push 触发 native CI，首先检查 Windows release 测试及保留下来的原始诊断。没有新增必须先修的问题。

已按 [paseo 技能](/home/jimxl/.agents/skills/paseo/SKILL.md) 尝试定位现有 root 通知入口：默认入口和会话提供的 `PASEO_HOME=/home/jimxl/.paseo` 均返回 `DAEMON_NOT_RUNNING`（actual exit 1），工具列表也无 Paseo MCP。没有可解析的 root agent ID，因此**自动通知未送达**；没有启动 daemon 或创建 agents。可直接转交的通知正文位于 `/tmp/leaf-ci-review-e1abf9e-r3/root-notification.txt`，本报告与最终回复构成 root 交接材料。

```json
{"verdict":"pass"}
```
