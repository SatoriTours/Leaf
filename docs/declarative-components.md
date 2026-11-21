# 声明式组件

用 `component` 声明界面，`state` 保存组件自己的状态，`view` 读取状态，按钮块直接写 Nim 动作。下面的代码节选自[预约示例](../examples/booking/application.nim)：

```nim
component Booking:
  state:
    name = ""
    day = today()
    guests = 1
    confirmation = ""
  view:
    column:
      textField name, placeholder = "姓名"
      datePicker day, earliest = today()
      stepper guests, maximum = 6
      button "确认", disabled = name.len == 0:
        confirmation = name & " · " & $day & " · " & $guests & " 位"
      text confirmation
```

这里 `text` 只读：可传字符串或数字表达式，其他类型可显式用 `$` 转成文本。`textField` 与 `datePicker` 的第一个参数分别声明为 `model`；不需要 `bindTo`，也不会把普通参数自动变成双向绑定。按钮块在点击时执行，而不是渲染时。旧的 `onClick:` 和 `onClick(e):` 仍可用；同一按钮不能混用两种动作写法。

`app(Booking, title = "Leaf · 预约")` 返回 `Application`，不启动窗口；桌面入口调用 `run`，Android 入口用 `registerAndroidApplication` 注册返回同一应用描述的工厂。参见[实际入口](../examples/booking/README.md)。

## 可复用组件：model 与 prop

```nim
component Stepper, exported:
  model value: int
  prop minimum: int = 1
  prop maximum: int = 8
  view:
    row:
      button "−", disabled = value <= minimum:
        value -= 1
      text value
      button "+", disabled = value >= maximum:
        value += 1
```

导入组件模块后写 `stepper guests, maximum = 6`。PascalCase 声明带参数组件，小写首字母调用；`exported` 可省略，使声明仅在当前模块可见。也可以使用命名模型参数：`stepper(value = guests, maximum = 6)`。

- `model` 必须直接绑定同类型的 `state` 或上层 `model` 名称，不能传字面值、普通常量、计算结果或 `prop`。读发生在本次渲染，写发生在事件中，并随同一次 UI 提交接受或回滚。
- `prop` 是只读输入，可以有默认值，可以传表达式。不能给属性赋值或把它作为可写 `var` 参数传递。与普通 Nim 一样，不应通过可变引用别名绕过这一约定；应用副作用也不会被 UI 事务回滚。
- `state` 初值在挂载时求值一次；`key` 保留为可选的组件身份参数。稳定的键和控件类型允许宿主差量更新，避免不必要的原生控件重建；这不是新的性能基准结论。
- 需要事件对象时用旧 `onClick(e)`；需要路由、所有权或生命周期低层接口时可继续用 `defineComponent`、`componentView` 与 `componentApplication`。

## 文本输入：绑定或显式处理

- `textField book.query` 双向绑定 `state` 或 `model` 的字符串字段，也可写 `textField draft.details.title` 或沿用 `textField name`。Leaf 在输入事件中更新整个对象的草稿，只改目标字段；通知与写回随同一次 UI 提交接受或回滚。
- 可省略通知，也可写 `onChange:` 或 `onChange(query):`。后者的参数是**输入字符串**，不是事件对象；回调读取绑定时已能看到新值。程序更新重新显示文本，但不触发输入通知。
- `textField value = expr:` 显示任意字符串表达式。它的 `onChange(query):` 可以自行处理输入，但 Leaf 不会写回表达式。只读的 `prop`、计算属性、引用解引用和下标不能用在双向路径里。程序要修改对象状态时，仍需在事件中赋一个新对象；字段绑定并不放开普通 Nim 语句中的原地写入。

## 虚拟列表与命名事件

下面是[读书清单](../examples/reading_list.nim)的列表组件。每项只写一次布局；`item` 是该项，在列表块外不可见。

```nim
component NoteList:
  prop shown: seq[Note]
  event onSelect: int
  view:
    list shown, key = "notes", rowHeight = 36, styles = style({"height": "120", "width": "full"}):
      text item.title:
        key: "note-" & $item.id
      button "打开", key = "open-" & $item.id:
        onSelect(item.id)
```

- `list shown:` 接受 Nim 序列或数组；每项内的控件放在同一横行，只按虚拟视口构造所需的行。列表块里的 `key = item.code` 可覆盖默认的 `item.id`；键转成字符串，重复立即报错。
- 没有 `id` 或显式键时用位置，只适合固定顺序的静态数据。排序、筛选及可编辑列表请用稳定业务键。重排时仍保留可见且键未变的行，事件会读取该键对应的最新行数据；因过滤或视口淘汰而卸载的行不保证保留本地状态。
- 列表头的 `key = "notes"` 指列表控件本身，不是行身份。没有显式键时 Leaf 按代码位置生成；需要用 headless 命令操作列表，或在循环中重复生成同一处列表，请显式指定彼此不同的列表键。
- `event onSelect: int` 声明一个带类型的事件，子组件在事件动作中调用 `onSelect(item.id)`；父组件写 `onSelect(id):` 处理。同理，`event onSave`、`onSave()` 与 `onSave:` 分别声明、发出和处理无参数事件。处理器可以省略；已连接的处理器与触发动作共用同一批 UI 草稿。常规 Nim 副作用不随 UI 回滚。

从仓库根目录运行示例（不需要窗口）：

```sh
nim c -d:leafHeadlessOnly --out:target/nim/reading-list examples/reading_list.nim
target/nim/reading-list --headless --list notes 0 2 --change search Nim \
  --click open-2 --change title "Nim 📚" --click save
```

最终 JSON 包含列表标题 `Nim 📚` 和状态 `已保存：Nim 📚`。搜索、草稿和保存结果都在内存中；持久化参见 [Leaf Notes](../examples/native_notes/README.md)。

## 契约与平台实现

契约声明调用方可见的参数；实现提供自己的 `state` 和 `view`，不重复声明参数：

```nim
contract Rating, exported:
  model value: int
  prop maximum: int = 5

implement Rating:
  view:
    button $value, disabled = value >= maximum:
      value += 1

implement Rating, platform = windows:
  view:
    button ("评分：" & $value), disabled = value >= maximum:
      value += 1
```

导入含实现的模块（若拆分声明与实现，通常由实现模块重导出声明模块）。编译器优先解析当前目标的实现，否则使用已导入的共享实现；两者都不存在时，在调用处报告契约名和目标。非当前目标的实现体不参与编译。支持 `windows`、`android`、`linux`、`macos`、`ios`、`headless`（`-d:leafHeadlessOnly`）；可声明目标不等于 Leaf 已具备该目标的原生运行时。平台 API 放进对应实现，应用组件不需要分支。覆盖只影响能够看到该实现的组件调用；在定义应用组件前导入它。

[`DatePicker`](../src/leaf/date_picker.nim) 使用同一契约机制。当前共享实现通过 Leaf 现有控件提供内联的 ISO 日期输入与前一天／后一天选择，**不是系统日历弹窗**。选择或输入只改变编辑草稿；确认时校验合法日期和闭区间 `earliest..latest`，通过才写模型。取消不写，下次打开从模型重新取值。需要在同一应用中自动化多个日期控件时，可用 `id` 给它们的事件键不同前缀。

## 当前验证范围

- Linux：可编译并从真实可执行文件运行 `--check` / `--headless`；没有 Linux 原生 GUI。
- Windows x64：复用现有 Win32 控件；本轮预约示例只做了目标语义检查，未验收窗口、焦点或输入法。
- Android x86_64：NDK 可链接预约的 JNI 共享库；本轮未安装 APK、未做模拟器或真机交互验收。
- macOS/iOS：未验证 GUI。选择契约实现的能力不新增任何平台后端。
