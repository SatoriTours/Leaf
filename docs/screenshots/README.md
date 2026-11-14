# README 截图来源

`leaf-notes-light.png` 与 `leaf-notes-dark.png` 来自真实运行的 [Leaf Notes](../../examples/native_notes/README.md)，不是 HTML 原型或概念图。

- 环境：Windows 11 VM，非提权交互 Session 1，实际 **96 DPI**。
- 尺寸：两张均为 **1186 × 692** 的原始无损 PNG；按 DWM 可见窗口边界采集，不含桌面边缘／任务栏，不修绘控件、不插值放大。
- 同一 EXE 启动参数：`--theme light` / `--theme dark`，各使用独立的首次启动示例数据库。
- EXE SHA256：`e096a419142255edd83ac092d99da2428394f0554266af0f8471d9eb81320a20`。
- 源码：基于 `c10f341` 工作区加入本次 Demo 与多行／主题改动，尚未提交。相关产品文件 hash 清单 SHA256：`fd69d9113fd241a707758822c63d23e2358fdc7793ae8d8e1571e17e4ed5ff5a`。

开发者已实际查看深浅色原图，并以同一 EXE 在实际桌面自测键盘搜索／清空、创建笔记、标题／多行正文输入、Enter 换行、保存、关闭重开和正常退出；另有 SQLite／组件状态测试及原生输入／主题回归。

以上是开发者自测与实拍证据，不等于独立验收。当前缺少符合模型边界的独立 Codex 验收通道；未覆盖完整真实 IME、高 DPI／混屏、高对比或辅助技术矩阵，也没有声称 GitHub 线上渲染已验收。

原始测试、截图、EXE 与脚本留在任务证据 `notes-demo-ui-final2-1107` / `notes-demo-entry-final2-1107` / `notes-demo-regression-v2-final-1107`，本机短状态索引：`~/.local/state/agent-artifacts/leaf/2026-11-07-notes-demo/status.md`。历史 `native-forms-win32.png` 保留供旧说明引用。
