# Windows 原生表单

[示例目录](../README.md) · [源码](main.nim)

使用真实 Win32 控件演示受控输入、通知开关、保存计数、reset token 和候选失败恢复。“保存”仅增加计数，不写数据库；持久化请看[SQLite 列表示例](../native_list/README.md)。

下面是历史系统外观实拍，并非当前松石主题：

![Windows 11 系统外观原生表单历史实拍](../../docs/screenshots/native-forms-win32.png)

## 松石主题（开发中）

示例已默认选择浅色松石；框架其他应用默认仍保留系统外观。启动配置可显式选择：

```nim
let themedApp = app.withNativeTheme(matsuDark) # 或 matsuLight / systemTheme
quit run(themedApp)
```

已实现真实 EDIT 的圆角外框／文字居中、字体层级、主次按钮、通知开关与确定进度主题。保存／重置均为 96×32 DIP；EDIT 仍由系统处理输入与选区。空名称就地报错且不增加提交次数；保存记录姓名／通知快照，修改后显示未保存，恢复原值后重新显示已记录。**保存不写数据库。**

深色占位提示与可选 DWM 深色标题栏已接入，最新三主题真实表单回归及正常退出均通过；列表／生成模板的焦点修复也已在恢复后的 Windows 环境完成开发复测。不是完整 V3 工作台：原生下拉、完整现场 IME／DPI／高对比及独立验收仍未完成。语义样式可通过 `text(..., variant="primary" | "secondary" | "danger")` 和 `input(..., variant="danger")` 选择；任意 decoration 仍未开放。

[真实浅色实拍](../../docs/design/previews/native-win32/forms-light-v2.png) · [深色实拍](../../docs/design/previews/native-win32/forms-dark-v2.png) · [错误态](../../docs/design/previews/native-win32/forms-error-dark-v2.png) · [实现与验证边界](../../docs/design/native-skin-status.md)

新图为 96 DPI、656×759 原始开发截图，未代替根 README 的最终高清采集。

## 运行

在 Windows x64、已配置当前源码 CLI 的终端：

```powershell
cd examples/native_forms
leaf run
```

不需要指定后端。纯逻辑检查：

```sh
leaf --check
leaf --headless --change name "测试姓名" --click save
```

## 可以试什么

| 操作 | 观察 |
| --- | --- |
| 编辑姓名并保存 | 合法名称记录快照并更新次数；空名称保留草稿并就地报错 |
| 保存后修改／恢复通知 | 显示更改尚未保存／当前状态已记录 |
| 切换输入模式 | echo 接受、reject 拒绝、trim 去掉首尾空白 |
| 重置输入 | 模型恢复初值，reset token 更新 |
| 尝试失败候选 | 非法尺寸被拒绝，不接受候选 |
| 恢复候选 | 再次提交合法状态 |

中文、emoji、选区、IME 和缩放必须在真实 Windows 窗口检查，不能由 headless 通过推断。历史测试范围见[Windows 原生验证](../../docs/native-win32-validation.md)。
