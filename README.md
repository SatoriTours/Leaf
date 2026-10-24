# Leaf

用 **Nim** 编写桌面应用：声明式界面、组件状态和事件处理，默认由 **GPUI** 渲染。

[![CI](https://github.com/SatoriTours/Leaf/actions/workflows/ci.yml/badge.svg)](https://github.com/SatoriTours/Leaf/actions/workflows/ci.yml)

## 快速开始

Linux / macOS 安装当前开发版（beta）：

```sh
curl -fsSL https://raw.githubusercontent.com/SatoriTours/Leaf/main/install.sh | sh -s -- --channel beta
```

Windows 安装、系统依赖和正式版安装见[安装说明](docs/installation.md)。SDK 自带 Nim 编译器和 GPUI 桥接库，开发应用无需安装 Rust。

安装后打开新终端，创建并运行应用：

```sh
leaf init my-app
cd my-app
leaf run
```

## 一个计数器

将项目的 `src/main.nim` 替换为以下代码，再执行 `leaf run`：

```nim
import leaf

let Counter = defineComponent[int, State[int]]("Counter",
  proc(ctx: MountContext, initial: int): State[int] =
    ctx.state(initial),
  proc(ctx: ComponentContext, initial: int, count: State[int]): UiDescription =
    let value = ctx.value(count)
    componentView:
      column:
        styles: {"padding": "24", "gap": "12"}
        text "计数：" & $value:
          key: "count"
        button "增加":
          key: "add"
          onClick(e):
            count.update(proc(value: int): int = value + 1))

let app = componentApplication(component(Counter, 0), "计数器", 400, 300)
when isMainModule:
  quit(run(app))
```

`ctx.state` 创建组件状态，`ctx.value` 读取当前值，`count.update` 更新状态并触发界面刷新。点击“增加”，计数加一。

更多可运行代码见 [examples](examples)：[完整计数器](examples/counter.nim)、[待办列表](examples/todo.nim)、[子组件](examples/components.nim)。

## 文档

- [Nim API](docs/nim-api.md) · [架构](docs/architecture.md)
- [脚手架与 CRUD](docs/scaffolding.md) · [SQLite Model](docs/models.md) · [数据库迁移](docs/migrations.md)
- [源码开发与测试](docs/development.md) · [应用打包](docs/packaging.md)
- [开发进度与平台限制](docs/progress.md) · [验证记录](docs/verification.md)

MIT 许可。第三方许可证见 [GPUI-NOTICES.json](src/leaf/vendor/GPUI-NOTICES.json)。
