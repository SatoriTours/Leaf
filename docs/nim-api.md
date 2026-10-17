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

## 组件与 State

显式 `import leaf/components`，通过 `defineComponent[Props,Model]` 定义 `MountContext` 初始化和 `ComponentContext` render，再用 `componentApplication(component(...),title)` 创建应用。完整可运行示例见 `examples/component_counter.nim`；原来的 `Application(render:...)` 保持兼容。

`ctx.state(initial)` 在挂载时建立 State；render 用 `ctx.value(state)` 读取当前候选。`state.set(value)` / `state.update(proc(old):T=...)` 排队，事件结束、`runtime.uiTask` 或 `runtime.batch` 最外层结束统一提交；手动 `runtime.flush()` 也可结算。队列在尝试开始时封存，失败不会自动重放 updater。初始化、render、updater 和提交期间禁止写 State；在一个 Runtime 的 UI 任务中也不能写另一个 Runtime 的 State 或嵌套进入它。普通 Nim 变量的修改仍是普通副作用，不随提交拒绝回滚。引用或可变容器类型必须提供独立 snapshot 函数，避免候选修改接受值。

组件默认在父 render 传入新描述时计算；`memo(def,equals)` 使用明确的 Props 比较，也可使用版本 token。memo 不阻止自身 State 更新或脏后代更新。稳定 key 只在相同父级、相同组件类型下保留身份；换父、换类型、换 key 会重挂载。无 key 使用位置身份。事件回调即使宿主属性未变也会更新到新接受版本。

`componentView` 与原 `view` 共用控制流语法，可以混合宿主节点与组件。`componentList` 提供组件行，可用 `styles` 设置列表尺寸；变量行高在一次绘制结束后合并视口请求，不随每行重复跨 FFI。滚出视口后 State 暂存于有限暖缓存，淘汰或源 generation 更换后旧 State 写入返回 disposed。需要长期保存的行数据应放在上层模型。

`runtime.snapshot` 和整树 validator 是显式完整导出；高频局部查询使用 `runtime.find(key)`，观察局部工作量使用 `runtime.updateStats()`。ABI2 默认自动选择；`LEAF_GPUI_ABI=1|2|auto` 可诊断协议选择，只有缺少 ABI2 查询符号才自动退回 ABI1，不会忽略不兼容查询结果。`LEAF_GPUI_CACHE=0` 可关闭组件缓存进行行为对照。

托管节点的完整诊断 ID 是内部格式，包含组件类型身份；业务查找应使用稳定 `key`。普通组件类型替换或卸载再挂载会建立新输入 Entity；列表源 generation 变化时，仅同一列表、逻辑 key 和宿主祖先类型一致的输入可迁移编辑状态。

## 组件页面路由

`leaf/components` 额外导出 `Route`、`PageRetention`、`ComponentPageDefinition`、`ComponentRouter`、`newComponentRouter`、`routes`、`navigate`、`currentRoute` 与 `renderPage`。路由在持有它的组件 initialize 中用 `newComponentRouter(ctx, routes, pages, initial)` 创建；`renderPage(ctx, router)` 在当前组件 render 中返回唯一页面出口，构造时只捕获当前页面的 build 与 view，不执行页面 build。`navigate(router, nameOrPath)` 把地址写入普通 State 队列，与同批 State、宿主和 revision 一起接受；未知地址抛出 `UiError` 且不排队，router 已销毁时返回 `StateWriteResult.disposed`。地址与页面配置在创建时复制并校验，之后不可变；`routes(router)` 返回副本。

页面生命周期由框架维护：默认 `PageRetention.retainState`，离开时移除该页宿主与活动事件、保留组件身份和 State，返回时分配新宿主句柄；`PageRetention.disposeOnLeave` 在离开被接受后递归卸载页面组件，旧 State 句柄变为 disposed，返回时重新初始化。隐藏页仍可接受 State 写入，但不 render、不导出；恢复时读取最新已接受值。整组保留页与列表暖行在 router 组件卸载时释放。保留不承诺光标、选区、焦点、滚动位置或未完成 IME 组合；重新挂载的输入控件建立新 Entity。

`PageOutletSpec`、`pageOutlet`、`outletSpec` 以及 owner/accounting helper 都是运行时内部入口，不从 `leaf/components` 导出。`DescriptionKind` 是可见枚举，新增 `pageOutlet` 值：对描述类型写穷尽 `case` 的低层代码需要显式处理该值，普通 `host`/`component` 使用方式不变。`ComponentRouter` 的配置字节与所属组件一起计入现有 `MaxTreeBytes` 预算，未显示的 controller 也不例外。完整可运行示例见 `examples/component_pages.nim`。

## 组件任务与生命周期

`import leaf/components` 导出 `ctx.onMount/onActivate/onDeactivate/onDispose`、`ctx.taskScope(retention=cancelOnDeactivate)`、`startTask` 和 `cancel`。初始化只登记回调；只有接受的转换才触发生命周期。首次可见也可能是 `onActivate`（例如最初为暖行的组件），不要假定 `onMount` 总先到，或在两处无条件重复启动任务。示例 [component_tasks.nim](../examples/component_tasks.nim) 导出 `tasksApplication(title="Leaf component tasks")`，演示加载、错误重试、默认离开取消、隐藏继续和离开销毁。

`work(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}` 只能接收复制的字节和借用的取消信号，不能捕获 UI 闭包、State、Runtime、Model/Query 或连接；不使用 `cast(gcsafe)` 绕过检查。`ctx.cancelled` 是协作式取消，work 不得保存 ctx。结果/错误处理器留在 UI scope，更新 State 后走正常宿主接受门禁。相同 owner/key 的新请求替代旧请求，旧完成不可写回重建或换绑后的 owner。取消不会撤销已经发生的外部写入，重试应考虑幂等性。

默认离开页面/活动列表行取消；`keepWhileRetained` 允许隐藏继续，隐藏 State 更新不 render，返回时呈现完成结果。`disposeOnLeave`、暖行淘汰和 Runtime 关闭仍取消保留任务。取消或替换的旧 work 在真正退出并 ack 前仍占任务/结果额度。默认两条 worker、64 个未收尾任务；单 input 1MiB、key 256 UTF-8 字节、总 input 8MiB；默认结果 65536 字节，上限 1MiB，总结果预留 8MiB。错误消息有界为 4KiB 且保持 UTF-8。

`pumpTasks(runtime)` 每轮最多认领 64 条完成/回调，4ms 是开始下一条的调度预算，不抢占当前 handler。`TaskPumpReport.delivered` 包括有效 work 错误的完成 claim；`callbacks` 是实际 handler 数；`failed` 是交付/作用域异常数，不是 work 错误数。未提供 onError 仍消费完成并记录有界错误。完成回调失败或其 UI 更新拒绝不会重放同一消息。`taskPumpPending` 只查 metadata，不消费、render、导出 Snapshot 或变更 revision。

GPUI 和 Win32 在 ordinary UI 安全点自动泵；headless 工具/SDK fixture 自行在有界循环显式 `pumpTasks`，CLI 普通 `--headless` 不等待后台任务。空 tick 不 render、不导出 Snapshot、不发送 UI 树、不增加 revision。ABI1 实际更新仍可能传完整活动树，不能套用 typed 增量路径的成本结论。

普通退出必须 `closeRuntime`。业务回调内关闭先使 State 无效/关投递门，未 claim 的 dispose 与 pool 回收留到 ordinary 边界。scope 拒绝后可显式再次关闭，不能把 closed 当全部清理完成。`runDesktop(...,cleanupOwner=addr owner)` 和 `GpuiRunError(cleanupRuntime,exitStatus)` 可移交待重试 Runtime；out slot 必须预先为 nil，无 out 时整数状态（含 0）保存在异常的 `some(status)`，原异常无整数时为 none，msg/parent 保留。重试成功后释放 owner/异常引用。

Win32 `runNative` 同样支持 `cleanupOwner` 和 `Win32RunError(cleanupRuntime,cleanupHost,exitStatus)`。若 Host 资源仍未释放，即使提供 Runtime out 也必须处理双 owner 异常：先 ordinary `cleanupHost.destroyHost()` 成功，再 `cleanupRuntime.closeRuntime()`；失败继续持有 owner。WndProc/renderer/native callback 不负责最终 join，也没有析构自动重试。
