# SDK CI 修复执行记录 r2

日期：2026-10-07。开始和结束 HEAD：`c303806d7984fd12dbc4311d1ff5a48485e01d8b`，开始工作区 clean。本轮角色 executor，当前工具会话 `/root`；沿用用户指定的当前执行 runtime，没有创建 agent、会话或工作区，没有模型切换。本轮未 commit/push/发布/部署/安装/工作区清理或外部主机接入，没有读取凭据或无关 model plan 内容。

本轮完成多 Git Application 发现的最小修复和 Linux 可执行验证，交回 root 独立审核。**不宣称整体审核 pass，不以 Linux harness、C 生成或 36 项测试替代 Windows 原生入口实测。** 原 r0/r1 记录和所有原审核报告未修改。

## 根因、技能和实际复现

新 SDK run `37576721291`，Windows job `112647205752` 的原始日志 `/tmp/leaf-ci-windows-c303806.log` 显示 Git `2.55.0.windows.5`，在 `scripts/prepare_windows_https.ps1:9` 报 `Git HTTPS executable missing`，值包含 bin、cmd、mingw64/bin 三个 git.exe 路径。失败发生于默认发现后、DLL/TLS 验证前。保留新旧布局支持，无需修改版本或库策略。相关日志摘录位于 `/tmp/leaf-ci-e1abf9e-r2/ci-failure-excerpt.log`。

实际调用 `functions.exec → tools.exec_command` 读取当前脚本/测试/状态（chunk `59ccfa` exit 0），读取反馈日志及 `receiving-code-review/SKILL.md`、`systematic-debugging/SKILL.md`（chunk `4ea80d` exit 0）。技能来源为 `/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/`；此调用输出较长被截断，沿用本会话此前完整读取的相同技能内容（receiving chunk `9e805c`，debugging chunk `cabca3`）。TDD、`writing-good-tests.md`、`verification-before-completion` 也沿用本会话真实读取记录（chunks `9e805c`、`cabca3`，exit 0），没有据此创建 agent、提交或扩大范围。

在本轮新目录建立真实可执行的三个 git.exe shell 文件，放入中文空格 Git root 的 bin、cmd、mingw64/bin。真实 pwsh `Get-Command git.exe -CommandType Application` 返回三个 `Application` 对象；原 `(Get-Command ...).Source` 绑定 string 后连成一个不存在的路径，同样在 locator 拒绝。没有 mock Get-Command 或伪造 Application 对象。Nim 仓库测试在 Windows 上使用同名文件作发现 fixture，不执行它们；Linux 上赋予执行权限并由真实 PowerShell 发现。

## 最小改动范围

1. `scripts/prepare_windows_https.ps1`：新增 6 行 `Resolve-LeafGitExecutable` helper，显式路径原样优先返回；默认调用 `(Get-Command git.exe -CommandType Application | Select-Object -First 1).Source`。生产入口和仓库测试均调用同一 helper。只改变默认发现和入口调用，原受支持布局选择、库加载/导出、OpenSSL 3、CA 解码/X509 校验、环境发布顺序及 PATH finally 恢复原样保留。
2. `tests/release/test_sdk.nim`：新增一项真实 Application 发现回归，测试三个入口、首路径、PATH 重排、单入口、中文空格、所选路径确实存在及可进入原 mingw64 布局选择；空 PATH 下显式覆盖仍成功。fixture 的布局 DLL/CA 仅用于 locator，不冒充加载或证书验证。
3. 本新记录 `docs/superpowers/plans/2026-10-07-sdk-ci-e1abf9e-execution-r2.md`。

没有修改 workflow、smoke helper、依赖/vendor、版本、build.rs、旧 DPI 文件或旧 spec/plan/state/review。修改前后 SHA256 快照为证据目录内 `files-before.json` / `files-after.json`；旧执行记录、原审核报告、workflow 和 smoke 哈希全部不变。Git index 空、HEAD 未变、无其他意外未跟踪文件。

| 业务文件 | 开始 SHA256 | 当前 SHA256 |
| --- | --- | --- |
| `scripts/prepare_windows_https.ps1` | `5604220f169481da948aaed7ee3c5213a2932302bb901ed9ae511889cf064827` | `76ef7e68ed08d03f73647d5d7e42173e43e1c6833ef3b3ccc01067be8cb1af4f` |
| `tests/release/test_sdk.nim` | `b6b5cd89760a927aa5717f45c642ce56ae0f7b7d4669a4425d6038489f617916` | `f4709be6ba265543c13586183af9d4b212302230bf8d1cd55abda3ecfd907cb2` |

## TDD 和验证结果

证据目录 `/tmp/leaf-ci-e1abf9e-r2`；`run.py` 保留完整命令、stdout/stderr 和实际退出码，`commands.jsonl` 为命令清单及时间。外层记录工具的退出码不等于被测命令退出码，表中使用原始日志内实际值。

| 日志 | exit | 实际结果 |
| --- | --- | --- |
| `discovery-baseline-red.log` | 1（预期 RED） | 原生产表达式，真实三个 Application，绑定后拼成不存在的单路径；出现同类 executable missing。 |
| `discovery-helper-red.log` | 1（预期 RED） | 仓库测试写在修复前；仅抽出原发现逻辑，15 OK / 1 FAILED / 0 skipped，明确 `Discovery did not return one path string`。 |
| `discovery-helper-green.log` | 0 | 对仓库嵌入的同一发现脚本直接运行；确认三 Application、首项、重排、单项、显式覆盖及 legacy locator 全部通过，保留成功 stdout。 |
| `entry-regression.log` | 0（harness 断言） | 完整入口基准默认失败；修复后默认三入口与空 PATH 显式覆盖成功；垃圾 CA 和无效显式路径失败且不写 PATH/ENV，结果见 `entry-results.json`。 |
| `release-suite.log` | 0 | 完整 release-only runner：3 文件、36 OK、0 FAILED、0 skipped；新增发现测试与原真实 OpenSSL CA/布局/路径保护均实际执行。 |
| `windows-cgen.log` | 0 | 当前测试 Windows 宏分支仅 C 生成；保留原有未使用 import warnings，不宣称 warning-free 或 Windows native pass。 |
| `diff-check.log` | 0 | Git diff 空白检查通过。 |
| `integrity.log` | 0 | 仅两授权业务文件改变；旧记录/报告和 workflow/smoke 哈希不变、HEAD 未变、index 空。 |

入口 harness 在 `/tmp` 副本仅移除 Windows 平台门禁，三个真实可执行 git.exe 由 PATH 发现，不提供默认 GitExecutable 参数；使用本机真实 Linux OpenSSL 库及 executable，保持其余生产代码。默认修复完整调用库加载/导出、版本、PKCS#7/X509 校验及环境写入。显式成功场景初始 PATH 为空；无效显式路径在有三个有效默认入口时仍失败，证明覆盖不会静默回落默认。**Linux 库指向 Windows 风格 fixture 文件名仅供 Linux harness，不证明 Windows DLL 加载。** repo 回归直接 dot-source 真实 helper，无源码重写；standalone 发现脚本从同一嵌入原文提取。

入口子进程实际状态：

| 场景 | exit | 写 PATH / ENV |
| --- | --- | --- |
| baseline-default | 1 | 否 / 否 |
| current-default | 0 | 是 / 是 |
| current-explicit（初始 PATH 空） | 0 | 是 / 是 |
| current-garbage-ca | 1 | 否 / 否 |
| current-explicit-missing | 1 | 否 / 否 |

全部原始命令如下（亦可直接核对 `commands.jsonl`）：

`discovery-baseline-red`，exit `1`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data /tmp/leaf-sdk-pwsh/pwsh -NoProfile -File /tmp/leaf-ci-e1abf9e-r2/baseline_discovery.ps1 -Helper /tmp/leaf-ci-e1abf9e-r2/baseline-helper.ps1 -FixtureRoot "/tmp/leaf-ci-e1abf9e-r2/baseline Git 中文 spaces"
```

`discovery-helper-red`，exit `1`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r2/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r2/test_sdk tests/release/test_sdk.nim
```

`discovery-helper-green`，exit `0`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data /tmp/leaf-sdk-pwsh/pwsh -NoProfile -File /tmp/leaf-ci-e1abf9e-r2/discovery_tests.ps1 -Helper /home/jimxl/projects/leaf/scripts/prepare_windows_https.ps1 -GitRoot "/tmp/leaf-ci-e1abf9e-r2/discovery Git 中文 spaces"
```

`windows-cgen`，exit `0`：

```sh
/tmp/nim-2.2.6/bin/nim c --os:windows --cpu:amd64 --compileOnly --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r2/windows-c --out:/tmp/leaf-ci-e1abf9e-r2/test_sdk.exe tests/release/test_sdk.nim
```

`entry-regression`，exit `0`：

```sh
python3 /tmp/leaf-ci-e1abf9e-r2/entry_regression.py
```

`release-suite`，exit `0`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH NIM=/tmp/nim-2.2.6/bin/nim CARGO_HOME=/tmp/mui-cargo /tmp/nim-2.2.6/bin/nim c -r --nimcache:/tmp/leaf-ci-e1abf9e-r2/runner-nimcache --out:/tmp/leaf-ci-e1abf9e-r2/test_runner scripts/test.nim --release-only
```

`diff-check`，exit `0`：

```sh
git diff --check
```

`integrity`，exit `0`：

```sh
python3 /tmp/leaf-ci-e1abf9e-r2/integrity.py
```

## 原生验证边界与交接

本机已有 Nim `/tmp/nim-2.2.6/bin/nim`、pwsh `/tmp/leaf-sdk-pwsh/pwsh` 和 OpenSSL `/usr/sbin/openssl`。只使用命令局部 XDG 目录和工具 PATH，没有安装工具、修改 HOME 或全局配置。常规 target/Nim 编译缓存和临时 fixture 生命周期保持原授权范围。未重复全量 Rust 或 DPI 回归。

Windows 新提交的真实默认入口、Git 2.55/2.56 安装库/证书、Windows 真实路径/链接：仍 `not_verified`，需 root 审核后原生 CI 实测。本轮没有宣称已修好远端 run；原 run 已失败，新提交尚未发出。macOS ARM/Intel 的其余 CI 由 root 继续跟踪，本轮不推断其当前结果。

原 DPI P1–P4 必需 Windows 原生验收仍逐项 `not_verified`：P1 EXE 资源/复杂路径；P2 桌面加载前初始化、宿主与 headless；P3 真实 144 DPI/1.5 和原图；P4 同窗口 DPI 变化、输入/IME 命中。没有最终 Windows 清晰度证明。原 build.rs 全局 fmt 基线限制仍保留，本轮未修改或声称通过。

本轮 executor 工作结束，交回 root/coordinator 独立审核默认发现修复与当前证据。没有创建 verifier、没有整体 pass 声明、没有 commit/push。
