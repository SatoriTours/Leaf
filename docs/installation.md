# 安装 Leaf SDK

SDK 把 Leaf CLI、Leaf 源码、Nim 2.2.6 编译器与标准库、预编译 GPUI 桥接库放在一起。Windows 安装器会自动从 Nim 官方源下载并校验 MinGW；创建应用无需安装 Rust，也无需设置 NIM、LEAF_LIBRARY 或 LEAF_GPUI_LIBRARY。

以下下载命令在发布工作流推送到 GitHub 并首次成功运行后可用。正式版需要至少一个 `vX.Y.Z` tag；此前可以安装 beta。

## Linux / macOS

安装最新正式版（默认渠道）：

```sh
curl -fsSL https://raw.githubusercontent.com/SatoriTours/Leaf/main/install.sh | sh
```

安装或切换到最新 beta：

```sh
curl -fsSL https://raw.githubusercontent.com/SatoriTours/Leaf/main/install.sh | sh -s -- --channel beta
```

指定正式版本：

```sh
curl -fsSL https://raw.githubusercontent.com/SatoriTours/Leaf/main/install.sh | sh -s -- --version v0.1.0
```

默认 SDK 目录是 `~/.local/share/leaf/versions/`，命令入口为 `~/.local/bin/leaf`。安装器会把命令目录加入 `.profile` 以及 Bash/Zsh 配置；安装完成后打开新终端。重复运行安装命令即更新，切换渠道使用同一个 `leaf` 入口。旧 SDK 保留在 versions 目录，可以在不运行相关构建时手动清理。

自定义目录时先下载安装器，再执行：

```sh
sh install.sh --channel beta --prefix /path/to/leaf --bin-dir /path/to/bin --no-path
```

`--no-path` 禁止修改 shell 配置。`--download-base` 可配置 HTTPS 镜像或 `file://` 离线目录，镜像应保持 GitHub Release 的路径结构和校验文件。

## Windows

在 Windows PowerShell 5.1 或 PowerShell 7 中安装正式版：

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/SatoriTours/Leaf/main/install.ps1')))
```

安装或切换到 beta：

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/SatoriTours/Leaf/main/install.ps1'))) -Channel beta
```

指定正式版本：在上一条命令结尾使用 `-Channel release -Version v0.1.0`。

默认 SDK 位于 `%LOCALAPPDATA%\Leaf\versions`，命令入口为 `%LOCALAPPDATA%\Leaf\bin\leaf.cmd`，安装器会配置用户 PATH 和当前 PowerShell PATH。重复运行即更新。可使用 `-Prefix`、`-BinDir`、`-NoPath` 和 `-DownloadBase` 自定义安装。

## 创建应用

```sh
leaf --version
leaf doctor --json
leaf g scaffold my-app
leaf g scaffold Note title:string archived:bool --project my-app
leaf --check my-app
leaf my-app
```

默认 SQLite 数据库位于系统用户数据目录，可通过 `LEAF_DATABASE_PATH` 覆盖。`leaf --check` 会运行应用的初始化和迁移，所以也会创建数据库。

## 平台依赖

首批 SDK 支持 Linux x86_64（Ubuntu 24.04 及同等或更新的 glibc 环境）、macOS Intel / Apple Silicon、Windows x86_64。Linux ARM、Windows ARM 原生包尚未提供。macOS 构建运行器分别为 macOS 15 Intel 与 macOS 14 ARM；对应系统作为首批支持基线。

Unix 编译应用仍需要系统 C 编译器。macOS 安装 Xcode Command Line Tools：

```sh
xcode-select --install
```

Ubuntu 24.04 安装编译器及运行库：

```sh
sudo apt-get update
sudo apt-get install -y build-essential libsqlite3-0 libfontconfig1 libfreetype6 \
  libxkbcommon0 libxkbcommon-x11-0 libxcb1 libx11-xcb1 libwayland-client0 \
  libwayland-cursor0 libwayland-egl1 libvulkan1 fonts-noto-cjk
```

Windows 使用系统 `winsqlite3.dll`；Nim 随 SDK 提供，C 编译器由同一安装命令自动下载配置。所有平台打开窗口都需要系统图形驱动和可用桌面会话。Linux 的具体运行库依赖可通过 `ldd SDK/lib/libleaf_gpui.so` 查看；headless 编译检查不初始化窗口。

安装器使用 HTTPS 下载并核对同一 Release 下的 SHA256；校验失败或版本不匹配时不切换现有入口。SHA256 用于发现传输/资产损坏，发布来源的信任来自 GitHub 仓库与 HTTPS。

## 维护者：自动发布

- 推送 `main`：四个平台构建、原生安装验证、SQLite 脚手架编译成功后，更新 `beta` tag 的预发布。版本为 `beta.<commit 前 12 位>`，不成为 GitHub latest。
- 推送 `vX.Y.Z`：创建正式 Release；上传全部 SDK 与校验文件后才公开。GitHub 按版本规则选择 latest；已存在的正式版不会静默覆盖。
- 其他分支只运行现有 CI。发布工作流可手动重新运行；beta 发布前会核对当前 main，跳过已经过时的构建。
- 不需要个人访问令牌，发布 job 使用仓库 `GITHUB_TOKEN` 的 `contents: write` 权限。仓库应允许 Actions 创建 Release；如果组织策略禁用该权限，需要维护者调整仓库设置。
- `.github/workflows/release.yml` 负责 SDK；原有应用打包 `leaf pack` 继续用于发布开发者自己的应用。

例如完成验证后发布首个正式版本：

```sh
git tag v0.1.0
git push origin main
git push origin v0.1.0
```

beta 在滚动更新资产的短暂时间内可能发生校验失败；已有安装会保留，稍后重试即可。工作流没有完成时，安装命令不会自行回退到其他渠道。
