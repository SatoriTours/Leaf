# 原生单选组实施计划

> 单负责人按 executing-plans 连续实现、自测和修复；不逐文件拆派、不提交或发布。

**Goal:** 补足已批准阶段 B 的纵向 RadioGroup，使表单可用真实原生单选语义选择一个值。
**Architecture:** 复用 column + 原生 BUTTON 和现有 typed UI roles、受控事件及 State 事务；不增加 NodeKind，不改变 wire ABI。采用原生 RadioButton 而非普通按钮伪装；由接受后的受控值决定选中，不让系统自动取消兄弟项成为独立状态权威。
**Tech Stack:** Nim、既有 Win32 后端、stock UIA、现有 token/skin、既有 Windows 工具链。
**Spec:** `docs/superpowers/specs/2026-11-07-shadcn-native-ui-design.md` §6/7/8；本片为用户要求继续既定路线后的主控实现取舍。

## 范围与约束
- 首片纵向、single selection；不做横向/RTL、非受控状态或整套 Form。
- 模块限定 `standard.radioGroup` + `standard.radioGroupItem`，复合部件延续项目惯例。
- 建议接口：`radioGroup(items: openArray[Node], value: string, label = "", key = "", disabled = false, onChange: EventHandler = nil): Node`；`radioGroupItem(value, label: string, key = "", disabled = false): Node`。以既有 EventHandler/Node 的真实声明为准，不额外复制事件体系。
- 非空且唯一的选项 value；空组、重复 value、非法部件/嵌套组在构造或 prepare 拒绝。group value="" 表示未选择；非空且不存在于选项中拒绝，不能悄悄选第一项。
- disabled item 可以是已接受值，但不响应用户输入；全禁用无 Tab stop。无选中时第一可用项成为入组焦点，不因此发送选择事件。
- 一个组只有一个 Tab 入口（已选且可用项，否则第一可用项）；Tab/Shift+Tab 离组，Up/Down 循环跳过禁用项，Home/End 到首尾可用项，Space/鼠标请求选中，重复激活已选项不重复提交。
- `onChange` 只在普通 turn 投递 `Event.value`；忽略请求保留已接受值，拒绝 revision 不污染下一次选择，卸载后旧事件不投递到新组。两个兄弟组互不串扰。
- 保留原生 RadioButton 角色与真实选择状态；UIA SelectionItem 等实际支持需跨进程核实，不把 Checkbox/Toggle 或普通 Button 称作单选语义。
- 参考既有 Neutral token 与 checkbox/field 视觉；不重新获取上游文件，不改 vendor 来源 metadata，不声称核过未读取的 radio-group.tsx 或逐像素一致。
- 保留当前全部未提交 Popover/ScrollArea 成果及失败历史。现 cwd/main/.git/index；禁止新空间/分支/worktree、Git写入、安装依赖、认证/防护更改。仅必要产品/测试/示例增量，不重构大后端。

## 文件与职责
- `src/leaf/ui.nim`：构造器及受控事件映射。
- `src/leaf/ui_contract.nim`：末尾追加角色，既有 ordinal 不变。
- `src/leaf/backend.nim`、`src/leaf/backends/win32/capabilities.nim`：结构化能力/不支持时拒绝。
- 必要时新增 `src/leaf/radio_group_protocol.nim`：纯校验、可用项和 roving 焦点策略；避免把全算法堆进 Win32 backend。
- `src/leaf/backends/win32/backend.nim`、`skin.nim`：真实 radio 类型、组隔离、接受状态同步、键盘/鼠标与绘制。只在必要时扩展私有 calls/api seam。
- `tests/nim/test_ui_radio_group.nim`、`tests/windows/test_win32_radio_group.nim`：共享与真实宿主回归。
- `examples/ui_controls/radio_group.nim`、`tests/windows/radio_group_client.cs`：实际入口与跨进程交互/截图。
- `docs/ui/README.md`：限定 API/语义/平台与未验证项。

## Review Focus
1. 忽略/拒绝 onChange 后原生兄弟项是否恢复；第二次事件是否继承错误候选。
2. 原生组边界与 roving Tab；两个组或 Dialog 中是否越界/抢 EDIT 按键。
3. 动态删除/禁用选中项与稳定 HWND，拒绝无效 value 不默改业务值。
4. UIA 角色/SelectionItem/IsSelected 与可见选中态是否一致。
5. 同身份从 Checkbox/其它角色变 radio 时原生 class/style 是否能安全保持；不支持则 prepare 拒绝要求新 key。

## 一个完整可验收切片
- [ ] 先写共享校验与能力测试；运行失败证据（缺 API 编译失败与真实断言失败分开记）。
- [ ] 共享合同 GREEN，随即落原生 fixture 和最小完整接线；不只交模块草稿或只在文档标记能力。
- [ ] 原生测试覆盖上述五项风险、一次选择/重复选择、disabled、清空、两个组隔离、Tab/方向/Home/End/Space、候选拒绝、卸载、资源归零。
- [ ] 实际示例覆盖受控接受/忽略、浅深、窄窗、Dialog/ScrollArea 组合；跨进程核真实鼠标/键盘/UIA并产生截图。截图用有界输入空闲+正常绘制，不强制重绘。
- [ ] 测试构建使用仓库 v6/PMv2 manifest；Defender 开启、非提权交互 Session、输入/产物 SHA256、有限 timeout 与独占锁。沿已有 runner，不新增另一测试调度体系。
- [ ] 必要回归聚焦 checkbox/switch/field/focus/ScrollArea/布局；不顺带修已知无关 Dialog/Select 基线。全量未跑明确记录。
- [ ] 保存唯一外部 status.md 的短增量与本片结果，提交独立验收请求；主控目视真实截图。96 DPI 受限结论，不覆盖150%/HC/IME/读屏/全平台。

## 执行与止损
复用当前 Workspace 创建一个本片 UI 实现负责人，原 ScrollArea 失败历史不清零也不原样续派。普通实现约10–15分钟应出现有意义的代码/测试增量；若无增量或上下文耗尽，保存短状态/最小缺口，不无限恢复历史。模型/通道故障不自动换主控或备用。Windows VM 当前已停，可按已有正常生命周期启动并持锁自测；不得重建、改安全设置或绕过上游来源限制。
