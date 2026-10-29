# 测试发现记录（本轮从研发文档 + 实测中得到的结论）

> 每条都写明「对应文档条目 → 用例 → 实测 → 结论/待确认」，便于直接回填研发或 PLM。


## 索引
## 版本回归状态（RC9 复测，2026-10-22）

对 `v20121rc9_1020_d206dc2` 全量复测后，各发现的**修复状态**如下：

| 编号 | 问题 | RC8 | RC9 | 结论 |
|---|---|---|---|---|
| F-01 | SQL INSERT 自动建序列未按 `string_infer_type` 推断 | 存在 | **仍存在** | 未修复 |
| F-07 | 非法 `storage_engine_memory_proportion` 致 DN 起不来（NPE） | 存在 | **仍存在** | 未修复（`return` 未改为 `break`） |
| F-08 | `datanode_memory_proportion` 的 60% 上限未生效 | 存在 | **仍存在** | 未修复 |
| F-09 | `tvlist_sort_algorithm=BACKWARD` 数据查不到 | 存在 | **仍存在** | 未修复（三次复现） |
| F-10 | IoTConsensusV2 不刷盘 + 副本不可见 + 吞吐劣化 | 存在 | **仍存在** | 未修复（V2/V1 = 13.0%） |
| — | 顺乱序分离乱序负载 P99 恶化 114% | 未出现 | **新出现** | RC9 新增性能问题 |

详细数据见 [REPORT_RC9.md](REPORT_RC9.md)。



| 编号 | 标题 | 严重级 | 性质 |
|---|---|---|---|
| F-01 | SQL INSERT 自动建序列未按 `*_string_infer_type` 推断 | 中 | 待研发确认 |
| F-02 | 文档 `target_chunk_size` 默认值与本版本差 10 倍 | 低 | 文档不一致 |
| F-03 | `avg_series_point_number_threshold` 已按文档移除 | — | 与文档一致 |
| F-04 | 顺乱序分离存储落盘目录验证通过 | — | 已验证 |
| F-05 | `set system to normal status` 日志不必然打印 | 低 | 判据修正 |
| F-11 | 环境侧（非产品）问题汇总 | — | 环境问题 |
| **F-07** | 非法 `storage_engine_memory_proportion` 让 DN 起不来（NPE） | **高** | **产品缺陷** |
| F-08 | `datanode_memory_proportion` 的 60% 上限在本构建未生效 | 中 | 待研发确认 |
| **F-09** | `tvlist_sort_algorithm=BACKWARD` 下数据查不到 | **高** | **待研发确认（疑缺陷）** |
| **F-10** | IoTConsensusV2 不刷盘 + 停 DN 后副本不可见 + 吞吐 -91.9% | **高** | **待研发确认** |

## F-01 SQL INSERT 自动建序列未按 `*_string_infer_type` 推断（待研发确认）

| 项 | 内容 |
|---|---|
| 文档依据 | 《V1.1.0.1-内存缓冲区-内存缓冲区-需求分析》配置表 + 《技术设计》§数据类型推断：写入的 String 按 `boolean/integer/floating/nan_string_infer_type` 推断为具体类型 |
| 用例 | `MB-18` |
| 配置 | `boolean_string_infer_type=BOOLEAN`、`integer_string_infer_type=DOUBLE`、`floating_string_infer_type=DOUBLE`、`nan_string_infer_type=DOUBLE` |
| 生效值确认 | 表方言 `show configuration` 返回上述值（说明配置确实生效） |
| 复现 | `create database root.inf2;` 后 `insert into root.inf2.d2(time,s1) values (1000,'123');` |
| 实测 | 自动建出的 `root.inf2.d2.s1` 类型 = **TEXT**（'true'→TEXT、'3.14'→TEXT、'NaN'→TEXT 同样都是 TEXT） |
| 对照 1 | 单行 INSERT（`visitInsert` 路径，源码里明确 `setNeedInferType(true)`）与多行 INSERT 结果相同，都是 TEXT |
| 对照 2 | 预先建 DOUBLE 序列再写字符串 `'123'` → 明确报 `507 data type is not consistent, input '123', registered DOUBLE`（说明值确实是 String，没有在解析期转成数值） |
| 结论 | 该路径上「字符串 → 类型推断」没有生效。可能是：(a) 产品缺陷；(b) 只有 Session/CSV/JSON/MQTT 等"外部格式写入"才走推断，SQL 字符串字面量不走。**需研发确认预期** |
| 影响 | 与需求文档"写入内存缓冲区前对字符串做可选类型推断"的描述不一致；用户用 SQL 写数字字符串会得到 TEXT 序列，后续无法直接做数值聚合 |

## F-02 文档中 `target_chunk_size` 默认值与本版本不一致

| 项 | 内容 |
|---|---|
| 文档 | 《V2.0.5.1-…切分 Chunk-需求分析》写 `target_chunk_size` 默认 **16M** |
| 实测 | v20121rc8 模板 `target_chunk_size=1600000`（≈1.6MB），源码 `IoTDBConfig.java:539` 也是 `1600000L` |
| 结论 | 文档与实现差 10 倍。**以代码为准**，用例按实际默认值写；建议文档修订 |

## F-03 `avg_series_point_number_threshold` 已按文档移除

| 项 | 内容 |
|---|---|
| 文档 | 《V2.0.5.1-…切分 Chunk-需求分析》明确"旧配置项 `avg_series_point_number_threshold` 将被移除" |
| 实测 | v20121rc8 模板中确实**不存在**该键（`grep` 无匹配） |
| 结论 | 与文档一致，`MB-12` 据此只测 `target_chunk_*` |

## F-04 顺乱序分离存储的落盘目录已验证

| 项 | 内容 |
|---|---|
| 文档 | 《顺乱序分离存储-需求分析》：`enable_separate_data` 打开后分 `sequence/`/`unsequence/` 两个目录；关闭后"数据只存储在乱序文件夹" |
| 实测 | 目录结构为 `data/datanode/data/{sequence,unsequence}/<database>/<regionId>/<timePartitionId>/*.tsfile`；默认 `enable_separate_data=true` |
| 用例 | `MB-11`（三阶段：true→sequence、false→unsequence、false 下乱序数据仍 unsequence） |

## F-05 MB-06 的 `set system to normal status` 日志不必然打印（判据修正）

| 项 | 内容 |
|---|---|
| 现象 | 内存压力场景下 `Change system to reject status` 出现 92~244 次，但恢复后 `set system to normal status` 一行都没出现，而 `regionMemCost` 确实从 16MB 回落到 10MB |
| 源码 | `SystemInfo.resetStorageGroupStatus()` 里该 INFO 只在特定分支打印（`totalStorageGroupMemCost >= FLUSH_THRESHOLD && < REJECT_THRESHOLD && rejected`） |
| 处置 | 用例把"内存确实释放"作硬判据，normal 日志行降级为 WARN 证据 |


## F-07 【严重】非法 `storage_engine_memory_proportion` 让 DataNode 直接起不来（NPE），且 WARN 文案与行为不符

> 📄 **完整缺陷报告（RC9 源码定位、真实调用栈、修复补丁）见 [DEFECT_F-07.md](DEFECT_F-07.md)**
> 📄 **PLM 提单（日志缺失专项）见 [PLM_TICKET_F-07_LOGGING.md](PLM_TICKET_F-07_LOGGING.md)**
>
> **补充（2026-10-22 严格复测）**：研发确认"配置非法时拒绝启动"属预期行为，但实测该路径的
> `ExceptionInInitializerError` **未写入 `logs/`**（`log_datanode_error.log` 的 size/md5 完全不变，
> `all.log` 无 ERROR，异常仅在启动脚本 stdout），已单独提 PLM 单。
> 对照组 `storage_engine_memory_proportion=a:b`（解析期异常）则**能正常写入** `error.log` —— 同一函数、同类错误、日志行为不一致。

| 项 | 内容 |
|---|---|
| 严重级别 | **高**（配置写错 → 节点起不来；WARN 明确承诺 "use default value" 但实际没兜底） |
| 需求依据 | 《内存缓冲区-需求分析》配置表（各比例项取值范围）；《技术设计》§写入内存管理 |
| 用例 | `MB-19`（专门暴露此问题）；`MB-02` 已把该取值移出，避免整轮被它卡死 |
| 复现配置 | `storage_engine_memory_proportion=0:10`（其余用默认） |
| 实测现象 | DataNode 启动即崩，集群 5 个 DN 全部起不来（只剩 3 个 CN）：<br>`Exception in thread "main" java.lang.ExceptionInInitializerError`<br>`  at ...DataNodeDevicePathCache.getInstance(DataNodeDevicePathCache.java:58)`<br>`Caused by: java.lang.NullPointerException: Cannot invoke "org.apache.iotdb.commons.memory.MemoryManager.exactAllocate(String, MemoryBlockType)" because the return value of "org.apache.iotdb.db.conf.DataNodeMemoryConfig.getDevicePathCacheMemoryManager()" is null` |
| 同时出现的日志 | `WARN DataNodeMemoryConfig:413 - The value of storage_engine_memory_proportion is illegal, use default value 8:2 .`（**说了会用默认值，但实际没继续**） |
| 根因（源码定位） | `DataNodeMemoryConfig.initStorageEngineAllocate()`：<br>• 第 ~560 行算出默认 `writeMemorySize/memtableMemorySize/...`；<br>• `storage_engine_memory_proportion` 分量 `<=0` 时执行 `LOGGER.warn(...); **return**;`；<br>• 而 `writeMemoryManager / compactionMemoryManager / memtableMemoryManager / timePartitionInfoMemoryManager / devicePathCacheMemoryManager / bufferedArraysMemoryManager / walBufferQueueMemoryManager` 这 **7 个 manager 的创建语句全部在这个 return 之后**（源码 ~600-620 行）；<br>• `write_memory_proportion` 的同类守卫（~579 行）在 `writeMemorySize` 计算之后、manager 创建之前，位置相对安全；但 `storage_engine` 的 `return` 会连 `write_memory_proportion` 的解析一起跳过。<br>⇒ 所有 manager 保持 `null`，`DataNodeDevicePathCache` 初始化时 `.exactAllocate()` 直接 NPE。 |
| 影响 | 用户在 `iotdb-system.properties` 里把比例写错（写 0 或负数是最常见的笔误），得到的不是"回退默认值继续跑"，而是**整个 DataNode 起不来**；且日志里先打了一条"已回退"的 WARN，误导排查方向。 |
| 建议修复 | 把这两处 `return` 改成 `break`/跳过解析（保留前面已算好的默认值），或在方法末尾统一兜底创建各 manager；并对 `write_memory_proportion` 做同样检查。 |
| 附带问题 | `MB-02` 原设计把 4 类非法值放在一条用例里，其中一个会把集群打死 ⇒ 后续断言全部无法执行、且 `wait_cluster_ready` 白等 600s。已在 `cluster_start` 里加"启动日志出现 main 线程异常即快速失败"，并把该取值拆到 `MB-19` 单独暴露。 |



## F-08 `datanode_memory_proportion` 的 60% storage 上限在本构建未生效（待确认是否版本差异）


| 项 | 内容 |
|---|---|
| 参考 | master 源码 `DataNodeMemoryConfig.isStorageEngineMemoryCapped()`：`dangerous_mode=false` 且 `storage段 × 5 > 比例总和 × 3`（即 storage > 60%）时，把 storage engine 限幅到堆的 3/5，并打 `The StorageEngine proportion in datanode_memory_proportion exceeds 60% ...` |
| 实测（v20121rc8_1016_ebaf9da，堆 20G） | `9:1:1:1:1:1`（storage=9/14≈64.3%，已超 60%）→ `Write = 13805252022 = 堆 × 9/14`，**无限幅告警**<br>`12:1:1:1:1:1`（storage=12/17≈70.6%）→ `Write = 15158708103 = 堆 × 12/17`，**无限幅告警** |
| 对照 | `2:4:1:1:1:1`（storage=20%）→ `Write = 4294967296 = 堆 × 2/10`，符合"按比例直接分配" |
| 结论 | 本构建把 `datanode_memory_proportion` **按比例直接分配，未套用 60% 上限**。要么该构建与 master 源码不一致（rc8 早于该逻辑），要么 `dangerous_mode` 默认值不同。**需研发确认预期**；若上限是设计意图，则本构建缺失该保护（用户配出 storage 占 80% 会把 query/schema 挤到很小） |
| 用例处置 | `MB-02` ③ 改成**自洽判据**：有告警就必须限幅到 3/5、无告警就必须等于 raw 比例；并在日志里记录本构建属于哪一种，避免绑定某个版本的实现细节。 |

## F-09 【严重】`tvlist_sort_algorithm=BACKWARD` 下数据查不到（2000 点写入后 count=0）

| 项 | 内容 |
|---|---|
| 严重级别 | **高**（数据写入报成功但查不到，属数据可见性/正确性） |
| 文档依据 | 《内存缓冲区-需求分析》配置表：`tvlist_sort_algorithm` 可选 TIM / QUICK / BACKWARD，默认 TIM |
| 用例 | `MB-15` |
| 复现配置 | `tvlist_sort_algorithm=BACKWARD`，其余默认 |
| 复现步骤 | 建库建序列（int64）→ 单条 INSERT 写 2000 点、时间戳**逆序 + 步长 7** → `select count(s1) from db.**` |
| 实测 | 写入语句返回 `The statement is executed successfully.`；`select count(s1)` = **0**；`flush;` 后再查仍为 **0**；`select s1 from db.d1 order by time` 返回 `Empty set.` |
| 对照 | 同一份 SQL 在 `TIM` 与 `QUICK` 下：count = **2000**，两者查询结果指纹完全一致（`b89017e84a6fc523618d6f8af02eb8e3`） |
| 重复性 | **两次独立完整运行（16:35、17:08）均复现**，且两次都先跑通 TIM/QUICK 再跑 BACKWARD，排除顺序污染 |
| 现状 | 我另起的定向 BACKWARD 验证脚本因环境长跑被中断未跑完，因此暂记 **"待研发确认"**，未直接下"数据丢失"结论 |
| 建议排查方向 | `TVListSortAlgorithm.BACKWARD` 的排序/写回路径：逆序写入时 sorted 标记与 rowIndex 是否一致、flush 时是否把未排序 list 当作已排序写出 |
| 临时规避 | 生产环境暂不建议使用 BACKWARD；回归时用 `MB-15` 盯住 |

## F-10 `data_region_consensus_protocol_class` 类名不一致导致副本静默失去冗余（P2，**已降级**）

> ⚠️ **本条已更正（2026-10-22 16:15）**。前一版把它记成"V2 副本复制功能失效（P0）"，**是错的**——
> 根因是测试侧把类名写成了 `...consensus.pipe.IoTConsensusV2`。换成规范值
> `...consensus.iot.IoTConsensusV2` 后复制完全正常（两个副本 TsFile 一致、CN 日志出现 28 条 pipe 记录）。
> 完整更正后的报告见 [DEFECT_F-10.md](DEFECT_F-10.md)。

| 项 | 内容 |
|---|---|
| 严重级别 | **P2**（配置一致性 / 可观测性；不影响读写，不丢数据） |
| 现象 | 配成 `...pipe.IoTConsensusV2` 时，DataNode 正常按 V2 启动、写入查询正常，但 ConfigNode 判定"非 V2 region"⇒ **从不创建 consensus pipe** ⇒ follower 永远收不到数据；ERROR=0、`syncLag=0`、`error.log` 0 字节 |
| 根因 | `ConsensusFactory.normalizeConsensusProtocolClass()` 只在 `getConsensusImpl()`（DN 侧）被调用；ConfigNode 的 `RegionMaintainHandler.isIoTConsensusV2DataRegion()` 直接 `IOT_CONSENSUS_V2.equals(原始字符串)`，**不归一化** |
| 实测对照 | `pipe.` 值：70.14 有 3 个 TsFile、70.30 为 0、CN pipe 日志 0 条<br>`iot.` 值：两副本各 3 个同尺寸 TsFile、CN pipe 日志 28 条 |
| 建议 | ConfigNode 侧补一次 `normalizeConsensusProtocolClass`；并对"副本就绪"加可观测性（`TsFileSize=Unknown` 未收敛即告警，`syncLag` 未建 pipe 时报 -1） |
| 测试侧已修 | `lib/common.sh` 的 `mb_consensus_class()`、MB-14/P-05 的断言与注释、`CALIBRATION.md` |

**受影响并作废的既有结论**：MB-14（V2 功能）与 P-05（V1 vs V2 性能）都是在错误配置下跑的，需用正确配置重跑。



## F-12 【测试侧】性能用例把 P999 当成 P99，导致 P-03 误判 FAIL

| 项 | 内容 |
|---|---|
| 性质 | **测试侧缺陷**（非产品问题），影响历史性能结论的数值准确性 |
| 现象 | benchmark CSV 的延迟矩阵表头为 `Operation,AVG,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,SLOWEST_THREAD`，P99 是第 10 列、P999 是第 11 列；`lib/perf.sh` 写死取 `$11`，于是所有用例的「P99」实际是 **P999** |
| 影响 | P-01 记录 45.87 ms 实为 P999（真 P99 = 7.54 ms）；**P-03 因此把「P999 从 44.45 涨到 95.35」误报成「P99 恶化 +114%」并判 FAIL**，真 P99 为 7.26 vs 7.15（+1.5%） |
| 更正后结论 | 按原判据（吞吐 -30% / P99 +50%）复核，**P-03 两个场景均应 PASS** |
| 已修 | `lib/perf.sh` 改为按表头名定位 `P99` 列（`PERF_LAT_COL`），不再写死列号 |
| 遗留 | 历史 `perf_*.csv` 与 `PERF.md` / `REPORT_RC9.md` 中的「P99」均为 P999，已在两份文档顶部加更正说明 |
| 教训 | 解析第三方 CSV 不要写死列号，按表头名定位；跨列比较前先打印表头核对一次 |

## F-11 环境侧（非产品）问题汇总

见 `KNOWN_ISSUES.md`：客户端 CLI 单条 INSERT 上限、大结果集截断、`rc=137` 孤儿进程、`reset_conf.sh` 不可用等。
