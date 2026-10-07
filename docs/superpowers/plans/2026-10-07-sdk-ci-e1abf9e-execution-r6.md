# SDK CI r6：私钥通过 stdin 校验

2026-10-07；仅当前隔离工作区，base/current HEAD 均为 `c82ac41bd4611c4700a86beb77975d2b95d2109b`。只修改 `tests/release/test_sdk.nim` 并新增本记录；沿用当前 runtime，没有 agents、commit/push、主 checkout 操作或 model `08d2c99` 工作。helper、collector、workflow、依赖和旧记录（含 r5）均未修改。使用 systematic-debugging、test-driven-development、receiving-code-review、verification-before-completion；已读取技能及 writing-good-tests，用户限定范围优先。

已有 native RED：run `37584909726` / job `112673311503`，[/tmp/leaf-ci-windows-c82ac41.log](/tmp/leaf-ci-windows-c82ac41.log)，摘录 [native-red.log](/tmp/leaf-ci-e1abf9e-r6/native-red.log)。req 中文目录 keyout 经 PowerShell 重定向已成功；后续 `pkey -in` 返回 1，`file_store.c:265` 报中文路径 stat NoSuchFile。本地没有伪造 Linux Unicode RED。

机制核对：[OpenSSL 3.5.7 file_store.c](https://github.com/openssl/openssl/blob/openssl-3.5.7/providers/implementations/storemgmt/file_store.c#L33) 将 Windows stat 映射为 `_stat`，245 行先 stat，262 行才开 BIO。[pkey 官方文档](https://docs.openssl.org/3.5/man1/openssl-pkey/) 明确省略 `-in` 读 stdin；[apps.c 910–928](https://github.com/openssl/openssl/blob/openssl-3.5.7/apps/lib/apps.c#L910) 的 stdin 分支走 BIO/OSSL_STORE_attach，绕过文件名 stat。

修补：req 后立即保存退出码、finally 恢复 UTF8，先报告生成错误。PowerShell `[IO.File]::ReadAllText` 实际读取原中文目录 key，再 pipe 到真实 `openssl pkey -noout`，不传 `-in`。stdout/stderr 分别重定向，立即保存 pkey 退出码。原私钥与破坏其 base64 内容的私钥通过同一条 stdin 调用；在 UTF8 未设置/已有值两种状态下分别要求成功/失败、stdout 为空、finally 恢复值及存在性、stderr 不含私钥 PEM。原 key 内容不变，错误日志不打印输入私钥。

生产 CA 三段仅核查：[crl2pkcs7.c 208/215](https://github.com/openssl/openssl/blob/openssl-3.5.7/apps/crl2pkcs7.c#L208) 使用 BIO_new_file/PEM_X509_INFO_read_bio，直接读原中文 CA，不走 provider stat；读取 root 经官方 contents API 缓存的 [/tmp/leaf-openssl-crl2pkcs7.c](/tmp/leaf-openssl-crl2pkcs7.c)。[pkcs7.c 130/144](https://github.com/openssl/openssl/blob/openssl-3.5.7/apps/pkcs7.c#L130) 使用 bio_open_default/PEM_read_bio_PKCS7，本轮经官方 contents API 读取并缓存 [openssl-pkcs7.c](/tmp/leaf-ci-e1abf9e-r6/openssl-pkcs7.c)。[x509.c 814](https://github.com/openssl/openssl/blob/openssl-3.5.7/apps/x509.c#L814) 经 load_cert_pass → OSSL_STORE_open_ex，仍可到 provider stat；当前 native runner 的 decoded 临时文件及 parent 为 ASCII，不扩大 helper。原中文证书 argv/内容、严格三段校验、垃圾/注释/畸形 PEM 拒绝、PATH/ENV 保护和 junction 清理均保留。

| 验证证据 | 实际结果 |
| --- | --- |
| [release-suite.log](/tmp/leaf-ci-e1abf9e-r6/release-suite.log) | exit 0；完整 release-only 3 文件，41 OK / 0 FAILED / 0 skipped。 |
| [key-stdin-evidence.log](/tmp/leaf-ci-e1abf9e-r6/key-stdin-evidence.log) | exit 0；独立运行从当前 test_sdk 提取的原 CA fixture，原 key 两次 exit 0、损坏 key 两次 exit 1；同一 stdin 入口，stdout 空、UTF8 恢复、日志/stderr 无私钥 PEM。有效 CA 两状态通过，三类无效 CA 拒绝且 PATH/ENV 不变；畸形 PEM 的 OpenSSL 错误为预期证据。 |
| [windows-cgen.log](/tmp/leaf-ci-e1abf9e-r6/windows-cgen.log) | exit 0；Windows amd64 compileOnly C 生成，未链接/运行；已有 unused import/install 提示保留。 |
| [final-integrity.log](/tmp/leaf-ci-e1abf9e-r6/final-integrity.log)、[diff-check.log](/tmp/leaf-ci-e1abf9e-r6/diff-check.log) | exit 0；HEAD/index/改动范围稳定，其他 231 个 tracked 文件摘要未变，被测 test_sdk 摘要未变，空白检查通过。 |

实际命令：`nim c -r --nimcache:/tmp/leaf-ci-e1abf9e-r6/runner-cache --out:/tmp/leaf-ci-e1abf9e-r6/test_runner scripts/test.nim --release-only`；`nim c --os:windows --cpu:amd64 --compileOnly --path:src --nimcache:/tmp/leaf-ci-e1abf9e-r6/windows-c --out:/tmp/leaf-ci-e1abf9e-r6/test_sdk.exe tests/release/test_sdk.nim`。Nim `/tmp/nim-2.2.6/bin/nim`；PowerShell `/tmp/leaf-sdk-pwsh/pwsh`；本地 OpenSSL 3.6.4。PowerShell 初次版本探测因默认 cache 路径只读失败；实际验证用 /tmp 下 XDG 目录后成功，未安装依赖。完整 argv、环境、UTC、真实退出码及 fixture 命令见 [commands.jsonl](/tmp/leaf-ci-e1abf9e-r6/commands.jsonl)，计数见 [summary.json](/tmp/leaf-ci-e1abf9e-r6/summary.json)。仅本轮 fixture 临时目录已清理，未输出私钥内容。

被测 `test_sdk.nim` SHA256：`0379522e6bf8618bdcd4113640de71b96367b8528f556e94df8720e4d1f3430c` → `8338dd687b125a723174e193e084c7ce1976cd9ca99587ce3c95f1f804e6a6ae`；完整前后摘要见 [before.json](/tmp/leaf-ci-e1abf9e-r6/before.json)、[after.json](/tmp/leaf-ci-e1abf9e-r6/after.json)。

本地指定验证完成；交回 root 独立审核及 native CI。Windows 原生修补结果和 GUI DPI 仍 **not_verified**，不宣称 Windows/总体 CI/GUI DPI 通过。
