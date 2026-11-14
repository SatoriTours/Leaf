# 原生账户设置视觉实施计划

> **For agentic workers:** Use superpowers:executing-plans inline. 单实现负责人连续完成，自测后独立验收；用户已批准视觉方向及继续开发，不重复审批，不提交。

**Goal:** 在真实 Win32 浅／深窗口还原用户认可的 account-settings.html 视觉稿，而不是扩充杂乱的组件测试页。
**Architecture:** 保留 HWND EDIT、现有 Runtime／布局引擎及 owned 外侧焦点环。类型化 Label／Field／Textarea 复用原生 text／column／input；只在 shadcn 主题显式选择中文无衬线字体，测量与实际控件使用同一 HFONT。Card 用现有容器组合布局；局部 GDI 绘制细边框和分区 footer，不新增 WebView、CSS 引擎或全 Canvas 底座。
**Tech Stack:** Nim 2.2.6 / Win32 / GDI / 既有 Windows 验收 VM。
**Spec:** `docs/superpowers/specs/2026-11-07-shadcn-native-ui-design.md`；外部证据 `evidence/design-preview-01/account-settings.html`（已获用户认可）。

## Global Constraints
- 固定 shadcn-ui/ui@42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9、new-york-v4、Neutral。HTML 仅设计参照。
- 当前 workspace、main、既有脏修改保留；不提交、不创建空间／分支、不安装依赖、不改系统字体配置。
- 不改旧 system／matsu 默认字体、行为或枚举序号；新增枚举只追加。
- 设置模型只在内存保存；原生编辑语义、HWND／选区、已闭合焦点环与所测 UIA 不退化。
- 必需新语义严格验证，不支持不能静默替代。仅实现本页需要的垂直 Field，不宣称完整 Field／ARIA／读屏器覆盖。

## Review Focus
- 中文／英文／emoji 使用无衬线观感；测量、绘制同源。Windows 已确认有 msyh*.ttc；核实际 LOGFONT face，不臆测 CSS fallback。
- Textarea 换行输入／撤销／选区、无横向滚动；状态更新不重建 EDIT。空白／160／161 Unicode code points 的简介校验保留草稿；取消同时重置两个输入。
- Label → EDIT 的真实 UIA Name／LabeledBy、按钮 Invoke／禁用；完整错误描述关联仍单列缺口，不以内部 props 当 UIA 验收。
- 浅／深默认／焦点／错误／禁用以及 100%／150% DPI 的真实交互和截图；缺所需环境就标阻塞。
- 旧主题、焦点 popup、资源释放回归；全部源文件与构建 hash 对齐，测试范围诚实标明。

### Task 1：模型及标准 Field 接口
**Files:** `src/leaf/{ui.nim,ui_contract.nim,styles.nim}`；`examples/ui_showcase/model.nim`；`tests/nim/test_ui_{components,showcase_model}.nim`。
**Interfaces:** `textarea(value,onChange,key,placeholder,disabled,invalid,resetToken,height=64)` → native multiline EDIT；`label`、`field`、`fieldDescription`、`fieldError`；SettingsModel 追加 bio/savedBio、editBio/bioInvalid（最多160 code points，非 bytes）。
- [x] 先加失败测试：textarea multiline／reset／invalid／最低64 DIP、input 不能偷偷设 multiline、角色与 kind 匹配、label font role、两字段保存／取消／160／161／emoji。
- [x] 在 Windows Nim 下运行并保存 RED；最小实现后运行到 GREEN。

### Task 2：原生字体、Card 分区与账户页
**Files:** `src/leaf/backends/win32/{measure,backend,skin}.nim`；`examples/ui_showcase/{main,view}.nim`；`tests/windows/test_win32_ui.nim`。
**Interfaces:** `newNativeMeasure(..., standardFonts=false)` 仅 shadcn 显式启用 Microsoft YaHei UI；新增 label=14/500、hint=13/400 字体角色。Card 组合：外16 DIP、内部横向8 DIP，header额外顶8、content末16；分区 footer 以真实 child rect 定位分隔线（按钮顶前16），底留16。
- [x] 加 Windows RED：shadcn 实际 font face／weight、Textarea multiline／几何／选区保留；旧主题字体路径不变。
- [x] 实现字体、36 DIP Input/Button、96 DIP 本页 Textarea、24 DIP 标题、16 DIP CardTitle、14 DIP Label、13 DIP hint、紧凑分组及底部状态／取消／保存更改。
- [x] 页面32 DIP边距，独立页面标题及说明；设置页不再混入按钮目录或技术计数。Card圆角14是本页获批稿取值，不宣称完全等于上游默认值；系统窗口标题栏保留。
- [x] 自测模型／组件／Win32关键回归与资源清零；真实键鼠保存／校验／取消，100%浅深截图。
- [ ] 150%真实DPI：阻塞，VM唯一显示器96 DPI，不获授权改系统缩放。

### Task 3：独立验收和证据
**Files:** 唯一外部 `status.md`／证据索引，`docs/ui/README.md` 及来源清单增量。
- [x] 保存源／EXE hash、RED/GREEN、真实截图与所测 UIA；独立只读同模型审查关键交互及与认可稿的视觉差异。
- [x] 主会话检查 diff／证据，报告通过、不通过、阻塞；必要修复在当前实现端连续处理。没有整套证据不得称 M0＋M1 完成。
- [x] 保存证据后释放本任务临时资源；不停止 VM／共享服务，不清理历史。

## 独立视觉拒收后的有界调整
首轮100%布局及已测交互通过，字体视觉P1未通过。真实字体文件为YaHei UI Regular／Bold、PANOSE Sans、无嵌入位图；进程内选中字体／中文glyph正确，不能把请求名称当观感通过。raw STATIC／EDIT 对照表明标题700优于合成600；charset134与family别名没有决定性收益。独立复核建议只在shadcn把标题／CardTitle改700、per-font quality5改灰阶ANTIALIASED_QUALITY4，正文400不动、Label／Button不动，再看最终页，不再扩字体面板。不引入Noto字体资产或改系统配置；若仍不能接受，保留P1并合并呈报字体资产或原生近似的产品选择。

复验结论：首轮P1保留失败证据；Bold700／灰阶quality4后独立视觉P1已闭合，100%浅深可接受原生近似，无需新增字体资产。最终10套共享92项、Windows UI2项及9套host回归均通过；源码／测试546文件guest一致。完整UIA错误说明关联／IME／高对比／全项目Actions仍未完成。
