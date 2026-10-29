# Canvas CPU 侧性能采集

这是独立、无 HUD 的 Windows producer，不是交互实验室的 view/HUD 循环。
正式27进程CPU侧基线已完成并独立验收，范围仅Windows软件渲染VM；结果见文末。
短跑、截图和本基线都不能证明硬件GPU时间、显示FPS或10k稳定60FPS。

## 入口

- `benchmarks/canvas_native.nim`：Windows / AMD64，Release、ORC、threads，显式 software。
- `scripts/canvas_performance.ps1`：有界启动独立进程，保存实际 PID、退出码、超时与输出 hash。
- `scripts/verify_canvas_performance.nim`：离线校验 raw JSON、CSV、退出和环境，生成汇总／比较。

producer 编译必须包含 `-d:release --mm:orc --threads:on -d:leafCanvasMeasure`
和 `-d:LeafCanvasSourceHash=<核实过的源码内容aggregate SHA256>`、
`-d:LeafCanvasToolchainHash=<toolchain.json原始UTF-8字节的SHA256>`，并链接项目现有
`src/leaf/resources/windows/leaf_app.manifest` 的 CommonControls v6 resource。
不能用缺 manifest 的临时链接命令；不会安装 SDK、改认证或 OS DPI。
源码清单格式为按路径排序的 `path + " " + lowercase_sha256 + "\n"`，再取整体 SHA256。
构建方必须逐项验证 frozen 清单／源码及归档 hash，保存 Nim、C compiler、参数和 EXE hash；
仅将任意 64 字符写入编译选项不构成源码验证。
`toolchain.json` 必须为UTF-8无BOM，schema1，保存 `nim_version`、`cc_version`、
`nim_binary_sha256`、`cc_binary_sha256`、`resource_manifest_sha256` 和 `flags` 字符串数组。
构建方实际核上述二进制与资源，并记录实际调用参数（source/out/cache路径可归一化；
sourceHash/toolchainHash参数不参与自引用hash）。producer嵌入同一文档hash，runner/离线校验
复核原始字节及编译身份。组内／基线比较不允许工具链hash变化，不能只匹配Nim版本。

准备好该 EXE 后，在非提权交互 Windows session 中运行（输出目录必须是新的）：

```powershell
.\scripts\canvas_performance.ps1 -Executable C:\build\canvas_native.exe `
  -SourceSha256 <同编译时的已核实aggregate> -ToolchainManifest C:\build\toolchain.json -OutputDirectory C:\measurements\canvas-run
```

默认采集 100／1,000／10,000 对象、三种负载，各 **3 个独立进程**；每进程
**5 秒预热＋30 秒采样**。完整 27 进程约需 16 分钟，另计启动／退出。
每进程默认 90 秒 watchdog；超时、非零退出或退出未确认使整个 index failed，保留失败材料。
不会自动重跑到绿。纯短跑可以显式缩短：

```powershell
.\scripts\canvas_performance.ps1 -Executable C:\build\canvas_native.exe `
  -SourceSha256 <hash> -ToolchainManifest C:\build\toolchain.json -OutputDirectory C:\measurements\canvas-smoke `
  -Repetitions 1 -WarmupMs 250 -SampleMs 1000
```

离线工具可在 Linux 运行；它不是 Win32 绘制／视觉证据：

```sh
nim c -d:release --path:src --out:/tmp/leaf-canvas-verify scripts/verify_canvas_performance.nim
/tmp/leaf-canvas-verify --index /path/run-index.json --require-formal --output /path/verified.json
# 只比较兼容的、完整的正式 index；允许 code/EXE hash 改变，不允许环境/参数偷偷改变。
/tmp/leaf-canvas-verify --index /new/run-index.json --baseline /old/run-index.json \
  --require-formal --output /path/comparison.json
```

## 冻结负载

`leaf-canvas-lab-v1`，seed `0x1EAFC0DE`，viewBox 960×540，实际 Canvas 物理
960×540（不符或运行中变化即拒绝）；opacity .85、sizeScale 1、无交互绑定。
按 circle／rectangle／triangle 循环：圆 `(N+2) div 3`、矩形 `(N+1) div 3`、
三角形 `N div 3`。每对象 group begin＋primitive＋end，共 **3N 命令**；每三角形
move＋两 line＋close，共 **4 floor(N/3) 路径段**。100／1000／10000 档分别
300／3000／30000 命令及 132／1332／13332 段。

|负载|dynamic ratio|热路径|
|---|---:|---|
|staticFrame|0|只重绘已接受的同一帧，不重建 view/frame/path，不进行 State 提交|
|properties|1|预分配 items 采样 transform/color，保留封存 path；重建命令帧并提交|
|geometry|1|采样尺寸并重建 triangle paths；重建命令帧并提交|

动态帧复用 owner State／现有 BackendSession FIFO 和唯一接受门；没有另一个提交注册表。
纯 Timeline 按单调绝对时间产生候选值，没有 onFinish/business callback。
循环运行在 ordinary message-loop turn，不在 WndProc、paint 或 accept 中采样业务。
Scene、帧及实际命令一致性有共享测试，但与交互实验室拥有相同命令不代表相同 producer 开销。

## 数值含义

- 名义请求周期 1000/60ms；超时请求合并，不追帧。`requests = frames + coalesced + cutoff_dropped`。
  最后采样边界尚未构建的请求单列，不伪装成合并后成功帧。
- `interval_ms` 是**实际 producer 操作开始间隔**，不是 GPU 时间或实际显示帧率。
  第一条使用真实最后预热操作的起点，包含测量边界／观察间隙。
- `timeline_ms`：纯 Timeline advance/sample；`scene_sample_ms`：属性采样或包含新路径的几何采样。
- `frame_build_validate_ms`：共用 builder 命令构建和 finish/seal 校验。
- `native_resource_ms`：原生准备分支（含 retirement/preflight、转换、创建 SDK 资源、scene ready）。
- `cpu_draw_submit_ms`：同步 nativeDraw／EndDraw 调用的 CPU 侧 wall elapsed，**非 GPU 执行时间**。
- `framework_commit_ms`：整个 State/Host 事务（static 为 repaint 调用）扣除上述原生资源和绘制分支的余项；
  不是纯校验时间。分段不重叠，但还存在计时／diagnostics／计数校验等余量。
- `total_ms`：上述 producer 操作总耗时。p50/p95/p99 使用 nearest-rank；超预算比按操作开始间隔
  与名义周期比较。三进程汇总是“三个 process p95 的中位数”，不是把所有帧合并后换权重。
- `successful_draws` 是 EndDraw 成功次数，可能包含额外 OS paint；与请求、build、采样帧分别记录。
  `gpu_ms` 和 `display_fps` 必须为 null，不以 CPU 样本补造。
- `record_ms` 观察预分配记录写入，clock pair 取 128 次最小值；它们不等于完整观察开销。
  native clock、环境检查和诊断读数未作 observer-subtracted 校正；报告是 instrumented Release。
  读对最小值可因时钟量化为0，不代表取时／完整观察无开销。

每帧不写磁盘、不刷新统计 UI；items/sample 缓冲预分配，sample 上限 20,000，JSON 读取／输出
上限 16MiB。时长、样本、计数、原始时间戳、分段数值、完整性和末尾覆盖缺口均校验。
关闭窗口／runtime 后先核原生计数回归，再输出 CSV 和完整 JSON；actual exit0 仍是额外必要条件。
JSON alone、一个 complete 字段或 controller 收集 exit0 都不能代替 producer 成功。

资源窗口记录 CPU counter、Nim heap／reserved heap、Windows RSS／peak RSS、GDI／USER 计数，
分别是 warmup 前、warmup 后、采样截止、清理后。GC 不在采样窗口内。Nim heap 不等于进程 RSS；
高水位或 allocator 留存不直接等于泄漏。三次 create/close 原生计数测试与独立进程资源窗口分别解释。

## 环境与证据范围

环境包含机器指纹、OS、CPU、GPU／driver、remote/VM、driver 报告刷新率，以及 DPI、实际像素尺寸、
显式 renderer、Nim 版本／Release／ORC 与内容／EXE hash。最小化、隐藏、viewport／DPI／远程状态变化
使当前样本无效；runner 采集前后环境应一致。这是已观察边界，不承诺发现所有瞬时外部环境变化。
`GetDeviceCaps(VREFRESH)` 是 driver 报告值，不是物理显示刷新测量。

目前只有 Windows VM 的 software 环境；没有硬件 GPU 时间／present 观测、物理显示 FPS、
150%／200%／mixed-DPI、设备丢失或 10,000 对象稳定 60FPS 证明。截图只验静态入口／布局。
本地历史 540 秒 timeout 那次仍未完成，不因本 producer 的局部通过而改称成功；后续最终交付 SHA `db34265` 的完整共享／Windows 官方入口已在 CI 成功，固定链接见[当前总览](../docs/progress.md#当前总览2026-10-29)。CI 不覆盖全部现场门。


## 2026-10-28 首份正式基线（已限定独立验收）

完整9场景×3独立进程，每进程5s预热＋30s采样，均exit0、无timeout，44,522次
操作／48,600请求（合并4,074、cutoff4）；`--require-formal` → `validated-baseline`。
独立复核615项断言、27份CSV逐字节重建、11个正／负控通过。没有第二个历史正式
基线，不能声称性能改善；自比较零变化仅是比较入口正控。

Win11 Enterprise Evaluation 10.0.26300，i5-13500H暴露4逻辑核，VirtIO GPU DOD
100.103.104.30200，非RDP，96DPI／960×540／software，Nim2.2.6、GCC11.1.0、
Release ORC。64Hz是driver报告值而非物理显示测量。

以下是**三个独立process p95的中位数**，单位ms，CPU侧每次操作wall时间：

|负载|100对象|1,000对象|10,000对象|
|---|---:|---:|---:|
|staticFrame|1.4223|2.5185|9.4485|
|properties|1.8951|4.3267|26.7422|
|geometry|1.8158|4.1722|28.1029|

10k动态已超16.667ms CPU侧预算；主要大项是draw submit、frame build/seal和native
resource准备。阶段p95不能相加或当同一帧的成本占比。低负载operation interval受
约15.625ms OS唤醒量化，p95约31ms，不能换算成显示FPS。`gpu_ms/display_fps`仍null。
静态负载`builds=0`但仍有成功EndDraw，表示重绘已接受帧，不是漏测绘制。

27个独立process的tracked native计数均回基线且HWND销毁；这不等于所有Win32
GDI/USER对象或Nim heap/RSS都归零。after-cleanup仍有共享缓存与producer数据，
不能据30s窗口宣称不存在长期泄漏。采集端是信任根，离线hash校验不证明恶意采集者诚实。

证据tag `canvas-performance-baseline-1028`，source collection609文件aggregate
`52c638bbd316fc6e555d1b75445c77dceb91ebec6f98ec7c02b0eb2f2d6905a6`，
EXE `35fe99d8185d5867385b1b9a54a690e156c02a80bf96203adc42ad71c408b847`，
toolchain `a93f336976bdf0b5101ee6277bf66dc49aabc351c1f728c3ea55f8b45bb5fb2c`。
原始index：`~/.local/share/leaf/windows-acceptance/shared/evidence/canvas-performance-baseline-1028/guest/canvas-performance-baseline-1028/reports/run-index.json`。
主证据索引：`~/.local/state/agent-artifacts/leaf/2026-10-26-graphics-api-design/implementation/canvas-input-next-integration.md`。
本说明是609归档之外的补充材料。未来source/EXE允许变化，但各自必须绑定，且工具链／
环境／负载／时长兼容；三重复观察不能直接确立通用1%或5%回归门限。


## 2026-10-29 两项优化后的正式测量（限定独立验收）

实现：有序有限值比较替代完整 FloatClass 分类（保留零／次正规语义）；Native 转换前显式
FLT_MAX 守卫修复有限 double 溢出；SDK immutable path 仅在单个 prepared scene 内按完整
段内容／count／fillRule 驻留，精确比较、8次探测上限与无共享fallback。paint／transform
仍逐命令，scene一次释放物理几何；配额保守计账，不设跨帧全局缓存或第二套事务。

同工具链／环境描述／负载／时长的第二份9×3正式采集：27 actual exit0，无超时，
46,779 samples／48,600 requests＝46,779＋1,820 coalesced＋1 cutoff；独立615项检查、
27份CSV字节重建通过，主控既有验证器 `--require-formal --baseline` 输出 `validated-baseline`。
下表为各组**三次独立process p95的中位数**（ms），并非池化帧：

|负载|对象|原基线|优化后|跨会话差值|
|---|---:|---:|---:|---:|
|staticFrame|100|1.4223|1.4986|+5.36%|
|staticFrame|1,000|2.5185|3.9946|+58.61%|
|staticFrame|10,000|9.4485|11.6699|+23.51%|
|properties|100|1.8951|2.0530|+8.33%|
|properties|1,000|4.3267|5.0236|+16.11%|
|properties|10,000|26.7422|22.4941|-15.89%|
|geometry|100|1.8158|1.9510|+7.45%|
|geometry|1,000|4.1722|4.3599|+4.50%|
|geometry|10,000|28.1029|19.9402|-29.05%|

另做同会话交替 A1,B1,B2,A2,A3,B3、各5s/30s的 properties-10000 对照：
旧process p95＝27.3397／28.9182／27.9546，新＝23.0509／19.9582／21.5598ms；
中位27.9546→21.5598ms，**本轮配对观察降低22.88%**。build/validate、native resource
阶段p95中位分别降低47.25%、47.99%；阶段百分位不可相加、也不是同一帧成本占比。
这比早先float-only约15%的中间对照更接近最终实现，但仍是有限VM/software观察，
三重复离散不是通用门限／显著性证明。低负载与staticFrame升高如实保留，未做配对，
并发宿主负载与SDK资源身份等因素未隔离，**不能证明回归，也不能排除代码影响**。
geometry-10000的−29.05%仅是跨会话观察，不冒称其另做了配对。

10k动态CPU p95仍为22.4941／19.9402ms，均超16.667ms；不宣称60FPS达标。
`gpu_ms/display_fps`仍null，不将CPU操作率或p95倒数称显示FPS。tracked Native计数
27进程均回零，但清理后GDI10/USER4及heap/RSS留存不抹除，也不证明长期无泄漏。
新旧同入口截图仅证明未见明显静态外观损坏，不证明动态连续性或任意transform精确相同。

本次独立功能：Linux43、默认无测量define的Canvas23、插桩1通过；非全仓重跑。
额外CI交付overlay只改 `scripts/test_win32.nim` 测试选择器并新增
`tests/nim/test_windows_suite_config.nim`，仅给插桩套加 `leafCanvasMeasure`；
行为RED→GREEN2、Windows compileOnly、独立2项与Native既有插桩1分开计。
overlay及本文档**不属于下面609测量快照**，不因此重收未变运行代码的样本。

正式tag `canvas-opt-baseline-1028`；paired tag `canvas-opt-paired-final-1028`。
609源码aggregate `b40bb8f93ffb01c884bdd0182098d0b379a7ceafc7ecdbd3e72b7524dd6a1599`；
EXE `04b390bfd0329d5a5c77c7ff6d46bd831129b4e88cefda6080353447c1da5f6a`；
toolchain仍 `a93f336976bdf0b5101ee6277bf66dc49aabc351c1f728c3ea55f8b45bb5fb2c`；
index `980d23fc4e89228f18b78677d0f6253c0bd0af8c95bbeba56b5df4fcf4802f6c`。
原始index同证据根下 `canvas-opt-baseline-1028/guest/canvas-opt-baseline-1028/reports/run-index.json`；
最终裁决 `implementation/canvas-opt-parent-evidence.json`，独立报告
`canvas-opt-independent-functional.md`／`canvas-opt-independent-visual-recovery1.md`。
硬件／高DPI／AT／视频与Task4/5整体仍开放；Git交付及本次SHA Actions结果另存统一证据索引。

交付CI另发现并修复旧快照JSON兼容：`MountedNode.toJson`仅三旧事件字段恒在，
`back/canvasInput`等可选字段有handler才输出；原旧快照断言不改。两路径修复经独立
31项／旧核行为RED及back兼容检查通过。这是额外交付修复，不是b40/04b测量源码；
producer无MountedNode/Snapshot JSON采样调用，绘制与事务代码未改，不重标或重收原27数据。

## 2026-10-29 定点复核：staticFrame-1000 同会话 A/B

仅针对此前跨会话 +58.61% 的 staticFrame-1000，复用上文已经绑定源码的旧／新 EXE，
不重新构建产品，不改负载、采集器、工具链或系统设置。Windows VM、非提权 Session 1、
96 DPI、software，顺序 A1→B1→B2→A2→A3→B3；每次独立进程、5s 预热＋30s 采样。

| CPU total process p95（ms） | 第1次 | 第2次 | 第3次 | 三 process 中位数 |
| --- | ---: | ---: | ---: | ---: |
| A：旧 EXE 35fe99d8… | 2.6168 | 2.5673 | 2.9264 | 2.6168 |
| B：新 EXE 04b390bf… | 2.5680 | 2.8119 | 2.4771 | 2.5680 |

六进程 actual exit0、无超时、PID 均不同，共 10,793 个样本；环境、工具链与时长一致。
逐份使用既有离线验证器复算 raw summary、CSV 字节、报告 hash、环境、退出及 tracked
native 清理，六份均 `validated-smoke`：这是因为每个 index 只有一个负载／一次独立运行，
**不是**重新取得九负载×三重复的完整正式基线，也未合并／改写原始 index 来伪造 formal。

新／旧中位数差 −1.86%，本轮没有复现该单负载此前跨会话的 +58.61%；三次观察的离散
不能支持显著改善、等价／无回归保证或宿主负载因果归属。原跨会话升高如实保留，
staticFrame-100／10000 和低计数动态场景尚未配对，不能外推。旧／新 EXE 是各自的归档
测量快照，不冒称重建了最终 db34265 SDK 或做了新 UI 验收。

另从既有优化后正式 properties／geometry-10000 的三进程原始样本计算：
**每进程将各 stage 累计时间除以该进程 total_ms 累计时间**，draw／EndDraw 约占
51.4–52.6%／49.0–49.2%，frame build/validate 约18.5–19.0%，native resource
约16.9–17.5%；并非相加 p95 或从其推出同一帧百分比。优先调查绘制提交与帧／资源准备，
不据此臆造 SDK／GPU 内部瓶颈，也不做未经 RED／回归的产品改动。

tag `quality-static-paired-1029`，原始六份 index／JSON／CSV 与 Session／工具能力检查：
`~/.local/share/leaf/windows-acceptance/shared/evidence/quality-static-paired-1029/`。
离线核验与阶段统计：主证据索引同目录下 `quality-1029/static-paired-summary.json`、
`quality-1029/existing-dynamic-attribution.json` 和 `quality-1029/verified-{A1,B1,B2,A2,A3,B3}.json`。
此处只增加诊断证据；60FPS、hardware／高 DPI／AT、资源预算和长期留存门仍开放。

## 2026-10-29 后续诊断：同色画刷状态去重候选已撤回

原绘制循环对每个 fill／stroke 都调用 `SetColor`。尝试仅在一次 draw 内对连续相同
RGBA 去重；不跨帧缓存、不改变换／裁剪或资源归属。独立测试程序包含真实 C bridge，
观察并转发真实 Direct2D 画刷调用，同步读取实际窗口像素（仅颜色数值回归，不是语义视觉验收）。
旧产品测试得到同色更新 3→预期1、fill／stroke 序列6→预期4 两项 RED，alpha 变化项通过；
候选三项均 GREEN，覆盖首次绘制／repaint／target rebuild 与资源计数恢复，既有 Canvas
23 项和 CPU 测量1项亦通过。测试进程均在非提权 Session1，未改变系统设置。

随后同 VM／96 DPI／software、相同工具链及负载，按 A1→B1→B2→A2→A3→B3，
每进程5s预热＋30s采样，定点测 properties-10000：

| CPU total process p95（ms） | 第1次 | 第2次 | 第3次 | 三 process 中位数 |
| --- | ---: | ---: | ---: | ---: |
| A：本次未优化基线 | 18.7118 | 22.7794 | 20.1362 | 20.1362 |
| B：draw-local RGBA 去重候选 | 19.4268 | 21.6692 | 19.9160 | 19.9160 |

六进程共9,353个样本，actual exit0／无超时、进程身份不重复、tracked native 均归零；
每份 index 经既有离线验证器重算 summary／CSV／hash／环境／清理，均 `validated-smoke`，
不是新的全矩阵正式基线。−1.09%仅为观察值，离散且方向不一致，**未建立可信的端到端收益**；
不据此声称统计显著、等价／无回归、宿主因果、GPU／显示 FPS 或 60FPS 达标。
为避免引入无已证收益的状态逻辑和测试维护负担，候选及夹具已归档后从工作树撤回，
产品／测试源码恢复 `db34265`，不再为此候选追加测量；这不等于证明所有画刷去重均无效。

源码快照A／B aggregate `82698bb7…`／`0d96cd72…`，仅 C bridge 不同；EXE
`2aeefcfd…`／`a33d7f15…`，工具链与上文相同。原始证据 tags：
`quality-brush-red3-1029`、`quality-brush-green-1029`、`quality-brush-paired2-1029`。
统一证据索引下 `quality-1029/brush-paired-summary.json`、`brush-candidate.patch`、
`brush-verified-{A1,B1,B2,A2,A3,B3}.json` 保存结果、可回放补丁和离线校验；
前置链接／打包／启动夹具失败亦保留，不计为产品 RED。该诊断结束时仅文档改动，未提交／推送；后续列表修复及代码提交状态见[当前进度](../docs/progress.md)。
