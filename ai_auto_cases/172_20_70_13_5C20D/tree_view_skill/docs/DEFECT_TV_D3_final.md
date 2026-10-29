# 缺陷报告 TV-D3：`CREATE VIEW` 的**预期失败**（同名测点类型冲突）被 CN 记为 ERROR

> **已录入 PLM：`TDB-894`** —— 【树转表视图】CREATE VIEW 因同名测点类型冲突失败（符合需求）时，
> CN 仍记 ERROR 并打印完整 response；迭代 **V2.0.13.1**，负责人 **陈耀斌**，组长 **田原**，验证 **刘珍**，
> 发现版本 **V2.0.12.1**，parent = TDB-343。
>
> 面向研发：功能行为**正确**（视图创建失败），问题是**日志级别与可观测性**：
> 用户输入错误被记成 ERROR + 完整 response，污染 CN 日志与告警。

## 1. 测试环境

| 项 | 值 |
|---|---|
| 版本 | `2.0.11-SNAPSHOT`，BuildInfo **`dc11a35`** |
| 集群 | 5 CN + 20 DN，SchemaRegion 3 副本 / DataRegion 3 副本，`IoTConsensus` |
| 部署目录 | `/data/iotdb/master_1026_dc11a35` |
| 客户端 | `start-cli.sh`，root/TimechoDB@2021 |
| 每轮准备 | 停 25 节点 → 清 data/logs → 恢复 conf → 启动 → 等 Running |

## 2. 测试用例（最小复现）

用例 ID：`TV-REPRO-D3`（回归用例：`TV-BASE-07`）
源码：`treeview_5c20d/scripts/pgkit/cases_tv_repro.py::case_repro_d3`

```sql
-- 树模型：同名测点 s1 在两个设备上类型不同
create timeseries root.rp_d3.d1.s1 INT32;
create timeseries root.rp_d3.d2.s1 DOUBLE;

-- 表模型：不声明 FIELD，触发自动扫描
create database rp_d3;
create view rp_d3.v (dev STRING TAG) as root.rp_d3.**;
```

## 3. 测试结果

**功能面（正确）**：视图创建失败，错误码明确

```
SQL> create view rp_d3.v (dev STRING TAG) as root.rp_d3.**
Msg: org.apache.iotdb.jdbc.IoTDBSQLException:
     614: Multiple types encountered when auto detecting type of measurement 's1', please check
```

614 = `DATA_TYPE_MISMATCH`，与需求 docx §2.1.1「有同名但不同类型的测点，则创建时报错」一致。

**日志面（缺陷）**：CN 对同一个**预期内的用户输入错误**打 ERROR

```
ERROR o.a.i.c.c.a.h.r.TreeDeviceViewFieldDetectionHandler:67
  - Failed to DETECT_TREE_DEVICE_VIEW_FIELD_TYPE on DataNode:
    {id=13, internalEndPoint=TEndPoint(ip:172.20.70.112, port:10730)},
    response: TDeviceViewResp(status: TSStatus(code:302,
      subStatus:[TSStatus(code:614, message: Multiple types encountered ...)]))
```

（302 = `MULTIPLE_ERROR`，614 = `DATA_TYPE_MISMATCH`）

用例判定：**FAIL**（"D3 缺陷面：该预期失败不应在 CN 日志留下 ERROR" 与
"收尾③ CN/DN 日志无 ERROR/WARN 异常" 两项命中）。

## 4. 日志取证

| 项 | 内容 |
|---|---|
| 主机 | 172.20.70.100 |
| 文件 | `logs/log_confignode_all.log` |
| 时间 | 2026-10-28 13:54:35,495 |
| 线程 | `AsyncDataNodeInternalServiceClientPool-selector-29` |
| 级别 | **ERROR** |
| 计数 | 1 行（DN 端 1 个 region 返回 302/614） |

原始取证文件：`results/rp_TV-REPRO-D3/cases/TV-REPRO-D3/evidence/repro_d3_createview_error.txt`
（含完整 response 与前后文），CN 日志归档在 `.../evidence/logs/cn_172.20.70.100.tar.gz`。

## 5. 源码取证与根因

**位置**：`iotdb-core/confignode/src/main/java/org/apache/iotdb/confignode/client/async/handlers/rpc/TreeDeviceViewFieldDetectionHandler.java:60-73`

```java
@Override
public void onComplete(final TDeviceViewResp response) {
  responseMap.put(requestId, response);

  if (response.getStatus().getCode() == TSStatusCode.SUCCESS_STATUS.getStatusCode()) {
    LOGGER.info(ConfigNodeMessages.SUCCESSFULLY_ON_DATANODE, requestType, formattedTargetLocation);
  } else {
    LOGGER.error(                                    // ← 只要不是 SUCCESS 就 ERROR
        ConfigNodeMessages.FAILED_TO_ON_DATANODE_RESPONSE,
        requestType, formattedTargetLocation, response);
  }
  ...
}
```

i18n 文本（`ConfigNodeMessages.java:323`）：`"Failed to {} on DataNode: {}, response: {}"`。

### 根因

该 handler 是 **CN→DN 异步探测** 的通用回调，判定只有"SUCCESS / 非 SUCCESS"两档：

- 对**真正的系统故障**（DN 不可达、内部异常）记 ERROR 合理；
- 但 `DATA_TYPE_MISMATCH(614)`、`MULTIPLE_ERROR(302)`、`COLUMN_ALREADY_EXISTS(552)`
  这类是**用户输入/并发导致的预期结果**，属于业务流程的正常分支，
  对它们记 ERROR 并打印完整 `response` 会造成：
  1. 每个真实的用户误操作都在 CN 日志留下 ERROR（本例仅 1 个 region，20D 多 region 会成倍）；
  2. 监控/告警按 ERROR 计数会持续误报；
  3. 排查真实故障时被噪声淹没（本特性 41 条回归用例中，仅因这条日志被判 FAIL 的就有 1 条）。

### 附带的第二层噪声

同一场景在 `CreateTableProcedure` 侧还有一条回滚日志（INFO，但带完整异常）：

```
INFO CreateTableProcedure:288 - Rollback CreateTable-CHECK_TABLE_EXISTENCE costs 0ms.
INFO ProcedureExecutor:774  - Rolled back pid=15, state=ROLLEDBACK,
     exception=ProcedureException: IoTDBException: Multiple types encountered ...
```

## 6. 影响与定级

| 维度 | 影响 |
|---|---|
| 功能 | 无（视图未创建、procedure 已回滚、错误码明确） |
| 可观测性 | CN 日志被用户误操作刷 ERROR；告警误报；回归用例被误判 |
| 定级建议 | **P3**（日志级别/可观测性） |

## 7. 修复建议

1. 在 `TreeDeviceViewFieldDetectionHandler.onComplete` 里按错误码分流：
   `DATA_TYPE_MISMATCH / MULTIPLE_ERROR / COLUMN_ALREADY_EXISTS / COLUMN_CATEGORY_MISMATCH`
   → **WARN（不带完整 response，只带 code + message + 目标 DN）**；其余 → 保持 ERROR；
2. `ProcedureExecutor` 对"预期业务失败"的回滚不打印异常堆栈；
3. 与 **TV-D1**（扩列重复请求打 ERROR）、**TV-D2**（类型冲突静默成功）一起，
   为树转表路径定义一张"可忽略/可降级错误码表"，统一处理。

## 8. 复现方式

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp TV-REPRO-D3
# 用例 FAIL 即缺陷复现（断言的是"预期失败不应记 ERROR"）
```

## 9. 证据索引（172.20.70.122）

| 内容 | 路径 |
|---|---|
| 用例结果 | `TREEVIEW/results/rp_TV-REPRO-D3/cases/TV-REPRO-D3/result.json` |
| SQL + 返回 + CN 命中行 | `.../evidence/repro_d3_createview_error.txt` |
| 命中上下文（含 response 全文） | `.../evidence/repro_d3_createview_context.txt` |
| CN/DN 日志归档 | `.../evidence/logs/{cn,dn}_<host>.tar.gz` |
