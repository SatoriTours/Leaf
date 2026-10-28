# Leaf 绘图、交互与动画：统一 API 设计

状态：用户已批准按方案实施，当前为未完成的开发版本。组件／托管草稿及基础 Canvas 已有共享和真实 Windows 自测；SDK C COM 桥接已编译链接，Counter／Canvas 入口键鼠、96 DPI 绘制／调整大小和截图已验证。交互动画、性能及独立验收仍未完成；注入 HRESULT 的恢复测试不代表实际 GPU 设备丢失。详细范围见 `graphics-animation-plan.md`；不提交发布。

检查基线：`c0686db`。现有 `defineComponent`、`componentView`、State 候选提交、typed Host 增量及 Win32 原生控件继续保留。

## 1. 目标与范围

用户目标：写法简单、高效、人读起来舒服；绘图 demo 同时用于功能验证和可重复性能测试。参考为 https://x.com/huacnlee/status/2114337681157067174 ，目前无法取得视频，不宣称已理解／复现该效果。

推荐：普通 Nim 控制流 + 少量编译期 DSL。避免全命令式样板，也不引入运行时解释语言。Canvas 是一个原生宿主区域，图元不是 HWND 或独立 Leaf UI 节点。

首期范围：组件语法糖、State 简写、二维 Canvas、基本图形／路径／系统字体文本、矩形裁剪、组变换、鼠标点击／悬停／拖动、Canvas 键盘入口、属性过渡、可控制 tween、实验室 demo 与跑测。

不包含：任意原生控件旋转／透明合成、3D、完整 SVG、滤镜、图片解码管线、任意遮罩、通用布局动画、spring、触摸／多指／手写笔、跨平台 GUI、每个图元的 UI Automation 节点。新增能力逐项声明，不以静默换渲染器支持。

下列代码是统一目标 API；不能据此推断全部已实现。当前组件与基础 Canvas 的可运行共享样例见 `examples/simple_counter.nim`、`examples/simple_canvas.nim`；事件、动画及性能实验室仍待实现，语法／headless 检查不能替代 Windows 实跑。

## 2. 统一组件写法

```nim
import leaf

component Counter:
  state:
    count = 0

  view:
    column:
      padding: 24
      gap: 12

      text count

      button "增加":
        onClick:
          count += 1

      button "重置":
        onClick:
          count = 0

when isMainModule:
  quit(run(Counter, title = "Leaf 计数器"))
```

- `component` 生成现有组件定义、挂载初始化、render 和稳定类型身份，不另建 Runtime。实例仍可通过既有 `component(Counter, props, key=...)` 装配；无 Props 的组件生成空 Props 适配，实例不共享 State。
- `state` 和 `animation` 是每个挂载实例的一次性声明，不是每次 render 初始化；初始化表达式只读初始 Props。Props 更新不会自动重置状态，换 key／类型或真正卸载再挂载才重建。
- 应用入口提供 `run(Counter, title="...")` 的无 Props 便捷重载，以及 `run(Meter, propsValue, title="...")`；内部仍创建既有 componentApplication 并走原生 run，返回退出码，不生成第二套启动流程。旧 `run(app)` 不变。
- 第一版组件允许无参声明或显式单一 Props 类型声明 `component Meter(props: MeterProps):`；不引入隐式双向 Props 写入。`view` 内用普通 `props.field` 读取本次 Props。
- 恰好一个 `view` 和一个根；`state`／`animation` 可省略。同名声明、未知属性、错误嵌套及重复属性指向用户源码报编译错误。
- `view` 中禁止状态写入与动画控制副作用；宏不会把普通文件／数据库副作用变成可回滚操作。复杂计算使用普通纯函数和局部变量。
- `if`、`case`、`for`、`let`、普通函数继续使用 Nim，不另造循环、表达式和字符串绑定语法。

### 2.1 托管变量：直接读取与赋值

经用户后续确认，默认不再写 `.value`／`.set`：view 中直接 `count`；事件中 `count += 1`、`count = 0`、`enabled = not enabled`、`position += e.delta`。这不是把旧 State 的方法机械换名，而是增加事件批内草稿。

- view 读取当前候选值，且只读；事件读取所属 UI 批次的草稿值，尚无草稿时以该状态本批起点初始化。不能捕获创建事件时的候选 ctx，也不依赖全局隐式 ctx。
- 同一事件中 `count = 0; count += 1; count += 1` 后读取 count 必须为 2。同一最外层 UI 任务中的多个回调对同一状态共享有序草稿，不能各从旧接受值覆盖。
- 草稿只在所属 Runtime／普通 UI 任务内有效；批结束后进入现有候选校验／prepare／apply／accept。提交前不修改已接受状态，失败批消费并丢弃，不重放事件；文件／数据库等普通副作用不随失败回滚。
- 新宏按有类型的词法绑定识别托管变量，不按字符串名字替换；普通局部变量及同名遮蔽遵循 Nim 规则。属性赋值、数值／Vec2 的 +=／-=、索引读取先做类型校验；复杂更新可以由普通纯函数计算新值后赋值。
- 普通辅助函数接收值快照；托管绑定不自动变成 `var T` 参数，不允许靠传 var 地址绕过草稿。不可变值可安全跨函数，worker 不可捕获托管绑定／Runtime。
- 旧 State[T]、ctx.value／read／set／update 的公开语义不变；新托管绑定不隐式转换成 State[T]。第一版不开放同一状态同时经草稿和旧排队 updater 写入；需要原始 State 的既有高级代码继续用显式 defineComponent，不假装两种时序已经兼容。
- 坐标二元组按属性类型转换为不可变 Vec2；托管坐标初值用 vec2(...)。可变引用／容器仍需安全 snapshot／equal；高级初值配置可写 `items = stateValue(initialItems, snapshot=copyItems, equal=equalItems)`。不支持的原地深层修改报错，首期通过新值赋值更新，不允许引用泄露修改接受值。
- disposed／跨 Runtime／render 阶段写入仍被拒绝；旧实例事件不交给新实例。草稿与清理、嵌套 UI scope、失败门以及 accept 分配围栏的实际接线是实现前工程验证项，不能靠宏表面语法声称已经成立。

### 2.2 显示入口自动接受数字

`text count`、`text name` 是默认写法。text 接受 string 和标量整数／浮点数，数字在明确的显示入口用稳定的标准字符串格式转换；不引入全局隐式数值／字符串转换。

普通计算和判断仍保持原类型。文字拼接可写 `text "计数：" & $count`，或显式导入 Nim 的 strformat 使用 fmt；不把普通字符串里的花括号自动解释为绑定。bool、枚举、业务对象需要显式选择显示文本，避免自动 dump 内部内容。

### 2.3 兼容与事件块

现有 API 和 `componentView` 语义保持。新 `component` DSL 内 `onClick:` 总是延迟执行的事件体，`onClick(e):` 额外绑定事件参数。不在 render 时执行这个代码块。

旧 `onClick: callback` 是已有 callback 值的属性写法，不在旧宏里静默改义。新 DSL 复用已有函数时明确写 `onClick(e): callback(e)`；迁移示例说明两者区别。

## 3. 绘图语法与坐标

```nim
canvas:
  width: fill
  height: 360
  viewBox: (640, 360)
  background: "#101820"

  rect:
    position: (24, 24)
    size: (592, 312)
    radius: 16
    fill: "#1B2936"

  circle:
    center: (120, 180)
    radius: 20
    fill: "#5ED5B0"

  path:
    stroke: "#5ED5B0"
    strokeWidth: 3
    moveTo (60, 260)
    curveTo (180, 260), (220, 80), (560, 80)

  text "Leaf":
    position: (48, 48)
    size: 16
    fill: "#FFFFFF"
```

- 布局：普通数值为 DIP。裸写 `width: fill` 是占满可用宽度的布局关键字，即使组件状态或局部变量也叫 `fill`，仍按此关键字解释；`width: (fill)`、`width: fill * 2` 则是普通 Nim 值表达式。它不是颜色字符串；Canvas 默认 width=fill，高度由自身或父布局明确给出。Canvas 必须得到有限正尺寸，不能用循环内容尺寸推导。
- 省略 viewBox 时绘图坐标也是 DIP；指定后坐标是设计空间，默认等比 contain、居中、边缘留白。设计空间外不参与绘制与命中；需要其他适配模式另作显式 API，不默认拉伸。
- `position` 为左上角；`center` 为圆心；`size` 为宽高；角度使用 `deg`；无隐式 DPI 乘法。`radius`／宽高／描边不得为负，坐标／矩阵不得有 NaN 或 Infinity。
- 基本图元为 rect（含 radius）、circle、line、path、text；路径含 moveTo、lineTo、curveTo、closePath。路径默认无 fill／stroke，至少显式提供一项；其他面图形默认主题前景填充、无描边；line 必须有 stroke。stroke 默认宽 1 设计单位。
- 几何必需字段为 rect 的 position／size、circle 的 center／radius、line 的 start／finish；缺失字段报错而非猜测。path 默认非零绕数填充，可用 `fillRule: evenOdd` 表达孔洞，绘制和命中共用规则。描边默认 flat cap、miter join／limit 10，后续可显式扩展，不让平台默认值改变跨测试结果。
- 绘制顺序为源码顺序、后画在上。不引入额外 zIndex 排序机制。
- 颜色接受类型化 Color 或 `#RRGGBB`／`#RRGGBBAA`。字面量编译期校验，动态颜色在 prepare 校验／转换，不在每条原生绘制调用中反复解析字符串。
- Canvas 内 `text` 编译成绘制文本，Canvas 外 `text` 仍是原生文本控件；上下文类型明确，不能嵌入原生输入控件到图形 group。文字使用 DirectWrite 系统字体、Unicode shaping／回退，首期无富文本／编辑／自动换行承诺。position 是文字布局盒左上角。
- 文本／透明颜色变化不自动提供可访问语义。背景透明度仅在 Canvas 自身绘图表面内合成，首期不支持穿透显示兄弟 HWND。

### 3.1 组合、裁剪与变换

```nim
group:
  translate: (200, 120)
  rotate: 30.deg
  scale: (1.2, 1.2)
  clip: (0, 0, 160, 120)

  circle:
    center: (40, 40)
    radius: 20
    fill: "#5ED5B0"
```

组内局部原点默认 (0,0)，变换固定先 scale、再 rotate、再 translate，嵌套组从内到外组合。clip 为组局部矩形，随组变换；作用域自动恢复，不要求手工 save／restore。首期描边也随变换缩放，无 non-scaling-stroke 承诺；零缩放／不可逆变换不参与命中。

## 4. 图形事件

```nim
component DraggableDot:
  state:
    position = vec2(120, 120)
    selected = false

  view:
    canvas:
      height: 240

      circle:
        center: position
        radius: 20
        fill: "#5ED5B0"

        onClick:
          selected = not selected

        onDrag(e):
          position += e.delta
```

- 事件：onClick、onEnter、onLeave、onDragStart、onDrag、onDragEnd、onDragCancel；Canvas 另外提供 onPointerDown／Move／Up、onWheel、onKeyDown。原始事件不是普通拖动的前提。
- 指针事件字段包括 pointerId、button／buttons、modifiers、position（目标父坐标）、localPosition（目标局部坐标）、canvasPosition（设计坐标）、delta（当前父坐标中的屏幕位移向量）。向父组冒泡时重新换算 position／localPosition，target 保持初始目标。
- hit test 从上向下遍历可接收事件的几何，使用填充实际区域／描边区域、裁剪和变换，不只使用 bounding box。文本首期按文字布局盒命中，不承诺字形轮廓命中。
- 纯装饰图形默认不拦截；带事件的 group 可命中可见子几何并接收冒泡。`hitTest: false` 明确让当前图形／组子树穿透。背景未命中图元时可交给 Canvas。
- onClick／原始指针事件从目标向 group、Canvas 冒泡，`e.stopPropagation()` 只停止本次冒泡。Enter／Leave 是边界变化通知，不冒泡；拖动事件交付捕获 owner，不在移动时转移到其他图元。
- onDrag 自动处理鼠标捕获。默认主按钮，超过 Windows DPI 感知拖动阈值才开始；首次 delta 含从按下到越过阈值的全部位移，随后为相邻实际样本位移。Move 合并保留累计位移。
- delta 将屏幕指针位移向量用当前父变换逆矩阵换算，不把父动画自身位移当作指针位移。变换不可逆则取消。普通拖动默认即时跟手；位置不得默认套缓动。
- 完成拖动不再产生 click；未达阈值且有效主按钮抬起命中同一绑定才 click；End 与 Cancel 对一次开始最多各路径二选一，丢捕获／失焦取消。
- owner 仍有效时 Cancel 在普通 UI turn 交付；卸载／关闭立即退役捕获和队列，不在 dispose／绘制回调执行业务，也不向已销毁 owner 发送 Cancel。
- 事件绑定使用 session／mount／图形 binding generation／frameId 检查，过期事件不交给新实例。错误处理按现有 Runtime 候选失败与故障门，不自动重放。
- 命中依据最近成功绘制帧的几何快照，而非尚未画出的目标值；本实现不能据此声称知道显示器扫描时的真实物理画面。首次成功绘制前无图形命中。

### 4.1 身份、键盘与可访问性

静态位置身份无需处处写 key；循环中会重排且带交互／transition 的图形必须提供稳定 key，同父级重复 key 拒绝。纯批量几何不必建交互身份。换父／类型／key 取消旧交互与动画，不继承旧捕获。

Canvas 可声明 `focusable: true`、`accessibleLabel: "..."` 并使用 onKeyDown；焦点、Tab、失焦取消需要真实 Windows 验证。首期 demo 的播放／暂停／重置和选择操作同时提供原生控件／键盘等价入口，不提供只能靠悬停发现的关键功能。

不宣称每个 circle 已成为可被屏幕阅读器独立遍历的控件。完整虚拟图元焦点／UIA provider 是后续能力，必须单独实现及现场验收。

## 5. 两种动画

### 5.1 状态变化：transition

```nim
circle:
  center: position
  radius: (if hovered: 28 else: 20)
  fill: (if selected: "#5ED5B0" else: "#667788")

  transition:
    properties: [radius, fill]
    duration: 180.ms
    easing: easeOut

  onEnter:
    hovered = true

  onLeave:
    hovered = false
```

- 目标值仍来自被接受的 State／Props。transition 仅在新目标被接受后启动；失败候选不能启动动画或覆盖正在显示的动画。
- 不列 properties 时覆盖本图元支持的可插值属性：position／center／size／radius／fill／stroke／strokeWidth，以及 group translate／rotate／scale。首期不插值 path 几何、文本内容、key、clip 或任意数据结构。显式列出不支持的属性报编译错误；未列清单时这些属性直接切换。
- 首帧直接显示初值，无隐式入场动画。中途改目标从当前采样显示值续接；颜色按明确的线性光、预乘 alpha 规则插值，再转后端格式，避免透明边缘黑边。rotate 按标量角度插值，不暗中选最短路径。
- duration 默认 180.ms、easing 默认 easeOut；零时长直接切换，负数／非有限时长拒绝。默认不动画业务 State、不每帧写回目标值。
- drag 直接控制的属性建议排除在 properties 外。一个属性只能由一个动画来源驱动；显式时间轴值与 transition 同时驱动同一属性时拒绝，不叠加两层缓动。

### 5.2 持续运动：animation

```nim
component MovingDot:
  animation:
    x = tween(
      60.0, 580.0,
      duration = 1200.ms,
      easing = easeInOut,
      repeat = pingPong,
      autoplay = true
    )

  view:
    column:
      canvas:
        height: 240
        viewBox: (640, 240)

        circle:
          center: (x, 120)
          radius: 16
          fill: "#5ED5B0"

      button "暂停":
        onClick:
          x.pause()
```

- 本轮收敛建议：animation 绑定在 view 的数值表达式里直接写 x，表示本帧采样值，不再要求 x.value；事件中的 x.play()／pause() 等保留显式控制方法，x 不可直接赋值。数值读取与控制接收者由宏类型和词法位置区分，不注册全局 converter；辅助函数得到采样值，不得到动画 owner。
- tween 端点统一使用前两个位置参数，duration／easing／repeat 等控制参数保留命名；避免 fromValue／toValue 冗长，也不同时维护多套端点别名。
- 初始化一次，默认 autoplay=false、easing=linear、repeat=once；有限次数写 `repeat=times(3)`，另支持 forever、pingPong（无限往返）。首期插值类型为标量、Vec2、尺寸和 Color，端点类型必须一致。
- play：从暂停处继续；已结束则保持终点，重新开始须 restart。pause：保留当前采样位置。restart：重设当前播放周期并播放。reset：停止回到起点。seek(0..1)：定位当前单程，不改变播放／暂停状态。越界 seek 拒绝，不静默截断。
- 有限 repeat 的次数按单程计数；每个 tween 的 duration 是单程时长。有限动画自然结束可有 onFinish，once／有限次数结束每个播放 generation 最多交付一次；seek／reset／取消不触发 Finish。无限往返无 Finish。
- 动画控制在普通 UI 任务排队，与本 turn 的状态／Host 更新一起接受；候选失败保留原控制状态，不在 render／原生绘制回调立即执行控制。onFinish 在普通 UI turn 交付并检查 owner/generation，不在绘制／accept 中执行业务回调。
- Finish 交付最多尝试一次：回调抛错或其普通 UI turn 被拒时，托管 State／Host 草稿回滚并传播错误，但当前回调不自动重放，避免重复无法回滚的外部副作用；尚未尝试的其他 Finish 保留。此情形与“自然结束候选帧失败不消费 Finish”区分。
- 单调时钟按实际时间采样；不以 tick 次数累计位置。UI 忙时合并过期请求，直接采样新时间，不逐帧补跑业务事件。
- 同一窗口共享调度。最小化、已知隐藏页面停止请求帧并冻结活动时间；恢复从冻结位置继续，不积压回调。部分遮挡不能可靠判断时不声称已停止 GPU 工作。
- seek 控制后下一次成功帧应包含定位结果；pause／reset 是逻辑控制接受，不等于屏幕已显示。页面卸载取消；retainState 隐藏页冻结动画，恢复续播。owner 销毁后所有帧请求与 Finish 退役。
- 当前 Win32 普通应用默认在 owner 挂载前只读查询系统减少动态效果设置（SPI_GETCLIENTAREAANIMATION）：非必要 transition 直接切换、非必要 autoplay 不自动开始；用户显式播放仍可操作。应用可显式选择 full／reduced 策略；跑测冻结并记录策略，不能把禁用动画后的帧率当成相同工作负载。headless 无桌面偏好来源，system 按确定性 full 处理；可显式传 reduced 测试，不声称跨平台系统偏好已接入。

## 6. 简洁 API 的实际成本

Canvas DSL 编译成类型化帧命令、资源引用、交互元数据和绑定标识，不生成每个圆一个组件，不在运行时解释 Nim 源码。帧命令不跨平台边界携带业务闭包、Node 引用或 HWND。

- transition 的已准备图元属性可直接时间采样，不要求每帧重新运行用户 view。当前实现将逻辑目标与 presentation/anchor 一起保存在现有 managed Instance；普通共享帧泵复用 State/Host 同一提交边界，失败帧不发布 presentation，后续成功帧从已接受 anchor 追赶。仍需 O(Canvas 图元＋transition 属性) 的 typed frame 采样／验证／传输，不等于 O(1) 或已测性能。
- 当前 `transition:` 支持 `properties`（静态属性列表；省略则当前图元全部可过渡属性）、`duration`（默认180.ms）、`easing`（默认easeOut）。初始／新key直接显示；group保留translate/rotate/scale分量，rotate按标量插值而非矩阵反解或最短角。fill/stroke只有Some→Some插值，缺失／重新加入直接切换；不做入场动画。循环中的过渡图元必须有稳定key。
- 同属性的可见tween表达式／词法别名由宏拒绝；普通共享采样帧中仍改变的transition目标在提交前拒绝，覆盖不透明数值helper的连续双驱动。不是任意Nim全局／跨组件数据流的静态污点分析；不同属性的tween与transition允许在同一帧同一提交中更新。别名检查保守：同一作用域内被标记为tween来源的局部变量，不尝试证明后续普通赋值消除了来源；可改用新的局部名称。
- 如果调用者捕获双驱动拒绝后仍反复调用pump，每次都可能再次拒绝：整帧回滚也包括tween采样，系统不会为了消除错误自动改写已接受动画为停止状态；应修正驱动声明，或显式暂停／关闭。presentation字节预算保守计入显示帧，即使它暂与target共享存储，也不把预算当真实驻留内存测量。
- 显式 tween 参与任意 Nim 表达式时，不能承诺编译器自动分析并只改一个字段。Canvas 作为独立受管理更新边界，在普通安全 turn 重算其必要绘图描述；循环构建 N 个动态点仍可能是 O(N)。动画用于 Canvas 外文字／布局时，走所属组件正常局部 render，明确计入成本。
- Canvas 更新边界在父 render 时接收新 Props／值快照，不能持有失效候选 ctx；帧构建必须进入当前 Runtime 作用域。无法安全隔离的捕获在编译期诊断，不隐式提升为全 App 每帧刷新。
- 不变资源可以复用；任意 Nim 函数不自动 memo、不跳过可见业务求值。路径内容、字体、DPI、目标设备 generation、裁剪和变换的缓存键／失效条件分别明确。
- 同一个 tween 多处读取共享时钟；CPU 采样可以重复但不能每次读值推进时间。数据量大的场景可使用 draw(c)／批量图元接口，它们进入同一提交、资源与交互管线，不另建绘图引擎。
- 零分配、只更新一个属性、O(1) 命中均不是未经实测的保证；报告实际分配、命令数、重算范围和资源增减。

## 7. 原生接入、预算与失败处理

推荐首个 Windows 后端为 Direct2D HWND render target，文本使用 DirectWrite。只依赖 Windows 原生图形 API；Nim／MinGW 的头文件、接口调用约定、链接库和实际硬件能力先做有界验证，再实现完整功能。

静态命令／元数据通过扩展现有 typed Host 协议接入 prepare/apply/accept；动画 presentation 资源属于同一 Host／Canvas owner，不形成第二个业务 Runtime。受管理帧构建也遵循普通安全 turn，不在 WndProc 里调用应用渲染。

- prepare 校验数据、额度、绑定与能力，准备所需资源；accept 仅发布已准备元数据，保持现有不得执行业务、不得新增分配的边界。
- 重绘和动画帧不凭空增加业务 State revision；独立 frameId 标识最近成功绘制的命令／命中快照。业务接受不等于 EndDraw 成功，也不等于实际显示完成。
- apply 失败沿用已接受描述恢复或进入故障门；操作系统绘图不是原子事务，不承诺撤销已画出的像素。候选描述、时间轴控制和交互绑定不能提前接受。
- EndDraw 失败不发布成功 frameId／命中快照。设备目标失效退役设备相关资源，在下一普通 turn 最多尝试一次重建；仍失败报告明确故障／冻结，不无限重试、不静默切到 GDI／软件后端。
- 硬件／软件渲染是显式启动配置并记录实际模式；硬件不可用时硬件模式报不支持。软件模式结果不得混入硬件性能基线。
- 初始有限额度：单帧最多 100,000 绘图命令、250,000 路径段、16 MiB 自有帧数据；10,000 交互绑定；单 Canvas 自有接受帧／候选帧／资源缓存合计 64 MiB CPU 数据；表面每轴不超过 16,384 物理像素且总像素不超过 32,000,000，并受设备更小限制约束。各限制同时成立，显式超限拒绝，不能靠删图元／降采样通过。GPU／驱动实际内存另记，不以 CPU 上限冒充 GPU 精确预算。
- 指针队列有界，首期上限 256；Move 可合并且保留累计 delta。不能容纳关键 Up／Cancel 时退役相应捕获并报告输入溢出故障，不能永久卡在 dragging，也不能默默丢释放消息继续成功运行。
- CPU 缓存有界淘汰不改变画面。关闭时先停止帧调度、取消捕获与事件绑定，再释放目标／资源／Canvas；失败保留 owner 供既有清理机制处理，不声明已关闭。
- 非 Windows GUI 明确不支持；headless 可校验 DSL 降低结果、时间采样、命中几何和命令数据，不能代替实际绘制。

## 8. 实验室 Demo 与性能规程

`examples/graphics_lab/` 复用同一场景构建逻辑，提供演示、能力检查、压力测试三种模式。默认先做可点击／拖动／过渡／持续运动的二维交互场景；这不是尚未取得的视频的等效复现。视频取得后单独冻结其视觉清单，不阻塞通用 API 设计。

- 功能模式：时间轴定位、暂停／单步、参数调整、原生按钮／键盘等价操作、窗口缩放、正常关闭。
- 压力档位初定 100／1,000／10,000 对象，每档冻结图元类型、路径段数、透明度、交互绑定数量与动态比例。图形数不能冒充实际提交数；记录两者。
- 三类负载：固定帧重绘；固定几何只改变换／颜色；每帧重建几何。分别定位后端、属性采样／提交和路径构建成本。
- Release、固定 seed／场景版本／像素大小，默认预热 5s、采样 30s、独立进程重复 3 次；时长／次数有界可配置，进程超时视为失败。采样完成功清理才输出完整报告，退出 0 与报告完整同时必要。
- 采样使用预分配缓冲，逐帧不写磁盘／不刷新统计 UI；结束输出 JSON／CSV。低频演示 HUD 与正式跑测分离，并记录观测开销。
- 分段记录动画采样、几何生成、框架校验／提交、资源更新、CPU 绘制提交耗时；frame interval 的 p50／p95／p99、超预算比例、实际帧数；CPU／内存／图形资源及多轮创建关闭后的变化。
- 分开统计请求数、构建数、绘制成功数、合并数。首期 HWND target 的 EndDraw 时间不能称为 GPU 执行时间；调用间隔不是显示器实际呈现 FPS。没有可靠呈现观测时显示未知，需要更强呈现测量时另接 DXGI 路径。
- 记录代码内容 hash、编译器、Release／内存管理模式、OS、GPU／驱动、实际硬件／软件模式、刷新率、DPI、窗口物理尺寸、远程桌面／VM。窗口最小化或测试环境变化的样本无效，不当性能提升。
- 无冻结硬件／场景实测前不承诺任意 10,000 对象稳定 60 FPS。16.67ms 仅是 60Hz 候选帧预算；正式门槛按确认测试设备／负载冻结。基线比较必须参数与环境相容。

## 9. 分期与必需验收

一个实现负责人连续交付完整切片，不按文件拆散写端；现有 checkout 默认复用。以下是范围顺序，不是本次实现授权。

1. 语法与 Canvas 闭环：新宏降低到既有组件／State，旧 API 回归；基本图形／文本、真实窗口、DPI、重绘、资源上限、创建失败与关闭。
2. 交互与动画闭环：命中、捕获、冒泡、键盘入口、transition、tween、取消／隐藏／恢复；完整交互 demo，不用纯内部测试代替真实入口。
3. 性能与交付闭环：冻结工作负载、跑测／报告、回归预算、独立功能／视觉／性能验收与使用文档；按视频补充实际参考场景。

必需测试矩阵：

| 范围 | 核查项 |
| --- | --- |
| 语法与类型 | 全部示例、嵌套 if／for、Props／多实例、命名冲突、未知属性、旧 callback 写法、源码错误位置；编译期语法解析不替代真实类型／运行检查 |
| State／事务 | 候选读取、事件延迟执行、连续赋值／累加及读己之写、同 UI 批草稿顺序、旧接口隔离、不可变快照、失败不重放、disposed／跨 owner／Runtime 边界 |
| 绘图 | 路径闭合／孔洞、描边／文字、alpha、变换顺序、裁剪、零尺寸／超限、缓存失效；真实截图语义视觉检查 |
| 输入 | 重叠／穿透／组冒泡、clip、旋转／viewBox／DPI 坐标、拖出窗口、合并 delta、click 抑制、丢捕获、取消、动态 key 重排、卸载后旧事件、队列溢出 |
| 动画 | 首帧、零时长、重定向连续性、暂停／继续／seek／reset／restart、重复次数、唯一 Finish、失败提交、绑定冲突、忙帧、最小化／隐藏冻结、owner 退役 |
| 平台与资源 | Windows 100／150／200% DPI 和必要跨屏、正常关闭、设备目标重建失败、HWND／COM／CPU／图形缓存收支、多轮创建关闭无持续增长 |
| 可使用性 | 原生按钮及 Canvas 键盘入口、焦点提示、缩放、关键功能不依赖颜色／悬停；未实现的图元 UIA 明示 |
| 性能与兼容 | 三类负载、实际硬件元数据、完整报告、采样开销、业务局部更新、旧表单／列表／导航／任务关键回归 |

实现自测后必须独立验收关键路径与必要回归；先核授权、Windows／视觉／输入等能力，缺环境标阻塞。当前仅设计自查，未运行产品编译／GUI／性能测试，不能把本文或语法探针当功能通过。

## 10. 本轮自查纠正与剩余边界

已在设计中纠正：候选读取／事件草稿与真实接受的区别、tuple 与 Vec2 运算、旧 callback 兼容、动画冲突与事务、拖动阈值／取消／坐标、最近绘制帧而非真实扫描画面、任意表达式的 O(N) 成本、键盘／UIA 边界、额度／设备故障、隐藏时钟、真实性能口径。

后续 API 简化：用户已认可托管变量和 text 自动显示数字；新增默认建议为动画直接采样及 tween 位置端点。不再增加状态符号前缀、自动字符串模板、所有值的全局 converter、同义属性简称或第二套循环语法。已有宽度／描边／transition 默认值继续沿用，可省略默认参数；动态有状态对象的 key、重复策略和 autoplay 等影响行为的选择仍显式保留。

实现前的工程验证门：新宏及真实类型检查、Nim／MinGW 调用 Direct2D／DirectWrite、Canvas 子边界与候选所有权、现有 accept 分配围栏、Windows 能力与独立验收通道。验证失败先报告或修订工程方案，不擅自换引擎／安装环境。

外部未确认项仅影响效果对齐：参考视频／截图尚未取得。精确视频场景和固定硬件性能门槛不能先声称已完成；不需要用户重复批准已认可的整体 API 方向。

### 本轮实际检查证据

- 最新简化版的 Nim 2.2.6 parseStmt 检查：本文 6 个 Nim 块、一个 Props 声明及一个连续草稿读写示例，共 8 个样例全部解析成功，检查进程退出 0。只验证解析，不解析到真实新 API、不证明草稿语义、类型检查／宏展开正确；早期 7 样例结果仅对应先前版本。
- 设计探针与日志：`~/.local/state/agent-artifacts/leaf/2026-10-26-graphics-api-design/`。没有启动 Windows、GUI、服务或子 Agent；临时探针目录已移除，保留单份探针与必要日志。
- 本文是设计自查结果，不是独立验收结论；尚未进行产品构建、功能测试或性能测量。

### 实验室功能入口（2026-10-28，正式测量仍开放）

`examples/graphics_lab/main.nim` 提供时间轴、参数、键盘及交互圆点；`scene.nim` 共用三类固定seed负载，详见同目录README。DSL新增 `path: geometry: sealedPath` 保留原PathData的fillRule，不得混路径命令／另设fillRule。演示循环仍重建Canvas描述，含HUD及键盘绑定；不能把其开销当正式producer，5s预热／30s采样／3独立进程和JSON/CSV仍待实现。


### 正式CPU侧基线（2026-10-28，限定Windows软件VM）
无HUD producer及协议见 `benchmarks/CANVAS_PERFORMANCE.md`。固定九负载×三个独立
Release ORC进程，均5s预热／30s采样，27个actual exit0，raw／CSV／环境／工具链内容
身份及每process p95后取三次中位数已独立验收。10k对象static/properties/geometry的
CPU侧wall p95中位数为9.4485／26.7422／28.1029ms，动态已超16.667ms预算。
staticFrame `builds=0`仍重绘accepted帧并有EndDraw；不把静态缓存当“零绘制”。
GPU时间／显示FPS仍null；低负载interval受OS唤醒粒度影响，不是呈现FPS。tracked
native计数回基线，不等于所有进程缓存归零或长期无泄漏。当前只有首份兼容正式基线，
无跨版本性能改善结论；全仓历史timeout及高DPI／硬件／AT／视频缺口不变。
