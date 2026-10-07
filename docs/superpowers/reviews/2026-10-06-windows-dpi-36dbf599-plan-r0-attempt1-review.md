# Windows DPI 计划独立审查（round 0 / attempt 1）

裁决：**fail**。两项计划缺陷涉及必需验收证据的获取顺序和取样入口，修订后应重新审查。本裁决评估计划覆盖性与可执行性，不表示任何实施代码、构建、测试或 Windows 行为已经验证。当前 Linux 缺少 Windows 桌面不单独使计划失败。

任务 `36dbf599`；审查者 ID `f845fb6d-43ed-4ace-85d3-66f61d02e2eb`，实际读取自 state.agents.plan_reviewer。state.stage 为 plan_review。spec 与 plan 的 SHA-256 均与委派及 state 一致：

- spec：`86fb877f38bee050d16355122e30c474f9cb2e4041480957fe9187070f66ee74`
- plan：`d111feb1ab46cc589160046a7805c102398467ff415c4741b19e37ce489b5c5c`
- 只读检查时 state：`f184eaea795343da31ebd1afcd21d8549ac7fdb499b141d80a10b6572b0e1a47`
- 当前 Git HEAD：`2fb9501c6612819187689d72ccbcd4e525c65fde`；这是本次观察值，计划本身尚未绑定它作为运行基线。

用户授权 GPT‑6.1‑Sol 审核及开发，state.model_override 与委派一致，覆盖 spec 中原先的 DeepSeek executor 默认。spec 顶部“等待批准”属冻结设计时的状态文字；真实用户批准和 state.design_approval 已绑定该摘要，不构成摘要或授权异常。设计已人审，计划 AI 审通过后自动执行，无第二次人工审批。

**技能与读取证据。** 实际通过 functions.exec → tools.exec_command 读取以下技能及审查模板；原始工具结果 `06142c`（两份 SKILL.md）、`6c573f`（发现和模板），审查者 ID 如上。另用 `rg --files` 实际发现，复读结果保存在原始日志的 skills-discovery、skills-read、review-template 条目。

- `requesting-code-review`：`/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/requesting-code-review/SKILL.md`；采用按要求评估、问题定位、严重度校准和明确裁决。
- `verification-before-completion`：`/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/verification-before-completion/SKILL.md`；采用“NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE”。
- 模板：同 requesting-code-review 目录的 `code-reviewer.md`，包括“Do all of this review yourself. Never spawn a subagent”。

技能默认调度、worktree 或提交步骤由本任务明确禁止项覆盖。未创建子代理、未编排、未修改业务/spec/plan/state；未提交、push、merge、发布、部署、安装依赖、清理或接入外部 Windows 主机。本次只新增报告和 `/tmp/leaf-dpi-plan-36dbf599-review-evidence.log`。未发现适用的祖先或项目 AGENTS.md。

**已覆盖的设计边界。** 主 EXE ID=1 DPI manifest 与现有 DLL ID=2 Common Controls 资源分离；资源置于 src 随 SDK 递归复制；启动时机置于 runDesktop 第一个桌面操作、早于 loadGpui。决策接口先识别 PMv2，再分类 per-monitor/system，不强改线程；setter 失败保存错误并复查，不将访问拒绝直接当作成功。ready 的 Rust 方法签名可变而导出的 C ABI 保持 1；旧 Nim ready 忽略新增可选字段，旧 DLL 消息仍能被新版 Nim 接收。计划还保留首屏失败与 watch receipt 语义，并明确计算尺寸与推导 DPI 的命名。这些都是计划/现有接口审查结论。

文件地图与设计允许范围一致，Tasks 1→2、1→3、1–3→4 的业务依赖成立。新增测试由 scripts/test.nim 自动发现；app/probe 不用 test_* 名称，避免自动启动真实窗口。流程图的“EXE manifest / 直接编译 → 上下文检查 → 必要初始化 → GPUI → 实测比例 → 绘制”被 Task 1–3 覆盖，没有新增布局倍率或第二次字号缩放。

**Important / F1：缺少运行中 DPI 变化后的 GPUI 比例取样。**

定位：spec 第69行；plan 第80–84、91、93行。Task 3 仅在首帧 ready 发送 scale/viewport；外部 probe 读的是 HWND 的 GetDpiForWindow。Task 4 要求变化后检查重绘和命中，却没有取得变化后 GPUI scale 的方法。启动时 1.5 的记录不能证明同一窗口在随后 125%/100% 下使用正确比例。

原始源码证据：desktop.rs 第496行注册 window.on_next_frame，第510行调用 bridge.ready；锁定 gpui-pre-0.3.7 的 window.rs 第2602行签名为 `callback: impl FnOnce(&mut Window, &mut App)`。上游 events.rs 第887–888行处理新比例，说明后端已有变化处理，但上游存在处理不能替代实际应用变化后的验收数据。此处不是认定上游有 bug，而是计划无法采集 P4 所需证据。

最小修订：在已有文件范围内明确变化后的 rendering 取样入口，例如比例/viewport 变化时通过诊断请求发送当前 Window 的数据；或明确验收可触发的取样操作。不要为取样重复 ready 并重写 watch receipt。验收记录须绑定同一 PID/窗口及变化前后的 Win32 DPI、GPUI 比例和交互结果。无法触发变化或取得当前比例时标记未验证，最终验收 blocked。

**Important / F2：修复前基线没有前置保留步骤。**

定位：spec 第23、68行；plan 第89、92行。Task 4 依赖完成所有业务修改后，才要求保存改前/改后原图并检查“修复前读取值已正确则停止”条件。计划没有明确在修改前冻结原始源码/EXE/DLL 的版本及保留或重建办法。只保存修复后的产物不足以完成同机根因验证与对照；未来仍有 Git 历史不等于计划已经绑定可复现的基线。

最小修订：首次业务写入前记录原始源码版本和哈希，并明确保留或从该版本重建原 EXE/DLL。有已授权 Windows 桌面时先获取原始上下文、实际 DPI、GPUI 比例及原图，再继续修复；当前 Linux 可执行实现，但应保留可复现的原始来源，并将真实前后对照维持为必需未验证项。不要仅关闭 DPI setter 却使用其余新实现，冒充完整修复前版本。无须新增提交、worktree 或擅自连接 Windows 主机。

**提醒 C1（不单独阻止本轮，执行审查须落实）：Nim dynlib pragma 不等于按需加载。**

plan 第30行要求 headless 不加载 user32，第62行又仅称“现有 Win32 动态链接方式”。现有 windows_process.nim 使用 `{.dynlib: "kernel32".}` 风格；Nim 2.2.6 compiler/cgen.nim 第844、908行把该风格的加载/符号绑定写入 cfsDynLibInit，第1838–1841行并入模块数据初始化。若照搬到 user32，即使 setter 只在 runDesktop 调用，user32 仍可能在程序初始化阶段加载。这里尚无实现，所以不宣称 headless 已经回归。

应明确在 initializeWindowsDpi 内按需获取库和符号（可参考 gpui_api.nim 的显式加载与函数指针方式），缺失查询/setter 时返回可诊断状态，避免在 NimMain 初始化阶段抛出加载异常。Windows headless 测试应区分“未加载/未调用新增 DPI 后端”与“有效上下文未变”；Linux 生成代码检查也应覆盖真实 leaf/headless 入口，而不仅是 DPI probe。现有注入决策测试本身不能证明 DLL 加载时机。

**工具、路径与权限复核。**

本机 Nim 2.2.6、Cargo/rustc 1.98.1、rustfmt 1.9.0、clippy 0.1.98 可用；`CARGO_HOME=/tmp/mui-cargo cargo metadata --no-deps --locked --offline --format-version 1` exit=0，工作区和依赖声明匹配。这里只核实命令/工程解析，不等同 cargo test/fmt --check/clippy 检查通过。计划所用 /tmp Nim 路径在本 Linux 工作区存在，真实 Windows 的操作入口需使用当地已有 Nim/MinGW 路径，不应直接复制 POSIX 环境赋值语法。

`uname -s` 输出 Linux；`command -v windres x86_64-w64-mingw32-windres wine` exit=1、无输出。这是当前 PATH 工具缺口，不表示已授权 Windows 环境也缺工具；没有安装或尝试以 Wine 替代原生验收。

MinGW 计划覆盖 windres 来源、与已选 GCC 一致、COFF 链接、rc 引用转义、compilerPath、Nim 的 `$` 转义和实际中文/空格/$ 路径构建。startManaged 确实以 argv 启动进程；compilerPath 的中文短路径转换可能失败而返回原路径，不能只凭调用它宣称支持中文路径。执行/原生验证还须检查 windres 内部预处理器和 Nim→GCC 的二次参数解析，并读取最终 PE 资源；源码 GCC 的配置来源不明时应明确失败，不能静默选另一套工具链。这些已有实际 Windows 测试要求可覆盖，故 P1 的计划覆盖通过，实际行为仍未验证。

Linux 全量回归会产生 target 编译产物，超出本 reviewer 只写报告/临时日志的权限，因此未执行；该限制没有妨碍计划源审查。现有测试中的临时 fixture 清理属于测试生命周期，不是授权清理工作区。执行时仍须遵守业务文件白名单及无安装/外部主机操作限制。

**P1–P6（仅计划覆盖及可执行性）。**

| ID | 结果 | 结论 |
| --- | --- | --- |
| P1 | pass | 实际 PE/XML、SDK 搬迁和复杂路径构建及失败检测已列入；Windows 未实测。 |
| P2 | pass | 初始化时机、既有模式、失败复查及 headless 决策测试已列入；见 C1 加载风险。 |
| P3 | fail | F2 缺少业务修改前的原始基线绑定/保留步骤。 |
| P4 | fail | F1 缺少同一窗口缩放变化后的当前 GPUI 比例取样入口。 |
| P5 | pass | Nim/Rust、ready、ABI、首屏失败、headless/Linux 回归已列入；未运行回归。 |
| P6 | pass | 文档范围与未验证状态规则已列入。 |

计划第21、97、103行正确保留原生证据缺失后的 blocked，未将模拟/源码检查当作 Windows pass。后续只有完成必需真实证据才可声明消除模糊。本轮 fail 的分类为 plan；不是设计重审、环境故障或权限请求。

**暂不评价的范围（Declined to judge）。**

- 混合 DPI 多显示器：spec 明确为可选，本用户使用单屏，不升级为必需验收。
- 字体替换、抗锯齿策略与逐页像素调整：spec 明确排除，当前根因验证未完成。
- 非 MinGW 新工具链支持：plan 明确不新增，已有用户配置仍须得到明确失败诊断。
- 任何“代码已正确/Windows 已清晰”的判断：属于实施与最终验证阶段，本阶段没有对应证据。

**原始证据。** `/tmp/leaf-dpi-plan-36dbf599-review-evidence.log` 保存完整技能正文、spec/plan 带行号内容、涉及启动/ready/工具链/测试/锁定上游的源码片段、实际命令和退出码。证据采集工具结果为 `64c459`；关键输出复读工具结果为 `df5f4a`。commands_run 对应这份裁决证据日志中实际重跑的检查命令。此前的 rg/nl/cat/git 只读浏览还见工具结果 `7101d8`、`b51b60`、`171dbb`、`722c67`、`65aa6f`、`ba525d`、`818a1c`、`e02188`、`0cee54`、`550e49`、`ab7cc9`、`46e2d3`、`8cf4d2`；其中一次尝试读取不存在的 tests/nim/test_windows_paths.nim 返回文件不存在，未用该文件作为证据。未运行计划中的业务测试或 Windows 命令。

```workflow-verdict
{
  "task_id": "36dbf599",
  "stage": "plan",
  "round": 0,
  "reviewer_agent_id": "f845fb6d-43ed-4ace-85d3-66f61d02e2eb",
  "spec_sha256": "86fb877f38bee050d16355122e30c474f9cb2e4041480957fe9187070f66ee74",
  "plan_sha256": "d111feb1ab46cc589160046a7805c102398467ff415c4741b19e37ce489b5c5c",
  "verdict": "fail",
  "checks": [
    {
      "id": "P1",
      "result": "pass",
      "evidence": "计划覆盖性通过：Task 2 第69–76行明确主 EXE ID=1/RT_MANIFEST=24、实际 PE 提取/XML 解析、SDK 搬迁、中文/空格/$ 路径、资源失败及旧输出拒用。src/leaf/build.nim:24–54 为共享构建入口；scripts/package_sdk.nim:61 递归携带 src。未验证 Windows 资源编译/链接/运行。"
    },
    {
      "id": "P2",
      "result": "pass",
      "evidence": "计划覆盖性通过：Task 1 第59–65行定义可注入查询/设置接口，在 runDesktop/loadGpui 前初始化，PMv2 精确比较、宿主其他模式保留、error=5 后复查、unknown 不盲设、独立子进程与 headless 上下文测试；未验证真实 Win32 调用。见提醒 C1：必须区分懒加载与 Nim dynlib pragma。"
    },
    {
      "id": "P3",
      "result": "fail",
      "evidence": "F2：spec:23、68 要求修复前根因检查及同机原图对照；plan:89–92 把改前证据放在依赖 Tasks 1–3 的 Task 4，未绑定/保存修复前源码及 EXE/DLL 基线。真实 DPI=144 与 scale=1.5 的双来源、100%/125%及截图要求其余已列入，尚无真实运行证据。"
    },
    {
      "id": "P4",
      "result": "fail",
      "evidence": "F1：spec:69 要求缩放变化后的 GPUI 比例正确；plan:80–84 只在首帧 ready 读取 scale，plan:91 外部 probe 只读 HWND DPI，plan:93 无再次读取当前 GPUI 比例的入口。desktop.rs:496–516 与锁定 Window::on_next_frame:2602 的 FnOnce 证明首帧路径不会自动产生变化后的比例证据。"
    },
    {
      "id": "P5",
      "result": "pass",
      "evidence": "计划覆盖性通过：Tasks 1/3/4 有 Nim/Rust 回归、旧 ready/新可选字段、ABI=1、首屏失败不发布 ready、headless 与 Linux 分支要求；scripts/test.nim:18–20 确认自动发现新测试；本机 Nim/Cargo/rustfmt/clippy 可用。只检查工具和源边界，没有运行回归。C1 懒加载风险需在执行时明确落实。"
    },
    {
      "id": "P6",
      "result": "pass",
      "evidence": "计划覆盖性通过：Task 4:94、97 和交接:103 要求开发/验证文档说明直接编译与 CLI、重新编译、兼容性覆盖、逻辑/设备像素、平台和未验证项；缺 P1–P4 原生证据时 verifier 必须 blocked。未验证文档实施结果。"
    }
  ],
  "failures": [
    {
      "id": "F1",
      "classification": "plan",
      "evidence": "spec:69；plan:80–84、91、93；crates/leaf-gpui/src/desktop.rs:496–516；锁定 gpui-pre-0.3.7/src/window.rs:2602 的 on_next_frame 接受 FnOnce。首帧 ready 的 scale 元数据不能证明同一窗口经历 DPI 变化后的 GPUI scale。",
      "minimal_fix": "在已有 bridge.rs/desktop.rs/gpui_bridge.nim 范围内明确缩放/viewport 变化时或验收主动取样时的 rendering 诊断入口，读取当前 Window，避免重复 ready/watch receipt。Task 4 同窗口记录变化前后 Win32 DPI、GPUI scale、重绘/命中证据；无法触发或取样时该项 not_verified，最终 blocked。"
    },
    {
      "id": "F2",
      "classification": "plan",
      "evidence": "spec:23、68；plan:89 明确 Task 4 依赖 Tasks 1–3，而 plan:92 才首次提出保存改前/改后原图与根因停止条件。计划没有执行前基线绑定、产物保留或可重建来源步骤。",
      "minimal_fix": "在首次业务写入前绑定原始源码版本和哈希，说明如何保留或从该版本重建原始 EXE/DLL。有已授权 Windows 桌面时先采集原始 awareness/DPI/scale/原图，再执行修复；Linux 可继续实施，但保留可复现的基线来源，将同机前后对照留为必需未验证项。用原始版本运行同一验收内容，不得只关闭 DPI 初始化却把其余新代码称为完整修复前版本。"
    }
  ],
  "commands_run": [
    {
      "id": "identity",
      "command": "sha256sum docs/superpowers/specs/2026-10-06-windows-dpi-36dbf599-design.md docs/superpowers/plans/2026-10-06-windows-dpi-36dbf599.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "reviewer",
      "command": "python3 -c 'import json; s=json.load(open(\"docs/superpowers/plans/2026-10-06-windows-dpi-36dbf599-state.json\")); print(json.dumps({\"reviewer_agent_id\":s[\"agents\"][\"plan_reviewer\"],\"stage\":s[\"stage\"],\"model_override\":s[\"model_override\"]},ensure_ascii=False,indent=2))'",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "skills-discovery",
      "command": "rg --files /home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/requesting-code-review /home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/verification-before-completion",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "skills-read",
      "command": "cat /home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/requesting-code-review/SKILL.md /home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/verification-before-completion/SKILL.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "review-template",
      "command": "cat /home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/requesting-code-review/code-reviewer.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "spec",
      "command": "nl -ba docs/superpowers/specs/2026-10-06-windows-dpi-36dbf599-design.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "plan",
      "command": "nl -ba docs/superpowers/plans/2026-10-06-windows-dpi-36dbf599.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "entry-and-build",
      "command": "nl -ba src/leaf/build.nim; nl -ba src/leaf/desktop.nim; nl -ba src/leaf/runner.nim; nl -ba src/leaf/windows_paths.nim",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "ready",
      "command": "nl -ba crates/leaf-gpui/src/desktop.rs | sed -n '492,518p'; nl -ba crates/leaf-gpui/src/bridge.rs | head -32; nl -ba src/leaf/gpui_bridge.nim | sed -n '86,101p'",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "locked-api",
      "command": "rg -n 'fn scale_factor|fn viewport_size|fn on_next_frame|WM_DPICHANGED|GetDpiForWindow' /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-0.3.7/src/window.rs /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-windows-0.3.7/src/window.rs /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-windows-0.3.7/src/events.rs",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "one-shot-callback",
      "command": "nl -ba /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-0.3.7/src/window.rs | sed -n '2600,2608p'",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "nim-dynlib",
      "command": "nl -ba /tmp/nim-2.2.6/compiler/cgen.nim | sed -n '823,848p'; nl -ba /tmp/nim-2.2.6/compiler/cgen.nim | sed -n '878,910p'; nl -ba /tmp/nim-2.2.6/compiler/cgen.nim | sed -n '1824,1848p'",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "regression-and-sdk",
      "command": "nl -ba scripts/test.nim; nl -ba tests/nim/test_bootstrap.nim; nl -ba tests/nim/test_gpui_bridge.nim | sed -n '26,48p'; nl -ba scripts/package_sdk.nim | sed -n '55,65p'; nl -ba crates/leaf-gpui/build.rs",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "nim-version",
      "command": "/tmp/nim-2.2.6/bin/nim --version",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "cargo-version",
      "command": "cargo --version",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "rust-version",
      "command": "rustc --version",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "fmt-version",
      "command": "CARGO_HOME=/tmp/mui-cargo cargo fmt --version",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "clippy-version",
      "command": "CARGO_HOME=/tmp/mui-cargo cargo clippy --version",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "metadata",
      "command": "CARGO_HOME=/tmp/mui-cargo cargo metadata --no-deps --locked --offline --format-version 1",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "platform",
      "command": "uname -s",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "windows-tools",
      "command": "command -v windres x86_64-w64-mingw32-windres wine",
      "exit_code": 1,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "baseline-head",
      "command": "git rev-parse HEAD",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "status",
      "command": "git status --short",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    },
    {
      "id": "tracked-diff",
      "command": "git diff --stat",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-36dbf599-review-evidence.log"
    }
  ],
  "not_verified": [
    "所有实施代码与完整 Nim/Rust 回归：本阶段仅审查计划，且 reviewer 未获业务/target 写权限。",
    "Windows 原生 API、PE 资源、MinGW 资源编译与链接、SDK 搬迁及中文/空格/$ 路径实际构建。",
    "Windows 100%/125%/150% 实际窗口 DPI/GPUI scale、同机原图对比、IME、选区、命中、resize/最大化与运行中缩放变化。"
  ]
}
```
