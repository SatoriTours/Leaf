# Nim API

```nim
import leaf
```

`Application(title, width, height, render)` 定义应用；`render` 接收 `BuildContext`，返回 `Node`。`run(app)` 默认打开 GPUI 窗口，命令行 `--headless` / `--check` 使用相同 Nim 业务逻辑。

推荐用 `view:` 描述界面，括号只用于短表达式，组件层级由缩进表示：

```nim
proc render(ctx: BuildContext): Node =
  view:
    column:
      styles: {"padding": "24", "gap": "12"}
      text "待办事项"
      input draft:
        key: "entry"
        placeholder: "输入事项"
        onChange(e): draft = e.value
      row:
        for item in items:
          taskView(item)
      button "添加":
        key: "add"
        onClick(e):
          addTask(draft)
          draft = ""

let app = Application(title: "Todo", width: 720, height: 560, render: render)
```

`view:` 返回一个 `Node`，必须恰好有一个根组件。组件块的属性使用 `name: value`，事件块使用 `onClick(e):`、`onChange(e):` 或 `onSubmit(e):`；`e` 是可自行命名的 `Event` 参数。已有回调可写成 `onClick: callback`。

`styles:` 可以接收样式表字面量（自动调用 `style`）或已有 `Styles`，例如 `styles: grow()`。样式放在组件块开头，子组件逐行排列，不需要 `@[...]` 或逗号。属性只放在组件块的直接层级，条件样式可通过表达式指定。

布局内支持普通 Nim 的 `let`、`var`、`if`、`when`、`case`、`for`、`while` 和 `block`；节点与节点序列表达式会加入子组件，返回 `void` 的调用可用于普通计算。已有 `Node` 和自定义组件可直接放入布局。自定义容器只需接收 `children: seq[Node]` 参数，例如 `card:` 内可嵌套组件。动态子节点也可写成 `children: nodes`，但不能同时嵌套子组件。

`view:` 在编译期展开为以下普通构造器，保留 Nim 类型检查与原有运行时行为。单独定义 `render` 后传给 `Application`，避免将匿名函数放在跨多行的构造器括号内。

需要构建 `seq[Node]` 时使用 `views:`，其中可排列多个根组件，用法与布局内部相同。例如：

```nim
let actions = views:
  button "保存":
    key: "save"
    onClick(e): save()
  button "取消":
    key: "cancel"
    onClick(e): cancel()
```

| 构造器 | 内容 |
| --- | --- |
| `column(children)` / `row(children)` | 纵向或横向布局 |
| `text(value)` / `tag(label)` | 文本与 Kit 标签 |
| `button(label, onClick)` | Kit 按钮 |
| `input(value, onChange, onSubmit)` | Kit 受控输入 |
| `checkbox(label, checked, onChange)` / `switch(...)` | Kit 布尔控件 |
| `progress(value)` / `separator()` / `spinner()` | Kit 进度、分隔与加载控件 |
| `virtualList(key, keys, builder, rowHeight, estimatedHeight, overscan)` | 按视口构建列表行 |

`key` 在同一父级内唯一，稳定 key 用于重排与输入实体复用。`Event` 包含 `kind`、`value`、`checked`。回调修改应用状态后，Runtime 重新构建并校验完整候选树。`cached(ctx, key, revision, builder)` 缓存不变的子组件。

`style({"padding": "24", "gap": "12"})` 支持尺寸与 min/max、full/auto、padding、gap、flex grow/shrink、align、justify、颜色、字号、字重、边框、圆角、opacity 和 overflow。具体校验由 `gpui_styles.nim` 完成；值在进入 GPUI 前检查。

列表最多十万项，行通过 `builder(index)` 延迟构建。`rowHeight > 0` 使用固定行高，零使用变量行高；`estimatedHeight` 提供初始估计。输入框应使用稳定 key，并根据 `onChange` 更新受控值。

完整例子见 `examples/counter.nim`、`examples/todo.nim`、`examples/kit.nim` 与 `example/main.nim`。

## 页面组与桌面路由

`import leaf` 同时导出 `PageGroup`、`PageDefinition`、`Route` 和 `Router`。页面组的 render 接收 `BuildContext` 与 View 名称；`PageDefinition` 声明允许的 View 及创建工厂。`newRouter(routes, pages, initial)` 校验配置，按首次渲染惰性创建页面组，切换路由复用状态。

`navigate(router, nameOrPath)` 切换静态路由；`currentRoute(router)` 返回当前 Route，`routes(router)` 返回有序配置，`renderPage(router, ctx)` 构建当前 View。导航放在事件回调中，利用 Leaf 的事件后刷新。完整应用和资源模板使用相同接口，见[应用架构与脚手架](scaffolding.md)。

## SQLite 存储

`import leaf/sqlite` 提供 `openDatabase(path)`、`close()`、`execute(sql, values)`、`query(sql, values)`、`lastInsertId` 和 `migrate(migrations)`。`dbValue` 绑定字符串、整数、浮点数与布尔值，查询值通过 `asString`、`asInt`、`asFloat`、`asBool` 读取；`SqlValue(kind: sqlNull)` 表示 NULL。`execute` 返回受影响行数。`execute`/`query` 只接受单条 SQL，并检查参数数量；可信迁移脚本使用 `executeScript`。

`Migration(version, name, sql)` 定义一个版本，`migrate` 接收完整迁移历史并按版本应用尚未执行的 SQL，每个版本事务提交。连接在所属线程使用；显式关闭后的操作会抛出 `DatabaseError`。完整应用模板在启动时配置连接与迁移，并将连接传给所有页面组与服务。
