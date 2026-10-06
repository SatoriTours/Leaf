# Leaf 应用与资源脚手架实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. 用户已批准规格并明确要求开始开发；本次在当前共享工作区直接实施。

**Goal:** 实现页面组、独立路由和两种一键脚手架，并验证生成应用可以编译和交互。

**Architecture:** Leaf 提供 PageGroup、PageDefinition、Route 和 Router。生成器输出普通 Nim 模块与页面组 include 文件；资源清单驱动专用注册文件更新，人工代码保持独立。

**Tech Stack:** Nim 2.2.6、Leaf、Nim 标准库；生成 SQLite SQL，使用 Python sqlite3 验证。

**Spec:** ../specs/2026-10-06-scaffold-design.md

## Global Constraints

- 不改变现有 leaf init、示例和 leaf.json 字段含义。
- 两种命令都支持 generate/g 别名与 --dry-run。
- 生成器不安装依赖；应用默认使用 SQLite，并在启动时事务执行待应用迁移。
- 生成前检查冲突和符号链接；普通写入失败回滚本次改动。
- 页面依赖预组装，资源生成自动更新专用注册，不覆写人工代码。

## Review Focus

- Nim 忽略下划线和部分大小写的标识符冲突。
- 已被修改的自动注册文件、损坏清单与不含注册协议的 init 示例。
- 多次生成迁移版本冲突与资源名称复数规则。
- 页面切换、取消编辑、失败提交时的状态保留。
- 发布文件完整性与写入路径中的符号链接。

## Task 1: 页面组与路由运行时

**Files:** src/leaf/routing.nim、src/leaf.nim、tests/nim/test_routing.nim。

**Interfaces:** PageGroup(render: proc(ctx: BuildContext, view: string): Node)、PageDefinition(name, views, create)、Route(name, path, page, view)、newRouter、navigate、currentRoute、renderPage。

- [x] 编写并运行失败测试：惰性创建一次、跨路由保留状态、拒绝重复及无效路由。
- [x] 实现接口，运行路由测试及核心回归。

## Task 2: 两种生成器和 CLI

**Files:** src/leaf/scaffold*.nim、src/leaf/templates/scaffold/、src/leaf_cli.nim、tests/nim/test_scaffold.nim。

**Interfaces:** ScaffoldOptions(target, project, fields, dryRun)、generateScaffold(options): seq[string]；CLI 分派 g/generate scaffold。

- [x] 编写 CLI 生成、预览、冲突和项目协议测试，确认现有 CLI 不支持命令。
- [x] 实现参数与清单校验、文件计划、预检和回滚。
- [x] 实现完整应用模板、资源字段代码与迁移 SQL，自动生成页面和路由注册。
- [x] 编译真实生成应用，执行增删改查、搜索、导航与设置；验证两次资源生成和保留人工修改。
- [x] 在 SQLite 中执行迁移与回滚，验证打包文件收集。

## Task 3: 文档与完整验证

**Files:** README.md、docs/development.md、docs/nim-api.md、docs/scaffolding.md。

- [x] 记录运行接口、两种命令、页面组、注册文件所有权和实际能力边界。
- [x] 运行全部 Nim 回归；核对规格，完成独立代码审查并修复重要问题。
- [x] 保留工作区改动供用户审阅，不主动提交、发布或修改分支。

验证结果：25 组 Nim 测试已运行，24 组通过。已有 test_diagnostics 中 Cargo multicall 用例因本机缺少 libxkbcommon-x11 而失败；其余用例通过。新增 3 个路由与 12 个脚手架测试全部通过，生成应用经 headless CRUD、设置/搜索/状态切换、SQLite up/down 及 Linux 打包验证。审查发现的只读清单回滚、A_B 名称重新加载问题已修复，并加强符号链接祖先检查。

后续 SQLite 修改已完成：用户指定默认数据库使用 SQLite，新增 leaf/sqlite 连接与迁移能力，SQLite 模板在启动时打开连接、执行迁移并注入服务。5 项 SQLite 和 13 项脚手架测试全部通过；最终全量 26 组测试通过 25 组，已有 Cargo diagnostics 用例仍缺 libxkbcommon-x11。独立审查发现的首页数据库错误显示问题已修复。重新启动与解包后的 Linux 程序均验证了建库、迁移和保存记录。

首版清理：用户确认没有已发布的内存版应用，SQLite 清单统一为首版格式；移除旧模板转换说明与升级提示，保留清单校验和数据库结构迁移。
