# SDK CI r4 执行记录：OpenSSL Windows UTF-8 argv

日期：2026-10-07。开始/结束 HEAD：`9b930a24c74b31f9e9f1028ebf43b59bbb8273a7`。角色 executor，沿用已授权当前会话 runtime，未切换模型、创建 agent/会话/工作区或独立 reviewer。本轮没有 commit/push、发布、部署、安装、外部主机接入、读取凭据或工作区清理。提交/push 和新的独立审核交由 root。

## 已核实原因与边界

实际读取 `/tmp/leaf-ci-windows-9b930a2.log`。原生 run `37581190120` / Windows job `112661058213` 中 layout/discovery、junction、路径、输出 collector/诊断已成功；剩余 real OpenSSL CA fixture 的 req 失败。原始 Message 显示中文目录从 `leaf CA 中文 space` 损坏为 `leaf CA ?? space`，key 创建报 Invalid argument。摘录 `/tmp/leaf-ci-e1abf9e-r4/native-red.log`；原始完整日志保留在上述 root 提供路径。这是 Windows 原生 RED，未声称 Linux 能复现该代码页转换。

本轮通过 `functions.exec → tools.web__run` 实际核对官方来源：

- [OpenSSL 环境文档](https://docs.openssl.org/3.6/man7/openssl-env/) 472–474：`OPENSSL_WIN32_UTF8` 使 Windows CLI 参数使用 UTF-8；只在 Windows 被 OpenSSL 检查。
- 同版本 [win32_init.c](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/apps/lib/win32_init.c) 138–145、246–259：环境开关控制 GetCommandLineW，然后 WideCharToMultiByte(CP_UTF8)。
- [openssl.c](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/apps/openssl.c) 239–242：Windows main 调用 win32_utf8argv。
- [crypto/o_fopen.c](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/crypto/o_fopen.c) 44–68：UTF-8 文件名经 MultiByteToWideChar 后传入 _wfopen。

读取工具证据：源码/日志 chunks `d206ab`、`80262e`（exit 0）；web 返回 `turn7view0/1/2`、`turn8view0/1/2`。本轮重新实际读取 systematic-debugging 与 test-driven-development（chunk `80262e` exit 0；回显有 token 截断，沿用本会话此前已完整读取内容），receiving-code-review 沿用本轮前段读取 `e44242` 和本会话既有完整读取。verification-before-completion 再次完整实际读取，chunk `a9dff7`、原始 `verification-skill.log` exit 0。技能来源均为 `/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/` 下对应 SKILL.md。按已批准的窄范围顺序自执行，用户禁止 agent/commit/worktree 的约束覆盖技能默认流程。

## 实际改动

1. `scripts/prepare_windows_https.ps1`：仅在 Assert-LeafGitHttpsCertificates 的现有 try 内设置 `OPENSSL_WIN32_UTF8=1`，覆盖 crl2pkcs7、pkcs7 解码、x509 三次真实 native 调用。finally 恢复原非空/空值；原值为 null 时显式移除变量。转换退出码、非空输出、至少一张实际解析 X509 的原校验保留，验证成功后才写 runner PATH/ENV，未增加 GITHUB_ENV 全局开关。
2. `tests/release/test_sdk.nim`：证书生成 req 使用独立 try/finally 开关，调用后校验恢复，中文/空格目录、中文 CA 文件名和该目录内 key 保留。先直接执行产品校验真实 OpenSSL，再通过本测试二进制的 test-only child mode 检查 native 边界环境并转交真实 OpenSSL；不模拟证书解析或返回成功。child 逐次记录 argv/开关，要求值为 1，再实际启动 OpenSSL 并保持输出/退出码。对子进程三段成功校验、中文 cert argv/内容保持、未写额外 ENV 开关断言；调用者未设置/已有原值各覆盖成功和垃圾/注释/畸形 PEM 拒绝，PATH/ENV 文件 absent/已有 sentinel 共 12 次拒绝均保持。拒绝轨迹也要求子进程收到开关，避免把代理自身拒绝当作真实 CA 拒绝。仅 PowerShell fixture 子进程设置 test-only delegate/trace 变量，不影响父 Nim/全局配置。
3. 新增本记录。所有 r0–r3/continuation 记录/review 保留，collector、workflow、DPI、依赖及其他业务源码未改。

## TDD 与验证结果

证据目录 `/tmp/leaf-ci-e1abf9e-r4`。`commands.jsonl` 保存每条实际命令、UTC、真实退出码和原始日志路径；`summary.json` 保存计数。run.py 外层 exit 0 不代表被测命令通过，以下取被测命令真实状态。没有重复已通过的 DPI/Nim/Rust 全量回归。

| 日志 | exit | 实际结果 |
| --- | --- | --- |
| `utf8-red.log` | 1（预期 RED） | 测试先改、产品未改；20 OK / 1 FAILED / 0 skipped。真实 native child 收到空开关并 exit 97，有效 CA 失败，准确捕获产品漏设置；`test-sdk-red.nim` 和 `https-before.ps1` 保存阶段字节。 |
| `utf8-green.log` | 1（补修中失败） | 初次设置开关后，恢复 null 的 .NET API 在 Linux 留下空变量，生成后恢复断言失败。没有隐瞒或标为 green。 |
| `env-restore-probe.log` | 0 | 独立 pwsh 实测：初始 IsNull=true/Present=false；SetEnvironmentVariable(null) 后 Value=""/Present=true；Remove-Item 后重新 null/absent。根据此证据改为显式移除。 |
| `utf8-green-restored.log` | 0 | 21 OK / 0 FAILED / 0 skipped；有效 CA 和三类严格拒绝、两种调用者状态全部通过。 |
| `release-suite.log` | 0 | 最新最终源码完整 release-only runner：3 测试文件，41 OK / 0 FAILED / 0 skipped；含新增直接调用与拒绝轨迹断言。真实 pwsh、OpenSSL、native child 都执行。 |
| `windows-cgen.log` | 0 | 最新 Windows amd64 宏分支 C 生成成功；没有链接/执行。已有 process_io、archives/checksum/archive_reader unused import 和 install 未使用提示保留，不把 Cgen 当 Windows native。 |
| `diff-check.log` | 0 | Git diff 空白检查通过。 |
| `integrity.log` | 0 | HEAD 不变、index 空，仅两授权业务源码改变；旧记录/reviews、smoke collector、workflow 哈希不变，untracked 范围受限。 |
| `final-integrity.log` | 0 | 新记录写入后的相同边界/摘要检查再次通过；新增 untracked 仅本记录。 |
| `verification-skill.log` | 0 | 完整技能读取。 |
| `tool-versions.log` | 0 | 本机 pwsh 7.6.6、Nim 2.2.6、OpenSSL 3.6.4。本机 OpenSSL 与 Windows 3.5.7 平台/版本不同，未作原生等价声明。 |

关键完整命令及其所有原始结果也保存在 commands.jsonl：

`utf8-red` exit `1`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r4/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r4/test_sdk tests/release/test_sdk.nim
```

`utf8-green` exit `1`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r4/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r4/test_sdk tests/release/test_sdk.nim
```

`env-restore-probe` exit `0`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data /tmp/leaf-sdk-pwsh/pwsh -NoProfile -File /tmp/leaf-ci-e1abf9e-r4/env_restore_probe.ps1
```

`utf8-green-restored` exit `0`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r4/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r4/test_sdk tests/release/test_sdk.nim
```

`release-suite` exit `0`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH NIM=/tmp/nim-2.2.6/bin/nim CARGO_HOME=/tmp/mui-cargo /tmp/nim-2.2.6/bin/nim c -r --nimcache:/tmp/leaf-ci-e1abf9e-r4/runner-nimcache --out:/tmp/leaf-ci-e1abf9e-r4/test_runner scripts/test.nim --release-only
```

`windows-cgen` exit `0`：

```sh
/tmp/nim-2.2.6/bin/nim c --os:windows --cpu:amd64 --compileOnly --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r4/windows-c --out:/tmp/leaf-ci-e1abf9e-r4/test_sdk.exe tests/release/test_sdk.nim
```

`diff-check` exit `0`：

```sh
git diff --check
```

`integrity` exit `0`：

```sh
python3 /tmp/leaf-ci-e1abf9e-r4/integrity.py
```

## 文件摘要与必需未验证项

`before.json` / `after.json` 保存源码和旧记录摘要。

| 文件 | 开始 SHA256 | 最终 SHA256 |
| --- | --- | --- |
| `scripts/prepare_windows_https.ps1` | `76ef7e68ed08d03f73647d5d7e42173e43e1c6833ef3b3ccc01067be8cb1af4f` | `160c568f49b2b1b2362d30a72635c31e5afa795aa104b8b3d497375c498272dd` |
| `tests/release/test_sdk.nim` | `f378cb7a858f989e63ff5272eea63c65a1bd13ff13d39d004db0bc141f62765d` | `ff8770011ef6c9d51125f3c0552503dfedff7345a326345f38dae04ffa0c2144` |

Linux 可执行的本轮实施、环境传播/恢复、真实 OpenSSL 严格校验和 release 回归完成；Windows 原生 Unicode argv 修复结果仍 **not_verified**，需要 root 独立审核并在真实 Windows runner 重跑。没有本地 Windows runtime，C 生成和 Linux 41 pass 不替代该验收，也没有总体 CI/整体验收 pass 声明。

原 DPI 必需 P1 EXE 资源/复杂路径、P2 Windows 初始化与宿主/headless、P3 144DPI/1.5及原图、P4 同窗口 DPI 变化/输入 IME 命中均继续 **not_verified**。没有最终 Windows 清晰度证明。本轮仅解决有原生日志证据的剩余 CA argv 根因，不扩大 Windows 架构或发布流程。

执行结束交回 root 独立 GPT-6.1-Sol 审核；未创建 verifier 或自行批准合并/发布。
