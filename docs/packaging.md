# 打包 Windows 原生应用

[文档首页](README.md) · [开发环境](development.md)

在项目目录执行：

```powershell
leaf pack --target windows
# 或使用已编译的 Windows x64 应用：
leaf pack --target windows --binary path/to/app.exe --output dist
```

默认打包会从暂存的 include 内容编译应用，再运行暂存产物的 `--check`；不允许编译器悄悄引用未打包模块。提供 `--binary` 时检查文件头及 x64 架构，**不运行这个外部产物**，应由提供者另行验证。

## 你会得到什么

```text
dist/
  <slug>-<version>-windows-x86_64.zip
  <slug>-<version>-windows-x86_64.zip.sha256
```

ZIP 包含 `bin/<slug>.exe`、`app/` 中的资源与源文件、`licenses/` 和说明。不需要渲染桥接 DLL；控件来自 Windows，默认 SQLite 使用系统 `winsqlite3.dll`。自定义 SQLite 动态库或其他业务原生依赖需另行安排，不会自动收集。

路径冲突、符号链接、输出覆盖 include/许可目录、已有发布文件都会被拒绝；整批暂存成功后才发布，不覆盖旧包。请保留 SHA256 和完整产物。

## 边界

- 从源码编译窗口及打包需要 Windows x64、Nim、MinGW 和 windres。
- Linux/macOS GUI、对应应用包及 `--target all` 暂不支持。
- Android 保留现有 `leaf pack --target android` 路径，需已有工具链；当前是 debug APK，不是商店签名发布。
- 自动 `--check` 验证逻辑，不代表视觉、IME、混合 DPI 或完整设备验收。
- 必须核对对应源码提交的 SDK 工作流和产物，不能以旧 SDK 产物代替新原生包。
