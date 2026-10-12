# 开发

安装 Nim 2.2.6+ 和 Rust 1.92+，按照 README 安装平台图形依赖。GPUI Kit 固定为 0.7.0，提交 `Cargo.lock`。

```sh
cargo build --locked -p leaf-gpui
nim c -d:release --out:target/nim/leaf src/leaf_cli.nim
export PATH="$PWD/target/nim:$PATH"
leaf --help
leaf init my-app
cd my-app
# 将未修改的最小模板升级为完整应用。
leaf g scaffold
leaf g scaffold Note title:string archived:bool
leaf db migrate --dry-run
leaf db migrate
leaf --watch
```

`NIM` 指定 Nim 编译器，`CARGO` 指定 Cargo；`LEAF_LIBRARY` 指定包含 `leaf.nim` 的 Nim 源码目录；`LEAF_GPUI_ROOT` 指定包含桥接 Cargo workspace 的目录。`LEAF_GPUI_LIBRARY` 可以指定已编译桥接库；使用它时 CLI 直接复制该库。设置 `LEAF_GPUI_PROFILE=release` 可构建优化桥接库，默认使用 Cargo dev profile。

项目配置 `leaf.json` 指定名称、入口、资源包含规则和平台二进制路径。`init` 创建多模块 Nim 项目和资源示例。资源根据程序位置解析，发布包可搬迁运行。

`g scaffold` / `generate scaffold` 在当前目录创建完整页面组应用；加模型名与字段则在最近的 Leaf 项目生成并注册业务资源。所有项目命令从 cwd 向上查找最近的 `leaf.json`；旧 PROJECT 位置参数与 `--project` 已移除。两种模式支持 `--dry-run`，已有文件或被修改的自动注册文件会报告冲突。页面组、独立路由、模型、服务与迁移文件的约定见[脚手架说明](scaffolding.md)。完整模板默认 SQLite 持久化并在启动时执行待应用迁移；可用 `LEAF_DATABASE_PATH` 指定测试数据库。目标平台需要 SQLite 动态库。`init` 提供简洁示例，业务应用使用 `g scaffold`。

应用命令支持 `--check`、`--headless`、`--click KEY`、`--change KEY VALUE`、`--submit KEY VALUE`、`--toggle KEY true|false` 和 `--list KEY FIRST FINISH`。`--trace`、`--log-file`、`--dump-tree` 提供诊断。

watch 在后台编译候选，失败保留旧程序。候选在 GPUI 首次显示帧之后通过同步 ready 回调写入带代号和 PID 的就绪消息，随后监督器替换旧程序。每次成功替换重新初始化状态。

```sh
cargo test --workspace --locked
nim c -r --out:target/nim/test_runner scripts/test.nim
# 仅执行 SDK 归档、安装与发布工具回归
nim c -r --out:target/nim/test_runner scripts/test.nim --release-only
# 数据库 CLI、DSL、并发锁与历史回归（无需图形库或 Rust）
nim c -r --out:target/nim/test_runner scripts/test.nim --database-only
nim c -r --out:target/nim/native_test scripts/native_test.nim
nim c -d:release -r --out:target/nim/benchmark benchmarks/runtime.nim
```

真实桌面验收当前使用 Linux X11、Xvfb 和 xdotool。`LEAF_TEST_XVFB` / `LEAF_TEST_XDOTOOL` 可指定测试工具。Xvfb 中的软件图形结果不能代表硬件 GPU 性能。

Windows 应用的尺寸、布局和字号采用逻辑像素，由 GPUI 按当前窗口的设备比例缩放一次。例如逻辑宽度 640 在 150% 下换算为 960 设备像素，不应再在页面中乘 1.5。

Windows CLI 的 build/run/watch/pack 共用 `startBuild`，为主 EXE 嵌入 ID=1、RT_MANIFEST=24 的 PerMonitorV2 manifest，保留 Common Controls v6 依赖。安装 SDK 的资源取自其 `src/leaf/resources/windows`，可随 SDK 搬迁。资源编译复用已选 MinGW GCC 同目录的 windres（其次 PATH），缺工具、工具失败或缺输出会终止构建。源码构建先用 Nim 的项目配置生成 C 编译/链接命令，确认同一 GCC；不兼容工具链明确失败。发现阶段的源码编译错误与正式编译错误一样返回可轮询的失败 BuildJob，保留诊断和退出码。CLI 与 Win32 测试 runner 显式选择 Windows 10 头文件（`_WIN32_WINNT=0x0A00`、`WINVER=0x0A00`），无需编辑 Nim 安装目录的配置。此路径仅支持现有 MinGW，未新增 MSVC/Clang 支持。

仓库通过 `.gitattributes` 将内嵌模板、vendored ORM 与测试 fixture 固定为 LF，避免 Windows `core.autocrlf=true` 改变生成文件字节或 ORM 的 SHA256。新检出会自动遵循这些属性；已有 CRLF checkout 可在独立目录重新克隆后验证，不要强制覆盖包含未提交修改的目录。ORM 的原始字节哈希校验保持启用。

直接 `nim c` 不自动嵌入应用资源；桌面入口在加载 GPUI 前按需加载 WinAPI，检查有效 DPI 上下文并尝试 PMv2。已是 PMv2 不重复设置；宿主已选 system/per_monitor 模式则保留并输出 `host_context`，unknown 或初始化失败输出 `failed` 和错误码。访问拒绝只有复查到 PMv2 才视为 already_set。不会强改线程模式。导入 Leaf 和 `--headless`/`--check` 不调用此初始化。Manifest 建立的进程上下文由 Windows 加载器在进程启动时决定，CLI 产物即使以 headless 运行也可能已是 PMv2；这与 headless 主动初始化是两回事。

```powershell
# 在已有 Windows Nim/MinGW/Rust 环境中，从项目根目录运行
nim c --path:src --out:target\dpi-direct.exe tests\nim\windows_dpi_app.nim
.\target\dpi-direct.exe --trace --log-file .\dpi-direct.jsonl
```

JSONL 的 `dpi` 记录包含 `awareness`、`status` 和 `error_code`。首帧的 `rendering` 记录包含 GPUI 当前窗口实测 `scale_factor` 和 `logical_size`；`device_size_calculated`、`dpi_from_scale_calculated` 为换算值，不是 Win32 DPI 或交换链实测。ABI1 在成功 ready 严格协商 `capabilities.rendering_diagnostics=true` 后，才在窗口 bounds 变化时继续记录并去重；旧 Nim 宿主未宣告能力时，新 DLL 禁发新 op，新 Nim 仍接受旧 DLL 的无 metadata ready。ABI2 使用类型化 `RENDERING` 请求，在 Nim 侧按比例和逻辑尺寸去重，`FRAME` 采样不重复写尺寸日志；非法尺寸或换算溢出只拒绝该诊断请求，不影响后续 ready。两条路径都不会因尺寸诊断再次 ready 或改写 watch receipt。JSONL 仅为可选日志，不用于 UI 树传输；完整诊断需要重新编译框架/DLL 和应用。

更新 SDK/框架后应重新编译主 EXE，已有 EXE 不会获得新 manifest。比例仍不符合系统设置时，先查应用属性中的 Windows 高 DPI 兼容性覆盖、启动宿主的 DPI 模式，再用[原生验证步骤](verification.md)核对实际 HWND DPI 和 GPUI 比例。当前 Linux 测试不能证明 Windows 清晰度已改善。

数据库命令在 `target/leaf-db` 编译独立维护入口，不导入应用 UI，也不要求 Cargo 或 GPUI。`db init` 仅安装配置；自定义入口需显式调用 `openApplicationDatabase()`，完整脚手架自动接入。命令、DSL 与多分支规则见[数据库迁移](migrations.md)。

## 组件性能与发布回归

组件 CPU 基准：`nim c -d:release --mm:orc -d:nimAllocStats --path:src --out:target/nim/component_bench benchmarks/components.nim`。分别运行 `--mode legacy-json|legacy-typed|managed-typed --static 100|1000|5000 --iterations 200 --warmup 50 --rounds 3 --output PATH`。计时内不输出报告。分配字段是 Nim allocator 的分配次数；RSS、堆占用与峰值另记，不能把存活堆增量当总分配字节数。

`nim c -r scripts/verify_component_performance.nim MODE-100.json MODE-1000.json MODE-5000.json` 验证元数据、原始样本、业务正确性和局部计数约束；legacy 模式保留完整树成本，不套 managed 上限。CPU 工具只测 Runtime 与编码，Rust apply 和 GPUI 帧字段为空，不能据此推出帧率。

`benchmarks/components_native.nim` 使用真实 GPUI 窗口。设置 `LEAF_GPUI_LIBRARY` 和 `LEAF_BENCH_MODE`，参数由 `LEAF_BENCH_STATIC/ITERATIONS/WARMUP/ROUNDS/OUTPUT` 指定。typed 模式测量 Rust prepare/apply 与显式 GPUI draw（layout+paint 合计），event-to-frame 含调度；纯 layout 无公开独立测量时保留空值。报告必须标明 Rust profile、库 hash、实际 GPU 或软件渲染，不能与 CPU 微基准混算。

SDK 打包复制所有新 Nim 模块及 `include/leaf_gpui_v2.h`。实际搬迁回归应清除 `NIM/LEAF_LIBRARY/LEAF_GPUI_ROOT/LEAF_GPUI_LIBRARY` 覆盖，检查 doctor 指向随包编译器和源码，默认 GPUI build 的 staged DLL hash 与 SDK lib 相同，再运行组件应用。Linux 测试不能替代 Windows ABI、IME、DPI 和窗口验收。
