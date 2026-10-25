# 从源码开发 Leaf

[文档首页](README.md) · [架构](architecture.md) · [验证范围](verification.md)

## 需要哪些工具

| 工作 | 环境 |
| --- | --- |
| 共享 Runtime、CLI、headless 与数据库测试 | Nim 2.2.6+、C 编译器 |
| Windows 原生窗口与打包 | Windows x64、Nim、MinGW（含 windres） |
| Android 现有构建路径 | 现成 SDK/NDK/JDK/离线 Gradle |

不需要 Rust、Cargo、Vulkan 或其他渲染工具包。不要为了源码构建安装已删除的桥接依赖。

## 构建与运行

在仓库根目录：

```sh
nim c -d:release --out:target/nim/leaf src/leaf_cli.nim
```

Windows 产物为 `leaf.exe`。把 `target/nim` 加入当前终端 PATH 后，在应用目录：

```sh
leaf doctor --json
leaf run
leaf --check
leaf --headless --click add
leaf pack --target windows
```

`NIM` 指定 Nim 编译器；`LEAF_LIBRARY` 指向包含 `leaf.nim` 的源码目录。安装 SDK 时默认使用随包编译器和源码。`--backend native` 可省略；其他后端被拒绝。Linux/macOS GUI 尚未实现，使用 headless 检查。原生 `--watch` 暂不支持，不承诺热替换。

## 测试入口

```sh
# 共享运行时、工具链和发布脚本
nim c -r --out:target/nim/test_runner scripts/test.nim
# Model / 数据库专项
nim c -r scripts/test.nim --model-only
nim c -r scripts/test.nim --database-only
# 真实 Windows host（只能在 Windows 执行）
nim c -r --out:target/nim/test_win32 scripts/test_win32.nim
```

测试应保留实际命令、退出码、输入快照与原始日志。Windows runner 在非 Windows 返回 NotRun/退出 2，不能当通过。截图、物理输入、IME、混合 DPI 和辅助技术仍需实际环境核查。

## 诊断

应用支持 `--trace`、`--log-file FILE`、`--dump-tree FILE`。诊断不得覆盖源码、配置或成为 watch 资源循环；完整快照会产生显式成本。headless 检查不初始化窗口，但应用初始化仍可能写数据库。

Windows CLI 产物嵌入 Common Controls v6 / PerMonitorV2 manifest。直接 `nim c` 不自动得到同一资源；窗口启动会检查现有 DPI 上下文。逻辑尺寸是 DIP，不在业务代码重复乘比例。既有宿主 DPI 模式和全局系统设置不得为了测试擅自修改。

## 性能：先说清测了什么

```sh
nim c -d:release --out:target/nim/leaf-performance scripts/performance.nim
target/nim/leaf-performance --suite runtime --output artifacts/performance
```

运行时工作负载保留原始样本、校验与构建身份。`--suite native/all` 当前因原生测量 producer 未实现而明确失败，不再运行旧绘制基准。

`benchmarks/components.nim` 仅测 managed Runtime 与 Host 批次准备；无原生 apply/layout/frame 数据。Nim 分配次数、存活堆、RSS 与 CPU 时间是不同指标，不能互相替代，也不能由 headless 微基准推断窗口 FPS。

## SDK 与资源

`scripts/package_sdk.nim` 组装原生 schema 2 SDK，不接受渲染库参数；`scripts/verify_sdk_install.nim` 验证安装和重定位。搬迁验证应清除编译器/源码覆盖，核对 doctor 指向随包工具，再检查生成应用、CRUD、迁移和后台任务。

Windows 应用默认使用系统 `winsqlite3.dll`；Android 使用固定的应用内引擎。连接只在创建线程使用；worker 自建连接。UI 与数据库不是联合事务。

发布、安装和打包细节：[SDK 安装](installation.md) · [应用打包](packaging.md)。
