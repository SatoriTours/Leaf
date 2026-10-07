# SDK CI r5 独立审查

2026-10-07。最终投送对象为 Paseo 工作区 `wks_b06bf0badf43e897`，路径 `/home/jimxl/.paseo/worktrees/1c1rvoii/windows-ca-fixture`，被测 base/HEAD `acfccbd0ab5f0fd92ba453e72f2d9b2bf452d5ea` 加现有 r5 fixture patch（19 添加、2 删除）。通过本轮窄范围审核，可由 root 提交该隔离分支进入 native CI。main 的 `08d2c99f971e98363b99f2ee2dacc26cec527855` 仅为本地集成验证对象，不是投送对象；本报告不授权发布 model，也不证明 model 已发布。

已读取两份 execution-r5 记录及两处实际 diff。原生 run `37583027569` / job `112667100599` 的旧日志确认中文 argv 正确而私钥 keyout 失败，见 [摘录](/tmp/leaf-ci-review-e1abf9e-r5/native-red-excerpt.log)。独立核对 [OpenSSL 3.5.7 apps.c](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/apps/lib/apps.c) 的 `bio_open_owner`：私有文件窄字符 open、`-` 转 stdout；[PowerShell 官方文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_redirection?view=powershell-7.4) 确认 7.4 起原生 stdout 重定向保持字节，合并 stderr 会改变该行为。此次修复与该机制吻合，Windows 实际结果仍待 native CI。

- **Critical：** 无。
- **Important：** 无。req 保留原中文 cert 和中文目录，`-keyout -` 只将私钥 stdout 重定向到原 key 路径；stderr 独立用于诊断。req/pkey 各自即时保存 exit，成功后真实 `pkey -in 原key -noout`，要求解析 exit 0 且 stdout 为空；不读取或打印 key PEM。生成失败先报告已保存 req exit，不会因缺少后续 keyCheck 文件掩盖错误。
- **Minor：** 无。中文 cert 内容/argv、直接证书校验、真实 crl2pkcs7/pkcs7/x509 三段、垃圾/注释/畸形拒绝、拒绝不创建或追加 PATH/ENV、UTF8 try/finally 恢复、既有 collector/junction 清理及路径保护均保留并参与回归。
- **declined_to_judge：** Windows 原生私钥写入及中文 key 读取、GUI/DPI P1–P4 均 **not_verified**；C 生成不能替代 Windows 执行。本轮未审查 model 实现、未打开 model plan、未跑无关 Rust/model/DPI 全量。

独立使用真实 Nim 2.2.6、pwsh 7.6.6、OpenSSL 3.6.4；PATH 仅对子进程局部增加，`NIM=/tmp/nim-2.2.6/bin/nim`、`CARGO_HOME=/tmp/mui-cargo`，XDG、TMPDIR、编译缓存和输出全部在指定 `/tmp` 证据目录。按 release runner 的完整文件集合逐份 `nim c -r`，避免 runner 向工作区 target 写产物。

| 被测对象 | 实际结果与 exit | 原始证据 |
| --- | --- | --- |
| main 合并快照四份 release | model_dependencies 3、notices 10、publish 10、SDK 21；共 44 OK / 0 FAILED / 0 skipped；四命令各 exit 0 | [命令及 UTC](/tmp/leaf-ci-review-e1abf9e-r5/commands.jsonl)、[汇总及日志路径](/tmp/leaf-ci-review-e1abf9e-r5/summary.json) |
| 隔离投送 base 三份 release | notices 10、publish 10、SDK 21；共 41 OK / 0 FAILED / 0 skipped；三命令各 exit 0 | [命令及 UTC](/tmp/leaf-ci-review-e1abf9e-r5/delivery/commands.jsonl)、[汇总及日志路径](/tmp/leaf-ci-review-e1abf9e-r5/delivery/summary.json) |
| 两处 Windows amd64 C 生成及 diff 空白检查 | 各 exit 0；未链接/运行；原 unused 提示保留 | 两处 commands.jsonl 对应日志 |
| 隔离 fixture 的错误诊断探针 | req 真实失败后包装 exit 23、损坏 key 真实解析后包装 exit 37、pkey 成功但异常 stdout；各在 UTF8 未设置/已有值下正确拒绝，六个 fixture 各 exit 1，诊断验证程序 exit 0 | [探针代码](/tmp/leaf-ci-review-e1abf9e-r5/diagnostic_checks.py)、[结果及日志路径](/tmp/leaf-ci-review-e1abf9e-r5/diagnostics/summary.json) |
| stdout 字节探针 | 独立 stderr 重定向下 768 个含 NUL/高位字节逐字节一致，原生命令 exit 0；六项失败诊断均恢复 UTF8、无私钥头 | 同上 |

main 新增 `test_model_dependencies` 三项确实执行来源摘要、许可证及拒绝篡改；44 项结果属于本地集成回归，41 项结果才对应隔离投送源码。executor 原 41 项快照在并发 merge 后失效的说明与后续 44 项记录一致，没有将旧快照冒充 current HEAD 验证。

[字节一致性证据](/tmp/leaf-ci-review-e1abf9e-r5/delivery-equivalence.json)：两处完整 CA 测试段 SHA256 均为 `ec6005d439607542904a78fb95bf71bf6c773d3b582c4737338e61496d9bb826`，patch 增删行和两份 execution 记录逐字节一致。SDK 文件全文 SHA256：main `036320026f8c42fc230caac10cb86e04b2dd42f35fc5e45cd9618a4436feedd4`；隔离 `0379522e6bf8618bdcd4113640de71b96367b8528f556e94df8720e4d1f3430c`。全文差异来自不同 base，不影响已比对的 CA 段。

[main 稳定性](/tmp/leaf-ci-review-e1abf9e-r5/integrity.json) 的 402 项及 [隔离稳定性](/tmp/leaf-ci-review-e1abf9e-r5/delivery/integrity.json) 的 169 项摘要、各自 HEAD/index SHA 和原 dirty diff 在审查前后稳定。仅作只读 Git 检查；reviewer 唯一仓库写入为本报告，未改任何源码/旧文件/HEAD/index，未创建 agent、未 commit/push。root 后续复制此单一报告到隔离分支并协调提交和投送；不推 main 的 model 合并 HEAD。

```json
{"verdict":"pass"}
```
