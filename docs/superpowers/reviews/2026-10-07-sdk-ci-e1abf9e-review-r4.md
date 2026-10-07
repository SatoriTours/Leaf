# SDK CI UTF-8 修复独立审查 r4

2026-10-07；base、审查开始/结束 HEAD：`9b930a24c74b31f9e9f1028ebf43b59bbb8273a7`。

当前窄范围修复可由 root commit/push 进入 native CI。未发现阻止提交的问题；Windows 原生 Unicode 修复结果仍 **not_verified**。

**范围与独立性。** 审查两份未提交源码 `scripts/prepare_windows_https.ps1`、`tests/release/test_sdk.nim` 及 `execution-r4.md`，核对 HEAD/index、原生日志、官方源码和 executor 的 commands/summary。独立执行当前源码回归，executor 的通过声明未替代本轮验证。仅新增本报告与 `/tmp/leaf-ci-review-e1abf9e-r4` 证据，未创建 agents、commit/push 或修改旧记录、DPI/spec/plan/state。用户指定 GPT-6.1-Sol；当前可访问元数据未能独立确认会话型号，不宣称已核实或另建代理。

**Critical：** 无已确认问题。

**Important：** 无已确认问题。

**Minor：** 无应列为实际代码发现的问题；Windows Cgen 的既有 unused-import 提示保留。

**依据与行为。**

- 产品只在 `Assert-LeafGitHttpsCertificates` 的 try 内设置 `OPENSSL_WIN32_UTF8=1`，finally 显式移除原不存在变量或恢复原值。成功、真实无效 CA 拒绝均检查值及存在状态；独立探针另覆盖空值、中文原值，以及三阶段失败和启动异常。恢复先于临时文件清理，未向 GITHUB_ENV 增加全局开关。
- `crl2pkcs7` 的退出码/非空输出、`pkcs7 -print_certs` 的退出码/非空解码结果和 `x509 -noout` 的退出码校验全部保留。`Publish` 先验证，再写 runner PATH/ENV。真实垃圾、注释、畸形 PEM，在两种调用者状态和 absent/已有文件情形下共 12 次拒绝，PATH/ENV 不创建或 sentinel 不变。没有弱化原 PKCS7/X509 解析标准或增加 TLS 绕过。
- fixture 的真实 `req` 单独 try/finally 设置并恢复开关，随后直接调用真实产品验证，再由自子进程检查环境、记录 argv 并委托真实 OpenSSL。业务探针要求自身获得开关；使用 HEAD helper 的独立 RED 因子进程 exit **97** 失败，证明生成阶段开关未掩盖业务漏设置。当前 GREEN 检查三次成功调用、中文 argv、证书内容原样保持及真实解析拒绝；test-only delegate/trace 仅存在于 fixture 子进程。
- 原生 run `37581190120` / job `112661058213` 日志中旧 collector、junction、路径/诊断、layout/discovery 已 OK；剩余失败是 `req` 写 key 时中文目录变为 `??`，native job 实际 **exit 1**。日志第 484 行确认为 OpenSSL **3.5.7**。这支持 Windows argv 转码问题的推断，不证明 r4 在 Windows 已成功。
- 独立读取 [OpenSSL 环境文档](https://docs.openssl.org/3.6/man7/openssl-env/) 和同版本 [win32_init.c](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/apps/lib/win32_init.c)：非空变量开启 GetCommandLineW → WideCharToMultiByte(CP_UTF8)。[openssl.c](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/apps/openssl.c) 的 Windows main 调用此转换，[o_fopen.c](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/crypto/o_fopen.c) 将 UTF-8 文件名转为宽字符后 `_wfopen`。另核对 Nim 2.2.6 的 GetCommandLineW、CreateProcessW 和继承环境实现，自子进程边界没有主动丢弃 Unicode 参数。实际 runner 二进制结果仍需 native CI。

**独立验证及真实退出码。** 证据目录 `/tmp/leaf-ci-review-e1abf9e-r4`；`commands.jsonl` 保存完整 argv、局部环境、UTC、被测退出码及日志路径。外层 Python 成功不替代被测命令状态。

| 检查 | 实际 exit / 结果 | 证据 |
| --- | --- | --- |
| 当前全部 release 源码 | 三份均 **0**；10 + 10 + 21 = **41 OK / 0 FAILED / 0 skipped** | `test_notices.log`、`test_publish.log`、`test_sdk.log`、`release-summary.json` |
| HEAD helper / 当前 helper 真实边界对照 | **1** 预期 RED / **0** GREEN | `boundary-red.log`、`boundary-green.log`、两份 trace summary、`boundary.py` |
| 各阶段失败 finally 恢复 | **0**；12 情形通过 | `finally-probe.log`、`finally-probe.ps1`、`failure-child.py` |
| Windows amd64 Cgen | **0**；仅 C 生成，未链接/执行 | `windows-cgen.log` |
| Git 空白检查 | **0** | `diff-check.log` |
| 报告前/后完整性 | 各 **0** | `integrity-before-report.log`、`final-integrity.log`、`files-before.json`、`files-after.json` |
| 工具版本 | 各 **0**；Nim 2.2.6、pwsh 7.6.6、Linux OpenSSL 3.6.4 | 三份 `*-version.log` |

release 验证按 `scripts/test.nim --release-only` 相同顺序直接编译/执行全部三个 `tests/release/test_*.nim`，以真实 `/tmp/nim-2.2.6/bin/nim`、`--path:src`、证据目录内 `--out`/`--nimcache` 执行，未运行会写仓库 target 的 dispatcher。局部 `PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH`、`NIM=/tmp/nim-2.2.6/bin/nim`、`CARGO_HOME=/tmp/mui-cargo`；XDG/TMPDIR 全在证据目录，命令环境 HOME 未修改，原有测试自身的 installer HOME 隔离保持。完整执行入口为 `python3 /tmp/leaf-ci-review-e1abf9e-r4/run.py release`。

finally 探针在相应真实 OpenSSL 调用成功后注入 exit 53，并测试缺失 executable；这是异常恢复证据，真实无效 CA 拒绝由仓库测试与 boundary GREEN 证明。保留的 GREEN trace 为第二种调用者状态的 13 次实际调用，第一次成功序列为 crl2pkcs7/pkcs7/x509，其余为真实拒绝路径；两种状态的断言均执行。

executor 的记录与实际 summary/commands 相符：初始 RED=1、第一次所谓 green 实为恢复失败=1、修正后=0、release=0、Cgen=0；本报告未将中间失败标为成功。

**完整性。** 前后 233 个既有受检文件的 SHA256/mtime/mode 不变，包含源码、旧记录、受版本管理的 spec/plan/state 和已有 release 产物；新增只有本报告。HEAD 不变、index 内容及时间不变、staged diff 空。产品删除本次三段环境设置/恢复新增字节后与 HEAD 完全相同；SDK 测试删除新 child mode 并排除 CA test 后与 HEAD 完全相同；collector、workflow 与 HEAD 字节一致。因此旧 within/Git layout/DLL/路径/诊断检查未改。

| 审查对象 | 审查前后相同 SHA256 |
| --- | --- |
| HTTPS helper | `160c568f49b2b1b2362d30a72635c31e5afa795aa104b8b3d497375c498272dd` |
| SDK test | `ff8770011ef6c9d51125f3c0552503dfedff7345a326345f38dae04ffa0c2144` |
| execution-r4 | `bac50d34cb9f242e717d54e108afeda043e5d61915d12087c9626cba2fbfb9bc` |
| Git index | `da486945b2a80271f32245f682a029987f5f00ada966f5ece0211a37aeae4b4b` |

**declined_to_judge。** Windows r4 native Unicode argv、实际 runner 二进制结果仍 **not_verified**；Linux 真实边界通过和 Cgen 不替代原生验收。原 DPI P1 EXE 资源/复杂路径、P2 Windows 初始化及宿主/headless、P3 144 DPI/1.5 与原图、P4 同窗口 DPI 变化/输入 IME 命中均 **not_verified**。无关 Rust/DPI 全量、最终发布/整体 CI 验收和会话实际模型身份不在本轮可判定证据内。缺少 Windows 本机不阻止正确窄范围代码提交后交 native CI 验证。

**root 通知。** 按 [Paseo 技能](/home/jimxl/.agents/skills/paseo/SKILL.md) 查找既有 root：`paseo ls --global --json --home /home/jimxl/.paseo` 实际 **exit 1 / DAEMON_NOT_RUNNING**，未解析到 root ID，自动通知未送达。未启动 daemon 或创建 agents；可转交正文为 `/tmp/leaf-ci-review-e1abf9e-r4/root-notification.txt`。

```json
{"verdict":"pass"}
```
