# 绘图、交互与动画实施计划

> 实现方式：原会话按 executing-plans 连续实现、自测与修复；当前 checkout/main，不新建空间／分支，不提交。适用用户已确认流程，不逐任务审批或按文件派发。

**Goal:** 落地已确认的简单组件／托管变量语法与二维绘图实验室，并用真实入口及重复工作负载验证。
**Architecture:** 编译期宏降低到唯一 managed Runtime；托管变量使用 StateStore 批内草稿；Canvas 通过 typed Host 数据进入 Win32 Direct2D。事件与动画业务回调留在普通 UI turn，不进入绘制／accept。
**Tech Stack:** Nim 2.2.6、现有 MinGW C 编译器、Win32／Direct2D／DirectWrite；内部最小 C ABI 桥接 COM 接口，不引入解释器或安装新依赖。
**Spec:** `docs/design/graphics-animation-api.md`。

## Global Constraints

- 初始实现基线 `305e787`；现有设计文档为本任务未提交成果，不覆盖其他修改。
- 现有 defineComponent／State／componentView／run(app) 行为兼容；新事件草稿禁止隐式与同状态旧 updater 混用。
- 共享代码可在 Linux 验证，GUI／绘制／视觉结果必须来自真实 Windows。VM 为受支持的软件／虚拟 GPU 环境证据，不宣称本机硬件帧率。
- 命令有界；每项先 RED 再实现。证据统一 `~/.local/state/agent-artifacts/leaf/2026-10-26-graphics-api-design/implementation/`，临时探针在 /tmp。
- 用户已授权按需启动既有 Windows VM；不重建、不改认证／SDK。结束或受阻先保存证据，再核无人使用正常关闭。
- 整个任务不是仅 DSL 完成；分切片记录真实完成与缺口，不能以解析／headless 冒充 Canvas 或性能完成。

## Review Focus

1. 同 UI 批两次事件读己之写，异常／拒绝后不残留草稿；状态不同实例与 owner 不串写。
2. 宏参数、局部变量／循环变量遮蔽、嵌套 handler 和普通函数不能被名字文本替换误伤。
3. Canvas 类型数据不可由调用者变异；apply／EndDraw 失败不得提前发布交互快照。
4. DPI／变换／忙帧／捕获取消下，拖动不跳、不误点，旧实例事件不作用于新实例。
5. 动画只在接受后启动，暂停／隐藏／卸载停止工作；统计不能把请求／提交频率当真实显示 FPS。

## Task 1 — 组件语法与托管变量完整闭环

Files：新增 `src/leaf/component_dsl.nim`；修改 `component_state.nim`、`component_description.nim`、`components.nim`、必要的 runner／公开入口；新增 `tests/nim/test_component_dsl.nim`、`test_component_drafts.nim`、示例 `examples/simple_counter.nim`。

Interfaces：`allocateManagedState[T](store,owner,initial,equal,snapshot):State[T]`；内部 `readDraft/writeDraft`；`component Name:` 宏生成现有 ComponentDef；`component Name(props: PropsType):`；`run(definition,title,width,height)` 生成现有 componentApplication。text 的数值转换限新 DSL 显示入口。

- [x] RED：草稿两次更新得到2、接受读仍0、beginAttempt候选2、reject后再次候选0；跨owner／失效／非法phase；旧queueUpdate不得写托管槽。
- [x] GREEN：在 StateStore 槽实现模式隔离与草稿，复用既有 dirty／stage／reject／publish／dispose 清理门，不在 accept 分配。
- [x] RED：直接编译用户 Counter，dispatch 后 text 为1，重置为0；两实例初始化一次、Props、同batch两次callback、读己之写、事件异常及候选拒绝回滚；局部遮蔽；view写入编译拒绝；旧callback回归。
- [x] GREEN：新宏以词法绑定降低读写／事件；不使用全局 converter，不改旧 componentView 事件体语义。默认静态节点位置身份保留；数值 text 转换；不支持的语法明确诊断。
- [ ] Verify：`nim c -r --path:src -d:leafHeadlessOnly tests/nim/test_component_drafts.nim`、`test_component_dsl.nim`；受影响 State／managed／DSL／tasks／lifecycle 回归；真实 Windows Counter 入口点击／键盘／关闭。

## Task 2 — 基础 Canvas 与真实绘制闭环

Files：新增 `graphics.nim`（值类型、命令、帧／路径builder与校验）、`canvas_dsl.nim`；扩展 core／styles／typed Host／Backend 相关 Canvas sidecar；新增 `backends/win32/canvas.nim` 及最小 SDK FFI；新增对应 Nim／Windows 测试和 `examples/graphics_lab/` 初始场景。

Interfaces：不可变 `CanvasFrame`、`Vec2/vec2`、typed primitives／path／clip／transform；`canvas` Host kind；新 DSL 将 Canvas 子语句变成同一帧构建，不创建每图元 Node。

- [x] RED／共享 GREEN：值／命令／颜色／几何／额度／拷贝隔离；用户 DSL 的形状／for／if／path／text；typed Host prepare失败与恢复。
- [x] 先有界验证现有 MinGW C++ 接口能创建／链接 Direct2D／DirectWrite 并成功 EndDraw；已通过非提权交互 Session 1 工具链探针。这不覆盖当前 Nim C ABI 桥接，桥接的真实编译／链接仍待验证。
- [ ] GREEN：接入原生子窗口、DPI／resize／paint、字体／路径缓存、EndDraw 成功frameId、限额与所有权；旧控件保持原生。
- [ ] Verify：共享测试＋真实 Windows 编译／窗口／截图语义视觉检查、资源归零及原生控件受影响回归。

## Task 3 — 图元事件与拖动闭环

Files：graphics交互元数据、Canvas Runtime事件绑定、BackendSession队列、Win32 Canvas输入；新增几何／队列／真实交互测试。
Interfaces：typed事件坐标、binding generation／frameId、HitResult；普通UI安全点交付回调。

- [ ] RED：描边／填充／clip／变换命中、遮挡／穿透／冒泡；drag threshold／delta合并／captureLost／取消／卸载；循环key重排及上限；键盘等价操作。
- [x] GREEN：只为交互图形维护绑定，最近成功绘制几何命中；有界队列、过期检查、自动捕获／取消；不在WndProc执行业务。（软件／96DPI切片已独立验证，完整Verify仍开放。）
- [ ] Verify：纯几何／Runtime测试与真实入口键鼠、DPI、拖出窗口、关闭；必要独立视觉证据。

## Task 4 — 过渡与时间轴闭环

Files：新增纯 `animation.nim`、组件声明控制层及Canvas presentation接线，Host帧调度；新增采样／生命周期／真实动画测试。
Interfaces：`tween(start,finish,duration,easing,repeat,autoplay)`；`transition`；`play/pause/restart/reset/seek`；控制入草稿／提交，view中动画名直接采样。

- [ ] RED：插值端点／颜色／次数、重定向、控制顺序、失败提交、Finish恰好一次、同帧一致读取、隐藏冻结／owner取消／同属性冲突。
- [ ] GREEN：单调帧时钟与合并请求、普通安全点采样；纯属性过渡不每帧运行用户view；动态表达式局部Canvas重算并记录O(N)成本。
- [ ] Verify：共享采样测试、真实播放／暂停／seek／缩放／最小化／关闭、零空闲请求与有限资源检查。

## Task 5 — 完整实验室与性能验收

Files：完善 `examples/graphics_lab/`、新增测量producer，复用现有performance报告工具的可兼容部分；新增报告校验及实际工作负载测试，更新使用文档。
Interfaces：同一场景／固定seed／100、1000、10000对象；绘制、属性、动态几何三类；JSON／CSV、环境元数据、分阶段CPU耗时及帧请求／成功／合并数。

- [ ] RED：报告缺样本／不相容基线／超限／timeout／cleanup失败必须拒绝；scene计数与实际图元／段数一致。
- [ ] GREEN：Release进程，默认5s预热／30s采样／3次独立进程，预分配采样、无逐帧IO／HUD；记录VM和实际render mode，不输出未知GPU时间／显示FPS为真值。
- [ ] Verify：完整真实入口与冻结Release负载；开发自测→独立验收关键功能／视觉／回归→原会话核diff与证据。参考视频未取得时效果对齐单列未完成。

## 执行记录

- 已读取计划／TDD及必要平台说明；Linux Nim 2.2.6可用。Windows VM初始为exited；现有启停权限已在平台说明核实。原生子Agent doctor可调用，实际验收运行能力仍须在派发前核实，不把doctor当验收通过。
- 接口检查：Task1产生组件DSL和草稿，Task2复用其typed view降低；Task3依赖Task2帧身份；Task4同时依赖Task1控制事务和Task2／3帧生命周期；Task5只测实际已实现能力。无并发产品写端。
- Task1首批有效落盘：StateStore草稿5项通过；组件DSL真实编译／运行9项通过，含同批callback、拒绝／异常恢复、Props、独立实例、for／block遮蔽、显式mutable snapshot；view写入／var参数／深层原地修改编译拒绝。simple_counter可类型检查，尚未真实Windows验收。
- 公共component需由单一宏路由声明与旧实例调用；直接同时导出旧typed proc和新untyped宏会在声明前尝试解析Counter名字。旧typed proc仍可从component_description导入；公共宏将key/revision等完整转发typed helper。
- 受影响回归：State10／旧componentView3／compat7／managed10／commit3／faults5／lifecycle16全通过。managed首跑因PATH无nim使子编译fixture失败；显式PATH后同断言通过，保留原失败过程，不修改产品／断言绕过。
- Windows既有VM已正常启动，sshd Running、未见运行中的nim/gcc进程；现有MinGW的d2d1.h与dwrite.h均存在，但尚未证明C调用／链接可用。

### 2026-10-26 基础 Canvas 接线切片（未验收）

- typed 数据／不可变帧、Canvas DSL、core／managed 描述已接入；一个 Canvas 只有一个 Host。`MountedEntity`、`UpdateOp`、旧 Reconciler、native adapter、recording backend 保留完整帧；原始协议拒绝缺失／错属 sidecar，Host 字节预算计入 frame 数据。新 host 测试证明 prepare／部分 apply 拒绝后 State 和旧 frame 保留，再次事件从旧值继续。
- 新增 Win32 `canvas.nim`、`canvas_bridge.h/.cpp`，接线创建、prepare、layout／paint、accept、恢复及销毁。prepare 构建字体／路径／裁剪缓存；accept 仅移动已准备的值／指针，普通 turn 释放旧场景；WndProc 不执行应用渲染。目标丢失只安排普通 turn 的单次重建，无静默渲染器 fallback。这些是当前代码路径说明，**尚无真实 Windows C++ 构建、链接或运行证据**，设备故障等路径仍需测试。
- `run(..., canvasRenderer=...)`／`app.withCanvasRenderer(...)` 显式选择硬件或软件；新增 `examples/simple_canvas.nim` 明确使用软件模式，`tests/windows/test_canvas.nim` 定义原生资源／接受时点／组件更新测试，尚未执行。
- 最新共享回归：29 套、319 项通过；含 drafts 5／component DSL 9／graphics 5／Canvas DSL 5／Canvas host 3，以及 State、managed、tasks、host、native reconcile／commit／layout／capability 等。完整明细和日志在既定 implementation 证据目录；不是全仓库测试，也不是独立验收。
- 回归中旧 capability 精确集合断言因计划新增 canvasHost 失败；对照产品差异确认仅此新增后，更新精确集合并新增 typed Canvas／strict 检查；其余布局／装饰限制断言不变。原失败另存 `canvas-capabilities-compat-red.log`，未删除或降低既有约束来绕过失败。
- Nim 侧 `--os:windows --compileOnly` 检查通过：`tests/windows/test_canvas.nim`、两个 simple 示例。该命令**不编译桥接 C++、不链接 Windows EXE，更不是 GUI 运行**。
- 实际验收阻塞：现有 `control/run-guest-script.py` 的 `--prepare-source` 固定旧 c207e48 archive，overlay 白名单仅允许四个旧 Win32 模块及 Windows 测试，不接受本次新增的组件、graphics、Canvas Nim/C++ 文件。尚未传入新源码、修改控制器白名单或另走传输路径；需确认授权将本工作区产品／测试源码作为 SHA256 校验快照写入既有 VM 的独立测试目录。认证、工具链、固定旧源码和历史证据保持不变。
- Task1 真实 Counter、Task2 原生绘制／视觉／资源故障验证仍未完成；图元交互、动画、完整实验室／真实性能以及独立验收尚未开始。参考视频仍未取得，不宣称已复现。
- 受阻后的资源收尾：保存源码 SHA256 清单、29 套测试日志及状态后，独占原 native-verification 锁复核 guest 无运行中原生测试／构建／Leaf 窗口，console/RDP 连接为0，最近输入已闲置3657秒。执行原有 `docker stop leaf-a2-windows`（stop timeout 120 未改），exit0；确认容器 exited／PID0，本任务原 QEMU PID 身份均已消失。证据 `vm-shutdown.json`；未删除磁盘、SDK、缓存或历史证据。


### 2026-10-26 Windows 源码快照、实际入口及恢复自测

- 用户明确同意传入当前源码；使用现有 SSH／非提权 Scheduled Task 通道，将仅产品／测试白名单文件写到全新独立目录，压缩包及 566 个文件分别核 SHA256。未改控制器白名单、认证、SDK、历史源码或旧 stop timeout。传输阻塞已解除。
- 初版 C++ 桥接确实编译、链接并通过当时三项原生测试，但自然启动发现 `0xC0000135`：编译进程 PATH 中的 `libgcc_s_seh-1.dll` 掩盖了额外运行库依赖。新增最小 Windows PATH 子进程测试取得 RED；一次 compile pragma 尝试未应用编译参数，仍失败，保留日志。最终改为同一 SDK 的 **C COM 接口** `canvas_bridge.c`，不安装或打包编译器 DLL；该回归 GREEN，两个示例自然启动成功。旧 `.cpp` 初稿由本任务新建且未提交，已被 `.c` 取代。
- 当前原生自测快照 `canvas-recovery-green-1026`，archive SHA256 `81ad695b747f5045ab924de5292373919e0df51958f54a2a1df96bf11a019b2a`，Session 1、elevated=false。Canvas **7 项通过**：干净 PATH 启动、prepare／accept／discard、target-loss 状态／单次真实 SDK 重建、重建失败冻结且不 fallback、busy／隐藏不推进、无效 HWND 清理、managed 更新不重建且资源归零。恢复错误由仅 `leafProtocolProbes` 可用的单次 HRESULT seam 注入；**不声称实测真实 GPU 故障或显存**。
- `canvas-ui-c-1026-1354`：真实 Counter 鼠标增加至1、空格至2、键盘重置0，Canvas 中文／三圆／路径／旋转矩形裁剪正常显示，按钮增加半径、resize contain 居中、重置恢复；两入口正常关闭 exit0，16 项自动化检查通过。主控实际查看自然初始／增大／resize／重置截图，非像素脚本替代。此 UI 轮次用 C 接口修复快照 `canvas-c-sdk-1026-1352` 的精确 EXE；后续仅增加恢复 probe，最新快照的独立 UI 验收仍待执行。仅 96 DPI／显式 software，不冒称硬件、混合屏 DPI 或真实显示 FPS。
- 受影响原生回归分两批执行：`canvas-native-compat-1026` 的 component host／tasks 通过；旧 label 实屏像素回归因包装器普通 60 秒上限超时并结束。检查其两轮逐像素 GetPixel 捕获后，单独合理放宽该套至 240 秒并开启既有 trace；`canvas-native-compat-rest-1026` 实耗 80.7 秒通过，其余 cleanup／controls／host／input／resource-owner 均通过。未修改产品或删改原断言来消除超时；原超时证据保留。
- 当前仍为开发自测，不等于独立验收或整个任务完成。下一步独立核对 Task1／基础 Canvas 关键路径与证据，再进入图元交互、动画和实验室。实际 GPU 故障、混合 DPI、参考视频及性能证据仍缺失。


### 2026-10-26 独立非视觉验收及 F1 修正（仍未完成）

- 按最新保存的“功能验收” profile，复用当前 Workspace／cwd，由 Pi 原生独立子 Agent `magpie/group/deepseek-flash-4.1` 只读验收。不是 Paseo Tab／权限隔离，不创建空间、不提交发布。初次 run `612a394b-2b8a-48bb-8508-14dd1af3c34b`；报告 `canvas-independent-review.md`。
- 验收端实际运行共享 21 套 **198 项通过**、从566文件校验快照独立重建 Windows Canvas **7 项通过**、精确 EXE 的真实 Counter／Canvas 非视觉入口 **16 项通过**。主控核对原始 JSON、测试日志及 SHA；最初 resize 假失败来自验收脚本将内容 Static 也算为 Canvas，独立几何探针定位并修正选择器，最终 `canvas-independent-review-1026d` 通过；不计为产品故障。该端没有图像能力，**独立视觉验收阻塞，Task1／Task2不标完整验收通过**。
- 独立发现 F1（medium）：状态命名为 `fill` 时，state lowering 抢先改写 `width: fill`，字符串导致 mount 失败，数字静默宽度7／8。主控先新增两项测试取得 RED，再只保护非 event 的精确裸 `width: fill` 语法；普通 text、Canvas paint、handler 和计算宽度仍按词法状态处理。新 DSL 11 项、受影响6套36项自测通过，未削弱原断言。
- 复用同一独立验收端聚焦复验，run `93bd7bc7-5dd7-4952-9d50-01b6390aec0d`：**36 项通过**，两个原始复现及额外边界探针均通过，确认 F1 闭合。主控核源码 delta、日志及报告；仅 `component_dsl.nim` 和其测试两文件变化，564/566文件不变。完整报告 `canvas-independent-fill-recheck.md`；代码 hash 及 RED/GREEN 见 `fill-keyword-source-delta.json`、`fill-*.log`。文档补充裸关键字与 `(fill)`／表达式的区别。
- 不重复无关全套回归：本次修正是共享编译期宏，Win32／桥接未变；独立验收认为旧 CanvasPage 也不触发这个命名冲突。既有 Windows EXE／UI 证据明确属于 F1 前快照，不冒称修正后 GUI 重测。F1宏闭合不代表独立视觉通过；硬件 renderer、非96 DPI和真实 GPU loss仍未验证。
- 独立视觉能力是当前阶段的实际缺口；未自动切换其他 profile／模型绕过。Task3 事件拖动、Task4动画、Task5实验室及真实性能尚未实现，未提交发布。
- 资源收尾：复验只用Linux，Windows不再需要。原锁下复核无 Leaf 测试／构建／窗口，console/RDP连接0，交互 Session1闲置741秒，正常 `docker stop leaf-a2-windows` exit0，原timeout120未改；容器 exited／PID0。QEMU的comm实际为windows，已在容器内核实exe并用NSpid映射宿主PID3566501／startTicks249847880，停机后该身份消失。证据 `canvas-vm-shutdown.json`。Pi复验状态显示 process terminal observed／active capacity0，保留会话历史，未直接杀进程或归档。


### 2026-10-26 继续优化：补独立视觉能力

- 用户在换用已配置模型补视觉验收的询问后回复“继续优化”，按此上下文继续，不再次重复审批。最新profiles仍为六项且notes未变；本次仅选UI工作配置的 `cliproxy/gemini-3.8-flash-high`／high做独立只读视觉补证，原会话继续唯一产品实现负责人，不跨模型接管实现。
- Pi原生视觉验收run `89ca8699-6d40-4ea0-817a-96bf3d68e4f8`，先用一张实际截图核实图像输入，成功才比较其余已绑定EXE的截图；能力／通道失败立即报阻塞，不改认证、装依赖、切备用或写像素脚本。报告 `canvas-independent-visual-review.md`，当前尚无结论。
- 本轮复用现存独立Windows截图，VM保持关闭，不为纯图片核验重启。视觉证据满足基础software／96DPI关键路径后再继续Task3事件与拖动；不以此关闭硬件／混合DPI／性能或整个任务。


- 视觉通道故障单列：run `89ca8699-6d40-4ea0-817a-96bf3d68e4f8` 实际读取5张PNG及Counter源后，最后assistant stop/content空，工具报 `Subagent produced no output`。没有观察或验收结论，不当作图像能力/视觉通过。主控一次核实原进程terminal、active async0，代码diff检查通过，VM仍exited/PID0。
- 按同配置仅有界恢复一次，run `54516ef2-bf9b-470c-9ca7-b5a3102a4db1`（180秒上限），不切模型、不改认证/预算、不开VM、不重复功能测试；优先利用保留图片上下文输出必要观察与报告。若仍无有效结论则明确阻塞，不第三次原样派发。报告 `canvas-independent-visual-review-recovery.md`；当前尚无恢复结果。


### 2026-10-26 基础视觉补证与 Task3 共享核心（进行中）

- 原视觉run空回复后同配置唯一恢复run `54516ef2-bf9b-470c-9ca7-b5a3102a4db1` 返回79行非空报告 `canvas-independent-visual-review-recovery.md`。独立端实际接收5张PNG，描述Counter标题／数字2／中文按钮与Canvas初始／resize／reset／增大画面，基础语义视觉通过，允许继续Task3。增大图来源为较早自测快照，其余为独立1026d；未混淆为F1后EXE。
- 主控裁决限定：96DPI、显式software、已有静态截图；不采纳报告“软件后备”措辞（无fallback），不从焦点框推导点击行为，行为仍由既有独立16项支持；clip边界／AA像素精度不等于已专项验证。hardware／高DPI／真实GPU loss及动画／性能仍未完成。VM保持关闭。
- Task3开始有效落盘：新增 `canvas_hit.nim`／`canvas_input.nim` 与两套测试，18项共享自测通过。命中元数据随不可变frame准备，倒序真实基本几何、组目标／冒泡路由、变换clip、穿透、不可逆子树、键身份／额度；path／text及SDK特殊圆角必须有renderer containment查询，未提供即拒绝，绝不用bbox近似。新增graphics.commandAt只返回值拷贝。
- 指针纯协议核心涵盖主按钮／物理阈值、捕获意图、首次完整delta、合并屏幕位移后用当前父矩阵换算、唯一End/Cancel、静默owner退役、hover边界、256上限／溢出显式故障与释放意图、session/mount/binding generation及来源frame检查；无应用回调调用。
- 自查补RED/GREEN纠正描边内边界及frame fence：正常成功重绘会增加frameId，不能把同一活binding的旧来源事件全当失效；允许已知过去sourceFrame、拒绝未来／零frame及失效identity，并保留原sourceFrameId、按当前父矩阵投影。生成新实例仍必须更换generation。未删减身份检查。Nim2.2.6对 `sizeof(RefType[])` 触发编译器错误，独立小复现定位后改为已实例化对象解引用的sizeof，不改编译器。
- **这两模块尚未接Canvas DSL／Host metadata／Win32消息或native geometry查询，尚无新的真实拖动UI证据，不算Task3功能完成**。下一步为共享核心独立审查、接入既有prepare/apply/accept及最近成功绘制帧、SDK几何、输入队列／普通UI turn事件，再跑真实捕获／重排／卸载／焦点路径。新模块不从leaf公共入口宣称现已可用。


- 全仓检查实际执行 `nim r --hints:off scripts/test.nim`，600秒上限触发时104个测试可执行文件完成、863个[OK]、0个[FAILED]，第105个 `test_native_list_entrypoint` 正在执行；一次核实无残留匹配测试／编译进程。没有把这一轮记成成功。
- 未重跑已完成104套：系统临时目录复用原 `scripts/test.nim` 内容，仅改绝对root/import以及筛选排序中从未完成的 `test_native_list_entrypoint` 起，测试体／断言／ORM编译参数不变，53套（含release）282.6秒 exit0、439个[OK]。两日志覆盖集合与实际157个test_*.nim精确匹配、无缺项／失败项，共记录1302个[OK]；这是同快照的分段全覆盖，不冒称原单命令未超时。保留复制driver供复核，未修改项目测试入口。源hash清单 `canvas-interaction-core-manifest.json`。

- 最新功能验收profile仍为 `magpie/group/deepseek-flash-4.1`，核原复验端process terminal后复用其Pi保留会话，纯核心独立审查run `d623cc1f-e20b-4d78-86cc-dfac25b8cddf`（240秒有界）。冻结5文件SHA，实际独立运行两新套及graphics，最多一份必要临时边界probe；不再跑旧Windows/157套，不修改产品源码。报告 `canvas-interaction-core-independent-review.md`；当前尚无结论，不标核心独立验收通过。


### 2026-10-26 核心独立审查超时、H1纠正（待聚焦复验）

- run `d623cc1f-e20b-4d78-86cc-dfac25b8cddf` 在240秒上限超时，process terminal已核实，active async0。此前实际核5文件SHA一致、独立23项全部通过，留有hover边界失败probe，但没有正式结论，**不当作审查通过**；原输出／session保留，不重跑完成项目。
- H1（medium）：原算法只比较hover路由最长共同后缀。直接换父而保留generation的probe存在身份前提歧义；主控确认了真实有效场景：同一个immutable frame、相同 outer→inner→circle 父链，inner从无监听变为有监听，leaf身份与几何完全不变，却多发leaf Leave/Enter。新增真实hit snapshot到input的回归：预期只Enter inner，RED实发3条。
- 原实现者改为按完整binding token身份集合差计算边界，Leave保持内到外、Enter保持外到内，保留者刷新当前projection但不重复边界通知；祖先退役也不打扰仍hover的child，不向dead owner发事件。仅input核心与其测试2文件改变，24项（input11/hit8/graphics5）自测GREEN，diff检查通过。
- 原157套/1302项属于H1前快照，保留 `canvas-interaction-core-manifest.json`。修正快照另存 `canvas-interaction-core-hover-fix-manifest.json`，其余3文件hash不变，当前该input模块没有公共/Native调用者，只聚焦受影响范围复验，不冒称旧全仓证据是修正后全量重跑。仍未进行Task3实际拖动窗口／DSL接线；VM继续关闭。

- 按原功能验收配置唯一恢复／H1聚焦复验run `849b6eef-4a4f-4500-8929-6fb07c8fc64e`（180秒），只核新SHA、input11及原hover probe；不新增探针、不再次读全模块／生成目录、不重复未变hit8/graphics5或全仓。报告 `canvas-interaction-core-independent-review-recheck.md`；当前尚无结论，若再超时则停止原样恢复并报告阻塞。

### 2026-10-26 H1 独立闭合及 Task3 DSL／托管桥接

- 聚焦复验 run `849b6eef-4a4f-4500-8929-6fb07c8fc64e` 返回非空正式报告：核冻结 SHA、input11 与原 hover probe 通过，H1 closed；此前 hash 未变的 hit8／graphics5 复用，不重跑。父裁决仅共享核心通过，既有首次240秒超时命令不算成功；157套／1302项仍属于H1前版本。
- 继续同一批准任务，由原会话实现 `canvas_events.nim`：图元／group 事件块降低为 typed `CanvasPointerEvent`，稳定 key 和事件 mask 随不可变 frame；callback 存 accepted Node 的独立 registry，通过新增 typed `canvasInput` 通道进入原 Runtime／managed draft 批次，不增业务运行时，也不从 paint／WndProc 调用业务。
- 自测证明 child→ancestor click 冒泡及 stopPropagation、循环重排 key 与每次迭代捕获、同父重复 key 拒绝、handler 异常／Host prepare 拒绝不提交草稿、不回放事件；退休 route 在任何 callback 前丢弃。Host raw 协议拒绝将 Canvas input mask 安装到普通控件。交互 metadata 纳入 owned bytes、10,000绑定额度与 sealed frame，拒绝重复 opaque identity。
- 本阶段16套／128项共享自测通过，`git diff --check`通过；新7项事件测试、graphics新增额度测试均有 RED/GREEN。冻结 `canvas-interaction-dsl-manifest.json`，与早先H1独立审查快照分层；这是自测，不扩成新DSL独立验收或真实输入通过。
- 尚未接通 SDK containment、最近成功绘制命中快照、Win32消息／capture／普通turn派发、wheel／keydown与真实拖动。Task3整体仍未完成；VM未启动，未提交发布，Task4／5未开始。

### 2026-10-26 SDK containment 与绘制快照自测

- `canvas_bridge.c/.h` 增加同一 SDK prepared path／DirectWrite layout／特殊圆角 containment；普通基本形状仍复用共享几何，不猜 path bbox。NativeScene query lease 在释放前失效，accept 只移动已准备 hit snapshot，candidate 成功绘制本身不提前发布；丢弃保留旧 accepted/drawn 命中。metadata 与 lease 纳入已有64MiB缓存计账。
- 新 Windows 用例先获得缺失 hitDrawn API 的类型检查 RED，再实现。类型检查 GREEN 本身不作为原生证据；随后确实在原 VM／Session1／非提权 token 从572文件 SHA 校验快照 `canvas-hit-sdk-1026-185707` 实编译、链接、运行：旧7项＋新SDK包含性／发布测试共8项通过；两个simple入口仅重建，未冒称重新跑UI操作或独立验收。
- 本轮直接验证 evenOdd 孔洞、文本布局内部与外部、SDK超半径圆角；prepare与candidate draw不发布、accept发布、discard／maintain保留活旧几何，关闭资源归零。共享 hit8 对新增 native boundary helpers 的受影响回归通过。原16套128项证据仍对应其 DSL manifest，新增 Native 改动另按本次572文件清单分层。
- 保存证据后核 Session1闲置575秒、无RDP／Leaf任务／构建／窗口，正常停止原VM，timeout120未改；容器exited/PID0，已用容器exe＋NSpid＋startTicks确认的QEMU宿主PID3747586身份消失。`docker top`仅有表头且宿主exe不可读，改用既有容器内身份查询与宿主只读status/stat关联，没有改权限。
- Task3余项：原始消息source顺序、binding namespace／generation、capture、普通turn投影与托管派发、wheel／keydown／focus，以及真实输入与独立验收。下一步保持唯一实现端连续接线，不另造业务Runtime，也不以SDK查询测试冒充拖动UI通过。

### 2026-10-27 Task3 真实输入接线（自测通过，待独立验收）

- Windows WndProc 仅采集事实、执行系统捕获／焦点操作；回调由原 Session FIFO 在普通 turn 交付。补原始 Pointer／wheel／key、修饰键、Canvas `focusable`／`accessibleLabel`、Tab 与焦点提示，以及 `examples/canvas_interaction.nim` 原生按钮／键盘等价入口。
- 对失焦／捕获丢失、奇异变换、key退休、卸载、拖出窗口、FIFO、溢出冻结补真实原生测试；源事件掩码约束后装 handler，RAW Move 仅兼容时合并。测试观察接口仅在 `leafProtocolProbes` 构建可见。
- 当前577文件冻结快照 `canvas-interaction-final-1027`（archive SHA256 `f7c488b8a3ac035678a7b5cc0e88fccf5c8a607090fdf33828ea21f2c9e77f89`）：20原生测试通过、三个示例真实编译链接成功。`canvas-interaction-ui-final-1027` 用同hash EXE完成30项真实系统鼠标／键盘检查及正常退出；不是 SendMessage 注入或物理硬件证据。
- 实际入口暴露三个注入测试未覆盖的缺陷：空捕获维护 self-wake、STATIC的双击down、paintAccepted遗漏最新presentation。均补 genuine RED 后修复，最新原生／真实UI绿色；保留全部失败tag。
- Linux受影响8套先行自测通过；已交独立端批量执行最新共享／兼容回归及原生／系统输入复验，另用已配置UI profile补独立图片语义验收，不重复派发实现。当前无独立结论，Task3 Verify仍未勾选；150/200%、物理混DPI、硬件/真实GPU loss与完整辅助技术未验。动画／实验室／性能不在本切片完成声明中。
- 最新唯一索引为 implementation/canvas-input-next-integration.md，脚本及source manifests同目录；VM暂保留供独立验收，结束后依既有约定保存证据并核无人使用后正常关闭。不提交／发布。
- 独立视觉补证已完成：run `aa1dff2a-af60-4ba9-8210-c2300b954c70` 实际接收同EXE四张真实PNG，报告 `canvas-interaction-independent-visual.md`，96DPI/software静态视觉限定通过。主控核报告和EXE/hash来源；不从焦点框推导实际事件、不采“合并裁决”为Git授权。独立功能与回归仍待结果，阶段3矩阵不关闭。
- 独立源码审查run `127c59b4-6439-4ca0-a971-f1d32ecc1eb8` 无P0/P1，但角色无exec，原生/真实输入只复核旧证据，不算独立重跑。主控重新逐577文件核SHA与冻结快照全匹配；generation永不回收及奇异矩阵检查两条P2建议不作为阻断修复。已核官方delegate有bash，保持同验收profile与只读产品边界补独立执行run `7aae8beb-65dc-4ed3-840d-ec990172852d`，不重复源码审查/视觉。执行结果尚待，不以启动确认作通过。
- 独立执行run `7aae8beb-65dc-4ed3-840d-ec990172852d` 已完成，原生进程terminal observed、active capacity0：选定22套Linux196项通过（managed_runtime首因PATH无nim失败，仅进程PATH修正后通过，失败保留）；最新精确hash Canvas20项和系统输入30断言独立实跑通过。另从577文件校验源实际编译链接运行 test_win32_input 15项、test_component_host 1项。报告 `canvas-interaction-independent-execution.md` 的“兼容31项”是算术笔误，原始JSON/日志为16；不为文案重测。主控核原始结果、diff检查和577源码hash全一致。接受软件96DPI交互切片；Task3 GREEN标完成，Verify仍因150/200%／混DPI／真实硬件／辅助技术缺证据而开放，动画／实验室／性能未实现，不提交发布。
- 资源收尾：所有报告/原始日志及4张已验视觉PNG已保存；无Leaf App/任务、无RDP/console网络连接且验证锁空闲后，锁下docker stop正常发出ACPI并记录`Shutdown completed!`。容器exited/PID0、docker top确认非运行；supervisor143为SIGTERM，不写成0。宿主QEMU身份前置探针缺口及脚本未因错误提前退出的事实单列保留在`canvas-interaction-vm-shutdown.json`，不重启补探针。三个子Agent均process terminal observed、active capacity0；VM磁盘、SDK及历史证据/会话保留。


### 2026-10-28 Task4 动画基础层（自测，待独立验收）

- 新增纯值语义 `animation.nim`：毫秒时长、标量／Vec2（位置与尺寸）／线性光预乘alpha颜色插值、四种easing、有限单程次数／forever／pingPong、play/pause/restart/reset/seek、唯一自然Finish token、取消、当前采样值重定向、共享活动时钟及需求合并。全部无回调／I/O。
- 新增内部 `animation_state.nim`：控制与候选帧复用StateStore托管草稿、owner与同一接受／拒绝／销毁门；render不可控制，失败候选不消费Finish，空推进不入队。
- 两新套20项自测通过；API缺失的编译失败仅记API RED，不冒充行为RED。后续两个真实行为RED（重复／零时长seek终点、暂停／结束空推进入队）均修复并复跑通过。日志、4文件hash见既有implementation证据目录的 animation-*。
- 边界：此为内部基础，不从leaf公共入口导出；未接component animation:／Canvas transition:、presentation、原生共享帧调度、owner隐藏生命周期或onFinish业务交付，系统减少动态效果尚未查询（核心只接收显式reduced）。真实Windows动画／视觉／性能未验证；Task4整项RED/GREEN/Verify均不勾选。既有96DPI交互验收不重跑，VM保持关闭。
- 独立验收准备中：仅冻结四新文件及必要State／组件回归，不委派实现、不提交／发布。


### 2026-10-28 Task4 内部基础独立验收闭合（整项仍未完成）

- 功能验收profile按最新六项notes选择；Pi原生delegate run `7d54ed24-5b6b-4606-9004-980f34f4f6d2`，实际模型 `magpie/group/deepseek-flash-4.1`。只读源码＋独立执行两新套20项、必要State草稿／State／组件DSL回归26项、唯一边界probe通过，无P0/P1。原始日志 `animation-independent-logs/`，报告 `animation-core-independent-review.md`。父会话核4文件SHA与冻结manifest一致、原始OK共46项及probe、git diff检查；未重复跑未变快照。
- 原报告日期2026-10-26误记；实际run UTC 2026-10-27 17:10:07—17:12:50（本地2026-10-28），原报告保留。probe两次作者期望错误未保留失败版本／原始日志，这是探针证据留存缺口，不冒充产品RED；已保存最后probe源码与实际通过日志。产品两个genuine RED日志均完整保留。
- 非阻断P2留待接线时文档／必要测试：accepted sample与candidate value区别；seek不会重开已自然结束的play generation；pingPong边界归下一单程；隐藏tick计入截止隐藏时刻区间；死owner控制静默退役而纯Timeline先校验参数；同attempt重复value及接受后Finish交付补测。为避免改冻结源码，不做无关注释修补。
- 父裁决纠正P2-2说明的一处混淆：失败候选的finishIssued／finishPending均随整份State回滚，不是失败候选保留finishIssued；现有“frame failure cannot consume a natural Finish”已实际证明拒绝后仍可重新产生token。同generation已接受自然结束后seek不重新交付Finish，只有restart开启新generation，符合现有设计。
- Final: Ruling: 接受上述核心范围，不将Declined to judge项当通过：真实Windows播放／最小化／缩放／DPI／视觉／GPU、性能与分配、公共DSL和属性冲突、presentation与native共享调度、真实owner隐藏与onFinish普通turn交付、OS reduced查询、实际多Canvas同帧一致及O(N)重算成本均仍未完成。若误把基础通过当整体通过，将漏掉真实显示、生命周期、双驱动和性能问题，因此Task4整项RED/GREEN/Verify继续不勾选，未导出公共入口。无提交／发布授权，不做Git写入。
- 子Agent实际process terminal observed、active async0，保留会话／全部证据。VM本轮未启动。usage／实付未知。本次仅内部基础切片闭合；下一实现主线仍为component animation:词法区分、共享frame registry和owner生命周期，再接Canvas transition/presentation及真实Windows验收。


### 2026-10-28 Task4 tween／组件与共享调度（自测通过，待独立验收）

- `component animation:` 初始化一次，view/普通数值辅助函数读取采样值，event的x.play/pause/restart/reset/seek显式控制；词法遮蔽、跨实例、只读动画变量与view禁控制；onFinish命名参数从纯tween配置分离，初始化后闭包绑定所有State／动画handles，无全局converter。
- 共享Runtime活动clock＋owner-owned bindings，不造第二份commit registry。控制与采样anchor同StateStore事务；失败帧保留accepted anchor并在下次实际时间追上。retained隐藏owner以accepted activation epoch冻结，窗口最小化／隐藏停止帧timer，不对未知遮挡作承诺。Finish仅成功State/Host帧后入下一普通turn，复核owner/generation；销毁清回调、死owner不再请求帧。
- 单窗口复用原16ms task timer，WndProc只置due flag，普通safeTurn采样／交付；空闲停timer。默认runNative在挂载前只读查询SPI_GETCLIENTAREAANIMATION，显式MotionPolicy.full/reduced可冻结策略；不写OS设置。
- Windows genuine RED `animation-timer-red-1028`：compile0/run1，x始终0、Finish0、timer arms0；修复后真实GREEN，再补实际minimize/restore。最新587文件快照 `animation-native-final2-1028`（ZIP SHA256 `174b5dd1259290f6881dde00cf5582b5b815ba6e6e6c72ac79c35242b7844049`）：动画native2、旧Canvas20均compile/run0；示例 `examples/canvas_animation.nim` 实编译链接。中间final版本为测试fixture raises effect编译失败，保留，不算行为RED。
- 同hash示例EXE `388d93751266fc68f101cae500a82617691043c3f7e8d140320bdeb0ec71eda4`；系统mouse_event真实按钮脚本 `animation-ui-1028` 的所有检查通过及4张截图，Session1/elevated=false、96DPI/software/MotionPolicy.full。非物理硬件；静态PNG不作动画节奏／FPS证据。脚本在已有implementation目录 `leaf_canvas_animation_ui.ps1`。
- 核心/State/DSL/runtime/Finish和旧组件／草稿7套自测53项属motion接入前；motion另补genuine行为RED→GREEN，当前runtime10项。完整最新选定回归由独立端执行，不将旧53项伪称最后快照全测。Finish新共享测试首轮直接GREEN，未声称所有分支均先行为RED；native端的Finish缺失已被真实RED捕获。
- 本轮是tween完整运行切片，不是Task4全部：Canvas transition语法／presentation-only不跑用户view的属性过渡、同属性双驱动冲突未实现；当前动态表达式每帧重算owner view／Canvas，成本O(owner hosts＋Canvas图元)，未测性能。Task4整项RED/GREEN/Verify仍不勾选。高DPI／hardware／辅助技术／参考视频缺口保留，未提交发布。

### Tween组件与调度：限定验收通过（2026-10-28，Task4未完）
- 基线final2独立Linux17套147项、Windows原生22＋Host24＝46项及真实UI21项；修复后最新final587文件delta独立4套26项、精确新EXE native2项、系统mouse_event UI21项全部通过，无必需项失败。不是最终快照全仓／17套重跑。
- except别名遮蔽已RED→GREEN修复；Finish每generation最多尝试一次，失败交付turn的托管回滚／异常传播与不重放外部副作用契约已文档化并独立实测。
- 当前示例 examples/canvas_animation.nim 的新EXE及静态图独立通过（96DPI/software/full）；全部587文件验收前后hash一致。唯一证据索引canvas-input-next-integration.md，最终报告animation-tween-independent-delta.md、animation-tween-independent-visual-final.md。
- Task4仍未完成：Canvas transition语法／presentation-only属性过渡／同属性双驱动冲突未接；高DPI/GPU/辅助技术、实验室、性能及视频对齐缺口保持。保留主线继续位置，不提交／发布。

### Canvas transition／presentation：限定独立验收通过（2026-10-28）
- `transition:` 支持属性白名单／默认180.ms easeOut、首帧直显、accepted目标从当前显示值重定向、group原始变换分量、颜色Some→Some、reduced直切及稳定key；不在纯属性帧重跑用户view。presentation/anchor随现有Instance patch与State/Host唯一gate接受或回滚。
- 最新final592文件、11源码路径增量；独立Linux18套126项、精确新EXE原生transition2＋animation2＋Canvas20＝24项、实际示例系统mouse_event19项全部通过；5张实际Windows VM截图静态视觉通过。仅96DPI/software/full；不是全仓测试、高DPI/GPU/FPS或物理输入证明。
- 原生首轮中间态观察失败留存；只改测试计时起点后final及独立重跑通过，不作产品RED／唯一根因声明。源码前后592 hashes一致，原会话已核raw logs、有限增量diff及单一提交路径。
- P2观察保留：捕获双驱动错误后继续pump可重复拒绝、别名来源检查保守、presentation预算保守、同帧dirty＋presentation归一化冗余、原生墙钟观察潜在抖动。API已说明前3项；冗余未优化，normalizedHosts按实际归一化调用次数而非唯一host计；时序夹具风险不扩展成产品缺陷。
- Task4整项RED/GREEN/Verify仍不勾选，完整跨环境验证不在本限定结论内。下一实现主线是Task5实验室／参数与单步，再冻结性能负载；高DPI/hardware/辅助技术和视频对齐缺口不抹除。无提交发布。
- 证据仍用统一canvas-input-next-integration.md；正式报告canvas-transition-independent-functional.md、canvas-transition-independent-visual.md；原会话核验canvas-transition-parent-evidence.json。

### Task5实验室功能子切片：限定独立验收通过（2026-10-28，整体仍未完成）
- 新入口examples/graphics_lab/main.nim及同目录README；scene私有封存，三类固定seed负载与Canvas DSL共用采样，新增sealed path geometry复用。播放暂停／百分比定位／1/120周期单步、左右±5%/Home/Space及原生Tab/Space、size/alpha、可交互transition圆点与三档规模完成。
- 独立Linux54、系统UI27、五张Windows VM静态视觉通过。原生Lab1覆盖九负载EndDraw/资源归零，既有compatibility22和新transition夹具3分属各自已核源/EXE，不加称某一final全量重跑。旧minimize观察P1已受控复现为夹具假阴性，改状态驱动后3用例独立两次通过，负控不冻结被捕获；不修产品或删失败证据。
- 当前验收以graphics-lab-accepted-input.json的base598＋fixture overlay为准：composite598 aggregate18b8950af2b126177a34e24cbab7df1ed129e5fcc23e0c9211228e1fad5c1d52。原8路径功能增量不变，新夹具作为第9路径单独列；旧清单不覆盖。不为只改测试重跑Linux/UI旧矩阵。
- 正式producer、JSON/CSV、Release 5s/30s×3独立进程、环境基线比较仍缺；全仓入口540s timeout未完成。Task4/5整项RED/GREEN/Verify保持未勾选，高DPI/hardware/辅助技术/video与旧P2限制不抹除，无Git交付授权。

### Task5 正式性能 producer：CPU侧基线限定独立验收通过（2026-10-28）
- 无HUD Release ORC producer、独立进程runner、raw JSON／CSV验证及兼容比较落盘。静态重绘accepted帧，动态沿用State/BackendSession；工具链绑定Nim/GCC二进制、版本、flags、manifest内容hash，不只匹配Nim版本。
- Linux证据为first609 57项中的未变35项＋final609 affected24项替换旧22项，共59种（不是final一次全重跑）；final609 default Win32 Canvas20＋仪表化1种实际独立重建通过，后者内部3cycles，额外重建是replicates不是新测试数。旧UI/整矩阵不重贴为final重建。
- 正式27个独立process（九组各三次，5s/30s）全部exit0、无timeout，44,522次操作；独立615项复算、27CSV字节重建、11正负控，主控核源／diff／工件，`--require-formal`输出validated-baseline。first9短跑与单长窗口探针不计入27。
- 三次process p95中位数（ms）：static100/1000/10000=1.4223/2.5185/9.4485；properties=1.8951/4.3267/26.7422；geometry=1.8158/4.1722/28.1029。10k动态CPU侧已超预算，不等于稳定60FPS；无GPU／显示FPS证据、无第二历史正式基线改善结论。详细范围见benchmarks/CANVAS_PERFORMANCE.md。
- Task4/5整体继续不勾选：全仓历史540s timeout、150/200%／mixed-DPI、hardware／AT／video及旧P2不抹除。不做Git提交／推送／发布。

### 2026-10-29 Canvas 优化限定独立验收与代码交付准备

- 已实现轻量有限／Native FLT_MAX校验及scene-local immutable SDK path驻留，未改producer负载／协议／事务门。独立Linux43、默认无测量Canvas23、插桩1通过；同入口静态视觉未见明显损坏。CI测试入口overlay另行独立2项通过，不混入609测量源码。
- 最终同会话properties-10000配对6进程：process p95中位27.9546→21.5598ms（−22.88%）。第二正式9×3进程全部exit0，独立615项／27 CSV通过，主控验证器validated-baseline；10k动态新p95为22.4941／19.9402ms，仍超16.667ms，不是60FPS／GPU时间证明。
- 九组全部差值和离散保留于benchmarks/CANVAS_PERFORMANCE.md。低负载／staticFrame跨会话升高未隔离归因，不把并发负载作唯一解释，也不把三次spread当普适门限。阶段p95不作成本占比；Native归零不等于heap/RSS/GDI/USER或长期无泄漏。
- 测量609源码b40bb8f…、EXE04b390bf…、原工具链a93f3369…；Git交付含独立接受的CI选择器overlay与后续事实文档，不伪称整棵Git树就是旧609。原始档案不覆写。主控裁决纠正审查中FLT_MAX“缝隙”误报（常量二进制恰为扩展FLT_MAX）及旧zero语义误述。
- 用户已明确授权“提交代码”：当前main整合本任务源／测试／文档→push核实GitHub远端→跟进同SHA四个自动workflow及必需产物，完成后按安全条件核本任务空间归档。当前尚未push／核CI，不把交付准备写成成功；实际SHA／Actions／资源及空间结果保存在统一canvas-input-next-integration.md。
- Task4/5整项及硬件／高DPI／AT／video继续未完成；历史全仓540s timeout不改称当前通过，新的整仓CI结论以本次SHA为准。此前“无提交授权／性能未实现”等段落均属所标历史批次，不覆盖本条最新状态。
