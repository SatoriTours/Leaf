# 验证

验收包含三条独立路径：Nim 核心与工具回归、GPUI Kit 控件测试、Linux 真实窗口测试。无窗口回归不能替代实际桌面交互。

2026-10-05 在 Linux x86_64 上完成以下验收，使用 Nim 2.2.6、GPUI Kit 0.7.0 以及锁定的 Cargo 依赖。

| 验证 | 命令或方式 | 结果 |
| --- | --- | --- |
| Nim 核心、CLI、watch、发布与页面逻辑 | `nim c -r --out:target/nim/test_runner scripts/test.nim` | 22 个测试套件全部通过 |
| GPUI Kit 控件与 C ABI | `cargo test --workspace --locked` | 9 项测试通过 |
| Rust 静态检查 | `cargo clippy --workspace --all-targets -- -D warnings`、`cargo fmt --all --check` | 通过 |
| 真实 GPUI 窗口 | `nim c -r --out:target/nim/native_test scripts/native_test.nim` | 鼠标点击、输入、Enter、就绪与关闭通过；首屏列表失败不报告就绪 |
| CLI 与多模块发布 | `cd examples/project && leaf pack --target linux --output dist` | tar.gz 与 SHA256 生成，独立读取器验证归档 |
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
# CLI 从 leaf.json 解析入口；为独立验收源码创建一个临时项目配置。
New-Item -ItemType Directory -Force target\dpi-project | Out-Null
Copy-Item tests\nim\windows_dpi_app.nim target\dpi-project\main.nim
'{"name":"dpi-check","entry":"main.nim","include":["main.nim"]}' | Set-Content -Encoding utf8 target\dpi-project\leaf.json
Push-Location target\dpi-project
leaf build --output ..\dpi-cli.exe
Pop-Location
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


## React 风格组件和类型化宿主（2026-10-12）

运行 `nim c -r --path:src tests/nim/test_component_faults.nim` 验证候选拒绝、State 与宿主 revision、恢复失败冻结、已接受作用域收尾错误、旧序列及提交重入。`cargo test --workspace --locked` 包括真实 GPUI Kit 输入控件、组件缓存和错误诊断测试。

Linux 实际窗口：先 `cargo build -p leaf-gpui --features native-test-support --locked`，设置 `LEAF_GPUI_LIBRARY` 指向该库，运行 `nim c -r scripts/native_test.nim`。`LEAF_TEST_APP=tests/nim/component_native_app.nim`、`LEAF_TEST_MODE=legacy|managed`、`LEAF_GPUI_ABI=1|2`、`LEAF_GPUI_CACHE=0|1` 组成八组矩阵。可用 `LEAF_TEST_XVFB` / `LEAF_TEST_XDOTOOL` 指定工具。定位使用测试构建导出的实际元素 bounds；几何文件只用于工具，不走 UI 桥接协议。`LEAF_KEEP_NATIVE_TEST=1` 可保留临时交互日志。

已执行：Linux Xvfb / Mesa 软件渲染八组，点击、中文初值/重置、编辑、Enter、拒绝恢复、选区替换、resize、隐藏/显示、ready/失败 viewport、退出。ABI1 保留拒绝非零 reset token 的原契约，fixture 使用受控值变化重置；ABI2 检查显式 token。测试构建启用 GPUI 句柄泄漏检查，两个渲染器均在安全帧释放平台输入处理器后退出。

未执行：真实 Windows / macOS、系统 IME 输入法组合阶段、真实平台的离屏焦点行操作与 DPI 切换；这些不由 X11 模拟输入或纯运行时测试替代。`nim c -r scripts/test_win32.nim` 在 Linux 返回 2，必须记 NotRun。新增 `tests/windows/test_component_host.nim` 需要实际 Windows 执行，跨平台窗口验收仍有阻塞。

## 组件页面路由（2026-10-13）

托管路由、自动State保留/销毁、配置与注册表计费、故障回滚及虚拟列表回归已通过独立任务审查。实际生产输入一致的bade396完成官方91个Nim套件和独立4个发布套件；后续bb2e981仅补性能测试围栏，普通3项/probes4项退出0。ABI布局157项通过；Rust43测试及fmt/clippy在输入和工具链一致核对后复用本轮成功结果。

Linux私有Xvfb/软件渲染的ABI1/2×CACHE0/1四组真实页面窗口均退出0，覆盖计数、重置、未知地址、完整中文草稿编辑及往返保留、disposeOnLeave和正常关闭。使用独立native-test-support桥接库；发行SDK搬迁验证使用普通桥接库。SDK在仓库外的中文/空格/`$`路径完成八条实际命令及行为断言，包内新模块和生产源码SHA一致。

100/1000/5000静态兄弟的导航均为静态render增量0、Snapshot导出增量0、6个宿主操作。共享父setChildren分别携带101/1001/5001个句柄（raw child payload808/8008/40008字节），这些样本不证明恒定CPU或总FFI字节。100完整往返保留A11/B22/C33及初始化身份；同页更换根不重复计费，prepare拒绝后验证旧registry映射仍可恢复。

[完整验证记录](superpowers/reviews/2026-10-13-component-routing-verification.md)列明每项实际提交、命令、身份复用、证据及范围裁定。真实Windows/macOS桌面、系统IME组合阶段和跨屏DPI仍为NotRun，旧React计划13.4保持未关闭。


## 组件任务与异步生命周期（2026-10-17）

Task7 源码依次提交 `f088c465`（示例、性能/native/SDK fixture 与 API 文档）、`4e1b9a9b`（独立 NimScript include 路径修复）、`a3c63c71`（实际 scaffold 生成配置路径修复）。最终产品和测试源码为 `a3c63c710611ec1bad7ef3663bcccbf210166223`；本段后续文档提交不改变这些运行输入。官方 Nim normal 100 套件、独立 `--release-only` 4 套件均实际 EXIT0，使用固定 Nim 2.2.6/ORC 串行执行。ABI 校验 161 项 EXIT0；本轮实际 Rust workspace 52 测试及 fmt/clippy 均 EXIT0，Rust/Cargo/工具链/profile 未变后复用，不借用历史数字。

100/1000/5000 静态兄弟下由真实 worker 完成单组件更新，render 增量均为 1，额外 Snapshot 均为 0，无关宿主句柄逐一保持。completion wall 样本为 2.308106/2.328006/2.322388ms，不含随后 handle 比较；这些计数与墙钟样本不承诺恒定 CPU、总 FFI 字节或 GPU 帧耗时。空泵保持 revision；ABI1 实际更新仍可能传完整活动树。

Linux 私有 Xvfb/Mesa 显示环境下，ABI1/2 × CACHE0/1 四组真实任务窗口均 EXIT0，覆盖无需后续点击的完成、错误重试、默认离开取消、keep 隐藏完成返回、dispose 重建、关闭前在途任务及最终 dispose 次数。各使用本轮新构建 native-test-support 库独立绝对路径，SHA256 `25e3213182a4b616cd22a484c47ab8e8115a580e5e3a2d5026d6c1846a2e0bd0`。四组冻结于 f088；后续 nims 字节有变，当前无 `$` 的仓库路径下 path-only 转义不改变有效选项，普通配置实际探针确认 path/define/deepcopy，宿主/任务/harness/库未变。原 f088 native 行为据此复用，没有宣称 a3 重新跑窗口或全部依赖 bytes 一致。

窗口消失/进程退出观测分别约 34.0–34.1ms / 34.1–44.2ms，受轮询与工具开销影响，合作 work 样本不构成非合作 work 的退出上界。真实窗口 ready/geometry/caption/trace 与 CPU 计数分别记录；未采样 GPUI 帧耗时/FPS，也未独立查询本轮 renderer/adapter 型号。沙箱首次禁止 X11 socket 的失败保留，审批后私有 Xvfb 成功，不当作产品 RED。

最终 SDK 新 CLI 使用 a3 真实 commit 参数打包，production 桥接库 default features/dev debug=0，独立于 native-test-support 产物。包 SHA256 `7fbe8ef270190248e6c68d87e67e176427f775579aa3ea22f6e11454665b851b`；在仓库外 `/tmp/Leaf SDK 搬迁 $ Task7 a3c63c71/leaf-sdk` 真实解包，210 个 src/include 文件逐一匹配。清除 NIM、LEAF_LIBRARY、LEAF_GPUI_ROOT、LEAF_GPUI_LIBRARY、LEAF_SDK 后，doctor、普通 build、完整 smoke（保留 migration/CRUD/持久化）及独立任务 fixture 均 EXIT0，实际断言 `SDK_TASK_RESULT=后台完成`。SDK 使用自身 Nim/source；系统 GCC 和 `/tmp/mui-display/usr/lib` OS 依赖仍保留，不称完全无外部系统依赖。

两个早期失败包未覆盖：f088/4e1 的 doctor/普通 build 成功，但完整 smoke 在生成配置路径失败。4e1 只修复独立 include 入口，随后实际 scaffold 产物回归取得 RED→GREEN，a3 才完成发布链路验证。普通/中文空格/`$`/`$$` 路径与非路径 define/deepcopy 都有实际配置运行断言。未缩路径、删 migration 或放宽结果断言。

完整 argv/exit、源码/库/工具链/profile SHA、失败分类及证据复用边界保留在 `target/verification/component-async-lifecycle/task7`，并有独立空间外报告与 manifests 备份；二进制不提交。Task1–6 已接受的接口和历史 RED/GREEN 以协调专门验证记录为准，本项没有冒称找回缺失原始日志。

NotRun：真实 Windows/macOS、完整 Windows PE 构建、系统 IME、跨屏 DPI、内存工具/长期稳态 RSS、Snapshot-export 独立故障注入、diagnostic 异常及联合 Snapshot+error 原缺口、动态 wrongthread。Task6 代码/静态通过不代表 Windows 行为通过；框架额度归零也不证明系统零泄漏。Task7 与整分支仍需独立架构审查，不自动合并、推送或归档。
