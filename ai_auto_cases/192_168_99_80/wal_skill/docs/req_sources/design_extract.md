# WAL 设计文档结构化需求抽取（为 WAL 测试 skill 提供依据）

## 0. 抽取范围与约定

**输入（仅这三份）**：

| 引用时使用的文件名 | 绝对路径 |
| --- | --- |
| `V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md` | `D:\IDEA\deepseek\ip99_80\feishu_docs_wal\V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md`（467 行） |
| `WAL 预写日志.md` | `D:\IDEA\deepseek\ip99_80\feishu_docs_wal\归档\WAL 预写日志.md`（270 行） |
| `写前日志.md` | `D:\IDEA\deepseek\ip99_80\feishu_docs_wal\归档\写前日志.md`（50 行） |

**引用格式**：`文件名#章节/小标题`。章节号沿用原文（如 `#4.1 文件滚动命名`、`#6.3.2 MemTable 快照`）；原文无编号的章节用原文标题文字（如 `#参数配置`、`#概述`）。

**标记约定**：
- 「原文」= 引号内为原文照抄（原文错别字如 "Leade"、"Wokring Buffer" 保留原样，另加说明）。
- 「文档未提及」= 三份文档正文均无此内容。
- 「不确定」= 只能推断、不能从原文确证。
- 三份文档均为飞书导出，**大量关键细节只在图片里**（`image.png` / `image4.png` / `image7.png` / `image8.png` / `image10.png` / `image13.png` 等），正文只有图题（如"图2.1 WAL 文件与 MemTable 的映射关系"），**图片内容无法提取**，凡涉及图片处一律标注。

**三份文档关系（重要，影响引用权威性）**：`写前日志.md`（50 行）是 `WAL 预写日志.md`（270 行）的**严格子集**（仅"整体方案 + 参数配置"），两者逐字相同；`WAL 预写日志.md` 是 `技术设计.md` 的**较早版本 + 加密补充**（多了 1.1 简介 / 1.2 检查点 / 1.3 性能考量 / 1.4 数据安全 / 相关资料，且有加密相关描述），`技术设计.md` 是较新版本（多了设计目标实验数据、内存控制与 `MemoryControlledWALEntryQueue`、`wal_buffer_queue_proportion`、LZ4 说明、测试计划、安全性自查）。**冲突时以 `技术设计.md` 为准**，差异见 §9.3。

---

## 1. 机制总览

### 1.1 WAL 作用与原理

- 定义与 redo-only 语义（`WAL 预写日志.md#1.1. 简介`）：「预写日志 WAL，全称 write-ahead logging，是一种能在设备故障中保障数据库持久性和原子性的技术，最典型的几种实现思路就是 redo log、undo log、redo/undo log，IoTDB不支持事务，仅考虑 redo log 即可。」
  → **redo-only**：只做重放（redo），无 undo log；原因是「IoTDB不支持事务」。
- 作用（`WAL 预写日志.md#1.1. 简介`）：「作用：为减少磁盘 I/O 开销，数据插入/修改操作通常先在内存中缓存，等积攒到一定大小以后再写入磁盘。如果数据库在数据落盘前发生故障，那么在内存中的数据就可能丢失，而正在写的磁盘文件也可能损坏，WAL 用来保障这部分数据的持久性。」
- 原理（`WAL 预写日志.md#1.1. 简介`）：「原理：数据在实际修改数据库文件前被写入到一个称为 WAL 的文件中。数据库在重启恢复阶段读取 WAL，恢复未落盘的数据。」
- 检查点目的与原理（`WAL 预写日志.md#1.2. 检查点`）：「目的：当数据成功落盘后，其对应的 WAL 日志记录就是无效的。为了防止磁盘上的 WAL 文件积累过大，需要定期对日志做检查点，删除无效的 WAL 文件。」/「原理：比对 WAL 文件和数据库文件，检查哪些 WAL 记录已经失效。」
- 性能定位（`V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#设计目标`）：「此外，WAL 操作磁盘开销很大，很容易造成性能瓶颈，这时 WAL 的写入能力就决定了数据库整体的写入性能上限。需要对 WAL 写入的各个环节进行优化。」
- 实验量级（同上）：「假设以 I/O 吞吐量为磁盘资源使用的指标，写入 WAL 在 InsertTablets 和 InsertRecords 中分别占据了 67% 和 88% 的磁盘使用量。」（实验用 `InsertTablets`/`InsertRecords` 各写 20 分钟；配置在图片 `image.png` 中，未提取）
- 四个优化方向（`WAL 预写日志.md#1.3. 性能考量`）：「避免在 WAL 引入随机 I/O / 增大 WAL 每次写入磁盘的数据量 / 提高 WAL 写内存的并发度 / 使用压缩减少 WAL 占用的磁盘空间」

### 1.2 写入路径（客户端写入 → WAL → MemTable → TsFile）

文档**没有**给出端到端的单行写入路径描述，可确证的部分：

1. 写入请求进入 DataRegion（`技术设计.md#WAL 对 IoTConsensus / Pipe 的支持`，标题"DataRegionStateMachine（Leader） 写入流程"）：「将写入请求写到 DataRegion」→「将写入请求写到 DataRegionStateMachine 的 Consume Queue【使用 IoTConsensus || Pipe 需要】」。
2. 写入被包装为 WAL Entry 提交给 WAL Node（`技术设计.md#写入流程`）：「写入线程将这次写入包装为 WAL Entry 提交给 WAL Node；」→ WAL Buffer 队列 → 序列化到 Working Buffer → 切换 Syncing Buffer → 压缩为 Compressed Buffer（`WAL 预写日志.md` 另有：加密）→ 写入 WAL 文件（fsync）。
3. WAL Entry 对应「一个写入相关的物理计划 WritePlanNode（包括 InsertRowNode、InsertTabletNode 和 DeleteDataNode）」（`技术设计.md#概述`）。
4. WAL 与内存表/磁盘的映射见「图2.1 WAL 文件与 MemTable 的映射关系」（`技术设计.md#概述`）：每个 MemTable 的 WAL 可写在多个 WAL 文件中，每个 WAL 文件记录多个 MemTable 的 WAL；WAL Node ↔ DataRegion ↔ 时间分区的对应关系**仅在图片中**（正文未给文字描述）。
5.「数据在实际修改数据库文件前被写入到一个称为 WAL 的文件中」（`WAL 预写日志.md#1.1. 简介`）+ MemTable 刷盘成 TsFile（由检查点"记录 MemTable 的刷盘"、删除条件"其对应的 memtable 中只要有一个没有刷盘，此 WAL 文件就不能被删除"反推）。
6. 恢复路径反向：重启「读取 WAL 中的 WAL Entry，将其中属于未刷盘 MemTable 的部分分配给对应 TsFile 的 `UnsealedTsFileRecoverPerformer` 写入」（`技术设计.md#WAL 重启恢复`）。

> **不确定**：「先写 WAL 再写 MemTable」的严格时序、以及 MemTable 何时对查询可见，文档未显式写明；只能由「数据在实际修改数据库文件前被写入到 WAL」推断。

### 1.3 与共识协议的关系

- WAL Node 数量与共识协议（`技术设计.md#概述`、`WAL 预写日志.md#2.1. 概述`、`写前日志.md#1. 概述`，三处逐字一致）：「每个 WAL Node 代表一个 WAL 目录，每个目录下有多个 WAL 文件。在 IoTConsensus 中，每个 DataRegion 拥有一个 WAL Node；在 RatisConsensus 中不使用 WAL；在 SimpleConsensus 中一般为[data region num / 2, data region num] 个 WAL Node；」
- WAL Node 申请键（`技术设计.md#WAL Node 分配策略`）：「MemTable 通过一个字符串 unique id 向 WAL Manager 申请 WAL Node。IoT Consensus 下 unique id 为 databaseName，其他情况下为 databaseName-{sequence/unsequence}。」
- MultiLeader 约束（`技术设计.md#WAL Node 分配策略`）：「FirstCreateStrategy：为每个 unique id 分配一个 wal node（MultiLeader 只能使用该策略）。」
- IoTConsensus 队列与 WAL 的关系（`技术设计.md#WAL 对 IoTConsensus / Pipe 的支持`）：
  - 「入队时机：【当前 DataRegion 为 Leade】&【队列缓存的条目不超过 4096】&【未超过 IoTConsensus 内存的 60%】」（原文 "Leade" 为 "Leader" 的错别字）
  - 「出队时机：请求被同步成功」
  - 图 `image13.png` 标注了 `WAL File`、`Pipe Event`、`IoTConsensus Sync`、`Pipe Queue`、`WALEntryHandler`、`WALEntryPosition file position size`、`WAL Reader Cache List<InsertNode(Bytebuffer)>`、`WAL Buffer`、`IoTConsensus Queue（InsertPlanNode的ByteBuffer）`——**这些信息来自图内文字标注**（图片本身未提取，但导出文本里保留了标注串）。
- WAL 与 Pipe：`技术设计.md#WAL 文件没法被删除的原因` 明确 pipe 会 pin 住 MemTable（见 §5.4）；`WAL 预写日志.md#WAL 对 IoTConsensus / Pipe 的支持` 有「Pipe Queue【补充需求】」小节，但「入队时机：」「出队时机：」**内容为空**（文档未填写）。
- 传输/恢复时读 WAL（`技术设计.md#设计目标`）：「在系统恢复和 IoT Consensus 传输数据时，也可能需要从磁盘上读取 WAL。」

> **IoTConsensusV2：文档未提及**（三份文档只出现 IoTConsensus / RatisConsensus / SimpleConsensus / MultiLeader）。

### 1.4 线程模型（观测面之一）

`技术设计.md#WAL 相关线程`（`WAL 预写日志.md#2.3. WAL 相关线程`、`写前日志.md#3. WAL 相关线程` 同）：
- 「WAL-Serialize：序列化线程，和 WAL Node 的个数相等，将 WAL Entry 序列化到 WALBuffer 中；」
- 「WAL-Sync：磁盘写入线程，和 WAL Node 的个数相等，将 WAL Buffer 的数据写入到 WAL 文件；」
- 「WAL-Delete：WAL 文件删除线程，1 个，负责删除无效的 WAL 文件以及触发 MemTable 快照；」
- 「WAL-Recover：重启恢复线程，仅在重启恢复阶段存在，与 WAL Node 文件夹的数目相同；」

### 1.5 关键类

`技术设计.md#关键类`（写入侧）：「WAL Manager 管理所有的 WAL Node，每个 WAL Node 有一个用于管理检查点的 Checkpoint Manager 以及一个 用于写入 WAL Entry 的 WAL Buffer。在创建 WAL Node 发生异常时，使用 WAL Fake Node 进行异常处理。」/「Checkpoint Manager 使用 Check Point Writer 向检查点文件写入检查点；WAL Buffer 使用 WAL Writer 向 WAL 文件写入 WAL Entry；两者都继承自 Log Writer，提供统一的字节流压缩方法。」
类清单（来自图 2.2 标注串）：`WALManager`、`IWALNode`、`WALNode`、`WALFakeNode`、`IWALBuffer`、`AbstractWALBuffer`、`WALBuffer`、`ILogWriter`、`LogWriter`、`WALWriter`、`CheckpointManager`、`CheckPointWriter`、`WALValue`、`WritePlanNode`、`WAL Entry`、`MemTable`。
恢复侧（`技术设计.md#关键类`）：「WAL Recover Manager 管理所有 WAL Node 的恢复。每个 WAL Recover Task 对应一个 WAL Node 的恢复任务，它包含一个 Check Point Reader 用于读取 Check Pointer 文件，以及一个 WAL Reader 用于从 WAL 文件读取 WAL Entry；二者都包含一个直接访问文件并提供解压功能的 WAL Input Stream。」类清单：`WALRecoverManager`、`WALRecoverTask`、`WALReader`、`CheckPointReader`、`WALInputStream`。

---

## 2. WALNode / 文件组织

### 2.1 WALNode 概念

`技术设计.md#概述`：「每个 WAL Node 代表一个 WAL 目录，每个目录下有多个 WAL 文件。」（`WAL 预写日志.md#2.1. 概述`、`写前日志.md#1. 概述` 同）
- 恢复粒度（`技术设计.md#概述`）：「重启恢复：重启恢复粒度为 WAL Node，每个 WAL Node 独立恢复其对应的 MemTable 并在恢复后直接将这些 MemTable 刷盘。」
- 每个 WAL Node 一个 buffer、一个 checkpoint manager、一组线程（§1.4、§1.5）。
- WAL Node 个数与协议/分配策略见 §1.3 与下表（`技术设计.md#WAL Node 分配策略`）：

| 策略 | 原文语义 |
| --- | --- |
| ElasticStrategy | 「根据 unique id 的个数来决定 wal node 的个数，每个 wal node 负责固定数量（默认 4 个）的 unique id；」 |
| RoundRobinStrategy | 「规定 WAL Node 的个数，通过轮转法分配给各个 unique id；」 |
| FirstCreateStrategy | 「为每个 unique id 分配一个 wal node（MultiLeader 只能使用该策略）。」 |

（三种策略对应的**配置项名文档未提及**，只给了策略英文名。）

### 2.2 `max_wal_nodes_num` 语义

`技术设计.md#参数配置`：「max_wal_nodes_num：WAL Node 的最大数量，默认为 0 表示根据 wal_dirs 中目录数量由系统针对负载自行决定；」（**未标"热加载"**）
- 与 `wal_dirs` 的关系：默认 0 时按 `wal_dirs` 中**目录数量**由系统针对负载自行决定。
- 与实际生效策略（Elastic/RoundRobin/FirstCreate）的绑定关系、以及该参数由哪个配置项选择策略——**文档未提及**。

### 2.3 WAL 目录结构

- `技术设计.md#参数配置`：「wal_dirs：保存 WAL 的目录，若配置多个目录则使用逗号分隔，默认为 data/wal；」（**未标"热加载"**）
- 可确证的层级：`wal_dirs`（默认 `data/wal`）→ 每个 **WAL Node 一个目录** → 目录下有多个 WAL 文件 + 同一时刻 1 个 checkpoint 文件。
- 文件名（`技术设计.md#4.1 文件滚动命名`）：「文件名格式为 _[version_id].wal，其中 version_id 从 0 开始递增；」（注意：格式串以 `_` 开头，原文**未**给出 `version_id` 之前的前缀是什么——即不含任何可识别前缀，或前缀在图片 `image4.png` 中）
- 检查点文件名（`技术设计.md#6.2 检查点文件`）：「检查点文件名格式为 _[version_id].checkpoint，其中 version_id 从 0 开始递增；」
- 文件头尾特征（`技术设计.md#4.2 文件格式`）：WAL 文件尾部是 Metadata，Metadata 以 `Marker：1 个字节（-126），表示 Metadata 开始；` 起始，以 `MagicString：WAL 文件版本字符串，“WAL-V2”；` 结束；`FirstSearchIndex：8 个字节，第一个 WAL Entry 对应的共识进度，含义见相关资料1；`

> **文档未提及（影响大）**：`<wal_dir>/<nodeId>/<regionId>/<file>.wal` 这类**完整路径模式与目录命名规则**——文档从未说明 WAL Node 目录的**目录名**如何生成（是否含 nodeId / regionId / databaseName / unique id），也未说明多 `wal_dirs` 时如何选择目录。这是纯目录观测的最大缺口。

### 2.4 文件轮转规则

- 触发条件（`技术设计.md#4.1 文件滚动命名`）：「文件滚动的触发条件是当前文件及其待写入的 buffer 的数据量超过 wal_file_size_threshold_in_byte；」
- 目的（同上）：「文件滚动的目的是便于 checkpoint 后对 WAL 文件进行删除；同时利于使用纯追加模式避免在 WAL 引入随机 I/O；」
- 动作（`技术设计.md#线程分工`）：「Roll WAL File：关闭旧的WALWriter，创建新的WALWriter来开启新的WAL文件；」
- 检查点文件滚动的触发条件（`技术设计.md#6.2 检查点文件`）：「检查点文件滚动的触发条件是其大小超过 3 MB ；触发滚动时，向新检查点文件写入 MemTable 全局信息检查点后删除上一个检查点文件，因此每个 WAL Node 同一时刻只有一个检查点文件；」
- 滚动状态机（图4.1 标注串：`closed` / `closed flush writing` / `WAL Buffer` / `_1.wal` / `_0.wal` / `_{versionid}.wal`）——**细节在图片**。

### 2.5 `wal_file_size_threshold_in_byte` 与 `wal_buffer_size_in_byte`

- `技术设计.md#参数配置`：「wal_file_size_threshold_in_byte (热加载)：WAL 单个文件的大小限制，默认为 10 MB，超过该阈值会滚动 WAL 文件，即关闭当前文件，开启一个新的 WAL 文件，便于创建检查点后对 WAL 文件进行归档；」
- `技术设计.md#参数配置`：「wal_buffer_size_in_byte：WAL Buffer 的大小，默认为 16 MB；」（**未标热加载**）
- `wal_buffer_size_in_byte` 的另一个作用点（`技术设计.md#参数配置`，`fsync_wal_delay_in_ms` 条目）：「如果当前 WAL Buffer 已写入的大小不大于 wal_buffer_size_in_byte 的 95%时，将该 WAL Buffer 刷盘前的等待时间；」
- 相关：`wal_buffer_queue_capacity`「WAL Buffer 中阻塞队列的容量，用于限制队列中缓存的 WALEntry 数量，默认为 50；」（未标热加载）
- 相关：`wal_buffer_queue_proportion`（`技术设计.md#内存控制`，表格）＝「WALBuffer 队列内存在 MemTable 内存中的占比」，类型 float，默认 0.1。

---

## 3. 关键数据结构 / 记录格式

### 3.1 WAL Entry（WalEntry）

`技术设计.md#4.2 文件格式`（`WAL 预写日志.md#4.2. 文件格式` 同）：
「WAL Entry：一个 InsertRowNode、一个 InsertTabletNode、一个 DeleteDataNode 或一个 MemTable 的快照（WAL Value）对应一个 WALEntry，包含以下字段：」

| 字段 | 原文长度/取值 |
| --- | --- |
| `Type` | 「1个字节，表示 Value 的类型：0x00-0x02：已废弃；0x03：表示 MemTable 的快照；0x04：表示 InsertRowNode；0x05：表示 InsertTabletNode；0x06：表示 DeleteDataNode；」 |
| `MemtableId` | 「8 个字节，是 MemTable 的 id，为从 0 开始递增的整数;」 |
| `Value` | 「不定长，InsertRowNode、InsertTabletNode、DeleteDataNode 或 memtable 全量快照的序列化结果；」 |

### 3.2 WAL 文件尾部 Metadata

`技术设计.md#4.2 文件格式`（逐字段原文）：

| 字段 | 原文 |
| --- | --- |
| `Marker` | 「1 个字节（-126），表示 Metadata 开始；」 |
| `FirstSearchIndex` | 「8 个字节，第一个 WAL Entry 对应的共识进度，含义见相关资料1；」 |
| `WALEntryListSize` | 「4个字节，WALEntrysSizes 的大小 k；」 |
| `WALEntrySizes` | 「4 * k 个字节，k个WALEntry，每个 WALEntry 的序列化大小」 |
| `MemTableSetSize` | 「4个字节，MemTableIdSet 的大小 q；」 |
| `MemTableIds` | 「8 * q 个字节，所有 WALEntry 的 MemTable ID 之集合；」 |
| `MetadataSize` | 「4 个字节，Metadata 部分的大小;」 |
| `MagicString` | 「WAL 文件版本字符串，“WAL-V2”；」 |

设计意图（`技术设计.md#概述`）：「每个 WAL File 的尾部存有一个 MetaData，其中通过 Set<Long> memTablesId 字段记录了该 WAL File 涉及哪些 MemTable；」

### 3.3 WAL Segment 与压缩/加密的（TLV 式）长度字段规则

`技术设计.md#4.2 文件格式`：「WAL Segment: 压缩后的若干个（视刷盘时 Syncing Buffer 中的包含情况）WAL Entry 被压缩为一个 WAL Segment，包含以下字段：」

| 字段 | 原文（**长度字段规则**） |
| --- | --- |
| `Compression Type` | 「1 字节，使用的压缩类型；」 |
| `Compressed Size` | 「4 字节，压缩后的大小 s，在压缩类型为不压缩时，同时也是压缩前大小；」 |
| `Uncompressed Size` | 「4 字节，压缩前的大小，在压缩类型为不压缩时没有该字段；」 |
| `Compressed Entries` | 「s 字节，压缩后的 WAL Entry。」 |

**条件字段规则（可测点）**：`Uncompressed Size` 是**条件存在**的字段——「在压缩类型为不压缩时没有该字段」。因此一个未压缩 Segment 是 `1 + 4 + s` 字节，一个压缩 Segment 是 `1 + 4 + 4 + s` 字节。

加密补充（**仅 `WAL 预写日志.md#4.2. 文件格式` 有**）：「Compressed Entries：s 字节，压缩后的 WAL Entry。如果开启加密，该数据块将在压缩后被加密。」

压缩算法（`技术设计.md#WAL 压缩`）：「每个 WALBuffer 在刷盘之前都进行压缩，在这种方式下一个 WAL 文件中可能就包含多个段，每个段都是压缩和解压缩的基本单位。这种方式的优点是只需要在 WAL 的写读阶段压缩/解压缩一次，WALEntry 序列化与反序列化、IoT Consensus、Pipe 相关的逻辑都无需修改。这种方式的缺点是无法实现最高的压缩率。系统选择 LZ4 作为默认的压缩算法来在时间和空间上取得一个平衡。」
压缩开关（`技术设计.md#参数配置`）：「enable_wal_compression (热加载)：是否开启 WAL 压缩；」（**原文未给默认值**）

### 3.4 检查点记录（CheckpointEdit）

`技术设计.md#6.2 检查点文件`（`WAL 预写日志.md#6.2. 检查点文件` 同）：
「CheckpointEdit：一个检查点落盘成为一个 CheckpointEdit:」

| 字段 | 原文 |
| --- | --- |
| `Type` | 「1 个字节：0x00：MemTable 全局信息检查点；0x01：MemTable 新建检查点；0x02：MemTable 刷盘检查点；」 |
| `Count` | 「4 个字节，MemtableEntry 的个数;」 |
| `MemtableEntry` | 「每个 MemTable 的信息: MemtableId： 4 个字节， memtableId; Length：4 个字节，TsfilePath 的长度; TsFilePath： n 个字节，Tsfile 的路径; VersionId： 4 个字节，该 memtable 的 WAL 起始记录条目所在文件的 version_id;」 |

三种检查点（`技术设计.md#检查点类型`，表6.1）：

| 检查点名称 | 触发时机 | 作用 | 字段 |
| --- | --- | --- | --- |
| MemTable 新建 | 「MemTable 新建」 | 「记录 MemTable 的创建」 | 「每个 MemTable 的 memTableId / 每个 MemTable 对应的 TsFile 路径 / 每个 MemTable 的首个 WAL 文件的 version_id」 |
| MemTable 刷盘 | 「MemTable 刷盘」 | 「记录 MemTable 的刷盘」 | （空） |
| MemTable 全局信息 | 「新建检查点文件」 | 「记录当前所有的 MemTable」 | （空） |

### 3.5 MemTable 快照（snapshot）

- 动机（`技术设计.md#MemTable 快照`）：「当一个 MemTable 写入负载很低，迟迟无法刷盘，会导致对应的多个 WAL 文件无法删除，此时可以将此 MemTable 刷盘（若形成小的数据块则会影响查询的效率）、或者做快照。」
- 语义（`技术设计.md#MemTable 快照`）：「MemTable 快照：假如一个 MemTable 当前对应的 WAL 文件为 WAL1 - WAL10，快照将 memtable 的数据重新持久化到最新的 WAL 文件中，快照后对应的 WAL 文件版本号则在 10 之后，WAL1-WAL9 将不再被此 MemTable 占用。快照过程中 MemTable 是不可修改的，做完快照之后可继续接受写入。」
- 快照的内容形态：一个 WAL Entry，`Type = 0x03`，「Value：不定长，…或 memtable 全量快照的序列化结果」（`技术设计.md#4.2 文件格式`）。
- 概述中的动机表述（`技术设计.md#概述`）：「或 MemTable 的快照（将 MemTable 直接序列化到 WAL 文件中，用于避免写入负载低的 MemTable 长时间占用 WAL 文件，导致无法对 WAL 文件进行归档来释放磁盘空间）」

### 3.6 WAL Buffer（三 Buffer 状态机）与内存控制

- 三 Buffer（`技术设计.md#概述`）：「每个 WAL Node 都有对应的内存缓冲区 WAL Buffer，用于在内存中缓存 WAL Entry。每个 buffer 逻辑上为一整块，物理上平均分为三块（Working Buffer，Compressed Buffer，SyncingBuffer），交替执行序列化、压缩和刷盘任务。」
- 状态机（`技术设计.md#设计细节`）：「三 Buffer 机制：三个 Buffer 在 working、compressed、idle、syncing 四种状态之间切换，始终有一个 Buffer 处于 working 状态；」/「Serialize 任务完成或 working buffer 写满时，阻塞直至有处于 idle 状态的 buffer，将 working buffer 置为 syncing buffer，将 idle buffer 置为 working buffer;」/「Sync 任务完成时，将 syncing buffer 置为 idle buffer;」/「compressed buffer 不参与状态切换，始终占用一个 buffer；」
- WAL Buffer 的接收方式（`技术设计.md#概述`）：「每个 WAL Buffer 通过一个阻塞队列接收 WAL Entry，并通过一个线程将 WAL Entry从中取出写到缓存中，并根据缓存状态进行刷盘；」
- 内存控制（`技术设计.md#内存控制`）：「WALBuffer 中的队列使用自行研发的 MemoryControlledWALEntryQueue。」「MemoryControlledWALEntryQueue 是在 LinkedBlockingQueue 上进行封装，在队列的放入和取出方法上进行内存的统计和控制。」
  流程原文：「放入队列时，首先计算这个 WAL Entry 的内存大小，然后获取 SystemInfo 中统计的当前所有 WAL队列的总内存大小，如果总内存大小超过设置的最大值则进行等待」/「当 SystemInfo 中统计的当前所有 WAL队列的总内存大小小于最大值时，将 WAL Entry 放入内部队列中，之后向 SystemInfo 中报告新增的内存大小」/「从内部队列中拿出 WAL Entry，向 SystemInfo 中报告减少的WAL Entry占用内存大小」
  代码要点（同节 Java 片段）：`private static final Object nonFullCondition = new Object();`、`while (SystemInfo.getInstance().cannotReserveMemoryForWalEntry(elementSize)) { nonFullCondition.wait(); }`、注释「使用一个全局 Object 进行并发控制，否则多个队列发生阻写时写入线程有可能不会被唤醒」。
- 写路径总代价（`技术设计.md#写入流程`）：「总代价：t_enqueue + t_dequeue + t_serialize + t_compress + t_IO」（`WAL 预写日志.md#5 写入流程` 因含加密，实际步骤代价里还有 `t_encrypt`）。

---

## 4. 持久化与恢复

### 4.1 wal_mode 与 fsync 时机

`技术设计.md#参数配置`：
- 「wal_mode：WAL 的写入模式，默认为 ASYNC；」
- 「SYNC：同步提交，写入需要等待 WAL 成功刷盘后才可以返回；」
- 「ASYNC：异步提交，写入不等待 WAL 刷盘，成功后立即返回；」
- 「DISABLE：关闭 WAL 功能；」

fsync 在流程中的位置（`技术设计.md#写入流程`）：「Buffer 序列化线程向Buffer 磁盘同步线程提交同步任务（fsync）；」→「Buffer 磁盘写入线程将 Compressed Buffer 写入到 WAL 文件 ；」→「Buffer 磁盘写入线程向 Syncing Buffer 所包含的 WAL Entry 对应的每一个 WAL Flush Listener 报告状态；」→「写入线程获取到 WAL 状态，进行后续写入流程；」

### 4.2 fsync 延迟参数语义

`技术设计.md#参数配置`：「fsync_wal_delay_in_ms (热加载)：如果当前 WAL Buffer 已写入的大小不大于 wal_buffer_size_in_byte 的 95%时，将该 WAL Buffer 刷盘前的等待时间；调大该值可以增加 WAL 刷盘的批量大小；默认为 1500ms；」

> **`wal_async_mode_fsync_delay_in_ms` / `wal_sync_mode_fsync_delay_in_ms`：三份文档均未提及。** 文档中与 fsync 延迟相关的参数**只有** `fsync_wal_delay_in_ms`（单一参数、无 async/sync 区分、无 `_in_ms` 后缀）。
> **不确定（需到 `iotdb-system.properties` 侧核对，本次不联网不查库）**：这两个名字很可能是该参数在新版产品配置里的拆分（ASYNC/SYNC 两模式各自的延迟），但**不能从这三份文档确证**；文档也未说明 SYNC/ASYNC 两模式下 fsync 延迟语义是否不同。

### 4.3 重启恢复流程

`技术设计.md#WAL 重启恢复`：「恢复粒度：WAL Node」/「流程：」
1. 「启动 DataRegion 的恢复任务，对于各个时间分区下的 0 层未封口的 TsFile，提交异步恢复任务后阻塞等待恢复结果；」／代价：`t_find_unsealed_files`（「确认所有 TsFile 是否封口」）
2. 「待所有 DataRegion 提交完毕后，启动 WAL 恢复任务，恢复各个 WAL Node 下的数据：」
   - 「读取检查点文件，恢复未刷盘 MemTable 信息;」／代价：`t_read_checkpoint + t_uncompress_checkpoint`
   - 「读取 WAL 中的 WAL Entry，将其中属于未刷盘 MemTable 的部分分配给对应 TsFile 的 `UnsealedTsFileRecoverPerformer` 写入；」／代价：`t_read_wal + t_uncompress_wal`（`WAL 预写日志.md#7 WAL 重启恢复` 额外含 `+ t_decrypt`，且该步原文为「如果系统开启加密，读取 WAL Segment 后需要对其进行解密」）
   - 「删除 WAL Node 下的所有文件；」／代价：`t_delete`
3. 「各个 DataRegion 在 TsFile 恢复完成后继续执行后续的恢复任务；」

检查点用于恢复的算法（`技术设计.md#检查点类型`）：「在重启时，可以利用上述检查点（1）根据 MemTable 全局信息检查点恢复全局未刷盘 MemTable；（2）然后从前往后读取 MemTable 新建检查点和 MemTable 刷盘检查点，在未刷盘 MemTable 的信息中添加新建的 MemTable 并删除已刷盘的 MemTable ;（3）根据扫描所有检查点后未刷盘 MemTable 就可以从 WAL 日志文件中过滤出有效的WAL Entry。」
恢复后行为（`技术设计.md#概述`）：「每个 WAL Node 独立恢复其对应的 MemTable 并在恢复后直接将这些 MemTable 刷盘。」
检查点基本功能（`技术设计.md#WAL 检查点及 MemTable 快照`）：「重启恢复：过滤掉 WAL 文件中已刷盘的 memtable 所对应的 WAL Entry。」

### 4.4 「恢复完成」的判定信号

- 文档**没有**给出任何日志关键字、日志级别、metrics 或 SQL 作为恢复完成信号。
- 文档唯一可作**间接**信号的两条原文：①「删除 WAL Node 下的所有文件；」（流程第 2 组最后一步，目录层面可观测）；②「各个 DataRegion 在 TsFile 恢复完成后继续执行后续的恢复任务；」（未给出可观测特征）。
- **不确定**：①「删除 WAL Node 下的所有文件」是否严格发生在恢复成功之后（失败时是否也删）文档未说明；②恢复完成的**并发可见性**（何时可以安全查询）文档未说明。
- 文档提到的恢复期观测对象：「各个时间分区下的 0 层未封口的 TsFile」（即 `UnsealedTsFileRecoverPerformer` 的目标），可作为"恢复是否在跑"的间接迹象。

---

## 5. 检查点与无效 WAL 删除

### 5.1 无效的定义

- 顶层定义（`技术设计.md#WAL 检查点及 MemTable 快照`）：「一个 WAL 文件是否可以被删除由其对应的 MemTable 刷盘状态决定：其对应的 memtable中只要有一个没有刷盘，此 WAL 文件就不能被删除。为记录每个 MemTable 的刷盘状态，进而计算出每个 WAL 文件是否可以被删除，需要引入检查点。」
- 删除判据（同节）：「WAL 文件删除：判断一个 WAL 文件对应的 MemTable 是否都已经刷盘，都刷盘后则可以删除此 WAL 文件；」
- 记录级定义（`WAL 预写日志.md#1.2. 检查点`）：「当数据成功落盘后，其对应的 WAL 日志记录就是无效的。」
- 完全不可删除的三种原因（`技术设计.md#WAL 文件没法被删除的原因`，见 §5.4）。

### 5.2 `delete_wal_files_period_in_ms` 与常规整理

- 参数（`技术设计.md#参数配置`）：「delete_wal_files_period_in_ms (热加载)：对 WAL 文件进行归档，删除无效的 WAL 文件的间隔；默认为 20000ms 。」
- 常规整理算法（`技术设计.md#6.3.1 常规整理`）：「WAL 删除线程定时(delete_wal_files_period_in_ms)获取所有 MemTable 的首个 WAL 文件的 version_id，比较出其中的最小值，删除 version_id 小于该最小值的所有 WAL 文件（如图6.3 所示）；」
- 图6.3 标注串（`技术设计.md#6.3.1 常规整理`）：「file versionId of first WAL」「≤ min(wal versionId of first WAL)」「closed」「writing」「chekcpoiont information」（原文拼写 "chekcpoiont"）；`WAL 预写日志.md#6.3.1 常规整理` 的图6.3 标注含具体版本号示例：`_1.wal`/`_2.wal`/`_3.wal`/`_4.wal`/`_5.wal`/`_6.wal`、`tsfile01`/`tsfile02`、`memtableId 1/2/3/6`。
- 删除线程逻辑图（图6.5 WAL-删除线程，`技术设计.md#WAL 文件总大小限制` 段末 / `WAL 预写日志.md#6.3.3`）的判定文字：「WAL 文件有效信息占比低于阈值或 WAL 文件总大小达到上限？」→ 否：「删除无效的 WAL 文件」；是：「版本号最小的 MemTable 大小小于 wal_memtable_snapshot_threshold_in_byte 并且已进行快照次数小于 max_wal_memtable_snapshot_num」→ 是：「将版本号最小的 MemTable 快照」；否：「将版本号最小的 MemTable 刷盘」；随后「等待 delete_wal_files_period_in_ms」。

### 5.3 `wal_min_effective_info_ratio` / `wal_memtable_snapshot_threshold_in_byte` / `max_wal_memtable_snapshot_num`

- `wal_min_effective_info_ratio`（`技术设计.md#参数配置`）：「WAL 文件的最小有效信息比（即其中未刷盘的 MemTable 所对应的 WAL 的比例），有效信息比小于该值后会触发 memTable 快照或刷盘并删除无效 WAL 文件；默认为 0.1；」(热加载)
  - 触发细节（`技术设计.md#MemTable 快照`）：「如果 WAL 中有效信息的占比 ≤ wal_min_effective_info_ratio，则将 version_id 最小的 MemTable 做快照或刷盘（目的是处理长时间不刷盘的 MemTable，如图6.4 所示），然后继续执行文件删除，直至有效信息占比 > wal_min_effective_info_ratio；」
  - **注意口径不一致**：参数条目写「小于该值」（<），MemTable 快照章节写「占比 ≤ wal_min_effective_info_ratio」（≤）。**不确定**等号是否生效（`ratio = 0` 的边界行为尤其敏感）。
- `wal_memtable_snapshot_threshold_in_byte`（`技术设计.md#参数配置`）：「进行快照的 MemTable 大小阈值，小于该阈值的 MemTable 进行快照写入 WAL 文件，大于该阈值则将其刷盘；默认为 8 MB；」(热加载)
  - 与 `#MemTable 快照` 的分支表述：「MemTable 大小 < wal_memtable_snapshot_threshold_in_byte 时在 WAL 文件内做快照；」「MemTable 大小 ≥ wal_memtable_snapshot_threshold_in_byte 或 累计触发快照数 ≥ max_wal_memtable_snapshot_num 时触发 MemTable 的刷盘；」
  - **注意口径不一致**：参数条目用「大于该阈值则将其刷盘」（隐含等于阈值时不刷？），章节用「≥」。**不确定**等于阈值的归属。
- `max_wal_memtable_snapshot_num`（`技术设计.md#参数配置`）：「MemTable 做快照的次数上限，超过该次数则直接触发刷盘，默认为 1；」(热加载)
  - 判据口径（章节）：「累计触发快照数 ≥ max_wal_memtable_snapshot_num 时触发 MemTable 的刷盘」→ 默认 1 时**第 1 次**触发即走刷盘（因为 `1 ≥ 1`）；参数条目则说「超过该次数」。**不确定**：默认值 1 下到底是"允许 1 次快照后刷盘"还是"不允许快照直接刷盘"——这是高价值待澄清点。

### 5.4 WAL 文件没法被删除的原因（观测/白盒要点）

- `技术设计.md#WAL 文件没法被删除的原因`：
  1. 「MemTable 未刷盘，即 MemTableInfo.flushed 为 false；」
  2. 「MemTable 已经刷盘但是其被 pipe 模块 pin 住，即 MemTableInfo.flushed 为 true 但 MemTableInfo.pinCount 大于 0；」
     - 「有助于调试的输出内容：walNode 的 id；memtable 的 id；」（原文照抄，两行）
  3. 「MemTable 已经刷盘，但是其中的数据没有被 IoTConsensus 消费完，即 endFileIndex 小于 filesToDelete.length；」
     - 「有助于调试的输出内容：walNode 的 id；wal 文件名字；当前的 safeIndex；当前的 searchIndex。」（原文照抄）
- **注意**：这三段是"有助于调试的输出内容"的**字段清单**，原文**没有**给出任何一条具体的日志文本/关键字/级别。

### 5.5 WAL 文件总大小限制

`技术设计.md#WAL 文件总大小限制`：
- 「为了防止 IoTConsensus 发送速率小于 WAL 生成速率所导致的 WAL 文件无限增大，使用参数iot_consensus_throttle_threshold_in_byte来控制 WAL 文件的总大小上限。当 WAL 的文件总大小达到该上限时，将阻止客户端写入。」（**默认值文档未给出**）
- 「但是在有些场景下，即使 IoTConsensus 没有导致 WAL 文件堆积，WAL 文件的运行时总大小也可能会超过该上限（例如 DataRegion 较多、DataNode 内存较大的场景）。为避免对这种场景的写入产生影响，当 WAL 的文件总大小达到上限时，如果不是由于 IoTConsensus 导致，则根据 WAL 有效信息比例对 MemTable 进行快照或刷盘。该操作由 WAL 删除线程执行，不会影响写入线程。」
- 「如此一来， WAL 文件的总大小不会随着写入环境的变化而无限膨胀，并且 WAL 文件总大小触发该阈值时不会阻塞写入。」

---

## 6. 可观测信号（最关键）

### 6.1 日志关键字 / 日志级别 —— **结论：三份文档均未给出**

- 三份文档**没有任何** INFO / WARN / ERROR / DEBUG 级别的日志样例，也没有任何可 grep 的日志文本（全文检索所见均为参数名、类名、线程名、字段名、图题）。
- 文档中与"输出"最接近的表述只有两处，且**只给字段名不给文案**（`技术设计.md#WAL 文件没法被删除的原因`）：
  - 原文：「有助于调试的输出内容：」→「walNode 的 id；」→「memtable 的 id；」
  - 原文：「有助于调试的输出内容：」→「walNode 的 id；」→「wal 文件名字；」→「当前的 safeIndex；」→「当前的 searchIndex。」
- 结论：**日志层面的断言目前无文档依据**；写 WAL skill 时若要用日志，必须先到真实环境采样日志再做断言（或改用目录/文件/白盒信号）。
- 可作为日志观测**锚点**的标识符（文档明确出现的名字，可用于 grep 候选，但**文档未声明它们会出现在日志里**）：`WAL-Serialize`、`WAL-Sync`、`WAL-Delete`、`WAL-Recover`（线程名）、`WALFakeNode`（「在创建 WAL Node 发生异常时，使用 WAL Fake Node 进行异常处理」）、`MemTableInfo.flushed`、`MemTableInfo.pinCount`、`endFileIndex`、`filesToDelete.length`、`safeIndex`、`searchIndex`、`FirstSearchIndex`、`UnsealedTsFileRecoverPerformer`、`MemoryControlledWALEntryQueue`、`SystemInfo`。
- 异常处理线索仅一条（`技术设计.md#关键类`）：「在创建 WAL Node 发生异常时，使用 WAL Fake Node 进行异常处理。」（**未给日志文案**）

### 6.2 metrics / 监控指标名

- `技术设计.md#内存控制` 原文：「并在 WritePerformance 监控面板下新增监控项：」——**其后紧接 `image.png`，正文无指标名**。⇒ **指标名未能提取（在图片里）**。
- 除此之外，三份文档**未出现任何 metrics 名称**（无 `iot_consensus{...}`、无 WAL 相关指标名）。

### 6.3 目录与文件名规律（当前最可用的观测面）

| 观测项 | 原文依据 | 备注 |
| --- | --- | --- |
| WAL 根目录 | `...md#参数配置`：`wal_dirs`「默认为 data/wal」 | 支持多目录，逗号分隔；**未说多目录如何分配** |
| 每个 WAL Node 一个目录 | `...md#概述`：「每个 WAL Node 代表一个 WAL 目录，每个目录下有多个 WAL 文件。」 | **目录命名规则文档未提及** |
| WAL 文件 | `...md#4.1 文件滚动命名`：「文件名格式为 _[version_id].wal，其中 version_id 从 0 开始递增；」 | 正则 `^_\d+\.wal$` |
| 检查点文件 | `...md#6.2 检查点文件`：「检查点文件名格式为 _[version_id].checkpoint，其中 version_id 从 0 开始递增；」 | 正则 `^_\d+\.checkpoint$`；「每个 WAL Node 同一时刻只有一个检查点文件」 |
| 文件内容版本串 | `...md#4.2 文件格式`：「MagicString：WAL 文件版本字符串，“WAL-V2”；」 | 可用于识别 WAL 文件（二进制层面） |
| Metadata 起始标记 | `...md#4.2 文件格式`：「Marker：1 个字节（-126），表示 Metadata 开始；」 | -126 = 0x82 |
| 文件滚动状态 | 图4.1/图4.2 标注串：`closed`、`closed flush writing`、`_0.wal`、`_1.wal` | 细节在图 |
| TsFile 侧关联 | `...md#WAL 重启恢复`：「各个时间分区下的 0 层未封口的 TsFile」；checkpoint 内 `TsFilePath` | checkpoint 里存 TsFile 路径（需白盒解析） |

### 6.4 SQL / 命令

- **三份文档均未出现任何 SQL 或 shell 命令**：没有 `flush`、没有 `SHOW ...`、没有 `SET CONFIGURATION`、没有 `checkpoint` 语句、没有 iotdb-confignode / iotdb-cli 调用。
- 文档中的"检查点"是**内部机制**（检查点文件 + WAL 删除线程），**不是**用户可执行的命令或 SQL。
- 参数表中的「(热加载)」字样是**文档对参数属性的标注**，并非"用某条 SQL 设置"的说明；文档未说明热加载的生效方式/命令。
- **不确定**：真实产品里可用 `SET CONFIGURATION`、`flush`、`show ...` 观测，但**文档未提及**，不能作为有依据的断言来源。

### 6.5 实验性/量级信号（可作性能类断言的文档依据）

- `技术设计.md#设计目标`：`InsertTablets` / `InsertRecords` 各写 20 分钟，「写入 WAL 在 InsertTablets 和 InsertRecords 中分别占据了 67% 和 88% 的磁盘使用量。」
- `技术设计.md#测试计划`：「原本会快速OOM的大请求场景运行 1 天+无OOM」；「手动 Atmos 测试未发现明显的性能影响」。
- `技术设计.md#WAL 压缩`：「设备数=100000 / 序列数=10 / 写入请求大小=1000 / 每个设备写入的行数=1 / 使用单 HDD 作为存储盘的情况下，可以将 I/O 资源节约 30% 左右」。
- `技术设计.md#设计目标` 图片：Benchmark 配置（`image.png`、`img_v3_02hd_ddb5fbf9-4302-401c-99be-c4a1b364c0dg.jpg`）——内容未提取。

---

## 7. 边界与约束

### 7.1 文档明确写出的限制

1. **共识协议差异**（`技术设计.md#概述`）：IoTConsensus 每 DataRegion 一个 WAL Node；RatisConsensus 不用 WAL；SimpleConsensus 一般 `[data region num / 2, data region num]` 个 WAL Node。
2. **MultiLeader 只能用 FirstCreateStrategy**（`技术设计.md#WAL Node 分配策略`）。
3. **WAL 不支持事务**（`WAL 预写日志.md#1.1. 简介`）：「IoTDB不支持事务，仅考虑 redo log 即可」。
4. **写入阻塞上限**（`技术设计.md#WAL 文件总大小限制`）：WAL 总大小达到 `iot_consensus_throttle_threshold_in_byte` 且由 IoTConsensus 导致时「将阻止客户端写入」；非 IoTConsensus 导致时改为快照/刷盘，「不会影响写入线程」「不会阻塞写入」。
5. **IoTConsensus 队列上限**（`技术设计.md#WAL 对 IoTConsensus / Pipe 的支持`）：「队列缓存的条目不超过 4096」且「未超过 IoTConsensus 内存的 60%」且必须是 Leader。
6. **内存上限**：`wal_buffer_queue_capacity` 默认 50（`#参数配置`）；WAL 队列总内存上限由 `wal_buffer_queue_proportion`（float 0.1，「WALBuffer 队列内存在 MemTable 内存中的占比」）约束，超限时**阻塞写入线程**（`#内存控制`）。
7. **并发/一致性约束**：三 Buffer 中「始终有一个 Buffer 处于 working 状态」，「compressed buffer 不参与状态切换，始终占用一个 buffer」；快照期间「MemTable 是不可修改的」（`#设计细节`、`#MemTable 快照`）。
8. **文件数约束**：每个 WAL Node 同一时刻只有一个检查点文件（`#6.2 检查点文件`）；检查点文件 3 MB 滚动。
9. **追加写约束**：滚动「利于使用纯追加模式避免在 WAL 引入随机 I/O」（`#4.1 文件滚动命名`）。
10. **删除受阻约束**：MemTable 未刷盘 / 被 pipe pin 住 / 已刷盘但未被 IoTConsensus 消费完 → WAL 文件不能删（`#WAL 文件没法被删除的原因`）。
11. **恢复粒度约束**：WAL Node（`#概述`），恢复后直接刷盘。
12. **DISABLE 的边界**：`wal_mode` 支持 `DISABLE`「关闭 WAL 功能」，但**「流模式下不允许 DISABLE」这类限制：文档未提及**。
13. **单机 vs 分布式差异**：文档只按共识协议（IoTConsensus / RatisConsensus / SimpleConsensus / MultiLeader）区分，**没有"单机模式 vs 分布式模式"的对比描述**（文档未提及）。
14. **加密**（主要见 `WAL 预写日志.md#1.4. 数据安全` 与 `#4.2. 文件格式`、`#5 写入流程`、`#7 WAL 重启恢复`）：
    - 「WAL 中包含了用户操作，一旦 WAL 文件发生泄漏，攻击者可以通过读取其中的用户操作的方式，获取一部分用户数据。因此，在对数据安全具有较高需求的场景，需要对 WAL 文件进行加密。」
    - 写入侧：「Buffer 磁盘写入线程将 Syncing Buffer 压缩为 Compressed Buffer ，如果系统开启加密，还将对 Compressed Buffer 进行加密，加密的算法和密钥与对 TsFile 加密时相同；」；代价「压缩时间 t_compress + 加密时间 t_encrypt;」
    - 落盘形态：「如果开启加密，该数据块将在压缩后被加密。」
    - 恢复侧：「如果系统开启加密，读取 WAL Segment 后需要对其进行解密，」
    - 加密项与 HTTPS/传输无关（`技术设计.md#安全性设计`）：「该功能是否涉及跨网络 / 跨服务的数据传输，传输链路是否启用加密协议？ 否」
    - `技术设计.md#安全性设计` 另三条：「该功能涉及的数据存储是是否需进行加密存储？ 是」「该功能处理的敏感数据是否需进行数据加密？ 是」「加密算法是否符合安全标准？ 否」
    - **加密开关的参数名/默认值：文档未提及**（只说"开启加密/系统开启加密"）。
15. **热加载属性**（`技术设计.md#参数配置`）：标 `(热加载)` 的有 7 个——`fsync_wal_delay_in_ms`、`wal_file_size_threshold_in_byte`、`wal_min_effective_info_ratio`、`wal_memtable_snapshot_threshold_in_byte`、`max_wal_memtable_snapshot_num`、`delete_wal_files_period_in_ms`、`enable_wal_compression`。**未标热加载**的：`wal_mode`、`wal_dirs`、`wal_buffer_size_in_byte`、`max_wal_nodes_num`、`wal_buffer_queue_capacity`。`wal_buffer_queue_proportion`（`#内存控制`）**未标**热加载。（文档未说明"非热加载 = 必须重启"。）

### 7.2 参数清单（原样汇总，含默认值与热加载标注）

| 参数 | 原文释义（照抄要点） | 默认值 | 热加载 |
| --- | --- | --- | --- |
| `wal_mode` | 「WAL 的写入模式」SYNC/ASYNC/DISABLE | ASYNC | 未标 |
| `wal_dirs` | 「保存 WAL 的目录，若配置多个目录则使用逗号分隔」 | `data/wal` | 未标 |
| `wal_buffer_size_in_byte` | 「WAL Buffer 的大小」 | 16 MB | 未标 |
| `fsync_wal_delay_in_ms` | 「不大于 wal_buffer_size_in_byte 的 95%时，将该 WAL Buffer 刷盘前的等待时间」 | 1500ms | ✔ |
| `max_wal_nodes_num` | 「WAL Node 的最大数量，默认为 0 表示根据 wal_dirs 中目录数量由系统针对负载自行决定」 | 0 | 未标 |
| `wal_buffer_queue_capacity` | 「WAL Buffer 中阻塞队列的容量…限制队列中缓存的 WALEntry 数量」 | 50 | 未标 |
| `wal_file_size_threshold_in_byte` | 「WAL 单个文件的大小限制…超过该阈值会滚动 WAL 文件」 | 10 MB | ✔ |
| `wal_min_effective_info_ratio` | 「WAL 文件的最小有效信息比…」 | 0.1 | ✔ |
| `wal_memtable_snapshot_threshold_in_byte` | 「进行快照的 MemTable 大小阈值…」 | 8 MB | ✔ |
| `max_wal_memtable_snapshot_num` | 「MemTable 做快照的次数上限，超过该次数则直接触发刷盘」 | 1 | ✔ |
| `delete_wal_files_period_in_ms` | 「删除无效的 WAL 文件的间隔」 | 20000ms | ✔ |
| `enable_wal_compression` | 「是否开启 WAL 压缩」 | **未给** | ✔ |
| `wal_buffer_queue_proportion` | 「WALBuffer 队列内存在 MemTable 内存中的占比」（float） | 0.1 | 未标 |
| `iot_consensus_throttle_threshold_in_byte` | 「控制 WAL 文件的总大小上限」 | **未给** | 未标 |
| `wal_async_mode_fsync_delay_in_ms` | **文档未提及** | — | — |
| `wal_sync_mode_fsync_delay_in_ms` | **文档未提及** | — | — |

---

## 8. 可测点清单（34 条）

格式：`- [来源] 断言式描述（信号：… → 期望：…）〔类别〕`。类别 ∈ {可稳定构造 / 需白盒 / 不可观测·不可稳定构造}。

### 8.1 A 组：目录与文件组织（可稳定构造，纯黑盒）

- TP-01 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#参数配置] 写入数据并触发 WAL 落盘后，`wal_dirs`（默认 `data/wal`）下应存在 WAL Node 目录且其内有 `.wal` 文件（信号：`ls` 目录树 → 期望：至少 1 个 `^_\d+\.wal$` 文件）〔可稳定构造〕
- TP-02 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#4.1 文件滚动命名] 文件名必须匹配「文件名格式为 _[version_id].wal」（信号：目录列表 → 期望：全部 WAL 文件满足 `^_\d+\.wal$`，无其它后缀）〔可稳定构造〕
- TP-03 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#4.1 文件滚动命名] `version_id` 应从 0 开始递增（信号：同一 WAL Node 目录内 version_id 排序 → 期望：最小值 0 且无重复、无回退）〔可稳定构造〕
- TP-04 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#6.2 检查点文件] 每个 WAL Node 目录「同一时刻只有一个检查点文件」（信号：`^_\d+\.checkpoint$` 计数 → 期望：== 1）〔可稳定构造〕
- TP-05 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#6.2 检查点文件] 检查点文件名须匹配「_[version_id].checkpoint，其中 version_id 从 0 开始递增」（信号：多次滚动后文件名集合 → 期望：正则匹配且 version_id 递增）〔可稳定构造〕
- TP-06 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#4.1 文件滚动命名 + #参数配置] 热加载把 `wal_file_size_threshold_in_byte` 调到远小于写入量后持续写入，应产生多个 WAL 文件（信号：`.wal` 文件数 → 期望：单调增加，出现 `_N.wal` 与 `_N+1.wal` 并存）〔可稳定构造〕
- TP-07 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#概述 + #WAL Node 分配策略] 「IoTConsensus 中，每个 DataRegion 拥有一个 WAL Node」，且分配策略语义为 Elastic（每 node 默认 4 个 unique id）/ RoundRobin（定 node 数后轮转）/ FirstCreate（每 unique id 一 node，MultiLeader 强制）（信号：库数/DataRegion 数与 WAL Node 目录数 → 期望：与所选策略一致；**目录命名规则与策略选择配置项文档未提及，须现场标定**）〔可稳定构造，判据需现场标定〕
- TP-08 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#参数配置] `wal_dirs` 配多个目录（逗号分隔）时应写入多个目录（信号：各目录下 `.wal` 分布 → 期望：多目录均有 WAL；**分配策略文档未提及**，只断言"都非空"）〔可稳定构造，弱断言〕
- TP-09 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#4.2 文件格式] WAL 文件内应含版本串 `MagicString = "WAL-V2"`（信号：`grep -a "WAL-V2"` → 期望：每个 `.wal` 文件命中）〔需白盒/二进制检查〕

### 8.2 B 组：写入与持久化语义

- TP-10 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#参数配置] `wal_mode=SYNC` 时写入成功返回即已刷盘（信号：写入返回后立即 `kill -9` 再重启 → 期望：数据可查，不丢）〔可稳定构造〕
- TP-11 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#参数配置] `wal_mode=ASYNC` 时写入返回不等待刷盘（信号：写入返回后立即 `kill -9` 再重启 → 期望：文档**未承诺**不丢数据，只断言"不报错、可恢复出已刷盘部分"）〔可稳定构造，但**不能**断言丢或不丢〕
- TP-12 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#参数配置] `wal_mode=DISABLE` 时关闭 WAL 功能（信号：写入后目录 → 期望：无新增 `.wal`/`.checkpoint` 文件；重启后未落盘数据不可恢复）〔可稳定构造；**流模式限制文档未提及**〕
- TP-13 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#参数配置] `fsync_wal_delay_in_ms` 调大应提高刷盘批量（信号：单文件/单次刷盘写入量 → 期望：批量增大、刷盘次数下降）〔需白盒（需 OS/内核层或插桩统计 fsync/写次数）〕
- TP-14 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#设计细节] 三 Buffer 状态机不变量：任意时刻恰有一个 working（信号：线程 dump / 内部状态 → 期望：working==1，syncing≤1，compressed==1）〔需白盒〕
- TP-15 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#内存控制] WAL 队列总内存超过 `wal_buffer_queue_proportion` 限制时写入线程等待而非 OOM（信号：大请求压测 + 进程 RSS/是否 OOM → 期望：不 OOM，写入变慢）〔可稳定构造（压测），判据为"不 OOM"，属稳定性而非精确值〕
- TP-16 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#测试计划] 「原本会快速OOM的大请求场景运行 1 天+无OOM」（信号：长稳运行日志/RSS → 期望：无 OOM）〔不可稳定构造（1 天+ 长稳）〕
- TP-17 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 压缩 + #参数配置] 开启 `enable_wal_compression` 相比关闭，WAL 目录总大小应显著减小（信号：同负载下 `wal_dirs` 总字节数 A/B → 期望：开启 < 关闭；提示：文档给的量级是「I/O 资源节约 30% 左右」，**不可直接当阈值**）〔可稳定构造（A/B 对照）〕
- TP-18 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#4.2 文件格式] Segment 长度字段规则：`Uncompressed Size`「在压缩类型为不压缩时没有该字段」，未压缩时 `Compressed Size` 兼作压缩前大小（信号：二进制解析 → 期望：按 `Compression Type` 两种长度模型（`1+4+s` / `1+4+4+s`）解析均不越界）〔需白盒〕

### 8.3 C 组：检查点、无效删除与快照

- TP-19 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 检查点及 MemTable 快照] 当某 WAL 文件对应的所有 MemTable 都已刷盘后，该 WAL 文件应可被删除（信号：目录内 `.wal` 文件消失 → 期望：刷盘 + 等过 `delete_wal_files_period_in_ms` 后文件数不增、旧 version_id 文件被清）〔可稳定构造〕
- TP-20 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#6.3.1 常规整理] 删除规则应为「删除 version_id 小于 min(各 MemTable 首个 WAL 文件 version_id) 的所有 WAL 文件」（信号：目录内文件 version_id 集合 → 期望：保留下来的文件 version_id ≥ min；**min 需白盒从 checkpoint 读取**）〔部分可稳定构造，判据需白盒〕
- TP-21 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#参数配置] `delete_wal_files_period_in_ms` 热加载生效：调小后无效 WAL 文件更快被删、调大后删除变慢（信号：从"全部刷盘"到"文件消失"的时间差 → 期望：与配置值同向变化）〔可稳定构造〕
- TP-22 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 文件没法被删除的原因] MemTable 未刷盘时其 WAL 文件不得被删除（信号：抑制刷盘 + 目录文件数 → 期望：文件始终保留）〔可稳定构造（抑制刷盘手段需现场标定）〕
- TP-23 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 文件没法被删除的原因] 被 pipe 模块 pin 住（`pinCount > 0`）时 WAL 文件不得被删除（信号：`MemTableInfo.pinCount` → 期望：pin 期间文件保留）〔需白盒〕
- TP-24 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 文件没法被删除的原因] 已刷盘但未被 IoTConsensus 消费完（`endFileIndex < filesToDelete.length`）时 WAL 文件不得被删除（信号：`endFileIndex`/`safeIndex`/`searchIndex` → 期望：文件保留至消费完成）〔需白盒〕
- TP-25 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#MemTable 快照] MemTable 大小 < `wal_memtable_snapshot_threshold_in_byte` 时应在 WAL 文件内做快照，快照后该 MemTable 占用的 WAL version_id 跳到最新（信号：目录内旧 version_id 文件被删、且**不新增 TsFile** → 期望：WAL 文件数下降而 TsFile 数不变）〔可稳定构造（目录层面），"是否真为快照"需白盒确认 `Type=0x03`〕
- TP-26 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#MemTable 快照 + #参数配置] MemTable 大小 ≥ 阈值或累计快照数 ≥ `max_wal_memtable_snapshot_num` 时应改为刷盘（信号：出现新 TsFile → 期望：TsFile 数 +1）；**口径矛盾须先标定**：参数表写"大于该阈值/超过该次数"、章节写"≥"，且 `wal_min_effective_info_ratio` 有"<"与"≤"两种写法、默认 `max_wal_memtable_snapshot_num=1` 时"首次即刷盘 vs 允许 1 次快照"不确定〔可稳定构造，触发条件难精确控制〕
- TP-27 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#MemTable 快照] 快照过程中 MemTable 不可修改（信号：并发写入延迟/是否报错 → 期望：文档只说"不可修改"，**未说写入是阻塞还是报错**，故只能断言"不丢数据、最终一致"）〔不可观测（语义未定义到可断言程度）〕
- TP-28 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#检查点类型] 三种检查点（`0x00` 全局信息 / `0x01` 新建 / `0x02` 刷盘）应分别由"新建检查点文件 / MemTable 新建 / MemTable 刷盘"触发（信号：解析 checkpoint 文件的 `Type` 字节序列 → 期望：三类都能出现且顺序符合"全局在新建检查点文件时写入"）〔需白盒〕

### 8.4 D 组：重启恢复与规模/长稳

- TP-29 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 重启恢复 + WAL 预写日志.md#1.1. 简介] 未刷盘数据在重启后应被重放并可查（信号：写入（未刷盘）→ 重启 → `SELECT` → 期望：数据存在）〔可稳定构造〕
- TP-30 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 重启恢复 + #概述] 恢复流程末步为「删除 WAL Node 下的所有文件」，且恢复粒度为 WAL Node、「恢复后直接将这些 MemTable 刷盘」（信号：重启完成后 WAL Node 目录内旧 `.wal`/`.checkpoint` 消失且出现新 TsFile → 期望：WAL 清空、数据已落 TsFile；**该步与"恢复成功"的因果关系文档未声明**）〔可稳定构造〕
- TP-31 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 重启恢复] 恢复前应先确认「各个时间分区下的 0 层未封口的 TsFile」（信号：存在未封口 TsFile 时重启 → 期望：恢复成功、不报错；**具体判定信号文档未给**）〔不可观测（无日志/指标信号）〕
- TP-32 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 文件总大小限制] WAL 总大小达 `iot_consensus_throttle_threshold_in_byte` 时：IoTConsensus 导致则「将阻止客户端写入」，非 IoTConsensus 导致则由 WAL 删除线程按有效信息比例做快照/刷盘且「不会影响写入线程」（信号：写入成功率 + WAL 总量 → 期望：前者写入被拒、后者写入不阻塞且总量回落）〔不可稳定构造（需精确制造共识落后/堆积）〕
- TP-33 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 对 IoTConsensus / Pipe 的支持] IoTConsensus Queue 入队条件为 Leader & 条目 ≤ 4096 & IoTConsensus 内存 < 60%（信号：队列长度/内存占比 → 期望：不超过约束）〔需白盒〕
- TP-34 [V1.1.0.1-存储模块-写前日志-写前日志-技术设计.md#WAL 相关线程] 线程数与 WAL Node 数一致：「WAL-Serialize / WAL-Sync 和 WAL Node 的个数相等」「WAL-Delete：1 个」「WAL-Recover…与 WAL Node 文件夹的数目相同」（信号：jstack 中的线程名与计数 → 期望：Serialize/Sync == Node 数，Delete == 1，Recover 仅恢复期存在）〔需白盒（jstack）〕

> 计数说明：共 **34 条**，其中**可稳定构造 21 条**（TP-01~08、10~12、15、17、19~22、25、26、29、30）、**需白盒 9 条**（TP-09、13、14、18、23、24、28、33、34）、**不可观测/不可稳定构造 4 条**（TP-16、27、31、32）。写 skill 时建议先落地可稳定构造组，白盒组作为二期。

---

## 9. 文档未提及清单（按对测试设计的影响排序）

### 9.1 影响最大的 3 项

1. **完全没有日志关键字/日志级别，也没有 metrics 指标名**（§6.1、§6.2）。
   三份文档无任何 INFO/WARN/ERROR 文本、无指标名（唯一的监控项名字在 `image.png` 图片里）。→ WAL skill **无法**基于文档写日志/指标断言；必须先到真实环境采样（日志采样 + `:9092/metrics` 或监控面板）建立基线，否则只能靠"目录/文件 + 端到端数据正确性"这类黑盒判据。
2. **`wal_async_mode_fsync_delay_in_ms` / `wal_sync_mode_fsync_delay_in_ms` 未提及**（§4.2）。
   文档只有单一参数 `fsync_wal_delay_in_ms`（默认 1500ms，热加载，语义绑定 `wal_buffer_size_in_byte` 的 95%）。→ 两模式各自的 fsync 延迟默认值与差异**无文档依据**；写参数用例前必须核对产品 `iotdb-system.properties`。
3. **WAL 目录/文件的完整命名规则与 WAL Node ↔ DataRegion/时间分区的映射未给出**（§2.3）。
   只有「每个 WAL Node 代表一个 WAL 目录」+「文件名格式为 `_[version_id].wal`」，**没有** `<wal_dir>/<nodeId>/<regionId>/…` 这类路径模式，也没说目录名怎么起、多 `wal_dirs` 如何分配。→ 所有目录级断言的第一步（定位目录）必须先现场标定。

### 9.2 其余"文档未提及"项

- **IoTConsensusV2**：完全未提及（只有 IoTConsensus / RatisConsensus / SimpleConsensus / MultiLeader）。
- **「流模式下不允许 DISABLE」**：未提及；`DISABLE` 只写了「关闭 WAL 功能」，未写任何模式限制或副作用。
- **单机 vs 分布式差异**：未提及（只有按共识协议的区分）。
- **SQL / 命令**：未提及（无 `flush`、无 `SHOW ...`、无 `checkpoint` 语句、无 `SET CONFIGURATION` 示例）。
- **"恢复完成"的判定信号**：未提及（只列了流程步骤与代价符号）。
- **WAL Node 分配策略的选择配置项名**：未提及（只给策略英文名与语义）。
- **`wal_buffer_queue_proportion` 之外的内存总量上限计算式**：未提及（只说"设置的最大值"，未说该最大值如何由 MemTable 内存算出）。
- **`enable_wal_compression` 与 `iot_consensus_throttle_threshold_in_byte` 的默认值**：未给出。
- **加密开关的参数名/默认值/算法**：未提及（只说"开启加密"，并称算法与密钥同 TsFile，且自查表写「加密算法是否符合安全标准？ 否」）。
- **WAL 文件加密后的**文件格式是否变化（头部/Metadata 是否也加密）：未提及。
- **`Set<Long> memTablesId` 与正文 `MemTableIds/MemTableSetSize` 的对应关系**：仅由字段名推断（`技术设计.md#概述` 写 `Set<Long> memTablesId`，`#4.2 文件格式` 写 `MemTableIds：8 * q 个字节`）——**不确定**是否为同一物。
- **Pipe Queue 的入队/出队时机**：`WAL 预写日志.md#WAL 对 IoTConsensus / Pipe 的支持` 明确留空（「【补充需求】」+ 空行）。
- **图内细节未提取**：`image.png`（Benchmark 配置、WritePerformance 监控项）、`image4.png`（文件滚动）、`image5.png`（文件格式）、`image7.png`（Buffer 状态切换）、`image8.png`（检查点操作）、`image10.png`（WAL 文件整理理想情况）、`image11.png`（非理想情况）、`image12.png`（WAL-删除线程）、`image13.png`（WAL 对 IoTConsensus/Pipe）、`image1.png`/`image2.png`/`image3.png`/`image6.png`/`image9.png`（类图/时序图）、`img_v3_02hd_*.jpg`（OOM 测试结果）。
- **WAL 的**多时间分区 / 多 TsFile 与 checkpoint `TsFilePath` 的一对多关系：未明确（`MemtableEntry` 只有单个 `TsFilePath` 字段）。

### 9.3 三份文档之间的差异（需在 skill 里注意口径）

| 差异点 | `V1.1.0.1-…-技术设计.md` | `WAL 预写日志.md` / `写前日志.md` |
| --- | --- | --- |
| 加密 | 写入流程**无**加密步骤（`#写入流程` 只到压缩）；仅有安全自查表 | 写入流程含「如果系统开启加密，还将对 Compressed Buffer 进行加密…」与 `t_encrypt`；恢复含 `t_decrypt`；`#1.4 数据安全` 专门一节 |
| 内存控制 | 有 `#内存控制`：`MemoryControlledWALEntryQueue` 全文 + `wal_buffer_queue_proportion` | **无**（无该参数、无该类） |
| 压缩算法 | 有 `#WAL 压缩`：说明段选择 LZ4 | 无 LZ4 说明（仅 `Compressed Entries` 段的加密补充） |
| 测试计划 | 有 `#测试计划`（1 天+无 OOM、Atmos、压缩 30%） | 无 |
| 背景/简介 | `设计背景`/`设计目标`（引 1.0.0.1 需求分析 + 实验数据） | `1.1 简介 / 1.2 检查点 / 1.3 性能考量 / 1.4 数据安全` + `相关资料`（论文/设计链接） |
| Buffer 拼写 | `Working Buffer` | `写前日志.md` 写作 `Wokring Buffer`（错别字） |
| 共识日志 | `#WAL 对 IoTConsensus / Pipe 的支持` 有 IoTConsensus Queue 时机 + DataRegionStateMachine 流程 | 多一个 `Pipe Queue【补充需求】`（内容为空） |

**共同点（三份一致，可放心引用）**：概述 6 条、关键类、4 个线程、参数配置 13 项（技术设计多 `wal_buffer_queue_proportion`）、文件滚动命名、WAL Entry/Metadata/Segment/CheckpointEdit 格式、写入流程与三 Buffer、检查点三类型与检查点文件、WAL 文件整理与快照、总大小限制、没法删除的原因、重启恢复流程、WAL Node 分配策略。

---

## 10. 给 WAL skill 的直接建议（基于以上缺口）

1. **优先建"目录/文件"观测层**：先在真实环境确认 WAL Node 目录命名、多 `wal_dirs` 分配、`.wal`/`.checkpoint` 生成时机，把 §6.3 的规律补成可判定的现场基线（文档缺口 9.1-3）。
2. **日志与指标必须现场采样**：文档零日志、零指标名；采样后再回填断言，避免把"文档没写的日志"当成断言。
3. **端到端数据正确性作为核心判据**：写入 →（不刷盘）kill -9 → 重启 → 查询（TP-29），这是不依赖日志/白盒的最强黑盒判据。
4. **参数用例先做语义标定再固化断言**：`wal_min_effective_info_ratio`（< vs ≤）、`max_wal_memtable_snapshot_num=1`（首次即刷盘 vs 允许 1 次）、`wal_memtable_snapshot_threshold_in_byte`（> vs ≥）三处文档自相矛盾（§5.3、TP-26）。
5. **白盒组后置**：三 Buffer 状态、`pinCount`、`endFileIndex/safeIndex/searchIndex`、checkpoint `Type` 字节、Segment 条件长度字段——都需要解析 WAL/checkpoint 或 jstack，建议二期用只读 agent 或离线解析工具做。
