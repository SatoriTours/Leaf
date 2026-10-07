# SDK CI r5：中文路径私钥 fixture

2026-10-07，executor；开始 HEAD 为 `acfccbd0ab5f0fd92ba453e72f2d9b2bf452d5ea`，结束检查发现外部推进到 `08d2c99f971e98363b99f2ee2dacc26cec527855`，沿用授权会话 runtime。本执行者仅修改 `tests/release/test_sdk.nim` 并新增本记录；本执行者未修改 HTTPS 产品 helper、collector、workflow、依赖/DPI 或旧记录/review。没有 commit/push、agent/工作区创建、安装、发布或外部主机接入。

实际读取原生 run `37583027569` / job `112667100599` 的 [/tmp/leaf-ci-windows-acfccbd.log](/tmp/leaf-ci-windows-acfccbd.log)，中文 argv 原样保留，但 req keyout 报 No such file or directory。此为本轮原生 RED，摘录 [native-red.log](/tmp/leaf-ci-e1abf9e-r5/native-red.log)；本地没有 Windows runtime，未伪造 Linux RED。

自行核对同版本 [apps.c 的 bio_open_owner](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/apps/lib/apps.c)：2902–2940 的 private 文件输出走窄字符 open；filename 为 `-` 则走 bio_open_default，2974–2975 转 stdout。另核对 [PowerShell 重定向文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_redirection?view=powershell-7.4)：7.4 起原生 stdout 重定向保持字节；合并 stderr 会失去该行为。工具证据：源码/日志读取 chunk `0a80ac`（末尾 rg 查无 AGENTS 导致组合命令 exit 1，前面的源码和日志读取成功）；web `turn9view0/1`、`turn10view0/1`。沿用本会话已实际读取的 systematic-debugging/TDD/verification-before-completion/receiving-code-review，来源与读取证据见 [r4 记录](2026-10-07-sdk-ci-e1abf9e-execution-r4.md)。本轮根据已有失败测试和源码机制做最小 fixture 修复。

实际变更：req 保留真实中文/空格目录和中文 cert，改用 `-keyout - -out $cert 1> $key 2> $generationErrors`。PowerShell 打开原中文目录内 key 路径并存 stdout 字节，诊断只读取 stderr；紧接 req 保存 `$generationExit`。成功后在同一 UTF8 try/finally 内实际调用 `pkey -in $key -noout`，分别保存 stdout/stderr 与退出码，要求解析成功且 stdout 为空。没有读取/打印私钥 PEM 到 CI 错误日志，并对 fixture 输出检查没有私钥头。生成失败仍用保存的 req 退出码报告，不能被后续 pkey 覆盖。

原证书直接校验、三段 PKCS7/X509、垃圾/注释/畸形 PEM 严格拒绝、中文 cert argv/内容保持、UTF8 原值/未设置恢复、拒绝不写 PATH/ENV、junction 清理/路径保护全部保留。新增文件均处于既有测试临时 fixture 生命周期。

| 原始日志 | 真实 exit | 结果 |
| --- | --- | --- |
| [sdk-green.log](/tmp/leaf-ci-e1abf9e-r5/sdk-green.log) | 0 | 21 OK / 0 FAILED / 0 skipped；真实 req stdout 写 key + pkey 中文路径读取和原保护实际执行。 |
| [release-suite.log](/tmp/leaf-ci-e1abf9e-r5/release-suite.log) | 0 | 测试当时快照的完整 release-only，3 文件，41 OK / 0 FAILED / 0 skipped；不是结束时并发变化后的源码验证。 |
| [windows-cgen.log](/tmp/leaf-ci-e1abf9e-r5/windows-cgen.log) | 0 | Windows amd64 宏分支 C 生成；未链接/执行。原 unused import/install 提示保留。 |
| [diff-check.log](/tmp/leaf-ci-e1abf9e-r5/diff-check.log) | 0 | 空白检查通过。 |
| [integrity.log](/tmp/leaf-ci-e1abf9e-r5/integrity.log) | 0 | 较早的阶段检查通过：HEAD 未变/index 空，仅授权 test 源码变化；当时 helper、collector、workflow 和旧 SDK 记录/review 摘要不变。 |
| [final-integrity.log](/tmp/leaf-ci-e1abf9e-r5/final-integrity.log) | 1 | 收尾发现外部 HEAD 改变，立即停止业务写入；随后只读检查确认当前 test/collector/workflow 摘要不同于已测试快照。 |

完整实际命令、UTC、退出码和原始日志路径见 [commands.jsonl](/tmp/leaf-ci-e1abf9e-r5/commands.jsonl)，计数见 [summary.json](/tmp/leaf-ci-e1abf9e-r5/summary.json)。取日志内被测命令退出码，未把 run.py 外层正常结束当作测试 pass。只运行必要 SDK/release 与 Windows Cgen，没有复跑无关 Rust/DPI。

源码 SHA256：`tests/release/test_sdk.nim` 从 `ff8770011ef6c9d51125f3c0552503dfedff7345a326345f38dae04ffa0c2144` 本执行者修改并测试时变为 `0379522e6bf8618bdcd4113640de71b96367b8528f556e94df8720e4d1f3430c`；不能用此摘要代表结束时并发变化后的文件。完整前后快照见 [before.json](/tmp/leaf-ci-e1abf9e-r5/before.json)、[after.json](/tmp/leaf-ci-e1abf9e-r5/after.json)。

截至先前快照，Linux 修改与验证已完成；收尾并发变化使最新源码验证失效，当前不宣称 Linux 实施完成。Windows 原生私钥生成/中文 key 读取结果仍 **not_verified**，由 root 独立审核并重跑 native CI。原 DPI P1–P4 继续 **not_verified**，没有最终 Windows 清晰度证明。本轮不宣称总体 CI/整体验收 pass，结束执行并交回 root。


收尾并发事件：本执行者没有执行 git commit/push/merge。`final-integrity` 发现 HEAD 为 `08d2c99f971e98363b99f2ee2dacc26cec527855`；只读 git log 显示标题 `Merge branch feat/rails-model-layer`。没有读取该 model plan 或实施修复。随后摘要检查（chunk `156fcf` exit 0，[concurrent-head.json](/tmp/leaf-ci-e1abf9e-r5/concurrent-head.json)）发现 `tests/release/test_sdk.nim`、`scripts/smoke_sdk.nim`、`.github/workflows/release.yml` 与此前已测试 after.json 不同；旧 SDK 记录/review 和产品 HTTPS helper 当次摘要仍相同。目录仍有外部操作迹象，因此只报告观察时事实，不把当前工作区变化全部归于本执行者。

已按并发源码变化停止后续业务写入/测试，未覆盖、回滚或清理其他写者修改。请 root 先协调并发状态，再决定独立审核及最新源码回归。r5 当时通过的日志和摘要保留，不把它们用于声明目前源码通过。
