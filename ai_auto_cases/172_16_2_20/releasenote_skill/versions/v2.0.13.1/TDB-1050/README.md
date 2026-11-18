# TDB-1050 RC3 验证：创建可写视图（cascade=true）提交阶段与源表 fetch 竞争导致 NPE

## 一、结论

**RC3（2.0.13.1 / build `ac7f95e`）已修复**，黑盒与插桩两种方式均验证通过。

| 项 | 结果 |
| --- | --- |
| 版本 | `2.0.13.1` / `ac7f95e`（与源码 HEAD `ac7f95e953` 一致） |
| 环境 | 3C5D 全量重装 RC3（3 CN + 5 DN，SR3/DR2，IoTConsensusV2） |
| 代码 | `DataNodeTableCache.commitUpdateTable(db1,db2,t1,t2)` 增加 `Objects.nonNull(table1)` / `Objects.nonNull(table2)` 判空 |
| 黑盒 | 10 轮「建库/建表/写入 → 并发 SELECT → 建可写视图 → 改视图名」10/10 成功，5 台 DN **0** 条 `Internal error processing updateTable` |
| 插桩 | 模拟 fetch 在 commit 前消费源表条目：日志出现 `[DDLHA-PROOF-RC3] consumed specialStatus entry`，**无 NPE**，视图创建成功 |
| 验证后处理 | 恢复原 jar、删除测试开关、重启 DN，集群 8/8 |

## 二、缺陷回顾（RC2 及之前）

`CREATE WRITABLE VIEW`（`schema_cascade=true` 默认）会成对提交「视图 + 源表」。若在 pre-update 与 commit 之间，源表的 specialStatus 条目被 `updateTableByFetch` 消费（`:940 existingPair.setLeft(null)`），commit 侧 `table2` 为 null，而旧代码未判空，`innerCommitUpdateTable` 把 null 写入 `ConcurrentHashMap`，抛 NPE。

## 三、RC3 代码确认

`iotdb-core/datanode/.../DataNodeTableCache.java`（RC3 `ac7f95e`）：

```java
// consider that, writable view (with cascade = true) is changed,
// between the preUpdate and commitUpdate, another select thread trigger that fetching the
// base table and writable view,
// the base table coule be fetched successfully but writable view do not;
// so the base table can be null but the writable view is not null;

if (Objects.nonNull(table1)) {
  innerCommitUpdateTable(unqualifiedDatabase1, tableName1, table1, null);
}

// if the writable view is null, the base table should not be null, the idempotency keeps the
// follower commitUpdate correct;
if (Objects.nonNull(table2)) {
  innerCommitUpdateTable(unqualifiedDatabase2, tableName2, table2, null);
}
```

即：消费后为空的表被**跳过**，不再以 null 写缓存。

## 四、黑盒验证

```sql
SET SQL_DIALECT=TABLE;
CREATE DATABASE t1050_<i>;
CREATE TABLE t1050_<i>.t (dev STRING TAG, v INT32 FIELD);
INSERT INTO t1050_<i>.t(time,dev,v) VALUES (1799500000000,'d1',<i>);
-- 并发 SELECT count(*) FROM t1050_<i>.t
CREATE WRITABLE VIEW t1050_<i>.v AS SELECT v AS v FROM t1050_<i>.t;   -- cascade 默认 true
ALTER VIEW t1050_<i>.v RENAME TO v2;
```

10 轮全部成功；`grep -c 'Internal error processing updateTable'` 在 5 台 DN 上均为 0。

## 五、确定性验证（插桩）

在 RC3 的 `commitUpdateTable` 中注入测试开关：当 `-Diotdb.test.consumeTable2BeforeCommit=<表名>` 命中时，模拟 fetch 路径把源表的 specialStatus 条目 `setLeft(null)`（即缺陷触发条件）。

补丁见 [`patch/DataNodeTableCache-proof.patch`](patch/DataNodeTableCache-proof.patch)。

执行建视图后 DN19 日志：

```
2026-11-18 09:47:52,125 [pool-58-IoTDB-DataNodeInternalRPC-Processor-1] INFO
  o.a.i.d.s.t.DataNodeTableCache:455 - [DDLHA-PROOF-RC3] consumed specialStatus entry for t1050p.t
```

- hook 命中（条目被消费）；
- 无 `Internal error processing updateTable`、无 `NullPointerException`；
- `SHOW TABLES` 显示表与视图均创建成功。

测试后：`cp .orig` 还原 jar、删除 `datanode-env.sh` 中的开关、重启 DN19、确认 8/8。

## 六、证据

| 内容 | 位置 |
| --- | --- |
| 版本 | [`evidence/version.txt`](evidence/version.txt) |
| 插桩日志 | [`evidence/proof-log.txt`](evidence/proof-log.txt) |
| 代码补丁 | [`patch/DataNodeTableCache-proof.patch`](patch/DataNodeTableCache-proof.patch) |
| PLM | TDB-1050（已回填 RC3 验证结果） |
