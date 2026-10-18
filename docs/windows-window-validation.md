# Windows 真实窗口补验（2026-10-18）

本页保留修复前的[持久 Windows 环境](windows-environment.md)补验及真实失败，并记录后续修复。**当前结论：GPUI ABI1/ABI2 本批任务流程通过；原生文本刷新缺陷已作最小修复，开发自测与独立功能验收均为 8 套、97/0/0；重建应用的自然完成态文字完整。P1 与 A2/H 门仍未全部关闭。**

下面“身份与固定输入”至“修复前不通过”记录初始窗口补验：当时未改框架，确有视觉失败。后续代码及输入变化单列于“重绘修复与独立验收”，不将旧 SDK/EXE 当作已含修复的产物。

## 身份与固定输入

- Windows 11 Enterprise Evaluation build 26300；LeafTester，Interactive/Limited，Session 1，elevated=false。该账户仍属管理员组，不代表完全非管理员账户矩阵。
- 使用 `c207e48af8b33b8e6ecaf4dc1548ec9b2541b737` 的样例和同版本 Windows SDK，Nim 2.2.6、MinGW GCC 11.1.0。SDK 可用预编译 GPUI DLL，不必为这些窗口安装 Rust/Cargo。
- GPUI 程序 SHA256：`8a0fa4411bbb33de385763d379d573e51f9f3c30e1e96e02d5edb6bc81215df4`。
- native_forms 程序 SHA256：`792f8a9f9342798cc9803279940774439e2815066bbbc99971fa229c85b133f5`。
- SDK DLL 与 staged DLL SHA256 均为 `10049a113d3ccd3fe3721aca9653f8ed31bdddecb2cf4476f2e6573690485dfc`。
- 每个程序均取得真实 HWND 和前台；实测窗口 DPI 为 96。未改变系统缩放、语言或安全设置。
- 本轮窗口程序没有使用此前未提交的测试 overlay；该 overlay 仅影响测试文件，不影响产品实现。旧基线 CI 仍不能代表后续修复已通过对应提交的远端 CI。

## 执行方式与原始证据

持久根目录为 `/home/jimxl/.local/share/leaf/windows-acceptance`。验收使用其中 `shared/bootstrap/` 的 PowerShell 客户端，经 Limited 交互计划任务执行，不在 SSH Session 0 中冒充桌面测试。

| 轮次 | 客户端脚本 / 计划任务 | 证据目录（相对持久根目录） |
| --- | --- | --- |
| 初始构建失败 | 首版 window probe | `shared/evidence/p1-window-probe/` |
| 构建、首帧、窗口与 UIA 基础观察 | `p1-window-probe.ps1` / `LeafP1WindowProbe2` | `shared/evidence/p1-window-probe2/` |
| 首次完整交互 | `p1-interactions.ps1` / `LeafP1Interactions` | `shared/evidence/p1-interactions/` |
| 更正客户端读值后的完整交互 | `p1-interactions2.ps1` / `LeafP1Interactions2` | `shared/evidence/p1-interactions2/` |
| 原生文本刷新专项复现 | `p1-native-visual.ps1` / `LeafP1NativeVisual` | `shared/evidence/p1-native-visual/` |

主要脚本调用形式为 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\LeafTests\bootstrap\p1-interactions2.ps1`，执行身份由上述计划任务限定。脚本拒绝覆盖已有证据；复测须先指定新运行目录和任务名，不直接覆盖或重用旧结论。每个证据目录附 SHA256 manifest，保存实际脚本、结果和日志；窗口案例另有树快照、UIA 数据及原始 PNG。原始 ready 凭据保留在受控本机证据内，不写入本报告。

首次构建因验收生成的 leaf.json 缺少 identifier/version 失败，补齐的是临时项目配置，不是放宽框架配置校验；原失败日志保留。首次交互的 native 读值错误也保留，见下节。

## GPUI ABI1/ABI2：本批流程通过

两个案例分别以 `LEAF_GPUI_ABI=1`、`2` 启动 `examples/component_tasks.nim`，校验首帧 ready 的协议、凭据匹配和 PID，再通过 UIA Invoke 操作真实按钮。自动完成等待阶段只读取诊断输出，不额外点击、注入框架回调或轮询 UI 来驱动任务。

两种 ABI 均实际完成：

1. 加载后无后续点击自动完成；第二轮观测约为 882/869ms，含工具轮询开销，不作为性能基准。
2. 模拟错误后重试成功。
3. 离开页面取消在途任务，返回后状态保留。
4. 隐藏继续的任务在隐藏期间完成，返回可见结果。
5. 离开销毁，不交付已销毁实例的结果，返回后重建实例。
6. 真实 OS 键盘 Tab、Shift+Tab 移动焦点，Space 激活已聚焦按钮。
7. 新请求在途时关闭；关闭后的结果数不增长，最终 dispose 次数符合断言，进程正常退出 0。

`p1-interactions2/probe-result.json` 中两个案例均为 `ready=true`、`workflow.passed=true`、`finalLifecyclePassed=true`、exitCode=0；逐项断言和完整 stdout 可查。自然完成态截图可见“main:后台完成”，原会话实际查看了两种 ABI 的图片。

UIA 各观察到 8 个元素，按钮具有 Button/Invoke 语义；这里没有检验完整名称质量、状态播报、禁用态矩阵或屏幕阅读器体验，也不是所有组件/缓存/路由输入组合的 Windows 矩阵。

## 原生表单：键盘、读值与基础 UIA 通过

`examples/native_forms` 的实测步骤：Ctrl+A 输入 `Leaf-keyboard`，Enter 恰好提交一次，Tab 到“接收通知”，Space 取消勾选，Shift+Tab 回到 EDIT；正常关闭，退出 0。

测试客户端显式注册 .NET 自带的 Win32 client-side UIA providers 后，实际观察到 1 个 Edit、2 个 CheckBox，五个应用按钮分别具有 Button/Invoke 语义。总计 8 个 Button 包含三个窗口标题栏按钮，不能把它们都算成应用按钮。Edit 的 ValuePattern 和复选框的 TogglePattern 值均与真实键盘操作一致。

两个客户端观察问题已区分，未当作产品缺陷：

- 初始客户端仅观察到 Pane；注册 stock-Win32 代理后出现正确角色和模式。这是客户端初始化差异，不是补写了 Leaf 的辅助功能实现。
- 跨进程 GetWindowText 读到旧 caption `Leaf 原生控件 😀`，不能据此判定 EDIT 仍为旧值。改用 WM_GETTEXT，并另读 UIA ValuePattern；两者和 accepted 模型均为 `Leaf-keyboard`。原错误、旧缓存值与更正后的三方观测均保留在 `edit-measurement.json` 等证据中，未削弱模型/原生值一致性要求。

以上只批准实际检查的键盘、角色与值，不批准 Narrator、语义名称质量、全部原生表单操作或整个辅助功能 H 门。

## 修复前不通过：原生文本更新后需要 resize 才完整显示

在相同未修改的 native 程序上连续观察到可见文本刷新问题：

1. 执行上述输入、Enter、Tab/Space/Shift+Tab；accepted 模型和 EDIT/UIA 值正确。
2. 模型标签的 WM_GETTEXT 已为 `模型：Leaf-keyboard`，但完成态屏幕上中间字符缺失，近似只见“模型：”和末尾 `d`。
3. 不再发 UI 事件，等待 2 秒，原始截图仍缺字。
4. 同一窗口仅增大宽高各 20 像素，文字才完整显示。没有修改模型、重启程序或改变 DPI。

专项证据位于 `shared/evidence/p1-native-visual/native-forms/`：`native-labels-after.json`、`keyboard-result.png`、`keyboard-settled.png`、`keyboard-resized.png`。原会话实际逐张查看，明确区分了自然完成态和 resize 后的诊断状态。**不能拿 resize 后的完整截图替换原失败、宣布原生视觉验收通过。**

该次补验结束时，缺陷已复现而具体根因尚未裁定；未依据 API/树快照正确排除绘制问题，也未猜测 WinAPI flag 就改框架。随后按最小复现、边界追踪、失败回归及最小修复顺序推进，结果如下。

## 重绘修复与独立验收：通过（仅本批 bugfix）

### 根因与最小修改

在本机 Windows build 26300 的 trace 中，Leaf 设置标签 `WM_SETTEXT` 后 update region 为空；随后的布局/窗口区域增长只令新增的窄条无效，于是仅新暴露字形被绘制。空闲等待不会补画无待绘区域的旧内容。该判断限定于本次实际路径，不泛化为所有 Windows 静态控件均不自绘。

仅在 `src/leaf/backends/win32/backend.nim` 的非 EDIT 文本分支中，当文字真实改变且 `SetWindowTextW` 成功后，调用一次 `InvalidateRect(control.window, nil, 1)`，明确使该控件完整客户区失效；失败沿用 `nativeError`。`api.nim` 和 `calls.nim` 增加相应声明/可注入调用。共三文件新增 4 条有效代码及 3 行注释，没有改 Runtime、Host、布局或输入契约，没有每 tick 全窗刷新，也没有用验收客户端重绘代替产品修复。

新增 `tests/windows/test_native_redraw.nim`：真实 EDIT/SendInput/消息泵，输入后静置 2 秒，从屏幕 DC 采集自然态像素；断言没有大块缺字、文字抵达测量宽度，以及自然态等于同一控件自身全量重绘。强制绘制 oracle 只在自然态捕获之后执行，不能修复被测的旧图。测试要求未遮挡的解锁交互桌面，输入有 12 秒超时。

### 固定输入与 RED/GREEN

所有运行以固定 c207e48 归档为底，在独立目录叠加下列文件并复核 hash；固定源码与共享 SDK 未改。最终回归文件 SHA256 为 `503dbf1e1f68b32e4af650b38717c29ef578cd2bded9787511f3d2d7d10be7b4`；原 `test_component_tasks.nim` 仍为 `42d51442134f22470502858db8377218b251bda2b3efa1d6b20de7a954244be9`。

| 修改实现 | SHA256 |
| --- | --- |
| `api.nim` | `ea498514d3315f8df32ceb408f341cfb8fee15377bd57467a5f5fd096981fa07` |
| `backend.nim` | `974675bde4ff8e8e427a7ca271cad7b5f543869a122c08f6cd59fb9bc6a722f7` |
| `calls.nim` | `6d8b2d32fcbd5d5554f8bd90ab5015fc93ac8a55dd9e0c44937a0c94a9c63f80` |

证据目录均相对持久根的 `shared/evidence/`：

| 阶段 | 目录 | 实际结果 |
| --- | --- | --- |
| 最终回归 RED，同测试无三个产品 overlay | `redraw-final-red/` | 值检查通过，但新回归缺字空洞 72px、自然态与完整绘制相差 348 像素；run=1，16 OK/1 FAILED 后停止 |
| 开发最终完整 GREEN | `redraw-final-green/` | 原 7 套加新回归共 **8 套，97 OK/0 FAILED/0 SKIPPED**，compile/run=0/0 |
| 应用级旧源码对照 | `app-baseline-1/` | 同脚本/工具链重建，缺字空洞 73px，自然态仍失败 |
| 开发侧修改源码应用 | `app-verify-6/` | 重建 EXE，17 项检查符合预期，自然态完整 |
| 独立完整复验 | `redraw-review-final/` | 同五个 overlay，**8 套、97/0/0**，compile/run=0/0 |
| 独立重建及真实键盘复验 | `redraw-review-app/` | discovery/windres/build=0/0/0，应用正常退出 0，无强制回收；17 项检查符合预期 |

开发与独立运行均为 Session 1/elevated=false。独立结果的 17 项含 14 个通过标志及三个数值指标：控件宽 106、最大墨迹间隔 4、最右墨迹列 104，不将数值误说成布尔值。EDIT/accepted 模型/UIA 值为 `Leaf-keyboard`；标签包含 `模型：` 前缀，全文为 `模型：Leaf-keyboard`。Enter 恰好提交一次，Tab/Space/Shift+Tab、焦点还原、checkbox 值和正常关闭均保持。

验收者与原会话均实际查看独立运行的 `redraw-review-app/guest/redraw-review-app/native-forms/keyboard-natural.png` 和 `model-label-natural.png`，完整文字已在 fresh/resize 对照之前显示，不依赖 resize。独立输入证据分别见套件的 `inputs.json` 和应用 `probe-result.json` 内的 `sourceHashes`、构建参数；原会话核对了当前文件 hash、原始 97 项输出、截图和实际 diff，没有再重复全套。

开发报告与独立报告分别保存在本地 `target/verification/windows-native-redraw-2026-10-18/developer-report.md`、`functional-review.md`。独立结论为“通过（仅本批 bugfix）”，未发现阻断问题。Linux 相关 31 项为开发者实跑、验收者日志复核，不称独立重跑；未补跑 102 套通用回归或 Rust。所有窗口活动已结束，计划任务 Ready；保留 Windows 容器、旧失败和过程日志。

### 本机复验入口

控制器位于持久根 `control/`；与本页早期 p1 客户端分开保存。官方 runner 未改，它动态扫描新增文件，因此当前是 8 套而非历史 7 套。选择新 tag 串行运行，勿覆盖已有证据：

```sh
python3 /home/jimxl/.local/share/leaf/windows-acceptance/control/run-win32-case.py \
  --tag UNIQUE-REDRAW-TAG \
  --overlay-file /home/jimxl/projects/leaf/tests/windows/test_component_tasks.nim \
  --overlay tests/windows/test_native_redraw.nim=/home/jimxl/projects/leaf/tests/windows/test_native_redraw.nim \
  --overlay src/leaf/backends/win32/backend.nim=/home/jimxl/projects/leaf/src/leaf/backends/win32/backend.nim \
  --overlay src/leaf/backends/win32/calls.nim=/home/jimxl/projects/leaf/src/leaf/backends/win32/calls.nim \
  --overlay src/leaf/backends/win32/api.nim=/home/jimxl/projects/leaf/src/leaf/backends/win32/api.nim
```

应用级入口是同目录 `run-guest-script.py --tag UNIQUE-APP-TAG --deadline-min 20 --script <持久根>/shared/bootstrap/verify-native-redraw.ps1 --prepare-source`，另附上面三个产品文件的 `--overlay`，重新构建后执行原键盘路径。完整实际命令见上述报告。控制器每次解包/叠加到新的运行目录；不要直接修改固定源码或 SDK，也不能用基线 beta.c207e48af8b3 中未包含此修复的 SDK EXE 冒充新代码验证；后续 SDK 须另核对版本、提交与产物。

## 阻塞／未完成项

| 项目 | 当前证据与限制 |
| --- | --- |
| 全量通用回归 | 未执行 102 套；guest 没有 Git、Cargo/Rust 和完整 GPUI 源码开发依赖。本批 SDK 窗口成功不等同全量通过 |
| 中日文真实 IME | 未执行。用户语言仅 en-US/US keyboard；zh-CN、ja-JP Language.Basic 均 NotPresent，记录在 `p1-interactions2/ime-prerequisites.json`；本轮未安装或启用语言组件 |
| DPI 与物理混合双屏 | 仅实测 96 DPI；没有 150%/200%、实际跨不同 DPI 物理屏幕或同窗口切换证据，未用消息注入冒充 |
| 完整辅助技术体验 | 仅基础 UIA 与键盘子集完成；Narrator/Accessibility Insights、状态播报及完整焦点/禁用态检查未完成 |
| 其他平台与长期项 | macOS、完全非管理员账户、长期内存与硬件性能未补验 |

初始 p1 窗口补验是原会话实际执行；后续重绘修复单独经过了上述独立功能验收。此前七套四项测试修复与本次八套重绘修复的输入、结果分别保留，不改写历史失败。本批 bugfix 通过不关闭表中缺证据项。本报告绑定上述验收输入 hash，不以旧 SDK/旧 CI 替代后续提交的结果。GitHub 推送及自动 SDK 构建须另核对实际提交和对应 Actions；Windows 容器保留运行。
