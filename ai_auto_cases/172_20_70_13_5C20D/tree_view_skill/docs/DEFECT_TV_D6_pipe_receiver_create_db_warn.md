# 缺陷报告 TV-D6：Pipe 接收端应用 schema 快照时，`create database` 的**幂等重复**被记为 WARN（`ClusterConfigTaskExecutor:523`，code 501）

- 版本：`master_1026_dc11a35`（2.0.11-SNAPSHOT，BuildInfo **dc11a35**）
- 环境：**双集群** —— 发送端 172.20.70.100–109、接收端 172.20.70.110–119，
  每套 **5 CN + 10 DN / SchemaRegion 5 副本 / DataRegion 3 副本**，`IoTConsensus`
- 发现用例：`TV-PIPE-04`（`inclusion='all'` 的树模型 pipe 不同步视图）
- **修复状态**：上游 PR <https://github.com/apache/iotdb/pull/19054> 已按本报告 §5.1 的定位补齐
  `setEnablePrintExceptionLog(false)`（open，未合并）；**不再单独提 PLM**，以 `TV-PIPE-04` 作为回归验证点
- 发现方式：pipe 组启用**双集群日志扫描**后，接收端 DN 日志命中
- 定级建议：**P3（日志级别/幂等表达）**

## 1. 现象

接收端 DataNode 日志（172.20.70.110）：

```
2026-10-29 07:05:18,178 [Pipe-Receiver-75-172.20.70.103:38222$20261028_230518_00084_9]
  WARN o.a.i.d.q.p.e.c.e.ClusterConfigTaskExecutor:523
  - Failed to execute create database root.pipe_p04 in config node,
    status is TSStatus(code:501, message:root.pipe_p04 has already been created as database).
```

- `501 = DATABASE_ALREADY_EXISTS`；
- 线程名 `Pipe-Receiver-*` ⇒ 来自 **pipe 接收端**应用发送端 schema 快照的过程；
- 同一事件重复到达（发送端 3 副本 / 重复快照）时，接收端每来一次就打一条 WARN。

用例判定：`TV-PIPE-04` 的功能断言 **ok**（`inclusion='all'` 确实没有把视图同步过去，符合需求），
仅"收尾③ CN/DN 日志无 ERROR/WARN 异常"因**接收端**这条 WARN 判 FAIL。

## 2. 最小复现

```sql
-- 发送端（172.20.70.100，tree 方言）
create database root.pipe_p04;
create timeseries root.pipe_p04.d1.s1 INT32;
insert into root.pipe_p04.d1(time,s1) values(1,10);
create pipe p_all_p04 with source ('inclusion'='all')
  with sink ('node-urls'='172.20.70.110:6667');

-- 接收端（172.20.70.110）：
--   等 30~60s 后看 logs/log_datanode_all.log
--   grep "Failed to execute create database" logs/log_datanode_all.log
```

自动化：

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW
bash treeview_5c20d/run_pipe_case.sh conf/cluster.pipe_sender.conf pipe TV-PIPE-04
```

## 3. 源码取证与根因

### 3.1 接收端建库入口（问题点）

`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/pipe/receiver/protocol/thrift/IoTDBDataNodeReceiver.java:1123-1140`

```java
private TSStatus createSchemaSnapshotDatabaseIfNecessary(final PartialPath databasePath) {
  final DatabaseSchemaStatement statement =
      new DatabaseSchemaStatement(DatabaseSchemaStatement.DatabaseSchemaStatementType.CREATE);
  statement.setDatabasePath(databasePath);
  // ← 这里**没有** statement.setEnablePrintExceptionLog(false);

  final TSStatus status = executeStatementAndClassifyExceptions(statement);
  if (status.getCode() == TSStatusCode.SUCCESS_STATUS.getStatusCode()) {
    return status;
  }
  if (status.getCode() == TSStatusCode.DATABASE_ALREADY_EXISTS.getStatusCode()) {
    return Objects.equals(status.getMessage(),
            databasePath.getFullPath() + " has already been created as database")
        ? RpcUtils.getStatus(TSStatusCode.SUCCESS_STATUS)          // ← 语义上就是幂等成功
        : new TSStatus(...PIPE_RECEIVER_USER_CONFLICT_EXCEPTION...);
  }
  ...
}
```

### 3.2 日志产生处

`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/queryengine/plan/execution/config/executor/ClusterConfigTaskExecutor.java:516-533`

```java
if (TSStatusCode.SUCCESS_STATUS.getStatusCode() != tsStatus.getCode()) {
  // If database already exists when loading, we do not throw exceptions to avoid printing too many logs
  if (TSStatusCode.DATABASE_ALREADY_EXISTS.getStatusCode() == tsStatus.getCode()
      && !databaseSchemaStatement.getEnablePrintExceptionLog()) {
    future.set(new ConfigTaskResult(TSStatusCode.SUCCESS_STATUS));      // 幂等：静默
  } else {
    LOGGER.warn(DataNodeQueryMessages
        .FAILED_TO_EXECUTE_CREATE_DATABASE_ARG_IN_CONFIG_NODE_STATUS_IS_ARG, ...);  // ← 我们的 WARN
    future.setException(new IoTDBException(tsStatus));
  }
}
```

### 3.3 对比：同一文件的另一条建库路径**已经**关掉了这个开关

`IoTDBDataNodeReceiver.java:1881-1890`（pipe 接收端另一处建库）

```java
final DatabaseSchemaStatement statement =
    new DatabaseSchemaStatement(DatabaseSchemaStatement.DatabaseSchemaStatementType.CREATE);
statement.setDatabasePath(new PartialPath(database));
statement.setEnablePrintExceptionLog(false);      // ← 这里关了，所以那条路径不报 WARN
```

### 3.4 根因

1. `createSchemaSnapshotDatabaseIfNecessary` 构造建库语句时**漏了** `setEnablePrintExceptionLog(false)`；
2. 于是"库已存在"这一**预期内的幂等情形**在 `ClusterConfigTaskExecutor` 里走了 else 分支 → WARN + 抛异常；
3. 而调用方（3.1 第 1132-1138 行）**随后又把 501 显式转成 SUCCESS**，
   说明代码本身就认为这是幂等成功——**语义与日志级别不一致**；
4. 发送端 schema 快照可能被重复投递（多副本/重试），所以每重复一次就多一条 WARN。

## 4. 影响

| 维度 | 影响 |
|---|---|
| 功能 | 无（建库最终成功，接收端数据正常） |
| 日志 | 每次重复投递产生一条 WARN；pipe 长期运行/频繁建库时持续刷 |
| 告警 | WARN 计入告警即误报；排查真实同步问题时被噪声干扰 |
| 一致性 | 同一份代码里两条建库路径行为不一致（一条静默、一条 WARN），后续维护易踩坑 |
| 定级建议 | **P3** |

## 5. 修复建议

1. `createSchemaSnapshotDatabaseIfNecessary` 里补 `statement.setEnablePrintExceptionLog(false);`
   （与 1886 行保持一致），让 501 走"静默幂等成功"分支；
2. 若希望保留可观测性，改为 `LOGGER.debug/info` 并仅在**非幂等冲突**（`DATABASE_CONFLICT`）时 WARN；
3. 建议把"建库语句构造"抽成一个工厂方法，统一设置 `enablePrintExceptionLog`，
   避免同类路径再次不一致。

## 6. 证据索引（172.20.70.122）

| 内容 | 路径 |
|---|---|
| 用例结果 | `TREEVIEW/treeview_5c20d/results/pipe2_TV-PIPE-04/cases/TV-PIPE-04/result.json` |
| 命中行（接收端） | `.../evidence/log_findings.txt`（key 带 `R:` 前缀） |
| 双端日志归档 | `.../evidence/logs/{cn,dn}_<host>.tar.gz`（发送端 + 接收端，共 30 个节点） |

> 备注：这是**双集群 pipe 场景**才暴露的问题（单集群回归扫不到接收端日志）。
> 建议在 pipe 相关的 CI 里保留"接收端日志扫描"，否则这类 WARN 会一直漏掉。
