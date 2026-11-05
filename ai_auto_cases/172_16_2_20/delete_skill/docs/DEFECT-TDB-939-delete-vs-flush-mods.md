> **PLM 缺陷单：[TDB-939](https://plm.infra.timecho.com/iterations?productId=1&itemId=1562)** ｜ 优先级 P1 ｜ 负责人 江天 ｜ 验证人员 刘珍 ｜ 迭代 V2.0.15.1 ｜ 问题发现版本 V2.0.13.1 ｜ 状态 排期确认
# 缺陷报告：DELETE 与 FLUSH 并发导致删除标记（mods）未落盘，已删数据"复活"且副本不一致

| 项 | 内容 |
|---|---|
| 标题 | DELETE 与 FLUSH 并发时删除标记未写入 mods，已删数据在落盘文件中重新可见，多副本不一致 |
| 严重程度 | **P1**（数据正确性 + 副本一致性；snapshot 截断后可能**永久**丢失删除） |
| 影响版本 | **TimechoDB 2.0.13.1 RC1（`ab6d3de`）**；2.0.12.1 RC10（`c60ce63`）同用例未复现，疑似本版本引入或时序窗口变化 |
| 发现时间 | 2026-11-05 |
| 发现场景 | DELETE 全量回归（IoTConsensus，85 轮）中的 7 个用例 |
| 复现率 | 2/2（`DEL-PRED-007`、`DEL-PRED-008` 各复现两次） |
| 环境 | 3 CN（172.16.2.16/17/18）+ 5 DN（172.16.2.19/21/22/23/24），SchemaRegion 3 副本 / DataRegion 2 副本，IoTConsensus，DN 堆 12 GB |

## 一、现象

删除成功后立即可读到正确结果，**数分钟后同一查询又能读到已删除的行**；重启相关 DataNode 后恢复正确。

以 `DEL-PRED-008` 为例（表模型，`del_rc10_pred008.t`）：

| 时间点 | 查询结果 |
|---|---|
| DELETE 执行后（用例 SQL 内 `SELECT`） | 3 行（正确） |
| 5 分钟后（31 × 10 秒零 lag 门禁全过之后的快照） | **14 行（重新出现已删行）** |
| 五台 DN 逐个 kill/重启后 | 3 行（恢复正确） |

85 轮里 7 轮失败，全部是这一形态（`FAIL_DN_DIFF`）：

| 用例 | 停机前快照 | 重启后 |
|---|---:|---:|
| DEL-PRED-007 | 20 行 | 8 行 |
| DEL-PRED-008 | 26 行 | 14 行 |
| DEL-MEMLEAK-TABLE-001 | 7 行 | 5 行 |
| DEL-MEMLEAK-TABLE-002 | count=4 | count=1 |
| DEL-MEMLEAK-TREE-001/002 | 3 行 | 2 行 |
| DEL-MEMLEAK-TREE-003 | 2 行 | 1 行 |

## 二、直接证据：部分副本根本没有 mods 文件

`DEL-PRED-008` 复现轮（2026-11-05 10:10）现场核对：

| DN | 数据 TsFile 落盘时间 | 删除执行日志 | `.mods2` |
|---|---|---|---:|
| .19 | 10:10:02.656 | 10:10:02.825、10:10:12.876（两次） | ✅ 10:10:12.884 |
| .21 | 10:10:02.660 | 10:10:02.829、10:10:11.803（两次） | ❌ **无** |
| .22 | — | 有 | ✅ 1 个 |
| .23 | — | 有 | ❌ **无** |
| .24 | — | 有 | ❌ **无** |

关键时间差：**数据文件写入 10:10:02.660 → 删除开始执行 10:10:02.829，相差 0.17 秒**。

DN21 的日志明确包含：

```
10:10:02,829 [DataNodeInternalRPC-Processor-3] [Deletion] Executing table deletion RelationalDeleteDataNode-1[...]
10:10:02,830 ... Writing no-file-related deletion to WAL
10:10:11,803 [IoTConsensusRPC-Processor-4]     [Deletion] Executing table deletion RelationalDeleteDataNode-1[...]
```

即：**删除在两台副本上都执行了、也写了 WAL，但 DN21/23/24 的删除标记没有落到磁盘**。

## 三、代码分析

### 3.1 DELETE 本身是共识写

```java
// RegionWriteExecutor.execute(...)
return dataRegionConsensus.write(groupId, planNode);
```

`RelationalDeleteDataNode` / `DeleteDataNode` 与 INSERT 走同一条 IoTConsensus 日志，正常路径下有序、会复制到全部副本。**问题不在复制，而在删除标记的落盘。**

### 3.2 删除与 flush 的竞争窗口

`DataRegion.deleteByTable()`（`iotdb-core/datanode/.../storageengine/dataregion/DataRegion.java`）：

```java
writeLock("delete");
  logDeletionInWAL(node);                    // 删除写 WAL
  deleteDataInUnsealedFiles(...);            // 删 memtable
  ...
writeUnlock();                               // ← 先释放写锁
deleteDataInSealedFiles(sealedTsFiles, ...); // ← 再给已落盘文件写 mods
deleteDataInRemoteFiles(deletion);
```

写 mods 在**释放写锁之后**，flush/compaction 可以在这个窗口内操作同一批 TsFile。

### 3.3 命中"正在 flush 的文件"时，删除只记在内存

`DataRegion.deleteDataInSealedFiles(...)`：

```java
for (TsFileResource tsFileResource : deletedByMods) {
  if (tsFileResource.isClosed()
      || !tsFileResource.getProcessor().deleteDataInMemory(deletion)) {
    involvedModificationFiles.add(tsFileResource.getModFileForWrite());   // 写 mods
  } // else do nothing     ← 未关闭 + 内存删除成功 → 什么都不写
}

if (involvedModificationFiles.isEmpty()) {
  logger.info(DELETION_DOES_NOT_INVOLVE_ANY_FILE, deletion);
  return;                  // ← 直接返回，磁盘上不产生任何 mods
}
```

`TsFileProcessor.deleteDataInMemory(...)`：

```java
if (workMemTable != null) { workMemTable.delete(deletion, ...); deleted = true; }

if (!flushingMemTables.isEmpty()) {                       // ← 文件正在 flush
  modsToMemtable.add(new Pair<>(deletion, flushingMemTables.getLast()));
  deleted = true;                                          // ← 返回 true，调用方就不写 mods
}
return deleted;
```

而 `modsToMemtable` 的唯一消费点在 flush 收尾的 `syncReleaseFlushedMemTable`：

```java
synchronized (flushingMemTables) {
  flushQueryLock.writeLock().lock();
  Iterator<Pair<ModEntry, IMemTable>> iterator = modsToMemtable.iterator();
  while (iterator.hasNext()) {
    Pair<ModEntry, IMemTable> entry = iterator.next();
    if (entry.right.equals(memTableToFlush)) {
      tsFileResource.getModFileForWrite().write(entry.left);   // 只有这条路径会补写 mods
      tsFileResource.getModFileForWrite().close();
      iterator.remove();
    }
  }
}
```

**缺陷**：`deleteDataInMemory` 判定"该 memtable 正在 flush"并向 `modsToMemtable` 追加，但 flush 收尾可能**已经走过**这个 drain 点。此时：

- 删除被判为"已在内存中处理"（返回 true）→ 调用方不写 mods；
- flush 收尾已经执行完 → 没有第二次 drain；
- 结果：`modsToMemtable` 里的条目**被永久遗弃**，磁盘上没有对应 mods。

0.17 秒的时间差（文件写完 → 删除执行）正好落在这个窗口里。DN19/DN22 之所以有 mods，是因为随后的第二次删除（10:10:11/12，共识日志重放）执行时文件已关闭，走了正常写 mods 分支；DN21/23/24 的第二次删除仍被判为"未关闭"或内存删除成功，于是再次跳过。

### 3.4 为什么重启能"修好"，但这个修复不可依赖

- 删除同时写了 WAL（`logDeleteDataNodeInWAL`），也进了 IoTConsensus 日志；
- 重启时重放删除 → 重新写 mods → 查询恢复 3 行（我们观察到的现象）。

**但两条恢复路径都会被清理**：

| 路径 | 清理时机 | 代码/配置 |
|---|---|---|
| WAL | flush 完成后周期性删除，默认 **20 秒**一次 | `delete_wal_files_period_in_ms = 20 * 1000L`（`IoTDBConfig.java:257`） |
| IoTConsensus 日志 | 快照后截断 | `IoTConsensusServerImpl.takeSnapshot()` + 日志截断 |

也就是说：**删除在 WAL/共识日志里只活很短一段时间；一旦快照/清理越过这条删除，而 mods 又从未落盘，删除就永久丢失**，副本会长期带着"已删但可见"的数据，且各副本不一致（本次 2/5 有 mods、3/5 没有）。

## 四、影响面

1. **数据正确性**：删除成功后已删数据重新可读，且不依赖客户端、不依赖换会话。
2. **副本一致性**：不同副本的 mods 状态不同，同一查询在不同 DN 上结果不同（本次 7 个 `FAIL_DN_DIFF` 即由此暴露）。
3. **持久性**：snapshot 截断后不可恢复——从"临时不一致"升级为"永久脏数据"。
4. **可观测性缺口**：`syncLag = searchIndex - minSyncIndex` 只度量日志索引差，**不覆盖 mods 是否落盘**，所以监控与门禁全绿也发现不了。

## 五、复现步骤

环境：3C5D，IoTConsensus，DN 堆 12 GB，`schema_replication_factor=3`、`data_replication_factor=2`。

```sql
SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_pred008;
CREATE TABLE del_rc10_pred008.t (device_id STRING TAG, sensor STRING TAG, region STRING ATTRIBUTE, v INT32 FIELD);
-- 插入 13 行夹具（3 设备 × 3~5 时间点）
FLUSH;
DELETE FROM del_rc10_pred008.t
  WHERE ((region='r1' AND device_id='d1') OR (region='r2' AND device_id='d2'));
SELECT time,device_id,sensor,region,v FROM del_rc10_pred008.t ORDER BY time,device_id,sensor;  -- 期望 7 行
FLUSH;   -- ← 关键：删除后紧跟 FLUSH，制造"删除 vs 正在写文件"的窗口
SELECT time,device_id,sensor,region,v FROM del_rc10_pred008.t ORDER BY time,device_id,sensor;
```

复现要点：**DELETE 之后紧跟 FLUSH，且 DELETE 要落在 FLUSH 写文件的同一秒内**。随后等待数分钟再查（或直接检查各 DN 的 `*.tsfile.mods2` 是否存在），即可看到已删行重新出现。

自动化复现：`bash /data2/iotdb/rc10_matrix/scripts/run_round.sh IoTConsensus DEL-PRED-008`（约 40 分钟/轮，本轮 2/2 复现）。

## 六、证据位置

测试机 `172.16.2.20`：

| 路径 | 内容 |
|---|---|
| `/data2/iotdb/rc10_matrix/artifacts/IoTConsensus/DEL-PRED-008/` | 本轮 SQL、输出、lag 采样、五台 DN 门禁、diff |
| `.../DEL-PRED-008/logs/dn*-datanode.log` | 六台节点本轮日志（含删除执行、compaction 事件） |
| `/data2/iotdb/rc10_matrix/artifacts/IoTConsensus/DEL-PRED-007/` | 第一次复现的证据 |
| `/data2/iotdb/rc10_matrix/results/results.tsv` | 85 轮逐轮结论（7 个 FAIL_DN_DIFF） |
| `/data2/iotdb/rc10_matrix/report/RC10-DELETE-REPORT.md` | 全量报告（56h26m） |

现场文件核对（复现轮 DN19）：`1793844601558-1-0-0.tsfile` 10:10:02.656 落盘，`1793844601558-1-0-0.tsfile.mods2` 10:10:12.884 才出现；DN21 同批文件无 `.mods2`。

## 七、修复建议

1. **消除"遗弃条目"**：`deleteDataInMemory` 返回 true 前，必须确保 `modsToMemtable` 条目要么被 flush 收尾消费、要么由调用方补写 mods。可在 `syncReleaseFlushedMemTable` 的 drain 之后加一次"孤儿检查"，或在 `deleteDataInSealedFiles` 里对 `!isClosed()` 的文件**同时**写 mods（不依赖内存标记）。
2. **关闭窗口**：把 `deleteDataInSealedFiles` 移入 `writeLock` 内，或对目标 TsFile 加"删除进行中"标记，阻止 flush/compaction 在该窗口内重写同一文件。
3. **可观测性**：`syncLag` 之外增加"删除标记落盘一致性"校验（例如删除返回前确认目标文件 mods 已 close）。
4. **回归**：把"DELETE 后立即 FLUSH"作为专项用例（本次 7 个失败用例已覆盖），并在 RC 回归中固定执行。
