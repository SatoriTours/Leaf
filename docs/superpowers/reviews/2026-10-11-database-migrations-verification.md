# 数据库迁移本地验收记录

日期：2026-10-11。首轮代码提交：`153247f66d714d90090fd9a3b80ac15c33debc93`，分支 `feat/database-migrations`。

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

首轮未做 Windows/macOS 实际运行，Windows 已在下方追加完成 Docker 虚拟机专项验收；macOS 和远端 CI 仍待验证。未运行本轮真实桌面验收。其他 POSIX 后端管理进程组和嵌套 Leaf 命令，配置自行脱离进程组启动的任意外部守护进程不在该后端保证内；Linux subreaper 与 Windows Job Object 不依赖此组假设。

Linux 本地功能与 SDK 验证通过，跨平台验收待 CI。尚无合并或推送授权，保留功能空间；获得授权后先推送功能分支验证三平台，再按结果处理 main 集成。不能把准备的 CI 或 compileOnly 当成平台运行成功。


## Windows Docker 追加验收

追加代码提交：`8be87d8aecde240652fd65d0a7503b169ebddb54`。复用本机已经运行的 `leaf-a2-windows` Docker 托管 Windows 虚拟机，在 `C:/LeafTests/database-153247f` 独立目录执行；没有重建、重启或关闭该虚拟机。内核版本 `10.0.26300.0`、amd64，Nim 2.2.6、MinGW GCC 16.2.0。测试环境显式将 CARGO 与 LEAF_GPUI_ROOT 指向不存在的路径。

本轮真实运行发现并修复：

- 数据库维护程序缺少 Windows `.exe` 后缀，导致编译成功后无法启动；测试辅助程序和并发/遗留构建的启动路径同步修正。
- 初始化与 scaffold 的迁移 README 计划误用 Windows 反斜杠，触发规范相对路径校验；计划统一使用 `/`。
- Windows 关闭 Job Object、等待子进程退出后没有保存实际退出码，导致关闭后的状态仍为 -1；现于释放进程句柄前读取最终退出码，普通与分离输出进程均使用该结果。
- Windows PE 重建带来的维护程序变化不属于数据库/源文件只读契约；快照仅排除 `target/leaf-db` 编译产物，继续严格比较数据库和项目源文件。
- 精确时间戳断言在 Windows 改用 getFileInfo 的句柄查询。Nim 的快捷查询使用 FindFirstFile，NTFS 可能返回缓存元数据；微软建议使用句柄信息获取当前属性。所有文件与目录时间戳断言保留。[微软 FindFirstFile 文档](https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-findfirstfilea)
- 数据库 CI 移除额外的 Bash NIM 路径覆盖，使用 runner 已有的原生编译器发现逻辑；在 Windows 实际验证未设置 NIM 时能找到有效的原生路径。远端工作流未执行。

最终结果：

| 检查 | 结果 |
| --- | --- |
| Windows 数据库专项 | 全部 14 文件套件，日志 174 OK、0 FAILED、3 SKIPPED，exit 0 |
| Windows 此前失败的集成用例 | schema 2 遗留调用、初始化与 scaffold dry-run 精确时间戳、强制关闭后已知退出码均通过 |
| 最终 Linux 全量回归 | 59 文件套件，日志 514 OK、0 FAILED、0 SKIPPED，exit 0 |
| 源码一致性 | Windows 中 11 个修改过的 Nim 文件 SHA256 与本地提交源码逐个一致 |
| 进程收尾 | Windows 本任务目录关联进程数量 0；虚拟机继续保留供其他任务使用 |

Windows 明确跳过 POSIX 信号驱动的取消、双引号目录名和删除仍打开的 SQLite 文件三个场景。日志 OK 是测试声明的计数，其中还包含编译期平台条件的空分支；不据此声称 Windows 执行了 POSIX 专用断言。

Windows 使用临时审计 runner，选取同样的 14 个数据库套件、使用同样的编译与运行命令，仅将首个失败即退出改为跑完后汇总失败。该 runner、完整日志、此前失败证据、环境、最终状态及源码指纹保存在原项目的 `target/verification/database-windows-153247f`。源码由 `git archive 153247f` 加本轮修复组成；原始 result.json 的 commit 字段指归档基线，最终代码提交和逐文件指纹以 manifest.json 为准。

本轮没有打包/发布 Windows SDK，没有执行 macOS 实机测试或 GitHub Actions；此前的 Linux SDK 搬迁 smoke 对应首轮提交 153247f。功能分支已本地提交，尚无合并、推送授权，保留执行空间。后续还需 macOS 运行验收及授权后的 main 集成、推送。
