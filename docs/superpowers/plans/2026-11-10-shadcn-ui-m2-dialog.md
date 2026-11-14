# M2 原生模态浮层与 Dialog 实施计划

> 单一实现负责人连续完成实现、自测和普通修复；使用 executing-plans/TDD。
> 用户已在路线分析后确认继续进入M2；沿用原设计，不重复审批M0/M1，不提交。

**目标：**交付可真实打开、编辑、嵌套、请求关闭及恢复焦点的Dialog/AlertDialog，形成Select可复用的浮层生命周期基础。
**架构：**同一Runtime/BackendSession/普通消息泵，原生owned窗口承载子树，不用MessageBox或裁剪于父容器的假浮层。准备/接受/回滚/退役与既有宿主事务整合；业务事件仍只在安全turn投递。
**技术：**Nim2.2.6，Win32，既有typed host协议和原生EDIT。
**依据：**../specs/2026-11-07-shadcn-native-ui-design.md §6.2–6.3、§8 M2。本文件是获批路线的首片技术细化，不把整阶段宣称完成。

## 边界与技术选择
- 现有column/row只是普通子窗口；不能仅增加ui_role而让非Win32后端静默当普通布局。浮层语义须显式typed传递、预算验证、能力拒绝；如需新增NodeKind/EventKind只能尾部追加，保持已有枚举与ABI。
- 首片只做模态Dialog和AlertDialog。Select锚定/菜单键盘模型随后做，不顺带实现整个M2或非模态窗口。
- open受控：触发按钮在调用方置true；Esc/关闭按钮/遮罩点击只提出false请求。回调被忽略则保留已接受open，不自行消失。不能把open复用成checked或字符串解析。
- 公开构造器至少包括dialog、alertDialog以及标题/说明/内容/操作区组合；明确open/onOpenChange、稳定key、初始焦点与恢复焦点目标。准确签名由实现者按现有不可变Node和typed sidecar惯例落地并以共享测试固定。
- 普通Dialog的应用内遮罩点击可请求关闭；AlertDialog不因遮罩关闭，Esc请求取消。系统关闭/显式取消不暗中执行业务确认。
- AlertDialog初始焦点优先取消/安全操作，不默认聚焦危险确认。空对话框也要有合法焦点目标。
- Tab/Shift+Tab仅在顶层模态作用域内循环；背景鼠标/键盘不可激活。焦点通过合法系统/UIA操作进入背景也必须符合模态约束。
- 关闭后恢复仍存在且可用的触发器；触发器删除/禁用时选确定的合法回退。嵌套只关闭最上层，关闭内层恢复外层，不误启用主窗。
- 复用现有原生Input/Textarea，不换EDIT provider；主题变化不重建活跃EDIT、不丢草稿/选区/Undo。跨关闭重建不承诺Undo持久化。
- owned窗口居中于owner并约束到工作区；owner移动/最小化/关闭、窗体尺寸/内容变化、DPI消息时同步，不起第二套消息泵。96DPI实窗先验，高DPI合成测试不算真实150%验收。
- 不承诺本片具备完整半透明遮罩、CSS阴影/开闭动画；先核固定上游dialog.tsx/alert-dialog.tsx，将差异明确写入文档，不自行用无关装饰替代。
- 系统UIA名称/角色/窗口及模态属性按真实能力验证；不能用Pane名称或内部断言冒充Dialog语义。若需要替换EDIT provider或新增大范围自定义provider，报告主控决策，不绕开限制。

## 文件与责任
- 新增纯浮层契约/状态模块（建议src/leaf/overlay_protocol.nim）及Win32窗口所有权模块（建议src/leaf/backends/win32/overlay_host.nim）。
- 必要接入：src/leaf/core.nim、ui.nim、ui_contract.nim、styles.nim、host_protocol.nim、host_reconcile/native_host_adapter及backend能力检查；Win32 host/backend/calls/api/skin/native_layout的最小修改。
- 新增tests/nim/test_ui_dialog.nim、tests/windows/test_win32_dialog.nim、tests/windows/dialog_client.cs、examples/ui_controls/dialog.nim；必要修改既有协议/兼容/故障测试。
- 更新docs/ui/README.md、固定上游vendor manifest/许可证映射和本计划进度。先独立示例闭环，不重写已验收目录/账户页/Notes。
- 不做范围外重构。现有大量未提交文件全部保留；先记录起点hash/差异，不覆盖未知成果。

## 执行与验收清单
- [x] 核固定上游42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9/new-york-v4的dialog/alert-dialog文件，保存输入及许可归属；确定typed API与拒绝矩阵。
- [x] TDD共享契约：open控制/忽略关闭请求、错误属性/非法焦点目标/预算、hostCompatible不丢语义、未支持后端拒绝、稳定身份及退役事件失效；先记录有效RED再实现。
- [x] TDD原生生命周期：真实owned HWND、创建/发布失败回滚、关闭/卸载/owner销毁、重复开关与嵌套、失效焦点回退；验证窗口/字体/provider等无泄漏。失败不得留下禁用owner或不可见模态窗口。
- [x] 真实编辑与键鼠：打开、Tab/Shift+Tab、Esc、背景点击阻断、Dialog遮罩关闭请求被拒绝、AlertDialog遮罩不关闭、显式确认/取消各一次；EDIT原生行为保持。
- [x] 原生消息重入期间只记录请求；普通turn才调用业务。prepare失败不能抢焦点/禁用owner；新旧revision事件不能投递到替换实例。
- [x] 独立示例浅深、窄窗、错误表单、嵌套、owner移动/最小化/恢复；跨进程CLR UIA及真实截图。确认窗口不超工作区，不以强刷截图掩盖正常绘制缺陷。
- [x] 执行受影响共享/原生回归并冻结源码/EXE身份。必要时官方全原生runner；既有旧hash的42套252项不是新代码的通过证据。
- [ ] 独立视觉/功能验收，主控核diff及证据后收口；缺必需环境或能力标阻塞，不宣称整个M2完成。

## 进度（修复轮 r1，自测通过待独立复验）
- 首片初审 P1-1..5、P2-1..3 与本轮决策项已落实：UIA 方案 A（仅 WS_CAPTION + 创建即有效
  NCCALCSIZE，ControlType.Window/WindowPattern/IsModal 断言）、非置顶 Z 序、超高内容显示前拒绝、
  prepare/apply/turn 三段事务（发布不在 accept 内）、原生+UIA 输入门控、资源成功回执与可重试清理、
  真实 DC_BRUSH 绘制、示例分层 dismiss、动态标题同步、失效触发器等。
- 证据：20 项 Dialog 原生检查、全原生 44 套 272 检查、跨进程 UIA 36 项观察 + 9 张截图、
  24 个共享套件原始日志已下载到证据根。仅 96DPI；150% DPI/HC/IME/读屏与全项目脚本未验证。

## 环境与执行约束
当前workspace wks_6f1e22dd96509cec，cwd /home/jimxl/projects/leaf，main基线c10f3417e287e9fe999d954e76523f7357b5a1af，git-dir/index为.git/.git/index。不建分支/worktree/空间，不提交/推送，不派生。
Windows既有LeafTester@127.0.0.1:12222，source=C:\LeafTests\work\shadcn-ui-1107\source；工具与脚本说明在/home/jimxl/.local/share/leaf/windows-acceptance/README.md。秘密不读取/输出；不安装依赖，不改缩放/输入法/认证。
复用control/guest-ps.py与run-guest-script.py，GUI串行、唯一tag、脚本必须使用TAGPLACEHOLDER及成功stage=observations-collected；检查真实exit。命令显式有限timeout，不启动无界探针/后台轮询。
现有唯一状态索引 /home/jimxl/.local/state/agent-artifacts/leaf/2026-11-07-shadcn-ui-design/status.md；新证据使用m2-dialog-*前缀，临时脚本/tmp，保留失败证据。共享全量/跨平台/Actions及真实DPI/HC/IME/读屏仍未完成。
普通实现约10–15分钟无有效落盘需保存缺口，不反复读取全史；同类根因两轮未收敛先交主控分析。通道不可用或架构阻塞立即报告，不自行换模型或缩成只有基础设施的“完成”。
