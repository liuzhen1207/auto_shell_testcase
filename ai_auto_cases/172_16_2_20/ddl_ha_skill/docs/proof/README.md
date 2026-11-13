# TDB-1050 确定性复现证明（插桩构建）

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
