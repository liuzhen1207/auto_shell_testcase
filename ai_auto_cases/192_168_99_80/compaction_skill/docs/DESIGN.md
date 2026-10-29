# 合并专项 skill —— 设计说明

## 1. 目标与范围

- **首要目标**：合并**基本功能没问题**——合并该发生时发生、不该发生时不动、合并前后数据完全一致；
- 其次：conf **参数功能**与**热加载**正确；有**性能基准**可跨版本对比；覆盖**缩容（REMOVE CN/DN）**场景；
- 每个 RC 都能直接回归：`tools/run_all.sh --set smoke` 是必跑集合（14~20 分钟量级），
  `--set all` 是完整集合（含参数/性能/缩容）。

范围：3C3D / 三副本；data region 协议可指定（默认 `IoTConsensus`，可 `IoTConsensusV2`）。
树模型与表模型都覆盖：冒烟（seq/unseq/cross）、删除数据、删除元数据、多类型多编码、对齐序列+空值。

## 2. 统一收尾（每条用例都跑，判据固定）

| 顺序 | 检查 | 判据 | 实现 |
| --- | --- | --- | --- |
| 1 | **sync lag 归零** | 每个 DataNode 自己的 `http://<dn>:9092/metrics` 里 `type="syncLag"` 全部为 0，连续 3 次稳定 | `check_sync_lag`（子集节点用 `check_sync_lag_on`） |
| 2 | **副本一致性** | 以"全部在线时各副本查询结果"为基准 → **逐个停 1 个 DN**，用剩余副本查询并与基准逐行比对，不一致即 FAIL；停完自动拉起并等 Running | `consistency_check <SQL> <dialect>`（子集节点用 `consistency_check_on`） |
| 3 | **CN/DN 日志异常** | 扫 `logs/*{confignode,datanode}*all*.log`/`*error*.log`，命中 NPE / OOM / 越界 / overlap / schema 不匹配 / 数据类型不一致 等即 FAIL 并打印原文；同时打印"合并任务累计 starts/finishes"作为**正证据** | `check_logs`（子集节点用 `cmp_check_logs_on`） |

异步合并类缺陷（如"合并卡死""合并把删除数据带回来"）**不会**在第 2 步直接暴露，
所以每条用例在收尾前还有**合并自身的硬断言**（文件数下降、数据指纹一致、无卡死线程）。

## 3. 观测方法（怎么"看见"合并）

| 观测面 | 方法 | 用途 |
| --- | --- | --- |
| TsFile 文件数 | `find <DB_DIR>/data/datanode/data/{sequence,unsequence}/<db>/... -name '*.tsfile'`（seq/unseq 分开计数，支持按节点/求和两种视图） | 合并是否发生（数下降）、unseq 是否归零、输入/输出规模 |
| TsFile 字节数 / 最大文件 | `-printf '%s'` 求和 / 取最大 | 统计口径、性能基准、写放大、`target_compaction_file_size` 效果 |
| 合并日志 | `log_datanode_compaction.log` + `log_datanode_all.log` 里 `{db}-{region} [Compaction] {Sequence\|Unsequence} InnerSpaceCompaction task starts with … / finishes successfully …`、`CrossSpaceCompaction …` | 合并任务是否真的跑了（starts）、是否完成（finishes）、按库/按类型区分 |
| 数据指纹 | 对同一条 SQL 取 `norm_result`（去 CLI 回显、按列对齐、空集记为 EMPTY、报错记为 ERROR:xxx），合并前后比较 | **合并前后数据必须逐字节一致**（等价于"没丢、没重、没改、没复活"） |
| 线程栈 | `jstack <DN pid> \| grep 'TsFileResource.writeLock'` | 合并卡死类问题的直接证据（写锁等不到） |
| 生效配置 | 表方言 `show configuration`（`name｜value｜default_value`） | 参数是否真的生效（含热加载） |
| 集群结构 | `show cluster`（列序 `NodeID｜NodeType｜Status｜InternalAddress｜…`） | 节点数、缩容前后对比、按 IP 反查节点 id |

## 4. 用例设计矩阵

| 组 | 用例 | 设计要点 |
| --- | --- | --- |
| 冒烟（合并真的会发生） | CO-01/CO-02 | 用 `inner_compaction_candidate_file_num=2` + `compaction_schedule_interval_in_ms=1000` 把合并调成"必触发"；**先造出 ≥2 个文件**，再断言"finishes 增长 **且** 文件数下降"（两个独立信号同时成立才算合并发生，避免把 flush 误算成合并） |
| 冒烟（unseq） | CO-03 | 关掉 seq/cross 合并把观测对象**隔离**到 unsequence；先写"新"数据当水位线，再用更早时间戳写两批 → 落 unseq |
| 冒烟（cross） | CO-04 | seq 区间 + **重叠**的 unseq 区间 → unseq 归零、数据指纹不变（同一时间戳以后写入为准）、日志无 overlap |
| 删除语义 | CO-05 | DELETE 一半时间范围 → 等副本应用 → 再写一批让带 mods 的文件参与合并 → 断言"合并前后指纹一致 + 行数不变"（删除行不得复活）；树/表各一遍 |
| 元数据语义 | CO-06 | DELETE TIMESERIES / DROP DATABASE 重建 / DROP TABLE / DELETE DEVICES 之后继续写 + 合并 → 被删对象不得复活、无 `CompactionTableSchemaNotMatchException` |
| 类型/编码 | CO-07 | 24 种 (datatype, encoding) 组合（建不成的只 WARN）；写入含负数、int 极值、NaN/Infinity、含逗号/引号/中文的文本；断言 `select *` 全库指纹 + 逐序列指纹 + 表头不变 |
| 对齐/空值 | CO-08 | 对齐设备多序列在不同时间点写入 → 制造 null；断言 null 个数不变、全库与逐序列指纹一致 |
| 参数功能 | CO-09 | ① 模板里 35 个合并相关键静态齐全；② 负向（`enable_seq_space_compaction=false` + `inner_compaction_candidate_file_num=100`）不合并；③ 正向（true + 2）合并 |
| 热加载 | CO-10 | 热关 seq 合并 → 写多批不合并；热开 → **不重启**立即合并；再对 10 个参数校验不变量「是否要求重启 ⇔ 生效值是否立即变化」，逐项还原 |
| 性能基准 | CO-11 | **单 CLI 会话**批量写入（逐条 `sq` 会被 CLI/JVM 启动开销主导，测的是 CLI 不是引擎）→ 关合并攒文件 → 热开合并计时 → 记录输入/输出文件数与字节、耗时、吞吐、写放大到 `results/perf_baseline.csv`；同 build 有历史行时给耗时比值（>2× 只 WARN） |
| 缩容 | CO-12 | REMOVE DATANODE → 剩 2 DN 仍可读写/合并、经剩余节点查询与基准一致；REMOVE CONFIGNODE → 集群仍可用；收尾按**剩余节点**做三件套 |

## 5. harness 结构

```
compaction_skill/
├── conf/env.conf          # 集群/版本/协议/合并参数组合/规模/窗口
├── lib/common.sh          # 通用 harness（与 TTL / 磁盘占用 skill 同源）：集群生命周期、SQL、
│                          #   断言、收尾三件套、结果 CSV；入口函数前缀 cmp_
├── lib/cmp.sh             # 本 skill 专用：造数据(seq/unseq)、TsFile 观测、合并观测(jstack/指纹/等合并)、
│                          #   参数(模板/生效值/热改)、REMOVE 节点、性能记录
├── cases/{tree,table,common}/*.sh   # 12 条用例
├── tools/run_all.sh       # 集合入口（--set smoke|basic|param|perf|remove|all、--only、--consensus、--ver）
├── tools/selftest.sh      # 自检（语法/矩阵/env/helper/断言/正则覆盖/静态坑），当前 ok=132 failed=0
└── tools/adapt_common.py  # 记录 common.sh 是如何从通用 harness 适配过来的（异常正则、改名、子集收尾）
```

## 6. 稳定性设计（都是踩过坑之后的加固）

- **正向对照**：门禁类断言都先证明"这套配置本来就会合并"（否则结果没有意义）；
- **双信号判据**：`finishes` 增长 + 文件数下降；辅信号允许"低于窗口内首次采样"（避免把查询/落盘滞后的计数当成未合并）；
- **单会话写入**：批量写用 `sql_lines_tree` 一次会话喂多条语句，避免 CLI 每条一次 JVM；`cmp_write_tree_batch` 用于小规模场景；
- **启动加固**：`cmp_cluster_prepare` 在启动前 `pkill` 残留 CN/DN（重复进程抢端口会让框架启动脚本的
  `while true; do show cluster; done` **永久卡住**），并给框架启动脚本加 `timeout`；
- **停/起 DN 后等状态**：一致性校验停 DN 后轮询 `show cluster` 直到状态变更，再查询，避免"还没停干净"造成的假不一致；
- **`set -u` 安全**：不使用 `local a=$1 b=$((...a...))` 同行引用（selftest 有静态检查）。

## 7. 已知限制与后续可扩展

- 参数用例只对 2 个参数做行为级对照（其余做静态 + 生效值检查），避免把环境相关阈值写进硬判据；
- 性能基准是**单机单盘**的粗略基线（写入规模可调 `CO_PERF_*`），跨环境比较意义有限，主要用于**同环境跨版本**回归；
- 未覆盖：`IoTConsensusV2` 的完整矩阵（协议可指定，但默认集合只跑 V1）、object 存储合并、多级存储（tiered）合并、
  `enable_auto_repair_compaction` 的专门场景（乱序文件自动修复）、磁盘水位触发的选择策略
  （`inner_compaction_task_selection_disk_redundancy`）。这些可作为下一轮扩展方向。
