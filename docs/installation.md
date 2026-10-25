# 安装与使用 Leaf

[文档首页](README.md) · [源码开发](development.md)

**本轮先支持 Windows x64。** 原生 SDK 包含 CLI、Leaf 源码、Nim 2.2.6 编译器和标准库；Windows 安装器下载并校验 MinGW。不包含渲染桥接库，也不需要 Rust。

> native-only 已有本地 Windows 构建与 SDK 安装验证；远端 SDK 是否可用须核对对应提交的发布工作流，不能仅依据源码已推送判断。此前 SDK 属于旧渲染实现，不能作为本轮原生产物。新安装器要求 `schema: 2`、`backend: native`，会拒绝旧 SDK。现在请从源码运行；下述下载命令须等本次对应发布工作流成功后使用。

## 现在：Windows 源码运行

准备 Nim 2.2.6+ 与 MinGW（含 windres），在仓库根目录：

```powershell
nim c -d:release --out:target/nim/leaf.exe src/leaf_cli.nim
.\target\nim\leaf.exe doctor --json
.\target\nim\leaf.exe init my-app
cd my-app
..\target\nim\leaf.exe run
```

检查 `doctor` 的 `host_available`、Nim、C 编译器及 windres。可通过 `NIM` 指定编译器、`LEAF_LIBRARY` 指向当前 `src`；通常无需覆盖。

## 新 SDK 发布后：安装 beta

在 PowerShell 5.1 或 7 执行：

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/SatoriTours/Leaf/main/install.ps1'))) -Channel beta
```

正式版使用 `-Channel release`，指定已有版本使用 `-Version vX.Y.Z`。默认 SDK 位于 `%LOCALAPPDATA%\Leaf\versions`，入口为 `%LOCALAPPDATA%\Leaf\bin\leaf.cmd`。支持 `-Prefix`、`-BinDir`、`-NoPath`、`-DownloadBase`。

安装器经 HTTPS 下载并核对同一 Release 的 SHA256，再核对原生 SDK 元数据；失败不切换已有入口。校验和检测损坏，来源信任仍依赖 GitHub 仓库与 HTTPS。

## 创建完整应用

```sh
leaf --version
leaf doctor --json
mkdir my-app
cd my-app
leaf g scaffold
leaf g scaffold Note title:string archived:bool
leaf db migrate --dry-run
leaf --check
leaf run
```

默认数据库位于用户数据目录，`LEAF_DATABASE_PATH` 可覆盖。初始化、迁移和 `--check` 可能创建或修改数据库，请用测试路径验证。

## 平台范围

| 平台 | 当前范围 |
| --- | --- |
| Windows x64 | 系统原生控件、源码构建、ZIP 打包；SDK 发布链以该平台为目标 |
| Linux / macOS | GUI 与应用打包未实现；共享逻辑可 headless 检查，不在本轮开发后端 |
| Android | 保留原生 Views、现有构建入口；需现成 SDK/NDK/JDK/离线 Gradle |
| iOS | 后置 |

## 维护者发布

推送 `main` 后，既有工作流构建并验证 Windows SDK，再更新滚动 beta；版本为 `beta.<SHA 前 12 位>`。显式推送 `vX.Y.Z` 才创建正式版本。发布保持原有校验、渠道隔离和旧正式版本保护。工作流未成功不算已交付，不能用旧产物充当本次成功。
