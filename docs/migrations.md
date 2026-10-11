# 数据库迁移

Leaf 使用 SQLite 和声明式 Nim 迁移。Model 负责查询和持久化；迁移负责表结构，二者不会通过导入模块自动打开数据库。

## 创建和维护

所有项目命令从当前目录向上查找最近的 `leaf.json`，子目录也可执行。旧 PROJECT 位置参数和 `--project` 已移除。

```sh
mkdir my-app
cd my-app
leaf g scaffold
leaf g scaffold Note title:string archived:bool
leaf db status
leaf db migrate --dry-run
leaf db migrate
leaf g migration AddPriority
```

完整脚手架包含 `config/database.nim`、`db/catalog.nim` 和初始迁移，应用启动时正向应用全部未执行迁移。已有自定义项目可运行 `leaf db init` 安装配置；按命令输出在启动入口显式调用 `openApplicationDatabase()`。初始化和生成命令不打开数据库。未修改的 `leaf init` 最小模板可用无参数 `leaf g scaffold` 升级，修改过的模板会报告冲突。

`LEAF_DATABASE_PATH` 覆盖默认的用户数据目录路径；应用和 CLI 使用同一个 `databasePath()` 函数。不同开发分支可使用独立数据库：

```sh
export LEAF_DATABASE_PATH="$PWD/branch.sqlite3"
leaf db migrate --dry-run
leaf db migrate
```

`g migration` 生成 `db/migrations/<UTC毫秒编号>_add_priority.nim`，编号为正 int64。模板中的 `pending()` 必须替换为真实操作；执行器拒绝执行未完成模板。

```nim
import leaf/migrations

migration add_priority:
  change:
    addColumn tasks, priority, integer, default = 0
```

`db/catalog.nim` 编译时自动发现该目录直接包含的迁移，新增、删除文件后重新构建即可，无需修改共享注册表。编译后的目录描述已嵌入可执行文件，可随 SDK 和应用搬迁。

## DSL 和回滚

迁移文件只包含 `import leaf/migrations` 和一个与文件名一致的 `migration` 声明。表、列和索引名使用裸标识符，无需预先定义变量；不允许在迁移内执行任意 Nim 代码。

```nim
import leaf/migrations

migration create_notes:
  change:
    createTable notes:
      string title, nullable = false
      boolean archived, default = false
      timestamps()
    addIndex notes, [title]
```

列类型为 `string`/`text`、`boolean`、`integer`、`float`、`datetime`。SQLite 分别存储为 TEXT、带 0/1 CHECK 的 INTEGER、INTEGER、REAL 和 REAL Unix 秒。普通列默认可空；`nullable = false` 声明 NOT NULL，`default` 是类型匹配的常量。表默认生成 `id INTEGER PRIMARY KEY`；`autoIncrement = true` 选择 AUTOINCREMENT，`id = false` 关闭自动主键。`timestamps()` 生成 NOT NULL 的 created_at/updated_at，业务写入需由 TimestampedRecord 等提供值。

支持 createTable/dropTable、addColumn/removeColumn、renameTable/renameColumn 和 addIndex/removeIndex。`change` 按反序自动生成逆操作；删除操作需要提供原结构以便反转。无法自动反转时明确声明方向：

```nim
import leaf/migrations

migration create_archive:
  up:
    createTable archives:
      string title
  down:
    dropTable archives
```

SQLite renameColumn 需要 3.25+，removeColumn 需要 3.35+；执行前会检查所选双向计划的实际能力，回滚 addColumn 同样需要 DROP COLUMN 支持。回滚仅恢复结构，不恢复已经删除的数据。

## 命令语义

| 命令 | 行为 |
| --- | --- |
| `leaf db status [--json]` | 只读检查完整目录及已应用历史 |
| `leaf db migrate` | 版本升序应用所有未执行项，包括后合入的较低版本 |
| `leaf db migrate --to V` | 先降序撤销大于 V 的版本，再补齐小于等于 V 的未执行项 |
| `leaf db migrate --to 0` | 撤销全部已应用项 |
| `leaf db rollback --steps N` | 按版本降序撤销 N 项，默认 1 |
| `leaf db forward --steps N` | 按版本升序应用 N 项，默认 1 |
| `leaf db up V` / `leaf db down V` | 仅应用或撤销指定版本；已处于目标状态则无操作 |

所有修改命令支持 `--dry-run` 和 `--json`。非零目标版本必须存在，N 必须为正数；指定版本命令不推断表结构依赖。回滚按版本排序，与实际执行时间可能不同。

`status` 和执行预览使用只读连接；数据库不存在时视为空历史，不创建数据库、父目录、历史表或迁移锁。编译缓存仍写入 `target/leaf-db`。预览展示 SQL 和方向，不保证实际执行一定满足数据约束。

每条迁移的 DDL 和历史记录在一个事务内提交，整条命令通过 OS 文件锁串行化。后续步骤失败会撤销当前步骤，此前已提交步骤保留并列于报告。等待锁后重新读取历史和计算计划；锁超时为 `concurrent_migration`。持久 `.leaf-migrate.lock` 文件存在不代表锁被持有，不要删除它来解锁。进程退出由系统释放锁；硬链接数据库的多路径并发不受支持。

## 历史和多分支

`leaf_schema_migrations` 保留版本、名称、SQL 和源文件、双向操作、反向定义的 SHA256。已应用迁移缺文件、内容变化（包括注释）或历史格式未知时，修改命令和应用启动拒绝执行；`status` 指出版本和文件。修复结构时新增迁移，不能重写已执行历史。

两个分支新增不同编号的文件，合并后自动发现二者。已运行较高版本的数据库会补跑后合入的较低版本。重复版本、重复名称和跨 Nim/SQL 格式冲突在写入前拒绝；时间戳不能解决创建同一张表等语义冲突。切回缺少已应用迁移的分支会报 missing，应使用分支独立数据库，或先在拥有完整历史的分支显式回滚。

旧 `.up.sql` / `.down.sql` 文件继续按原文、原名称读取，不改写历史 SQL。只有 up 的旧迁移可正向运行，但不可回滚。旧三列历史在受控事务内升级；第一次接入 down 文件仅建立当前校验基线，`legacy-unverified-down` 表示过去未记录的反向内容无法验证。生成器只转换可确认未修改的旧注册文件；人工配置冲突需手动接入，schema 1 的 service 与 AUTOINCREMENT 语义保留。schema 3 清单用 `model_schema` 记录业务模型版本，迁移编号保存为十进制字符串。

## 自动化和取消

数据库命令编译独立维护入口，只导入配置和 catalog，不需要 Rust、GPUI 或显示服务器。配置是项目受信任的 Nim 源码，不是脚本沙箱。

`--json` 的 stdout 只有一个对象，诊断走 stderr。版本是十进制字符串；字段含 command、database、dry_run、execution_confirmed、planned、executed、skipped、current_version、pending_versions、statuses 和 errors。历史未知时 current_version/pending_versions 为 null；执行未确认时 executed 也为 null。正常/无操作退出 0，错误退出 1，中断退出 130。

中断先通过唯一取消 token 请求维护程序撤销当前事务，最多等待 10 秒后强制清理。完整且通过验证的最终报告保留实际提交项；没有报告时不推断哪些步骤提交，应运行 `db status` 核验。进程清理失败与已验证的数据库提交事实分别报告。Linux 使用 subreaper 回收后代，Windows 使用 Job Object；其他 POSIX 系统使用保留未回收组长的进程组监督，配置自行脱离进程组启动的任意外部守护进程不属于该后端的清理保证。

专项测试不需要 GUI：

```sh
nim c -r --out:target/nim/test_runner scripts/test.nim --database-only
```

Windows/macOS 的锁、系统 SQLite 和中文路径由 `.github/workflows/database.yml` 实际运行验证；本地 Linux 测试和交叉生成 C 不能代替这些平台结果。
