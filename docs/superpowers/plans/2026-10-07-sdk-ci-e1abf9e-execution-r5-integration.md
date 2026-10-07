# SDK CI r5 合并后验证

2026-10-07，executor。按 root 并发协调结论，仅验证 current HEAD `08d2c99f971e98363b99f2ee2dacc26cec527855` + 已有 r5 dirty，不写任何业务源码，不修 model。保留 model 合并结果；没有 commit/push/merge、agent/工作区创建、读取 model plan、workflow/collector 修改、安装或发布。

开始工作区仅 `tests/release/test_sdk.nim` 的 r5 diff（19 添加 / 2 删除）及原 `execution-r5.md` untracked。开始/结束 HEAD 一致；274 个源码、Cargo/构建输入、release 测试、旧 SDK 执行记录/review 的 SHA256 均稳定，原 r5 diff 完全相同，index 空。新增文件仅本记录和任务证据目录；旧 r5 未改。本次被测 `test_sdk.nim` SHA256 为 `036320026f8c42fc230caac10cb86e04b2dd42f35fc5e45cd9618a4436feedd4`，不是旧 r5 停止时的快照。

| 原始日志 | 被测 exit | 实际结果 |
| --- | --- | --- |
| [release-suite.log](/tmp/leaf-ci-e1abf9e-r5-integration/release-suite.log) | 0 | 最新合并快照完整 release-only：4 文件，44 OK / 0 FAILED / 0 skipped。包含新 test_model_dependencies 的来源摘要/许可证/拒绝篡改三项，以及 r5 真实 req stdout 私钥生成、中文 key 的 pkey 读取、原严格 CA 和环境恢复保护。 |
| [windows-cgen.log](/tmp/leaf-ci-e1abf9e-r5-integration/windows-cgen.log) | 0 | 最新 test_sdk Windows amd64 宏分支 C 生成成功，未链接/运行；process_io、licenses、SDK 平台分支 unused import/install 提示如实保留。 |
| [integrity.log](/tmp/leaf-ci-e1abf9e-r5-integration/integrity.log) | 0 | HEAD、274 项摘要、原 dirty diff、index 和工作区范围检查通过。 |
| [final-integrity.log](/tmp/leaf-ci-e1abf9e-r5-integration/final-integrity.log) | 0 | 新记录写入后再次确认 HEAD/摘要/diff/范围稳定。 |
| [diff-check.log](/tmp/leaf-ci-e1abf9e-r5-integration/diff-check.log) | 0 | Git diff 空白检查通过。 |

完整实际命令/UTC/真实退出码/日志路径见 [commands.jsonl](/tmp/leaf-ci-e1abf9e-r5-integration/commands.jsonl)，计数见 [summary.json](/tmp/leaf-ci-e1abf9e-r5-integration/summary.json)，前后摘要见 [before.json](/tmp/leaf-ci-e1abf9e-r5-integration/before.json)、[after.json](/tmp/leaf-ci-e1abf9e-r5-integration/after.json)。run.py 外层退出状态不替代日志内被测退出码。实际工具证据：开始 `5c5c2f/c3d164`；测试 `417065/306e58/10ac00`、Cgen `d922e5/d625b6`；完整结果核对与摘要 `3f4294/ec0a16`。沿用本会话已读 verification-before-completion，证据先于结果声明。

本次合并后的必要 Linux 验证完成，没有发现需要 model 修复的失败；不复跑无关 Rust/DPI。Windows 原生私钥生成及中文 key 读取仍 **not_verified**，Cgen 不替代 native CI。原 DPI P1–P4 继续 **not_verified**，没有最终 Windows 清晰度证明。交回 root 独立审核/提交协调和 Windows native 重跑；不宣称总体 CI/整体验收 pass。
