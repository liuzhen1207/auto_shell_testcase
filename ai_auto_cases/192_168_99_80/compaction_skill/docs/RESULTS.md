# 合并专项 skill —— 实测结果（RC6 / 3C3D / IoTConsensus）

**环境**：3C3D（192.168.99.77/78/79，各 1 CN + 1 DN），RF=3，data region 协议 `IoTConsensus`，
build **`v20121rc6_1010_7ae8713e`（2.0.12.1 / 7ae8713e）**。
**公共口径**：`inner_compaction_candidate_file_num=2`、`compaction_schedule_interval_in_ms=1000`；
写入阶段三类合并**全关**（`CMP_EXTRA_WRITE`），写完记基线后**热开**要验证的那类合并再观察
（否则合并在写入期间就完成，基线之后不再有推进 ⇒ 会误判"合并未推进"）。
每条用例末尾固定**收尾三件套**：sync lag 归零 → 所有在线节点为基准、**逐个停 1 个 DN** 再查并比对
→ CN/DN 日志扫 NPE/OOM/越界/overlap/`CompactionTableSchemaNotMatchException` 等 ERROR。

**最终结果：41 条用例（CO-01~CO-32 + DT-01~DT-09）= PASS 40 / FAIL 1**，来源：`results/final_results.csv`（每用例最后一条）、
`results/test_result_all_rounds.csv`（多轮原始）、`results/<ID>_<runid>.out`（逐条完整输出）、
`results/DT_final_evidence.tgz`（DT 批证据包）、`results/SUITE_*.out`（集合汇总）、`results/perf_baseline.csv`。
唯一 FAIL 是 **DT-07**（视图列类型修改触发 ConfigNode NPE，功能面断言全 PASS），属**产品缺陷门禁**，
根因与修复建议见 `docs/DEFECT_view_column_datatype_procedure.md`；DT 批的需求映射见 `docs/DATATYPE_CHANGE.md`。
> **跑法与轮次**：第 1 轮全量（14:32→16:39，`tools/run_full_chain.sh`）暴露了 16 个**用例自身**的问题
> （不是产品缺陷，逐条列在下面第 4 节）；第 2/3 轮定点复跑（16:58→19:49，`tools/run_rerun_chain.sh`
> + `tools/run_rerun2_chain.sh`）后 **14 条全部 PASS**。
> `results/final_results.csv` 是"每个用例最后一条"的汇总，`results/test_result_all_rounds.csv` 是多轮原始记录。

| 用例 | 覆盖 | 结果 | 耗时 | 关键实测值 |
| --- | --- | --- | --- | --- |
| **CO-01** | 树模型 seq 内部合并（冒烟） | **PASS** | 328s | 写入阶段关合并造 14 个 seq TsFile → 热开 seq 合并 → `finishes 0→12`、TsFile **14 → 6**；`count/sum` 与 `d1` 全序列指纹不变；无卡死线程 |
| **CO-02** | 表模型 seq 内部合并（冒烟） | **PASS** | 326s | `count=5400`；11s 内 `finishes 0→12`、TsFile **14 → 6**；`dev=d1` 全序列指纹不变 |
| **CO-03** | unseq 内部合并（冒烟） | **PASS** | 349s | 乱序时间戳造 unseq 文件 → 热开 unseq 合并 → unseq 文件数下降、指纹不变 |
| **CO-04** | 跨空间合并 + `min_cross_compaction_unseq_file_level` 负/正对照 | **PASS** | 527s | **A 相（=1 默认）**：inner 合并有推进、**cross finishes 不增**（level=0 的小 unseq 被正确拦住）；**B 相（改成 0 重启、数据保留）**：`cross finishes 0 → 12`、unseq **6 → 0**、count/sum/min/max 与 d1 全序列指纹不变、日志无 overlap |
| **CO-05** | DELETE 数据后合并（树 + 表） | **PASS** | 523s | 删除后行数 1800→900（与期望一致）；树/表合并均完成（finishes 0→12、TsFile 12→6）；**合并前后行数不变、指纹一致 ⇒ 删除行未复活**；表模型 DELETE 1800→900 |
| **CO-06** | 元数据变更后合并（DELETE TIMESERIES / DROP DATABASE 重建 / DROP TABLE / DELETE DEVICES） | **PASS** | 718s | 删时序后元数据减少且合并后仍不存在；删库重建后仍可写可合并；`DROP TABLE t3` 后 `SHOW TABLES` 不含 t3；`DELETE DEVICES d1` 后 d1 无数据（合并未复活）；无 `CompactionTableSchemaNotMatchException` |
| **CO-07** | 24 组（数据类型 × 编码） | **PASS** | 445s | 24/24 组合全部建成（int32/int64/float/double/boolean/text/string/timestamp × plain/rle/ts_2diff/zigzag/gorilla/dictionary）；合并前后 `select *` 全库与逐序列指纹逐字节一致、结果表头（类型）不变；**本构建拒绝的字面量**：`'Infinity'` / `'-Infinity'`（引号字符串与 DOUBLE 不兼容）——用例自动回退普通值并只记 WARN；`NaN`（裸写）、int32/int64 极值、含空格与双引号的中文文本**均被接受** |
| **CO-08** | 对齐序列 + 空值 | **PASS** | 352s | 对齐设备 d1(s1,s2,s3) 与非对齐设备 d2(s1) 按不同节奏写入制造 null；合并完成且 null 出现次数不变、全库与 4 条序列指纹全部一致 |
| **CO-09** | conf 模板 35 个合并参数 + 行为对照 | **PASS** | 655s | 模板里 **35/35** 键齐全；生效值校验（`enable_seq_space_compaction`/`inner_compaction_candidate_file_num`/`compaction_schedule_interval_in_ms`）；**负向**（关 seq + candidate=100）窗口内 **0 次合并**；**正向**（seq=true + candidate=2）同场景合并推进（TsFile 下降）；两相指纹一致 |
| **CO-10** | 参数热加载 | **PASS** | 450s | 热关 seq 合并 → 写入不合并；**热开 → 不重启**立即合并（窗口内推进）；10 个参数逐项校验不变量：8 个模板标注 `hot_reload` 的键 **CLI 不要求重启且生效值 0~1s 内变化**，`compaction_schedule_interval_in_ms` / `compaction_priority`（标注 `restart`）**要求重启且生效值不变** |
| **CO-11** | 合并性能基准 | **PASS** | 478s | 首轮小规模：10 设备 × 3000 点 × 6 批 = **180000 点**；输入 36 个 TsFile/89994B → 输出 12 个/78714B；**合并耗时 7s = 25714 点/秒；写放大 0.87**（写入 89994B → 输出 78714B）；已写入 `results/perf_baseline.csv`（跨版本回归对比用；同 build 偏差 >2× 只 WARN） |
| **CO-12** | 缩容 REMOVE DATANODE / CONFIGNODE | **PASS** | 645s | **负向守卫**：RF=3 时 `REMOVE DATANODE` 被正确拒绝（`1003: Cannot remove 1 DataNode(s): … must retain at least 3`，集群仍 3 DN）；**正式缩容**：`SCHEMA_RF/DATA_RF=2` 重启后 REMOVE DATANODE → 剩 2 DN（`Msg: The statement is executed successfully.`），经剩余节点查询 count/sum 与基准一致；缩容后再写 2 批仍能合并；REMOVE CONFIGNODE → 剩 2 CN、集群仍可用；收尾按剩余节点做 sync lag/日志（RF=2 下不做"停 1 个 DN"校验——停 1 个就没有多数派了，实测会得到 `721: Fetch Schema failed`，属正常） |
| **CO-13** | **TTL 场景（树）**：TTL 过期清理（settle 合并）与在线合并组合 | **PASS** | 567s | ①过期批次（48h 前，整设备）写入后可见 1800 行 → ②`SET TTL=24h` 后查询侧 **0 行** → ③settle 合并在 ~25s 内动作（`SettleCompaction task starts` **+6**、TsFile 6→0，过期文件被物理删除）→ ④再写新鲜设备 2 批：TTL 生效期间过期数据**未复活**（count=3600）、在线合并推进、指纹不变 → ⑤`SET TTL=30s` 后 **count=0** 且合并产物被二轮 settle 清理（settle +6）→ ⑥`UNSET TTL` 后 **0 行**（已物理删除，合并没有复活） |
| **CO-14** | **TTL 场景（表）**：同上，TTL 挂在表上 | **PASS** | 570s | 与 CO-13 同构、结果一致（表 TTL 由 `ALTER TABLE … SET PROPERTIES ttl=` 设置；`0 all-outdated → settle 动作 → 合并产物同样被清理 → ttl='INF' 后 0 行`） |
| **CO-15** | **参数组合①**：门控开关 8 组合矩阵 + 合并优先级 + 极端值组合 | **PASS** | 1653s | 八种 `enable_seq/unseq/cross` 组合全部符合门控语义（见下节矩阵）；`compaction_priority` 三种取值都完成 inner+cross 合并且指纹一致；极端值组合（线程/限流/层级/上限全极端）无卡死、无数据损坏 |
| **CO-16** | **参数组合②**：selector×performer 组合 + chunk 组合 + 非法值门禁 | **PASS** | 897s | seq selector×performer 4/4、unseq 4/4、`cross_performer` 2/2 全部合并推进且指纹不变；chunk 组合（小目标 chunk + 大反序列化门槛）合并仍正确；**非法值门禁发现产品问题**（见下节） |
| **CO-17** | **参数组合③（边界）**：层级 gap 边界 + 任务文件数上限×候选门槛 + cross 候选上限截断 | **PASS** | 718s / 722s（**连续两轮 PASS**） | `max_level_gap_in_inner_compaction` 在**同一场景**上卡边界：`[L1,L0]` gap=0 不合并 / gap=1 → **L2**，`[L2,L0]` gap=1 不合并 / gap=2 → **L3**；`inner_compaction_total_file_num_threshold` =2 时单任务只收 2 个文件（3→2）、=100 时收 3 个（3→1），且非活跃分区下 2 < 候选门槛 3 仍提交；cross 每任务 unseq 数：`num=2` → 1、`num=500` → 3、`num=500+size=1B` → 1（size 上限也真的截断） |

## 3. 参数**组合**测试（`--set combo`，CO-15/CO-16/CO-17，2026-10-13 新增）

单参数用例（CO-09/CO-10/CO-04）只能证明"某个键有作用"，证明不了**参数之间**的相互作用。

### CO-15 门控开关矩阵 + 合并优先级 + 极端值组合

**段 1：`enable_seq/unseq/cross` 三种开关的 8 种组合**（全热改；每组合一个独立库，写入"2 批 seq + 2 批更早的乱序"，
按 `Sequence`/`Unsequence InnerSpaceCompaction` 与 `CrossSpaceCompaction` 分开计数）：

| seq | unseq | cross | SequenceInner | UnsequenceInner | Cross | TsFile |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | 1 | +8 | +4 | +8 | 14 → 6 |
| 1 | 1 | 0 | +4 | +4 | **+0** | 14 → 10 |
| 1 | 0 | 1 | +8 | **+0** | +12 | 14 → 6 |
| 1 | 0 | 0 | +4 | **+0** | **+0** | 14 → 12 |
| 0 | 1 | 1 | **+0** | +4 | +8 | 14 → 10 |
| 0 | 1 | 0 | **+0** | +4 | **+0** | 14 → 12 |
| 0 | 0 | 1 | **+0** | **+0** | +12 | 14 → 12 |
| 0 | 0 | 0 | **+0** | **+0** | **+0** | 14 → 14 |

⇒ **八种组合全部符合门控语义**：关掉哪一类，那一类就一次都不跑；每组合的 `count/sum` 指纹都与合并前完全一致。
附带证据：**cross 只受 `enable_cross_space_compaction` 控制**（`seq=0 unseq=0 cross=1` 时 cross 照样跑 +12），不依赖另外两个开关。

**段 2：`compaction_priority` 三种取值**（restart-only，各重启一次）：

| 取值 | 结果 | 首个推进的类型 |
| --- | --- | --- |
| INNER_CROSS | inner +8、cross +10，指纹一致 | **inner**（与语义一致 ✓） |
| CROSS_INNER | inner +8、cross +8，指纹一致 | inner（**与语义预期 cross 不符 → 记 WARN**） |
| BALANCE | inner +8、cross +10，指纹一致 | inner（BALANCE 不限定顺序 ✓） |

> 观察（WARN，非缺陷判定）：`CROSS_INNER` 语义是"优先跨空间合并、先消掉乱序文件"，但本轮 3s 轮询看到的
> 首个推进类型是 inner。可能是**观测竞态**（两者几乎同时启动、inner 更快完成），也可能优先级只影响任务
> 入队顺序。三种取值下合并本身都正确完成，故不判 FAIL；建议后续用"`task starts` 日志先后"级别的证据再确认。

**段 3：极端值组合**（`compaction_thread_count=1`、`sub_compaction_thread_count=1`、读/写限流 =1、
`max_level_gap_in_inner_compaction=1`、`inner_compaction_total_file_num_threshold=1`、
`inner_compaction_task_selection_disk_redundancy=0.99`，逐键确认生效）：TsFile 14→12（有推进）、
**数据指纹完全一致、无合并线程卡在 `TsFileResource.writeLock`**。

### CO-16 selector × performer 组合 / chunk 组合 / 非法值门禁

**段 1：`inner_seq_selector` × `inner_seq_performer`（4 组合，全热改）**

| selector | performer | 结果 | 实测 |
| --- | --- | --- | --- |
| size_tiered_single_target | read_chunk | PASS | `finishes 0→2`、TsFile 8→6、指纹一致 |
| size_tiered_single_target | fast | PASS | `0→4`、8→6、指纹一致 |
| size_tiered_multi_target | read_chunk | PASS | `0→4`、8→6、指纹一致 |
| size_tiered_multi_target | fast | PASS | `0→4`、8→6、指纹一致 |

**段 2：`inner_unseq_selector` × `inner_unseq_performer`（4 组合，全热改）**：4/4 PASS，每组合
`Unsequence InnerSpaceCompaction finishes 0→4` 且指纹不变。
（⚠️ 造场景要求：先写 1 批**水位**（当前时间）再造 2 批**互相重叠**的更早数据；unseq 内部合并要求文件区间重叠，
第一版写成"两批互不重叠的更早数据"时 0 次合并——属场景问题，不是产品问题。）

**段 3：`cross_performer` ∈ {read_point, fast}**：2/2 PASS —— `cross finishes 0→4 / 0→2`、`unseq 2→0`、
重叠区间取值正确（d1 全序列指纹一致）、总行数不变（750）。

**段 4：chunk 组合**（restart：`target_chunk_size=4096`、`target_chunk_point_num=10`、
`chunk_size_lower_bound_in_compaction=8192`、`chunk_point_num_lower_bound_in_compaction=1000`、
`chunk_metadata_size_proportion=0.9`）：5 个键全部确认生效；合并推进 `finishes 0→2`、
**数据指纹与总行数（600）均不变**（强制走"chunk 反序列化成点再写"的路径仍然正确）。

**段 5：非法值门禁 —— 研发已确认「`SET CONFIGURATION` 设计上不校验取值」，按现状记录 + 强制自清理**

| 探针 | CLI 返回 | properties 是否被改 | 之后 DN 重启 |
| --- | --- | --- | --- |
| `compaction_priority=BOGUS` | **成功**（仅提示 `restart is required`） | 是（三节点） | **起不来**（`No enum constant …CompactionPriority.BOGUS` + `System.exit(-1)`） |
| `inner_seq_selector=bogus` | 报错 301 | **是**（报错也落盘） | **起不来** |
| `compaction_thread_count=abc` | 报错 301 | **是**（报错也落盘） | **起不来**（`NumberFormatException`） |
| `inner_compaction_candidate_file_num=-5` | 成功、无报错 | 是 | 可启动（无范围校验，负数被接受） |

**定性（2026-10-13 研发反馈）**：*"设计的时候应该就是按不校验做的，有些不合法检查也没法提前判断出来；
先记录为研发已知，设计如此。"* ⇒ **不作为缺陷跟踪**。本段只做两件事：
① 把 CLI 原始返回原样打进日志（供后续版本对比行为是否变化）；
② **保证用例自清理、不留脏数据** —— 每个探针后立刻 `SET` 回合法值，段末逐节点 `grep` 校验
`^[a-z_]+=(BOGUS|bogus|abc|-5)$` 必须为 0（只查未注释行：`SET` 覆盖旧值是"注释掉旧行 + 追加新行"）。
收尾的"逐个停/起 DataNode + 副本一致性"本身就是**隐式硬门禁**：只要残留非法值，DN 起不来、一致性校验必然 FAIL。

**给运维/测试的注意事项（本次实测踩过）**：非法值会让 DN 在**下次重启**时起不来；
且 DN 是"先写文件、再热加载"（`StorageEngine` L790-807），**报错 301 时文件已经被改**；
节点离线后拿不到集群配置下发、**不能自愈**，必须手工改该节点 `iotdb-system.properties` 才能恢复。
完整说明与源码位置见 `docs/NOTE_set_configuration_value_validation.md`。

### CO-17 层级 gap / 任务文件数上限 / cross 候选上限的**边界**

> 最终状态：**连续两轮 PASS**（`elapsed=718s` / `722s`，fail_flag=0，RC6 `7ae8713e` / 3C3D / IoTConsensus），
> 证据 `results/CO17_final.out`；中途 3 轮 FAIL 全是**用例侧**问题（选错 selector / 副本布局竞态 / cross 日志正则），
> 逐条列在第 4 节事故 17~19。`results/test_result_all_rounds.csv` 保留了 5 轮的完整历史。

**前置纠正（这是本用例第一版 FAIL 的根因，也是本 skill 最重要的一条领域知识）**：
`inner_seq_selector` 的取值 ↔ 实现类是"反直觉"的（`selector/constant/InnerSequenceCompactionSelector.java:52-60`）：

| 取值 | 实现类 | 会读哪些选择参数 |
| --- | --- | --- |
| `size_tiered_multi_target`（**模板默认值**） | `NewSizeTieredCompactionSelector` | `inner_compaction_candidate_file_num`、`inner_compaction_total_file_num_threshold`、`max_level_gap_in_inner_compaction`、`target_compaction_file_size`（**会跨层级合并**） |
| `size_tiered_single_target` | `SizeTieredCompactionSelector`（经典） | 只有 `inner_compaction_candidate_file_num` + `target_compaction_file_size`（**不跨层级、不看 gap/文件数上限**） |

⇒ 第一版 CO-17 为了"用 single target 语义"把 selector 设成 `size_tiered_single_target`，等于**把被测参数摘掉**，
gap=1 时当然合不出 L2（当时我误以为是产品缺陷）。改成默认的 `multi_target` 后，边界行为完全符合源码语义。

**段 1：`max_level_gap_in_inner_compaction` 层级边界**（场景：单设备 + 每批时间戳递增 ⇒ 全部落 sequence 空间；
每批写完等 close 事件再写下一批，保证各副本层级布局一致）

| 场景（各副本一致） | 配置 | 观测 | 结论 |
| --- | --- | --- | --- |
| `[L1(旧), L0(新)]`（写 2 批 → 合并出 L1 → 再写 1 批） | `gap=0` | 45s 内 `finishes 6 → 6`、布局仍 `1/1/0/0` | `\|0-1\|=1 > 0` ⇒ **不合并** ✓ |
| 同上 | 热改 `gap=1` | 布局 → `0/0/1/0`（各副本 1 个 **L2**） | `\|0-1\|=1 ≤ 1` ⇒ 合并，产物层级 = max+1 = **2** ✓ |
| `[L2(旧), L0(新)]`（再写 1 批） | `gap=1` | 45s 内 `finishes` 不增、布局仍 `1/0/1/0` | `\|0-2\|=2 > 1` ⇒ **不合并** ✓ |
| 同上 | 热改 `gap=2` | 布局 → `0/0/0/1`（各副本 1 个 **L3**） | `\|0-2\|=2 ≤ 2` ⇒ 合并，产物层级 = **3** ✓ |

数据指纹（`count/sum`）在 A、B 两段合并前后均完全一致。

**段 2：`inner_compaction_total_file_num_threshold`（单任务文件数上限）× `inner_compaction_candidate_file_num`（提交门槛）**

| 场景（各副本 3 个 L0） | 配置 | 实测 | 结论 |
| --- | --- | --- | --- |
| 3 个 L0 | `threshold=2`、`candidate=3`、`gap=0` | 日志 `starts with 2 files`（分布 `2×6`）、布局 3 → `1/1/0/0` | 单任务**最多 2 个文件** ⇒ 上限生效 ✓；且"只选了 2 个 < 门槛 3"仍被提交 ⇒ **非活跃分区绕过候选门槛**（源码 `\|\| !isActiveTimePartition`）✓ |
| 3 个 L0 | `threshold=100`、`candidate=2`、`gap=0` | 日志 `starts with 3 files`、布局 3 → `0/1/0/0` | 上限放大后一个任务收下全部 3 个 ⇒ 上限确实来自该键 ✓ |

**段 3：`max_cross_compaction_candidate_file_num` / `_file_size` 截断**（场景：每副本 1 个 seq 水位 + 3 个互相重叠的更早 unseq）

| Run | 配置 | 实测（每任务 unseq 数分布） | 结论 |
| --- | --- | --- | --- |
| A | `num=2`、size 默认 5GB | `1×18`（每任务 1 个 unseq）、任务数 18 | 文件数上限把任务卡在"1 unseq + 1 seq" ✓ |
| B | `num=500`（默认）、size 默认 | `3×6`（一个任务收下全部 3 个 unseq）、任务数 6 | 上限放大后能一次收完 ✓ |
| C | `num=500`、`size=1B` | `1×18`（每任务仍只有 1 个 unseq）、任务数 18 | **文件大小上限**同样在截断 ✓ |

三段 cross 合并后 unseq 都归零、`count/sum` 指纹不变、无 overlap 异常。
（日志证据的关键字是 `[Compaction] CrossSpaceCompaction task starts with N seq files and M unsequence files`
——不是 `N files`，且必须排除 `InsertionCrossSpaceCompaction`；两处都踩过。
另外场景必须让 unseq 与 seq **时间区间重叠**：不重叠时 `RewriteCrossSpaceCompactionSelector` 会走
`getLatestSealedSeqFile()` 特殊路径，实测一个任务最多只收 2 个 unseq，上限 500 也收不满 3 个。）


### CO-18 ~ CO-32 逐参数基础功能 + 基础形态/生命周期（2026-10-14 新增，用例数 17 → 32）

背景：用户要求"**根据源码，不同参数功能应该覆盖最基础的合并场景**（17 条太少）"。
先把 35 个 compaction 键逐个对照源码的使用点做成覆盖清单（`docs/PARAM_COVERAGE.md`），
再按清单补 **15 条**用例（`--set param2` / `--set scene`）。实测（RC6 `7ae8713e` / 3C3D / IoTConsensus）：

| 用例 | 覆盖 | 结果 | 耗时 | 关键实测值 |
| --- | --- | --- | --- | --- |
| **CO-18** | `compaction_priority` 三取值（1 线程去竞态） | **PASS** | 1258s | 用 `compaction_thread_count=1` + `inner_compaction_total_file_num_threshold=2`（一轮产生多个 inner 任务）与 cross 竞争队列；三取值下两类任务都执行（I=21、C=3）、指纹一致。**观察（不判缺陷）**：三取值"首个 Cross 完成位置"都是第 8 位 ⇒ 该场景下优先级不影响执行顺序——源码 `DataRegion.executeCompaction` 每轮**先选 inner、再选 cross**，首个 inner 任务早已开跑，优先级只在"同类型任务同时在队列里"时体现 |
| **CO-19** | 乱序空间的 `inner_unseq_selector` × 文件数上限 × gap | **PASS** | 264s | 文件数上限=2 ⇒ `starts with 2 files`（分布 `2×6`）；热改 gap=1 ⇒ unseq 空间 `[L1,L0]` 合并（`finishes 6 → 12`，布局 `1/0/1/0`） |
| **CO-20** | `target_compaction_file_size`（1KB vs 默认 2GB） | **PASS** | 325s | **分片生效：小 target 产物 8 个 > 默认 6 个**（同一 6 设备场景，源码 `InnerSpaceCompactionTask:314-320`） |
| **CO-21** | `inner_compaction_total_file_size_threshold` | **PASS** | 301s | 阈值=2000 ⇒ 装不下两个文件 ⇒ **不提交任务、不合并**（布局仍 4×L0）；热改 10000 ⇒ 4 个 L0 一次并成 1 个 L1 |
| **CO-22** | `candidate_compaction_task_queue_size` | **PASS** | 453s | 队列=1（4 seq + 2 重叠 unseq、1 线程）下 unseq 归零、TsFile 数下降（6 → 2）、**无写锁卡死线程**、指纹不变；重启成 64 复跑同样 PASS |
| **CO-23** | 线程族（`compaction_thread_count`/`sub_compaction_thread_count`/`compaction_schedule_thread_num`） | **PASS** | 661s | 每个 DN 执行 `jstack` 计数：1 线程配置下恰好 **1 个 `IoTDB-Compaction-Worker`**；热改 3 ⇒ 线程池重建后 **3 个**；三种配置下 3 个库的合并全部完成且指纹不变 |
| **CO-24** | `compaction_max_aligned_series_num_in_one_batch` | **PASS** | 395s | 8 条对齐序列 × 3 批，取值 1 / 8 / 0（不分批）三种都 `finishes 0→4/0→2/0→4`、8 条序列指纹与合并前完全一致 |
| **CO-25** | 限流三件套（写/读 MB/s + 读操作/s） | **PASS** | 703s | TEXT 1KB×3000×2 批（≈6MB）：默认限流与 1MB/s+1MB/s+50 IOPS 两相都完成合并、行数与前 2 行内容一致，**耗时明显变长**（限流确实作用于合并路径） |
| **CO-26** | settle 选择门控（mods 阈值 / 磁盘冗余） | **PASS** | 541s | 默认 mods 阈值(128KB)+磁盘充足 ⇒ **不重写**；热改阈值=1B ⇒ 出现 `partially_dirty` settle 任务并**清理 `.mods`**；`disk_redundancy=0.999` ⇒ `isDiskHasSpace=false` 同样触发重写（三场景删除后的行数都不变） |
| **CO-27** | 基础形态：单文件 no-op / 空库 / 全删 / 多时间分区 | **PASS** | 661s | 单文件不合并（finishes 不增）；空库无文件无临时文件；全删后合并仍执行且 **行数 0 不复活**；一个 region 跨两个时间分区（相隔两周）⇒ 每个分区各自并成 1 个 L1、各副本一致 |
| **CO-28** | **表模型** unseq 内部合并 + 跨空间合并 | **PASS** | 421s | unseq 内部合并 `finishes 0 → 4`；cross 后 **unseq 归零**、指纹一致、行数 1240 不变（补齐表模型缺口） |
| **CO-29** | 合并中 `kill -9` 一个 DN → 恢复；整体重启 | **PASS** | 816s | 合并进行中杀掉 `.78` → 其余副本照常完成；重启后 **三副本一致（逐个停 DN 比对全 PASS）**、**无残留 `*.compaction.log`/`*.tmp`**、之后仍能继续合并；整体重启后布局与指纹不变 |
| **CO-30** | **插入式**跨空间合并（`InsertionCrossSpaceCompaction`） | **PASS** | 254s | 1 seq 水位 + 3 个互不重叠的更早 unseq ⇒ **插入任务被触发**（源文件直接挪进 seq 空间）、unseq 归零、指纹与行数不变 |
| **CO-31** | 合并与读写并发 | **PASS** | 536s | 限流把合并拖长后，期间后台写 6 小批 + 查询：**0 条错误输出**、合并仍推进、写入数据都在、收尾三件套全绿 |
| **CO-32** | `enable_auto_repair_compaction` 开/关 | **PASS** | 365s | 两相都完成合并且指纹一致，且都**没有误报** `RepairUnsortedFileCompactionTask`（真造未排序文件需 load 路径，已如实记录为超范围） |

**这一轮踩到的 harness 坑（都已修，值得记住）**：

1. **大 payload 不能用 `sq`（`timeout CLI -e "<200KB SQL>"`）**：Linux 参数长度上限会报
   `Argument list too long`，而且**静默不落盘**（表现为"布局 0/0/0/0、合并没发生"）。
   CO-25/CO-29/CO-31 改成**单会话 stdin**（`session_tree`）喂语句后正常。
2. **`local x` 声明但没赋值 + `set -u` + `$(( x + 1 ))` ⇒ `x: unbound variable`**
   （CO-25/CO-29 各中一次）；`local ... i=0` 才是安全写法。
3. **同一场景里的批次时间戳必须互不重叠**：批次跨度大于批次间隔时，后一批会落进 **unseq** 空间
   ⇒ 布局每批 +2（CO-22/CO-18 首轮都踩到，前者侥幸 PASS、后者判据失真）。
   正确写法：间隔 100s、每批只跨 2s；要造 unseq 就把它放在 seq 水位区间**内**且小于水位最大值。
4. **用例脚本不要在运行中被覆盖**（老坑复发）：CO-30 第一次跑时脚本被 scp 覆盖成半截内容
   （`co30_wate: command not found`）⇒ 水位批没写、场景退化成"全是 seq"、判据 FAIL。
5. **`compaction_priority` 不能用"第一个完成的类型"判**：调度器每轮**先选 inner、再选 cross**，
   首个 inner 任务早已开跑；1 线程 + 常规场景下三种取值的"首个 Cross 完成位置"完全相同（都是第 8 位）
   ⇒ 本用例改成"比首个 Cross 位置 + 记录观察"（不判缺陷）。
6. 15 条新用例最终 **15/15 PASS**（`results/B6_chain.out` 为最后一轮；各条耗时见上表）。

## 3.6 修改数据类型 × 合并 / 高可用（DT-01 ~ DT-09，2026-10-14 新增）

需求来源：《修改数据类型手册更新内容》（树模型 `ALTER TIMESERIES … SET DATA TYPE`、表模型
`ALTER TABLE … ALTER COLUMN … SET DATA TYPE`、树转表视图 `ALTER VIEW … ALTER COLUMN … SET DATA TYPE`），
用户追加要求"与合并并发 + 高可用（磁盘 readonly、节点正常 stop）"。需求点 → 用例映射见
`docs/DATATYPE_CHANGE.md`；每个需求点都有对应用例与判据。

| 用例 | 覆盖 | 结果 | 耗时 | 关键实测值 |
| --- | --- | --- | --- | --- |
| **DT-01** | 树模型基础 + 兼容性矩阵（10 类型 / 30 条转换） | **PASS** | 693s | 30/30 转换成功、`show timeseries` 类型三副本一致、行数不减、值按新类型可读（`11 → 11.0`）；实测 TIMESTAMP 测量列**只接受不带引号**的字面量，设备名不能叫 `TIMESTAMP`（解析 700） |
| **DT-02** | 树模型负向（不兼容/不存在） | **PASS** | 299s | 6 组不兼容全部 507 且**类型与数据不变**；不存在序列/库 508；链式转换逐步正确 |
| **DT-03** | 树模型 × 合并（改后合并 / 合并中改类型 / 混合 schema 合并） | **PASS** | 752s | A：新旧类型混合文件合并（finishes 0→6、TsFile 6→3、值 `11.0\|12.0\|1.25\|2.75\|` 不变）；B：限流 1MB/s 下 **合并进行中 ALTER 成功**（30→6 文件、finishes 0→12，TEXT 6×100KB 载荷与 INT32 指纹均不变）；C：INT32/DOUBLE/TEXT 同库合并（0→4、8→6）三序列指纹全一致 |
| **DT-04** | 树模型并发（并发删除 / 并发写入） | **PASS** | 400s | ①先删后改 → 508；②`ALTER ∥ DELETE TIMESERIES` 8 轮**每轮最终态自洽**（3 轮 DOUBLE、5 轮序列已删除、0 轮不明确）；③`ALTER ∥ 连续写入` 10/10 写入成功且数据不丢、类型保持 DOUBLE；④无 `TsFileResource.writeLock` 卡死 |
| **DT-05** | 表模型基础（FIELD-only、兼容性、值转换） | **PASS** | 236s | 值转换硬断言：`42\|43\| → 42.0\|43.0\|`、`abc\|def\|`、`2.5\|3.5\|`；TAG/时间列 701、不兼容 701、不存在列 616、不存在表 550 |
| **DT-06** | 表模型 × 合并（顺序空间 / 跨空间 / 并发 DROP） | **PASS** | 297s | A：finishes 0→2、TsFile 6→5、值不变；B：**与 seq 重叠**的乱序文件 unseq **4→0**，**真实 `CrossSpaceCompaction` finishes 0→8**，值不变；C：并发 `DROP TABLE ∥ ALTER COLUMN` 双方成功、删除后 550、`SHOW TABLES` 无残留 |
| **DT-07** | 树转表视图列类型修改 × 底层合并 | **FAIL** fail_flag=3（**功能面断言全 PASS**，3 条 FAIL 全部来自 CN NPE 门禁） | 236s | 视图读数 `7\|8\| → 7.0\|8.0\|`（硬断言）、`desc` 更新为 DOUBLE、不兼容 701、不存在列 616、底层合并后视图读数不变；**ConfigNode follower 抛 `NullPointerException` / `Unknown Procedure type: 766`** ⇒ `ProcedureFactory.create()` 漏 `ALTER_VIEW_COLUMN_DATATYPE_PROCEDURE` 分支（缺陷定位见 `docs/DEFECT_view_column_datatype_procedure.md`） |
| **DT-08** | 高可用：合并期间磁盘 readonly | **PASS** | 1022s | 整盘 `mount -o remount,ro /data` 在本环境必 EBUSY（有进程持有可写 fd）⇒ 用"自绑定 + `remount,ro,bind`"把数据根变只读，**硬校验**（`touch` 返回 EROFS）才算注入成功；只读窗口内 .77/.78 各并成 1 个文件、**受害副本仍 2/0/0/0**（写不了新目标），数据指纹/行数/1KB 载荷原文不变；恢复可写 RW_OK、节点自动回 Running；该 region **180s 内不自动重试**（WARN，见下）⇒ 重启该 DN 触发 region 恢复后 **4s 内三副本布局收敛一致**、TsFile 6→3、finishes 4→6 |
| **DT-09** | 高可用：节点正常下线（TERM）+ `kill -9` 对照 | **PASS** | 852s | A 合并中优雅停 1 DN ⇒ 一致且收敛；B 停 1 CN ⇒ 写入成功、**合并仍推进**（finishes 6→10、TsFile 9→6）；C 停 2 CN（无 CN 多数派）⇒ DML 与已有库上的 DDL 都成功且数据/元数据一致（数据区/模式区共识都在 DN 上，架构如此）、读可用；D 改类型期间停 DN ⇒ 恢复后类型仍 DOUBLE、三副本各 2 行；E `kill -9` 对照 ⇒ 指纹/行数一致、无残留临时文件 |

**DT 汇总：9 条用例，8 PASS + 1 FAIL（DT-07 为缺陷门禁，功能面断言全 PASS）**，
汇总见 `results/final_results.csv`（**CO 32 条 + DT 9 条 = 41 条，PASS 40 / FAIL 1**）、
`results/DT_final_evidence.tgz`（9 条 DT 的最终输出 + 多轮 CSV + 链日志）。

**本轮发现（写进 `docs/DATATYPE_CHANGE.md`，细节见该文件 §三）**：

1. **缺陷候选（已定位到源码）**：`ALTER VIEW … ALTER COLUMN … SET DATA TYPE` 的 procedure 类型 766
   （`ALTER_VIEW_COLUMN_DATATYPE_PROCEDURE`）在 `ProcedureFactory.create()` 里**没有 case**，
   follower ConfigNode 反序列化抛 `IOException: Unknown Procedure type: 766` → `deserializeRequest` 吞异常返回 null
   → `ApplicationStateMachineProxy.applyTransaction:153` 对 null 调方法抛 NPE（每条日志按 apply 重试反复刷）。
   同族 case（765 表模型、ADD/RENAME_VIEW_COLUMN、可写视图、pipe-enriched）都在，**master 同样缺**
   ⇒ 不是回合遗漏而是功能缺陷。完整链条/修复建议/门禁：
   `docs/DEFECT_view_column_datatype_procedure.md`；DT-07 已把"CN 日志出现 NPE"做成硬 FAIL。
2. **"磁盘 readonly" 注入不能用整盘 `remount,ro`**（EBUSY），要用自绑定 + `remount,ro,bind`，
   并且**必须硬校验注入生效**（否则会出现"注入没生效却 PASS"的假通过——首版就是这样）。
3. **只读盘事件后该 region 不会自动重试合并**：合并因 EROFS 失败后留下 target/`*.inner-compaction.log`，
   磁盘恢复可写后 8 分钟无新任务，直到 region 重开（DN 重启）才由 `CompactionRecoverManager` 恢复并完成合并
   （源码：`CompactionRecoverManager.recoverCompaction()` 只在 DataRegion 构造/恢复路径调用）⇒ 记为**待研发确认的观察**。
4. **停 2 个 CN（无 CN 多数派）不等于"写入必须失败"**：DML 与已有库上的 DDL 都仍成功
   （数据区共识在 DN、库的模式区共识也在 DN）⇒ 判据应为"明确结果 + 恢复后一致"。
5. **`stop-datanode.sh -f` 是 `kill -9`**：不带 `-f` 才是 `kill -s TERM`（优雅停）。

**本轮实测的产品行为（写进用例断言/文档）**：

1. **TIMESTAMP 测量列只接受不带引号的字面量**（ISO 或 epoch 毫秒）：带引号一律 `507 data type is not consistent`，
   `CAST(... AS TIMESTAMP)` 报 700 解析失败；`create timeseries root.db.TIMESTAMP.s1`（设备名=关键字）也会 700。
2. **表模型 `SELECT` 只返回投影列**（`select v from t` 每行只有 1 列）——按列序号写的取值 helper 会取到空串，
   让"值可读"判据空转；已改为按表头列名定位（`cmp_tbl_col_vals` 等）。
3. **表模型 Compaction 日志前缀与树模型同形**（`<db>-<regionId> [Compaction] …`）⇒ 按库统计的 helper 通用。
4. **合并 × 改类型可以共存**：三个场景（改后合并、合并中改类型、混合 schema 同库合并）都无 schema 不一致异常，
   合并产物读数与改类型后指纹逐字节一致 —— 这是本轮最关键的正面结论。

**这一批踩到的 harness 坑（都已修）**：

1. **多相共用一个库 ⇒ 前相开着的合并会在本相写入期间把文件并掉**，基线之后不再推进 ⇒ 误判"合并未收敛"
   （DT-03 首轮 B/C 两相都中）。修法：**每相独立库** + 写入前 `cmp_compaction_off` + 写完用 `cmp_wait_lay`
   等布局稳定 + 把"起点 level-0 文件数 ≥2"做成**场景有效性硬断言**。
2. **树方言查询用序列路径会返回空集**（`select s1 from root.db.dev.s1`）⇒ 并发可见性轮询一度恒为 0 行、
   误报"写入丢失"（DT-04）。修法：一律走 `cmp_rows_series`（内部转设备路径）。
3. **表模型取值列号**：见产品行为 2；DT-05/DT-07 修复后新判据实测全部命中（`42|43| → 42.0|43.0|` 等）。
4. **函数返回值用 `$(...)` 捕获时别把 log 一起当返回值**（DT-08 首版）：`RO_ON=$(dt08_ro_on)` 拿到的是
   "明细行 + 判定值"，与 `1` 比较恒不相等 ⇒ 注入明明生效却判 FAIL；改成 `| tail -1` 只取判定值。
5. **注入类场景必须硬校验注入真的生效**（DT-08 首版整盘 `remount,ro` 被 EBUSY 拒，只 WARN ⇒ 假 PASS）；
   恢复也要校验（`RW_OK`），并用 `trap` 保证一定恢复。

## 3.7 DT 批的判据/证据口径（补充说明）

- **每条 DT 用例都跑统一收尾三件套**（sync lag 归零 → 逐个停 DN 比对副本一致性 → CN/DN 日志异常扫描），
  负向场景自带 `CMP_LOG_BENIGN_EXTRA`（数值错误码、只读文件系统、停机噪声）。
- **证据**：`results/final_results.csv`（41 条的最后一条记录）、`results/test_result_all_rounds.csv`（多轮原始）、
  `results/DT_final_evidence.tgz`（9 条 DT 最终输出 + 两份 CSV + 8 份链日志）、
  以及本机 `results/NEWCHAIN_20261014_*.out` 逐轮链日志。
- **判据口径**：合并类用"finishes↑ **且** 该库 TsFile↓"双信号；数据类用"归一化指纹 / 行数 / 1KB 载荷原文"三重比对；
  高可用类额外要求"恢复后三副本布局收敛一致"；缺陷类（DT-07）把日志门禁做成硬 FAIL。

## 4. 性能基线（`--set perf`）


## 关键结论（写给研发/后续版本）

1. **合并基本功能在 RC6 上无问题**：树/表 seq 内部合并、unseq 内部合并、跨空间合并、带 mods 的合并
   （DELETE 后）、元数据变更后的合并、对齐/null、24 组类型×编码，全部"合并推进 + 文件数下降 + 数据指纹完全一致 + 无卡死/无异常日志"。
2. **跨空间合并"不触发"不是缺陷**：`RewriteCrossSpaceCompactionSelector:306` —— 小 unseq 文件
   （size < `target_compaction_file_size`）必须先被内部合并过一次（`innerCompactionCnt ≥
   min_cross_compaction_unseq_file_level`，默认 1）才配参与 cross。只有 1 个 unseq 文件/region 时永远不会触发。
3. **TTL 清理是"文件级 + 设备级"的**：`SettleSelectorImpl.selectFileBaseOnDirtyData()` L255~260 ——
   设了 TTL 的文件里**只要有一个设备还有未过期数据，整个文件直接 NOT_SATISFIED**。
   所以 TTL 清理场景必须让过期数据单独成文件；否则会看到
   `[TTL] … Totally select 0 all-outdated files and 0 partial-outdated files` 永不清理（**符合实现语义，不是缺陷**）。
   另：settle 需要 `enable_seq_space_compaction`/`enable_unseq_space_compaction` 至少一个为 true。
4. **热加载与模板标注一致**：35 个 compaction 键里只有 `compaction_schedule_interval_in_ms` 与
   `compaction_priority` 是 `effectiveMode: restart`，其余 33 个是 `hot_reload`；实测 10 个探针全部符合不变量。
5. **缩容有副本数守卫**：RF=3 + 3 DN 时不允许移除 DataNode（1003），缩容必须先降副本数
   （本用例降到 2 后完成 DN/CN 各移除 1 个，剩 2C2D 仍可读可写可合并）。
6. **性能基线（首轮小规模，供回归对比）**：18 万点合并 7s、25714 点/秒、写放大 0.87；
   完整回归请去掉 `CO_PERF_ROWS=3000` 覆盖（默认 10 设备 × 10000 点 × 6 批 = 60 万点）。

## 本轮 harness 事故与踩坑（细节见 `SKILL.md`「踩坑清单」）

| # | 现象 | 根因 | 修法 |
| --- | --- | --- | --- |
| 1 | CO-02 报 `550: Table 'cosmoketb.t1' does not exist`（假 FAIL） | **两个 `run_all` 并发**：后启动的 `cmp_cluster_prepare` 清掉先启动用例的数据，且互相停集群 | `run_all.sh` 加 `flock` 并发锁；整套跑用 `run_full_chain.sh` 单进程串行 |
| 2 | CO-10 收尾时 2 个 DN 起不来、后续用例连锁 FAIL | `SET CONFIGURATION '<键>'=''`（还原"原本不存在的键"）写出空值行 ⇒ DN 热加载 `NumberFormatException` / `No enum constant CompactionPriority.`、重启失败 | 空值不还原；探测后重写 conf；`cluster_write_conf` 加空值守卫；`tools/fix_broken_conf.sh` 用 `conf_orig` 救回 |
| 3 | 多相用例报"合并未推进" | 上一相已热开合并 ⇒ 本相数据在写入期间被合并完，基线之后无推进（CO-05/06/09/12 都中过） | 每相写入前 `cmp_compaction_off`；合并基线取在写入**之前** |
| 4 | CO-05 报"d1 行数 0 ≠ 150" | 树方言里 `select count(s1) from db.d1.s1`（及 `db.d1.**`）返回 `\|Time\| Empty set.`（聚合被忽略） | 单设备行数改用原始查询数行（`select s1 from db.d1 … \| table_rows \| wc -l`） |
| 5 | CO-06 报"其余设备指纹不一致" | 指纹在"补写数据之前"采集，之后又给同一设备写了新行 | 指纹一律放在本相**全部写入之后**、开合并之前 |
| 6 | CO-07 全部插入失败 `506 already exist` | `insert into <序列路径>(time,s)` —— insert 的 prefixPath 必须是**设备路径** | 改成 `insert into <device>(time, s)` |
| 7 | CO-04 B 相报"cross 未推进" | 基线取在**重启之后**，而 cross 在重启后几秒内就做完了 | 基线取"动作发生之前"（用 Phase A 的 cross0） |
| 8 | CO-13/14 前两版 settle 永不动作 | 见结论 3：同设备两批时间 / 过期与新鲜设备被合并进同一文件；另外写了"未来时间戳"（永不过期） | 重排为"先写过期数据 → 等 settle 清完 → 再写新鲜数据"，时间戳用"过去但很近" |
| 9 | CO-12 报"REMOVE CN 后与基准不一致" | 拿缩容前的旧快照去比（期间又写过数据） | 改成"剩余节点之间互相一致" |
| 10 | 改正在跑的用例脚本 | 就地 `scp` 覆盖会让运行中的 bash 读到错位内容 | `tools/install_staged.sh`：暂存 → 同目录 `cp` 隐藏名 → `mv -f` 原子替换 |
| 11 | PowerShell 的 `\$VAR` 不转义 | 远端 shell 变量被 **PowerShell** 先展开成空串（真把文件写到 `/` 去了） | 远端 shell 变量用**单引号**包住整条 ssh 参数；复杂命令写脚本文件再 `bash /tmp/x.sh` |
| 12 | CO-16 段 5 报"properties 里仍有非法值"（假 FAIL） | `SET` 覆盖同一键时会把旧行**注释掉**（`#compaction_priority=BOGUS`），校验用了 `grep '=BOGUS$'` 把注释也算进去 | 只检查未注释行（`^[a-z_]+=…$`） |
| 13 | CO-16 收尾日志扫描把 6 条 CN 异常算进 FAIL | 段 5 的非法值探针**故意**触发 `IllegalCompactionSelectorNameException`/`NumberFormatException`/热加载失败，属自造噪声 | `lib/common.sh` 支持 `CMP_LOG_BENIGN_EXTRA`，CO-16 在段 5 导出这些模式作为 benign |
| 14 | 组合参数逐键校验恒 WARN（假 WARN） | `for kv in $EXTREME`（`EXTREME="a=1,b=2"`）拿到的是**一整个字符串** | `for kv in $(printf '%s' "$EXTREME" \| tr ',' ' ')` |
| 15 | CO-15 组合 2 的 inner 计数为 0（假 FAIL） | 上一组合把合并开着，本组合**写入期间**就把文件并掉了，基线之后没有推进 | 每组合写入前先 `SET` 三类合并全关；合并基线一律取在写入之后、开合并之前 |
| 16 | CO-16 的 `CMP_LOG_BENIGN_EXTRA` 不生效（日志扫描仍 FAIL） | 该变量在 **source `lib/common.sh` 时**就被拼进 `BENIGN_PAT`，而用例是**运行到段 5 才 export**，此时 pattern 早已定型 | 改成在 `check_logs()` **调用时**拼接（`benpat` 局部变量） |
| 17 | CO-17 首轮 §1 `gap=1` 判"未产出 L2"（假 FAIL，一度怀疑是产品缺陷） | 用例把 `inner_seq_selector` 设成 `size_tiered_single_target` 去测 `max_level_gap_in_inner_compaction`——而该取值实例化的是**经典 `SizeTieredCompactionSelector`**，它根本不读 gap/文件数上限。改用默认 `size_tiered_multi_target`（→`NewSizeTieredCompactionSelector`）后边界行为完全正确 | 用例头部写明映射关系；`SKILL.md`/`CONF_PARAMS.md` 增加"取值↔实现类↔会读哪些参数"映射表；CO-17 显式断言 `inner_seq_selector=size_tiered_multi_target` |
| 18 | CO-17 第二轮 §1 场景"各副本层级不一致"（77 有 1 个文件、78 有 2 个） | `flush;` 返回后 TsFile 仍是 `UNCLOSED`/可追加，此时写下一批会被**追加进同一个文件**（IoTConsensus 下各副本 memtable 关闭时刻不同） | 每批写完等该库的 **close 事件**数达标（`co17_wait_close`）再写下一批；场景有效性用"各副本层级布局一致"断言；单设备让 region 数固定为 1 |
| 19 | CO-17 第三轮 §3"每任务 unseq 数分布"恒为空（假 FAIL） | cross 任务日志格式是 `CrossSpaceCompaction task starts with N **seq files and M unsequence files**`，第一版正则按 `N files` 解析；且 `grep -F 'CrossSpaceCompaction task starts with'` 会把 `InsertionCrossSpaceCompaction task starts with unseq file …` 也算进来 | 正则与关键字改为带 `[Compaction] CrossSpaceCompaction` 前缀 + 解析 `and (\d+) unsequence files` |
