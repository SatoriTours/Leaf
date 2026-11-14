<div align="center">

# Leaf

**用 Nim 描述界面，让状态驱动系统原生控件。**

声明式 UI · 组件状态 · Win32 原生控件 · SQLite 应用脚手架

[![CI](https://github.com/SatoriTours/Leaf/actions/workflows/ci.yml/badge.svg)](https://github.com/SatoriTours/Leaf/actions/workflows/ci.yml)

[第一个应用](docs/getting-started.md) · [笔记 Demo](examples/native_notes/README.md) · [文档](docs/README.md)

</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/leaf-notes-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/screenshots/leaf-notes-light.png">
    <img src="docs/screenshots/leaf-notes-light.png" width="960" alt="Leaf Notes 松石主题真实原生应用：左侧笔记导航、中间搜索列表、右侧多行编辑与 SQLite 保存，提供浅色和深色外观">
  </picture>
  <br><sub>Leaf Notes · 松石主题 · 真实 Windows 11 / 96 DPI 窗口实拍。</sub>
  <br><sub><a href="docs/screenshots/leaf-notes-light.png">查看浅色原图</a> · <a href="docs/screenshots/leaf-notes-dark.png">查看深色原图</a> · <a href="examples/native_notes/README.md">运行这个 Demo</a> · <a href="docs/screenshots/README.md">截图来源</a></sub>
</p>

**原生交互，也有自己的风格。** 松石主题以松绿强调色、圆角输入框和清晰的主次按钮，提供统一的浅色与深色外观；文本输入、选区和 IME 仍由系统 EDIT 控件处理。示例与新生成的应用默认使用浅色松石，框架默认保留系统外观，也可在启动时通过 `app.withNativeTheme(matsuLight)` 或 `app.withNativeTheme(matsuDark)` 显式选择主题。

**从一个真正可用的小应用开始。** [Leaf Notes](examples/native_notes/README.md) 将导航、搜索、虚拟列表与多行编辑组合成一个本地笔记应用：新建、收藏、归档，点击保存后写入 SQLite，关闭重开仍在。不是控件拼图，也不是网页效果图。

## 状态 → 界面 → 事件

业务和组件状态留在 Nim；Windows 界面使用系统的按钮、输入框和其他原生控件，不依赖浏览器或 Rust 渲染桥接。

```nim
let n = ctx.value(count)
componentView:
  column:
    text $n:
      key: "count"
    button "增加 +1":
      key: "add"
      onClick(e): discard count.update(proc(v: int): int = v + 1)
```

这是组件 render 中的**节选**；初始化、组件声明与启动见[完整入门代码](docs/getting-started.md)。

| 你来描述 | Leaf 来处理 |
| --- | --- |
| **界面结构** | 编译期 DSL、类型检查、原生布局与控件 |
| **状态变化** | 候选校验、受影响组件更新、稳定身份 |
| **应用业务** | 页面路由、SQLite Model、迁移及 CRUD 生成 |

## 先在 Windows 跑起来

从源码需要 **Windows x64、Nim 2.2.6+ 和 MinGW（含 windres）**。在仓库根目录：

```powershell
nim c -d:release --out:target/nim/leaf.exe src/leaf_cli.nim
.\target\nim\leaf.exe init my-app
cd my-app
..\target\nim\leaf.exe run
```

[SDK 安装与发布状态](docs/installation.md) · [源码开发](docs/development.md)

## 从小界面，到完整应用

| 想做什么 | 从这里开始 |
| --- | --- |
| 学 State、布局和事件 | [第一个应用](docs/getting-started.md) → [Nim API](docs/nim-api.md) |
| 看完整的原生应用 | [Leaf Notes 笔记 Demo](examples/native_notes/README.md) |
| 学 Windows 原生交互 | [原生表单](examples/native_forms/README.md) · [万行 SQLite 列表](examples/native_list/README.md) |
| 生成带数据库的应用 | [脚手架](docs/scaffolding.md) → [Model](docs/models.md) → [迁移](docs/migrations.md) |
| 理解设计与提交边界 | [架构](docs/architecture.md) |
| 打包给别人 | [Windows 应用打包](docs/packaging.md) |

> **当前阶段：beta，优先 Windows。** 默认桌面路径是 Win32；Linux/macOS GUI 尚未实现，明确报不支持，不使用备用渲染器。共享逻辑可做 headless 检查。Android 保留已有原生路径，不代表设备矩阵已验收。平台限制与历史未关闭项见[开发进度](docs/progress.md)。

[MIT 许可](LICENSE) · 第三方清单随应用及 SDK 打包，详见 `licenses/inventory.json`。
