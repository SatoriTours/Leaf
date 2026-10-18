# 开发进度与下一步

验收记录日期：2026-10-18。固定代码与 CI 基线：`c207e48af8b33b8e6ecaf4dc1548ec9b2541b737`；本批后续文档、测试及 Win32 重绘修复不包含在该基线提交中。Windows 验证使用该归档加逐文件固定 overlay SHA；下列旧基线 CI 成功不代表后续修复的 CI。后续提交、推送及 CI 状态以实际 Git 历史与对应 head SHA 的运行记录为准。

本页汇总当前状态；日期化的计划、审查和验证记录保留当时输入、失败与限制，不能将其中早期“尚未合并”的描述当作当前 Git 状态。没有实机证据的平台不列为已验收。

## 当前交付状态

| 范围 | 实现与验收状态 |
| --- | --- |
| Nim UI、状态、事件、CLI、watch | 已实现，持续回归；默认桌面后端仍是 GPUI |
| SQLite Model、数据库迁移、CRUD 脚手架 | 已实现，当前提交的 Model 与迁移三平台 CI 成功 |
| 托管组件、State、ABI2 类型化增量宿主 | 已合入主分支；Linux 窗口及 Windows 任务示例 ABI1/2 已有证据，全平台矩阵未关闭 |
| 组件页面路由、保留/销毁策略 | Windows 任务示例的离开取消、隐藏继续和销毁重建已实测；完整路由输入矩阵、macOS、系统 IME 与跨屏 DPI 仍待验 |
| 组件任务与生命周期 | Task1–7 实现、最终修复和固定差异复核已完成，并已合并、推送；Win32 首轮失败已作测试修复，七套开发自测与独立复验均 96/0 通过，平台门仍未关闭 |
| Win32 原生表单 A2 | 标签重绘缺陷已修复；含新回归的八套开发自测及独立复验均 97/0，自然态文字完整，键盘/基础 UIA 通过；完整 H 门未完成 |
| GPUI SDK | Linux x86_64、Windows x86_64、macOS x86_64/aarch64 包及 SHA256 已发布；beta 指向当前代码基线 |
| 原生迁移 A3 | 原生虚拟列表、平台导航、Canvas/图表、完整纵向样例及 native 打包尚未完成 |
| Android B 与后续原生平台 | 尚未落地；不能由 GPUI 桌面 SDK 构建推断支持 |

代码边界：`src/leaf/backends/win32/capabilities.nim` 未声明 virtualList/scroll 能力；`src/leaf/pack.nim` 明确拒绝 native 打包；`src/leaf/targets.nim` 尚无 Android 构建目标。组件页面路由不等于原生导航栈，GPUI SDK 也不等于 native-only SDK。

## 当前提交的验证

2026-10-18 查询 GitHub，以下四个运行均为 completed/success，且 head SHA 与上述基线一致：

| 工作流 | 证据 |
| --- | --- |
| Nim + GPUI 构建与测试 | [39064572133](https://github.com/SatoriTours/Leaf/actions/runs/39064572133)：日志确认 102 个 Nim 套件通过，Rust 55 项通过 |
| Model 三平台回归 | [39064572131](https://github.com/SatoriTours/Leaf/actions/runs/39064572131) |
| 数据库迁移三平台回归 | [39064572140](https://github.com/SatoriTours/Leaf/actions/runs/39064572140) |
| Leaf SDK 发布 | [39064572160](https://github.com/SatoriTours/Leaf/actions/runs/39064572160)：四平台构建和 publish 成功 |

[滚动 beta](https://github.com/SatoriTours/Leaf/releases/tag/beta) 名称为 `Leaf beta.c207e48af8b3`，包含四个 SDK 包和四个校验文件。滚动 tag 后续可能变化；核对时同时使用上述固定提交与 CI 运行号。

同日 Linux 本地定向抽检（Nim 2.2.6、threads:on，不是本地全量重跑）：

| 套件 | 通过 | 跳过 |
| --- | ---: | ---: |
| `test_scaffold` | 18 | 0 |
| `test_migration_integration` | 22 | 0 |
| `test_component_task_shutdown` | 15 | 0 |
| `test_public_task_launchers` | 10 | 0 |
| `test_task_pump_compatibility` | 21 | 1 |

合计 86 项通过；唯一跳过项是未配置的可选真实旧库 integration。ABI2 C/Nim/Rust 布局 161 项与 `cargo fmt --all -- --check` 通过。该次 Linux 抽检未重跑本地全量、真实窗口矩阵或长期内存/硬件性能；后续 Windows 窗口补验另列下节，不混作同一运行。

本机 Nim 不在默认 PATH，使用已有 `/tmp/nim-2.2.6/bin/nim`。兼容性抽检首次无法加载桥接库；`ldd` 确认缺少 `libxkbcommon-x11.so.0`，仅为复测进程设置已有 `/tmp/mui-display/usr/lib` 为动态库目录后通过，没有安装系统软件或修改配置。这是本机环境记录，不是其他机器的路径约定；复现方法见[开发说明](development.md#本地工具链与动态依赖排查)。

## Windows 首轮补验（2026-10-18）

用户授权重建后，已在 worktree 外的持久目录安装 Windows 11 Enterprise Evaluation，验证 SSH、Nim 2.2.6、MinGW GCC 11.1.0/windres 2.36.1，启用 guest UAC 并重启。源码归档内 523 个常规文件经 Windows SHA256 复核，0 个不匹配。

官方 Win32 runner 在 Session 1、elevated=false 下实际运行：编译退出 0，运行退出 1，合计 **12 OK / 4 FAILED / 0 SKIPPED**。`test_component_host` 通过，`test_component_tasks` 失败后 runner 停止，其余五套此次未运行。失败涉及 hook 注入未命中、销毁计数、缺尺寸的测试夹具及带 UI guard 的错误消息断言；未修改产品或测试源码。完整环境、四项失败与日志位置见[Windows 持久环境与首轮结果](windows-environment.md)。该首轮失败不能由 CI 绿色替代或抹去。

后续只修复同一测试文件的观察边界、故障对象、尺寸夹具和异常链断言，Runtime/Host 实现未改。固定 c207e48 基线加测试 overlay 的真实 Windows 七套开发自测为 **96 OK / 0 FAILED / 0 SKIPPED**，Session 1/elevated=false；Linux 相关回归 31 项通过。相同测试 SHA 的独立功能复验也完整执行七套，96/0/0、compile/run=0/0，结论为“通过（仅本批修复）”；原会话已核对实际 diff、原始结果和覆盖边界。独立 Windows 日志位于持久根目录的 `shared/evidence/task-fixes-review/`，详见上述环境记录；Linux 31 项是开发者实跑、验收者日志复核，不称作独立重跑。H 门仍未关闭。

## Windows 真实窗口续验（2026-10-18）

复用同一 VM 和固定版本 SDK，Session 1/elevated=false，实际执行 GPUI ABI1/ABI2 的任务窗口：无后续点击自动完成、错误重试、离开取消、隐藏继续、销毁重建、Tab/Shift+Tab/Space 及在途关闭均通过，两个进程均退出 0。native_forms 的编辑、Enter 单次提交、Tab/Space 和基础 UIA 角色/值也通过；初始 UIA 代理缺失和跨进程旧 caption 读值的问题已纠正并保留原证据；该次初始窗口补验未修改产品实现。

**修复前原生视觉项曾不通过**：模型/EDIT/UIA 值正确，但自然完成态标签缺字，静置 2 秒不恢复，resize 才完整显示。该失败和原图均保留；随后定位到文本更新没有稳定触发完整客户区重绘，以三个 Win32 文件中的局部 InvalidateRect 修复，保持输入/模型契约不变。

新屏幕像素回归在旧源码上实际 RED（空洞 72px、像素差 348），当前实现 GREEN；新增回归令原七套变为 **八套，97 OK/0 FAILED/0 SKIPPED**。开发自测与独立功能验收各实际完整运行，均 compile/run=0/0、Session 1/elevated=false。独立修改源重建的 native_forms 原键盘路径 17 项检查符合预期，文字无需 resize 已完整；验收者与原会话实际查看该次自然态原图。完整输入、命令、证据与范围见[Windows 真实窗口补验](windows-window-validation.md)。独立结论为“通过（仅本批重绘修复）”，不批准整个 A2/H 门。

当前只配置 en-US/US keyboard，中日文基本语言组件均 NotPresent；真实 IME 未执行。仅实测 96 DPI，没有物理混合双屏证据。基础 UIA/键盘不等于完整辅助技术 H 门，全量通用回归及其他未执行项仍开放。

## 下一批执行顺序

| 阶段 | 当前状态 | 交付与验收出口 |
| --- | --- | --- |
| P0 状态同步与复现说明 | 本批文档已更新 | 当前摘要链接到固定代码/CI；历史证据保留；本地依赖排查和 Windows 步骤可查 |
| P1 Windows 平台验收 | 八套97/0与重绘修复独立验收通过；GPUI ABI1/2本批任务窗口通过 | 继续补适用通用回归、真实 IME、不同 DPI 双屏和完整辅助功能 H 门，未执行项不关闭 |
| P2 原生 A3 | 待逐项设计 | 顺序推进虚拟列表、平台导航、Canvas/图表、native 打包；每项独立验收，最终完成带数据库的编辑/滚动/返回/移机运行纵向样例 |
| P3 Android 最小贯通 | 待前置公共边界稳定 | 通用宿主/JNI、表单、资源与 SQLite，真机验证保存重开、中文输入及旋转恢复；再扩展列表和生命周期 |

环境沿革：旧容器因 worktree 下挂载源缺失、storage 仅余 12K 缓存而启动失败，原排查记录保留在 `target/verification/progress-sync-2026-10-18.mz2K3B/windows-start-investigation.md`。用户随后明确授权重建；新 `leaf-a2-windows` 已运行，磁盘位于 `/home/jimxl/.local/share/leaf/windows-acceptance/storage`，旧容器改名保留，未删除原记录。网页控制台只绑定宿主机 `127.0.0.1:18006`，没有创建/切换 Workspace、提交推送或触发远程 CI。此后继续使用该持久环境，不重复安装。普通桌面账户矩阵/真实 IME/双屏/辅助功能证据不全的项仍保持未验收，不能由 VM 自动化或 CI 绿色替代。

本轮在 Linux 实际编译 `scripts/test_win32.nim` 退出 0，直接运行所得二进制退出 2 并输出 NotRun；这是非 Windows 拒绝路径通过，不是 Windows 套件通过。编译、运行日志和退出码保存在 `target/verification/progress-sync-2026-10-18.mz2K3B/`。最初没有 PowerShell/Windows 时只静态核对了示范步骤；随后按授权重建并执行了上面记录的实际 Win32 路径，未声称逐字执行了全部示范命令。文档范围、链接、锚点与格式检查另行执行，不重跑无关全量测试。

相关依据：[异步生命周期合并验收](superpowers/reviews/2026-10-17-component-async-lifecycle-local-merge-verification.md)、[Win32 范围与 H 门](native-win32-validation.md)、[原生迁移总体设计](superpowers/specs/2026-10-07-native-controls-design.md)。本批不扩展产品功能；提交与推送仅按用户明确授权执行，不扩大到平台验收或额外部署。
