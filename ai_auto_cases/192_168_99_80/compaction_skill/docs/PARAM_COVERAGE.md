# 合并参数 × 用例覆盖清单（源码驱动，RC6 = 本地源码树 `7ae8713e`）

生成背景：用户 2026-10-13 要求"**根据源码，不同参数功能应该覆盖最基础的合并场景**，17 个用例太少"。
本清单把 `iotdb-system.properties.template` 里 **35 个 compaction 键**逐个对照源码的**使用点**，
标出"覆盖用例 / 可观测判据"；新增用例 **CO-18 ~ CO-32**（15 条）按此表补齐，用例总数 **17 → 32**。

## 一、参数逐键覆盖表

| # | 键（模板名） | 源码使用点（RC6） | 覆盖用例 | 判据/备注 |
| --- | --- | --- | --- | --- |
| 1 | `enable_seq_space_compaction` | `CompactionScheduler:146` | CO-15 段 1 | 8 组合矩阵，该跑的跑/不该跑的不跑 |
| 2 | `enable_unseq_space_compaction` | 同上 | CO-15 段 1 | 同上 |
| 3 | `enable_cross_space_compaction` | `CompactionScheduler:246` | CO-15 段 1 / CO-17 段 3 | cross 只受本开关控制 |
| 4 | `enable_auto_repair_compaction` | `SizeTieredCompactionSelector:217-235`；`AbstractCompactionTask:550-557` | **CO-32** | 开/关两相合并都正确、都不误报 `RepairUnsortedFileCompactionTask`（真造未排序文件需 load 路径，超出 SQL 范围，如实记录） |
| 5 | `cross_selector` | `RewriteCrossSpaceCompactionSelector` | CO-09 / CO-04 / CO-17 | 模板只有 `rewrite` 一个合法值 |
| 6 | `cross_performer` | `CrossSpaceCompactionPerformer` | CO-16 段 3 | read_point/fast 都完成且取值正确 |
| 7 | `inner_seq_selector` | `InnerSequenceCompactionSelector:52-60` | CO-16 段 1 / **CO-17** | multi_target→`NewSizeTiered`（读 gap/上限）；single_target→经典 |
| 8 | `inner_seq_performer` | `InnerSeqCompactionPerformer` | CO-16 段 1 / CO-24 | read_chunk/fast 都完成 |
| 9 | `inner_unseq_selector` | `InnerUnsequenceCompactionSelector` | CO-16 段 2 / **CO-19** | 乱序空间同样读 gap/文件数上限（CO-19 用文件数上限=2 + gap 0→1 验证） |
| 10 | `inner_unseq_performer` | `InnerUnseqCompactionPerformer` | CO-16 段 2 | read_point/fast |
| 11 | `compaction_priority` | 候选队列比较器（`CompactionTaskManager:76-78`） | **CO-18** | `compaction_thread_count=1` 去竞态，三种取值验"第一个完成的是 inner 还是 cross" |
| 12 | `candidate_compaction_task_queue_size` | `CompactionTaskManager:76-78 / 247-253 / 266-277` | **CO-22** | 队列=1 高压场景最终仍全部合并、无卡死；退出选择用 `5*(max-size)>=size` |
| 13 | `target_compaction_file_size` | `InnerSpaceCompactionTask:314-320`；选择阶段 `singleFileSizeThreshold` | **CO-20** | 6 设备场景下 1KB vs 2GB 的产物文件数对照 |
| 14 | `inner_compaction_total_file_size_threshold` | `NewSizeTieredCompactionSelector:86/234-236/281-285` | **CO-21** | 阈值=2KB ⇒ 装不下两个文件 ⇒ 不合并；10KB ⇒ 4→1 |
| 15 | `inner_compaction_total_file_num_threshold` | 同上 `:284` | CO-17 段 2 / CO-19 | 单任务文件数上限 |
| 16 | `max_level_gap_in_inner_compaction` | `NewSizeTieredCompactionSelector:238` | CO-17 段 1 / CO-19 | 层级差边界（seq 与 unseq 两个空间） |
| 17 | `chunk_size_lower_bound_in_compaction` | `ChunkCompactionPerformer` | CO-16 段 4 | 小 chunk 反序列化成点 |
| 18 | `chunk_point_num_lower_bound_in_compaction` | 同上 | CO-16 段 4 | 同上 |
| 19 | `inner_compaction_candidate_file_num` | `NewSizeTiered:85`；`SizeTiered:106` | CO-09 / CO-17 段 2 | 提交门槛（非活跃分区可绕过） |
| 20 | `max_cross_compaction_candidate_file_num` | `RewriteCrossSpaceCompactionSelector:100` | CO-17 段 3 | 每任务 unseq 数 1 / 3 / 1 对照 |
| 21 | `max_cross_compaction_candidate_file_size` | 同上 `:102` | CO-17 段 3 | size=1B ⇒ 卡回每任务 1 个 unseq |
| 22 | `min_cross_compaction_unseq_file_level` | `RewriteCrossSpaceCompactionSelector:307` | CO-04 两相 / CO-16 | 小 unseq 先被拦住 |
| 23 | `compaction_thread_count` | `CompactionTaskManager:136-153` | CO-15 段 3 / **CO-23** | 1 → 热改 3；jstack 数工作线程；各配置合并都正确 |
| 24 | `compaction_max_aligned_series_num_in_one_batch` | `BatchedFastAlignedSeriesCompactionExecutor:80` 等 | **CO-24** | 8 条对齐序列 × {1,8,0} 指纹一致 |
| 25 | `compaction_schedule_interval_in_ms` | `NewSizeTiered:105-109`；`CompactionScheduleTaskManager` | CO-09 / CO-10 | 活跃窗口 = 2×该值 |
| 26 | `compaction_write_throughput_mb_per_sec` | `CompactionTaskManager:85-89 / 298-318` | **CO-25** | 默认 vs 1MB/s：耗时变长 |
| 27 | `compaction_read_throughput_mb_per_sec` | 同上 `:95-99 / 306-308` | **CO-25** | 同上（读侧） |
| 28 | `compaction_read_operation_per_sec` | 同上 `:90-94 / 302-304` | **CO-25** | IOPS 限流 |
| 29 | `sub_compaction_thread_count` | `CompactionTaskManager:146` | CO-15 段 3 / CO-10 / **CO-23** | 子任务池 = 线程数 × 本值 |
| 30 | `inner_compaction_task_selection_disk_redundancy` | `SettleSelectorImpl:229-233` | **CO-26** | 0.999 ⇒ `isDiskHasSpace=false` ⇒ 有 mods 的文件被重写 |
| 31 | `inner_compaction_task_selection_mods_file_threshold` | 同上 | **CO-26** | 默认 128KB 不重写；改成 1B ⇒ 重写并清理 `.mods` |
| 32 | `compaction_schedule_thread_num` | `CompactionScheduleTaskManager:55/118` | **CO-23** | 生效值 + 合并仍正确 |
| 33 | `target_chunk_point_num` | `ChunkCompactionPerformer` | CO-16 段 4 | 目标 chunk 点数 |
| 34 | `target_chunk_size` | 同上 | CO-16 段 4 | 目标 chunk 大小 |
| 35 | `chunk_metadata_size_proportion` | `ChunkMetadataSizeCalculator` | CO-16 段 4 | chunk 元数据占比 |

## 二、"最基础合并场景"矩阵（与单个参数无关的形态/生命周期）

| 维度 | 取值 | 覆盖用例 |
| --- | --- | --- |
| 模型 × 空间 | 树 seq / 树 unseq / 树 cross | CO-01 / CO-03 / CO-04 |
| | **表 unseq / 表 cross** | **CO-28** |
| 数据形状 | 多设备、多 region | CO-01/02（隐式）、CO-20（显式 6 设备） |
| | 对齐序列（inner / 批量参数） | CO-08 / **CO-24** |
| | **多时间分区**（一个 region 跨两周） | **CO-27 ④** |
| 边界形态 | 单文件 no-op / 空库 / 全删后合并 | **CO-27 ①②③** |
| 与写/查并发 | **合并期间持续写 + 查** | **CO-31** |
| 进程生命周期 | 合并完成后重启 / **合并中崩溃（kill -9）后恢复** | **CO-29** |
| 跨空间路径 | 重写式（重叠 unseq） | CO-04 / CO-17 段 3 |
| | **插入式（不重叠 unseq 直接挪进 seq）** | **CO-30** |
| 删除清理 | mods 文件参与合并 / 触发 settle 重写 | CO-05 / **CO-26** |
| 规模级联 | 多文件 → 多层级的连续合并 | CO-01（14→6）、CO-33 未做（见下） |

> 尚未覆盖（有意留白，需专门环境）：`enable_auto_repair_compaction` 的**真实修复动作**
> （需要构造未排序 TsFile，SQL 侧做不到，需走 load/导入路径）；超大规模（数千文件）级联压力。

## 三、实测结论（RC6 `7ae8713e` / 3C3D / IoTConsensus，2026-10-14）

**15 条新用例 15/15 PASS**（耗时：CO-18 1258s、CO-19 264s、CO-20 325s、CO-21 301s、CO-22 453s、
CO-23 661s、CO-24 395s、CO-25 703s、CO-26 541s、CO-27 661s、CO-28 421s、CO-29 816s、
CO-30 254s、CO-31 536s、CO-32 365s）。逐条判据与证据见 `docs/RESULTS.md` 第 3 节 CO-18~CO-32 小节。

两条**观察**（已记录、不判缺陷）：

1. **`compaction_priority` 在本场景下不影响实际执行顺序**：三种取值的"首个 Cross 完成位置"都是第 8 位
   （I=21、C=3）。原因见源码：`DataRegion.executeCompaction` 每轮**先选 inner 任务、后选 cross 任务**，
   且 cross 选择还受 `shouldSelectCrossSpaceCompactionTask()`（队列占用 ≤1/6）门控
   ⇒ 优先级比较器只在"同类型多个任务同时在等待队列里"时才有机会体现。
2. **`target_compaction_file_size` 的分片是"按源文件位置/设备分配"，不是按字节精确切分**：
   6 设备场景下 1KB 目标得到 8 个产物、默认 2GB 得到 6 个（差值来自任务切分与设备分布），
   因此用例只做"N_A > N_B"的相对断言。

