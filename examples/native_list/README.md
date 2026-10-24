# Win32 原生列表与 SQLite 示例

这是实际 Leaf 应用，不是独立重写的测试夹具：10,000 个稳定 id，按视口构建复合行，含输入框、复选框、保存按钮和多行文字。每行使用独立组件 State；编辑一行不会重建列表 source。

在 Windows 的已配置 Leaf SDK 中进入本目录运行：

```powershell
leaf run --target windows --backend native
```

数据库默认位于用户数据目录 `leaf-native-list/items.sqlite3`，不写安装目录或资源目录。运行已生成的可执行文件时可显式选择测试数据库：

```powershell
.\LeafNativeList.exe --database 'C:\可写测试目录\列表.sqlite3'
```

操作：输入备注、切换“完成”、点击该行的“保存”。关闭应用并用同一数据库重开，内容按稳定 id 恢复；滚至最后一行也不会把池槽位置当作 id。只保存修改过的行，不预先向 SQLite 插入 10,000 条空记录。

未点击保存的草稿只属于内存中的行 State：暖缓存可能暂时保留，但淘汰或关闭后丢弃。数据库写入失败显示错误并保留当前草稿，不显示虚假的“已保存”。数据库提交与后续 UI 提交不是跨系统原子事务。

验证：`tests/nim/test_native_list_example.nim` 直接运行此应用的 Runtime/组件和真实 SQLite；`tests/windows/test_win32_list_example.nim` 使用同一应用，在真实 Host pump 中走 EDIT、checkbox、Save、首尾滚动与关闭/重开窗口。自动 Win32 消息不等于物理输入、真实 IME 或视觉验收；测试通过不代表完整 T2 或冷 USER/GDI 预算通过。
