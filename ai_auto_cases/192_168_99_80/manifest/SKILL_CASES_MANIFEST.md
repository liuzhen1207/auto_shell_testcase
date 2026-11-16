# 全部 skill 用例主清单

- 目标构建：**83183d0**
- 用例总数：**146**；该构建有结果：**146**；未跑：**0**
- 机器可读清单：`manifest/skill_cases_manifest.tsv`
- 覆盖率检查：`bash tools/check_case_coverage.sh 83183d0`（有未跑则退出码 2）

| skill | 用例数 | 该构建已跑 | 未跑 |
| --- | --- | --- | --- |
| compaction_skill | 52 | 52 | 0 |
| crud_skill | 15 | 15 | 0 |
| diskusage_skill | 5 | 5 | 0 |
| metadata_skill | 14 | 14 | 0 |
| treeview_skill | 18 | 18 | 0 |
| ttl_skill | 15 | 15 | 0 |
| wal_skill | 27 | 27 | 0 |
| **合计** | **146** | **146** | **0** |

## compaction_skill（52 条）

| 编号 | 用例文件 | 方言 | 分组 | 需重启 | 说明 | 该构建结果 | 最近构建 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CO-01 | cases/tree/co_tree_inner_smoke.sh | tree | tree | yes | **冒烟**：树模型 seq 内部合并——多批 flush 造多个 TsFile → 合并 → 文件数下降、合并前后数据指纹完全一致、无卡死 | PASS 448s | 83183d0 |
| CO-02 | cases/table/co_table_inner_smoke.sh | table | table | yes | **冒烟**：表模型 seq 内部合并（同 CO-01 判据，表模型接口） | PASS 442s | 83183d0 |
| CO-03 | cases/tree/co_unseq_inner.sh | tree | tree | yes | **冒烟**：unseq 内部合并——乱序时间戳造 unsequence 文件（关 seq/关 cross 隔离观测）→ unseq 文件数 | PASS 468s | 83183d0 |
| CO-04 | cases/common/co_cross_space.sh | tree | tree | yes | **冒烟**：跨空间合并——seq 区间 + 重叠的 unseq 区间 → unseq 归零、数据指纹不变、日志无 overlap 异常 | PASS 716s | 83183d0 |
| CO-05 | cases/common/co_delete_data.sh |  |  | yes | **冒烟**：DELETE 数据后合并——删除过的行合并后不得复活；树/表各跑一遍（带 mods 文件参与合并） | PASS 648s | 83183d0 |
| CO-06 | cases/common/co_metadata.sh |  |  | yes | **冒烟**：元数据变更后合并——DELETE TIMESERIES / DROP DATABASE 重建 / DROP TABLE / D | PASS 844s | 83183d0 |
| CO-07 | cases/tree/co_data_types_encoding.sh | tree | tree | yes | **冒烟**：多数据类型 × 多编码（int32/int64/float/double/boolean/text/string/timest | PASS 606s | 83183d0 |
| CO-08 | cases/tree/co_aligned_null.sh | tree | tree | yes | **冒烟**：对齐序列（aligned）+ 空值（null）在合并前后完全一致，null 个数不变 | PASS 470s | 83183d0 |
| CO-09 | cases/common/co_conf_params.sh | tree | tree | yes | **参数功能**：conf 模板 35 个 compaction 键齐全；`enable_seq_space_compaction=fals | PASS 857s | 83183d0 |
| CO-10 | cases/common/co_hot_reload.sh | tree | tree | yes | **热加载**：热关 seq 合并→写入不合并；热开→不重启立即合并；对 10 个参数逐项校验「CLI 是否要求重启 ⇔ 生效值是否立即变化 | PASS 568s | 83183d0 |
| CO-11 | cases/common/co_perf_baseline.sh | tree | tree | yes | **性能基准**：固定规模（默认 10 设备 × 10000 点 × 6 批）单会话写入 → 计时合并 → 记录输入/输出文件数与字节数、合 | PASS 1726s | 83183d0 |
| CO-12 | cases/common/co_remove_nodes.sh | tree | tree | yes | **缩容场景**：REMOVE DATANODE 后剩 2 DN 仍可读/可写/可合并、副本一致；REMOVE CONFIGNODE 后集群 | PASS 774s | 83183d0 |
| CO-13 | cases/tree/co_ttl_settle.sh | tree | tree | yes | **TTL 场景**：48h 前的批次在 TTL=24h 下过期（查询过滤）→ settle 合并物理清理（日志 + TsFile 数下降） | PASS 666s | 83183d0 |
| CO-14 | cases/table/co_ttl_table_settle.sh | table | table | yes | **TTL 场景（表模型）**：与 CO-13 同构，TTL 挂在表上（`ALTER TABLE … SET PROPERTIES ttl= | PASS 613s | 83183d0 |
| CO-15 | cases/common/co_param_gate_matrix.sh | tree | tree | yes | **参数组合①**：`enable_seq/unseq/cross` **8 种开闭组合矩阵**（热改，逐组合断言"该跑的跑/不该跑的不跑" | PASS 2929s | 83183d0 |
| CO-16 | cases/common/co_param_selector.sh | tree | tree | yes | **参数组合②**：`inner_seq_selector`×`inner_seq_performer`（4 组合）、`inner_unse | PASS 1013s | 83183d0 |
| CO-17 | cases/common/co_param_level_boundary.sh | tree | tree | yes | **参数组合③（边界）**：① `max_level_gap_in_inner_compaction` 层级边界（各副本造 [L1(旧),  | PASS 809s | 83183d0 |
| CO-18 | cases/common/co_param_priority.sh | tree | tree | yes | **参数功能（优先级确定性）**：`compaction_thread_count=1` 去掉并发竞态，INNER_CROSS / CROS | PASS 1493s | 83183d0 |
| CO-19 | cases/common/co_unseq_select.sh | tree | tree | yes | **乱序空间选择参数**：`inner_unseq_selector=size_tiered_multi_target` × `inner_ | PASS 356s | 83183d0 |
| CO-20 | cases/common/co_target_file_size.sh | tree | tree | yes | **目标文件大小**：6 设备 × 2 批同一场景，`target_compaction_file_size=1KB` 与默认 2GB 对照 | PASS 414s | 83183d0 |
| CO-21 | cases/common/co_inner_total_size.sh | tree | tree | yes | **单任务总大小上限**：4 个 L0（单文件约 1.3KB）时阈值=2000 ⇒ 装不下两个文件 ⇒ 不合并；热改 10000 ⇒ 一个任 | PASS 394s | 83183d0 |
| CO-22 | cases/common/co_task_queue.sh | tree | tree | yes | **候选队列容量**：队列=1 的高压场景（4 seq + 2 重叠 unseq、1 个合并线程）必须最终全部合并完、无写锁卡死、指纹不变； | PASS 620s | 83183d0 |
| CO-23 | cases/common/co_threads.sh | tree | tree | yes | **线程族**：`compaction_thread_count`（1 → 热改 3，用 jstack 数 `IoTDB-Compactio | PASS 728s | 83183d0 |
| CO-24 | cases/common/co_aligned_batch.sh | tree | tree | yes | **对齐序列批量**：1 个对齐设备 8 条序列 × 3 批，该键取 1 / 8 / 0（不分批）三种值合并，8 条序列指纹与合并前完全一致 | PASS 435s | 83183d0 |
| CO-25 | cases/common/co_rate_limit.sh | tree | tree | yes | **限流三件套**：TEXT 每行 1KB × 3000 行 × 2 批（约 6MB），默认限流与 写=1MB/s、读=1MB/s、读操作= | PASS 762s | 83183d0 |
| CO-26 | cases/common/co_settle_select.sh | tree | tree | yes | **settle 选择门控**（带删除标记的文件何时被重写）：mods 阈值默认 128KB + 磁盘充足 ⇒ 不重写；热改阈值=1B ⇒  | PASS 550s | 83183d0 |
| CO-27 | cases/common/co_basic_shapes.sh | tree | tree | yes | **最基础形态**：① 单文件 no-op 不合并 ② 空库不报错 ③ 数据全被 DELETE 后合并仍执行且删除行不复活 ④ **一个 r | PASS 741s | 83183d0 |
| CO-28 | cases/common/co_table_unseq_cross.sh | table | table | yes | **表模型 unseq 内部合并 + 跨空间合并**（补齐表模型只测过 seq 内部合并的缺口）：2 批顺序水位 + 2 批重叠乱序 ⇒ u | PASS 508s | 83183d0 |
| CO-29 | cases/common/co_restart_recovery.sh | tree | tree | yes | **合并与进程生命周期**：合并**进行中** kill -9 一个 DataNode → 其余副本照常完成 → 重启该 DN 等恢复 ⇒  | PASS 836s | 83183d0 |
| CO-30 | cases/common/co_insertion_cross.sh | tree | tree | yes | **插入式跨空间合并**（`InsertionCrossSpaceCompaction`，不重写数据、直接把 unseq 文件挪进 seq  | PASS 351s | 83183d0 |
| CO-31 | cases/common/co_concurrent_io.sh | tree | tree | yes | **合并与读写并发**：限流把合并拖到秒级，合并期间后台持续写 6 小批 + 查询 ⇒ 无任何错误输出、合并仍推进、写入数据都在、收尾三件套 | PASS 604s | 83183d0 |
| CO-32 | cases/common/co_auto_repair.sh | tree | tree | yes | **乱序文件自动修复开关**：开/关两相下正常场景合并都完成、指纹一致，且都**不得**误报 `RepairUnsortedFileComp | PASS 416s | 83183d0 |
| DT-01 | cases/common/dt_tree_basic.sh | tree | tree | yes | **改数据类型（树）基础 + 兼容矩阵正向**：10 种原始类型各建 1 条序列 → 按手册兼容表逐条 `ALTER TIMESERIES  | PASS 757s | 83183d0 |
| DT-02 | cases/common/dt_tree_negative.sh | tree | tree | yes | **改数据类型（树）负向 + 链式 + 改后写入**：不兼容转换必须被拒（507）、失败后类型/数据不变；不存在路径 508；链式 INT3 | PASS 381s | 83183d0 |
| DT-03 | cases/common/dt_tree_compaction.sh | tree | tree | yes | **改类型 × 合并（核心）**：A 改类型前后文件混合后合并（旧值可读、新值在、无 DataType/schema 异常）；B 合并进行中 | PASS 795s | 83183d0 |
| DT-04 | cases/common/dt_tree_concurrent.sh | tree | tree | yes | **并发删除序列 × 改类型**：先删后改必须明确报错；N 轮 `ALTER ∥ DELETE TIMESERIES` 竞争（每轮必须一方明 | PASS 358s | 83183d0 |
| DT-05 | cases/common/dt_table_basic.sh | table | table | yes | **改数据类型（表模型）基础**：`ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE`（仅 FI | PASS 318s | 83183d0 |
| DT-06 | cases/common/dt_table_compaction.sh | table | table | yes | **改类型（表模型）× 合并**：顺序空间内部合并 / 跨空间合并（unseq 归零）/ 并发 `DROP TABLE` ∥ `ALTER  | PASS 491s | 83183d0 |
| DT-07 | cases/common/dt_view.sh | table | table | yes | **树转表视图改列类型**：正确建视图语法（`CREATE VIEW db.v (col TYPE FIELD FROM m) AS roo | FAIL 4136s | 83183d0 |
| DT-08 | cases/common/dt_ha_disk_ro.sh | tree | tree | yes | **高可用·磁盘只读**：合并进行中把一个 DN 的**数据目录挂成只读**（整盘 `mount -o remount,ro /data`  | PASS 1166s | 83183d0 |
| DT-09 | cases/common/dt_ha_stop_nodes.sh | tree | tree | yes | **高可用·节点下线**：A 合并中**优雅 stop 1 DN**（不带 `-f` = `kill -s TERM`）→ 恢复一致；B 停 | PASS 1129s | 83183d0 |
| CO-33 | cases/common/co_repair_unsorted_load.sh | tree | tree | no | **未排序 TsFile 的真实修复链路（load 导入路径）**：按官方 IT `IoTDBRepairDataIT` 的方式用底层 `T | PASS 534s | 83183d0 |
| CO-34 | cases/common/co_scale_cascade.sh | tree | tree | no | **千级 TsFile 大规模级联合并压力**：三类合并全关下单会话连续 `INSERT 1 行 + FLUSH` × N（默认 1000） | PASS 311s | 83183d0 |
| CO-35 | cases/common/co_target_split_formula.sh | tree | tree | no | **目标文件拆分量化**（D1-1/1-2/1-3，官方 MG-10/MG-P20）：A/B/C 三相（小 target / 默认 2GB  | PASS 1248s | 83183d0 |
| CO-37 | cases/common/co_aligned_grouping.sh | tree | tree | no | **对齐序列分组合并分组规则 + 全 null 列 timestamp 保留**（D4-1/4-2/4-3/4-5，官方 MG-02-4/M | PASS 430s | 83183d0 |
| CO-40 | cases/common/co_recovery_branches.sh | tree | tree | yes | **合并临时态与恢复四分支 + 残留文件/句柄**（D3-1/3-2/3-3/3-4/3-5/3-7/3-9，官方 MG-P10/P15/P | PASS 1268s | 83183d0 |
| CO-42 | cases/common/co_fast_vs_default_perf.sh | tree | tree | no | **fast vs 默认的产物规格与耗时对照**（FC-01、FC-02-1/02-4、FC-03/07 产物规格列、D5-1）：4 个同构 | PASS 1569s | 83183d0 |
| CO-36 | cases/common/co_fast_fake_overlap.sh | tree | tree | no | **FastCompaction 直搬路径：「假 overlap」page 直刷与 ALL_DELETED 跳过**（D5-1/5-2/5- | PASS 760s | 83183d0 |
| CO-38 | cases/common/co_level_search_gate.sh | tree | tree | no | **空间内选择的逐层策略与提交通道门槛**（D1-4/D2-1/D2-2）：断言提交通槛 =「≥10 个文件 **或** ≥2GB」两类触发 | PASS 1068s | 83183d0 |
| CO-39 | cases/common/co_priority_rules.sh | tree | tree | yes | **任务优先级排序规则与线程族数量关系**（D2-9/2-10/2-11 + 官方 MG-T01/T02/T03）：同类型 5 级排序（低层 | PASS 833s | 83183d0 |
| CO-41 | cases/common/co_object_ttl.sh | table | table | no | **表模型 OBJECT 类型合并与 TTL/deletion 清理语义**（D7-1/7-2/7-3/7-4）：OBJECT 列（`to_ | PASS 481s | 83183d0 |
| CO-43 | cases/common/co_samename_aligned_flip.sh | tree | tree | yes | **同名序列重建 + 对齐属性翻转后的合并**（官方 MG-P18/MG-P19，缺陷 **IOTDB-5686**：官方首测 select | PASS 903s | 83183d0 |

## crud_skill（15 条）

| 编号 | 用例文件 | 方言 | 分组 | 需重启 | 说明 | 该构建结果 | 最近构建 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CR-00 | cases/common/cr_smoke.sh | tree | tree | yes | **冒烟（骨架 fallback）**：树模型 seq 内部合并——多批 flush 造多个 TsFile → 热开合并 → 文件数下降 + | PASS 408s | 83183d0 |
| CR-01 | cases/common/cr_timestamp_precision.sh | tree | tree | no | **时间戳精度检查门禁**（R-01~R-05）：开关 + ms/us 位数阈值 + ns 放行 + 文案/错误码逐字匹配；含兼容性与"10 | PASS 703s | 83183d0 |
| CR-02 | cases/common/cr_ts_partition_balance.sh | tree | tree | yes | **精度检查 × 时间分区**（R-06~R-08）：改 time_partition_interval 后精度门禁行为与文件分布不变/符合 | PASS 456s | 83183d0 |
| CR-03 | cases/common/cr_table_time_only.sh | table | table | no | **表模型"只有 Time 列"门禁**（R-12/R-13）：写入必须拒绝（码 ∈ {1100,507} 且文案逐字）、DROP COLU | PASS 515s | 83183d0 |
| CR-04 | cases/common/cr_mod_shape.sh | tree | tree | no | **`.mods2` 基础形态**（R-16~R-20,R-22）：删除前无 Mod；被删除覆盖的 TsFile 各 1 个独占 `<tsf | PASS 395s | 83183d0 |
| CR-05 | cases/common/cr_mod_alloc_threshold.sh | tree | tree | no | **Mod 分配阈值边界**（R-21）：时间不重叠不分配、被覆盖者 1:1 独占、重复删除只追加、批量追加把 `.mods2` 顶过 16 | PASS 460s | 83183d0 |
| CR-06 | cases/common/cr_delete_concurrent_compaction.sh | tree | tree | no | **删除 × 合并并发**（R-23~R-25）：合并窗口内删除不得丢（N_Mod/C_Mod/cascade），双信号 + 数据面指纹 + | PASS 1057s | 83183d0 |
| CR-07 | cases/common/cr_delete_midstate.sh | tree | tree | no | **删除中间态**（R-26~R-27）：memtable 中 / 正在 flush 的文件也被删除覆盖，且不破坏其它设备数据 | PASS 1621s | 83183d0 |
| CR-08 | cases/common/cr_delete_pipe.sh | tree | tree | no | **Pipe 传输带删除的 TsFile**（R-33~R-34）：单集群内可构造部分（带 `.mods2` 的 TsFile 经 load | PASS 352s | 83183d0 |
| CR-09 | cases/common/cr_mod_lifecycle.sh | tree | tree | yes | **Mod 生命周期 + 旧格式兼容 + 重启恢复**（R-28~R-32）：注入 V1 文本 `.mods` → 完整重启后升级为 `.m | PASS 975s | 83183d0 |
| CR-10 | cases/common/cr_delete_block_write.sh | tree | tree | no | **DELETE 阻塞写入量化**（R-38~R-41）：固定规模关/开机制对照，耗时随 TsFile 数变化（**耗时只 WARN**）； | PASS 4875s | 83183d0 |
| CR-11 | cases/common/cr_object_manual_delete.sh | table | table | no | **OBJECT 手动删除**（R-46~R-50）：整表/部分/整库删除后 object 真实文件被**异步 GC** 物理清理（轮询等待 | PASS 501s | 83183d0 |
| CR-12 | cases/common/cr_object_delete_negative.sh | table | table | no | **OBJECT 删除异常路径与开销对照**（R-51~R-53）：无权限/不存在/并发 DROP 的明确结果与错误码；异常路径不得留下不一 | PASS 988s | 83183d0 |
| CR-13 | cases/common/cr_load_lastcache.sh | tree | tree | no | **Load 时 LastCache 四策略正确性**（R-54~R-60）：`UPDATE`/`UPDATE_NO_BLOB`/`CLEA | PASS 1177s | 83183d0 |
| CR-14 | cases/common/cr_load_pipe_last.sh | tree | tree | yes | **Load × Pipe + Last：配置 restart-only 语义 + 性能与内存预算**（R-58/R-59/R-60/R-6 | PASS 2014s | 83183d0 |

## diskusage_skill（5 条）

| 编号 | 用例文件 | 方言 | 分组 | 需重启 | 说明 | 该构建结果 | 最近构建 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DU-01 | cases/tree/du_tree_merge_after_stats.sh | tree | tree | yes | **TDB-629 门禁（树模型接口）**：`show disk_usage from <db>.**` 统计后，被扫过的 TsFile 必 | PASS 419s | 83183d0 |
| DU-02 | cases/table/du_table_merge_after_stats.sh | table | table | yes | **TDB-629 门禁（表模型接口）**：`select * from information_schema.table_disk_usa | PASS 368s | 83183d0 |
| DU-03 | cases/tree/du_tree_stats.sh | tree | tree | yes | 树模型统计正确性（有数据）：`SHOW DISK_USAGE FROM root.db.**` 的列序与含义、SizeInBytes 与磁盘 | PASS 399s | 83183d0 |
| DU-04 | cases/table/du_table_stats.sh | table | table | yes | 表模型统计正确性（有数据）：information_schema.table_disk_usage 列序与含义、按 table/databa | PASS 433s | 83183d0 |
| DU-05 | cases/common/du_privilege.sh | both |  | yes | 权限与错误路径：仅 SYSTEM 权限用户可执行（普通用户应报错/无权），树模型非法 pattern（不以 root 开头等）报错，表模型对 | PASS 301s | 83183d0 |

## metadata_skill（14 条）

| 编号 | 用例文件 | 方言 | 分组 | 需重启 | 说明 | 该构建结果 | 最近构建 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MD-T01 | tree/md_tree_database.sh | tree | tree | reuse | 树模型 DATABASE 元数据闭环（建/查/计数/详情/改/删 + 失败路径） | PASS 80s | 83183d0 |
| MD-T02 | tree/md_tree_timeseries.sh | tree | tree | reuse | 树模型 TIMESERIES 元数据闭环（建/SHOW 过滤/COUNT 各级/ALTER 系列/RENAME/死路径） | PASS 91s | 83183d0 |
| MD-T03 | tree/md_tree_template.sh | tree | tree | reuse | 树模型 SCHEMA TEMPLATE 元数据闭环（建/ALIGNED/SHOW NODES/SET/UNSET/SHOW PATHS/US | PASS 85s | 83183d0 |
| MD-T04 | tree/md_tree_observe.sh | tree | tree | reuse | 树模型元数据观测面（集群/区域/时隙/会话/版本 + DataRegion 懒创建） | PASS 95s | 83183d0 |
| MD-T05 | tree/md_tree_ddl_negative.sh | tree | tree | reuse | 树模型 DDL 失败路径与错误码（不被静默接受 + 失败后元数据不被改脏） | PASS 86s | 83183d0 |
| MD-T06 | tree/md_tree_view_ttl.sh | tree | tree | reuse | 树模型 VIEW 与 TTL 元数据闭环 | PASS 93s | 83183d0 |
| MD-B01 | table/md_table_ddl.sh | table | table | reuse | 表模型 DATABASE/TABLE/COLUMN 元数据闭环（DESC/SHOW CREATE/加删列/改类型/属性/注释） | PASS 88s | 83183d0 |
| MD-B02 | table/md_table_view_schema.sh | table | table | reuse | 表模型 VIEW + information_schema 交叉校验与能力边界 | PASS 83s | 83183d0 |
| MD-C01 | common/md_meta_consistency.sh | common | tree | reuse | 元数据副本一致性 + 重启持久化 + 跨模型命名空间隔离 | PASS 342s | 83183d0 |
| MD-C02 | common/md_dcl_user_role.sh | common | tree | reuse | 权限元数据（USER/ROLE/PRIVILEGE）闭环 | PASS 98s | 83183d0 |
| MD-C03 | common/md_privilege_matrix.sh | common | tree | reuse | 权限矩阵（权限值 × 路径粒度 × 用户/角色 + LIST PRIVILEGES + 越权 803） | PASS 147s | 83183d0 |
| MD-U01 | common/md_udf_trigger.sh | common | tree | reuse | 真实 jar 的 UDF/Trigger 全链路（注册/SHOW/执行/触发/重启恢复/DROP） | PASS 325s | 83183d0 |
| MD-S01 | common/md_scale_bulk.sh | tree | scale | reuse | 元数据规模（2000 时序 / 200 表下的 SHOW/COUNT/DESC/information_schema 正确性与耗时） | PASS 85s | 83183d0 |
| MD-B05 | table/md_writable_view.sh | table | table | reuse | 表模型可写视图（WRITABLE VIEW）元数据闭环 + 并发 ALTER 缓存一致性（TDB-615） | PASS 75s | 83183d0 |

## treeview_skill（18 条）

| 编号 | 用例文件 | 方言 | 分组 | 需重启 | 说明 | 该构建结果 | 最近构建 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tv_align | cases/treeview/tv_align.sh |  |  |  | TV-16 对齐 / 非对齐设备的 null 行语义（树转表视图） | PASS 170s | 83183d0 |
| tv_alter | cases/treeview/tv_alter.sh |  |  |  | TV-04 ALTER / COMMENT / DROP 视图（需求 §2.2；含 tree view add column / drop  | PASS 189s | 83183d0 |
| tv_autosync_1000 | cases/treeview/tv_autosync_1000.sh |  |  |  | TV-13 单设备新增 1000 个测点 → 树转表视图（auto_sync_schema=true）补列成功 | PASS 229s | 83183d0 |
| tv_autosync_fail | cases/treeview/tv_autosync_fail.sh |  |  |  | TV-12 树侧"新增测点失败"时，树转表视图（auto_sync_schema=true）不得补列 | PASS 198s | 83183d0 |
| tv_client_iface | cases/treeview/tv_client_iface.sh |  |  |  | TV-CLI-01 不同客户端接口建序列 → 树转表视图自动补列一致性 | PASS 342s | 83183d0 |
| tv_create_basic | cases/treeview/tv_create_basic.sh |  |  |  | TV-01 CREATE 基本信息面：显式列定义 / 类型 / TAG-FIELD 映射 / FROM 改名 / 无 FIELD 扫描 /  | PASS 328s | 83183d0 |
| tv_create_negative | cases/treeview/tv_create_negative.sh |  |  |  | TV-02 CREATE 负向与 OR REPLACE 语义（需求 §2.1.1.1、§2.1.1.4） | PASS 326s | 83183d0 |
| tv_create_restrict | cases/treeview/tv_create_restrict.sh |  |  |  | TV-03 RESTRICT 与设备层级匹配（需求 §2.1.1.3） | PASS 323s | 83183d0 |
| tv_log_noise | cases/treeview/tv_log_noise.sh |  |  |  | TV-LOG-01 预期内失败不得产生 ERROR/WARN 噪声（可观测性门禁） | FAIL 331s | 83183d0 |
| tv_perf | cases/treeview/tv_perf.sh |  |  |  | TV-15 性能：树转表视图 vs 普通表（同数据量） | PASS 352s | 83183d0 |
| tv_real_alter | cases/treeview/tv_real_alter.sh |  |  |  | TV-09 真实数据：ALTER VIEW（重点：tree view add column）+ 元数据展示 | PASS 167s | 83183d0 |
| tv_real_ha | cases/treeview/tv_real_ha.sh |  |  |  | TV-10 真实数据：高可用（停 1 DN / 停 1 CN 后视图 DDL 与查询可用） | PASS 220s | 83183d0 |
| tv_real_query | cases/treeview/tv_real_query.sh |  |  |  | TV-08 真实数据：查询能力与树模型对照（需求 §2.4 / §3） | PASS 172s | 83183d0 |
| tv_real_ttl | cases/treeview/tv_real_ttl.sh |  |  |  | TV-11 真实数据：WITH TTL（视图 TTL 与树 TTL 取更小值；只影响查询不物理删除） | PASS 160s | 83183d0 |
| tv_real_views | cases/treeview/tv_real_views.sh |  |  |  | TV-07 真实数据：同一前缀建多个视图（AA5 / AA6）+ 视图间一致性 | PASS 161s | 83183d0 |
| tv_realdata | cases/treeview/tv_realdata.sh |  |  |  | TV-06 真实数据集（树模型 TsFile → 树转表视图） | FAIL 2164s | 83183d0 |
| tv_security | cases/treeview/tv_security.sh |  |  |  | TV-14 树转表视图的权限（§2.7） | PASS 330s | 83183d0 |
| tv_show | cases/treeview/tv_show.sh |  |  |  | TV-05 视图展示面（需求 §2.3） | PASS 332s | 83183d0 |

## ttl_skill（15 条）

| 编号 | 用例文件 | 方言 | 分组 | 需重启 | 说明 | 该构建结果 | 最近构建 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| TT-01 | cases/tree/ttl_tree_basic.sh | tree | tree | yes | SET/UNSET/SHOW 基本功能、前缀路径与 303、INF 与默认值、规则继承与优先级、SHOW DEVICES TTL、删库/删序 | PASS 304s | 83183d0 |
| TT-02 | cases/tree/ttl_tree_expire.sh | tree | tree | yes | 过期可见性过滤、TTL 内外边界、写入过期时间戳被拒 607、FLUSH 后物理删除、取消 TTL 后新数据不再被清 | PASS 544s | 83183d0 |
| TT-03 | cases/tree/ttl_tree_dml.sh | tree | tree | yes | 大数据量(默认 2000 点) + DELETE 数据/元数据 + DROP 重建后规则保留并生效 | PASS 383s | 83183d0 |
| TT-04 | cases/tree/ttl_tree_scope.sh | tree | tree | yes | 作用域语义：三级继承与覆盖、规则热更新对已写数据立即生效、UNSET 后未被物理删除的过期数据重新可见、预置规则作用于后创建设备、TTL=0 | PASS 515s | 83183d0 |
| TB-01 | cases/table/ttl_table_basic.sh | table | table | yes | 建库/建表/改表 TTL、ttl='INF'/default、继承与解耦、SHOW TABLES/SHOW DATABASES DETAIL | PASS 255s | 83183d0 |
| TB-02 | cases/table/ttl_table_expire.sh | table | table | yes | 过期行过滤、TTL 内外边界、FLUSH 后物理删除、改小/取消 TTL 行为、视图读过期数据 | PASS 392s | 83183d0 |
| TB-03 | cases/table/ttl_table_object.sh | table | table | yes | OBJECT 列 + TTL：to_object 写入、查询、过期不可见、object 文件随 TTL 清理（60s 缓冲）、树模型不支持  | PASS 409s | 83183d0 |
| TB-04 | cases/table/ttl_table_dml.sh | table | table | yes | 大数据量(默认 2000 行) + DELETE 数据/DELETE DEVICES + DROP 重建后 TTL 继承与生效 | PASS 385s | 83183d0 |
| TB-05 | cases/table/ttl_table_cleanup.sh | table | table | yes | 表模型清理阈值：过期表被清理、同库 ttl='INF' 表数据完好、零脏数据文件不得被反复 settle（ratio=1e-6）、ratio | PASS 1107s | 83183d0 |
| TT-05 | cases/tree/ttl_show_ttl_scope.sh | tree | tree | yes | TDB-444 回归门禁：`SHOW TTL ON <db>.<dev>.**` 不得返回不相干库规则或 `root.**` 全局规则（缺陷 | PASS 252s | 83183d0 |
| TP-01 | cases/common/ttl_param_effect.sh | both |  | yes | 参数值/热加载/重启生效：ttl_check_interval 实测周期（按 region 相邻时间差取中位数）与 restart 提示、c | PASS 1654s | 83183d0 |
| TP-02 | cases/common/ttl_cleanup_threshold.sh | tree | tree | yes | 文件级清理阈值：全过期→FULLY_DIRTY 整文件删除、部分过期+max_expired_time=INF+极小 ratio→按比例清理 | PASS 1209s | 83183d0 |
| TP-03 | cases/common/ttl_param_effect_mode.sh | tree | tree | yes | expired_data_ratio 生效方式与数值语义：A M=INF+ratio=1e-6 → 部分过期文件被清理（基线，10 设备保证 | PASS 665s | 83183d0 |
| TP-04 | cases/common/ttl_dup_region_register.sh | tree | tree | yes | **TDB-610 门禁**：同一个 DataRegion 被注册两次到压缩/TTL 调度列表 ⇒ 该 region 每周期被检查两遍。判据 | PASS 485s | 83183d0 |
| TP-05 | cases/common/ttl_tier_warn_key.sh | tree | tree | yes | **TDB-611 门禁**：写入 `tier_ttl_in_ms=1000;2000`（与默认 1 层 dn_data_dirs 不匹配） | PASS 580s | 83183d0 |

## wal_skill（27 条）

| 编号 | 用例文件 | 方言 | 分组 | 需重启 | 说明 | 该构建结果 | 最近构建 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W-00 | cases/common/wal_smoke.sh | tree | tree | yes | **冒烟（骨架门禁）**：写多批 → 记 WAL 目录基线（目录口径 + `file_count{name="wal"}` 指标口径，并把* | PASS 585s | 83183d0 |
| W-01 | cases/common/wal_mode_matrix.sh | tree | tree | yes | **wal_mode 模式矩阵**：ASYNC 与 SYNC 各自写入正确性 + WAL 目录确有文件 + 耗时/文件数/字节数对照（**耗 | PASS 990s | 83183d0 |
| W-02 | cases/common/wal_mode_disable_rejected.sh | tree | tree | yes | **集群下 DISABLE 必须被拒绝**（负向门禁）：校验在 `IoTDBStartCheck.java:150-163`（经 `Data | PASS 525s | 83183d0 |
| W-03 | cases/common/wal_mode_restart_only.sh | tree | tree | yes | **wal_mode 的 restart-only 语义**：`SET CONFIGURATION 'wal_mode'` 返回文案 + p | PASS 734s | 83183d0 |
| W-04 | cases/common/wal_recovery_kill9.sh | tree | tree | yes | **掉电恢复（WAL 重放）**：写入后（不 flush）`kill -9` **全部 DN**（只杀 1 个只验证共识补齐，不是掉电语义） | PASS 591s | 83183d0 |
| W-05 | cases/common/wal_recovery_flush_boundary.sh | tree | tree | yes | **flush 边界对照**：A 相"写入后立刻 kill -9 全部 DN"（必须靠 WAL 重放）vs B 相"写入 + flush + | PASS 934s | 83183d0 |
| W-06 | cases/common/wal_recovery_dn_down.sh | tree | tree | yes | **DN 正常下线期写入 + 恢复**：`wal_stop_dn` 停 1 个 DN（**正常 stop**，对照 kill -9）→ 期间 | PASS 387s | 83183d0 |
| W-07 | cases/common/wal_recovery_metadata.sh | tree | tree | yes | **元数据变更后的 WAL 恢复**：建库/建序列 → 写数据 → `DELETE TIMESERIES` / `DROP` 相关操作（不  | PASS 492s | 83183d0 |
| W-08 | cases/common/wal_file_rotate.sh | tree | tree | yes | **WAL 文件轮转阈值**：`wal_file_size_threshold_in_byte`（hot_reload；文档间 30M/10 | PASS 927s | 83183d0 |
| W-09 | cases/common/wal_buffer_size.sh | tree | tree | yes | **`wal_buffer_size_in_byte`**（**restart-only**；文档间 16M/32M 矛盾 ⇒ 先读生效值） | PASS 767s | 83183d0 |
| W-10 | cases/common/wal_node_alloc.sh | tree | tree | yes | **WALNode 分配（本环境走 FirstCreateStrategy）**：源码 `WALManager.java:76-85` —— | PASS 629s | 83183d0 |
| W-11 | cases/common/wal_compress_toggle.sh | tree | tree | yes | **WAL 压缩开关对照**（`enable_wal_compression` 默认 true、hot_reload）：同一数据量同阈值下  | PASS 991s | 83183d0 |
| W-12 | cases/common/wal_compress_recovery.sh | tree | tree | yes | **压缩态掉电恢复**：压缩开启 + 未 flush 写入 → kill -9 全部 DN → 重启 → 数据完整（走段解压路径，`WALI | PASS 1109s | 83183d0 |
| W-13 | cases/common/wal_compress_mixed.sh | tree | tree | yes | **压缩开关切换后的共存恢复**：压缩是**段级**的（段头 1 字节标 compressionType），**文件级**兼容靠 `WALF | PASS 752s | 83183d0 |
| W-14 | cases/common/wal_cleanup_period.sh | tree | tree | yes | **无效 WAL 清理**：写入 → `flush`（数据落盘后对应 WAL 记录即无效）→ `delete_wal_files_perio | PASS 1191s | 83183d0 |
| W-15 | cases/common/wal_min_effective_ratio.sh | tree | tree | yes | **`wal_min_effective_info_ratio`**（hot_reload）：调大/调小后 MemTable 快照 vs f | PASS 1109s | 83183d0 |
| W-16 | cases/common/wal_memtable_snapshot.sh | tree | tree | yes | **MemTable 快照**：`wal_memtable_snapshot_threshold_in_byte` 调小 + `max_wa | PASS 579s | 83183d0 |
| W-17 | cases/common/wal_throttle.sh | tree | tree | yes | **WAL 阻写（throttle/背压）**：真实键 **`wal_throttle_threshold_in_byte`**（**hot | PASS 744s | 83183d0 |
| W-18 | cases/common/wal_queue_memory.sh | tree | tree | yes | **大压力下 WAL 队列内存受控**：高并发大写入期间采集 `wal_queue_mem_cost{name="wal_queue_cur | PASS 696s | 83183d0 |
| W-19 | cases/common/wal_object_recovery.sh | table | table | yes | **OBJECT 写入的 WAL 恢复**：`to_object(isEOF,offset,content)` 分段写入（如 100 字节分 | PASS 412s | 83183d0 |
| W-20 | cases/common/wal_object_load_restart.sh | table | table | yes | **导入 OBJECT 数据后重启一致性**：LOAD/导入路径写 OBJECT → 完整重启（`wal_restart_all`）→ 数据 | PASS 758s | 83183d0 |
| W-21 | cases/common/wal_param_invalid.sh | tree | tree | yes | **参数合法性（负向）**：非法取值（`wal_mode=XXX`、负数字节、0 阈值、超范围 ratio、`max_wal_nodes_n | FAIL 1615s | 83183d0 |
| W-22 | cases/common/wal_param_hotload.sh | tree | tree | yes | **参数热加载语义**：逐个 `SET CONFIGURATION` 19 个 WAL 键 → 记录返回文案（哪些 restart requ | PASS 1052s | 83183d0 |
| W-23 | cases/common/wal_metrics.sh | tree | tree | yes | **WAL 可观测性**：**指标名已在源码确认**（`Metric.java:80-85,156-157`）：`file_count{na | FAIL 870s | 83183d0 |
| W-24 | cases/common/wal_dir_config.sh | tree | tree | yes | **WAL 目录配置**：`dn_wal_dirs`（**restart-only**；`wal_dir` 单数键不存在）指向自定义目录 → | PASS 1512s | 83183d0 |
| W-25 | cases/common/wal_disk_readonly.sh | tree | tree | yes | **WAL 盘只读/写不进去（高可用）**：让 WAL 目录不可写（DN 以 root 运行 ⇒ `chmod` 无效；按序尝试 `chat | PASS 758s | 83183d0 |
| W-26 | cases/common/wal_consensus_matrix.sh | tree | tree | yes | **双协议对照**：同一 WAL 场景（写入 → 不 flush → kill -9 全部 DN → 重启 → 数据完整 + 压缩对照）在  | PASS 930s | 83183d0 |

