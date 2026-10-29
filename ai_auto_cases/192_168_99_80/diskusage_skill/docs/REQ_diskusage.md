# 需求文档要点：统计数据的磁盘空间占用

**原件**：《V2.0.8.2-计算模块-查询执行-统计数据的磁盘空间占用-需求分析》
（`V2.0.8.2-计算模块-查询执行-统计数据的磁盘空间占用-需求分析.pdf` / `.docx`，作者 舒文炜 / 田原）
**正文抽取件**：`docs/req_disk_usage.txt`（本 skill 内，从 `.docx` 无损提取，214 段）

## 1. 需求描述

IoTDB 原先只能按 DataRegion / Database 粒度统计存储空间，无法直观比较各表占用。
本功能提供 SQL，支持展示 **table（表模型）/ pattern（树模型）** 级的存储空间使用统计。

## 2. 功能定义（§3.2）

| 项 | 表模型 | 树模型（非标准 SQL） |
| --- | --- | --- |
| 入口 | `information_schema.table_disk_usage` 系统表 | `SHOW DISK_USAGE FROM pathPattern [whereClause] [orderByClause] [rowPaginationClause]` |
| 路径/范围 | 通过系统表查询 | pattern 以 `root` 开头，中间节点支持 `*` 或 `**` |
| 列 | `database｜table_name｜datanode_id｜region_id｜time_partition｜size_in_bytes` | `Database｜DataNodeId｜RegionId｜TimePartition｜SizeInBytes` |
| 特殊约定 | 不显示 view；过滤条件里指定不存在的 table 或 view 时**返回空结果集** | — |

- 统计的是 **TsFile 中数据的真实大小**（ChunkGroup + Metadata），**因此不考虑 mods 删除的情况**。
- 起始支持版本：**2.0.8.2**。

## 3. 场景示例（§3.4，原文摘录）

```sql
-- 表模型
IoTDB:information_schema> select * from table_disk_usage
+--------+----------+-------+---------+--------------+-------------+
|database|table_name|datanode_id|region_id|time_partition|size_in_bytes|
+--------+----------+-------+---------+--------------+-------------+
|   test1|        t1|          1|        5|             0|          142|
|   test1|        t2|          1|        5|             0|            0|
|   test1|        t1|          1|        6|             0|            0|
|   test1|        t2|          1|        6|             0|           82|
+--------+----------+-------+---------+--------------+-------------+
Total line number = 4   It costs 2.821s

IoTDB:information_schema> select * from table_disk_usage where region_id = 6 and table_name like '%2'
→ 1 行（t2 / region 6 / 82）

-- 树模型
IoTDB> show disk_usage from root.test.**
+---------+----------+--------+-------------+-----------+
| Database|DataNodeId|RegionId|TimePartition|SizeInBytes|
+---------+----------+--------+-------------+-----------+
|root.test|         1|       3|            0|         70|
+---------+----------+--------+-------------+-----------+
```

## 4. 非功能要求（§3.3）

- **性能**：气象局有几百万 object 文件，预期 2~3s 返回；每执行一次即时计算可能很慢，因此**需要缓存加速**
  （表模型即持久化的大小索引 `TableDiskUsageIndex`）。
- **权限（§3.3.3.1 访问控制）**：**仅允许拥有 SYSTEM 权限的用户执行**。

## 5. 官方自测场景（§4，注意其中的"关合并"）

- 硬件 16C32G / 单块 HDD / 物理机；表模型单表 20 个测点。
- 聚合查询示例：
  `select database, table_name, SUM(size_in_bytes) AS total_size_in_bytes from information_schema.table_disk_usage GROUP BY database, table_name`
- 结论：查询延迟与 TsFile 数量成正比（1 → 0.330s、10 → 0.468s、100 → 3.326s、500 → 15.420s、1000 → 30.018s），
  与"单 tsfile 内表的数量"基本无关。
- **自测明确写了"仅查询，关合并"** —— 这正是 TDB-629（统计泄漏读锁导致合并卡死）没被自测发现的原因；
  本 skill 的门禁用例（DU-01/DU-02）专门把合并打开来复现/回归。

## 6. 竞品调研（§2.2，摘要）

- TimescaleDB：`hypertable_detailed_size()` 提供 hypertable 级统计（table_bytes/index_bytes/toast_bytes/total_bytes）。
- InfluxDB：不支持。
- TDengine：不支持，只有 db 粒度（`ins_disk_usage`，data1/data2/data3 是一/二/三级存储而非配置目录）。
- 客户场景：气象局（表模型，按表设容量阈值 → 超阈值收回写权限）、宝武 E4（树模型，`root.db.基地.XXXXX` 按基地统计）。
