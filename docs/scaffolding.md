# 应用架构与一键脚手架

完整应用和业务资源使用同一套页面组与路由接口。`g` 是 `generate` 的别名。

## 创建完整应用

```sh
mkdir my-app
cd my-app
leaf g scaffold
leaf --check
leaf --watch
```

生成器创建一个可以运行的首页、搜索和设置示例，包含继承式模型、页面逻辑、View、独立路由、Nim 数据库迁移 和测试。

```text
my-app/
├── main.nim
├── leaf.json
├── .leaf/scaffold.json
├── app/
│   ├── application.nim
│   ├── shell.nim
│   ├── pages/home/
│   │   ├── page.nim
│   │   ├── logic.nim
│   │   └── views/
│   │       ├── index.nim
│   │       ├── list.nim
│   │       ├── search.nim
│   │       └── settings.nim
│   ├── components/empty_state.nim
│   ├── models/task.nim
│   ├── models/application_record.nim
│   └── generated/
│       └── pages.nim
├── config/
│   ├── application.nim
│   ├── database.nim
│   ├── routes.nim
│   └── generated/routes.nim
├── db/catalog.nim
├── db/migrations/
├── assets/
└── tests/
```

`pages/` 按页面组划分。首页的主界面、搜索界面和设置面板共同持有一份状态。`logic.nim` 接收用户操作并调用 Model；`views/` 只生成界面及绑定事件。

`page.nim` 预加载 Leaf、Model 与组件，并用 Nim `include` 组合本组的逻辑和 View 文件。这些文件无需重复导入依赖。新增本组 View 时，在 `page.nim` 添加 include，并保持被调用的子 View 先于组合 View 声明。任意用户新增文件的自动发现不在这一版本中。

## 在应用中生成业务资源

```sh
leaf g scaffold Note title:string archived:bool
leaf generate scaffold Metric count:int amount:float
```

资源命令一次生成：

- `app/models/note.nim`：继承 ApplicationRecord、只读 int64 id、校验及时间字段。
- `app/pages/notes/logic.nim` 和 `views/`：列表、编辑器、详情及页面组状态。
- `app/pages/notes/page.nim`：依赖预组装与页面工厂。
- `db/migrations/<version>_create_notes.nim`。
- `tests/test_notes.nim`。

生成器自动接入页面工厂、`/notes` 路由和主窗口导航，无需手动导入或修改 shell。

字段支持 `string`、`bool`、`int`、`float`。字符串必填、最多 200 个 Unicode 码点，并去除两端空白；整数与浮点数在提交时解析；浮点数必须有限。创建和编辑失败会保留输入，取消编辑不会修改已保存数据。数据库只读或锁定等写入错误会显示在页面上，失败的完成或删除操作不会提前改变记录。输入 key 为 `notes_field_title`，按钮 key 为 `notes_new`、`notes_save` 等，列表操作 key 使用业务 id。

模型名使用单数 PascalCase，文件名使用 snake_case。复数采用简单规则：辅音加 y 变 ies；s/x/z/ch/sh 加 es；其余加 s。没有完整英语词形还原。完整模板已有 Task 模型，重复生成会被拒绝。`leaf_schema_migrations` 和 `sqlite_` 开头的表名保留给存储层。

## 路由与页面组

`config/routes.nim` 是独立的人工配置入口，默认返回自动注册的路由。可在这里增加 Route，并在 `app/application.nim` 的页面定义中接入相应 ComponentPageDefinition。

Leaf 导出以下运行接口：

```nim
ComponentPageDefinition(name: "home", views: @["index", "search"],
  build: proc(view: string): UiDescription = component(HomePage, viewIndex))
Route(name: "home", path: "/", page: "home", view: "index")

let router = newComponentRouter(ctx, routes, pages)
discard navigate(router, "home")       # 也可使用路径，例如 "/search"
discard push(router, "/search")       # 显式保留返回历史
discard pop(router)                   # 根处不变
renderPage(ctx, router)
```

页面动作（普通 home、model home 与生成的 resource 页）只通过 `State.update`/页面 `edit` 从 updater 的 current 构造隔离 candidate；`ctx.value` 在 render 中返回的快照只读，不会把被拒事件对捕获 ref 的修改带入下一次接受。数据库/服务副作用在一次普通 event 中执行一次，随后按结果 queue UI 字段，不放进可被重放的纯 updater。

路由在创建 ComponentRouter 时检查重复名称、重复路径、缺失页面与无效 View；当前地址是组件拥有的 State，页面切换与同批 State/宿主/revision 一起提交。旧 PageGroup/PageDefinition 非事务页面运行模型已删除，历史文档仅作存档。

当前路由匹配静态名称和路径；资源详情和编辑使用页面组状态与业务 id，不提供动态 URL 参数。

## 预览与冲突保护

```sh
leaf g scaffold --dry-run
leaf g scaffold Contact name:string active:bool --dry-run
```

预览只列出计划创建、更新的相对路径。生成前检查参数、字段、文件和注册冲突；已有项目目录不会被覆盖。写入路径及项目目录的祖先路径禁止符号链接。普通可捕获的写入失败会恢复原注册文件并清理本次新建文件；若系统同时阻止恢复，生成器会继续清理其余文件并报告未完成的恢复。不提供崩溃恢复或并发写入事务。

`app/generated/pages.nim`、`db/catalog.nim`、`config/generated/routes.nim` 和 `.leaf/scaffold.json` 由生成器维护，应一起提交版本控制。注册文件与清单不一致时，生成器拒绝覆盖。人工配置、已有模型、服务和 View 不会被重写。

清单保存模型名称、规范化的单数文件名、字段和迁移编号；单数文件名用于再次生成时恢复页面路径，例如 `A_B` 保持 `a_b`，不会被重新解释为 `ab`。

资源模式适用于完整脚手架应用。未修改的 `leaf init` 最小模板可先运行无参数 `leaf g scaffold` 升级；编辑过的模板不会被覆盖。自定义项目可用 `leaf db init` 安装配置，并按输出示例手动接入启动函数。

## 数据与项目配置

默认 Model 使用 SQLite，类型声明与公共持久化层共同负责校验和参数化读写；已保存记录在退出或 watch 替换进程后保留。草稿、搜索条件和显示设置属于页面状态，重启后重置。schema 2 的 int64 id 使用 INTEGER PRIMARY KEY，删除后可能复用；schema 1 继续使用原 service 与 AUTOINCREMENT。

`config/database.nim` 默认使用 `getDataDir() / <应用名> / application.sqlite3`，导入配置不会打开数据库。`createApplication()` 打开一份连接、执行迁移，再为页面创建、渲染和事件绑定连接作用域。应用自建连接在根组件的 Runtime dispose 时显式关闭；调用者传入的连接属于借用，仍由调用者关闭。数据库父目录首次打开时自动创建。

可以设置 `LEAF_DATABASE_PATH=/absolute/path/application.sqlite3` 覆盖路径；测试使用 `openApplicationDatabase(":memory:")` 获得隔离的 SQLite 数据库，再传给 `createApplication(connection)`。schema 1 也保留 service 构造函数。`--check` 也会初始化数据库，检查时请使用独立测试路径。

`db/catalog.nim` 在编译时自动发现直接位于 `db/migrations/` 的 Nim 和兼容 SQL 迁移；新增迁移不修改共享注册表。应用启动按版本执行所有未应用项，每条迁移及其历史写入在同一事务提交。`leaf db status` 检查状态，`leaf db migrate --dry-run` 预览，`leaf db rollback --steps 1` 显式回滚；启动只执行正向迁移。已应用迁移被修改或缺失时拒绝执行，历史指纹包括源文件及反向定义。详见[数据库迁移](migrations.md)。

Leaf 提供显式的 `leaf/sqlite` 模块。Linux 默认使用 `libsqlite3.so.0`、macOS 使用 `libsqlite3.dylib`、Windows 使用系统 `winsqlite3.dll`；Android 将一个 SQLite 引擎静态链接进应用，Leaf、Norm 与 lowdb 共用它。没有导入存储模块的原有应用不增加此依赖。

需要外部接口或后台工作时，将业务 API 适配放入 `app/clients/`、后台工作放入 `app/jobs/`、定时规则放入 `config/schedules.nim`、维护命令放入 `lib/tasks/`。后台执行与 UI 回传仍需实现；后台工作应使用自己的数据库连接，不跨线程共享页面连接。

`leaf.json` 记录应用元数据、Nim 编译入口与发布包含路径；其中 `include` 是打包包含规则，不是模块导入规则。`.leaf/scaffold.json` 是生成器清单，二者用途不同。发布包包含运行源文件、资源和迁移，不包含 tests、target 或 scaffold 清单。

运行生成测试时，给 Nim 提供 Leaf 的 src 搜索路径，例如：

```sh
nim c -r --path:/path/to/leaf/src --nimcache:target/test-cache --out:target/test_home tests/test_home.nim
nim c -r --path:/path/to/leaf/src --nimcache:target/test-cache --out:target/test_notes tests/test_notes.nim
```

## Android 入口

`leaf init` 生成共享应用工厂和 `src/mobile.nim`；完整脚手架使用根目录的 `mobile.nim`。`leaf.json` 中 `platforms.android.entry` 显式指向移动注册入口，桌面 `entry` 保留。新建项目的标识符会去除名称归一化产生的连字符，以满足 Kotlin 包名规则；这也影响其默认产物名。已有显式桌面配置不变。

```sh
leaf doctor --target android
leaf run --target android --device SERIAL
leaf pack --target android --output dist-android
```

Android 工厂接收 `HostResources`，从应用 assets 读取资源，并在应用私有数据目录打开 `application.sqlite3`。Activity 重建保留 Runtime 和连接；普通 detach 不关闭应用。正常 Runtime dispose 会关闭应用自有连接，强制停止进程不证明优雅关闭。调用者注入的连接和 HostResources 仍由调用者或宿主拥有。

Android 与 Windows 原生模板使用变量行纵向列表；Android 行内按钮纵向排列，以适应窄屏。桌面 GPUI 模板保留原有滚动布局。Android 编译需要预先安装的 SDK、NDK、JDK 与离线 Gradle 依赖；生成器不会安装工具。当前 pack 交付 debug APK，不是商店发布。

## Model 与连接作用域

新应用清单为 `schema: 3, model_schema: 2, model_api: 1, timestamps: true`，迁移编号保存为十进制字符串。`ApplicationRecord` 继承 `TimestampedRecord`；每个具体模型用 `defineModel` 声明表名、校验和回调，共享保存、查询、删除、dirty tracking 与事务能力。常规 CRUD 不生成 service。

```nim
import leaf/model
import ./application_record

type Note* = ref object of ApplicationRecord
  title*: string
  archived*: bool

defineModel(Note, table = "notes"):
  validates title, presence = true, maxLength = 200
  scope active, it.archived == false

# 位于应用执行作用域内，无需传 db。
let titles = Note.active.where(it.title.contains("中文")).pluck(it.title)
let first = Note.first  # Option[Note]，默认按 id ASC
let last = Note.last
let records = Note.all # seq[Note]
let total = Note.count # int64；count/exists 忽略排序与分页
transaction:
  let note = Note.createOrRaise(title = "事务内创建")
  note.archived = true
  note.saveOrRaise()
```

启动时打开并迁移数据库一次，在 `withDatabase` 内建立 ComponentRouter 与 ComponentPageDefinition。`createApplication(database = nil)` 保留测试注入接口；组件页面构建与 Application.executionScope 绑定同一连接，覆盖事件、延迟列表行和验证器。直接使用 Model 的后台任务须自行打开连接并进入同步 withDatabase，不能跨线程复用连接或跨 await 保留作用域。

页面 Draft 是独立值类型，编辑先查询完整 Model，再赋值及 save。校验失败返回 false，保留输入并显示 errors.fullMessages；数据库失败抛异常，页面显示错误。取消编辑不改变已存数据。详情和编辑主键为 int64。

## schema 1 兼容与人工升级

已有 schema 1 清单继续生成原来的值模型、service、int id 和迁移；生成器不会自动升级或改写历史 SQL。schema 2 缺少 model_api/timestamps 或版本未知时拒绝生成。升级须先改应用基类、声明、页面和连接作用域，再核对生成注册文件与清单，最后用新迁移补齐旧表时间字段：

```sql
-- 新增 002_task_timestamps.up.sql，001_create_tasks.up.sql 保持原样。
ALTER TABLE tasks ADD COLUMN created_at REAL;
ALTER TABLE tasks ADD COLUMN updated_at REAL;
UPDATE tasks SET
  created_at = CAST(strftime('%s', 'now') AS REAL),
  updated_at = CAST(strftime('%s', 'now') AS REAL);
```

将新迁移放入 `db/migrations/`，catalog 自动发现；模型使用 Option[DateTime] 接收时间值，未来写入由框架补齐 UTC 时间。schema 2 新表的时间字段为 REAL NOT NULL。如需对旧表补 NOT NULL 约束，另建迁移重建表。新表用 INTEGER PRIMARY KEY，删除后的 id 可能重用；原 schema 1 AUTOINCREMENT 语义保持不变。

完整 API 与事务失败语义见 [Model 文档](models.md)。
