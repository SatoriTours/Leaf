# 组件页面路由验证记录

本轮组件路由已实现，Task1–5及定向修复经独立审查通过。全分支最终审查在本记录更新后执行。Windows/macOS真实桌面、系统IME和跨屏DPI仍为NotRun。

## 源码与证据身份

功能基线为`f427bad02ae799a6169008975d505ee00e3d28be`。生产代码在`3bc3078`完成注册表计费修正；`bade396`补齐窗口输入和回归测试；`bb2e981`仅修改性能测试围栏。后两者的`src/`完全一致。

证据保存在项目主目录的`target/verification/component-routing/2026-10-14-final/`。`bade396-source-identity.json`记录353个输入文件；`bb2e981-coverage.json`确认只有性能测试文件改变，并记录该最终文件的普通/probes复测。已通过的生产、窗口、SDK和Rust结果按实际提交记录，没有声称在bb2重跑全量测试。

## 实际检查

| 检查 | 实际源码/身份 | 结果 |
| --- | --- | --- |
| 官方Nim全量：`nim c -r --out:<evidence>/test_runner scripts/test.nim` | bade396 | EXIT0，91套件，624.827秒；平台专用项保留SKIPPED |
| 独立发布检查：同runner加`--release-only` | bade396 | EXIT0，4套件，11.085秒 |
| `scripts/check_gpui_v2_abi.nim` | 3bc3078，相关输入与最终版本一致 | EXIT0，C/Nim/Rust布局157项 |
| 最终性能回归，普通构建 | bb2e981 | EXIT0，3项；退出码来自实现报告，独立审查核对日志 |
| 同性能回归，`-d:leafProtocolProbes` | bb2e981 | EXIT0，4项，日志无warning |
| Rust test/fmt/clippy | 本轮先前实际成功，最终输入与工具链一致 | 43项测试通过；fmt/clippy EXIT0，未重复运行 |
| 搬迁SDK | 3bc3078生产源码，与最终src一致 | 八条命令EXIT0，行为断言通过 |

Rust原始命令为`cargo test --workspace --locked`、`cargo fmt --all --check`、`cargo clippy --workspace --all-targets --locked -- -D warnings`。`2026-10-14-rust/results.json`保留真实结果；`final/rust-reuse.json`确认Rust源码、Cargo清单/锁文件、头文件、rustc和cargo身份全部匹配。

## Linux真实窗口

使用Nim2.2.6/ORC、私有Xvfb和软件渲染，显式指定独立native-test-support桥接库，运行：

```sh
LEAF_TEST_PAGES=1 LEAF_TEST_APP=tests/nim/component_pages_native_app.nim \
LEAF_GPUI_LIBRARY=/absolute/path/to/native-test-bridge.so \
LEAF_GPUI_ABI=1 LEAF_GPUI_CACHE=0 \
nim c -r --out:target/nim/native_test scripts/native_test.nim
```

依次将ABI设为1/2、CACHE设为0/1。实际窗口源码均为bade396，与最终窗口fixture相同：

| ABI | CACHE | 退出码 | 秒 |
| --- | --- | --- | --- |
| 1 | 0 | 0 | 4.874 |
| 1 | 1 | 0 | 4.373 |
| 2 | 0 | 0 | 4.424 |
| 2 | 1 | 0 | 4.826 |

四组均验证计数、未知地址、重置、页面切换、逐字中文输入完整值`页面草稿`、跨view和离开返回后的草稿保留、disposeOnLeave返回初值、ready及ctrl+q正常退出。逐字发送后等待每一步已接受caption，不放宽中文断言。旧counter/example/list分支及共同关闭路径保持兼容。

`native-matrix.json`记录源码、桥接库、工具、应用与产物SHA；ready/geometry/tree/events另存`native-artifacts/`。测试桥接SHA为`661e0b961307b9e3d8289cbf0c2be33de8d059e692a73ca367a3cd65c762fc84`。X11模拟键入不等于系统IME组合阶段验收。

## 结构性性能与预算

以下为真实HostConsumer batch样本；预热和非零State写入在测量之前，显式Snapshot在检查之后：

| 静态兄弟 | 静态render增量 | 宿主操作 | 共享父setChildren | 全部child entries | child-array payload bytes | snapshotExports增量 |
| --- | --- | --- | --- | --- | --- | --- |
| 100 | 0 | 6 | 1 | 101 | 808 | 0 |
| 1000 | 0 | 6 | 1 | 1001 | 8008 | 0 |
| 5000 | 0 | 6 | 1 | 5001 | 40008 | 0 |

六个操作是create1、remove1、setChildren1、boundary3，update/window均0。检查全部静态宿主句柄；boundary的页面/静态组件ID来自语义定位的accepted HostRecord，关联page→router→shell祖先链，root0只允许离开页。未从未过滤的warm输出训练白名单。

A11/B22/C33的真实State句柄和初始化计数保持；100完整A→B→A往返共200条切页leg，不重建页面模型，接受费用与节点数稳定。普通重访不再扫描注册页面键计算费用。新增注册收费、删除扣费，已有页面更换根type/key只替换值，不重复增加条目费。

根替换费用回归在旧b81产品上真实RED（每次多65字节），修复后GREEN。最终围栏包含登记/删除精确费用、prepare阶段在COW/set之后拒绝、新candidate State disposed、原页面值5/费用/地址不变、离开再返回验证旧registry根，以及owner卸载回实测empty Shell基线。原故障/预算/嵌套列表回归随全量runner通过。

这些计数不证明恒定CPU时间、总FFI字节或GPU帧耗时。child-array payload仅为entries×8，不含结构体、字符串和其他字段；宽父宿主的数组仍随兄弟数量增长。ABI2普通更新使用类型化batch；ABI1、显式Snapshot及Snapshot validator仍承担完整活动树导出成本。

## SDK搬迁

从新CLI和最终生产src真实打包，再搬迁到仓库之外的`/tmp`独立目录；SDK及项目路径均含中文、空格和`$`。清除NIM/LEAF_LIBRARY/LEAF_GPUI_LIBRARY/LEAF_SDK覆盖，确认无仓库父配置和用户Nim配置参与。八项依次为package、extract、init、headless、draft-retained、dispose-on-leave、desktop build、built-headless；计数/未知地址、中文草稿跨view及往返、销毁后初值均有实际断言。

包内含`leaf/component_routing.nim`；关键源码SHA与最终src一致。managed_runtime SHA为`71aa98b43321005d8c4ba56d0b8875ac12aa5e180565b01c56755e27e7037015`。包及项目stage使用普通production-feature debug桥接库`63ef5b8104253b14bfcda7dca45fe84cc8a8e3ce8840c1f2555cfdfec63af9a1`，不是带geometry probe的测试库。此为Linux包/构建/功能验收，不声称release GPU性能或SDK实机窗口验收；细节见`sdk-identity.json`和八份sdk命令记录。

## 范围裁定与兼容

- 汇总导出仅排除新增内部helper，保留公开routing API。若裁定错误可能误删公开API；已有公开组件回归及内部helper不可见检查覆盖此风险。
- 不可变路由配置在所属组件初始化时计费一次，包含未渲染controller；成功及异常均关闭初始化帧。若裁定错误可能重复计费或过早拒绝；一次计费、未显示配置合计、销毁和旧context拒绝回归覆盖此风险。

旧Router/PageGroup及Application语义不变，不改NodeKind/C ABI/依赖。直接穷尽匹配DescriptionKind的低层代码需处理新增pageOutlet，普通组件DSL按原用法使用。默认框架保留组件模型与State；不承诺保留宿主光标、选区、焦点、滚动位置或IME组合。

## 尚未执行

真实Windows/macOS桌面、系统IME组合与提交、跨屏DPI为NotRun。Linux窗口和SDK构建不能替代这些平台证据；旧React计划13.4保持未关闭，执行工作区保留。异步生命周期、URL参数、浏览器历史和嵌套路由不在本轮范围。
