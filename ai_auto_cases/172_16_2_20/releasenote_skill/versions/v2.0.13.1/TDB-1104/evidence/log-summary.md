# TDB-1104 证据摘要

> 采集时间：2026-11-17 10:50 ~ 11:12（Asia/Shanghai）
> 环境：RC2 `83183d0`，3C5D（CN 16/17/18，DN 19/21/22/23/24）
> 原始日志：各 DN 的 `/data1/iotdb/v20131rc2_1110_83183d0/logs/log_datanode_all.log`，检索标记 `TDB1104-*`

## 一、空 DataRegion 构造结果

`SET CONFIGURATION`（TREE 方言）热改策略：

```
SET CONFIGURATION "data_region_group_extension_policy"="CUSTOM";
SET CONFIGURATION "default_data_region_group_num_per_database"="10";
```

| 库 | 模型 | DataRegion 组数 | SeriesSlotNum=0 的组 |
| --- | --- | ---: | ---: |
| `tdb1104i` | 表 | 10 | 9（17/18/19/20/22/23/24/25/26） |
| `root.tdb1104tree` | tree | 10 | 9（28/29/30/31/32/33/34/35/36） |

`SHOW REGIONS` 片段（表模型）：

```
region=17 slot=0 dn=4    region=17 slot=0 dn=5
region=18 slot=0 dn=5    region=18 slot=0 dn=7
...
region=21 slot=1 dn=3    region=21 slot=1 dn=6
```

## 二、Adding + load snapshot 日志（表模型 region 17 → DN 172.16.2.23）

```
10:59:30,026 [pool-45-IoTDB-DataNodeInternalRPC-Processor-9] INFO  DataNodeInternalRPCServiceImpl:4375
  - Successfully submit addRegionPeer task for region: TConsensusGroupId(type:DataRegion, id:17), target DataNode: 172.16.2.23
10:59:30,026 [pool-30-IoTDB-Region-Migrate-Pool-3] INFO  RegionMigrateService$AddRegionPeerTask:324
  - [REGION_MIGRATE_PROCESS], Start to addPeer TDataNodeLocation(dataNodeId:3, ..., dataRegionConsensusEndPoint:TEndPoint(ip:172.16.2.23, port:10760), ...) for region TConsensusGroupId(type:DataRegion, id:17)
10:59:32,039 [pool-30-IoTDB-Region-Migrate-Pool-3] INFO  RegionMigrateService$AddRegionPeerTask:366
  - [REGION_MIGRATE_PROCESS], Succeed to addPeer TEndPoint(ip:172.16.2.23, port:10760) for region DataRegion[17]
```

结论：目标 DN 约 **2 秒**完成 Adding → Running，**无 snapshot 异常**。

## 三、异常扫描结果（按标记分段）

| 阶段 | 标记 | 操作数 | dn19 | dn21 | dn22 | dn23 | dn24 | 合计 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 表模型空 region 扩缩容 | `TDB1104-LOOP2-*` | 18 | 0 | 0 | 0 | 0 | 0 | **0** |
| tree 模型空 region 扩缩容 | `TDB1104-TREE2-*` | 18 | 0 | 0 | 0 | 0 | 0 | **0** |

扫描正则：`NullPointerException|snapshot.*(fail|error|exception)|addPeer.*(fail|error)`

全量日志复查（不按标记）：

| DN | NullPointerException 计数 |
| --- | ---: |
| 172.16.2.19 | 0 |
| 172.16.2.21 | 0 |
| 172.16.2.22 | 0 |
| 172.16.2.23 | 0 |
| 172.16.2.24 | 0 |

## 四、清理

- 策略恢复：`data_region_group_extension_policy=PROACTIVE`、`default_data_region_group_num_per_database=2`
- 测试库全部 drop，`SHOW DATABASES` 只剩 `information_schema`
- 集群恢复 8/8 Running
