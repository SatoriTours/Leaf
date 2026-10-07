# 验证

验收包含三条独立路径：Nim 核心与工具回归、GPUI Kit 控件测试、Linux 真实窗口测试。无窗口回归不能替代实际桌面交互。

2026-10-05 在 Linux x86_64 上完成以下验收，使用 Nim 2.2.6、GPUI Kit 0.7.0 以及锁定的 Cargo 依赖。

| 验证 | 命令或方式 | 结果 |
| --- | --- | --- |
| Nim 核心、CLI、watch、发布与页面逻辑 | `nim c -r --out:target/nim/test_runner scripts/test.nim` | 22 个测试套件全部通过 |
| GPUI Kit 控件与 C ABI | `cargo test --workspace --locked` | 9 项测试通过 |
| Rust 静态检查 | `cargo clippy --workspace --all-targets -- -D warnings`、`cargo fmt --all --check` | 通过 |
| 真实 GPUI 窗口 | `nim c -r --out:target/nim/native_test scripts/native_test.nim` | 鼠标点击、输入、Enter、就绪与关闭通过；首屏列表失败不报告就绪 |
| CLI 与多模块发布 | `leaf pack examples/project --target linux --output dist` | tar.gz 与 SHA256 生成，独立读取器验证归档 |
| 发布包搬迁 | 解压到独立目录，从 `/tmp` 运行，清除框架路径覆盖 | 资源读取、两次 headless 点击、真实窗口点击与关闭通过 |
| 桥接库加载 | 检查搬迁后窗口进程的加载映射 | 使用随包 `libleaf_gpui.so`，没有加载 GTK 库 |

GPUI 控件回归覆盖禁用事件、中文文本、输入与 Enter、稳定输入实体和选区、受控输入拒绝后的恢复、IME 组合状态与提交，以及同屏多个变量列表行和来源重排后的焦点行。Nim 桥接回归另外验证十万项按需构建、首屏失败拒绝就绪、替换来源失败时保留成功快照和行回调。

真实窗口验收使用私有 Xvfb、xdotool 与 SwiftShader Vulkan 软件驱动。`docs/screenshots/counter-gpui.png` 来自实际 GPUI 计数器窗口。当前平台证据为 Linux；macOS 和 Windows 发布格式用目标文件头与资源布局回归验证，尚未在这两个系统上执行原生窗口验收。

性能管道使用 Release Nim producer 执行：

```sh
target/nim/leaf-performance --suite all --iterations 2 --warmup 2 \
  --rounds 1 --repeat 2 --interval 0 --output artifacts/performance
```

运行时与原生帧两组各完成两轮，输出 schema 2 原始样本和通过报告。原生组包含普通布局、十万项固定行高及变高列表，计时包含事件更新到下一绘制帧的调度与渲染。这是管道功能验收的小样本，不能代表硬件 GPU 性能或长期性能基线。

2026-10-06 Windows DPI 任务提供了跨平台决策、资源失败和握手回归，以及原生验收入口。当前执行机是 Linux，无 windres/Wine/真实 Windows 桌面；P1–P4 原生证据均为 **not_verified**，没有最终 Windows 清晰度证明。Linux 模拟窗口取样和 Windows `--compileOnly` 仅检查代码路径，不能替代 PE 链接、Windows API 运行或视觉验收。执行命令和退出码见 `target/verification/windows-dpi-36dbf599/commands.jsonl`，任务记录见 `docs/superpowers/plans/2026-10-06-windows-dpi-36dbf599-execution-r0.md`。

在已授权、有现成 Nim 2.2.6、MinGW/windres 和锁定 Rust 依赖的真实 Windows 环境中执行（不需要安装新截图/自动化依赖）：

```powershell
# 从 Leaf 根目录执行，nim/leaf 为本地现有工具；也可用其绝对路径
nim c -r --path:src --out:target\test_windows_dpi.exe tests\nim\test_windows_dpi.nim
nim c -r --path:src --out:target\test_windows_manifest.exe tests\nim\test_windows_manifest.nim
nim c -r --path:src --out:target\test_gpui_bridge.exe tests\nim\test_gpui_bridge.nim
nim c -r --path:src --out:target\test_bootstrap.exe tests\nim\test_bootstrap.nim
nim c --path:src --out:target\windows_dpi_probe.exe tests\nim\windows_dpi_probe.nim
leaf build tests\nim\windows_dpi_app.nim --output target\dpi-cli.exe
.\target\dpi-cli.exe --trace --log-file .\dpi-cli.jsonl
# 直接 Nim 编译的兜底路径，独立运行，保存另一份 JSONL
nim c --path:src --out:target\dpi-direct.exe tests\nim\windows_dpi_app.nim
.\target\dpi-direct.exe --trace --log-file .\dpi-direct.jsonl
```

`test_windows_dpi` 为 default、PMv2、system、per_monitor、headless 各创建独立进程，避免 awareness 相互污染。headless probe 比较 `GetModuleHandleW(user32)` 前后和有效上下文；同时审查真实 import Leaf/headless 的生成 C，确认新增 DPI 模块不在 NimMain 初始化阶段加载 user32。注入测试覆盖 setter 被拒绝后的复查，不把错误码 5 当作成功。

`test_windows_manifest` 通过 CLI 共用的 `startBuild` 构建最小程序，使用资源数据加载标志和 `FindResourceW` 读取实际主 EXE ID=1/24，解析取出的 XML 的 asm.v1/asm.v3、SMI 2005/2016 命名空间及 DPI 声明。程序只查询 PMv2，不调用 setter，验证上下文来自 manifest。测试使用搬迁 sources 和含中文、空格、`$` 的 output/cache。另在已搬迁的完整 SDK 下运行其现有 `bin\leaf.exe`，从复杂路径项目编译同一 app，并保存实际 EXE 的资源验证和运行日志；源码 fixture 不能替代完整 SDK 搬迁验收。资源失败/缺输出/拒用旧对象由 Linux 可执行工具 fixture 覆盖；真实 MinGW 链接仍需本步骤。

基线位于 `target/verification/windows-dpi-36dbf599/baseline/`，保持原字节和 SHA256。`source.tar` 冻结 HEAD `726df073739e1bdcc9318939b5e840d16fede2ad` 的原框架、DLL 源码及 Cargo 输入，identity.json 记录 clean 状态；没有原始 Windows 产物或截图。原版必须从此来源重建，不能关闭新 setter 假装原版。以下操作仅在已授权 Windows 验收环境、任务临时 fixture 目录中进行：

```powershell
$evidence = Join-Path (Get-Location) 'target\verification\windows-dpi-36dbf599'
$original = Join-Path $evidence 'original-source'
New-Item -ItemType Directory -Force $original | Out-Null
Get-FileHash (Join-Path $evidence 'baseline\source.tar') -Algorithm SHA256
# 必须匹配 5a844eaa371391d16f00e435bde0119df5d602de26a5fb062c0dfb1318d9d169
 tar -xf (Join-Path $evidence 'baseline\source.tar') -C $original
cargo build --locked --manifest-path (Join-Path $original 'Cargo.toml') --target-dir (Join-Path $evidence 'original-rust')
# 同一纯验收内容复制到 fixture；不添加任何新 DPI API 到原版
Copy-Item tests\nim\windows_dpi_app.nim (Join-Path $original 'dpi_app.nim')
nim c --skipParentCfg:on --skipUserCfg:on "--path:$original\src" "--nimcache:$evidence\original-nim" "--out:$original\dpi-original.exe" (Join-Path $original 'dpi_app.nim')
Copy-Item (Join-Path $evidence 'original-rust\debug\leaf_gpui.dll') $original
# 避免环境中的新 DLL 覆盖；此设置仅在本终端、本次验收中使用，结束后恢复
$previousGpui = $env:LEAF_GPUI_LIBRARY
$env:LEAF_GPUI_LIBRARY = Join-Path $original 'leaf_gpui.dll'
& (Join-Path $original 'dpi-original.exe') --trace --log-file (Join-Path $evidence 'original.jsonl')
$env:LEAF_GPUI_LIBRARY = $previousGpui
```

记录原/新 app 源码、EXE、DLL 的 SHA256、源码来源、Nim/Rust/MinGW 版本及每条命令/退出码。确认原版使用冻结框架和 DLL，且不被当前 `LEAF_LIBRARY`、`LEAF_GPUI_LIBRARY` 或当前 checkout 的 Nim path 覆盖。原版旧协议没有 rendering 记录：若不能直接取得 GPUI 比例，基于锁定源码和独立 DPI 推导的值必须标为 inferred，P3 原版实测仍未满足。若实际原版 DPI 已是 144 且 GPUI 比例已是 1.5，应停止“未 DPI 感知导致模糊”的假设并重新调查。

打开 app 后，在第二个 PowerShell 终端从 JSONL 的 `pid` 取得应用 PID；probe 精确枚举该 PID 的可见顶层 HWND，无前台窗口假设。它独立输出 `hwnd`、`dpi_win32_measured` 和 `awareness_win32_measured`：

```powershell
.\target\windows_dpi_probe.exe window 12345
# 将 12345 替换为应用自身 PID，保存原始 JSON 输出。
Get-FileHash tests\nim\windows_dpi_app.nim,target\dpi-cli.exe,target\leaf_gpui.dll -Algorithm SHA256
```

同机、同显示器的用户现有 100%/125%/150% 设置分别应核对 Win32 DPI 96/120/144 和 GPUI scale 1.0/1.25/1.5；150% 时逻辑客户区宽 640 对应计算设备宽 960（以实际 logical_size 为准）。分别用原版、CLI 新版和直接编译新版，保存未重采样的原始截图和完整元数据。不要以压缩图片或 Linux 渲染替代原图对照，也不要擅自修改全局显示设置。

P4 要求在 150% 实际点击计数、编辑中文、移动光标、选择文本、IME 组合/提交、resize、最大化和重绘。用户在 Windows 自行改变系统缩放时保持同一 app PID/HWND：变化前后分别运行 probe，并保存同一进程 bounds 变化产生的 rendering JSONL，确认当前 DPI、GPUI 比例/尺寸更新及命中/IME正常；不能只重启窗口取首帧值。若没有同窗口真实变化和操作证据，P4 继续 not_verified。混合 DPI 多屏是可选项。

P5 的混版本回归通过真实 Desktop 订阅和 ready 路径验证：能力初始 false，只有成功 ready 的严格布尔 true 开启新 op；缺能力/false/非bool/ready拒绝或回调失败保持关闭。旧宿主 fixture 保留 unknown op 持久错误及 status/list/event/receipt 语义，不能用丢弃响应掩盖污染。协商后的诊断失败不交给业务 accept；旧 DLL 的旧格式 ready 仍被新版 Nim 接受。

必需 Windows 原生证据缺失时，最终验收结论应为 blocked；本记录只证明已执行的平台检查，不声明模糊已解决。
