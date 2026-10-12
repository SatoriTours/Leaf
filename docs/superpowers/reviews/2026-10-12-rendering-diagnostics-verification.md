# 类型化渲染诊断兼容验证

修复提交：`ad647449c55aa4e9c325d2bc9578a7a98fa84f7e`；功能分支 `feat/leaf-react-runtime`；本轮基线 `992c7e77654ba3551b1869e67496e1cd75658272`。复用现有功能工作区，未合并、推送或归档。

M2 已修复：Nim 的 ABI2 `RENDERING` 请求恢复 `rendering/ok` 日志及原有四组数值字段。相同缩放和逻辑尺寸去重；缩放单独改变仍记录。设备尺寸和 DPI 是换算值。`FRAME` 不重复写尺寸日志，不触发组件渲染、整树 Snapshot/JSON 导出或 watch ready 收据更新。非法尺寸、非有限数和换算溢出仅拒绝该诊断请求，不污染后续 ready；C ABI 和 Rust 实现未改变。

- 专用回归先复现两项失败，再修复通过；最终覆盖尺寸变化、仅缩放变化、去重、FRAME、非法值和 ready 隔离。日志比较按数值语义处理整数与浮点 JSON；初次比较类型过严的失败输出保留。
- 项目全量回归：85 个 Nim suite、43 个 Rust 测试通过，fmt 和 diff 检查通过。
- Linux 实际窗口：legacy/managed × ABI1/2 × CACHE0/1 共 8 组通过。每组均检查首帧日志、实际 resize、重复尺寸去重、ready 收据不变，以及点击、输入、Enter、拒绝、reset、watch 错误显示/清除和关闭。

证据单独保存于 `/home/jimxl/projects/leaf/target/verification/react-runtime/2026-10-12-rendering`：原始失败/成功输出、命令脚本、窗口 JSONL/收据、Nim 源码与实际 Rust 动态库身份，以及源码归档和 SHA256 索引。此前 `2026-10-12-reviewed` 的性能、SDK 与封存索引保持不变，仍对应其记录的 `b7c52a1`；本次仅验证诊断修复，未重新测性能或打包 SDK。M3 的旧历史索引 caveat 不改写。

Windows 文档中的现有 `leaf-a2-windows` 虚拟机经只读确认已停止，未启动或修改。Windows/macOS、真实系统 IME 和跨不同 DPI 显示器检查仍 NotRun；计划 13.4 不勾选，Linux resize 不替代真实 DPI 验收。
