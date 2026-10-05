# Nim API

```nim
import leaf
```

`Application(title, width, height, render)` 定义应用；`render` 接收 `BuildContext`，返回 `Node`。`run(app)` 默认打开 GPUI 窗口，命令行 `--headless` / `--check` 使用相同 Nim 业务逻辑。

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
