# DDL 高可用回归报告（TimechoDB 2.0.13.1 RC2 / 3C5D / SR3 / DR2）

| 项 | 值 |
| --- | --- |
| 被测版本 | **2.0.13.1 RC2（`83183d0`）** |
| 上一轮 | 2.0.13.1 RC1（`ab6d3de`），报告见 [`REPORT.md`](REPORT.md) |
| 环境 | 3 CN（.16/.17/.18）+ 5 DN（.19/.21/.22/.23/.24），SR3 / DR2，IoTConsensus |
| 用例 | 29 个（normal 11 / dn_down 9 / partition 4 / extreme 2 / ha_event 3） |
| 执行 | 2026-11-10 18:21 ~ 20:43（另含 4 例定向复验），**总 8500s ≈ 2.36h**，平均 293s/例 |
| 结果 | **22 PASS**，7 条非 PASS（其中 3 条为判定口径/环境问题，见 §3） |
| 部署说明 | RC2 部署与激活见 [`../../docs/package-deploy-activation.md`](../../docs/package-deploy-activation.md) |

## 1. 结论速览

1. **TDB-929（预删除表心跳异常）在 RC2 已修复**：29 例日志全量扫描，`getDataNodeHeartBeat` + `SemanticException` **0 命中**；RC1 上同一用例（D-007）曾出现 34 次心跳失败。
2. 核心需求保持达成：**DN 宕机前置的 9 类 DDL 全部成功**（D-001~009 的 meta/data/exp 全 YES）。
3. **RC2 新观察到一处 NPE**：改视图名触发 `updateTable` RPC 的 `NullPointerException`（`DataNodeTableCache.innerCommitUpdateTable:497`），功能结果仍正确（改名成功、元数据一致），属 RPC 层异常。
4. 两处 RC1 遗留问题 **RC2 未变**：分区 DN 的元数据操作仍返回 `305 + SocketTimeoutException`（无隔离提示）；`DROP VIEW` 仍未级联删除原表。
5. `C-002`（DDL 后整集群重启）仍无法验证：重启后集群 `0/8`，`READABLE_DNS=0/5`，判 `META_CONSISTENT=UNKNOWN`（可读性门禁生效，未误判为一致）。

## 2. 逐例结果

| 用例 | 分组 | 结论 | 耗时(s) | 说明 |
| --- | --- | --- | ---: | --- |
| N-001~004, 006~011 | normal | PASS | 153~204 | 建表/加列/改类型/建视图/TTL/删表/删库/删设备，元数据与数据一致 |
| N-005 | normal | FAIL_LOG | 204 | 改视图名触发 `updateTable` NPE（见 §3.1），功能结果正确 |
| D-001, D-003, D-004, D-006~009 | dn_down | PASS | 243~304 | **DN 宕机时 DDL 全部成功** |
| D-002 | dn_down | FAIL_LOG | 830 | DN 重启竞态 `Fail to start server`（环境） |
| D-005 | dn_down | FAIL_LOG | 293 | 同 §3.1 的 `updateTable` NPE |
| P-001, P-003, P-004 | partition | PASS | 176~600 | 正常 DN 上执行成功；数据面返回 `301 Failed to connect to config node`；恢复后收敛 |
| P-002 | partition | FAIL_ERROR_KIND | 596 | 元数据操作仍返回 `305 + SocketTimeoutException`（§3.2） |
| X-001, X-002 | extreme | FAIL_NO_ERROR | 154 / 180 | 两台数据副本全宕时删除仍成功（优于文档要求） |
| C-001, C-003 | ha_event | PASS | 238 / 191 | DDL 期间杀 CN leader 成功；并发两条 DDL 成功 |
| C-002 | ha_event | FAIL_EXPECT | 1025 | 整集群重启后未恢复，未验证元数据持久（§3.3） |

## 3. 发现

### 3.1 【RC2 新观察】改视图名触发 `updateTable` NPE

**现象**（`DDLHA-N-005`、`DDLHA-D-005`）：

```
ERROR o.a.t.ProcessFunction:49 - Internal error processing updateTable
java.lang.NullPointerException
    at java.util.concurrent.ConcurrentHashMap.putVal(ConcurrentHashMap.java:1011)
    at java.util.concurrent.ConcurrentHashMap.put(ConcurrentHashMap.java:1006)
    at o.a.i.db.schemaengine.table.DataNodeTableCache.innerCommitUpdateTable(DataNodeTableCache.java:497)
    at o.a.i.db.schemaengine.table.DataNodeTableCache.commitUpdateTable(DataNodeTableCache.java:483)
    at o.a.i.db.protocol.thrift.impl.DataNodeInternalRPCServiceImpl.updateTable(DataNodeInternalRPCServiceImpl.java:3076)
```

**代码分析**：`innerCommitUpdateTable` 直接执行

```java
databaseTableMap.computeIfAbsent(database, k -> new ConcurrentHashMap<>()).put(tableName, newTable);
```

而 `commitUpdateTable` 在 `table2` 为 null 时仍调用：

```java
innerCommitUpdateTable(unqualifiedDatabase1, tableName1, table1, null);
innerCommitUpdateTable(unqualifiedDatabase2, tableName2, table2, null);   // table2 可能为 null
```

上游只做了 `table1 == null` 的保护（注释写明 "table2 could be null"），但没有阻止把 null 值 put 进 `ConcurrentHashMap` → NPE。

**影响**：该次 `updateTable` RPC 失败，CN 侧重试后改名仍成功（`SHOW TABLES` 得到 `v2`，元数据 5 台一致），所以**功能面未受损**；但会失败一次 RPC 并打出 NPE，属实现缺陷，建议修（null 保护或跳过 put）。

**是否 RC2 引入**：RC1 的同用例（N-005）日志未见该 NPE，RC2 上稳定在 N-005/D-005 出现；两版本间 `DataNodeTableCache` 有提交 `1bbb4ff6db`（+2 行），但不是该 null-put 路径本身。需要研发确认是 RC2 变化触发还是时序问题。

### 3.2 【RC1 遗留，RC2 未变】分区 DN 的元数据操作无隔离提示

`DDLHA-P-002` 返回：

```
IoTDBSQLException: 305: net.sf.cglib.core.CodeGenerationException:
  org.apache.thrift.TException-->java.net.SocketTimeoutException: Connect timed out
```

与 RC1 完全一致。文档 §3.2.3 要求"告知用户此 DN 处于隔离状态，无法与 CN 通信"。数据面（P-003）返回 `301: Failed to connect to config node.` 是符合要求的，说明元数据路径缺同样的错误包装。

### 3.3 【环境/流程】整集群重启后无法恢复，C-002 未验证

`C-002`：DDL 后 `cluster_ctl stop` + `start`，300 秒内集群 `0/8`，5 台 DN 的 `SHOW DATABASES` 全部不可读（`READABLE_DNS=0/5`），判 `META_CONSISTENT=UNKNOWN`。

该用例的目标是验证"重启后元数据持久"，当前卡在重启本身：需要单独排查重启流程（是否 CN 选举失败 / 端口未释放 / 启动过快），再重跑该用例。**不代表产品问题**，但也说明"重启后元数据持久"这条需求目前没有验证结论。

### 3.4 【RC1 遗留，RC2 未变】`DROP VIEW` 未级联删除原表

`DDLHA-N-009` 删除视图后 `SHOW TABLES` 仍为 `t;`（原表还在），视图定义中带 `schema_cascade=true`。与 RC1 行为一致，需研发确认预期（是否只级联删除视图自动创建的表）。

## 4. RC1 vs RC2 对比

| 验证项 | RC1（ab6d3de） | RC2（83183d0） | 结论 |
| --- | --- | --- | --- |
| 预删除表心跳异常（TDB-929） | D-007 出现 34 次心跳失败 | **0 命中**（29 例全扫） | ✅ 已修复 |
| DN 宕机时 DDL 成功 | 9/9 | 9/9 | ✅ 保持 |
| 分区 DN 元数据操作提示 | 305 + SocketTimeout | 305 + SocketTimeout | ❌ 未变 |
| 删视图级联 | 原表未删 | 原表未删 | ❌ 未变 |
| 改视图名 updateTable | 未见异常 | **NPE** | ⚠️ 新观察 |
| 整集群重启后元数据持久 | 未验证（0/8） | 未验证（0/8） | ⚠️ 待补 |

## 5. 证据

测试机 `172.16.2.20`：

| 路径 | 内容 |
| --- | --- |
| `/data2/iotdb/ddl_ha_results_rc2/results.tsv` | 29 例逐例结论与耗时 |
| `/data2/iotdb/ddl_ha_results_rc2/<CASE>/` | setup/sql 输出、故障记录、元数据与数据一致性、日志扫描 |
| `/data2/iotdb/ddl_ha_results_rc2/<CASE>/logs/` | 该例 5 台 DN + 3 台 CN 的原始日志（本轮新增，失败用例可直接查栈） |
| `/data2/iotdb/overnight_rc2.log` | 整晚编排日志 |
| `/data2/iotdb/ddl_ha_results/` | RC1 的 29 例结果（归档 `results-rc1.tsv`） |

## 6. 建议

1. **§3.1 的 NPE** 单独提给研发（RC2 引入或暴露），优先级建议 P2：功能不受损，但每次改视图名都会打一次 NPE + RPC 失败重试。
2. **§3.2 隔离提示**属需求未实现项，建议回填到迭代，与 TDB-929 同批排期。
3. **§3.3 重启流程**需要单独排一次（我可以先把重启步骤加固：等 CN 全部退出、端口释放后再起，并延长等待）。
4. **§3.4 级联删除**待研发确认预期后，再决定是否算缺陷。
