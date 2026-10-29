# CO-11 / CO-14 RC7 双协议 FAIL 定性结论（triage）

> **被测版本**：`v20121rc7_1014_7c61428`（RC7，2.0.12.1 / `7c61428`），3C3D（192.168.99.77/78/79，RF=3），
> 对照版本 RC6 `v20121rc6_1010_7ae8713e`（`7ae8713e`）。证据来自 99.80 上 `compaction_skill/results/` 的
> `*.out`、`artifact_*/logs/*.log`、`perf_baseline.csv`、`test_result*.csv`（**只读**：ssh 读取 + scp 到本机 `%TEMP%`
> 的副本上做统计；未启动/停止集群，未在 77/78/79 上跑用例，未修改 `cases/`、`tools/`、`results/`、`docs/RESULTS.md`）。
> **源码依据**：`D:\IDEA\timechodb_src\v20121\timechodb`（RC7 源码树），下文所有 `文件:行号` 均指该树。
> **结论口径**：(a) 产品行为变化（回归，建议提单）｜(b) 环境/时序｜(c) 用例窗口/构造｜(d) 证据不足需定向复跑。

---

## 0. 先纠正 3 处事实（否则证据会对不上号）

| # | 任务描述里的说法 | 实际情况（本文件核对结果） |
| --- | --- | --- |
| 0-1 | CO-11「V1 输出 2026-10-16 00:41 那次，elapsed≈1698s，消息 finishes=12(基线12)…」 | **00:41 那次是 PASS**（`CO-11_20261016_004107.out`，`elapsed=820s`，`finishes 基线4→12`）。1698s / `finishes=12(基线12)` 属于 **`CO-11_20261015_201417.out`**（内部 `run_id=20261015_213535`，对应 artifact `artifact_co_perf_baseline_IoTConsensus_20261015_213535`）。`.out` 文件名用的是套件时间戳，artifact 用的是用例内部 `run_id`，两者不同。 |
| 0-2 | CO-14「V1（2026-10-15 22:24 那次）elapsed≈643s，fail=2」 | **RC7 上 CO-14 的 IoTConsensus(V1) 是 PASS**：`CO-14_20261015_201417.out` → `RESULT PASS fail_flag=0 elapsed=577s`（CSV：`test_result_rc7_v1_archived_20261016_041349.csv`）。`643s / fail_flag=2` 属于 **V2** 那次（`CO-14_20261016_041349.out`，内部 `run_id=20261016_063147`）。所以「两协议都 FAIL」只对 CO-11 成立；**CO-14 只有 V2 FAIL**。 |
| 0-3 | CO-14「V2 输出 2026-10-16 06:31 那次」 | 06:31:47 结束的是 **CO-13**（`co_ttl_settle_IoTConsensusV2`，PASS 639s）；CO-14 V2 是 **06:31:47 开始、06:42:30 结束**（643s）。 |

另外两条贯穿全篇的**证据边界**（先说清楚，后面不再重复）：

* **artifact 里没有 jstack**：`artifact_*/logs/` 只有各节点 `log_*.log`（tar 包解开后逐文件核对，无 `jstack*.txt`）。
  「是否卡在 `TsFileResource.writeLock`」只能靠用例自己的 `cmp_stuck_sum()`（`lib/cmp.sh:126-132`，实时 `jstack | grep -c`）的判定结果反推：
  两次 FAIL 的 `fail_flag` 分别是 **1（CO-11 V1）/1（CO-11 V2）/2（CO-14 V2）**，而 `fail_flag` 是 `fail()` 的**计数器**
  （`lib/common.sh:70`），所以「`fail_flag` 里没有卡死项」= `cmp_stuck_sum()==0`。
* **artifact 没有目录/文件清单**：用例只把 TsFile 数**合计**写进日志（`cmp_all_sum`），没有逐副本/逐空间（seq/unseq）明细，
  凡涉及「32 个文件是怎么构成的」这类问题，本文件如实标为**不可复原**，并在复跑方案里补采。

---

## 1. CO-11（合并性能基准，`cases/common/co_perf_baseline.sh`）

### 1.1 用例到底断言什么（判据在哪儿）

| 环节 | 代码 | 说明 |
| --- | --- | --- |
| 写入阶段三类合并全关 | `co_perf_baseline.sh:29` | `CMP_EXTRA_WRITE` 写 conf：`enable_seq/unseq/cross_space_compaction=false` |
| 记输入文件数 | `co_perf_baseline.sh:41` | `IN_FILES=$(cmp_seq_sum "$DB")` → **只数 sequence 空间**（`lib/cmp.sh:78,81`） |
| 记 finishes 基线 → 热开合并 | `co_perf_baseline.sh:49-51` | `cmp_set_hot enable_seq_space_compaction true` **之后**才 `fin0=$(cmp_inner_finish "$DB")` |
| 等合并（判据核心） | `lib/cmp.sh:134-144` | 成功条件 = `f > fin0` **且**（`t < ts0` 或 `t < first_ts`）；`t = cmp_all_sum` = **seq+unseq**（`lib/cmp.sh:83`） |
| 记输出文件数 | `co_perf_baseline.sh:59` | `OUT_FILES=$(cmp_seq_sum "$DB")` → 又是 **只数 seq** |
| finishes 计数口径 | `lib/cmp.sh:103,115` | `cmp_log_files()` 返回 **`log_datanode_compaction.log` + `log_datanode_all.log` 两个文件**，`cat` 后 grep → **同一条 finish 被计 2 次** |
| 卡死判据 | `co_perf_baseline.sh:66-67` + `lib/cmp.sh:126-132` | `jstack <pid> | grep -c 'TsFileResource.writeLock'`，>0 才 FAIL |
| 窗口 | `co_perf_baseline.sh:25` | `WIN=${CO_PERF_WIN:-900}` |

### 1.2 四次运行的数字（`perf_baseline.csv` + `.out` + DN 日志）

| # | 时间（用例时钟） | build | 协议 | 输出文件 | artifact（日志） | 规模(点) | IN(seq) / 逐节点 | finishes 基线→终值（唯一任务数） | TsFile(seq) | merge_seconds | RESULT |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 2026-10-12 16:14:28 | RC6 `7ae8713e` | V1 | `CO-11_20261012_161428.out` | 空（PASS 不备份） | 180000 | 36 / 12-12-12 | 16→24（8→12） | 36→12 | 7 | **PASS 478s** |
| 2 | 2026-10-15 21:35:35 | RC7 `7c61428` | V1 | `CO-11_20261015_201417.out` | `artifact_..._IoTConsensus_20261015_213535` | 600000 | 36 / 12-12-12 | **12→12（6→6）** | 36→12 | **905** | **FAIL fail=1 elapsed=1698s** |
| 3 | 2026-10-16 00:41:07 | RC7 | V1 | `CO-11_20261016_004107.out` | 空 | 600000 | 36 / 12-12-12 | 4→12（2→6） | 36→12 | 8 | **PASS 820s** |
| 4 | 2026-10-16 05:41:52 | RC7 | **V2** | `CO-11_20261016_041349.out` | `artifact_..._IoTConsensusV2_20261016_054152` | 600000 | **14 / 0-7-7** | **2→4（1→2）** | 14→**4** | **904** | **FAIL fail=1 elapsed=1710s** |

> finishes 的「唯一任务数」= 日志条数 ÷ 2（见 1.1 口径）；下同。

**运行 2（V1 FAIL）的 DN 日志证据** —— 全部 6 个任务（每节点 2 个）在基线读取前就已完成：

```
artifact_co_perf_baseline_IoTConsensus_20261015_213535/logs/192.168.99.79.logs/logs/log_datanode_compaction.log
2026-10-15 21:46:32,436 ... InnerSpaceCompactionTask:239 - root.coperf-4 [Compaction] Sequence InnerSpaceCompaction task starts with 5 files, ...
2026-10-15 21:46:32,464 ... InnerSpaceCompactionTask:266 - root.coperf-4 [Compaction] Sequence InnerSpaceCompaction task finishes successfully, target files are [{file: .../1792071746729-1-1-0.tsfile}],time cost is 0.01 s, ... total process point num: 250000
（同一秒内 root.coperf-3 同样 start/finish）
.../192.168.99.78.logs/logs/log_datanode_compaction.log
2026-10-15 21:46:39,510  root.coperf-3 / -4 task starts with 5 files  → 21:46:39,536 两个任务 finishes successfully
.../192.168.99.77.logs/logs/log_datanode_compaction.log
2026-10-15 21:46:41,198  root.coperf-3 task starts with 5 files → 21:46:41,222 finishes successfully
2026-10-15 21:46:41,297  root.coperf-4 task starts with 5 files → 21:46:41,308 finishes successfully
```

* 该库 `root.coperf` 在这份 artifact 的 compaction 日志里**只有这 6 条 start / 6 条 finish**（3 节点 × 2 region），
  22:02:19 之后出现的只有 `CompactionRecoverManager:80` 的 recover 行（用例收尾重启节点产生的），**没有第 7 个任务**。
* 用例第一次轮询（`CO-11_20261015_201417.out`，也是 CSV message 里那条）：
  `[2026-10-15 21:46:42] 等合并: finishes=12(基线12) tsfile=12(基线36 首次12)` —— 首次轮询看到的就是**终态**；
  此后 244 次轮询**全部**是同一个字符串（`finishes=12(基线12) tsfile=12(基线36 首次12)`），到 22:01:39 超时。
* 同一次运行的 `perf_baseline.csv` 行：
  `2026-10-15T22:01:41+08:00,v20121rc7_1014_7c61428,IoTConsensus,co_perf_baseline,600000,36,210684,12,197796,905,663.0,0.94`
  ⇒ **输入 36 → 输出 12（文件数确实降了）**，字节 210684 → 197796；`merge_seconds=905` 是**窗口本身**，不是合并耗时。

**运行 3（同 build、同协议、同规模，2 小时后 PASS）**：`fin0=4`（2 个任务）→ 终值 12（6 个任务），
`PASS 合并完成：...finishes=12(基线4) tsfile=12(基线36 首次12)`，`merge_seconds=8`。
⇒ **同一构建、同一协议、同一规模，一次 FAIL 一次 PASS，差别只在「读 `fin0` 的瞬间落在 6 个任务完成之前还是之后」。**

**运行 4（V2 FAIL）的证据**：

```
（.out）写入耗时=501s；输入：14 个 TsFile / 212586B（逐节点 77=0 78=7 79=7）
（.out）WARN root.coperf 有 DN 的 TsFile 未落盘              ← ensure_closed 3 轮 flush 全失败（co_perf_baseline.sh:40）
（.out）244 次轮询全部为：finishes=4(基线2) tsfile=32(基线14 首次32)
（perf_baseline.csv）2026-10-16T06:08:15+08:00,...IoTConsensusV2,co_perf_baseline,600000,14,212586,4,207586,904,663.7,0.98
artifact_..._IoTConsensusV2_20261016_054152/logs/192.168.99.78.logs/logs/log_datanode_compaction.log
2026-10-16 05:53:14,784 InnerSpaceCompactionTask:239 - root.coperf-3 [Compaction] Sequence InnerSpaceCompaction task starts with 6 files
2026-10-16 05:53:14,834 InnerSpaceCompactionTask:266 - root.coperf-3 ... finishes successfully, ... time cost is 0.05 s, ... total process point num: 250000, rewrite point num: 50000
.../192.168.99.79.logs/logs/log_datanode_compaction.log
2026-10-16 05:53:06,450 ... root.coperf-6 ... starts with 6 files → 05:53:06,497 finishes successfully（同样 250000 点）
.../192.168.99.77.logs/logs/log_datanode_compaction.log
（root.coperf 一条 Compaction 行都没有；只有 05:53:15,770 起的 10 条 `CompactionWorker:67 - CompactionThread-N terminates because interruption`
 + 05:53:15,772 `CompactionTaskManager:474 - Compaction task manager started.`，即热改配置触发的调度器重建）
```

* V2 的两个任务各把 **6 个文件并成 1 个**（`-5` 个文件），合计 `14 → 4`，与 perf CSV 的 `in=14/out=4` **完全对上**；
  字节 212586 → 207586（数据没丢），`rewrite point num: 50000 = 600000/12`（跨 2 批的重写量，正常）。
* `finishes 2→4` = **确实又多完成了 1 个任务**，即「合并没停」；失败的是 TsFile 判据：轮询用的 `t=seq+unseq` 从基线的 14
  涨到 32（**32 > ts0=14，`t < ts0` 永远不可能成立**），而基线 14 是在 `ensure_closed` 失败、且**节点 77 的落盘数为 0** 的
  瞬间采到的（`IN(seq)=14` 与 `ts0(all_sum)=14` 同时成立 ⇒ 那一刻 unseq=0，之后才涨上去）。
* `32` 的构成**无法从现有 artifact 复原**（见 §0 证据边界）：artifact 里节点 77 全程 `Async close tsfile: ...root.coperf` 条数为 **0**、
  `log_datanode_all.log` 里也没有 77 的 coperf 文件清单；用例只记了合计。**但这不影响定性**：`ts0` 采在「落盘未完成」的瞬间，
  它本来就不能当作「必须回落到其以下」的稳定基线。

### 1.3 三个候选假设逐条判据

| 假设 | 判据 | 结论 |
| --- | --- | --- |
| ① 基线**取晚了**（合并已在记基线前完成） | 运行 2：DN 日志 6 个任务全部 `finishes successfully` 于 21:46:32~21:46:41；`fin0=12` = 6 个任务 × 2（双日志口径）= **全部 6 个**；终值也是 12（`+0`）。同 build 运行 3 的 `fin0=4`（2 个）→ 终值 12 ⇒ 差异只在采样时刻 | **成立（V1 的唯一失效原因）** |
| ② 合并**真的卡住**（finishes 不增 + TsFile 不降 + writeLock 卡死） | TsFile **降了**（36→12 / 14→4，perf CSV 双证）；`fail_flag=1` ⇒ `cmp_stuck_sum()=0` ⇒ **无 `TsFileResource.writeLock` 卡死线程**；artifact 无 jstack（无此项证据）；合并任务 `time cost 0.01~0.05 s` | **不成立** |
| ③ **窗口/规模不够**（合并在跑，只是 900s 没跑完） | 合并 8s（运行 3）/ 6~8s（运行 1）/ 两次任务各 0.05s（运行 4）；运行 2 给了 **900s** 观察窗，期间 `task starts` **0 条**（日志可查）⇒ 不是在跑，是**已经收敛**；收敛点由选择器决定，见 §1.4 | **不成立** |

### 1.4 源码出处（为什么「合并到这里就该停」）

1. **合并的最小规模与停止条件**（默认 selector `size_tiered_multi_target` → `NewSizeTieredCompactionSelector`）：
   * `.../compaction/selector/impl/NewSizeTieredCompactionSelector.java:316-318`
     ```java
     if (totalFileNum < 2) {
       return;                       // 少于 2 个文件不建任务
     }
     ```
   * 同文件 `:337-342`
     ```java
     boolean isSatisfied =
         (currentSelectedResources.size() >= totalFileNumLowerBound   // =inner_compaction_candidate_file_num(本用例=2)
                 || !isActiveTimePartition
                 || currentSelectedFileTotalSize >= singleFileSizeThreshold
                 || reachMemoryLimit)
             && currentSelectedResources.size() > 1;
     ```
   * 同文件 `:128-134`：**task 为空时只挑与当前 level 相同的文件**（`innerCompactionCount != level → continue`）。
     ⇒ 合并后每个 region 只剩「1 个 L1 产物 + 1 个 L0」，每个 level 只有 1 个文件 ⇒ `totalFileNum < 2` ⇒ **再等多久都不会有新任务**
     （这就是运行 2 里 900s 内 0 条 `task starts` 的原因）。层级差门槛见 `:238-240`（`|cnt-level| <= maxLevelGap`）。
   * 经典 selector（`size_tiered_single_target` → `SizeTieredCompactionSelector.java:128-137,157-167`）同样要求一个任务至少 2 个文件。
2. **不合法的候选文件**：`SizeTieredCompactionSelector.java:171-174` / `SettleSelectorImpl.java:172-174`
   ```java
   private boolean cannotSelectCurrentFileToNormalCompaction(TsFileResource resource) {
     return resource.getStatus() != TsFileResourceStatus.NORMAL
         || !resource.getTsFileRepairStatus().isNormalCompactionCandidate();
   }
   ```
   `TsFileResource.java:159` 新建时状态是 `UNCLOSED`；`:1055-1099` 由 close 流程改成 `NORMAL`。
   ⇒ **没关闭（未落盘）的 TsFile 不参与 inner/settle 选择** —— 这解释 V2 里 `77=0` 与「未落盘」告警同时出现时，基线不可能稳定。
3. **落盘（close 事件）的日志出处**：`DataRegion.java:2395-2419`（`tsFileProcessor.asyncClose()` + `:2410` 打
   `Async close tsfile: {} file start time {} file end time {}`）—— 本文件统计 close 事件的依据。
4. **提交/节流**：`CompactionScheduler.java:377`（三类合并全关 ⇒ 直接返回 0）；提交入口
   `CompactionTaskManager.addTaskToWaitingQueue`（`CompactionScheduler.java:409`）；本用例把
   `compaction_schedule_interval_in_ms=1000`、`inner_compaction_candidate_file_num=2` 写进 conf（`co_perf_baseline.sh:29`），
   默认值为 `IoTDBConfig.java:565 innerCompactionCandidateFileNum = 30`、`:532 maxLevelGapInInnerCompaction = 2`、
   `:530 inner_compaction_total_file_num_threshold = 100`、`:528/535` 10GB/2GB。
5. **TDB-629 同族（读锁泄漏→合并卡死）对照**：`TsFileResource.java:860-864`（`writeLock`）/`:880-884`（`readLock`）——
   本文件判据 `cmp_stuck_sum()` 正是抓 `TsFileResource.writeLock` 栈帧；**RC7 两次 FAIL 的 `fail_flag` 里都没有这一项**，
   且 `e46c4b7a7d`（修 `DiskUsageStatisticUtil` 的 readLock 泄漏）已在 RC6，本轮**没有**同族迹象。

### 1.5 判定

| 运行 | 判定 | 理由（一句话） |
| --- | --- | --- |
| CO-11 V1（RC7，21:35 那次） | **(c) 用例窗口/构造问题** | `fin0` 在「热开合并之后」才采（`co_perf_baseline.sh:49-50`），而合并只要 8s；采样落在合并完成之后 ⇒ `f > fin0` 恒不成立，文件数 36→12、指纹一致、无卡死线程、收尾三件套全过（`fail_flag=1`）。**不是 RC7 行为变化**：同 build 同规模 2 小时后 PASS（`merge=8s`），RC6 的 7s/180k 点与 RC7 的 8s/600k 点性能一致。 |
| CO-11 V2（RC7，05:41 那次） | **(b)+(c)**：环境时序（V2 三副本落盘不齐，77 关闭事件=0）＋用例判据口径混用（`IN/OUT` 只数 seq，判据 `t=seq+unseq`） | 合并本身完成了（`14→4`、字节保全、`time cost 0.05s`、`finishes 2→4`），FAIL 只因基线 `ts0=14` 采在「77 尚未落盘」的瞬间、之后 `seq+unseq` 涨到 32。**不是 RC7 行为变化**。 |

> 关于「是不是 RC7 的变化」的正面回答：**不是**。`perf_baseline.csv` 里 RC6（180k 点）7s / RC7（600k 点）8s，
> 单位点耗时同量级；RC7 内部一次 FAIL 一次 PASS。CO-11 暴露的是**用例的采样竞态（+ 计数口径混用）**，
> RC7 全量回归把 `CO_PERF_ROWS` 覆盖去掉（180k→600k，写入 158s→490s）后，这个竞态才被踩到。

### 1.6 最小定向复跑方案（**不要现在执行**；涉及改 `cases/`，需你确认）

目的：把「基线取晚 / 口径混用」变成**确定性判据**，并钉死 V2 的 32 是怎么来的。

```bash
# 环境：99.80；单条用例（约 15~25 分钟）
cd /data/iotdb/autotest/compaction_skill
V_TESTDB=v20121rc7_1014_7c61428 BUILD_TAG=v20121rc7_1014_7c61428 \
CO_PERF_DEVS=10 CO_PERF_ROWS=10000 CO_PERF_BATCHES=6 CO_PERF_WIN=900 \
bash cases/common/co_perf_baseline.sh --consensus IoTConsensus      # 再各跑一次 --consensus IoTConsensusV2
```

需要在用例里做的**最小改动**（建议，等批准后再改）：

1. **基线前置 + 双采样**：`fin0` 取在 `cmp_set_hot` **之前**；热开后再取一次 `fin0b`，判据用
   `fin_now > fin0b`，并额外断言 `fin0b < fin_final`（若 `fin0b == fin_final` 说明采样又晚了，记 `WARN 采样竞态` 而非 FAIL）。
2. **判据单一口径**：`IN_FILES/OUT_FILES` 与等待判据都改成**同一个量**（只用 `cmp_seq_sum`），
   或都改成 `cmp_all_sum`；并在日志里同时打印 `seq/unseq` 两个数。
3. **基线可用性硬断言**：`ensure_closed` 失败（有 DN 未落盘）或逐节点计数出现 0 时，**不允许**把它当作 `ts0`：
   先 `flush` 重试到各节点均有新 close 事件（或直接 `pass` 场景无效并重跑写入段）。
4. **补采证据**：写入段结束与窗口结束时各采一次**逐节点 × seq/unseq** 计数；把 `jstack` 原始输出（含 `TsFileResource.writeLock` grep）
   一起写进 artifact（当前只有计数，没有原文）。

判据（预期）：`IN(seq)` 逐节点均衡（600k 点下应为 12/12/12）、`merge_seconds ≤ 60`、`OUT(seq)=12`、
`fin` 增量 ≥ 1（唯一任务数）、`cmp_fp_tree` 与合并前完全一致、`cmp_stuck_sum()=0`、`fail_flag=0`。
**若两次（V1/V2）在 `fail_flag=0` 下 `merge_seconds` 都落在 5~15s**，则 CO-11 的 FAIL 100% 是用例侧，可结案。

---

## 2. CO-14（表模型 TTL × 合并，`cases/table/co_ttl_table_settle.sh`）

### 2.1 用例断言什么（含参数与被测窗口）

* 参数：`DEVS=6`（`CO_DEVS=6`）、`ROWS=300`、`WIN=90s`、`TTL=24h→30s`、
  `TTL_CHECK_INTERVAL_MS=5000`、`MAX_EXPIRED_TIME_MS=Long.MAX_VALUE`、`EXPIRED_DATA_RATIO=0.000001`（`:22-27,54-58`）。
* 第 1 轮（先写 48h 前的 d1..d6 → 设 TTL=24h）：判据 `settle 增加 **或** TsFile 下降`（`:78-86`）。
* 第 4 轮（再写"新鲜"d7..d12，时间戳 `NOW-20s/NOW-10s`）：在线合并推进 + 指纹不变（`:90-109`）。
* 第 5 轮（TTL→30s）：`alter ttl=30000; flush; sleep 20` **之后**才采基线 `TS3`（`:112-117`），
  循环判据**只有** `cur_ts < TS3`（`:121`），不满足只 `warn`（`:125`）。
* 第 6 轮（TTL→'INF'）：断言 `count=0`（`:127-133`）——「过期数据已物理删除，合并未复活」。
* 收尾：sync lag → **副本一致性**（`common.sh:563-585`：以 `DN[0]=.77` 为基准，**逐个停 1 个 DN** 再经其余节点查）→ 日志扫描。
* `flush;` 不保证三副本同时 close：用例自己用 `ensure_closed` 等 close 事件（`common.sh:208-218`），
  并用 `common.sh:205-207` 的注释明确「**未关闭的 TsFile 不参与 settle 选择**」。

### 2.2 四次运行的数字

| # | 时间 | build | 协议 | 输出/日志 | RESULT | 关键数字 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 2026-10-12 16:58 | RC6 | V1 | `CO-14_20261012_165832.out` / artifact `..._20261012_171035` | FAIL 661s fail=3（后判定为**用例侧**：合并基线晚；见 RESULTS.md 事故 7/8） | 三节点对称：`Async close(cottltb)=6/6/6`、`settle starts=2/2/2`、非零 TTL 候选 `2/2/2` |
| 2 | 2026-10-12 18:50 | RC6 | V1 | `CO-14_20261012_185017.out` / 空 artifact | **PASS 570s fail=0** | message 含 WARN「第二轮窗口内 TsFile 数未下降（**0 → 0**）」 |
| 3 | 2026-10-15 22:24 | **RC7** | **V1** | `CO-14_20261015_201417.out` / 空 artifact | **PASS 577s fail=0** | 第 1 轮 `settle 0→6，TsFile 6→0`；第 5 轮 `settle 6→12，TsFile 0→0` ⇒ WARN「（0 → 0）」；`TTL=INF 后 count=0` PASS；三副本一致性 6/6 PASS |
| 4 | 2026-10-16 06:31 | **RC7** | **V2** | `CO-14_20261016_041349.out` / artifact `..._IoTConsensusV2_20261016_063147` | **FAIL 643s fail=2** | 第 1 轮 `settle 0→2，TsFile 10→8`；第 5 轮 `settle 2→4，TsFile 18→**16**`（WARN 16→16）；`TTL=INF 后 count=0` PASS；一致性：`停 .79 后经 .77 / .78 查询` 得 600 行 vs 基准 `[EMPTY]` ⇒ **2 条 FAIL** |

**运行 4 的关键日志（逐节点计数，来自 artifact 的 `logs/192.168.99.*.logs/logs/log_datanode_all.log`）**

| 节点 | `[TTL] cottltb-*` 行数 | 其中非零候选 | `Async close tsfile: ...cottltb` | `SettleCompaction task starts` | `delete file ...cottltb` |
| --- | --- | --- | --- | --- | --- |
| .77 | 272 | **0** | **0** | **0** | 0 |
| .78 | 272 | 2 | 4 | 2（06:34:42,605 / 06:36:52,673，均 `cottltb-3 ... 1 fully_dirty`） | 4 |
| .79 | 268 | 2 | 4 | 2（06:34:37,586 / 06:36:47,672，均 `cottltb-6 ... 1 fully_dirty`） | 4 |

对照 **运行 1（RC6 V1）**：`6/6/6`、`2/2/2`、`2/2/2` —— **三副本完全对称**。这两组数字是「RC7 V2 的差异从哪来」的核心：
**V2 下 .77 全程一个 TsFile 都没关闭**（用例自己的 WARN 也证实：`过期批次未全部落盘` / `新鲜批次未全部落盘`）。

```
（.out，运行 4）
[06:34:30] WARN cottltb 过期批次未全部落盘              ← ensure_closed 3 轮 flush 后仍失败
[06:34:34]   设 TTL 前：count=1800（期望 1800）TsFile=10 settle=0
[06:34:52] PASS 表 TTL 触发的 settle 已动作：settle +2，TsFile 10 → 8
[06:36:39] WARN cottltb 新鲜批次未全部落盘
[06:36:44]   新写 2 批后：count=3600 TsFile=18 finishes=4→8      ← 在线合并确实推进
[06:37:08] PASS 合并产物同样被 TTL 过滤: = 0
[06:37:13]     等二轮 settle：settle=2 → 4；TsFile=16 → 16      ← 注意：基线 TS3 此刻已是 16
[06:40:13] WARN 第二轮窗口内 TsFile 数未下降（16 → 16），以第 6 步为准
[06:40:20] PASS TTL=INF 后无残留（过期数据已物理删除，合并未复活）: = 0
[06:40:44]   基准(经 192.168.99.77): [EMPTY]
[06:41:08] FAIL 停 192.168.99.79 后经 192.168.99.77 查询与基准不一致: [| 3| | 4| ... |303|] vs [EMPTY]
[06:41:12] FAIL 停 192.168.99.79 后经 192.168.99.78 查询与基准不一致: [同上] vs [EMPTY]
```

* 两次 settle 的**真实时刻**：`06:36:47,672`（.79，cottltb-6）与 `06:36:52,673`（.78，cottltb-3）；
  而第 5 轮的 TsFile 基线 `TS3=16` 是 **06:37:13** 才采到的（`:117` 在 `flush; sleep 20` 之后）⇒
  **18→16 的下降发生在基线之前**，用例的 `cur_ts < TS3` 判据**从一开始就不可能成立**（且它连 `settle 2→4` 的增长都没看）。
  这与运行 2/3 的 WARN「0 → 0」是同一类问题（RC6 上就存在，**不是 RC7 新现象**）。
* 「停 .79 后经 .77 / .78 查询」「基准 [EMPTY]」这两点合起来说明：**数据只在一个副本上"消失"**（.79 的 replica 已被 settle 物理删除），
  另外两个副本还有；`.79` 在线时查询命中的是它（结果 EMPTY），`.79` 停下后查询落到还有数据的副本（600 行）。

### 2.3 三个问题的回答

**①「第二轮 TsFile 未下降（16 → 16）」是 TTL 没触发清理，还是产品不清理？**
都不是 —— **是基线取晚了**：两次真实 settle 在 `06:36:47/06:36:52` 完成（`TsFile 18→16`），
而用例在 `06:37:13` 才采基线 `TS3=16`（`co_ttl_table_settle.sh:112-117`）。判据只看 TsFile 且只 warn（`:121,125`）。
TTL 选择器一直在工作（`[TTL] cottltb-* Totally select ...` 共 812 行），只是**在其它副本上没有候选**（见 ②）。
⇒ 归 **(c) 用例窗口**（叠加 (b)：V2 下 .77 未落盘）。

**②「停一个 DN 后查询与基准不一致」是真副本不一致，还是清理进度差异的时序假象？**
**是副本物理状态差异，但它是"逐副本各自清理 + 落盘不齐"的直接结果，而不是共识层丢数据**，依据：

* 一致性检查的实现（`common.sh:563-585`）以 `DN[0]=.77` 为基准，**逐个停 1 个 DN**、经其余节点重查 —— 它检验的是
  「同一条 SQL 在不同副本/不同时刻是否同解」，而 `ALTER TABLE … ttl='INF'`（`:128`）把**已经被合法清理掉的过期数据重新变成"可见"**。
  一旦各副本清理进度不同，这个断言必然可被触发。
* 逐节点计数（§2.2 表）：`.77` 一个 TsFile 都没关闭 ⇒ 它的 TsFileManager 里没有 `NORMAL` 文件 ⇒
  `SettleSelectorImpl.selectTasks()` 的 `resource.getStatus() != NORMAL → NOT_SATISFIED`（`SettleSelectorImpl.java:172-174`）
  使 `.77` **永远选不出候选**（`Totally select 0 all-outdated ... 0 partial-outdated` 136 次）
  ⇒ `.77` 上什么都没删；而 `.78/.79` 各删了 2 个文件（第 1、2 轮各 1 个/节点）。
  `delete file` 之后数据就真的不在那个副本上了（`SettleCompactionTask.java:112-167`，`settleWithFullyDirtyFiles()` 是**本地文件操作**，不经共识）。
* 所以「不一致」的内容是**已经被 TTL 判死、只是被测试脚本回滚成 'INF' 的过期数据**；不是"已提交数据丢失"。
  **但**「同一时刻、不同副本对同一条 SQL 给不同结果」这件事本身值得让研发确认（见 §2.6 的判定实验）。

**③ 与 RC6 同用例 artifact 对比，行为是否变化？**
RC6 的 V1 对照（运行 1）三副本 `Async close=6/6/6`、`settle=2/2/2`、非零候选 `2/2/2`，**对称**；
RC7 V1（运行 3）第 1 轮直接把 6 个文件清到 0、第 6 步 `count=0`、一致性 6/6 PASS，**与 RC6 的 PASS 行为一致**（同为 PASS）。
差异只出现在 **RC7 的 V2 运行**：`.77` 全程 0 个 close。而「V2 下三副本落盘不齐」在 RC7 V2 整套件里是**普遍现象**
（同一 artifact 批次里 CO-05/06/07/08/09/10/12/13 的 message 都带 `有 DN 的 TsFile 未落盘`/`未全部落盘`），
本环境已知「`flush;` 不保证三副本同时 `Async close`」。**没有 RC6 的 V2 对照 artifact**（RC6 那两份都是 V1），
所以「V2 落盘不对称是否 RC7 新引入」目前**没有对照数据**，列入 §2.6 的复跑项。

### 2.4 源码出处（判定所依赖的实现事实）

1. **TTL 清理的选择门控**（树/表共用同一个选择器，无 `TableSettleSelector`）：
   `.../compaction/selector/impl/SettleSelectorImpl.java`
   * `:165-211` `selectTasks()`；`:172-174`
     ```java
     if (resource.getStatus() != TsFileResourceStatus.NORMAL
         || !resource.getTsFileRepairStatus().isNormalCompactionCandidate()) {
       fileDirtyInfo = new FileDirtyInfo(NOT_SATISFIED);   // 未 close 的文件直接跳过
     }
     ```
   * `:244-320` `selectFileBaseOnDirtyData()`：
     - `:262-274` 表模型走 `DataNodeTTLCache.getInstance().getTTLForTable(storageGroupName, tableName)`（**DN 本地缓存**），
       树模型走 `getTTLForTree(device)`；
     - `:276-286`
       ```java
       if (hasSetTTL) {
         if (!isDeleted) {
           // For devices with TTL set, all data must expire in order to meet the conditions
           return new FileDirtyInfo(DirtyStatus.NOT_SATISFIED, ttlTables);   // 文件里有一个没过期的 TTL 设备 ⇒ 整文件不可选
         }
         ...
       long ttlThreshold = ttl <= Long.MAX_VALUE / 3 ? 3 * ttl : Long.MAX_VALUE;   // :294（TDB-452 修复后的形态）
       ```
     - `:306-311` `deletedDeviceRatio == 1d ⇒ FULLY_DIRTY`；`:312-318` 部分过期门槛
       （`max_expired_time == Long.MAX_VALUE` 时 `hasExpiredTooLong` 被强制置 false，只剩 `deletedDeviceRatio >= expired_data_ratio`）。
     ⇒ **对表模型（整表挂 TTL）而言，一个 TsFile 要么"整个文件所有 TTL 设备都过期"（FULLY_DIRTY），要么 NOT_SATISFIED；
       这使"能否清理"完全取决于**该副本自己的文件里装了哪些设备**，而文件组合是逐副本各自合并出来的。
2. **选择范围 = 本副本本地文件，无跨副本协调**：
   `.../compaction/schedule/CompactionScheduler.java:371-416`
   ```java
   SettleSelectorImpl settleSelector = new SettleSelectorImpl(heavySelect, logicalStorageGroupName, dataRegionId, timePartition, tsFileManager, context);
   if (config.isEnableSeqSpaceCompaction())   { taskList.addAll(settleSelector.selectSettleTask(tsFileManager.getTsFileListSnapshot(timePartition, true))); }
   if (config.isEnableUnseqSpaceCompaction()) { taskList.addAll(settleSelector.selectSettleTask(tsFileManager.getTsFileListSnapshot(timePartition, false))); }
   ```
   `tsFileManager` 是**本 DataRegion（本副本）**的；`:377` 是「seq/unseq 合并都关 ⇒ 不做 TTL 清理」的门控。
3. **TTL 检查按副本独立调度**：`DataRegion.java:4285-4336 executeTTLCheck()`
   （`:4309-4311` 调 `tryToSubmitSettleCompactionTask(..., true)` ⇒ `heavySelect=true`，即用 TTL 脏数据选择器；
   `:4295` / `:4320` 就是日志里的 `Start ttl and modification checking` / `Totally select N all-outdated files and M partial-outdated files`
   —— 与日志行号一致）；
   调度入口 `.../compaction/schedule/TTLScheduleTask.java:56-73`：每 `ttlCheckInterval`（本用例 5s）遍历**本节点**的 DataRegion 列表逐个 `executeTTLCheck()`，
   **没有任何跨副本同步/共识参与**。
4. **清理动作是本地文件删除**：`.../compaction/execute/task/SettleCompactionTask.java:112-167`
   （`:129-140` 即日志 `SettleCompaction task starts with N fully_dirty files and M partially_dirty files`；
   `:161 settleWithFullyDirtyFiles()` → `:166 settleWithPartiallyDirtyFiles()`）。
5. **落盘/close 是 settle 参与的前提**：`DataRegion.java:2395-2419`（`asyncClose()` + `:2410 Async close tsfile: ...`）；
   `TsFileResource.java:159`（`UNCLOSED` 初值）/`:1055-1099`（close 后 `NORMAL`）。
6. **TTL 检查会被整段跳过**：`DataRegion.java:4367-4408 skipCurrentTTLAndModificationCheck()`
   —— 表模型路径去 ConfigNode `showTables` 拿 TTL，全为 `INF` 就跳过（**此时不会有 `[TTL]` 日志**）。
   运行 4 在第 6 步是 'INF' 之后仍能看到 `[TTL] ... Start ttl and modification checking`，
   说明该副本走的是"有 mods 文件 / 本地缓存仍有 TTL"的分支，即**各副本看到的 TTL 生效状态并不必然一致**（值得研发确认的点）。
7. **一致性检查的口径**（用例侧）：`lib/common.sh:563-585`（基准取 `DN[0]`，逐个停 DN 比对）；
   `lib/common.sh:70`（`fail_flag` 是计数器 `fail_flag=$((fail_flag+1))`，故 `fail_flag=2` ⇒ 恰好 2 条 FAIL，即上面两条一致性 FAIL）。

### 2.5 判定

**CO-14 V2（RC7）= (b) 环境/时序 为主 + (c) 用例构造（断言不成立）**；`(a)` **不成立**：

* 「第二轮 16→16」：**基线晚于真实清理**（(c)，`co_ttl_table_settle.sh:112-117` + `:121`）——RC6 上同样存在（WARN「0→0」），**非 RC7 新现象**。
* 「停 .79 后不一致」：**逐副本清理进度不同导致的副本物理状态差异**（(b)：V2 下 `.77` 全程 0 个 close ⇒ TTL 选择器按
  `SettleSelectorImpl.java:172-174` 永远选不出候选；`.78/.79` 各清了 2 个文件），
  而这条断言本身依赖「把 TTL 从 30s 回滚到 'INF'」（`:127-133`）——**回滚已过期数据的 TTL 后要求三副本同解，是构造性不成立**（(c)）。
  数据面没有丢已提交数据：第 4 轮的 `count=3600`、指纹、`sum=550800` 都 PASS，sync lag 归零，日志无异常。
* **不建议提单**。作为**观察项**（不判缺陷）交研发确认一次：「TTL 过期数据的物理清理是逐副本、异步、无共识参与的，
  因此在 TTL 被改回大值/'INF' 时，同一查询在不同副本上可能给不同结果」（依据即 §2.4 的 2/3/4 三条）。

### 2.6 最小定向复跑方案（**不要现在执行**；其中第 2 步涉及改用例，需你确认）

目的：分清「(b)(c) 假象」与「真的副本可见性不一致（若是，则升为 (a)/(d) 提单）」。

```bash
# ① 复现现状（约 11 分钟）：V2 再跑一次，确认 .77 是否仍然 0 个 close
cd /data/iotdb/autotest/compaction_skill
V_TESTDB=v20121rc7_1014_7c61428 BUILD_TAG=v20121rc7_1014_7c61428 CO_DEVS=6 CO_ROWS=300 \
bash cases/table/co_ttl_table_settle.sh --consensus IoTConsensusV2

# ② RC6 V2 对照（是否有 RC6 的 V2 数据）：同一脚本换版本
V_TESTDB=v20121rc6_1010_7ae8713e BUILD_TAG=v20121rc6_1010_7ae8713e CO_DEVS=6 CO_ROWS=300 \
bash cases/table/co_ttl_table_settle.sh --consensus IoTConsensusV2
```

用例侧需要补的 3 个证据/判据（建议改动，最小化）：

1. **每相都采"逐副本 × TsFile 清单 + close 计数"**（`find $DB_DIR/data/datanode/data -path '*/cottltb/*' -name '*.tsfile'`、
   `grep -c 'Async close tsfile: .*cottltb'`），并把它写进 artifact —— 当前 artifact 里没有清单，无法复原文件构成。
2. **改判据**：
   * 第 5 轮基线 `TS3` 改为**在 `alter table ... ttl=30000` 之前**采（或在 `flush; sleep 20` 之前采并同时记录 `settle` 基线），
     判据改成与第 1 轮一致的「`settle` 增加 **或** TsFile 下降」（`:82` 的写法），不要只看 TsFile；
   * 第 6 步在断言 `count=0` 之前，**先等所有在线副本的 close 计数与 TsFile 计数收敛**（用 `ensure_closed` + 逐副本计数相等），
     否则把该断言降级为 WARN 并记录各副本的 count/TsFile 明细。
3. **一致性检查加"同一时刻、全在线、逐副本对比"一步**（现在只有"停 1 个 DN"这一种）：
   在全在线时分别用 `sqt_node .77/.78/.79` 查同一条 SQL 并逐副本比对（`cmp_fingerprint_on`），
   并且比较 **TTL=30s（清理完成）** 与 **TTL='INF'（回滚后）** 两个时刻的结果。

判据（预期与分流规则）：

* 若「全在线、逐副本」在**两个时刻都一致**，且 `.79` 单独停机时的不一致消失 ⇒ 结论锁定 **(b)+(c)**，用例按上面改，**不提单**。
* 若「全在线、三副本同一时刻查询」就出现不同结果（例如 TTL='INF' 时 `.79` 空、`.77/.78` 有 600 行）⇒ 说明
  **副本可见性依赖"哪个副本物理删过数据"**，属需要研发确认的一致性问题 ⇒ 升级为 **(d)/(a)**（带 artifact + 逐副本清单提单前先与研发确认语义）。
* 若 RC6 的 V2 对照里 `.77` 也能正常 close、而 RC7 V2 稳定 0 个 close ⇒ 「V2 下某副本不落盘」值得单独作为**环境/性能回归**记录（(b)→需研发看）。

---

## 3. 证据文件清单（本文件引用的原始证据）

| 类别 | 路径（99.80 `/data/iotdb/autotest/compaction_skill/results/`） |
| --- | --- |
| CO-11 输出 | `CO-11_20261012_161428.out`（RC6 PASS）、`CO-11_20261015_201417.out`（RC7 V1 FAIL 1698s）、`CO-11_20261016_004107.out`（RC7 V1 PASS 820s）、`CO-11_20261016_041349.out`（RC7 V2 FAIL 1710s） |
| CO-11 日志 | `artifact_co_perf_baseline_IoTConsensus_20261015_213535/logs/192.168.99.{77,78,79}.logs/logs/log_datanode_compaction.log`、`artifact_co_perf_baseline_IoTConsensusV2_20261016_054152/logs/...`（`artifact_..._20261016_004107/logs/` 为空 = PASS 不备份） |
| CO-14 输出 | `CO-14_20261012_165832.out`（RC6 FAIL）、`CO-14_20261012_185017.out`（RC6 PASS）、`CO-14_20261015_201417.out`（**RC7 V1 PASS 577s**）、`CO-14_20261016_041349.out`（**RC7 V2 FAIL 643s**） |
| CO-14 日志 | `artifact_co_ttl_table_settle_IoTConsensus_20261012_171035/logs/...`（RC6 对称对照）、`artifact_co_ttl_table_settle_IoTConsensusV2_20261016_063147/logs/...`（RC7 V2） |
| 汇总 | `results/perf_baseline.csv`（RC6 与 RC7 逐行）、`test_result_rc7_v1_archived_20261016_041349.csv`、`test_result.csv` |
| 未取得 | artifact 内**无 jstack**；**无逐副本/逐空间 TsFile 清单**（用例只记合计）⇒ 凡「32 个文件的构成」类结论均标为不可复原 |

> 本机副本位于 `%TEMP%\co11co14\`（解包后的日志与下载的 `.out`），未写入工作区；工作区内**只新增**
> `compaction_skill/docs/CO11_CO14_TRIAGE.md` 这一个文件。
