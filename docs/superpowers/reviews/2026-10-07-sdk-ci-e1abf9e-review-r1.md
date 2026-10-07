# SDK CI 修复独立复审 r1

日期：2026-10-07。原基准：`e1abf9e10d93ae32244315dbac792561814a77dc`。审核开始、验证后共享 HEAD：`1b12ea806ed88df7cfd98ed6c9b73d2cba052044`。

**Verdict: pass。当前四源码修复可由 root/coordinator commit/push，进入真实 Windows/macOS native CI 验证。** 前次 I1、M1 均关闭，本轮未发现新的 Critical/Important/Minor 实际问题。本结论是代码提交验证的审核门槛，不代表远端 CI 已通过，也不代表 SDK/DPI 原生最终验收完成。

## 范围与独立性

复审 `.github/workflows/release.yml`、新增 `scripts/prepare_windows_https.ps1`、`scripts/smoke_sdk.nim`、`tests/release/test_sdk.nim`。读取 r0/r1 执行记录、r0 审核记录与旧证据，独立执行当前源码测试和补充入口验证；executor 的 35 OK 声明不是本报告的通过依据。

已实际读取并采用以下指引：`/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/requesting-code-review/SKILL.md`、同目录 `code-reviewer.md`，以及 `verification-before-completion/SKILL.md`。按用户限制及 reviewer 模板，本审核自行执行，不创建其他 agent。

共享 HEAD 相比原基准的已提交变化仅为排除的 `docs/superpowers/plans/2026-10-07-model-plan.md`，只核对文件名，没有读取其内容。`src` 相比原基准无 diff，旧 DPI 源码未改。只写本报告和 `/tmp/leaf-ci-review-e1abf9e-r1`；未修改业务、索引、HEAD 或分支，未 commit、push、发布、安装工具。r0 报告与两份执行记录 SHA256 审核前后不变。

## Strengths 与前次问题复核

- **I1 关闭：** `scripts/prepare_windows_https.ps1:56` 保留 `crl2pkcs7` 的完整证书转换与失败检查，在 `:67` 实际解码 PKCS#7，在 `:71` 实际执行 `x509 -noout`，要求至少一张可解析的 X.509 证书。`:83` 必须完成 CA 校验才调用环境写入；生产入口 `:106` 调用同一 `Publish-LeafGitHttpsEnvironment`，没有仅在测试分支补检查。
- `tests/release/test_sdk.nim:307` 使用真实 OpenSSL 生成证书并调用生产发布 helper，覆盖有效 CA、非空垃圾、纯注释、畸形 PEM；`:351` 对不存在/既存 runner 文件分别断言不创建/原内容不变，同时核对进程 PATH。独立 release 执行中该测试实际运行，未 skip。
- 独立完整入口 Linux harness 验证 13 种输入、每种不存在/既存 runner 文件两种状态，共 **26 个通过断言**。除有效系统 bundle 和重复多证书 bundle 成功外，垃圾、纯注释、畸形 PEM、有效 bundle 后接畸形 PEM、空/缺 CA、坏库、缺导出、OpenSSL 2、缺 executable、缺 crypto 全部拒绝，未创建或改变 PATH/ENV 文件；进程 PATH 在成功、失败后都恢复。混入坏 PEM 仍在完整转换阶段失败，新增“至少一张”条件没有吞掉这种错误。
- 本轮从 r0 已保留 harness 恢复原脚本字节并核对 SHA256 `7ffe81f7…991bd6c`，运行相同“垃圾 CA 必须拒绝”断言，真实得到 **exit 1**，且旧入口实际写了 runner 文件；当前入口同场景断言 exit 0。证据构成独立 RED/GREEN，而非仅阅读 executor 汇报。r0 文件未改。
- **M1 关闭：** `tests/release/test_sdk.nim:271` 新增“两边完整优先 ucrt64”；`:276` 删除 ucrt64 crypto 后验证回退完整 mingw64。本轮实际运行该仓库测试，两个断言通过，不再只有审核者临时补充测试。
- **r0 布局修复保留：** 脚本前两项函数与 r0 逐字节一致。`:20` 只枚举推导的 Git root 下 ucrt64/mingw64，ssl/crypto/executable 同 bin、CA 同 prefix，支持两种 CA 目录；缺失/空文件失败，不拼凑不完整布局。`:98`–`:104` 的库加载、导出及 OpenSSL 3 版本检查保留，之后才发布环境。完整 bin 进入 PATH，供同源运行时依赖查找；真正 Windows 依赖加载仍待 CI。
- **r0 真实路径修复保留：** `scripts/smoke_sdk.nim:44` 在 Unix 用真实 `realpath`，Windows 复用 handle-based `windows_paths.realPath`，两端解析后仍保留相对路径边界判断与 OSError 拒绝。独立 6 项边界测试验证双向别名、嵌套别名、内部文件链接可接受，目录/文件逃逸、缺失根、悬空链接、邻目录前缀及 `..` 逃逸被拒绝。Windows 分支另外 C 生成成功；没有把它当 Windows 执行。
- `.github/workflows/release.yml:84` 的 Windows 条件、pwsh、步骤顺序保留；`:109` 仍传入 `NIM_SSL_VERSION`，`:157` 仍实际执行原生安装/重定位验证，没有跳过 native 安装或关闭 TLS。

## Issues

### Critical

无已确认问题。

### Important

无已确认问题。r0 I1 已由当前生产路径修复，并经独立实际执行关闭。

### Minor

无新增实际问题。r0 M1 的仓库测试缺口已补齐并实际通过。

## 独立验证命令与证据

证据根目录：`/tmp/leaf-ci-review-e1abf9e-r1`。完整命令、时间、退出码见 `commands.jsonl`；子编译参数见 `child-commands.jsonl`；结果汇总见 `summary.json`。本机实际版本为 PowerShell 7.6.6、OpenSSL 3.6.4，使用已有 Nim 2.2.6，无安装。

| 检查 | 本轮实际结果 | 证据 |
| --- | --- | --- |
| 当前 checkout 完整 release-only runner | exit 0，3 个测试文件，35 OK / 0 FAILED / 0 SKIPPED | `release-suite.log` |
| 当前完整入口 Linux library harness | 13 场景 × 两种文件状态，26/26 预期行为断言 exit 0 | `entry-harness/results.json`、`entry-*.log` |
| r0 垃圾 CA 拒绝断言 | **exit 1，预期 RED**；旧代码接受垃圾并发布环境 | `r0-ca-red.log`、`entry-harness/r0-garbage/` |
| 当前独立真实路径边界 | exit 0，6/6 OK | `current-boundaries.log` |
| 当前 Windows Nim 分支 C 生成 | exit 0；含 junction/CA 测试；存在原有 unused-import warnings | `windows-cgen.log` |
| `git diff --check` | exit 0 | `diff-check.log` |
| 原有状态及文件完整性 | exit 0；四源码、r0 报告/执行记录不变，HEAD/index 不变，staged 为空 | `final-integrity.log`、`files-before.json`、`files-after.json` |

实际 release 命令：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-review-e1abf9e-r1/cache \
XDG_CONFIG_HOME=/tmp/leaf-ci-review-e1abf9e-r1/config \
XDG_DATA_HOME=/tmp/leaf-ci-review-e1abf9e-r1/data \
TMPDIR=/tmp/leaf-ci-review-e1abf9e-r1/tmp \
PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH \
NIM=/tmp/leaf-ci-review-e1abf9e-r1/nim-child-wrapper.py \
CARGO_HOME=/tmp/mui-cargo \
/tmp/nim-2.2.6/bin/nim c -r \
  --nimcache:/tmp/leaf-ci-review-e1abf9e-r1/nimcache \
  --out:/tmp/leaf-ci-review-e1abf9e-r1/test_runner scripts/test.nim --release-only
```

相对用户提供命令的必要调整：现有 runner 硬编码子测试输出到 checkout `target/nim/release`，配置还指定 checkout nimcache。为遵守“只写报告和本轮 /tmp”，`NIM` 指向临时透明 wrapper，只替换子进程 `--out`/`--nimcache`，最后 exec 原 `/tmp/nim-2.2.6/bin/nim`，不改变测试源码、筛选或执行逻辑。XDG/TMPDIR 同样指向本轮证据目录。runner 本身及三份测试都直接编译当前 checkout 原文件；原有 `target/nim/release` 文件内容及 mtime 前后完全不变。wrapper 与逐条子编译命令均留证。

其他验证入口：

```sh
python3 /tmp/leaf-ci-review-e1abf9e-r1/entry_harness.py
python3 /tmp/leaf-ci-review-e1abf9e-r1/additional.py
python3 /tmp/leaf-ci-review-e1abf9e-r1/integrity.py
```

`additional.py` 中边界/分支检查的实际命令：

```sh
/tmp/nim-2.2.6/bin/nim c -r --path:src \
  --nimcache:/tmp/leaf-ci-review-e1abf9e-r1/boundary-cache \
  --out:/tmp/leaf-ci-review-e1abf9e-r1/current_boundaries \
  /tmp/leaf-ci-review-e1abf9e-r1/current_boundaries.nim
/tmp/nim-2.2.6/bin/nim c --os:windows --cpu:amd64 --compileOnly --path:src \
  --nimcache:/tmp/leaf-ci-review-e1abf9e-r1/windows-c \
  --out:/tmp/leaf-ci-review-e1abf9e-r1/test_sdk.exe tests/release/test_sdk.nim
git diff --check
```

Linux 入口 harness 仅在 `/tmp` 副本移除 Windows 平台门禁，使用本机真实 `libssl.so.3` / `libcrypto.so.3` / OpenSSL，以 fixture 文件名引用它们；保留生产布局、加载、导出、版本、CA、发布及 finally 逻辑。它没有在 checkout 放宽门禁，**不能证明真实 Windows DLL/依赖行为**。OpenSSL 2 场景明确使用版本失败 fixture，不假称那是安装过的 OpenSSL 2。

重新读取原 run `37572624868` 三平台日志，确认原 Windows 缺 `mingw64/bin/libssl-3-x64.dll`，两个 macOS job 的 doctor 路径为 `/private/var` 且报 outside SDK。`/var` 词法根的来源按用户任务和 r0 执行记录标注，与当前 Unix realpath 实现及本轮双向 alias 实测一致；一次直接搜索原 ARM 日志中的 `/var` SDK 根行未找到，取证断言 exit 1（`original-root-log-probe.log`），不把这次证据定位失败当成代码回归或伪造原日志证明。还解析 r0 保存的官方 SDK 原响应：`ucrt64-bin.txt` 的两 DLL 与 executable、`ucrt64-cert.txt` 的 CA 项均存在；摘录及原响应 SHA256 见 `official-layout-extract.json`。这是已保存证据的复核，没有把官方 SDK 清单当成当前 Windows runner 的实际加载结果。

## 文件 SHA256

以下为本轮实际测试的四源码，审核前后一致，并与 executor r1 快照独立核对一致：

| 文件 | SHA256 |
| --- | --- |
| `.github/workflows/release.yml` | `e5866fbff06a63903417ad45bb18b22327a0c3025223986be2bbbd325d9ab5b4` |
| `scripts/prepare_windows_https.ps1` | `5604220f169481da948aaed7ee3c5213a2932302bb901ed9ae511889cf064827` |
| `scripts/smoke_sdk.nim` | `2f9a14f16e7b6bee1bd0d6c8289060b7058bd5af0208b40048b17a89dad77902` |
| `tests/release/test_sdk.nim` | `b6b5cd89760a927aa5717f45c642ce56ae0f7b7d4669a4425d6038489f617916` |

r0 审核报告 SHA256 为 `61805fd3ccfa01b7d346905077bbac281d569943aa62a577cfa490436988226d`，保持不变。执行记录哈希、index 哈希及既存测试产物内容/mtime 在前后快照内。

## Declined to judge

- **Windows 原生 DLL、同源传递依赖、exports/OpenSSL/CA 与实际 TLS：not_verified。** 本机 Linux，library harness 不验证 Windows loader。需真实 Windows CI 使用当前 Git 安装完成准备、许可证收集与后续 native 安装。
- **Windows junction、盘符/大小写/UNC 和真实 SDK 搬迁运行：not_verified。** 本轮已核对现有 handle helper、Nim Windows root/字符比较实现并生成 Windows C，不能替代 API 实际运行。
- **macOS ARM/Intel 完整安装与 `/var` ↔ `/private/var` 原生复测：not_verified。** Unix 双端真实路径行为已经 Linux 实测，但两个 macOS job 仍需远端 CI。
- **原 DPI P1–P4 必需原生验收：not_verified。** 本轮未改 DPI，不判定 PE/初始化、144 DPI/1.5 比例/原图、同窗口 DPI 变化及 IME/命中已通过。
- **无关 model 计划、全量 Rust/DPI 回归、恶意替换 Git 安装的供应链真实性证明：范围外。** 分别为明确排除文档、未修改模块，以及超出支持布局完整性检查的威胁模型。本轮没有据此推导全项目最终验收结论。

## 交接 root/coordinator

**Ready to commit/push for native CI: Yes。Critical 0 / Important 0 / Minor 0；I1/M1 关闭。** 建议提交上述四源码修复后运行真实四平台发布 CI，重点核对 Windows HTTPS 准备/许可证 HTTPS 与安装重定位、两 macOS 架构重定位。原生待测是本地审核结论的明确限制，本轮不因此把可验证的代码提交一律 blocked，也不宣称远端 pass。

审核者到此交回 root/coordinator；未执行 commit/push/发布。本报告新增，不覆盖 r0 记录。
