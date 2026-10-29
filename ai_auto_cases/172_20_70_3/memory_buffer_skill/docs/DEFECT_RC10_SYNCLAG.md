> # ⚠️ 本文件已大幅降级（不作为独立缺陷）
>
> **2026-10-26 复测结论**：把 `datanode_memory_proportion` 恢复为产品默认 `3:3:1:1:1:1`
> （Pipe 池由 6.4 MB 提升到约 1.4 GB）后，**MB-04 与 MB-08 在 V2 下均 PASS（fail_flag=0）**，
> `syncLag` 能够收敛到 0。
>
> 因此本文此前记录的"syncLag 恒为 1、永不归零"，**根因是用例把 Pipe 内存池配得过小**：
> TsFile 复制长期完不成 → 进度差固定为 1。**研发认定属配置问题，非指标缺陷**。
>
> 仍成立的部分（可作为观察项，不建议单独提单）：
> - `syncLag == 0` 不能单独作为"复制已完成"的判据（池子不足时会在复制未完成的情况下长期停在 1）；
> - 建议暴露 `leaderReplicateProgress` / `followerApplyProgress` 原始值，便于现场区分"真滞后"与"池子不足"。
>
> 请以 [REPORT_RC11.md](REPORT_RC11.md) 的结论为准。

# 缺陷报告：IoTConsensusV2 的 `syncLag` 恒为 1，永不归零（指标失真，非数据丢失）

| 项 | 内容 |
|---|---|
| 版本 | TimechoDB V2.0.12.1，BuildInfo **`c60ce63`**（RC10） |
| 环境 | 3C5D，`schemaRF=3`、`dataRF=2`；协议 `IoTConsensusV2`（`iot_consensus_v2_mode=batch`） |
| 配置 | `datanode_memory_proportion=1:1000:1:1:1:1`、`flush_proportion=0.5`、定时刷盘 15s |
| 现象来源 | 用例 MB-04 在 RC10 V2 轮报 `sync lag 未在 600s 内归零 (series=14 nonzero=1)` |
| 严重级别 | **P2**（不影响读写与数据一致性；但让"复制是否完成"的判定永久为否） |
| 日期 | 2026-10-23 |

---

## 一、复现结果：确实永不归零

在 RC10 + V2 上按 MB-04 的配置写 600 点（随后又加写 300 点），每 15 s 采样一次，连续 **40 次（10 分钟）**：

```
#1   series=24 nonzero=1  172.20.70.27[nodeId="6",region="DataRegion[13]"]=1.0
#10  series=24 nonzero=1  172.20.70.27[nodeId="6",region="DataRegion[13]"]=1.0
#20  series=24 nonzero=1  172.20.70.27[nodeId="6",region="DataRegion[13]"]=1.0
#30  series=24 nonzero=1  172.20.70.27[nodeId="6",region="DataRegion[13]"]=1.0
#40  series=24 nonzero=1  172.20.70.27[nodeId="6",region="DataRegion[13]"]=1.0
```

- 24 条 series 中**只有 1 条非零**，且**恒等于 1.0**，10 分钟内**一次都没变过**
- 位置固定：`172.20.70.27`（nodeId=6）、`region="DataRegion[13]"`

### 1.0 决定性的排除实验：完全不写入时它就已经是 1

为了区分"确实有 1 单位未同步的数据"与"进度指针固定差 1"，做了不写入的对照：

```
[16:13:55] === 基线（不进行任何写入）lag 合计=1 ===
[16:14:18] === 建库后 lag=1 ===
[16:14:19] 写入中 #1  lag=1      ← 开始批量写入
[16:14:29] 写入中 #6  lag=1
[16:14:53] 写入中 #17 lag=1
[16:15:02] 写入中 #21 lag=1      ← 期间共写入 2000 点
```

**结论：一行新数据都不写的时候，`syncLag` 就已经是 1；写 2000 点它仍然还是 1。**

如果它代表"未同步的数据量"，应当满足：

| 若语义为"待同步量" | 实测 |
|---|---|
| 空闲时应为 0 | ❌ 空闲时就是 1 |
| 批量写入期间应 > 1（或随写入增长） | ❌ 始终 1 |
| flush（把所有尾部数据 seal 成 TsFile）后应收敛到 0 | ❌ 仍然 1（另测 10 分钟 40 次采样恒为 1） |

⇒ **它不是"还有未落盘/未同步的数据"，而是两个进度指针的固定差 1。**

### 1.0b 追加实验：全新 region 写入后仍为 0（排除"首次写入 off-by-one"）

新建一个从未写入过的库（DataRegion[22]），**只写 1 个点**，每秒采样一次：

```
[16:28:28] 写入前基线  #1..#5        lag(r22)=0
[16:28:44] 写入 1 点后 +1s .. +25s   lag(r22)=0   ← 全程 25 次均为 0
[16:29:18] flush 后 +1s ..           lag(r22)=0
```

⇒ **"1"不是"首次写入就偏移"的普遍现象**，需要特定条件才会出现。

### 1.0c 出现"1"的分布规律

在同一集群里枚举全部非零 series 与副本角色，只找到 1 条：

```
node=172.20.70.27 (nodeId=6)  region=9  value=1.0     ← region 9 是 root.__system，该节点是其 Leader
```

而此前 MB-04 场景里卡住的是：

```
node=172.20.70.27 (nodeId=6)  region=13 value=1.0     ← region 13 是 root.mb04，该节点是其 Follower
```

两次的共同点：**都是节点 172.20.70.27**，但**region 不同**（9 / 13）、**角色也不同**（Leader / Follower）。

⇒ 更像**该节点上某条 pipe 的 connector 条目残留/未推进**（`consensusPipe2ConnectorMap` 里一条
"leaderReplicateProgress=1、followerApplyProgress=0"的记录），而不是某个 region 的数据问题。

### 1.0d 重启实验：结论不成立（受环境干扰）

**目的**：判断恒为 1 是"运行期残留状态"还是"持久化/必然重建"。

**过程**：

| 时间 | 操作 | 结果 |
|---|---|---|
| 17:53 | 重启 172.20.70.27 的 DN | 该节点 **无法重新注册**：`Reject DataNode registration … TEndPoint(172.20.70.27, 10730)` |
| 18:05 | 全停后保留 data 重启（8/8 Running） | 非零 `syncLag` **条数=0**；70.27 上 `syncLag` series 从 20+ 降到 **2 条** |
| 18:14 | 复核数据 | **用户库全部丢失**，`show databases` 仅剩 `root.__audit`、`root.__system` |

**为什么不能作为结论**：重启后用户库已不存在，等于"没有数据 → 没有对应 pipe/region"，
"非零为 0"很可能只是因为没有数据可比，而不是运行期状态被清除。
**该实验无法区分两种假设，判定为不成立。**

> **附带记录（已做对照，不构成缺陷）**
>
> | 关停方式 | 用户库 | 点数 |
> |---|---|---|
> | `pkill -9` 硬杀全部节点后重启 | **丢失**（只剩 `root.__audit`、`root.__system`） | 丢失 |
> | **官方脚本优雅停（先 DN 后 CN）后重启** | **保留** | **100 → 100 完好** |
>
> 优雅停/启的对照结果：
> ```
> [18:39:26] 停止前  库数=1  点数=100
> [18:40:13] 官方脚本 stop（先 DN 后 CN）
> [18:41:05] 重启完成 Running=8
> [18:41:16] 重启后  库数=1  点数=100   ← 完好
> ```
> ⇒ **正常运维路径（官方 stop/start）不丢数据**；此前的丢失出现在人工 `pkill -9` 同时杀掉全部
> ConfigNode 的异常路径下，且该路径尚存在其他干扰因素（未单独隔离验证），
> 因此**不作为缺陷记录**，仅提示：做破坏性实验时应使用官方关停脚本。

### 1.1 加写数据也不增长 —— 不是积压

| 动作 | `syncLag`(70.27 / region 13) | TsFile 总数 |
|---|---|---|
| 写 600 点后 | 1.0 | 3 |
| **再写 300 点后** +10s…+120s | **始终 1.0** | 5 |

如果它是"队列积压"，新增数据会让它变大；实测纹丝不动 ⇒ **它是一个固定的进度差，不是待同步量**。

---

## 二、现场：数据其实是完整且一致的

`DataRegion[13]` 就是 `root.mb04` 的数据区（seriesSlot=1）：

| 角色 | 节点 | TsFile 明细 | 本节点查询 |
|---|---|---|---|
| **Leader** | 172.20.70.26 (nodeId=4) | 1 个，14,080 B | **365** |
| **Follower** | **172.20.70.27 (nodeId=6)** | 3 个：38,616 + 32,865 + 32,865 = 104,346 B | **365** |
| 其他 3 个节点 | — | 无（非本 region 副本） | 365 |

- 两个副本**查询结果一致（365 点）**，follower 的 TsFile 甚至比 leader 还多；
- 该 region 有 2 条双向 pipe：`__consensus.DataRegion[13]_4_6`、`__consensus.DataRegion[13]_6_4`；
- **日志里没有** `PipeRuntimeOutOfMemoryException`，也没有 dedup / skip / timeout / ERROR。

⇒ **数据没丢、副本一致，失真的是 `syncLag` 这个指标本身。**

---

## 三、源码分析：为什么会恒为 1

### 3.1 指标定义

`iotdb-core/consensus/.../metric/IoTConsensusV2SyncLagManager.java:58-70`

```java
/** userWriteProgress - currentReplicateProgress. If res <= 0, indicating that replication is finished. */
public long getSyncLagForSpecificConsensusPipe(ConsensusPipeName name) {
  return Optional.ofNullable(consensusPipe2ConnectorMap.get(name))
      .map(sink -> {
        long userWriteProgress = sink.getLeaderReplicateProgress();
        long replicateProgress = sink.getFollowerApplyProgress();
        return Math.max(userWriteProgress - replicateProgress, 0L);
      }).orElse(0L);
}
```

即 `syncLag = max(leaderReplicateProgress − followerApplyProgress, 0)`。
恒为 1 ⇒ **两个进度值永久相差 1**。

### 3.2 两个进度值分别来自哪里

**leader 侧**（`IoTConsensusV2AsyncSink:863`）：

```java
public long getLeaderReplicateProgress() {
  return ReplicateProgressDataNodeManager.getReplicateIndexForIoTV2(consensusPipeName);
}
```
`ReplicateProgressDataNodeManager:69`：`consensusPipe2ReplicateIndex.getOrDefault(pipeName, new AtomicLong(0)).get()`
—— 这是**本节点已分配给写入请求的复制进度索引**。

**follower 侧**（`IoTConsensusV2AsyncSink:868`）：

```java
public long getFollowerApplyProgress() { return currentReplicateProgress; }
```
而 `currentReplicateProgress` 只在**成功应用事件**时推进（同文件 :275-276）：

```java
private volatile long currentReplicateProgress = 0;
...
currentReplicateProgress =
    Math.max(currentReplicateProgress, event.getReplicateIndexForIoTV2());
```

### 3.3 推论

固定差 1 意味着：**本节点记录的"已分配索引 N"始终比"已应用事件的索引 N−1"大 1**，
即**最后一个索引对应的"应用"从未被计入 `currentReplicateProgress`**。

可能的具体成因（需研发确认是哪一种）：

1. **索引分配与应用粒度不一致**：leader 侧按"写入请求"分配索引，而 V2 的 pipe 按 **TsFile** 投递事件；
   最后一次分配索引对应的写入可能还在 memtable 里、尚未形成 TsFile，于是永远没有事件带该索引。
2. **事件被跳过但仍计入了分配进度**：`IoTConsensusV2Processor:102-113` 对
   `getReplicateIndexForIoTV2() != NO_COMMIT_ID` / 已见索引有跳过逻辑，
   若"跳过"的事件不推进 `currentReplicateProgress`，就会留下永久差 1。
3. **ack 未回写**：`getFollowerApplyProgress()` 取的是**发送端本地**的 `currentReplicateProgress`，
   若最后一次 apply 的确认没有回写，发送端视角就永远差 1。

> 注意：该指标在**同一 region 的不同节点上取值不同** —— 实测 leader 侧为 **0.0**、follower 侧为 **1.0**，
> 说明它是"各节点站在自己角度"的结果，而 `calculateSyncLag()` 取所有 pipe 的 **max**，
> 因此只要有一条 pipe 卡在 1，该 region 的 `syncLag` 就永远 ≥1。

---

## 四、影响面

### 4.1 直接后果：`syncLag==0` 不能作为"复制完成"的判据

- 用例 MB-04 就是等 `syncLag` 归零，等了 600 s 也不归零 → 判 FAIL；
- **我此前建议的"副本一致性校验前先等 syncLag 归零"在这个场景下同样无效** —— 它永远等不到。

### 4.2 更值得注意：会让"传输是否完成"的判定永久为否

`IoTConsensusV2ServerImpl:396-402`

```java
public boolean isConsensusPipesTransmissionCompleted(List<String> consensusPipeNames) {
  return consensusPipeNames.stream()
      .noneMatch(pipeName ->
          replicateProgressManager.getSyncLagForSpecificConsensusPipe(groupId, new ConsensusPipeName(pipeName)) > 0);
}
```

只要某条 pipe 的 `syncLag` 恒为 1，这个方法就**永远返回 false**。

它出现在 Region 迁移/加副本的等待路径上（`waitPeersToTargetPeerTransmissionCompleted` →
`isRemotePeerConsensusPipesTransmissionCompleted` 会走到远端节点的该判定）。
本次**未实测迁移场景**，因此只能标注为**潜在风险**，需研发确认：

- 本地等待用的是另一个重载（按 progressIndex 比较，`isAfter`），未必受影响；
- 但远端 peer 的完成判定若走 `syncLag > 0` 这条，**迁移可能一直等到超时**。

### 4.3 运维视角

- 监控大盘上该 region 永远显示"差 1"，与真实状态不符；
- 值班/巡检若以 `syncLag==0` 作为健康标准，会持续误报；
- 与已提的 **TDB-870** 属同类问题：**指标不能作为副本健康依据**。

### 4.4 反方向也会误导（重要）

在 MB-03/MB-14 场景（Pipe 池被压干、TsFile 传输 OOM）中，**follower 真实缺了 4/5 个 TsFile**，
但它自身的 `syncLag` 报的是 **0**：

| 场景 | 真实状态 | `syncLag` | 误导方向 |
|---|---|---|---|
| 空闲、两副本数据一致 | 已同步 | **1** | 假报警 |
| follower 缺 4/5 TsFile | 真实落后 | **0** | **假正常** |

⇒ 该指标在当前实现下**两个方向都不可信**，不能单独作为复制健康判据。

---

## 五、建议

### 5.1 指标语义（本单核心）

1. 明确 `syncLag` 的定义边界：它是"**已分配给写入但尚未被对端应用的数量**"，还是"**队列表数**"？
   当前实现下，只要存在"已分配索引但没有对应事件"的情况，它就永远 >0。
2. 建议让 `getFollowerApplyProgress()` 反映**对端已确认应用的最新索引**（含 ack 回写），
   或让 `currentReplicateProgress` 在"索引被跳过/无需应用"时也同步推进。
3. 建议把 `syncLag` 的判定从"**差值 <= 0**"改为"**差值 <= 容忍阈值**"（例如 <=1 视为追平），
   或在上报时区分"真实待同步字节/事件数"与"进度索引差"。

### 5.2 判定逻辑

`isConsensusPipesTransmissionCompleted` 用 `syncLag > 0` 作为"未完成"的判据过于脆弱，
建议改用进度索引比较（与另一个重载一致），避免被 1 的固定偏移卡死。

### 5.3 可观测性

- 建议额外暴露 `leaderReplicateProgress` / `followerApplyProgress` 两个原始值，
  便于现场直接看出"是差 1 还是差很多"；
- 建议对"`syncLag` 长期恒定为同一小值（如 1）"增加自检告警，因为这种形态更可能是指标问题而非真实积压。

---

## 六、需要研发回答的问题

1. `currentReplicateProgress` 只在 `Math.max(current, event.getReplicateIndexForIoTV2())` 处推进——
   **是否存在"分配了索引但不会产生事件"的写入**（例如仍在 memtable 的尾部）？
   若有，这类索引是否本就不该计入 leader 侧进度？
2. follower 侧 `getFollowerApplyProgress()` 取的是**发送端本地值**，
   它与"对端实际应用到的索引"是否可能长期相差 1（ack 丢失/未回写）？
3. `isConsensusPipesTransmissionCompleted(List)` 用 `syncLag > 0` 判定完成，
   在 `syncLag` 恒为 1 时是否会导致 **Region 迁移/加副本等待超时**？

---

## 七、复现脚本要点

```bash
# 1) 起 RC10 + V2 + 1:1000 比例 + 定时刷盘（与 MB-04 同配置）
MB_MEM_PROPORTION="1:1000:1:1:1:1" MB_FLUSH_PROPORTION="0.5" \
MB_TIMED_FLUSH_SEQ="true" MB_SEQ_FLUSH_INTERVAL="15000" MB_SEQ_FLUSH_CHECK="5000" \
DATA_CONSENSUS=IoTConsensusV2 bash cases/common/mb_04_timed_flush_seq.sh

# 2) 或直接采样（观察恒为 1）
for i in $(seq 1 40); do
  for h in 172.20.70.4 172.20.70.26 172.20.70.14 172.20.70.27 172.20.70.30; do
    curl -s -m 5 "http://$h:9092/metrics" | grep 'type="syncLag"' | awk -v h="$h" '$NF+0>0 {print h, $0}'
  done
  sleep 15
done
```

---

## 附：交给研发的诊断脚本

`tools/diag_synclag.sh`（独立运行，只依赖 `curl` / `awk`，不需要部署 skill 其他文件）

```bash
# 默认采集 5 个 DN，12 轮 × 10s = 2 分钟
./diag_synclag.sh

# 自定义：只看两个节点，观察 5 分钟
DN_LIST="172.20.70.4 172.20.70.27" ROUNDS=30 INTERVAL=10 ./diag_synclag.sh

# 附加 region→库名/角色 映射
CLI=/path/to/start-cli.sh ./diag_synclag.sh
```

**它做什么**：逐轮抓每个 DataNode `:9092/metrics` 上的 `type="syncLag"`（保留 `region` / `nodeId` 标签），
然后按 (节点,region) 判定：

| 判定 | 含义 | 处置 |
|---|---|---|
| `ZERO` | 始终为 0 | 正常 |
| **`STUCK`** | **非零且窗口内恒定为同一值** | **疑似指标记账问题（本次上报形态）** |
| `GROWING` | 末值 > 首值 | 真实积压，查 pipe 队列与 Pipe 池 |
| `DRAINING` | 末值 < 首值 | 正在追赶，继续观察 |
| `FLUCT` | 非零但无单调趋势 | 结合 pipe 队列判断 |

检出 `STUCK` 时脚本会直接打印结论与下一步建议（暴露两个原始进度值）。

实测输出示例（当前集群、无卡住项）：

```
=== 结论 ===
  采集 series 总数: 14   非零: 0   恒定非零(STUCK): 0   增长(GROWING): 0
```
