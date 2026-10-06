# Leaf 应用与业务资源脚手架设计

## 目标与范围

用户已明确要求同时实现完整应用脚手架与业务资源脚手架。新增 `leaf g scaffold` 和等价的 `leaf generate scaffold`，支持两种明确区分的调用：无 `--project` 时新建完整应用；有 `--project` 时向现有脚手架应用添加一个业务资源。一条命令生成对应的页面、模型、逻辑、服务、路由与迁移，自动完成注册。

页面按页面组组织：每组包含 `logic.nim` 和 `views/`，View 与交互逻辑分别保存，相关代码集中。项目元数据继续使用已有 `leaf.json` 格式。

## 当前基础

- CLI 已有 `init`、构建、检查、headless、watch 和打包。
- `initProject` 目前创建 `src/main.nim`、`src/app.nim` 和资源示例。
- 通用文件自动发现与后台调度不在本次范围内。
- 保留原有 `leaf init DIRECTORY` 的行为，独立增加完整模板命令。

## 命令约定

```sh
leaf g scaffold my-app
leaf generate scaffold my-app
leaf g scaffold my-app --dry-run
leaf g scaffold Note title:string archived:bool --project my-app
leaf generate scaffold Contact name:string active:bool --project my-app
leaf g scaffold Note title:string --project my-app --dry-run
leaf --check my-app
leaf --headless --change task_draft "第一项任务" --click task_add my-app
leaf --watch my-app
```

`--dry-run` 输出计划创建和更新的相对路径，不写文件、不编译、不启动窗口。缺少目标、缺少选项值、重复选项、未知选项和应用模式中的字段参数均失败。资源模式必须指定 `--project` 并提供至少一个字段，避免根据大小写或当前工作目录猜测命令含义。完整模板已有 Task 示例，重复生成 Task 应当报告资源冲突。

## 模板结构

```text
my-app/
  main.nim
  leaf.json
  README.md
  .gitignore
  .leaf/scaffold.json
  app/
    application.nim
    shell.nim
    pages/home/
      page.nim
      logic.nim
      views/index.nim
      views/search.nim
      views/settings.nim
    components/empty_state.nim
    models/task.nim
    services/task_service.nim
    generated/pages.nim
    generated/migrations.nim
  config/
    application.nim
    database.nim
    routes.nim
    generated/routes.nim
  db/migrations/
    001_create_tasks.up.sql
    001_create_tasks.down.sql
  assets/message.txt
  tests/test_home.nim
```

仅生成有实际职责的文件。提供 SQLite 迁移 SQL 与数据库路径配置；网络客户端和后台工作在模板 README 中给出明确的扩展位置，不生成不存在的运行时能力或伪命令。

## 可运行的默认行为

- 主界面显示任务列表和输入框，支持添加任务。
- 任务模型负责数据类型和名称校验；服务通过参数化 SQL 维护 SQLite 中的任务数据。
- 页面组逻辑维护草稿、搜索词、当前面板和操作错误。
- 首页、搜索、设置 View 共用页面组状态，切换保留草稿和搜索条件。
- 搜索 View 对已有任务进行筛选；设置 View 提供实际影响显示的开关。
- `config/routes.nim` 独立定义首页、搜索和设置的导航名称和目标。
- shell 消费路由配置进行导航，View 通过逻辑操作改变当前路由。
- 运行、headless 检查和打包沿用现有 Leaf 工具。

迁移 SQL 定义任务表，包括 id、title 和 done，附带对应的删除表回滚 SQL。生成命令创建迁移文件，不打开数据库。应用启动时打开 SQLite 连接并按版本执行尚未应用的迁移；已应用版本记录在数据库中，每个版本事务提交，失败回滚。SQL 在编译时嵌入应用；重复启动不会重复执行，已应用历史被修改时报告错误。数据库路径默认位于用户数据目录，可通过 LEAF_DATABASE_PATH 覆盖。

路由为模板提供简单、类型化的 Nim 配置，统一的路由定义类型由 Leaf 提供。`config/routes.nim` 是人工维护的入口，通过稳定的导入接入 `config/generated/routes.nim`。自动生成的页面工厂注册位于 `app/generated/pages.nim`。业务资源生成器更新页面、路由、迁移专用注册文件和 scaffold 清单，不重写 shell、application 或人工路由。

资源内列表、创建和详情/编辑 View 由页面组状态组合，资源的 `/notes` 路由由独立配置注册。首版无需动态路径参数或完整 Rails 式路由 DSL；详情选择使用稳定的业务 ID，而非列表索引。生成前检查清单与自动注册路由的名称和路径冲突；人工 Nim 路由配置可能包含动态表达式，完整路由表在构建应用对象时再统一检查重复名称、路径和不存在的页面目标。

## 业务资源生成

以 `leaf g scaffold Note title:string archived:bool --project my-app` 为例，一次创建：

```text
app/models/note.nim
app/services/note_service.nim
app/pages/notes/page.nim
app/pages/notes/logic.nim
app/pages/notes/views/index.nim
app/pages/notes/views/list.nim
app/pages/notes/views/editor.nim
app/pages/notes/views/detail.nim
db/migrations/<version>_create_notes.up.sql
db/migrations/<version>_create_notes.down.sql
tests/test_notes.nim
```

同时更新 `app/generated/pages.nim`、`app/generated/migrations.nim`、`config/generated/routes.nim` 和 `.leaf/scaffold.json`。不要求用户手工添加导入、页面工厂或路由注册。

- 资源名称必须为合法的单数模型名，生成规范化的 snake_case 文件名和页面组名称，模型使用 PascalCase。
- 首版字段支持 `string`、`bool`、`int` 和 `float`；模型自动增加稳定的整数 id，用户不得重复定义 id。
- 拒绝非法标识符、关键字、不支持的字段类型、重复字段，以及 Nim 标识符规范化后重名的字段或资源。
- 默认复数命名采用末尾辅音加 y 变 ies、末尾 s/x/z/ch/sh 加 es、其余加 s 的规则。文档明确不提供完整英语词形还原，预检按最终路径和类型身份判断冲突。
- 字符串编辑使用输入框，布尔编辑使用复选框，数字编辑使用输入框并在业务提交边界解析及报告错误。有效模型字段使用对应的 Nim 类型。
- 默认页面实现创建、列表、查看、编辑、删除；失败保留草稿，取消编辑不修改已保存数据，保存成功才更新展示状态。
- 服务使用注入的 SQLite 连接；新资源的迁移 SQL 与其字段相匹配，应用下次启动时自动建表，已有记录保持不变。
- 清单保存模型名、规范化的单数文件名、字段与迁移版本；页面路径、路由与整套注册从清单确定性生成。
- SQL 中 id 使用 INTEGER PRIMARY KEY AUTOINCREMENT，string 使用 TEXT，bool 使用 INTEGER 与 0/1 CHECK，int 使用 INTEGER，float 使用 REAL。字段为 NOT NULL，down SQL 删除对应表。
- 迁移版本取现有清单中的下一个整数，并检查 up/down 文件均不冲突；不依赖秒级时间戳，连续生成不会产生同名版本。

完整模板中的首页演示与资源生成使用相同模型、服务、页面组和注册契约，避免维护两种互不兼容的架构。

## 资源生成协议

本次资源生成支持完整脚手架创建的应用。普通 `leaf init` 项目和手工组织的应用没有注册协议，缺少 scaffold 清单时在写入前拒绝，并明确说明需要先采用完整应用模板；不擅自覆盖入口或推测用户项目结构。

## 依赖预组装

`pages/home/page.nim` 是页面组的编译入口，预先导入 Leaf、模型、服务和组件，再使用 Nim `include` 组合逻辑与 View 文件。页面组内文件无需重复书写依赖导入。各 View 使用不同的过程名，入口 View 最后组合子 View，避免名称冲突及不明确的加载顺序。

应用模板和每次生成的业务资源均采用页面组预组装方案，资源自动进入统一注册表。生成器不要求页面内逐个手写导入。用户自行添加任意文件的自动发现、逐文件包装、依赖解析和编辑器集成属于后续通用加载器，不作为本命令的完成条件。

数据库连接、网络连接等资源不会在模块导入阶段自动创建；新增资源应由 application 启动流程创建并传递。

## 文件生成规则

- 新项目名称与 identifier 使用现有项目校验和命名规则。
- 新应用目标已经存在时拒绝覆盖，包括空目录和符号链接。
- 资源模式预检已有资源、模型、服务、页面组、测试、迁移和路由冲突；遇到任何冲突不写入。
- 拒绝写入路径中未经允许的符号链接，确保生成文件位于目标应用内。
- 先校验参数、项目协议、清单和文件冲突，再构造完整文件计划并写入。
- 新应用写入失败清理本次创建的未完成项目；资源模式普通可捕获写入失败时恢复原注册文件与清单，删除本次创建的文件。不得删除或覆盖已有业务文件。
- 自动生成的注册文件包含所有权标记；内容与清单生成结果不一致时拒绝更新，保留用户改动并说明冲突。
- 生成器不安装依赖、不调用 Cargo、不访问数据库、不启动后台进程。
- `leaf.json` 的 entry 为 `main.nim`，include 包含入口和实际运行、发布需要的目录；不包含 tests 或 target。
- 保存的记录存于 SQLite，重启或 watch 后保留；草稿、搜索与显示设置为页面状态。

## 实现边界

- 新增独立 scaffold 生成模块及模板目录，避免把模板拼接逻辑堆入 CLI。
- CLI 只解析命令并调用生成器，应用和资源两种模式使用同一文件计划及写入机制。
- 与 init 共用项目名称和元数据计算，必要时提取最小共享函数。
- 不更改既有示例及现有 init 目录结构。
- 新增最小的页面注册与类型化路由运行契约，供两个模式共用，提供显式 leaf/sqlite 连接、参数绑定与事务迁移能力，不引入通用 ORM 或后台调度器。

## 验证

1. 使用 CLI 生成项目，readProject 可以读取，入口与发布文件有效。
2. 两个命令别名生成等价项目；dry-run 不产生任何文件。
3. 已有目标、符号链接、非法名称和选项不修改原有数据。
4. 实际编译生成项目，执行 headless 添加、搜索、导航和设置操作，验证页面内容及状态保留。
5. 运行生成的测试，验证空名称校验、任务添加和筛选行为。
6. 在临时 SQLite 数据库中执行生成的 up/down SQL，验证字段、布尔约束和回滚。
7. 连续添加两个资源并实际编译整个应用，使用 headless 验证两者均可导航，CRUD 与数字校验有效，旧页面状态保持且原文件不变。
8. 对重复资源、同名字段、路由冲突、修改过的注册文件、损坏清单和普通 init 项目验证生成失败且文件内容不变。
9. 验证资源模式 dry-run 不写入、不更新清单；两个别名与相同命令参数行为一致。
10. 验证跨进程持久化、新资源增量迁移、写入失败保留草稿与记录。
11. 验证发布文件包含新增资源和迁移，不包含生成器清单、tests 或 target；运行现有 Nim 回归，仅在相关桥接代码变化时增加桌面验证。
