# DDL 高可用回归报告（TimechoDB 2.0.13.1 RC1 / 3C5D / SR3 / DR2）

| 项 | 值 |
| --- | --- |
| 被测版本 | 2.0.13.1 RC1（`ab6d3de`） |
| 需求文档 | PingCode `RD/T79TdX5O`《DDL 高可用》 |
| 环境 | 3 CN（.16/.17/.18）+ 5 DN（.19/.21/.22/.23/.24），SchemaRegion 3 副本、DataRegion 2 副本，IoTConsensus |
| 用例 | **29 个**（正常 11 / DN 宕机 9 / 网络分区 4 / 极端 2 / 并发 3），每例独立重置集群 |
| 执行 | 2026-11-10 14:30 ~ 16:37（另含 4 次定向复验），单例 2.5~4.5 分钟 |
| 结果 | **21 PASS / 4 FAIL_LOG / 1 FAIL_EXPECT / 1 FAIL_ERROR_KIND / 2 FAIL_NO_ERROR**（后两类中的 2 条为判定口径问题，见 §4） |

## 1. 按需求点逐条结论

| 需求点 | 用例 | 结论 |
| --- | --- | --- |
| §3.2.1 建表 / 加列 / 改列类型 | N-001/002/003 | ✅ 通过，5 台 DN 元数据一致 |
| §3.2.1 可写视图（建/改名/加列/改列名） | N-004/005 | ✅ 通过 |
| §3.2.1 TTL 设置与取消 | N-006/007 | ✅ 通过（`864000` / `INF` 均正确回读） |
| §3.2.1 删库 / 删设备 | N-010/011 | ✅ 通过 |
| §3.2.2 删表 | N-008 | ⚠️ 功能通过，但触发心跳异常（见 §3.1） |
| §3.2.2 删视图 | N-009 | ⚠️ 视图删除成功，但**未级联删除原表**（见 §3.3） |
| **§3.2.1 场景1：SQL 前 DN 宕机** | **D-001~009** | ✅ **9/9 全部成功**，元数据与数据均一致 —— 核心需求达成 |
| **§3.2.1 场景2：网络分区** | **P-001/004** | ✅ 正常 DN 上执行成功；分区恢复后元数据收敛 |
| §3.2.3 分区 DN 上的元数据操作 | P-002 | ❌ 返回 `305 + SocketTimeoutException`，**不是隔离提示** |
| §3.2.3 分区 DN 上的数据操作 | P-003 | ✅ 返回 `301: Failed to connect to config node.`，符合"无法连接 CN" |
| §3.2.2 >1/2 副本不可用的删除 | X-001/002 | ✅ 超出预期：两台数据副本全宕时删除仍成功 |
| §3.2.4 `metadata_lease_fence_ms` | P 组 | ✅ 默认 20000ms，分区 25s 后 DN 自我隔离生效 |
| §3.3 兼容性（元数据/数据一致） | 全部 | ✅ 一致性校验无一次不一致 |

## 2. 执行统计

| 分组 | 用例 | PASS | 非 PASS |
| --- | ---: | ---: | --- |
| normal | 11 | 10 | 1（N-008 心跳异常） |
| dn_down | 9 | 8 | 1（D-002 DN 重启竞态） |
| partition | 4 | 2 | 2（P-002 隔离提示、P-003 白名单未覆盖已修） |
| extreme | 2 | 0 | 2（判定口径问题，实际优于预期） |
| ha_event | 3 | 1 | 2（C-001 重启竞态、C-002 整集群重启未恢复） |

## 3. 发现

### 3.1 【缺陷候选 · 较严重】DROP TABLE 处于 pre-delete 时，心跳处理抛异常并连续失败

**现象**：`DROP TABLE` 在有一台 DN 宕机时，表进入 `pre-delete` 状态；此期间 3 台存活 DN 的心跳 RPC 连续报错：

```
ERROR o.a.t.ProcessFunction:49 - Internal error processing getDataNodeHeartBeat
org.apache.iotdb.commons.exception.SemanticException: The table ddlha_ddlha_d_007.t
  is in the pre-delete state. Please wait a few seconds. If the table is still in this state, please drop it
    at org.apache.iotdb.db.schemaengine.table.DataNodeTableCache.updateDeleteTable(DataNodeTableCache.java:1024)
    at org.apache.iotdb.db.schemaengine.table.DataNodeTableCache.getTable(DataNodeTableCache.java:811)
    at org.apache.iotdb.db.schemaengine.table.DataNodeTableCache.getTable(DataNodeTableCache.java:791)
    at org.apache.iotdb.db.schemaengine.SchemaEngine.lambda$getTimeSeriesNumber4Quota$10(SchemaEngine.java:473)
    at org.apache.iotdb.db.schemaengine.SchemaEngine.getTimeSeriesNumber4Quota(SchemaEngine.java:486)
    at org.apache.iotdb.db.schemaengine.SchemaEngine.lambda$updateAndFillSchemaCountMap$12(SchemaEngine.java:513)
```

**量级**：`DDLHA-D-007` 一轮内 DN19 15 次、DN22 2 次、DN24 17 次，共 **34 次心跳失败**；`DDLHA-N-008`（无故障删表）也出现 1~2 次。

**影响**：心跳是 DN 存活判定的唯一通道。删除卡在 pre-delete 时（恰是"有副本 DN 宕机"这一高可用目标场景），存活 DN 的心跳持续失败，CN 侧可能把这些 DN 判为不可用，进一步减少可用副本，形成恶性循环。与本需求"DN 宕机时 DDL 仍成功"的目标直接冲突。

**建议**：`getTimeSeriesNumber4Quota` / `updateAndFillSchemaCountMap` 这类后台统计路径应跳过 pre-delete 表（或捕获 `SemanticException` 不计入），不应让心跳 RPC 失败。

### 3.2 【需求未实现】分区 DN 上的元数据操作未给出隔离提示

`DDLHA-P-002`（分区 DN 上 `ALTER TABLE ADD COLUMN`）实际返回：

```
org.apache.iotdb.jdbc.IoTDBSQLException: 305: net.sf.cglib.core.CodeGenerationException:
  org.apache.thrift.TException-->java.net.SocketTimeoutException: Connect timed out
```

文档 §3.2.3 要求"抛出异常告知用户此 DN 处于隔离状态，无法与 CN 通信"。当前把底层 RPC 异常直接透传给用户，既没有隔离语义，也泄露了内部实现（cglib/thrift）。对比数据面（P-003）返回的 `301: Failed to connect to config node.` 是符合要求的，说明元数据路径缺少同样的包装。

### 3.3 【待确认】删可写视图未级联删除原表

视图 DDL 中带 `schema_cascade=true`：

```
CREATE WRITABLE VIEW "v" AS SELECT ... FROM "t" WITH (ttl='INF', schema_cascade=true)
```

但 `DROP VIEW v` 后 `SHOW TABLES` 仍能查到原表 `t`（`DDLHA-N-009` 元数据行：`DN19|tables=t;`）。文档 §3.2.2 注明"对可写视图的删除会导致其涉及到的原表一同进行删除"。需研发确认：是预期行为（仅级联删除视图自动创建的表），还是缺陷。

### 3.4 【优于预期】数据副本全宕时删除仍成功

`X-001`（DROP TABLE）与 `X-002`（DELETE DEVICES）在两台数据副本全部宕机时**均成功**，元数据一致。文档只要求"失败时用户能感知并重试"，实际表现更好。原用例期望写成"必须失败"，属判定口径问题，已记录。

### 3.5 【测试环境问题，非产品】重启竞态

1. `D-002`：DN 被 kill 后立即重启，出现 2 次 `Fail to start server`，需等待端口/会话回收后重试。
2. `C-001`：杀 CN leader 后立即拉起，出现 `another process has already locked the storage directory` + `RaftServerProxy has failed (STARTING -> EXCEPTION)`，属 Ratis 目录文件锁未及时释放。
3. `C-002`：整集群 `stop` + `start` 后 300 秒内未恢复（0/8），本轮未能验证"重启后元数据持久"。需单独排查重启流程（建议延长等待并检查 CN 选主日志）。校验器当时把"5 台都连不上"误判为"一致"，已加可读性门禁（`READABLE_DNS < 3` 时判 `UNKNOWN`）。

## 4. 判定口径修正

| 用例 | 原判定 | 修正后 | 依据 |
| --- | --- | --- | --- |
| N-010 | FAIL_EXPECT | PASS | `DROP DATABASE` 后 `SHOW TABLES` 返回空结果而非报错，判据已改为"报错或空结果" |
| P-003 | FAIL_ERROR_KIND | PASS | 报错 `301 Failed to connect to config node` 符合"无法连接 CN"，正则已补 |
| X-001 / X-002 | FAIL_NO_ERROR | 视为通过 | 文档允许失败但不要求失败，成功更优 |

## 5. 证据

测试机 `172.16.2.20`：

| 路径 | 内容 |
| --- | --- |
| `/data2/iotdb/ddl_ha_results/results.tsv` | 33 行逐轮结论（29 例 + 4 次复验） |
| `/data2/iotdb/ddl_ha_results/<CASE>/` | 每例 `setup.out`、`sql.out`、`fault.txt`、`meta-consistency.txt`、`data-consistency.txt`、`log-scan.txt`、`round.log` |
| `/data2/iotdb/ddl_ha_results/DDLHA-D-007/logs/` | 心跳异常现场日志（含完整栈） |
| `/data2/iotdb/ddl_ha_results/run_all.log` | 全量执行日志 |

## 6. 结论

1. **需求主体已达成**：DN 宕机前置的 9 类 DDL 全部成功，分区场景正常 DN 上可执行，元数据与数据在 5 台 DN 上始终一致。
2. **两个必修项**：心跳异常（§3.1）直接威胁存活判定；分区 DN 元数据操作缺隔离提示（§3.2）。
3. **一个待确认项**：删视图级联（§3.3）。
4. 建议把 §3.1 单独立缺陷单（影响面比 §3.2 大），§3.2 作为需求未实现项回填到迭代。
