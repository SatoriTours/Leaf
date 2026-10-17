# 组件异步任务实施裁定汇总

本表汇总协调裁定及代价，保留已提交规格/验证记录和归档恢复后ledger的依据。原Task1–4独立scratch被客户端归档删除，以下从已提交记录恢复，不声称找回全部原始ledger。功能源基线53368cf；Task7冻结7abb798并已独立Approved C0/I0/M2；最终整分支审查尚未进行。

| 顺序 | 裁定与理由 | 代价或判断错误时的风险 |
| --- | --- | --- |
| 1 | 在同一功能空间复用相关实现/独立审查会话，协调只处理接口、证据及交付。 | 长上下文可能使审查偏差延续；每次固定brief/diff/report，最终另做整分支审查。 |
| 2 | 功能空间保留至授权合并、推送与安全归档条件满足，保留原协调入口。 | 临时证据持续占盘；避免提前归档再次丢失未提交成果。 |
| 3 | Task1只有无既有引用的新模块时可与旧基线测试并行，不允许同共享缓存编译。 | 基线身份可能混淆，后补稳定输入官方92套并记录依赖。 |
| 4 | 日常模型实际启动报Model unavailable，线程/恢复/宿主SDK复杂集成采用保存的高消耗codex/gpt-6.1-sol/high/auto-review，独立审查采用架构配置pi/openai-codex/gpt-6.1-sol/high。 | 模型消耗增加；不修改用户profiles，不把配置名称当实际模型。 |
| 5 | 首个hook可隐式创建默认scope，首次显式taskScope配置并取得同一scope不重复收费；重复显式申请拒绝，次序无关。 | 业务可能误解隐式生命周期scope；每scope128字节加各hook128字节，文档和0/256/384回归说明。 |
| 6 | 同候选双materialize形成的新inactive暖行登记存活但不mount；以后inactive→active只activate，不补mount。 | 业务若依赖mount必先发生会遗漏初始化；明确说明首次可见回调可为activate。 |
| 7 | Task3先提供headless默认允许的任务泵能力接缝，真实GPUI/Win32在各宿主绑定；有committer不等于不支持。 | 未绑定真实能力可能过度允许，真实宿主初始和动态mount入场需拒绝不支持库。 |
| 8 | 任务服务显式保活pool并分离retire与最终回收，不依赖ORC环/GC时机；join只在普通UI边界、scope已退且身份0。 | 需要显式close/retry；非合作work仍可能延长最终join，窗口消失不等于进程已退。 |
| 9 | task-only候选复用宿主树未变的已接受Snapshot，继续validator/preparer/apply/revision门禁；真实UI/materialize失效缓存。 | 错误缓存失效会验证旧树，回归覆盖metadata后materialize和失败门禁。 |
| 10 | Snapshot-export独立可恢复异常注入暂记NotRun，不新增仅为测试的生产钩子；export仍可能触发不变量UiError。 | 该异常分支没有独立动态覆盖，不能把更早的build/预算拒绝算作它的证据。 |
| 11 | 合法busy业务体close立即关门、使State/owner失效并取消；cleanup/join延至普通边界。保护阶段/线程/Runtime错误拒绝，真实onDispose递归close幂等。 | 两阶段调用者须继续ordinary收尾；scope拒绝后保留未claim清理供重试，closed不等于cleanup完成。 |
| 12 | 关闭专用cleanup容量最多50000=活动pendingDispose40000+liveOwner10000，活动40000/16MiB门禁不变；关门后不接新生产者，去重和计费独立。 | 关闭时额外有界存储，逻辑cleanup费用最多6400000字节，不能丢dispose强守40000。 |
| 13 | delivered计有效完成claim含work错误，callbacks计实际handler，failed计交付异常；正常onError不计failed，nil handler仍消费并诊断。 | 监控调用者需按定义解释；callback0不代表没有错误交付。 |
| 14 | 公共close错误线程用普通Nim线程的nongcsafe负编译保留；uiThreadId运行时guard静态核对，动态注入NotRun；不cast或加外部pthread绕过线程检查。 | 动态错误线程分支无运行证据，不能宣称负编译等于该guard动态通过。 |
| 15 | Task5最小扩core/managed只读pending接缝和Rust model默认false严格bool的tasks_pending字段，复用既有类型，保持Bridge Copy和旧request Snapshot语义。 | 新协议元数据影响root timer唤醒，需所有正常响应与旧库协商回归。 |
| 16 | 只有有效当前session的terminal detach退役Runtime；temporary release/rebind和过时session不得关新Runtime；C detach仅metadata/atomic，不进scope/业务/join。 | session代/lease判断错误会误杀或遗漏收尾，ordinaryfinally承担最终cleanup。 |
| 17 | 能力/安装拒绝时已接受初始owner普通close并允许一次最终onDispose，仍禁止进入/完成回调/work；未接受候选无dispose。 | 启动失败仍可能有dispose副作用；这是最终清理例外，主启动错误须保留。 |
| 18 | Task5扩lists.rs正常range/finish成功响应直接arm唯一root timer，测试不手动notify。 | 唤醒可能重入/重复timer；借用释放后回调并维持root唯一泵。 |
| 19 | GpuiRunError携cleanupRuntime/exitStatus；runDesktop可选空slot同步out，每失败边界一次close尝试。pending清理且有out保留整数；默认以异常保留owner和some(0/非0)，主异常msg/parent不覆盖。 | cleanup拒绝时默认调用可能抛异常而不直接返回int；调用者须ordinary重试、成功后释放owner/error，无全局保留队列。 |
| 20 | Task6最小扩backends/win32.nim外层runNative，Win32RunError携Host/Runtime/status，Host先destroy再closeRuntime；Host未清即使有Runtime out也抛双owner，避免隐藏资源。 | 新公开失败处理义务及双owner存活；不在WndProc/release/genericSession.dispose中join，不自动重试同一边界。 |
| 21 | 修正工具目录即可用的误判：MinGW wrapper127/clang symlink broken/目标CRT缺失，无Wine；不启动停止的Windows容器或安装，Windows语义/C生成不算PE/实跑。 | Windows动态行为、PE、控件/IME/DPI仍未验收；Linux结果不能代替。 |
| 22 | Task7实际SDK特殊路径暴露独立orm_config.nims raw path入口，仅path值在switch前$→$$，非path不动，单独4e1提交和真实include回归。 | 扩一个既有ORM配置源；转义层错误会破坏路径，此修复没有解决另一generated入口，原4e1完整smoke失败保留。 |
| 23 | 随后确认scaffold内联生成独立raw path switch，明确局部例外只改生成config的--path值$→$$，页面/模板/业务不改；实际generateScaffold产物RED→GREEN，a3新包完整smoke。 | 扩一个既有生成器；未来生成配置变化，普通/中文空格/$/$$和非path及完整migration验实际链路。 |
| 24 | 四native复用f088真实运行；后续nims依赖bytes确变，但普通无$绝对repo路径path-only有效配置不变，runtime/harness/lib不变；不称a3重跑或全输入一致。 | 依赖影响判断有边界，仓库根含$本身未验证；Rust/ABI按实际依赖与工具身份单独评估。 |
| 25 | 归档恢复后证据另存主仓库忽略区及/tmp，逐SHA核对；不清理现有任务空间/会话或以原失效路径工作。 | 当前Task7完整payload约1.15GB加历史副本持续占盘；可靠保存优先于提前清空间。 |

无已知parked Critical/Important。原Task3/存量编译警告与Task6测试BareExcept/Spacing仍按证据披露；Task4新增Spacing已修。Windows/macOS/PE/IME/DPI、内存工具/长期RSS、独立Snapshot注入/diagnostic异常/联合Snapshot+error/动态wrongthread、renderer具体型号/GPUI帧耗时/FPS未执行；没有零泄漏、全平台或恒定性能结论。

Task7新增Minor交最终审查：M1 close观测fallback无deadline及异常probe释放缺口；M2遗留编译/显示告警。两者未在任务阶段进入fix loop，最终审查需明确分级和处理，不静默丢弃。
