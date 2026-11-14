# M2 原生 ScrollArea 实施计划（纵向有限视口首片）

> 单负责人连续实现；沿用已批准 M2 路线与既有 managed/host prepare→apply→accept→ordinary turn
> 合同。本片只做纵向、有限高度、普通内容（非 virtualList 替换）；不新增 NodeKind、不改 wire ABI。

## 目标与边界
- 目标：有限长表单/普通内容在**真实 HWND viewport** 内纵向滚动；内容子树持久，滚动只改几何与裁剪，
  不重建 EDIT、不丢草稿/选区/Undo、不运行用户 view 或改业务 State。
- 首片：纵向；viewport 高度有限（显式 height，1..MaxScrollAreaHeight DIP）；内容按**可用宽度**测量
  高度；滚动条占宽纳入测量并单调决定，避免来回抖动；offset 在 [0, range] 夹紧。
- 不做：水平滚动、触摸惯性、自定义覆盖式滚动条、大型虚拟化、嵌套 ScrollArea（prepare 明确拒绝）、
  自动改旧 Dialog 尺寸策略、删除既有超高拒绝门。
- 不宣称与 shadcn 上游逐像素一致；不重取上游源码（来源 metadata 仍未核实）。

## 结构（无 ABI 变更）
- `standard.scrollArea(children, height = <DIP>, key)`：
  - 根节点：`NodeKind.column` + `UiRole.scrollArea` + 显式 `styles.height`；
  - 唯一子节点：`NodeKind.column` + `UiRole.scrollAreaContent`，承载普通子树。
- 不新增 typed sidecar（不同于 popover/select）：viewport/内容全部由既有 merged entity 树 +
  role + layout 推出，故 **NodeKind/wire 不变**。
- 能力：`BackendCapabilities.scrollAreas: set[ScrollAreaFeature]`（`saVertical`），Win32 声明支持；
  其它后端默认不声明 → prepare 阶段明确拒绝，不把 `overflowHidden` 放宽成假滚动。

## 几何（纯函数，可跨平台单测）
- 复用 `overlay_geometry.planOverlayGeometry` 的单调 bar 决策与夹紧：bar 只增不减、最多 4 轮、
  以最终 viewport 宽度复测内容高度、range 非负、offset 夹紧。
- 纵向专用包装 `scroll_area_protocol.planVerticalScroll`：仅纵向 bar；若内容宽度超过可用宽度 →
  **明确拒绝**（不发散成水平裁剪），并给出宽度/需要的诊断；viewport 高度非法/非有限 → 拒绝。

## 构造期与 prepare 期拒绝
- 构造：空 children、缺失/非正/越界/非有限 height、内容节点不是 column、内容带第二个滚动根、
  role 被误用 → `ValueError`（经既有 UiError 边界）。
- prepare：后端不支持 `saVertical`、嵌套 ScrollArea（祖先已是 scrollArea）、role/layout 组合非法、
  内容宽度超可用宽度 → 失败候选（拒绝 revision，不发布、不重建）。
- 资源/失败：viewport 与内容共用既有控件资源回执；滚动失败不改 accepted、不写假 offset；
  退出后 liveWindows/liveFonts/liveRoots 归零。

## 交互（Win32）
- 滚轮：view→scroll root 路由；EDIT 自身的滚轮/编辑按键语义不被抢；系统滚动条（WS_VSCROLL）由
  既有消息泵处理，不新增第二泵/私有 timer。
- 键盘：PageUp/PageDown/Home/End 在 viewport 聚焦时滚动；Tab 焦点进入视口外控件时自动显露
  （只改 offset 与几何，不改业务 State）。
- 嵌套容器：首片不支持嵌套 ScrollArea；ScrollArea 内允许普通列/卡片/字段与原生 EDIT。

## 集成示例
- `examples/ui_controls/scroll_area.nim`：页面长表单（缩窄与短窗口可达）+ Dialog 内有限高度
  ScrollArea（标题/footer 常驻，底部按钮可达；保存拒绝与恢复；Esc/Tab/模态门控沿既有合同）。

## 验收
- 共享：结构化拒绝矩阵、能力拒绝、纵向几何（bar 单调/夹紧/宽度复测）、offset 夹紧。
- 原生：真实 wheel/滚动条拖拽/Tab 显露/PageDown、同 EDIT 身份与草稿/选区/Undo、Dialog 内作用域、
  失败候选不发布、资源归零；浅深与窄短窗截图（由主控目视，不以像素脚本代替）。
- 回归：Popover/Dialog/Select/virtualList 受影响套件按依赖复用已证结论，不重跑无关失败。
