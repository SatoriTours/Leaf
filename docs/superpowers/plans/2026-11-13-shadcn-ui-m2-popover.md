# M2 原生 Popover 实施计划

> 单一原实现负责人使用 executing-plans/TDD 连续完成切片；不派生、不提交、不新建空间。用户在 Select 限定验收后要求继续，沿已批准 M2 路线推进，不重开基础视觉方向。

**目标：**非模态受控锚定内容浮层，容纳现有文本、按钮、原生 EDIT 与表单组合；真实键鼠、UIA、Dialog 作用域及资源生命周期可独立验收。
**架构：**复用现有 Runtime/BackendSession/普通 turn、typed host、owned 窗口与工作区几何。借鉴 Select 的锚定与 Dialog 的内容布局，不把 Select 列表当通用内容容器，不把模态 Dialog 改造成全局非模态宿主。
**技术：**Nim 2.2.6、Win32、既有主题及 stock UIA/EDIT provider。
**依据：**2026-11-07-shadcn-native-ui-design.md §6.2–6.3、§8 M2；Select r4 已限定通过。

## 边界与取舍
- 推荐真实非模态 owned popup：普通子窗口受裁剪；复用模态 Dialog 的 owner-disable 会改变语义，均不采用。仅抽取确有两处使用的小型几何/所有权 helper，不重构已接受的 snapshot/provider 算法。
- 首片一个按钮触发器、一个命名内容面板、受控 open、浅深主题、基本 side/align/offset；默认下方、起始侧对齐，工作区避让。只支持非模态，不提供 modal 参数冒充未实现能力。
- 公共部件为 popover、popoverTrigger、popoverContent、popoverClose；具体 Nim 参数顺序沿已有 select/dialog 的 Node/Callback 风格由实现端锁定共享测试。open 用 typed bool，开关请求用既有 EventKind.openChange/Event.open，不复用 checked/CSV。
- 内容使用既有标准子树，不实现菜单项导航、Tooltip/HoverCard、任意递归 Popover、动画、CSS 阴影。嵌套 Popover 首片显式拒绝，不能静默错误显示。支持 Popover 位于 Dialog 内，以及内容中使用现有 Select（Esc/点击的最上层优先级必须正确）。
- 固定上游仍为 shadcn-ui/ui@42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9 new-york-v4/popover.tsx；先核其部件与必要底层语义，留版本/输入哈希/许可映射。不可获取权威来源或必需原生语义需要新provider时保存最小缺口交主控，不安装SDK/改策略、不自行扩UIA授权。

## 行为不变量
1. open 完全受控；触发器、Esc、外点、close 部件仅提出请求，忽略/拒绝请求不得偷偷销毁窗口或改 accepted 状态。旧实例排队事件不能更新同key新实例，回调只在普通 turn 执行。
2. prepare/apply 不发布/抢焦点；接受 revision 后的普通 turn 才显示。真实 owned HWND，不禁用 owner、不全局置顶、不新增消息泵。背景可交互，外点不吞掉也不双发底层业务输入；关窗焦点不能覆盖外点的新目标。
3. 打开聚焦首个合法内容控件，无可聚焦项则面板本身；Esc/显式关闭后若仍拥有前台则恢复合法触发器或确定回退，失去应用前台不得抢回。
4. Tab/ShiftTab 在内容中顺序移动，边界请求关闭并转入 owner 合法后继/前驱；忽略关闭时可继续保持显示但不强迫焦点回来。此为明确的原生非模态首片策略，若与固定上游行为不同须注明，不谎称完全等价。Dialog 内所有目标仍必须在最顶层模态域内。
5. 内容内 Select 打开时第一次 Esc 只作用于 Select；其关闭后的 Esc 才请求关闭 Popover，再之后才可请求关闭 Dialog。Select 弹层和 Popover 面板内点不能被误当作上层外点。外层关闭/卸载按后进先出退役，不能解除仍存在的外层模态禁用。
6. owner/锚点移动、滚动、最小化、隐藏、禁用或删除：无悬空/不可达浮层，不误用缓存矩形。布局与主题变化保留活跃 EDIT 的 HWND/草稿/选区/Undo。关闭再开不承诺跨销毁 Undo。
7. 内容测量与工作区预算须预检；初次无法容纳的内容在发布前明确拒绝，不默默裁掉关闭/输入控件。已打开后工作区收缩沿现有布局/滚动能力维持可达；能力不足时按明确安全故障契约处理并报告，不夹在一个无法退出的面板里。
8. stock UIA 必须能自然发现触发 Button、命名非模态内容容器与其原生控件；实际名称/角色/焦点/启用/Invoke/Value 与受控状态一致。不能用直接目标 HWND 查询替代自然树入口，不把无意义的成功返回当语义已支持。保留 EDIT 系统provider；本任务不授权新增专用provider或把 Select provider 泛化。
9. OS 创建/定位/显示/销毁失败保留真实成功回执，可安全重试或进入既有故障合同；最终 dispose 资源归零。空名称、非法部件/参数、重复稳定身份、越预算及不支持后端必须在构造/typed wire 明确拒绝。

## 文件与职责
- 新增 src/leaf/popover_protocol.nim：typed 属性、拒绝矩阵、纯几何/焦点意图，必要复用已有几何而非复制整个宿主。
- 新增 src/leaf/backends/win32/popover_host.nim：owned 面板/内容挂载/资源回执；必要接入 src/leaf/ui.nim、ui_contract.nim、core.nim、host_protocol.nim、adapter/reconcile、Win32 backend/host/布局/skin。
- tests/nim/test_ui_popover.nim：公共部件、受控请求、wire、预算、非法嵌套/后端拒绝。
- tests/windows/test_win32_popover.nim：真实输入/布局/焦点/资源/失败回执/嵌套门控。
- examples/ui_controls/popover.nim、tests/windows/popover_client.cs：独立页面、Dialog内表单、内层Select、接受/拒绝关闭、正常退出和浅深窄窗截图。
- docs/ui/README.md、上游许可映射、本计划：仅必要更新。历史 Select 文稿中的旧证据标历史并链接 r4，不改旧测试日志/冻结产物，不重写目录/Notes。

## 单负责人实施与验收
- [ ] 先核 upstream 与最小实际UIA能力；失败门槛有界，不能做完后才发现必须新增provider。
- [ ] 共享测试先 RED：忽略 openChange 保持 accepted、构造/wire 拒绝、稳定身份/过期事件、几何边界，再最小实现 GREEN。运行现有 Nim 测试入口及受影响协议/后端能力套件，实际命令及数字exit记索引。
- [ ] 原生先 RED 后落地：外点恰好一次、Tab合法退出、Esc最上层、前台丢失不抢焦点、触发器退役、prepare拒绝不夺焦点、故障回执与资源归零；补正常内容控件/空内容焦点目标。
- [ ] 在真实非提升 Session1 验证编辑、选择、关闭与拒绝关闭；换肤不损EDIT、边缘翻转/窄窗/owner移动最小化/工作区约束；Dialog→Popover→Select 组合不越域，背景UIA拒绝与合法内层操作分别有正负控。
- [ ] 当前输入冻结后跑受影响共享及 Dialog/Select 回归；公共 backend/host 的生产变化影响广时跑正式 Windows runner，列完整 Exec 与numeric exit。不能把旧45套当新生产输入的整轮通过。未变且已证明无影响的部分仅按明确覆盖映射复用。
- [ ] 自然树发现、真实 UIA Invoke/Value/Focus/非模态状态、关闭后退役与正常 WM_CLOSE；异常/HRESULT分类严格、正负控非零语义可靠。浅深/窄窗/嵌套截图实际查看，不能用像素脚本顶替。
- [ ] 独立验收者核关键路径/必要回归，主控核 diff/证据后限定收口；真实150%DPI/HC/IME/读屏/跨平台无现场证据仍标未验。

## 环境与证据安全
- 同workspace wks_6f1e22dd96509cec，/home/jimxl/projects/leaf，main，HEAD c10f3417e287e9fe999d954e76523f7357b5a1af，.git/index；local不隔离。不stash/reset、提交/推送、建分支/worktree/空间或派生，保留未知修改。
- A=/home/jimxl/.local/state/agent-artifacts/leaf/2026-11-07-shadcn-ui-design；沿用A/status.md（主控），实现端仅维护A/m2-popover-result.json。临时脚本/tmp；新证据m2-popover-*。
- Select冻结目录A/m2-select-freeze-1及guest同名目录只读保留，APP SHA 5E9A0479317A09D75FABA1F6C521D3091B8D8AFDA930D55AEC8151D6078FC6E1。新组件建新输出目录，目录存在即拒绝覆盖。
- 正式manifest先从本地生成实体→复制guest同字节→建前核missing/mismatch/extra→新目录构建→建后校漂移→GUI前复制EXE到主机并校SHA→运行后核源/EXE/清单。记录实际命令、资源对象/客户端源码与EXE完整SHA，保留旧失败；不能只有哈希无文件，也不能重建覆盖旧已验产物。
- Windows沿现有control与SDK，GUI串行、有限timeout与唯一tag。每轮先收证据再清本轮cache/完成任务/核PID+启动时间+路径的自有闲置进程，保留EXE/源码/SDK/清单/截图，最后核磁盘（起点约13.53GiB）。旧Ready任务不动，不擅自改DPI/HC/IME/前台策略/认证或重启VM。
- 约10–15分钟无有效落盘保存缺口；同类根因两轮不收敛交主控，不增加模型/探针无限重试。遇工具/profile/新架构授权阻塞立即保存短状态并结束回合，不能以联系工具不可用当许可。

## 执行进展（Popover 故障语义切片）——**历史已撤回**

> 本节关于"显示失败不 fault session／不冻结事件，可在同实例同 generation 重试"的结论**已作废**：
> 那是测试捷径 `safeListTurn` 的观察。真实入口 `host.pump` → `safeTurn` → `bridge.nativeTick`
> → `Win32Backend.tick` 在转发错误前调用 `faultBackendEffects`（fault + 事件冻结 + 应用退出）。
> 当前合同见「第二轮」与 `docs/ui/README.md`。原文保留作历史记录，不删除。

- 已改为可判别故障注入：单层 spy calls（panel class 前缀匹配、一次性拒绝、真实 nil HWND／FALSE／
  SetLastError 5 与已命中计数），不再使用未注入的 systemWin32Calls。
- 创建失败：改为"被拒 revision"场景（popover root 只存在于候选 revision），断言真实命中、产品
  错误消息（含 `popover panel construction rolled back`）、class 注册与回执释放、无可达 host；
  产品侧 `ensurePopoverHost` 失败即完整回滚（释放 class／cookie 回执、不跟踪半开 host），恢复
  路径明确为新实例。
- 显示失败：断言真实命中、产品错误消息、无"已显示"计数、不 fault session／不冻结事件、accepted
  open 与面板／EDIT 保留，并在**同实例同 generation** 的下一普通 turn 重试成功且只计一次发布。
- 销毁失败：拒绝目标限定为该面板 HWND（不再误伤子窗口），断言产品错误消息与回执保留，重试后
  `liveWindows／liveFonts／liveRoots／livePopovers == 0`。
- 负控（`m2-popover-negative5`）：移除回滚 + 吞掉显示失败检查后，恰好上述两用例失败
  （`message.contains("... rolled back")`、`seamAttempts.unregister == 1`、
  `popoverCountForTest() == 0`、`did not become visible`、`popoverShows` 两次计数），其余 28 项
  通过，编译 exit 0／运行 exit 1 —— 证明断言可失败。
- 正向（`m2-popover-native98`）：编译 exit 0、运行 exit 0、30 OK／0 FAILED，输入 hash 见外部
  status；受影响回归 `m2-popover-regress-f1`：shared popover／dialog／select／components 全绿，
  native dialog 72/1（与 HEAD 基线 `m2-popover-dialogbase-f1` 同项失败，属既有视觉样式问题）、
  native select 3 项因 guest 前台加锁失败（`window could not be made foreground`，与本次改动无关）、
  select lifecycle 4/4。
- 文档：`docs/ui/README.md` 增加 Popover 章节与边界表行；上游 `popover.tsx`（sha256
  `3f99d3ad…`）加入许可证 manifest，`test_ui_licenses` 通过（`m2-popover-licenses-f1`）。
- 仍未完成：完整跨进程 UIA 客户端矩阵（`tests/windows/popover_client.cs` 尚不存在，仅有早期
  自然树发现证据）、浅深／窄窗／Dialog 内实际截图与视觉复核、完整 Windows 套件整轮、150% DPI／
  高对比／IME／读屏器现场；本轮不声明独立验收。

## 执行进展（第二轮：故障合同与跨进程 UIA）

- **显示失败改按真实入口取证**：此前用测试捷径 `safeListTurn` 得出的"不 fault／可同实例重试"不成立。
  真实链路 `host.pump()` → `safeTurn()` → `bridge.nativeTick()` → `Win32Backend.tick()` →
  `nativeTurn()` → `popoverTurn()` → `Win32Popover.show()` 中，`tick()` 在转发错误前调用
  `faultBackendEffects`：session faulted、业务事件冻结，异常离开泵，`runNative` 清理后抛给应用
  入口（真实应用退出）。用例改为断言该合同（含 `enqueue` 被拒、无 `popoverShows` 增量、
  accepted open／面板／EDIT 保留），负控 `m2-popover-negative6`（去掉 `tick` 的 fault 包装）
  恰好让该用例失败（`f.s.faulted`、`eventsFrozen`），其余 30 项通过。
- **回滚失败路径**：新增 `UnregisterClassW` 一次性拒绝用例，断言错误消息含
  `popover panel rollback failed` + `UnregisterClassW popover panel`、回执保留
  （`popoverCountForTest() == 1`），随后 teardown 二次注销成功并四计数归零
  （`m2-popover-native100`：编译 exit 0、运行 exit 0、31 OK／0 FAILED）。
- **跨进程 UIA 客户端**：新增 `tests/windows/popover_client.cs`（`m2-popover-uia-f5`：应用构建 exit 0、
  客户端构建 exit 0、运行 exit 0、55 OK／0 FAILED）：从应用／对话框元素子树自然发现面板
  （位置记录 `scope-subtree`）、Window＋`IsModal=false`、非置顶、owner 不被禁用、stock
  EDIT／Text／Button、SetValue 与回读、关闭即隐藏且草稿重开后保留、深色主题、窄 owner 仍在工作区、
  Dialog 内面板归属 dialog 并随其关闭隐藏。截图 6 张（浅色／深色 2 张／窄窗／Dialog 内 2 张），
  路径与 sha256 见外部 status；**未做视觉复核**（本会话无图像查看能力），不声明视觉通过。
- **Select 三项前台失败的独立性**：同一会话用 HEAD 基线 `backend.nim` 复跑
  `m2-popover-selectbase-f1`，结果与当前输入完全一致（10 OK／3 FAILED，三项均为
  `window could not be made foreground`），且诊断记录 session=1、`userInteractive=true`、
  `foregroundHwnd` 非零；因此该三项是环境前台加锁而非本改动回归。未改系统前台策略。
- 文档按已证范围收窄：显示失败不再写成"可安全重试"，改为既有故障合同；仍缺 150% DPI、高对比、
  IME、读屏器、截图视觉复核与完整 Windows 套件整轮。

## 执行进展（第三轮：I1 主题重绘 + 证据绑定 + Minor）

- **I1 先 RED 后修**：新增原生用例读真实屏幕像素（`WindowFromPoint` 归属 + 屏幕 DC 取色 +
  主导色），修复前 `m2-popover-red-theme5` 为 **32 项中 1 FAILED**：`THEME panel light=16777215
  dark=16777215 label dark=0 edit dark=1381653`，即深色下面板与正文仍是白底。探针进一步定位：
  `PANELPAINT theme=shadcnDark fill=1513239` 说明面板自身已按深色重绘，但它的正文容器
  （`Static` 覆盖整个客户区）从未重绘，且面板填充用 `palette.surface`、正文解析回
  `palette.canvas`。修复（仅 popover/skin 最小面）：
  1) `popover_host.setTheme` 由单窗口 `InvalidateRect` 改为
     `redrawWindow(panel, nil, nil, RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN)`（与
     `overlay_host.overlayTheme` 同族做法；只在主题真正变化时执行，普通 turn 不重绘）；
  2) 面板窗口用 `skin.markPanelSurface` 标记为主 surface，`paintPanel` 改用
     `skin.surfaceColor(theme, window)`（导出），使面板填充与正文/文字子控件同源；
  3) 顺带修正面板填充的 COLORREF 二次转换（通道交换）。
  修复后 `m2-popover-themefix4`：编译 exit 0、运行 exit 0、**32 OK／0 FAILED**；`THEME panel
  light=16777215 dark=1513239 label dark=1513239 edit dark=2171169`，并断言浅→深→浅、EDIT
  HWND/草稿/选区/Undo 状态不变。未改动系统按钮基线样式。
- **证据绑定（I2/I3）**：新运行全部在跑前记录 12 个输入文件 sha256 + 全树 manifest sha256
  （`eff0ee6d… files:11624`）、nim/gcc/csc 版本、构建命令、EXE sha256、编译与运行退出码、
  跑后输入漂移（空）。A/B 基线改为**显式换入 HEAD 三文件（backend/skin/popover_host）→ 校验
  哈希 → 跑套件 → 换回并校验当前哈希**：`m2-popover-ab-head-f3` 换入 `f0e9452b…/c9bca486…/
  8bcdc362…`（全部 matchesHead）、换回 `eecedb19…/7eb452db…/196316b8…`（全部 matchesCurrent），
  结果与当前输入 `m2-popover-regress-f2` **逐项相同**：dialog 72/1（同一条
  `GetWindowTheme` 失败）、select 10/3（同三条，3 处 `could not be made foreground`）、
  select lifecycle 4/0、shared 18/14/23/9/1 全绿。
- **negative5 定位**：其失败行指向已被替换的首轮测试断言，只能证明旧测试/旧语义；当前显示合同的
  负控是 `m2-popover-negative6`（`f.s.faulted`/`eventsFrozen` 两行与当前文件逐字对应）。
- **Minor 处理**：M1 回滚成功同时 `popoverRects.del`；M2 新增"回滚失败后移除 Popover 走
  stale-drop 二次注销"断言；M3 新增故障**前**同一 envelope 被接受的正控（同 session/同 mount
  generation/真实 binding）；M4 新增 `popoverReceiptsForTest()`（cookie 表）断言与
  `seamAttempts.destroy` 记录；M5 新增"place 后未发布"断言（`popoverPublishedRectForTest` 为
  false + 面板矩形非零）；M6 见上方撤回标注；M7 新截图重新生成。
- **截图**：`m2-popover-uia-f6` 的 6 张 PNG 路径与 sha256 见外部 status；像素统计（仅佐证，
  不作视觉结论）：深色图近白像素占比 17.11% → **7.97%**、近黑 78.64% → **85.87%**。
- 仍未完成：截图视觉复核（本会话无图像查看能力）、150% DPI／高对比／IME／真实读屏器／跨平台、
  完整 Windows 套件整轮、来源安全（上游 popover.tsx 仍 UNRESOLVED）。

## 执行进展（第四轮：surface 标记失败回执 + 重绘失败上报）

- **问题**：`openWindows` 在 `markPanelSurface` 失败分支里 `discard destroyWindow(panel)` 且把
  `host.windows.panel = panel` 放在标记之后——销毁结果被丢弃、HWND 回执丢失，且销毁调用会覆盖
  `lastError()`，使抛出的主错误变成 `Win32 error 0`。
- **RED（收窄陈述）**：`m2-popover-mark-red2`（编译 exit 0、运行 exit 1、31 OK／**4 FAILED**）
  证明的是**消息级三条失败**（见下）。深层所有权回退负控未做，故不宣称"全合同 RED"；同轮第 4 项
  `failed show faults…` 失败由实现者报告为**新用例漏 `close` 造成 cookie 表外溢**，其旧测试源
  未留存、无法独立复核，**不作为已证产品 RED**。
  - `surface-mark failure rolls the panel back…` → `message.contains("SetPropW popover panel surface
    failed: Win32 error 5")` 失败（原始错误被清理调用覆盖）；
  - `failed surface mark whose cleanup also fails…` → 缺少
    `DestroyWindow popover panel failed: Win32 error 5`（销毁被 discard，清理错误不可见）；
  - `theme redraw failure is reported and retried…` → 缺少 `RedrawWindow popover panel failed: …`
    （返回值被忽略，静默承诺换肤成功）；
  - 另 1 项 `failed show faults…` 因该轮新用例夹具未关闭造成 cookie 表外溢（测试夹具缺陷，
    与产品无关，已在同一轮补 `defer: close(f)`）。
- **修复**：
  1) `openWindows`：`CreateWindowExW` 成功后**立即**写 `host.windows.panel`，再调
     `markPanelSurface(panel, host.calls.setProp)`；失败直接 `nativeError("SetPropW popover panel
     surface")`（错误码仍是 SetProp 的），不做分支内销毁，清理与上报由既有 `closeWindows`／
     `ensurePopoverHost` 负责（主错误在前、清理错误以 `; popover panel rollback failed: …` 追加）。
  2) `setTheme`：重绘前记录 "重绘债" `needsThemeRepaint`；`RedrawWindow` 返回 0 时
     `nativeError("RedrawWindow popover panel")`（与 `overlayTheme` 同合同），债务保留，下一普通
     turn 重试；成功才清零，普通 turn 仍不重绘。新建面板时债务清零（新窗口本就按当前主题首绘）。
  3) 接缝：新增最小 `Win32Calls.setProp`（仅 SetProp 操作）供注入复用；`skin.markPanelSurface`
     增加带 `SetPropProc` 的重载，删除随之失效的单参重载与注释里多余的反斜杠。
- **GREEN（最终）**：`m2-popover-mark-green3`（编译 exit 0、运行 exit 0、**35 OK／0 FAILED**，
  EXE `8b76879f6682b81e69ae199355d48e7b24bd899d324c04be439fee4a7e0693df`，依赖子集
  `sha256:beae3013…nimFiles:645`）；`mark-green1`／`mark-green2` 为中间历史（前者缺最终
  `skin.nim` 单参重载删除，后者未含最终文档编辑），不作为最终记录。主题色实测仍为
  `panel dark=1513239, label dark=1513239, edit dark=2171169`（正常视觉未变）。
- 复用映射：`uia-f7` 的 5 张截图与 55 项断言按依赖复用（本轮只改失败资源路径与重绘错误分支，
  正常渲染路径未变）；dialog/select 的 HEAD A/B（`ab-head-f4`）与当前输入回归（`regress-f3`）
  不重跑，因为改动只落在 popover 失败分支（`calls/skin/popover_host` 均为 Windows-only 且
  dialog/select 不经过 `markPanelSurface`／`setTheme` 失败分支）。
- 文档：README 增加两条合同（标记失败回执、重绘失败上报+重试）；中间 tag
  （`red-theme5`／`themefix1..4`／`final1`）标注为历史并指向最终记录。
