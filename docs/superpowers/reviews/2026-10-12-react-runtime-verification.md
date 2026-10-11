# Leaf 组件与增量宿主最终验证

最终实现提交：`b7c52a1e75ee1d88e241414427c8f4342659e657`；功能分支 `feat/leaf-react-runtime`，基线 `96a2e035b57c8683c73957506c9a4f2a63c9141a`。功能分支保留，未合并或推送。Linux 实现与验证完成；Windows/macOS、真实系统 IME、DPI/跨屏和离屏焦点手势仍未验收。

审查后的独立证据目录：`/home/jimxl/projects/leaf/target/verification/react-runtime/2026-10-12-reviewed`。原审查报告和审查前样本保留在 `../2026-10-12-final/`；其结论对应修复前代码，不改写为复审通过。本轮按执行约定做一次集中修复与验证，没有第二位审查者。

## 审查问题与修复

| 问题 | 最终行为与证据 |
| --- | --- |
| I1 首次接入已更新 Runtime | 新宿主可安装当前接受版本，后续更新仍要求连续版本；真实 Rust HostStore 回归 |
| I2 无关 Counter 扫描列表源 | 100/1000/100000 项源、50 行已挂载时，独立 Counter 的 source key 读取增量为 0 |
| I3 可变高度列表逐行 FFI | 同次绘制在 effect 边界合并；相同视口与保护行跳过。100000 项实际窗口首屏请求 59→1，独立 Counter/行 State 更新不新增请求；滚动、初始失败退出和 scope 清理失败不重放通过 |
| I4 默认 ABI2 丢失 watch 错误 | 类型化 STATUS 返回借用 UTF-8 状态，无 UI JSON；8 种窗口组合均验证显示/清除，清除外部状态不抹除业务错误 |
| I5 nativeStrict 与 issues | 后续提交沿用 strict；兼容 issues 只随接受版本发布并去重，拒绝不发布 |
| I6 跨 Runtime State 泄漏 | init/render/updater/event/commit 中跨 Runtime 写入和嵌套任务被拒绝，执行域在异常后恢复 |
| I7 诊断 ID 导致错误输入复用 | 组件类型进入内部诊断身份；普通重挂载建立新 Entity，列表源替换只在同列表/key/宿主祖先类型匹配时迁移 |
| M1 深度兼容（升级为 Important） | 根深度 0，合法 64 条边通过、65 条边拒绝；Nim/Rust 一致 |

各问题的实际 RED/GREEN 输出在 `logs/final-i*.log`、`logs/final-m1*.log`；初始环境缺失与测试探针定位失败亦保留，没有覆盖为成功输出。

ABI2 尚未发布，本分支为 watch 在 `LeafReply` 尾部加 `value` 和 STATUS 有效标记；使用过此功能分支旧 ABI2 的外部调用者须重编译，结构尺寸不匹配会拒绝。ABI1 合同保留。托管完整节点诊断 ID 是内部格式，业务查找使用稳定 key。

## 最终回归

- 全部 85 个 Nim suite、43 个 Rust 测试通过；default/原生测试特性严格 clippy、fmt、diff 检查通过。
- C/Nim/Rust 独立实际声明布局一致：157 entries。
- Linux legacy/managed × ABI1/2 × CACHE0/1 共 8 组实际窗口通过；每组都验证 watch 错误显示/清除。组件示例与十万项可变高度列表窗口另通过。
- 最终 SDK 在中文及含空格路径解包。清除外部 NIM 并限定 PATH 后，以包内 CLI/Nim 构建组件应用；headless 增加一次得到 1，doctor 成功。应用 staged、SDK bundled 与性能测量库 SHA256 一致。
- `harness/final-reviewed.sh` 为全量回归、修复提交、串行测量和打包命令；`harness/relocate-reviewed.sh` 证明实际包内编译器；`harness/seal-reviewed.py` 校验并封存来源、原始输出与 hash。

## 最终 CPU 对照

Nim 2.2.6 Release/ORC、分配次数统计；同业务，warmup50、rounds3×iterations200，各规模 600 个原始样本。只测 Runtime+编码，Rust apply/GPUI frame 不在这张表内。

| 模式 | 静态数 | median/P95 ms | 每次分配次数 median |
| --- | ---: | ---: | ---: |
| legacy-json | 100 | 0.386314/0.398241 | 9888 |
| legacy-json | 1000 | 3.989032/4.200137 | 96887 |
| legacy-json | 5000 | 26.800928/29.970507 | 481085 |
| legacy-typed | 100 | 0.390260/0.402102 | 3553 |
| legacy-typed | 1000 | 3.902312/4.016677 | 35068 |
| legacy-typed | 5000 | 23.325497/24.026297 | 171376 |
| managed-typed | 100 | 0.013655/0.025367 | 116 |
| managed-typed | 1000 | 0.013459/0.013928 | 116 |
| managed-typed | 5000 | 0.013652/0.014132 | 116 |

managed 每次组件 render、宿主访问/归一化/索引编辑、操作数均为 1，整树 Snapshot 导出为 0。 `ffiBytes` 范围 466–467（计数字符串长度变化）。 分配是次数，不是字节；原始报告另外保存存活堆、RSS 和峰值。

## 最终实际窗口对照

1000 个静态节点，warmup50、3×200 样本。Nim Release、Rust Debug、Xvfb/Mesa 软件绘制。draw 包含 layout+paint，纯 layout 未测；frame 含调度/帧节奏。不能据此宣称硬件 60FPS。

| 模式 | 缓存 | frame median/P95 ms | dispatch median ms | Rust prepare/apply median ms | draw median ms | Host render median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| legacy-json | 0 | 79.883927/80.116469 | 1.384519 | —/— | — | — |
| legacy-json | 1 | 79.839077/80.123255 | 1.379389 | —/— | — | — |
| legacy-typed | 0 | 80.551102/99.206291 | 4.939974 | 0.055680/0.000333 | 35.157437 | 2 |
| legacy-typed | 1 | 80.405762/95.966529 | 4.932746 | 0.054426/0.000367 | 34.970257 | 2 |
| managed-typed | 0 | 96.292667/112.026209 | 0.125548 | 0.054126/0.000349 | 43.441768 | 2004 |
| managed-typed | 1 | 48.090660/59.411110 | 0.117906 | 0.048489/0.000355 | 19.404941 | 3 |

以上只支持当前工作负载的局部更新和缓存收益。保留组件状态/边界带来内存成本，各 run 的 RSS/峰值见 resources；独立 Rust 分配与候选峰值、硬件 GPU/Release Rust 性能仍缺证据。CPU metadata 在测量时记录 dirty；原生 harness 保守固定 source_dirty=true，以 implementation commit、源码归档及 binary/library hash 确认来源。

## 保留的 Minor 与平台门

- M2：类型化 RENDERING 尚未恢复旧 DPI 诊断日志；尺寸请求仍有效，日志兼容后续处理。
- M3：审查前 artifact 表中 progress.md 副本 hash 过期；原表和原样本保留并注明。本次单独封存最终证据，索引只引用不再修改的副本。
- Windows/macOS、真实系统 IME、DPI/跨屏、离屏焦点手势 NotRun。Windows runner 在 Linux 的返回 2 不计通过；计划 13.4 保持未勾选，不签全平台验收。

## 审查前记录（历史对照）

以下内容来自修复前提交 e4de315，对应 `2026-10-12-final`，不作为最终代码性能或测试计数。

### 审查前验收原文

代码采用 React 风格组件/State 调度和 ABI2 类型化宿主批次。Linux 证据通过与全平台验收分开记录；Windows/macOS、实际系统 IME、DPI 切换和离屏焦点原生手势仍未验证。

## 来源与工具链

- 执行分支：`feat/leaf-react-runtime`；基线 `96a2e035b57c8683c73957506c9a4f2a63c9141a`。
- 原始证据：`/home/jimxl/projects/leaf/target/verification/react-runtime/2026-10-12-final/`。
- Nim 2.2.6，ORC，CPU 基准 `-d:release -d:nimAllocStats`；Rust 1.98.1 / Cargo 1.98.1，锁定 GPUI Kit 0.7.0。
- CPU：13th Gen Intel Core i5-13500H；Linux Xvfb / Mesa 软件绘制。Rust 窗口测量为 Debug，不能据此宣称硬件 GPU 或 Release Rust 帧性能。
- 报告 commit 是测量时最新提交，`source_dirty=true` 明确包含尚未提交的本任务修改；binary/library SHA256 和证据中的源码 manifest/archive 用于确认准确来源，不能只凭 commit 字段当作干净构建。

## CPU Runtime 与编码

每模式同一计数业务，static=100/1000/5000，warmup=50、rounds=3、iterations=200，600 个原始样本。计时内无报告输出；这里只测 Nim Runtime 与编码，Rust apply、GPUI draw、帧指标为空。

| 模式 | 静态数 | median (ms) | P95 (ms) | 每次分配次数 |
| --- | ---: | ---: | ---: | ---: |
| legacy-json | 100 | 0.388209 | 0.406760 | 9888 |
| legacy-json | 1000 | 3.983121 | 4.331620 | 96887 |
| legacy-json | 5000 | 25.310927 | 28.014823 | 481085 |
| legacy-typed | 100 | 0.393426 | 0.416729 | 3553 |
| legacy-typed | 1000 | 3.779116 | 4.035152 | 35068 |
| legacy-typed | 5000 | 23.254101 | 24.269206 | 171376 |
| managed-typed | 100 | 0.013360 | 0.013847 | 114 |
| managed-typed | 1000 | 0.013364 | 0.013777 | 114 |
| managed-typed | 5000 | 0.013406 | 0.013775 | 114 |

三种模式均通过严格 `verifyComponentReport`，legacy 不套 managed 上限。managed 每次只 render 1 个组件、访问/归一化/索引编辑各 1 个宿主、产生 1 个操作、编码 463 字节、整树 Snapshot 导出 0 次；分配 114 次，三个规模相同。分配字段是次数，不是字节。各报告另含 GC 后存活堆、RSS 与峰值，不能把堆增量当总分配。

## 正确性与兼容

- 完整 Nim runner：85 个 suite 通过，Windows 专用项的 skip 不算 Windows 通过。
- Rust workspace：38 项测试通过；clippy `-D warnings`、fmt 检查通过。
- 缓存：固定外部尺寸的 sibling 无额外 render；自动测量文本 9→10 的布局与缓存关闭一致；外部布局、继承样式、全局 refresh 使边界失效。
- 故障：State/Runtime/consumer revision 一致，build/prepare/apply/入场拒绝不发布，恢复失败冻结，已接受 scope 错误不重放，安装和旧 owner/序列回归通过。
- 输入：实际 GPUI Kit 选区、中文、reset、拒绝恢复；源替换按稳定 ID 重绑 Entity/事件 handle；模型冲突在组合结束后同步；卸载清除边界弱注册记录。
- 虚拟列表：100000/50、活动/暖缓存有界、源替换失败、State 淘汰与 ABI1 导出通过；5000 逆序使用最终索引。
- SDK：归档包括所有组件模块及 ABI2 C 头文件，实际搬迁后随包 CLI/Nim 编译组件应用并运行，staged 和 bundled 库 hash 一致。

## 原生窗口成本

同样的 1000 个静态节点、50 次预热、3×200 样本；Nim Release、Rust Debug、Mesa 软件绘制。frame 是事件到下一次帧回执，受调度与帧节奏影响；draw 是显式 GPUI draw，含 layout+paint，不能解读为纯 layout。ABI1 不提供类型化分段，空值保持空值。各 run 的 RSS/存活堆/峰值在原始报告 resources 中；managed 额外保留组件及缓存状态，此次峰值 RSS 约 231–236MiB，高于 legacy 的约 211–215MiB。

| 模式 | 缓存 | frame median/P95 ms | dispatch median ms | Rust prepare/apply median ms | draw median ms | Host render median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| legacy-json | 0 | 64.059706/80.110163 | 1.315157 | —/— | — | — |
| legacy-json | 1 | 79.897794/80.132798 | 1.386607 | —/— | — | — |
| legacy-typed | 0 | 80.234266/96.571165 | 4.900777 | 0.056144/0.000443 | 35.012790 | 2.000000 |
| legacy-typed | 1 | 80.523649/97.726215 | 4.888888 | 0.065822/0.000400 | 34.739406 | 2.000000 |
| managed-typed | 0 | 96.190900/109.597346 | 0.123675 | 0.054889/0.000363 | 42.564059 | 2004.000000 |
| managed-typed | 1 | 48.113900/63.823857 | 0.113169 | 0.046284/0.000339 | 19.309519 | 3.000000 |

缓存开启的 managed 本次 draw median 19.31ms、frame median 48.11ms；缓存关闭分别为 42.56ms、96.19ms。说明当前固定尺寸边界避免了静态 sibling 的重复 render，不能推出所有界面都更快或达成硬件 60FPS。

## 复现与证据索引

所有下列最终执行退出码为 0；Windows runner 例外为 2 / NotRun。日志保存在证据目录 `logs/`；`commands.json` 保存命令与结果；`source.tar.gz`、`source-manifest.json` 保存测量对应源码，`artifact-sha256.json` 保存原始报告、归档和二进制 hash。

```sh
export NIM=/tmp/leaf-model-final-installed/leaf-sdk/toolchain/nim/bin/nim
export PATH="${NIM%/*}:$PATH"
export LIBRARY_PATH="$PWD/.superpowers/sdd/2026-10-12-react-runtime/sysroot/usr/lib"
export LD_LIBRARY_PATH="$LIBRARY_PATH:/tmp/mui-display/usr/lib"
cargo test --workspace --locked --target-dir /home/jimxl/projects/leaf/target
cargo clippy --workspace --all-targets --locked --target-dir /home/jimxl/projects/leaf/target -- -D warnings
cargo fmt --all --check
"$NIM" c -r --out:target/nim/test_runner scripts/test.nim
"$NIM" c -d:release -d:nimAllocStats --mm:orc --path:src --out:target/nim/component_bench benchmarks/components.nim
for mode in legacy-json legacy-typed managed-typed; do
  for count in 100 1000 5000; do
    target/nim/component_bench --mode "$mode" --static "$count" --warmup 50 --rounds 3 --iterations 200 --output "$mode-$count.json"
  done
done
"$NIM" c -r --path:src scripts/verify_component_performance.nim legacy-json-100.json legacy-json-1000.json legacy-json-5000.json
# 同样验证 legacy-typed、managed-typed 三份报告。
sh .superpowers/sdd/2026-10-12-react-runtime/verify-13-native.sh
sh .superpowers/sdd/2026-10-12-react-runtime/verify-14-native.sh
```

上述两个 shell harness 原样保存在证据 `harness/`，原生基准先编译 `benchmarks/components_native.nim`，复制默认库到固定 native-bench-bridge.so；兼容矩阵使用 native-test-support 库的独立副本，避免默认 cargo build 覆盖正在使用的库。

最终 SDK 在 `/tmp/leaf-react-sdk-final-moved/SDK 中文 with spaces/leaf-sdk` 解包，在相邻 `project 中文` 使用随包 `bin/leaf build`、构建后的 `app --headless --click add`、`leaf doctor --json`，均退出 0；结果值 1，应用 staged 原生库与 SDK bundled 库 hash 一致，且等于本次原生测量库。新示例另通过 Xvfb 下真实 increment/reset/ready/close，八种兼容组合通过 click/input/Enter/reset/reject/selection/resize/hide/show/ready/failed-viewport/close。

独立整分支审查结果在交付前补入此记录。

## 未关闭的验收项

- Windows runner 在 Linux 返回 2 / NotRun，新增 Windows fixture 已静态检查，实际窗口尚未执行；macOS NotRun。
- 系统输入法组合、真实离屏焦点行操作、DPI/缩放变化尚未取得平台操作证据；GPUI Kit 组合态 API 测试不替代真实 IME。
- 纯 GPUI layout 时间无法独立测量，原生报告只提供显式 draw（layout+paint）和 event-to-frame。
- 没有全平台通过结论；主分支未合并、未推送。
