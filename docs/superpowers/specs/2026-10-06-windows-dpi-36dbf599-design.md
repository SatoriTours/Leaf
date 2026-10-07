# Windows 高 DPI 清晰度修复设计 v1

任务：36dbf599。工作区：`/home/jimxl/projects/leaf`。状态：等待用户批准；尚未实施或编写实施计划。

## 目标与已知环境

用户希望优化 Leaf 应用界面的模糊，提供 DreamTools Desktop 截图，并确认 Windows 单显示器、150% 缩放。目标是在系统缩放下按实际设备分辨率绘制文字和控件，保持逻辑尺寸、输入命中和中文输入正确。

本次只修复 Leaf 的 Windows DPI 接入。DreamTools 项目不在写入范围。无新增页面或交互布局，因此不需要 UI 原型。设计采用现有启动流程的有限修改；按当前会话的 Paseo 协作规则保留书面 spec 和之后的独立计划审查。

## 事实、假设与证据

- `Cargo.lock` 锁定 GPUI Kit 0.7.0、gpui-pre / gpui-pre-windows 0.3.7。
- `src/leaf/build.nim:startBuild` 编译 Nim 主 EXE，目前没有注入 DPI manifest。
- `src/leaf/desktop.nim:runDesktop` 加载 DLL 后启动 GPUI，目前没有设置 DPI awareness。
- `crates/leaf-gpui/build.rs` 向 DLL 嵌入 ID=2 manifest；该 manifest 仅声明 Common Controls v6，没有 DPI 设置。
- 锁定上游源位于 `/tmp/mui-cargo/registry/src/index.crates.io-1949cf8c6b5b557f/`。`gpui-pre-windows-0.3.7/src/window.rs:126` 用 `GetDpiForWindow(hwnd) / 96` 初始化比例；`src/direct_write.rs:685` 用比例栅格化字形；`src/events.rs:878` 已处理 `WM_DPICHANGED`。该 Windows 后端没有设置进程或线程 DPI awareness 的 API 调用。
- 上游 `gpui-pre-0.3.7/resources/windows/gpui.manifest.xml` 有 PerMonitorV2 声明，资源 ID 为 1。上游 Rust EXE 的构建资源不能替代独立 Nim 主 EXE 的声明。
- Microsoft 明确规定 DPI-unaware 窗口的 `GetDpiForWindow` 返回 96；推荐在应用 manifest 声明 DPI awareness，API 初始化必须早于任何 HWND 创建。

**最可能的原因**：Nim EXE 未启用 DPI 感知，GPUI 按 1.0 渲染，Windows 把客户区位图放大到 1.5，造成整体模糊。截图客户区比标题栏软，支持该解释，但当前 Linux 工作区没有取得截图应用的实际 awareness 和窗口 DPI，因此不是已完成的运行时根因证明。

替代解释包括 Windows 兼容性缩放覆盖、截图或远程显示的二次缩放、文字抗锯齿和字体回退。如果实际窗口 DPI 已为 144、GPUI 比例已为 1.5，应停止沿本假设继续修复并重新调查。

查询日期：2026-10-06 UTC。参考：

- [Microsoft：进程默认 DPI 感知](https://learn.microsoft.com/en-us/windows/win32/hidpi/setting-the-default-dpi-awareness-for-a-process)
- [Microsoft：GetDpiForWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdpiforwindow)
- [Microsoft：高 DPI 桌面应用](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows)

## 方案选择

1. **推荐：主 EXE manifest + 桌面启动兜底。** Leaf CLI 构建的 Windows EXE 嵌入资源 ID=1 的 PerMonitorV2 声明；直接 `nim c` 的应用在进入 GPUI 前尝试初始化同一模式。覆盖 CLI、SDK 和直接编译，且可检查实际效果。
2. 只做运行时初始化：改动更少，适合验证假设，但其他依赖提前创建 HWND 时可能错过初始化时机。
3. 只做 manifest：最符合系统推荐，但遗漏直接 Nim 编译路径。

调整字号、整体乘 1.5 或更换抗锯齿不能解决缺失的 DPI 接入。字体和像素对齐作为根因验证后的独立问题处理，不包含在本次实施范围。

## 行为与边界

Windows 构建资源放在 `src/leaf/` 下，随现有 SDK 源码复制规则携带。资源声明仅包含 DPI 设置和已有 Common Controls v6 依赖；不引入权限、认证、执行级别或其他无关系统设置。复用现有 Windows 工具链生成并嵌入主 EXE 资源，不安装依赖。CLI run、watch 和 pack 共用构建入口。

直接编译应用的兜底在 `runDesktop` 内、加载 GPUI 和任何 GPUI 平台初始化之前执行；导入库和 headless 不改变进程 DPI。已是 PerMonitorV2 时无需重复设置；API 失败必须检查有效上下文，不能把“访问拒绝”直接视为成功。宿主已指定不同模式时保持其上下文，输出明确诊断，不偷偷强改线程模式。不在窗口创建后设置 process awareness。

保留现有 C ABI。复用 ready 回调和现有诊断通道传递有限元数据：有效 DPI awareness、GPUI scale factor、逻辑客户区尺寸和其换算的设备尺寸。只有能够实际读取的值才标为实测；换算值明确标为计算值，不冒充交换链实测值。不记录输入内容或凭据。

尺寸和字号继续使用 GPUI 逻辑像素；设备缩放由 GPUI 完成一次。沿用上游 DPI 变化处理，不新增每页缩放或重复乘 DPI。失败诊断应能区分初始化失败、已设置的宿主模式和窗口实际比例。

预期文件边界：`src/leaf/build.nim`、`src/leaf/desktop.nim`、`src/leaf/gpui_bridge.nim`、新增 Windows DPI/manifest 辅助模块与资源（均在 `src/leaf/`）、`crates/leaf-gpui/src/bridge.rs`、`crates/leaf-gpui/src/desktop.rs`、相关 `tests/nim/`、必要的 `scripts/test.nim` 注册、`docs/verification.md` 和 `docs/development.md`。具体文件在设计范围内由计划明确。不得修改 vendor、上游缓存、依赖版本、用户配置或 DreamTools 源码。

```mermaid
flowchart LR
    A[Leaf 构建主 EXE] --> B[嵌入 PerMonitorV2 manifest]
    B --> C[桌面启动前检查 DPI 上下文]
    D[直接 Nim 编译] --> C
    C --> E[必要时初始化 PerMonitorV2]
    E --> F[加载 GPUI 并创建窗口]
    F --> G[读取实际 DPI 与比例]
    G --> H[按设备分辨率绘制]
```

## 必需验收项

| ID | 判据与证据 |
| --- | --- |
| P1 | Windows CLI 构建的主 EXE 内嵌 ID=1 manifest，解析实际 PE 资源确认 PerMonitorV2 和正确 XML 命名空间；不是只检查模板。含 SDK 搬迁与中文/空格路径构建检查。 |
| P2 | Windows 直接 Nim 编译路径在 GPUI 初始化前启用 PerMonitorV2；测试已设置模式、初始化失败及 headless 无副作用。失败不被伪报为成功。 |
| P3 | Windows 单屏 150% 的真实窗口读到 DPI=144、GPUI scale factor=1.5；同机修复前后原始截图对比文字和控件，保留原图及运行元数据，确认消除客户区整体位图放大。100% 和 125% 至少完成启动与比例检查。 |
| P4 | 真实 Windows 150% 窗口点击命中、输入选区、中文输入/IME、调整窗口和最大化正常；系统缩放变化后的 GPUI 比例和重绘正确。 |
| P5 | Nim 回归与 Rust 回归通过，ready 回调兼容，headless 保持可用；Linux 分支不引入 Windows 链接依赖。 |
| P6 | 开发/验证文档说明 DPI 诊断、直接编译与 CLI 的行为、重新编译要求及兼容性覆盖排查，并准确区分测试平台与未验证行为。 |

当前只能在 Linux 读取源码。Windows 原生运行、视觉及 PE 产物验收需要真实 Windows 环境；源码检查、模拟测试或 Wine 不替代 P3/P4。不能获得必需运行证据时验收必须 blocked，不声称“已解决模糊”。混合 DPI 多显示器测试为可选项，当前用户仅使用单屏。

## 协作与授权

批准绑定此 v1 文件摘要。本轮只完成只读调查和设计记录。用户批准后才写实施计划，由独立 GPT 审查；通过后由指定 DeepSeek 执行，再由全新 GPT 验证。禁止 commit、push、merge、发布、部署、归档或清理工作区；不扩大项目写入边界。

技能证据：coordinator `/root` 在本会话通过 exec_command 实际读取 brainstorming、systematic-debugging 和 paseo 的 SKILL.md；前两者来源为 `/home/jimxl/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/`，后者来源为 `/home/jimxl/.agents/skills/paseo/SKILL.md`。Paseo v1 的“设计人审、计划 AI 审”和“禁止自动提交”覆盖技能默认提交及执行选择步骤。
