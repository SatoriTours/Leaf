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
