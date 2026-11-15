# Windows 验收步骤与历史

> **当前范围（2026-11-15）：** 应用基线为 `5ce24ea`（上一已交付基线 `8b683ca`），Windows 默认原生；Linux/macOS GUI 暂缓；SDK 滚动 beta 本次只重建 windows-x86_64。完整状态统一见[开发进度总览](progress.md#当前总览2026-11-15)，构建入口见[源码开发](development.md)。下方 a1/a2/a3 和折叠区按原日期保留，不是当前 SDK 身份或新执行说明。

> **当前桌面补验（2026-10-31）：** `8b683ca` 的表单、列表部分滚动、生成应用三主题关键流程及24张实际截图已完成独立只读复核，限定范围通过。此前列表部分滚动的独立视觉缺口已关闭；完整 T2／T3／M4、系统现场能力及资源预算仍未完成。详见[当前进度](progress.md#当前总览2026-11-15)，下方保留历史失败与当时结论。

> **随后发现并修复的新路径：** 原 SDK 的列表按钮鼠标入口仍可在焦点转换前卡死。工作区候选已通过 SDK 生成→实际增删改查→关闭重开→默认打包→搬迁运行及默认用户数据目录的限定独立复核；同一候选 Windows 全部27套／199项累计通过，尚未提交／发布。此新失败不抹去上述限定通过，也不能由上述通过忽略，输入快照失败及分批复用细节见进度中的“Windows 实际使用链路与鼠标卡死修复”。

> **最新候选交付阻塞：** 后续搜索布局修复已有三主题18项尺寸观察和12张目标图；系统主题测试 EXE 在运行收尾时被 Defender 拦截。后续经授权已通过官方工具恢复单个隔离样本并补齐 hash，检测原因仍未澄清，用户已提供 Microsoft 提交编号，等待判定，尚未独立读取门户结果。保留已观察结果，不判整个候选可交付，详见进度中的后续搜索布局记录。

> **2026-11-07 补验：** 当前工作区动态布局已完成三主题单字段Note的96 DPI开发验证，并获17张原生截图及对应身份／数据库／日志的独立离线复核限定通过。系统宽窗固定28px断言原失败保留，同EXE宽窄补验通过；不代表独立重跑、完整主题状态矩阵或资源预算通过。共享官方回归180套退出0，1454 OK／5 SKIPPED（本机无pwsh）。详见进度中的本日结论。

## 当前验收出口

使用已授权且解锁的普通用户 Windows x64 桌面，记录 SDK commit／checksum、编译链、Session／权限／DPI 和实际入口。只使用任务独立数据库与目录，不改系统缩放、输入法、认证或全局 PATH。

| 门 | 必需证据 | 当前状态 |
| --- | --- | --- |
| 已提交代码与 SDK 自动化 | 同 SHA 的共享／Windows 测试、安装／重定位、CRUD 与失败更新日志 | `8b683ca` 四工作流／11 job 全部 success，共享178套／1449项、Windows26套／198项；复用同 SHA 既有证据，固定链接见进度总览，不覆盖所有 probe |
| 实际应用纵向链路 | 同一应用从安装／创建到真实窗口编辑、滚动、保存、关闭重开，再打包搬迁启动／读回 | 有 a3 入口／列表／搬迁与后续主题真实入口证据，各自只对应冻结快照；最新 SDK 自动化不代表最终 SHA 全部现场重跑 |
| 原生视觉 | 实际入口截图的语义检查，文字／控件／布局与操作结果 | `8b683ca` 表单、列表部分滚动、生成应用三主题共24张96 DPI实际截图独立复核限定通过；a3 首尾五行／末行9999及 Canvas／动画／实验室另有历史静态证据，不判完整主题矩阵或整体通过 |
| 冷资源预算 | 原 cold USER/GDI 失败的根因与按既定预算的验证 | 未关闭；不继续无界追加裸 API 变体，不放宽阈值 |
| 系统输入与辅助技术 | 真实中文 IME 组合／提交、物理键鼠、混合 DPI／多屏与完整辅助功能 | 缺现场证据；96 DPI 合成消息／基础 UIA 不替代 |

## 2026-10-29 资源与现场门复核

- **资源门仍不通过／根因未定位**：旧 fresh 冷预算为 USER4>3、GDI10>2；旧裸窗口对照已有首次 +3 USER／+9 GDI，不能将全部增量都归为 Leaf。最终 `native-s1t2-leaf-measure-1022-cf58d12c` 观测 26 次 DrawText 无采样 GDI 增量，52 组实际字体／DC 恢复归还正常；额外 GDI 在首个 GetDC 入站前已可见。以上不证明隐式对象归属、Windows 缓存或无泄漏。
- **停止同类探针，限定转入对象级观察**：旧总计数／API 家族在累计7次 C/link、6个 Native 进程后停止，不恢复 API／控件矩阵、不改预算。随后只读核查117个限定路径／当前用户 WinDbg 包，发现现成 GDB10.2 可启动；未在这些目录找到 GDIView／WinDbg／CDB，不推论全盘未安装，也未附加调试器。用户随后明确授权从 NirSoft 官方 HTTPS 下载并运行便携 GDIView x64 1.26，签名状态 Valid，非提权 Session1；不安装、不改系统／认证设置，扩展信息保持关闭。
- **一次对象级结果，不是根因通过**：`quality-gdiview-object-1029` 以归档 cf58 的548文件快照为输入（不是重建当前 `db34265` 产品），只在诊断副本的建窗前／建窗后／关窗后加入30秒上限的观察停留；原产品、计数／收据、列表操作和关闭逻辑不变。新增一次 C/link＋一个目标进程，均自然 exit0，资源诊断累计至8次 C/link／7个目标进程；工具能力检查不计作产品探针。进程存活时，GDIView 可枚举对象为0→6→7，All GDI 为0→9→10：建窗后为 Brush1／Font2／DC2／Bitmap1，关窗后另观察到 Region1。三处是离散快照；即使六个句柄值／类型匹配，也不证明连续生命周期或所有权。
- **限制与原失败保留**：本次原收据完整，26次 DrawText、7次滚动／8次 settle／24次 reuse 和关闭前提仍成立，但关窗后 USER=5，不同于历史4，原输出明确 `pattern_matches=false`；不能说完全复现历史联合模式。Region 的创建时点／分配栈／释放责任未获证据，不能判为 Leaf 泄漏、Windows 缓存，或据此直接 `DeleteObject`。All GDI 比枚举行数多3，未归属；本次读取的 `GDI Total` 列为0，与分类型计数／对象表不符，未将此列作判据。不开启扩展信息、不追加目标运行或直接读取内核内存／自写私有 GDI 表遍历；进一步创建／释放追踪需要另行核实方法与授权，资源门继续不通过。
- **后续 GDB/MI 追踪未完成，失败归控制器**：用户批准继续有界创建／转交／释放栈追踪，现成 GDB10.2 的 `--without-python` 阻止原 Python 方案，随后零目标核验其原生 MI2 可用。`quality-region-mi-trace-1029` 一次编译成功，但控制器在加载文件前设置 `startup-with-shell off` 时收到 `No symbol table is loaded` 错误，目标未启动；移除该非必需选项后，`quality-region-mi-trace-reuse-1029` 复用完全相同的 EXE／548源，仅启动一个目标 PID2652，停在 `main` 和建窗前边界。控制器错误地用 JSON 转义生成 MI C-string，把 `&CreateRectRgn` 变为 `\u0026CreateRectRgn`，GDB 实际报告缺少 `u0026CreateRectRgn` 符号；不是 Windows 缺少该 API 的证据。尚未采到任何 Region API 入口／返回事件、建窗后／关窗后快照或分配栈，调试器退出时终止了本任务目标；目标退出码未知，不把 GDB exit0 当成目标自然成功。旧资源台账加本轮1次 C/link／1目标后为9／8（包括这次中止进程），未追加第二目标。
- **仅修复采集器转义，未验证追踪成功**：`quality-region-mi-quote-check-1029` 的8项 C-string 正例、非法控制字符／非 ASCII 两项拒绝以及 GDB 文件级 `(void*)&main` 地址解析通过；无编译、无目标启动或附加。该阶段修正后的完整追踪控制器只归档为未运行版本，不把这些前端检查替代完整 API／返回栈验证、原失败复现或资源预算通过；后续获准复验见下项。产品／仓库测试未变，未安装／提权／修改系统设置或追加总计数／API变体。
- **追加一个目标后的真实前缀，完整追踪仍未完成**：用户随后批准最多再启动一个诊断目标。`quality-region-mi-r2-live-1029` 复用同一归档 EXE／548源（0编译、1目标 PID7892），四项必需 API 地址从该目标自身经 `GetProcAddress` 绑定的函数指针读取，十项选定公开 API 地址均解析成功；仅普通用户态变量／寄存器／栈，不读内核内存或私有 GDI 表。结构化日志包含951条记录：两个边界、475条 API 入口／474条返回，含118次 CreateRectRgn 返回；474对已记录返回的线程与返回栈指针匹配。81次已完成 SetWindowRgn 的调用区间中，各有同值参数的 DeleteObject 返回非零；这是有限前缀的调用事实，不作跨快照生命周期／全局所有权证明。建窗前／建窗后枚举行数0／6、All GDI为0／9；随后在120秒总限／单次读取时限保护下报 `MI bounded read timed out`（原记录未明确区分哪项时限触发），目标被调试器退出终止，退出码未知。最后一条已记录 SetWindowRgn 尚无返回，原始 MI 还多出一处未完整写入结构化日志的 DeleteObject 停点；没有关窗快照、最终收据／USER/GDI／完整路径，不能关联此前另一进程的残留 Region，不能判根因或预算通过。未扩大时限／追加第二目标；累计资源台账为9次 C/link／9个目标（含中止样本），本轮不新增编译。前置零目标检查曾误以为无效线程 ID 必须被 GDB 拒绝而报失败；实际 `^done` 已保存线程过滤／条件，按原始响应确认支持，失败判据与记录保留，不归产品或调试器缺陷。系统 DLL 栈名可能是最近导出符号标签，只信模块／地址与本项目 DWARF C 栈，不据此指定 Windows 内部创建者。
- **2026-11-01 仅补控制器零目标检查，未续跑活体追踪**：复用旧原始日志，候选将暂停态寄存器与返回地址合并为一次 MI 数组读取，并仅省去 DeleteObject 的完整栈查询（仍保留其调用参数／返回 PC／线程／返回 SP 检查，创建／转交／销窗完整栈不省）。按已入账的475个入口可省475次地址读取与256次完整栈查询，另加2条格式初始化命令；少命令不证明实际可在120秒内完成。现成 GDB／PowerShell 的12项前端检查通过，包括实际数组表达式、完整 uint64、重复零不省略、文件符号 `&main`、非法／缺失值拒绝及无 inferior；仅启动调试器，0编译／0目标进程。候选完整控制器仍未运行，真实寄存器／栈内存与跨边界追踪未验证，旧总时限与单次读取超时的历史原因仍不能倒推。原累计9次 C/link／9个目标不变，资源门仍不通过；上次最多1目标的授权已用完，本轮未把“继续”扩成追加目标许可。日志和未运行候选链接入进度总览的原唯一证据索引。
- **单次续跑仍不完整，停止当前逐调用断点路线**：用户在上述最多1归档目标／原120秒问题后明确批准继续。`region-mi-batch-live-1101` 复用同一 `30144d13…` EXE／548源，0编译、仅1目标 PID9516，非提权 Session1／GDIView扩展信息关闭。得到1157条结构化记录：两边界、578入口／577返回；577组线程与返回 SP 均匹配，最后一条 CreateRectRgn 尚无返回。真实暂停态寄存器／栈内存的批量读取已执行，但在 `elapsedMs=120014 token=3202` 明确触发总时限，仍无关窗快照或最终 USER/GDI／原诊断收据。建窗前后仍为0／6对象、All GDI 0／9；不能将更多前缀记录当作完整生命周期、根因定位或性能对比。目标由调试器退出中止，`targetNaturalExit=false`、目标退出码未知；GDB与GDIView退出0、计划任务Ready／0都不代表目标成功，runner实际exit1。累计变为9次 C/link／10个目标（含中止），资源门继续不通过。已保全raw／不完整收据／输入hash，postcheck精确PID与三种相关EXE均无残留、防护开启。连续两次实际追踪均到总／读取保护前缀，停止继续以合并MI、重命名候选、扩时或增加同类目标微调；后续必须先形成低干扰、能在原边界内闭合全路径的实质新方案，不能据此猜改产品或放宽预算。
- **后续改用原生命令列表（仅零目标验证，未实跑）**：`region-native-controller-unrun.ps1` 不再逐调用读取寄存器／回主控装临时返回断点，而由 GDB 便利变量记录入口和返回，以线程＋返回SP＋返回PC配对；已知返回地址在断点命令内自动继续，仅新返回地址和原三边界回 MI 主控。两份旧前缀均只有15个不同返回PC（475／578入口），仅为选型依据，不是全程上限或性能证据。保留全部原API、创建／转交／销窗8帧栈、Delete的caller PC与参数；64并发／返回站点、512 creators、6000总stops越界显式失败，120秒不变；不向目标注入代码、不读取内核／私有GDI表。已在 Linux GDB17.2 执行12项零inferior测试，并在现有同hash Windows GDB10.2执行12项相同核心测试＋7项实际MI前端检查（候选PS语法、内嵌内核一致、真实MI新站点标记／计数、完整uint64往返、错误拒绝、10入口＋1返回断点命令列表仅绑定、无inferior PID）。覆盖嵌套、同SP不同线程、错误SP／PC拒配、歧义不释放、容量与原上限。最初宿主测试因末尾printf换行转义错误全部失败，修正后12项通过，原失败log保留；不是产品RED。VM启动首次防护false，立即停止工具执行，只读复查后true才运行测试，未改安全设置；全部Session1／非提权／前后防护true、0 C/link／0目标。两次runner rc0，缺少可选transcript是脚本未创建该文件，不冒称丢失证据。候选SHA256 `aad4a238c3c5d7d581ac16cdc76ea2f5f196e701a0a9abc85f59f8587633445a`，Windows上传及解析身份一致。注意：真实寄存器／栈读取、断点命中后的自动继续及MI事件时序、完整控制器性能／关窗路径均尚未验证；这些检查不是产品回归，也不关闭资源门。累计仍9次C/link／10个目标；不把零目标测试当成新的实跑授权。
- **现场能力仍不足**：本轮交互用户语言 en-US，性能报告为 96 DPI／software VM；没有中文 IME 组合／提交、物理混屏、物理键鼠或屏幕阅读器的实际证据。不得用 SendKeys、缩放数学或几何／像素脚本替代。补验需有具备这些能力的实际环境及操作范围授权；不改变现有用户设置来伪造通过。

原始资源结果：`target/verification/native-five-platform/s1/t2/geometry-verification/coordinator-result.md` 的 cf58 节，以及持久证据根 `~/.local/share/leaf/windows-acceptance/shared/evidence/native-s1t2-leaf-measure-1022-cf58d12c/`。最新质量收口结果继续写入[进度总览](progress.md#当前总览2026-11-15)所列唯一证据索引。

## 2026-10-25 历史入口与列表验收

以下“本轮／最新／原发布 beta”均指 2026-10-25 批次，不覆盖上表的当前交付状态。

a1 的参数二次解析与 `--check` 拒绝已获准修复：仅由示例消费开头数据库参数，并显式向框架转交其余 args。GPT a2 对相同 dirty 示例、原已发布 SDK 独立验证上述功能链路，未绕过 pack 内置自检，该验收执行时线上 beta 未更新。用户随后批准继续定位列表缺陷：窗口位置的父局部坐标与裁剪的视口坐标混用，现保存原视口rect并同空间求区域。真实示例区域回归已在Windows先失败后通过，受影响失败恢复／变高回放自测通过。同一GPT的a3已确认真实多行／末行、非首行保存／重开和默认pack搬迁；使用固定源码覆盖，不能说原beta已修。部分滚动先因位置／track语义混用未发生，一次合成拖动纠正仍未产生跨视口边界的行，断言失败，故该门阻塞／未完成；不把未覆盖直接定性新产品裁剪缺陷。机器 `scopePassed=true` 或区域读回绿不是整体视觉裁定，停止原策略追加。

沿用既有有界 runner 与受监督任务生命周期，单端使用 VM。首次有效失败保留源码／包 hash、stdout／stderr、退出码与进程 postcheck；不自动修改产品或增大测试预算来凑通过。既有未变快照的测试按范围复用，不重复全套。本轮证据目录为 `~/.local/state/agent-artifacts/leaf/2026-10-25-windows-beta-acceptance/`，最新报告为 `acceptance-gpt/report-a3.md`，原始结果／图片位于 `run-a3/guest/` 与 `run-a3-partial/guest/`。主控已核报告、结果／脚本／数据库／图像hash，实际看过交付exe首尾两图；`final-postcheck-a3.json`显示主任务Ready/0、补验Ready/1、ownedProcesses=[]、runningTasks=[]。a3各app自身均exit0；补验task1来自验收断言，不冒称app1。a1/a2旧失败保留；完整T2/T3/M4及现场门不随局部通过关闭。

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

## 2026-11-07 采集器零目标回放补证

既有 v2 候选的实际 `Mi-Read` 已在 Windows PowerShell 5.1.26100.9444 回放通过，原读取器负面对照错误上报2个自动继续停点；候选保留信号／未知停止，拒绝重叠停止和采集器错误。该批为 SSH Session0、0编译／0诊断目标、前后防护开启；不关闭Windows GDB实际事件时序、完整生命周期或资源预算。输入hash与日志：`target/verification/resource-followup-20261107/`。累计资源台账仍9次C/link／11目标，后续目标须按单次授权和原120秒／6000停点／512创建边界执行。
