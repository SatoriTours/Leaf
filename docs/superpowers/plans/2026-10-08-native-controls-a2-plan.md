# Leaf A2：Win32 原生表单实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 A1 已验收协议之上交付可独立选择的 Win32 Unicode 表单、原生测量线性布局与受控组合输入，并用真实 Windows 证据验收。

**Architecture:** Nim 直接调用 Win32，Host 管窗口、消息循环及所属线程，Backend 管实体与资源；纯布局/编辑状态机可在 Linux 测试。沿用当前 BackendSession、owner-bound RuntimeInstallLifecycle 与增量批次，补足事件结算及 restore 后监听身份通知，而不新建事务框架。原生分支编译期隔离 GPUI；旧 API、headless 和默认 GPUI 保留。

**Tech Stack:** Nim 2.2.6+ / ORC / unittest；标准 `windows/winlean`（`std/winlean` 导入）和私有缺失 Win32 W API 绑定；user32、gdi32、comctl32、imm32 等系统库，无 Rust、第三方 UI toolkit 或新增 Nim 包。

**Spec:** `docs/superpowers/specs/2026-10-07-native-controls-design.md`（已批准；重点 §4–8 / §13–15）；A1 阶段拆分见 `docs/superpowers/plans/2026-10-07-native-controls-a1-plan.md`。

## 状态 / 审阅 gate

初稿commit `b1b0db7` 保留；本次按 `coordinator-plan-review.md` 修订§7线程body-entry、§8显式组合取消及诊断/真实故障边界。本计划 **待主Agent复核、用户确认后才能执行**。“好的，那你继续”批准推进阶段，不批准尚未存在的计划；当前不编码/改 CI/安装工具链。工作区 `/home/jimxl/.paseo/worktrees/1c1rvoii/native-controls-a2`，branch `feat/native-controls-a2`，BASE `74a697ada668a58adae7328ab63f2f3601c5edec`；A1/main 只读，不 merge/push。

A2 仅基础 NodeKind 表单、Host、线性布局、编辑与组合输入、显式 native 工具链选择。**virtualList 原生池、scroll/navigation、Direct2D/Canvas、完整数据库纵向样例和 release/package/SDK发布归 A3；Android/JNI/Views/SQLite/lifecycle 归 B。** 不新增这些节点，不缩减后续阶段。A2 通过也不等于总体 A 完成。

本批 Windows 原生验证目标为 **x86_64、Windows 10 1703+ / Windows 11**；PMv2 要求 1703，GetDpiForWindow 的 1607 不足以推导 PMv2。Windows Server 2022 runner 可跑 API 自动化，但不替代客户端真人 IME/DPI/accessibility。此边界随本计划审阅，不改变 GPUI 既有系统支持；更早 Windows/其他架构不声称本批支持。

## Global Constraints

- 首批平台为 **Windows + Android**；没有通过验收的平台不进入支持清单。Nim 管应用状态、页面、事件和业务逻辑；原生对象不进入可序列化快照，闭包始终留在 Runtime。
- 相同父路径/key/kind 复用；跨父移动、类型替换或卸载重建是新实体。重复 sibling key 拒绝，无 key 按位置；discarded handle 不回收。
- “原生控件提交也不是数据库事务”；不回滚闭包对业务对象的修改，不引入通用业务/SQL回滚或修改 ORM executionScope。
- “准备阶段不改动可见控件、不执行业务回调”；所有 Runtime 闭包、提交、行构建在所属 UI 线程，禁止提交中递归业务 dispatch。WndProc/Subclass 不泄漏 CatchableError。
- 仅已知装饰 compatible 降级一次结构化诊断，strict 挂载前拒绝；未知属性/非法值始终错误；required 控件/布局缺失直接拒绝，不默默近似。
- 首版非完整 CSS/Flexbox；“full 转为父容器剩余空间内的 fill，不是无限尺寸”；非负 flex_grow 是剩余空间权重。min/max、flex_shrink、around/evenly 不声明就拒绝。
- 原生 UI 意外部分 apply 失败尝试旧 accepted 重挂载；失败冻结业务 dispatch。不承诺恢复 selection/IME 暂态、不允许半更新继续触发业务。
- 同文本 ack 不 setText、不丢光标/选区/撤销/组合；拒绝/格式化必须同步最终 accepted 值，即使 batch 无 op。组合冲突只随成功接受更新，结束时按最终模型同步；应用可显式要求取消组合并重置，T1 resetToken / T5 ForceCancel 是明确的同值ack例外，仅成功accepted后生效。
- 重绘只读已接受控件状态（原生编辑暂态由系统控件持有），不业务 render；尺寸/字体/DPI 只使测量布局失效，不重建稳定 input。
- 保持 `MaxNodes = 10_000`、`MaxDepth = 64`、`MaxStringBytes = 1_048_576`、`MaxTreeBytes = 16_777_216`、`MaxListItems = 100_000`、暖行缓存最多128及现有字节预算；Win32 转换另检查 UTF16 长度/整数溢出，不扩大公共预算。
- 旧桌面默认 GPUI；构造器/DSL/JSON 快照形状、事件旧字段、ORM 保留。原 RuntimeCommitter/Preparer/ExecutionScope 与 install* 的旧调用兼容，RuntimeInstallLifecycle 不被绕过。
- native 应用构建/运行不 ensure/stage/load GPUI、不 Cargo；headless-only 不 import/link 图形工具包。既有 GPUI SDK 可继续带旧桥接，但 native 应用不依赖它。

## Review Focus

1. **无差异拒绝/格式化、两次未 drain 输入：** 最终 Native 必须等于 accepted；处理较早事件不能抹掉较新的编辑；T1/T5钉住。
2. **组合结束/显式取消与失败候选交错：** pending conflict/reset仅来自成功接受模型；普通同值ack不结束IME，同值显式reset一次取消；真实中日文与synthetic分gate；T1/T5钉住。
3. **restore后/OS复用旧身份：** listener 捕获 session/mount/binding，不在 drain 临时读取“最新身份”；旧 HWND/ID/cookie 通知不能命中新控件；T1/T4/T5钉住。
4. **异线程Scope body/忙时关闭/FFI异常/半创建：** 在任何Runtime closure前拒绝异线程body；close不丢、catchable不越ABI、root/font/subclass/HWND可清理重试；T3/T4钉住。
5. **有限/溢出/高DPI空间：** layout 不偷偷 shrink/近似 unsupported，字体/DPI/paint 不 render 或销毁 editor；T2/T4/T5钉住。

## 平台 gate / 执行分工

- **L（Linux）**：纯属性/协议/布局/编辑状态机和旧回归。固定编译器 `/tmp/nim-2.2.6/bin/nim`。`nim check`、recording、fake WinApi 仅各自边界，不算 W/H 通过。
- **W（Windows API）**：真实 W API、HWND/子类化/GDI/manifest、失败注入、消息自动化；至少真实 Windows x64 + Nim2.2.6 + MinGW GCC/windres。测试必须创建实际窗口，缺 API/桌面不是 PASS。
- **H（真人客户端）**：解锁交互桌面，Microsoft Pinyin 与 Microsoft Japanese IME、键盘/焦点、emoji选区、跨实际不同DPI屏幕、Narrator/Accessibility Insights。截图/版本/逐项动作与数值日志；WM_IME_*模拟不代替 HIMC/TSF/真人。
- **当前前提：** Linux 没有 MinGW/Wine/PowerShell/Windows；clang 不等于 Windows SDK。主Agent已在 A2 BASE 执行50 suites/402 OK/0 FAILED/5既有SKIP/exit0（artifact `baseline-full-suite.log`），不是规划者新执行，既有 GPUI 库仅过程借 A1 artifact，不是 native 依赖。
- **取得机器：** 用户/主Agent在 T3 前确认一台现有 Windows 开发机/VM 的授权访问及工具路径、在 T5 前确认客户端交互桌面/中日文 IME/不同DPI显示器与操作者。若没有，T1/T2可交付 L，T3+ W与H记 **NotRun/Blocked**，A2不得宣称 Approved。禁止本机系统安装/服务/config变更。
- 另一个可选 **W-only** 通道是后续获准发布代码后由主Agent显式触发 `windows-2022` manual workflow，复用 `prepare_windows_sdk.ps1` 和按需要的 HTTPS脚本；现在没有 push/远程CI触发授权，不假定runner已可用。CI也不能自动关闭H。取得方式选定后写platform-env.md（机器/OS/session/工具/责任人），不改总体架构。
- 方案已给定，沿用现有执行方式/会话：常规协议/backend/FFI/tooling由「日常工作」，普通Native也不默认「高消耗工作」；只有有证据的疑难ABI/IME问题升级；本独立架构角色逐task验收及最终验收。没有真实业务视觉设计需求，不派Gemini；必要时只给明确视觉范围。主Agent协调集成，不再创建reviewer/子Agent。任务顺序1→2→3→4→5→6，每个task可单独拒绝，不能用后一task绿灯补前一task未验。

## Files / 职责

| 文件（新增除非标“改”） | 单一职责 / owner task |
|---|---|
| 改 `core.nim`、`styles.nim`、`widgets.nim`、`backend.nim`、`backend_session.nim`、`gpui_bridge.nim`、`docs/architecture.md` | T1 additive composition/resetToken、typed required能力、纯accepted通知/结算/restore；GPUI只拒绝新非零reset信号，不重构A1 gate或放宽公共属性 |
| `src/leaf/native_edit.nim` | T1 平台无关受控值/sequence/selection/composition状态机 |
| `src/leaf/native_layout.nim`、`backends/win32/capabilities.nim` | T2 DIP布局、纯能力表/规范边界，无 Win32 imports |
| `src/leaf/ui_thread.nim`；`backends/win32/api.nim`、`calls.nim`、`host.nim`、`host_state.nim` | T3 Scope body-entry守卫、系统ABI与真实调用依赖边界、所属线程窗口循环、close状态 |
| `backends/win32/backend.nim`、`controls.nim`、`measure.nim`；扩展 `calls.nim` | T4 batch/资源、stock控件/测量cache、调用边界延伸与只读生产诊断 |
| `backends/win32/edit.nim`、`src/leaf/backends/win32.nim` | T5 edit subclass/IME/通知来源及薄runNative入口，避免host/backend循环依赖 |
| `src/leaf/targets.nim`；改 `project/build/doctor/runner.nim`、`src/leaf_cli.nim`、最小改 `pack.nim` | T6 backend/target决策、编译期入口、工具链与native pack明确拒绝 |
| `tests/nim/test_native_{edit,layout,toolchain}.nim`、改现有native styles/backend/commit测试 | T1/T2/T6 L；行为回归而非只编译接口 |
| `tests/nim/test_ui_thread.nim`、`test_win32_host_state.nim`；`tests/windows/test_win32_{host,controls,input,toolchain}.nim` | T3线程/close纯契约及真实线程；T3–6实际Windows，不用Linux SKIP冒充 |
| `tests/windows/win32_form_probe.nim`、`scripts/test_win32.nim` | T3建立明确Windows-only runner，T5真实表单probe与H手册；runner测试非Windows出口 |
| `examples/native_forms/{leaf.json,main.nim}`、`docs/native-win32-validation.md` | T5同一纯Nim表单/验收动作，T6显式backend配置与build命令；不是数据库纵向例 |
| `.github/workflows/windows-native-check.yml`（后续可选）、改 `docs/architecture.md` | T6 W-only manual验证入口与只据实更新支持矩阵；不改现有GPUI SDK workflow |

表中 `core.nim` 等均在 `src/leaf/` 下，`backends/` 同属该目录。A1 M-remove 在T1协议文档澄清；M-record-index在T2明确recording镜像非位置权威、不用于layout oracle；M-attrs永久边界与T1合并，不单开polish任务。

### 统一执行/日志约定

在A2根目录运行。L套件以下命令中的NIM固定为绝对路径，统一 fresh cache与out（先 `mkdir -p target/nim/a2`）；RED/GREEN日志和exit code写 `.superpowers/sdd/2026-10-08-native-controls-a2/task-N-*`。新模块缺失的编译RED可记录，但最少一项行为断言还需在实现前/临时撤回相关实现时RED；GREEN后恢复实现，绝不留故意失败代码。新增 Windows runner 非Windows必须 exit2并打印NotRun，而不是skip后exit0；W步骤若环境缺失就阻塞，不伪造RED/GREEN。

`L(NAME)`（各task下面给确切NAME）展开为：
```sh
/tmp/nim-2.2.6/bin/nim c -r --path:src --nimcache:target/nim/a2/cache-NAME --out:target/nim/a2/NAME tests/nim/NAME.nim
```
`W(NAME)`在已授权Windows根目录展开为（先创建target/nim/a2，NIM为该机器的nim.exe绝对路径）：
```powershell
& $env:NIM c -r --threads:on --path:src "--nimcache:target/nim/a2/cache-$NAME" "--out:target/nim/a2/$NAME.exe" "tests/windows/$NAME.nim"
if ($LASTEXITCODE -ne 0) { throw "suite failed: $NAME ($LASTEXITCODE)" }
```
记录compile和run原始exit，测试输出不得有FAILED；Windows环境实际路径由platform-env.md固定，不把Linux `/tmp` 路径复制到Windows。

---

### Task 1：平台消费所需最小协议与受控编辑状态机

**Files:** 表中T1；新 `tests/nim/test_native_edit.nim`，改 `test_native_{styles,backend,commit}.nim`。

**Consumes（当前生产签名，不用A1旧草案）：** `Backend.prepare/apply(UpdateBatch)`、`discardPrepared()`、`restore(Table[NodeHandle,MountedEntity])`、`dispose()`；`attachBackend(runtime,backend,HostContext,mode=compatible):BackendSession`；`installCommitter(runtime,RuntimeCommitter,lifecycle=default(RuntimeInstallLifecycle)):uint64`、`installPreparer(runtime,RuntimePreparer):uint64`；`EventEnvelope` 的 session/mountGeneration/handle/sequence/observedRevision/source/event；acceptedEntities/mountGeneration、normal gate与pending install confirm/abort。

**Produces（均additive，本文审批后才实现）：**
- core：`CompositionPhase* = enum compositionNone, compositionStart, compositionUpdate, compositionResult, compositionEnd`；`Event.composition*:CompositionPhase` 默认None；不增加EventKind、不改变旧snapshot事件JSON。旧 `e.value/e.checked`继续工作，composition使用change且value为完整editor文本，不把partial composition string冒充整个value。
- backend：`EventSettlement*`含 `sessionId,mountGeneration,bindingGeneration,sequence,revision:uint64; handle:NodeHandle; props:NormalizedProps`（无Node/callback/HWND）。可选字段 `accepted*:proc(entities:Table[NodeHandle,MountedEntity],revision:uint64){.closure,raises:[].}`、`rebind*:proc(sessionId,mountGeneration:uint64){.closure.}`、`bindingValid*:proc(handle:NodeHandle,bindingGeneration:uint64):bool{.closure.}`、`settle*:proc(value:EventSettlement){.closure.}`。原五必需字段/旧调用兼容；未提供者保持A1行为。
- session：`EventEnvelope.bindingGeneration*:uint64` 默认0。bindingValid非nil时enqueue与process均复查；accepted通知在acceptPlan完成后仅复制框架metadata，禁止Native API/render/业务，尤其install confirm无额外apply。initial rebind在取得Backend lease后、安装try内、第一prepare前先告知HostContext身份（失败沿本次lease清理）；restore仍先执行旧签名restore，再增加generation，清queue/sequence，调用rebind重新arm，成功才解冻；rebind失败与restore失败同样fault+freeze direct dispatch。
- process在有效活实体的事件处理后（含无handler/disabled、业务拒绝、空batch）结算最新accepted props；在Runtime Scope完全返回后、未busy且session/handle/binding仍有效才settle。generation改变/closing/fault/removal不结算旧事件。settle本身失败明确fault/freeze并诊断，停剩余批，不能递归业务或重放callback。settle是UI元数据效果，不读取业务/DB、不render、不安装新hook；不扩成普通Scope业务回滚。
- **显式组合取消信号：** `input*(value:string,onChange:Callback=nil,key="",placeholder="",onSubmit:Callback=nil,disabled=false,styles:Styles=default(Styles),resetToken:uint64=0):Node` 仅在末尾添加可选参数。普通 `view: input(state.value, resetToken=state.reset)` 可触发；应用递增token并显式refresh或在普通事件后render，不调用Backend测试方法。0/省略不增加Node属性，旧构造器调用/默认JSON逐字保持；非零输出已有attributes中的 `"input_reset_token"` 十进制字符串，`ControlProps.resetToken*:Option[uint64]`。typed转换只允许input及无符号十进制0..high(uint64)，拒负数/溢出/浮点/错kind；不走float styleNumber。`ControlFeature* = enum cfInputReset`，`BackendCapabilities.controls*:set[ControlFeature]` 默认空，fullCapabilities声明该测试能力；非零token必须cfInputReset，compatible也不能装饰降级。Win32 T2声明支持；headless校验信号不宣称取消IME；旧GPUI在bridge的独立validator分支拒绝新非零token，不改gpui_styles style-only规则、不把旧control属性全面强验。这是§8的最小additive公开形状，随本计划一并审阅，不是新事务API。
- native_edit：`ControlValue*`含 `text:string; checked,isCheck:bool`；`Selection16*`含 `anchor,caret:int`（UTF16 codeunits）；`EditorState*`含 `accepted,native:ControlValue; phase:CompositionPhase; latestObserved,lastSettled,acceptedRevision,consumedResetToken:uint64; conflict:Option[ControlValue]; pendingReset:Option[uint64]; selection:Selection16`；`EditEffectKind* = enum forceCancelComposition,setText,setChecked,setSelection`；`EditEffect*`含 `kind:EditEffectKind; value:ControlValue; selection:Selection16; force:bool`。上述纯值字段对tests/adapter导出，不导出任何原生资源。
  `newEditorState*(accepted:ControlValue):EditorState`初始化native=accepted/phase=None/sequence=0/no conflict/no reset；`observeEditor*(s:var EditorState,value:ControlValue,phase:CompositionPhase,selection:Selection16,sequence:uint64)`；`acceptModel*(s:var EditorState,value:ControlValue,revision:uint64,resetToken:Option[uint64]=none(uint64))`仅成功accepted metadata；`settleEditor*(s:var EditorState,sequence:uint64):seq[EditEffect]`处理普通ack；`resetEffects*(s:EditorState):seq[EditEffect]`在pending token大于consumed时输出ForceCancel→forced setText(最新accepted)→selection到文本尾，不能在生成效果时提前消费；`completeReset*(s:var EditorState,token:uint64)`仅完整Native效果成功后消费/清pending。同token/回退/0/属性删除不再次取消；失败candidate不记录token，token可原值重试；restore保留同handle已消费token，新identity不继承旧editor暂态。初次mount在无组合的新EDIT设好模型后可完成该token，不能留初始token在未来组合时突然执行。
  普通同文本或旧sequence无setter、组合未结束不写冲突；成功reset明确优先于取消前旧input，其binding在accepted后标pending-reset使旧输入无效，T5执行成功后重新arm新binding；不同于普通ack的较新编辑保留规则。selection夹取不截UTF16代理对，普通拒绝/格式化保留公共前缀内位置、其余夹取到新边界；显式reset允许终止IME/重置选区与撤销，不承诺跨平台撤销栈一致。

- [ ] **RED tests：** `zero diff rejection resets editor`：accepted="7", Native="x",模型仍"7"、batch.ops.len=0，settlement仍setText("7")恰一次；format(" 7 ")→"7"同样。`same text ack preserves selection and composition`无setter；输入seq1="a"、seq2="ab"排队，处理1无setter，处理2才按finalmodel；checkbox/toggle拒绝时setChecked(old)一次。comb start/update/result/end期间两次成功conflict与一次失败candidate，只保留最后成功值，end才同步；无conflict不破坏默认IME。
- [ ] **RED reset：** 组合中普通同值ack无effect，但成功accepted同值resetToken=1输出ForceCancel/forcedSetText/末尾选区一次；candidate失败或install Scope post失败无cancel/pending变化，原token重试成功才生效；同tokenrefresh/no-op不重复，token2可再reset；去掉/降token无cancel；非input/负数/超uint64拒绝、capability缺失compatible仍拒绝；默认input JSON/DSL原调用不变、GPUI旧style-only回归不变而显式新token拒绝。
- [ ] **RED协议回归：** recording注入fake listener证明restore回调仍见旧代际、rebind见新代际且一次；失败rebind冻结direct dispatch；optional钩子nil保持原44；install pending的accepted通知只在成功confirm；stale binding进入pending批后失效不dispatch；callback报错但旧accepted可结算、不重放。补M-attrs旧variant/GPUI control attr style-only/lazy非法属性；document remove handle权威、index historical，不改remove算法。
- [ ] **Run RED：** `L(test_native_edit)`、`L(test_native_backend)`、`L(test_native_styles)`；Expected接口RED及上述实际断言RED，不以未安装Windows当RED。
- [ ] **Implement：** 只上述纯状态机/optional hooks与精确调用点；不触及已有owner/busy/scope发布时序，不继承installation标记到普通candidate。
- [ ] **Run GREEN：** 同三套+`L(test_native_commit)`、`L(test_native_reconcile)`、`L(test_core)`、`L(test_view)`、`L(test_gpui_bridge)`、`L(test_model_postcommit_ui)`；全部exit0，selfreview L全部状态矩阵、旧hook调用兼容与nil paths。
- [ ] **Gate/commit：** 独立架构核对新增接口不越Native框架范围，特别confirm无外部Native。仅本task文件 `git commit -m "feat: settle native controlled events and rebind restored listeners"`；不批准业务回滚扩展。

### Task 2：有限 DIP 线性布局与真实能力边界

**Files:** native_layout、win32/capabilities；`tests/nim/test_native_layout.nim`、native_styles/reconcile相关回归；协议文档。

**Consumes:** `MountedEntity`/typed `LayoutProps`/`DecorationProps`；Session acceptedEntities中的index是accepted sibling位置；不消费Recording.entities.index作layout权威。

**Produces:**
- `DipSize*`含width,height:float64；`DipRect*`含x,y,width,height:float64；`LayoutBox*`含handle:NodeHandle、rect/clip:DipRect；`MeasureProc* = proc(entity:MountedEntity,available:DipSize):DipSize {.closure.}`；`layoutTree*(entities:Table[NodeHandle,MountedEntity],content:DipSize,measure:MeasureProc):seq[LayoutBox]`；`pixelEdges*(rect:DipRect,dpi:int):tuple[left,top,right,bottom:int]`，以共享边界round避免累计缝隙，不独立round每个width；系统整数边界转换先检查，完全在clip外的实体保持身份但不传越界坐标给SetWindowPos。
- `win32Capabilities*():BackendCapabilities`：controls={cfInputReset}；kinds={column,row,text,button,input,checkbox,toggle,progress,tag,separator,spinner}；layouts={lfGap,lfPadding,lfWidth,lfHeight,lfFlexGrow,lfAlign,lfJustify,lfOverflow}；align全部四值；justify仅start/end/center/between；overflow仅hidden（缺省也hidden）；decorations={}（本批只原生系统font，不宣称支持任意font_size/weight/颜色等装饰）；variants仅default。不支持virtualList/minmax/shrink/around/evenly/scroll/visible，required明确拒绝；其他装饰/variants沿compatible/strict，不自绘危险/强调外观假装支持。
- 缺省gap/padding=0、align=start、justify=start、dimension=auto；auto从递归原生preferred测量，fixed为DIP基数，fill基数0且默认权重1；显式flexGrow>0给剩余空间权重（含fixed基数的显式增长），0不增长。分配max(0,可用-main padding-gaps-bases)，负余量不shrink，按clip裁剪；justify仅正余量，between单子无除零。交叉stretch只扩未显式fixed的auto/fill，不压小intrinsic。root采用有限content，auto容器intrinsic由子树+gap/padding得出，不能递归fill到无限；无循环/NaN/负输出。

- [ ] **RED tests：** row content120x40,padding5,gap5，fixed10、fill weight2、fill weight1 → widths10/60/30，x5/20/85；nested column、empty/single、gap大于空间、超大intrinsic、10_000个大fixed/gap累计超32bit但clip有限、0尺寸、crossfixed+stretch、负剩余无shrink、between、UTF文本假measure及96/144/192边界round。measure调用数和结果缓存职责分开，不从recording metadata猜位置。
- [ ] **RED capability：** 每个required extended值拒绝、radius compatible warning/strict error、default switch复选映射说明；Recording.childrenOf对照顺序，文档标Recording.entities.index非权威。`L(test_native_layout)` Expected断言FAIL。
- [ ] **Implement：** 有界树测量/分配，不Flexbox、不parse Styles字符串、不业务render；capabilities独立纯模块，能在Linux验证拒绝；不新增scroll来掩盖overflow。
- [ ] **GREEN：** 同套+`L(test_native_styles)`、`L(test_native_reconcile)`；selfreview nested fill、边界溢出与unsupported在挂载前拒绝。W真实字体测量/DPI留T4，不声称此task已经原生测量通过。
- [ ] **Gate/commit：** 架构验收纯布局和能力表可单独拒绝；`git commit -m "feat: add bounded DIP linear layout for Win32 forms"`。

### Task 3：Unicode Host、ABI边界与可重试关闭

**Files:** ui_thread、win32/api、calls、host、host_state；test_ui_thread、test_win32_host_state、tests/windows/test_win32_host；scripts/test_win32。

**Consumes:** `initializeWindowsDpi():DpiResult`现有host_context政策；Application/newRuntime、Session disposed/closing/faulted/installingUpdate/dispose；T1恢复身份、T2有限content。

**Produces（先于任何Runtime初始化）：** `ThreadIdProc* = proc():uint64 {.closure,raises:[].}`；`guardUiApplication*(app:Application,currentThread:ThreadIdProc):Application` 放 `src/leaf/ui_thread.nim`，调用时立即捕获expected=currentThread，返回app的值副本，包装executionScope，不提前render。wrappedScope调用原scope前检查owner，再把 `proc() = checkOwnerAtBodyEntry(); body()` 交给原scope（nil则直接执行该guarded body）；所有render/handler/rowbuilder/validator/preparer/committer action在body-entry检查之后，不能把apply检查当替代。getter在Win32为真实GetCurrentThreadId转uint64，L可注入线程ID；guard不import Win32、不改ORM scope参数/context或Runtime安装发布顺序。原scope仍须同步、body恰一次；拒绝异线程/0次/重复body，跨线程拒绝用每次调用的原子latch保证即使原scope吞掉worker异常也在owner返回时抛UiError，不默许未render的Runtime初始化成功；有原scope primary/post-body异常时保留其类型/chain（guard违规作为secondary）。正常post-body异常不被吃掉、不新增业务回滚，A1 install abort仍收到原异常。

`Win32Calls*` / `systemWin32Calls*():Win32Calls` 在 `calls.nim` 先定义Host用的注册/创建/销毁/消息API依赖字段（W参数/返回按api.nim，Nim内部wrapper用closure，不把closure当stdcall FFI），全转发真实系统；T4延伸font/subclass/setter/IME字段，见T4精确故障机制。`HostDiagnostics*`含只读copy `liveWindows,liveRoots:int; callbackErrors:uint64; pendingClose:bool`，`diagnostics*(host:Win32Host):HostDiagnostics`供生产资源观测。

`Win32Host*`（opaque ref，HWND/线程/owner/root在私有实现）；`createHost*(title:string,size:DipSize,calls:Win32Calls=systemWin32Calls()):Win32Host`；`context*(host:Win32Host):HostContext`；`setSafeTick*(host:Win32Host,tick:proc(){.closure.})`；`requestClose*(host:Win32Host)`；`pump*(host:Win32Host):int`；`destroyHost*(host:Win32Host)`。`CloseState*`存pending/posted/complete；`requestClose*(s:var CloseState)`、`closeOnTick*(s:var CloseState,busy:bool):bool`表示本tick是否可尝试，不先消费请求；成功dispose后才complete，失败仍pending并诊断。重试合并WM_APP/timer，nested busy tick不自旋，outermost dispatch finally重新排safe tick；同一host所有操作检查GetCurrentThreadId所属线程。

api.nim最小私有W绑定，按标准pointer-sized HWND/HANDLE/UINT_PTR/DWORD_PTR/WPARAM/LPARAM/LRESULT、固定DWORD/UINT/WCHAR和Windows结构alignment；WndProc与SUBCLASSPROC `.stdcall, raises:[]` 外层catch CatchableError返回安全LRESULT/DefSubclassProc，错误入host记录，safe tick再处理。Defect/内存损坏不伪称可恢复。Nim registry强root持host/control refs，USERDATA/subclass refdata只放检查过的数字cookie，不可解引用Nim地址；remove subclass/WM_NCDESTROY后释放root。ABI与结构sizeof用Windows头文件编译时static assertions（测试内最小C断言，无产品C shim），不以x64“stdcall忽略”替代类型正确性。

- [ ] **RED L thread：** `L(test_ui_thread)`钉住包装前capture、original scope context保留、正常body一次、post-body原异常保留、fake转移body/吞掉拒绝仍失败且action计数0；newRuntime初始render、dispatch handler、materialize rowbuilder三入口分别断言执行0，不等到committer。配套真实线程命令：`/tmp/nim-2.2.6/bin/nim c -r --threads:on --out:target/nim/a2/test_ui_thread tests/nim/test_ui_thread.nim`；用join同步、owner保活的borrowed body trampoline让scope在worker调用，错误转回owner，不执行业务于worker、不从此引入异步Scope支持。
- [ ] **RED L close：** `close request survives busy tick and disposal error`；三次close只一次pending，busy不consume；失败重试，complete后幂等。`L(test_win32_host_state)`。
- [ ] **RED W thread：** `W(test_win32_host)`用GetCurrentThreadId真实worker转移scope body，分别验证initial newRuntime/dispatch/materialize被拒，render/handler/rowbuilder/Native调用增量均0；先guard再newRuntime失败时连Host创建也0。正常scope/context、ordinary刷新与A1两阶段install/abort post-body failure回归照旧；hostOwner与guardOwner一致，wrong-thread直接调用wrappedRuntime也不能执行业务。
- [ ] **RED W：** `W(test_win32_host)`创建中文/emoji标题，实际GetWindowTextW roundtrip；WM_CLOSE在Runtime callback/Backend apply及嵌套pump时不销毁，不丢请求，外层安全tick最终dispose；wrong-thread拒绝（不在该线程运行Runtime）；GetMessage -1/0分支；用系统调用装饰层在真实class/root取得后拒绝CreateWindowExW一次，验证无泄漏/后续可正常创建；WndProc用正常safeTick closure经实际消息触发UiError不穿ABI，无test-only生产方法。
- [ ] **Implement：** 注册Unicode class、CreateWindowExW/message loop、IsDialogMessageW用于Tab导航，WM_SIZE/WM_DPICHANGED更新content/scale并通知安全布局；DPI在任何HWND前初始化，不修改已选host context。ownership包括 class/window/root/timer；退出时清safeTick/sink/session引用、切断root闭环，不以ORC“以后收集”替代资源关闭；每个失败路径按取得顺序逆序清理，不卸自己没拥有的class，不以destroy top window替代成功session.dispose。
- [ ] **GREEN：** 同L/W；Windows real window count、registry roots回到baseline；scripts/test_win32.nim扫描tests/windows/test_*.nim，Windows逐套compile/runexit0，非Windows明确NotRun exit2，不能无tests成功。通过前记录platform-env；W未具备就Blocked，不转为fake W。
- [ ] **Gate/commit：** selfreviewABI、root释放、busy/error close矩阵；独立架构执行W，`git commit -m "feat: host native forms in an owned Unicode Win32 window"`。

### Task 4：真实stock控件批次、资源与原生测量

**Files:** win32/backend、controls、measure、calls；tests/windows/test_win32_controls；按测量cache相关T2 tests。

**Consumes:** T1 Backend可选hooks/lease/accepted metadata、T2 layoutTree/MeasureProc/capabilities、T3 Win32Host/context/Win32Calls；UpdateBatch顺序，remove.handle权威，remove.index仅历史，update全量typed props、属性删除回默认。

**Produces:** `Win32Backend*` opaque；`newWin32Backend*(host:Win32Host,calls:Win32Calls=systemWin32Calls()):Win32Backend`；`asBackend*(win:Win32Backend):Backend`；`bindSession*(win:Win32Backend,session:BackendSession)`（成功attach后arm；之前无业务sink）；`relayout*(win:Win32Backend,content:DipSize,dpi:int)`不render；`measureControl*(win:Win32Backend,entity:MountedEntity,available:DipSize):DipSize`；`Win32Diagnostics*`只含只读copy的 `creates,destroys,setTexts,measures,layouts,callbackErrors:uint64; liveWindows,liveFonts,liveSubclasses,liveRoots:int`；`diagnostics*(win:Win32Backend):Win32Diagnostics` 是生产资源/性能诊断，不是test-only方法、不给计数setter/伪造实体入口；token/NodeHandle可以追踪，不导出HWND/Nim pointer到common protocol。Windows driver自行EnumWindows/EnumChildWindows并校验本进程/标题/ID，从真实W API读class/text/rect；用live counts交叉核对，不从计数绿灯推导实际控件存在。

`calls.nim`延伸T3私有生产系统调用依赖层：`Win32Calls*`含与api.nim完全相同W参数/返回（内部Nim closure而非FFI回调）的createWindowExW/createFontIndirectW/setWindowSubclass/setWindowTextW/setWindowPos/destroyWindow/deleteObject/immNotifyIME等操作；`systemWin32Calls*():Win32Calls`全转发真实系统API，生产构造默认用它。它不是公开leaf接口或通用mock框架，不引入failNext/testMode/setFakeWindow等生产方法。W故障driver装饰同一依赖表：其余调用真实系统，仅选定第N次调用在进入系统前SetLastError并返回该API合法失败值；先创建的HWND/font/subclass都是真实对象，cleanup后用API枚举/生产只读诊断观测。prepare创建到一半、apply在第N次实际setter前、restore重建、discard释放、dispose销毁的一次失败均记录真实资源trace/实际返回值与重试。不得把全套fakeAPI替代上述W；Host callback UiError通过正常safeTick closure/实际消息路由触发，不添测试异常注入方法。

| NodeKind | 实际映射/测量 |
|---|---|
| row/column | 不绘制业务的子窗口container，有限clip；尺寸由纯布局子树测量 |
| text/tag | STATIC Unicode，text从typed accessibility.label、tag从control.label；GDI当前font DrawTextW/GetTextExtentPoint32W（有限宽度文本换行），tag不额外假装装饰 |
| button | BUTTON push；设置相同font的不可见测量实体用BCM_GETIDEALSIZE，仅push适用，不用它“测”checkbox |
| input | 单行EDIT，cue placeholder、enabled/value；根据当前font metrics/边框原生系统度量，preferred width至少20个平均字宽及placeholder度量，height font+native margins；不是按字符UTF8字节数估宽 |
| checkbox/toggle | BUTTON BS_AUTOCHECKBOX，toggle明确为复选原生等价；label+theme glyph/spacing/font metrics，不承诺现代switch外观 |
| progress/spinner | msctls_progress32，progress0..100映射确定范围，spinner PBS_MARQUEE/PBM_SETMARQUEE，关闭必须停marquee/宿主timer资源 |
| separator | STATIC SS_ETCHEDHOR（语义horizontal separator），native/system metrics，不Canvas |

字体由系统message font与DPI建立；font_size/weight等未声明装饰遵循compatible诊断/strict拒绝，不能静默宣称已实现。WM_SETTINGCHANGE/theme/DPI改变系统font度量；HFONT共用有明确owner/refcounts，不能DeleteObject系统stock对象。测量cache key=(kind/effective typed props/available width/font+theme version/DPI)，临时控件不可见，不改live editor，不保留无限测量HWND。resize/theme/font/DPI失效只re-measure/re-layout、SetWindowPos/WM_SETFONT，稳定input HWND/handle/selection保留。

- [ ] **RED W：** 每种映射GetClassNameW/实际值/disabled；两个stable input更新label/move/sibling insert/remove，未改input创建数0，顺序按当前children而非historical remove.index；remove后同key/newkind全新cookie/handle；prepare拒绝/部分apply/restore/discard/dispose failure各owner资源清理；unknown|required caps在prepare前拒绝。
- [ ] **RED测量/layout：** 用真实字体/中文/emoji/button测量结果作layout输入（非跨机固定字形像素golden）；100%/150%/200% API尺寸重排、finiteclip，字体变更只measure/layout计数增，render/create input计数不增。相同tree纯layout使用该测量结果对照最终GetWindowRect相对坐标。
- [ ] **Implement：** prepare只创建隐藏临时控件/字体和不可变操作计划，不触visible；apply所属UI线程按batch执行、窄范围通知抑制、完整candidate native数据准备；accepted hook只提交metadata供缓存paint/控制值，不额外Native setter；restore清旧listener再重挂旧entities，listeners先unarmed，T1 postgeneration rebind后arm。禁止把恢复时读取旧generation的监听留到未来使用。
- [ ] **GREEN W：** `W(test_win32_controls)`、`W(test_win32_host)`及L布局/协议回归；每项失败注入成功清理后fonts/windows/subclasses/roots回baseline、cleanup secondary可见；Native own paint只cache/accepted，不render。selfreviewDestroyWindow同步WM_NCDESTROY期间cookie尚有root、无use-after-free。
- [ ] **Gate/commit：** 架构验收真实batch与测量，IME交互尚未完成必须标partial；`git commit -m "feat: apply Win32 stock control batches with native measurement"`。

### Task 5：真实编辑、composition、监听身份与受控结算

**Files:** win32/edit、controls/backend/host连接处；tests/windows/test_win32_input、win32_form_probe；examples/native_forms与docs/native-win32-validation；T1 puretests补对应回归。

**Consumes:** T1 EditorState/acceptModel/observeEditor/settleEditor/resetEffects/completeReset与EventSettlement、T3 guardUiApplication/safe ticks、T4 Win32Backend/session binding、原EventKind change/submit；T1恢复后rebind顺序。

**Produces:** `attachEditor*(win:Win32Backend,handle:NodeHandle)`、`detachEditor*(win:Win32Backend,handle:NodeHandle)`（内部使用，同owner/UI线程）；`runNative*(app:Application,diagnostics:Diagnostics=nil):int`放 `src/leaf/backends/win32.nim` 薄入口（import host/backend/edit，不构成host/backend循环import），次序GetCurrentThreadId捕获→guardUiApplication(app,真实ThreadIdProc)→newRuntime(guardedApp,validateProps)→createHost（核对同owner、DPI在任何HWND前）→newWin32Backend→attachBackend(RuntimeInstallLifecycle由Session自动安装)→bindSession→safeTick flushAcceptedEdits/drain/layout/close→pump→可重试dispose/destroy。输入没有onChange也不能放任失控值。

监听绑定捕获session/mount/handle/binding cookie；收到通知立即复制Unicode value/UTF16 selection及observed revision，分配单session sequence，不留HWND待drain再读。每控件setterDepth/source标记，EN_CHANGE/BN_CLICKED校验parent、HWND、control ID与cookie；commit中另一控件真正User仍入队，不把installingUpdate当Setter。control ID生命周期内不回收（WM_COMMAND low16 ID按范围检查，耗尽明确错误），HWND复用旧ID不能打新实体；subclass refdata旧cookie不可用。私有排队消息携带cookie而非只HWND，bindingValid两次复验。

**显式reset执行：** `flushAcceptedEdits*(win:Win32Backend)`由Host安全tick（Runtime Scope已返回、!installingUpdate、binding有效）调用，覆盖直接refresh/按钮改token等非该input的事件；accepted hook仅记pending token，不在confirm/apply做ForceCancel。新reset先使取消前旧input envelope的binding失效，安全tick重绑cookie并在该editor窄setterSource内执行 `ImmGetContext`→`ImmNotifyIME(himc,NI_COMPOSITIONSTR,CPS_CANCEL,0)`→配对ImmReleaseContext→forced SetWindowTextW(最新accepted文本)→EM_SETSEL末尾，成功后completeReset并arm；普通同值ack仍完全无setter。取消期间WM_IME_ENDCOMPOSITION/EN_CHANGE保留默认DefSubclassProc处理但标Setter，不合成User change/submit；其他editor真正User照常排队。若未在组合且没有HIMC，取消步骤为无组合no-op，reset文本/选区仍执行；观测正在组合却无法取得context或ImmNotifyIME失败明确fault/诊断，不伪称取消成功。default IMM/TSF消息链与真实中日文取消效果分别W/H验证，不强吞默认IME消息或手插result。旧已queued输入不能把reset后的accepted值反覆盖，安全tick后真正新绑定输入仍正常。

标准EDIT的WM_IME_STARTCOMPOSITION/COMPOSITION/ENDCOMPOSITION保留DefSubclassProc链；GCS_COMPSTR/RESULTSTR用ImmGetContext/ImmGetCompositionStringW并配对release，字节长度/负error/UTF16代理对处理正确。观测默认过程后的完整editor text，去重EN_CHANGE与composition result，不手工再插result导致双字。start/update/result/end对应Event.composition；未显式reset的普通同值ack不会setter/取消IME。组合中程序/其他事件成功model冲突只存accepted metadata；failed候选不污染；end在最后成功模型结算，重入/较新input未处理时延后，不覆盖它。Enter submit只有非IME确认路径触发一次，IME候选确认键不得额外submit；没有任意multiline模式扩展。

- [ ] **RED W zero-diff：** 真实EDIT输入"x"（WM_CHAR/EM_REPLACESEL Native消息路径，明确是自动化非真人IME），业务拒绝/trim后accepted仍"7"，断言无op仍Native="7"、setter一次/no递归change；相同ack setter0、selection未变；seq1/2在drain前排队，观察处理1后Native仍较新值，2后才final accepted。实际checkbox/toggle user click拒绝也回accepted bool（包括nohandler/disabled路径）。
- [ ] **RED W reset：** 普通DSL递增token直接refresh，真实EDIT已accepted同文本也走一次forced reset/末尾选区，same-token不重复；失败候选/Scope安装posterror不取消，重试token原值成功才执行。真实系统调用trace钉ImmNotifyIME参数/返回、Setter通知0用户回调；pre-reset旧envelope拒绝、新binding可编辑。synthetic phase只验routing，不冒充有真实HIMC。用T4调用依赖层一次真实API失败钉cancel失败不消费token、fault阻止业务；无组合/no HIMC路径仍reset。
- [ ] **RED W identity/source：** setter单行EN_CHANGE不得回业务；setterA期间UserB入队并最终仅执行一次；destroy/recreate强制fake handle table复用+实际OS若复用，两者分别标证据，旧WM_COMMAND(controlId/HWND)、旧cookie、旧captured envelope均拒绝；restore后的listener真实新generation，旧notification不通过，backend bind/restore失败冻结direct dispatch。
- [ ] **RED W input：** UTF16 emoji selection/caret、稳定key无关refresh、失焦/Tab与submit；synthetic composition顺序/duplicate result/取消/失败candidate/程序冲突/事件较新矩阵。synthetic发送WM_IME消息不创建真实HIMC，专门注入composition观测数据，只验state+API routing，不能写“中文输入已通过”。
- [ ] **Implement：** Native effect只在所属UI线程、有效binding且safe结算执行；普通ack读取Native同值短路，变化按UTF16 selection策略EM_SETSEL，不能无条件setText；显式reset的force=true效果按上述强制文本/尾选区规则执行，不能被同值短路吞掉。apply期间accepted模型尚未确认的conflict只pending；T1 accepted hook成功后记录冲突。同一editor的较新观测存在时apply与settle均不回写较旧候选；最后event/外部模型确认后统一同步。catchable wrapper错误只入队诊断、安全fault/close，不穿Subclass/Host ABI。
- [ ] **GREEN自动：** `W(test_win32_input)`与host/controls；L(edit/backend/commit/layout)。`win32_form_probe`以同一Nim model包含全部基础控件、reject/format/ack切换、unrelated label、focus/selection计数、模拟apply失败与恢复、busy close，Native UI操作不触Businessrender计数。
- [ ] **H gate（必须人操作/记录，不运行空泛“输入法正常”）：** 用户提供Windows10/11实际交互机，独立架构/用户测试员记录OS/Nim/IME版本及逐项日志：①Pinyin输入“中文”选择候选、编辑中无关label刷新、成功冲突/失败candidate、结束model回写，再组合中触发同值显式reset（候选窗/组合结束、模型文本与末尾选区正确、无假change）；②Japanese IME输入“日本語”转换/确认及显式reset同样矩阵；③Enter确认不submit、组合结束后Enter恰一次submit；④emoji选区/剪贴板/键盘Tab、checkbox/switch Space、disabled/focus；⑤跨100%与150%/200%实际显示器拖窗/字体变化，input HWND/create计数不变，无文字选区丢失；⑥Narrator/Accessibility Insights核对stock角色/name/value/enabled及keyboard focus。input现有typed hint/value映射cue/default原生语义，不假称已有任意公开aria DSL；若stock控件缺必要accessible name则作为H blocker报告最小label/provider方案选项，不暗加公共API。
- [ ] **Gate/commit：** 独立架构分别裁定L/W/H；缺中日文/不同DPI屏幕/accessibility任何证据记NotRun，不能A2全验。Native疑难给高消耗附消息trace/已试方法；`git commit -m "feat: preserve controlled Win32 editing and IME state"`。

### Task 6：显式native工具链/入口与整批验收

**Files:** targets/project/build/doctor/runner/leaf_cli、pack的拒绝guard；test_native_toolchain、package_project/pack_cli/sdk相关测试，tests/windows/test_win32_toolchain；examples config、validation文档；可选manual workflow。

**Consumes:** 当前Project严格字段/platforms配置、startBuild/build、sdkCompiler/sdkGcc、compileWindowsManifest；T5 runNative入口；现有pack(target=all三桌面目标)、GPUI默认和headless-only。

**Produces:**
- targets纯类型：`BackendChoice* = enum backendGpui, backendNative`；`BuildSelection*`含 `target:string; backend:BackendChoice; headlessOnly:bool`；`resolveBuild*(configured:BackendChoice,target="",backend="",headlessOnly=false):BuildSelection`，空target取host，backend只接受gpui/native，显式CLI>Project.backend>GPUI默认。
- Project.backend additive默认GPUI，leaf.json仅新增可选字符串backend；未知/duplicate CLI/非法backend仍拒绝，不加Android配置。`startBuild*(project:Project,output="",cacheDirectory="",isolatedConfig=false,selection:Option[BuildSelection]=none(BuildSelection)):BuildJob`、`build*(project:Project,output="",selection:Option[BuildSelection]=none(BuildSelection)):string`，原调用兼容；doctorReport可选selection同样保留零参数。
- CLI `leaf build PROJECT [--target windows] [--backend native|gpui] [--output EXE]`、`leaf run PROJECT [--target windows] [--backend native|gpui]`、`leaf doctor [--json] [--target windows] [--backend native|gpui]`；旧 `leaf PROJECT`、--headless/--check保留且已知headless选headlessOnly，不stage GPUI。native只Windows host x64、不隐式跨编译/下载工具；非Windows显式native窗口提前报缺环境，native --watch提前明确不支持本批，不落到GPUI。
- `-d:leafNativeWin32`的runner import仅win32入口；headlessOnly优先隔离两桌面分支，非Windows native符号明确编译拒绝；无符号仍旧desktop。native build不调用ensureGpui/stageGpui；MinGW与windres通过现有SDK/实际Nim脚本发现，复用同GCC/relocated sources manifest，不单独猜编译器。doctor native不loadGpui/探Cargo/Rust，列Nim版本、真实GCC/windres/target/native系统依赖与缺失；clang不当WinSDK。
- A2 **不实现native release**：pack解析可选backend并在Project或flag选native时早期明确“A3 native packaging not implemented”，不继续走旧GPUI staging；旧GPUI pack/all仍三桌面目标，Android仍拒绝。sdkCompiler/sdkGcc继续复用，现有SDK发布仍要求桥接的事实写清；不声称新的native-only SDK/release已经交付。

- [ ] **RED L：** resolver优先级/严格字段、不支持host/target/native watch/pack清晰失败；native/headless构建决策中GPUI操作计数0（测试纯计划+最小fake compiler/process，不能推导Windows编译通过）；旧GPUI默认仍调用原链；unknown field与paths/SDK overrides不放宽。`L(test_native_toolchain)`、`L(test_package_project)`、`L(test_pack_cli)`。
- [ ] **Implement：** 最小backend选择分支，配置/build/doctor/CLI使用同resolver，不复制不同平台表；headless不探图形库；pack仅前述明确拒绝，不实现A3发布。
- [ ] **GREEN L：** 同RED+`L(test_sdk)`、`L(test_windows_manifest)`、`L(test_windows_dpi)`及native_*；独立headless生成C/import/nm/ldd验证noGPUI/Vulkan/User32图形路径（Linux），旧GPUI tests照跑。主Agent当前baseline日志不代替变更后回归。
- [ ] **GREEN W真实工具链：** `W(test_win32_toolchain)`在中文/空格/$的移动source/SDK路径，用实际Nim+MinGW+windres编native表单；无Cargo/Rust可发现且移走GPUI DLL后build/run/--check/headless均有效；对生成C/import/modules、PE imports/delay-load与实际加载module名单检查无leaf_gpui/Vulkan/Rust依赖（允许系统User32/Gdi32/Comctl32/Imm32及真实C运行库）。用Native test读取EXE resource1 XML核实PMv2+common-controls，不拿DLL manifest替代EXE。旧GPUI工具链与pack regression保持。
- [ ] **可选W-only CI：** 新manual workflow在获授权后复用现有Windows编译链准备脚本、Nim2.2.6；调用scripts/test_win32、上传日志/PE分析，不依赖先下载GPUI SDK artifact、不改原Windows SDK DLL检查、不执行Cargo。本次不push/触发；windows-2022 API绿灯不填H。没有授权可只交本地W流程并把workflow标未执行。
- [ ] **最终独立gate：** 审完整BASE→HEAD diff/计划偏离/每task真实RED与GREEN；主Agent变更后跑 `NIM=/tmp/nim-2.2.6/bin/nim /tmp/nim-2.2.6/bin/nim c -r --out:target/nim/a2/test_runner scripts/test.nim`（缺旧外部fixture按实说明，不借native不需GPUI掩饰旧回归）；Windows运行 `& $env:NIM c -r --out:target/nim/a2/test_win32.exe scripts/test_win32.nim`，分别报告L/W/H结果与具体SKIP。普通问题交日常修复后复验，疑难才升级。
- [ ] **交付/commit：** selfreview所有Required映射、无默认切换、A3/B保留、无平台证据时明确Not Ready；`git commit -m "feat: select a Cargo-free Win32 native build path"`。文档仅按实际W/H填写，不提前称Native已支持；没有merge/push授权。

## 关键官方参考（规划检索，不是本机API测量）

Google官方grounding；直接fetch因fake-IP/SSRF拒绝，未改安全配置，不能伪称raw抓取成功：
- [EN_CHANGE](https://learn.microsoft.com/en-us/windows/win32/controls/en-change)：不通知备注仅ES_MULTILINE+WM_SETTEXT，不能泛化所有SetWindowText；单行setter必须窄来源抑制并W验证。
- [WM_IME_COMPOSITION](https://learn.microsoft.com/en-us/windows/win32/intl/wm-ime-composition)、[ImmGetCompositionStringW](https://learn.microsoft.com/en-us/windows/win32/api/imm/nf-imm-immgetcompositionstringw)：COMPSTR/RESULTSTR区分、Unicode API返回字节数/不含NUL/负数错误；默认EDIT处理必须保留，不重复插入result。
- [SetWindowSubclass](https://learn.microsoft.com/en-us/windows/win32/api/commctrl/nf-commctrl-setwindowsubclass)：不能跨线程；refdata不替应用管理生命周期；remove/NCDESTROY先解绑后清root。
- [WM_DPICHANGED](https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged)、[DPI_AWARENESS_CONTEXT](https://learn.microsoft.com/en-us/windows/win32/hidpi/dpi-awareness-context)：读取并应用suggestedRECT，重测重排；PMv2最低1703，不与GetDpiForWindow1607混同。
- [BCM_GETIDEALSIZE](https://learn.microsoft.com/en-us/windows/win32/controls/bcm-getidealsize)：pushbutton测量依赖当前font/common-controls v6，非push不能据此推导intrinsic；checkbox另测theme glyph/text。
- [ImmNotifyIME](https://learn.microsoft.com/en-us/windows/win32/api/imm/nf-imm-immnotifyime)：NI_COMPOSITIONSTR/CPS_CANCEL，dwValue未用传0，BOOL非零成功；这里只据Google官方grounding核实参数/返回，不采用搜索延伸的EDIT使用断言，更不把参数正确当实际取消已通过。
- [EM_SETSEL](https://learn.microsoft.com/en-us/windows/win32/controls/em-setsel)、[IMM概览](https://learn.microsoft.com/en-us/windows/win32/intl/about-input-method-manager)：选区UTF16、真实输入上下文与消息模拟分开验。不能用纯WM_IME序列宣布真实IME完成。

## 计划 self-review / 后续边界

- 已按主Agentreview补§7在newRuntime前capture+scope body-entry拒异线程（T3/T5），§8显式resetToken→ForceCancel一次消费且失败candidate不执行（T1/T5）；T4不再含私有test-only计数，采用生产只读诊断+真实系统调用装饰失败。原初稿commit保持可追踪，新增公开信号默认JSON/旧调用不变并有required能力拒绝。
- §4/5→T2/T3/T4、§6/7→T1/T3/T4、§8→T1/T5、§13→T6（仅选择/toolchain；native pack明确拒绝，release归A3）、§14/15→分层gate及最终验收。Required没有落入模糊“做一些测试”。
- Review Focus五项均有实际状态/计数/Windows消息测试；H动作、设备与owner明确，未提供设备不写假定已可运行。
- 类型沿当前A1：NodeKind.toggle、EventEnvelope.session、dispose/drain void、Backend五closures、host.scale、acceptedRevision/proposedRevision、owner-boundinstall confirm/abort；新hooks全optional，确认只metadata，普通prepare/materialize不误分类installation。
- 六task是独立可拒绝产物（协议编辑、布局、Host、实体测量、输入交互、工具链集成），不为每个小API单开task；只给接口/算法规则与测试断言，不预写整实现。
- 目前不选新依赖/C shim：最小C只ABI测试断言，不产品桥。若私有binding无法安全表达某ABI，停止该task，在planning/偏离报告列“修正Nim binding / 小C shim”及精确ABI与理由请审阅，不暗装第三方库。
- 公共accessible label/provider缺口若H证实阻塞，或native原生默认font/variant不可保持设计意图，应列必要选项交主Agent/用户；不得用自绘普通控件/默默装饰降级绕过required语义。
- A1三Minor与D1–D10仍可追踪：本批只处理消费必要协议/props回归；A3原生列表/导航/图表/数据库/release与B Android未删除，整体性能/长期内存及其他平台支持也未提前验收。

**Handoff：主Agent审读此唯一书面计划，向用户确认后按既定分工执行；现在停止，未开始编码。**
