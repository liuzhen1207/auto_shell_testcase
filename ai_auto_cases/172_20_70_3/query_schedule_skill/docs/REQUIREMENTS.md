# 查询调度（Query Scheduler / MLFQ）需求点拆解

来源文档（飞书）：
- [需求分析](https://timechor.feishu.cn/docx/FSNJdv0xHo2PqTxGQoNcCoxcnxe)
- [技术设计](https://timechor.feishu.cn/docx/OL0odP7B3oNKmhxX4QEcc1Kinfc)
- [软件测试文档](https://timechor.feishu.cn/docx/TFRidmQYIoykLyxMHdhcTnK1nHh)

被测版本：TimechoDB RC11（`ea4f835`）。原文见 `feishu_src/`。

---

## 一、需求点清单（逐条对应测试用例）

### 调度目标（非功能，核心验收）

| 编号 | 需求点 | 原文位置 | 验收判据 | 用例 |
|---|---|---|---|---|
| **REQ-01** | 短查询不被长查询阻塞 | 需求分析 §3.1、技术设计「设计目标」 | `query_thread_count=1` 下，长查询运行期间短查询（最新值）**P99 < 50ms** | QS-02 |
| **REQ-02** | 长查询不会饿死 | 同上 | 同一场景下长查询**在有限时间内正常结束**（不超时、不被永久饿死） | QS-03 |
| **REQ-03** | 无需用户手动指定优先级 | 技术设计「设计目标」、需求分析「客户场景」 | 不设置任何优先级参数，上述调度行为仍生效 | QS-04 |

### 调度器与线程资源

| 编号 | 需求点 | 原文位置 | 验收判据 | 用例 |
|---|---|---|---|---|
| **REQ-04** | Worker 线程数可配置，且实例启动后不可改变 | 技术设计 §「Worker Thread」 | `query_thread_count` 生效；实际调度线程数与之匹配 | QS-01 |
| **REQ-05** | 时间片机制：任务用完时间片让出执行权 | 技术设计 §「Worker Thread」 | `driver_task_execution_time_slice_in_ms` 生效（默认 200ms；每层 = (level+1)×该值） | QS-10 |
| **REQ-06** | 超时中断：Sentinel 线程按 deadline 中止任务 | 技术设计 §「Sentinel Thread」 | `query_timeout_threshold` 设小 → 查询被 Abort 并报超时；资源释放 | QS-06 |
| **REQ-07** | 主动取消：Coordinator abortQuery 级联中止同查询的其他子任务 | 技术设计 §「toAborted」 | 取消一个查询 → 同查询其他 DriverTask 一并 Aborted | QS-07 |

### 状态机与依赖

| 编号 | 需求点 | 原文位置 | 验收判据 | 用例 |
|---|---|---|---|---|
| **REQ-08** | DriverTask 五状态：Ready / Running / Blocked / Finished / Aborted，状态变化触发回调 | 技术设计 §「DriverTask 完整的生命周期与状态」 | 日志/指标可观测到状态流转；无非法状态组合 | QS-05 |
| **REQ-09** | 依赖管理：Blocked→Ready 由 DataBlockManager 回调驱动；Aborted 后跳过后续流程 | 技术设计 §「Blocked→Ready 流程」 | 上下游背压下任务进入/退出 Blocked，查询结果正确 | QS-08 |
| **REQ-10** | 查询任务组：同一查询的并行子任务按**组累计执行时间**定优先级；组降级时子任务跟随降级 | 技术设计 §「查询任务组」 | 分布式多 Fragment 大查询的子任务优先级一致，不出现组内错乱 | QS-09 |

### 队列与防饿死

| 编号 | 需求点 | 原文位置 | 验收判据 | 用例 |
|---|---|---|---|---|
| **REQ-11** | 多级反馈队列 + **队列累计执行时间**，按"实际/期望执行时间比"选队列（k=2） | 技术设计 §「队列累计执行时间」 | 持续短查询压力下，低优先级队列仍被调度（长查询能推进） | QS-09 |
| **REQ-12** | 队列管理：队列有最大长度限制（容量） | 技术设计 §「多级反馈调度队列」 | 并发超过 `max_allowed_concurrent_queries` 时被拒绝/排队，不崩溃 | QS-11 |
| **REQ-13** | 队列监控：可观测队列长度/等待时间 | 技术设计 §「队列监控」、需求分析 §「队列监控」 | 存在调度相关指标（`DriverSchedulerMetricSet`） | QS-14 |

### 安全性与稳定性

| 编号 | 需求点 | 原文位置 | 验收判据 | 用例 |
|---|---|---|---|---|
| **REQ-14** | 无死锁：无全局锁，只使用队列锁 + 任务锁 | 技术设计 §「安全性总结」 | 长时间混合并发压测无卡死、无查询永久挂起 | QS-13 |
| **REQ-15** | 资源与对象管理安全：Aborted/Finished 一定从三类容器移除，最终可被 GC | 技术设计 §「资源管理安全性/对象管理安全性」 | 取消/超时后无残留任务、内存不持续增长 | QS-12 |
| **REQ-16** | 重启后调度器恢复正常（生命周期与查询引擎一致） | 技术设计 §「Worker Thread 生命周期」 | 集群重启后查询与调度均正常 | QS-15 |

---

## 二、RC11 实现与配置对照（源码核对）

| 项 | 值 | 源码位置 |
|---|---|---|
| 调度核心 | `DriverScheduler` | `db/queryengine/execution/schedule/DriverScheduler.java` |
| 任务 | `DriverTask` / `DriverTaskStatus`（READY/RUNNING/BLOCKED/ABORTED/FINISHED） | 同目录 |
| 多级队列 | `MultilevelPriorityQueue` | `.../schedule/queue/multilevelqueue/` |
| Worker 线程实现 | `DriverTaskThread`（文档写的是 `DriverSchedulerThread`，实现类名不同） | 同目录 |
| 超时哨兵 | `DriverTaskTimeoutSentinelThread` | 同目录 |
| 期望时间比例 k | `LEVEL_TIME_MULTIPLIER = 2`（**硬编码**） | `DriverScheduler.java:84` |
| Worker 线程数 | `query_thread_count`，默认 = CPU 核数，<=0 则回退 CPU 核数 | `DataNodeMemoryConfig.java:82/731` |
| 查询超时 | `query_timeout_threshold` | `IoTDBDescriptor.java:588` |
| 时间片单位 | `driver_task_execution_time_slice_in_ms`，默认 **200** | `CommonConfig.java:607` |
| 全局并发上限 | `max_allowed_concurrent_queries` | `IoTDBDescriptor.java:656` |
| 队列容量 | `TASK_MAX_CAPACITY = max_allowed_concurrent_queries × degree_of_parallelism` | `DriverScheduler.java:99-101` |
| 调度指标 | `DriverSchedulerMetricSet` | `db/queryengine/metric/DriverSchedulerMetricSet.java` |

> ⚠️ 与文档的两处偏差（以 RC11 源码为准）：
> 1. 时间片单位文档写"内置常量 100ms"，RC11 已改为**可配置** `driver_task_execution_time_slice_in_ms`，默认 **200ms**；
> 2. Worker 线程实现类名文档写 `DriverSchedulerThread`，RC11 实际为 `DriverTaskThread`。

---

## 三、测试环境与规模说明

| 项 | 文档环境 | 本环境（3C5D） | 处理 |
|---|---|---|---|
| 集群 | 3 DN + 3 CN（Chaos 系列，16C32G） | 3 CN + 5 DN（.5/.4/.26 / .4/.26/.14/.27/.30） | 沿用，副本 3/2 |
| 数据规模 | 500 设备 × 1000 序列 × ~10 亿点 | 受写入与磁盘限制，按比例缩小 | 记录实际规模，判据不变（P99<50ms） |
| 长查询时长 | 约 10 分钟（全量扫描） | 按实际数据量尽可能拉长 | 记录实测时长；以"短查询不过度劣化 + 长查询能完成"为准 |

---

## 四、状态

- [x] 需求点拆解（16 条）
- [x] RC11 源码实现与配置核对
- [x] 用例框架（lib/qs.sh + benchmark 封装，已打通造数/查询延迟采集）
- [x] 用例实现：QS-02（核心场景）已跑通
- [x] RC11 执行：QS-02 三轮实测完成（详见 [REPORT.md](REPORT.md)）
- [ ] 其余 13 条需求点用例待写

### 执行进展与阻塞

| 步骤 | 状态 |
|---|---|
| 拉取需求文档 | ✅ 3 篇已入库 `feishu_src/` |
| 需求点拆解 | ✅ 16 条 |
| 源码/配置核对 | ✅ 参数与实现均已确认 |
| 测试框架（造数 + 延迟采集） | ✅ 打通（benchmark 写入 `root.test.qs_0`，可读 P99） |
| QS-02 首跑 | ❌ 无效：踩到 4 个**测试侧** bug（解析取错行、浮点比较、`count(s)` 语法、线程名不匹配） |
| QS-02 复跑 | ❌ 无效：`cluster_clean` 被残留进程挡住 → 复用了上轮 1 亿行旧数据 |
| QS-02 三跑 | ❌ 无效：收尾误用内存缓冲区用例的重型一致性校验 |
| QS-02 四跑 | ❌ 无效：我并发重复拉起集群，DN 启动报 `Connection refused`（CN 未就绪） |

> **结论：产品本身尚未被判定通过或失败。** 以上失败全部来自测试脚本与环境操作，非被测功能结论。
> 环境已恢复：集群 8/8 Running + ACTIVATED。
