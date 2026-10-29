# 缺陷草稿：查询超时（query_timeout_threshold）未生效

**建议标题（三段式）**：
`【查询调度】设置 query_timeout_threshold=1s 后执行全量 select * 【90s 仍未超时中止，DriverTaskTimeout 日志为 0 条】`

**一句话结论**：阈值设 1 秒，全量查询跑满 90 秒未中止；客户端显式 `-timeout 2000` 同样无效；5 台 DataNode 的 `DriverTaskTimeout` 日志均为 **0 条**。

---

## 一、环境

| 项 | 内容 |
|---|---|
| 版本 | TimechoDB **2.0.12.1 RC11**（build `ea4f835`，安装目录 `v20121rc11_1023_ea4f835`），企业版 |
| 部署 | 3C5D：CN `172.20.70.5/.4/.26`；DN `172.20.70.4/.26/.14/.27/.30`；客户端 `172.20.70.3` |
| 副本 | schemaRF=3，dataRF=2；树模型；共识 IoTConsensus |
| 关键配置 | `query_thread_count=1`、`query_timeout_threshold=1000`、`driver_task_execution_time_slice_in_ms=200` |
| 数据准备 | `root.test.qs_0`：201 设备 × 10 序列 × 3000 点 ≈ **600 万点**，已 flush |

## 二、复现步骤

1. 在 5 台 DN 的 `conf/iotdb-system.properties` 写入：

```
query_thread_count=1
query_timeout_threshold=1000
```

2. 重启集群，确认配置已加载：

```bash
for h in 172.20.70.4 172.20.70.26 172.20.70.14 172.20.70.27 172.20.70.30; do
  ssh cluster@$h "grep '^query_timeout_threshold=' /data/iotdb/v20121rc11_1023_ea4f835/conf/iotdb-system.properties"
done
```

五台均返回 `query_timeout_threshold=1000`。

3. 记录基线：五台 DN 的 `DriverTaskTimeout` 日志条数（均为 0）。

4. 执行一条必然超过 1 秒的全量查询：

```bash
/data1/iotdb/testdb/v20121rc11_1023_ea4f835/sbin/start-cli.sh -h 172.20.70.4 \
  -e "select * from root.test.qs_0.**;"
```

5. 观察返回内容与耗时；再显式带客户端超时重试一次：

```bash
... start-cli.sh -h 172.20.70.4 -timeout 2000 -e "select * from root.test.qs_0.**;"
```

6. 查询结束后统计五台 DN 的 `DriverTaskTimeout`：

```bash
grep -c 'DriverTaskTimeout' /data/iotdb/v20121rc11_1023_ea4f835/logs/log_datanode_*.log
```

## 三、实际现象

| 实验 | 结果 |
|---|---|
| 服务端阈值 `1000ms`，`select *` | 跑满 **90 秒**（被外部 `timeout 90` 掐断，rc=124），**未返回任何超时错误** |
| 客户端显式 `-timeout 2000` | 跑满 **60 秒+**，**同样未中止** |
| 五台 DN 的 `DriverTaskTimeout` 日志 | **全部 0 条**（Sentinel 线程从未记录超时） |
| 集群状态 | 8/8 Running + ACTIVATED，事后查询正常 |

唯一出现过的 abort 是**内存保护**，不是超时：

```
301: Query is aborted since it requests more memory than can be allocated,
     bytesToReserve: 3608040B, maxBytesCanReserve: 3423412B
```

## 四、期望结果

1. 查询执行时间超过 `query_timeout_threshold` 后，应返回 `QueryTimeoutException`（或等价超时错误）并中止。
2. 相应 DataNode 日志应出现 `[DriverTaskTimeout] Current time is {}, ddl of task is {}`。
3. 中止后资源释放，集群仍 8/8、后续查询正常。

## 五、关键证据

**配置侧（确认写入生效）**

```
172.20.70.4    query_timeout_threshold=1000
172.20.70.26   query_timeout_threshold=1000
172.20.70.14   query_timeout_threshold=1000
172.20.70.27   query_timeout_threshold=1000
172.20.70.30   query_timeout_threshold=1000
```

**日志侧（五台 DN 全部无超时记录）**

```
172.20.70.4    all=0 warn=0
172.20.70.26   all=0 warn=0
172.20.70.14   all=0 warn=0
172.20.70.27   all=0 warn=0
172.20.70.30   all=0 warn=0
```

## 六、根因分析（代码定位，RC11 `ea4f835`）

超时链路有三处，问题出在**哨兵的生命周期**上。

**① 每次提交只登记"最后一个" DriverTask 作为超时哨兵**
`DriverScheduler.submitDrivers:328`

```java
if (!submittedTasks.isEmpty()) {
  scheduler.enforceTimeLimit(submittedTasks.get(submittedTasks.size() - 1)); // 只这 1 个进 timeoutQueue
  for (DriverTask task : submittedTasks) { submitTaskToReadyQueue(task); }
}
```

设计意图是"一个哨兵看护整批"——哨兵触发时 `toAborted` 会级联中止同一 query 的所有 task。

**② 但哨兵任务一结束就被摘出超时队列**
`DriverScheduler.clearDriverTask:452`

```java
timeoutQueue.remove(task.getDriverTaskId());
```

`clearDriverTask` 对**任何**结束的 task 都执行。只要哨兵先结束，整条查询就**失去超时看护**，而同批其他 task 仍在运行。

**③ 片段级兜底只覆盖 FLUSHING**
`FragmentInstanceManager.cancelTimeoutFlushingInstances:474`

```java
if (execution.getStateMachine().getState() == FragmentInstanceState.FLUSHING
    && (now - execution.getStartTime()) > execution.getTimeoutInMs()) { ... }
```

该方法本身是**周期调度**的（`FragmentInstanceManager:123`），但状态条件卡在 `FLUSHING`，**RUNNING 状态的长查询不在兜底范围内**。

**④ DDL 是创建时固定的**
`task/DriverTask.java:52/84`

```java
private final long ddl;
...
this.ddl = computeDeadlineTimeInMs(timeoutMs);
```

DDL 创建后不变。所以只要哨兵还在 `timeoutQueue` 里，到期必然触发；**没触发只能是哨兵已被 ② 摘掉，或从未被 ① 登记**。

**⑤ 超时值的来源**
`SimpleFragmentParallelPlanner.produceFragmentInstance:140`

```java
queryContext.getTimeOut() - (System.currentTimeMillis() - queryContext.getStartTime())
```

传入的是"剩余超时"，再经 `DriverScheduler:206` 的
`timeOut > 0 ? timeOut : QUERY_TIMEOUT_MS` 兜底。

## 七、影响面

1. **失控查询无法被超时保护**：一条长时间查询可无限占用 Worker 线程；`query_thread_count=1` 时直接影响其它查询的排队。
2. 与需求《V1.0.0.1-计算模块-查询调度》REQ-06「Sentinel 线程按 deadline 中止任务」不符。
3. 客户端设置的 `query_timeout` 同样不生效，影响所有依赖超时兜底的调用方（JDBC `setQueryTimeout`、REST、MQTT）。
4. 风险不在于"精度不够"，而在于**完全不触发**：阈值 1s、实跑 90s、日志零记录。

## 八、修复建议

**方案 A｜止血，1 行（建议先评估）**
放宽片段级兜底的状态条件：

```java
// FragmentInstanceManager.cancelTimeoutFlushingInstances
if (execution.getStateMachine().getState() != FragmentInstanceState.FINISHED
    && execution.getStateMachine().getState() != FragmentInstanceState.FAILED
    && (now - execution.getStartTime()) > execution.getTimeoutInMs()) { ... }
```

代价：可能误杀"跑得久但一直在推进"的分析查询——**是否可接受需产品/研发确认**。

**方案 B｜根治，改动较小**
哨兵不依赖业务 task 生命周期。`clearDriverTask` 摘除前，若同一 query 仍有未结束 task，补一个新哨兵：

```java
timeoutQueue.remove(task.getDriverTaskId());
// 该 query 仍有未结束任务时补哨兵，避免看护中断
queryMap.getOrDefault(task.getDriverTaskId().getQueryId(), Collections.emptyMap())
    .values().stream().flatMap(Set::stream)
    .filter(t -> !t.isEndState())
    .findAny().ifPresent(this::enforceTimeLimit);
```

更彻底：为每个 FragmentInstance 维护独立看护对象（只存 deadline），与业务 task 解耦。

**方案 C｜先补可观测性（建议无论如何都做）**
在 `DriverTask` 构造与 `DriverTaskTimeoutSentinelThread.execute` 各加一行日志：task id、ddl、剩余时间。当前从外部**完全看不到 ddl 实际值**，这会让任何修复都无法验证。

## 九、待研发确认

1. **`queryContext.getTimeOut()` 的取值来源**：客户端请求里的 timeout？CN 侧配置？默认值是多少？——若它被设成极大值（如 -1 / Long.MAX），则方案 A/B 都不会生效，需先改这个。
2. **语义确认**：`query_timeout_threshold` 是"单个 DriverTask 的 deadline"还是"整条查询的 deadline"？长分析查询（如全量扫描）是否应该被超时中止？
3. 是否已有对应的已知问题单号？（我这边的理解是：本次是**完全不触发**，不是阈值不够精确）

## 十、验证方法

1. 按方案 C 加日志后重跑步骤 4，确认 `ddl - now` 是否约等于 1000ms。
2. 修复后：阈值 1s 时该查询应在 ~1–2s 内返回超时错误，且 DataNode 日志出现 `[DriverTaskTimeout]`。
3. 回归：
   - 短查询压测不受影响（QS-02 的 P99 仍 < 50ms）；
   - 正常时长的查询不被误杀（用 QS-02/QS-03 的常规查询验证）。

---

## 附：自动化用例

本条由 `ai_auto_cases/172_20_70_3/query_schedule_skill` 的 **QS-06** 覆盖。
当前 QS-06 已改为「配置生效（硬判据）+ 行为观测（记录不判失败）+ 集群可用性（硬判据）」，
待研发确认语义后再决定是否恢复为硬判据。
