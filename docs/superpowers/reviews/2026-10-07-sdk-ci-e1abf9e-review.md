# SDK CI 独立只读审核

日期：2026-10-07。基准及审核开始时 HEAD：`e1abf9e10d93ae32244315dbac792561814a77dc`。

**Verdict: fail。当前实现不建议提交/push；先修复 Important I1，再提交进行真实三平台 CI 验证。** 该判定来自本地复现的 CA 校验缺陷，并非因为 Windows/macOS 远端尚未运行。修复后的远端通过情况不能由本报告替代。

## 范围与方法

审核当前未提交的三个 tracked diff 和新增 `scripts/prepare_windows_https.ps1`，读取执行记录、原始失败日志、官方响应快照及 TDD/最终证据；独立运行测试，不以 executor 的通过声明作为依据。排除无关 `docs/superpowers/plans/2026-10-07-model-plan.md`，没有读取或修改它。

已读取 `requesting-code-review/SKILL.md`、其 `code-reviewer.md` 模板和 `verification-before-completion/SKILL.md`，路径均位于 `/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/`。遵守用户及 reviewer 模板的不派生 agent、只读审核要求。

只新增本报告，测试输出写入 `/tmp/leaf-ci-review-e1abf9e` 和已授权的 `target`。没有修改业务代码、Git 索引/HEAD/分支，没有 commit、push、发布或部署。审查前后四源码及执行记录 SHA256 一致；四源码还与 executor 的 `files.json` 一致。

并发状态说明：收尾时共享工作区 HEAD 已由其他操作推进到 `1b12ea806ed88df7cfd98ed6c9b73d2cba052044`。只读比较该提交与指定基准的文件名，唯一新增项为排除的 model plan；没有读取其内容。四被审源码和执行记录哈希未变，staged diff 为空，故本次测试和判定仍对应报告列出的同一 SDK 修复内容。首次收尾检查因 HEAD 与基准不同返回 1，证据保留于 `final-integrity.log`；明确并发变化后的检查成功，见 `final-integrity-after-concurrent-head.log`、`concurrent-head.json`。审核者没有做该提交或恢复 HEAD。

## Strengths

- `.github/workflows/release.yml:84` 保留 Windows 条件、pwsh 和步骤顺序，调用独立准备脚本；许可证收集仍使用 `NIM_SSL_VERSION`，原生安装/重定位验证仍在第 157 行实际执行，没有 TLS bypass 或跳过安装验证。
- `scripts/prepare_windows_https.ps1:19` 只枚举当前推导 Git root 下 `ucrt64`、`mingw64` 两类布局，先选 ucrt64；ssl/crypto/openssl.exe 必须同一 bin，CA 必须同一 prefix，支持两种 CA 位置。缺失/零长度明确失败。独立 PowerShell 补充测试验证了两个完整布局的优先级、不完整 ucrt64 到完整 mingw64 的 fallback，以及环境追加和中文路径。
- `scripts/prepare_windows_https.ps1:67` 在写环境之前实际调用 `NativeLibrary.Load/GetExport`，检查 OpenSSL 3 版本并运行 CA 转换；其坏库、缺导出、错误主版本、坏 PEM 失败分支在明确标注的 Linux 临时 harness 中均拒绝，未写环境。Windows 上同一代码是否加载成功仍待原生 CI。
- `scripts/smoke_sdk.nim:44` 对两端都解析真实路径，Unix 使用 Nim realpath，Windows 复用现有 `GetFinalPathNameByHandleW` helper，再保留相对路径目录边界和异常拒绝。独立测试验证别名双向接受、嵌套别名、内部文件链接、目录/文件逃逸、悬空链接、缺失路径、邻目录及 `..` 边界。对基准临时副本运行同组测试得到真实 RED，当前实现得到 GREEN。

## Issues

### Critical

无已确认问题。

### Important

**I1：不含任何证书的非空 CA 文件被当作有效 bundle，并发布 `SSL_CERT_FILE`。**

- 文件：`scripts/prepare_windows_https.ps1:76`、`:77`、`:80`；测试缺口位于 `tests/release/test_sdk.nim:230`、`:240`。现有测试 dot-source helper，只调用选择/环境函数，其 `fixture CA bytes` 不经过原生校验入口。
- 问题：`openssl crl2pkcs7 -nocrl -certfile ...` 可以对普通文本返回 0，并生成非空、但包含零张证书的 PKCS#7。检查退出码和输出文件大小不能证明 CA 被有效解析。
- 实证：本机 OpenSSL `3.6.4` 对 `fixture CA bytes\n` 返回 0，生成 95 字节 PKCS#7；再运行 `openssl pkcs7 -print_certs` 返回 0、输出 0 字节。原校验流程的 `/tmp` 副本仅移除 Windows 平台门禁，使用真实 Linux OpenSSL 库/导出和 executable，仍返回 0，并实际写入 `NIM_SSL_VERSION` 与指向垃圾 CA 的 `SSL_CERT_FILE`。正向有效 CA 成功，坏 PEM、坏库、缺导出、OpenSSL 2 均失败，说明问题定位在零证书接受条件。此 harness 不是 Windows DLL 验证。
- 实际后果：非空损坏或只有注释的 bundle 不会在 HTTPS 准备步骤明确失败，后续依赖证书信任的 HTTPS 操作可能失败；违反本任务“CA 完整、实际解析后才传环境”的要求。没有证据表明它关闭 TLS 或导致无验证连接，不作此推断。
- 修法：保留完整 PEM 转换/解析检查，再解码 PKCS#7 并要求至少一张实际解析出的 X.509 证书，例如对 `openssl pkcs7 -in ... -print_certs` 同时检查成功退出与输出中的证书块；之后才写 GitHub 环境。添加原生校验路径回归，覆盖真实有效 bundle、非空无证书文本/注释和畸形 PEM，并断言拒绝时不写 PATH/ENV。
- 证据：`/tmp/leaf-ci-review-e1abf9e/ca-garbage.log`、`native-harness-fixed-paths.log`、`native-harness/results.json`、`ca-regression.log`。独立拒绝断言 **exit=1**，确实捕获当前缺陷。[OpenSSL 官方说明](https://docs.openssl.org/3.0/man1/openssl-crl2pkcs7/) 将该命令定义为 PKCS#7 转换工具；零证书接受行为由以上本地实际执行证明。

### Minor

**M1：仓库回归未覆盖两个布局同时存在时的优先级与 fallback。**

- 文件：`tests/release/test_sdk.nim:250`、`:263`、`:277`。
- 当前分别覆盖新旧布局及不完整混合组合拒绝，没有覆盖“两个都完整选 ucrt64”与“不完整 ucrt64、完整 mingw64 应成功回退”。本审核补充 PowerShell 测试已证明当前实现正确，因此这不是已发现的功能缺陷。
- 后果：将来改变布局选择顺序或早退逻辑，现有仓库测试可能遗漏回归。
- 修法：把以上两种情形加入现有 fixture 测试；可参考 `/tmp/leaf-ci-review-e1abf9e/supplemental.ps1`。不需要新依赖。

## 独立测试命令与结果

完整命令、时间、退出码记录：`/tmp/leaf-ci-review-e1abf9e/commands.jsonl`。结果摘要：同目录 `summary.json`。

| 检查 | 实际结果 | 日志 |
| --- | --- | --- |
| 完整 release-only runner | exit 0；3 个文件、34 `[OK]`、0 `[SKIPPED]`、0 `[FAILED]`；PowerShell 测试实际执行 | `release-suite.log` |
| Windows Nim 分支 C 生成 | exit 0；含 junction 测试代码；没有 Windows 链接/执行 | `windows-compile.log` |
| PowerShell Parser、优先级/fallback、环境追加 | exit 0；实际调用现有 helper | `supplemental-pwsh.log` |
| 独立边界测试：基准实现 | exit 1；6 项中 4 项失败，符合 RED 预期 | `baseline-boundaries.log` |
| 独立边界测试：当前实现 | exit 0；6/6 通过 | `current-boundaries.log` |
| OpenSSL 无证书输入复现 | exit 0 表示复现命令成功；垃圾文本转换错误地成功 | `ca-garbage.log` |
| 原校验流程 Linux harness，6 种场景 | exit 0 表示 harness 确认结果；其中垃圾 CA 错误接受并写环境 | `native-harness-fixed-paths.log` |
| CA 必须拒绝无证书输入的独立断言 | **exit 1，回归失败，构成 I1 证据** | `ca-regression.log` |
| `git diff --check` | exit 0 | `diff-check.log` |

主要命令：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH NIM=/tmp/nim-2.2.6/bin/nim CARGO_HOME=/tmp/mui-cargo /tmp/nim-2.2.6/bin/nim c -r --nimcache:/tmp/leaf-ci-review-e1abf9e/nimcache --out:/tmp/leaf-ci-review-e1abf9e/test_runner scripts/test.nim --release-only
/tmp/nim-2.2.6/bin/nim c --os:windows --cpu:amd64 --compileOnly --path:src --nimcache:/tmp/leaf-ci-review-e1abf9e/windows-c --out:/tmp/leaf-ci-review-e1abf9e/test_sdk.exe tests/release/test_sdk.nim
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data /tmp/leaf-sdk-pwsh/pwsh -NoProfile -File /tmp/leaf-ci-review-e1abf9e/supplemental.ps1 -Helper /home/jimxl/projects/leaf/scripts/prepare_windows_https.ps1
python3 /tmp/leaf-ci-review-e1abf9e/native_harness.py
python3 /tmp/leaf-ci-review-e1abf9e/ca_regression.py
git diff --check
```

基准临时副本来自 `git show e1abf9e...:scripts/smoke_sdk.nim`，仅导出 `within` 以调用，未改 checkout。边界测试源码与完整编译命令见同目录 `baseline_boundaries.nim`、`current_boundaries.nim`、`commands.jsonl`。

如实保留一次 harness 设置失败：首次假定 Debian 的 `/usr/lib/x86_64-linux-gnu`，断言失败（`native-harness.log`，exit 1），没有进入校验逻辑；查明本机库位于 `/usr/lib` 后更正 `/tmp` harness 并运行上述六场景。未安装新依赖。

## 文件摘要与证据核对

| 文件 | 变更摘要 | SHA256 |
| --- | --- | --- |
| `.github/workflows/release.yml` | Windows HTTPS 内联准备改为调用脚本 | `e5866fbff06a63903417ad45bb18b22327a0c3025223986be2bbbd325d9ab5b4` |
| `scripts/prepare_windows_https.ps1` | 新增布局选择、依赖及原生探测、环境写入 | `7ffe81f712889fb1d0e5761cba7ad737323697a8e4efff44faa7b612d991bd6c` |
| `scripts/smoke_sdk.nim` | 两端真实路径解析，保留目录边界 | `2f9a14f16e7b6bee1bd0d6c8289060b7058bd5af0208b40048b17a89dad77902` |
| `tests/release/test_sdk.nim` | 真实路径及 PowerShell 布局/环境回归 | `830231b839ac60b24b37db3e45edddf9f28895f0a2a4bbff3a334fc50d9ea60d` |

独立哈希快照：`files-before.json`、`files-after.json`，位于 `/tmp/leaf-ci-review-e1abf9e`。执行记录为 `docs/superpowers/plans/2026-10-07-sdk-ci-e1abf9e-execution.md`。

原始 run `37572624868` 的三个 `/tmp/leaf-ci-{windows,macos-arm,macos-intel}-37572624868.log` 确认 Windows 缺硬编码 mingw64 SSL，macOS 两架构在 relocated SDK 边界检查报错。读取官方原始响应后确认 ucrt64 同名 DLL/executable 和 `ucrt64/etc/ssl/certs/ca-bundle.crt` 存在。上述修复方向与原失败一致。

Windows 大小写/根路径逻辑已读到 Nim 2.2.6 `relativePath` 的 Windows root 检查及按平台比较字符实现，并核查现有 helper 的长路径/UNC 前缀处理。未以阅读或 compileOnly 代替 Windows 实测。[Microsoft 文档](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew) 支持使用 handle 取得最终路径；[NativeLibrary.Load 文档](https://learn.microsoft.com/en-us/dotnet/api/system.runtime.interopservices.nativelibrary.load?view=net-9.0) 说明其使用操作系统加载器。

## Declined to judge

- Windows 实际 Git DLL 加载/导出、openssl/CA、真实 junction/文件链接及大小写路径运行：本机 Linux，无现成 Windows 执行环境；需要 push 后的真实 CI。Linux harness 不冒充 Windows 通过。
- macOS ARM/Intel 完整已安装 SDK 冒烟和 `/var`→`/private/var` 原生复测：本机 Linux；Unix真实 symlink 行为已测，但不能替代这两平台的完整原生安装。
- 原 DPI P1–P4 的 PE/初始化、144 DPI/1.5、视觉对照、同窗口变化与 IME/命中：本轮不改旧 DPI 实现，证据仍为 not_verified，未判定其完成。
- 无关 untracked model plan、全量 Rust/窗口回归以及 SDK 对恶意替换 Git 安装的完整供应链真实性证明：超出四文件修复范围；本报告只判断受支持布局完整性、已实现失败条件和已授权回归。

## 交接 coordinator

独立审核完成；Critical 0、Important 1、Minor 1。**当前 fail，应修复 I1 并补充拒绝回归，再提交/push 验证真实 CI。** M1 为可选测试补强。远端待跑是验证限制，不把本地代码审核一律标为 blocked，也不宣称 SDK/DPI 原生验收已通过。
