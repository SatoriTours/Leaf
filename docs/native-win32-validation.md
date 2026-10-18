# Windows 原生表单开发与验收

当前代码/CI 状态见[开发进度](progress.md)，当前七套 runner 的身份、日志和平台验收步骤见[Windows 当前版本验收](windows-acceptance.md)。下文日期化的五套/77 项等数字保留为历史开发证据，不表示当前源码已在 Windows 全量重验。2026-10-18 新持久环境首轮的 12 通过/4 失败已保留；修正四项测试夹具后，七套非提权交互开发自测及独立复验均为 96 通过/0 失败，详见[环境记录](windows-environment.md)。这不批准完整 A2 平台支持或关闭 H 门。

同日后续[真实窗口补验](windows-window-validation.md)：GPUI ABI1/2 本批任务流程、native_forms 键盘与基础 UIA 通过，期间发现原生模型标签缺字、resize才恢复的视觉失败；现已补局部客户区失效与屏幕回归，八套97/0开发自测及独立复验通过，重建应用的原键盘路径自然态完整。原失败保留。真实 IME、物理混合双屏和完整辅助技术 H 门仍未关闭；下方历史 NotRun 表述保留其日期范围。

## 当前范围

A2 提供 Windows x64 原生表单后端：column、row、text、button、input、checkbox、toggle、progress、tag、separator、spinner。toggle 使用系统 checkbox 语义。默认后端仍为 GPUI；项目可在 leaf.json 设置 `"backend": "native"`，命令行 `--backend` 优先。

原生后端支持有限 DIP 线性布局、系统字体测量、稳定控件身份、输入事件排队、受控值结算和递增 `resetToken`。普通同值响应保留编辑选区；组合输入期间延后冲突模型；显式 reset 在接受模型后的安全 turn 取消组合并设置最终值。平台句柄不进入 DSL、JSON 或业务事件。

颜色、字体等装饰受 capability 策略约束；required 能力不足在挂载前拒绝，compatible 可报告装饰降级。A2 不提供列表、导航、Canvas、Android、原生打包或发布能力。`leaf pack --backend native` 会明确拒绝。这些属于后续阶段，不能据此宣布原生迁移全部完成。

## 构建和运行

需要 Windows x64、Nim 2.2.6+、MinGW GCC 与 windres。在项目根目录用 PowerShell 执行；将工具目录加入 PATH，或把 NIM 设置为 nim.exe 的完整路径。

```powershell
nim c --out:target/leaf.exe src/leaf_cli.nim
./target/leaf.exe doctor --backend native --target windows
Set-Location examples/native_forms
../../target/leaf.exe build --backend native --target windows
../../target/leaf.exe run --backend native --target windows
```

`examples/native_forms/leaf.json` 已选择 native，因此可省略后端参数。原生构建不调用 Cargo、不构建或复制 leaf_gpui.dll，主 EXE 嵌入 Common Controls v6 和 PerMonitorV2 manifest。

纯检查可在支持的主机运行，不加载窗口后端：

```sh
cd examples/native_forms
leaf --check
leaf --headless
```

这里的 `leaf` 指加入 PATH 后的 CLI；命令从当前目录向上查找 leaf.json，无需项目路径参数。native 窗口构建要求 Windows x64；未配置跨平台编译会明确报错。native 不支持 `--watch`。已构建的原生程序也可使用 `--check` 或 `--headless`。

## 自动化验证

Windows 根目录执行：

```powershell
nim c -r --threads:on --path:src scripts/test_win32.nim
if ($LASTEXITCODE -ne 0) { throw "Windows native tests failed" }
```

runner 自行生成并链接每个测试 EXE 的 manifest；无需预先生成 `.o`。它动态扫描 tests/windows/test_*.nim，2026-10-18 c207e48基线共有七个套件，包含新增的组件宿主与任务集成；覆盖宿主 ABI/线程/关闭、真实 stock HWND、prepare/discard/restore 与失败资源重试、系统字体测量/缓存、事件来源隔离、受控输入及组合消息、完整 native/headless 构建和应用启动/关闭、PE manifest、复杂输出路径及 GPUI 隔离。非 Windows 执行该 runner 输出 NotRun、退出码 2，不能作为 Windows 通过证据。

本批新增 `test_native_redraw.nim`，当前修复输入为八套97项，开发与独立验收均97/0/0；它需解锁、控件未遮挡的交互桌面，真实屏幕自然态像素不能由 caption/模型或强制重绘后的对照代替。具体输入与完整日志见[真实窗口补验](windows-window-validation.md)。上述七套/历史数字仍按各自基线保留。

平台无关回归：

```sh
NIM=/path/to/nim /path/to/nim c -r scripts/test.nim
```

自动化 `WM_IME_*` 消息覆盖适配器时序；它不证明真实 IME 或辅助技术体验。失败注入仍调用实际系统 API，只在指定调用点失败，不用假 HWND 替代实际资源。

## 真人验收清单（H 门）

2026-10-11 主分支集成回归：合并数据库迁移功能后，Linux 全量 70 个套件通过，707 项成功、0 失败，5 项 Windows 专用检查跳过。合并后的 CLI 通过 Windows x64、threads:on 的 Nim 静态检查；本次集成未重跑真实 Windows 自动化，沿用开发版已有证据。CLI 保留当前目录项目解析，并接入 `build/run/doctor/pack` 的后端选择；原生项目 `--check` 和拒绝 `--watch` 有集成回归。Linux GPUI 测试使用本机已有的 `/tmp/mui-display/usr/lib` 依赖目录。

在解锁的普通用户桌面运行同一个 native_forms 示例，记录 Windows/Nim/GCC 版本、用户令牌、输入法版本、实际 DPI、步骤和结果。开发 VM 的 elevated 测试不能代替普通用户验收。

0. 使用“切换输入模式”分别选择 echoValue、rejectValue、trimValue；“组合期间更新冲突模型”开启冲突路径。“尝试失败候选并重置”应被校验拒绝，旧界面保留；随后“恢复候选”以原 token 接受并执行重置。该示例故意保留业务状态修改，以核对 UI 发布和业务回滚的边界。
1. 使用 Tab / Shift+Tab 在输入、checkbox 和按钮间移动；Space 切换 checkbox，Enter 提交输入。观察计数只增加一次，窗口关闭干净。
2. 使用 Microsoft Pinyin 和 Microsoft Japanese IME 分别输入、候选选择、确认及取消；组合期间点击重置，确认取消后模型和 EDIT 值一致。同一 resetToken 不重复取消，下一 token 可再次重置。
3. 输入中文、日文和 emoji，改变光标与选区，执行同值响应；选区和控件身份稳定。业务拒绝/格式化后显示最终模型；快速连续输入不被较早事件覆盖。
4. 在两个实际不同 DPI 的屏幕之间移动窗口，调整大小、切换系统主题和字体；记录客户端 DIP、像素边界、裁剪和字体变化。不得用向同屏发送 WM_DPICHANGED 代替此项。
5. 使用 Narrator / Accessibility Insights 检查名称、角色、值、禁用状态、焦点顺序和键盘操作；核对 checkbox/toggle 的系统语义。

任何一项尚未执行都记 NotRun，并保留具体限制；全部 H 项完成并通过独立验收后才可批准 A2 平台支持。

## 本轮自动化证据（2026-10-11）

实际 Docker Windows 11 开发桌面（Session 1，elevated）运行永久 runner，五套 77 项全部通过，退出码 0；运行编号 `3f7fd70997054bf0a8c43300427d2b7d`。其中包括真实 HWND、系统字体和主题、失败清理重试、输入结算与 reset、实际 ABI、移动 Unicode/空格/`$` SDK 路径构建、PE manifest、加载模块及表单启动关闭。当前环境为 Nim 2.2.6、MinGW GCC 16.2.0；链接器报告多 manifest 合并诊断但返回 0，应用实际 resource XML 和 Common Controls v6 检查通过，保留原始日志。

Linux 全量 57 套、511 项通过，5 项已有 Windows 环境测试跳过；另执行 headless 二进制 ldd/nm、链接指令和生成 C 检查，未引入 GPUI/Vulkan/Win32 图形依赖。

完整五套之后，新增恢复身份回归在同一真实 Windows 环境复跑 input 套件，15 项全部通过（运行编号 `d017074ebad94982be7609075e3302c2`）；合计覆盖 78 项。该测试将旧 ID/cookie 与当前真实 HWND 组合，并保留实际旧绑定事件，验证 restore 后隔离；未执行强制操作系统数字句柄复用的压力测试。

这批结果仅作为开发版交付证据。上方 H 清单仍全部 NotRun，后续单独验收；不能据此批准普通用户桌面、真实 IME、跨屏 DPI 或辅助技术支持，也不表示 A3/Android 已完成。


## 普通用户 Windows 实测后的修复（2026-10-11）

用户在 Windows 11 普通桌面、150% DPI、Nim 2.2.6、官方 MinGW GCC 11.1.0 的实测中，通用/发布套件最近结果为 63/70 通过、7 套失败，Win32 为 4/5 通过、1 套失败。该结果包含 LF 副本复测，不能称为一次全量成功。此前 elevated 开发桌面证据仍是历史记录，不能代替这次普通用户结果。

本轮修复涉及 Windows discovery 的失败 BuildJob、模型编译诊断完整捕获、watch 的可移植编译屏障、迁移符号链接 fixture 的能力检测、DPI 尺寸断言，以及仓库内 Windows 10 头文件与 LF 约束。DPI 测试从实际外框像素增大并保持窗口位置，验证实际客户端像素与 DIP 一致；同屏消息仍不作为跨屏证据。无创建链接权限时，只跳过链接专属测试，普通路径与元数据验证继续执行。

修复后的 Windows 自动化、100%/150%/200% DPI、MinGW 11、普通用户链接权限矩阵仍需在真实 Windows 运行并记录。Linux 回归和 Windows 目标 Nim 静态检查均不能替代这些验收；真实 IME、双屏不同 DPI、Narrator/Accessibility Insights 的 H 门保持待验。

本轮 Linux 同一候选代码的完整 `scripts/test.nim` 回归：70 套，710 项通过、0 失败、5 项平台相关跳过，进程退出 0。日志与摘要保存于主目录 `target/nim/windows-report-fixes/`；包含 CRLF 红绿对照、两种 checkout 回归、无 Git 的 17 套 model 回归及 11 项 Windows 目标静态检查。上述结果不替代真实 Windows 运行或独立验收。
