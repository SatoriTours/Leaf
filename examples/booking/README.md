# 预约 Demo

[application.nim](application.nim) 是共享业务组件；[booking_controls.nim](booking_controls.nim) 是可独立导入的 Stepper 组件库，[stepper.nim](../stepper.nim) 展示独立用法。桌面走 [main.nim](main.nim)，Android 注册入口在 [mobile.nim](mobile.nim)。

仓库根目录（Nim 2.2.6+）：

```sh
nim c --path:src --out:target/nim/booking examples/booking/main.nim
target/nim/booking --check
target/nim/booking --headless --change name Ada --click date-open \
  --change date-draft 2099-01-01 --click date-cancel --click date-open \
  --change date-draft 2099-01-02 --click date-confirm --click plus --click confirm
nim c --path:src --out:target/nim/stepper examples/stepper.nim
target/nim/stepper --check
```

在 2099 年前运行此测试，最后的确认文本应为 `Ada · 2099-01-02 · 2 位`。在支持的 Windows 原生环境，从此目录运行 `leaf run` 打开窗口；Linux 只运行 headless。在已配置 Android 工具链时，可从此目录按 [Android 构建说明](../../docs/packaging.md) 构建。构建或 headless 通过不代表设备 UI 通过。

[声明式组件说明](../../docs/declarative-components.md)
