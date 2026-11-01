# 安装与使用 Leaf

[文档首页](README.md) · [源码开发](development.md)

**本轮先支持 Windows x64。** 原生 SDK 包含 CLI、Leaf 源码、Nim 2.2.6 编译器和标准库；Windows 安装器下载并校验 MinGW。不包含渲染桥接库，也不需要 Rust。

> **已核实的 Windows 原生 beta：** `beta.8b683ca188f7`，对应提交 `8b683ca188f74f512b1bc8a0857342adef8a316d`。[SDK 发布与安装验证工作流](https://github.com/SatoriTours/Leaf/actions/runs/41184027560)已成功，安装器要求 `schema: 2`、`backend: native`，拒绝旧 SDK。该版本仍有下述列表点击缺陷；完整平台、资源与现场矩阵未完成。
>
> [滚动 beta 页面](https://github.com/SatoriTours/Leaf/releases/tag/beta)仍留有之前的 Linux/macOS 包；它们不是本轮原生 SDK，不适用于当前 GUI。当前请只选择 `leaf-sdk-windows-x86_64.zip` 及其同名 `.sha256`。beta 会滚动更新，安装时同时核对包内 `sdk.json` 的版本、提交与目标，不能只看 Release 标题。

> **当前使用限制：** `8b683ca` 生成应用在外部输入框持焦、搜索结果恢复后点击列表按钮时可能卡死。工作区的三处 Win32 修复已通过实际操作、持久化、打包搬迁及默认用户数据目录的限定独立复核，但尚未提交／发布；直接安装上列旧 beta 不包含这次修复。最终回归与交付身份见[开发进度](progress.md)，列表裁剪等历史验收见[Windows 验收](windows-acceptance.md)。

> **最新候选尚未通过交付门：** 后续生成应用的搜索布局修复已取得三主题交互观察，但本地系统主题测试 EXE 被 Defender 检测拦截。经用户授权，已通过官方工具恢复单个隔离样本并补齐 hash；检测原因仍未澄清，用户已提供官方提交编号，等待微软判定，尚未独立读取门户结果。该候选未发布，不能将其描述为可直接交付的新 SDK，也不能据此认定所有旧 SDK 产物有同样检测；详情见开发进度。

## Windows 源码运行

准备 Nim 2.2.6+ 与 MinGW（含 windres），在仓库根目录：

```powershell
nim c -d:release --out:target/nim/leaf.exe src/leaf_cli.nim
.\target\nim\leaf.exe doctor --json
.\target\nim\leaf.exe init my-app
cd my-app
..\target\nim\leaf.exe run
```

检查 `doctor` 的 `host_available`、Nim、C 编译器及 windres。可通过 `NIM` 指定编译器、`LEAF_LIBRARY` 指向当前 `src`；通常无需覆盖。当前工作区修复支持相对路径：两者均相对于执行 `leaf` 时所在目录解析，再固定为绝对路径，避免从项目子目录运行时因编译进程切换目录而失效；此修复尚未发布。

当前工作区的 `doctor` 与 Windows 构建共用资源编译器查找规则：优先使用 GCC 同目录的 `windres`，不存在时再查 `PATH`。因此将资源编译器单独加入 `PATH` 后，诊断也能显示其版本；确实找不到时 `tools.windres` 为 `null`。版本探测不代表应用构建已经通过，此修复尚未发布。

## 安装 Windows beta

在 PowerShell 5.1 或 7 执行：

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/SatoriTours/Leaf/main/install.ps1'))) -Channel beta
```

只有对应正式版本已存在时才使用 `-Channel release` 或 `-Version vX.Y.Z`；上述命令安装 Windows beta，使用前请核对本页已知限制和包内提交。默认 SDK 位于 `%LOCALAPPDATA%\Leaf\versions`，入口为 `%LOCALAPPDATA%\Leaf\bin\leaf.cmd`。支持 `-Prefix`、`-BinDir`、`-NoPath`、`-DownloadBase`。

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
