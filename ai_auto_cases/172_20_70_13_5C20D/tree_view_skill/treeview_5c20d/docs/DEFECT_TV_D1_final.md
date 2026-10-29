# 缺陷报告 TV-D1：树转表扩列请求在副本间重复触发 → CN 返回 `INTERNAL_SERVER_ERROR(305)` / `COLUMN_ALREADY_EXISTS(552)`，DN 记 ERROR

> **已录入 PLM：`TDB-890`** —— 【树转表视图】开启 auto_sync_schema 后自动补列在列已存在时报 ERROR（552/305），
> 功能正确但日志异常；负责人 **陈耀斌**；条目 <https://plm.infra.timecho.com/iterations?productId=1&itemId=1485>。
>
> 面向研发：本文给出**触发场景、实测日志（含两副本对照）、源码定位（文件:行）与根因**。
> 功能结果正确（列最终加上了），问题是**幂等/去重失败 + 错误日志**，并且把"重复加列"包装成 500 级错误。

## 1. 测试环境

| 项 | 值 |
|---|---|
| 版本 | `2.0.11-SNAPSHOT`，BuildInfo **`dc11a35`** |
| 集群 | 5 CN + 20 DN，SchemaRegion **3** 副本 / DataRegion 3 副本，`IoTConsensus` |
| 部署目录 | `/data/iotdb/master_1026_dc11a35` |
| 每轮准备 | 停 25 节点 → 清 data/logs → 恢复 conf → 启动 → 等 Running |

## 2. 触发场景

**要点：同一视图在一次 schema 变更中，被多个副本各触发一次扩列。**

线上命中的都是"短时间连续触发同一视图扩列"的用例：

| 用例 | 动作 | 命中时间 |
|---|---|---|
| `TV-SYNC-06` | 视图(auto_sync=true) → 激活模板 → 立即 `ALTER SCHEMA TEMPLATE tp add (s3 INT64)` | 14:07:55 |
| `TV-SYNC-10` | 视图(auto_sync=true) → `create timeseries ...MixedCase DOUBLE` | 14:34:08 |
| `TV-SYNC-11` | 视图(RESTRICT + auto_sync=true) → `create timeseries ...` | 23:02:31 |
| `TV-LEAK-01` | 反复建删视图 + 新增测点（6 轮） | 19:21:28 |

最小 SQL（以 TV-SYNC-10 为例）：

```sql
create database tv_s10;
create view tv_s10.v (dev STRING TAG) with (auto_sync_schema=true) as root.tv_s10.**;
create timeseries root.tv_s10.d1.MixedCase DOUBLE;   -- 触发扩列
```

## 3. 测试结果

**功能面（正确）**：列被加上，2 秒后视图更新成功

```
14:07:55.179 DataNodeTableCache:246 - Pre-update  table tv_s06.v successfully
14:07:55.191 DataNodeTableCache:505 - Commit-update table tv_s06.v successfully
14:07:57.538 DataNodeTableCache:246 - Pre-update  table tv_s06.v successfully   ← 重试后再次成功
14:07:57.549 DataNodeTableCache:505 - Commit-update table tv_s06.v successfully
desc 结果：s1/s2/s3 均在视图中，类型正确
```

**日志面（缺陷）**：两个副本各打一对 ERROR

```
14:07:55,252 [8@group-000200000002-StateMachineUpdater]  (172.20.70.103)
  ERROR o.a.i.d.s.t.ViewColumnAutoSyncTrigger:141
    - Failed to add columns to the tree to table views for operation 1,
      ConfigNode returned TSStatus(code:305, message:Internal server error.).
  ERROR o.a.i.d.s.t.ViewColumnAutoSyncTrigger:149
    - Failed to add a column to the view tv_s06.v for operation 1,
      ConfigNode returned TSStatus(code:552, message:Column 's1, s2' already exist).

14:07:55,265 [23@group-000200000002-StateMachineUpdater] (172.20.70.118)
  ERROR ViewColumnAutoSyncTrigger:141 ... code:305 Internal server error.
  ERROR ViewColumnAutoSyncTrigger:149 ... code:552 Column 's1, s2' already exist.
```

TV-SYNC-10 同一形态（列名不同，节点 8@.101 / 9@.104）：

```
14:34:08,705 ERROR ViewColumnAutoSyncTrigger:141 ... code:305 Internal server error.
14:34:08,705 ERROR ViewColumnAutoSyncTrigger:149 ... code:552 Column 'mixedcase' already exist.
14:34:08,752 ERROR ViewColumnAutoSyncTrigger:141 ... code:305 Internal server error.   (另一副本)
```

状态码定义：`305 = INTERNAL_SERVER_ERROR`、`552 = COLUMN_ALREADY_EXISTS`（`TSStatusCode.java`）。

## 4. 源码取证

### 4.1 DN 侧：每个副本都会触发并检查返回码

`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/schemaengine/table/ViewColumnAutoSyncTrigger.java:130-155`

```java
TAutoSyncViewColumnsResp resp =
    configNodeClient.autoSyncViewColumns(new TAutoSyncViewColumnsReq(updateViewReqs));
...
if (resp.getStatus().getCode() != TSStatusCode.SUCCESS_STATUS.getStatusCode()) {
  LOGGER.error(DataNodeSchemaMessages.LOG_ADD_VIEW_COLUMN_CN_FAILED_FE4F10AC,   // :141
      operationId, resp.getStatus());
}
if (resp.getFailedViews() != null) {
  for (TAutoSyncViewColumnsFailure failedView : resp.getFailedViews()) {
    LOGGER.error(DataNodeSchemaMessages.LOG_ADD_VIEW_COLUMN_FAILED_FOR_VIEW_B3EB8144,  // :149
        failedView.getDatabase(), failedView.getTableName(), operationId, failedView.getStatus());
  }
}
```

### 4.2 DN 侧：queryId 本意是让 leader/follower 的请求被 CN 识别为同一个

同文件 `:300-320`

```java
// leader and follower would build the same queryId when apply the same log; so CN could recognize
// the same add view column request.
private static String buildQueryId(String columnFingerprint, String database, String table) { ... }
```

### 4.3 CN 侧：只对**提交阶段**的重复/重叠做了处理

`iotdb-core/confignode/src/main/java/org/apache/iotdb/confignode/manager/ProcedureManager.java`

```java
// :2396 autoSyncViewColumns(...)
final TSStatus submissionStatus = submitAddViewColumn(addColumnReq, procedures, failedViews);
if (submissionStatus.getCode() == TSStatusCode.OVERLAP_WITH_EXISTING_TASK.getStatusCode()) {
  overlappingReqs.add(...);            // 只处理"与正在跑的任务重叠"
}
processOverlappingTask(overlappingReqs, procedures, failedViews);
...
final TSStatus status = failedViews.isEmpty() ? StatusUtils.OK : StatusUtils.INTERNAL_ERROR;  // :2435
```

```java
// :2502 重复提交分支：如果之前那个 procedure 已经跑完（get 返回 null）
} else if (status.getCode() == TSStatusCode.REPEATED_WITH_EXISTING_TASK.getStatusCode()) {
  final Procedure<ConfigNodeProcedureEnv> repeatedProcedure =
      executor.getProcedures().get(submissionResult.getRight());
  if (Objects.isNull(repeatedProcedure)) {                 // ← 已完成的重复请求
    failedViews.add(new TAutoSyncViewColumnsFailure(..., 
        RpcUtils.getStatus(TSStatusCode.INTERNAL_SERVER_ERROR)));   // ← 直接 305
  } else {
    procedures.add(new Pair<>(addColumnReq, repeatedProcedure));
  }
}
```

### 4.4 552 的产生处：所有列都已存在就直接报错，而不是幂等成功

`iotdb-core/confignode/src/main/java/org/apache/iotdb/confignode/manager/schema/ClusterSchemaManager.java:1898-1908`

```java
final boolean shouldFail =
    tableType == TableType.BASE_TABLE && detectConflict
        ? checkResult.hasConflict()
        : checkResult.getColumnsToAdd().isEmpty();        // ← 视图：没有新列要加
if (shouldFail) {
  final String errorMsg = String.format("Column '%s' already exist", ...);
  return new Pair<>(RpcUtils.getStatus(TSStatusCode.COLUMN_ALREADY_EXISTS, errorMsg), null);  // 552
}
```

## 5. 根因

一次 schema 变更（模板激活 / 建序列 / 模板扩列）会在 SchemaRegion 的 **3 个副本**上分别应用同一份日志，
每个副本的 `ViewColumnAutoSyncTrigger` 都会向 CN 发一次 `autoSyncViewColumns`，且都携带
**由列指纹算出的同一个 queryId**（见 4.2）。

CN 端**只有两种情况能合并**：

1. 提交时与"正在运行"的任务重叠（`OVERLAP_WITH_EXISTING_TASK`，2s×4 轮重试）；
2. 重复提交且旧 procedure **仍在 executor 里**（`REPEATED_WITH_EXISTING_TASK` 且 `get(...) != null`）。

**缺口在于**：副本 A 的加列 procedure 很快（毫秒级）就完成了；副本 B 的请求到时，
- 已经"不重叠"（A 不在运行），
- 也不"重复"（A 已从 executor 移除，`get()` 返回 null）→ 走 4.3 的 `INTERNAL_SERVER_ERROR` 分支；

或者 B 重新提交了一个新的 AddViewColumnProcedure，执行时发现
`columnsToAdd.isEmpty()` → 4.4 直接返回 `COLUMN_ALREADY_EXISTS(552)`。

两种路径最后都被 4.3 汇总成 **整体 305**（`failedViews` 非空 ⇒ `StatusUtils.INTERNAL_ERROR`），
DN 端 4.1 于是打出两条 ERROR。**这正是 doc 913 里"幂等过滤 + queryId 去重"两道防线应当拦住、但实际没拦住的地方。**

## 6. 影响

| 维度 | 影响 |
|---|---|
| 功能 | 无（列最终加上，数据可查） |
| 日志 | 每次触发（3 副本）产生 2~6 条 ERROR；模板/批量建序列场景会持续刷 |
| 告警 | ERROR 计入告警 ⇒ 误报；`Internal server error` 会误导为严重故障 |
| 排查 | 真实故障淹没在噪声里；本次回归 4 条用例（SYNC-06/10/11、LEAK-01）**仅因此项**判 FAIL |
| 定级建议 | **P2**（幂等/去重缺陷 + 错误日志） |

## 7. 修复建议

1. **幂等前置（推荐）**：CN 在 `submitAddViewColumn` 之前，先按当前表结构过滤掉已存在的列；
   过滤后为空 ⇒ 视为**成功（no-op）**，不建 procedure、不进 `failedViews`；
2. **缩短/补全去重**：`getProcedures().get(queryId)` 为 null 时，不要直接判 500，
   而是查一次表结构（同 1）再决定；
3. **错误码语义**：把 `COLUMN_ALREADY_EXISTS` 在 `autoSyncViewColumns` 上下文里当成功处理；
4. **日志级别**：DN 端对"重试后最终成功"的情形不应打 ERROR（doc 90 的表述是"重试次数内全部失败"才记），
   首次冲突可记 INFO/DEBUG；与 TV-D3 一并整理"可忽略错误码表"。

## 7.5 稳定复现（`TV-REPRO-D1` v3，2026-10-28 16:36）

**触发要点：让同一视图在短时间内被触发多次加列**（批量激活模板 + 连续扩模板）。
实测单次激活不命中（v1 PASS），批量触发**稳定命中**：

```sql
create database rp_d1;
create device template rp_tp (s1 FLOAT, s2 DOUBLE);
set device template rp_tp to root.rp_d1;
create view rp_d1.v (dev STRING TAG) with (auto_sync_schema=true) as root.rp_d1.**;

-- 24 台设备批量激活（每台都触发一次扩列）
create timeseries using device template on root.rp_d1.dev00;   -- … dev23
-- 紧接着连续扩模板（再触发一批"同一视图加列"）
alter schema template rp_tp add (s3 INT64);
create timeseries using device template on root.rp_d1.dev24;   -- … dev35
alter schema template rp_tp add (s4 BOOLEAN);
```

实测结果（`results/rp5_TV-REPRO-D1`）：

```
16:36:53,880 dn@172.20.70.106 [15@group-000200000002-StateMachineUpdater]
  ERROR ViewColumnAutoSyncTrigger:141 ... code:305 Internal server error.
16:36:53,881 dn@172.20.70.106
  ERROR ViewColumnAutoSyncTrigger:149 ... code:552 Column 's1, s2' already exist.
16:36:53,901 dn@172.20.70.117 [23@group-000200000002-StateMachineUpdater]
  ERROR ViewColumnAutoSyncTrigger:141 ... code:305 Internal server error.
16:36:53,902 dn@172.20.70.117
  ERROR ViewColumnAutoSyncTrigger:149 ... code:552 Column 's1, s2' already exist.
```

功能面同时验证通过：`fields={'s1','s2','s3','s4'}` 全部进入视图（缺陷复现不影响功能正确性）。
命中后 2 秒内视图更新成功（`Pre-update/Commit-update table rp_d1.v successfully`）。

## 8. 复现方式

单次触发在本环境不必然命中（实测 `TV-REPRO-D1` v1 单次激活 PASS），需要**并发触发**：

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW
# 连续触发同一视图扩列（12 台设备批量激活模板 + 立即扩模板 + 连续建序列）
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp TV-REPRO-D1
# 或直接跑原始命中用例
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp TV-SYNC-06
```

判定：`grep -a ViewColumnAutoSyncTrigger logs/log_datanode_all.log` 出现
`code:305 Internal server error` 与 `code:552 Column '...' already exist` 即成对复现。

## 9. 证据索引（172.20.70.122）

| 内容 | 路径 |
|---|---|
| TV-SYNC-06 判定与取证 | `TREEVIEW/results/tv_TV-SYNC-06/cases/TV-SYNC-06/{result.json,evidence/log_findings.txt,evidence/log_context.txt}` |
| TV-SYNC-10 取证 | `.../tv_TV-SYNC-10/cases/TV-SYNC-10/evidence/log_findings.txt` |
| TV-SYNC-11 取证 | `.../tv3_TV-SYNC-11/...`（或 latest） |
| TV-LEAK-01 取证 | `.../tv_TV-LEAK-01/cases/TV-LEAK-01/evidence/log_findings.txt` |
| CN/DN 日志归档 | 各用例 `evidence/logs/{cn,dn}_<host>.tar.gz` |
