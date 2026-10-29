# RC10（c60ce63）IoTConsensusV2 轮 5 条失败用例的定位结论

| 项 | 内容 |
|---|---|
| 被测版本 | TimechoDB V2.0.12.1，BuildInfo **`c60ce63`**（RC10） |
| 环境 | 3C5D，`schemaRF=3`、`dataRF=2`；DN `-Xmx12804M`；客户端 172.20.70.3 |
| 协议 | `org.apache.iotdb.consensus.iot.IoTConsensusV2`（`iot_consensus_v2_mode=batch`） |
| 用例集 | `membuf_skill`（19 功能 + 5 性能），本文件只涉及 V2 轮失败的 5 条 |
| 结论日期 | 2026-10-23 |

---

## 一、结论摘要

| 用例 | 现象 | 定性 | 处置建议 |
|---|---|---|---|
| MB-03、MB-14 | 停副本后剩 160/1200 点 | **测试配置副作用**（Pipe 池被压干） | 撤销，改用例配置 |
| MB-04 | `syncLag` 600s 未归零 | **指标缺陷**（恒为 1，另有专项单） | 转 [DEFECT_RC10_SYNCLAG.md](DEFECT_RC10_SYNCLAG.md) |
| MB-05 | 阶段B "无新 TsFile"（实得 3、期望 4） | **用例断言缺陷**（合并使总数下降） | 修断言 |
| MB-11 | 顺序数据的 `unsequence/` 非空 | **V2 走 LOAD 路径的固有结果**（LOAD 硬编码进 unsequence） | **需产品决策** |

⇒ 5 条中 **1 条需产品决策（MB-11）**，其余为测试侧问题或已单独立项。

---

## 二、MB-03 / MB-14：Pipe 内存池被压干导致 TsFile 传输 OOM

### 2.1 现象

写入 1200 点后停掉一个副本，其余副本查询只返回 **160 点**（基准 1200）。V1 下同样操作返回 1200。

### 2.2 现场证据

**（1）DN 日志：TsFile 传输因内存不足失败**（leader 侧）

```
WARN IoTConsensusV2TsFileInsertionEventHandler:385 - IoTConsensusV2-__consensus.DataRegion[5…]
  PipeRuntimeOutOfMemoryException{message='forceAllocate: failed to allocate memory after 10 retries,
    total memory size 6698334 bytes, used memory size 6675534 bytes, requested memory size 488…'}
WARN IoTConsensusV2AsyncSink:779 - Failed to borrow client from client pool or exception occur
```

**（2）逐节点 TsFile 盘点**（不停任何副本时）

| 节点 | TsFile | 同步指标 |
|---|---|---|
| 172.20.70.14（Leader） | 5 个，合计 168,759 B | syncLag sum=2 |
| 172.20.70.30（Follower） | **1 个，9,333 B** | syncLag sum=0 |
| 70.4 / 70.26 / 70.27 | 无（非该 region 副本） | 0 |

停掉 leader 后，follower 只能提供本地那 1 个 9.3 KB 的 TsFile，对应 **160 点**。

### 2.3 根因

**（1）Pipe 内存池容量取自 `datanode_memory_proportion` 的第 5 段**

`DataNodeMemoryConfig:212-215`：

```java
if (proportions.length >= 6) {
  pipeMemorySize = maxMemoryAvailable * Integer.parseInt(proportions[4].trim()) / proportionSum;
}
```

六段含义（配置模板原文）：
`StorageEngine : QueryEngine : SchemaEngine : Consensus : StreamingEngine : Free`
**第 5 段（StreamingEngine）即 Pipe 池。**

| 配置 | 第 5 段份额 | Pipe 池（heap 12804 MB） |
|---|---|---|
| `1:2000:1:1:1:1`（MB-03/MB-14） | 1/2005 | **≈6.4 MB** |
| `1:1000:1:1:1:1`（MB-04） | 1/1005 | ≈12.7 MB |
| 默认 `3:3:1:1:1:1` | 1/9 | **≈1.4 GB** |

**（2）为什么"逐个 TsFile 传"仍会 OOM**

V2 确实是逐 TsFile 传输的，但：

- 每打开一个 TsFile 需要一块**固定大小**的 reader 缓冲：
  `pipe_memory_allocate_for_tsfile_sequence_reader_in_bytes` 默认 **2 MB**，**与 TsFile 实际大小无关**；
- 当时集群有 **14 条 `__consensus` pipe**（7 个 DataRegion × 双向），并发传输时各自需要 reader；
- 6.4 MB ÷ 2 MB ⇒ **仅够约 3 个并发 reader**，第 4 个开始
  `forceAllocateForTabletWithRetry` 按 `max_retries=10`、间隔 50 ms 重试后失败，该 TsFile 即传不出去。

**（3）对照验证**

| 配置 | 结果 |
|---|---|
| `1:2000:1:1:1:1`（Pipe 池 6.4 MB） | 停副本后 160/1200，稳定复现 |
| `1:5:1:1:1:1`（Pipe 池 ≈1.4 GB） | 两副本 TsFile 尺寸一致（43,306 B），停任一副本查询仍 1200 |

### 2.4 处置

- **测试侧**：副本一致性校验不复用极端比例；用例已支持外部覆盖 `MB_MEM_PROPORTION`。
- **建议（非缺陷）**：固定 2 MB 的 reader 缓冲可考虑按需申请，见 §五。

---

## 三、MB-05：用例断言缺陷（合并使 TsFile 总数下降）

### 3.1 现象

```
阶段B tsfile 合计: 4 -> 3（sequence=3 unsequence=0）
FAIL 阶段B 关闭乱序定时刷盘后无新 TsFile: 实际=[3] 期望=[4]
```

阶段A 的正面证据是通过的：

```
PASS 阶段A：乱序定时刷盘触发（产品日志 'Exceed unsequence memtable flush interval' 出现 1 次）
```

### 3.2 根因

阶段B 的意图是"关闭乱序定时刷盘后**不再新增乱序 TsFile**"。
实测 `unsequence=0`，**意图已满足**；断言失败仅因为用例用 **TsFile 总数**做单调递增假设，
而**合并（compaction）会让总数下降**（4 → 3）。

### 3.3 处置

断言应改为"**unsequence 目录的 TsFile 数不增加**"，而非"总数不小于基线"。

> 该条在默认内存比例下同样复现，与内存配置无关。

---

## 四、MB-11：V2 副本数据必然进 `unsequence/`（LOAD 路径固有语义）

### 4.1 现象

`enable_separate_data=true`、纯顺序写入后：

```
A 相布局: sequence=1 unsequence=1
FAIL ②A 相 unsequence/ 为空（顺序数据不进乱序目录）: 实际=[1] 期望=[0]
PASS ④A 相点数: 400
```

- **默认内存比例（1:5）下同样复现** ⇒ 与 Pipe 池无关；
- V1 下同一用例通过（V1 走日志复制，follower 走正常写入路径）。

### 4.2 精确定位

按 MB-11 阶段A 的写法（INT64、400 点、`flush_proportion=0.5`、`enable_separate_data=true`）单独复现：

| 节点 | `sequence/` | `unsequence/` | 说明 |
|---|---|---|---|
| **172.20.70.4** | **1** | 0 | leader，归属正确 |
| **172.20.70.26** | 0 | **1** | follower，全部进 unsequence |

副本上的文件：

```
data/datanode/data/unsequence/root.mb11a/13/0/1792741269761-1-0-0.tsfile   410 B
```

### 4.3 根因：LOAD 路径硬编码 `setSeq(false)`

V2 的复制接收端直接调用存储引擎的 **load** 入口：

```java
// IoTConsensusV2Receiver.java:734
region.loadNewTsFile(...)
```

而该入口内部**无条件**把资源标记为非顺序、并加载进 unsequence 目录
（`DataRegion.doLoadNewTsFileWithObject`）：

```java
5084:  newTsFileResource.setSeq(false);           // 强制非顺序
...
5109:  loadTsFileToUnSequence(
5110:      tsfileToBeInserted, newTsFileResource, newFilePartitionId,
5111:      deleteOriginFile, isGeneratedByPipe, effectiveHasObjectData);
```

对应日志文案也明确写着：

```
STORAGE_LOG_TSFILE_MUST_BE_RENAMED_TO_FOR_LOADING_INTO_THE_UNSEQUENCE
```

`isFromConsensus` 参数只用于跳过 last-cache 初始化（`DataRegion.java:5049`），**不影响 seq 判定**。

⇒ **LOAD 一律进 unsequence 是既有设计**（这一点与运维经验一致）。
V2 选择用 LOAD 路径做 TsFile 复制，因此副本数据**必然**落在 `unsequence/`，
与 leader 的 `sequence/` 不一致。**这不是 V2 复制逻辑的缺陷，而是路径选择带来的固有结果。**

### 4.4 影响

| 影响面 | 说明 |
|---|---|
| 目录语义 | `enable_separate_data` 在副本上不成立：leader 全在 `sequence/`，副本全在 `unsequence/` |
| 统计口径 | 按目录统计（`sequence/` 与 `unsequence/` 文件数、大小）的巡检/报表在副本上会得到不同结果；`show regions` 的 TsFile 分布同样不同 |
| 合并行为 | unsequence 与 sequence 的合并策略不同，副本与 leader 的文件布局会持续分化 |
| 数据正确性 | **不受影响**：查询结果一致（MB-11 的「A 相点数=400」PASS，MB-03/14 的查询比对也能返回完整数据） |

### 4.5 需要产品决策

1. **副本数据全部进 `unsequence/` 是否可以接受？**
   - 若可接受：用例应调整为「副本只校验数据完整性（点数/查询结果）」，不校验目录归属；
     `enable_separate_data` 的文档需说明该差异。
   - 若不可接受：V2 需要一条**保留原 seq 归属**的加载路径
     （例如接收端携带该 TsFile 原本是 sequence 的信息，加载时不再无条件 `setSeq(false)`）。
2. 若长期保留该差异，是否会影响后续 **compaction 触发条件**与**分层存储/归档策略**
   （例如只归档 `sequence/` 目录的运维方案会在副本上失效）？

## 五、附带的产品改进建议（不影响本次定性）

### 5.1 固定 2 MB 的 TsFile reader 缓冲可考虑按需申请

```java
// PipeConfig / CommonConfig
private volatile long pipeMemoryAllocateForTsFileSequenceReaderInBytes =
    (long) 2 * 1024 * 1024;   // 2MB，固定
```

本次实测的利用率：

| 项 | 数值 |
|---|---|
| 单个 TsFile 实际大小 | 51,377 / 48,887 / 9,804 B |
| 每个 reader 固定申请 | 2,097,152 B |
| 利用率 | **≈2.5%** |
| 可并发 reader 数（6.4 MB 池） | ≈3 |
| 实际并发 pipe 数 | 14 |

建议改为 `min(固定上限, max(TsFile 实际大小, pipe_memory_allocate_min_size_in_bytes))`
（下限用现成配置项，默认 32 B）。默认配置下此问题不显现，仅在小池 + 高并发时暴露。

### 5.2 可观测性

- Pipe 池建议暴露 `total / used` 与"当前打开中的 reader 数"，便于现场直接判断池子是否不足；
- TsFile 传输因内存不足**最终失败**时建议升级为 ERROR 并计入指标（当前仅 WARN）。

---

## 六、复现方法

```bash
# MB-03 / MB-14（极端比例触发 Pipe 池不足）
MB_MEM_PROPORTION="1:2000:1:1:1:1" DATA_CONSENSUS=IoTConsensusV2 \
  bash cases/common/mb_14_consensus_v2.sh

# MB-05（断言问题）
MB_MEM_PROPORTION="1:5:1:1:1:1" DATA_CONSENSUS=IoTConsensusV2 \
  bash cases/common/mb_05_timed_flush_unseq.sh

# MB-11（副本目录归属）
MB_MEM_PROPORTION="1:5:1:1:1:1" DATA_CONSENSUS=IoTConsensusV2 \
  bash cases/common/mb_11_separate_data.sh
```

排查单个库的副本目录分布：

```bash
VER=v20121rc10_1021_c60ce63
for h in 172.20.70.4 172.20.70.26 172.20.70.14 172.20.70.27 172.20.70.30; do
  s=$(ssh cluster@$h "sudo find /data/iotdb/$VER/data/datanode/data/sequence/root.mb11a -name '*.tsfile' | wc -l")
  u=$(ssh cluster@$h "sudo find /data/iotdb/$VER/data/datanode/data/unsequence/root.mb11a -name '*.tsfile' | wc -l")
  echo "[$h] sequence=$s unsequence=$u"
done
```
