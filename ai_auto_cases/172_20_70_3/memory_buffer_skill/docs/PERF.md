# PERF —— 3C5D 内存缓冲区性能对比（iot-benchmark）


> ⚠️ **P99 数值更正（2026-10-22 18:20）**
>
> 本文档及 RC9 报告中的「P99」列，实际取的是 benchmark CSV 的 **P999** 列（写死 `$11`，而 P99 是 `$10`）。
> 真值需按下方「更正后的 P99」查看。已修 `lib/perf.sh`（改为按表头名定位 P99）。
>
> | 用例 | 原记录「P99」= 实际 P999 | 更正后的真 P99 |
> |---|---|---|
> | P-01 | 45.87 ms | **7.54 ms** |
> | P-03 sep_off_ooo | 44.45 ms | **7.15 ms** |
> | P-03 sep_on_ooo | 95.35 ms | **7.26 ms** |
>
> **P-03 的结论因此变更**：原判「乱序负载 P99 恶化 +114%（FAIL）」不成立 ——
> 那是 P999 从 44.45 涨到 95.35；真 P99 是 7.26 vs 7.15（**+1.5%**）。
> 按原判据（吞吐 -30% / P99 +50%）复核，P-03 两个场景**均应 PASS**。

## 0. 一句话

在同一 3C5D 集群上，用 `iot-benchmark` 跑固定负载，只改内存缓冲区参数，对比**写入吞吐（points/s）**
与**最新点查询延迟（P99）**；判据是"相对同轮基线不显著劣化"，不是绝对吞吐门槛。

## 1. 为什么不用绝对阈值

《软件测试文档》里的数字（1C1D 顺序写入 30.3M points/s、3C5D 64.4M points/s）是
16 核/32G × 多机 + 大并发客户端的结果。本环境：
- 3CN（4核8G）+ 5DN（16核32G），数据节点单机堆 20G；
- 客户端只有 1 台 `172.20.70.3`（31G），benchmark 单 JVM；
- 因此本环境的绝对吞吐与文档**差两个数量级是正常的**。

所以本套用例的判据是**同轮对照**：
| 变化 | 判据 |
|---|---|
| 吞吐下降 ≤ 30% | PASS/WARN（`PERF_TOLERANCE_PCT`） |
| 吞吐下降 > 30% | FAIL |
| P99 恶化 > 50% | FAIL（`PERF_LATENCY_TOL_PCT`） |

## 2. 环境与工具

| 项 | 值 |
|---|---|
| benchmark | `/data1/iotdb/testcase/MigrateRegionTest/benchmark/bm_20251017_b6be9bd` |
| 入口 | `bash benchmark.sh -cf <配置目录>`（**是目录不是文件**，目录里要有 `config.properties` + `function.xml` + `logback.xml`） |
| 集群 | 3CN `70.5/70.4/70.26` + 5DN `70.4/70.26/70.14/70.27/70.30` |
| 账号 | `root` / `TimechoDB@2021`（本集群只建了 root；benchmark 自带模板里的 `sys_admin` 不存在） |
| 结果 | 每次跑完在 `$BM/data/csvOutput/*-test-result.csv` 追加一份，含 Throughput Matrix / Latency Matrix |
| 解析字段 | `INGESTION,okOp,okPoint,failOp,failPoint,throughput` 与 `INGESTION,AVG,...,P99,...` |

## 3. 用例与变体

| 用例 | 变体 | 对应文档 |
|---|---|---|
| **P-01** flush_proportion | `base_fp04`(0.4 默认) / `fp05`(0.5) | 软件测试文档：*「flush_proportion 从 0.4 提高到 0.5，因为 TVList 新增 indices 和 null bitmap」* |
| **P-02** Chunk 切分参数 | `c100k`(默认) / `c10k` / `csize`(8MB) | Chunk 切分需求分析 + 软件测试文档「针对不同 target_chunk_point_num 性能比较」 |
| **P-03** 顺乱序分离 | 顺序×{false,true} + 乱序50%×{false,true} | 顺乱序分离需求分析：*「分别打开和关闭，测试不同乱序率下的读写性能」* |
| **P-04** 最新点查询 | `q_tim` / `q_quick` / `q_backward` | 软件测试文档：*「1万点最新值查询 Table mode 536s→818s」*（本环境用 1000 设备，见下） |
| **P-05** 共识协议 | `v1`(IoTConsensus) / `v2`(IoTConsensusV2) | 本次测试要求：默认 V1，其次 V2 |

负载：`DEVICE_NUMBER=100`、`SENSOR_NUMBER=20`、`BATCH_SIZE_PER_WRITE=10`、
`OPERATION_PROPORTION=91:1:1:1:1:1:0:0:0:0:0:0`（写为主，与文档口径一致）。
P-04 换成 `1:0:0:0:0:0:0:0:90:0:0:0` —— **第 9 个数是 Q8 = 最近点查询**（见 benchmark 自带
`conf/config.properties:331-342` 的注释），设备数放大到 1000。

> 文档的"1 万点最新值查询"是 10000 个设备；本环境用 1000 设备以控制时长
> （`PERF_DEVICES_QUERY=10000` 可完全对齐，但单变体会跑很久）。

## 4. 怎么跑

```bash
cd /data1/iotdb/testcase/MigrateRegionTest/skill_case/membuf_skill

# 与功能用例互斥（共用 flock）：先确认 run_all 已结束
bash tools/run_perf.sh --set all                 # 5 条全跑
bash tools/run_perf.sh --set write               # P-01/P-02/P-03
bash tools/run_perf.sh --set consensus           # P-05
bash tools/run_perf.sh --only P-01 --repeat 3    # 单条 + 3 次取最优（降噪）
bash tools/run_perf.sh --set all --devices 200 --loop 500   # 缩规模快跑
```

产物：
- `results/perf_<P-xx>.csv`：每变体一行
  `time,case,tag,param,consensus,ingest_throughput_point_s,ok_points,avg_ms,p99_ms,elapsed_s,benchmark_csv`
- `results/<P-xx>_<runid>.out`：完整输出（含每次 benchmark 的日志路径）
- `results/PERF_all_<runid>.out`：整套汇总（含各 CSV 拼接）

## 5. 结果怎么读

1. 先看 `perf_P-*.csv` 里每个变体的 `ingest_throughput_point_s`；
2. 再看 `.out` 里的 `perf_compare` 行：`吞吐 X vs 基线 Y（±Z%）`；
3. `WARN` 表示下降但在容忍内（本环境单机 benchmark 波动 10~20% 很常见，建议 `--repeat 3`）；
4. 每个变体都在"干净集群"上跑，所以变体间差异只来自内存参数，不来自数据残留。

## 6. 已知限制

1. **单客户端**：benchmark 只有一个 JVM，客户端侧可能先成为瓶颈（尤其 `POINT_STEP` 小时）。
   若某变体吞吐异常低，先看 benchmark 日志里是否有客户端侧 GC/超时。
2. **TEXT 与 10 类型混合**：`INSERT_DATATYPE_PROPORTION=1:1:1:1:1:1:1:1:1:1` 保留文档口径，
   因此 TEXT 写入的绝对吞吐会明显低于纯数值场景；
3. **不判绝对性能**：跨环境比较没有意义，只做同环境同轮对照；
4. **不与功能用例并行**：共享 flock，且都会清 data/logs。
