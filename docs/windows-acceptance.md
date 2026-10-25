# Windows 验收步骤与历史

> **当前范围（2026-10-24）：** Windows 默认使用系统原生控件；旧渲染桥接及其工具链已退出当前实现，Linux/macOS GUI 暂缓。下面保留旧快照的实际命令、失败和证据，**不是当前依赖安装说明，也不能作为本轮验收结果**。本轮进展见[开发进度](progress.md)，当前命令见[源码开发](development.md)。

当前验证分为共享 Runtime/数据库/工具链测试，以及真实 Windows 默认入口、原生控件、打包和 SDK 检查。headless、代码生成和历史成功不能替代新的 Windows 运行证据；视觉、IME、物理输入、混合 DPI 与未关闭资源门分别报告。

<details>
<summary>展开历史记录（含已退役渲染器，不适用于当前构建）</summary>

# Windows 当前版本验收步骤

准备日期：2026-10-18。当前代码基线及已取得结果见[开发进度](progress.md)；本页是执行步骤，不是 Windows 已通过报告。示范命令未逐字全量执行；本轮重建环境及实际命令/结果以[持久环境与首轮记录](windows-environment.md)为准。

## 前置条件与停止边界

- 使用已获授权、已解锁的 Windows x64 桌面。优先普通用户，不提升权限来绕过失败；elevated VM 结果必须单独标记，不能关闭普通用户验收门。
- 已有 Nim 2.2.6+、MinGW GCC/windres、Git；本轮不安装工具、不改 Nim/系统配置、不调整全局 DPI 或链接权限。
- 从仓库根目录执行。记录实际 HEAD，确保产品/测试/构建输入无未提交或未跟踪变更；文档变更可以保留。代码或工具链变更后另建证据目录，不复用旧运行的通过结论。若验收未提交修复，须像[本批补验](windows-window-validation.md)那样使用固定归档加逐文件 overlay/hash 的独立目录，不能声称原始归档没有变。
- 先执行不依赖 GPUI 的 Win32 runner。全量通用回归另需现成的 Rust/Cargo、兼容 GPUI DLL、SQLite/HTTPS 等依赖；缺依赖记 blocked，不把环境失败当作产品行为 RED。
- 测试失败或挂起时停止，保留日志和仍需回收的测试进程信息，不强行将结果改成通过、不静默换成管理员执行。

## 1. 记录身份与工具链

在同一个 PowerShell 窗口、仓库根目录执行：

```powershell
$ErrorActionPreference = 'Stop'
$head = & git rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source HEAD' }
$head = $head.Trim()
$inputs = @('src', 'tests', 'scripts', 'include', 'crates', 'Cargo.toml',
            'Cargo.lock', 'config.nims', 'leaf.nimble', '.gitattributes')
$dirty = & git status --porcelain=v1 --untracked-files=all -- $inputs
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect source state' }
if ($dirty) { throw "Uncommitted source inputs; preserve them before testing:`n$dirty" }
$nim = (Get-Command nim -ErrorAction Stop).Source
$gcc = (Get-Command gcc -ErrorAction Stop).Source
# 产品优先复用同一 GCC 目录中的 windres，其次才是 PATH。
$windres = Join-Path (Split-Path $gcc) 'windres.exe'
if (-not (Test-Path -LiteralPath $windres)) {
    $windres = (Get-Command windres -ErrorAction Stop).Source
}
$evidence = Join-Path (Get-Location) (
    'target/verification/windows-' + $head.Substring(0, 8) + '-' +
    (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $evidence -ErrorAction Stop | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
@{
    head = $head
    os = [Environment]::OSVersion.VersionString
    powershell = $PSVersionTable.PSVersion.ToString()
    user = $identity.Name
    elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    session = $env:SESSIONNAME
    nim = $nim; path_gcc = $gcc; candidate_windres = $windres
} | ConvertTo-Json | Set-Content (Join-Path $evidence 'environment.json') -Encoding utf8
Get-FileHash -LiteralPath @($nim, $gcc, $windres) -Algorithm SHA256 |
    Export-Csv (Join-Path $evidence 'toolchain-sha256.csv') -NoTypeInformation
& git status --porcelain=v1 --untracked-files=all |
    Set-Content (Join-Path $evidence 'git-status.txt') -Encoding utf8
foreach ($tool in @($nim, $gcc, $windres)) {
    & $tool --version >> (Join-Path $evidence 'toolchain-versions.txt') 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Tool version query failed: $tool" }
}
```

另外记录 Windows build、实际显示器/缩放、输入法版本、桌面是否交互可用。`environment.json` 的 OS 字符串不能替代显示器实测。这里的 GCC/windres 只是 PATH 候选；runner 从 Nim 生成的构建命令解析实际 GCC 并选择资源编译器，需保留其 cache/JSON 和完整日志，不能仅凭 PATH 推断实际工具链。不要把登录凭据写入证据。

## 2. 运行当前全部 Win32 套件

```powershell
$previousNim = $env:NIM
$previousOut = $env:LEAF_WIN32_TEST_OUT
try {
    $env:NIM = $nim
    $env:LEAF_WIN32_TEST_OUT = Join-Path $evidence 'win32-suites'
    $runner = Join-Path $evidence 'test_win32.exe'
    & $nim c --threads:on "--out:$runner" scripts/test_win32.nim `
        *> (Join-Path $evidence 'win32-compile.log')
    $compileCode = $LASTEXITCODE
    "compile=$compileCode" | Set-Content (Join-Path $evidence 'win32-exit.txt')
    if ($compileCode -ne 0) { throw "Win32 runner compile failed: $compileCode" }
    & $runner *> (Join-Path $evidence 'win32-run.log')
    $runCode = $LASTEXITCODE
    "run=$runCode" | Add-Content (Join-Path $evidence 'win32-exit.txt')
    if ($runCode -ne 0) { throw "Win32 runner failed: $runCode" }
} finally {
    $env:NIM = $previousNim
    $env:LEAF_WIN32_TEST_OUT = $previousOut
}
```

runner 动态扫描 `tests/windows/test_*.nim`，c207e48 基线有 7 套：`test_component_host`、`test_component_tasks`、`test_win32_controls`、`test_win32_host`、`test_win32_input`、`test_win32_measure`、`test_win32_toolchain`。本批新增 `test_native_redraw` 后，当前修复输入是 **8 套、97 项**，应出现 `Passed all 8 Windows host test suites` 且退出 0；七套/96项只属于此前输入。新增屏幕像素回归须使用解锁、控件未遮挡的交互桌面，不用 Session 0 代替。摘要不能替代完整逐套日志。核对真实 ABI 断言、timer、安全 turn、busy/hook、迟到换绑、Runtime/Host 双 owner 与失败重试，不只检查编译成功。

非 Windows 上，直接运行已编译 runner 必须返回 2 并打印 NotRun；`nim c -r` 外层可能把子进程非零包装为 1。这两种结果都不是 Windows 行为验收通过。

## 3. 通用回归与 GPUI 任务窗口

确认现成开发链和实际 GPUI DLL 后，按[开发说明](development.md)执行 `scripts/test.nim` 全量；当前基线动态发现 102 个套件，逐套失败/跳过必须保留。记录 `NIM`、Cargo/Rust 版本、DLL 的绝对路径和 SHA256，以及编译/运行各自退出码。需要 `LEAF_GPUI_LIBRARY` 覆盖时只在本次进程环境设置，结束后还原。不要将 `--release-only`、`--model-only` 或 SDK smoke 成功写成全量通过。

另外运行 `examples/component_tasks.nim`，分别使用 ABI1/ABI2，确认加载无需后续点击即可完成、错误后重试、离开取消、隐藏继续后返回、离开销毁和在途关闭。真实 GPUI 窗口与 Win32 原生套件是不同验收路径，不能相互代替；Linux 专用 Xvfb/xdotool harness 不能当成 Windows 自动化入口。

2026-10-18 已通过现成 SDK 实际完成上述两种 ABI 的本批任务窗口检查，并执行键盘和 UIA 子集；这不要求补齐 Cargo 源码开发链，也不代表 102 套通用回归通过。实际步骤、原生视觉失败及随后修复的独立通过结果见[真实窗口补验](windows-window-validation.md)。

## 4. 普通用户与真人 H 门

使用 `examples/native_forms` 和[既有 H 清单](native-win32-validation.md#真人验收清单h-门)，分开记录：

| 项目 | 必需证据 | 当前状态 |
| --- | --- | --- |
| 普通用户自动化 | 当前全部 Win32 套件；适用的通用回归与跳过原因；权限/工具链身份 | 当前修复输入八套97/0非提权开发自测及独立复验通过；完整账户/通用套件矩阵未关闭 |
| 任务生命周期 | native timer 与两种 GPUI ABI 的完成、取消、关闭、失败重试；窗口消失与进程退出分列 | 当前Win32八套通过；GPUI ABI1/2本批任务窗口、键盘及在途关闭已实跑通过 |
| 原生可见文本 | 输入后自然完成态标签正确显示，不依赖 resize 或强制重绘 | 先前失败已保留；局部重绘修复后八套97/0独立通过，重建应用原键盘路径与自然态图片通过 |
| 真实 IME | Microsoft Pinyin/Japanese 的组合、候选、确认、取消、reset 和选区保持 | NotRun；仅配置 en-US，中日文基本语言组件 NotPresent |
| DPI | 可用的 100%/150%/200% 场景逐项记录；实际不同 DPI 双屏移动另记；不擅自修改全局设置 | 仅实测 96 DPI；150%/200% 与物理混合双屏 NotRun |
| 辅助功能 | Tab/Shift+Tab/Enter/Space；Narrator 或现有 Accessibility Insights 的角色、名称、禁用态和焦点 | 本批键盘及基础 UIA 角色/值通过；完整名称/禁用态/播报与屏幕阅读器检查未完成 |

每项记录步骤、期望、实际结果、日志/截图路径与执行者。缺输入法、第二块不同 DPI 屏幕或辅助工具的项保持 NotRun，禁止用注入 `WM_IME_*`/`WM_DPICHANGED` 的自动化代替真人证据。长期 RSS/内存工具与硬件性能属于另外的验收，不因上述测试通过自动关闭。

## 当前环境与未关闭项

2026-10-18 旧容器启动失败后，用户已明确授权重建。新容器 `leaf-a2-windows` 已运行，持久根目录为 `/home/jimxl/.local/share/leaf/windows-acceptance`，不在 worktree 中；旧容器记录保留。Windows、密钥 SSH 和原生编译工具链已验证，首轮的 12 通过/4 失败日志保留；修正四项测试夹具后，七套非提权交互开发自测和独立功能复验均为 96 通过/0 失败/跳过，本批测试修复通过。

环境定位方法、输入哈希、四项实际失败及剩余范围见[Windows 持久环境与首轮记录](windows-environment.md)。独立复验结果已由原会话核对；后续复用该环境推进剩余范围，不再补空 storage 或重复安装。当前未安装 Git/Cargo/Rust 和完整 GPUI 源码开发依赖，未执行全部 102 个通用套件；GPUI ABI1/2 本批任务窗口已用 SDK 实跑。原生文本刷新缺陷已最小修复，并完成八套97/0独立验收和修改源重建后的自然态图片核查，原失败保留。普通用户账户矩阵、真实 IME、物理双屏与完整辅助技术等缺证据项仍不得标为通过。

</details>
