# SDK CI 修复执行记录 r1

日期：2026-10-07。基准为原 CI 提交 `e1abf9e10d93ae32244315dbac792561814a77dc`；本轮开始及结束共享 HEAD 为 `1b12ea806ed88df7cfd98ed6c9b73d2cba052044`。后者为 coordinator 已说明的并发 model plan 提交，本轮没有读取其内容。角色 executor，当前工具会话标识 `/root`；沿用当前 runtime，没有创建 agent、会话或工作区。

本轮完成授权的 I1 代码修复和 M1 测试补强，Linux 可执行验证已完成，交回 root 独立复审。**本记录不作整体审核 pass 判定，不替代 Windows/macOS 原生 CI，也不证明 DPI 清晰度。** 未 commit、push、发布、部署、安装、清理工作区或连接外部主机，没有读取凭据。没有重跑已通过的全量 Rust/DPI 回归。

## 反馈核实与技能证据

已真实读取 `docs/superpowers/reviews/2026-10-07-sdk-ci-e1abf9e-review.md` 及 `/tmp/leaf-ci-review-e1abf9e/ca-garbage.log`，核实非空垃圾文本可转换为非空、零证书 PKCS#7。进一步在本轮新目录重新执行原生产入口的 Linux harness，确认原行为接受垃圾 CA 并实际写环境，拒绝断言 exit 1。不是仅依据审核结论改 fixture。

以下技能通过 `functions.exec → tools.exec_command` 实际 `cat` 读取；来源根目录 `/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/`：

- `receiving-code-review/SKILL.md`：工具 chunk `9e805c` exit 0（此前反馈读取 chunk `659d99` 亦 exit 0）。核实 I1 实证与现有入口后实施，不修改审核报告。
- `test-driven-development/SKILL.md`、`verification-before-completion/SKILL.md`：chunk `9e805c` exit 0。先真实 RED，再最小修复和当前源码 GREEN。
- `systematic-debugging/SKILL.md`、`test-driven-development/writing-good-tests.md`：chunk `cabca3` exit 0。该调用同时完整读取审核 harness 和拒绝断言，追踪问题位于转换成功与环境写入之间。
- 审核报告、复现日志及测试入口读取：chunk `add724` exit 0；本轮修改前哈希和 HEAD 核对：chunk `d5b456` exit 0。

## 本轮实际文件范围

只在 r0 内容上继续修改两个业务文件，新增本执行记录。其余工作区未提交的 r0 业务变更仍保留，并非本轮重新实现。

1. `scripts/prepare_windows_https.ps1`：抽出 `Assert-LeafGitHttpsCertificates` 与 `Publish-LeafGitHttpsEnvironment`。保留 `crl2pkcs7` 转换、退出码、非空输出检查，再实际执行 `pkcs7 -print_certs` 解码并检查退出码和非空输出，最后执行 `x509 -noout` 要求至少一张实际解析的 X509 证书。通过后才写 GitHub PATH/ENV。生产入口仍先检查库加载、导出和 OpenSSL 3 版本，调用同一发布 helper；进程 PATH 的 finally 恢复与库释放保留。两个证书中间临时文件仅用于校验，finally 删除。
2. `tests/release/test_sdk.nim`：新增真实 OpenSSL CA 回归，生成一次性测试证书，覆盖有效 CA、非空垃圾、纯注释和畸形 PEM。每种拒绝分别检查不存在的 runner 文件不会被创建，以及既存 runner 文件原字节不变；同时检查进程 PATH 不变，覆盖中文和空格路径。测试 dot-source 实际生产脚本，调用生产发布 helper，没有替换 OpenSSL 命令或仅断言 fixture。现有布局 fixture 增加“两边完整优先 ucrt64”和“ucrt64 不完整回退完整 mingw64”。
3. `docs/superpowers/plans/2026-10-07-sdk-ci-e1abf9e-execution-r1.md`：新记录，保留 r0 原记录。

修改前后 SHA256 快照：`/tmp/leaf-ci-e1abf9e-r1/files-before.json`、`files-after.json`。相对于 r0，仅以上两个业务文件哈希改变；workflow、smoke helper、r0 执行记录和原审核报告哈希完全一致。HEAD 未变，Git index 为空。没有修改旧 DPI、spec/plan/state、审核报告、依赖、vendor、版本或无关 build.rs。

| 文件 | r0 SHA256 | r1 SHA256 |
| --- | --- | --- |
| `scripts/prepare_windows_https.ps1` | `7ffe81f712889fb1d0e5761cba7ad737323697a8e4efff44faa7b612d991bd6c` | `5604220f169481da948aaed7ee3c5213a2932302bb901ed9ae511889cf064827` |
| `tests/release/test_sdk.nim` | `830231b839ac60b24b37db3e45edddf9f28895f0a2a4bbff3a334fc50d9ea60d` | `b6b5cd89760a927aa5717f45c642ce56ae0f7b7d4669a4425d6038489f617916` |

## TDD 与当前结果

证据目录：`/tmp/leaf-ci-e1abf9e-r1/`。`run.py` 对每条命令保留原始合并 stdout/stderr、完整命令与实际退出码；`commands.jsonl` 记录时间、命令、退出码和日志。外层日志工具正常结束不等于被测命令通过，以下采用日志内真实退出码。

| 检查/日志 | exit | 实际证据 |
| --- | --- | --- |
| `baseline-ca-red.log` | 1（预期 RED） | r0 原生产入口的临时 Linux harness，有效 CA 成功；垃圾 CA 错误接受且写环境，拒绝断言失败。 |
| `ca-helper-red.log` | 1（预期 RED） | 写好仓库回归后，仅抽出原转换/发布逻辑、不增加新校验；14 OK / 1 FAILED / 0 skipped，明确 `garbage incorrectly accepted`，证明测试捕获真实行为。 |
| `ca-helper-green.log` | 0 | 加入解码和 X509 解析后，同一 SDK 测试 15 OK / 0 FAILED / 0 skipped。 |
| `release-suite.log` | 0 | 完整 release-only runner：3 文件、35 OK、0 FAILED、0 skipped，pwsh 与真实 OpenSSL 测试实际执行。 |
| `real-ca-cases.log` | 0 | 单独运行仓库嵌入的同一 CA 脚本保留成功场景 stdout：有效 X509 接受，垃圾/注释/畸形 PEM 拒绝，PATH/ENV 保持不变。畸形 PEM 的真实 OpenSSL 解析错误是预期拒绝证据。 |
| `layout-cases.log` | 0 | 实际生产 locator 回归，含两完整布局优先 ucrt64、不完整 ucrt64 回退完整 mingw64。DLL/CA 是布局 fixture，不冒充原生校验。 |
| `current-native-regression.log` | 0（harness 总断言） | 当前完整入口：有效 CA 子进程 exit 0；垃圾 CA、坏 PEM、坏 SSL 库、缺导出、OpenSSL 2 子进程均 exit 1 且无 PATH/ENV 写入。结果 `current-native-harness/results.json`。 |
| `windows-cgen.log` | 0 | 当前 Nim Windows 宏分支只生成 C，含 junction 测试；未 Windows 链接或运行。保留已有分支未使用 import warnings，未宣称 warning-free。 |
| `diff-check.log` | 0 | 当前 diff 空白检查通过。 |
| `final-integrity.log` | 0 | 仅授权两业务文件相对 r0 改变；r0 报告、review、workflow、smoke 哈希不变，HEAD 未变、index 空。 |

RED 入口 harness 和 GREEN 入口 harness 仅在 `/tmp` 副本去掉 Windows 平台门禁，使用本机真实 Linux `libssl.so.3` / `libcrypto.so.3` / OpenSSL，通过 fixture 文件名指向它们。没有修改 checkout 平台门禁或库检查。**该证据仅证明 Linux OpenSSL 和入口失败行为，不是 Windows DLL 原生验证。** 仓库新增 CA 回归直接调用生产 helper，不用源码重写 harness；单独 CA/布局日志脚本由同一仓库嵌入测试原文提取。

本机已有 pwsh `/tmp/leaf-sdk-pwsh/pwsh`、Nim `/tmp/nim-2.2.6/bin/nim`、真实 OpenSSL `/usr/sbin/openssl`（3.6.4）。只设命令局部 XDG 目录和工具 PATH，没有更改 HOME、全局配置或安装依赖。测试生成的临时私钥只用于合成 CA fixture，不读取真实凭据。

## 完整验证命令

`baseline-ca-red`，exit `1`，原始日志 `/tmp/leaf-ci-e1abf9e-r1/baseline-ca-red.log`：

```sh
python3 /tmp/leaf-ci-e1abf9e-r1/baseline_ca_regression.py
```

`ca-helper-red`，exit `1`，原始日志 `/tmp/leaf-ci-e1abf9e-r1/ca-helper-red.log`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r1/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r1/test_sdk tests/release/test_sdk.nim
```

`ca-helper-green`，exit `0`，原始日志 `/tmp/leaf-ci-e1abf9e-r1/ca-helper-green.log`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH /tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r1/sdk-nimcache --out:/tmp/leaf-ci-e1abf9e-r1/test_sdk tests/release/test_sdk.nim
```

`real-ca-cases`，exit `0`，原始日志 `/tmp/leaf-ci-e1abf9e-r1/real-ca-cases.log`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data /tmp/leaf-sdk-pwsh/pwsh -NoProfile -File /tmp/leaf-ci-e1abf9e-r1/ca_tests.ps1 -Helper /home/jimxl/projects/leaf/scripts/prepare_windows_https.ps1 -FixtureRoot /tmp/leaf-ci-e1abf9e-r1/ca-fixtures -OpenSsl /usr/sbin/openssl
```

`windows-cgen`，exit `0`，原始日志 `/tmp/leaf-ci-e1abf9e-r1/windows-cgen.log`：

```sh
/tmp/nim-2.2.6/bin/nim c --os:windows --cpu:amd64 --compileOnly --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r1/windows-c --out:/tmp/leaf-ci-e1abf9e-r1/test_sdk.exe tests/release/test_sdk.nim
```

`current-native-regression`，exit `0`，原始日志 `/tmp/leaf-ci-e1abf9e-r1/current-native-regression.log`：

```sh
python3 /tmp/leaf-ci-e1abf9e-r1/current_native_regression.py
```

`release-suite`，exit `0`，原始日志 `/tmp/leaf-ci-e1abf9e-r1/release-suite.log`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH NIM=/tmp/nim-2.2.6/bin/nim CARGO_HOME=/tmp/mui-cargo /tmp/nim-2.2.6/bin/nim c -r --nimcache:/tmp/leaf-ci-e1abf9e-r1/runner-nimcache --out:/tmp/leaf-ci-e1abf9e-r1/test_runner scripts/test.nim --release-only
```

`layout-cases`，exit `0`，原始日志 `/tmp/leaf-ci-e1abf9e-r1/layout-cases.log`：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-pwsh/cache XDG_CONFIG_HOME=/tmp/leaf-ci-pwsh/config XDG_DATA_HOME=/tmp/leaf-ci-pwsh/data /tmp/leaf-sdk-pwsh/pwsh -NoProfile -File /tmp/leaf-ci-e1abf9e-r1/layout_tests.ps1 -Helper /home/jimxl/projects/leaf/scripts/prepare_windows_https.ps1 -FixtureRoot /tmp/leaf-ci-e1abf9e-r1/layout-fixtures
```

`diff-check`，exit `0`，原始日志 `/tmp/leaf-ci-e1abf9e-r1/diff-check.log`：

```sh
git diff --check
```

`final-integrity`，exit `0`，原始日志 `/tmp/leaf-ci-e1abf9e-r1/final-integrity.log`：

```sh
python3 -c 'import json,hashlib,pathlib,subprocess; p=pathlib.Path("/tmp/leaf-ci-e1abf9e-r1"); before=json.loads((p/"files-before.json").read_text()); after={f:hashlib.sha256(pathlib.Path(f).read_bytes()).hexdigest() for f in before}; assert set(f for f in before if before[f]!=after[f]) == {"scripts/prepare_windows_https.ps1", "tests/release/test_sdk.nim"}; head=subprocess.check_output(["git","rev-parse","HEAD"],text=True).strip(); assert head=="1b12ea806ed88df7cfd98ed6c9b73d2cba052044", head; assert not subprocess.check_output(["git","diff","--cached","--name-only"],text=True).strip(); print("Only two authorized source files changed since r0; r0 report/review/workflow/smoke hashes unchanged; HEAD unchanged; index empty.")'
```

执行记录落盘后补充 `report-diff-check`：`git diff --check` exit 0；原始日志 `/tmp/leaf-ci-e1abf9e-r1/report-diff-check.log`，命令与退出码也已追加到 `commands.jsonl`。此检查只针对 Git diff，不宣称未跟踪 Markdown 获得测试或格式审核。

## 必需后续验证与交接

- Windows Git for Windows 的实际 DLL 加载、导出、OpenSSL/CA 以及 junction/真实路径行为：`not_verified`，需 root 审核后真实 Windows CI 运行。Windows 宏分支 C 生成不作 native pass。
- macOS ARM 与 Intel 完整 SDK 重定位及 `/var` ↔ `/private/var` 真实安装验证：`not_verified`，需两架构原生 CI；本轮 Linux release suite 保留并通过真实 Unix symlink 边界回归。
- 原 DPI **P1**（EXE 资源/复杂路径）、**P2**（桌面初始化/宿主/headless）、**P3**（真实 144 DPI/1.5 + 原图）、**P4**（同窗口 DPI 变化/输入/IME 命中）的必需原生验收仍全部 `not_verified`。本轮未改旧 DPI 实现，未提供最终 Windows 清晰度证明。
- 原全局 Rust fmt 的 build.rs 基线失败仍是 r0 DPI 记录所述限制，本轮没有改该文件或宣称全局 fmt 通过。

executor 本轮到此结束，交回 root/coordinator 独立复审 I1/M1 与当前源码。本轮未发起 verifier、未作审核通过声明、未提交或推送。
