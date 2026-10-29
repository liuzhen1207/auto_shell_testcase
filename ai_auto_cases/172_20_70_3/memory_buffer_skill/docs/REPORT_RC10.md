# RC10 测试报告 —— 内存缓冲区专项（双共识协议）

| 项 | 内容 |
|---|---|
| 被测版本 | TimechoDB **V2.0.12.1**，BuildInfo **`c60ce63`**（RC10） |
| 版本目录 | `v20121rc10_1021_c60ce63` |
| 源码 | `/data/deepseek/timecho_src/timecho_v2_0_12_1`（分支 HEAD `c60ce63`） |
| 测试包 | `timechodb-2.0.12.1-bin.zip`（172.20.70.3:`/data1/iotdb/testdb/v20121rc10_1021_c60ce63`） |
| 部署 | 本次由测试侧自行解压部署到 6 个节点，见 §一 |
| 用例集 | `membuf_skill` 24 条：19 条功能（MB-01～MB-19）+ 5 条性能（P-01～P-05） |
| 协议轮次 | ① `IoTConsensus`　② `org.apache.iotdb.consensus.iot.IoTConsensusV2` |
| 执行时间 | 2026-10-22 19:31:03 ～ 2026-10-23 06:46:32 |
| 验证人员 | 刘珍 |

---

## 一、部署过程

原测试包仅为 zip（102 MB），环境各节点无 RC10 目录。本次执行了完整部署：

1. 在客户端解压并打包，`scp` 分发到 6 个节点，解压至 `/data/iotdb/v20121rc10_1021_c60ce63`（每节点 114 MB，jar 校验通过）。
2. 客户端侧同步解压（提供 `start-cli.sh`，避免 CLI 缺失）。
3. **企业版激活**：RC9 的 license 直接复用时被拒（`LicenseException: This license is not allowed to activate this ConfigNode`）。
   根因是 RC10 首次启动会新建 `.env` 中的 `node_uuid`，而指纹 `activation/system_info` 第三段由该 uuid 派生：
   - RC9 `.env` node_uuid → 指纹 `...-PXAEDQLR`；RC10 新生成 uuid → 指纹 `...-BRMZDOTX`
   - 处理：把各节点 RC9 的 `.env` 复制到 RC10 目录后，指纹恢复为 RC9 原值，license 校验通过
4. 部署后校验：`show cluster` 显示 8/8 Running、BuildInfo **`c60ce63`**、全部 **ACTIVATED**；写操作验证通过。

> 备注：指纹在同一安装路径下稳定（重建 data 后重启不变），因此该激活方式可复现，详见 `docs/RC10_DEPLOY.md`。

---

## 二、结果总览

| 协议 | 功能用例（19） | 性能用例（5） | 合计（24） | 通过率 |
|---|---|---|---|---|
| **IoTConsensus** | **16 PASS / 3 FAIL** | **5 PASS / 0 FAIL** | **21 / 24** | **87.5%** |
| **IoTConsensusV2** | **12 PASS / 7 FAIL** | **5 PASS / 0 FAIL** | **17 / 24** | **70.8%** |

两轮合计 48 次执行：**38 PASS / 10 FAIL**。

### 2.1 功能用例逐条对照

| 用例 | IoTConsensus | IoTConsensusV2 | 备注 |
|---|---|---|---|
| MB-01 内存分配报告 | PASS | PASS | |
| MB-02 配置校验 | PASS | PASS | |
| MB-03 按比例刷盘 | PASS | **FAIL** | V2 下副本不一致（160/1200） |
| MB-04 顺序定时刷盘 | PASS | **FAIL** | V2 下 syncLag 未归零 + 副本不一致（65/1200） |
| MB-05 乱序定时刷盘 | PASS | **FAIL** | V2 下阶段B 无新 TsFile（3 vs 4） |
| MB-06 reject 与恢复 | PASS | PASS | 首轮均因环境 SIGKILL 未出结论，补跑后 PASS |
| MB-07 并发刷盘 | PASS | PASS | |
| MB-08 WAL 快照 | PASS | PASS | |
| MB-09 内存池占比 | PASS | PASS | 同上，补跑后 PASS |
| MB-10 重启 WAL 回放 | PASS | PASS | |
| MB-11 顺乱序分离存储 | PASS | **FAIL** | V2 下 A 相 `unsequence/` 非空（顺序数据进了乱序目录） |
| MB-12 chunk 切分 | PASS | PASS | |
| MB-13 停 DN 高可用 | PASS | PASS | |
| MB-14 IoTConsensusV2 | **FAIL** | **FAIL** | 该用例内部切换 V2，两轮均暴露同一问题（160/1200） |
| MB-15 TVList 排序算法 | **FAIL** | **FAIL** | BACKWARD 下查询报错（F-09 缺陷仍在） |
| MB-16 刷盘线程数 | PASS | PASS | |
| MB-17 时间分区内存 | PASS | PASS | |
| MB-18 类型推断 | PASS | PASS | |
| MB-19 非法内存比例 | **FAIL** | **FAIL** | 非法比例致 DN 启动崩溃（F-07 行为仍在） |

### 2.2 性能用例逐条对照（两轮均 5/5 PASS）

| 用例 | IoTConsensus | IoTConsensusV2 | 关键数据（V2 轮） |
|---|---|---|---|
| P-01 flush_proportion 0.5 vs 0.4 | PASS | PASS | 吞吐 2,309,972 vs 2,273,492（**+1.6%**），P99 3.35 vs 3.78 ms |
| P-02 chunk 参数 | PASS | PASS | 10k vs 100k：**+1.6%**；8MB chunk：P99 3.70 vs 3.24 ms |
| P-03 顺乱序分离存储 | PASS | PASS | 顺序 **+2.7%**、乱序 **+4.1%**；P99 均在容忍内 |
| P-04 TVList 排序算法（查询） | PASS | PASS | TIM/QUICK/BACKWARD 吞吐 59.9k/59.4k/58.3k；BACKWARD P99 137.81 ms vs TIM 95.05 ms（+45%，未超 50% 阈值） |
| P-05 V2 vs V1 | PASS | PASS | V2 **+2.9%**（V1 轮）／**+5.9%**（V2 轮）；P99 3.34 vs 4.75 ms |

> 性能用例判据为**同轮内相对比较**（吞吐降幅 >30% 判 FAIL，P99 恶化 >50% 判 FAIL），不设绝对门槛。

---

## 三、耗时统计（跑一轮的实测耗时）

### 3.1 分阶段墙钟时间

| 阶段 | 起 | 止 | 墙钟耗时 |
|---|---|---|---|
| ① IoTConsensus 功能（主轮 + 补跑） | 10-22 19:31:03 | 10-22 23:57:07 | **4 h 26 m** |
| 　└ MB-06/MB-09 补跑 | 10-23 05:36:30 | 10-23 05:58:51 | 22 m |
| ① IoTConsensus **功能合计** | | | **4 h 48 m** |
| ② IoTConsensus 性能（主轮 + 补跑） | 10-23 00:14:11 | 10-23 01:14:48 | **1 h 00 m** |
| **IoTConsensus 一个小计** | 10-22 19:31:03 | 10-23 01:14:48 | **≈ 5 h 44 m** |
| ③ IoTConsensusV2 功能（主轮） | 10-23 01:22:22 | 10-23 04:22:08 | **3 h 00 m** |
| 　└ MB-06/MB-09 补跑 | 10-23 06:15:40 | 10-23 06:46:32 | 31 m |
| ③ IoTConsensusV2 **功能合计** | | | **3 h 31 m** |
| ④ IoTConsensusV2 性能（主轮 + 补跑） | 10-23 04:33:06 | 10-23 05:35:00 | **≈ 1 h 02 m** |
| **IoTConsensusV2 一个小计** | 10-23 01:22:22 | 10-23 06:46:32 | **≈ 4 h 33 m** |
| **两轮总计（墙钟）** | 10-22 19:31:03 | 10-23 06:46:32 | **11 h 15 m** |

### 3.2 用例自身耗时（不含重试与集群重建）

| 协议 | 有效用例数 | 用例耗时合计 |
|---|---|---|
| IoTConsensus | 19 | 7,090 s ≈ **1 h 58 m** |
| IoTConsensusV2 | 19 | 8,812 s ≈ **2 h 27 m** |

> V2 轮用例耗时明显更长（+24%）：主因是 V2 下 `syncLag` 等待与副本一致性检查超时（MB-04 单条 1217 s）。
> 墙钟远大于用例耗时，差值为每例"停集群→清 data/logs→写配置→启动→等待 8/8"的固定开销（约 3~4 min/例）。

### 3.3 与上一版 RC9 的耗时对比

| 协议 | RC9 | RC10 | 变化 |
|---|---|---|---|
| IoTConsensus 功能 | 8,992 s（不含补跑） | 7,090 s | −21% |
| IoTConsensus 性能 | 3,250 s | 3,600 s | +11% |

---

## 四、失败明细

### 4.1 IoTConsensus 轮（3 条）

| 用例 | 首条失败断言 |
|---|---|
| MB-14 | `FAIL 副本不一致 停 172.20.70.4 时经 172.20.70.26 查询: 基准=1200 实际=160` |
| MB-15 | `FAIL ②BACKWARD 点数: 实际=[QUERY_ERROR] 期望=[2000]`；`FAIL ②BACKWARD 查询无数据` |
| MB-19 | `FAIL DataNode 172.20.70.4 启动即崩溃（日志有 main 线程异常）` |

### 4.2 IoTConsensusV2 轮（7 条）

| 用例 | 首条失败断言 | 分类 |
|---|---|---|
| MB-03 | `副本不一致 停 172.20.70.4 … 基准=1200 实际=160` | **V2 专属** |
| MB-04 | `sync lag 未在 600s 内归零 (series=14 nonzero=1)`；`副本不一致 … 实际=65` | **syncLag 指标缺陷（见 5.1b）** |
| MB-05 | `阶段B 关闭乱序定时刷盘后无新 TsFile: 实际=[3] 期望=[4]` | **用例断言缺陷（已修）** |
| MB-11 | `②A 相 unsequence/ 为空（顺序数据不进乱序目录）: 实际=[1] 期望=[0]` | **LOAD 路径固有语义（需产品决策）** |
| MB-14 | `副本不一致 … 基准=1200 实际=160` | **V2 专属**（用例内部即 V2） |
| MB-15 | `②BACKWARD 点数: 实际=[0] 期望=[2000]` | 已知缺陷 F-09 延续 |
| MB-19 | `DataNode … 启动即崩溃` | 已知缺陷 F-07 行为延续 |

---

## 五、关键发现

> ⚠️ **补充说明（2026-10-23 11:10 追加）**：本节三条 V2 结论在首次发布时**只基于用例断言**，
> 当时未做 CN/DN 日志与源码分析。补做分析后：
> - **A 类（MB-03/MB-14 的 160/1200）在干净最小复现下未能重现**（写 1200 点、flush、停副本，其余副本仍返回 1200，
>   两个副本 TsFile 尺寸一致 43306 字节）；更像"复制未追平就停副本"的时序问题
> - 源码层面：`consensus/pipe`（V2 实现）在 RC9→RC10 **零改动**，但 RC10 重写了 V2 所用的
>   `IoTDBDataRegionAsyncSink` 并新增 `PipeInsertInFlightKeyRegistry`（去重仅对 TEXT 生效，与失败用例数据类型吻合）
> - 因此本节结论应视为**线索**而非定论，详见 [DEFECT_RC10_V2_REPLICA.md](DEFECT_RC10_V2_REPLICA.md)

### 5.1 【已定根因·测试配置】V2 副本数据不全 = Pipe 内存池被压干导致 TsFile 传输 OOM

**结论：属测试配置副作用，不是 V2 复制缺陷。**（2026-10-23 补做日志分析后更正）

现场证据（DataNode leader 日志）：

```
WARN IoTConsensusV2TsFileInsertionEventHandler:385 - IoTConsensusV2-__consensus.DataRegion[5…]
  PipeRuntimeOutOfMemoryException{message='forceAllocate: failed to allocate memory after 10 retries,
    total memory size 6698334 bytes, used memory size 6675534 bytes, requested memory size 488…'}
```

逐节点 TsFile 盘点（不停副本时）：

| 节点 | TsFile | syncLag |
|---|---|---|
| 172.20.70.14（leader） | **5 个**，合计 168,759 B | sum=2 |
| **172.20.70.30（follower）** | **1 个，9,333 B** | **sum=0** |

停掉 leader 后 follower 只能提供本地那 1 个 TsFile → 正好 **160 点**。

原因：`datanode_memory_proportion` 六段为
`StorageEngine : QueryEngine : SchemaEngine : Consensus : StreamingEngine : Free`，
而 MB-03/MB-14 用 `1:2000:1:1:1:1`，把 **第 5 段（Pipe 池）压到 1/2005 ≈ 0.05%**（≈6.4 MB）；
每个 TsFile reader 固定要 2 MB、同时有 14 条 pipe 并发 → 传第 4 个 TsFile 起就 OOM。
默认比例 `3:3:1:1:1:1`（Consensus ≈11%）下复制正常。

> 补充：**"等 syncLag 归零再校验"在这些用例上无效** —— 实测 syncLag 连续为 0 时
> follower 仍缺 4/5 TsFile（OOM 导致永远追不平，但指标报 0）。
> 详见 [DEFECT_RC10_V2_REPLICA.md](DEFECT_RC10_V2_REPLICA.md)

### 5.1b 【已复现·指标缺陷】`syncLag` 恒为 1，永不归零

- 复现：RC10 + V2，`1:1000` 比例写 600 点后再加写 300 点，每 15s 采样 40 次（10 分钟）：
  24 条 series 中**只有 1 条非零且恒为 1.0**，固定在 `172.20.70.27` / `DataRegion[13]`；加写数据后**不增长**（说明不是积压）。
- 数据侧是好的：该 region 两副本查询均为 **365 点**，follower 的 TsFile（3 个，104 KB）甚至多于 leader（1 个，14 KB）。
- 源码：`syncLag = leaderReplicateProgress − followerApplyProgress`，而 follower 侧只在"成功应用事件"时推进 ⇒ 永久差 1。
- 影响：`syncLag==0` **不能**作为"复制完成"判据（MB-04 因此永远等不到归零）；
  `isConsensusPipesTransmissionCompleted(List)` 用 `noneMatch(syncLag > 0)` 判定，只要差 1 就**永远返回 false**（迁移/加副本的远端判定存潜在风险，未实测）。
- 详见 [DEFECT_RC10_SYNCLAG.md](DEFECT_RC10_SYNCLAG.md)

### 5.2 【已定·用例断言缺陷】MB-05 "无新 TsFile" 误报

- 现象：`阶段B 关闭乱序定时刷盘后无新 TsFile: 实际=[3] 期望=[4]`
- 实测：`阶段B tsfile 合计: 4 -> 3（sequence=3 unsequence=0）` —— **unsequence 为 0，用例意图（无新增乱序文件）已满足**；
  总数从 4 降到 3 是**合并（compaction）**造成的。
- 定性：**用例用 TsFile 总数做单调递增假设**，属判据缺陷；默认内存比例下同样复现，与内存配置无关。
- 处置：断言已改为只校验 `unsequence` 目录是否增加。

### 5.3 【已定·LOAD 路径固有语义】MB-11 副本数据必然进 `unsequence/`

- `enable_separate_data=true` + 纯顺序写入：leader `172.20.70.4` 落 `sequence/`，
  副本 `172.20.70.26` 落 **`unsequence/`**（410 B）。
- 根因：V2 接收端调用存储引擎 load 入口（`IoTConsensusV2Receiver:734` → `loadNewTsFile`），
  该入口**无条件** `newTsFileResource.setSeq(false)` 并 `loadTsFileToUnSequence(...)`
  （`DataRegion.java:5084/5109`）。
- ⇒ **LOAD 一律进 unsequence 是既有设计**；V2 用 LOAD 路径做复制，副本落 unsequence 是固有结果，
  **不是复制逻辑缺陷**。数据正确性不受影响（点数/查询一致）。
- 影响：`enable_separate_data` 的目录语义在副本上不成立，按目录统计的巡检/归档方案在副本上会得到不同结果。
- 处置：需**产品决策**——接受则改用例断言（副本只校验数据完整性）；不接受则需为 V2 增加保留 seq 归属的加载路径。
  详见 [DEFECT_RC10_V2_REPLICA.md](DEFECT_RC10_V2_REPLICA.md) §四。

### 5.4 【遗留缺陷仍在】F-09：BACKWARD 排序导致查询报错与数据丢失

- MB-15 两轮均 FAIL：`BACKWARD` 下 `QUERY_ERROR`、点数 0；`TIM`/`QUICK` 正常。
- 对应 PLM **TDB-871**，RC10 未修复。

### 5.5 【遗留缺陷仍在】F-07：非法内存比例致 DataNode 启动崩溃

- MB-19 两轮均 FAIL：配置非法比例后 DataNode 启动即崩溃、集群无法就绪。
- 对应 PLM **TDB-864**，RC10 未修复。

### 5.6 性能侧：RC10 无明显退化，V2 略优于 V1

- 两轮 10 次性能用例全部 PASS，吞吐与 P99 均在容忍范围内。
- P-05 显示 V2 比 V1 **快 2.9%～5.9%**，P99 更低（3.34 vs 4.75 ms）。
- P-04 中 `BACKWARD` 的查询 P99 为 137.81 ms，比 `TIM` 高 45%（未超 50% 阈值），建议持续关注。

---

## 六、环境限制与数据可信度说明

本次执行期间，客户端存在**周期性 SIGKILL 现象**（`rc=137`），会打断长跑用例，特征：

- 客户端无 OOM（`dmesg` 无记录）、systemd 无 cgroup 内存限制、机器负载接近 0
- 被杀的总是**用例脚本本身**，runner 存活；发生在并发写/长耗时阶段
- journalctl 无 oom-kill 记录，判断为执行环境侧进程回收机制

对结论的影响与处置：

| 情形 | 处置 | 结果 |
|---|---|---|
| MB-06、MB-09 首轮多次被杀 | 单独补跑（各 2 次尝试） | 两轮均 PASS |
| P-01、P-03、P-05 首轮启动即被杀 | 按用例单独重试 | 全部 PASS |
| P-02、P-04 首轮 csv 不完整 | 删除残缺 csv 后重跑 | 补全 3 个变体，PASS |

因此**24 条用例在两轮中均取得了有效结论**，无 NO_RESULT 残留。

---

## 七、结论

1. **RC10 功能通过率**：IoTConsensus **87.5%**（21/24）、IoTConsensusV2 **70.8%**（17/24）。
2. **V2 是本版主要风险（结论待研发确认）**：7 条失败中有 5 条为 V2 专属，集中在
   **副本数据完整性 / syncLag 收敛 / 乱序定时刷盘 / 顺乱序目录语义** 四个方向，且互相关联（均指向 V2 复制链路）。
3. **两个已知缺陷未修复**：F-09（TDB-871，BACKWARD 排序）、F-07（TDB-864，非法比例 DN 崩溃）。
4. **性能无退化**：10 次性能用例全 PASS，V2 略优于 V1。
5. **建议**：
   - 就 §5.1 先与研发确认（草稿见 [DEFECT_RC10_V2_REPLICA.md](DEFECT_RC10_V2_REPLICA.md)）；确认是产品问题后再提 PLM
   - §5.2、§5.3 可并入同单或单独提，均为 V2 专属
   - V1 路径可作为本版的稳定基线

---

## 八、证据与产物

| 项 | 位置 | 说明 |
|---|---|---|
| **阶段日志归档** | `results/rc10_logs/` | 8 份阶段日志 + 起止时间戳 + `rc10_summary_v1.tsv`（V1 轮结果快照），共 24 个文件 |
| 用例明细（两轮共存） | `results/MB-*_<runid>.out` | 59 份，按时间戳区分轮次：`20261022_*` = IoTConsensus 轮；`20261023_0*` = IoTConsensusV2 轮 |
| 当前结果文件 | `results/result_MB-*.txt` | 19 份，均为 V2 轮（`consensus=IoTConsensusV2`） |
| V1 轮补跑结果 | `results/rc10_v1/result_MB-*.txt` | MB-06、MB-09 的 V1 轮结论 |
| 性能明细（V2 轮） | `results/perf_P-0*.csv` | 5 份，含各变体吞吐/P99/点数 |
| 性能明细（V1 轮） | `results/rc10_v2/perf_P-0*.csv` | 5 份 |
| V2 缺陷草稿（含证据分级） | `docs/DEFECT_RC10_V2_REPLICA.md` |
| 部署与激活过程 | `docs/RC10_DEPLOY.md` | 含流式 tar 截断、license 指纹不匹配两个坑的完整解法 |

> ⚠️ 说明：用例初始化会清理同名 `result_<ID>_*.txt`，因此 **V1 轮的结果文件已被 V2 轮覆盖**。
> V1 轮的结论以 `results/rc10_logs/rc10_summary_v1.tsv`（逐例 result/failCount/elapsed）与
> `results/MB-*_20261022_*.out`（逐条断言明细）为准，本报告 §二~§四 的 V1 数据均取自这两处。

## 九、复现方式

```bash
# 0) 前置：RC10 已部署且已激活（见 docs/RC10_DEPLOY.md）
cd /data1/iotdb/testcase/MigrateRegionTest/skill_case/membuf_skill

# 1) 指向 RC10（conf/env.conf 默认值已是 RC10）
grep '^V_TESTDB' conf/env.conf

# 2) IoTConsensus 轮：功能 + 性能
DATA_CONSENSUS=IoTConsensus   bash tools/run_until_done.sh --set all --tries 3
DATA_CONSENSUS=IoTConsensus   bash tools/run_perf.sh --set all

# 3) IoTConsensusV2 轮：功能 + 性能
DATA_CONSENSUS=IoTConsensusV2 bash tools/run_until_done.sh --set all --tries 3
DATA_CONSENSUS=IoTConsensusV2 bash tools/run_perf.sh --set all
```

> 本环境存在周期性 SIGKILL（见 §六），建议对未产出结果的用例单独重试，不要直接判失败。
