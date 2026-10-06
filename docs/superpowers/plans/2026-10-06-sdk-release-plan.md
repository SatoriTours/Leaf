# Leaf SDK 发布安装 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 提供 release/beta 自动发布及三个操作系统的一键 SDK 安装。
**Architecture:** CLI 按可执行文件位置发现 SDK；Python 组装归档；原生矩阵构建后集中发布；Shell/PowerShell 校验并安装。
**Tech Stack:** Nim 2.2.6、Rust、Python 标准库、GitHub Actions、POSIX Shell、PowerShell。
**Spec:** docs/superpowers/specs/2026-10-06-sdk-release-design.md

## Global Constraints

- main → beta；vX.Y.Z → release；beta 不成为 latest。
- Linux x86_64、macOS x86_64/aarch64、Windows x86_64。
- 安装包包含 Nim/Leaf/GPUI；Windows 安装器自动安装 MinGW，SQLite 使用系统 winsqlite3。
- 校验成功并通过 smoke 才替换已安装版本；用户环境变量优先。

## Review Focus

- 重定位、路径空格：实际解压到新目录编译 SQLite 脚手架。
- 下载损坏或不存在：安装失败保留旧版本与入口。
- release/beta 切换：安装元数据及 leaf --version 同步变化。
- 旧 main 构建晚完成：发布前比对最新 main SHA。
- 未支持平台：下载前明确失败，不碰现有安装。

### Task 1: SDK 发现及重定位构建

Files: src/leaf/sdk.nim、build.nim、gpui_build.nim、gpui_api.nim、doctor.nim、sqlite_native.nim、src/leaf_cli.nim；tests/nim/test_sdk.nim。
Interfaces: sdkRoot(executable=getAppFilename()):string；sdkFile(relative):string；sdkVersion():string。
- [x] 写并运行失败测试：有效 SDK 布局、缺失 SDK、显式覆盖、版本元数据。
- [x] 实现 SDK 源码/Nim/桥接库发现及 Windows gcc 与 SQLite 配置。
- [x] 测试通过，并编译 CLI 验证版本。

### Task 2: 归档及安装

Files: scripts/package_sdk.py、scripts/smoke_sdk.py、install.sh、install.ps1、tests/release/test_sdk.py。
Interfaces: package_sdk CLI 接收 --nim-root --bridge --cli --target --version --channel --commit --output ；smoke_sdk 接收 SDK 目录。
- [x] 写并运行失败测试：归档完整性、渠道安装与校验失败保留旧入口。
- [x] 实现归档、校验文件、两个原生安装器。
- [x] 运行 Python 测试及真实 Linux SDK smoke；重复安装验证升级。

### Task 3: GitHub 发布矩阵与文档

Files: .github/workflows/release.yml、scripts/publish_sdk.py、README.md、docs/installation.md。
- [x] 测试严格 tag 及 beta 发布命令/过时 SHA 保护。
- [x] 实现四目标原生构建/归档安装 smoke/集中发布，文档给出两渠道三平台命令。
- [x] 运行脚本/CLI 回归、工作流静态检查、最终独立代码审查；记录本机无法执行的平台验证。

## 验证记录

- 新增 Python 发布/安装/许可证测试 14 项通过；Nim SDK 测试 4 项通过。
- actionlint 1.7.12 检查 release.yml 与 ci.yml 通过；两个 PowerShell 脚本通过 PowerShell 7.6.6 AST 解析。
- Linux 真实归档安装到中文/空格路径，生成 SQLite CRUD 应用、两次初始化、重复安装、损坏更新保留入口通过。
- 原生依赖许可证收集：Linux 605、Windows 511、macOS ARM 524、macOS Intel 526 项，均无空文本项。
- Nim 完整回归 26/27 套件通过；既有 diagnostics 多调用 Cargo symlink 测试因本机缺 libxkbcommon-x11 无法链接，未修改该测试。
- 本机缺图形运行库，真实 SDK 本地使用 --headless-only；发布 CI 默认必须成功加载 GPUI ABI。macOS/Windows 的原生运行、安装与应用编译待 GitHub 各平台执行。
- 代码尚未推送，因此本地验证没有创建任何 GitHub Release 或 tag。
