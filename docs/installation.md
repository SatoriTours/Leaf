# 安装与使用 Leaf

[文档首页](README.md) · [源码开发](development.md)

**本轮先支持 Windows x64。** 原生 SDK 包含 CLI、Leaf 源码、Nim 2.2.6 编译器和标准库；Windows 安装器下载并校验 MinGW。不包含渲染桥接库，也不需要 Rust。

> **Windows 原生 beta 已可安装：** 本轮修复前的已核实基线为 `beta.c72ca99dfad6`，对应提交 `c72ca99dfad610ae06e95fad214b384c95046920`。[发布与安装验证工作流](https://github.com/SatoriTours/Leaf/actions/runs/40156213210)已成功，可使用下方安装命令。这是预发布版本，不代表完整平台、资源或现场验收通过。安装器要求 `schema: 2`、`backend: native`，拒绝旧 SDK。
>
> [滚动 beta 页面](https://github.com/SatoriTours/Leaf/releases/tag/beta)仍留有之前的 Linux/macOS 包；它们不是本轮原生 SDK，不适用于当前 GUI。当前请只选择 `leaf-sdk-windows-x86_64.zip` 及其同名 `.sha256`。beta 会滚动更新，安装时同时核对包内 `sdk.json` 的版本、提交与目标，不能只看 Release 标题。

> **已知验收缺口：** `c72ca99` 基线的 `native_list` 存在数据库参数／自检入口冲突；本轮修复已通过 GPT 独立功能复验（保存、同库重开、默认打包及搬迁读回）。修复随本轮 main 提交交付，新 beta 必须以对应工作流及 `sdk.json` 核实，不以旧包代替。a2 曾暴露列表单行／末行不可见缺陷；本地裁剪修复已在 a3 独立确认首尾五行及末行完整可见，非首行保存与打包搬迁也通过。但部分滚动裁剪未有效触发，整体验收仍阻塞／未完成，不要将 beta 安装成功等同于完整应用可交付。详见[当前验收状态](windows-acceptance.md)。

## Windows 源码运行

准备 Nim 2.2.6+ 与 MinGW（含 windres），在仓库根目录：

```powershell
nim c -d:release --out:target/nim/leaf.exe src/leaf_cli.nim
.\target\nim\leaf.exe doctor --json
.\target\nim\leaf.exe init my-app
cd my-app
..\target\nim\leaf.exe run
```

检查 `doctor` 的 `host_available`、Nim、C 编译器及 windres。可通过 `NIM` 指定编译器、`LEAF_LIBRARY` 指向当前 `src`；通常无需覆盖。

## 安装 Windows beta

在 PowerShell 5.1 或 7 执行：

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/SatoriTours/Leaf/main/install.ps1'))) -Channel beta
```

只有对应正式版本已存在时才使用 `-Channel release` 或 `-Version vX.Y.Z`；当前推荐上面的 Windows beta。默认 SDK 位于 `%LOCALAPPDATA%\Leaf\versions`，入口为 `%LOCALAPPDATA%\Leaf\bin\leaf.cmd`。支持 `-Prefix`、`-BinDir`、`-NoPath`、`-DownloadBase`。

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
