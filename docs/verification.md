# 验证

验收包含三条独立路径：Nim 核心与工具回归、GPUI Kit 控件测试、Linux 真实窗口测试。无窗口回归不能替代实际桌面交互。

2026-10-05 在 Linux x86_64 上完成以下验收，使用 Nim 2.2.6、GPUI Kit 0.7.0 以及锁定的 Cargo 依赖。

| 验证 | 命令或方式 | 结果 |
| --- | --- | --- |
| Nim 核心、CLI、watch、发布与页面逻辑 | `nim c -r --out:target/nim/test_runner scripts/test.nim` | 22 个测试套件全部通过 |
| GPUI Kit 控件与 C ABI | `cargo test --workspace --locked` | 9 项测试通过 |
| Rust 静态检查 | `cargo clippy --workspace --all-targets -- -D warnings`、`cargo fmt --all --check` | 通过 |
| 真实 GPUI 窗口 | `nim c -r --out:target/nim/native_test scripts/native_test.nim` | 鼠标点击、输入、Enter、就绪与关闭通过；首屏列表失败不报告就绪 |
| CLI 与多模块发布 | `leaf pack examples/project --target linux --output dist` | tar.gz 与 SHA256 生成，独立读取器验证归档 |
| 发布包搬迁 | 解压到独立目录，从 `/tmp` 运行，清除框架路径覆盖 | 资源读取、两次 headless 点击、真实窗口点击与关闭通过 |
| 桥接库加载 | 检查搬迁后窗口进程的加载映射 | 使用随包 `libleaf_gpui.so`，没有加载 GTK 库 |

GPUI 控件回归覆盖禁用事件、中文文本、输入与 Enter、稳定输入实体和选区、受控输入拒绝后的恢复、IME 组合状态与提交，以及同屏多个变量列表行和来源重排后的焦点行。Nim 桥接回归另外验证十万项按需构建、首屏失败拒绝就绪、替换来源失败时保留成功快照和行回调。

真实窗口验收使用私有 Xvfb、xdotool 与 SwiftShader Vulkan 软件驱动。`docs/screenshots/counter-gpui.png` 来自实际 GPUI 计数器窗口。当前平台证据为 Linux；macOS 和 Windows 发布格式用目标文件头与资源布局回归验证，尚未在这两个系统上执行原生窗口验收。

性能管道使用 Release Nim producer 执行：

```sh
target/nim/leaf-performance --suite all --iterations 2 --warmup 2 \
  --rounds 1 --repeat 2 --interval 0 --output artifacts/performance
```

运行时与原生帧两组各完成两轮，输出 schema 2 原始样本和通过报告。原生组包含普通布局、十万项固定行高及变高列表，计时包含事件更新到下一绘制帧的调度与渲染。这是管道功能验收的小样本，不能代表硬件 GPU 性能或长期性能基线。
