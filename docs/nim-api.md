# Nim API

```nim
import leaf
```

唯一应用入口是 `componentApplication(root: UiDescription, title, width, height, executionScope)`；`newRuntime` 拒绝只有旧 `render` 的应用。`run(app)` 默认打开 GPUI（ABI 2）窗口，命令行 `--headless` / `--check` 使用同一托管运行时。

推荐用 `view:` 描述界面，括号只用于短表达式，组件层级由缩进表示：

```nim
proc renderTodo(state: TodoState): Node =
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

componentApplication(component(TodoRoot, 0), "Todo", 720, 560)
```

`view:` 仍是组件内部可用的纯 `Node` 描述 DSL，必须恰好有一个根组件。组件块的属性使用 `name: value`，事件块使用 `onClick(e):`、`onChange(e):` 或 `onSubmit(e):`；`e` 是可自行命名的 `Event` 参数。已有回调可写成 `onClick: callback`。应用根不再是 `Application(render:)`。

`styles:` 可以接收样式表字面量（自动调用 `style`）或已有 `Styles`，例如 `styles: grow()`。样式放在组件块开头，子组件逐行排列，不需要 `@[...]` 或逗号。属性只放在组件块的直接层级，条件样式可通过表达式指定。

布局内支持普通 Nim 的 `let`、`var`、`if`、`when`、`case`、`for`、`while` 和 `block`；节点与节点序列表达式会加入子组件，返回 `void` 的调用可用于普通计算。已有 `Node` 和自定义组件可直接放入布局。自定义容器只需接收 `children: seq[Node]` 参数，例如 `card:` 内可嵌套组件。动态子节点也可写成 `children: nodes`，但不能同时嵌套子组件。

`view:` 在编译期展开为普通 `Node` 构造器，保留 Nim 类型检查。它应运行在组件 render 内，并由 `host`/`hostShell`/`componentView` 接入托管描述。

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

`import leaf` 导出纯配置 `Route` 与事务化 `ComponentRouter`/`ComponentPageDefinition`。`newComponentRouter(ctx, routes, pages, initial)` 在组件初始化时校验配置并建立导航历史 State；`navigate(router, nameOrPath)` 选择当前地址，`push`、`replace`、`pop` 显式更新历史，`renderPage(ctx, router)` 返回页面出口。旧 `PageGroup`/`PageDefinition`/`Router` 非事务运行模型已移除，日期化历史文档中的示例只作存档。完整应用和资源模板使用相同接口，见[应用架构与脚手架](scaffolding.md)。

## SQLite 存储

`import leaf/sqlite` 提供 `openDatabase(path)`、`close()`、`execute(sql, values)`、`query(sql, values)`、`lastInsertId` 和 `migrate(migrations)`。`dbValue` 绑定字符串、整数、浮点数与布尔值，查询值通过 `asString`、`asInt`、`asFloat`、`asBool` 读取；`SqlValue(kind: sqlNull)` 表示 NULL。`execute` 返回受影响行数。`execute`/`query` 只接受单条 SQL，并检查参数数量；可信迁移脚本使用 `executeScript`。

`Migration(version, name, sql)` 定义一个版本，`migrate` 接收完整迁移历史并按版本应用尚未执行的 SQL，每个版本事务提交。连接在所属线程使用；显式关闭后的操作会抛出 `DatabaseError`。完整应用模板在启动时配置连接与迁移，并将连接传给组件页面与服务。

Android 将固定的 SQLite 3.54.1 编入应用，Leaf、Norm 与 lowdb 共用同一实现；桌面默认仍使用动态库。`-d:leafBundledSqlite` 可在本地验证应用内引擎。借用连接不能交给另一个 SQLite 库释放或操作；Windows 默认三种绑定已在真实 Windows 用例中验证共用 `winsqlite3.dll`；统一 `-d:leafOrmSqliteLibrary` 可覆盖三者，Windows override 仅经编译验证，未作运行通过声明。

## 宿主资源与私有数据路径

`import leaf/app_resources` 提供显式的 `HostResources`。`readAsset(relative, maxBytes)` 返回拥有的二进制 string，允许内容含 NUL；默认单资源预算 1 MiB，可调低。相对路径须符合项目的可移植路径规则，最长 4096 字节。`dataPath(relative)` 返回私有数据根内的路径，不创建目录或打开数据库；业务按需创建父目录。已有路径前缀会检查 canonical 路径，拒绝符号链接逃出根目录。

`asset(resources, relative)` 为只接受文件路径的 API 按需提取资源，保留相对文件名和后缀，存入私有 cache 根下的内容 SHA256 目录。已有内容一致时复用，内容不符时拒绝；没有跨进程 writer 协调或自动缓存回收。读取和提取会分配并执行 I/O，应在普通业务边界调用。

Android 可从 `leaf/backends/android/ffi` 注册 `proc(resources: HostResources): Application` 工厂。`LeafActivity` 以 applicationContext 的 assets/filesDir/cacheDir 建立资源宿主，Activity 重建沿用原 Runtime 的资源；终态清理成功后旧资源访问拒绝。业务使用创建线程访问，由宿主管理其关闭；失败清理仍保留原 owner 供显式重试。原无参工厂继续支持；资源工厂经旧无资源 create 入口会被明确拒绝。桌面可用 `directoryResources(assetDirectory, dataDirectory, cacheDirectory)` 建立相同接口，三个根目录均须已存在。

## 组件与 State

`leaf` 默认导出唯一组件 API：通过 `defineComponent[Props,Model]` 定义 `MountContext` 初始化和 `ComponentContext` render，再用 `componentApplication(component(...),title)` 创建应用。完整可运行示例见 `examples/component_counter.nim`。旧的 `Application(render:...)`/`BuildContext` 运行路径已移除。

`ctx.state(initial)` 在挂载时建立 State；render 用 `ctx.value(state)` 读取当前候选。`state.set(value)` / `state.update(proc(old):T=...)` 排队，事件结束、`runtime.uiTask` 或 `runtime.batch` 最外层结束统一提交；手动 `runtime.flush()` 也可结算。队列在尝试开始时封存，失败不会自动重放 updater。初始化、render、updater 和提交期间禁止写 State；在一个 Runtime 的 UI 任务中也不能写另一个 Runtime 的 State 或嵌套进入它。普通 Nim 变量的修改仍是普通副作用，不随提交拒绝回滚。引用或可变容器类型必须提供独立 snapshot 函数，避免候选修改接受值。

组件默认在父 render 传入新描述时计算；`memo(def,equals)` 使用明确的 Props 比较，也可使用版本 token。memo 不阻止自身 State 更新或脏后代更新。稳定 key 只在相同父级、相同组件类型下保留身份；换父、换类型、换 key 会重挂载。无 key 使用位置身份。事件回调即使宿主属性未变也会更新到新接受版本。

`componentView` 与原 `view` 共用控制流语法，可以混合宿主节点与组件。`componentList` 提供组件行，可用 `styles` 设置列表尺寸；变量行高在一次绘制结束后合并视口请求，不随每行重复跨 FFI。滚出视口后 State 暂存于有限暖缓存，淘汰或源 generation 更换后旧 State 写入返回 disposed。需要长期保存的行数据应放在上层模型。

`runtime.snapshot` 和整树 validator 是显式完整导出；高频局部查询使用 `runtime.find(key)`，观察局部工作量使用 `runtime.updateStats()`。GPUI 只加载 ABI 2 `query_v2`；仅 ABI1 的库会被明确拒绝，`LEAF_GPUI_ABI=1` 报已移除，unset/auto/2 均指向同一 ABI2 路径。`LEAF_GPUI_CACHE=0` 可关闭组件缓存进行行为对照。

托管节点的完整诊断 ID 是内部格式，包含组件类型身份；业务查找应使用稳定 `key`。普通组件类型替换或卸载再挂载会建立新输入 Entity；列表源 generation 变化时，仅同一列表、逻辑 key 和宿主祖先类型一致的输入可迁移编辑状态。

## 组件页面路由

`leaf/components` 额外导出 `Route`、`PageRetention`、`ComponentPageDefinition`、`ComponentRouter`、`newComponentRouter`、`routes`、`navigate`、`currentRoute` 与 `renderPage`。路由在持有它的组件 initialize 中用 `newComponentRouter(ctx, routes, pages, initial)` 创建；`renderPage(ctx, router)` 在当前组件 render 中返回唯一页面出口，构造时只捕获当前页面的 build 与 view，不执行页面 build。`navigate(router, nameOrPath)` 把地址写入普通 State 队列，与同批 State、宿主和 revision 一起接受；未知地址抛出 `UiError` 且不排队，router 已销毁时返回 `StateWriteResult.disposed`。地址与页面配置在创建时复制并校验，之后不可变；`routes(router)` 返回副本。

`push(router, target)` 追加历史条目（同地址也有新条目身份），`replace(router, target)` 替换栈顶，`pop(router)` 返回上一条；根处 pop 保持原值。兼容 `navigate` 替换当前地址且不增加深度，同地址不触发页面 render。几次操作进入同一批时按顺序折叠；候选失败保留原历史，并消费失败批次，不自动重试。`history(router)` 返回已接受的 root→current 地址副本，`history(ctx, router)` 在所属组件 render 中读取候选，`canPop(router)` 查询是否能返回。历史最多 10000 条；重复地址仍复用现有按 page 保留的组件模型，不因此创建独立业务对象。

宿主可用 `backProposal(router, requestId)` 登记返回提案，requestId 在该 router 内严格递增；返回的 `NavigationBackProposal.requestId == 0` 表示根或已过期请求。`cancelBack(router, requestId)` 在确认前撤销请求，不写历史；`confirmBack(router, proposal)` 仅在原登记提案仍有效时返回 true 并排队一次 pop，true 表示已排队，最终仍受正常提交门约束。重复、取消、伪造和历史版本已变的完成返回 false。已排队的请求即使候选失败也不能重用，重试需新 requestId；取消边界截止于确认排队。平台还需核对自身 session/mount，不能用此共享 API 的测试代替各平台原生导航验收；Android ABI5 的容器与系统返回接线见下文，转场动画未实现。

页面生命周期由框架维护：默认 `PageRetention.retainState`，离开时移除该页宿主与活动事件、保留组件身份和 State，返回时分配新宿主句柄；`PageRetention.disposeOnLeave` 在离开被接受后递归卸载页面组件，旧 State 句柄变为 disposed，返回时重新初始化。隐藏页仍可接受 State 写入，但不 render、不导出；恢复时读取最新已接受值。整组保留页与列表暖行在 router 组件卸载时释放。保留不承诺光标、选区、焦点、滚动位置或未完成 IME 组合；重新挂载的输入控件建立新 Entity。

`renderNavigation(ctx, router, key)` 是显式选择 typed 原生宿主的出口，保留 `renderPage` 的页面 State/retention 语义，并额外生成一个 `NodeKind.navigation` 容器；旧 `renderPage` 仍为透明出口。导航元数据仅包含 router/history revision/current/previous/depth，不传路由字符串、业务闭包或第二份历史栈。当前共享宿主与记录后端已接线。Android ABI5/LAV5 提供单一无歧义导航容器和系统返回事实桥；ABI1–4 保留旧能力并拒绝导航；Win32 已支持 typed 导航容器，GPUI ABI2 明确拒绝该节点。Android 宿主须在 manifest 启用 `android:enableOnBackInvokedCallback="true"`。API34+ 接 begin/cancel/confirm，API33 接 invoked，API26–32 接 legacy back；仅普通前台 turn 提交历史。当前不提供转场动画；API26–33 路径尚无设备运行证据。

Win32 将 Alt+Left 与 `WM_APPCOMMAND/APPCOMMAND_BROWSER_BACKWARD` 登记为普通 UI turn 的返回事实，按键自动重复会折叠；输入正在 composition 时让编辑器处理。history-only 更新保留容器 HWND，返回候选失败时恢复原 accepted 历史，不在 idle 自动重试。当前原生测试覆盖注入 Win32 消息、重挂载和故障回放；物理键盘、自然 IME、多栈、动画和跨 DPI 尚未验收。

原生适配器通过 `BackendSession.queueNavigation` 登记带 session/mount/handle/binding/revision/sequence/requestId 的 begin/cancel/confirm 事实。begin/cancel 不执行业务，confirm 进入同一普通事件队列，交付前重新核对 accepted 身份；取消可在原生事实被 claim 前撤销。此取消边界位于 router 的 `confirmBack` 入队之前。平台 requestId 在同一 session 内跨容器单调，并须满足 retained router 的单调要求；挂载重建不能复用该 router 已消费的请求。已登记事实不代表 pop 成功，最终以 accepted 导航元数据为准。该队列会分配，未作零分配声明。

`PageOutletSpec`、`pageOutlet`、`outletSpec` 以及 owner/accounting helper 都是运行时内部入口，不从 `leaf/components` 导出。`DescriptionKind` 是可见枚举，新增 `pageOutlet` 值：对描述类型写穷尽 `case` 的低层代码需要显式处理该值，普通 `host`/`component` 使用方式不变。`ComponentRouter` 的配置字节与所属组件一起计入现有 `MaxTreeBytes` 预算，未显示的 controller 也不例外。完整可运行示例见 `examples/component_pages.nim`。

## 组件任务与生命周期

`import leaf/components` 导出 `ctx.onMount/onActivate/onDeactivate/onDispose`、`ctx.taskScope(retention=cancelOnDeactivate)`、`startTask` 和 `cancel`。初始化只登记回调；只有接受的转换才触发生命周期。首次可见也可能是 `onActivate`（例如最初为暖行的组件），不要假定 `onMount` 总先到，或在两处无条件重复启动任务。示例 [component_tasks.nim](../examples/component_tasks.nim) 导出 `tasksApplication(title="Leaf component tasks")`，演示加载、错误重试、默认离开取消、隐藏继续和离开销毁。

`work(input:string,ctx:WorkerContext):string {.nimcall,gcsafe.}` 只能接收复制的字节和借用的取消信号，不能捕获 UI 闭包、State、Runtime、Model/Query 或连接；不使用 `cast(gcsafe)` 绕过检查。`ctx.cancelled` 是协作式取消，work 不得保存 ctx。结果/错误处理器留在 UI scope，更新 State 后走正常宿主接受门禁。相同 owner/key 的新请求替代旧请求，旧完成不可写回重建或换绑后的 owner。取消不会撤销已经发生的外部写入，重试应考虑幂等性。

默认离开页面/活动列表行取消；`keepWhileRetained` 允许隐藏继续，隐藏 State 更新不 render，返回时呈现完成结果。`disposeOnLeave`、暖行淘汰和 Runtime 关闭仍取消保留任务。取消或替换的旧 work 在真正退出并 ack 前仍占任务/结果额度。默认两条 worker、64 个未收尾任务；单 input 1MiB、key 256 UTF-8 字节、总 input 8MiB；默认结果 65536 字节，上限 1MiB，总结果预留 8MiB。错误消息有界为 4KiB 且保持 UTF-8。

`pumpTasks(runtime)` 每轮最多认领 64 条完成/回调，4ms 是开始下一条的调度预算，不抢占当前 handler。`TaskPumpReport.delivered` 包括有效 work 错误的完成 claim；`callbacks` 是实际 handler 数；`failed` 是交付/作用域异常数，不是 work 错误数。未提供 onError 仍消费完成并记录有界错误。完成回调失败或其 UI 更新拒绝不会重放同一消息。`taskPumpPending` 只查 metadata，不消费、render、导出 Snapshot 或变更 revision。

GPUI 和 Win32 在 ordinary UI 安全点自动泵；headless 工具/SDK fixture 自行在有界循环显式 `pumpTasks`，CLI 普通 `--headless` 不等待后台任务。空 tick 不 render、不导出 Snapshot、不发送 UI 树、不增加 revision。ABI 2 typed 增量路径是唯一桌面更新通道；完整树只用于显式诊断/初次同步。

普通退出必须 `closeRuntime`。业务回调内关闭先使 State 无效/关投递门，未 claim 的 dispose 与 pool 回收留到 ordinary 边界。scope 拒绝后可显式再次关闭，不能把 closed 当全部清理完成。`runDesktop(...,cleanupOwner=addr owner)` 和 `GpuiRunError(cleanupRuntime,exitStatus)` 可移交待重试 Runtime；out slot 必须预先为 nil，无 out 时整数状态（含 0）保存在异常的 `some(status)`，原异常无整数时为 none，msg/parent 保留。重试成功后释放 owner/异常引用。

Win32 `runNative` 同样支持 `cleanupOwner` 和 `Win32RunError(cleanupRuntime,cleanupHost,exitStatus)`。若 Host 资源仍未释放，即使提供 Runtime out 也必须处理双 owner 异常：先 ordinary `cleanupHost.destroyHost()` 成功，再 `cleanupRuntime.closeRuntime()`；失败继续持有 owner。WndProc/renderer/native callback 不负责最终 join，也没有析构自动重试。

`RuntimeCleanupError` 在 `leaf/core` 定义，公开 `cleanupRuntime: Runtime`、`exitStatus: Option[int]`；`GpuiRunError` 和 `Win32RunError` 继承它，Win32 另有 `cleanupHost`。`newRuntime` 首次已接受刷新在 scope-exit 报错时，完全退出保护域后只尝试一次 ordinary close；清理成功原样抛出原错误，清理拒绝则由共用异常保存原 msg/parent 和可重试 owner，status 为 none。未接受候选不执行 dispose，也不会为清理而泵 mount/activate/work。

`run(app, args, cleanupOwner=nil)`、`run(app, cleanupOwner=nil)` 和 `runHeadless` 的两个重载也支持末尾 owner 输出；slot 必须预先为 nil。高层 `run` 继续传播带待清理 Runtime/Host 的异常，普通无 owner 错误保留诊断/整数合同。构造已经尝试过清理时，外层只移交 owner，不立即再 close；诊断对象收尾不能覆盖 pending owner。headless 在正常、check、help 和错误出口关闭 Runtime，然后关闭诊断对象；它不自动泵任务、不等待后台结果。

有 out 时，即使整数返回 0，也必须检查 owner 是否非 nil：整数保留运行状态，不表示清理完成。恢复 scope 条件后在 ordinary UI 边界显式 `owner.closeRuntime()`；成功后将 out 和保存的异常引用清空。无 out 时仅最终清理失败以异常的 some(status) 保存整数；原业务/构造异常与清理同时失败时保留原 msg/parent、none status，不能吞成整数。Win32 的 pending Host 仍必须先 destroyHost，再 closeRuntime，不能只处理共用 Runtime 字段。


Android 源码项目可在 `platforms.android` 显式配置移动入口，例如：

```json
"platforms": {"android": {"entry": "src/mobile.nim", "minSdk": 26, "targetSdk": 36,
  "versionCode": 1, "abis": ["arm64-v8a", "x86_64"]}}
```

保留桌面 `entry` 与 `include`；移动入口也必须在 include 中。移动入口 `import leaf/mobile`，并调用 `registerAndroidApplication(factory)`；资源工厂接收 `HostResources`，可在同一业务组件内读 APK assets、取得应用私有数据库路径。Android 下 `import leaf` 使用移动组件入口；桌面 `run` 不用于移动注册。`leaf init` 与完整 scaffold 的 Android 入口生成仍待后续片实现。

`leaf doctor --target android --json` 检查现有 Nim、SDK、NDK、JDK 和 Gradle；设置 `ANDROID_HOME`，可选 `ANDROID_NDK_HOME`、`JAVA_HOME`、`GRADLE_HOME`。兼容 `ANDROID_SDK_ROOT`，但两 SDK 变量必须指向同一目录。当前验证组合为 Build Tools 36.0.0、AGP 9.0.1、Gradle 9.1.0 与本机 JDK 21；工具不会自动下载依赖或接受许可证，Gradle 使用离线缓存。

`leaf build --target android` 输出 `target/android/<slug>.apk`，可用 `--output PATH.apk` 指定路径。各架构编译、Gradle 与 APK 校验都有时限，日志保存在项目 `target/android/.build-*/logs/`。Android 自动选择 native，拒绝显式 GPUI、headless 和 watch。

`leaf run --target android --device SERIAL` 构建后使用 `adb install -r` 保留数据并启动；省略 device 时必须恰有一台就绪设备。`leaf pack --target android [--binary APK] [--output DIR]` 检查包名、版本、SDK、ABI、ELF 对齐、资源和许可证，再生成 APK、许可证 ZIP 与各自 SHA256；已有发布文件拒绝覆盖。这里的 APK 是调试安装包，商店签名/AAB、API26 设备运行、arm64/16KiB 页运行仍需分别验证。SDK 归档包含 `native/android/src/main`，工具链从已安装的 SDK/NDK/JDK/Gradle 取得。
