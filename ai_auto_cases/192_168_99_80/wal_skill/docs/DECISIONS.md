# WAL 专项 skill —— 口径与决策记录（DECISIONS）

> 记录本 skill 的**判定口径**与**为什么这样定**。凡"文档没写 / 环境测不到 / 版本没实现"的，
> 一律记为 WARN 或"不可构造"，**绝不静默通过、绝不编造判据**。
> 需求出处：`docs/req_sources/`（飞书文档抽取 + 源码印证）。

## 0. 范围与命名

| 项 | 约定 |
| --- | --- |
| 目标版本 | RC7 `v20121rc7_1014_7c61428`（`2.0.12.1`）；换环境只改 `conf/env.conf` |
| 集群 | 3C3D（77/78/79，1CN+1DN/台），RF=3；协议默认 `IoTConsensus`，可 `--consensus IoTConsensusV2` |
| 用例编号 | `W-00`…`W-26`（27 条）；库名一律 `root.wal…` |
| 集合 | `tools/run_all.sh --set smoke\|mode\|recover\|file\|compress\|cleanup\|mem\|object\|param\|observe\|ha\|all`（**显式 ID 清单**） |
| 观测层 | `lib/wal_ext.sh`（WAL 专属）；`lib/common.sh`/`lib/cmp.sh` 沿用合并 skill 的基线，**不改默认语义** |

**首轮实跑范围（用户 2026-10-16 决定）**：核心 12 条、单协议 IoTConsensus
`W-00 W-01 W-02 W-03 W-04 W-05 W-08 W-11 W-12 W-14 W-17 W-23`。

## 1. 观测口径：WAL 三件套

| 面 | 手段 | 地位 |
| --- | --- | --- |
| 目录面 | `<wal_dirs>/_<version_id>.wal`、`_<version_id>.checkpoint`（设计文档 §4.1/§6.2；`wal_dirs` 默认 `data/wal`）；`wal_file_cnt` / `wal_dir_bytes` / `wal_ckpt_cnt` / `wal_node_dirs` / `wal_ls`；文件尾魔数 **`WAL-V2`**（`wal_magic_cnt`） | **过程证据** |
| 日志面 | `wal_log_sum` / `wal_log_tail`：按源码文案计数（**文档零日志关键字，见 §4**） | **弱证据**：只证明"WAL 子系统在动" |
| 数据面 | 故障/重启后的 `count/sum/min/max` + 单设备全序列指纹（`cmp_fp_tree`/`cmp_fingerprint`） | **最终判据**（唯一能判 FAIL 的） |

**场景有效性一律硬断言**：WAL 文件数为 0、阈值没生效、kill 没发生、重启没完成 ⇒ `fail "场景无效：…"`，
不许静默跳过 —— 否则会出现"用例全绿但其实什么都没测"。

## 2. 只 WARN、不判 FAIL 的项（及理由）

| 项 | 理由 |
| --- | --- |
| 各模式/各参数的**耗时**对照 | 环境噪声大（3 节点时钟差、JVM 抖动），且文档只给方向性结论 |
| WAL **压缩率**（`WAL_COMPRESS_RATIO_MIN`，默认 1.2） | 文档未定稿算法（候选 GZIP/LZ4/ZSTD；设计文档写默认 LZ4，压缩方案文档实验用 GZip），只给"Wal size 压缩率约 3""I/O 节约 30% 左右"这类**特定负载下的经验值**；数据可压性差异极大 |
| WAL **绝对内存/队列上限**数值 | 文档只有相对口径"memtable 内存的 10%"，无绝对字节阈值 |
| **指标名/指标是否存在** | 文档零 metrics 名（唯一监控项只在图片里）⇒ `wal_metric_names` 动态发现，缺了只 WARN |
| V2 下**单副本不落盘**导致的 `close 未达 N` | 已定性为协议路径现象（合并 skill V2 全量回归中反复出现），非本 skill 判据 |
| 阻写在小规模下**能否触发** | 阈值语义与默认值在文档间不一致（见 §3）；无法触发时记"场景未成立"+WARN |

## 3. 文档自相矛盾 / 版本差异 —— 先标定再断言

| 配置项 | 需求分析（V1.1.0.1） | 设计文档（技术设计） | 处理 |
| --- | --- | --- | --- |
| `wal_file_size_threshold_in_byte` | 30M | 10M，热加载 | 用例**先用 `cmp_eff` 读实际生效值**再断言，不写死 |
| `wal_buffer_size_in_byte` | 32M | 16M，未标热加载 | 同上 |
| fsync 间隔 | `wal_async_mode_fsync_delay_in_ms`=1000 / `wal_sync_mode_fsync_delay_in_ms`=3 | 只有单一 `fsync_wal_delay_in_ms`=1500 | 两个键都探测，用存在的；W-22 逐项记录 |
| 阻写键 | `wal_throttle_threshold_in_byte`=200G（IoTConsensus 下触发阻写） | `iot_consensus_throttle_threshold_in_byte`（达上限阻止写入） | **源码已定**：真实键 = `wal_throttle_threshold_in_byte`（**hot_reload**）；`iot_consensus_throttle_threshold_in_byte` **已废弃**（仅作旁证） |
| 队列容量键 | — | `wal_buffer_queue_capacity` → `wal_buffer_queue_proportion`（默认 memtable 内存 10%） | 2.0 实际键 = `wal_buffer_queue_proportion`（**restart-only**）；以相对口径描述，不断言绝对值 |

### 3.1 源码印证后的确定结论（2026-10-16，`docs/req_sources/source_grounding.md`）

1. **配置项共 19 个**（模板：`iotdb-core/node-commons/src/assembly/resources/conf/iotdb-system.properties.template:1919-2030`）。
   **restart-only**：`wal_mode`、`max_wal_nodes_num`、`wal_buffer_size_in_byte`、`wal_entry_size_limit_in_byte`、
   `wal_file_list_cache_enabled`、`wal_cache_shrink_clear_enabled`、`dn_wal_dirs`、`wal_buffer_queue_proportion`；
   其余（含 `wal_file_size_threshold_in_byte`、`wal_throttle_threshold_in_byte`、`enable_wal_compression`、
   `delete_wal_files_period_in_ms`、`wal_min_effective_info_ratio`、`*_snapshot_*`）为 **hot_reload**。
2. **`wal_mode=DISABLE` 的拒绝条件**：`IoTDBStartCheck.java:150-163`（经 `DataNode.java:530` 调用）；
   仅 `IoTConsensus` 或（`IoTConsensusV2` 且 `iot_consensus_v2_mode=stream`）时拒绝；
   **只在 `isFirstStart()` 生效**（已初始化节点重启不被拒）；**V2 默认 `batch` 允许 DISABLE**；Ratis 强制 DISABLE。
3. **WAL 目录/文件名**：`<dn_wal_dirs>/<identifier>/_<versionId>-<startSearchIndex>-<statusCode>.wal`（statusCode∈{0,1}）；
   IoTConsensus 下 `identifier=<database>-<regionId>`；`wal_dir`（单数）键**不存在**。
   **分配策略更正**（`WALManager.java:76-85`）：IoTConsensus / IoTConsensusV2 一律 `FirstCreateStrategy`
   ⇒ **`max_wal_nodes_num` 在本环境不生效**；`ElasticStrategy`（=0，每 4 个申请者 1 个 WALNode）与
   `RoundRobinStrategy`(>0) 只在**非** IoTConsensus（standalone）路径下生效（模板注释："only valid in the standalone mode"）。
   ⚠️ 这条更正推翻了 source_grounding §3 的原始表述（原文把 Elastic 说成本环境的行为）——**以本处为准**。
4. **压缩 = LZ4**，单元是**一次 sync 批次的 buffer 段**，**段 < 32KB 不压**，段头 1 字节标 compressionType；
   文件级兼容靠 `WALFileVersion` 的 V1/V2/V3 magic。
5. **指标名已确定**（见 `cases.tsv` W-23 行）；`file_count{name="wal"}` / `file_size{name="wal"}` 是最权威的文件面证据。
6. **不可作判据**：`WALNode.java:116-118 memTableSnapshotCount`（内存 Map，不落盘无指标）；
   `WALNode.java:466-470`"删除过期 WAL 条数"文案（**DEBUG 级、默认 `root level="info"` 不落盘**）。
7. **阻写是两套互不相同的机制**（REQ_MATRIX §6-7/§6-8）：
   WALManager 侧按 WAL 磁盘占用 **不阻塞**（只删文件 / 触发快照，超水位打 WARN）；
   IoTConsensus 侧**阻塞写入线程约 30s 后返回 `WRITE_PROCESS_REJECT`（拒绝）**。
   且**废弃旧键 `iot_consensus_throttle_threshold_in_byte` 优先级更高**、读到即打废弃 WARN，而文档只写了旧键
   ⇒ W-17 的判据写成"任一键 / 任一机制出现即场景成立"，`WRITE_PROCESS_REJECT` 类拒绝**只 WARN**。
8. **WAL 目录永远不会清零**：`WALNode.java:671-676` —— statusCode=1 的文件与"最后一个 WAL 文件"恒被保留；
   可删的只是 `version_id < min(各 MemTable 首个 WAL version_id)` 的文件。
   ⇒ 所有目录面断言（W-14 等）只能写"相比基线**下降**"，**不得**写"降到 0 / 目录为空"。
9. **文件名口径分裂**：文档写 `_[version_id].wal`，源码实际是
   `_<versionId>-<startSearchIndex>-<statusCode>.wal`（`WALFileUtils.java:65-83`，statusCode∈{0,1}）
   ⇒ 用例按**源码形态**解析，文档差异记 WARN（矩阵 R-W17/R-W19）。
10. **不要用来构造场景的键**：`iot_consensus_cache_window_time_in_ms`（全仓无消费者）、
   `wal_cache_shrink_clear_enabled`（不在模板里，`SET CONFIGURATION` 会被 `filterInvalidConfigItems` 丢弃）。
| `wal_min_effective_info_ratio` 比较符 | — | 文中 `<` 与 `≤` 并存 | 只断言"占比变化后行为方向"，不判边界等号 |
| `max_wal_memtable_snapshot_num=1` | — | "超过该次数"vs"累计 ≥"并存 | 同上 |
| `wal_memtable_snapshot_threshold_in_byte` | 8MB | `>` 与 `≥` 并存 | 同上 |

## 4. 文档未提及 ⇒ 不可构造 / 只能间接判定

1. **零日志关键字、零指标名**：三份设计/需求文档没有任何 INFO/WARN/ERROR 文案，也没有 metrics 名。
   ⇒ 日志面断言**没有文档依据**，必须先现场采样（首轮跑 W-23 时采集 DN metrics 里含 `wal` 的全部时间序列名）。
2. **WAL 目录完整命名规则与 WALNode↔DataRegion 映射未给出**（只在图片里）⇒ `wal_dir_roots` 采用
   "读配置 `wal_dirs`/`dn_wal_dirs` → 探测 `data/wal`、`data/datanode/wal` → `find` 兜底"的**动态定位**，
   不写死路径；首轮跑 W-00 时把真实目录结构打出来，之后可收紧。
3. **压缩后的可观测性**：无日志、无专用目录约定，但**有指标**（`wal_buffer{name="wal_compress_cost"|"wal_uncompress_cost"}`）
   与**段级设计**（每段头 1 字节标 compressionType、< 32KB 不压、文件级靠 `WALFileVersion` magic 兼容）。
   ⇒ W-11 以"总体积 + `wal_compress_cost` 指标 + 重启后可恢复"判定，压缩率只 WARN；
   **W-13（压缩/未压缩共存）由"无依据"升级为"设计支持、可构造"**：同目录下"老段未压缩 + 新段压缩"应能完整恢复，
   失败即真发现（留逐副本证据），不预先降级。
4. **`wal_mode=DISABLE` 在流模式下被拒**只在《软件测试文档》里以一条启动 ERROR 出现（不是需求/设计文档），
   源码印证见 `source_grounding.md`；这是 W-02 的判据来源。
5. **IoTConsensusV2 完全未提及**（三份文档都没写）⇒ 双协议对照（W-26）只作差异记录，不作文档符合性判定。
6. **OBJECT 的 WAL 引用格式/校验和/"写入成功未落盘时重启是否必须可恢复"未提及**；
   导入导出/LOAD 一期写的是"二期评审时继续补充" ⇒ W-19/W-20 只断言"可读且与写入前一致"，不声称覆盖全部语义。

## 5. 安全/权限类需求（需求分析"自查内容"）的落法

| 需求 | 落法 |
| --- | --- |
| 配置修改需系统管理员权限 | W-22 里以非 SYSTEM 用户执行 `SET CONFIGURATION` 必须被拒（复用 CR-14 的做法） |
| 配置项修改需记录到审计日志 | 有审计库时查 `root.__audit`，没有则 WARN（环境相关） |
| WAL 文件加密（"高安全场景需加密"） | **需求文档只写"需要"、未给参数名**；源码印证若找不到开关 ⇒ 记为"未实现/不可测"+WARN，不判 FAIL |
| 内存占用受控、防 OOM | W-18：无 `OutOfMemoryError` 是**硬断言**；内存绝对值只作证据 |

## 6. 与其它 skill 的去重

| 本 skill 用例 | 与谁去重 |
| --- | --- |
| W-19/W-20（OBJECT WAL/重启） | `crud_skill` CR-11/CR-12（OBJECT 删除与 GC）、合并 skill CO-41（OBJECT TTL）——本 skill 只做"WAL/重启恢复"这一面 |
| W-08/W-09（文件轮转/buffer） | 合并 skill 的文件数观测是 TsFile，本 skill 是 WAL 文件，**不重叠** |
| W-25（盘 readonly） | 合并 skill DT 系列（磁盘 readonly 高可用场景）——本 skill 聚焦"WAL 写入受阻后的数据一致性" |
| 收尾三件套 | 与所有 skill 一致（sync lag → 逐 DN 停机比对 → CN/DN 日志扫描） |
