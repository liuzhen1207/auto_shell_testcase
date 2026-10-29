# CALIBRATION —— 本环境实测事实（2026-10-20，v20121rc8_1016_ebaf9da）

> 这些数字决定了用例的**规模与阈值**，换环境/换版本后请重新跑一遍本文件里的命令再改用例参数。

## 1. 集群与版本

| 项 | 实测值 |
|---|---|
| 版本 | `2.0.12.1`，`BuildInfo=ebaf9da`，目录名 `v20121rc8_1016_ebaf9da` |
| 形态 | 3CN（`70.5`、`70.4`、`70.26`）+ 5DN（`70.4`、`70.26`、`70.14`、`70.27`、`70.30`） |
| 副本 | `schema_replication_factor=3`、`data_replication_factor=2` |
| 启动后库 | 只有 `root.__audit`、`root.__system`（干净集群判据） |
| DN 堆 | `-Xms20G -Xmx20G`，`MaxDirectMemorySize=2G`，`OFF_HEAP_MEMORY=2G`<br>⚠️ **这 20G 是运维在 `conf/datanode-env.sh` 里手工加 `ON_HEAP_MEMORY="20G"` 得到的，不是发布包默认值**：RC8/RC9 两版发布包该文件逐字节相同（md5 `908b821c...`），`#ON_HEAP_MEMORY="2G"` 在两版里都是注释掉的，上游默认一直是"按机器内存自动算"。未手工设置时（如 RC9 新目录）实测为 `-Xmx12804M` / 12.50G。<br>**因此用例不得硬编码堆大小**，一律从进程 cmdline 读 `-Xmx`（见 `lib/mb.sh` 的 `mb_heap_bytes`） |
| 元数据 | 2 DB、16 DataRegion、14 条 `syncLag` series（5 DN 合计） |
| 认证 | `root` / `TimechoDB@2021`（**不是** `root/root`） |
| 客户端机 | `172.20.70.3`，31G 内存，**无 python3**，有 JDK 17 与 `start-cli.sh` |

## 2. 内存分配基线（堆 20G、`datanode_memory_proportion=1:5:1:1:1:1`）

> 下表是**手工把堆设成 20G 时**（本环境 RC8 的配置）的实测基线，用于理解比例关系。
> 换堆大小后绝对值会等比变化，**比例关系不变** —— 断言应写成比例，不要写绝对字节数。

DN 启动日志 `DataNodeMemoryConfig` 实测：

```
initial allocateMemoryForWrite = 2147483648      (2G)
initial allocateMemoryForRead = 10737418240      (10G)
initial allocateMemoryForSchema = 2147483648
initial allocateMemoryForConsensus = 2147483648
initial allocateMemoryForPipe = 2147483648
initial allocateMemoryForAutoResizingBuffer = 1073741824
allocateMemoryForSchemaRegion = 1073741824       (schema 的 5/10)
allocateMemoryForSchemaCache = 858993459         (4/10)
allocateMemoryForPartitionCache = 214748364      (1/10)
```

派生（内部再分比例）：

- storage engine = write 的主来源；`storage_engine_memory_proportion=8:2` ⇒ write:compaction = 8:2；
- `write_memory_proportion=19:1` ⇒ memtable : timePartitionInfo = 19:1；
- **memtable ≈ 1.9GB**（`1:5:1:1:1:1` 时）⇒ 想靠"写满 memtable"触发刷盘要写 ~760MB（`flush_proportion=0.4`），单条用例不可接受。

**因此用例统一"压 memtable"**：放大 `datanode_memory_proportion` 的分母。实测 `1:1000:1:1:1:1` ⇒ write≈21MB、
memtable≈20MB，`flush_proportion=0.4` ⇒ 阈值≈8MB，写 10MB TEXT 即可触发自动刷盘。

## 3. 写入吞吐（决定用例规模）

| 场景 | 数据量 | 耗时 | 备注 |
|---|---|---|---|
| 树模型 INT64，单会话 20 条语句 × 5000 点 | 10 万点 | **23.5s** | `start-cli.sh < file` 单会话喂多条 |
| 树模型 TEXT 400B × 2 万点 | 8MB | **39s** | 同上 |
| 逐条 `-e` 执行 | — | 极慢 | 每条新起一个 JVM，启动开销主导 |
| 单条 INSERT 784KB（200 行×4KB） | 200 点 | **11.5s** | 可用 |
| 单条 INSERT 1.6MB（400 行×4KB） | 400 点 | 16.5s，**rc=1** | 客户端 `SQLException: Cannot get id for statement after reconnecting` |
| 单条 INSERT 1.96MB（500 行×4KB） | 500 点 | **52s 且 ok=0**（静默失败） | 不可用 |
| 一次喂 10MB SQL | 2600 点 | **客户端 `OutOfMemoryError: Java heap space`**，0 行入库 | 不可用 |

**写入分片口径（已固化进 `lib/common.sh`）**：单条 INSERT 载荷 ≤ 256KB、每次 CLI 调用喂 4 条语句（≈1MB/次）。
按此口径实测：2000 点 × 4KB = 7.8MB，**146s 写完，31 条语句全部成功，2000 行可查**。

**查询输出也有坑**：`select s1 from <device> order by time` 取 2000 行 × 4KB ≈ 8MB 输出时，
CLI 侧只回 **1000 行**（被封顶/截断），据此判"数据丢失"会假 FAIL。
⇒ 数据量与一致性判据一律改用**通配聚合**：`select count(s1) from <db>.**`（输出一行、每序列一列），
既避开截断，也避开"几十 MB bash 变量把用例进程拖进 OOM（rc=137 Killed）"。

结论：**必须用"单会话 + 多语句"**（`mb_bulk_text` / `mb_bulk_int` 内部就是 `session_tree < file.sql`）；
TEXT payload 4KB、单语句 500 行（≈2MB/语句）在本环境稳定。

## 4. 协议

| 项 | 实测 |
|---|---|
| V1 | `org.apache.iotdb.consensus.iot.IoTConsensus`（jar 内 `consensus/iot/IoTConsensus.class`） |
| V2 | **`org.apache.iotdb.consensus.iot.IoTConsensusV2`（配置项必须写这个规范值）**<br>⚠️ 不要写 `org.apache.iotdb.consensus.pipe.IoTConsensusV2`：该 class 在 jar 内确实存在，DataNode 经 `getConsensusImpl()` 归一化后仍能按 V2 启动，但 ConfigNode 的 `isIoTConsensusV2DataRegion()` 是拿原始字符串直接比 `IOT_CONSENSUS_V2`、不做归一化 ⇒ 判定"非 V2 region" ⇒ **不创建 consensus pipe** ⇒ follower 永远收不到数据且无 ERROR（2026-10-22 踩过，详见 `DEFECT_F-10.md`） |
| syncLag 指标 | V1 `iot_consensus{type="syncLag"}`、V2 `iot_consensus_v2{type="syncLag"}` |
| Prometheus | `http://172.20.70.13:9090`，`cluster="defaultCluster"`（= `cluster_name`），scrape 15s |

## 5. 观测手段实测可用性

| 观测点 | 命令/指标 | 实测 |
|---|---|---|
| 内存块分配 | DN 日志 `DataNodeMemoryConfig` | ✅ 每次启动都有 |
| 各池实际占用 | `memory_actual_size{name="StorageEngine-Write-Memtable-DevicePathCache"}` 等 | ✅ 存在（DevicePathCache 实测 81MB） |
| region 未落盘内存 | `data_region_mem_cost{region="DataRegion[N]"}` | ✅ 存在 |
| 刷盘计数 | `flush_memtable_count_total`、`active_memtable_count_total` | ✅ 存在 |
| syncLag | Prometheus 或直连 `http://<dn>:9092/metrics` | ✅ 14 条 series |
| reject | 日志 `Change system to reject status` / `set system to normal status` | ✅（源码 `SystemInfo.java` 的字符串，已核对） |

## 6. 本环境踩到的"环境坑"（影响用例写法）

| 坑 | 实测现象 | 处理 |
|---|---|---|
| **`show configuration` 在树方言下语法错** | `700: no viable alternative at input 'show configuration'` | 一律 `-sql_dialect table`（`sqt`/`sqt_node`） |
| **树方言在具体设备路径上聚合返回空集** | `select count(s1) from root.db.d1.s1` ⇒ `Empty set.`；只有 `from root.db.**` 通配才有值 | 单设备行数用**原始查询数时间戳行**（`mb_rows`/`mb_count_dev`，用 `|时间戳|` 形状判定，不数表头） |
| **框架 `reset_conf.sh` 会把集群配坏** | `conf_orig` 是 tar 包原始配置：`cn_seed=127.0.0.1`、`schema/data_replication_factor=1`；还原后 CN 互相找不到 | 本 skill **不调它**，改为按 `conf/env.conf` 全量生成 `iotdb-system.properties` |
| **框架 `start_cluster.sh` 必打 `801 Authentication failed`** | 它先用 `root/root` 改密码，本版本口令已是 `TimechoDB@2021` | 不影响启动；本 skill 用自己的 `cluster_start` |
| **`start-datanode.sh` 若在 ssh 里直接前台跑会挂住** | ssh 不返回、后续步骤全卡住（首轮 MB-01 卡在"启动集群"18 分钟） | 用 `sudo setsid nohup ... </dev/null &` + `timeout`，再轮询端口就绪（`mb_wait_port_up`） |
| **残留进程会抢 data 目录** | 手动再起一个 DN ⇒ `Conflict is detected in directory ... (ProcessId=xxx)` | 清理阶段必须 `jps` 逐节点校验为 0，再 `pkill -9` 兜底 |
| **kill 掉 run_all 会遗留用例进程** | 遗留的 `mb_xx.sh` 继续停/起集群，与新一轮互相打断 ⇒ 莫名 `rc=137`、写入语句成功数=0 | `tools/run_all.sh` 启动时自动清理遗留用例进程；也可手工 `tools/cleanup_strays.sh` |
| **客户端机无 python3** | `python3: command not found` | Prometheus JSON 解析改用 awk（`prom_series`），不依赖解释器 |
| **`flock -n` 会让"刚跑完"被误判为并发** | 锁文件被上次进程持有/未释放时第二个实例直接退出 | 改为 `flock -w 600`（等锁），并可用 `cleanup_strays.sh` 删陈旧锁 |
| **聚合在树方言只有 `<db>.**` 通配可用** | `from db.d1.s1` / `from db.*.**` 都返回 `Empty set.`，只有 `from db.**` 返回每序列一列 count | 数据量/一致性 SQL 统一用 `mb_data_sql`（`select count(s1) from <db>.**`） |
| **`pkill -f 'mb_xx.sh'` 会误杀本轮用例** | 想在 run_all 启动时"清理遗留用例"，结果把**正在执行的**用例一起 kill（用例命令行本身匹配），表现为 `Killed`（rc=137） | 已删除该兜底；只保留 `flock`，手工清理走 `tools/cleanup_strays.sh`（默认 dry-run） |
| **reject+wal+device 之和 ≥1 会整体回退默认值** | 打 WARN 并回退 0.8/0.1/0.05，`reject_proportion=0.95` 的场景失效 | `reject_proportion` 保持 < 0.85，靠缩小 memtable 造压力 |
| **storage 占比 > 60% 会被限幅** | `dangerous_mode=false` 时 storage engine 最多拿堆的 60%，打 `limited to 60% of the DataNode heap` | MB-02 把"被限幅到 60%"做成断言 |
