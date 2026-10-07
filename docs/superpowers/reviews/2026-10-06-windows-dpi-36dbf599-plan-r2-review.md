# Windows DPI 计划第 2 轮独立审查

本轮结论为 **pass（仅计划）**。已独立核对指定摘要、P1–P6、现有协议控制流、锁定 GPUI 的观察及测试接口、命令入口和权限边界。未发现必须修订的计划缺陷；上一轮 F3 在计划层面关闭。没有实施或运行新版业务代码，不能把本结论理解为 Windows DPI、兼容性回归或清晰度已通过。缺少必需原生证据时，最终验收仍必须 **blocked**。

审查任务 `36dbf599`，stage `plan`，round `2`；reviewer agent ID `0e485d12-ca8e-4c9c-89a9-1b22e03582cc`，来自实际读取的 `state.agents.plan_reviewer`，与 dispatch round=2 登记一致。coordinator 为 state 中的 `/root`。读取到用户批准 spec 及覆盖默认 DeepSeek 的 `codex/gpt-6.1-sol / auto-review / high` 配置记录；依直接任务授权审查，不创建代理。没有通过读取凭据验证模型，也未声称做过运行时 provider 检查。

指定 spec SHA-256 `86fb877f38bee050d16355122e30c474f9cb2e4041480957fe9187070f66ee74`、plan SHA-256 `beb0df449ff9ca1a6caddc118302d736a69d7e239212744e9b531d3bcbcf7f8e` 均由本轮 `sha256sum` 实际核对，保存报告前再次按原字节校验。state 摘要和本轮身份匹配。未发现摘要异常、技能缺失或权限拒绝。祖先路径与工作区 AGENTS.md 检查无匹配（rg exit=1，stderr为空），没有附加本地代理指令。

本轮使用的技能来源及实际读取证据：

| 技能 | 实际文件与工具证据 |
| --- | --- |
| requesting-code-review | `/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/requesting-code-review/SKILL.md`；functions.exec → tools.exec_command 的 cat，结果 chunk `a271ce`、exit=0；随后在 chunk `c52723` 的原始采集中再次 cat，并读取同目录 code-reviewer.md。 |
| verification-before-completion | `/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/verification-before-completion/SKILL.md`；同一 `a271ce` cat 实读、exit=0；`c52723` 再读并保存完整内容。 |
| using-superpowers | 首次 cat 实际读取，chunk `892fde`、exit=0；其 dispatched task 的 SUBAGENT-STOP 及用户本轮直接限制适用，未引入额外技能编排。 |

requesting-code-review 默认派生 reviewer 的步骤由用户本轮“禁止创建子代理/编排”和既定 Paseo 局部覆盖；本席已是全新独立审查者，直接独立核实。沿用模板的只读审查、按实际影响定级、列明不评价行为和 evidence-before-claims 要求；未创建 worktree、提交、实施或要求第二次人审。

F3 的核实依据及本轮修订效果：

1. **先查旧协议实际副作用。** `src/leaf/gpui_bridge.nim:89–101` 的 ready 只检查现有 error/viewportError 和写 watch receipt，不读取请求的其他字段；未知 op 会执行 `host.error=error.msg`。成功 list 仅清 viewportError（:79），status 不清 host.error（:86–88），成功 event 才清它（:47）。因此新 ready 附加 rendering 元数据可被旧 Nim 接受；任何未协商的 rendering 新 op 都可能造成持久错误，Rust 丢弃响应没有恢复作用。`desktop.rs:81–83,98–107` 与 `lists.rs:259–265` 证实后续 status/list 会再次吸收该错误。本轮没有假装执行过这个复现。
2. **协商使用现有可兼容的第一条 ready。** plan:89–91 在成功响应中增加可选 `capabilities.rendering_diagnostics`，严格 JSON true 且 Response.error 为空才支持。现有 `bridge.rs:11–23` 先复制/解析 Nim 响应，再验证 snapshot、反序列化 Response；计划抽取 request_value 保留该生命周期和验证，在 Value 被转换前读取能力即可。`model.rs:129–139` 的 Response 使用普通 serde Deserialize，无 deny_unknown_fields，旧 Rust 会忽略新增 capabilities；新增响应字段不需修改 model.rs。现有 `bridge.rs:29–31` ABI=1 保持不变。
3. **检查门槛对应真实发送位置。** 首帧 ready 当前位于 `desktop.rs:496–512`，并受视图/首屏列表失败检查保护；新的 bounds 订阅发生在 Desktop::new，可早于此处收到事件。plan:93 明确能力初值 false，只在首次成功 ready 明确支持后改 true；首帧前、旧响应缺字段、false/非bool、失败均禁止调用新 op，而不仅忽略其响应。plan:98 进一步禁止用忽略拒绝响应替代协商。没有额外探测 op，因此旧 Nim 不会在协商前走未知分支。新 Nim 的 rendering 分支要求只写诊断、不修改 snapshot/业务错误/receipt；协商后失败只留诊断错误、不送入 accept。执行阶段必须核实该隔离实际落实。
4. **回归可覆盖实际路径。** plan:96 要求保留旧 handler 的持久 error、ready 拒绝、status/list 不清 error、event 清 error 语义，经过实际 Desktop 订阅和 ready 握手触发首帧前/后及重复 bounds；断言未知 op 未发送、ready 一次、receipt 不重写、后续 status/list/event 正常。缺能力、false、非bool及 ready 失败逐项验证关闭状态，新配对验证比例/尺寸变化与去重，旧 DLL→新 Nim 用旧格式 ready 验证。不是仅解析字段的单测。现有 `ui_tests.rs:44–57` 已能建立真实 Desktop 测试实体；Cargo dev-dependency 已开启 test-support。锁定 TestAppContext :461–492 / VisualTestContext :972–983 公开 resize/scale 模拟，TestWindow :211–231 更新平台状态并调用真实 resize callback，最终经过 Window::bounds_changed 更新数据后通知订阅。测试能在指定 desktop.rs 内编写，不需扩大文件边界或改缓存。

保留前轮必要修订的独立核实：

- **Task0 / 原版基线。** plan:58–64 把 Task0 设为首次业务写入前置，Tasks1–4 依赖它；登记 HEAD、工作树原字节/缺失/未跟踪/dirty，遇到未提交源码覆盖归档内同范围文件，避免把 HEAD 冒充原源码。原版框架及 DLL 从冻结来源取得，与新版共用纯验收 app，不能只关闭新 setter 伪造旧版；原版实测已经144/1.5时停止该假设。当前 HEAD `2fb9501c6612819187689d72ccbcd4e525c65fde`，tracked diff为空，任务文档未跟踪。列明的 Git 路径存在；git archive 流式列目录 exit=0，未保存或实施基线归档。该特定源码基线是任务明确保留的范围，不构成整工作区归档授权。
- **bounds 取样 / F1。** 锁定 `Context::observe_window_bounds:402–417` 返回 Subscription 并可访问 Desktop/Window/Context；`Window::bounds_changed:2683–2693` 先更新 scale_factor 和 viewport_size，后通知观察者。平台 resize/move 已接入该函数（:1856–1870）。Windows `events.rs:887–888` 先更新比例，再经 SetWindowPos 或最大化的 handle_size_change 触发 resize；后者 :280–291 先更新逻辑尺寸。plan:93 保存订阅、首次ready样本作为基准、变化才发；plan:107 绑定同PID/HWND的原生probe和变化前后日志，无实际变化证据最终blocked。没有重新退回只取首帧数据。
- **按需 API / C1。** plan:71 只允许 initializeWindowsDpi 内显式 loadLib/symAddr，禁止模块级 user32 dynlib 或导入时初始化，:73 检查真实 import leaf/headless 的生成C与模块句柄。实际 Nim `dynlib.nim:186–193` 支持运行时显式加载；compiler `cgen.nim:844,908,1838–1841` 证明 dynlib pragma 可进入模块初始化，计划采取的限制对应真实问题。现有 gpui_api 也在 loadGpui 内显式加载。未运行 Windows 加载或新代码生成检查。

P1–P6 均在**计划覆盖/可执行性**层面通过，逐项证据见下方机器结论。接口和依赖有明确落点：Task1 定义 DPI 决策/返回状态并接入 runDesktop；Task2 依赖1，资源编译返回绝对 COFF 路径、复用已选GCC；Task3 依赖1，在允许的 bridge.rs/desktop.rs/gpui_bridge.nim 实现握手/观察/诊断；Task4 依赖1–3。Task0由coordinator前置完成，业务仍单executor。新模块/resources/tests、既有修改点、执行记录和证据目录均明确；test runner 自动发现 test_*.nim（scripts/test.nim:18–20），非test_前缀的app/probe避免无桌面启动。plan:115的P3简表未重列Task0，但完整任务明确依赖且实际验收引用Task0，不造成丢项。

spec:51–60 的流程图与计划一致：CLI manifest或直接编译→runDesktop检查/必要时设置→加载GPUI→窗口实测比例→按设备绘制一次。现有 desktop.nim:4–5 是loadGpui接入点，runner.nim:6在桌面前分流headless。不改布局字号/每页缩放，不强设线程上下文，不改C ABI，不把DLL ID=2替代主EXE ID=1。失败/宿主不同模式诊断、计算值明确标记、SDK源复制和共同CLI/watch/pack构建入口均有对应实现路径。

命令与权限：本机实际有 Nim2.2.6、cargo/rustc1.98.1、rustfmt1.9.0、clippy0.1.98、git/tar/python3。cargo metadata --no-deps --locked --offline exit=0，确认leaf-gpui工作区及rust-version1.92。只验证工具入口，未运行回归、fmt检查或clippy检查。Linux下windres/交叉windres/Wine查找无匹配（exit=1），Windows实际资源编译/链接和复杂路径仍待目标机现有工具验证。POSIX的/tmp命令是当前环境入口，Windows文档须提供目标机的本地现有路径；计划已有可操作原生入口要求。reviewer没有target业务写入权限，因此未运行会产生业务目录构建产物的完整测试。

未发生凭据读取、安装、外部Windows主机接入、全局显示设置改动、commit/push/merge/发布/部署/清理或代理编排。仅新增指定报告与 `/tmp/leaf-dpi-plan-r2-36dbf599-*` 原始审查日志。spec/plan/state和业务均未修改。计划通过后按任务授权自动进入执行，无二次人审；本reviewer结束后由coordinator处理Task0及执行/验证。

本阶段不评价的行为（Declined to judge）：

- 混合DPI多显示器：spec规定可选，用户为单屏，不升级为必需验收。
- 更换字体、抗锯齿及逐页缩放：spec排除，不扩展本轮修复范围。
- 新增非MinGW工具链支持：本轮不新增；已有不兼容配置需明确失败，已在计划中约束。
- 业务实现是否正确、Windows模糊已消除、完整回归已通过：没有新代码或原生运行证据，本计划审查不作此断言。

原始证据：`/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log` 保存命令、stdout、stderr及退出码，`/tmp/leaf-dpi-plan-r2-36dbf599-commands.json` 保存实际采集命令目录。functions.exec → exec_command 原始采集 chunk `c52723`，针对真实scale/resize测试路径的补充采集 chunk `87183a`。此前交互式读取提供定位，日志采集完整重读相应来源，未以截断输出代替完整证据。下方commands_run列出原始日志的实际采集命令；缺Windows不是当前计划fail或blocked的理由，但最终原生验收缺证据必须blocked。

```workflow-verdict
{
  "task_id": "36dbf599",
  "stage": "plan",
  "round": 2,
  "reviewer_agent_id": "0e485d12-ca8e-4c9c-89a9-1b22e03582cc",
  "spec_sha256": "86fb877f38bee050d16355122e30c474f9cb2e4041480957fe9187070f66ee74",
  "plan_sha256": "beb0df449ff9ca1a6caddc118302d736a69d7e239212744e9b531d3bcbcf7f8e",
  "verdict": "pass",
  "checks": [
    {
      "id": "P1",
      "result": "pass",
      "evidence": "仅计划覆盖/可执行性 pass：plan:78–85、105–106要求实际主EXE ID=1/RT_MANIFEST=24提取并解析XML、正确命名空间和PMv2、SDK搬迁及中文/空格/$路径、资源失败拒用旧对象。build.nim:24–54和CLI/watch/pack共享入口、package_sdk.nim:61的递归src复制支持该接入；未执行Windows构建。"
    },
    {
      "id": "P2",
      "result": "pass",
      "evidence": "仅计划覆盖/可执行性 pass：plan:68–74规定PMv2精确分类、保留宿主不同模式、失败立即记录错误并复查、unknown不盲设；initializeWindowsDpi内loadLib/symAddr、禁止导入时user32加载；desktop.nim:4–5和runner.nim:6提供GPUI前/仅桌面入口。原生子进程和真实leaf/headless生成C检查已列明，未执行。"
    },
    {
      "id": "P3",
      "result": "pass",
      "evidence": "仅计划覆盖/可执行性 pass：plan:58–64的Task0必须先于首次业务写入，保存HEAD/工作树原字节/dirty/缺失项和可重建源码，原新框架及DLL来源明确；plan:97、105–106区分实际GPUI测量、Win32独立DPI和计算设备尺寸，要求100/125/150%及同机原始截图。Git归档范围流式检查可行，基线保存及Windows对照尚未执行。"
    },
    {
      "id": "P4",
      "result": "pass",
      "evidence": "仅计划覆盖/可执行性 pass：plan:93、96–97保存bounds Subscription并从更新后的Window取样/去重；锁定Context::observe_window_bounds:402–417、Window::bounds_changed:2683–2693和Windows events.rs:878–947支持实际变化后路径。plan:107要求同PID/HWND的日志/probe、IME/选区/命中/resize/最大化/重绘；无变化后实测证据须最终blocked。"
    },
    {
      "id": "P5",
      "result": "pass",
      "evidence": "仅计划覆盖/可执行性 pass：plan:89–98通过首个兼容ready响应严格JSON true且无error协商，新Desktop默认false，首帧前/缺能力/false/非bool/失败禁发rendering；bridge.rs读取原Value而model.rs/C ABI不变。旧Nim忽略ready附加字段，旧Rust Response未deny未知字段。plan:96要求真实Desktop订阅/握手发送门槛及保留旧持久错误/status/list/event/watch receipt语义的混版本回归；现有test-support和simulate_scale_factor_change可触发实际bounds路径。F3在计划层面关闭，未运行新测试或声称实现通过。"
    },
    {
      "id": "P6",
      "result": "pass",
      "evidence": "仅计划覆盖/可执行性 pass：plan:105–111要求原生可操作app/probe、DPI/编译/重编译/宿主模式/兼容性覆盖文档及平台证据区分，plan:117明确缺P1–P4原生证据由verifier输出blocked。当前CLI诊断入口和Diagnostics JSONL存在；文档修改未实施。"
    }
  ],
  "failures": [],
  "commands_run": [
    {
      "id": "identity",
      "command": "sha256sum docs/superpowers/specs/2026-10-06-windows-dpi-36dbf599-design.md docs/superpowers/plans/2026-10-06-windows-dpi-36dbf599.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "state",
      "command": "cat docs/superpowers/plans/2026-10-06-windows-dpi-36dbf599-state.json",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "skills-discovery",
      "command": "rg --files /home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/requesting-code-review /home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/verification-before-completion",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "skills-read",
      "command": "cat /home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/requesting-code-review/SKILL.md /home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/verification-before-completion/SKILL.md /home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/requesting-code-review/code-reviewer.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "instructions",
      "command": "for p in /AGENTS.md /home/AGENTS.md /home/jimxl/AGENTS.md /home/jimxl/projects/AGENTS.md /home/jimxl/projects/leaf/AGENTS.md; do if test -f \"$p\"; then cat \"$p\"; fi; done; rg --files --hidden -g AGENTS.md -g '!target' -g '!.git' .",
      "exit_code": 1,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "spec",
      "command": "nl -ba docs/superpowers/specs/2026-10-06-windows-dpi-36dbf599-design.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "plan",
      "command": "nl -ba docs/superpowers/plans/2026-10-06-windows-dpi-36dbf599.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "prior-review",
      "command": "cat docs/superpowers/reviews/2026-10-06-windows-dpi-36dbf599-plan-r0-attempt1-review.md docs/superpowers/reviews/2026-10-06-windows-dpi-36dbf599-plan-r1-review.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "entry-build",
      "command": "nl -ba src/leaf/build.nim; nl -ba src/leaf/desktop.nim; nl -ba src/leaf/runner.nim; nl -ba src/leaf/windows_paths.nim; nl -ba src/leaf/process_io.nim | sed -n '1,70p'",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "protocol",
      "command": "nl -ba src/leaf/gpui_bridge.nim; nl -ba crates/leaf-gpui/src/bridge.rs; nl -ba crates/leaf-gpui/src/model.rs | sed -n '78,139p'; nl -ba crates/leaf-gpui/src/desktop.rs | sed -n '47,109p;492,518p'; nl -ba crates/leaf-gpui/src/lists.rs | sed -n '196,284p'",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "test-support",
      "command": "nl -ba crates/leaf-gpui/src/ui_tests.rs | sed -n '1,160p'; rg -n 'bounds_changed|set_scale_factor|set_content_size|simulate_resize|resize|TestWindow|platform_window' /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-0.3.7/src/platform/test/window.rs /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-0.3.7/src/app/test_context.rs",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "locked-bounds",
      "command": "nl -ba /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-0.3.7/src/app/context.rs | sed -n '401,417p'; nl -ba /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-0.3.7/src/window.rs | sed -n '1856,1871p;2678,2694p;2761,2764p;2922,2934p'; nl -ba /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-windows-0.3.7/src/events.rs | sed -n '249,293p;878,949p'",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "lazy-api",
      "command": "nl -ba src/leaf/gpui_api.nim; nl -ba /tmp/nim-2.2.6/lib/pure/dynlib.nim | sed -n '175,203p'; nl -ba /tmp/nim-2.2.6/compiler/cgen.nim | sed -n '823,848p;878,910p;1824,1848p'",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "test-sdk",
      "command": "nl -ba scripts/test.nim; nl -ba scripts/package_sdk.nim | sed -n '55,67p'; nl -ba tests/nim/test_bootstrap.nim; nl -ba tests/nim/test_gpui_bridge.nim; cat crates/leaf-gpui/Cargo.toml; nl -ba crates/leaf-gpui/build.rs; cat crates/leaf-gpui/resources/windows/leaf_gpui.manifest; nl -ba src/leaf/diagnostics.nim | sed -n '1,115p'",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "shared-build",
      "command": "rg -n 'startBuild|build\\(' src/leaf_cli.nim src/leaf/watch.nim src/leaf/pack.nim",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "baseline-scope",
      "command": "git rev-parse HEAD; git status --short; git diff --stat; git ls-tree --name-only HEAD src crates/leaf-gpui Cargo.toml Cargo.lock config.nims leaf.nimble LICENSE",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "archive-scope",
      "command": "git archive HEAD src/ crates/leaf-gpui/ Cargo.toml Cargo.lock config.nims leaf.nimble LICENSE | tar -tf -",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "tools",
      "command": "command -v git tar python3 cargo rustc; /tmp/nim-2.2.6/bin/nim --version; cargo --version; rustc --version; CARGO_HOME=/tmp/mui-cargo cargo fmt --version; CARGO_HOME=/tmp/mui-cargo cargo clippy --version",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "metadata",
      "command": "CARGO_HOME=/tmp/mui-cargo cargo metadata --no-deps --locked --offline --format-version 1",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "platform",
      "command": "uname -s",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "windows-tools",
      "command": "command -v windres x86_64-w64-mingw32-windres wine",
      "exit_code": 1,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "test-bounds-path",
      "command": "nl -ba /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-0.3.7/src/platform/test/window.rs | sed -n '211,233p'; nl -ba /tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-pre-0.3.7/src/app/test_context.rs | sed -n '458,495p;969,986p'",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    },
    {
      "id": "trace-api",
      "command": "nl -ba src/leaf/diagnostics.nim | sed -n '54,99p'; rg -n 'trace|log-file' src/leaf/developer_options.nim docs/development.md docs/verification.md",
      "exit_code": 0,
      "evidence_log": "/tmp/leaf-dpi-plan-r2-36dbf599-evidence.log"
    }
  ],
  "not_verified": [
    "本阶段仅计划审查：未实施业务代码，未执行新旧宿主混版本回归、完整Nim/Rust测试、fmt --check或clippy检查；发送门槛为经现有源码核实可实现的计划约束，尚无新实现运行证明。",
    "Task0 identity/source.tar/原EXE/DLL保存和Windows重建尚未执行；本轮只读Git范围及流式归档目录，不保存归档。",
    "Windows真实API/按需user32加载/headless/PE资源/链接/SDK搬迁/复杂路径构建。",
    "Windows100/125/150%真实窗口比例、同机修复前后原图及P4交互/同窗口运行中缩放变化；缺P1–P4必需原生证据，最终验收必须blocked，当前计划pass不能替代。",
    "状态文件记录指定模型/配置及授权；本轮没有运行provider introspection或另行创建/配置代理。"
  ]
}
```
