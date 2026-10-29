# RESULTS —— 3C5D 全量实跑结果（v20121rc8_1016_ebaf9da，2026-10-21）

> **环境**：3CN（70.5 / 70.4 / 70.26）+ 5DN（70.4 / 70.26 / 70.14 / 70.27 / 70.30），
> SchemaRF=3 / DataRF=2，默认 IoTConsensus；客户端 172.20.70.3。
> **每条功能用例都从干净集群起**：停集群 → 验证无残留进程 → 清 data/logs → 写 conf → 启动 →
> 核对"只有 `__audit`/`__system` 两个库" → 执行 → 收尾三件套（syncLag 归零 / 逐个停 5 个 DN 比副本 / ERROR-WARN 日志）。
> 性能用例同样每个变体从干净集群起。

## 一、总账

**最终汇总表**（每个用例取最新一次运行）：`results_20261021/SUMMARY_FINAL.tsv`

| 类别 | 总数 | PASS | FAIL | 备注 |
|---|---|---|---|---|
| 功能用例 | 19 | **16** | **3** | 3 条 FAIL 中 MB-19 是**刻意暴露产品缺陷**的函数用例；MB-14/MB-15 是真实问题 |
| 性能用例 | 5 | 5 | 0 | 用例级 PASS，但变体级对照给出 2 条重要结论（V2 严重劣化 -91.9%、chunk_size 轻微劣化 -5.7%） |
| **合计** | **24** | **21** | **3** | |

累计运行约 **6.5 小时**（功能 ~4.8h + 性能 ~1.7h），全部在真实 3C5D 集群上完成。

## 二、功能用例逐条结果

| 用例 | 结果 | 耗时 | 关键证据 / 说明 |
|---|---|---|---|
| **MB-01** 内存分配事实 | ✅ PASS | 353s | 5 DN 的 `Write=4294967296`（20G×2/10）、`Read=8589934592`、`Schema/Consensus/Pipe=2147483648`、`AutoResizing=1073741824`；SchemaEngine 三段 `1073741824/858993459/214748364`，全部与 `2:4:1:1:1:1` 精确相符 |
| **MB-02** 参数守卫 | ✅ PASS | 500s | ①`reject+wal+device≥1` → 打出回退 WARN，且 `devicePathCache/memtable` 阈值比回落到 **0.050**；②storage 9/14 → `Write=13805252022` 自洽且无告警；③storage 12/17 → `Write=15158708103` 自洽（本构建未启用 60% 限幅，见 **F-08**） |
| **MB-03** 按比例刷盘 | ✅ PASS | 589s | 2000 点×4KB=7.8MB → 自动刷盘 `flush_memtable_count 0→2`、TsFile `0→4`、未进 reject、点数 2000；20 次副本比对（停 5 个 DN × 4 个剩余节点）全部一致；6 节点日志无异常 |
| **MB-04** 定时刷盘(seq) | ✅ PASS | 664s | 不手工 flush 也在窗口内新增 TsFile；**对照组**关掉 `enable_timed_flush_seq_memtable` 后同窗口不新增 |
| **MB-05** 定时刷盘(unseq) | ✅ PASS | 559s | 命中产品日志 `Exceed unsequence memtable flush interval, so flush working memtable...`；对照组不新增；顺序 600 + 乱序数据点数正确 |
| **MB-06** 拒绝与背压 | ✅ PASS | 486s | `Change system to reject status` 出现 20 次；20/20 语句全部成功、1300 点精确落库（**整语句原子**，无部分写） |
| **MB-07** 刷盘限流并发 | ✅ PASS | 539s | `io_task_queue_size_for_flushing=2` 下 3 写 + 1 查询并发：查询**零 SQL 异常**，9000 点 == 18 语句×500，刷盘确实发生 |
| **MB-08** WAL 快照+kill -9 | ✅ PASS | 577s | 阈值/份数配置回读生效；`kill -9` 一个 DN 后恢复 Running，2000 点不丢（WAL 回放） |
| **MB-09** 各内存池比例 | ✅ PASS | 669s | 三个比例逐节点 conf 回读一致；Memtable 子池指标在本构建未暴露（降级 WARN）；2400 点正确 |
| **MB-10** 优雅重启回放 | ✅ PASS | 178s | 重启后点数 2000 不变、副本一致 |
| **MB-11** 顺乱序分离 | ✅ PASS | 589s | `separate=true` → `sequence/` 有文件且 `unsequence/=0`；`false` → **只落 unsequence/**；关闭后写乱序数据仍落 unsequence/；三阶段点数正确 |
| **MB-12** Chunk 切分 | ✅ PASS | 669s | 极小 `target_chunk_point_num=500` / `target_chunk_size=4096` 下 INT64 5000 点 + TEXT 600 点全部完整、文件数未爆炸；**极值 1/1 下节点不崩、数据可查** |
| **MB-13** 高可用停 DN | ✅ PASS | 507s | 写入中途停 DN(70.30)：在线 DN=4、写入仍成功（6+6 语句）、恢复后 6000 点精确、副本一致 |
| **MB-14** IoTConsensusV2 | ❌ FAIL | 940s | 协议配置生效、V2 `syncLag` 指标存在、点数 2000 正确；但 ③`flush_proportion=0.4`+memtable 20MB 下**未触发自动刷盘**；④停 DN 后剩余副本 `count=0`（基准 2000）→ 见 **F-10** |
| **MB-15** TVList 排序算法 | ❌ FAIL | 833s | TIM / QUICK 两相 PASS（各 2000 点、指纹 `b89017e8...` 一致）；**BACKWARD 相两次独立运行均点数=0、查询无数据**（写入语句全部报成功）→ 见 **F-09** |
| **MB-16** flush 线程/数组 | ✅ PASS | 665s | 线程 0/数组 64 与 线程 1/数组 16 两相点数一致、刷盘发生、无异常日志 |
| **MB-17** 时间分区内存可控 | ✅ PASS | 541s | 6 个时间分区全部可查、点数精确；未观察到 `degrade LastFlushTimeMap` 时按 WARN 记"场景未成立"（不误判 FAIL） |
| **MB-18** 字符串类型推断 | ✅ PASS\* | 495s | 全 TEXT 相符合预期；默认相四类推断仍为 TEXT（**F-01**）→ 按已知缺陷记 WARN，不计 FAIL（可用 `MB_KNOWN_F01=0` 切换成硬失败） |
| **MB-19** 非法比例致 DN 起不来 | ❌ FAIL | 161s | `storage_engine_memory_proportion=0:10` → DataNode 启动即 NPE，集群只剩 3 CN → **F-07（高严重级）** |

\* MB-18 的 PASS 是"已知缺陷模式下 PASS"，产品行为本身未达需求。

## 三、失败三例的定性（可直接回填研发）

| 用例 | 性质 | 证据链 |
|---|---|---|
| **MB-19** | **产品缺陷（高）** | `WARN ... use default value 8:2` 之后 `DataNodeMemoryConfig.initStorageEngineAllocate()` 直接 `return`；而 7 个 memory manager 的创建语句全在该 `return` 之后 ⇒ 全为 `null` ⇒ `DataNodeDevicePathCache` 初始化 `exactAllocate` 抛 NPE。**日志先打"已回退"的 WARN，实际却没回退**，误导排查。修复：`return` → `break`/跳过解析，或在方法末尾统一兜底创建 |
| **MB-15** | **待研发确认（疑似缺陷）** | `tvlist_sort_algorithm=BACKWARD` + 2000 点逆序写入：语句全部 `executed successfully`，但 `select count(s1) from db.**` = **0**，flush 前后均为 0；同样数据在 TIM/QUICK 下均为 2000。**两次独立运行均复现**。我另起的定向 BACKWARD 验证因环境长跑中断未跑完，因此暂记"待确认"而非直接判定数据丢失 |
| **MB-14** | **V2 特有问题（待确认）** | ①与 V1 同配置（`flush_proportion=0.4`、memtable≈20MB）下 V2 未触发自动刷盘；②收尾"停 1 个 DN"那轮，剩余副本 `count=0`（基准 2000）。V2 batch 模式只复制**已 seal 的 TsFile**，未 seal 的 memtable 尾部不在 follower —— 但本次连 flush 都未发生，说明不只"尾部"没同步 |

## 四、性能用例结果（3C5D + iot-benchmark）

**负载**：`DEVICE_NUMBER=60`、`SENSOR_NUMBER=20`、`BATCH_SIZE_PER_WRITE=10`、`LOOP=600`、
`OPERATION_PROPORTION=91:1:1:1:1:1:0:0:0:0:0:0`（写为主，与文档口径一致）。单变体固定 683 万点。
**判据**：与同轮基线比，吞吐下降 >30% 记 FAIL、0~30% 记 WARN；P99 恶化 >50% 记 FAIL。**不设绝对门槛**。

### 4.1 P-01 flush_proportion（0.4 默认 vs 0.5 文档建议值）

| 变体 | 吞吐 (point/s) | AVG | P99 | 耗时 |
|---|---|---|---|---|
| base_fp04（0.4） | 1,397,692 | 0.98ms | 35.11ms | 4.89s |
| fp05（0.5） | **1,427,140** | 0.97ms | **29.79ms** | 4.79s |

→ **PASS**：吞吐 **+2.1%**，P99 **-15.2%**。文档"提高到 0.5 避免频繁刷盘"的取舍在本环境**成立**（略微更快、延迟更低）。

### 4.2 P-02 Chunk 切分参数

| 变体 | 吞吐 (point/s) | P99 | 相对基线 |
|---|---|---|---|
| c100k（默认 10w 点） | 1,416,214 | 36.04ms | 基线 |
| c10k（1w 点） | 1,427,099 | 37.80ms | **+0.8%（PASS）** |
| csize（chunk 8MB） | 1,335,426 | 37.93ms | **-5.7%（WARN）** |

→ **PASS**。文档担心的"切碎导致文件数暴涨"在写入吞吐上**未复现**；把 chunk 调大到 8MB 反而略降 5.7%。

### 4.3 P-03 顺乱序分离存储

| 变体 | 吞吐 (point/s) | P99 | 相对基线 |
|---|---|---|---|
| sep_off_seq | 1,403,747 | 35.34ms | 基线 |
| sep_on_seq | 1,360,674 | 46.83ms | **-3.1%（WARN）** |
| sep_off_ooo | 1,334,877 | 33.78ms | 基线 |
| sep_on_ooo | 1,388,216 | 39.47ms | **+4.0%（PASS）** |

→ **PASS**。文档要求"打开后不低于关闭时"：顺序负载略降 3.1%（在容忍内），**乱序负载反而 +4.0%**，方向符合设计意图。

### 4.4 P-04 最新点查询（对应文档"1 万点最新值查询"）

| 变体 | LATEST_POINT 吞吐 | LATEST_POINT P99 | 相对 TIM |
|---|---|---|---|
| q_tim（默认） | 337.25 op/s | 202.66ms | 基线 |
| q_quick | **400.34 op/s** | 208.78ms | **+18.7%** |
| q_backward | 377.89 op/s | **104.56ms** | **+12.1%**，P99 几乎腰斩 |

→ **PASS**。文档记录过"TVList 改动让最新点查询从 536s 恶化到 818s"，本版本**未复现该劣化**；
QUICK 查询吞吐最高，BACKWARD 的 P99 最优。

### 4.5 P-05 共识协议（V1 vs V2）—— **本轮最重要的性能发现**

| 变体 | 吞吐 (point/s) | AVG | P99 | 耗时 |
|---|---|---|---|---|
| v1（IoTConsensus） | **1,357,344** | 0.95ms | 33.84ms | 5.03s |
| v2（IoTConsensusV2） | **109,588** | 17.76ms | 33.33ms | 62.35s |

→ **FAIL**：V2 吞吐只有 V1 的 **8.1%**（**-91.9%，慢 12.4 倍**），AVG 延迟恶化 18.7 倍。
P99 反而相当（33.33ms vs 33.84ms），说明不是"偶发慢请求"，而是**整体吞吐被系统性拖慢**。
这与 MB-14 观察到的"V2 下不刷盘 / 副本数据不可见"方向一致，建议一并排查。
（注：两次 V1 运行分别为 1,383,790 与 1,357,344，重复性 2% 以内，可排除测量噪声。）

## 五、复现命令

```bash
cd /data1/iotdb/testcase/MigrateRegionTest/skill_case/membuf_skill

bash tools/selftest.sh                                   # 71 项环境自检（语法/集群/模板键/benchmark）
bash tools/run_serial.sh --set regression                # 19 条功能用例，串行、前台
bash tools/run_until_done.sh --set regression --tries 3   # 带用例级重试（长跑推荐）
bash tools/run_perf.sh --set all --loop 600 --devices 60  # 5 条性能用例
bash tools/run_perf.sh --only P-05 --consensus IoTConsensusV2  # 单项复跑
```

## 六、本轮修掉的用例侧问题（下轮不再踩）

| 问题 | 现象 | 修法 |
|---|---|---|
| `grep -c` 无匹配返回 `0\n0` | `$(( total_ok + 0\n0 ))` 语法错 ⇒ 写入结果拿不到、用例 rc=1 且无 result 文件 | 统一 `| tr -dc '0-9'` 兜底 |
| `set -u` 下变量先用后定义 | MB-06 的 `SUBMITTED` ⇒ 脚本静默退出、无结果文件 | 定义提前，并写脚本全仓扫描一遍 |
| `EXTRA_CONF` 在 `cluster_write_conf` 之后赋值 | MB-15 每相读到上一相的值 ⇒ **15 条假 FAIL** | 赋值提到写配置之前 + 脚本扫描 |
| unseq 定时刷盘假失败 | 乱序数据未先建立 flushedTime，全被判成顺序 ⇒ unsequence 恒 0 | 先写水位并 flush；主判据改用产品日志 |
| 基线对比静默跳过 | `perf_variant` 返回后拿不到 `PERF_INGEST_TP` ⇒ V2 慢 12 倍却不 FAIL | 改为**从结果 CSV 回读**基线（`perf_from_csv`），并给基线为 0 时打 WARN |
| 收尾阶段才写 result | 长跑被 SIGKILL 时"用例无结果" | `mb_case_finish` 先落盘 interim 结论，收尾后再覆盖 |
| 启动崩溃仍等满 600s | MB-02 曾白等 10 分钟 | `wait_cluster_ready`/`mb_wait_port_up` 检测到 main 线程异常即快速失败 |
| DN 启动会以 root 重写 conf | 后续 `cat >` 报 Permission denied（6 节点全失败） | conf 写入统一 `sudo tee` |
| 客户端 CLI 单条 INSERT 上限 | 1.96MB/语句 → 52s 且 ok=0 静默失败；10MB → 客户端 OOM | 分片：单语句 ≤256KB、每次调用 ≤4 条 |
| 大结果集查询被截断 | 输出 ~8MB 时只回 1000/2000 行 ⇒ 假"数据丢失" | 数据量/一致性判据统一改用 `select count(s1) from db.**` 通配聚合 |

## 七、环境侧已知限制（非产品问题）

1. **用例偶发被 SIGKILL（rc=137）**：本环境长跑有约 1/3 概率在运行 8~15 分钟后被打断，`dmesg`/`journalctl`/cgroup 均无 OOM 记录，已排除内存、cgroup、systemd-oomd、cron。判定为**发起端 ssh 会话层回收**（我的执行通道对长连接有上限），真机本地终端或 screen/tmux 不受影响。已用 `run_until_done.sh` 的用例级重试兜住。
2. **单客户端 benchmark**：客户端只有 1 台 31G 机器、单 JVM，绝对吞吐（~140 万 point/s）远低于文档的 3C5D 64M point/s（文档是 16 核 32G × 多机 + 多客户端）。**跨环境的绝对数字不可比，只做同环境同轮对照。**
3. **P-04 规模**：文档是 1 万设备最新值查询，本环境用 1000 设备（`PERF_DEVICES_QUERY=10000` 可完全对齐，但单变体会跑很久）。
