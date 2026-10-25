# Leaf 文档

**先在 Windows 做出原生窗口，再按需要深入。** Linux/macOS 后端暂缓；原生 SDK 的发布状态须以对应提交工作流为准。

[返回项目首页](../README.md) · [Windows 原生表单](../examples/native_forms/README.md) · [当前能力与限制](progress.md)

## 第一次使用

| 步骤 | 你会得到什么 |
| --- | --- |
| **01 · [安装 SDK](installation.md)** | 配好工具，运行最小应用 |
| **02 · [第一个应用](getting-started.md)** | 从完整代码理解「状态 → 界面 → 事件」 |
| **03 · [生成完整应用](scaffolding.md)** | 页面、CRUD、SQLite 与测试一起就位 |
| **04 · [打包给别人](packaging.md)** | 可搬迁的桌面应用包 |

## 正在写应用

| 需要 | 查阅 |
| --- | --- |
| 布局、控件、事件与 State | [Nim API](nim-api.md) |
| 查询、保存、校验与事务 | [SQLite Model](models.md) |
| 建表、升级与回滚 | [数据库迁移](migrations.md) |
| 路由、页面组与生成器约定 | [应用脚手架](scaffolding.md) |
| 完整界面的源码 | [原生表单](../examples/native_forms/README.md) · [SQLite 列表](../examples/native_list/README.md) |

## 理解或开发框架

| 主题 | 查阅 |
| --- | --- |
| 谁管理状态？如何提交和绘制？ | [架构与设计](architecture.md) |
| 源码构建、测试、诊断与性能 | [源码开发](development.md) |
| 哪些已经交付，哪些尚未验收？ | [开发进度](progress.md) |
| 结果对应哪个输入和环境？ | [验证记录](verification.md) |

<details>
<summary>维护者入口：Windows 原生验证与历史证据</summary>

这些是平台验收材料，**不是上手教程**。旧批次的数字与 ABI 不代表当前完整能力。

- [Win32 范围与 H 门](native-win32-validation.md)：原生控件、构建和真人检查。
- [Windows 验收步骤](windows-acceptance.md)：身份、输入、runner 与判定。
- [Windows 环境记录](windows-environment.md)：持久环境、失败及复验。
- [真实窗口补验](windows-window-validation.md)：键盘、UIA、视觉失败与修复。

</details>

---

**阅读约定**：标有“节选”的代码需要上下文；“完整示例”可按所列命令运行。截图来自真实应用，但单个平台的图片、headless 检查或 CI 构建都不等于全平台视觉验收。
