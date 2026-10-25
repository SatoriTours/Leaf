# 松石 Win32 原生开发状态

**结论：表单深色细节、列表与生成模板主题已落盘；列表焦点修复、Windows 全套及三主题真实入口开发自测均通过。整套 App 风格尚未完成，独立功能／视觉验收未执行。用户确认 Pi 依赖已更新、新会话生效，并明确要求本次不再测试、沿用已有证据提交代码；不将未执行项记为通过，不另发版本。**

## 最新续接：App 风格推广与恢复复测

- 深色 EDIT 占位提示改用主题辅助文字色，仅覆盖空值／未聚焦的 cue 绘制；完整提示仍存于原生 EDIT，实际输入／选区／IME 不接管。深色标题栏通过可选 DWM 属性启用，不支持时保留系统外框，高对比时撤销深色标记。
- `native_list` 接入可选择的浅／深／系统主题、标题／辅助说明／错误色、96×32 DIP 保存按钮及 40 DIP 输入；保留 96 DIP 行高、SQLite 保存边界及有界回收。
- 新生成 scaffold 显式选择浅色主题；框架默认仍是系统外观。导航由未实现的 ghost 改为原生支持的 secondary；标题、错误与次级动作使用共享语义，CRUD 保存／取消紧凑化。新增测试运行真实生成物，验证导航切换、空值错误与 SQLite 保存，不通过源码 grep 代替功能检查。
- **修复前全套自测：**Linux 官方 runner 一次完整通过 150 文件，1254 OK、0 FAILED；5 项平台／环境前置跳过，分别是两项 PowerShell fixture、Git 环境布局、OpenSSL CA 和 Application Git 路径发现测试。Windows 官方 19 文件 161 OK、0 FAILED、0 SKIPPED。三主题的表单、列表和真实生成 App 均编译成功。这些结果只对应 `fa94712283666609dc54fb09f357ea277d332d26ccee3e1a669f1f0567e35f49`，**不代表之后焦点修改已通过**。
- 三主题真实表单键鼠保存／错误／dirty／恢复及正常关闭通过。开发者查看深色正常／错误截图，确认占位提示可读及深色原生标题栏：[深色 v3](previews/native-win32/forms-dark-v3.png)、[深色错误 v3](previews/native-win32/forms-error-dark-v3.png)。截图仍为 96 DPI 开发实拍，不是独立验收。
- **真实入口发现缺陷：**列表连续键入后点击复选框，状态能更新，但接着保存未到达；正常关窗后进程仍未退出。诊断 trace 证明文字和通知已到模型、尚无保存事件；GDB 将忙循环定位至 USER32／`DefSubclassProc` 的 `WM_GETDLGCODE` 焦点遍历。新增有界回归先检查安全遍历前提，避免在测试内永久阻塞。
- 全局／按子树保持 `WS_EX_CONTROLPARENT` 会绕过既有列表 viewport 的 Tab 入口，`test_win32_list_keyboard` 明确失败，不能接受为修复。已调整为**仅真实行控件持焦时**开启递归，在 `WM_SETFOCUS`／`WM_KILLFOCUS`、原生处理之前使用下一焦点同步；保留原有 viewport Tab／方向键入口。用户授权启动原 VM 后，此最后策略在真实 `GetNextDlgTabItem`、既有完整 Tab／方向键回归及真实鼠标路径上均已 GREEN，未放宽原断言。
- 前次复测前，既有 `leaf-a2-windows` 曾自行退出，SSH 12222 拒绝连接；保留当时未运行的结果。用户随后明确授权后续按需启动、测试后关机，本轮使用 `docker start` 复用原 VM 完成复测；不重建、不安装工具或改认证。普通 pause 仍占 RAM，不作为关机替代。
- 本地补测：列表模型／实际 headless 入口／生成物主题共 3 文件、17 OK；恢复前的 Windows-target C codegen 仅为早期检查，已由下列真实 Windows 编译／执行结果补齐。原有 UnusedImport 等编译警告未顺带清理。

本次已实际编译／运行的源码归档：`506209e99505467ef7df9cae34f45f98a50c54c145c3832d977648398c485b22`。工件位于 `~/.local/state/agent-artifacts/leaf/2026-10-25-app-polish/`，原始 Windows 证据在持久环境的 `shared/evidence/`。

| 恢复后开发验证 | 本次快照结果 |
| --- | --- |
| 受影响回归 | `app-polish-resume-focus`：list_example／list_keyboard／skin 三文件通过，8 OK；包括真实安全遍历、40px EDIT 与旧 viewport 键盘入口 |
| 官方 Windows 全套 | `app-polish-resume-full`：未经修改的 `scripts/test_win32.nim`，19 文件，161 OK、0 FAILED、0 SKIPPED，编译／运行均退出 0 |
| 实际编译产物 | 表单、列表、真实生成 App 的浅／深／系统三主题共 9 个 EXE，均来自上列归档，逐文件验证源码 hash |
| 真实列表流程 | `app-polish-resume-visual2`：鼠标聚焦、SendKeys 输入、切换完成、保存、滚轮加载后续行、同库重开值／复选状态；三主题通过 |
| 真实生成 App | 同一 visual2：添加任务、搜索过滤、切到设置、Notes 空值保存拒绝／草稿保留、改正保存；三主题通过 |
| 正常退出 | visual2 的列表／重开／生成 App 共 9 个进程均正常关闭退出 0，forcedStops 为空；`app-polish-resume-forms` 的 3 个表单也正常关闭退出 0 |
| 真实表单回归 | 同一 forms：三主题空值拒绝不计次、纠错保存、通知 dirty／恢复均通过；6 张实拍；非提权 Session 1 |

早一次恢复探针的 PowerShell 计数数组未初始化，第二次运行抛重复 pid 键错误；另有中文 JSON 控制台编码取回失败。这些是测试包装器问题，不是产品 GREEN：保留原结果、按已核路径及参数定点终止遗留进程，修正数组初始化／资源 finally 和 ASCII JSON 转义后，以上 visual2 完整通过，不改系统编码或认证。开发者已查看浅／深／系统列表及生成 App 关键页面实拍；深色普通 checkbox 和滚动条仍使用系统外观，页面留白较多，不能宣称完整 V3 工作台。

当前 `.nim` 已核与本次已测归档一致，之后仅更新文档／截图。原 Pi 依赖错误保留为历史记录；用户确认已更新、新会话生效，本次按明确要求不再启动验收或复测。原生 ComboBox、现场 IME／DPI／高对比及独立验收仍未完成。

下文保留前一片的实现与证据，不将旧快照当作最新快照验证。

## 当前实现

- `Application.withNativeTheme(systemTheme | matsuLight | matsuDark)`：启动时选择外观。默认系统外观不变，仅映射 Win32，不承诺运行时主题切换。
- `native_theme.nim` 提供语义 RGB 色板及 DIP 尺寸；皮肤借用 stock GDI 画刷／笔，绘制后恢复 DC，不保存 Nim 对象指针。
- 真实 EDIT：40 DIP 外框、圆角非客户区、左右留白与字体驱动的垂直居中。客户区文字、选区、滚动、光标与 IME 仍由系统 EDIT 处理，不是自绘输入控件。
- BUTTON：保存／重置 96×32 DIP，5 DIP 圆角、8 DIP 间距；主次、悬停、按下、禁用及键盘焦点绘制。按钮用 12 DIP 字体；自动宽度按同一字体和内边距测量。
- 通知开关仍是原生自动复选 BUTTON，仅 custom-draw 轨道与圆点；点击区域默认至少 40 DIP 高，保留原生键盘／可访问性语义。普通 checkbox 保留系统 glyph。
- 确定进度条按真实 PBM 范围和值绘制主题轨道与填充；原生 marquee/spinner 保留系统动画，不冒称其已完成主题映射。
- 字体沿用 Windows 消息字体家族：正文 14、标题 24 / 600、说明及按钮 12 DIP。同一 `NativeMeasure` 持有分角色字体，实际测量／控件安装共用字体；删除失败保留所有权供重试。
- `text(..., variant="primary" | "secondary" | "danger")` 映射标题、次级说明和错误文字；`input(..., variant="danger")` 映射错误边框。仅主题开启时按控件类型声明支持，不开放任意字体／颜色／圆角 decoration。
- 示例空名称保存失败时保留草稿、不增加次数，显示就地错误；改正后清除名称错误。保存仅记录本页姓名／通知快照，设置变更显示未保存，恢复原值后重新显示已记录，**不写数据库**。
- 占位提示仅在空值／未聚焦时按语义辅助色重绘；深色标题栏为可选 DWM 装饰，失败回退原生框架。
- 高对比或查询失败时回到系统绘制；字体／设置变化重新计算 EDIT 非客户区。实际高对比切换仍待现场验收，不把代码分支当实测。

## 前一片快照与证据（保留历史）

基线 `dd8f0e84d1e19abdbf8ac1328701247d4d14fe07`；前一片已编译源码归档：

```text
77ed5bd2ed57d6593cda8aea614f2a9358a68c51d085ef057127e796b44f47ce  source.zip
```

证据目录：`~/.local/state/agent-artifacts/leaf/2026-10-25-native-skin/continuation/`，含源码逐文件 hash、最终归档、命令日志、脚本和 `checkpoint.json`。文档更新不改变该产品源码快照。

| 开发验证 | 结果与限制 |
| --- | --- |
| Linux Nim 2.2.6 官方全套 | 149 个文件覆盖完毕，日志合计 1250 OK；首次官方命令在 900 秒上限于 scaffold 文件中途终止，使用官方 runner 的临时精确过滤副本补跑最后 24 个文件，退出 0；不是一次未中断的全绿运行 |
| Windows 官方 runner | 前 16 文件及续跑最后 3 文件合计 19 文件、159 OK；新增动态样式测试夹具最初缺 startup Scope guard，补齐后通过 |
| 最终输入双边框修复 | 受影响 skin / input / measure / controls 共 4 文件，57 OK、0 FAILED、0 SKIPPED；实际重新编译并运行 |
| 主题测试 | 实际 HWND、语义颜色与字体、40 DIP EDIT 居中、无内部第二边框、按钮几何、开关与进度像素、样式切换不重建 HWND／丢选区、字体测量缓存、重绘 GDI 稳定及关闭资源清零 |
| 字体生命周期 | 分角色实际测量，删除失败仅保留失败字体，再次关闭释放成功；系统字体原有测量／故障回归保留 |
| 浅色／深色／系统 EXE | 三版实际编译、开窗、键鼠交互、正常关闭，退出均 0 |
| 真实键鼠流程 | 聚焦 EDIT、Ctrl+A / Backspace 清空、保存不计次、键盘改正并保存、点击通知产生脏状态、恢复通知回到已记录；三版均通过 |
| headless 与模型 | `--check`、空值阻止与快照模型测试；不替代原生交互验证 |
| 格式 | `git diff --check` |

Windows 使用既有持久 VM、非提权交互 Session 1、SDK Nim 2.2.6 与既有 GCC 11.1.0，未安装工具或改环境。原始证据标签：`native-skin-continuation-final`、`native-skin-continuation-rest`、`native-skin-border-green`、`native-skin-border-visual`，保存在 `~/.local/share/leaf/windows-acceptance/shared/evidence/`。

## 真实截图与视觉边界

- [浅色](previews/native-win32/forms-light-v2.png) · [深色](previews/native-win32/forms-dark-v2.png) · [系统对照](previews/native-win32/forms-system-v2.png)
- [浅色错误态](previews/native-win32/forms-error-light-v2.png) · [深色错误态](previews/native-win32/forms-error-dark-v2.png)

以上由前一片真实 EXE 抓取，**96 DPI、656×759 原始 PNG**，开发者已逐图查看；不是 HTML、不是高 DPI 成品截图，也不是独立视觉验收通过。根 README 与历史截图未替换。

输入框居中／圆角、字号层级和开关已比首片实拍改善，已修复系统 EDIT 内部第二边框。以上 v2 截图仍是旧 cue／浅色标题栏，新的深色细节见本页顶部 v3。页面仍为能力验证表单、留有较多空白，不能宣称与 V3 工作台视觉等效。

## 失败与修复记录

- EDIT 居中测试先 RED（顶部／左右内边距 0），实现非客户区布局后 GREEN。
- 开关／进度绘制先 RED；旧 checkbox 的 `SetWindowTheme` 禁用路径让 toggle 不再发 custom-draw。只为普通 checkbox 保留兼容路径，toggle 保留 v6 主题通知后 GREEN。
- 字体／错误态先 RED；语义属性在兼容 host normalization 被过滤，修正识别范围后字体通过；首次控件的 entity 已含新属性，不能靠 old/new props 判断是否安装标记，改为核对实际 HWND 标记后颜色通过。
- 全套 Windows 新动态样式夹具缺 startup Scope guard，是测试初始化错误；补齐夹具，产品不放宽守卫。
- 首次窗口探针用跨进程 `SetWindowText` 未触发用户编辑路径，故验证失败；改为实际鼠标聚焦与 SendKeys，不以注入模型 setter 冒充用户键盘输入。
- 实拍发现内部第二边框：仅检查公开 WS_BORDER 位无法捕获，改为真实客户区边缘像素回归并看到 RED；EDIT 创建时不设置内部旧边框标志后 GREEN，最终实拍复核已消除双框。

首片历史证据仍保留于父目录：135 项相关 Linux 测试、157 项 Windows 测试及旧 `forms-light.png` 等，只代表续接前的基础实现，不替代当前快照。

## 未完成与真实阻塞

- **独立功能／视觉验收未执行：**此前旧 Pi 会话定点 resolve 报 chord／context `MODULE_NOT_FOUND`。用户随后确认依赖已更新、新 Pi 会话生效，并明确要求本次不再测试、直接提交；没有新开会话、安装依赖或换通道验证该更新。保留已有开发证据，不宣称独立验收通过。
- 真实中文 IME、100 / 150 / 200% 及混合跨屏 DPI、高对比切换、屏幕阅读器仍待现场；当前键盘测试不是中文 IME 证据。
- 原生 ComboBox 与向下优先／空间不足上翻尚未实现；模式仍用按钮切换。
- 列表／导航与生成模板的本轮真实入口／开发视觉复测已通过；独立验收、最终页面层级和 README 高 DPI 实拍仍未完成。按既有分期先闭合表单关键验收，不能把本轮组件进展当整套 App 完成。

## 资源与续接

最新 9 个列表／生成 App 及 3 个表单均正常关闭退出 0；失败探针按精确 PID／路径清理的证据保留，不把强制结束计为正常通过。收尾核实无运行中的 Leaf 进程、无其他测试任务或可见 App；仅见 Windows 自身 Edge 更新任务，不针对它杀进程。先取回证据，再按用户新授权正常 `docker stop leaf-a2-windows`，已核 `exited / running=false / pid=0`，三个映射端口均关闭。本地无本任务常驻服务；保留 VM 磁盘、SDK、缓存及历史证据，不删除环境。新的按需启停约定已记录到[Windows 环境](../windows-environment.md)及持久根 README，不把普通暂停当作释放 RAM。后续提交／推送／CI 与空间收尾以 Git 及空间外交付记录为准；本次按用户明确要求不再复测。实现仍由原会话单写端负责，usage 未知。
