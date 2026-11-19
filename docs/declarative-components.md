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
