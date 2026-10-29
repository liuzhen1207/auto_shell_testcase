# 缺陷报告：树转表视图自动补列在“列已存在”时误报 ERROR（552/305）

> **已登记 PLM：[TDB-890](https://plm.infra.timecho.com/iterations?productId=1&itemId=1485)**（itemId 1485，父记录 TDB-343，已建立双向关联；类型缺陷、优先级 P2、迭代 V2.0.13.1、负责人 陈耀斌、验证人员 刘珍、所属组长 田原）。问题发现版本 字段是下拉选项，仅含版本号（最高 V2.0.12.1），master 无法写入，暂留空。


| 项目 | 内容 |
| --- | --- |
| 缺陷标题 | 树转表视图自动补列（`auto_sync_schema`）在列已存在时产生 ERROR 日志：`Column 'x' already exist`(552) + `Internal server error`(305) |
| 严重级别 | **P2（日志/可观测性缺陷，无数据影响）**；若按“日志 ERROR 必须为零”的验收口径则为阻塞项 |
| 缺陷类型 | 功能实现与设计不符（幂等语义 + 日志级别） |
| 组件 | DataNode `ViewColumnAutoSyncTrigger` / ConfigNode `autoSyncViewColumns` 流程 |
| 发现版本 | TimechoDB 2.0.11-SNAPSHOT，BuildInfo **dc11a35** |
| 关联需求 | PLM 工作项 **TDB-343**（V2.0.13.1 树转表视图增加自动识别树模型新增测点）；需求分析 PLM doc 90 §3.2.2；技术设计 PLM doc 913 |
| 发现时间 | 2026-10-27（IoTConsensus 轮）、2026-10-28（IoTConsensusV2 轮） |
| 复现率 | **稳定复现**：49 条回归用例中两轮各 15 条命中；单轮产生 17~19 次失败调用（34~38 条 ERROR 行） |
| 影响面 | 所有使用 `auto_sync_schema=true` 的树转表视图；SchemaRegion 多副本时必然出现（副本数越多越明显） |

## 1. 摘要

开启 `auto_sync_schema=true` 的树转表视图，在树模型新增测点时会自动向视图补列。该操作由**每个 SchemaRegion 副本各自触发**：先到的一次成功补列，后到的副本再次请求时，ConfigNode 判定“列已存在”返回 `COLUMN_ALREADY_EXISTS(552)`；`ProcedureManager.autoSyncViewColumns` 把任何一个失败视图视为整体失败，返回 `INTERNAL_ERROR(305)`；DataNode 因此按 ERROR 级别打印两条日志。

**功能结果正确**（列确实补上了，查询正常），问题在于：

1. “列已存在”本应是**幂等成功**（技术设计：已存在的列会被过滤掉），却被当作**失败**；
2. 由此产生 **ERROR 级日志**，而需求 3.2.2 只要求“视图已有该列时记一条 **warn** 日志”；
3. 每次补列在 SR3 下最多产生 `(副本数-1) × 2` 条 ERROR，且多跑一次无意义的 CN procedure。

**该缺陷没有 Java 异常堆栈**：DN 侧是 `LOGGER.error(msg, status)` 打印格式化状态码，并非抛异常（详见 §7.4）。下面给出的调用链、代码行号与两侧日志锚点等价于堆栈信息。

## 2. 环境

| 项目 | 值 |
| --- | --- |
| 集群 | 3 ConfigNode（172.16.2.26/27/28）+ 5 DataNode（172.16.2.2~6） |
| 副本 | SchemaRegion 3 副本（Ratis）、DataRegion 2 副本 |
| 数据面协议 | 复现于 `IoTConsensus` 与 `IoTConsensusV2` 两种（行为一致） |
| 版本 | 2.0.11-SNAPSHOT / dc11a35，8/8 Running、全 ACTIVATED |
| 客户端 | 172.16.2.205 `/data2/iotdb/master_1026_dc11a35` |

## 3. 前置条件

1. 已建 tree 库（如 `root.tv018`）与树转表视图，且视图开启自动补列：

```sql
CREATE VIEW tv018.v (dev STRING TAG) WITH (auto_sync_schema = true) AS root.tv018.**;
```

2. SchemaRegion 为 3 副本（默认生产配置）；
3. 视图当前列的集合与即将新建的测点存在**重叠**（即新测点对应的列已被别的副本/更早的请求补上）。

## 4. 复现步骤（最小）

```sql
-- 1) 建库、建视图（auto_sync_schema=true），此时视图只有 s1
CREATE DATABASE root.tv018;
CREATE TIMESERIES root.tv018.d1.s1 INT32;
CREATE VIEW tv018.v (dev STRING TAG) WITH (auto_sync_schema = true) AS root.tv018.**;

-- 2) 在同一设备上新增一个测点，触发自动补列（三个副本都会执行这条 schema 日志）
CREATE TIMESERIES root.tv018.d1.s2 INT64;
```

等价的真实用例：`TV-018`（建视图后建序列）、`TV-020`（冲突场景）、`TV-022`（大写原名）、`TV-034`（改名后）、`TV-050`（DN 停机时）、`TV-015`（模板激活，operation 记为 `template_1`）。

## 5. 预期结果

1. 后到的副本请求应被判定为**幂等重复**，返回成功或被静默过滤，不产生失败；
2. 即使记录，也应为 **WARN**（需求 3.2.2：视图已有该列时记一条 warn 日志），不是 ERROR；
3. 主机 `logs/log_datanode_view_column_auto_sync_error.log` 不应出现内容。

## 6. 实际结果

1. 每个 SchemaRegion 副本各触发一次补列请求；先到者成功，后到者收到 `552 Column 'x' already exist`；
2. ConfigNode 返回整体状态 `305 Internal server error`，DataNode 打印两条 ERROR；
3. 单轮 49 条用例回归中，15 条用例命中，产生 34 条（IoTConsensus）/ 38 条（IoTConsensusV2）ERROR 行；
4. 功能本身正常：列均已补齐，`DESC` 与查询结果正确。

日志原文（DataNode 172.16.2.5，2026-10-28 13:32:09，`log_datanode_all.log`）：

```
2026-10-28 13:32:09,543 [6@group-00020000002B-StateMachineUpdater] ERROR o.a.i.d.s.t.ViewColumnAutoSyncTrigger:141
  - Failed to add columns to the tree to table views for operation 1,
    ConfigNode returned TSStatus(code:305, message:Internal server error.).
2026-10-28 13:32:09,544 [6@group-00020000002B-StateMachineUpdater] ERROR o.a.i.d.s.t.ViewColumnAutoSyncTrigger:149
  - Failed to add a column to the view tv038.vn for operation 1,
    ConfigNode returned TSStatus(code:552, message:Column 's1' already exist).
```

模板路径（operation 记为 `template_1`，来自 DN 内部 RPC 线程）：

```
2026-10-28 12:58:32,884 [pool-54-IoTDB-DataNodeInternalRPC-Processor-3] ERROR ...:141
  - Failed to add columns ... for operation template_1, ConfigNode returned TSStatus(code:305, ...)
2026-10-28 12:58:32,885 [pool-54-IoTDB-DataNodeInternalRPC-Processor-3] ERROR ...:149
  - Failed to add a column to the view tv015.v for operation template_1,
    ConfigNode returned TSStatus(code:552, message:Column 's3' already exist).
```

## 7. 证据

### 7.1 专用日志文件（每个 DN 独立）

`logs/log_datanode_view_column_auto_sync_error.log`（logback 里为该 logger 单独挂的 appender：`conf/logback-datanode.xml` 中 `logger name="org.apache.iotdb.db.schemaengine.table.ViewColumnAutoSyncTrigger"` → `VIEW_COLUMN_AUTO_SYNC_ERROR`）。

| 节点 | 该文件大小 | ERROR 行数 |
| --- | --- | --- |
| 172.16.2.2 | 3083 B | 12 |
| 172.16.2.3 | 509 B | 2 |
| 172.16.2.4 | 1018 B | 4 |
| 172.16.2.5 | 4081 B | 16 |
| 172.16.2.6 | 1019 B | 4 |
| 合计 | — | **38** |

同一对 ERROR 同时写入 `log_datanode_all.log` 与 `log_datanode_error.log`（172.16.2.5 上 `log_datanode_error.log` 内有 16 条），三处内容完全一致。

**逐字原文**（注意每条是**一个物理行**、行尾有一个空格、无换行续行、无堆栈）：

```
2026-10-28 13:32:09,543 [6@group-00020000002B-StateMachineUpdater] ERROR o.a.i.d.s.t.ViewColumnAutoSyncTrigger:141 - Failed to add columns to the tree to table views for operation 1, ConfigNode returned TSStatus(code:305, message:Internal server error.). 
2026-10-28 13:32:09,544 [6@group-00020000002B-StateMachineUpdater] ERROR o.a.i.d.s.t.ViewColumnAutoSyncTrigger:149 - Failed to add a column to the view tv038.vn for operation 1, ConfigNode returned TSStatus(code:552, message:Column 's1' already exist). 
```

**字段含义**

| 字段 | 值 | 说明 |
| --- | --- | --- |
| 时间 | `2026-10-28 13:32:09,543` | 与 CN 的 procedure 回滚（13:32:09 同秒）对齐 |
| 线程 | `6@group-00020000002B-StateMachineUpdater` | node 6 上该 SchemaRegion 的状态机应用线程；`StateMachineUpdater` 即“副本应用日志”路径 |
| 级别 | `ERROR` | 缺陷核心：需求只要求 WARN |
| logger:行号 | `o.a.i.d.s.t.ViewColumnAutoSyncTrigger:141` | 整体响应状态非成功时打印 |
| 消息 | `Failed to add columns to the tree to table views for operation {}, ConfigNode returned {}.` | 模板 `LOG_ADD_VIEW_COLUMN_CN_FAILED_FE4F10AC` |
| 参数 | `operation 1`、`TSStatus(code:305, message:Internal server error.)` | `operation` = 触发该次补列的 planNodeId（模板路径为 `template_1`） |

第二条同源：

| 字段 | 值 |
| --- | --- |
| logger:行号 | `ViewColumnAutoSyncTrigger:149` |
| 消息模板 | `Failed to add a column to the view {}.{} for operation {}, ConfigNode returned {}.`（`LOG_ADD_VIEW_COLUMN_FAILED_FOR_VIEW_B3EB8144`） |
| 参数 | 库 `tv038`、视图 `vn`、`operation 1`、`TSStatus(code:552, message:Column 's1' already exist)` |

即：**141 是“整体响应 = 305”，149 是“逐个失败视图 = 552”**，两条成对出现；SR3 下有几个非首个副本就重复几对。

**前后文**（`log_datanode_all.log` 同一位置，证明失败前该副本已正常应用表更新）：

```
13:32:09,325 [grpc-default-executor-1] INFO SchemaRegionStateMachine:76 - Current node [nodeId: 6] is no longer
              the schema region leader [regionId: SchemaRegion[43]], the new leader is [nodeId:7]
13:32:09,451 [pool-54-IoTDB-DataNodeInternalRPC-Processor-4] INFO DataNodeTableCache:246 - Pre-update table tv038.vn successfully
13:32:09,471 [pool-54-IoTDB-DataNodeInternalRPC-Processor-4] INFO DataNodeTableCache:505 - Commit-update table tv038.vn successfully.
13:32:09,543 [6@group-00020000002B-StateMachineUpdater] ERROR ViewColumnAutoSyncTrigger:141 - ... code:305 ...
13:32:09,544 [6@group-00020000002B-StateMachineUpdater] ERROR ViewColumnAutoSyncTrigger:149 - ... code:552 ...
```

这段上下文直接证明：**node 6 此时是 follower（leader 已切到 node 7），但它照样应用了日志、照样发起补列**，于是撞上“列已存在”。

### 7.2 线程名证明“副本各自触发”

同一 Region 组（如 `group-00020000002B`）在 **172.16.2.5（node 6）与 172.16.2.6（node 7）** 都出现了 `StateMachineUpdater` 触发的 ERROR；同理 `group-000200000034` 在 node 4 与 node 6 各出现一次。即同一批 schema 日志在多个副本上被分别应用、分别发起补列请求，后到者必然撞上“列已存在”。

### 7.3 ConfigNode 侧到底记了什么（305 在 CN 日志里查不到）

**CN 日志中不存在字面 “305”**：对三个 CN 的 `log_confignode_all.log` 执行 `grep -c 'code:305|INTERNAL_ERROR|Internal server error'` 结果均为 **0**（`grep '305'` 的 13 条命中全部是时间戳里的毫秒或耗时数字，如 `12:41:23,305`、`3059`）。

305 是 `ProcedureManager.autoSyncViewColumns` 在内存里根据“有失败视图”生成的状态（`failedViews.isEmpty() ? StatusUtils.OK : StatusUtils.INTERNAL_ERROR`），**只随 RPC 返回给 DataNode，CN 自己不落日志**；落日志的是真正的失败原因——加列 procedure 的回滚，级别 **INFO**。

一次真实调用在 CN（172.16.2.26）上的完整轨迹，同一视图 `tv034.v2` 有两个 procedure 先后到达（`log_confignode_all.log`）：

```
# 先到者：成功，列被加上
13:23:19,210 [ProcedureCoreWorker-9] INFO AddTableColumnProcedure:83  - Column check for table tv034.v2 when adding column
13:23:19,210 [ProcedureCoreWorker-9] INFO AddTableColumnProcedure:110 - AddTableColumn-tv034.v2-COLUMN_CHECK costs 0ms
13:23:19,212 [ProcedureCoreWorker-9] INFO AddTableColumnProcedure:88  - Pre release info of table tv034.v2 when adding column
13:23:19,214 [ProcedureCoreWorker-9] INFO AddTableColumnProcedure:110 - AddTableColumn-tv034.v2-PRE_RELEASE costs 2ms
13:23:19,215 [ProcedureCoreWorker-9] INFO AddTableColumnProcedure:93  - Add column to table tv034.v2
13:23:19,217 [ProcedureCoreWorker-9] INFO AddTableColumnProcedure:110 - AddTableColumn-tv034.v2-ADD_COLUMN costs 2ms
13:23:19,220 [ProcedureCoreWorker-9] INFO AddTableColumnProcedure:97  - Commit release info of table tv034.v2 when adding column
13:23:19,221 [ProcedureCoreWorker-9] INFO AddTableColumnProcedure:110 - AddTableColumn-tv034.v2-COMMIT_RELEASE costs 1ms

# 后到者（另一个副本的请求）：在 COLUMN_CHECK 就失败并回滚
13:23:19,287 [ProcedureCoreWorker-5] INFO AddTableColumnProcedure:83  - Column check for table tv034.v2 when adding column
13:23:19,288 [ProcedureCoreWorker-5] INFO AddTableColumnProcedure:110 - AddTableColumn-tv034.v2-COLUMN_CHECK costs 1ms
13:23:19,295 [ProcedureCoreWorker-5] INFO AddTableColumnProcedure:249 - Rollback DropTable-COLUMN_CHECK costs 0ms.
13:23:19,295 [ProcedureCoreWorker-5] INFO Procedure:385 - Force write unlock state to raft for pid=457
13:23:19,298 [ProcedureCoreWorker-5] INFO ProcedureExecutor:774 - Rolled back pid=457, state=ROLLEDBACK,
    exception=org.apache.iotdb.confignode.procedure.exception.ProcedureException:
      org.apache.iotdb.commons.exception.IoTDBException: Column 's2' already exist;
    org.apache.iotdb.confignode.procedure.impl.schema.table.view.AddViewColumnProcedure,
    time duration is 12
```

关键点：

1. **失败发生在 `COLUMN_CHECK`**（`ClusterSchemaManager` 的加列校验），此时列已被第一个 procedure 加上，过滤后无可加列 → `COLUMN_ALREADY_EXISTS(552)`；
2. 回滚日志只有**异常链文本**（`ProcedureException → IoTDBException: Column 's2' already exist`），没有 stack trace——`ProcedureExecutor:774` 用 `{}` 格式化异常对象，只输出 message；
3. 该行是 **INFO**，所以 `log_confignode_error.log` 里看不到；
4. `ProcedureManager` 拿到失败后把整体响应置为 305，DN 侧才出现 `code:305` + `code:552` 两条 ERROR。

即：**要查 305 的根，去 CN 的 `log_confignode_all.log` 搜 `Rolled back pid=... Column '...' already exist`，而不是搜 305。**

### 7.4 为什么没有 Java 堆栈

`ViewColumnAutoSyncTrigger.sync()` 对失败的写法是：

```java
if (resp.getStatus().getCode() != TSStatusCode.SUCCESS_STATUS.getStatusCode()) {
  LOGGER.error(DataNodeSchemaMessages.LOG_ADD_VIEW_COLUMN_CN_FAILED_FE4F10AC, operationId, resp.getStatus());
}
for (TAutoSyncViewColumnsFailure failedView : resp.getFailedViews()) {
  LOGGER.error(DataNodeSchemaMessages.LOG_ADD_VIEW_COLUMN_FAILED_FOR_VIEW_B3EB8144,
      failedView.getDatabase(), failedView.getTableName(), operationId, failedView.getStatus());
}
```

即：**用 `LOGGER.error(模板, 参数)` 打印 TSStatus，不打印异常**。因此日志里只有单行状态码，没有 stack trace。要定位只能依赖“调用链 + 两侧状态码 + 线程名”，本报告 §8 已给全。

## 8. 根因分析（调用链）

```
[DN] SchemaRegion 副本应用 schema 日志（如 CreateTimeSeries）
  └─ ViewColumnAutoSyncTrigger.sync(device2Measurements, operationId)
       ├─ collectViewMeasurements(...)                       // 视图/列探测
       └─ ConfigNodeClient.autoSyncViewColumns(req)           // 每个视图一条 TAlterOrDropTableReq
            ↓
[CN] ConfigNodeRPCServiceProcessor.autoSyncViewColumns  (…/service/thrift/ConfigNodeRPCServiceProcessor.java:1760)
  └─ ConfigManager.autoSyncViewColumns                  (…/manager/ConfigManager.java:3774)
       └─ ProcedureManager.autoSyncViewColumns          (…/manager/ProcedureManager.java:2396)
            ├─ submitAddViewColumn(...)                  // 提交 AddViewColumnProcedure
            ├─ waitingProcedureFinished(...)             // 等待；失败则加入 failedViews
            └─ status = failedViews.isEmpty() ? OK : StatusUtils.INTERNAL_ERROR;   // ← 305 的来源
                 ↓
[CN] AddViewColumnProcedure → ClusterSchemaManager 加列校验 (…/manager/schema/ClusterSchemaManager.java:1884 起)
       ├─ checkColumnSchemaForTree2TableView(...)        // 过滤“已存在的列”
       └─ shouldFail = checkResult.getColumnsToAdd().isEmpty();
            if (shouldFail) return RpcUtils.getStatus(COLUMN_ALREADY_EXISTS,
                "Column 'x' already exist");               // ← 552 的来源（1904-1908 行）
```

**结论**：设计意图是“已存在的列会被过滤掉、扩列是幂等且尽力而为的副作用”，但实现上把“过滤后无列可加”映射成了 `COLUMN_ALREADY_EXISTS` 错误，进而让整个 `autoSyncViewColumns` 返回 305，DN 按错误打印。多副本场景下这是**必然路径**，不是偶发竞态：每次补列只有第一个副本能成功，其余副本必然走 552。

## 9. 影响评估

1. **可观测性**：开启该功能的集群，`log_datanode_error.log` 与专用 error 文件持续出现 ERROR，误报警、干扰巡检；按“ERROR 日志必须为零”的验收口径直接判定失败。
2. **无效开销**：每次新增测点在每个副本上都会多跑一次必然失败的 CN procedure（等待、回滚），SR3 下放大 3 倍。
3. **数据正确性**：无影响——列由第一个成功的副本补齐，查询结果正确；两协议回归中所有相关用例的功能断言均通过。
4. **用户感知**：`SHOW CREATE VIEW`、`DESC`、查询均正常，仅日志层面异常。

## 10. 修复建议

**推荐方案 A（CN 侧幂等化）**：当 `checkColumnSchemaForTree2TableView` 过滤后 `columnsToAdd` 为空时，视为**成功**（返回 `SUCCESS_STATUS`，或返回“已存在、跳过”的显式成功标记），让 `autoSyncViewColumns` 不进入 `failedViews`。
- 优点：从根上消除 552/305，语义符合“扩列是幂等副作用”；
- 注意：需区分“用户显式 `ALTER VIEW ADD COLUMN` 时列重复”（应保持报错）与“自动补列时列重复”（应静默成功），可用请求中的 `operationType`/来源标记区分。

**方案 B（DN 侧降级）**：`ViewColumnAutoSyncTrigger` 对 `COLUMN_ALREADY_EXISTS` 只记 WARN 或不记。
- 优点：改动最小；缺点：CN 侧仍做了一次无效 procedure，305 仍会返回，治标不治本。

**方案 C（DN 侧预去重）**：补列前用本地 table cache 过滤掉已存在的列，空集合则不发起 RPC。
- 优点：省一次 RPC；缺点：cache 可能滞后（尤其副本间），仍需 A 兜底。

建议 **A + C** 组合：C 减少无谓调用，A 保证幂等正确；B 可作为临时热修。

## 11. 规避手段（用户侧）

1. 若不需要自动补列，保持默认 `auto_sync_schema=false`；
2. 必须使用时，对 `log_datanode_error.log` / `log_datanode_view_column_auto_sync_error.log` 配置过滤规则，忽略包含 `Column '.*' already exist` 且 `code:552` 的行；
3. 单副本 SchemaRegion 环境下该问题不出现（但生产不推荐单副本）。

## 12. 附件（证据包）

本地目录：`defect_evidence/`

| 文件 | 说明 |
| --- | --- |
| `dn_172.16.2.2_view_auto_sync_error.log` | DN .2 专用 error 文件全文（12 行 ERROR） |
| `dn_172.16.2.3_view_auto_sync_error.log` | DN .3（2 行） |
| `dn_172.16.2.4_view_auto_sync_error.log` | DN .4（4 行） |
| `dn_172.16.2.5_view_auto_sync_error.log` | DN .5（16 行） |
| `dn_172.16.2.6_view_auto_sync_error.log` | DN .6（4 行） |
| `alllog_context_2_5.txt` | 172.16.2.5 `log_datanode_all.log` 中一次完整上下文（含前因 schema 日志、后续 Ratis 选主），用于证明触发时序 |
| `cn_all_context.txt` | 三个 CN 在 6 个发生时刻的日志切片（无相关 ERROR，佐证 552 为业务状态码而非异常） |
| `cn_procedure_trace.txt` | **CN 侧一次失败调用的完整 procedure 轨迹**（成功者 COLUMN_CHECK→ADD_COLUMN→COMMIT_RELEASE，失败者 COLUMN_CHECK→Rollback，`IoTDBException: Column 's2' already exist`） |
| `defect_evidence_bundle.tgz` | **8 节点日志完整备份**（7.9 MB）：5 个 DN 的 `log_datanode_all.log`、`log_datanode_error.log`、`log_datanode_view_column_auto_sync_error.log`；3 个 CN 的 `log_confignode_all.log`、`log_confignode_error.log`、`log_confignode_warn.log` |

回归上下文：两轮共 49 条用例的结果与归因见 `treeview_autosync_regression_report.md`；命中用例清单为 TV-011/012/014/015/016/018/020/022/030/033/034/038/050/053 等（两轮略有差异）。

## 13. 建议提交信息

- 标题：`[TDB-343][auto_sync_schema] 树转表视图自动补列在列已存在时误报 ERROR（552/305），应为幂等成功或 WARN`
- 复现版本：2.0.11-SNAPSHOT / dc11a35
- 复现步骤：见 §4（建视图 auto_sync_schema=true → 新增测点）
- 期望：无 ERROR；已存在列静默跳过
- 实际：每个非首个副本产生 2 条 ERROR，CN 返回 552/305
