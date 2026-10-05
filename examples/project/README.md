# Nim 多模块资源项目

入口 src/main.nim 调用 src/app.nim，资源位于 assets/message.txt。Add 回调更新独立状态，资源通过 asset() 按开发根或包内位置查找。

```sh
nim c -d:release --out:target/nim/leaf src/leaf_cli.nim
target/nim/leaf --headless --click add examples/project
target/nim/leaf pack examples/project --target linux --output dist
```

解压后执行 demo/bin/demo；macOS/Windows 需分别原生构建。[完整发布说明](../../docs/packaging.md)
