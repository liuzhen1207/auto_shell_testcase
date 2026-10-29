# 缺陷报告：OBJECT 文件无法硬链接时 region 迁移整体失败，错误信息无法定位

| 项目 | 内容 |
|---|---|
| 产品/版本 | TimechoDB 2.0.12.1（RC11 发布包） |
| BuildInfo | `ea4f835`（2026-10-23 构建，`timechodb-2.0.12.1-bin.zip`） |
| 集群形态 | 3 ConfigNode + 5 DataNode，SR=3 / DR=2，IoTConsensus，双数据目录（`/data/mpp_test/.../data/datanode/data` + `/mpp_ssd/.../dn_data`），ext4 |
| 严重级别 | 高：阻断 `MIGRATE REGION` / `REMOVE DATANODE`，且失败原因只能在 DataNode 日志里找 |
| 发现时间 | 2026-10-29 10:39（复现），首次观察 2026-10-29 10:08 |
| 复现概率 | 100%（同一 region + 同一注入稳定复现；解除注入后同一迁移 21 s 成功） |
| 说明 | 迁移与缩容是**异步任务**，客户端返回“执行成功”是设计语义，本缺陷不要求回传客户端；判定点是“迁移失败后错误信息能否定位” |

## 1. 现象

1. 对含 OBJECT 列的表所在 region 执行迁移：

   ```sql
   MIGRATE REGION 41 FROM 3 TO 4;
   ```

   客户端返回 `Msg: The statement is executed successfully.`（异步提交，符合设计）。

2. 60 s 后 `SHOW REGIONS FROM objrepro` 仍是原 2 副本，目标节点 4 没有加入：

   ```
   region 41: [(3, 11.101.10.6, Leader), (6, 11.101.10.7, Follower)]
   ```

3. 失败原因只出现在 DataNode 日志（`11.101.10.6`，2026-10-29 10:39:02.468）：

   ```
   ERROR o.a.i.d.s.d.s.SnapshotTaker:298 - Failed to snapshot object files
   java.nio.file.FileSystemException:
     /data/.../data/snapshot/objrepro-41/snapshot_41_f0522bbb-.../object/41/OQ/MQ4DK/N4/85_1.bin
     -> /data/.../data/object/41/OQ/MQ4DK/N4/85_1.bin: Operation not permitted
     at sun.nio.fs.UnixFileSystemProvider.createLink(UnixFileSystemProvider.java:491)
     at com.timecho.iotdb.commons.file.SecureFileSystemProvider.createLink(SecureFileSystemProvider.java:212)
     at java.nio.file.Files.createLink(Files.java:1112)
     at org.apache.iotdb.db.storageengine.dataregion.snapshot.SnapshotTaker.createObjectHardLink(SnapshotTaker.java:375)
     at org.apache.iotdb.db.storageengine.dataregion.snapshot.SnapshotTaker$1.visitFile(SnapshotTaker.java:337)
     at org.apache.iotdb.db.storageengine.dataregion.snapshot.SnapshotTaker.snapshotSingleObjectRegionDir(SnapshotTaker.java:327)
     at org.apache.iotdb.db.storageengine.dataregion.snapshot.SnapshotTaker.snapshotObjectFiles(SnapshotTaker.java:292)
     at org.apache.iotdb.db.storageengine.dataregion.snapshot.SnapshotTaker.takeFullSnapshot(SnapshotTaker.java:119)
     at org.apache.iotdb.db.consensus.statemachine.dataregion.DataRegionStateMachine.takeSnapshot(DataRegionStateMachine.java:97)
     at org.apache.iotdb.consensus.iot.IoTConsensusServerImpl.takeSnapshot(IoTConsensusServerImpl.java:423)
     at org.apache.iotdb.consensus.iot.IoTConsensus.addRemotePeer(IoTConsensus.java:437)
     at org.apache.iotdb.db.service.RegionMigrateService$AddRegionPeerTask.addRegionPeer(RegionMigrateService.java:379)
   ...
   WARN SnapshotTaker:126 - Failed to take snapshot for objrepro-41, clean up
   INFO IoTConsensus:462 - [IoTConsensus] add remote peer failed, automatic cleanup side effects...
   ```

4. `log_datanode_error.log` 里同一失败被包装成 `ConsensusGroupModifyPeerException: unknown error when taking
   snapshot`，原始 errno 与文件路径在这一层丢失。

5. 移除注入（`chattr -i`）后执行**同一条**迁移语句，21 s 迁移成功 → 因果关系确认。

## 2. 复现步骤

1. 部署 RC11（`ea4f835`），3 CN + 5 DN，SR=3 / DR=2，IoTConsensus，双数据目录。
2. table 方言建库建表并写入 OBJECT 数据（每行 8 KiB，100 行）：

   ```sql
   CREATE DATABASE objrepro;
   CREATE TABLE objrepro.t (time TIMESTAMP TIME, dev STRING TAG, o OBJECT FIELD);
   INSERT INTO objrepro.t(time, dev, o) VALUES
     (0, 'd0', to_object(true, 0, X'<8 KiB hex>')), ...;
   FLUSH;
   ```

   写 100 行 OBJECT 的脚本：`/tmp/rc11_repro_f1.py`，或技能包 `scripts/rcdn/object_audit.py::ensure_object_probe_table`。
3. `SHOW REGIONS FROM objrepro`，记下该 region 的 leader 节点（本例 `41`，leader 节点 3 / `11.101.10.6`）。
4. 在 leader 上把该 region 的 OBJECT 文件置为不可变（模拟“object 文件不可硬链接/不可删除”的存储状态，
   等价于只读挂载、NFS 不支持硬链接、备份/杀毒持锁、ext4 链接数到上限）：

   ```bash
   find /data/mpp_test/.../data/datanode/data/object/41 -name '*.bin' -exec chattr +i {} +
   find /mpp_ssd/v20121rc11/dn_data/object/41            -name '*.bin' -exec chattr +i {} +
   ```

5. 执行迁移（table 方言）：`MIGRATE REGION 41 FROM 3 TO 4;`
6. 观察：客户端返回成功（异步）；60 s 后 region 仍是原 2 副本；leader 的 `logs/log_datanode_all.log`
   出现第 1 节的 `FileSystemException` 栈；`logs/log_datanode_error.log` 只有 `unknown error when taking snapshot`。
7. 清理：`chattr -i` 同样的文件，再执行同一条迁移，21 s 成功。

## 3. 期望 / 实际

| 维度 | 期望 | 实际 |
|---|---|---|
| 迁移行为 | OBJECT 文件不可硬链接时，应降级为物理复制（`Files.copy`），迁移照常完成 | 整次快照失败，迁移回滚，region 保持原副本 |
| 错误信息 | 异常/日志应包含 regionId、文件相对路径、原始 errno，可直接定位 | ERROR 行只有 `Failed to snapshot object files`（无 regionId、无路径）；向上被包装成 `unknown error when taking snapshot`，errno 丢失 |
| 客户端 | 异步任务，返回“执行成功”符合设计（本缺陷不以此为判定） | 同左 |
| 节点缩容 | `REMOVE DATANODE` 依赖批量迁移 | 同一失败路径会阻断缩容，且错误同样不可定位 |

## 4. 根因分析（代码路径，RC11 `ea4f835`）

- `SnapshotTaker.snapshotObjectFiles()`（`SnapshotTaker.java:292`）遍历所有 OBJECT 根目录，对每个
  `<object_root>/<regionId>` 调用 `snapshotSingleObjectRegionDir()`；**任一目录的任一文件失败，整次快照返回 false**。
- `snapshotSingleObjectRegionDir()`（`:327`）用 `Files.walkFileTree` 遍历对象文件，对每个 `.bin` 调用
  `createObjectHardLink()`（`:337`）。
- `createObjectHardLink()`（`:375`）只吞掉 `FileNotFoundException / NoSuchFileException`（TTL 删除），
  其余 `IOException`（`EPERM`、`EXDEV`、`EMLINK`、`EACCES`、`ENOSPC`）直接抛出；**没有 `Files.copy` 降级**。
- 异常向上：`takeFullSnapshot` 失败 → `DataRegionStateMachine.takeSnapshot` 失败 →
  `IoTConsensusServerImpl.takeSnapshot` 包成 `ConsensusGroupModifyPeerException: unknown error when taking snapshot`
  → `IoTConsensus.addRemotePeer` 失败 → `RegionMigrateService$AddRegionPeerTask` 失败并回滚。
- 由于迁移/缩容是异步任务，失败只落在日志；而 `SnapshotTaker:298` 的 ERROR 行既不打印 regionId，
  也不打印失败文件与 errno，`error.log` 里又只剩 `unknown error`，导致现场无法定位。

## 5. 影响面

任何让 OBJECT 文件**不可硬链接**的存储状态都会阻断迁移与缩容：

1. 只读挂载 / 只读快照目录；NFS、CIFS 等不支持硬链接的网络文件系统；
2. 文件被置为 immutable / append-only（本报告复现方式），或备份、杀毒、审计代理持有锁；
3. ext4 单 inode 链接数上限（65 000）：每次迁移都会给每个对象文件增加一个硬链接，遗留快照未清理时，
   OBJECT 文件多的实例（10 万级文件）可能先达到上限，之后所有迁移都失败；
4. 双数据目录跨文件系统（`/data` 与 `/mpp_ssd`）时，若快照目录与对象目录不在同一 device，
   会以 `EXDEV` 触发同一失败路径（本次环境快照目录与对象目录同盘，未触发，但代码路径相同）。

后果：`REMOVE DATANODE` 卡住或节点删不掉，现场只能靠 `Failed to snapshot object files` 这条无上下文的
日志去猜；叠加 TDB-861 的快照残留问题，对象场景的空间与运维风险会同时放大。

## 6. 修复建议（两条，低风险）

### 6.1 硬链接失败降级为物理复制

`SnapshotTaker.createObjectHardLink()` 在 `Files.createLink` 抛 `IOException` 时，改为
`Files.copy(source, target, StandardCopyOption.REPLACE_EXISTING)`；复制成功则迁移继续。
（复制会比硬链接多占一份对象空间，但对象文件通常是小文件、且迁移完成后快照目录会被清理，可作为兜底路径。）

### 6.2 错误信息带 errno / 路径 / regionId

- `SnapshotTaker:298` 的 ERROR 日志补上 `regionId`、失败文件相对路径、原始异常消息（如
  `Operation not permitted`），并保留完整栈；
- 向上包装处（`IoTConsensusServerImpl.takeSnapshot`）把 `unknown error when taking snapshot` 换成带
  底层异常摘要的消息，避免 `log_datanode_error.log` 丢失 errno；
- 建议为快照失败定义可检索的错误码/异常类型（如 `ObjectSnapshotLinkException`），便于日志告警匹配。

## 7. 证据与附件

- 复现脚本：`/tmp/rc11_repro_f1.py`（建库表 → 写 100 行 8 KiB OBJECT → `chattr +i` → 迁移 → 观察 → 解锁再迁移）
- 执行记录：`/tmp/rc11_repro_f1.log`

  ```
  region=41 leader=11.101.10.6 from=3 to=4 ts=10:38:59
  immutable 文件数: 20
  MIGRATE 客户端返回: Msg: The statement is executed successfully.
  60s 后副本: [(3, 11.101.10.6, Leader), (6, 11.101.10.7, Follower)]
  迁移是否成功: False
  已解锁，重新迁移: Msg: The statement is executed successfully.
  解锁后迁移成功，用时 21s
  ```

- DN 日志：`11.101.10.6:/data/mpp_test/v20121rc11_1023_ea4f835/logs/log_datanode_all.log` 第 2897-2912 行（10:39:02.468）
- 技能包内相关代码：`scripts/rcdn/object_audit.py`（`_migration_plan`、`run_object_snapshot_probe`）；
  用例 `dn_object_delete_residue`、`dn_object_big_migrate`、`dn_object_manyfiles_residue`
- 关联缺陷：TDB-861（OBJECT 快照/GC 残留，与本缺陷同在 `SnapshotTaker.snapshotObjectFiles` 路径）

## 8. 线上处置与替代方案（实测，2026-10-29）

### 8.1 只是“不可链接/不可写”，数据还在

修好存储（`chattr -i`、只读挂载改回可写、释放备份/杀毒的文件锁）后，**原地重试同一条 `MIGRATE REGION`
即可**，不需要重建 region：本报告第 7 节记录了解锁后同一迁移 21 s 成功。前提是对象文件本身完好。

### 8.2 对象文件真的丢了（更危险）

`createObjectHardLink()` 把 `FileNotFoundException / NoSuchFileException` 当作“被 TTL 删除”吞掉，
所以**源副本缺对象文件时迁移依然“成功”，新副本静默缺失这些 OBJECT 载荷**。实测：

```
region 47，leader 11.101.10.7，20 个 .bin，2 副本
删除 leader 上 6 个 .bin（模拟磁盘损坏丢文件）
MIGRATE REGION 47 FROM 6 TO 4 → Msg: The statement is executed successfully.（27 s 完成）
迁移后：新副本 14 个文件，旧副本仍 20 个
数据校验：100 行里 6 行 length(read_object(o)) = 0（如 d56/d88/d98/d13），迁移/读取都不报错
```

也就是说“修好磁盘后重建 region”只在数据完好时成立；数据缺了，重建会把缺失复制过去，必须靠对象级校验发现。

### 8.3 建议的线上处置顺序

1. **先修存储**（属性/权限/挂载/锁），重试同一条 `MIGRATE REGION`。
2. **对象级校验**（迁移前后都做，不能只数文件、数行）：

   ```sql
   SELECT count(*) FROM <db>.<table> WHERE length(read_object(o)) = 0;   -- 期望 0
   SELECT time, dev, length(read_object(o)),
          sha256(cast(read_object(o) as string)) FROM <db>.<table> LIMIT 10;  -- 与迁移前比对
   ```

3. **发现 0/NULL 即为源副本已丢对象**：先把该 region 的 leader 切到健康副本，再迁走坏副本、从健康副本重建，
   同时从备份核对是否需要重灌这批 OBJECT。
4. **`REMOVE DATANODE` 之前先跑一遍全库对象校验**，避免缩容过程中把缺失固化到新副本。
5. 修复前把 `Failed to snapshot object files` 纳入日志告警——异步语义下客户端不会报错，这是唯一线索。

### 8.4 本次建议的改动范围（仅两条）

1. 硬链接失败降级 `Files.copy`，使迁移在不支持硬链接的存储上仍能完成；
2. 失败日志/异常带 errno、文件相对路径与 regionId，替换 `unknown error when taking snapshot` 的包装。

（“失败回传客户端”按异步语义不列出；“缺失文件不再静默”属于 TDB-861 的引用集合修复范围，不在本单。）
