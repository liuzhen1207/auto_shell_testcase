# TDB-1104【load snapshot】空 DataRegion 在缩容（Adding）时 load snapshot 空指针

## 一、RN 信息

| 项 | 值 |
| --- | --- |
| 编号 | TDB-1104（PLM itemId 1732） |
| 标题 | 【2.0.10.1】【load snapshot】集群中存在空 DataRegion，缩容过程中（Adding）DN 需要修复 load snapshot 空指针 |
| 类型 / 优先级 | 代码优化 / **P0** |
| 迭代 | V2.0.10.1 |
| 负责人 / 验证 | 高宏志 / 刘珍 |
| 来源 | PingCode（`tc2026_3c4d_extend_remove_migrate_tree_table_show_migrations.sh` 场景） |
| PLM | https://plm.infra.timecho.com/iterations?productId=1&itemId=1732 |
| 本次验证版本 | **2.0.13.1 RC2（build 83183d0）** |
| 验证结果 | ✅ **通过**（表模型 + tree 模型，共 36 次扩缩容操作，0 空指针） |

## 二、缺陷背景

集群中存在**空 DataRegion**（`SeriesSlotNum=0`，CN 预创建但未分配任何 SeriesPartitionSlot）。对该 region 做副本扩展/迁移时，目标 DataNode 进入 **Adding** 状态并执行 **load snapshot**，旧版本在此处抛空指针。

触发前提：`data_region_group_extension_policy=CUSTOM`（或 AUTO/PROACTIVE 在扩容后自动调大 `maxDataRegionGroupNum`），从而产生"有 region 组、无 series slot"的空 region。

## 三、验证设计

3C5D（3 CN + 5 DN，SR3/DR2），RC2 `83183d0`。

### 3.1 造空 DataRegion

```
# TREE 方言下热改（table 方言会报 701）
SET SQL_DIALECT=TREE;
SET CONFIGURATION "data_region_group_extension_policy"="CUSTOM";
SET CONFIGURATION "default_data_region_group_num_per_database"="10";

# 表模型
SET SQL_DIALECT=TABLE;
CREATE DATABASE tdb1104i WITH (max_data_region_group_num=10);

# tree 模型
SET SQL_DIALECT=TREE;
CREATE DATABASE root.tdb1104tree;
```

结果：两个库各得到 **10 个 DataRegion 组**，其中 9 个 `SeriesSlotNum=0`（真正的空 region），1 个 `SeriesSlotNum=1`。

### 3.2 走 Adding + load snapshot

对每个空 region 执行：

```
EXTEND REGION <emptyRegionId> TO <targetDnId>;   -- 目标 DN 进入 Adding，加载 snapshot
REMOVE REGION <emptyRegionId> FROM <targetDnId>;  -- 缩容回 RF=2
```

- 表模型：region 17/18/19/20/22/23/24/25/26，共 9 组 × 2 次操作 = 18 次
- tree 模型：region 28/29/30/31/32/33/34/35/36，共 9 组 × 2 次操作 = 18 次

### 3.3 判定标准

每次操作前在 5 台 DN 日志末尾写入唯一标记，操作后只扫描标记之后的日志，命中以下任一即判失败：

- `NullPointerException`
- `snapshot.*(fail|error|exception)`
- `addPeer.*(fail|error)`

## 四、结果

| 模型 | 空 region 数 | 操作次数 | NPE | snapshot 异常 | addPeer 失败 | 结论 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 表模型 | 9 | 18 | 0 | 0 | 0 | PASS |
| tree 模型 | 9 | 18 | 0 | 0 | 0 | PASS |

关键证据（表模型 region 17 → DN 172.16.2.23）：

```
10:59:30,026 INFO DataNodeInternalRPCServiceImpl:4375 - Successfully submit addRegionPeer task for region: TConsensusGroupId(type:DataRegion, id:17), target DataNode: 172.16.2.23
10:59:30,026 INFO RegionMigrateService$AddRegionPeerTask:324 - [REGION_MIGRATE_PROCESS], Start to addPeer TDataNodeLocation(dataNodeId:3, ...) for region TConsensusGroupId(type:DataRegion, id:17)
10:59:32,039 INFO RegionMigrateService$AddRegionPeerTask:366 - [REGION_MIGRATE_PROCESS], Succeed to addPeer TEndPoint(ip:172.16.2.23, port:10760) for region DataRegion[17]
```

- 目标 DN 在约 **2 秒**内完成 Adding → Running；
- 全量日志复查：5 台 DN 的 `NullPointerException` 计数均为 **0**；
- 操作后 `SHOW REGIONS` 副本数回到 2，元数据与数据一致。

## 五、结论

**RC2（83183d0）上该缺陷已修复**：空 DataRegion 在 Adding + load snapshot 路径下不再出现空指针，表模型与 tree 模型均通过。

## 六、限制与后续

1. 本次用 `EXTEND/REMOVE REGION` 模拟"缩容过程中（Adding）"的代码路径，**未执行真实 `REMOVE DATANODE` 摘节点**（会破坏 3C5D 拓扑）；
2. 原始场景是"扩容 1 DN 后出现空 region"，本环境无第 6 台节点，改用 CUSTOM 策略直接在库内造出空 region，等价覆盖 `SeriesSlotNum=0` 前置条件；
3. 建议后续在可扩容环境补一次"真实扩容 → 缩容"回归，作为补充证据。

## 七、证据

| 内容 | 位置 |
| --- | --- |
| 执行脚本 | [`scripts/run_tdb1104.sh`](scripts/run_tdb1104.sh) |
| 日志摘要 | [`evidence/log-summary.md`](evidence/log-summary.md) |
| 服务器原始日志 | `/data1/iotdb/v20131rc2_1110_83183d0/logs/log_datanode_all.log`（172.16.2.19/21/22/23/24），标记 `TDB1104-*` |
