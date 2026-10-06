# 开发

安装 Nim 2.2.6+ 和 Rust 1.92+，按照 README 安装平台图形依赖。GPUI Kit 固定为 0.7.0，提交 `Cargo.lock`。

```sh
cargo build --locked -p leaf-gpui
nim c -d:release --out:target/nim/leaf src/leaf_cli.nim
target/nim/leaf --help
target/nim/leaf init my-app
target/nim/leaf --watch my-app
# 完整应用模板与一键资源生成
target/nim/leaf g scaffold business-app
target/nim/leaf g scaffold Note title:string archived:bool --project business-app
target/nim/leaf --watch business-app
```

`NIM` 指定 Nim 编译器，`CARGO` 指定 Cargo；`LEAF_LIBRARY` 指定包含 `leaf.nim` 的 Nim 源码目录；`LEAF_GPUI_ROOT` 指定包含桥接 Cargo workspace 的目录。`LEAF_GPUI_LIBRARY` 可以指定已编译桥接库；使用它时 CLI 直接复制该库。设置 `LEAF_GPUI_PROFILE=release` 可构建优化桥接库，默认使用 Cargo dev profile。

项目配置 `leaf.json` 指定名称、入口、资源包含规则和平台二进制路径。`init` 创建多模块 Nim 项目和资源示例。资源根据程序位置解析，发布包可搬迁运行。

`g scaffold` / `generate scaffold` 创建完整页面组应用；加 `--project` 则生成并注册一个业务资源。两种模式支持 `--dry-run`，已有文件或被修改的自动注册文件会报告冲突。页面组、独立路由、模型、服务与迁移文件的约定见[脚手架说明](scaffolding.md)。完整模板默认 SQLite 持久化并在启动时执行待应用迁移；可用 `LEAF_DATABASE_PATH` 指定测试数据库。目标平台需要 SQLite 动态库。`init` 提供简洁示例，业务应用使用 `g scaffold`。

应用命令支持 `--check`、`--headless`、`--click KEY`、`--change KEY VALUE`、`--submit KEY VALUE`、`--toggle KEY true|false` 和 `--list KEY FIRST FINISH`。`--trace`、`--log-file`、`--dump-tree` 提供诊断。

watch 在后台编译候选，失败保留旧程序。候选在 GPUI 首次显示帧之后通过同步 ready 回调写入带代号和 PID 的就绪消息，随后监督器替换旧程序。每次成功替换重新初始化状态。

```sh
cargo test --workspace --locked
nim c -r --out:target/nim/test_runner scripts/test.nim
nim c -r --out:target/nim/native_test scripts/native_test.nim
nim c -d:release -r --out:target/nim/benchmark benchmarks/runtime.nim
```

真实桌面验收当前使用 Linux X11、Xvfb 和 xdotool。`LEAF_TEST_XVFB` / `LEAF_TEST_XDOTOOL` 可指定测试工具。Xvfb 中的软件图形结果不能代表硬件 GPU 性能。
