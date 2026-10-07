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
# 仅执行 SDK 归档、安装与发布工具回归
nim c -r --out:target/nim/test_runner scripts/test.nim --release-only
nim c -r --out:target/nim/native_test scripts/native_test.nim
nim c -d:release -r --out:target/nim/benchmark benchmarks/runtime.nim
```

真实桌面验收当前使用 Linux X11、Xvfb 和 xdotool。`LEAF_TEST_XVFB` / `LEAF_TEST_XDOTOOL` 可指定测试工具。Xvfb 中的软件图形结果不能代表硬件 GPU 性能。

Windows 应用的尺寸、布局和字号采用逻辑像素，由 GPUI 按当前窗口的设备比例缩放一次。例如逻辑宽度 640 在 150% 下换算为 960 设备像素，不应再在页面中乘 1.5。

Windows CLI 的 build/run/watch/pack 共用 `startBuild`，为主 EXE 嵌入 ID=1、RT_MANIFEST=24 的 PerMonitorV2 manifest，保留 Common Controls v6 依赖。安装 SDK 的资源取自其 `src/leaf/resources/windows`，可随 SDK 搬迁。资源编译复用已选 MinGW GCC 同目录的 windres（其次 PATH），缺工具、工具失败或缺输出会终止构建。源码构建先用 Nim 的项目配置生成 C 编译/链接命令，确认同一 GCC；不兼容工具链明确失败。此路径仅支持现有 MinGW，未新增 MSVC/Clang 支持。

直接 `nim c` 不自动嵌入应用资源；桌面入口在加载 GPUI 前按需加载 WinAPI，检查有效 DPI 上下文并尝试 PMv2。已是 PMv2 不重复设置；宿主已选 system/per_monitor 模式则保留并输出 `host_context`，unknown 或初始化失败输出 `failed` 和错误码。访问拒绝只有复查到 PMv2 才视为 already_set。不会强改线程模式。导入 Leaf 和 `--headless`/`--check` 不调用此初始化。Manifest 建立的进程上下文由 Windows 加载器在进程启动时决定，CLI 产物即使以 headless 运行也可能已是 PMv2；这与 headless 主动初始化是两回事。

```powershell
# 在已有 Windows Nim/MinGW/Rust 环境中，从项目根目录运行
leaf --trace --log-file .\dpi-cli.jsonl .\tests\nim\windows_dpi_app.nim
nim c --path:src --out:target\dpi-direct.exe tests\nim\windows_dpi_app.nim
.\target\dpi-direct.exe --trace --log-file .\dpi-direct.jsonl
```

JSONL 的 `dpi` 记录包含 `awareness`、`status` 和 `error_code`。首帧 ready 的 `rendering` 记录包含 GPUI 当前窗口实测 `scale_factor` 和 `logical_size`；`device_size_calculated`、`dpi_from_scale_calculated` 为换算值，不是 Win32 DPI 或交换链实测。成功 ready 严格协商 `capabilities.rendering_diagnostics=true` 后，窗口 bounds 变化才继续记录当前比例/尺寸，并去重；不会再次 ready 或改写 watch receipt。旧 Nim 宿主未宣告能力时，新 DLL 禁发新 op，ABI 仍为 1。新 Nim 接受旧 DLL 的无 metadata ready；完整诊断需要重新编译框架/DLL 和应用。

更新 SDK/框架后应重新编译主 EXE，已有 EXE 不会获得新 manifest。比例仍不符合系统设置时，先查应用属性中的 Windows 高 DPI 兼容性覆盖、启动宿主的 DPI 模式，再用[原生验证步骤](verification.md)核对实际 HWND DPI 和 GPUI 比例。当前 Linux 测试不能证明 Windows 清晰度已改善。
