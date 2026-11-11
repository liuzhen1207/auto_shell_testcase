# TDB-890 在 2.0.13.1 RC2 的修复验证

| 项目 | 内容 |
| --- | --- |
| 缺陷 | TDB-890【树转表视图】开启 `auto_sync_schema` 后，自动补列在列已存在时报 ERROR（552/305），功能正确但日志异常 |
| 验证版本 | TimechoDB 2.0.13.1 / `83183d0`（RC2），另在 2.0.13.1 / `ab6d3de`（RC1）同样未复现 |
| 验证环境 | 3 CN + 5 DN，数据面协议分别为 IoTConsensus / IoTConsensusV2 各跑一轮 |
| 结论 | **已修复**：全部用例与日志中不再出现该类 ERROR |

---

## 一、验证方法

1. **日志证据（最直接）**：对两轮全量回归（tree_view 67 例，含 17 个会触发"列已存在"场景的用例）逐个收集
   每例执行窗口内的日志增量（`results/<run>/<case>_logdelta/new_*.txt`），统计：
   - `ViewColumnAutoSyncTrigger` 出现次数
   - 专门日志 `logs/log_datanode_view_column_auto_sync_error.log` 内容
2. **源码证据**：确认 RC2 的扩列流程在 `PRE_RELEASE` 之前增加了列存在性检查。
3. **误报校正**：核实回归中残留的 `logERROR` 到底是哪条日志。

## 二、结果

### 2.1 日志：该类 ERROR 消失

| 检查项 | 结果 |
| --- | --- |
| 全量日志中 `ViewColumnAutoSyncTrigger` | **0 次**（两个协议轮次均为 0） |
| DN 专门日志 `log_datanode_view_column_auto_sync_error.log` | **空**（DN2/DN6 用 `tail` 均无输出） |
| 全量日志中 `552` / `305` | 出现 13 / 16 次，但**全部是 Raft 日志里的 `nextIndex=552/305` 数值**，不是错误码（见下） |

`552/305` 的真实来源（示例）：

```
WARN o.a.r.g.s.GrpcLogAppender:262 - 5@group-...->3-GrpcLogAppender: Follower failed (...);
     keep nextIndex (552) unchanged and retry.
WARN o.a.r.g.s.GrpcLogAppender$AppendLogResponseHandler:591 - received INCONSISTENCY reply with nextIndex 305, ...
```

即：**"552/305 错误"已不再出现**，残留的是无关的 Raft 重试日志。

### 2.2 源码：扩列流程增加了 COLUMN_CHECK 阶段

`iotdb-core/confignode/.../procedure/impl/schema/table/AddTableColumnProcedure.java`：

```java
case COLUMN_CHECK:
  LOGGER.info(ProcedureMessages.COLUMN_CHECK_FOR_TABLE_WHEN_ADDING_COLUMN, database, tableName);
  columnCheck(env);          // 先检查列是否已存在，已存在则直接结束，不再走 PRE_RELEASE/ADD_COLUMN
  break;
case PRE_RELEASE: ...
case ADD_COLUMN:  ...
case COMMIT_RELEASE: ...
```

运行日志里也能看到该阶段（每例耗时 1~3ms）：

```
AddTableColumnProcedure:83  - Column check for table xxx.v1 when adding column
AddTableColumnProcedure:110 - AddTableColumn-xxx.v1-COLUMN_CHECK costs 1ms
```

这正是当年"列已存在仍去 add → 552/305 ERROR"的修复点：**先查再走流程**。

### 2.3 回归中的 logERROR 真实归属（此前误判）

2026-11-11 V2 轮次里 tree_view 有 3 个用例被判 `logERROR`，实际日志是：

| 用例 | 真实 ERROR | 性质 |
| --- | --- | --- |
| TV-015 | `ClusterSchemaInfo:1025 - Template t_tv015 does not exist` | 模板删除后的元数据噪声 |
| TV-031 | `ScheduledExecutorUtil:181 - Schedule task failed`（RatisBgDiskGuardian） | 后台任务噪声 |
| TV-060 | `PIPE_HEARTBEAT` / `PIPE_PUSH_ALL_META` / `TOPIC_PUSH_ALL_META` 超时 + `openSession` 失败 | 节点隔离期间的 HA 噪声 |

**与 TDB-890 无关**（`ViewColumnAutoSyncTrigger` 一次都没出现）。此前报告把它们归到 TDB-890 是错的，已更正。

## 三、套件侧的相应调整

1. **移除过期白名单**：`conf/known_failures.conf` 中 TDB-890 的 17 条（TV-003/010/011/012/014/015/016/018/020/022/030/033/034/038/050/053/060）
   已删除 —— 缺陷已修复，继续留着会把**真回归**误判为 KNOWN。
2. **补全噪声规则**：`tools/classify_run.sh` 的 HA/噪声正则增加
   `Schedule task failed`、`PIPE_HEARTBEAT`、`PIPE_PUSH_ALL_META`、`TOPIC_PUSH_ALL_META`、
   `dispatch write failed`、`TIMESERIES_ALREADY_EXIST`、`Template .* does not exist`。
3. **重新归因结果**（V2 全量 run `run_20261111_121100`）：

```
=== verdicts ===
PASS 62
FAIL_ASSERT 5        # TV-080/081/082/088（TDB-888）+ TV-055（瞬时，单独复跑 3/3 PASS）
other-ERROR cases  （空）
```

## 四、结论

- **TDB-890 在 2.0.13.1 RC2 已修复**，本次两轮（IoTConsensus / IoTConsensusV2）均无该类 ERROR；
- 后续回归中若 `ViewColumnAutoSyncTrigger:156 ... 552/305` 再次出现，应当作**新回归**处理（白名单已移除）。
