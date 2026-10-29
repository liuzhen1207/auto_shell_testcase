# 磁盘占用统计 skill —— 设计与缺陷根因（TDB-629）

## 1. 被验证的功能：磁盘空间占用统计

需求文档：《V2.0.8.2-计算模块-查询执行-统计数据的磁盘空间占用-需求分析》
（原件 `V2.0.8.2-…-需求分析.pdf` / `.docx`，正文已抽取为 `docs/req_disk_usage.txt`）

| 项 | 内容 |
| --- | --- |
| 目标 | 支持 **table（表模型）/ pattern（树模型）** 粒度的存储空间统计，含 ChunkGroup 与 Metadata 大小 |
| 统计口径 | **TsFile 中数据的真实大小**，**不考虑 mods 删除** |
| 表模型 | `information_schema.table_disk_usage` 系统表：`database｜table_name｜datanode_id｜region_id｜time_partition｜size_in_bytes`；不显示 view；过滤不存在的 table/view 返回**空结果集** |
| 树模型 | `SHOW DISK_USAGE FROM pathPattern [where] [order by] [rowPagination]`：`Database｜DataNodeId｜RegionId｜TimePartition｜SizeInBytes`；pattern 必须以 `root` 开头，中间节点支持 `*`/`**` |
| 权限 | **仅允许拥有 SYSTEM 权限的用户执行**（需求文档 §3.3.3.1） |
| 性能 | 气象局数百万 object 文件场景要求 2~3s 返回 ⇒ 需要缓存（表模型即 `TableDiskUsageIndex`） |

## 2. 代码链（RC6 源码 `7ae8713ecb`）

```
树模型：SHOW DISK_USAGE FROM <pattern>
  → ShowDiskUsageOperator.next()
      → 每个 (DataRegion, TimePartition) 新建 TreeDiskUsageStatisticUtil
          → acquireReadLocks(files)      ← 采集阶段加锁
          → calculateNextFile() × N      ← 逐文件打开读取，算 data/metadata 大小
          → close()                      ← 释放
表模型：select * from information_schema.table_disk_usage
  → TableDiskUsageIndexReader
      → checkAllFilesInTsFileManager() → calculateNextFile()
          → TableDiskUsageStatisticUtil（同一个基类 DiskUsageStatisticUtil）
      → 命中大小索引的快路径：TableDiskUsageStatisticUtil.calculateWithoutOpenFile()
          · 该 TsFile 已在索引里           → 直接取索引值（不打开文件）
          · 库内 >1 张表 或 存在 mods      → 返回 false ⇒ 必须打开文件
两者公共基类：iotdb-core/datanode/.../storageengine/dataregion/utils/DiskUsageStatisticUtil.java
```

## 3. TDB-629 缺陷：统计泄漏读锁 ⇒ 合并卡死

### 3.1 现象（工单原文）

> 只要用了 show disk_usage，那些被扫过的文件，就永远没法被合并了；并且合并线程也会被卡住，
> 后续 tsfile 数量就会一直堆积。

### 3.2 根因（修复提交 `e46c4b7a7d` / `849f98444f`「Fix read lock leak in disk usage statistics (#18807)」）

修复前的 `DiskUsageStatisticUtil`（RC5 及更早）：

```java
acquireReadLocks():                                  // 采集阶段
    resource.readLock();                             // ← 方式 A：裸读锁
    ...
    resourcesWithReadLock.add(resource);

calculateNextFile():
    if (deleted || calculateWithoutOpenFile(r)) { iterator.remove(); r.readUnlock(); return; }
    FileReaderManager.getInstance().increaseFileReaderReference(r, true);   // ← 方式 B：再加一次（含读锁）
    try { ...读文件... } finally {
        FileReaderManager.getInstance().decreaseFileReaderReference(r, true);  // 只还了 B
        iterator.remove();                           // ← 从"待释放队列"里移走 ⇒ A 再也没人还！
    }

releaseReadLocks():
    for (resource : resourcesWithReadLock) resource.readUnlock();   // 只能释放"还没被消费"的那些
```

⇒ **每个被真正打开读取过的 TsFile 都永久泄漏一把读锁**。
树模型 `TreeDiskUsageStatisticUtil.calculateWithoutOpenFile()` **恒返回 false**，
所以 `SHOW DISK_USAGE` 扫过的文件**全部**泄漏；表模型则在"库内多于一张表"或"存在 mods"时同样泄漏。

合并执行阶段要对源文件加写锁（`CompactionUtils:262`、`AbstractCompactionTask:435`、
`InnerSpaceCompactionTask:434` 都是 `tsFileResource.writeLock()`）⇒
**写锁永久等不到 ⇒ 该文件再也不被合并、合并线程阻塞挂住**（线程池被占满后其他库的合并也一起停），
于是 TsFile 持续堆积。

### 3.3 修复内容（RC6 已包含：`e46c4b7a7d` 是 `7ae8713e` 的祖先）

```diff
-        resource.readLock();
+        FileReaderManager.getInstance().increaseFileReaderReference(resource, true);
         if (resource.isDeleted() || !resource.isClosed()) {
-          resource.readUnlock();
+          FileReaderManager.getInstance().decreaseFileReaderReference(resource, true);
           continue;
         }
...
-  FileReaderManager.getInstance().increaseFileReaderReference(tsFileResource, true);   // next() 里删掉
...
-      tsFileResource.readUnlock();
+      FileReaderManager.getInstance().decreaseFileReaderReference(tsFileResource, true);
...
-      resource.readUnlock();
+      FileReaderManager.getInstance().decreaseFileReaderReference(resource, true);
```

统一成"FileReaderManager 引用计数"一种锁：采集时 +1、消费/收尾时 -1，不再有裸 `readLock()`，
也不再出现"被 `iterator.remove()` 掉之后没人还锁"的情况。
修复自带的单测断言正是本 skill 门禁的黑盒版：**统计完成后 `resource.tryWriteLock()` 必须成功**。

### 3.4 为什么自测没抓到

需求文档 §4 的自测场景明确写了"**仅查询，关合并**"。关掉合并后，读锁泄漏没有任何可观测后果，
只有把合并开成"很容易触发"（`inner_compaction_candidate_file_num=2`、调度 1s）并在统计之后观察合并，
才能在一个短窗口内看出来。

## 4. 门禁用例的设计（DU-01 树模型 / DU-02 表模型）

```
阶段 A 正向对照（必须先过，否则判"场景无效"）
    合并开启 → 连写 DU_FILES 批数据（每批 flush 落成一个 TsFile）
    → 窗口内必须出现 "InnerSpaceCompaction task finishes successfully" 增长
阶段 B 缺陷触发
    1) SET CONFIGURATION 关合并（实测可热加载）
    2) 再连写 DU_FILES 批 → 确认该库有 ≥2 个未合并 TsFile 且已落盘
    3) **执行磁盘占用统计**（DU-01 用 show disk_usage；DU-02 用 information_schema.table_disk_usage）
    4) SET CONFIGURATION 开合并
    5) 观察窗口 DU_WIN_SEC：必须出现 "合并完成行数增加" 且 "该库 TsFile 数下降"
判据
    PASS = 阶段 A 推进 且 统计查询成功 且 阶段 B 推进
    FAIL = 阶段 B 统计之后合并毫无推进（命中 TDB-629）
佐证（只记录）
    jstack 里卡在 TsFileResource.writeLock 的线程数 / 线程栈、合并日志尾部
```

要点与坑：

- **必须先把合并关掉再写数据**：否则两批文件在统计之前就被合并了，阶段 B 没有"未合并的文件"可观察。
- **树模型**只要扫过就泄漏（`calculateWithoutOpenFile` 恒 false）；**表模型**要求库内 >1 张表
  （否则走"库内只有一张表"的免打开快路径），且统计要发生在这些 TsFile 还没进大小索引的时候
  （集群刚起、库刚建、此前没有任何统计查询）。
  **实测（2.0.12.1）**：表模型接口在本场景下**没有**复现（统计后合并照常推进、卡死线程 0，RC5/RC6 表现一致）
  ⇒ 表模型侧存在不打开文件的快路径（大概率命中大小索引），门禁判定以树模型接口为准；DU-02 保留为表模型回归对照。
- 判定用"合并完成行数 + TsFile 数"两个独立信号同时成立，避免把"文件被 flush 出来"误算成"合并发生"。
  辅信号取"低于传入基线 **或** 低于窗口内首次采样"，避免统计之后仍在陆续 `Async close` 的文件把计数抬高造成误判。
- 统计口径不受 TTL 影响：env.conf 把 TTL 参数设成中性值（`expired_data_ratio=1.0`、间隔 2h），
  避免 settle 合并混进观测。

## 5. 本轮补充用例的实测语义（写断言必读）

| 项 | 实测（2.0.12.1 RC6） | 对用例的影响 |
| --- | --- | --- |
| 树模型 pattern 匹配对象 | **设备路径**（`matchFullPath(devicePath)`） | `root.db.**`/`root.db.*`/`root.db.d1` 有数；`root.db.d1.**`、`root.db`、`root.*` 均为 0；无匹配设备时仍出行、值为 0 |
| 表模型结果列 | 比需求文档多一列 `table_type` | 一律按列名取值（`du_col_*`） |
| 表模型聚合列类型 | double（`1698.0`） | 数值解析用 `+0`，不能 `gsub` 去非数字字符 |
| 表模型接口与 TDB-629 | 未复现（快路径不打开文件） | 门禁判定以树模型为准，表模型作对照 |
| 表模型权限 | 同样要求 SYSTEM（零权限报 803） | 权限用例覆盖两种接口 |
