# SDK CI r6 独立审核

2026-10-07；GPT-6.1-Sol。仅审核当前未提交 `tests/release/test_sdk.nim` 的 31+/7− diff 和 `execution-r6.md`。base/HEAD：`c82ac41bd4611c4700a86beb77975d2b95d2109b`。没有创建代理、commit/push、修改主 checkout 或审核 model 08d。

- Critical：无。
- Important：无。
- Minor：无。
- declined_to_judge：r6 Windows 原生执行、总体 CI、GUI DPI 均 not_verified；Rust/model/DPI 全量不在范围内。这些不构成本次代码审核失败。

实际实现为 `[IO.File]::ReadAllText($keyCase.Path)`，以字面 Unicode 路径读取原私钥，完整字符串 pipe 至真实 `pkey -noout`，没有 `-in`。这符合 [pkey 官方 stdin 语义](https://docs.openssl.org/3.5/man1/openssl-pkey/)。独立核对 [file_store.c 的 Windows `_stat` 与先 stat 后 BIO 路径](https://github.com/openssl/openssl/blob/openssl-3.5.7/providers/implementations/storemgmt/file_store.c#L245) 和 [apps.c 的 stdin/OSSL_STORE_attach 分支](https://github.com/openssl/openssl/blob/openssl-3.5.7/apps/lib/apps.c#L910)，与既有 native RED 日志一致；本地 Linux 结果不代表 Windows 原生通过。

原/损坏私钥走同一入口；审计代理把捕获的 stdin 原样交给 `/usr/sbin/openssl`，只记录长度、摘要、退出码，核对完整文件内容（忽略管道末尾换行）。两种调用方状态（unset、已有值）均得到有效 key exit 0、损坏 key exit 1。四次 stdout 为 0 字节；stderr 和日志既无 PEM 标记，也无原私钥 base64 行。`LASTEXITCODE` 紧接 native 调用保存，内层 finally 恢复当前状态，外层 finally 覆盖断言失败；故障注入 exit 29 确实被拒绝，unset/已有值均恢复。源码保留原 key 内容不变断言，未删除或绕过验证。

中文证书原路径/内容断言、严格 crl2pkcs7→pkcs7→x509、三类垃圾拒绝、PATH/ENV 和旧 fixture/junction 保护均位于逐字节未变部分，三份完整 release 回归覆盖通过。`execution-r6.md` 对 Linux、Windows C 生成和 native 未验证的界限准确。

所有测试产物、局部 XDG/TMPDIR、编译缓存和可执行文件均在 `/tmp/leaf-ci-review-e1abf9e-r6`；未安装依赖或修改 `/home` 配置。真实 `NIM=/tmp/nim-2.2.6/bin/nim`；PATH 优先 `/tmp/leaf-sdk-pwsh`、`/tmp/nim-2.2.6/bin`；本地 OpenSSL 3.6.4。分别运行 `nim c -r --path:src --nimcache:<审核目录>/cache/<name> --out:<审核目录>/bin/<name> tests/release/<name>.nim`，避免总入口写工作区 target。

| 独立验证 | 实际结果 |
| --- | --- |
| [test_notices.log](/tmp/leaf-ci-review-e1abf9e-r6/test_notices.log) | exit 0；10 OK |
| [test_publish.log](/tmp/leaf-ci-review-e1abf9e-r6/test_publish.log) | exit 0；10 OK |
| [test_sdk.log](/tmp/leaf-ci-review-e1abf9e-r6/test_sdk.log) | exit 0；21 OK |
| [stdin-audit.log](/tmp/leaf-ci-review-e1abf9e-r6/stdin-audit.log)、[真实 stdin 元数据](/tmp/leaf-ci-review-e1abf9e-r6/stdin-audit.jsonl) | exit 0；真实 pkey exits `[0,1,0,1]` |
| [restore-failure.log](/tmp/leaf-ci-review-e1abf9e-r6/restore-failure.log) | harness exit 0；两状态注入退出 29 均拒绝且恢复 |
| [integrity.json](/tmp/leaf-ci-review-e1abf9e-r6/integrity.json) | exit 0；HEAD/index/diff/两份文件摘要稳定，git diff --check exit 0 |

合计 41 OK / 0 FAILED / 0 skipped。完整 argv/环境/实际 exits 见 [commands.jsonl](/tmp/leaf-ci-review-e1abf9e-r6/commands.jsonl)。审核临时 harness 准备时曾有 import 和漏注入 AssertEqual 导致的 exit 1；仅修正 `/tmp` harness 后验证完成，非被审源码失败。未重复 Windows C 生成。

SHA256（审核前后相同）：

- `test_sdk.nim` HEAD：`0379522e6bf8618bdcd4113640de71b96367b8528f556e94df8720e4d1f3430c`；current：`8338dd687b125a723174e193e084c7ce1976cd9ca99587ce3c95f1f804e6a6ae`。
- `execution-r6.md`：`96abaf1b75911569f5883d1a6b6d870fec04a1f072449fb22b64499d589a7c9a`。
- index 清单（`git ls-files --stage -z`）：`6e211aeaf1976af8403066ed9c7495cbdeb59a1994e1efdfad0a93e1f07c3157`。
- 被审 binary diff：`6a10b23ddd20960288279661c80ae88c9d5c06261bbccecf75f49937d3b17fba`。

本次范围可交 root 提交/push 并继续 native CI；审核者未执行上述操作。

```json
{"verdict":"pass"}
```
