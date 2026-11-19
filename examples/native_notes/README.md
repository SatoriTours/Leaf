# Leaf Notes · 原生笔记 Demo

[示例目录](../README.md) · [入口](main.nim) · [启动参数](launch_options.nim) · [界面组件](application.nim) · [SQLite 存储](store.nim)

一个用 **Nim 组件状态、Win32 系统控件与 SQLite** 写的三栏笔记应用：松石浅色／深色外观，导航、虚拟列表与编辑区分层，只在点“保存”时写库。不是 WebView，也不是 HTML 设计稿。

![Leaf Notes 松石浅色真实窗口](../../docs/screenshots/leaf-notes-light.png)

[深色实拍](../../docs/screenshots/leaf-notes-dark.png) · [截图来源与验证范围](../../docs/screenshots/README.md)

> 上面两张是 2026-11-07 在 Windows 11、96 DPI 真实窗口采集的 1186×692 原始 PNG，属于历史批次，**不要覆盖**。当前界面见[根 README](../../README.md)。`--demo` 每次启动都会创建全新的隔离数据集，载入当前版本的四条中文笔记；不会改写旧示例库。重拍时请另存为新批次（见[截图步骤](#截图步骤实窗证据)）。

## 入口与分层

| 文件 | 责任 | 可照搬的地方 |
| --- | --- | --- |
| `main.nim` | 唯一进程入口：解析参数 → 解析数据库路径 → 打开 store → `run` | 参数在 `run` 之前处理；数据库句柄存活到窗口关闭 |
| `launch_options.nim` | 纯参数与路径解析、演示数据集创建；不删除任何文件 | 不依赖窗口和 SQLite，可直接单测 |
| `store.nim` | 表结构、一次性播种（`seeded`）、参数绑定、显式保存 | 业务 id 稳定；只有 `save` 写库 |
| `application.nim` | 组件 State、草稿、筛选、虚拟列表、主题 | 界面不直接读写文件，只发事件、收状态 |
| `leaf.json` | `entry`、`include`、`backend` | `leaf build` 的项目入口 |

建议阅读顺序：`main.nim` → `launch_options.nim` → `store.nim` → `application.nim`。

## 从干净 checkout 构建并运行（Windows x64）

需要 Windows x64、Nim 2.2.6+、MinGW（含 windres）；可用仓库的 `scripts/prepare_windows_sdk.ps1` 准备 Windows 编译链。Linux/macOS 只能跑共享／headless 测试，没有原生窗口。

```powershell
# 仓库根目录
cd <仓库根目录>
nim c -d:release --out:target/nim/leaf.exe src/leaf_cli.nim

# 示例目录
cd examples/native_notes
..\..\target\nim\leaf.exe build --output target\LeafNotes.exe
.\target\LeafNotes.exe --demo
```

启动时控制台先打印数据集路径与重开命令，然后打开窗口（应用请求 1184×660；历史截图 1186×692，为含边框的可见窗口边界）：

```
Demo database: C:\Users\<你>\AppData\Local\Temp\leaf-notes-demo\demo-20261118-101500-12345\notes.sqlite3
Reopen: --database "C:\Users\<你>\AppData\Local\Temp\leaf-notes-demo\demo-20261118-101500-12345\notes.sqlite3"
Seed: created
```

`leaf run` 只接受 Leaf 自己的参数（`--check`／`--headless`／事件／诊断），把 `--demo` 或 `--theme` 交给它会被 CLI 拒绝；应用参数只传给构建出的 EXE。改代码后重新 `build` 覆盖同一个 EXE 即可。

## 启动参数与隔离的演示数据

应用参数（`--demo`／`--database`／`--theme`）只传给 EXE，不要交给 `leaf run`（CLI 会报 unknown option）。直接运行 EXE 时，应用参数写在 Leaf 自己的参数（`--check`／`--headless`／`--trace` 等）之前。

| 参数 | 作用 |
| --- | --- |
| （默认） | 用户库 `%APPDATA%\leaf-notes\notes.sqlite3` |
| `--demo` | 每次启动在 `%TEMP%\leaf-notes-demo\demo-<UTC>-<pid>\` 新建一个数据集，并打印路径与 `Reopen:` 命令；不删除、不复用旧数据集 |
| `--database PATH` | 打开指定数据库（含上面打印的演示库路径），用于重开同一个数据集 |
| `--theme light\|dark\|system` | 启动主题；运行中不切换 |
| `--help` | 打印用法 |

- `--demo` 与 `--database` 互斥（任何顺序、后面跟 `--headless` 也一样），冲突在打开数据库前就报错退出，不创建、不改动任何文件。
- 演示数据集是**新建**的：不删除文件、不覆盖已有数据集，侧车文件（`-wal`／`-shm`／`-journal`）也不会被清理。旧的 `--reset` 已移除，传入会报错并提示改用 `--demo`。
- 演示根目录如果是符号链接会被拒绝，避免把数据集写进别的目录。
- 只有首次打开某个数据集才写入四条示例并记下 `notes_meta.seeded`；之后用 `--database` 重开只读已有内容（`Seed: existing`）。
- 演示库与用户库是两个不同文件：截图、演示、验收不会碰 `%APPDATA%\leaf-notes`。
- 演示数据集会留在 `%TEMP%` 下；需要清理时由使用者自行删除，应用不会删除任何数据集。
- 直接运行 EXE 做 `--headless`／`--check` 时同样会打开数据库；带上 `--demo` 就不会写用户库。

## 截图步骤（实窗证据）

前提：非提权交互桌面、缩放 100%（96 DPI）、单屏。记录当时的源码提交、EXE SHA256、DPI 与启动参数。

```powershell
# 仓库根目录 → 示例目录
cd <仓库根目录>\examples\native_notes
.\target\LeafNotes.exe --demo --theme light
```

1. 每次 `--demo` 都是全新数据集，浅色首屏天然可复现；等窗口稳定后只截取本窗口（Win+Shift+S 或 Print Screen）。
2. 存到**新的批次目录**，例如 `docs/screenshots/notes-20261118/leaf-notes-light.png`；不要覆盖仓库里已有的 `leaf-notes-light.png`／`leaf-notes-dark.png`。
3. 关闭窗口，再运行 `--demo --theme dark`（同样会得到全新数据集），存到同一批次目录的 `leaf-notes-dark.png`。
4. 需要列表／编辑区特写时只做 1:1 裁切，并把裁切坐标、原图与批次身份写在该批次目录的说明里；不要改动既有的 `docs/screenshots/README.md` 来源记录。设计稿、HTML、缩放图都不能冒充。
5. 同一批截图使用同一个 EXE 与同一份源码 hash；换了 EXE 就重拍。

`--check`／`--headless` 能验证编译、状态与数据层，但**不创建窗口**：不能当作截图或“窗口正常显示”的证据；截图也不能反过来证明 headless 通过。两者分别记录。

## 保存 → 退出 → 重开核验

1. 在示例目录用**一次启动**完成编辑与退出码记录，同时记下打印的路径：

   ```powershell
   $p = Start-Process .\target\LeafNotes.exe -ArgumentList '--demo' -PassThru -NoNewWindow
   # 控制台打印 Demo database / Reopen / Seed: created；复制 Reopen: 后面的路径
   ```

   窗口里是四条示例；`Seed: created` 表示这是全新数据集。
2. 点“＋ 新建笔记”，输入标题“重开核验”和两行正文，点“保存”，底部显示“所有更改已保存”。
3. 正常关闭窗口（标题栏 × 或 Alt+F4），再用同一个进程对象取退出码：

   ```powershell
   $p.WaitForExit(); $p.ExitCode
   ```

4. 用第 1 步打印的 `Reopen:` 命令重开（**不要再加 `--demo`**，否则会新建第二份数据集）：`.\target\LeafNotes.exe --database "<路径>"`。控制台必须是 `Seed: existing`，在列表中按标题找到并选中“重开核验”（不要求排在第一条），核对两行正文均与保存前一致。
5. 若重开时又出现 `Seed: created`，说明路径不对或又用了 `--demo`；这一项不算通过，先核对命令再重试。
6. 再验整理结果：收藏后重开仍在“已收藏”，归档后重开仍在“归档”，移回笔记后回到“全部笔记”。

自动化覆盖（共享、headless，不替代窗口检查）：`tests/nim/test_native_notes_launch.nim`（参数校验、演示数据集隔离、无删除、符号链接拒绝、显式路径保存重开）、`tests/nim/test_native_notes.nim`（播种一次、搜索、失败不改坏数据）、`tests/nim/test_native_notes_app.nim`（草稿、保存后重开、收藏／归档、错误提示）。

```sh
# 仓库根目录
nim c -r --path:src --out:target/nim/test_native_notes_launch tests/nim/test_native_notes_launch.nim
nim c -r --out:target/nim/test_runner scripts/test.nim   # 全量共享套件
```

## 可以试什么

- **新建**：立即创建“未命名笔记”；首次启动四条示例，重开不重复播种。
- **搜索与筛选**：标题、正文、emoji；收藏／归档／标签；空结果可清空恢复。
- **编辑与保存**：标题与正文都是真实系统 EDIT；正文支持换行、折行、滚动与选区；点“保存”才写库。
- **保留草稿**：切换笔记／筛选时未保存内容留在本次会话；关闭应用丢弃未保存草稿并提示。
- **整理**：收藏／归档立即持久化标志，不会顺手保存正在编辑的标题或正文。
- **保存失败**：空标题或数据库不可写时报错并保留草稿，不冒充成功。

默认库位于 `%APPDATA%\leaf-notes`；不联网、不上传。“仅存于本机”不代表加密。正文是纯文本编辑器，示例里的勾选符号只是文字；标签只用于筛选，不支持新增／编辑。

## 边界与验证状态

- 历史实拍与开发者自测来自 2026-11-07 批次的 Windows 11、96 DPI 非提权窗口；`--demo` 是之后新增的启动路径，界面与种子数据未变。
- 未覆盖：真实中文 IME、150% DPI／混屏、高对比、真实读屏器、触摸、跨平台；未保存草稿不跨进程保留属设计。
- 独立验收尚未完成；截图身份与范围见 `docs/screenshots/README.md`。不要把旧图或本页步骤当作新的通过结论。
