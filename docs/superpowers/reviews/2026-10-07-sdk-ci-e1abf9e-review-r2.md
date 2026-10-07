# SDK CI Git 发现修复独立复审 r2

日期：2026-10-07。基准与审核 HEAD：`c303806d7984fd12dbc4311d1ff5a48485e01d8b`。

**Verdict: pass。Ready to commit/push for native CI: Yes。Critical 0 / Important 0 / Minor 0。** 本轮未发现应阻止 root 提交当前两文件修复的实际问题。此结论只表示可进入原生 CI，不表示远端 Windows/macOS 或 DPI 验收通过。

## 范围与独立性

只审核未提交的 `scripts/prepare_windows_https.ps1`（7 行新增、1 行删除）和 `tests/release/test_sdk.nim`（新增 63 行）。读取 r1 报告、r2 执行记录及原始证据；独立运行当前 checkout 的 SDK 测试和额外真实 Application 发现检查。未创建 agent，未修改源码、index、HEAD，未 commit/push，未安装工具、访问凭据或运行无关 Rust/DPI 套件。只新增本报告，所有测试、脚本、缓存和证据写入 `/tmp/leaf-ci-review-e1abf9e-r2`。原报告及执行记录保留。

证据目录中的 `commands.jsonl` 保存本轮验证的实际 argv、环境、UTC 时间、退出码及日志路径。executor 的完整 release 36 OK 仅作原始证据核对，不替代本轮独立执行。

## 发现与错误语义

- 原始 `/tmp/leaf-ci-windows-c303806.log:484`–`:489` 确有旧脚本 `:9` 的 `Git HTTPS executable missing`，值依次包含 `C:\Program Files\Git\bin\git.exe`、`cmd\git.exe`、`mingw64\bin\git.exe`。日志 `:60` 为 Git `2.55.0.windows.5`，`:98` 为本次基准 SHA。run `37576721291` / job `112647205752` 的对应关系采用用户提供的日志归属；不声称文件内直接包含这两个编号。失败发生在库加载和 CA 验证之前。
- 本轮从 HEAD 原样保存旧 helper，真实创建带中文、空格及方括号的三个可执行 `git.exe` 文件。实际 builtin `Get-Command` 返回三个 Application；旧 `.Source` 绑定到 `[string]` 拼成不存在的路径，调用原 locator 真实以 **exit 1** 拒绝，重现同类错误。未 mock builtin、构造 Application 对象或只检查模拟字符串。
- `scripts/prepare_windows_https.ps1:6`–`:9` 的 resolver 在 `.Source` 之前取首个 Application，返回单个路径字符串；`:95` 的生产入口实际调用同一 resolver。当前真实 1/2/3 入口均选择 PATH 首项，重排 PATH 后改选新首项，中文/空格/方括号按字面保持。单入口结果与旧逻辑完全相同。
- `:8` 优先原样返回非空显式参数。本轮在有有效默认入口时验证显式首路径覆盖重排后的默认次路径；空 PATH 下显式路径仍成功。不存在的显式路径也原样返回，再由 `:14`–`:15` 拒绝，诊断保持 `Git HTTPS executable missing: <path>`，不会悄悄退回默认 Git。
- 空参数仍走默认发现。PATH 为空且不提供有效显式路径时，旧逻辑、新逻辑、显式空字符串均终止于 `CommandNotFoundException`，实际 `FullyQualifiedErrorId` 均为 `CommandNotFoundException,Microsoft.PowerShell.Commands.GetCommandCommand`，没有静默空结果或继续发布环境。
- `tests/release/test_sdk.nim:404` dot-source 当前生产 helper，`:413` 调用真实 `Get-Command`，`:417` 调用同一生产 resolver；`:442`–`:443` 将 checkout 的实际脚本传入 PowerShell。仓库回归覆盖三个入口、PATH 顺序/重排、单入口、显式空 PATH 覆盖以及所选路径进入旧 locator。布局 DLL/CA 内容只用来验证 locator，不作为真实 TLS 或库加载证据。Windows fixture 是供发现的 `.exe` 文件，不执行 shell 内容；本轮 Linux 实测不冒充 Windows 原生运行。

## r1 边界逐字节核对

`byte_check.py` 从 HEAD 读取旧脚本，只从当前字节移除新增 resolver，并将唯一生产入口调用替换回旧默认表达式，结果与 HEAD **逐字节相同**。因此 ucrt64/mingw64 布局、完整库对/同源 bin、加载/导出、OpenSSL 3、PKCS#7/X509 CA 校验、发布顺序及 PATH finally 恢复均无其他变动。现有 SDK 测试是新增部分之前的精确字节前缀，原测试未改。

workflow、smoke 路径保护与 HEAD 逐字节相同，`src` diff 为空。executor `files-after.json` 所有 SHA256 也独立匹配。r1 已通过的库/CA/路径边界没有被本修正改写，本轮不重复完整旧入口 harness 或不变发布套件。

## 独立执行结果

| 检查 | 实际退出码与结果 | 本轮证据 |
| --- | --- | --- |
| 当前 SDK 测试编译并运行 | 0；**16 OK / 0 failed / 0 skipped**，含新发现与原布局、真实 OpenSSL CA、真实路径检查 | `sdk-test.log` |
| HEAD 旧发现真实三入口复现 | **1，预期 RED**；路径拼接后 locator 拒绝 | `baseline-red.log`、`baseline-helper.ps1` |
| 真实发现/显式覆盖/错误补充检查 | 0；1/2/3 Application、重排、字面路径、显式优先、缺显式路径、缺命令全部符合预期 | `discovery-probe.log`、`discovery-probe.ps1` |
| r1 边界及 executor 哈希核对 | 0；生产剩余字节和原测试不变；workflow/smoke 不变 | `byte-check.log` |
| Git 空白检查 | 0 | `diff-check.log` |
| 原始输入证据及日志计数 | 0；输入 SHA 不变；executor 原始 release 日志确为 36 OK / 0 failed / 0 skipped | `verify-inputs.log`、`input-evidence-sha256.json` |
| 最终完整性 | 0；源码/index/HEAD/旧文档不变，只新增指定报告 | `final-integrity.log`、`files-before.json`、`files-after.json` |

实际 SDK 命令（exit 0）：

```sh
XDG_CACHE_HOME=/tmp/leaf-ci-review-e1abf9e-r2/cache \
XDG_CONFIG_HOME=/tmp/leaf-ci-review-e1abf9e-r2/config \
XDG_DATA_HOME=/tmp/leaf-ci-review-e1abf9e-r2/data \
TMPDIR=/tmp/leaf-ci-review-e1abf9e-r2/tmp \
PATH=/tmp/leaf-sdk-pwsh:/tmp/nim-2.2.6/bin:$PATH \
/tmp/nim-2.2.6/bin/nim c -r --path:src \
  --nimcache:/tmp/leaf-ci-review-e1abf9e-r2/nimcache \
  --out:/tmp/leaf-ci-review-e1abf9e-r2/test_sdk tests/release/test_sdk.nim
```

相对用户建议命令，仅将 XDG/TMPDIR 写入位置收拢到本轮授权证据目录；未改编译或测试逻辑。命令由 `run.py` 记录执行，另设置 `PYTHONDONTWRITEBYTECODE=1`。实际已有工具：Nim 2.2.6、PowerShell 7.6.6、OpenSSL 3.6.4；版本命令各 exit 0，原始输出留证。

其他实际被测命令（共享上述局部环境，完整记录见 `commands.jsonl`）：

```sh
# exit 1（预期 RED）
/tmp/leaf-sdk-pwsh/pwsh -NoProfile -File /tmp/leaf-ci-review-e1abf9e-r2/baseline-red.ps1 \
  -Helper /tmp/leaf-ci-review-e1abf9e-r2/baseline-helper.ps1 \
  -GitRoot '/tmp/leaf-ci-review-e1abf9e-r2/Git 中文 spaces [literal]'
# exit 0
/tmp/leaf-sdk-pwsh/pwsh -NoProfile -File /tmp/leaf-ci-review-e1abf9e-r2/discovery-probe.ps1 \
  -Helper /home/jimxl/projects/leaf/scripts/prepare_windows_https.ps1 \
  -GitRoot '/tmp/leaf-ci-review-e1abf9e-r2/Git 中文 spaces [literal]'
python3 /tmp/leaf-ci-review-e1abf9e-r2/byte_check.py
python3 /tmp/leaf-ci-review-e1abf9e-r2/verify_inputs.py
git diff --check
python3 /tmp/leaf-ci-review-e1abf9e-r2/final_integrity.py
```

## 文件 SHA256

本轮源码/旧记录 SHA256 开始与结束一致，完整快照见证据目录。

| 文件 | SHA256 |
| --- | --- |
| `scripts/prepare_windows_https.ps1` | `76ef7e68ed08d03f73647d5d7e42173e43e1c6833ef3b3ccc01067be8cb1af4f` |
| `tests/release/test_sdk.nim` | `f4709be6ba265543c13586183af9d4b212302230bf8d1cd55abda3ecfd907cb2` |
| `.github/workflows/release.yml` | `e5866fbff06a63903417ad45bb18b22327a0c3025223986be2bbbd325d9ab5b4` |
| `scripts/smoke_sdk.nim` | `2f9a14f16e7b6bee1bd0d6c8289060b7058bd5af0208b40048b17a89dad77902` |
| r1 审核报告 | `eba02d74b228ea38a2380e9ce08a76b1e51f3750d308fdcb2a581445e132ad4e` |
| r2 执行记录 | `6b439d926765c3718c817387261a2acf31d034ee818a40644178c7058ecb8a39` |
| Git index | `43167c3e935444eccba389eb7b20134e73a8e8f9ffcabffbd2f5e732f7662aab` |

原始 Windows 日志和 executor 输入文件哈希另见 `input-evidence-sha256.json`。本报告自身哈希写入 `files-after.json`，避免自引用。

## 原生边界与 root 交接

Windows 真实默认入口、DLL/传递依赖、CA/TLS、junction/SDK 重定位，以及 macOS ARM/Intel 原生复测，仍由 root 提交后跟踪。旧 DPI 源码未改，native 图形 P1–P4 仍逐项 `not_verified`。本轮只用 Linux 真实 PowerShell 和 SDK 测试验证新增发现行为；executor 的 Windows C 生成/移除门禁 Linux harness 没有被当作 native pass。

**交回 root：pass，可 commit/push 两源码修正进行 native CI。** 本轮没有 Critical/Important/Minor 实际问题，没有执行提交或推送，也没有因原生待跑而将审核一律 blocked。
