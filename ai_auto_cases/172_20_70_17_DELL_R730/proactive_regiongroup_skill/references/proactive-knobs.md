# 旋钮、可观测量与环境约定

来源：源码侦察（`PartitionManager.java`、`ConfigNodeDescriptor.java`、`ClusterSchemaManager.java`、
`DataPartitionPolicyTable.java`）+ 集群/客户端实测（2026-10-14）。

## 1. 配置旋钮

### 1.1 集群级（改后必须重启，`prepare` 阶段落盘，用例自证读回）

| 键 | 取值 | 备注 |
| --- | --- | --- |
| `series_slot_num` | 默认 `1000` | 模板标注 `first_start`；**不可热更**。实现里有两个来源：`DataPartitionPolicyTable.java:46` 类加载快照、`PartitionManager.java:745` 实时读 ⇒ 用例只做"重启后生效性"观测 |
| `schema_replication_factor` / `data_replication_factor` | 本任务 `3` / `2` | 参与上限换算 |
| `data_region_consensus_protocol_class` | `IoTConsensus` / `IoTConsensusV2` | 先 IoT 后 V2；**schema region 不允许 V2**（`ConfigNodeStartupCheck.java:162-172`） |
| `data_partition_allocation_strategy` | `INHERIT`（默认）/`SHUFFLE` | **不可热更**（`PartitionBalancer` 构造时读取，精确匹配字符串，非法值 warn+回落 INHERIT）。策略表只服务 INHERIT ⇒ SHUFFLE 下重平衡无分配层效果 |
| `time_partition_interval` | 默认 `604800`（7 天） | 跨时间分区用例需要调小（如 `3600`） |
| `dn_thrift_max_frame_size` | 模板 `0`（内部默认 64MB 档） | 表模型 1 行 20 万列的 insertTablet 请求约 181MB，会 `TTransportException: Frame size ... larger than protect max size (67108864)`；大测点档位调到 512MB |
| `wal_entry_size_limit_in_byte` | 模板 `-1`（按 WAL 缓冲推算，实测 32MB 档） | 50 万测点单行 aligned 写入的 WAL 条目约 41.5MB，会 620 拒绝；大规模测点档位调到 128MB |
| `dn_data_dirs` / `dn_wal_dirs` | 见 §4 | 多目录需重启 |

### 1.2 热加载（`SET CONFIGURATION`，一次一个键，禁止 `ON <nodeId>`，需 SYSTEM）

| 键 | 默认 | 校验 | 备注 |
| --- | --- | --- | --- |
| `schema_region_group_extension_policy` | `PROACTIVE` | 枚举严格匹配（无 trim/upper）⇒ `proactive` 非法，`" PROACTIVE "` 合法（`TrimProperties` 会 trim） | 非法值抛 IOException，**写在回调里先于落盘**（`ConfigurationFileUtils.java:429-432` vs `:434-483`）⇒ 坏值不会持久化，语句返回 `EXECUTE_STATEMENT_ERROR` |
| `data_region_group_extension_policy` | `PROACTIVE` | 同上 | 错误消息**恒为** `DataRegionGroupExtensionPolicy %s doesn't exist.`（解析 schema 键失败也报这条，`doc-gaps.md` G-02） |
| `default_schema_region_group_num_per_database` | `1` | `>0` | 最小组数 |
| `default_data_region_group_num_per_database` | `2` | `>0` | 最小组数 |
| `schema_region_per_data_node` | `1` | `>0` | 上限权重（resource=DN 数） |
| `data_region_per_data_node` | `0` | `>=0` | `0` ⇒ weight=0.5、resource=DN 上报 CPU 核数总数 |

六个键都在"必须全集群一致"集合内（`ConfigurationFileUtils.java:68-81`），指定单节点会被拒（`ConfigManager.java:2021-2029`）。

### 1.3 上限与最小组数的其它入口

- `ALTER DATABASE <db> WITH MAX_DATA_REGION_GROUP_NUM=…` 在**非 CUSTOM** 策略下被**拒绝**（`ClusterSchemaManager.java:1055-1061`；IT `DistributionIT:688-692` 断言抛 `SQLException`）⇒ 用例 `PG-LIM-19` 改为断言"被拒绝"。
- 建库时 min 回落 `default_*_region_group_num_per_database`；未显式指定 max ⇒ `max = min`（`ClusterSchemaManager.java:975-1025`）。
- 系统库/审计库（`root.__system`、`root.__audit`、表模型 `__audit`）不参与 `databaseNum` 分摊，且各自 min/max 固定 `1`（`:973-995`）。

## 2. 可观测量（SQL）

| 目的 | 树模型 | 表模型 |
| --- | --- | --- |
| 组清单 | `SHOW SCHEMA REGIONS OF DATABASE root.db` / `SHOW DATA REGIONS OF DATABASE root.db` | `SHOW SCHEMA REGIONS FROM db` / `SHOW DATA REGIONS FROM db` |
| 全集群组清单 | `SHOW (SCHEMA\|DATA) REGIONS` | 同 |
| 设备所属组 | `SHOW DATA REGIONID WHERE DEVICE=root.db.d0 [AND timeRange]` | 同（设备标识用表模型写法） |
| 某库某设备的时间分区 | `SHOW TIMESLOTID WHERE DEVICE=…` / `… WHERE DATABASE=…` | 同 |
| 时间分区计数 | `COUNT TIMESLOTID WHERE …` | 同 |
| 集群状态 | `SHOW CLUSTER`（读 Status/NodeType/InternalAddress） | 同 |
| 配置读回 | `SHOW CONFIGURATION`（或逐节点读 conf 文件，测试更稳） | 同 |

**去重口径**：`SHOW … REGIONS` 每行是一个**副本**，3 副本 ⇒ 每组 3 行。组数 = 去重后的 region id 数（用例 `PG-OBS-04` 自证）。

设备 → slot：`pgkit/slots.py`（BKDR131；与需求文档 `root.proactive.d0/d1/d2 → 327/328/329` 逐值一致）。

## 3. 权限与审计

- 建用户：`CREATE USER pg_normal 'Pwd@123456';`；授系统权限：`GRANT SYSTEM TO USER pg_system;`（树/表方言按客户端 `-sql_dialect` 区分）。
- 普通用户写入不需要额外授权，只需库/表读写权限（`GRANT WRITE ON root.db TO USER …` 等）。
- 三权分立：`enable_audit_log`/三权分立开关为集群级配置；用例 PRV-03 开启后重启再验。
- 审计检索：审计日志落在审计库（表模型 `__audit` / 树模型 `root.__audit`），查 `select * from __audit.audit_log` 之类（具体表名在用例里实测确认）。

## 4. 存储与"双盘"（实测修正）

**六台机器都没有独立 SSD 块设备**：只有 `sda`(953G, `/`) 与 `sdb`(18.2T, `/data`)，两块均为 `PERC H730P Mini` RAID 虚拟盘且 `rotational=1`。
所谓"SSD/HDD 双盘"在本环境只能按**目录约定**：

| 侧 | 实际位置 | 目录 |
| --- | --- | --- |
| HDD（数据盘） | `/dev/sdb1 → /data` | `/data/mpp_test/<部署名>/…` |
| "SSD"（系统盘 sda1） | `/dev/sda1 → /` | `/ssd_data/mpp_test/…`（五台均存在）、`/iotdb_ssd/…`（五台存在但为空） |

⇒ 多盘配置写：

```properties
dn_data_dirs=/data/mpp_test/<db>/data/datanode/data,/ssd_data/mpp_test/<db>/data
dn_wal_dirs=/data/mpp_test/<db>/wal/datanode/wal,/ssd_data/mpp_test/<db>/wal
```

技能里的写法是 `DB_DATA_DIR_2=/ssd_data/mpp_test` + `DB_MULTI_DIR_STRATEGY`（见 conf）。用例报告必须如实写明
"本轮双盘为同一物理介质上的两个目录（无独立 SSD 设备）"，不得声称验证了真实 SSD/HDD 分层。

**空间纪律**：集群 `/data` 已用 5.7–7.0T/19T（33–41%）；大规模用例（≥10 万测点）每例都会写数 GB，
因此每例 `prepare` 前必须 `wipe`（清 data/logs），并在 `full` 轮次结束后确认剩余空间。

## 5. 集群与访问

| 项 | 值 |
| --- | --- |
| ConfigNode | `11.101.10.9`（seed，`:10710`）、`.8`、`.7` |
| DataNode | `.9`、`.8`、`.7`、`.6`、`.10` |
| 驱动方式 | 本机（`ubuntu@172.20.70.17`）→ 各集群机 `root` **免密 key**（`ssh -o BatchMode=yes root@<ip>`）；远端命令需 `source /etc/profile` 才有 `java`/`jps`/`jstack`（`JAVA_HOME=/usr/local/jdk-17.0.8`） |
| 节点间互跳 | **不可用**（root 与 liuzhen 都被拒）⇒ 一切编排必须由本机/客户端逐一发起 |
| 客户端机 | `11.101.10.11`（`liuzhen`/`1qaz2wsx`，仅本机 SSH_ASKPASS 路径可达）——只用于跑 benchmark |
| 许可 | 内置试用码 `03-AAATKKLP-XREBT2T7-2QRCC===`（免机器码、通用、有效期至 2026-12-31），在 seed CN 的 CLI 上 `activate '…';` 一次即激活全集群 |

## 6. benchmark（大规模写入用例）

两个包目前**只是 zip**（内容为 `iot-benchmark-iotdb-<line>/`），首次使用需在客户端机解压：

| 包 | 库线 | 支持模型 |
| --- | --- | --- |
| `benchmark/bm_20260915_46fc572_v13/iot-benchmark-iotdb-1.3-java17.zip` | 1.3（`iotdb-session-1.3.7`） | **仅 tree** |
| `benchmark/bm_20260915_46fc572_v20/iot-benchmark-iotdb-2.0-java17.zip` | 2.0.11（`iotdb-session-2.0.11-*`） | tree + table + table_view + OBJECT |

调用（`-cf` 指向**目录**，目录内需自写 `config.properties`——zip 自带模板全被注释、有效行 0）：

```bash
source /etc/profile
nohup ${BM_HOME}/benchmark.sh -cf ${CONF_DIR} -heapsize 256m -maxheapsize 512m > ${OUT}/bm_<tag>.out 2>&1 &
```

最小键集合：`DB_SWITCH=IoTDB-200-SESSION_BY_TABLET`（v13 用 `IoTDB-130-…`）、`IoTDB_DIALECT_MODE=tree|table`、
`HOST`/`PORT`（逗号分隔 5 台）、`USERNAME`/`PASSWORD`、`DB_NAME`、`IS_DELETE_DATA=false`、`LOOP`、`TEST_MAX_TIME`(ms)、
`DEVICE_NUMBER`、`SENSOR_NUMBER`、`GROUP_NUMBER`、`IoTDB_TABLE_NUMBER`、`SCHEMA_CLIENT_NUMBER`、`DATA_CLIENT_NUMBER`、
`BATCH_SIZE_PER_WRITE`、`DEVICE_NUM_PER_WRITE=1`、`OPERATION_PROPORTION`、`INSERT_DATATYPE_PROPORTION`、`START_TIME`、`POINT_STEP`。

判据（沿用既有约定）：输出抓 `INGESTION <a> <b> <c> <d>`，要求 `rc=0` 且 `a>0`、`c=0`、`d=0`；
另加 CLI 侧 `COUNT`/抽样校验（harness 自己的判据，不依赖 benchmark 自报）。

## 7. 升级用例的服务端包

1.3 线服务端包在集群机上现成可用（无需拷贝）：

```
/data/mpp_test/v1373rc1_0422_dd35474d/iotdb-enterprise-1.3.7-SNAPSHOT-bin.zip
```

（同机另有 `v1361_*`、`v1359_*`、`v1342_*`、`v1341_*`、`v1322_*` 等历史包。）
技能里配置 `PG_UPGRADE_FROM_TARBALL` 指向它；**1.3 包为 `iotdb-enterprise-*` 命名**（与 2.0 的 `timechodb-*` 不同），
解压后的顶层目录名与 `sbin`/`conf` 布局需在首次执行时确认；若 1.3 侧无法用同一许可激活或布局不兼容，
`PG-UPG-*` 整族记 **SKIP 并写明具体原因**，绝不计 PASS。
