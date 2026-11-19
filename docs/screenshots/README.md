# README 截图来源

## 三栏写作工作台（2026-11-18，当前 README 首图）

- [浅色原图](leaf-notes-workbench-20261118-light.png) / [深色原图](leaf-notes-workbench-20261118-dark.png)：Windows 11 VM，96 DPI，**986 × 612** PNG（客户区 984 × 580 DIP）。按 DWM 可见窗口边界从实际交互桌面采集，无缩放、局部裁切或重绘。
- 同一 EXE、同一 SQLite 演示库、同一篇选中的中文笔记。第一次用 `--demo --theme light` 播种，第二次用打印的 `--database` 路径和 `--theme dark` 重开；两图均在修改内容之前采集。
- 源码基于 `9ce1949bfde5c2a2121d15383847806f2300103d` 工作树，未提交；来宾机逐文件核对 297 个构建输入，清单 `source.sha256` 的 SHA256 为 `96b3927183530de77eb94a3fe9f8d365ab470cc6d3916b484e5778726d74660f`。
- Win32 x64 EXE（Nim 2.2.6 + MinGW）：SHA256 `5d70829d005bf11b08e849592d3f1e43679aa45715535fb780b048bb082999f6`，构建机与宿主下载副本一致。

开发者另查看了 720 DIP 窄窗和深浅两色键盘焦点，并用真实键鼠搜索、清空、新建、输入两行中文、保存、关闭，按原数据库路径重开后搜索并选中，核对标题、两行正文和保存状态。探针日志、窄窗／焦点／重开截图及构建清单见本机证据 `~/.local/state/agent-artifacts/leaf/2026-11-18-notes-demo-example/windows/workbench-1118/final/`。不代表独立验收或已覆盖更窄窗口、实际 IME、高 DPI、系统高对比和读屏矩阵。

`leaf-notes-light.png` 与 `leaf-notes-dark.png` 来自真实运行的 [Leaf Notes](../../examples/native_notes/README.md)，不是 HTML 原型或概念图。

- 环境：Windows 11 VM，非提权交互 Session 1，实际 **96 DPI**。
- 尺寸：两张均为 **1186 × 692** 的原始无损 PNG；按 DWM 可见窗口边界采集，不含桌面边缘／任务栏，不修绘控件、不插值放大。
- 同一 EXE 启动参数：`--theme light` / `--theme dark`，各使用独立的首次启动示例数据库。
- EXE SHA256：`e096a419142255edd83ac092d99da2428394f0554266af0f8471d9eb81320a20`。
- 源码：基于 `c10f341` 工作区加入本次 Demo 与多行／主题改动，尚未提交。相关产品文件 hash 清单 SHA256：`fd69d9113fd241a707758822c63d23e2358fdc7793ae8d8e1571e17e4ed5ff5a`。

开发者已实际查看深浅色原图，并以同一 EXE 在实际桌面自测键盘搜索／清空、创建笔记、标题／多行正文输入、Enter 换行、保存、关闭重开和正常退出；另有 SQLite／组件状态测试及原生输入／主题回归。

以上是开发者自测与实拍证据，不等于独立验收。当前缺少符合模型边界的独立 Codex 验收通道；未覆盖完整真实 IME、高 DPI／混屏、高对比或辅助技术矩阵，也没有声称 GitHub 线上渲染已验收。

原始测试、截图、EXE 与脚本留在任务证据 `notes-demo-ui-final2-1107` / `notes-demo-entry-final2-1107` / `notes-demo-regression-v2-final-1107`，本机短状态索引：`~/.local/state/agent-artifacts/leaf/2026-11-07-notes-demo/status.md`。历史 `native-forms-win32.png` 保留供旧说明引用。
