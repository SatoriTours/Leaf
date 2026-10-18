# Windows 持久验收环境与首轮结果

记录日期：2026-10-18。用户已授权重建 Docker Windows；本页记录实际完成与失败，不将环境重建完成等同于平台验收通过。首轮失败已保留；四项测试修复后的开发自测与独立功能复验均完成七套、96 通过/0 失败。后续重绘缺陷修复另经八套97/0开发自测与独立验收通过，见本页后续章节；这些批次均不批准完整平台或 H 门。

## 已完成的重建

- 新容器：`leaf-a2-windows`，保持运行，便于后续复现。
- 持久根目录：`/home/jimxl/.local/share/leaf/windows-acceptance`，不在项目或 Paseo worktree 内；根目录权限 0700。
- 原容器保留为 `leaf-a2-windows-unavailable-20261018`，没有删除原记录；原磁盘未恢复，本次是全新安装。
- 固定镜像：`dockurr/windows@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea`。
- 使用微软官方 Windows 11 Enterprise Evaluation；实际系统查询为 `10.0.26300 / build 26300`。这是有期限的评估环境，没有执行激活绕过。
- KVM、4 vCPU、8GB RAM、64GB growable raw disk；重建完成时磁盘实际占用约 14GB。未使用 privileged 容器。
- Windows 已进入实际桌面；密钥 SSH 连接和 guest 重启后自动启动已验证。

仅绑定宿主机本地的端口：

| 用途 | 地址 |
| --- | --- |
| 网页控制台 | `http://127.0.0.1:18006/` |
| RDP | `127.0.0.1:13389`（TCP/UDP） |
| SSH | `127.0.0.1:12222` |

账号配置和专用私钥仅保存在持久根目录的 `control/windows.env`、`ssh/id_ed25519`，权限 0600；不在仓库或报告中记录口令/私钥。远程客户端的 localhost 不是此宿主机，不能据此假设手机可直接访问。

正常启停使用 `docker start leaf-a2-windows` / `docker stop leaf-a2-windows`。stop timeout 为 120 秒，未启用自动重启。不要再次运行首次安装或补空 storage，不要随 worktree 清理删除此持久目录。详细本机控制方法保存在该目录的 `README.md` 和 `control/` 中。

## 工具链与输入身份

实际运行验证了 Nim 2.2.6、MinGW GCC 11.1.0、windres 2.36.1：

- Nim：`C:\LeafTests\tools\leaf-sdk\toolchain\nim\bin\nim.exe`。
- GCC/windres：`C:\LeafTests\tools\mingw64\bin`。
- 源码：`C:\LeafTests\c207e48\source`。
- 初始基线的产品、测试和构建输入来自提交 `c207e48af8b33b8e6ecaf4dc1548ec9b2541b737` 的 `git archive`；不含本批后续文档或修复 overlay。
- 源码 tar SHA256：`efad4c689479b0a1aaac5e81281953909f562a10a5f33e4fe8a8223ec44176fa`。
- Windows 端逐个复核归档内 **523 个常规文件，0 个 SHA256 不匹配**。
- Leaf Windows SDK metadata 同样为 `beta.c207e48af8b3` / 上述完整提交；SDK、Nim 文档的 MinGW 包、仓库固定版本的 7zr 均先在宿主机核对 SHA256，再在 guest 复核后解包。

安装 OpenSSH 系统可选组件耗时约 12 分钟，最终服务 Running。曾临时运行 guest-only HTTP 文件/日志接收器辅助排查，已按 PID 身份核实后停止，没有宿主机公开端口或常驻额外调度服务。客户端仍有未协商 post-quantum KEX 的警告，没有通过修改算法或认证设置隐藏警告。

## 非提权交互身份

镜像默认 `EnableLUA=0`；本轮仅在新 guest 内启用 `EnableLUA=1` 并正常重启，没有修改宿主机安全配置或关闭安全功能。

通过 Windows Scheduled Task `LeafNativeC207e48`，以 `Interactive / Limited` 启动既有 runner；最终实际报告：

- 用户：`LeafTester`。
- SessionId：**1**，不是 SSH 服务的 Session 0。
- elevated：**false**。

该账户仍属于管理员组，准确表述是“非提权交互 token”，不是完全非管理员账户矩阵，也不是历史 elevated 开发桌面结果。任务设置 25 分钟总执行上限，前次未结束不启动重复任务。

## 首轮原生测试：未通过

实际运行仓库原有 `scripts/test_win32.nim`，没有修改产品、测试或 runner 源码。调度包装器先前两次分别因 PowerShell 5.1 的退出码读取 race、空 ArgumentList 被拒绝而失败，尚未进入套件；原记录单独保留。用真实退出 0/7 和无参数子进程验证控制脚本后，才取得下述实际套件结果。

最终运行时间为 2026-10-18T02:28:58Z–02:29:27Z（UTC）：runner 编译退出 **0**，实际运行退出 **1**，共 **12 OK / 4 FAILED / 0 SKIPPED**。官方 runner 在第二套失败后停止，因此不是完整七套通过：

| 套件 | 实际结果 |
| --- | --- |
| `test_component_host` | 1 项通过 |
| `test_component_tasks` | 11 项通过、4 项失败 |
| 其余五套 Win32 suite | 此次未执行；不得借用历史开发通过记录替代 |

四项失败均位于 `tests/windows/test_component_tasks.nim`：

| 用例 | 实际差异 |
| --- | --- |
| `native installation callback cannot claim lifecycle or completion in nested pump` | 第 128 行 `hookEntries > 0` 失败，实际为 0，注入点没有命中 |
| `independent pending timers cancel before close retry and never claim tasks` | 第 285 行期望 destroys=2，实际为 3 |
| `nonempty output is refused before new Runtime and preserves old owner` | 第 314 行夹具创建 existing Runtime 时抛 `invalid window dimensions`，尚未进入待验证的输出槽拒绝路径；该 Application 未填写尺寸 |
| `installation scope rejection does not hide original error or lose cleanup owner` | 第 420 行完整消息断言不匹配，实际为 `native installation scope; UI guard: body invoked 0 time(s)` |

以上保留首轮输入的真实失败，不因后续成功改写。当时仅定位到断言/夹具边界；随后按下节逐项验证根因和修复，不直接放宽计数或忽略错误。

## 四项测试修复与开发自测

独立诊断输入 `task-fixes-probe` 仍复现 12 通过/4 失败，并记录：真实 createWindow 内 accepted Runtime 的 installingHook=false、installingUpdate=true；三次销毁依次为 child、同一 child 重试、Host。因此失败来自测试的错误观察边界，而不是据失败数字推断需要放宽框架。

仅修改 `tests/windows/test_component_tasks.nim`，框架与 runner 均未修改：

1. 用独立 attachingNative 区间保证真实注入命中；验证 accepted Runtime 的更新保护、committer 尚未发布、嵌套 pump 不启动 worker 且不交付结果。
2. 故障仅拒绝第一次 Host 销毁；仍要求 Host 恰好两次尝试，并逐个验证实际 child 只销毁一次、窗口/subclass/root 资源计数归零。
3. 为输出槽夹具补合法宽高；必须因非空 slot 在 render 前拒绝，否则用确定性异常暴露误构造而不挂起窗口，已有 owner/快照保持。
4. 校验原异常对象身份、动态类型和 cause 链，保留原消息前缀并核对已有 guard secondary，而不是要求整条错误字符串不变。

实际命令：

```sh
python3 /home/jimxl/.local/share/leaf/windows-acceptance/control/run-win32-case.py \
  --tag task-fixes-green3 --overlay-file tests/windows/test_component_tasks.nim
```

固定输入为 c207e48 归档加唯一测试文件 overlay，SHA256 为 `42d51442134f22470502858db8377218b251bda2b3efa1d6b20de7a954244be9`。此前 523 文件无差异的记录属于原始基线，不能当作新测试文件也未变化的证明。overlay 上传后在 Windows 再核对 SHA。

2026-10-18T02:56:58Z–02:59:01Z（UTC），Session 1/elevated=false，原有 `scripts/test_win32.nim` 编译与运行均退出 0，实际出现 `Passed all 7 Windows host test suites`：

| 套件 | 通过 | 失败/跳过 |
| --- | ---: | ---: |
| `test_component_host` | 1 | 0/0 |
| `test_component_tasks` | 15 | 0/0 |
| `test_win32_controls` | 20 | 0/0 |
| `test_win32_host` | 24 | 0/0 |
| `test_win32_input` | 15 | 0/0 |
| `test_win32_measure` | 18 | 0/0 |
| `test_win32_toolchain` | 3 | 0/0 |
| 合计 | 96 | 0/0 |

另执行 Linux threads:on 的 `test_ui_thread` 16 项、`test_component_task_shutdown` 15 项，均通过；Windows 目标 Nim semantic check 退出 0，只作编译前检查，不替代上述 Windows 实跑。没有重跑未改实现的 102 个通用套件或 Rust 测试。

修复过程曾有两个候选测试输入的 Nim 类型/效果及 MountedNode 访问编译错误，已修正；其原日志保留在 `task-fixes-green`、`task-fixes-green2`，不当作行为 RED 或成功证据。成功输入和完整日志保存在持久根目录 `shared/evidence/task-fixes-green3/`，诊断失败在 `task-fixes-probe/`。

## 独立功能复验与原会话核对

功能验收角色在同一 Workspace 对相同测试 SHA 独立执行：

```sh
python3 /home/jimxl/.local/share/leaf/windows-acceptance/control/run-win32-case.py \
  --tag task-fixes-review --overlay-file /home/jimxl/projects/leaf/tests/windows/test_component_tasks.nim
```

2026-10-18T03:03:11Z–03:05:24Z（UTC），控制器、编译和运行退出码均为 0，原有七套完整执行，**96 OK / 0 FAILED / 0 SKIPPED**，Session 1/elevated=false，overlay SHA 与当前工作树一致。独立证据位于持久根目录 `shared/evidence/task-fixes-review/`；验收报告位于 `target/verification/windows-task-fixes-2026-10-18/functional-review.md`。Linux 两个小套件由开发者实际运行，验收者只复核其日志，不能称作独立重跑。

独立结论为“通过（仅本批测试修复）”，未发现阻断项。原会话完整读取报告、核对实际 diff、独立 result.json/逐套输出和输入文件 SHA，确认 Runtime/Host/runner 未变、四项修复没有靠扩大计数或丢弃异常通过，不另行重复全部验收。

验收者考虑但未单独裁定的三点由原会话限定如下：

- 发布阶段的 inUpdate 策略未修改，且本批断言符合既有安装保护契约；不据此宣称重新验收所有发布重入组合。
- 本批 Host 故障只验证“一次拒绝后成功重试”；连续多次销毁失败不在已取得证据中，不能泛化为任意失败次数均已验证。
- secondary 文案不作新格式设计；本批依赖主异常身份/类型/cause 链和有限消息片段，后续若合法调整文案仍可能需要维护测试，不构成本轮产品行为变更。

上述边界不阻塞本批修复交付，也不关闭相应的更广平台矩阵。此处是该批验收当时的工作树输入记录，后续提交/推送另核对 Git 历史。

## 后续真实窗口与视觉缺陷

同日继续复用该环境，使用现成 SDK 构建并运行 GPUI ABI1/ABI2 任务示例和 native_forms，仍为 Session 1/elevated=false、实测 96 DPI。两种 GPUI ABI 的完成、错误重试、离开策略、键盘与在途关闭通过；native 的键盘、基础 UIA 角色/值通过，但标签文本在自然完成态缺字，等待 2 秒仍不恢复，resize 后才完整显示，当时视觉项明确不通过，原始失败保留，后续修复见下。过程中的客户端 UIA 代理及旧 caption 读值问题已区分，不混作产品缺陷。

脚本、固定 EXE/DLL 哈希、全部实际步骤、前后截图和未完成项见[Windows 真实窗口补验](windows-window-validation.md)。新证据保存于持久根目录 `shared/evidence/p1-window-probe*`、`p1-interactions*` 与 `p1-native-visual/`，保留最初失败及 SHA256 manifests。不是另一个独立角色复跑，也没有据这些窗口宣布整个 H 门通过。

## 重绘修复的开发自测与独立验收

随后在非 EDIT 标签文本真实改变且 setText 成功后显式失效该控件客户区（InvalidateRect），仅修改 Win32 api/calls/backend，保持 Runtime、Host、布局和输入契约。新增屏幕像素回归在同一测试 hash 的旧源码上实际失败：缺字空洞72px、自然态与完整绘制像素差348；修复后通过。原七套加新回归成为八套，开发与独立复验均为 **97 OK/0 FAILED/0 SKIPPED**、compile/run=0/0、Session1/elevated=false。

持久证据：`shared/evidence/redraw-final-red/`、`redraw-final-green/`、独立 `redraw-review-final/`；应用旧源码对照 `app-baseline-1/`、开发 `app-verify-6/`、独立 `redraw-review-app/`。应用由固定归档加三个产品 overlay 在独立目录重建，原源码/共享 SDK 不污染；独立真实键盘路径17项检查符合预期，正常退出0。验收者及原会话均查看独立运行自然态整窗和标签图片，未借 fresh/resize 对照替代结果。

独立结论为“通过（仅本批 bugfix）”，未发现阻断问题；原会话已核对报告、实际diff、输入hash、原始97项日志及自然态图片，不重复全套。最终测试 hash、三个产品 hash、复验入口与范围见[真实窗口补验](windows-window-validation.md)。本地详细报告在 `target/verification/windows-native-redraw-2026-10-18/`。最终无运行中窗口/测试进程，计划任务均Ready；早期两个挂起测试经可执行路径核验后已停止，过程日志未删除。验收阶段未执行提交推送、安装新工具或再次重建VM；后续 Git 操作按用户授权单独执行。

## 证据与剩余范围

持久根目录的 `shared/evidence/native-c207e48/` 保存实际 `result.json`、编译与运行的完整 stdout/stderr、Nim/GCC 版本和 token groups；`shared/evidence/` 另存源码复核、工具链文件哈希、guest UAC 配置和进程退出 probe。安装与首次调度失败日志也分别保留。最终 Scheduled Task 为 Ready，未观测到仍运行的测试进程；Windows 容器本身继续运行。

当前没有安装 Git、Cargo/Rust 或整套 GPUI Windows 源码开发依赖，未执行 102 个通用套件；现成 SDK 已足够完成上面的 GPUI ABI1/2 任务窗口子集。用户语言仅 en-US，中日文基本语言组件均 NotPresent；真实 IME、不同 DPI 物理双屏、完整辅助技术体验、长期内存与硬件性能仍未验收。**环境重建、原四项测试修复及后续重绘修复验收完成；当前八套97/0独立通过，但P1完整平台与H门仍未关闭。**

相关入口：[当前进度](progress.md)、[Windows 验收步骤](windows-acceptance.md)、[Win32 范围与 H 门](native-win32-validation.md)。
