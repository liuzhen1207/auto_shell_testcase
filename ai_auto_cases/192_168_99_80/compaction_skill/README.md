# 合并（compaction）专项回归 skill

IoTDB / TimechoDB **2.0.12.1** 的**在线文件合并（compaction）**专项用例集：
优先保证**基本功能没问题**（冒烟），并提供 conf 参数功能/热加载验证、合并性能基准、缩容（REMOVE CN/DN）场景，
**每题统一收尾**（sync lag 归零 → 副本一致性 → CN/DN 日志异常），可直接用于每个 RC 的回归。

| 项 | 内容 |
| --- | --- |
| 目标版本 | **RC6 `v20121rc6_1010_7ae8713e`（`7ae8713e`）**，可用 `--ver` 切版本 |
| 集群 | **3C3D / 三副本**（192.168.99.77/78/79 各 1 CN + 1 DN）；**data region 协议可指定**：`--consensus IoTConsensus`（默认）/ `IoTConsensusV2` |
| 入口 | `bash tools/run_all.sh --set smoke\|basic\|param\|perf\|remove\|ttl\|combo\|all [--only CO-01,…] [--consensus …] [--ver …]` |
| 整套串行跑 | `setsid nohup bash tools/run_full_chain.sh /tmp/co_full.log >/dev/null 2>&1 &`；进度 `bash tools/progress.sh /tmp/co_full.log`（**同一时刻只能有一个 run_all**，已加 flock 并发锁） |
| 自检 | `SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh`（**ok=139 failed=0**） |
| 结果 | `results/test_result.csv`、`results/<ID>_<runid>.out`、`results/SUITE_*.out`、`results/perf_baseline.csv` |
| 本机路径 | `D:\IDEA\deepseek\ip99_80\compaction_skill` |
| 交付归档 | `D:\IDEA\deepseek\compaction\compaction_skill` |
| 99.80 部署 | `/data/iotdb/autotest/compaction_skill` |

## 用例清单（`cases/cases.tsv`）

| ID | 模型 | 覆盖 | 集合 |
| --- | --- | --- | --- |
| **CO-01** | 树 | 冒烟：seq 内部合并（多批 flush → 合并 → 文件数下降、数据指纹一致、无卡死） | smoke/basic |
| **CO-02** | 表 | 冒烟：表模型 seq 内部合并 | smoke/basic |
| **CO-03** | 树 | 冒烟：unseq 内部合并（乱序写入，隔离观测） | smoke/basic |
| **CO-04** | 树 | 冒烟：跨空间合并（seq + 重叠 unseq → unseq 归零、无 overlap 异常） | smoke/basic |
| **CO-05** | 树+表 | 冒烟：DELETE 数据后合并（删除行不得复活，带 mods 文件参与合并） | smoke/basic |
| **CO-06** | 树+表 | 冒烟：元数据变更后合并（DELETE TIMESERIES / DROP DATABASE 重建 / DROP TABLE / DELETE DEVICES） | smoke/basic |
| **CO-07** | 树 | 冒烟：多数据类型 × 多编码（含负数/极值/NaN/Infinity/特殊字符）合并前后 `select *` 逐字节一致 | smoke/basic |
| **CO-08** | 树 | 冒烟：对齐序列 + 空值（null 个数不变、结果一致） | smoke/basic |
| **CO-09** | 树 | 参数功能：conf 模板 35 个 compaction 键齐全 + 负向（关合并/候选数过大→不合并）+ 正向（打开→合并） | param |
| **CO-10** | 树 | 热加载：热关→不合并、热开→不重启立即合并；10 个参数逐项校验「是否要求重启 ⇔ 生效值是否立即变化」 | param |
| **CO-11** | 树 | 性能基准：固定规模单会话写入 → 计时合并 → 记录输入/输出文件与字节、耗时、吞吐、写放大 | perf |
| **CO-12** | 树 | 缩容：REMOVE DATANODE（剩 2 DN 仍可读写/合并/一致）+ REMOVE CONFIGNODE；收尾按剩余节点 | remove |
| **CO-13** | 树 | **TTL 场景**：48h 前批次在 TTL=24h 下过期 → settle 合并物理清理 → TTL 生效期间在线合并（指纹不变、过期数据不复活）→ TTL 调到 30s 后合并产物也被清理 → UNSET 后为空 | ttl |
| **CO-14** | 表 | **TTL 场景（表模型）**：同 CO-13，TTL 挂在表上（`ALTER TABLE … SET PROPERTIES ttl=`） | ttl |
| **CO-15** | 树 | **参数组合①**：`enable_seq/unseq/cross` 8 种开闭组合矩阵（热改逐组合断言"该跑的跑/不该跑的不跑"）+ `compaction_priority` 三种取值（重启，语义顺序记录）+ 极端值组合（线程/限流/层级/上限全极端：不得卡死、不得损坏） | combo |
| **CO-16** | 树 | **参数组合②**：selector×performer 组合（seq 4 组、unseq 4 组）+ `cross_performer` 2 取值 + chunk 组合（重启）——每组合都要合并推进且指纹不变；外加**非法值门禁**（SET 探针后立刻重写 conf） | combo |
| **CO-17** | 树 | **参数组合③（边界）**：① `max_level_gap_in_inner_compaction` 层级边界（各副本造 `[L1,L0]`：gap=0 **不合并**、gap=1 产出 **L2**；再造 `[L2,L0]`：gap=1 **不合并**、gap=2 产出 **L3**）② `inner_compaction_total_file_num_threshold` × `inner_compaction_candidate_file_num`（threshold=2+candidate=3 ⇒ 单任务最多 2 文件、3→2，且非活跃分区绕过候选门槛；threshold=100 ⇒ 单任务收 3 文件、3→1）③ cross 候选上限截断（1 seq 水位 + 3 个重叠 unseq：`num=2` ⇒ 每任务 2 文件；默认 `num=500` ⇒ 单任务 4 文件；`num=500+size=1B` ⇒ 又被 size 卡回每任务 2 文件） | combo |
| **CO-18** | 树 | **参数功能①**：`compaction_priority` 三种取值（用 `compaction_thread_count=1` 去竞态，验"先完成的是 inner 还是 cross"） | param2 |
| **CO-19** | 树 | **参数功能②**：乱序空间的 `inner_unseq_selector`（multi_target）× `inner_compaction_total_file_num_threshold` × `max_level_gap_in_inner_compaction`（gap=1 ⇒ unseq 空间 [L1,L0] → L2） | param2 |
| **CO-20** | 树 | **参数功能③**：`target_compaction_file_size`（1KB vs 默认 2GB：产物文件数对照 ⇒ 分片） | param2 |
| **CO-21** | 树 | **参数功能④**：`inner_compaction_total_file_size_threshold`（阈值=2KB ⇒ 装不下两个文件 ⇒ 不合并；热改 10KB ⇒ 4→1） | param2 |
| **CO-22** | 树 | **参数功能⑤**：`candidate_compaction_task_queue_size`（队列=1 高压场景必须最终全部合并完、无卡死；重启成 64 对照） | param2 |
| **CO-23** | 树 | **参数功能⑥**：线程族 `compaction_thread_count` / `sub_compaction_thread_count` / `compaction_schedule_thread_num`（jstack 数工作线程 + 各配置下合并正确） | param2 |
| **CO-24** | 树 | **参数功能⑦**：`compaction_max_aligned_series_num_in_one_batch`（8 条对齐序列 × 取值 1/8/0 ⇒ 指纹一致） | param2 |
| **CO-25** | 树 | **参数功能⑧**：限流三件套（写/读 MB/s + 读操作/s：默认 vs 1MB/s ⇒ 合并耗时变长） | param2 |
| **CO-26** | 树 | **参数功能⑨**：settle 选择门控 `inner_compaction_task_selection_mods_file_threshold` × `..._disk_redundancy`（有删除标记的文件何时被重写、`.mods` 何时被清理） | param2 |
| **CO-27** | 树 | **基础形态**：单文件 no-op / 空库 / 全删后合并 / **一个 region 跨两个时间分区** | scene |
| **CO-28** | 表 | **表模型 unseq 内部合并 + 跨空间合并**（补齐表模型缺口） | scene |
| **CO-29** | 树 | **进程生命周期**：合并进行中 `kill -9` 一个 DN → 恢复后三副本一致、无残留临时文件、仍能继续合并；再做整体重启对照 | scene |
| **CO-30** | 树 | **插入式跨空间合并**（`InsertionCrossSpaceCompaction`：unseq 文件直接挪进 seq 空间，不重写） | scene |
| **CO-31** | 树 | **合并与读写并发**：合并期间持续写 + 查，无错误、数据都在 | scene |
| **CO-32** | 树 | **参数功能⑩**：`enable_auto_repair_compaction` 开/关两相（不误报修复任务 + 合并正确） | param2 |

## 统一收尾（每条用例末尾自动执行）

1. **sync lag 归零**：抓每个 DataNode 自己的 `http://<dn>:9092/metrics` 里 `type="syncLag"`，要求连续 3 次全为 0；
2. **副本一致性**：以"全部在线时各副本查询结果为基准"→ **逐个停 1 个 DataNode**，用剩余副本查询并与基准比对，不一致即 FAIL（停完自动拉起）；
3. **CN/DN 日志异常**：扫 `logs/*{confignode,datanode}*all/*error*.log`，命中
   `NullPointerException`、`OutOfMemoryError`、`IndexOutOfBoundsException`/`ArrayIndexOutOfBoundsException`、
   `overlapped data`、`CompactionTableSchemaNotMatchException`、`DataTypeInconsistentException`、
   `StatisticsClassException`、`BufferUnderflowException`、`NegativeArraySizeException`、`NumberFormatException`
   等即 FAIL（并列出前 20 条原文）；同时打印"合并任务累计 starts/finishes"作为正证据。

## 文档

- `SKILL.md`：操作手册（怎么跑、判据、踩坑清单、如何扩展用例）
- `docs/CONF_PARAMS.md`：conf 模板里 35 个 compaction 参数的清单、默认值、本 skill 的验证方式
- `docs/DESIGN.md`：用例设计思路、观测方法（TsFile 计数 / 合并日志 / 数据指纹 / jstack）、目录与实现约定
- `docs/RESULTS.md`：逐轮实测结果（含协议对照与性能基线）
