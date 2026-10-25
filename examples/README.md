# 小示例：一次看懂一个概念

[文档首页](../docs/README.md) · [Windows 原生表单](native_forms/README.md)

**从计数器开始，按需要增加复杂度。** 这些示例使用真实公开 API，不是伪代码。

| 示例 | 看什么 |
| --- | --- |
| [counter.nim](counter.nim) | 声明式布局、State、增加与重置 |
| [todo.nim](todo.nim) | 受控输入、稳定业务 id、添加与删除 |
| [components.nim](components.nim) | 两个子组件各自持有状态，局部更新 |
| [kit.nim](kit.nim) | 输入、开关、校验、保存与重置 |
| [component_pages.nim](component_pages.nim) | 路由、返回历史与页面保留 |
| [component_tasks.nim](component_tasks.nim) | 后台完成、错误重试、取消与生命周期 |
| [errors.nim](errors.nim) | 拒绝候选后恢复到已接受界面 |

## 如何运行

安装 SDK 后，在本目录打开终端：

```sh
leaf counter.nim
leaf --headless --click add --click add counter.nim
```

这里的 `.nim` 是 CLI 支持的**单文件入口**。有 `leaf.json` 的应用则先进入项目目录，再执行 `leaf run`；不要把旧版的项目目录位置参数混进命令。

## Windows 原生示例

| 示例 | 重点 | 环境 |
| --- | --- | --- |
| [native_forms](native_forms/README.md) | Win32 受控输入、reset、键盘与失败候选 | Windows x64，native |
| [native_list](native_list/README.md) | 10,000 行虚拟列表、行 State、SQLite 保存重开 | Windows x64，native |

共享 DSL 中的装饰与布局能力由各原生后端声明，不保证任意示例的所有样式都可呈现。[当前范围与未关闭项](../docs/progress.md)。

七页旧展示源保留作[headless 业务示例](../example/README.md)，尚未迁移为 Windows 原生展示应用，不作为当前 UI 截图来源。
