# 常用 UI 界面示例

七页展示应用和三个压力入口使用 Nim + GPUI，默认窗口为 1240 × 860。每页保存自己的类型化状态，导航切换保留修改；行情、订单、消息、注册和同步都是本地模拟。

在仓库根目录运行，需要 Nim 2.2.6+、Rust 1.92+、C/C++ 编译器以及桌面图形环境：

```sh
nim c -d:release --out:target/nim/leaf src/leaf_cli.nim
target/nim/leaf example
# 编译并检查项目，或执行真实 Nim 回调而不打开窗口
target/nim/leaf --check example
target/nim/leaf --headless --click nav_board \
  --change task_draft '测试中文输入' --submit task_draft '测试中文输入' example
```

`leaf.json` 入口为 `main.nim`，共享组件在 `ui.nim`，七页通过正常 Nim 模块导入。进程退出后状态清空；`target/nim/leaf --watch example` 支持编译失败保留旧窗口，成功替换后重置状态。发布包包含 Nim 应用与 GPUI 桥接库。[开发与诊断](../docs/development.md)

| 页面 | 展示内容 | 可以尝试的操作 |
| --- | --- | --- |
| [数据概览](pages/dashboard.nim) | 统计卡片、趋势图、项目列表 | 切换周期、刷新、搜索及空态 |
| [任务看板](pages/board.nim) | 三列任务、进度、滚动 | Enter 添加、推进、删除、隐藏完成项 |
| [个人设置](pages/settings.nim) | 资料表单、预览、通知、同步 | 保存或撤销、校验、模拟同步 |
| [注册表单](pages/signup.nim) | 引导、逐项错误、成功页 | 提交空表单、填入示例、返回编辑 |
| [股票 K 线](pages/stocks.nim) | OHLC、成交量、MA5/20、十档盘口 | 三个标的、60/120/240 根、单帧/50帧、重置 |
| [统计报表](pages/reports.nim) | 100/500/1000 行订单、收入图、地区汇总 | 搜索、状态筛选、排序、分页、更新 |
| [即时聊天](pages/chat.nim) | 12 个会话、草稿、未读、历史 | Enter 发送、批量注入、广播、加载历史、切换顺序 |

报表与聊天默认分页显示 50 条；“完整数据 / 虚拟列表”保留完整数据来源，只构建可见行。报表使用 40px 行高提示，聊天根据 GPUI 测量保留变高内容。

独立压力入口：

```sh
target/nim/leaf example/stocks.nim   # 240 根 K 线
target/nim/leaf example/reports.nim  # 1000 行订单，虚拟列表
target/nim/leaf example/chat.nim     # 1000 条消息，虚拟列表
```

行情保留最近 240 根 K 线，每个会话最多保留 1000 条消息，新消息 ID 持续递增。每个会话保存独立草稿；切换会话清零未读，广播增加其他会话未读。默认最新消息置顶。按钮驱动单步或批量更新，没有自动播放或后台网络连接。

## 验证与性能

```sh
nim c -r --out:target/nim/test_runner scripts/test.nim
# 有 DISPLAY 时直接使用；Linux 无 DISPLAY 时需要 Xvfb
nim c -r --out:target/nim/native_test scripts/native_test.nim
nim c -d:release --out:target/nim/gallery_benchmark benchmarks/gallery.nim
target/nim/gallery_benchmark
```

页面回归覆盖导航状态、表单校验、任务流转、K 线几何、订单汇总/筛选/排序/缩页、草稿/广播/历史负编号时间和千条数据边界。真实 GPUI 窗口测试另外验证按钮、输入、Enter、就绪与关闭。

`benchmarks/gallery.nim` 测量 Nim 事件、render、验证和可见行构建。股票构建全部 240 根图元；报表和聊天保留 1000 项，每次构建 10 个可见行。这些数字不包含 GPUI 布局、绘制或输入法。`scripts/performance.nim --suite all` 分别测量 Nim 运行时与真实 GPUI 帧，并保存原始数据。

真实窗口验证范围与命令见[验证记录](../docs/verification.md)。
