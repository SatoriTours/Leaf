# Leaf SDK 自动发布与安装

用户要求：提交 GitHub 后自动构建 beta，版本 tag 构建 release；两个渠道都能用一条命令安装，支持 Linux、macOS、Windows。

- main 推送产生 `beta` 预发布；`vX.Y.Z` tag 产生正式版本。发布前四个原生目标全部构建并验证：Linux x86_64（Ubuntu 24.04+）、macOS Intel/Apple Silicon、Windows x86_64。
- SDK 包含 Leaf CLI、全部库源文件、Nim 2.2.6 编译器/标准库、预编译 GPUI 桥接库、许可证；Windows 安装器自动从 Nim 官方源下载并校验 MinGW。开发者不用安装 Rust或手动配置 Leaf 路径。Unix 仍需要系统 C 编译器和图形库；Windows SQLite 使用系统 winsqlite3。
- CLI 根据自身位置发现 SDK，保留 NIM、LEAF_LIBRARY、LEAF_GPUI_LIBRARY 的显式覆盖。`leaf --version` 显示渠道和提交。
- Unix `install.sh --channel release|beta`，Windows `install.ps1 -Channel release|beta`；默认 release，也支持指定正式 tag。安装到用户目录，校验 SHA256、解压验证后才切换入口，重复执行即更新。不修改已有应用。
- beta 滚动预发布永远不成为 GitHub latest；同渠道发布串行，并防止过时 main 构建覆盖最新 beta。正式 tag 严格校验，版本不能静默覆盖。
- 发布工作流使用仓库 GITHUB_TOKEN；只有发布 job 有 contents:write。不使用额外个人令牌。

验证：本地真实 SDK 重定位后生成 SQLite CRUD 应用、编译和检查；安装成功/升级/校验失败/不支持平台的脚本测试；GitHub 四个平台重复同一 SDK smoke。macOS/Windows 原生运行只能由各平台 CI 验证。
