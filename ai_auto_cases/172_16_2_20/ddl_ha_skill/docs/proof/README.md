# TDB-1050 确定性复现证明（插桩构建）

> **触发点修正（2026-11-13）**：NPE 发生在**创建可写视图（schema_cascade=true）的提交阶段**，不是改名。改名由 `RenameWritableViewProcedure` 处理，其 `getSourceResolutionOverride()` 返回 false，不会设置 originalInfo，因此走 3 参 `commitUpdateTableWithView`，不经过本文讨论的 4 参路径。

> 目的：证明 `updateTable` NPE 的机制是"**commit 之前 source table 的 specialStatus 条目被 fetch 路径消费**"，而不是"改视图名必现"。
> 结论：**100% 稳定复现**，栈与生产一致。

## 一、机制（源码定位，RC2 `83183d0`）

| 位置 | 代码 | 作用 |
| --- | --- | --- |
| `DataNodeTableCache:232-247` | `innerPreUpdateTable` | 把视图 `v` 与源表 `t` 放进 `specialStatusMap` |
| `DataNodeTableCache:940` | `existingPair.setLeft(null)` | fetch 路径（`updateTableByFetch`）**消费**该条目 |
| `DataNodeTableCache:456` | `table2 = getTableFromSpecialStatusMap(...)` | commit 时再取，已被消费则为 **null** |
| `DataNodeTableCache:472` | `if (Objects.isNull(table1)) return false;` | **只判了 table1**，没判 table2 |
| `DataNodeTableCache:483` | `innerCommitUpdateTable(db2, t2, table2, null)` | 把 null 传下去 |
| `DataNodeTableCache:497` | `ConcurrentHashMap.put(tableName, newTable)` | null 值 → NPE |

生产现场（2026-11-10 18:36:22，`DDLHA-N-005/logs/dn19.log`）已经走到过这条路径：

```
22,321 Pre-update table ...v successfully
22,322 Pre-update table ...t successfully
22,485 Update table ...t by table fetch        ← 消费
22,556 Commit-update table ...v successfully.
22,557 ERROR Internal error processing updateTable → NPE
```

## 二、插桩（只加测试开关，不改产品逻辑）

`commitUpdateTable(database1, database2, tableName1, tableName2)` 取写锁之前插入：

```java
final String proveConsume = System.getProperty("iotdb.test.consumeTable2BeforeCommit");
if (proveConsume != null && proveConsume.equals(tableName2)) {
  // 模拟 :940 existingPair.setLeft(null)
  ... specialStatusMap.get(db2).get(tableName2).setLeft(null); ...
}
```

完整改动见 [`DataNodeTableCache-proof.patch`](DataNodeTableCache-proof.patch)。

## 三、执行步骤

1. `javac` 单类编译（classpath 用 RC2 client 的 `lib/*`）；
2. 仅替换 172.16.2.19 上 `lib/timechodb-server-2.0.13.1.jar` 内的 `DataNodeTableCache.class`（原 jar 备份 `.orig`）；
3. dn19 的 `conf/datanode-env.sh` 追加 `-Diotdb.test.consumeTable2BeforeCommit=t`，重启 dn19，集群 8/8；
4. 执行：建库 `proof_npe` → 建表 `proof_npe.t` → 插入 1 行 → 建视图 `proof_npe.v` → `ALTER VIEW proof_npe.v RENAME TO v2`。

## 四、结果（100% 复现）

```
2026-11-13 17:19:15,093 INFO  DataNodeTableCache:478 - [DDLHA-PROOF] consumed specialStatus entry for proof_npe.t
2026-11-13 17:19:15,093 ERROR ProcessFunction:49 - Internal error processing updateTable
java.lang.NullPointerException
    at java.base/java.util.concurrent.ConcurrentHashMap.putVal(ConcurrentHashMap.java:1011)
    at java.base/java.util.concurrent.ConcurrentHashMap.put(ConcurrentHashMap.java:1006)
    at org.apache.iotdb.db.schemaengine.table.DataNodeTableCache.innerCommitUpdateTable(DataNodeTableCache.java:529)
    at org.apache.iotdb.db.schemaengine.table.DataNodeTableCache.commitUpdateTable(DataNodeTableCache.java:515)
    at org.apache.iotdb.db.protocol.thrift.impl.DataNodeInternalRPCServiceImpl.updateTable(DataNodeInternalRPCServiceImpl.java:3076)
```

> 行号 515/529 是插桩后的偏移；生产构建对应 483/497，方法与调用链完全一致。

## 五、复现之后的清理

1. `cp .orig` 覆盖回 jar；
2. 删除 `datanode-env.sh` 里的测试开关；
3. 重启 dn19，集群恢复 8/8；
4. 回归任务继续（V2 从断点续跑）。

## 六、给研发的建议

1. **修复**：`innerCommitUpdateTable` 对 `newTable == null` 显式跳过（打日志即可），或 `:472` 同时判断 `table2` 是否已被消费；
2. **单测**：可复用本插桩思路——先消费 `specialStatusMap` 条目，再调用 `commitUpdateTable`，断言不抛 NPE；
3. **优先级**：P2 或 P3 由研发定；功能结果不受影响（CN 重试后改名成功），但每次触发都会失败一次 RPC。

## 七、补充：为什么会走到 4 参 commitUpdateTable（回应研发疑问）

1. **入口与 cascade 无关**：`DataNodeInternalRPCServiceImpl` 的 `COMMIT_UPDATE_TABLE` 分支（:3060-3076）按 `req.isSetOriginalInfo()` 分流，带 `originalInfo`（改名形态）→ 4 参 `commitUpdateTable(...)`；不带 → `commitUpdateTableWithView(...)`。`DataNodeTableCache` 里该方法上的注释 "only for the writable view procedure and schema cascade" **已过时**。
2. **cascade 默认 true**：RC2 实测，创建可写视图不写 `WITH` 时 `SHOW CREATE TABLE` 返回 `WITH (ttl='INF', schema_cascade=true)`；显式写 `WITH (schema_cascade=false)` 才为 false。
3. **源表因此被一起提交**：`isSchemaCascade()==true` 时 `CreateWritableViewProcedure`（:196/:207）调用 `initOriginalTableForCascade(source)`，把源表纳入同一批 pre-update / commit，于是 commit 里 `tableName2 = t`（源表），NPE 落在这一路。
4. **若视图为 `schema_cascade=false`**，源表不会进 commit，就绕开该路径——这可能是"不复现"的原因之一。复现前请先 `SHOW CREATE TABLE <视图>` 确认。

复现用的完整 SQL（与用例 `DDLHA-N-005` 一致，创建视图未写 WITH）：

```sql
SET SQL_DIALECT=TABLE;
CREATE DATABASE proof_npe;
CREATE TABLE proof_npe.t (region STRING TAG, dev STRING TAG, s1 INT64 FIELD);
INSERT INTO proof_npe.t(time,region,dev,s1) VALUES (1,'r1','dev01',10);
INSERT INTO proof_npe.t(time,region,dev,s1) VALUES (2,'r1','dev01',20);
INSERT INTO proof_npe.t(time,region,dev,s1) VALUES (3,'r1','dev02',30);
INSERT INTO proof_npe.t(time,region,dev,s1) VALUES (4,'r1','dev03',40);
CREATE WRITABLE VIEW proof_npe.v AS SELECT s1 AS temp FROM proof_npe.t;
SHOW CREATE TABLE proof_npe.v;   -- WITH (ttl='INF', schema_cascade=true)
ALTER VIEW proof_npe.v RENAME TO v2;
```
