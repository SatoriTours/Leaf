# Leaf Rails 风格 Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让业务 model 继承共享能力，以 `Task.where(...)`、`Task.first`、`task.save()` 完成免传数据库的查询和持久化，并接入新应用脚手架。

**Architecture:** 公共业务对象继承 Leaf Record；声明宏生成仅含持久化字段的私有 Norm 存储类型。Leaf 持有 SQLite 连接、执行上下文、事务日记及查询描述，Norm 负责插入和行映射。core 通过通用执行钩子绑定应用边界，schema 2 使用新接口，schema 1 继续使用旧模板。

**Tech Stack:** Nim 2.2.6+、ORC、SQLite、Norm 2.8.7、lowdb v0.3.0、锁定的 db_connector 0.1.0、unittest、现有 headless Runtime 与 SDK 构建工具。

**Spec:** [已批准设计](../specs/2026-10-06-model-design.md)

## Global Constraints

- Nim 2.2.6 及以上、ORC；model 应用显式启用 `deepcopy:on`。
- 首版 SQLite；不承诺 PostgreSQL、异步、关联、STI、复合主键、乐观锁、批量写入。
- Norm `aba796d0251fa6aeb01ec2c49f48b63522db5e32`（2.8.7）；lowdb `b1891f492ac31eeb9b4e7e08761cccd0f01263a8`（v0.3.0）；db_connector `29450a2063970712422e1ab857695c12d80112a6`（0.1.0）。锁文件记录归档和文件哈希、许可及本地补丁。
- db_connector 仅补动态库选择：Windows `winsqlite3.dll`、macOS `libsqlite3.dylib`、Linux `libsqlite3.so(|.0)`；Norm 与 lowdb 不关闭借用连接。
- 所有主键和 schema 2 编辑状态使用 `int64`；schema 1 保留原有接口。
- 持久化字段为 `string/bool/int/int64/float/DateTime/Option[这些标量]`；列名保留声明拼写，按 Nim 标识符等价规则检查保留名。
- 参数绑定保留中文、引号、NUL 和 NULL；禁止查询 DSL 接受任意函数或原始 SQL。
- 导入、声明、生成命令不打开数据库；启动只使用现有 SQL 迁移，不调用 Norm.createTables，不修改已应用历史。
- 同步 `threadvar` 上下文，退出时恢复；没有进程级默认连接；连接关闭、跨线程、跨数据库对象和活动事务切换连接均拒绝。
- SDK 携带依赖源码与许可；生成命令不运行 nimble install，安装后的应用构建不下载 ORM。
- 实施前检查并保留工作区中其他任务的修改；提交仅包含本任务文件。执行隔离按 using-git-worktrees 技能处理。

## Review Focus

1. lowdb 文本读取使用 C 字符串转换，NUL 后内容会丢失：适配查询必须保留完整文本（任务 1、3）。
2. 两个应用交替处理延迟按钮和虚拟列表事件：每次进入所属连接，异常后恢复原上下文（任务 2、9）。
3. 保存返回 false、内层回滚、外层回滚和提交后异常：分别恢复正确对象状态，已提交数据不能被重试或回滚（任务 6、7）。
4. 多列排序含相同值，并叠加 offset/limit 后取 last(n)：返回分页窗口的尾部，保持原排序，无整表加载（任务 8）。
5. 旧 schema 1 应用增量生成和无 Nimble 缓存的安装 SDK：不混入新模板，model 依赖完全离线可用（任务 10、11）。

---

## 文件职责与执行约定

| 文件 | 职责 |
| --- | --- |
| `src/leaf/model.nim` | 选择性导出公共 API，不把 ORM 加入 `leaf.nim` 的默认依赖 |
| `src/leaf/model/{record,errors,changes}.nim` | 对象状态、结构化错误、快照与变化 |
| `src/leaf/model/{context,transactions}.nim` | 当前连接、事务范围、对象日记和提交事件 |
| `src/leaf/model/{metadata,declarations}.nim` | 字段元数据、抽象声明、生成存储类型和参数赋值入口 |
| `src/leaf/model/{validation,callbacks,persistence}.nim` | 校验、生命周期调用、统一 CRUD |
| `src/leaf/model/query.nim`、`query_expression.nim`、`query_sql.nim` | 不可变描述、编译期表达式检查、参数化 SQL 与终结操作 |
| `src/leaf/model/adapters/norm_sqlite.nim` | 借用连接、Norm 插入/行映射、Leaf 原生查询与精确行数 |
| `src/leaf/orm_config.nims` | 同一份依赖搜索路径、deepcopy 和动态库配置 |
| `src/leaf/vendor/orm/` | 三个上游源码、许可、`lock.json`、db_connector 补丁 |
| `src/leaf/scaffold_model_templates.nim` | schema 2 model、迁移、model 测试模板 |
| `src/leaf/scaffold_model_pages.nim` | schema 2 页面、Draft 和应用绑定模板 |
| `tests/nim/model_fixtures.nim` | Task、Note、抽象共享规则及独立测试数据库；不导入 UI |
| `tests/nim/test_model_*.nim` | 各任务行为测试，现有测试 runner 自动发现 |

先完成任务 1–3 的连接和声明验证，再扩大功能。任务之间顺序执行；不按模块并行修改。

当前 PATH 与 NIM 环境变量均未提供编译器。任务 1 执行前安装或定位 Nim 2.2.6 到任务专用目录，设置 `NIM` 为其绝对路径，不改系统工具链。记录 `nim --version`。以下命令中的 `nim` 指该编译器；输出放 `target/nim/`。

每项测试采用 `nim c -r --out:target/nim/<测试名> tests/nim/<测试名>.nim`。新增目录由执行前创建；需要线程的测试显式使用 `--threads:on`。配置文件在任务 1 接通依赖路径，此后不要依靠机器的 Nimble 缓存。

## Task 1: 共享 SQLite 连接与锁定依赖

**Files:** Create `src/leaf/vendor/orm/`、`src/leaf/orm_config.nims`、`src/leaf/model/adapters/norm_sqlite.nim`、`tests/nim/test_model_adapter.nim`；Modify `src/leaf/sqlite.nim`、`src/leaf/sqlite_native.nim`、`config.nims`、`src/leaf/build.nim`、`scripts/test.nim`。

**Interfaces:**
- Consumes: `openDatabase(path: string): Database`、`Database.query(sql, values): seq[seq[SqlValue]]`、`execute(...): int`。
- Produces: storage `asInt64(value: SqlValue): int64`、`lastInsertId64(db: Database): int64`、`requireUsable(db: Database)`、`borrowSqliteHandle(db: Database): pointer`。后者仅供内部适配器，所有权不转移。
- Adapter: `insertStorage[S: norm.Model](db: Database, storage: var S)`、`selectStorage[S: norm.Model](db: Database, sql: string, values: openArray[SqlValue]): seq[S]`、`executeAffected(db: Database, sql: string, values: openArray[SqlValue]): int64`。
- SQLite `ConstraintError` 继承现有 `DatabaseError`；错误对象保留 SQLite 基础/扩展代码与原始消息。lowdb 异常在 adapter 中转换。

- [ ] **Step 1: 写失败测试。** 同一 `:memory:` 连接迁移建表，再经 Norm 插入、Leaf 查询及 adapter 查询；断言 `title == "中文'\0尾部"`、`id == 5_000_000_000'i64`、NULL/外键失败、close 后拒绝执行。独立存储类型字段顺序与 Norm 一致，不含 Leaf 状态。第二次关闭不重复释放；另一连接看不到同一内存表。

  核心断言：`check rows[0].title == "中文'\0尾部"`、`check rows[0].id == 5_000_000_000'i64`；`expect ConstraintError: discard db.execute(...)`；`expect DatabaseError: discard selectStorage[AdapterTask](closedDb, ...)`。
- [ ] **Step 2: 运行 adapter 测试。** 预期新模块/接口不存在；记录失败输出。
- [ ] **Step 3: 实现锁定产物和平台配置。** 只从上述提交取源码与 MIT 许可，建立 `vendor/orm/{norm,lowdb,db_connector}/src` 搜索路径。补丁将 db_connector 的库常量改为可配置 `leafOrmSqliteLibrary`，默认沿用上游；Leaf 配置传入现有库名。构建器与测试 runner 引用同一配置，生成应用的独立配置也能使用。记录补丁及原始/修改后哈希。
- [ ] **Step 4: 实现 adapter 和连接检查。** Database 保存创建线程身份，每次借用/操作检查。Norm 插入借用同一指针；查询使用 Leaf.query 取得长度正确的值，转换为 lowdb.Row 后调用 Norm `fromRow`，每行分配独立存储对象。不要使用会截断 NUL 的 lowdb 原始文本查询；更新/删除复用 Leaf.execute。连接层分类约束异常。
- [ ] **Step 5: 运行 `test_model_adapter` 和 `test_sqlite`。** 预期全部 PASS，原有迁移 authorizer、FULLMUTEX、foreign_keys 和 busy timeout 不变。三平台运行留到任务 11，不能将当前 Linux 结果记作三平台验证。
- [ ] **Step 6: 提交本任务文件。** `feat: bridge Norm with Leaf SQLite connection`。

## Task 2: 同步数据库上下文

**Files:** Create `src/leaf/model/context.nim`、`src/leaf/model/errors.nim`、`tests/nim/test_model_context.nim`。

**Interfaces:**
- Consumes: Task 1 `requireUsable(db)`。
- Produces: `ModelContext`（连接、事务深度、回滚中标记）、`currentContext(): ModelContext`、`currentDatabase(): Database`、`withDatabase(db: Database, body: untyped)` 模板。
- Errors: `DatabaseContextError`、`ModelUsageError`；后续任务使用 `RecordNotFound`、`RecordInvalid`、`RecordNotSaved`、`RecordNotDestroyed`、`PostCommitError`（只读 `committed = true`、错误消息列表）。

- [ ] **Step 1: 写失败测试。** 无上下文 currentDatabase 抛 DatabaseContextError；A→B→A 嵌套、异常和过程 return 恢复；连续测试不泄漏；关闭连接及另一个线程访问拒绝。标记 A 活动事务后切换 B 抛 ModelUsageError，同连接嵌套复用上下文。

  核心断言：`expect DatabaseContextError: discard currentDatabase()`；外层 `withDatabase(a)` 在内层退出后 `check currentDatabase() == a`；异常/return 退出外层后再次 `expect DatabaseContextError`。
- [ ] **Step 2: 运行 context 测试，预期接口不存在。** 命令加 `--threads:on`。
- [ ] **Step 3: 实现模板与错误类型。** threadvar 保存当前 context；进入前检查连接和活动事务，finally 恢复前值。嵌套同连接复用 context；不打开、关闭连接，不开始事务。
- [ ] **Step 4: 重跑 context/adapter 测试，预期 PASS。** 断言借用作用域退出后连接仍可用。
- [ ] **Step 5: 提交。** `feat: add scoped model database context`。

## Task 3: Record 与声明宏的可运行骨架

**Files:** Create `src/leaf/model.nim`、`src/leaf/model/record.nim`、`src/leaf/model/metadata.nim`、`src/leaf/model/declarations.nim`、`tests/nim/model_fixtures.nim`、`tests/nim/test_model_declarations.nim`。

**Interfaces:**
- Produces: `Record`、`TimestampedRecord`；`id(record: Record): int64`、`isNewRecord/isPersisted/isDestroyed(record: Record): bool`；只读身份，无公开 id 字段。
- `FieldMeta`（name、SQL type、nullable、frameworkManaged）、`FieldValues = seq[tuple[name: string, value: SqlValue]]`。元数据按生成存储类型实际字段顺序排列。
- Macros: `defineAbstractModel(T: typedesc, body: untyped = empty)`、`defineModel(T: typedesc, table: static[string], body: untyped = empty)`。
- Generated internal interfaces: `modelTable(T): string`、`modelFields(T): seq[FieldMeta]`、`modelValues(record: T): FieldValues`、`assignModelValues(record: T, values: FieldValues)`、`storageType(T): typedesc`、`toStorage(record: T): storageType(T)`、`fromStorage(T, storage: storageType(T), db: Database): T`。泛型调用使用 mixin 在实例化处解析；不使用运行时类型名查表。
- Public `T.build(namedFields): T`，通过声明生成字段参数和类型检查；默认字段值与 `T()` 一致。

- [ ] **Step 1: 写失败测试。** 两个 model 继承同一 ApplicationRecord；继承持久化字段映射正确，id/errors/快照不变成列；`Task()` 与 build 无上下文均为新对象。遍历全部受支持类型做 adapter 往返，包括 Option[DateTime]、5_000_000_000 主键、中文/NUL 和 UTC 秒。读取不同结果对象互不别名。

  核心断言：`check Task().isNewRecord`、`check Task.build(title = "测试").id == 0'i64`；`check modelFields(Task).allIt(it.name notin ["errors", "baseline", "savedChanges"])`；`check restored.optionalTime.get.toTime.toUnixFloat == original.optionalTime.get.toTime.toUnixFloat`。
- [ ] **Step 2: 运行 declarations 测试，预期新类型或宏不存在。** 加编译失败子进程断言：不支持字段、具体继承具体、抽象建表/查询、手工 id 赋值和保留名大小写/下划线变体均失败且定位声明。
- [ ] **Step 3: 实现状态与宏生成。** Record 私有运行状态随对象存储；内部状态访问器只在内部模块使用，公共 barrel 选择性导出。宏遍历抽象继承链，剔除运行字段，生成私有 Norm ref object 和显式转换；不建全局对象表。日期编码用 Unix REAL 秒；TimestampedRecord 的两个 Option 时间字段只出现一次。
- [ ] **Step 4: 运行 declarations/context/adapter，预期 PASS。** 明确证明此骨架支持跨模块导入和继承后再继续持久化。
- [ ] **Step 5: 提交。** `feat: generate model metadata and private Norm storage`。

## Task 4: 错误集合与变更快照

**Files:** Create `src/leaf/model/changes.nim`、`tests/nim/test_model_changes.nim`；Modify `record.nim`、`errors.nim`、`model.nim`。

**Interfaces:**
- `ModelError`（field/code/message: string、params: Table[string,string]）、`ModelErrors`；`errors(record): ModelErrors`、`add(errors, field, code, message, params)`、`forField(errors, field): seq[ModelError]`、`fullMessages(errors): seq[string]`、`clear(errors)`。
- `FieldChange`（field、before/after: Option[SqlValue]）、`ChangeSet = seq[FieldChange]`。none 表示无原始值，some(sqlNull) 表示已有 NULL。
- `changes[T: Record](record: T): ChangeSet`、`changed[T](record): bool`、`savedChanges(record: Record): ChangeSet`、`dupRecord[T](record: T): T`。
- Internal `captureState(record: Record): RecordState`、`restoreState(record: Record, state: RecordState)`、`acceptPersistedValues(record: Record, db: Database, id: int64, values: FieldValues, changes: ChangeSet)`；RecordState 含框架时间值，恢复不覆盖用户业务字段。

- [ ] **Step 1: 写失败测试。** 一字段可多个错误；清除重建；新对象 absent 与 nullable NULL 区分；查询对象修改→改回无变化；返回 ChangeSet 的修改不改变内部快照；dupRecord 复制业务值，身份/时间/errors/baseline 全部重置；nil 使用报 ModelUsageError。

  核心断言：`check task.errors.forField("title").len == 2`、`check task.dupRecord.id == 0'i64`、`check task.dupRecord.created_at.isNone`；已加载对象改回原值后 `check not task.changed`。
- [ ] **Step 2: 运行 changes 测试，预期接口不存在。**
- [ ] **Step 3: 实现错误和快照 API。** SqlValue 按 kind 比较；FieldValues 使用稳定字段顺序；每次暴露变化返回独立值集合。捕获对象状态时保存 managed 时间字段，留下供事务恢复的内部闭包，不擦除具体字段映射能力。RecordState 不恢复字段错误或取消标记；校验失败回滚后仍须展示本次 errors，重入标记由操作 finally 清理。
- [ ] **Step 4: 重跑 changes/declarations，预期 PASS。**
- [ ] **Step 5: 提交。** `feat: add model errors and dirty tracking`。

## Task 5: 校验、声明规则和生命周期回调

**Files:** Create `src/leaf/model/validation.nim`、`src/leaf/model/callbacks.nim`、`tests/nim/test_model_validation.nim`；Modify `declarations.nim`、`model.nim`。

**Interfaces:**
- Public `valid[T: Record](record: T): bool`、`abortOperation(record: Record)`；callback 普通签名 `proc(record: T)`。
- `OperationKind = enum createOperation, updateOperation, destroyOperation`；`ModelEvent` 的只读访问器 `operation(event): OperationKind`、`eventChanges(event): ChangeSet`。
- afterCommit/afterRollback 签名 `proc(record: T, event: ModelEvent)`。
- Generated internal `runValidations(record: T)`、`runCallbacks(record: T, phase: CallbackPhase, event: ModelEvent = nil)`；CallbackPhase 包含设计列出的所有 before/after 阶段。
- Declaration body 接受 `validates field, presence=true, maxLength=N`、`finite=true`、设计中的回调声明；Task 8 加 scope。

- [ ] **Step 1: 写失败测试。** 中文码点长度 200 通过、201 失败；presence/Option 空值、有限 float、两条规则叠加；显式 trim 回调，未声明字段不被 trim。before 基类→子类、after 子类→基类，同层声明顺序；valid 需要 context，校验失败 errors 重建、不写 SQL。

  核心断言：`check Task.build(title = "中".repeat(200)).valid()`；201 字时 `check not task.valid()`、`check task.errors.forField("title")[0].code == "too_long"`；回调日志 `check phases == @["base_before", "child_before", "child_after", "base_after"]`。
- [ ] **Step 2: 运行 validation 测试，预期接口不存在。** 子进程编译检查非法规则字段/字段类型、错误 callback 签名失败。
- [ ] **Step 3: 实现校验和回调注册。** 编译期继承声明元数据，生成类型正确的调用；不在 import 时注册。Unicode 长度使用 std/unicode 码点统计。abortOperation 是每次操作独立的取消状态，仅 before 阶段允许取消；同对象正在操作时重入拒绝。
- [ ] **Step 4: 重跑 validation/changes/declarations，预期 PASS。** 数据库读取的业务校验能访问当前 context。
- [ ] **Step 5: 提交。** `feat: add inherited validations and lifecycle callbacks`。

## Task 6: 事务日记、嵌套范围与提交通知

**Files:** Create `src/leaf/model/transactions.nim`、`tests/nim/test_model_transactions.nim`；Modify `context.nim`、`callbacks.nim`、`model.nim`。

**Interfaces:**
- Public templates `transaction(body: untyped)` 与 `transaction(db: Database, body: untyped)`，支持 `db.transaction:`。
- Internal `beginFrame(): TransactionFrame`、`commitFrame(frame)`、`rollbackFrame(frame)`、`enlist(record: Record, restore: proc() {.closure.})`、`queueEvent(record: Record, event: ModelEvent, notifyCommit, notifyRollback: proc() {.closure.})`。frame 栈属于当前 context，同步执行。
- 保存失败显式 rollbackFrame；普通异常传播；提交后 PostCommitError 与事务 SQL 失败采用不同分支。

- [ ] **Step 1: 写失败测试。** 外层 BEGIN IMMEDIATE、内层 SAVEPOINT；内层 rollback 不撤销外层；首次触碰日记在每层记录、内层 commit 合并到外层。rollback 恢复框架状态及时间，保留用户字段。outer commit 前不通知，通知按操作顺序；一通知抛异常仍执行后续通知、数据库保持 committed=true；rollback 通知异常不掩盖原始失败且不阻断恢复。

  核心断言：外层提交前 `check notifications.len == 0`，之后 `check notifications == @["first", "second"]`；捕获提交后异常 `check error.committed` 且 `check db.query("SELECT COUNT(*) FROM entries")[0][0].asInt64 == 2'i64`；回滚后 `check record.id == 0'i64`。
- [ ] **Step 2: 运行 transactions 测试，预期接口不存在。** 用 Task 4 内部状态和测试通知闭包验证，不提前实现 CRUD。
- [ ] **Step 3: 实现 frame。** savepoint 名称由内部递增整数生成；日记对象身份比较只用于当前 frame 局部列表，不建立全局注册表。提交 SQL 成功后先弹出最外层 frame，再派发全部事件并汇总错误；rollback 先恢复全部状态再派发，回滚连接拒绝写入。显式 db 入口绑定同一 withDatabase。
- [ ] **Step 4: 重跑 transactions/context/validation，预期 PASS。** 补齐事务中的提前 return 行为：正常退出提交，异常退出回滚，finally 恢复连接和 frame 栈。
- [ ] **Step 5: 提交。** `feat: journal model state across nested transactions`。

## Task 7: 统一持久化与失败语义

**Files:** Create `src/leaf/model/persistence.nim`、`tests/nim/test_model_persistence.nim`；Modify `declarations.nim`、`record.nim`、`model.nim`。

**Interfaces:**
- `save[T: Record](record: T): bool`、`saveOrRaise[T](record)`、`destroy[T](record): bool`、`destroyOrRaise[T](record)`、`reload[T](record)` 原位操作。
- `find[T: Record](T: typedesc[T], id: int64): T`；不存在抛 RecordNotFound。宏生成 `T.create/createOrRaise(namedFields): T`、`record.update(namedFields): bool`、`updateOrRaise(namedFields)`。
- 显式 overload `save(record, db)`、`saveOrRaise(record, db)`、`find(T, db, id)`、`destroy(record, db)`、`destroyOrRaise(record, db)`、`reload(record, db)` 只包 withDatabase 并调用无参实现。

- [ ] **Step 1: 写失败测试。** create 失败返回未保存对象和错误，createOrRaise 抛 RecordInvalid；before 取消 bool=false/OrRaise 对应异常；约束/只读/锁错误抛 DatabaseError 子类。插入补时间，更新只变更列，干净 save 不更新 SQL/时间但验证行存在；删除/重载丢失行抛 RecordNotFound，destroyed/nil/cross-db/reentrant 均拒绝。

  核心断言：`check Task.create(title = "").isNewRecord`、`check not invalid.save()`、`check invalid.errors.forField("title").len > 0`；`expect RecordInvalid: invalid.saveOrRaise()`；afterSave 修改之后 `check saved.changed`，干净 save 前后 `check saved.updated_at == previousTime`。
- [ ] **Step 2: 运行 persistence 测试，预期接口不存在。** 再添加多记录事务：false 仅撤销内部 savepoint，OrRaise 撤销外层；新记录 rollback id=0；旧记录 rollback baseline 恢复但输入保留。
- [ ] **Step 3: 实现保存管线。** Task 6 frame 覆盖校验和全部 before/after 回调；在最早修改框架时间前 enlist。插入走 Norm；更新/删除走 adapter 精确行数；成功写入先接受实际写入快照，再调用 after，让 afterSave 的修改保持 dirty。无变化保存运行回调，不产生成功写入事件。删除后生命周期暂存，可由外层 rollback 恢复。
- [ ] **Step 4: 实现构造/赋值和重载包装。** 参数宏只能赋业务字段，不允许 id 或 managed 时间。reload 重新完整加载、清 errors 与 baseline；dupRecord 的跨库保存是新插入。显式 db 的所有嵌套 callback 均使用指定连接。
- [ ] **Step 5: 跑 persistence/transactions/validation。** 再测同一行两个独立对象只修改各自列不覆盖未变列；同列最后提交胜出；引用别名共享实例状态；afterCommit 捕获每次变化，后一次修改不污染前事件。预期全部 PASS。
- [ ] **Step 6: 提交。** `feat: implement shared model persistence`。

## Task 8: 直接模型查询、scope 与首尾查找

**Files:** Create `src/leaf/model/query.nim`、`query_expression.nim`、`query_sql.nim`、`tests/nim/test_model_query.nim`；Modify `declarations.nim`、`model.nim`。

**Interfaces:**
- `Query[T: Record]` 值描述（private connection、predicate AST、order terms、optional limit/offset），`SortDirection = enum Asc, Desc`。
- Internal `newQuery(T: typedesc[T]): Query[T]` 捕获连接；`compileQuery(q, selectedFields, mode): tuple[sql: string, values: seq[SqlValue]]`；mode 区分 rows/count/exists/first/last。
- Type 与 Query 同时提供 where/orderBy 宏、limit/offset 过程；where 接收命名等值字段或一个表达式，两者不能同次混用；orderBy 接收一个 `it.field` 与方向，重复调用追加。
- 两类入口相同 terminals：`all: seq[T]`、`first/last: Option[T]`、`first/last(n: int): seq[T]`、`firstOrRaise/lastOrRaise: T`、`count: int64`、`exists: bool`、`ids: seq[int64]`。类型另有 `exists(id: int64): bool`。无参数项为 proc，支持点简写及括号。
- `findBy(namedFields): Option[T]`、`findByOrRaise(namedFields): T`；`pluck(it.field): seq[字段类型]`，多字段返回命名 tuple 列表（重复字段编译拒绝）。
- 宏继承 `scope name, expression`，生成 typedesc 与 Query 双入口。受控 `rawQuery(T, sql: string, values: openArray[SqlValue]): seq[T]` 仅接受完整模型列，按完整映射验证；不混入 where DSL。

- [ ] **Step 1: 写失败测试。** `Task.first/first()`、last、where named/expression、scope 两入口、两个 query 分支无污染。创建 q 后离开 A，在 B 中终结仍查 A；关闭/跨线程/活动 B 事务拒绝。中文/NUL/引号为绑定值；Option none→IS NULL；IN 空列表 false，not in 空列表 true，null 比较明确。

  核心断言：`check Task.first.get.id == 1'i64`、`check Task.last.get.id == 6'i64`、`check Task.offset(1).limit(3).last(2).mapIt(it.id) == @[3'i64, 4'i64]`；`check Task.where(title = "中文'\0尾部").pluck(it.title) == @["中文'\0尾部"]`。
- [ ] **Step 2: 运行 query 测试，预期 API 不存在。** 编译失败子进程覆盖未知字段、比较错误类型、任意函数、SQL 片段、表达式混命名参数、抽象类型入口。类型兼容由 Nim 编译器检查，不把所有值提前转成字符串。
- [ ] **Step 3: 实现表达式编译。** 只接受字段引用、比较、and/or/not、in/notin、isNull、contains/startsWith/endsWith；LIKE 参数转义 `%/_/转义符`，遵循 SQLite 大小写行为。编译期引用合法列名，运行期绑定值。Query 分支复制表达式/排序序列，重复分页参数替换，负数报 ModelUsageError。
- [ ] **Step 4: 实现执行和首尾算法。** 默认 id ASC，显式排序末尾补未出现的 id ASC。无分页 last 反转全部排序 + LIMIT，返回 n 条时反转结果；有分页通过有序窗口子查询限定原 limit/offset，再取其首尾。offset 无 limit 用 SQLite LIMIT -1。n=0 空列表、n<0 拒绝；count/exists 忽略分页排序。所有 terminals 进入捕获连接的 withDatabase。
- [ ] **Step 5: 实现字段终结与 scope。** ids/pluck 只读取要求的列，按声明类型转换，NULL 保留 Option，不构造业务对象。findBy 委托 id ASC first，scope 委托同一表达式宏；type shortcuts 统一 newQuery，不重复 SQL。
- [ ] **Step 6: 跑 query/persistence 测试。** 数据 `[id:1..6]`、相同 priority、混合 ASC/DESC；断言 `.offset(1).limit(3).last(2)` 返回原窗口最后两条且原顺序；空表/n=0/负数/重复分页、LIKE 字面 `%_\\` 全覆盖。检查内部编译 SQL 含限定窗口与 LIMIT，避免只靠结果测试掩盖整表读取。预期全部 PASS。
- [ ] **Step 7: 提交。** `feat: add direct model queries and scopes`。

## Task 9: 应用执行边界自动绑定连接

**Files:** Modify `src/leaf/core.nim`、`tests/nim/test_core.nim`；Create `tests/nim/test_model_runtime.nim`。

**Interfaces:**
- core `ExecutionScope* = proc(body: proc() {.closure.}) {.closure.}`，`Application.executionScope*: ExecutionScope`；nil 直接执行，core 不导入 SQLite/model。
- Runtime refresh、dispatch、materialize 中执行用户闭包的边界进入该 scope；保留现有重入防护、快照原子提交和诊断。

- [ ] **Step 1: 写失败测试。** 纯 core scope 记录 render/callback/row builder 的进入/退出；无 scope 的旧应用不变。model 测试中 A/B 两个 Runtime 交替点击相同 id，数据分别写入 A/B；callback 抛异常后 context 恢复；virtual row 稍后创建也能免 db 查询。

  核心断言：A→B→A 点击后 `check a.query("SELECT COUNT(*) FROM tasks")[0][0].asInt64 == 2'i64`、B 数量 `== 1'i64`；每个用户闭包内部 `check currentDatabase() == expectedDatabase`，dispatch/materialize 退出后 context 缺失。
- [ ] **Step 2: 跑 core/runtime 测试，预期 executionScope 字段不存在。**
- [ ] **Step 3: 实现 core 通用包装。** 每个公开执行路径包裹用户代码，同步闭包将 bool/seq 结果写回局部变量；finally 与重入标志仍按原有顺序恢复。直接 Application.render 的绑定由 schema 2 模板处理，不在 core 引入 model。
- [ ] **Step 4: 重跑 core、model_runtime 与现有虚拟列表/原生 Runtime 相关测试。** 预期 PASS，失败渲染不提交半成快照。
- [ ] **Step 5: 提交。** `feat: scope application rendering and events`。

## Task 10: schema 2 脚手架及旧应用兼容

**Files:** Create `src/leaf/scaffold_model_templates.nim`、`src/leaf/scaffold_model_pages.nim`、`src/leaf/templates/scaffold/model_application.nim`、`model_home_page.nim`、`model_home_logic.nim`、`tests/nim/test_scaffold_model.nim`、`tests/fixtures/scaffold_v1/`；Modify `src/leaf/scaffold.nim`、`src/leaf/scaffold_types.nim`、`tests/nim/test_scaffold.nim`、`docs/scaffolding.md`。

**Interfaces:**
- `ScaffoldManifest`（schema: int、resources: seq[ResourceSpec]）；加载同时支持 1、2；schema 2 必须包含 `model_api: 1`、`timestamps: true`，新应用默认 2。
- `modelCodeV2(resource): string`、`migrationFilesV2(resource): seq[ScaffoldFile]`、`modelTestCodeV2(resource): string`、`resourceFilesV2(resource): seq[ScaffoldFile]`；旧模板接口继续使用，不将新行为塞入旧生成函数。
- schema 2 `generatedPages(): seq[PageDefinition]`、各 page `definition(): PageDefinition`；`createApplication(database: Database = nil): Application` 保留启动注入入口。

- [ ] **Step 1: 写失败测试。** 固定的真实 schema 1 fixture 增量生成 Note，仍使用旧 service/id/int/SQL，不修改原文件和迁移；新 schema 2 生成 ApplicationRecord、Task/Note、时间迁移、model 测试，普通 CRUD 无 service。unknown schema 和缺少 model_api/timestamps 拒绝，dry-run 与冲突检查仍正确。

  核心断言：`check manifest["schema"].getInt == 2`、`check manifest["model_api"].getInt == 1`、`check not fileExists(app / "app/services/task_service.nim")`；旧 fixture 增量后 `check readFile(oldMigration) == originalMigration`。另建旧数据表，应用新增时间字段及 UTC backfill 迁移后 `check Task.find(oldId).title == originalTitle`，历史创建 SQL 不改动。
- [ ] **Step 2: 跑 scaffold/scaffold_model，预期当前只有 schema 1。** 旧 fixture 从当前模板固定保存，避免用新默认生成器伪造兼容测试。
- [ ] **Step 3: 实现清单分派与声明模板。** 新抽象基类 TimestampedRecord，string required + trim 回调、float finite；id/time 保留名；迁移 id INTEGER PRIMARY KEY 和 created_at/updated_at REAL NOT NULL。新 app 配置引用 Leaf orm_config，跨空间路径可编译；生成器不下载依赖。
- [ ] **Step 4: 实现 model 页面模板和应用绑定。** 启动打开/迁移一次，在 withDatabase 内构造页面/router；render 闭包和 executionScope 各绑定同一连接。Draft 为独立值类型；编辑 find 后赋值再 save，失败保留输入和显示列表，取消不修改 model；编辑状态/闭包主键 int64。列表只在成功后刷新。
- [ ] **Step 5: 跑真实生成编译和 headless CRUD。** 新建、修改、校验失败、取消、toggle、删除、重新启动持久化及新增第二资源；断言 error 字段展示、多 model 共用能力、事件无 db 参数。旧 schema 1 同样实际编译运行。预期 PASS。
- [ ] **Step 6: 更新 docs/scaffolding。** 给出新定义、免 db 查询和事务示例；注明 all/first/last/count 行为、旧清单分派、人工升级和新增时间字段 migration/backfill 示例，禁止修改既有迁移。
- [ ] **Step 7: 提交。** `feat: generate model-based schema 2 applications`。

## Task 11: SDK 离线依赖、三平台验证与公共文档

**Files:** Modify `src/leaf/licenses.nim`、`scripts/package_sdk.nim`、`scripts/smoke_sdk.nim`、`tests/release/test_sdk.nim`、`tests/release/test_notices.nim`、`.github/workflows/ci.yml`、`.github/workflows/release.yml`、`README.md`；Create `docs/models.md`、`tests/release/test_model_dependencies.nim`、`.github/workflows/model.yml`。

**Interfaces:**
- SDK 保持现有 src 全量复制，增加 ORM 许可/inventory/SDK-SOURCES 信息与锁文件校验；安装 compiler + src 足以执行 orm_config。
- 新 model CI matrix `ubuntu-24.04/macos-14/windows-2022`，Nim 2.2.6；只运行 model/headless 相关 suites，不为纯 ORM 测试编译 GPUI Rust 桥接。

- [ ] **Step 1: 写失败测试。** 发布 SDK 包含全部锁定源码/许可/配置；每个文件哈希匹配锁；补丁只能影响动态库配置。安装后清空任务专用 Nimble 搜索缓存，生成两个模型应用并以 isolated config 实际编译、运行 headless CRUD；操作过程不出现依赖下载。

  核心断言：`check fileExists(sdk / "src/leaf/vendor/orm/lock.json")`；每个锁定文件 `check sha256File(path) == lockedHash`；空缓存 SDK compile/run 子进程 `check result.exitCode == 0`，进程关闭再启动后旧记录仍存在。
- [ ] **Step 2: 跑 model_dependencies、sdk、notices，预期缺少 ORM 许可与离线 model 验证。** 如果其他任务已修改 SDK 文件，读最新内容后在其修改基础上合并，不回滚他人工作。
- [ ] **Step 3: 实现许可与离线 smoke。** 依赖源码仍随 src 复制，licenses 和 inventory 写入三项目来源/commit/MIT。SDK smoke 采用新 schema 2，编译器参数不引用开发 checkout 或用户缓存；增加纯 source archive 自测路径。
- [ ] **Step 4: 接入三平台矩阵和现有 release 验证。** Windows 运行同一内存连接 Norm 插入/Leaf 查询/NUL 往返，证明 winsqlite3 实际一致；macOS/Linux 同样运行，不仅交叉编译。
- [ ] **Step 5: 写 docs/models 与 README 入口。** 覆盖定义/继承/where/first/last/ids/pluck、save 错误、Draft、dirty、回调顺序、事务事件、withDatabase、显式 db overload、线程与首版范围；区分 Rails 行为差异，示例来自已编译 fixtures。
- [ ] **Step 6: 跑 `nim c -r --out:target/nim/test_runner scripts/test.nim`。** 预期全部 Nim/release suites PASS；构建 CLI 并生成新应用，用安装 SDK 编译/运行。执行现有 nativeTest 验证真实事件边界（有 DISPLAY/Xvfb 和桥接依赖时）。记录三平台 CI 实际结果；无法运行的平台或原生检查明确列为未验证，不声称完成该验证。
- [ ] **Step 7: 按执行技能完成最终代码审查、修正及复测后提交。** `feat: ship offline model dependencies and documentation`。未经用户授权不发布 release、不合并远端分支。

## 自审与验收映射

| 设计验证项 | 负责任务 |
| --- | --- |
| 1 共享父类/字段隔离；2 类型与值往返 | 1、3、5 |
| 3 失败语义；4 编辑隔离/状态；6 回调与时间；8 并发对象差异更新 | 4、5、7、10 |
| 5 查询；14 捕获连接；15 类型快捷入口；16 首尾排序；17 where/pluck | 8 |
| 7 事务/回滚/提交异常 | 6、7 |
| 9 共享连接与三平台 | 1、11 |
| 10 脚手架/迁移兼容；11 离线 SDK | 10、11 |
| 12 应用执行边界；13 作用域/线程隔离 | 2、9、10 |

已检查所有五项 Review Focus 都有归属测试，任务接口的 FieldValues、ChangeSet、ModelEvent 与连接身份一致。最终对照设计逐项验收；后续关联能力仍是独立增量。
