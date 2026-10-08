# Leaf 数据库迁移管理与当前项目命令设计

日期：2026-10-08

状态：对话方案已确认，本文待用户审阅；尚未开始产品代码实现。

## 1. 意图、已确认要求与边界

用户要继续完善 Leaf 数据库能力，以 Rails migration 为参考，提供创建迁移模板、正向执行、回滚、项目初始化及启动接入。主要调用者是 AI，但脚本、执行状态与失败信息必须便于人工阅读和检查，特别要考虑多分支并行开发后的合并。

已确认要求：

- 新迁移以 Nim 声明式 DSL 编写，不以 SQL 字符串为主要接口。
- 表名、字段名、索引名、迁移名尽量采用裸标识符；真正的文本值才使用字符串。
- 通常只写 `change`，可逆操作自动反转；复杂操作可声明 `up` / `down`。
- 项目内命令不接收 `--project`，不保留这个参数的兼容写法；已有项目路径位置参数也移除。
- `leaf init DIRECTORY` 可以要求新目录；`leaf g scaffold` 不接收目录，直接在当前目录生成完整应用。
- 已存在的 SQL 历史不自动重写。此后的生成器统一生成 Nim 迁移。

本设计选定的默认策略：完整应用启动时执行正向待迁移项，不自动回滚；普通导入不打开数据库。已有项目操作从当前目录向上定位最近的 `leaf.json`；创建完整脚手架严格作用于当前目录。

首版仅支持 Leaf 已有的 SQLite 后端。关联、数据库连接池、多数据库、任意 Nim 数据迁移脚本、数据库备份恢复、自动解决 SQL 语义冲突，以及 schema dump/load 不属于首版。CLI 的当前项目规则和迁移系统一起交付，不新增与其无关的 UI 功能。

## 2. 项目现状与 Rails 源码依据

基线是 `main` 的 `07f2a0dc7d5b3925652d18428f45e04e3a2fcdfb`。

Leaf 当前行为：

- `src/leaf/sqlite.nim` 的 `Migration` 保存 `int version`、`name`、正向 `sql`；执行器按版本排序并使用已执行集合，而不是只比较最大版本。
- `leaf_schema_migrations(version INTEGER PRIMARY KEY, name TEXT, sql TEXT)` 保存实际正向 SQL，拒绝已执行历史被修改或从应用中缺失。
- 每个迁移使用 `BEGIN IMMEDIATE`；SQLite authorizer 禁止脚本自行控制事务。
- 完整脚手架使用 `001/002` 等递增编号，维护共享的 `app/generated/migrations.nim` 与 `.leaf/scaffold.json`；`.down.sql` 没有独立执行命令。
- `config/database.nim` 在应用入口打开数据库并迁移。最小 `init` 项目不默认引入 SQLite。
- CLI 强制传入项目路径；运行类命令直接将最后一个参数当成项目路径，会误解无路径调用中的事件值。
- watch 已扫描 `.nim` 文件，但仍须测试迁移目录新增、删除和 Nim 增量缓存失效。

已下载阅读的 Rails v8.0.2 源码：

- [migration.rb](https://github.com/rails/rails/blob/v8.0.2/activerecord/lib/active_record/migration.rb)：`Migration.next_migration_number`、`MigrationContext`、`Migrator`。
- [command_recorder.rb](https://github.com/rails/rails/blob/v8.0.2/activerecord/lib/active_record/migration/command_recorder.rb)：`record`、`revert`、`inverse_of`、`replay`。
- [migration_generator.rb](https://github.com/rails/rails/blob/v8.0.2/activerecord/lib/rails/generators/active_record/migration/migration_generator.rb)：模板选择与名称检查。
- [generators/migration.rb](https://github.com/rails/rails/blob/v8.0.2/railties/lib/rails/generators/migration.rb)：目录扫描、编号及文件创建协议。

关键事实：Rails 默认编号取 UTC 秒级时间戳与本目录后继编号的较大值，并不协调不同分支的全局唯一性；合并后的重复编号和重复迁移名会失败。待迁移项是文件集合减去已执行集合，因此能补跑后来合并的低版本。通常按版本降序回滚，而不是按实际执行时间倒序。Rails 会显示已执行但没有文件的 `NO FILE`，不保存源码校验和，也不自动解决两条迁移的语义冲突。其 advisory lock 取决于数据库 adapter，不能直接照搬 PostgreSQL 方案到 SQLite。

## 3. 方案选择与模块边界

选择“受限宏 DSL → 操作数据 → 计划/反转 → SQLite 执行器”。相较于自由执行的 Nim `proc`，它限制表达能力，但可以静态检查、独立预览、生成回滚并保持历史与当前 Model 解耦。仅封装 SQL 的普通函数最简单，却不能满足已经确认的可读性和符号风格，因此不选。

职责拆分：

1. **声明层**：`leaf/migrations` 公开 DSL；`untyped` 宏捕获名称与字面量，输出无数据库副作用的迁移描述。
2. **操作与反转层**：保存有类型的列、表、索引、操作序列；验证与生成 inverse，不访问业务 Model。
3. **发现层**：扫描项目的 `db/migrations`，检查文件身份，组合 Nim 声明与旧 SQL 历史。
4. **SQLite adapter**：安全引用名称、序列化默认值、检查能力并生成 SQL。
5. **计划/历史/执行层**：读取历史、验证指纹、选择方向和顺序，获得锁后逐迁移原子提交。
6. **CLI 层**：当前项目解析、生成与维护命令、编译无 UI 的维护入口、输出人类文本或 JSON。
7. **脚手架集成**：生成配置、固定目录发现入口、真实迁移与项目测试。

这些层应为小型模块，不把 DSL parser、CLI、文件扫描、锁和 SQLite 执行全部堆入 `sqlite.nim` 或 `leaf_cli.nim`。原有 `leaf/sqlite` 公共入口继续支持旧调用；新的版本字段明确用 `int64`，不依赖平台 `int` 宽度。

## 4. DSL 外观与声明语义

```nim
import leaf/migrations

migration create_tasks:
  change:
    createTable tasks:
      string title, nullable = false
      boolean done, default = false
      timestamps()

    addIndex tasks, [title]
```

```nim
import leaf/migrations

migration add_priority_to_tasks:
  change:
    addColumn tasks, priority, integer, default = 0
    renameColumn tasks, title, name
```

显式方向也是同一套 DSL，不是任意执行 Nim：

```nim
migration replace_task_index:
  up:
    removeIndex tasks, [title], name = index_tasks_on_title
    addIndex tasks, [title, done], name = index_tasks_on_title_and_done
  down:
    removeIndex tasks, [title, done], name = index_tasks_on_title_and_done
    addIndex tasks, [title], name = index_tasks_on_title
```

Nim 没有 Ruby `:symbol` 对应的原生运行时类型。本 DSL 的名称是宏读到的 `nnkIdent`（及合法的反引号标识符），无需事先声明，不假装它们是运行时 Symbol。数据库名称保存原始拼写，不按 Nim 的忽略下划线比较规则改写；重复数据库名称按 SQLite 的标识符规则检查。

声明约定：

- 每个 `.nim` 迁移文件恰有一个顶层 `migration`，名称必须与文件的名称部分一致。发现层在导入前检查顶层只包含 `import leaf/migrations` 和这个声明，不接受额外可执行语句或业务模块导入；注释不影响语法检查。
- `change` 与 `up/down` 二选一；显式模式必须提供两种方向。
- 表、列、索引、迁移和类型名称只能是合法名称 token，不能是字符串或运行时表达式。
- 默认值只接受匹配类型的字面量（字符串、布尔、整数、有限浮点、`nil`）；非空列不接受 `default = nil`。`nullable`、`unique`、`id`、`autoIncrement` 是布尔字面量。未知选项、重复选项、冲突字段、缺参及未知操作在编译期给出文件/行号。`leaf_schema_migrations` 与 `sqlite_` 开头的表名保留，迁移不能修改执行器自身历史。
- 不允许操作体中的任意函数调用、循环、数据库查询或 Model 操作；内部生成 SQL 不作为首版公开迁移语法。
- 声明与导入只建立描述，不打开连接、不执行 SQL。
- 普通生成模板用唯一的 `pending()` 标记未填写状态，并附注释示例；不能用空迁移悄悄记录成功。`status` 能报告未完成，修改数据库前必须拒绝。真实 scaffold 模板不包含此标记。

## 5. 首版操作、类型与可逆性

| 操作 | 声明形式 | `change` 的反向操作 |
| --- | --- | --- |
| 建表 | `createTable tasks: ...` | 删除该表 |
| 删除表 | `dropTable tasks: ...原结构...` | 按声明重建空表 |
| 重命名表 | `renameTable tasks, archived_tasks` | 交换名称 |
| 加字段 | `addColumn tasks, priority, integer, ...` | 删除该字段 |
| 删除字段 | `removeColumn tasks, priority, integer, ...原选项...` | 重建该字段 |
| 重命名字段 | `renameColumn tasks, title, name` | 交换字段名 |
| 加索引 | `addIndex tasks, [title], unique = false, name = index_tasks_on_title` | 删除同名索引 |
| 删除索引 | `removeIndex tasks, [title], unique = false, name = index_tasks_on_title` | 重建声明的索引 |
| 时间字段 | 建表内 `timestamps()`；已有表 `addTimestamps tasks` | 删除对应时间字段 |

删除表/列用于 `change` 时必须提供原结构/类型以及原选项，不能从迁移时的当前 Model 猜测。显式 `up` / `down` 可以用不带重建信息的删除操作，由另一方向承担恢复结构的责任。`addTimestamps` 添加两个列，对非空表必须采用 SQLite 允许的 nullable/default 组合；不自动改写已有数据。

类型：`string` 与 `text` 对应 TEXT，`integer` 对应 64 位 INTEGER，`float` 对应 REAL，`boolean` 对应带 0/1 检查的 INTEGER，`datetime` 对应 Model 已使用的 REAL Unix 秒。普通列默认可空且没有默认值；可空与默认值是两件独立的事。

建表默认生成 `id INTEGER PRIMARY KEY`，与 schema 2 Model 保持一致；`id = false` 可禁用。开启默认 id 时不允许另行声明同名列。`autoIncrement = true` 仅在有默认 id 时有效，用于保留旧 schema 1 资源的 AUTOINCREMENT 语义；默认 false。`timestamps()` 默认生成 `created_at/updated_at REAL NOT NULL`，值由 Model 写入；`addTimestamps` 采用同样默认，可明确指定 `nullable = true` 或字面默认值用于已有数据。首版不支持外键 DSL、decimal/blob、修改列类型、修改约束或自动重建复杂表。

索引不提供 name 时使用确定性的 `index_<table>_on_<column1>_and_<column2>`，唯一性不改变名称；命名冲突须显式提供裸标识符 name，不能随机命名。

SQLite adapter 检查所需能力：`renameColumn` 要求 SQLite 3.25+，`removeColumn`（包括自动反向）要求 3.35+。不支持时在执行计划进入写入前报告版本与操作，不静默跳过，不默认关闭外键。自动可逆指结构上的 inverse 能被推导，不保证所有 SQLite 版本、现有约束和数据都允许该 inverse 成功；实际失败仍由事务撤销。

逆向按操作的相反顺序执行。例如创建表再加索引，会先删索引再删表。删除列后恢复列、删除表后恢复表都不会找回已删除数据，CLI 和文档必须明确这一点；回滚不是备份。

## 6. 文件发现、编号与模板

目录与格式：`db/migrations/<version>_<snake_case_name>.nim`。新编号使用 UTC `yyyyMMddHHmmssfff` 毫秒级数字，解析为正 `int64`；本目录生成时取当前编号和最大已发现编号加一的较大值。数字是排序/身份编号，不强制每个逻辑递增结果仍是合法日历时刻。旧 SQL 的正整数版本继续有效，所有版本按数值排序。

生成器校验文件名与版本范围、同版本、同迁移名（不含旧数字前缀）及目标文件占用。同目录并发生成不能覆盖已有文件，必须用独占创建/生成锁完成编号选择和写入，并对竞态进行重试或明确失败。预览不创建生成锁或目录。跨分支没有中心编号分配器；毫秒级降低碰撞，不承诺绝不碰撞，发现层仍严格拒绝重复。

`leaf g migration NAME` 使用同一命名规则将名称规范化为 snake_case，生成 `import leaf/migrations`、对应 `migration` 与 `change/pending()` 模板。可以按 `create_*`、`add_*_to_*` 附带注释示例，但不给缺少字段信息的命令编造完整结构。resource scaffold 根据已知字段生成可执行迁移，使用相同编号分配器。

固定入口 `db/catalog.nim` 不记录逐条迁移：

```nim
import leaf/migrations

discoverMigrations("migrations", applicationMigrations)
```

`discoverMigrations` 是顶层宏，路径相对调用源文件；它在编译时发现所有迁移、导入具名描述并生成 `applicationMigrations(): seq[MigrationDefinition]`。磁盘的遍历顺序不影响结果；带数字的文件通过受控路径导入，不要求它们是可直接书写的 Nim 模块标识符。迁移源码和旧 SQL 都编译进入应用，不要求发布后查找开发机路径。

Nim 模块创建、删除、重命名必须在重新编译时改变目录清单。普通 CLI 构建、维护命令和 watch 必须重新执行目录发现，不能只依赖上一轮 Nim 模块缓存。若底层增量机制不能正确追踪目录，构建器应将排序后的文件清单/内容指纹纳入该构建的缓存失效策略，生成产物放 `target`，不制造 Git 共享注册文件。

发现仅扫描该目录的直接迁移文件，不递归追随符号链接。未知迁移后缀、孤立 down SQL、同一 SQL 版本上下行名称不匹配、双重格式占用同一版本均明确失败。只有 up 而没有 down 的旧 SQL 按第 8 节接受为不可回滚历史；保留 `.gitkeep`、README 等非迁移辅助文件不作为迁移。

## 7. 计划、方向与执行语义

所有命令先验证完整目录、身份与已执行历史，再计划执行；获取排他锁后重新读取历史、重新验证并重新计划，不能使用等待锁之前的 stale pending 列表。

| 命令 | 选择规则 |
| --- | --- |
| `db migrate` | 所有未执行项，版本升序，包含较早版本的补跑 |
| `db migrate --to V` | 收敛到版本集合 `<= V`：先降序撤销已执行的 `> V`，再升序补齐未执行的 `<= V` |
| `db rollback --steps N` | 已执行项按版本降序选 N 个；不以实际执行时间排序 |
| `db forward --steps N` | 未执行项按版本升序选 N 个，包含低版本空洞 |
| `db up V` | 只执行指定版本，已执行则报告无操作 |
| `db down V` | 只撤销指定版本，未执行则报告无操作 |
| `db status` | 完整文件/历史状态，不执行迁移 |

`--to 0` 撤销全部已执行项，不补跑；非零 V 必须确实存在。步数默认 1，必须是正整数，超过可用数量就执行全部可用项。指定版本命令不推断依赖，调用者承担其顺序风险；数据库约束失败不能被忽略。这两点、`forward` 对低版本的处理，以及 `--to` 明确收敛集合，比 Rails 的磁盘游标行为更简单，应明确记录为 Leaf 语义。

修改数据库前一次性验证所选每个方向都有实现、非 pending、所需后端能力可用。即使后续某项不可逆，也不能先回滚前面的项再发现这个静态问题。

每条迁移有自己的 `BEGIN IMMEDIATE` 事务，DDL 与插入/删除历史记录一起 COMMIT。该条失败就 ROLLBACK 并停止后续步骤；此前已提交步骤保留，错误报告列出这些版本。不能把多步骤命令描述成全局原子事务。拒绝在已有业务事务内执行维护迁移；迁移 SQL 执行期间 authorizer 禁止自行控制事务和修改历史表（包括旧 SQL），执行器在自己的历史写入阶段解除该限制。恢复 authorizer 等连接状态必须放在异常安全的清理路径。

## 8. 历史不可变性、旧 SQL 与并发锁

沿用 `leaf_schema_migrations`，原 `version/name/sql` 字段保留，增加 `format TEXT NOT NULL DEFAULT 'sql-v1'`、`source_sha256 TEXT`、`operations_sha256 TEXT`、`down_sha256 TEXT`，而不是丢弃已有表。Nim 记录使用 `format = 'nim-v1'`，sql 保存确定生成的正向 SQL，source_sha256 保存源文件字节指纹，operations_sha256 保存规范化双向操作指纹，down_sha256 保存反向计划指纹。版本、名称、类型、默认值、选项及反向定义均纳入检查。不因换行/注释变更自动认可已执行历史。SHA256 复用现有 vendored checksums，不引入网络依赖；未认识的历史格式拒绝执行，不能按当前 DSL 版本重新解释。

历史表升级在修改类命令或启动迁移的受控事务内完成。旧记录仍以原 name/up SQL 精确比较，不把已有 `001_create_tasks` 名字改成新名字。发现 SQL 文件生成的描述必须保留原 name 的历史比较规则。

旧 SQL 成对文件仅作为兼容输入：正向 SQL 保持原文；down 缺失时可执行正向，但回滚预检查明确拒绝。已有旧记录没有 down 指纹，首次接入只能建立当前 down 文件的校验基线，不能声称验证了过去未记录的 down 内容；此情况要在状态/接入说明里明确。未来执行/接入后再检查该基线。旧底层 `db.migrate(openArray[Migration])` 保留，仍执行它原来的严格历史检查。

已执行版本缺文件或指纹变化时：`status` 输出具体版本、路径、`missing/modified`；修改命令与自动启动迁移拒绝执行。不能利用数据库中保存的 SQL 偷偷回滚丢失文件，也不能为了切分支静默删除历史。status 遇到目录重复身份也失败并指出冲突文件。

文件数据库使用数据库规范路径旁的持久锁文件 `<database>.leaf-migrate.lock`，通过 POSIX `flock` / Windows `LockFileEx` 持有整次修改命令的排他锁；文件是否存在不表示持锁，进程退出由 OS 自动释放锁。锁文件不在释放时删除，防止不同 inode 产生双锁。锁等待最多 5 秒，超时明确报告 `concurrent_migration`。锁覆盖所有新维护方向与新应用启动入口；每条步骤仍用 SQLite 写事务。符号链接路径按实际数据库文件（或创建前的规范父目录）统一定位锁。硬链接数据库多路径访问不支持，也不宣传为安全并发用法。

`:memory:` 不创建磁盘锁文件，只防止同连接重入；连接仍须满足已有线程归属约束。新执行器不能劫持既有事务或 authorizer。旧版本程序没有此命令级锁，不承诺新旧执行器混跑的整批互斥；其 SQLite 写事务仍保护单条迁移。

## 9. 当前项目 CLI 的完整协议

项目解析集中在独立 parser/resolver 中：

- 已有项目命令从 cwd 向上查找最近的 `leaf.json`，最近配置损坏时立即失败，不绕过它找到祖先项目。
- 不扫描子目录猜项目，不接受 `--project` 或末尾 PROJECT；报错建议 `cd` 到项目。
- 解析选项先准确消费值，不能把事件、日志文件、输出文件、模型名或版本当项目路径。
- 无项目时裸 `leaf` 显示帮助；已发现但损坏的配置报错；在项目内裸 `leaf` 编译并启动应用。
- `--help/-h`、`--version/-v`、doctor、内部 SDK 校验不依赖项目。
- 明确拒绝未知/重复选项与缺值。事件可重复以表达顺序；事件文本可以恰好等于选项名字。
- 显式输出/日志/二进制路径继续相对调用 cwd 解析；源码和默认产物相对项目根。不要借此次调整悄悄改变旧输出路径规则。

命令清单：

```text
leaf init DIRECTORY
leaf g scaffold [--dry-run]
leaf g scaffold MODEL FIELD:TYPE... [--dry-run]
leaf g migration NAME [--dry-run]
leaf generate ...                         # 与 g 等价
leaf build [--output EXE]
leaf pack --target TARGET [--binary EXE] [--output DIR]
leaf
leaf --watch [DIAGNOSTICS]
leaf --check [DIAGNOSTICS]
leaf --headless [EVENTS] [DIAGNOSTICS] [--stats]
leaf doctor [--json]
leaf --version | -v
leaf --help | -h
leaf --verify-sdk CHANNEL TARGET [VERSION] # 内部工具
leaf db init [--dry-run]
leaf db migrate [--to VERSION] [--dry-run] [--json]
leaf db rollback [--steps N] [--dry-run] [--json]
leaf db forward [--steps N] [--dry-run] [--json]
leaf db up VERSION [--dry-run] [--json]
leaf db down VERSION [--dry-run] [--json]
leaf db status [--json]
```

保留运行选项 `--click KEY`、`--change KEY VALUE`、`--submit KEY VALUE`、`--toggle KEY true|false`、`--list KEY FIRST FINISH`、`--stats`，诊断选项 `--trace`、`--log-file FILE`、`--dump-tree FILE`。事件必须走 headless/check；watch 与事件互斥。打包目标继续是 linux/macos/windows/all，`--binary` 不能与 all 组合，默认输出仍是 dist。

这是有意的 CLI breaking change。仓库中依赖旧 PROJECT 写法的测试、SDK smoke/verify 脚本、文档、安装示例、模板 README 均须改为在目标 cwd 调用。独立 `.nim` 的公共 CLI 位置入口移除，内部 `readProject(path)`、构建 API 和直接 Nim 编译保留；仓库的独立源码测试应使用这些 API 或临时项目配置，不重新引入隐藏项目参数。

## 10. 初始化、脚手架与既有项目接入

### 10.1 当前目录的完整脚手架

`leaf g scaffold` 没有模型参数时在 cwd 生成完整应用；有 MODEL 与字段时向当前项目加入资源，不根据大小写猜模式，不接受目录代替 MODEL。MODEL 没字段时明确报错，不创建同名目录。

当前目录必然已存在，不能沿用原 `newProject` 的“目录存在就失败”。改为逐目标预检：没有目标文件冲突时允许 `.git`、README 以外的无关文件留在目录；若生成目标 README 等已存在，列出全部冲突并不写入。不会删除无关文件、自动建子目录或覆盖用户源码。普通写入失败沿用原有 rollback 能力，目录本身以及用户已有空目录不得被清理。

支持 `leaf init app; cd app; leaf g scaffold` 的安全升级：仅当现有 leaf.json、src/main.nim、src/app.nim、assets/message.txt 与未改动的当前最小模板完全一致，且所有其它生成目标无冲突时，可把 leaf.json 与示例 asset 升级为完整应用模板。原 src 文件保留，不擅自删除。任一模板被用户改过就拒绝并给出冲突说明，不试图合并任意 Nim 源码。已有完整 scaffold 无参数重建也拒绝覆盖。

完整模板生成 `db/catalog.nim`、Nim 初始 Task 迁移、config/database.nim；resource scaffold 用 Nim 迁移及固定发现入口，不再为每次迁移改共享 migrations 注册列表。

### 10.2 db init 与启动入口

`leaf db init` 需要已经存在的当前 Leaf 项目，仅安装数据库目录、固定 catalog 和配置，不打开数据库、不运行迁移。新增 config/db 后，使用经过验证的 JSON 结构更新把这两项补入 leaf.json 的 include，保留已有入口、元数据及其它包含项，以便 pack 的 staged project 能编译这些模块；整个写入计划仍要检查原内容并支持普通失败恢复。重复调用对完全匹配的已有配置报告已初始化；对自定义或冲突文件报错而不是覆盖。`--dry-run` 不创建任何文件。

完整应用模板在 `createApplication` 的显式入口调用 `openApplicationDatabase`，使用编译嵌入的 catalog 并执行正向 migrate；保留测试注入连接和 withDatabase 作用域。默认路径继续使用 `getDataDir() / <应用名> / application.sqlite3`，`LEAF_DATABASE_PATH` 覆盖；CLI 和应用引用同一个配置函数，不各自推导路径。

最小 init 与自定义项目执行 db init 后，不能用 AST 猜测任意用户入口插入代码：生成配置并报告需在启动入口调用的函数/示例。完整 scaffold 保证自动接入；普通导入仍无副作用。这一区别应在成功输出中明确，不把“配置已创建”说成“自定义启动已接入”。

### 10.3 旧 scaffold

接入前保留旧 SQL、模型 API、迁移版本、名称与原数据库路径。对生成器可确认、未修改的旧 `app/generated/migrations.nim`，db init/资源生成的接入步骤可以替换为委托固定 catalog 的兼容入口，使原调用迁移函数的配置继续工作；人工修改的配置或注册文件拒绝自动覆盖，并给出人工接入示例。

已有 schema 1/2 清单继续读取。为保存 64 位迁移编号且避免 JSON 浮点消费者丢精度，新 scaffold 清单升级为 schema 3，新增 `model_schema: 1|2` 保存原模型生成语义，并把 resource.migration 编号保存为十进制字符串。新应用为 `model_schema: 2, model_api: 1, timestamps: true`；schema 1 接入后保留 `model_schema: 1` 的 service/普通对象/无时间字段及 AUTOINCREMENT 模板，不强行添加 schema 2 的声明要求。旧清单接入只转换表示和发现入口，不升级业务 Model 或重写历史 SQL。页面/路由清单仍按现有规则管理，其多分支 Git 冲突不宣称由迁移自动发现解决。

## 11. 无 UI 维护入口、预览与结果格式

数据库命令编译项目独立维护入口，仅导入 database 配置与 catalog，不导入 `main.nim`/UI，也不调用应用的自动 migrate 打开函数。必须复用 SDK 编译器、源码路径、ORM 编译参数、进程监督和中断能力，但不调用 `ensureGpui` 或启动 GUI，支持未安装 Rust/图形依赖的离线 SDK 数据维护。

编译入口及缓存放 `target/leaf-db`，不写入需提交的共享注册表。项目配置本身是受信任 Nim 源码，不把这种执行称为不可信脚本沙箱；DSL 内部受限并不阻止普通模块顶层自行执行 Nim。

`status` 和执行 `--dry-run` 使用只读数据库句柄，不自动建数据库、父目录、历史表、迁移锁或升级记录。数据库尚不存在时把历史视为空。允许编译产物写 target，但数据库和迁移源码必须保持不变。预览展示方向、版本、名称、源码路径及生成 SQL，明确没有执行；不能把预览称为已经验证数据库语义兼容。

状态包括 up/down、pending-template、modified、missing、legacy-unverified-down；状态报告检测到损坏历史时返回失败状态而非假装数据库可安全迁移。

`--json` 在 stdout 只输出一个对象（含 command、database、dry_run、planned、executed、skipped、current_version、pending_versions、errors），版本是十进制字符串，避免超过 JavaScript 安全整数。错误含稳定 code、message、version、file、direction；编译日志和人类诊断走 stderr。没有 JSON 选项的命令仍输出简洁人类文本。

正常/无操作退出 0，参数/编译/历史/SQLite/锁失败退出 1，中断退出 130。停止时撤销当前事务并释放锁；已提交步骤在报告中可见，不能让 AI 因错误输出误以为全部未执行而重复创建。

## 12. 多分支开发协议

1. 两个独立分支新增不同编号 Nim 文件，无需修改共享迁移注册表；合并后自动发现二者。
2. 较大版本已运行，再合入较小未运行版本：普通 migrate 仍补跑较小版本。
3. 同版本/同名冲突必须在数据库写入前指出两个文件。仅对确认未在任何需保留环境执行的迁移重编号；已执行迁移不能重编号。
4. 创建相同表、删除字段与建字段索引、顺序依赖等不会被时间戳解决。CI 必须测试空库全部执行和代表性的已有库增量执行；语义失败时保留历史并新增修正迁移/修正尚未执行的迁移。
5. 切回不包含已执行迁移的分支，修改命令/启动拒绝并列出 missing。开发分支使用独立 LEAF_DATABASE_PATH，或在切分支前于拥有原迁移的分支显式回滚，不自动破坏数据库。
6. 回滚按版本降序，不保证是实际最近执行的迁移。命令必须显示选中项，人工/AI 可用 dry-run 检查。原表/列数据的恢复需另有备份。

## 13. 验收标准

### DSL 与反转

- 裸名称无需定义变量；非法名称、字段重复、默认类型不符、未知选项、多个 migration、方向冲突、未完成模板有明确定位。
- string/boolean/integer/float/datetime/default/nullable/id/timestamps 与现有 Model 存储兼容。
- 多操作逆序，显式 up/down，删除缺恢复信息不可自动反转；后端能力不足在写入前失败。
- 导入 catalog/声明不打开数据库，不依赖当前 Model；没有秘密运行任意操作体。

### 发现与生成

- 创建目录、模板、dry-run、名称与版本检查、同目录并发生成、路径逃逸/符号链接保护。
- 旧 SQL 与新 Nim 混合发现、同版本跨格式冲突；编译嵌入与 SDK 搬迁运行。
- 新增/删除文件后普通 build、db CLI、watch 重编译都反映新目录，已有模块缓存不漏文件。

### 执行与历史

- migrate 重复执行无重复副作用；乱序低版本合入能补跑。
- to/up/down/steps/0/未知版本/非法步数/无操作行为符合第 7 节。
- 每迁移事务内记录历史，失败撤销当前步，先前提交保留；重试恢复。
- 源/反向/缺失历史拒绝，旧 SQL 记录升级不丢失；只读状态不升级/创建数据库。
- 两进程 migrate、migrate 对 rollback 串行，等待后重新读取历史；锁超时、持锁进程退出、事务内调用、跨线程连接拒绝。

### CLI 与初始化

- root/子目录/嵌套项目/损坏最近配置/非项目下操作正确；删除 --project 与 PROJECT 位置写法并明确失败。
- 事件值、选项形状文本、缺值、重复参数、输出路径不被误认项目。
- cwd 完整脚手架生成、untouched init 升级、编辑过 init 拒绝、无关文件保留、目标冲突与写入失败回滚。
- 新应用自动正向迁移，生成器和 import 无数据库副作用；测试连接注入继续可用。
- SDK maintenance 不引入 UI/GPUI/Rust 依赖；JSON 单对象、版本字符串、退出码与中断清理。

### 回归与跨平台

- 运行现有 SQLite、Model、scaffold、project/tooling、pack CLI、watch、SDK smoke/发布相关测试并改掉旧命令调用。
- Linux 运行真实并发与文件系统测试；Windows/macOS 运行或交给 CI 验证平台锁、SQLite 能力、中文/空格路径。只报告实际执行结果，不用 Linux 结果替代跨平台实测。

## 14. 实施前检查与流程

本功能使用 Paseo 托管 worktree `feat/database-migrations`，与原生控件工作隔离，后续编码、修复和验收复用同一空间。设计文档批准后再编写实施计划、确认执行方式；常规编码按实际 Agent profiles 的配置派发，主会话承担方案与协调，不创建重复架构角色。最终架构验收在该空间执行。

已找到 `/tmp/nim-2.2.6/bin/nim`。在隔离空间实际运行基线 `tests/nim/test_sqlite.nim`，5 项全部通过；尚未运行整个 Nim/Rust/平台测试套件，也未实现本设计中的新测试。

只提交本功能设计/代码，不触碰原主目录里原生控件任务的未跟踪文档。合并和推送仍需用户授权；在安全验证之前保留功能空间，不归档原协调入口。
