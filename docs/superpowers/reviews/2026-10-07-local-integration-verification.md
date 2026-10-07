# 本地整合与收尾验证

2026-10-07，按用户“尽快把本地的事情处理好”执行。仅本地合并、验证和提交；未推送、发布、删除分支或工作区。

## 整合与遗留修改

- 原本地 main：`08d2c99f971e98363b99f2ee2dacc26cec527855`，含已合并的 Model；合入 origin/main：`2e837b79469ef3bed3c900672d7cc309e8baa3b3`。Git 自动合并无冲突。
- 保留 Model SDK 文件/许可检查，同时采用远端 r6 的中文路径私钥 stdin 校验，不恢复旧 r5 的 `pkey -in`。
- 原 main 的三份未跟踪 r5 记录与远端已提交记录逐字节一致，已随合并进入本地版本。
- 唯一额外代码变更：按 rustfmt 换行 `crates/leaf-gpui/build.rs` 的 println，不改变行为。
- `/tmp/leaf-ci-repair` 四个文件的遗留新增行均已存在于 main；旧 Python installer 检查已迁移到 `scripts/verify_sdk_install.nim`，包括 7zr 复制和损坏 extractor 拒绝。没有把过时 Python 文件重新引入项目。
- 所有遗留改动保留在 Git stash，不删除：原 main `4ba220b4b08249e687231104d2488fbb31313d93`；旧 repair `3870b9b080044b231505d6c73c3ec0a171b62fb6`。同时保留 `/tmp/leaf-local-finish-uTM3c0/` 的二进制 patch 和未跟踪文件归档。两份 stash 是历史备份，不是待集成的新功能。

## 本机验证环境

使用现成 Nim 2.2.6、Rust/Cargo 1.98.1、pwsh，以及现成 `/tmp/mui-display/usr/lib` 中的 xkbcommon-x11。最小 C 链接探针确认该库可用；仅给测试进程设置环境变量，未安装依赖或修改系统配置。

```sh
export PATH=/tmp/nim-2.2.6/bin:/tmp/leaf-sdk-pwsh:/tmp/mui-display/usr/bin:$PATH
export NIM=/tmp/nim-2.2.6/bin/nim CARGO_HOME=/tmp/mui-cargo
export LIBRARY_PATH=/tmp/mui-display/usr/lib${LIBRARY_PATH:+:$LIBRARY_PATH}
export LD_LIBRARY_PATH=/tmp/mui-display/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
audit=/tmp/leaf-local-finish-uTM3c0
cargo fmt --all --check
cargo test --workspace --locked --offline
cargo clippy --workspace --all-targets --locked --offline -- -D warnings
nim c -r --nimcache:$audit/runner-cache --out:$audit/test_runner scripts/test.nim
nim c -d:release --out:target/nim/leaf src/leaf_cli.nim
target/nim/leaf --headless --click add --click add examples/counter.nim
target/nim/leaf --check example/main.nim
export LEAF_TEST_XVFB=/tmp/mui-display/usr/bin/Xvfb-mui
export VK_ICD_FILENAMES=/home/jimxl/.cache/ms-playwright/chromium-1208/chrome-linux64/vk_swiftshader_icd.json
export LIBGL_ALWAYS_SOFTWARE=1
nim c --nimcache:$audit/native-cache --out:$audit/native_test scripts/native_test.nim
$audit/native_test
```

默认 Xvfb 首次尝试失败：其硬编码 `/usr/bin/xkbcomp` 不存在，虚拟键盘初始化失败；完整日志 `native-tests.log` 保留。改为机器已有的 Xvfb-mui（使用现成 `/tmp/bin/xkbcomp`）后，相同源码真实桌面回归通过；不是修改或跳过失败测试。软件渲染的 EGL/键盘映射警告保留。

## 实际结果

以下日志均位于 `/tmp/leaf-local-finish-uTM3c0/`；每项命令 exit 0：

| 检查 | 结果 | 日志 |
| --- | --- | --- |
| Nim 全量 | 46 套件，320 OK，0 FAILED / 0 SKIPPED | `nim-tests.log`、`nim-exit.txt` |
| Rust | 17 passed，0 failed / ignored | `rust-tests.log`、`rust-exit.txt` |
| 格式、Clippy | 通过，Clippy 使用 `-D warnings` | `fmt.log`、`clippy.log` |
| CLI、counter、gallery | Release CLI 编译；两次点击计数为 2；gallery check 通过 | `cli-build.log`、`counter.log`、`example-check.log` |
| Linux 原生桌面 | 真实窗口、点击、输入、Enter、ready、失败 viewport、关闭通过 | `native-retry.log`、`native-retry-exit.txt` |

本记录仅证明当前整合源码的 Linux 本地验证。Model 三平台 CI 尚需推送后运行，Windows DPI 原生视觉验收仍未验证；既有远端 SDK CI 的成功不冒充当前 Model 整合的跨平台结果。
