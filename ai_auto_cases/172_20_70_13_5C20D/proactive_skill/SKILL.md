# iotdb-proactive-5c20d — 5C20D（SR5/DR3）PROACTIVE 回归包

用于 **5 ConfigNode + 20 DataNode**、**SchemaRegion 5 副本 / DataRegion 3 副本** 的
RegionGroup 积极扩容（PROACTIVE）回归：包内 14 条 LEAK/MULTI 用例 + 10 条高可用/整集群重启用例
（`5C-HA-*` / `5C-RST-01`），加上包内既有的 PROACTIVE 行为族（PG-*，可整族回归）。

## 与 3C5D 的分工
| 维度 | 3C5D | 5C20D（本包） |
|---|---|---|
| PROACTIVE 行为正确性 | 217 例全量 | 抽样对照 + 多 DN 专项 |
| 副本约束 | 3 副本 | **SR5 跨 5 台不同 DN**、DR3 互斥 + 20 DN 均衡 |
| 线程/内存泄漏 | 未系统测 | **本包主目标** |
| 创建过程中的故障 | 少量 | **只读 1~2 台 / 停 1~2 台 DN / 停 1~2 台 CN / CN+DN 组合** |
| 规模效应 | 5 DN 太小 | 20 DN 才暴露心跳/复制线程池、region 管理开销 |

## 环境
1. 5 CN：172.20.70.100-104；20 DN：172.20.70.100-119（`conf/nodes.conf` 是唯一拓扑来源）。
2. 驱动机 172.20.70.122，包与结果目录 `/data1/iotdb/5c20dtest/testcase/PROACTIVE`。
3. 数据库安装目录 `/data/iotdb/<版本目录>`（conf 的 `DB_DIR`），每个节点同路径。
4. benchmark（可选）：`/data1/iotdb/5c20dtest/benchmark`；未给 `BENCH_CMD` 时 `LEAK-MEM-04` 明确 SKIP。

## 协议档位
| conf | 共识协议 | 用途 |
|---|---|---|
| `conf/cluster.proactive_5c20d.iot.conf` | IoTConsensus | **默认优先跑这一档** |
| `conf/cluster.proactive_5c20d.v2.conf` | IoTConsensusV2 | 第二档，同一批用例复跑 |
| `conf/cluster.proactive_5c20d.conf` | IoTConsensus（密码登录版） | 目标机未配免密时用 |

`data_region_consensus_protocol_class` 是 first_start 生效，`prepare` 会按 `DEPLOY_CONSENSUS`
写进每台节点，所以换协议只需换 conf 再 `prepare`。

## 用例清单（24 条：包内 14 + 新增 10）
### 包内 LEAK/MULTI（优先）
| id | 判据 |
|---|---|
| LEAK-THR-01 | 逐 JVM 线程基线可采（top 线程名落 evidence） |
| LEAK-THR-02 | 建库→写 30 slot→删库 8 轮：线程**斜率** ≤ 阈值且末轮 ≤ 基线+余量 |
| LEAK-THR-03 | 多 slot 扩容→删库后线程回落且仍可建库 |
| LEAK-THR-04 | 空闲期 5CN+20DN 线程数波动 ≤ 阈值 |
| LEAK-MEM-01 | GC 后堆增长 ≤ 阈值或绝对增量 ≤ 余量，且不单调上升 |
| LEAK-MEM-02 | 300 库建删后堆回落 + `show databases` 清空 |
| LEAK-MEM-03 | 6 个时间分区 × 2000 点：堆增长 ≤ 每点预算 |
| LEAK-MEM-04 | benchmark 长跑堆呈锯齿（未配 `BENCH_CMD` → SKIP） |
| MULTI-01 | 每个 Schema 组 5 副本落在 5 台不同 DN |
| MULTI-02 | 每个 Data 组 3 副本互斥；20 DN 组数 max/min ≤ 2 |
| MULTI-03 | 停 1 台 DN 后 SR 仍有 ≥4 在线副本、查询可执行、恢复后回 Running |
| MULTI-04 | 20 DN 下每库 `Max*RegionGroupNum` ≥ 源码公式 |
| MULTI-05 | 建 20 库删 19 库后 region 无残留 |
| MULTI-06 | 单库 50 slot：Schema/Data 组数 = min(K, 上限) 且 > 1 |

### 新增高可用/重启（`scripts/pgkit/cases_ha5.py`）
| id | 场景 | 判据 |
|---|---|---|
| 5C-HA-01 | 1 台 DN READONLY 期间创建 Schema/Data 组 | 组数 = min(K, 上限)；副本不落只读节点；数据可查；恢复后 Running |
| 5C-HA-02 | 2 台 DN READONLY 期间创建 | 同上，SR5 仍须 5 台不同 DN |
| 5C-HA-03 | 停 1 台 DN 期间建新库写新 slot | 组数 = min(K, 上限)；DR3 副本不落停机；恢复后数据完整 |
| 5C-HA-04 | 停 2 台 DN 期间创建 | SR5/DR3 副本均不落停机的 2 台；恢复后 Running |
| 5C-HA-05 | 停 1 台 CN 期间创建 | 组数正确；CN 恢复后组 id 与组数**完全不变** |
| 5C-HA-06 | 停 2 台 CN（5→3 仍多数派）期间创建 | 同上 |
| 5C-HA-07 | 1 台 CN + 1 台 DN 同时停 | 创建成功、副本不落故障节点、查询可执行 |
| 5C-HA-08 | 1 台 DN READONLY + 1 台 DN 停机 | 新建组不落这两台，组数正确 |
| 5C-HA-09 | 后台持续写新 slot 途中停 1 台 DN | 在途写入不卡死；组数不超上限；成功写入全部可查 |
| 5C-RST-01 | **整集群重启**后再查询 | 组数/组 id/设备→组映射/行数全部不变；重启后继续扩容仍生效 |

### 顺手复用的行为族（按需）
| 族 | 说明 |
|---|---|
| PG-TTL-01 / PG-TTL-03 | TTL 下扩容与过期删除后组数、映射不变 |
| PG-EMPTY-03 | 写后删除数据不回收 RegionGroup |
| PG-EMPTY-08 / PG-SMK-03 | 空库不预建组 / 单设备单测点基线 |
| PG-RST-01..06 | 包内既有重启族（与 5C-RST-01 互补） |

阈值全部在 conf：`LEAK_THREAD_SLOPE_MAX`、`LEAK_THREAD_MARGIN`、`LEAK_HEAP_GROWTH_PCT`、
`LEAK_HEAP_MARGIN_MB`、`BALANCE_RATIO_MAX`、`LEAK_ROUNDS`、`LEAK_DEVICES_PER_DB`、
`MEM_LOOP_DBS`、`MULTI_SLOT_COUNT`、`CONSISTENCY_STOP_NODES`（默认 3）。

## 命令
每条用例都从干净集群开始（`prepare` = 停全部节点 → 清 `data`/`logs` → 还原 conf → 写
PROACTIVE 与协议键 → 启动 → 等 25 节点 Running）：

```bash
cd /data1/iotdb/5c20dtest/testcase/PROACTIVE/iotdb-proactive-5c20d

# 0) 自检（不碰集群）
bash scripts/pg.sh --conf conf/cluster.proactive_5c20d.iot.conf selftest
bash scripts/pg.sh --conf conf/cluster.proactive_5c20d.iot.conf doctor

# 1) 单条用例：干净集群 → 跑 → 报告
bash ../run_case_clean.sh conf/cluster.proactive_5c20d.iot.conf iot_r1 MULTI-01

# 2) 整轮：每条用例各自干净集群，串行
bash ../run_all_clean.sh conf/cluster.proactive_5c20d.iot.conf iot_r1 \
     MULTI-01 MULTI-02 MULTI-03 MULTI-04 MULTI-05 MULTI-06 \
     LEAK-THR-01 LEAK-THR-02 LEAK-THR-03 LEAK-THR-04 \
     LEAK-MEM-01 LEAK-MEM-02 LEAK-MEM-03 LEAK-MEM-04 \
     5C-HA-01 5C-HA-02 5C-HA-03 5C-HA-04 5C-HA-05 5C-HA-06 5C-HA-07 5C-HA-08 5C-HA-09 \
     5C-RST-01

# 3) 汇总中文报告（整轮多条 run 合并）
python3 ../aggregate_report.py results REPORT_IOT.md --prefix iot_r1 --title "PROACTIVE 5C20D（IoTConsensus）"
```

换协议：把 `--conf` 换成 `conf/cluster.proactive_5c20d.v2.conf`，`--run-id` 前缀换成 `v2_r1`，
报告用 `--prefix v2_r1`。

## 每条用例的收尾三件套（自动追加，任一不过不得 PASS）
1. **sync lag**：全集群逐实例等到归 0（`SYNC_STABLE_SECONDS` 稳定窗口 + `SYNC_MAX_WAIT_SEC` 上限）。
2. **副本一致性**：全在线时逐台 DataNode 各查一遍作为基线，再串行停 `CONSISTENCY_STOP_NODES`
   台（默认 3，20 DN 全停太慢）分别查询同一数据集与基线对拍，最后恢复并再等一次 sync lag。
3. **ERROR/WARN 扫描**：扫 CN/DN `*all*.log`，harness 自己的停/起/建删库动作按其**实际时刻**
   开归因窗口（窗口外的同样日志仍然判 FAIL，不是白名单）。

## 纪律
1. 采样工具不可用（jcmd/jstack）、benchmark 未配置、SSH 不通 → **SKIP 并写原因**，绝不写成 PASS。
2. 阈值只在 conf 调，不改代码。
3. 每条用例的采样明细写 `evidence/`，判据与实测值同时进 `result.json`。
4. 故障用例停/起节点前先 `mark_harness_action`，被停的 DataNode 立刻记入 `by_design_gone`，
   收尾① 才不会等一个永远到不了的 lag。
