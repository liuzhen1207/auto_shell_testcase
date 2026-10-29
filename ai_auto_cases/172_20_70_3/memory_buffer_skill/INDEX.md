# INDEX —— 内存缓冲区 skill 用例索引与覆盖矩阵

> 覆盖依据：`timechodb` master 源码（`DataNodeMemoryConfig` / `SystemInfo` / `IoTDBConfig`）
> + RC8 随包 `conf/iotdb-system.properties.template` 的内存相关键。
> **未能**与飞书《研发文档》逐条对照（应用对该文件夹 `1061004 forbidden`，见 SKILL.md §7）。

## 一、用例清单（执行顺序即编号顺序；MB-14 切协议，故最后）

| ID | 名称 | 被测参数 / 机制 | 造场景 | 主要判据 | 协议 |
|---|---|---|---|---|---|
| MB-01 | 内存分配事实 | `datanode_memory_proportion` → `allocateMemoryForWrite/Read/Schema/Consensus/Pipe/AutoResizingBuffer`、`SchemaRegion/SchemaCache/PartitionCache` | `2:4:1:1:1:1` | 6 个分配值 == 堆×比例（整数精确相等）；无比例告警；写入/刷盘可用 | V1（V2 可复跑） |
| MB-02 | 参数守卫 | `storage_engine_memory_proportion`、`write_memory_proportion`、`reject+wal+device` 之和、storage>60% 限幅 | 一次启动同时注入 4 类非法/越界值 | 4 条 WARN 都在；`Write` == 堆×60%（限幅生效）；回退后其余分配为正；集群可用 | V1 |
| MB-03 | 按比例刷盘 | `flush_proportion`（memtable 阈值 = memtable 大小 × 比例） | memtable≈21MB、阈值≈8MB，写 ~8MB TEXT，不手工 flush | 刷盘计数 +1；TsFile +1；未进 reject；点数不丢 | V1 |
| MB-04 | 定时刷盘（seq） | `enable_timed_flush_seq_memtable`、`seq_memtable_flush_interval_in_ms`、`seq_memtable_flush_check_interval_in_ms` | 阈值 10MB 但只写 <1MB；interval=15s、check=5s | 窗口内不手工 flush 也出现新 TsFile；**对照组**（关闭开关）同窗口不出现 | V1 |
| MB-06 | 拒绝与背压 | `reject_proportion`、`check_period_when_insert_blocked`、`max_waiting_time_when_insert_blocked_in_ms` | memtable≈20MB、flush=1%、reject=2%，2 会话并发写 2990 点（=46×65 满语句） | 出现 `Change system to reject status`（实测 92~244 次）；有明确的背压/拒绝结果；**整语句原子**（点数 % 每语句行数==0，全成功时精确相等）；`set system to normal status` 只作证据 | V1 |
| MB-07 | 刷盘限流并发 | `io_task_queue_size_for_flushing`、`check_period_when_insert_blocked` | io 队列=2、flush=5%，3 写 + 1 查询并发 30 轮 | 写会话不死锁；查询全程无异常；点数 == 成功语句×行数；刷盘发生 | V1 |
| MB-08 | WAL 快照 + 宕机 | `wal_memtable_snapshot_threshold_in_byte`、`max_wal_memtable_snapshot_num`、`wal_buffer_size_in_byte` | 阈值 1MB、快照 4 份；写 ~8MB 不 flush；`kill -9` 一个 DN | 参数回读生效；节点恢复 Running；点数不变（WAL 回放）；一致性通过 | V1 |
| MB-09 | 各内存池比例 | `wal_buffer_queue_proportion`、`device_path_cache_proportion`、`buffered_arrays_memory_proportion` | 三者放大 + 40 设备 TEXT 写入，**刷盘前**采样 | conf 回读；三个池指标存在；DevicePathCache/BufferedArrays 实际占用 >0；无回退告警 | V1 |
| MB-10 | 优雅重启回放 | WAL 回放路径（数据只在 memtable/WAL） | memtable≈100MB、关定时刷盘、写 ~3MB 不落盘，优雅重启 DN | 重启前确实未落盘（TsFile 未增）；重启后点数不变；一致性通过 | V1 |
| MB-13 | 高可用停 DN | DataRegion 2 副本下的写入可用性 | 写入中途停 DN[4]（70.30），再起回 | 停节点期间在线 DN=4、写入仍成功、查询无异常；节点恢复；点数 == 成功语句×行数；一致性通过 | V1 |
| MB-05 | 定时刷盘（unseq） | `enable_timed_flush_unseq_memtable`、`unseq_memtable_flush_interval_in_ms`、`unseq_memtable_flush_check_interval_in_ms` | 先写水位、再写更早且互相重叠的批次 ⇒ 落 unsequence/；只靠定时器落盘 | 窗口内不手工 flush 也新增乱序 TsFile；**对照组**（关闭开关）不新增；点数正确 | V1 |
| MB-16 | flush 线程与数组粒度 | `flush_thread_count`（0=CPU 核数）、`primitive_array_size`（默认 64） | A 相默认；B 相单线程 + 数组 16（放大扩容频次） | 参数回读；两相点数一致；刷盘发生；无异常日志 | V1 |
| MB-18 | 字符串类型推断 | `boolean/integer/floating/nan_string_infer_type` | 不预建序列，靠 INSERT 自动建序列（预建会固定类型）；A 相默认、B 相全 TEXT | 配置生效值；A 相按规则推断（**本版本 FAIL，见 FINDINGS F-01**）；B 相全 TEXT | V1 |
| MB-12 | flush 切分 Chunk | `target_chunk_point_num`（10w）、`target_chunk_size`（1.6MB） | 极小值 500 / 4096 下写 5000 点 + 600 TEXT；再打极值 1/1 | 参数生效；点数完整；文件数不爆炸；极值下节点不崩、数据可查 | V1 |
| MB-17 | 无限时间分区内存可控 | `write_memory_proportion` 第二项（TimePartitionInfo）、`time_partition_interval` | TimePartitionInfo 只给 1/2，时间分区压到 1 小时，写 8 个分区并逐个 flush | 分区目录数增长；出现 `degrade LastFlushTimeMap`（否则 WARN 记"场景未成立"）；**所有分区数据仍可查** | V1 |
| MB-15 | TVList 排序算法 | `tvlist_sort_algorithm` = TIM/QUICK/BACKWARD（默认 TIM） | 三种算法各跑一轮**乱序写入**（逆序 + 步长 7），每轮重启 | 参数生效；点数一致；三种算法查询指纹完全一致 | V1 |
| MB-11 | 顺乱序分离存储 | `enable_separate_data`（默认 true，重启生效） | 三阶段：true 写顺序→sequence/；false 写顺序→unsequence/；false 写乱序→unsequence/ | 参数生效；A 相 seq>0 且 unseq=0；B 相 seq=0 且 unseq>0；点数正确 | V1 |
| MB-14 | V2 协议回归 | `data_region_consensus_protocol_class=...pipe.IoTConsensusV2` | 与 MB-03 同形（memtable≈21MB，写 8MB 等自动刷盘） | 协议配置生效；`iot_consensus_v2{type="syncLag"}` 存在；自动刷盘；点数正确；逐个停 DN 一致性通过 | **V2** |

## 二、参数覆盖矩阵

| 参数（`iotdb-system.properties` 键） | 类型 | 覆盖用例 |
|---|---|---|
| `datanode_memory_proportion` | 6 段比例 | MB-01（正常）、MB-02（越界限幅） |
| `storage_engine_memory_proportion` | 2 段比例（8:2） | MB-02（非法回退） |
| `write_memory_proportion` | 2 段比例（19:1） | MB-02（非法回退） |
| `flush_proportion` | double（0.4） | MB-03、MB-04、MB-07、MB-08、MB-10、MB-13、MB-14 |
| `reject_proportion` | double（0.8） | MB-02（和越界）、MB-06、MB-07、MB-09 |
| `wal_buffer_queue_proportion` | double（0.1） | MB-02、MB-09 |
| `device_path_cache_proportion` | double（0.05） | MB-02、MB-09 |
| `buffered_arrays_memory_proportion` | double（0.6） | MB-09 |
| `wal_buffer_size_in_byte` | long（32MB） | MB-08、MB-09 |
| `wal_memtable_snapshot_threshold_in_byte` | long（8MB） | MB-08 |
| `max_wal_memtable_snapshot_num` | int（1） | MB-08 |
| `enable_timed_flush_seq_memtable` / `seq_memtable_flush_interval_in_ms` / `seq_memtable_flush_check_interval_in_ms` | bool/int | MB-04 |
| `enable_timed_flush_unseq_memtable` / `unseq_*` | bool/int | MB-10（关闭，保证不落盘）；**未单独建成用例**，可作为 MB-04 的 unseq 对称用例扩展 |
| `check_period_when_insert_blocked` | int（50） | MB-06、MB-07 |
| `max_waiting_time_when_insert_blocked_in_ms` | int（10000） | MB-06 |
| `io_task_queue_size_for_flushing` | int（10） | MB-07 |
| `primitive_array_size` | int（64） | 写入路径隐式覆盖（未单独判定） |
| `enable_timed_flush_unseq_memtable` / `unseq_*` | bool/int | MB-05 |
| `target_chunk_point_num` | long（100000） | MB-12 |
| `target_chunk_size` | long（1600000） | MB-12 |
| `flush_thread_count` | int（0=CPU 核数） | MB-16 |
| `primitive_array_size` | int（64） | MB-16（并含 MB-04 前的加载路径） |
| `boolean/integer/floating/nan_string_infer_type` | enum | MB-18 |
| `enable_separate_data` | bool（true） | MB-11 |
| `tvlist_sort_algorithm` | enum TIM/QUICK/BACKWARD | MB-15 |
| `time_partition_interval` | long | MB-17 |
| `write_memory_proportion` 第二项（TimePartitionInfo） | ratio | MB-17 |
| `data_region_consensus_protocol_class` | string | MB-01~MB-13（V1）+ MB-14（V2） |

## 三、观测手段

| 观测点 | 手段 |
|---|---|
| 内存块初始分配 | DN 启动日志 `DataNodeMemoryConfig` 的 `initial allocateMemoryForXxx = N` |
| 实际占用 | `:9092/metrics` → `memory_actual_size{name="StorageEngine-Write-Memtable-*"}` |
| memtable 未落盘内存 | `data_region_mem_cost{region=...}` |
| 刷盘 | `flush_memtable_count_total`、`active_memtable_count_total`、TsFile 计数（`find`） |
| 拒绝/背压 | 日志 `Change system to reject status` / `set system to normal status` / `WriteProcessRejectException` |
| 同步 | `{__name__=~"iot_consensus(_v2)?",type="syncLag"}`（Prometheus `172.20.70.13:9090`，`cluster="defaultCluster"`） |
| 副本一致性 | 全在线取基准 → 逐个停 1 个 DN（共 5 轮）→ 剩余副本查询结果与基准**完全一致** |
| 异常日志 | `ERROR|WARN` 行命中 `COMMON_ERR_PAT`（NPE/越界/类型转换/并发修改/运行时异常等），再排除已知正常日志 |

## 四、后续可扩展（同一骨架）

1. **unseq 定时刷盘**（MB-05）：`enable_timed_flush_unseq_memtable` 对称用例；
2. **跨空间/合并与内存缓冲区联动**：`compaction` 与 `memtable` 抢 write memory 时的限幅行为；
3. **benchmark 场景**：用 `benchmark/bm_20251017_b6be9bd` 做吞吐基线，按版本对比（当前只做功能回归）；
4. **文档对齐**：拿到飞书《研发文档》后，在本表加一列"文档条目"，逐条勾掉未覆盖项。

## 五、研发文档条目 → 用例映射（飞书文件夹 SCOPfmSRplJwkxdZ2aycRBZZnhe）

共 8 篇文档，已全部抓取到 `../feishu_docs/membuf/`（原始 Markdown）。

### 5.1 《V1.1.0.1-内存缓冲区-内存缓冲区-需求分析》配置项逐条覆盖

| 文档条目（配置项） | 类型/默认 | 生效方式 | 覆盖用例 |
|---|---|---|---|
| `enable_timed_flush_seq_memtable` | bool/true | 热加载 | MB-04 |
| `seq_memtable_flush_interval_in_ms` | long/600000 | 热加载 | MB-04 |
| `seq_memtable_flush_check_interval_in_ms` | long/30000 | 热加载 | MB-04 |
| `enable_timed_flush_unseq_memtable` | bool/true | 热加载 | MB-05 |
| `unseq_memtable_flush_interval_in_ms` | long/600000 | 热加载 | MB-05 |
| `unseq_memtable_flush_check_interval_in_ms` | long/30000 | 热加载 | MB-05 |
| `tvlist_sort_algorithm` | String/TIM | 重启 | MB-15 |
| `target_chunk_point_num` | long/100000 | 重启 | MB-12 |
| `target_chunk_size` | long/1600000 | 重启 | MB-12 |
| `flush_thread_count` | int/0 | 重启 | MB-16 |
| `write_memory_proportion` | ratio/19:1 | 重启 | MB-02（非法回退）、MB-17（TimePartitionInfo 项）、MB-01 |
| `primitive_array_size` | int/64 | 重启 | MB-16 |
| `flush_proportion` | float/0.4 | 重启 | MB-03、MB-07、MB-08、MB-10、MB-13、MB-14 |
| `reject_proportion` | float/0.8 | 重启 | MB-06、MB-07、MB-09；MB-02（和越界回退） |
| `check_period_when_insert_blocked` | int/50 | 重启 | MB-06、MB-07 |
| `io_task_queue_size_for_flushing` | int/10 | 重启 | MB-07 |
| `device_path_cache_proportion` | float/0.05 | 重启 | MB-09；MB-02（和越界） |

> 文档"自测及测试场景建议"两条：
> ① 「测试诸如 enable_timed_flush_seq_memtable、seq_memtable_flush_interval_in_ms 等配置是否生效」→ MB-04 / MB-05；
> ② 「测试诸如 tvlist_sort_algorithm、target_chunk_point_num 等配置在各种负载下对读写性能的影响」
>    → MB-15 / MB-12（功能与语义部分；**性能倍数**需配合 benchmark，见 §六）。

### 5.2 《技术设计》章节覆盖

| 设计章节 | 关键点 | 覆盖用例 |
|---|---|---|
| §模块设计·写入 MemTable 流程 | `enableMemControl` → 申请内存 → 记 WAL → 写 memtable → 更新 startTime/endTime | MB-01、MB-08、MB-10 |
| §写入内存管理 | TimePartitionInfo 内存剔除（`degradeLastFlushTime`）、优先级规则 | MB-17 |
| §对齐时间序列存储（方案 2 列式） | VectorTVList / bitmap / rowIndex | 间接覆盖（TEXT/多类型写入路径 MB-09/MB-18）；**共享时间戳对齐列**未单独立用例，可扩展 |
| §数据类型推断 | 四类 string 推断规则 | MB-18（**发现 F-01**） |
| DataRegion / TsFileProcessor / MemTable / TVList | 时间分区与 TsFileProcessor 一一对应、memtable 非线程安全 | MB-04/MB-05（定时器）、MB-17（分区）、MB-07（并发） |
| OOM 防护目标「无限时间分区不 OOM」 | 内存可控 | MB-17、MB-09 |

### 5.3 《顺乱序分离存储》两篇

| 文档条目 | 覆盖用例 |
|---|---|
| `enable_separate_data`（默认 true，重启） | MB-11 |
| 「打开后分顺序/乱序两个目录；否则只存储乱序文件夹」 | MB-11 A/B 相 |
| 「测试不同乱序率下的读写性能」 | MB-11 C 相做功能；性能倍数需 benchmark |

### 5.4 《flush 时按序列点数和大小切分 Chunk》两篇

| 文档条目 | 覆盖用例 |
|---|---|
| `target_chunk_point_num`、`target_chunk_size` | MB-12 |
| `avg_series_point_number_threshold` 被移除 | MB-12 断言该键不存在（selftest ⑥ 已核） |
| 三个目标：内存查询性能 / 减少频繁 flush / 避免超大 chunk | MB-12 用"文件数不爆炸 + 数据完整 + 极值不崩"覆盖前两项；超大 chunk 的查询耗时需 benchmark |

### 5.5 《软件测试文档》里值得继承的测试类型

文档列了 6 类：部署测试、功能正确性、性能、异常恢复与故障模拟、老化长测、安装与手册。本 skill 覆盖：

| 文档类型 | 本 skill 覆盖 |
|---|---|
| 功能正确性 | MB-01~MB-18 全部 |
| 异常恢复与故障模拟 | MB-08（kill -9 + WAL 回放）、MB-10（优雅重启）、MB-13（停 DN） |
| 性能 | 只做功能侧；吞吐/延迟/查询耗时的倍数对比见 §六（需 benchmark） |
| 老化长测 | **未覆盖**（需单独的长跑用例） |
| 部署/安装手册 | 不属于本 skill 范围 |

## 六、性能对比怎么做（文档 §测试内容及过程记录 的口径）

《软件测试文档》的性能表用的是 **iot-benchmark**，口径是 `points/s`，场景包括：
1C1D 顺序/乱序（common / template）、接口写入（Tablet / Record / Records）、
3C5D 集群读写（顺序 common_w / common_rw、乱序 common_rw）、1 万点最新值查询（Table mode）。

本环境 benchmark 已就位：`/data1/iotdb/testcase/MigrateRegionTest/benchmark/bm_20251017_b6be9bd`
（含 `conf/config.properties`、`benchmark.sh`、`cli-benchmark.sh`、多套 `lt_10type_user*` 配置）。

建议的对比跑法（同一硬件、同一数据规模，只改内存缓冲区参数）：

```bash
BM=/data1/iotdb/testcase/MigrateRegionTest/benchmark/bm_20251017_b6be9bd
# 用 bm 自带 conf 改：HOST/PORT、DB_SWITCH=IoTDB-200-SESSION_BY_TABLET、LOOP、DEVICE_NUMBER、SENSOR_NUMBER
bash $BM/benchmark.sh           # 单机/集群写入
bash $BM/cli-benchmark.sh       # CLI 侧
```

每组参数（`flush_proportion` 0.4 / 0.5、`target_chunk_point_num` 10k / 100k、
`tvlist_sort_algorithm` 三种、`enable_separate_data` true/false）跑 3 次取中位数，
与"默认参数"基线比 `points/s`。**这部分不在本 skill 的自动判定范围内**（避免把性能波动写成 FAIL），
建议后续单独做 `perf` 子集，判据用"不低于基线 X%"而非绝对阈值。

---

## 附：缺陷报告

| 文件 | 内容 |
|---|---|
| [docs/DEFECT_F-09.md](docs/DEFECT_F-09.md) | BACKWARD 排序：查询抛 301「blocks should never be zero」+ 数据丢失（含 RC9 完整栈与源码定位） |
| [docs/RCA_IOTV2_PIPE.md](docs/RCA_IOTV2_PIPE.md) |
| [docs/ANALYSIS_WRITE_SLOW.md](docs/ANALYSIS_WRITE_SLOW.md) |
| [docs/REPORT_RC10.md](docs/REPORT_RC10.md) | RC10（c60ce63）双协议全量结果：IoTConsensus 21/24、IoTConsensusV2 17/24，含耗时与失败明细 | 写入慢的根因：CLI 经 JLine 逐字符处理脚本输入（客户端 CPU 打满、约 57KB/s），DataNode 空闲；非死锁、非内存、与 V1/V2 无关 |
 根因分析：V2 复制通道未建立——归一化只覆盖 DN 实例化与持久化属性，唯 ConfigNode 的 V2 region 判定漏做；含在线取证与诊断方法 |
| [docs/DEFECT_F-10.md](docs/DEFECT_F-10.md) | IoTConsensusV2 BATCH：DataRF=2 实际单副本，停该副本数据不可见且不自愈；syncLag=0 与事实相反 |
| [docs/DEFECT_F-07.md](docs/DEFECT_F-07.md) | F-07 非法内存比例致 DataNode 起不来：RC9 源码定位、真实调用栈、5 种非法写法实测、修复补丁、验收矩阵 |
| [docs/PLM_TICKET_F-07_LOGGING.md](docs/PLM_TICKET_F-07_LOGGING.md) | **PLM 提单（可直接提交）**：启动失败异常未写入 `logs/` —— 配置隔离复现、对照组证据、根因（`prepare()` 在日志保护之外）、修复建议、7 条验收标准 |
