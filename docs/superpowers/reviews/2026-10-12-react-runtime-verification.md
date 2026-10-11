# Leaf 组件与增量宿主验收

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
