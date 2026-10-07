# SDK CI fixture 修复与诊断执行记录 r3

日期：2026-10-07。开始、当前 HEAD：`5b4bb0eb0b625f1cbd7e9c5d9683091d765cda17`；开始工作区 clean。角色 executor，沿用当前用户指定执行 runtime；工具会话 canonical `/root`，未创建 agent、会话或工作区。本轮未 commit/push、发布、部署、安装、外部主机接入、工作区清理或读取凭据。r0–r2 记录和原审核报告均保留原字节。

本轮完成有证据支持的测试 fixture 修复和可靠诊断，最新 Linux release-only 39 项通过、0 跳过；交回 root 独立审核并发起真实 Windows 测试。**没有宣称原生 Windows 测试已修好或整体验收 pass。** 两个 junction teardown 的已知缺陷与三个 PS 测试尚缺原始 assertion Message 的问题，按下面不同证据级别记录。

## 已确认事实、因果推断和未验证项

1. **原生 HTTPS 准备成功（已确认）**：run `37577877931`、Windows job 的本轮证据来自用户给出的原始日志 `/tmp/leaf-ci-windows-5b4bb0e.log`。日志明确 `OpenSSL 3.5.7`，runtime `C:\Program Files\Git\mingw64\bin`，CA `mingw64\etc\ssl\certs\ca-bundle.crt`。默认发现修复已在该 Windows run 的准备步骤成功，本轮没有修改产品 helper。
2. **junction 清理根因（已确认）**：两个 native 测试创建 junction 后，在 unittest teardown 的 `removeDir(base)` → `osdirs.nim:351` → `removeFile` 抛 AccessDenied，路径就是 junction。Nim 2.2.6 将 `pcLinkToDir` 交给 removeFile，后者调用 DeleteFile，源码与栈相符；不是目标别名/逃逸断言失败的证据。原 native RED 证据保留在 `/tmp/leaf-ci-e1abf9e-r3/ci-excerpt.log`。
3. **PS 断言具体失败原因（仍缺原始 Message）**：layout、CA 只见 generated script Assert 的位置；discovery 输出已发现 3 个 Application，后续退出 1。不能据此宣布产品 helper、证书生成或 Unicode API 出错。Nim `runCommand` 用 `Stream.readAll`；本地 Nim 源码确认 readAll 遇到短读取便停止，而 Windows pipe read 可以只返回当前可读的一段。该捕获实现提供了首行丢后续诊断的合理机制；本轮没有 Windows 环境去证明每次缺失输出都由它造成。新增 fixture failure 文件保证测试读取完整异常，不改通用 subprocess 产品实现。
4. **短路径比较误判（有官方源码支持的解释，尚非原断言 Message 实证）**：native fixture 输出含 `C:\Users\RUNNER~1`，PS script 报错路径为 runneradmin。root 补充的 [.NET PathHelper.Windows.cs 官方源码](https://raw.githubusercontent.com/dotnet/runtime/main/src/libraries/System.Private.CoreLib/src/System/IO/PathHelper.Windows.cs) 本轮实际读取，lines 31–33 在 `~` 出现时进入 TryExpandShortFileName，lines 163–164 调用 GetLongPathNameW。生产 locator 先 GetFullPath，fixture 的预期拼接保留短名，因此纯文本比较可误判同一位置。此机制与日志一致，支持最小 fixture 归一化；未拿到原 assertion Message，故不写“已证实这就是两个 PS 原生失败的实际原因”。
5. **CA 生成 Unicode 问题（未确认）**：原测试最早 Assert 可来自 openssl req 生成证书失败，但原 stderr 曾被 Out-Null 丢弃。新诊断保留生成退出码、可执行文件、证书路径和 stderr。保持真实 OpenSSL、中文/空格 CA 目录和后续严格转换/PKCS#7/X509 检查；没有据猜测改 CA 业务校验或改为 ASCII fixture/跳过该测试。

原日志本轮只读；证据目录内 `ci-excerpt.log` 保存必要准备成功和 fixture 失败行。其余平台的 native CI 由 root 继续跟踪，本记录不推断当前结果。

## 实际文件范围与修复

只修改 `tests/release/test_sdk.nim`，新增本记录。`scripts/prepare_windows_https.ps1`、workflow、smoke helper、旧 DPI/spec/plan/state/review、依赖/vendor/版本均未修改。修改前后 SHA256：

- 测试开始 SHA256：`f4709be6ba265543c13586183af9d4b212302230bf8d1cd55abda3ecfd907cb2`
- 测试当前 SHA256：`ba907a73a44c631b473097f92cd118c2d10564b0f82e654d955805d5f23db008`

完整哈希快照在 `files-before.json` / `files-after.json`；只有该测试源码改变，全部旧记录/报告和产品 helper 哈希不变。Git index 空、HEAD 未变。

- 增加 test-only `removeFixtureDirectoryLink`：先拒绝非链接路径；Windows 使用已有 std/winlean 的 RemoveDirectoryW Unicode API，只解除 junction 本身，Unix 使用 unlink/removeFile。两个原测试以 defer 在原递归 teardown 之前删除各自链接；原双向别名和逃逸断言保留。不会递归链接目标，不需要管理员。新增保护回归对 fixture 外、但本测试自己创建的临时目录保存 sentinel，验证链接删除与后续 fixture 递归清理都保留目标；普通目录和普通文件必须拒绝且内容保留。
- [Microsoft RemoveDirectoryW 官方说明](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-removedirectoryw) 明确可删除 junction 而不影响目标目录和内容；本轮实际浏览核实。本机 Windows 分支只 C 生成，API 实际调用待 native CI。
- 增加 test-only `runPowerShellFixture`：三个 PS fixture 均注入 plain 输出、明确 trap；将完整 Exception.Message、位置、fixture raw/full 根路径以 UTF-8 无 BOM 写入 `.failure.txt`，子进程结束后 Nim 从文件附加回输出，避免依赖首个 pipe chunk。退出 1 的行为保留。新增反例先输出 early stdout、延迟后失败，要求最终消息含完整中文、actual/expected 且 failure 文件存在。
- 路径断言用 test-only `AssertFixturePath` 对实际和预期调用相同 `.NET GetFullPath`，错误中同时保留 raw 与规范化值。prefix 新旧选择、优先级/fallback、多个 Application 首项和重排仍检查具体位置；错 mingw64/ucrt64 prefix、兄弟目录仍拒绝。单独回归在现存 fixture 上接受 `..` 等价位置，Windows 分支同时覆盖斜杠写法和传入短根 versus canonical 路径。Windows 的 8.3/斜杠代码尚未本机执行。
- 环境实际写入值继续用严格值断言，不经过位置等价归一化；显式 GitExecutable 必须原样返回、发现必须一个 string、Application 数量必须 3、选中路径必须存在，这些原保护保留。
- CA 生成阶段保留 OpenSSL 输出到变量并在失败 Message 内输出完整上下文；managed PATH/ENV 写入断言仍位于实际校验成功之后。生成/外部 binary 的失败诊断与 managed 环境值断言分开，不混为产品 CA 逻辑问题。

核查 `std/osproc` 使用 CreateProcessW（源码 lines 722–730），所以没有把 PowerShell 启动改成 ANSI workaround。现有 `windows_paths.compilerPath` 明确用于 bundled GCC 的 ANSI 路径，仅阅读其用途，没有把它用于这些 fixture 或其他外部 binary。读取证据在 `source-evidence.log`。

## 技能、TDD 与原始证据

沿用本会话已真实读取的 `receiving-code-review`、`systematic-debugging`、`test-driven-development`（含 writing-good-tests）、`verification-before-completion`；来源 `/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/`，实际 `functions.exec → tools.exec_command cat` 证据 chunks `9e805c`、`cabca3`。本轮反馈和完整当前测试读取 chunks `6ae50b`、`f57f4c`、`9aff11`，过程/stdio/Nim实现核查 chunks `76bf1b`、`9b3c34`、`923599`。root 后续反馈的 .NET 官方源码经实际 `web__run open` 读取；没有使用 agent。

TDD 首先写保护和诊断反例，并以原 removeFile/原 runCommand 对应行为运行：fixture-red 有 16 OK / 2 FAILED。失败分别为非链接目录抛 OSError 而无 guard，以及消息包装/缺 failure 文件；native junction 的原 RED 已由日志证实，本地不伪造 Windows syscall。加入 guard/API 和可靠诊断后 fixture-green 18 OK。随后收到官方路径反馈，先增加路径回归，原 raw 比较在同一现存 `ucrt64/bin` versus `ucrt64/../ucrt64/bin` 上失败，path-normalization-red 18 OK / 1 FAILED；加入归一化后最新完整 release 39 OK。各次全量 release 重跑均由新的测试/代码修改触发，没有循环重复已通过全量验证。

证据目录 `/tmp/leaf-ci-e1abf9e-r3`；原始命令、时间、实际退出码和日志见 `commands.jsonl`，汇总见 `summary.json`。所有日志均保存完整命令/合并 stdout-stderr/实际退出码；外层记录工具正常退出不是被测命令通过。

| 日志 | exit | 实际结果/限制 |
| --- | --- | --- |
| `fixture-red.log` | 1（预期 RED） | 16 OK / 2 FAILED / 0 skipped，捕获 guard 与诊断缺口。 |
| `fixture-green.log` | 0 | 18 SDK 项通过，当时未加路径比较回归。 |
| `release-suite.log` | 0 | 前阶段完整 release：38 OK / 0 FAILED / 0 skipped。 |
| `windows-cgen.log` | 0 | 前阶段 Windows C 生成，仅语义/C 生成检查。 |
| `diagnostic-probe.log` | 0 | 用同一 trap/断言内容输入 separator、短长名、普通不同字符串三种合成反例，子进程各 exit 1，完整 raw actual/expected 保存；不判定它们就是 native 原因。 |
| `path-normalization-red.log` | 1（预期 RED） | 18 OK / 1 FAILED / 0 skipped，等价真实位置被 raw 文本误拒绝。 |
| `release-suite-normalized.log` | 0 | 当前完整 release：3 文件、39 OK / 0 FAILED / 0 skipped；PowerShell、真实 OpenSSL、symlink 和新保护反例实际执行。 |
| `windows-cgen-normalized.log` | 0 | 当前 Windows 分支生成 C，包含 RemoveDirectoryW/junction/路径反例；未 Windows 链接或运行。原有 unused-import warnings 保留，不称 warning-free。 |
| `source-evidence.log` | 0 | 保存 Nim removeDir/DeleteFile/readAll/CreateProcessW/defer 和 compilerPath 相关原始源码片段。 |
| `diff-check.log`、`final-diff-check.log` | 0 | 对应阶段的 Git diff 空白检查。 |
| `integrity.log` | 0 | 唯一测试源码改动，旧记录/报告/helper等哈希及 HEAD 不变、index 空。 |

完整实际命令清单：

`fixture-red`，exit `1`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r3/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r3/test_sdk tests/release/test_sdk.nim
```

`fixture-green`，exit `0`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r3/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r3/test_sdk tests/release/test_sdk.nim
```

`windows-cgen`，exit `0`：

```sh
/tmp/nim-2.2.6/bin/nim c --os:windows --cpu:amd64 --compileOnly --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r3/windows-c --out:/tmp/leaf-ci-e1abf9e-r3/test_sdk.exe tests/release/test_sdk.nim
```

`release-suite`，exit `0`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH NIM=/tmp/nim-2.2.6/bin/nim CARGO_HOME=/tmp/mui-cargo /tmp/nim-2.2.6/bin/nim c -r --nimcache:/tmp/leaf-ci-e1abf9e-r3/runner-nimcache --out:/tmp/leaf-ci-e1abf9e-r3/test_runner scripts/test.nim --release-only
```

`diagnostic-probe`，exit `0`：

```sh
python3 /tmp/leaf-ci-e1abf9e-r3/diagnostic_probe.py
```

`diff-check`，exit `0`：

```sh
git diff --check
```

`path-normalization-red`，exit `1`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r3/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r3/test_sdk tests/release/test_sdk.nim
```

`windows-cgen-normalized`，exit `0`：

```sh
/tmp/nim-2.2.6/bin/nim c --os:windows --cpu:amd64 --compileOnly --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r3/windows-c --out:/tmp/leaf-ci-e1abf9e-r3/test_sdk.exe tests/release/test_sdk.nim
```

`release-suite-normalized`，exit `0`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH NIM=/tmp/nim-2.2.6/bin/nim CARGO_HOME=/tmp/mui-cargo /tmp/nim-2.2.6/bin/nim c -r --nimcache:/tmp/leaf-ci-e1abf9e-r3/runner-nimcache --out:/tmp/leaf-ci-e1abf9e-r3/test_runner scripts/test.nim --release-only
```

`source-evidence`，exit `0`：

```sh
python3 /tmp/leaf-ci-e1abf9e-r3/source_evidence.py
```

`final-diff-check`，exit `0`：

```sh
git diff --check
```

`integrity`，exit `0`：

```sh
python3 /tmp/leaf-ci-e1abf9e-r3/integrity.py
```

## 必需原生验证与交接

Linux 本轮可执行实施和回归已完成。Windows junction unlink 的实际运行及 target 保留、真实 8.3 路径比较、三个 PS fixture 的原始失败 Message 和 CA 外部 binary Unicode 行为：**not_verified**，需 root 审核后 native CI；尤其不能用 39 Linux pass 断言 CA native 已修好。本轮没有 Windows 本地 runtime，没有绕过测试、禁用 TLS 或修改业务 helper 来迎合 fixture。

原 DPI P1 EXE 资源/复杂路径、P2 桌面初始化/宿主/headless、P3 真实 144 DPI/1.5 和原图、P4 同窗口变化/输入/IME 的必需 native 验收仍逐项 **not_verified**，没有最终 Windows 清晰度证明。未运行无关 Rust/DPI 全量回归，也未修改 build.rs 或声称其原全局 fmt 基线缺陷已解决。

executor 本轮结束，交回 root/coordinator 独立审核 fixture cleanup、路径预期与可靠诊断，再由 root 承担真实 CI。没有自行创建 verifier 或整体 pass 声明，没有 commit/push。
