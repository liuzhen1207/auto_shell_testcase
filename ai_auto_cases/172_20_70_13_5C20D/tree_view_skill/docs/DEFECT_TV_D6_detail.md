# 【缺陷报告】TV-D6：Pipe 接收端应用 schema 快照时，`create database` 的**幂等重复**被记为 WARN（501）

> 状态：**已定位根因、稳定复现**（尚未提交 PLM）
> 版本：`master_1026_dc11a35`（2.0.11-SNAPSHOT，BuildInfo **`dc11a35`**，TimechoDB）
> 建议定级：**P3（日志级别 / 幂等表达）**

---

## 一、问题概述（一句话）

Pipe **接收端**在应用发送端的 schema 快照前，会先"必要时建库"；当这个库**已经存在**时，
代码在 `IoTDBDataNodeReceiver.createSchemaSnapshotDatabaseIfNecessary()` 里构造的建库语句
**漏掉了 `setEnablePrintExceptionLog(false)`**，导致本应被**幂等忽略**的 `501 DATABASE_ALREADY_EXISTS`
仍然走到 `ClusterConfigTaskExecutor` 的 else 分支，打一条 **WARN**（还带异常对象）。

而调用方随后又把 501 **显式转成 SUCCESS** —— 说明语义上就是幂等成功，**只有日志级别错了**。
同一文件的另一条建库路径（`:1886`）**已经**关掉了这个开关，两条路径行为不一致。

---

## 二、环境

| 项 | 值 |
|---|---|
| 版本 | master 源码构建 `2.0.11-SNAPSHOT`，BuildInfo `dc11a35`（TimechoDB） |
| 拓扑 | **双集群（pipe 收发）**，各 **5 ConfigNode + 10 DataNode** |
| 发送端 | 172.20.70.100–109（`conf/cluster.pipe_sender.conf`） |
| 接收端 | 172.20.70.110–119（`conf/cluster.pipe_receiver.conf`） |
| 副本 | **SchemaRegion 5 副本 / DataRegion 3 副本** |
| 数据面 | `IoTConsensus` |
| 部署目录 | `/data/iotdb/master_1026_dc11a35` |
| 相关需求 | doc 90 / doc 913 / TDB-343（树转表视图自动识别新增测点） |

---

## 三、复现步骤

### 3.1 手工复现（两套集群都要在跑）

```sql
-- ① 发送端（172.20.70.100，tree 方言）：造一个树库 + 数据
create database root.pipe_p04;
create timeseries root.pipe_p04.d1.s1 INT32;
insert into root.pipe_p04.d1(time,s1) values(1, 10);

-- ② 发送端（172.20.70.100，tree 方言）：建 pipe，sink 指向接收端
create pipe p_all_p04 with source ('inclusion'='all')
  with sink ('node-urls'='172.20.70.110:6667');
```

```bash
# ③ 接收端（172.20.70.110）：等 30~60s 后看 DN 日志
ssh root@172.20.70.110 \
  'grep -a "Failed to execute create database" /data/iotdb/master_1026_dc11a35/logs/log_datanode_all.log | tail'
```

### 3.2 自动化复现

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW
bash treeview_5c20d/run_pipe_case.sh conf/cluster.pipe_sender.conf pipe TV-PIPE-04
# 用例判定 FAIL（仅"收尾③ CN/DN 日志无 ERROR/WARN"这一项），功能断言通过
```

---

## 四、实际结果

### 4.1 日志（问题点）

接收端 DataNode（172.20.70.110）：

```
2026-10-29 07:05:18,178 [Pipe-Receiver-75-172.20.70.103:38222$20261028_230518_00084_9]
  WARN o.a.i.d.q.p.e.c.e.ClusterConfigTaskExecutor:523
  - Failed to execute create database root.pipe_p04 in config node,
    status is TSStatus(code:501, message:root.pipe_p04 has already been created as database).
```

- `501 = DATABASE_ALREADY_EXISTS`；
- 线程名 `Pipe-Receiver-*` ⇒ 明确来自 **pipe 接收端**应用发送端 schema 快照的过程；
- 同一份快照/重复投递每来一次就打一条（本次用例内命中 2 条）。

### 4.2 功能面（正常，不是数据问题）

- 接收端建库最终成功、视图/数据可查；
- pipe 状态 `RUNNING`、无 `ExceptionMessage`；
- 用例 `TV-PIPE-04` 的功能断言（`inclusion='all'` 不同步视图）**通过**；
- 唯一失败项是"收尾③ 日志无 ERROR/WARN"。

> 结论：**功能正确，纯日志问题**。

---

## 五、源码定位

### 5.1 出问题的建库路径（漏了开关）

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
        ? RpcUtils.getStatus(TSStatusCode.SUCCESS_STATUS)      // ← 语义上就是幂等成功
        : new TSStatus(TSStatusCode.PIPE_RECEIVER_USER_CONFLICT_EXCEPTION.getStatusCode())
            .setMessage(status.getMessage());
  }
  ...
}
```

### 5.2 日志产生处（通用建库实现）

`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/queryengine/plan/execution/config/executor/ClusterConfigTaskExecutor.java:516-531`

```java
if (TSStatusCode.SUCCESS_STATUS.getStatusCode() != tsStatus.getCode()) {
  // If database already exists when loading, we do not throw exceptions to avoid printing too many logs
  if (TSStatusCode.DATABASE_ALREADY_EXISTS.getStatusCode() == tsStatus.getCode()
      && !databaseSchemaStatement.getEnablePrintExceptionLog()) {
    future.set(new ConfigTaskResult(TSStatusCode.SUCCESS_STATUS));     // 幂等：静默
  } else {
    LOGGER.warn(                                                       // ← 我们的 WARN（:523）
        DataNodeQueryMessages
            .FAILED_TO_EXECUTE_CREATE_DATABASE_ARG_IN_CONFIG_NODE_STATUS_IS_ARG,
        databaseSchemaStatement.getDatabasePath(), tsStatus);
    future.setException(new IoTDBException(tsStatus));
  }
}
```

### 5.3 对比：同一文件的另一条建库路径**已经**关掉了开关

`IoTDBDataNodeReceiver.java:1881-1890`

```java
final DatabaseSchemaStatement statement =
    new DatabaseSchemaStatement(DatabaseSchemaStatement.DatabaseSchemaStatementType.CREATE);
statement.setDatabasePath(new PartialPath(database));
statement.setEnablePrintExceptionLog(false);      // ← :1886 关了，所以那条路径不报 WARN
final DatabaseSchemaTask task = new DatabaseSchemaTask(statement);
...
if (statusCode == SUCCESS || statusCode == DATABASE_ALREADY_EXISTS) {   // 也是幂等
  autoCreatedTreeDatabases.add(database);
  return TreeDatabaseCreationResult.CREATED_OR_EXISTED;
}
```

---

## 六、根因

1. `createSchemaSnapshotDatabaseIfNecessary()` 构造建库语句时**漏了** `setEnablePrintExceptionLog(false)`；
2. 于是"库已存在"这一**预期内的幂等情形**在 `ClusterConfigTaskExecutor` 里走了 else 分支 → `LOGGER.warn(...)` + 抛异常；
3. 而调用方（5.1 的 1132-1138 行）**随后又把 501 显式转成 SUCCESS**，
   说明代码本身就认为这是幂等成功 —— **语义与日志级别不一致**；
4. 发送端 schema 快照可能被重复投递（多副本 / 重试），每重复一次就多一条 WARN。

> 一句话：**"库已存在"是正常业务分支，不该用 WARN 表达；而且同一个类里两条建库路径的处理方式不一致。**

---

## 七、影响

| 维度 | 影响 |
|---|---|
| 功能 / 数据 | **无影响**：建库最终成功、接收端数据正确 |
| 日志 | 每次重复投递一条 WARN；pipe 长期运行、频繁建库的场景会持续刷 |
| 告警 | WARN 若纳入告警即误报；排查真实同步问题时被噪声干扰 |
| 一致性 | 同一类里两条建库路径行为不一致（一条静默、一条 WARN），后续维护容易踩坑 |
| 覆盖盲区 | 该日志**只在接收端**出现，单集群回归永远扫不到（本次是启用"双集群日志扫描"后才暴露） |

---

## 八、修复建议

1. **首选**：`createSchemaSnapshotDatabaseIfNecessary()` 里补一行
   ```java
   statement.setEnablePrintExceptionLog(false);
   ```
   与 `:1886` 对齐，让 501 走"静默幂等成功"分支；
2. 若希望保留可观测性：改为 `LOGGER.debug/info`，且**只在非幂等冲突**
   （`DATABASE_CONFLICT` / `PIPE_RECEIVER_USER_CONFLICT_EXCEPTION`）时 WARN；
3. **重构建议**：把"pipe 接收端建库语句"抽成工厂方法，统一设置
   `enablePrintExceptionLog`，避免同类路径再次不一致；
4. 可与 **TDB-890**（补列已存在时报 ERROR 552/305）一起纳入
   "树转表/pipe 路径的可忽略错误码表"，统一降级策略。

---

## 九、测试侧信息

| 项 | 内容 |
|---|---|
| 用例 | `TV-PIPE-04`（`inclusion='all'` 的树模型 pipe 不同步视图） |
| 判定 | 功能断言通过；仅"收尾③ CN/DN 日志无 ERROR/WARN"失败 |
| 日志扫描范围 | 发送端 15 + 接收端 15 = **30 个节点**（接收端命中带 `R:` 前缀） |
| 复现命令 | `bash treeview_5c20d/run_pipe_case.sh conf/cluster.pipe_sender.conf pipe TV-PIPE-04` |
| 证据（122） | `TREEVIEW/treeview_5c20d/results/pipe2_TV-PIPE-04/cases/TV-PIPE-04/{result.json,evidence/log_findings.txt,evidence/logs/*.tar.gz}` |
| 报告位置 | `TREEVIEW/reports/DEFECT_TV_D6_pipe_receiver_create_db_warn.md` |

---

## 十、备注：为什么这条容易被漏掉

- 它**只在接收端 DN 日志**出现，发送端、CN、单集群回归都看不到；
- 它**不伴随任何功能异常**（pipe RUNNING、数据可查），只有严格扫日志才能发现；
- 所以本轮的"pipe 组 + 两端日志扫描"是发现它的前提 —— 建议后续 pipe 相关 CI 保留该机制。
