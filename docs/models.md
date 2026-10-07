# Model

`leaf/model` 提供继承式 SQLite Model，基于锁定的 Norm 2.8.7、lowdb 0.3.0 和 db_connector 源码。业务对象继承 Leaf Record，Norm 只接收生成的独立存储对象。导入模块和声明模型都不打开数据库。Leaf 默认导入仍不包含 ORM。

## 定义与共同能力

以下声明对应已编译的 `tests/nim/model_fixtures.nim`：

```nim
import leaf/model
import std/strutils

type ApplicationRecord* = ref object of TimestampedRecord
  category*: string

proc normalizeCategory(record: ApplicationRecord) =
  record.category = record.category.strip()

defineAbstractModel(ApplicationRecord):
  validates category, maxLength = 200
  beforeValidation normalizeCategory
  scope home, it.category == "home"

type Task* = ref object of ApplicationRecord
  title*: string
  done*: bool
  priority*: int

proc normalizeTitle(record: Task) = record.title = record.title.strip()

defineModel(Task, table = "tasks"):
  validates title, presence = true, maxLength = 200
  beforeValidation normalizeTitle
  scope unfinished, it.done == false
```

层次是 `Record → TimestampedRecord → ApplicationRecord → Task`。所有模型共享 CRUD、连接作用域、errors、dirty tracking 和事务；抽象基类还可声明公共字段、校验、回调和 scope。具体模型不能再作模型的父类；首版不提供 STI 或关联。

持久字段支持 string、bool、int、int64、float、DateTime 和它们的 Option。未支持字段、重复字段、未知校验字段和具体模型继承在编译期报错。`id` 是框架管理的只读 int64；TimestampedRecord 的 created_at/updated_at 是 Option[DateTime]，保存时框架维护 UTC 时间，SQLite 存储 REAL Unix 秒。构造/更新参数只能指定业务字段。

## 配置与免 db 调用

迁移由现有 `leaf/sqlite` 管理，模型不自动建表。SQL 示例按上述字段建立表：

```nim
import leaf/sqlite
let db = openDatabase(":memory:")
db.executeScript("""
  CREATE TABLE tasks (
    id INTEGER PRIMARY KEY, title TEXT NOT NULL, done INTEGER NOT NULL,
    priority INTEGER NOT NULL, category TEXT NOT NULL,
    created_at REAL NOT NULL, updated_at REAL NOT NULL
  );
""")
withDatabase(db):
  let task = Task.build(title = "买牛奶", category = "home")
  task.saveOrRaise()
  let saved = Task.find(task.id)
  saved.done = true
  saved.saveOrRaise()
db.close()
```

应用通常只在入口打开和迁移一次。schema 2 脚手架的 createApplication 保留 Database 注入，render 与 `Application.executionScope` 绑定连接，事件、延迟列表行、验证器和准备器也进入同一作用域。页面代码因此无需传 db。

withDatabase 使用线程局部、同步的作用域；嵌套、异常及提前 return 均恢复前一个上下文。没有默认全局连接。未绑定、已关闭和跨线程连接明确报错；活动事务内不能切换数据库。后台任务自行打开连接并进入 withDatabase；作用域不能跨 await。

兼容显式入口：`task.save(db)`、`task.saveOrRaise(db)`、`Task.find(db, id)`、`task.reload(db)`、`task.destroy(db)`、`task.destroyOrRaise(db)`。它们委托同一实现，回调也使用指定连接。

直接用 Nim 编译时，提供 Leaf src 路径，并启用附带的 orm_config 参数；脚手架 config.nims 和 Leaf CLI 自动处理这些参数及 deepcopy。SDK 中已经包含全部依赖，无需 nimble install。

## 创建、修改与错误

```nim
withDatabase(db):
  let task = Task.build(title = "买牛奶") # 尚未插入
  if task.save():
    echo task.id
  else:
    echo task.errors.fullMessages.join("\n")

  let invalid = Task.create(title = "") # 返回带 errors 的未保存对象
  doAssert invalid.isNewRecord
  let saved = Task.createOrRaise(title = "读书")
  doAssert saved.update(title = "读两页")
  saved.updateOrRaise(done = true)
  saved.reload()                       # 原位完整重载
  saved.destroyOrRaise()
```

save/update/destroy 返回 bool，不能默默丢弃 save 的结果。false 表示校验失败或 before 回调取消；数据库失败始终抛 DatabaseError，约束失败为 ConstraintError，保留 SQLite code/extendedCode。OrRaise 把校验失败转换为 RecordInvalid、保存取消为 RecordNotSaved、删除取消为 RecordNotDestroyed；查询缺失为 RecordNotFound，错误用法为 ModelUsageError。

errors 每次校验重建，支持同一字段多个错误：`errors.forField("title")` 返回 field/code/message/params，`errors.fullMessages` 返回消息列表。presence 不自行修改输入；maxLength 按 Unicode 码点计算；finite 拒绝 NaN 和无穷。需要 trim 时明确声明 beforeValidation 回调。

reload 清 errors、dirty baseline 和 savedChanges；丢失行报 RecordNotFound。删除后不能再保存。删除新对象改变其生命周期但不执行 SQL，也不产生提交通知；新对象不能 reload。模型绑定到首次持久化的连接，跨库复制请使用 dupRecord。

## where、scope 与首尾查询

```nim
withDatabase(db):
  let allTasks = Task.all
  let first = Task.first              # Option[Task]
  let last = Task.last()               # 同样支持括号
  let required = Task.firstOrRaise     # Task；空表报 RecordNotFound
  let total = Task.count               # int64
  let found = Task.exists(1'i64)

  let unfinished = Task.where(done = false, category = "home").all
  let selected = Task.where(it.priority >= 2 and not it.done).all
  let byId = Task.where(it.id in @[1'i64, 3'i64]).all
  let title = Task.where(it.title.contains("中文%_\\")).first
  let prefix = Task.where(it.title.startsWith("买")).all
  let suffix = Task.where(it.title.endsWith("奶")).all
  let named = Task.findBy(title = "买牛奶")
  let scoped = Task.home.unfinished.orderBy(it.priority, Desc).limit(10).all

  let head = Task.first(3)             # seq[Task]
  let tail = Task.last(3)              # seq[Task]，仍按原顺序
  let windowTail = Task.offset(1).limit(3).last(2)
  let ids = Task.where(done = false).ids
  let titles = Task.pluck(it.title)    # seq[string]
  let pairs = Task.pluck(it.id, it.title) # seq[tuple[id: int64, title: string]]
```

不需要 query()。where 同一次调用可接受多个命名等值参数，或一个表达式；不能混合。表达式支持比较、and/or/not、in/notin、isNull、contains/startsWith/endsWith，未知字段和错误类型编译失败。所有值通过 SQLite 参数绑定；LIKE 的 `%`、`_` 和反斜杠按字面转义，大小写遵循 SQLite。Option 字段可与 none(T) 比较，等值编译成 IS NULL；pluck 保留 Option，不构造部分可写 Model。空 IN 为 false，空 NOT IN 为 true，其余 NULL 集合行为遵循 SQLite。

默认 id ASC；显式排序在没有 id 时补 id ASC，形成稳定排序。last 会反转全部排序并加 LIMIT，返回列表时恢复原顺序。已有 limit/offset 时先限定原窗口，再取首尾。n=0 返回空列表，负数报 ModelUsageError；重复 limit/offset 替换旧值，重复 orderBy 追加。

count/exists 统计筛选条件，忽略排序和分页。Query 是不可变描述，分支不会污染原查询；它捕获建立时的连接，离开作用域后仍可执行终结操作。若在另一连接的活动事务内执行、连接已关闭或跨线程，则拒绝。同名业务字段会遮蔽 Nim 的点简写，例如 count 用 `count(Metric)`，errors 用 `errors(task)`；内部持久化始终使用框架状态，不受这些字段影响。

rawQuery 是独立受控入口，调用方必须选齐所有持久列，且按模型声明映射顺序排列；按类型和列数校验结果。不要用它构造部分模型或拼接用户输入。

## Dirty tracking 与编辑隔离

`task.changes` 比较当前业务字段与最后成功写入/加载的快照；changed 返回 bool，savedChanges 是上次成功保存的变化。每项有 field、before、after，Option[SqlValue] 区分不存在和 SQL NULL。

只更新变化列；两个独立对象分别修改不同列时不覆盖未变列，同列最后写入胜出。无变化保存仍运行校验和回调，并验证行存在，但不执行 UPDATE、不改 updated_at，也不产生提交通知。afterSave 的后续修改保留为 dirty。

Model 是引用对象，赋值别名共享状态；页面 Draft 使用独立 object 值类型，取消时直接放弃 Draft。dupRecord 复制业务字段，清除 id、时间和持久状态，下一次保存插入新行。

## 回调与事务

声明支持 before/after Validation、Save、Create、Update、Destroy，以及 afterCommit/afterRollback。普通回调签名是 `proc(record: T)`，事件回调是 `proc(record: T, event: ModelEvent)`；`event.operation` 和 `event.eventChanges` 只读访问该次写入的信息。

before 按基类到子类、after 按子类到基类，同层声明按书写顺序。before 回调可调用 record.abortOperation()；after 阶段拒绝取消，同对象操作重入也拒绝。

```nim
withDatabase(db):
  transaction:
    let one = Task.createOrRaise(title = "一")
    transaction:                    # SQLite SAVEPOINT
      discard one.update(done = true)
# 或 db.transaction: ... / transaction(db): ...
```

每次 save/destroy 自带事务范围，覆盖校验和普通回调。外层用 BEGIN IMMEDIATE，嵌套用 SAVEPOINT。普通退出或提前 return 提交，异常回滚；false 只撤销当前操作的内部 savepoint，OrRaise 传播异常可使外层回滚。

回滚恢复框架管理的 id、生命周期、时间和 baseline，保留业务输入与 errors。直接通过底层 SQL 修改记录后，需 reload 更新对象快照。afterCommit 到最外层提交后才执行；每次成功 SQL 写入保留独立事件，按操作顺序派发。提交后通知失败仍执行剩余通知，汇总成 PostCommitError，committed 为 true；数据库已提交，不再回滚；页面应完成成功保存后的草稿清理和跳转，再显示通知错误，避免把已提交创建当作未保存重试。afterRollback 在状态恢复后执行，其错误不掩盖原始失败。

首版不包括关联、自动 schema 建表、连接池、异步 ORM、批量写入及乐观锁；后续可以在当前 Record/Query 接口上增量增加。
