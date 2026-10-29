# 验证范围与历史记录

> **当前范围（2026-10-29）：** Windows 优先的原生 beta，本轮变更前产品交付基线 `db34265`。完整当前状态统一维护在[开发进度总览](progress.md#当前总览2026-10-29)，命令见[源码开发](development.md)。下面保留历史证据，不把旧快照或旧渲染器当作当前输入。

> **本次列表修复：** 用户已授权提交代码；上述历史基线的 CI 不覆盖此补丁，须按本次最终提交 SHA 单独核验。真实系统拖动、两侧部分行64项区域、返顶、开发者截图复验及39项受影响原生回归／example／专用clipping程序已通过；独立功能／代码复核通过（无Critical／Important），但验收模型不支持图像输入，独立视觉仍阻塞，不判整体验收通过。详见[当前进度](progress.md)。

## 当前证据与未关闭门

- **历史基线自动化通过**：`db34265` 的共享 Runtime／Windows 原生、SDK、Model／数据库三平台四条工作流及 11 个 job 均 success，固定链接见进度总览。本次新 SHA 的全量结果另见交付证据；旧本地超时和失败记录保留，不代替任何新结果。
- **限定验收通过**：Canvas 交互、tween／transition、实验室和正式 CPU 侧性能采集已有独立功能证据及适用的静态视觉证据；主要为 Windows VM／96 DPI／software，不是硬件、动态视觉或显示 FPS 证明。
- **未完成**：cold USER/GDI 原预算失败仍未关闭；部分滚动视觉、完整 T2/T3/M4、真实中文 IME、物理混合 DPI／多屏、辅助技术、长期资源留存仍需证据。原生主题的开发自测不等于独立验收，见[主题状态](design/native-skin-status.md)。
- **平台边界**：Linux/macOS GUI 尚未实现；Model／数据库三平台成功不代表三平台 GUI 可用。Android 既有设备证据不代表完整设备矩阵。
- **复验原则**：同 SHA 已有完整自动化证据直接复用；新修复按受影响范围验证并绑定输入。缺证据为阻塞／未完成，确认缺陷为不通过，不以 CI 或滚动 beta 标签替代现场验收。

## 2026-10-25 历史证据与当时未关闭门

- **提交前基线 c72ca99 的 CI**：[40156213233](https://github.com/SatoriTours/Leaf/actions/runs/40156213233) 实际运行 145 套共享 Nim 测试和 18 套 Windows Host 测试成功；Model／数据库三平台工作流最终成功。Windows runner 只扫描 `test_*.nim`，不意味着 `probe_*.nim` 或全部现场矩阵均已执行。
- **提交前基线发布 SDK**：[40156213210](https://github.com/SatoriTours/Leaf/actions/runs/40156213210) 的安装、重定位、Model CRUD／持久化及后台任务检查成功；对应 `beta.c72ca99dfad6`。安装说明见[这里](installation.md)。
- **GPT a2 历史：功能链路通过，列表视觉不通过**。用户批准修复入口后，普通用户 Windows Session1 实测安装／构建、`--database` 与 `--check`、第一行编辑／保存／同库重开、默认 pack、ZIP 搬迁从交付 exe 读回均实际 exit 0，未用 `--binary` 绕过；task Ready/lastResult 0、无残留进程。但实际截图中视口只呈现一行，滚到底仅见9995、末行9999不可见，不能以绿色句柄断言宣称整体通过。报告见 `~/.local/state/agent-artifacts/leaf/2026-10-25-windows-beta-acceptance/acceptance-gpt/report-a2.md`；a1 参数失败与前旧端未执行记录保留为历史。
- **提交前入口／列表修复验证**：入口阶段仅修改真实示例参数消费／显式转交，该阶段框架和已发布 SDK 未变。新增真实入口测试先4FAIL/1OK→5OK；官方本地146套/1235OK/0FAILED/5平台SKIPPED/exit0。之后仅更正测试 Windows 文件扩展名，定向5项与Windows codegen通过，不冒充Windows测试运行。随后获准修复列表：Win32 行子树保存视口 rect，用同空间 rect/clip 生成窗口区域。真实示例区域回归先运行1再0，失败恢复15项及两项变高事务／滚动失败回放程序均0，共享定向28项通过。原146套不扩称最终Win32快照全量结果；同一GPT的a3已完成审阅及独立视觉／交付复验：首尾五行和9999完整可见，非首行3保存／重开／邻行隔离、默认pack与搬迁同库读回通过；验收执行时原发布SDK未更新；本轮新提交及对应CI状态见[交付记录](progress.md)。
- **最新 a3 整体裁定：阻塞／未完成**。部分滚动裁剪未有效触发；设置SIF_POS不能当SIF_TRACKPOS，合成拖动补验后行几何仍未偏移，原断言失败。没有证据认定新产品裁剪缺陷，也不判该门通过。主控已核原始结果／hash及实际交付首尾图；报告为 `acceptance-gpt/report-a3.md`。主任务Ready/0、补验Ready/1，各app自然exit0，ownedProcesses=[]；停止原控制策略追加，不重跑已通过项。
- **资源与现场门**：cold USER/GDI 原 FAIL、完整 T2/T3/M4、真实系统 IME、物理键鼠、混合 DPI／多屏与完整辅助功能保持未关闭；自动消息、headless、代码生成和有限零分配围栏不能替代。
- **已知限制**：本轮去 GPUI 尚无整体独立验收；其他 GCC 编译兼容性及 macOS 偶发生成竞争未根治。必需项缺证据报告“阻塞／未完成”，不能用 CI 或预发布标签代替。

<details>
<summary>展开历史记录（含已退役渲染器，不适用于当前构建）</summary>

# 验证

## 当前汇总（2026-10-18）

当前代码基线为 `c207e48af8b33b8e6ecaf4dc1548ec9b2541b737`，已在主分支和远端；该提交的四条 CI 均成功，Linux CI 日志确认 102 个 Nim 套件、55 项 Rust 测试通过，四平台 GPUI SDK 已发布。固定运行链接、本次本地抽检和后续计划见[开发进度](progress.md)。

组件异步生命周期的最终修复已完成固定差异复核并合并，详见[合并验收记录](superpowers/reviews/2026-10-17-component-async-lifecycle-local-merge-verification.md)。本页下面按日期保留历史输入、失败与当时“待审查/未合并”的结论，不将历史测试数字改写为当前全量结果。

按用户授权重建的持久 Windows 环境已运行；首轮 12 通过/4 失败的日志保留。后续只修复一份测试文件的四处夹具/观察边界，框架实现未改；Session 1/elevated=false 下七套开发自测已完整运行，编译与运行退出 0，96 项通过、0 失败/跳过；独立功能验收者对相同 SHA 另行完整执行七套，也为 96/0/0，原会话已核对 diff 和原始证据，本批测试修复通过。固定输入与逐套结果见[环境记录](windows-environment.md)。后续[Windows 真实窗口补验](windows-window-validation.md)已实际完成 GPUI ABI1/2 的本批任务流程、键盘及在途关闭，native_forms 键盘与基础 UIA 也通过；随后发现并保留了自然完成态模型标签缺字、resize才恢复的失败；现已局部重绘修复，新增屏幕回归使Win32从七套变八套，开发及独立复验均为97/0/0、compile/run=0/0，修改源重建应用的原键盘路径和自然态截图通过。全量通用回归、macOS、系统 IME、跨屏 DPI 和完整辅助技术等仍未完成，不能由 CI/SDK 绿色替代；后续步骤见[Windows 验收](windows-acceptance.md)。

## 历史验证记录

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

## 最终整分支修复波（2026-10-17）

独立整分支审查 `0159895415eba0f3da8634fa858f83c1d84afdf4` 为 Needs fixes（C0/I6/M0），发现首次接受构造的 cleanup owner 丢失、headless 不关闭、高层 run 吞 owner、ABI1 error 丢 pending、私有旧库路径及 native 关闭观测无界等待。原 Task7 通过记录属于历史输入，不代替这些边界；本波以源码提交 `1a79640bbf4b69b0fdb02ba978612a61f88f8a1e` 一组修复，仍待一次固定差异的独立 scoped 复核。

共用 `RuntimeCleanupError` 接通构造/launcher ownership，保留原错误、status 和一次 close 尝试；headless 所有普通出口关闭 Runtime，继续不泵/不等任务；run 传播 pending Runtime/Host，有 out 的 status0 仍须检查 owner 并 ordinary retry。各 I1–I6 均有独立保存的真实 RED→GREEN。受影响 22 个 Nim 套件实际 EXIT0；后续公开 launcher 最终 10 项单独重跑替换该套件早期9项，合并口径为220个 OK标记、0 FAILED，默认真实旧库integration一项SKIPPED。显式原旧库integration另行双ABI验证实际 SHA `63ef5b8104253b14bfcda7dca45fe84cc8a8e3ce8840c1f2555cfdfec63af9a1` 和 startup 拒绝通过，普通兼容套件使用可构建双 ABI fixture。

实际 worker 回归证明一个已 claim handler scope-exit 失败不重放、另一 worker 在途/入场拒绝保持 pending、恢复后只交付一次；Rust GPUI TestAppContext 验证合法 error+pending 后唯一 root timer 无额外 input/notify/二次 arm 自动继续并 idle 停止。两边分别测试，不冒称完整 Nim+GPUI 错误窗口。无 Snapshot 的合法响应没有虚构 Snapshot，transport/畸形响应单独拒绝。native probe 的共享 deadline、立即 defer close、挂起进程组和 FD 回收均实际验证；清理沿既有最多500ms TERM grace，最终测试预算仍可使旧无限轮询逻辑真实 RED。

本波实际 Rust workspace55测试、fmt、clippy、production新库构建及 ABI161 均 EXIT0；没有把旧Rust52复用为新输入。新 production 库 default features/dev debug=0，SHA `353e5ba4d40bdeafe4b373dc3bee35f2522d796918ceb5b8ddcb695df3e8d545`。Windows现有task/host两套及高层native入口只做Nim语义/C生成，未编译C SDK、链接PE或运行Windows。

新 SDK 以真实 `--commit 1a79640bbf4b69b0fdb02ba978612a61f88f8a1e`、新CLI/production库重新打包，包 SHA `0997f5ebf85e9d93dad4bf575cec6440d472288e053212861d7fa91d421fa43c`，仓库外 `/tmp/Leaf SDK 最终修复 搬迁 $ 1a79640b/leaf-sdk` 实际解包，210 个源码/头文件一致。清五项覆盖后 doctor、普通 build、完整 migration/CRUD/持久化 smoke、任务实际“后台完成”和公开 launcher 清理/重试 fixture 全部 EXIT0；后者断言重复headless/check/help/error退出的 State/dispose/线程回基线、workCalls=0，以及out/default拒绝后retry。Nim/source来自SDK自身，系统GCC与OS依赖库路径仍保留。旧三包不覆盖，a3包仅历史通过。

本波没有重跑官方100套/4套或历史四native矩阵，也不把旧成功称本波新输入；本波具体argv/exit/输入/日志、每项复用差异和完整报告位于 `target/verification/component-async-lifecycle/final-fix-0159895`，空间外备份 `/tmp/leaf-component-async-final-fix-0159895`。所有旧报告与失败证据保留，协调专门verification不在本提交范围。真实Windows/macOS/PE/IME/DPI、内存工具/长期RSS、线程创建失败注入、原独立Snapshot-export/diagnostic异常/联合Snapshot+error/动态wrongthread仍NotRun；未采样GPU帧/FPS/renderer。不得据此宣称全平台或系统零泄漏；没有合并、推送或归档。

</details>
