# 组件异步生命周期：合并前复核与合并验收（2026-10-17）

范围：`53368cf..3ef1627`（29 提交、63 文件、+8901/−168），以及随后为修 Windows 别名问题追加的 `2271ea9`。
前置记录：[实施验证](2026-10-17-component-async-lifecycle-verification.md)（Task1–7 与最终修复波）、[裁定记录](2026-10-17-component-async-lifecycle-rulings.md)。本文件只记录本轮实际执行与取得的结果，不重述、不改写历史证据。

## 复核对象

上一轮整分支审查在 `0159895` 判定 C0/I6/M0，`1a79640` 为一组修复，`3ef1627` 仅补充验证文档。本轮按固定差异（`0159895..3ef1627`，16 文件、+839/−91）逐项复核，未做全分支二次重验。

| 项 | 落点 | 复核要点 |
| --- | --- | --- |
| I1 首次已接受构造丢 cleanup owner | `core.newRuntime` | 只有 `acceptedRevision > 0` 才尝试一次 ordinary close；未接受候选直接原样抛出，不 dispose、不进入保护域清理；清理失败由 `RuntimeCleanupError` 保存原 msg/parent 与可重试 owner |
| I2 headless 不关闭 Runtime | `headless.runHeadless` | 正常、check、help、解析失败四类出口都先 close Runtime 再关诊断对象；构造已清理时只移交 owner 不重复 close；不泵任务、不等后台结果 |
| I3 高层 `run` 吞 owner | `runner.run` | 新增 `cleanupOwner` 输出；带待清理 Runtime/Host 的异常继续上抛，诊断收尾不再覆盖 pending owner；out slot 必须预先为 nil |
| I4 ABI1 error 丢 pending | `bridge.rs` / `desktop.rs` | 应用错误不再被当作传输错误：保留 `tasks_pending`，可选同时保留 snapshot，首个错误保留；畸形 envelope 仍是传输错误 |
| I5 测试依赖私有旧库绝对路径 | `test_task_pump_compatibility` | 改为从 `tests/ffi/gpui_v2_library.c` 现场构建双 ABI 无能力 fixture；真实旧库改为 `LEAF_TASK5_OLD_LIBRARY[_SHA256]` 显式可选输入 |
| I6 native 关闭观测无界等待 | `gpui_native` / `test_native_close_probe` | 两个分支共用截止时间、建后立即 defer close、超时回收进程组与句柄；挂起工具由真实 RED→GREEN 覆盖 |

结论：I1–I6 均有对应实现与独立回归，本轮未发现新的 Critical/Important 缺口。M1（close 观测 fallback 的 deadline）由 I6 的共享截止时间覆盖，M2（继承的编译/显示告警）按既有噪声保留。

## 本机实际执行

新增与受影响套装均在本机真实运行，不只是阅读源码：

- Nim 全量 runner：102 套件，**972 OK / 0 FAILED / 6 SKIPPED**；含 `test_component_tasks`、`test_component_lifecycle`、`test_component_task_{delivery,faults,performance,retention,shutdown}`、`test_task_worker`、`test_task_pump_compatibility`、`test_public_task_launchers`、`test_native_close_probe`、`test_component_routing`、`test_component_lists`、`test_gpui_v2_session`。
- Rust：`cargo test --workspace` **55 通过**；`cargo fmt --all -- --check` 与 `cargo clippy --workspace --all-targets -- -D warnings` 均退出 0。
- ABI：`scripts/check_gpui_v2_abi.nim` → `ABI 2 C/Nim/Rust layout PASS: 161 entries`。
- 示例：`examples/component_tasks.nim` 以 `-d:leafHeadlessOnly` 编译通过。

环境说明（不写入产品结论）：本机缺 `libxkbcommon-x11` 与系统 `xkbcomp`，因此 Cargo 链接需要 `LIBRARY_PATH=/tmp/mui-display/usr/lib`，native 窗口需要私有 `/tmp/mui-display/usr/bin/Xvfb-mui :99`。`test_diagnostics` 的 Cargo 用例在缺库时失败属于既有环境限制，不是本次回归。6 个 SKIPPED 为：可选真实旧库 integration（未设 `LEAF_TASK5_OLD_LIBRARY`）、2 项 PowerShell、3 项环境型（Git 布局/真实 OpenSSL CA/Application 发现）。

## 合并、CI 与 Windows 别名修复

- `main` 以 fast-forward 从 `53368cf` 前进到 `3ef1627` 并推送。
- 首轮 CI：`Nim + GPUI 构建与测试`、`Model 三平台回归`、`数据库迁移三平台回归` 成功；`Leaf SDK 发布` 的 windows 作业失败，Linux 与两个 macOS 作业通过。
- 失败根因：新增 release fixture 在含中文与字面 `$` 的临时目录中调用随附 ANSI MinGW，`cc1.exe: Invalid argument`；同一测试的纯空格目录通过，因此问题在 Unicode 路径而非 `$` 转义，Nim 自身能正常读取该路径。
- 修复 `2271ea9`：编译器自身消费的输入（`--path`、`--nimcache`、`--out`、入口文件、工作目录）改走 `windows_paths.compilerPath` 的 8.3 别名，与 `scripts/smoke_sdk.nim` 及产品构建一致；生成配置内的 include 仍保留真实 Unicode 转义路径，双重转义继续受测；文件系统不提供 8.3 别名时该用例记 skipped，不冒称通过。本机加验 `nim check --os:windows --cpu:amd64` 语义检查，以及 Linux release 套装 19 OK / 0 FAILED。
- 第二轮 CI（`2271ea9`）全部成功：`Leaf SDK 发布` 33m51s（windows-x86_64、linux-x86_64、macos-x86_64、macos-aarch64、publish），`Nim + GPUI 构建与测试` 21m24s，`Model 三平台回归` 9m53s，`数据库迁移三平台回归` 11m33s。
- beta 滚动到 `beta.2271ea96aca5`，`beta` tag 指向 `2271ea9`，4 个平台包与 4 个 SHA256 齐全。

## 仍未取得的证据

- 真实 Windows/macOS 任务泵窗口、Task6 Step2/4 的平台 RED/GREEN、系统 IME 组合与提交、跨屏 DPI、内存工具与长期 RSS、GPU 帧/FPS 仍未执行。Windows SDK 构建、安装与迁移 smoke 成功不等于窗口行为验收。
- 8.3 别名依赖仍是边界：ReFS 或禁用 8.3 的 NTFS 卷无法用随附 ANSI GCC 编译 Unicode 目录，fixture 在这种情况下记为 skipped。
- 本轮没有重跑官方 normal/release 之外的历史输入矩阵，也没有重跑 SDK 搬迁 smoke；`3ef1627`/`2271ea9` 的结论只覆盖上面列出的实际命令与 CI 记录。
