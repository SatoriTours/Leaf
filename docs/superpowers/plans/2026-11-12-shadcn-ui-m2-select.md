# M2 原生 Select 实施计划

> 使用 executing-plans/TDD；一个实现负责人连续完成实现、自测和普通修复，不按步骤拆 Agent。不提交、不新建空间。既有设计及本次“继续”授权沿路线推进，不重复审批既定范围。

**目标：**交付可真实打开、导航、选择、取消且可嵌套于 Dialog 的受控单选 Select。
**架构：**真正非模态、非全局置顶的锚定 owned 弹层；复用现有 Runtime/BackendSession/typed host/普通消息泵与资源回执。不把 Dialog scrim/owner disable 强行套给 Select，不以系统 ComboBox 冒充定制 Select。
**技术：**Nim2.2.6、Win32、现有主题和原生可访问性桥。
**依据：**../specs/2026-11-07-shadcn-native-ui-design.md §6、§8 M2；Dialog 边界和官方回归关卡已独立收口。

## 范围和取舍
- 本片是非编辑、单选、文本选项；支持 placeholder、disabled（整体和选项）、受控 value/open、稳定 key、基础尺寸和浅深主题。
- 不实现搜索/Combobox、多选、任意富内容、分组/分隔符、NativeSelect、Menu/Popover、动画；明确写入文档，不冒称完整上游兼容。
- 备选：直接系统 ComboBox 留给 NativeSelect；普通子窗口列表会受父裁剪，不采用；选择真正 owned popup，复用原生列表/可访问性能力。
- 首先做有界原生可访问性契约验证：实际展开/收起、选中项/值、disabled 项与可执行选择操作必须与真实状态一致。不能仅用 Button/Pane 名称冒充语义。保留现有 EDIT/stock provider；若必要语义必须替换 provider、引入大范围新 provider 或改系统策略，保留最小失败证据交主控决策，不悄悄降覆盖或扩权。
- 公共 API 保留适合 Nim DSL 的 select、selectTrigger、selectContent、selectItem 部件；按现有 Node/Callback/typed sidecar 惯例落地，不用 CSV 或任意属性字符串承载选项状态。构造与 host wire 均校验。

## 不变量
1. value 和 open 均以调用方接受状态为准。候选高亮是临时导航状态，不写入 value；提交/打开/关闭均是请求。忽略或拒绝值/开关请求，各自保留 accepted 状态；不得双发事件、让旧通知更新替换实例。值载荷使用 Event.value，新增事件/实体枚举只能尾追加并覆盖协议 round-trip 与能力拒绝。
2. 重复/空选项身份、重复值、非法初始值必须显式拒绝；空列表/全部禁用不得产生虚假候选或提交。无值表示 placeholder，重复显示标签允许但以稳定身份选择。删除或禁用当前项时不暗选邻项，调用方应提供合法新状态。
3. 开启时候选优先已选可用项，否则首个可用项；Up/Down、Home/End、字符前缀定位跳过禁用项，移动候选不提交。Enter/Space/有效项点击提出一次选择请求；Esc 仅取消候选并请求收起。Tab/Shift+Tab 请求收起并依 accepted 状态在合法 owner 焦点域移动，不形成新的模态循环。
4. 外点请求收起，不吞掉下一次业务输入、不双投底层点击；忽略关闭请求不擅自隐藏。失去应用前台不得抢回焦点；关闭焦点恢复区分键盘取消与外点已选的新目标。
5. 弹层不裁剪于父容器、不禁用 owner、不全局 topmost；锚点以 accepted 几何为准，上下翻转/工作区约束/有限滚动确保目标可达。owner 移动/滚动/最小化、锚点退役、主题/布局变更正确处理。
6. Dialog 内弹层属于最上层模态作用域。第一次 Esc 只请求关闭 Select；外层 Dialog 背景门控保持，Tab 和 UIA 不越域；关闭外层时同步回收其 Select。不要改动旧 Dialog 的语义以迁就下拉框。
7. WndProc/原生通知只记录请求，在既有普通 turn 执行业务；prepare 不夺焦点/发布窗口，失败保留真实 OS 成功回执。创建/显示/定位/销毁失败可恢复或遵守现有安全故障合同，不能藏在成功标记里。最终 dispose 必须无窗口/字体/子类/根资源残留。

## 实现和验证（同一负责人连续执行）
### 1. 原生语义门槛与共享 RED
- [ ] 核固定 upstream 42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9 的 new-york-v4 select.tsx，留存输入和许可证映射。
- [ ] 用最小原生探针和真实 CLR UIA 固定上述选择/禁用/展开语义；探针在 /tmp，失败输出保留。此步骤不是组件完成；不可行则报告具体能力缺口，不无限试探。
- [ ] 新增 tests/nim/test_ui_select.nim，先跑有效 RED：typed API、重复身份/非法值、空/全禁用、候选与 accepted value 分离、提交/取消、忽略请求、稳定 key、陈旧事件与预算、host wire 不丢状态、未支持后端明确拒绝。
- [ ] 在 src/leaf/select_protocol.nim（建议）实现纯契约/有限导航/锚定数学；接入 ui.nim、ui_contract.nim、core/host_protocol 及既有 adapter/reconcile 的必要位置，不另造平行 Runtime。

### 2. 原生完整交互闭环
- [ ] tests/windows/test_win32_select.nim 先 RED 后实现 src/leaf/backends/win32/select_host.nim（建议）及 backend/host/calls/api/skin 的必要接入；共用基础允许提取小的几何/ownership helper，不重写已验收 modal overlay。
- [ ] 真实键鼠覆盖候选导航、Enter/Space/鼠标提交、Esc取消、Tab、外点、disabled跳过、长列表滚动；验证回调次数、accepted value/open、焦点与真实 HWND/UIA 状态。
- [ ] 验证收起/展开期间删除触发器、禁用/替换选项、重复标签、主题变化、窄工作区与上下翻转、owner移动/滚动/最小化以及嵌套 Dialog，不依赖缓存旧几何。
- [ ] 注入创建/定位/显示/清理故障；保留失败回执，反复开关/销毁资源归零。验证拒绝更新和通知重入不会误提交或解禁外层 owner。

### 3. 实际入口与独立验收准备
- [ ] 新增 examples/ui_controls/select.nim、tests/windows/select_client.cs（以及必要 fixture）：独立页面与 Dialog 内各一处，真实 State 受控值，覆盖接受和拒绝分支，不重写已验收目录。
- [ ] 跨进程 UIA 核真实名称/角色、展开/值/选择、禁用项、焦点和交互；浅深主题/边缘翻转/长列表实际截图并查看，不用像素脚本冒充视觉判断，不强刷掩盖绘制问题。
- [ ] 更新 docs/ui/README.md 与上游映射，列真实支持范围和差异；记录未验证的真实150%DPI/HC/IME/读屏/跨平台，不冒称已验收。
- [ ] 受影响共享套件、完整 Dialog 回归、正式 Windows runner（新增 Select 后实际枚举全部程序）。有效的同一最终输入证据不重跑；绑定源文件 SHA、EXE SHA、真实退出码和完整覆盖清单。
- [ ] 原实现者集中交付 diff/RED/GREEN/失败谱系/最终输入与产物身份/真实图片，主控组织独立验收关键路径，不用自测替代独立验收。

## 关键审查项
- 重复标签或运行期重排：以 stable key/value 而非展示索引更新，旧通知不能选择新项。
- 全禁用/空列表及删除当前项：不能越界、隐式改值或陷入键盘循环。
- Dialog 中 Escape/Tab/UIA：先处理 Select、保留外层模态隔离与合法焦点。
- 锚点滚动/退役/owner最小化：不留悬空弹层、不抢别的程序前台。
- 受控拒绝及 OS 部分失败：真实可见状态与 accepted 模型一致，最后资源归零。

## 执行环境与证据
- Workspace wks_6f1e22dd96509cec；/home/jimxl/projects/leaf；main；.git/index；local 不隔离。保留全部已有未提交/未跟踪成果，不 stash/reset、提交、切分支、推送、建空间或派生。
- 已验收起点 A/m2-official-inputs.json：909项；官方43程序325检查exit0。A=/home/jimxl/.local/state/agent-artifacts/leaf/2026-11-07-shadcn-ui-design。当前计划为起点后的新增文档，不能把它伪称在旧909输入中。
- 唯一状态沿用 A/status.md；Select 证据前缀 m2-select-*，只保留一个当前结果索引。修改已有文件前记录原hash/必要preimage，不备份整机或覆盖旧证据。
- Windows为既有非提升Session1，SSH LeafTester@127.0.0.1:12222，source=C:\LeafTests\work\shadcn-ui-1107\source。控制脚本 /home/jimxl/.local/share/leaf/windows-acceptance/control/guest-ps.py 与 run-guest-script.py；唯一tag、TAGPLACEHOLDER、数值退出码，GUI串行；不运行会提取旧tar覆盖源码的历史build-current脚本。
- 不安装依赖/改认证、DPI/HC/IME或前台系统策略，不擅自重启VM。先核前台再送输入；未送达输入不是产品RED。OneDrive通知曾占据前台，已移入通知中心，未改备份设置。
- 每轮先收证据，再清本轮可重建缓存/无用临时文件/确认闲置的自有进程和完成任务，保留源码、SDK、EXE、失败日志和截图，最后核磁盘；不动未知/共享资源。
- 命令显式有限timeout，长官方回归约18分钟应合理有界；不新增后台监控或轮询Agent。约10–15分钟无有效落盘先保存具体缺口；同根因两轮未收敛交主控分析，不无限加探针或换模型。

## 补充裁决：Select 专用 UIA provider（用户确认继续）
- 前次实现留下的交互成果保留，但原生UIA选择门槛未满足，当前不得验收通过。用户在主控明确提出专用provider方案后确认继续，现授权仅为Select触发器、弹层与选项实现必要UIA接口；不替换EDIT或其他组件的原生provider，不扩大到通用provider框架。
- 先把select_client.cs中的必需[MISSING]变为失败断言/非零退出，保存对当前EXE的有效RED；含缺失项的旧exit0不能作为语义通过证据。
- 使用可追溯的微软官方接口文档/SDK头或IDL定义核实接口IID、vtable顺序、参数、结构对齐及COM调用约定，留来源版本/哈希和必要许可归属；允许项目内最小兼容声明，不安装、更换SDK，不凭记忆猜GUID。若权威定义无法取得，保存缺口并结束回合报告，不能越过门槛继续扩展。
- 触发器提供真实展开/收起与只读当前值；弹层/项提供真实Selection/SelectionItem、所属容器、稳定身份、名称、IsEnabled、IsSelected、边界/离屏与焦点。不得提供虚假的可写Value或把任意Provider调用当作成功。禁用项选择及模态域外操作须拒绝；合法项UIA操作必须通过正控。
- UIA请求只进入现有受控事件/普通turn路径，不能从COM线程直接运行view或业务回调。value/open请求被忽略或拒绝时，查询/事件仍反映accepted状态；导航候选不误报为已选。
- 核实COM引用计数、线程安全、provider/选项退役与销毁后的ElementNotAvailable，以及属性/结构/选择/展开事件。缓存旧provider、重排/同key替换、关闭重开和Dialog嵌套不得操作错误实例或越过外层门控。
- 先收敛严格跨进程UIA定点测试，最终冻结输入后跑必要共享、Select/Dialog与官方全清单回归；新provider影响产物，旧44程序结果不能直接充当新最终输入通过证据。由主控组织独立验收，不以实现者截图/自测代替。
- 原实现者连续完成本轮；若联系主控工具不可用，保存最小复现/尝试/缺口后直接结束回合，完成通知即交接通道，不视作默认许可。每轮取证/清缓存/查磁盘规则不变。
