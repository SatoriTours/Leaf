# Leaf 数据库迁移管理与当前项目 CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付裸标识符 Nim 迁移 DSL、生成/发现/正反向维护命令及启动接入，同时把 Leaf 项目命令统一为当前项目操作。

**Architecture:** 编译期宏输出有类型的操作描述；独立 planner、历史层及 SQLite runner 负责选择、指纹检查、整命令锁和逐迁移事务。项目解析与 CLI 参数解析独立，维护入口仅导入数据库配置和 catalog，不加载应用 UI。新文件自动发现，旧 SQL 与已执行历史保留。

**Tech Stack:** Nim 2.2.6+、现有 SQLite C binding、std/macros、vendored SHA256、POSIX flock / Windows LockFileEx、现有 Native SDK/ManagedProcess。

**Spec:** `docs/superpowers/specs/2026-10-08-database-migrations-design.md`（2026-10-08 用户确认开始开发；本计划仍需审阅）。

## Global Constraints

- 工作目录 `/home/jimxl/.paseo/worktrees/1c1rvoii/database-migrations`，分支 `feat/database-migrations`，workspace `wks_2d584befbac58e23`；不修改主 checkout 或原生控件空间。
- Nim 迁移文件仅 `import leaf/migrations` 和一个 migration；untyped 名称不用预先声明，不接受任意运行时操作体。
- SQLite 首版，不添加依赖下载、Model 关联或复杂表重建。renameColumn 要求 SQLite 3.25+；removeColumn 要求 3.35+。
- 版本是正 int64；新编号 UTC `yyyyMMddHHmmssfff`。JSON/新 scaffold manifest 的版本是十进制字符串。
- 删除 `--project` 及 PROJECT 位置写法，不做隐藏兼容；只有 `leaf init DIRECTORY` 指定新目录。完整 scaffold 写 cwd，已有项目找最近 leaf.json。
- 每条迁移和历史一起提交；整命令锁等待最多 5 秒；静态不可执行项在任何步骤写入前拒绝。
- 旧 SQL/up name/已执行版本不可重写；旧底层 `db.migrate(openArray[Migration])` 保留。
- status/dry-run 不建数据库、父目录、历史表、迁移锁或升级历史；编译 target 产物允许生成。
- 默认路径 `getDataDir() / <应用名> / application.sqlite3` 与 LEAF_DATABASE_PATH 保留；import/生成配置不打开数据库。
- 不覆盖人工文件、不删除无关文件；框架不声称回滚能恢复删除的数据。
- stdout JSON 单对象，编译/诊断 stderr；成功 0、失败 1、中断 130；不合并、不推送，直到用户另行授权。

## Review Focus

- 同一毫秒及钟回退时的本地生成不得覆盖；两个分支独立出现重复编号必须在数据库写入前指出双方文件（Task 3）。
- WAL 内已经提交但未 checkpoint 的历史不能被只读检查漏掉；不可使用 immutable 读取掩盖 WAL，且缺失数据库不能被 status 创建（Tasks 4、7）。
- 中文、空格和 `$` 路径及事件文本恰好等于选项名必须保持字面含义，不能被认作项目或经过 shell 展开（Tasks 1、3、7、8）。
- 多步骤失败/优雅中断发生在已有步骤提交之后时，结果必须准确列出已提交项；强制终止则显式报告未确认，不伪造空列表，允许从真实状态核验重试（Tasks 5、7）。
- 持锁进程被强制退出后下一进程能继续；现存 lock 文件和数据库 symlink 别名不得造成假忙或双锁（Task 5）。

---

## 文件布局与统一接口

创建：

- `src/leaf/project_context.nim`：当前目录的项目定位。
- `src/leaf/migrations.nim`：公开 façade 与兼容 migrate 重载。
- `src/leaf/migrations/{types,dsl,operations,sqlite_adapter,fingerprint,files,catalog,generator,history,planner,locking,runner,report,initialization}.nim`：各自只负责同名职责。
- `src/leaf/cli_options.nim`：纯参数解析，不打开数据库/构建应用。
- `src/leaf/db_cli.nim`：无 UI 维护入口构建与运行。
- `tests/nim/migration_compile_support.nim`、`tests/nim/migration_process_fixture.nim`：编译负例/临时 catalog 及跨进程测试辅助。
- `tests/nim/test_project_context.nim`、`test_migration_dsl.nim`、`test_migration_catalog.nim`、`test_migration_generator.nim`、`test_migration_planner.nim`、`test_migration_history.nim`、`test_migration_runner.nim`、`test_migration_locking.nim`、`test_cli_options.nim`、`test_db_cli.nim`、`test_migration_integration.nim`。

修改：`src/leaf/{project,sqlite,sqlite_native,build,scaffold,scaffold_types,scaffold_files,scaffold_templates,scaffold_model_templates}.nim`、`src/leaf_cli.nim`、scaffold README 模板、受影响的旧 CLI 测试与 SDK smoke/docs/workflows。不得改写 `tests/fixtures/scaffold_v1/db/migrations` 的旧 SQL 来让测试变绿。

统一类型定义在 `migrations/types.nim`，后续任务不得另造相似类型：

- `MigrationFormat = mfNimV1 | mfSqlV1`；`ColumnKind = ckText | ckInteger | ckReal | ckBoolean | ckDateTime`。
- `ColumnSpec`：name:string、kind:ColumnKind、nullable:bool、defaultValue:Option[SqlValue]；none 表示没默认，some(SqlValue(kind: sqlNull)) 表示 DEFAULT NULL。
- `TableSpec`：name:string、columns:seq[ColumnSpec]、hasId/autoIncrement:bool；`IndexSpec`：table/name:string、columns:seq[string]、unique:bool。
- `SchemaOperation`：kind 为 moCreateTable/moDropTable/moAddColumn/moRemoveColumn/moRenameTable/moRenameColumn/moAddIndex/moRemoveIndex 的判别式 object；table 分支字段 tableSpec:TableSpec、tableDefinitionProvided:bool；column 分支 tableName:string、columnSpec:ColumnSpec、columnDefinitionProvided:bool；rename table 分支 oldTableName/newTableName:string，rename column 分支 columnTableName/oldColumnName/newColumnName:string；index 分支 indexSpec:IndexSpec。timestamps 展开为普通列操作，不引入第二套反转逻辑。
- `MigrationDefinition`：version:int64、name/sourcePath/sourceChecksum:string、format:MigrationFormat、upOps/downOps:seq[SchemaOperation]、legacyUp/legacyDown:string、hasDown/pending:bool。
- `MigrationRequestKind = mrMigrate | mrRollback | mrForward | mrUp | mrDown | mrStatus`；`MigrationRequest`：kind、target:Option[int64]、steps:int（默认 1）。
- `MigrationRecord`：version:int64、name/sql/format/sourceChecksum/operationsChecksum/downChecksum:string。历史 format 是字符串，以便检测未知格式而不是默认为当前 enum。
- `MigrationDirection = mdUp | mdDown`；`MigrationStep`：version:int64、direction、statements:seq[string]；`MigrationPlan`：steps:seq[MigrationStep]、skipped:seq[int64]。
- `MigrationIssue`：code/message/file:string、version:Option[int64]、direction:Option[MigrationDirection]；`MigrationStatus`：version:int64、name/file/state:string、issues:seq[MigrationIssue]；`MigrationResult`：command/database:string、dryRun/executionConfirmed:bool、planned/executed:seq[MigrationStep]、skipped:seq[int64]、currentVersion:Option[int64]、pendingVersions:seq[int64]、statuses:seq[MigrationStatus]、errors:seq[MigrationIssue]。
- `MigrationError` 继承 DatabaseError，新增 issueCode:string、migrationVersion:Option[int64]、file:string、direction:Option[MigrationDirection]；不遮蔽基类的 SQLite code/extendedCode 整数字段。runner 捕获后放入结果，兼容启动 migrate 重载在失败时抛此异常。`CancelCheck = proc():bool {.closure.}` 是可空的受控取消检查，不是迁移 DSL 中的用户回调。

测试命令约定：在工作目录 `export NIM=/tmp/nim-2.2.6/bin/nim; export PATH=/tmp/nim-2.2.6/bin:$PATH; export LEAF_LIBRARY="$PWD/src"`。单套执行 `$NIM c -r --path:src --nimcache:target/migration-tests/cache --out:target/migration-tests/NAME tests/nim/NAME.nim`。正例应 exit 0；负例断言子编译 exit 非 0 且有文件/行号和约定关键错误。

## Task 1: 当前项目定位，先建立不依赖迁移的协议

**Files:** Create `src/leaf/project_context.nim`、`tests/nim/test_project_context.nim`；Modify `src/leaf/project.nim` 仅限确实需要的共享配置校验，不改变 readProject(path)。

**Interfaces:** Produces `findCurrentProject*(start = getCurrentDir()): Option[Project]`、`requireCurrentProject*(start = getCurrentDir()): Project`。最近配置损坏抛 UiError；没有配置时 find 返回 none，require 提示 cd 到项目。创建 scaffold 不使用这个 resolver 改变写入目录。

- [ ] **Step 1: 写失败测试。** 用 initProject 建立临时 parent/child；断言 root 和深层目录返回同一 root，嵌套项目选最近者，无项目为 none，损坏 child leaf.json 不回退 parent，中文/空格目录保持原路径。
主要测试名与断言（app/childDir 为 Step 1 创建的临时项目和子目录）：
```nim
test "nearest project resolves from nested cwd":
  check requireCurrentProject(childDir).root == realPath(app)
  check findCurrentProject(nonProjectDir).isNone
  expect UiError:
    discard requireCurrentProject(brokenNestedDir)
```

- [ ] **Step 2: 跑 `test_project_context`。** Expected：缺模块/函数失败；保存失败证据。
- [ ] **Step 3: 实现上述两个函数。** 仅向上遍历并调用原 readProject 验证；命中最近配置立即停止。不要全仓库扫描，不猜 `.nim` 入口。
- [ ] **Step 4: 重跑 `test_project_context`、`test_tooling`。** Expected：resolver 测试全部通过，readProject/原构建 API 行为不变。
- [ ] **Step 5: 提交。** `git add src/leaf/project_context.nim tests/nim/test_project_context.nim`（有受控 project.nim 改动则逐路径加入）；`git commit -m "feat: resolve Leaf projects from current directory"`。

## Task 2: 可编译的裸标识符 DSL、操作反转和 SQLite SQL

**Files:** Create `src/leaf/migrations/{types,dsl,operations,sqlite_adapter,fingerprint,files}.nim`（files 本任务只实现身份解析）、`src/leaf/migrations.nim`、`tests/nim/test_migration_dsl.nim`、`tests/nim/migration_compile_support.nim`、`tests/fixtures/migrations/001_create_tasks.nim`。

**Interfaces:** Produces `parseMigrationIdentity*(filename:string): tuple[version:int64,name:string]`（files.nim 的纯函数）、`macro migration*(name, body: untyped): untyped`（每文件输出导出的 `migrationDefinition`）、`invertOperations*(ops: openArray[SchemaOperation]): seq[SchemaOperation]`、`renderStatements*(ops: openArray[SchemaOperation]): seq[string]`、`checkCapabilities*(ops: openArray[SchemaOperation], version: tuple[major,minor,patch:int])`、`sha256Text*(content:string):string`、`operationsFingerprint*(definition:MigrationDefinition):string`、`downFingerprint*(definition:MigrationDefinition):string`。`compileProbe*(files: seq[tuple[path,content:string]], mainPath:string, run=false): tuple[code:int,output:string]` 是仅测试辅助。

- [ ] **Step 1: 写失败测试。** 正例编译用户确认的 create_tasks DSL（title/done 无变量声明）并断言列名、类型、NOT NULL、id、timestamps 和索引。分别覆盖显式 up/down、所有首版操作、默认索引名、autoIncrement、负数/中文/引号默认值。负例覆盖字符串名字、未知/重复选项、重复列、非法默认类型、非空 default=nil、NUL 文本默认、多个 migration、裸 drop 在 change 中缺恢复信息、pending 与真实操作混写。
主要测试名与断言（fixture 为本任务创建的 001_create_tasks 模块）：
```nim
test "bare field tokens compile without variables":
  let d = fixture.migrationDefinition
  check d.version == 1'i64
  check d.upOps[0].tableSpec.columns[0].name == "title"
  check d.upOps[0].tableSpec.columns[0].kind == ckText
  check not d.upOps[0].tableSpec.columns[0].nullable
  check d.downOps[0].kind == moRemoveIndex
  check d.downOps[^1].kind == moDropTable
```

- [ ] **Step 2: 跑 `test_migration_dsl`。** Expected：缺 façade/宏/描述类型失败；正负探针通过 Nim 真编译，不用字符串匹配冒充编译验证。
- [ ] **Step 3: 实现 types 和 operations 的以上接口。** default/nullable 独立，布尔加 0/1 CHECK；逆向反序，timestamps 拆列；显式方向无需猜原定义。`MigrationDefinition.version` 从受控文件名解析 int64，不向 int 截断。
- [ ] **Step 4: 实现 migration 宏、adapter 和 fingerprint 接口。** 解析 nnkCommand/nnkCall、nnkExprEqExpr 与 identifier，维护 line info；安全引用名称、正确 SQL 字面量转义，保留名称原拼写。SHA256 直接复用 vendor，不导入带打包/GUI行为的 release helper；源码与双向操作都参与检查。
- [ ] **Step 5: 重跑 `test_migration_dsl`、`test_sqlite`，补能力边界断言。** 模拟 3.24/3.25、3.34/3.35 验证精确门槛；用内存 SQLite 真执行生成的建表/索引及逆向 SQL。Expected：全部通过，编译声明没有 DB 文件产生。
- [ ] **Step 6: 提交上述精确路径。** `git commit -m "feat: add declarative Nim migration DSL and reversible operations"`。

## Task 3: 自动 catalog 与并发安全模板生成

**Files:** Create `src/leaf/migrations/{catalog,generator,locking}.nim`、`tests/nim/test_migration_catalog.nim`、`tests/nim/test_migration_generator.nim`、`tests/nim/test_migration_locking.nim` 的通用 OS 锁部分；Modify `src/leaf/migrations/files.nim` 增加扫描、`src/leaf/migrations.nim` 仅导出本任务接口。

**Interfaces:** Consumes Task 2 的身份解析/DSL/指纹。Produces `MigrationFile`（version:int64、name/sourcePath/upPath/downPath:string、format:MigrationFormat）、`scanMigrationFiles*(directory:string):seq[MigrationFile]`、`macro discoverMigrations*(relativeDir:static[string], procName:untyped):untyped`、`catalogInputFingerprint*(directory:string):string`、`nextMigrationVersion*(files:openArray[MigrationFile], now:Time):int64`、`generateMigration*(root,name:string,dryRun=false):seq[string]`；`FileLock` 持有 OS handle，`acquireFileLock*(path:string,timeoutMs=5000):FileLock`、`release*(lock:FileLock)`。通用 POSIX flock/Windows LockFileEx 在本任务完成，不能先交付会留下 stale 存在标记的替代锁。生成使用经过 guardedPath 预检的 `target/leaf-migration-generation.lock`，覆盖扫描/分配/写入，锁文件不纳入源码/发布包。

- [ ] **Step 1: 写失败测试。** 临时目录混合 `001_create_tasks.up/down.sql` 和 `20261008120000000_add_priority.nim`；catalog 真编译后顺序正确，保留旧 name/up SQL；up-only 旧历史可读取，孤立 down/名称不配对、Nim 顶层额外代码、跨格式重复版本、重复名字和 symlink 明确拒绝。
主要测试名与断言：
```nim
test "clock rollback allocates after existing version":
  let existing = @[MigrationFile(version: 20261008120000000'i64)]
  check nextMigrationVersion(existing, fromUnix(0)) == 20261008120000001'i64
```

- [ ] **Step 2: 跑 `test_migration_catalog` 和 `test_migration_generator`。** Expected：缺发现/生成接口失败。
- [ ] **Step 3: 实现 files/catalog 接口。** 仅扫直接文件；导入前 parseStmt 检查协议；使用独立模块 alias 和安全路径，生成指定 procName 返回 seq[MigrationDefinition]。保存旧 SQL 原文，包含路径与 source hash；发布后的源目录不存在也不影响已编译描述。
- [ ] **Step 4: 实现 OS 锁、生成与编号接口。** 锁文件存在不表示持锁，不 unlink；异常/进程退出释放 OS 锁。dry-run 不写任何目录/锁；now 参数支持确定性测试。验证同毫秒连续生成、钟回退、high(int64) 溢出、两个生成进程无覆盖以及模板 pending；只生成 Nim，不修改共享 catalog 清单。
- [ ] **Step 5: 重跑两套并做相同 nimcache 的三次编译。** 第一轮 1 文件，新增第二文件再编译须 2，删除第二再编译须 1；不同遍历顺序及相同时间跨分支重复身份均拒绝/稳定。Expected：结果严格 1/2/1；未执行数据库操作。
- [ ] **Step 6: 提交。** `git commit -m "feat: discover migration catalogs and generate Nim templates"`。

## Task 4: 只读历史、向后兼容与纯计划器

**Files:** Create `src/leaf/migrations/{history,planner}.nim`、`tests/nim/test_migration_history.nim`、`tests/nim/test_migration_planner.nim`；Modify `src/leaf/sqlite.nim`、`src/leaf/sqlite_native.nim` 限只读打开和连接状态查询。

**Interfaces:** Produces `openDatabaseReadOnly*(path:string):Database`（缺文件失败，不 mkdir）、`databaseFile*(db:Database):string`、`isAutocommit*(db:Database):bool`、`sqliteRuntimeVersion*():tuple[major,minor,patch:int]`，绑定 sqlite3_db_filename/sqlite3_get_autocommit/sqlite3_libversion_number。历史接口 `readMigrationHistory*(db:Database):seq[MigrationRecord]`（不存在表视为空）、`upgradeMigrationHistory*(db:Database,catalog:openArray[MigrationDefinition])`（由 runner 控制事务）、`inspectMigrationHistory*(catalog:openArray[MigrationDefinition],history:openArray[MigrationRecord]):seq[MigrationStatus]`；纯函数 `planMigrations*(catalog:openArray[MigrationDefinition],history:openArray[MigrationRecord],request:MigrationRequest):MigrationPlan`。

- [ ] **Step 1: 写失败测试。** fixture 版本 1/3 已执行、2 未执行：migrate/forward 补 2，rollback 取 3，to=2 先 down3 再 up2，to0 全撤销；steps 超过数量/零/负数、未知 target、指定已 up/未 up 的 no-op 符合 spec。
主要测试名与断言（catalog 为 1/2/3，history 为已执行 1/3）：
```nim
test "pending is a set difference rather than maximum version":
  let p = planMigrations(catalog, history, MigrationRequest(kind: mrMigrate))
  check p.steps.mapIt((it.version, it.direction)) == @[(2'i64, mdUp)]
```

- [ ] **Step 2: 跑 `test_migration_history`、`test_migration_planner`。** Expected：缺接口失败。
- [ ] **Step 3: 实现 sqlite 四个接口及只读读取。** 不改变 openDatabase 的父目录行为。测试 absent path/readonly parent 没有创建文件；WAL 连接有已提交未 checkpoint 的历史时 readonly 查询能读到，禁止用 immutable 忽略 WAL。
- [ ] **Step 4: 实现历史/计划接口。** upgrade 增加 format/source_sha256/operations_sha256/down_sha256，不丢原列；新 nim-v1、旧 sql-v1 与未知格式区分。保留旧 name/up 精确比较，首次 down 基线标记 legacy-unverified-down；检查全部 applied 缺失/改变后再选择步骤。plan 不写数据库。
- [ ] **Step 5: 重跑两套及 `test_sqlite`。** 测试旧三列表升级、升级回滚、源/注释/反向修改、历史表形状损坏、缺迁移、无 down、多步含不可逆项全量 preflight；status 报具体 issue，不偷偷修复。Expected：全部通过，原底层 migrate 测试仍通过。
- [ ] **Step 6: 提交。** `git commit -m "feat: plan migration directions and validate immutable history"`。

## Task 5: 整命令 OS 锁、事务 runner 与报告

**Files:** Create `src/leaf/migrations/{runner,report}.nim`、`tests/nim/test_migration_runner.nim`、`tests/nim/migration_process_fixture.nim`；Extend `tests/nim/test_migration_locking.nim` 的数据库规范路径/进程测试；Modify `src/leaf/sqlite.nim`、`src/leaf/sqlite_native.nim` 的 scoped authorizer、`src/leaf/migrations.nim` 增加新 migrate 重载。

**Interfaces:** Consumes Task 3 的 `FileLock/acquireFileLock/release` 与 Task 4 的历史/计划/连接状态接口。Native 增加 `ProgressHandler = proc(context:pointer):cint {.cdecl.}`、`setProgressHandler*(db:ptr SqliteConnection,interval:cint,callback:ProgressHandler,context:pointer)` 绑定 sqlite3_progress_handler，callback 不允许异常穿过 C 边界。Produces `executeMigrationScript*(db:Database,sql:string,shouldCancel:CancelCheck=nil)` 作用域 guard 禁止事务控制/历史写入并异常安全恢复框架管理状态；`runMigrations*(db:Database,catalog:openArray[MigrationDefinition],request:MigrationRequest,shouldCancel:CancelCheck=nil):MigrationResult`、`migrate*(db:Database,catalog:openArray[MigrationDefinition])`；`resultJson*(result:MigrationResult):JsonNode`、`resultText*(result:MigrationResult):string`、`resultExitCode*(result:MigrationResult):int`。

- [ ] **Step 1: 写失败测试。** 内存库正向/回滚/重复运行；两条迁移第二条失败时第一条存在且历史只有第一条、第二条 DDL 消失；修复尚未执行项后重试；脚本试 COMMIT/修改 leaf_schema_migrations 失败且 guard 恢复。
主要测试名与断言（第二条先建 partial，再执行失败操作）：
```nim
test "failed later migration preserves prior commit only":
  let r = runMigrations(db, catalog, MigrationRequest(kind: mrMigrate))
  check r.executed.mapIt(it.version) == @[1'i64]
  check r.errors.len == 1
  check db.query("SELECT name FROM sqlite_master WHERE name = 'partial'").len == 0
  check readMigrationHistory(db).mapIt(it.version) == @[1'i64]
```

- [ ] **Step 2: 跑 `test_migration_runner`、`test_migration_locking`。** Expected：缺 runner/锁接口失败。
- [ ] **Step 3: 接入数据库整命令锁并实现 SQLite guard。** 复用 Task 3 OS 锁，持有强引用并在全部异常/中断分支释放。使用真实规范 DB 路径；memory 不创建文件。框架管理的 guard 已活动时拒绝重入；借用裸 handle 自行改变 authorizer 不属于受支持的迁移组合，不能声称 SQLite 有查询旧 authorizer 的 API。
- [ ] **Step 4: 实现 runner/report 与 façade migrate。** 校验连接、autocommit、历史和全计划能力；拿锁后重新读取/计划；升级历史在受控事务内；每 step 执行 SQL+历史记录一起提交。步骤边界与 SQLite progress handler 检查 shouldCancel，取消时中止当前 SQL/回滚并返回130，finally 清除框架 progress handler。结果保留计划和实际提交项，正常 runner 设置 executionConfirmed=true，读取历史成功后才设置 currentVersion=some(maxVersion)。所有 JSON 版本字符串，未知 current 为 null，未确认 execution 的 executed 为 null 而不是空数组；启动重载失败抛 MigrationError。现有旧签名不重解释/丢弃历史。
- [ ] **Step 5: 跑真实子进程测试及两套单测。** 相同 DB migrate/migrate 不重复，migrate/down 不交错整批，等待锁后 pending 重算；5 秒超时 issue；kill 持锁 child 后重入成功，已存在 lock 文件不假忙，symlink DB 别名串行。中断发生在第一步提交后时撤销当前步/返回130并准确报告提交列表；跨线程/活动事务拒绝。检查 child/临时目录全部清理。
- [ ] **Step 6: 重跑 `test_sqlite`、`test_model_transactions`、`test_model_adapter`。** Expected：runner 与旧 ORM 连接/事务语义均通过，失败未让 authorizer 状态污染下一次普通 SQL。
- [ ] **Step 7: 提交。** `git commit -m "feat: execute reversible migrations with process locks and atomic history"`。

## Task 6: 当前目录脚手架、数据库初始化与旧项目接入

**Files:** Create `src/leaf/migrations/initialization.nim`；Modify `src/leaf/{scaffold,scaffold_types,scaffold_files,scaffold_templates,scaffold_model_templates}.nim`、`src/leaf/project.nim` 的最小模板判定、`src/leaf_cli.nim` 的 scaffold 分派（仅该分支，确保新 API 提交后 CLI 仍编译）；Modify `tests/nim/test_scaffold.nim`、`tests/nim/test_scaffold_model.nim`；Create/extend `tests/nim/test_migration_integration.nim` 的文件生成部分。

**Interfaces:** `ScaffoldMode = smApplication | smResource`，`ScaffoldOptions` 保留 target/fields/dryRun，加 mode，移除 project selector；`parseScaffoldOptions*(args:seq[string]):ScaffoldOptions`；`generateScaffold*(options:ScaffoldOptions,root:string):seq[string]`（root 由 CLI 选定，不是公开 CLI 参数）。`ResourceSpec.migration` 改 int64；`initializeDatabaseProject*(project:Project,dryRun=false):seq[string]`。配置契约 `databasePath*():string`、`openApplicationDatabase*(path=databasePath()):Database`，catalog 的 applicationMigrations 由 Task 3 生成。

- [ ] **Step 1: 写失败测试。** 已存在的空 cwd 正常生成、不另建子目录；`.git` 和无关文件保留，README/用户源码冲突全部列出且零写入；无参数/模型字段参数两模式，MODEL 无字段和旧 --project/目录形式失败。
主要测试名与断言（cwd 已存在，但没有生成目标文件）：
```nim
test "full scaffold writes existing cwd without nested directory":
  discard generateScaffold(ScaffoldOptions(mode: smApplication), cwd)
  check fileExists(cwd / "leaf.json")
  check fileExists(cwd / "db/catalog.nim")
  check not fileExists(cwd / cwd.extractFilename / "leaf.json")
```

- [ ] **Step 2: 跑 scaffold 两套和 integration 文件生成部分。** Expected：当前 root 必然存在与旧参数检查相关断言失败；不能删测试来逃过升级要求。
- [ ] **Step 3: 实现 types/parser/current-directory writePlan，并只接好 scaffold CLI 分支。** 无 MODEL 的 root=getCurrentDir()，resource root=requireCurrentProject().root；旧 CLI 该分支取消 args.len>=3 限制并向 generateScaffold 传 root，不等待 Task 7 才修复编译。现有 scaffold 测试改为在目标 cwd 调用或使用带显式 root 的内部 API。逐文件预检并保留原 root/已有目录；untouched init 的四文件全匹配才允许安全替换 leaf.json/asset，保留 src。预览与普通写失败不留新文件、不丢旧文件；编辑过 init 拒绝。
- [ ] **Step 4: 实现初始化、catalog 和 schema3 生成。** config/db 纳入 include；新 Task/resource 生成真实 Nim DSL，model_schema2 有 timestamps/id 默认，model_schema1 保留 service/AUTOINCREMENT。旧 schema1/2 注册与 SQL 原文匹配时接入稳定兼容 wrapper 并把 migration 表示转十进制字符串；人工改文件拒绝。db init 对受控同配置幂等、自定义配置不覆盖，并明确自定义入口需手动调用。
- [ ] **Step 5: 重跑生成/既有 scaffold 与 Model 测试。** 用复制的 v1 fixture 接入，旧库正向历史保持不变、新资源为 Nim、应用自动 migrate，注入 memory 与 withDatabase 仍工作；生成/import 不创建 DB，include staging 可找到配置/catalog。Expected：全部通过，旧 SQL fixture 没有改动。
- [ ] **Step 6: 提交。** `git commit -m "feat: initialize current-directory scaffolds with migration catalogs"`。

## Task 7: CLI 参数统一与无 GUI 维护入口

**Files:** Create `src/leaf/cli_options.nim`、`src/leaf/db_cli.nim`、`tests/nim/test_cli_options.nim`、`tests/nim/test_db_cli.nim`；Modify `src/leaf_cli.nim`、`src/leaf/build.nim`、`src/leaf/{developer_options,runner}.nim` 仅必要参数校验；受影响的 `tests/nim/{test_pack_cli,test_process_io,test_diagnostics}.nim` 同提交改调用，测试 helper 修改 `tests/nim/migration_compile_support.nim`。

**Interfaces:** `CliCommandKind = ccHelp | ccVersion | ccVerifySdk | ccInit | ccScaffoldApp | ccScaffoldResource | ccMigrationGenerate | ccBuild | ccPack | ccDoctor | ccRun | ccDeveloper | ccDatabase`；`CliCommand` 字段 kind:CliCommandKind、scaffold:ScaffoldOptions、request:MigrationRequest、dryRun/jsonOutput:bool、output/binary/target/initDirectory/migrationName:string、runArgs:seq[string]、sdkArgs:seq[string]；`parseCli*(args:seq[string]):CliCommand` 不做 IO。`startHeadlessBuild*(project:Project,entry,output,cacheDirectory:string):BuildJob` 复用现有 Nim 编译参数/Windows path/GCC，跳过 GPUI、stage 和图形 manifest 工具；原 startBuild 签名不变。`executeDatabaseCommand*(project:Project,request:MigrationRequest,dryRun,jsonOutput:bool):int`；生成维护程序调用 `runMaintenance*(databasePath:string,catalog:seq[MigrationDefinition],args:seq[string]):int`（放 db_cli，不能循环依赖 leaf_cli）。测试 helper 在 migration_compile_support 中追加 `runCli*(binary,workingDir:string,args:seq[string],env:StringTableRef=nil):tuple[code:int,stdoutText,stderrText:string]`，有界并发读取两路输出，不经 shell、不能用合并 stderr 的 execCmdEx 假装验证 stdout JSON。

- [ ] **Step 1: 写失败 parser 测试。** 全 spec 命令默认值；拒绝旧 PROJECT/--project；缺值/重复/未知参数；命名事件重复合法，`--change title --project` 是值而非参数；`--log-file` 值和 `--output` 值不作项目。watch/events 互斥。脚手架不接受目录模式。
主要测试名与断言：
```nim
test "current project commands reject selectors but preserve event values":
  check parseCli(@["build"]).kind == ccBuild
  check parseCli(@["g", "scaffold"]).kind == ccScaffoldApp
  check parseCli(@["--headless", "--change", "title", "--project"]).runArgs[^1] == "--project"
  expect UiError:
    discard parseCli(@["build", "."])
  expect UiError:
    discard parseCli(@["db", "migrate", "--project", "."])
```

- [ ] **Step 2: 跑 `test_cli_options` 与 `test_db_cli`。** Expected：缺 parser/maintenance 接口失败；先用纯 parser 证明不构建、不打开 DB。
- [ ] **Step 3: 实现 parseCli 并接入主 CLI。** 解析成功后按类型选择 cwd 或 Task 1 项目；裸 leaf 在项目内启动、外部 help；帮助/doctor/version/SDK verification 不定位项目。按 spec 更新 help。日志输出路径保持调用 cwd；内部 API 的 readProject(path) 继续可用。
- [ ] **Step 4: 实现共享 headless 编译与 DB command。** 在 target/leaf-db 生成安全 import 配置/catalog 的程序，不 import main/UI，不调用自动打开迁移函数。编译失败输出稳定 JSON error 且日志 stderr；运行进程用 parentStreams 保留 stderr/stdout 通道，中断沿用监督器。先用空历史/只读历史规划并通过 sqliteRuntimeVersion 检查所选操作、pending 和方向，预检失败则不打开写库；status/dry-run 不存在 DB 用空历史，存在 DB 只读打开。正常修改随后打开写库，由 runner 拿锁重算全部状态，不能把预检计划当成最终计划。父 CLI 每次运行创建唯一的 target 取消 token 路径，通过环境传给维护 child；中断先写 token，child 在步骤/SQLite progress 中检查并输出最终报告。父进程等待最多10秒完成优雅退出，然后才使用现有 close 强制清理；强制路径设置 executionConfirmed=false，报告 interrupted_unconfirmed 并要求 status 核验，executed/current_version 输出 null，绝不把未确认提交状态显示为全部未执行。无需 Windows 控制台信号，运行结束清理 token。
- [ ] **Step 5: 跑真实 CLI 流程。** cwd scaffold/init/migrate/status/rollback/forward/to/up/down、root与子目录、损坏最近配置、中文/空格/$ 路径；移除 CARGO/设无效 GPUI 路径仍可 db status/migrate；普通 UI build 不退化。检查 stdout JSON 可单次 parse、版本字符串、失败已执行列表、中断130。记录 DB 内容/mtime及 absent parent，证明 preview/status 不升级/创建。
- [ ] **Step 6: 用已有 nimcache 添加/删除迁移再运行 CLI 和 watch 构建。** Task 3 的 1/2/1 目录测试必须在 build/headless 路径也成立；若普通 Nim 行为已保证，勿加多余缓存方案。若真实测试证明 stale，build/headless 使用 Task 3 catalogInputFingerprint 检测变化并在变化时加 --forceBuild:on；成功后才记 fingerprint，目标记录仅写 target。
- [ ] **Step 7: 跑 parser/db CLI、pack CLI、tooling、watch、diagnostics、process IO。** 必须将旧 CLI 位置参数测试换成真实 cwd，不保留后门；internal API 独立 .nim 构建测试继续通过。
- [ ] **Step 8: 提交。** `git commit -m "feat: operate on current projects and run headless database commands"`。

## Task 8: 多分支/SDK 回归、文档与平台验收

**Files:** Extend `tests/nim/test_migration_integration.nim`、`tests/release/{test_sdk,test_model_dependencies}.nim`、`scripts/{smoke_sdk,verify_sdk_install}.nim`（后者如有直接调用才变更）；Modify `README.md`、`docs/{models,scaffolding,development,installation,packaging,verification}.md`、`src/leaf/templates/scaffold/{README,model_README}.md`；检查 `.github/workflows/{ci,model,release,windows-sdk-check}.yml` 的旧调用。

**Interfaces:** Consumes Tasks 1–7 的公开契约；不新增功能接口/CLI 参数。自测 helper 在已创建 cwd 内运行 CLI；migration 模块不加入默认 leaf 导入，未使用数据库项目不增加 SQLite/ORM 依赖。

- [ ] **Step 1: 写失败 integration/SDK 断言。** 模拟分支 A 先运行较高版本、合入分支 B 较低版本后补跑且数据保留；空库执行合并全集；同版本/同名在写入前报双方，语义冲突撤销该步；切回缺迁移分支 status missing、修改拒绝。安装 SDK 无网络可用迁移生成/维护，不依赖 Rust/GUI；新源码和目录发现随 SDK 搬迁有效。
主要测试名与断言（app 已复制较低版本 B 的迁移文件，A 的较高版本已执行）：
```nim
test "merged earlier branch migration runs on existing database":
  let p = runCli(cliBinary, app, @["db", "migrate", "--json"])
  check p.code == 0
  let j = parseJson(p.stdoutText)
  check j["executed"][0]["version"].getStr == earlierVersion
  check j["errors"].len == 0
```

- [ ] **Step 2: 跑 integration 与 release 两套相关测试，保存 red。** 缺预期覆盖时加真实 fixture，而非只检查帮助字符串。
- [ ] **Step 3: 修改 SDK smoke/workflows 调用与文档。** 各 app 建目录后在其 cwd g scaffold、生成资源、检查/事件/pack；不遗留 PROJECT/--project 使用说明。文档含 DSL/类型/能力门槛、版本/branch 规则、pending 填写、legacy 接入、回滚不恢复数据、自定义启动手动接入及安全 dry-run 示例。
- [ ] **Step 4: 全套本地验证。** `$NIM c -r --out:target/nim/test_runner scripts/test.nim`；`cargo test --workspace --locked`；`$NIM c -r --out:target/nim/test_runner scripts/test.nim --release-only`；`$NIM c -r --out:target/nim/test_runner scripts/test.nim --model-only`。必要 GPUI/SDK资源缺失时具体记录阻塞，不把跳过算通过。新的 test_*.nim 应由现有 runner 自动发现；不无故改白名单逃避测试。
- [ ] **Step 5: 平台/SDK 验证与源码巡检。** Linux 真并发/文件锁/目录失败测试；安排 Windows/macOS CI 的 LockFileEx/flock、SQLite门槛与中文路径测试。未授权 push 前只能准备 CI 配置/本地交叉编译并标注未实测。运行 `git diff --check`，检查没有 user 文件/旧 SQL/其它任务改动，没有后台 child/服务泄漏。
- [ ] **Step 6: 提交文档/SDK收口。** `git commit -m "test: verify migration branches and offline SDK workflows"`（精确 add 本任务文件，不 `git add .`）。

## 集成负责人、依赖与执行方式

依赖：Task 1 独立；Task 2 → 3/4 → 5 → 6 → 7 → 8。files 身份解析在 Task 2 定义，Task 3 仅扩展；通用 OS 锁在 Task 3 定义，Task 5 复用，不允许两份独立实现。Task 6/7 编辑 scaffold/CLI 测试及共享基础文件，不能安排两个 writer 同时修改。第一轮默认顺序推进；只有明确不同文件范围的读取/测试可以并行。

依据项目既有编排：主会话负责架构/协调与最后验收；复用一个“日常工作”编码子 Agent，在本执行 workspace 逐任务实现，每次给出本 task 范围/接口/红绿证据/提交与未解决项。不为每个 task 重建 workspace 或重新创建同上下文 Agent。普通修复回同一编码 Agent；疑难且常规处理无解才交“高消耗工作”。没有 UI 工作，不启动前端 Agent。

2026-10-08 已读取 Paseo config 中全部 agentProfiles/notes：日常工作保存为 provider=pi、model=opencode-go/deepseek-v4.1-flash、thinking=high，未设置 modeId；方案设计，架构思考保存为 pi/openai-codex/gpt-6.1-sol/high，与当前主 Agent 相同。启动前必须再读取最新配置，不用名称猜模型、不添加不存在的模式或 feature；本计划记录不是以后无需重新读取的理由。此环境没有 list_profiles MCP，实际通过 CLI daemon 配置读取已保存 profile；不能声称调用了不可用工具。

每个 task 结束主会话核对 VCS diff/接口/实际测试证据，再允许下一 task；阶段失败不继续堆积代码。主会话最后按 spec 第13节逐项架构验收，报告实际测试和未执行项。用户批准本计划前不派发产品编码。

## 计划自查与阶段状态

- Spec 1–5：Tasks 2/5；Spec 6：Task 3/7；Spec 7–8：Tasks 4/5；Spec 9：Tasks 1/7；Spec 10：Task 6；Spec 11：Tasks 5/7；Spec 12–13：Task 8 + 各单套；Spec 14：本执行协议。
- Review Focus 五项均指向带断言的具体任务，不把平台编译/静态阅读当作跨平台实测。
- 所有版本接口 int64，外部 JSON 为 string；旧 Migration int API 保留，模板清单的 model_schema 与模型风格独立。
- 当前只有设计/计划文档，原 SQLite 基线5项通过；尚未运行本计划的 red/green、新功能测试或全套测试。计划自查补齐了共享身份解析/OS锁的前置依赖、WAL只读检查、写库前能力检查，以及跨平台优雅取消与强制终止时不得虚构执行状态的边界。
- 本计划用户审阅通过后进入按既定 Paseo 分工执行；未获得 main 合并/push 授权，保留执行 workspace。
