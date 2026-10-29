# 5C20D PROACTIVE 用例清单（每版本回归用）

版本：master_1020_22f9710（2.0.11-SNAPSHOT）；集群 5 CN + 20 DN；SchemaRegion 5 副本 / DataRegion 3 副本。
包内既有 14 条 LEAK/MULTI 用例 + 本次新增 10 条高可用/整集群重启用例 = **24 条**；
另可复用包内 PROACTIVE 行为族（PG-*，约 200 条）做整族回归。

## 1. 每条用例的固定流程（干净集群）

| 步骤 | 动作 | 判据/产物 |
|---|---|---|
| 1 | `prepare`：停全部 25 个节点 → 删 `data`/`logs` → 从 `conf_orig` 还原 conf → 写 PROACTIVE 八键与共识协议 → 启动 | 25 节点 Running/ReadOnly |
| 2 | 执行用例体（建库/写入/故障注入） | 每条断言进 `result.json` |
| 3 | 收尾① sync lag | 全集群逐实例归 0（`SYNC_STABLE_SECONDS` 稳定窗口） |
| 4 | 收尾② 副本一致性 | 全在线逐 DN 查询为基线（默认直查 3 台）→ 串行停 3 台 DN 各查一遍对拍 → 恢复 → 再等 sync lag |
| 5 | 收尾③ 日志扫描 | 25 节点 `*all*.log` 的 ERROR/WARN；harness 自身动作按实际时刻开窗，窗外同样日志仍判 FAIL |
| 6 | 报告 | `results/<run_id>/cases/<CASE>/result.json` + `REPORT.md` |

## 2. 包内 14 条（优先）

| id | 场景 | 关键判据 | 阈值键 |
|---|---|---|---|
| MULTI-01 | SR5 副本分布 | 每个 Schema 组 5 副本落在 5 台不同 DN | `SCHEMA_REPLICATION_FACTOR` |
| MULTI-02 | DR3 互斥 + 均衡 | 每组 3 副本互不相同；20 DN 上组数 max/min ≤ 2 | `BALANCE_RATIO_MAX` |
| MULTI-03 | 停 1 台 DN | SR 在线副本 ≥ 4；查询可执行；恢复后组状态 Running | `MULTI_STOP_SETTLE_SEC` |
| MULTI-04 | 上限公式 | 每库 `Max*RegionGroupNum` ≥ 源码公式 | `PG_SCHEMA_PER_DATA_NODE` 等 |
| MULTI-05 | region 回收 | 建 20 库删 19 库后无残留，保留库仍有组 | `MULTI_DB_COUNT` |
| MULTI-06 | 单库 50 slot | Schema/Data 组数 = min(K, 上限) 且 > 1 | `MULTI_SLOT_COUNT` |
| LEAK-THR-01 | 线程基线 | 25 台逐 JVM 可采，top 线程名落 evidence | — |
| LEAK-THR-02 | 建删循环 | 8 轮（每轮 30 slot）线程斜率 ≤ 0.5 条/轮、末轮 ≤ 基线+50 | `LEAK_ROUNDS` 等 |
| LEAK-THR-03 | 扩容后删库 | 线程回落到基线+余量；仍可建库 | `LEAK_THREAD_CYCLES` |
| LEAK-THR-04 | 空闲稳定 | 3 次采样波动 ≤ 50 | `LEAK_THREAD_MARGIN` |
| LEAK-MEM-01 | 堆不增长 | GC 后增长 ≤ 15% 或绝对增量 ≤ 256MB；不单调 | `LEAK_HEAP_GROWTH_PCT` |
| LEAK-MEM-02 | 300 库建删 | 堆回落；`show databases` 无残留 | `MEM_LOOP_DBS` |
| LEAK-MEM-03 | 多时间分区 | 6 分区 × 2000 点，堆增长 ≤ 每点 4KB 预算 | `LEAK_MEM_BYTES_PER_POINT_MAX` |
| LEAK-MEM-04 | benchmark 长跑 | 堆呈锯齿；未配 `BENCH_CMD` → SKIP | `MEM_LONG_MINUTES` |

## 3. 新增 10 条（创建过程中的故障 + 整集群重启）

| id | 场景 | 关键判据 |
|---|---|---|
| 5C-HA-01 | 1 台 DN READONLY 期间创建 Schema/Data 组 | 组数 = min(K, 上限)；新组副本不落只读节点；写入可查；恢复后 Running |
| 5C-HA-02 | 2 台 DN READONLY 期间创建 | 同上；SR5 仍须 5 台不同 DN |
| 5C-HA-03 | 停 1 台 DN 期间建新库写 3 个新 slot | 组数 = min(K, 上限)；DR3 副本不落停机；恢复后数据完整 |
| 5C-HA-04 | 停 2 台 DN 期间创建 | SR5/DR3 副本均不落停机的 2 台；恢复后 Running |
| 5C-HA-05 | 停 1 台 CN 期间创建 | 组数正确；CN 恢复后组 id 与组数完全不变 |
| 5C-HA-06 | 停 2 台 CN（5→3 仍多数派） | 同上 |
| 5C-HA-07 | 1 台 CN + 1 台 DN 同时停 | 创建成功、副本不落故障节点、查询可执行 |
| 5C-HA-08 | 1 台 DN READONLY + 1 台 DN 停机 | 新建组不落这两台；组数正确 |
| 5C-HA-09 | 后台持续写新 slot 途中停 1 台 DN | 在途写入不卡死；组数不超上限；成功写入全部可查 |
| 5C-RST-01 | **整集群重启**后再次查询 | 组数 / 组 id / 设备→组映射 / 行数全部不变；重启后继续扩容仍生效 |

## 4. 按版本回归时的执行顺序

1. `selftest` + `doctor`（不碰集群，先确认 ssh/路径/CLI/JDK 都通）。
2. 冒烟：`MULTI-01`（最快暴露 SR5/DR3 配置错误）。
3. 默认协议 IoTConsensus 跑完整 24 条 + TTL/DELETE 抽样（`PG-TTL-01`、`PG-EMPTY-03`）。
4. IoTConsensusV2 跑代表性子集（P0 全量 + 各族的故障用例）。
5. 汇总：`aggregate_report.py` 生成中文报告，`results/<run_id>/` 整目录归档。

## 5. 缺陷回归用例（与策略无关）

| id | 场景 | 判据 | 归属 |
|---|---|---|---|
| 5C-NPE-01 | IoTConsensusV2：建库→写 slot→flush→等一个 flush 周期→`drop database`，循环至命中或窗口耗尽 | 命中 ≥1 次 ⇒ FAIL（输出每台 DN 命中次数与首条栈）；0 次且窗口足够（≥8 轮、≥3 个 flush 周期）⇒ PASS；0 次但窗口不足 ⇒ SKIP | **Pipe 子系统 / IoTConsensusV2**，与 RegionGroup 扩容策略（PROACTIVE/CUSTOM/AUTO）无关 |

`5C-NPE-01` 只在 V2 上有意义：V1（IoTConsensus）不走 `__consensus` pipe，进度表恒空，命中必然为 0
（正好做对照组）。跑法：

```bash
bash ../run_all_clean.sh conf/cluster.rc10.v2.minimal.conf npe_r1 5C-NPE-01   # 零策略配置（默认值）
bash ../run_all_clean.sh conf/cluster.proactive_5c20d.rc10.v2.conf npe_r2 5C-NPE-01  # 显式 CUSTOM
bash ../run_all_clean.sh conf/cluster.proactive_5c20d.rc10.iot.conf npe_v1 5C-NPE-01 # V1 对照
```

## 6. 已知边界

1. 需求文档（PLM docs 360/127/341）在本机取不到：SkillHub 不可达且无 PAT，用例期望值以
   **master 源码**（`ClusterSchemaManager`、`PartitionManager`、`RegionGroupExtensionPolicy`）
   与包内 `references/proactive-spec.md` 为准。
2. `LEAK-MEM-04` 需要 `BENCH_CMD`；未配置时明确 SKIP（不是 PASS）。
3. 20 DN 全量逐台停机太慢：收尾②固定抽 3 台（`CONSISTENCY_STOP_NODES=3`）。
4. 逐副本直查默认 3 台（`CONSISTENCY_DIRECT_NODES=3`），全量设为 0 即可。
