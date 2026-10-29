> # ⚠️ 本文件已撤回（不作为缺陷）
>
> **研发结论：被测场景把 Pipe 内存池配置得过小（`datanode_memory_proportion` 第 5 段 = 1，
> 6.4 MB），因此 TsFile 传输 OOM 属配置不足，不是产品缺陷。**
>
> 相应地：
> - 原 §3.4 提出的"记账泄漏（accounting leak）"**已撤回** —— 该推断基于"堆里看不到内存块对象"，
>   但内存块对象的 accounted size 只是对象里的一个 long 字段，负载在 `byte[]`，
>   因此"堆里看不到"不能证明记账未减；6.66 MB 也可由 3 个卡住的 TsFile 各持约 2 MB reader 缓存解释。
> - 仍可观测到、但同样归因于池过小的现象：失败传输无限重试（≈222 次/分钟）、
>   池满后新 TsFile 无法分配、重启后未送达的 TsFile 不再补传。
>
> **保留本文件的唯一用途**：记录现象与实测数据，供后续**正常内存配置**下复核是否有偶发残留。
> 请以 [REPORT_RC11.md](REPORT_RC11.md) 的结论为准。

# 缺陷报告：Pipe 内存池接近耗尽，导致 IoTConsensusV2 的 TsFile 复制不完整

| 项 | 内容 |
|---|---|
| 版本 | TimechoDB V2.0.12.1 —— **RC10 `c60ce63`** 与 **RC11 `ea4f835`** 均复现 |
| 环境 | 3C5D，`schemaRF=3`、`dataRF=2`，DN `-Xmx12804M` |
| 协议 | `org.apache.iotdb.consensus.iot.IoTConsensusV2`（`iot_consensus_v2_mode=batch`） |
| 触发条件 | `datanode_memory_proportion` 的第 5 段（Pipe 池）被压到很小 + 多 region 并发传输 |
| 现象 | follower 只收到部分 TsFile；停掉 leader 后副本查询缺数据（**160/1200**） |
| 严重级别 | **P1**（`data_replication_factor=2` 实际退化为单副本；且失败时 `syncLag` 仍报 0，无告警） |
| 日期 | 2026-10-24 |

---

## 一、结论摘要

1. Pipe 内存池在传输 TsFile 时被打满（**已用 99.7% / 99.96%**），随后每笔 TsFile 分配都失败，
   该 TsFile **永久传不到 follower**，副本数据不完整。
2. **RC11 的优化确实生效但没解决问题**：单次请求大小从 RC10 的 ≈488 KB 降到 **50,422 B（≈49 KB）**，
   但失败时池内**可用空间只剩 5,897 B**，仍然分不出来。
3. **已通过对照实验定位为"内存未释放"**（不是并发需求超池）：
   - 打满池子后**完全停止写入、静置 8 分钟**，`used` 仅从 6,675,529 B 降到 6,665,730 B（**−0.15%**），
     仍占 **99.5%**；期间**没有任何数据流动**，因此不可能是"并发占用"；
   - 同期 OOM 计数以 **≈220 次/分钟** 持续增长（8 分钟 +1770 次）⇒ 失败的 TsFile 在**无限重试**；
   - 实验细节见 §三。
4. 附带问题：TsFile 传输因内存不足**最终失败**时，`syncLag` 仍报 **0**，监控无法发现副本不完整。

---

## 二、现场证据

### 2.1 RC10（`c60ce63`）—— 池 6.4 MB，请求 488 KB

DataNode leader 侧（`172.20.70.14`）日志：

```
WARN IoTConsensusV2TsFileInsertionEventHandler:385 - IoTConsensusV2-__consensus.DataRegion[…]
  PipeRuntimeOutOfMemoryException{message='forceAllocate: failed to allocate memory after 10 retries,
    total memory size 6698334 bytes, used memory size 6675534 bytes, requested memory size 488…'}
```

| 指标 | 数值 |
|---|---|
| 池总量 | 6,698,334 B ≈ **6.4 MB** |
| 已用 | 6,675,534 B ≈ **99.7%** |
| 可用 | ≈ 22.8 KB |
| 本次请求 | ≈488 KB（日志截断） |

同步做的逐节点 TsFile 盘点（**不停任何副本**时）：

| 节点 | TsFile | 说明 |
|---|---|---|
| 172.20.70.14（Leader） | **5 个**：51,377 + 48,887 + 9,804 + 48,887 + 9,804 B = 168,759 B | 数据完整 |
| **172.20.70.30（Follower）** | **1 个：9,333 B** | **只收到 1/5** |
| 70.4 / 70.26 / 70.27 | 无 | 非该 region 副本 |

停掉 leader 后，follower 只能提供本地那 1 个 9.3 KB 的 TsFile ⇒ **160 点**（基准 1200 点）。

> 当时 `show pipes` 实测有 **14 条 `__consensus` pipe**（7 个 DataRegion × 双向）。

### 2.2 RC11（`ea4f835`）—— 池 12.7 MB，请求 49 KB，仍然失败

同一节点（`172.20.70.14`）本次出现 **1724 次** `PipeRuntimeOutOfMemoryException`，数值完整：

```
PipeRuntimeOutOfMemoryException{message='forceAllocate: failed to allocate memory after 10 retries,
  total memory size 13363344 bytes, used memory size 13357447 bytes, requested memory size 50422 bytes'}
```

| 指标 | RC10 | **RC11** | 变化 |
|---|---|---|---|
| 池总量 | 6.4 MB | 12.7 MB | — |
| 已用 | 99.7% | **99.96%** | 更满 |
| 可用 | 22.8 KB | **5,897 B** | — |
| **单次请求** | ≈488 KB | **50,422 B** | **↓ 约 10 倍** |
| 结果 | 分配失败 | **仍然分配失败** | 未改善 |

用例断言层面的结果完全一致（MB-03）：

```
FAIL 副本不一致 停 172.20.70.4 时经 172.20.70.26 查询: 基准值/行数=1200 实际值/行数=160
```
（该用例共出现 **9 次** `实际值/行数=160`）

### 2.3 池容量是怎么来的

`DataNodeMemoryConfig:212-215`：

```java
if (proportions.length >= 6) {
  pipeMemorySize = maxMemoryAvailable * Integer.parseInt(proportions[4].trim()) / proportionSum;
}
```

六段含义：`StorageEngine : QueryEngine : SchemaEngine : Consensus : **StreamingEngine(Pipe)** : Free`

| 配置 | 第 5 段份额 | Pipe 池（heap 12804 MB） |
|---|---|---|
| `1:2000:1:1:1:1`（MB-03/MB-14 用例） | 1/2005 | **≈6.4 MB** |
| `1:1000:1:1:1:1`（MB-04 用例） | 1/1005 | ≈12.7 MB |
| 产品默认 `3:3:1:1:1:1` | 1/9 | ≈**1.4 GB** |

> **触发条件是测试配置极端**（为了用小数据量快速触发刷盘，把 StorageEngine 段调到 1000~2000），
> 这一点需要如实说明；但**下面的机制问题与配置无关**，只要池子被打满就会发生。

### 2.4 相关的两个默认值

- `pipe_memory_allocate_for_tsfile_sequence_reader_in_bytes` 默认 **2 MB**（固定，与 TsFile 实际大小无关）；
- `pipe_memory_allocate_max_retries` 默认 10，间隔 50 ms（与日志 "after 10 retries" 对应）。

---

## 三、对照实验：判定为"内存未释放"（并发现无限重试）

### 3.1 实验设计

目的：区分两个候选机制。

| 假设 | 预期实验结果 |
|---|---|
| **A. 内存未释放** | 静置后 `used` **不回落**，且新分配仍失败 |
| **B. 并发需求超池** | 静置后（无并发）`used` **明显回落**，新分配能成功 |

步骤：起 RC11 + V2 + `1:2000`（Pipe 池 6.4 MB）→ 写 1200 点打满池子 → **停写静置 8 分钟**
（每分钟采 OOM 计数）→ 再写 100 点触发新的传输尝试。

### 3.2 结果

**（1）静置期间 OOM 持续增长 ⇒ 失败传输在无限重试**

| 静置分钟 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|---|
| OOM 累计 | 280 | 504 | 724 | 944 | 1166 | 1386 | 1608 | 1828 | **2050** |

**≈220 次/分钟**，且**期间没有任何写入**。

**（2）静置后池占用几乎不回落 ⇒ 假设 A 成立**

| 时点 | OOM 累计 | `used` | 占池比例 |
|---|---|---|---|
| A. 打满后 | 280 | 6,675,529 B | **99.7%** |
| B. 静置 8 分钟后 | 2054 | 6,665,730 B | **99.5%**（仅 −9,799 B / −0.15%） |
| C. 再写 100 点后 | 2364 | **6,665,730 B**（完全不变） | 99.5% |

池总量 **6,698,334 B**；失败请求 **48,882 B**（RC11 已把请求从 ≈488 KB 降到约 49 KB）。
即：**空载 8 分钟后，仍有 99.5% 的内存被持有**，可用仅约 32 KB，不足一次 48 KB 的请求。

**（3）follower 始终只拿到 1 个 TsFile**

| 时点 | Leader 172.20.70.14 | Follower 172.20.70.30 |
|---|---|---|
| A. 打满后 | **7 个**：48,882 / 9,799 / 9,328 / 48,882 / 9,799 / 48,882 / 9,799 B | **1 个：9,328 B** |
| C. 新写入后 | 4 个：9,877 / 51,372 / 48,882 / 48,882 B | **1 个：12,435 B** |

新写入的数据同样没有传到 follower。

### 3.3 结论

1. **"并发需求超池"被排除**：静置期间无任何数据流动，占用仍为 99.5%；
2. **"内存未释放"被证实**：`used` 在空载 8 分钟后只降了 9,799 B（恰好是一个 TsFile 的大小，
   可能是某次释放），主体 6.66 MB 一直被持有；
3. **附带发现：失败传输会无限重试**（≈220 次/分钟），这既放大了 CPU/日志开销
   （此前一次运行累计 1724 次），也说明系统不会"放弃"该 TsFile，而是持续空转；
4. 因此**继续减小请求粒度的方向无效**——RC11 已经把请求压到 48 KB，仍因池内只剩约 32 KB 而失败。

### 3.4 源码 + 现场确认：这不是"内存没释放"，而是"记账没减"

#### （1）OOM 里的 `used` 是记账值，不是堆占用

`PipeMemoryManager.forceAllocateWithRetry` 的失败分支：

```java
throw new PipeRuntimeOutOfMemoryCriticalException(String.format(
    DataNodePipeMessages.PIPE_EXCEPTION_FORCEALLOCATE_FAILED_TO_ALLOCATE_MEMORY_AFTER_D_RETRIES_44EF7AE7,
    memoryAllocateMaxRetries,
    getTotalNonFloatingMemorySizeInBytes(),
    memoryBlock.getUsedMemoryInBytes(),   // ← "used memory size" 取的是全局记账块的累计值
    sizeInBytes));
```

即日志里的 `used memory size 6665730 bytes` = `memoryBlock.getUsedMemoryInBytes()`，
是一个**只由 allocate/release 增减的 long 计数器**，与 JVM 实际堆占用无关。

准入判据也只看这个计数器：

```java
if (getTotalNonFloatingMemorySizeInBytes() - memoryBlock.getUsedMemoryInBytes() >= sizeInBytes) {
  return registerMemoryBlock(sizeInBytes, type);
}
```
本次：6,698,334 − 6,665,730 = **32,604 B** < 请求 **48,882 B** ⇒ 必然失败。

#### （2）现场堆里没有对应的对象

在报 OOM 的节点（172.20.70.14，pid 4768）上执行 `jmap -histo:live`（已触发 Full GC）后：

| 类 | 实例数 | 字节 |
|---|---|---|
| `org.apache.iotdb.db.pipe.resource.memory.PipeMemoryBlock` | **10** | 480 |
| `PipeTabletMemoryBlock` | **0** | 0 |
| `PipeTsFileMemoryBlock` | **0** | 0 |
| `PipeModelFixedMemoryBlock` | **0** | 0 |
| `org.apache.iotdb.commons.memory.AtomicLongMemoryBlock` | 19 | 760 |
| `byte[]` | 80,299 | 13.7 MB（平均 170 B，无大批 48 KB 负载） |
| `PipeTsFileInsertionEvent` | 3 | 816 |

- 失败的是 **tablet 分配**，但堆里 `PipeTabletMemoryBlock` **一个都没有**；
- 全局 `PipeMemoryBlock` 只有 10 个、合计 480 字节（纯对象头，字段就是一个 long）；
- `byte[]` 总量仅 13.7 MB 且以小块为主，**没有任何迹象**支持有 6.66 MB 的 pipe 负载被持有。

⇒ **计数器声称占用了 6.66 MB，但堆里没有与之对应的对象。**

#### （3）结论：记账泄漏（accounting leak）

| 判断 | 依据 |
|---|---|
| 不是"并发占用" | 空载 8 分钟 `used` 只降 0.15%（§3.2） |
| 不是"真实内存被持有" | Full GC 后堆内无 `PipeTabletMemoryBlock` / `PipeTsFileMemoryBlock`，`byte[]` 也无对应量级 |
| **是"记账未回滚"** | `used` 恒为 6,665,730 B 不变，而所有准入都看这个计数器 |

这也解释了三个此前"想不通"的现象：

1. **Full GC 无效** —— 门槛是计数器，不是堆；
2. **把请求从 488 KB 降到 49 KB 仍失败** —— 剩余额度只有 32 KB，仍小于请求；
3. **永不恢复** —— 没有任何超时/重置机制把计数器的残余扣掉。

#### （4）代码里值得重点查的三处（供研发定位）

1. **双份计数**：`memoryBlock`（全局）与 `usedMemorySizeInBytesOfTablets` / `usedMemorySizeInBytesOfTsFiles`（分类）
   在不同位置分别增减；`forceAllocateForTabletWithRetry` 在 `registerMemoryBlock` **之后**再加一次分类计数。
   只要某条路径只减了其中一个，两者就会永久漂移。
2. **两个语义不同的 release 重载**：
   - `release(PipeMemoryBlock block)`：按 `block.getMemoryUsageInBytes()` 全额扣减，并 `markAsReleased()`；
   - `release(PipeMemoryBlock block, long sizeInBytes)`：按**调用方传入的 size** 扣减，
     **不** `markAsReleased()`，减到 0 也不从 `allocatedBlocks` 移除。
   若调用方传入的 size 小于实际记账值，差额将永久留在 `memoryBlock` 里。
3. **`tryResizeInternal` 的 `targetSize == 0` 分支**：把块从 `allocatedBlocks` 移除、扣减计数，
   但**没有** `markAsReleased()`。若之后该块又被 `release(block)` 处理，会出现重复扣减；
   反之若之后没有任何处理，则块虽已移除但状态不是 released，容易在判重逻辑上出现偏差。

#### （5）建议研发先加一条日志

RC11 新增的 `getResizeFailureMessage(...)` 已经会打印
`total / used / usedTablets / usedTsFiles / tabletLimit / tsFileLimit / ...`，
但**只用于 `forceResize` 失败**。本次失败走的是 `forceAllocate`，消息里只有
`total / used / requested`。

**建议把 `forceAllocate` 的失败消息也扩展成同样的字段集**——一旦 `used` 与
`usedTablets + usedTsFiles` 出现明显差异，就能立刻确认是哪一侧漂移，不必再靠堆转储。

## 四、影响

1. **副本冗余失效**：`data_replication_factor=2` 时，停掉 leader 后副本只剩 160/1200 点，
   数据不可用——实际等同于**单副本**。该现象在 RC10 与 RC11 上都能稳定复现。
2. **静默失败**：TsFile 传输因 OOM 失败时，**follower 自身的 `syncLag` 仍报 0**
   （RC10 实测：follower 缺 4/5 个 TsFile 而 `syncLag` = 0）；
   日志级别是 **WARN**，`log_datanode_error.log` 无记录 ⇒ 监控与巡检**发现不了**。
3. 该失败只会打掉**部分** TsFile，因此数据"看起来还在"（其余副本可查），
   只有在副本故障切换时才暴露 —— 风险不容易被日常巡检察觉。

---

## 五、复现方法

```bash
# 环境：RC11（ea4f835），IoTConsensusV2，SchemaRF=3 / DataRF=2
# 关键：把 Pipe 池压小（第 5 段 = 1，StorageEngine 段调大）
MB_MEM_PROPORTION="1:2000:1:1:1:1" DATA_CONSENSUS=IoTConsensusV2 \
  bash cases/common/mb_03_flush_by_proportion.sh
```

复现后检查：

```bash
# 1) 是否有 OOM
grep -c 'PipeRuntimeOutOfMemoryException' <datanode>/logs/log_datanode_all.log

# 2) leader 与 follower 的 TsFile 数量/大小是否一致
for h in <leader> <follower>; do
  ssh $h "sudo find /data/iotdb/<VER>/data/datanode/data -path '*<db>*' -name '*.tsfile' -printf '%s '"
done

# 3) 停 leader 后从 follower 查询
```

---

## 六、建议

### 6.1 短期（规避）

- **不要把第 5 段（Pipe）配得过小**；生产建议用默认 `3:3:1:1:1:1`（Pipe ≈1.4 GB）；
- 若确实需要小池，同步下调 `pipe_memory_allocate_for_tsfile_sequence_reader_in_bytes`（默认 2 MB），
  避免"每个 reader 固定吃 2 MB"。

### 6.2 长期（修复方向）

1. **主攻"内存未释放"**：定位 TsFile 传输（含**失败路径**）中 reservation 的申请/归还配对，
   以及失败重试时是否重复持有；
2. **给失败重试加上限与退避**：当前即使无写入也会以 ≈220 次/分钟持续重试并持续失败，
   应设置最大重试次数/指数退避，并在放弃时打 ERROR；
3. **补可观测性**：暴露 Pipe 池 `total / used / peak`、在途 reservation 数、当前打开的 reader 数；
4. **失败可见性**：OOM 导致 TsFile 未送达时，不应让 `syncLag` 保持 0。
5. 若最终确认"每个 TsFile 固定 2 MB reader"是主要持有者，可再考虑按文件实际大小申请；
   但**优先级低于释放路径**（实测减小请求量并未缓解）。

## 七、给研发的确认问题

1. **已实测：空载 8 分钟后 `used` 仍为 99.5%（只降 9,799 B）**。请问是哪个对象/哪条路径持有了这 6.66 MB？
   失败传输的 reservation 是否在异常路径上漏了释放？
2. 当前架构下"每个 TsFile 需要一个固定 2 MB reader"是否必要？14 条 pipe 并发时是否预期会超池？
3. **已实测：失败后以 ≈220 次/分钟无限重试**（无写入时也在重试）。是否有重试上限？
   每次重试是否都会重新申请内存（从而持续失败）？
4. 为什么 OOM 最终失败后 `syncLag` 仍为 0（是否只统计已入队事件）？
5. 该失败是否应升级为 ERROR 并计入可观测指标？

---

## 八、证据索引

| 项 | 位置 |
|---|---|
| RC11 测试报告（含该问题的用例结论） | [REPORT_RC11.md](REPORT_RC11.md) §4.2 |
| RC10 测试报告 | [REPORT_RC10.md](REPORT_RC10.md) §5.1 |
| RC10 详细分析（含逐节点 TsFile 盘点原始数据） | [DEFECT_RC10_V2_REPLICA.md](DEFECT_RC10_V2_REPLICA.md) §二 |
| RC10 / RC11 用例日志 | `/tmp/rc10_phase3.log`、`/tmp/rc11_phase3.log`（集群侧 `/tmp`） |
| 用例明细 | `results/MB-03_*.out`、`results/MB-14_*.out`（含 `实际值/行数=160` 断言原文） |
