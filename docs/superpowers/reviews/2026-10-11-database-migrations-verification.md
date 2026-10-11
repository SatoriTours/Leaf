# 数据库迁移本地验收记录

日期：2026-10-11。代码提交：`153247f66d714d90090fd9a3b80ac15c33debc93`，分支 `feat/database-migrations`。

## 执行空间与恢复

- 原协调会话：`8c927e37-4b2f-4cd3-9390-fd50df972ddb`，项目 local 入口 `/home/jimxl/projects/leaf`。
- 旧记录中的 database-migrations 执行目录已不存在，Git 保留已提交分支 `b4816c5`；本轮仅恢复可验证的提交，不声称恢复旧未提交实验。
- 替代 Paseo 托管空间：`wks_a6b1356823af1be9`，名称“【自动】数据库迁移管理续开发”，路径 `/home/jimxl/.paseo/worktrees/1c1rvoii/database-migrations-resume`。复用原功能分支，基线 `07f2a0d`。
- 未修改项目主目录的原生控件未跟踪文档；未改动冻结的 scaffold_v1 fixture、Model 实现或 Rust 桥接代码。

## 本轮结果

完成 CLI 维护生命周期和 SDK 收口：Linux 通过内核子进程列表核验所有权，读取失败不当作空树；守护进程异常退出独立报告，输出读取错误停止轮询，有限等待错误仍继续回收；关闭时公平排空输出尾部。增加 POSIX waitid/WNOWAIT 进程组后端，保留未回收组长以避免延迟清理误用已回收 PID。继承描述符枚举覆盖高位句柄。

增加真实跨分支 CLI 测试：先应用高版本后合入低版本时补跑并保留数据，空库执行合并全集，重复版本和缺失历史拒绝写入，语义冲突撤销失败步骤。更新 SDK smoke、脚手架文档和 CI 的当前目录命令。新增 `--database-only` 及三平台数据库工作流。

## 实际验证

| 检查 | 结果 |
| --- | --- |
| 完整 Nim/release runner | 59 文件套件，日志 514 个 OK，0 FAILED / 0 SKIPPED；exit 0 |
| 无 Git 源码归档数据库 runner | 14 文件套件，194 个 OK，0 FAILED / 0 SKIPPED；exit 0 |
| 最终提交数据库 CLI 单独复测 | 20 OK，exit 0 |
| 分离输出与生命周期故障注入 | 7 OK，exit 0；真实 waitpid EINVAL、read EIO、2048 以上描述符 |
| 便携 POSIX 后端在 Linux 运行 | 5 OK，exit 0；不是 macOS 实测 |
| Rust workspace tests | 17 passed，exit 0 |
| 本地最终 SDK 归档与搬迁 smoke | exit 0；中文/空格路径，离线迁移、预览、回滚、状态和 Model CRUD/persistence |
| macOS arm64 / Windows C 生成 | 两项 `--compileOnly` exit 0；不是 C 链接或系统运行验证 |
| Git | 代码提交后工作树干净，diff check 通过；主分支未合并、未推送 |

全量 runner 已包含 Model 和 release 套件，未单独重复运行 --model-only/--release-only。数据库源码归档使用 `git archive 153247f`，设置 `CARGO=/nonexistent/leaf-no-cargo` 与 `LEAF_GPUI_ROOT=/nonexistent/leaf-no-gpui`，证明专项无需 Rust/GUI。

首次全量尝试因缺少 libxkbcommon-x11 链接失败（保留 tests.log），随后复用机器已有临时库，完整重跑通过。未安装系统依赖。最终运行环境：

```sh
export PATH=/tmp/nim-2.2.6/bin:/tmp/leaf-sdk-pwsh:$PATH
export NIM=/tmp/nim-2.2.6/bin/nim
export CARGO_HOME=/tmp/mui-cargo CARGO_NET_OFFLINE=true
export LIBRARY_PATH=/tmp/mui-display/usr/lib
export LD_LIBRARY_PATH=/tmp/mui-display/usr/lib
nim c -r --out:/tmp/leaf-db-test-runner scripts/test.nim
cargo test --workspace --locked --offline
nim c -r -d:leafSplitFaultTest --out:/tmp/leaf-db-split-faults tests/nim/test_split_process.nim
nim c -r -d:leafPortableSplit --out:/tmp/leaf-db-split-portable tests/nim/test_split_process.nim
```

完整日志和 SHA256 清单保存到原项目目录 `/home/jimxl/projects/leaf/target/verification/database-153247f`，不会随功能 worktree 归档删除。最终 SDK 归档保留于 `/tmp/leaf-db-sdk-153247f`，搬迁副本位于 `/tmp/leaf database SDK final 中文/leaf-sdk`；这是本地验证产物，未发布。

## 验证边界与下一步

Windows/macOS 实际运行、平台文件锁、系统 SQLite 和真实路径行为仍待 `.github/workflows/database.yml` 执行；未运行本轮真实桌面验收。其他 POSIX 后端管理进程组和嵌套 Leaf 命令，配置自行脱离进程组启动的任意外部守护进程不在该后端保证内；Linux subreaper 与 Windows Job Object 不依赖此组假设。

Linux 本地功能与 SDK 验证通过，跨平台验收待 CI。尚无合并或推送授权，保留功能空间；获得授权后先推送功能分支验证三平台，再按结果处理 main 集成。不能把准备的 CI 或 compileOnly 当成平台运行成功。
