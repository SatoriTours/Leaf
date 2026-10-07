# SDK CI r3 补修执行记录：完整输出收集

日期：2026-10-07。HEAD 始终为 `5b4bb0eb0b625f1cbd7e9c5d9683091d765cda17`。角色 executor，沿用当前授权执行 runtime，没有模型切换、agent/会话/工作区创建、commit/push、发布、部署、安装、外部主机接入或工作区清理。没有读取凭据或无关 model plan。

本轮按 root 新增明确授权修改 `scripts/smoke_sdk.nim` 的此处读取逻辑，覆盖此前 generic reader 不改的限制。当前 r3 junction 清理、fixture 路径归一化、完整失败 Message 文件和 CA 诊断均保留。**本记录是补修执行证据，不是独立审核 pass，不宣称 Windows native 或 DPI P1–P4 通过。** 原 r3 与全部更早执行记录、报告未修改。

## 根因与源码核对

本轮实际读取 `/tmp/nim-2.2.6/lib/pure/streams.nim:280–311`、`/tmp/nim-2.2.6/lib/pure/osproc.nim:552–569` 和 `scripts/smoke_sdk.nim`（`functions.exec → tools.exec_command`，chunk `34d4f7` exit 0）。readAll 对任何非零且小于请求缓冲的读取都会结束；Windows hsReadData 则把实际 ReadFile 的非零短读取返回，仅在 br==0 时置 atTheEnd。旧 runCommand 使用 readAll 后 waitForExit，不符合仍有后续输出的阻塞管道契约，可能截断输出；子进程后续输出超过管道容量时还存在未排空便等待的阻塞机制。本机没有 Windows runtime，未声称复现了 Windows 实际死锁。

根因核对后先写稳定短读反例，保留同一生产读取路径的 RED，再实现读到实际 0/EOF。技能沿用本会话已读 systematic-debugging/TDD/verification-before-completion；本轮重新完整读取 receiving-code-review 与 TDD 的 writing-good-tests（chunk `d2b77b` exit 0），来源 `/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/`。测试只断言完整输出/退出码，不把调用次数或 mock 行为当证明。

## 本轮实际改动

1. `scripts/smoke_sdk.nim`：新增生产 `readCommandOutput*(Stream)`，按块持续 readData，非零短读照常追加原始字节，仅在返回 0 时停止；runCommand 调用同一函数，读取完成后才 waitForExit。正常读取异常继续传播，进程 close defer 保留。命令参数、批处理包装、stdout/stderr 合并、环境及退出码逻辑未改，within 真实路径保护未改。该 helper 同时用于真实 runCommand 与短读 Stream 回归，没有测试专用分支。
2. `tests/release/test_sdk.nim`：新增一个满足 Stream 接口的内存短读源，每次最多 3 字节。回归包含空流、中文 UTF-8 与 NUL、17,003 字节跨块数据；直接对生产 collector 的结果检查逐字节完整性。另一回归启动本测试二进制的专用 child mode，先写并 flush `EARLY|`，延迟 50ms，再分别写 stdout 131,089 个 A 与 stderr 131,117 个 B，flush 并写各自 tail，退出 23。真实 runCommand 必须读取完整 **262,232** 字节的合并内容且保持退出码 23。无需额外 binary、网络或测试跳过；输出使用无换行 ASCII，使 Windows CRT 换行转换不影响字节断言。
3. 本新增 `docs/superpowers/plans/2026-10-07-sdk-ci-e1abf9e-execution-r3-continuation.md`。

只有上述两源码相对本轮开始改变。没有修改 HTTPS 产品脚本、CA 校验、DPI、workflow、依赖、vendor 或其他源码模块。原 r3 记录仍完整保留，不把其阶段性测试数更新为当前数。

| 文件 | 开始 SHA256 | 当前 SHA256 |
| --- | --- | --- |
| `scripts/smoke_sdk.nim` | `2f9a14f16e7b6bee1bd0d6c8289060b7058bd5af0208b40048b17a89dad77902` | `76f290f300fbda6727d0fb7db47a586e8e38ab4b86d803495c80885222bffcfd` |
| `tests/release/test_sdk.nim` | `ba907a73a44c631b473097f92cd118c2d10564b0f82e654d955805d5f23db008` | `f378cb7a858f989e63ff5272eea63c65a1bd13ff13d39d004db0bc141f62765d` |

哈希快照：`/tmp/leaf-ci-e1abf9e-r3-continuation/files-before.json`、`files-after.json`。`smoke-before.nim`、`test-sdk-before.nim` 保存本轮开始字节。旧 r3 和所有更早 SDK 记录/review、HTTPS helper、workflow 哈希不变；HEAD 未变、index 空。

## RED / GREEN 与当前验证

证据目录 `/tmp/leaf-ci-e1abf9e-r3-continuation`，原始命令/时间/真实退出码/日志路径保存于 `commands.jsonl`，计数汇总为 `summary.json`。run.py 外层正常结束不代表被测命令通过，以下按日志内实际值记录。

| 日志 | exit | 实际结果 |
| --- | --- | --- |
| `original-stream-red.log` | 1（预期 RED） | 修改生产代码前，使用实际 std/streams.readAll 和有效 3 字节短读 Stream，20 字节输入只读回 3 字节，完整性断言失败，稳定复现。 |
| `collector-red.log` | 1（预期 RED） | 仓库回归先写；仅抽出原 readAll 逻辑并让 runCommand 调用同一 helper，尚未修复。20 OK / 1 FAILED / 0 skipped，短读回归捕获截断。真实大输出 child 在旧 Linux 路径已通过，此项不误报为 Linux 原生短读 RED。 |
| `collector-green.log` | 0 | 持续 readData 到 0 后，SDK 21 OK / 0 FAILED / 0 skipped，空/中文/NUL/跨块与真实 child 两回归通过，原 r3 保护均通过。 |
| `release-suite.log` | 0 | 当前完整 release-only runner：3 文件、41 OK / 0 FAILED / 0 skipped；真实 child、PowerShell、真实 OpenSSL、路径/清理/失败诊断均实际执行。 |
| `windows-cgen.log` | 0 | 最新 Windows 宏分支 C 生成，覆盖 collector/child mode 和 r3 Windows fixture API。未链接、执行或冒充 native pass；已有 unused import warnings 保留。 |
| `diff-check.log` | 0 | 当前 Git diff 空白检查通过。 |
| `integrity.log` | 0 | 本轮只有两个授权源码改变；旧 r3 与更早记录/review 和 HTTPS helper/workflow不变，HEAD未变、index空。 |

短读源没有模拟 runCommand/进程返回值，而是提供一个真实 Stream 实现，供生产 collector 实际读取。稳定 RED 在 Linux 也可运行，不依赖 OS 时序。实际子进程回归走 runCommand/startProcess/真实合并管道，分离早期短输出和后续超过典型管道缓冲的输出；本机验证的是 Linux 运行。未把其 Linux 旧实现通过解释为 Windows 旧逻辑安全，也未声称已证实 Windows 的新实现不会阻塞。

完整实际命令：

`original-stream-red`，exit `1`：

```sh
/tmp/nim-2.2.6/bin/nim c -r --nimcache:/tmp/leaf-ci-e1abf9e-r3-continuation/original-nimcache --out:/tmp/leaf-ci-e1abf9e-r3-continuation/old_short_read /tmp/leaf-ci-e1abf9e-r3-continuation/old_short_read.nim
```

`collector-red`，exit `1`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r3-continuation/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r3-continuation/test_sdk tests/release/test_sdk.nim
```

`collector-green`，exit `0`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r3-continuation/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r3-continuation/test_sdk tests/release/test_sdk.nim
```

`windows-cgen`，exit `0`：

```sh
/tmp/nim-2.2.6/bin/nim c --os:windows --cpu:amd64 --compileOnly --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r3-continuation/windows-c --out:/tmp/leaf-ci-e1abf9e-r3-continuation/test_sdk.exe tests/release/test_sdk.nim
```

`release-suite`，exit `0`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH NIM=/tmp/nim-2.2.6/bin/nim CARGO_HOME=/tmp/mui-cargo /tmp/nim-2.2.6/bin/nim c -r --nimcache:/tmp/leaf-ci-e1abf9e-r3-continuation/runner-nimcache --out:/tmp/leaf-ci-e1abf9e-r3-continuation/test_runner scripts/test.nim --release-only
```

`diff-check`，exit `0`：

```sh
git diff --check
```

`integrity`，exit `0`：

```sh
python3 /tmp/leaf-ci-e1abf9e-r3-continuation/integrity.py
```

## 限制与交接

使用已有 Nim `/tmp/nim-2.2.6/bin/nim`，命令局部 XDG/PATH 与既有 pwsh；没有安装或全局配置更改。保留原 r3 诊断文件作为完整错误文本的额外保障，没有删除或弱化该入口。没有猜测 CA Unicode 失败根因，证书转换、PKCS#7 解码和 X509 检查原样保留。

Windows 原生 collector/延迟与大输出管道、junction target 保留、8.3 路径比较以及三个 PS fixture 的真实 Message 与 CA Unicode 行为仍 **not_verified**，由 root 审核后发起 native CI。Windows C 生成不等于 native 通过。原 DPI P1 EXE 资源/复杂路径、P2 初始化/宿主/headless、P3 144 DPI/1.5与原图、P4 同窗口 DPI 变化/输入/IME 必需 native 验收仍逐项 **not_verified**，无最终 Windows 清晰度证明。

本 continuation 的授权实现与 Linux 验证结束，交回 root；由 root 派独立 GPT-6.1-Sol 审核。本 executor 未创建 verifier、未整体 pass 声明、未 commit/push。
