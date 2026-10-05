# 发布 Nim + GPUI 应用

```sh
target/nim/leaf pack my-app --target linux --output dist
```

发布工具编译 Nim 入口，并将 GPUI + GPUI Kit 动态库放在可执行文件旁。Linux 为 tar.gz，macOS 为 .app ZIP，Windows 为 ZIP；生成 SHA256，包含业务资源、Nim 与 Rust 依赖许可证信息。

跨平台打包不能用本机二进制替代目标构建。预构建应用必须配有同目录的目标桥接库：Linux `libleaf_gpui.so`、macOS `libleaf_gpui.dylib`、Windows `leaf_gpui.dll`。`--binary` 或 `leaf.json` 的平台 binary 字段指定应用路径。工具检查目标文件头，并拒绝缺少桥接库的包。

资源与动态库均按程序位置解析，工作目录不影响运行。发布者应将包解压至其他目录，验证 `--check`、headless 事件及真实窗口启动。系统仍需安装图形驱动、字体和平台运行库。签名与公证根据目标平台单独执行。

发布扫描拒绝链接、越界路径、冲突文件名和超限归档，已有产物不会被覆盖。任何构建、验证或写入失败都会清理本次暂存结果。
