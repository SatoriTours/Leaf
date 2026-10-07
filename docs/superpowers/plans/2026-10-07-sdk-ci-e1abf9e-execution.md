# SDK CI 失败修复执行记录

本轮目标是修复已观察的发布流程失败，基准 HEAD `e1abf9e10d93ae32244315dbac792561814a77dc`，首次检查工作树 clean。保持同一 executor 会话顺序实施，按用户指定 GPT‑6.1‑Sol 审核/开发授权执行；不更改 provider、不读凭据，不创建 agents。不 commit/push，由 coordinator/root 独立审核后处理。旧 DPI spec/plan/state/reviews/artifact 记录及 16 个 DPI 业务文件未修改。

实际使用技能（通过 functions.exec → exec_command cat 读取）：

- systematic-debugging、test-driven-development、writing-good-tests：`/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/` 对应文件，chunk `5dd06b`、exit=0；前序同会话已完整读过 writing-good-tests。本轮先读取实际日志、源码和平台实现，再形成假设。
- verification-before-completion：同路径 `verification-before-completion/SKILL.md`，chunk `2bc1f3`、exit=0。

## 根因与实证

CI run `37572624868` 最终 failure，普通 Linux 与 Linux SDK 成功（coordinator 已确认）。本轮实际读取三个失败平台的原始日志：

- Windows job `112634467411`：`/tmp/leaf-ci-windows-37572624868.log`。HTTPS 步骤硬编码 `C:\Program Files\Git\mingw64\bin\libssl-3-x64.dll`，文件缺失而退出；Git 实际为 `2.56.0.windows.1`，runner `windows-2022` image `20261004.326.1`。
- macOS ARM job `112634467448`：`/tmp/leaf-ci-macos-arm-37572624868.log`。doctor 返回 `/private/var/folders/...`，SDK 路径来自 `/var/folders/...`；`smoke_sdk.within` 只做绝对/相对路径的词法判断，误报 Nim outside relocated SDK。
- macOS Intel job `112634467463`：`/tmp/leaf-ci-macos-intel-37572624868.log`，同一 alias 问题，桥接和 CLI 架构回归已成功；无需第三种修复。

两个失败脚本不是 DPI 提交 diff 中的文件，是已有发布流程暴露的缺陷，不能归因于 DPI 布局/渲染修复。

官方证据（实际 web open + 有边界的 GitHub API 查询，未作全盘搜索）：

1. [Git for Windows 官方 release notes](https://github.com/git-for-windows/build-extra/blob/main/ReleaseNotes.md)：2.56 从 MINGW64 迁移至 UCRT64，`/ucrt64/bin` 替代 `/mingw64/bin`；`/cmd/git.exe` 为稳定入口。
2. [官方 Git SDK 的 ucrt64/bin 文件列表](https://api.github.com/repos/git-for-windows/git-sdk-64/contents/ucrt64/bin)：实际列出 `libssl-3-x64.dll`、`libcrypto-3-x64.dll`、`openssl.exe`；名称后缀仍为 `3-x64`。
3. [官方 SDK CA 目录](https://api.github.com/repos/git-for-windows/git-sdk-64/contents/ucrt64/etc/ssl/certs)：存在 `ca-bundle.crt`。官方 [installer 源码](https://github.com/git-for-windows/build-extra/blob/main/installer/install.iss) 优先 `{prefix}/etc/ssl/certs/ca-bundle.crt`，兼容 `{prefix}/ssl/certs/ca-bundle.crt`。
4. [对应 runner image release](https://github.com/actions/runner-images/releases/tag/win22/20261004.326) 明确 Git `2.55.0.windows.5`→`2.56.0.windows.1`，与真实 job 的 image 版本一致。未使用落后于 release 的 main README 来冒充当前镜像版本。

初次 sandbox 网络请求 DNS 失败（chunk `5266b8` exit=1）；依用户已授权联网调查使用 require_escalated 读取上述四个固定官方 URL，实际成功（chunk `30d686` exit=0），没有审批拒绝。原始响应在 `/tmp/leaf-ci-e1abf9e/{ucrt64-bin,ucrt64-cert,release-notes,runner-releases}.txt`，未下载/安装新的运行库。

平台真实路径实现已核对 Nim 2.2.6 与现有项目 helper：Unix `expandFilename` 使用 realpath；Windows std/os.expandFilename 的 GetFullPathNameW 不解析 junction。修复优先复用 `src/leaf/windows_paths.nim:realPath` 的 GetFinalPathNameByHandleW，保留 Unix realpath 和相对路径边界检查。

## 实施范围与行为

仅四个源码文件：

- `.github/workflows/release.yml`：原 Windows HTTPS 内联硬编码步骤改为调用准备脚本。条件、shell、步骤顺序、发布/打包/许可证收集与原生安装验证架构保持原样。
- 新增 `scripts/prepare_windows_https.ps1`：只检查当前 Git 根内 ucrt64/mingw64 两种受支持 x64 OpenSSL 3 布局，支持 cmd/bin wrapper 和原生 prefix/bin 入口；完整的 ssl/crypto/openssl.exe 与同一 prefix 的 CA 必须存在且非空，不跨布局拼凑。缺失明确失败。执行路径在 Windows 实际加载 DLL 并检查 OpenSSL/SSL exports，运行 openssl 3 version 和 CA 解析后，才写入 GITHUB_PATH、NIM_SSL_VERSION=3-x64、SSL_CERT_FILE（UTF-8）。PATH 传递保留整个依赖 bin，未跳过 TLS 或禁用证书检查，未新增下载安装。
- `scripts/smoke_sdk.nim`：两端均解析真实路径后，再做 relativePath 边界保护；不可解析/不存在的目标拒绝。测试所用 within 导出，smokeSdk 的检查仍然实际使用该函数。
- `tests/release/test_sdk.nim`：增加真实文件/目录 alias 和边界测试，以及通过现有 PowerShell 实际执行的 Windows HTTPS 函数回归。现有 release runner 已自动执行此文件，不需要改 runner 注册。

未修改依赖、版本、vendor、build.rs、DPI 文件、旧文档/审查记录。测试中的归档/安装只发生于现有临时 fixture 生命周期，没有安装全局工具或发布 SDK。

## TDD 和验证

路径测试的预期 break 是“不解析真实 alias/逃逸”：初次测试因 private within 未导出失败，先只导出原词法实现，再运行实际 RED。`paths-red-behavior.log` 明确两种 alias 被拒绝、目录/文件 symlink 逃逸被错误接受；原有 installer 测试成功。替换真实路径解析后 GREEN，边界保护没有放宽。

HTTPS 测试先写：`https-red.log` 表明 helper 未实现，测试无法载入；随后实现 helper。`sdk-green.log` 所有新增/既有测试通过。新布局、旧布局两种 CA 位置、cmd/bin/native 入口、中文/空格路径、GitHub 环境传递、缺 ssl、缺/空 crypto、缺 CA、跨布局不完整组合都由实际 PowerShell 函数调用验证。

本机已有 `/tmp/leaf-sdk-pwsh/pwsh` 7.6.6，但默认 XDG 缓存/数据目录只读（初次调用发生初始化失败（组合命令未单独记录 pwsh exit）；第二次独立调用 exit=70，工具记录 chunk `1ee861`、`ed89a4`）。改用命令级 `/tmp/leaf-ci-pwsh/{cache,config,data}`，不改 HOME、全局配置或安装 PowerShell；version 成功 chunk `1ab22c` exit=0。最终 release suite 的 PowerShell 回归实际运行，没有 skip。

最终验证（后续没有再改代码）：release-only 的 3 个测试文件、34 项测试通过；Windows Nim 分支 compileOnly 成功，含未来原生 junction alias/逃逸测试。没有重跑无关 DPI Nim/Rust 全量测试。

原始命令、stdout/stderr 与退出码在 `/tmp/leaf-ci-e1abf9e/commands.jsonl` 及对应 `.log`。下表包括实际失败，不掩盖 RED：

| 检查 | Exit | 原始日志 |
| --- | --- | --- |
| paths-red | 1 | `/tmp/leaf-ci-e1abf9e/paths-red.log` |
| paths-red-behavior | 1 | `/tmp/leaf-ci-e1abf9e/paths-red-behavior.log` |
| https-red | 1 | `/tmp/leaf-ci-e1abf9e/https-red.log` |
| sdk-green | 0 | `/tmp/leaf-ci-e1abf9e/sdk-green.log` |
| windows-c | 0 | `/tmp/leaf-ci-e1abf9e/windows-c.log` |
| release-suite | 0 | `/tmp/leaf-ci-e1abf9e/release-suite.log` |
| final-diff-check | 0 | `/tmp/leaf-ci-e1abf9e/final-diff-check.log` |

关键命令全文：

```sh
# 所有测试使用已存在的 Nim/PowerShell；XDG 仅指向任务临时目录
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH NIM=/tmp/nim-2.2.6/bin/nim CARGO_HOME=/tmp/mui-cargo /tmp/nim-2.2.6/bin/nim c -r --out:/tmp/leaf-ci-e1abf9e/test_runner scripts/test.nim --release-only
/tmp/nim-2.2.6/bin/nim c --os:windows --cpu:amd64 --compileOnly --path:src --nimcache:/tmp/leaf-ci-e1abf9e/windows-c tests/release/test_sdk.nim
git diff --check
```

## 实際限制及交接

Linux 上真实 symlink/边界和 PowerShell 布局/拒绝/环境传递均已验证；Windows compileOnly 仅为 C 生成。**not_verified**：Windows 实际 DLL 加载/export/openssl/CA 解析执行、原生 junction，以及两种 macOS 平台的完整已安装 SDK 冒烟验证。修复后的 GitHub CI 未由 executor 重新触发，最终是否消除两个 CI 错误需 coordinator 审核并 push 后在新 run 证实。不能把本地 layout fixtures 当作真实 Windows TLS 运行成功。

原 DPI P1–P4 必需原生项继续 not_verified，包括 PE/初始化、144DPI/1.5比例与原图、同窗口变化/IME命中；本轮修复不提供 Windows 清晰度证明。全局 build.rs 格式限制没有触碰。

执行到此完成并交回 coordinator/root 独立审核。没有创建 verifier/agent，没有 commit/push/发布或接入外部主机。文件 SHA256 保存在 `/tmp/leaf-ci-e1abf9e/files.json`，便于复核本轮修改范围。
