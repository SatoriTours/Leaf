# 七页业务示例源（尚未迁移原生展示）

[文档首页](../docs/README.md) · [当前 Windows 原生表单](../examples/native_forms/README.md)

这里保留看板、报表、聊天、行情、设置与注册等页面及业务回归。数据均为本地模拟；**这些页面尚未作为 Windows 原生展示应用验收**，不能把历史自绘截图当作当前系统原生界面。

## 无窗口检查

在仓库根目录：

```sh
nim c -d:leafHeadlessOnly -r example/main.nim --check
nim c -r --path:src tests/nim/test_gallery.nim
```

旧窗口自动化与截图已退出当前展示入口，不再要求渲染桥接库。

## 仍可参考什么

- 页面自己的类型化 State 和路由切换。
- 表单验证、任务流转、过滤、排序与分页。
- 按需列表和稳定业务标识。
- 业务逻辑 headless 回归与运行时基准。

`benchmarks/gallery.nim` 只测 Nim 事件、render、验证和可见行构建，不包含系统控件测量、绘制、输入法或 FPS。要运行当前 Windows UI，请从[原生表单](../examples/native_forms/README.md)或[SQLite 列表](../examples/native_list/README.md)开始。
