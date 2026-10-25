# 松石 V3：交互细节打磨

沿用用户认可的 V2，不换配色，不改正式 App。入口：[V3 离线 Demo](leaf-studio-v3.html)，保留 [V2 对照](leaf-studio-v2.html)。

## 本轮变化

| 细节 | V2 问题 | V3 处理 |
| --- | --- | --- |
| 保存／错误反馈 | 页面顶部插入提示，挤动按钮 | 在操作区下方就地反馈；窄屏名称提示预留两行，避免报错时操作区收缩 |
| 保存状态 | 修改通知后还显示旧成功；改回原状态仍提示未保存 | 对比本页保存快照，更新草稿标记与提示；恢复原值后重新显示已记录 |
| 错误归属 | 候选失败也把有效名称标红 | 只有名称为空时关联名称错误；候选失败独立说明，保留草稿 |
| 键盘操作 | 列表重绘后焦点丢到页面 | 保存后聚焦同行备注；该行移出筛选则聚焦下一行，无剩余行则聚焦筛选器 |
| 搜索空态 | 只有说明文字，没有恢复入口 | 增加搜索图标、层级化文案与“清除筛选”，恢复后聚焦搜索框 |
| 开关 | 36×22px 区域较难点击 | 保持 36×22px 轨道，扩大至 44×40px 点击区 |
| 窄屏列表 | 横向滚动不明显 | 增加提示；表格区域可键盘聚焦并用方向键滚动 |
| 长文本 | 活动与时间共用未约束文本节点 | 活动文字独立包裹并允许换行，时间保持完整；验证 80 字符不换词模型预览不撑破窄屏 |

用户反馈按钮过大后，在同一 V3 内收敛操作密度：保存／重置由 **124×40px 改为 96×32px**，圆角由 6px 改为 5px；文字由 14px / 500 改为 12px / 400，图标由 16px 改为 14px。所有 `.btn` 操作按钮统一采用 32px 高；输入框维持 40px，开关点击区不缩小。按钮间距仍为 8px，操作区上下内边距由 20px 减至 12px，反馈区底部留白同步减小。

[查看紧凑深色操作区](previews/v3/actions-compact-dark.png) · [浅色操作区](previews/v3/actions-compact-light.png)

未引入虚假加载过程、数据库连接或原生能力声明。全部数据刷新后还原。

## 下拉菜单修订

用户截图指出：外框虽套用了皮肤，展开菜单仍是系统蓝色选中条，焦点存在分离的双层边框，选项还包含调试用代码名。

- 使用原生 `<select>` 的渐进增强能力 `appearance: base-select`，保留浏览器的键盘、选择与表单语义，不另写自定义列表框。
- 统一菜单表面、细边框、6px 弹层间隔、轻阴影、浅绿选中行及右侧勾选标记；下拉箭头改为细线。
- 展开方向优先向下，仅下方空间不足时翻到上方。用户指出异常后，实测发现浏览器默认 `position-try-order: most-block-size` 会选择空间较大的一侧，即使下方已经足够；现覆盖为 `normal`，保留原生避让候选。12 项方向回归覆盖模式与列表筛选、浅／深色、1440 / 390px 及底部空间不足时的上翻；实际菜单键鼠交互专项同时通过。本次增量证据：`~/.local/state/agent-artifacts/leaf/2026-10-25-select-direction/`。
- 焦点改为贴合边框的单圈提示；高级选项使用 32px 高度。选项只显示“实时同步 / 去除首尾空格 / 保持模型值”，程序值不变。
- 同套菜单样式覆盖列表筛选；不改变输入模式与筛选行为。
- **兼容边界：**展开菜单着色需要浏览器支持 `appearance: base-select`。不支持的浏览器保留系统下拉菜单，不能宣称跨浏览器外观一致；未验证 Win32 原生 ComboBox。
- [浅色组件预览](previews/v3/select-component-light.png) · [深色组件预览](previews/v3/select-component-dark.png)：从实际 Demo 复用 CSS 与 `<select>`，在独立画布实际展开后截图，便于查看组件，不是 Win32 截图。另保存实际完整 Demo 中的展开图与窄屏证据。
- 在 Chromium 152 的实际 `file://` 入口检查浅／深主题、1440 / 390px 下展开菜单、选中底色、菜单边界、鼠标选择、空格打开、方向键选择、Enter、Escape、Tab 及模式生效；14 项细节、36 项交互和紧凑按钮几何检查同时复跑。
- 最新证据：`~/.local/state/agent-artifacts/leaf/2026-10-25-select-refinement/`。复跑下拉专项：`LEAF_DEMO_EVIDENCE="$HOME/.local/state/agent-artifacts/leaf/2026-10-25-select-refinement" timeout 60s node "$HOME/.local/state/agent-artifacts/leaf/2026-10-25-select-refinement/leaf-select-check.cjs"`。

独立验收的环境阻塞仍未解除，没有换通道重试；上述是原型自测和本人视觉查看结果。

## 自测与证据

使用 Chromium + Playwright 访问真实 `file://` 入口，不将 HTML 预览当作 Win32 验收。

- 14 项细节回归：反馈位置、设置状态、错误归属、开关点击区、窄屏错误提示、同行及移出筛选后的焦点、清除筛选、80 字符长文本。
- 原有 36 项交互检查：双主题、中文／Emoji、表单模式、列表搜索与保存、组件页及 1440 / 1024 / 768 / 390px 页面溢出检查。
- 几何检查：双主题四档宽度、按钮尺寸与圆角、列表保存前后宽度稳定、唯一 DOM id。
- 预览以 2× 像素密度输出；人工查看浅色、错误、空态与窄屏渲染，未用像素脚本代替视觉判断。
- 首轮证据：`~/.local/state/agent-artifacts/leaf/2026-10-25-skin-v3/`。按钮收紧后的最新证据：`~/.local/state/agent-artifacts/leaf/2026-10-25-compact-buttons/`，包含脚本、日志、改前 HTML、差异及快照 hash。最新几何检查明确断言 96×32px、5px 圆角、12px 字号、400 字重、14px 图标及 12px 操作区内边距；14 项细节与 36 项交互回归重新通过。

复跑（在仓库根目录，使用证据目录中的脚本副本）：

```bash
EVIDENCE="$HOME/.local/state/agent-artifacts/leaf/2026-10-25-compact-buttons"
LEAF_DEMO_FILE="$PWD/docs/design/leaf-studio-v3.html" timeout 60s node "$EVIDENCE/leaf-v3-detail-check.cjs"
LEAF_DEMO_FILE="$PWD/docs/design/leaf-studio-v3.html" timeout 60s node "$EVIDENCE/leaf-v3-compact-geometry-check.cjs"
LEAF_DEMO_EVIDENCE="$EVIDENCE" timeout 90s node "$EVIDENCE/leaf-v3-browser-check.cjs"
```

脚本依赖当前机器已有的 `/usr/bin/chromium` 与 `/home/jimxl/projects/暗黑2/node_modules/playwright`，没有为 Leaf 新增运行依赖。

## 独立验收与未验证项

已尝试按配置的功能验收角色启动只读验收（Pi / `open-design/deepseek-v4.1-flash`，high），但子进程未启动：

> Background children require the host npm package (@earendil-works/pi-coding-agent) with its dependencies; the installed package does not provide @earendil-works/chord, @earendil-works/chord/context.

运行标识 `fda1194e-40b7-404a-a920-fa5b55d485f0`；随后状态查询为 `Async run not found`。无独立测试结果，不宣称独立功能或视觉验收通过；未改依赖、重启环境、切换通道或模型绕过。

当前结论：**原型自测通过；独立验收阻塞；等待用户视觉反馈。** 原生 Win32、真实 IME、跨 DPI、Windows 高对比及辅助技术实机验收仍未进行。正式原生皮肤和 README 真实截图未改。
