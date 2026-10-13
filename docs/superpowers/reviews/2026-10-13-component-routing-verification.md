# 组件页面路由验证记录（2026-10-13）

状态：Task5 实现与 Linux/ORC headless 结构性验证完成；真实窗口/平台与发行 SDK 结果待主会话在代码冻结后统一执行并补充。本文只记录实际执行的命令与未执行项，不声称全平台验收完成。

## 代码范围

- `src/leaf/component_routing.nim`：不可变地址配置、`State[int]` 导航、`renderPage` 惰性出口、配置字节初始化记账。
- `src/leaf/component_description.nim` / `component_state.nim`：`PageRetention`、`pageOutlet` 低层入口、`ownsState`、owner 初始化帧与只读计费 getter。
- `src/leaf/managed_runtime.nim`：第三类描述遍历、页面保留/恢复/销毁、router token 增量校验、owned 配置字节、缓存 registry 字节。
- `src/leaf/components.nim`：公开 routing API 与 `Route`，排除内部 helper。
- `examples/component_pages.nim`、`tests/nim/component_pages_native_app.nim`、`tests/nim/test_component_routing_performance.nim`、`tests/nim/gpui_native.nim` 页面分支。

## 实际执行的命令与结果（Linux，Nim 2.2.6，ORC）

- `nim c -r --path:src tests/nim/test_component_routing.nim` → 9 OK
- `nim c -r --path:src tests/nim/test_component_routing_state.nim` → 4 OK
- `nim c -r --path:src tests/nim/test_component_routing_outlet.nim` → 12 OK
- `nim c -r --path:src tests/nim/test_component_routing_faults.nim` → 5 OK
- `nim c -r --path:src tests/nim/test_component_routing_limits.nim` → 5 OK
- `nim c -r --path:src tests/nim/test_component_routing_performance.nim` → 1 OK；`-d:leafProtocolProbes` → 2 OK
- `test_component_faults` 5 OK、`test_component_lists` 5 OK、`test_host_reconcile` 7 OK、`test_component_commit` 与 `test_component_state` 各 OK
- `examples/component_pages.nim --check` 与 `--headless --click go-draft --click go-edit` 退出 0
- `tests/nim/component_pages_native_app.nim` 与 `tests/nim/gpui_native.nim` 编译通过

## 结构性证据

- 静态兄弟 100/1000/5000：导航不增加静态组件 render（0）、静态宿主句柄不变、`snapshotExports` 不变，宿主操作不涉及静态句柄。
- 页面根句柄变化时共享父宿主发出一次 `setChildren`，子句柄数组为兄弟数 +1（101/1001/5001）；数组体积与操作数分开报告。
- 往返 100 次后 `mountedNodes`==预热值、`treeBytes`==预热值；`-d:leafProtocolProbes` 下 registry 登记数不变。
- 故障矩阵逐 injector 核对 active + retained 页面值、地址、Runtime/session/consumer revision、旧句柄事件与首次清错后 flush 不重放。
- 预算四维（node/component/UTF-8 byte/depth）拒绝时捕获本次候选 State 已创建并 disposed，卸载回到空 Shell 基线。

## 边界与未验证项

- 结构性计数只描述受影响实例范围，不证明恒定 CPU 时间或 FFI 字节；宽父宿主的 `setChildren` 体积随兄弟线性增长，本实现不承诺 O(1)。
- 真实 Windows/macOS 窗口、系统 IME、跨屏 DPI、发行 SDK 安装后页面回归为 NotRun。
- 官方 Nim 全量 runner、Rust workspace 检查、四组 X11 ABI/CACHE 窗口与 `--release-only` 由主会话在代码冻结后执行；本记录不冒称这些结果。
