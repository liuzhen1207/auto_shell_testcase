# WAL 相关需求结构化抽取（写 WAL 测试 skill 的依据）

来源文档（仅这三份，UTF-8 markdown，纯只读）：

| 简称 | 文件 |
| --- | --- |
| 压缩 | `WAL 压缩功能设计.md` |
| 队列 | `WAL 队列内存控制.md` |
| OBJECT | `V2.0.8.1-存储模块-写前日志-新增 OBJECT 类型一期-需求分析.md` |

引用格式 `文件名#章节`，章节名取自文档内的标题原文（该三份 markdown 由飞书导出，标题层级已被压平成同级行）。
所有数字一律照抄原文；文档没写的写"**文档未提及**"，不做推断、不补数字。

---

## A. WAL 压缩

### A.1 基线（未压缩时的 WAL 形态，压缩的改动面）

- WAL 的基本单位是 WALBuffer，每个 WALBuffer 都包含两个 ByteBuffer：一个是 Working Buffer，一个是空闲或者 Syncing Buffer；两个 Buffer 轮流工作以提高 WAL 的工作效率。（`WAL 压缩功能设计.md#背景`）
- 每个 Buffer 的大小默认是 **16MB**（参数 **walBufferSize**）；每个 Buffer 写满了或者在内存中驻留时间过长（默认超过 **1s**，参数 **walAsyncModeFsyncDelayInMs**）就会触发 Buffer 的刷盘。（`WAL 压缩功能设计.md#背景`）
- 每个 Buffer 落盘以后会检查当前 WAL 文件的大小，如果超过了一定大小（默认 **30MB**，参数 **walFileSizeThresholdInByte**）就会封口当前 WAL 文件，然后切换到下一个 WAL 文件。（`WAL 压缩功能设计.md#背景`）
- 目前的 WAL 是**没有压缩**的：每个写入请求对应的 WALEntry 按照一定的格式序列化到 WALBuffer 中，然后 WALBuffer 在刷盘时也原封不动地将数据写入到磁盘中。（`WAL 压缩功能设计.md#背景`）

### A.2 是否默认开启 / 配置项名与取值 / 压缩粒度

- 新增参数：**`ENABLE_WAL_COMPRESSION=true/false`**（原文即大写），**默认为 true**，**允许热加载**。（`WAL 压缩功能设计.md#新增参数`）
  - 文档在参数名下方留有占位句"（写一写开启之后对系统性能的影响）"，即**开启后的性能影响文档未给出**。（`WAL 压缩功能设计.md#新增参数`）
- 算法 / 级别：**文档未定稿**。文中只说明"上图中的实验结果是使用 **GZip** 算法进行压缩的，我们可以测试多种压缩算法，选择效率最高的"，以及"通过选择合适的压缩算法（**GZIP、LZ4、ZSTD** 等）也可以获得不错的压缩率"。（`WAL 压缩功能设计.md#需要确定的内容`、`#WAL 压缩设计概述`）
  - 压缩级别（level）**文档未提及**。
- 压缩粒度：文档给出三种候选思路，并明确"目前我倾向于使用第二种方案"。（`WAL 压缩功能设计.md#WAL 压缩设计概述`）
  1. **基于 WALEntry 做压缩**：每个 WALEntry 在序列化时按自己的特点压缩（如时间列 Gorilla 编码），压缩率最高，但需改每种 WALEntry 的序列化逻辑，工作量较大。
  2. **基于 Buffer 做压缩（倾向方案）**：每个 WALBuffer 在刷盘之前都进行压缩；"在这种方式下一个 WAL 文件中可能就包含多个段，每个段都是压缩和解压缩的基本单位"；WALEntry 序列化/反序列化、IoT Consensus、Pipe 相关逻辑都无需修改；缺点是无法实现最高压缩率。
  3. **基于文件做压缩**：WAL 文件封口时整文件压缩，读取前整文件解压；压缩率可能更大，但每次压缩/解压都要把整个文件读进内存，可能对内存压力较大。
  - 即：**粒度不是整文件、也不是每个 entry，而是每个 WALBuffer / 每个段**（按倾向方案二）。**方案未最终定稿**（"目前我倾向于"）。
  - payload 级压缩 **文档未提及**（payload 级是竞品 InfluxDB 3.0 的描述）。

### A.3 预期收益（压缩率、磁盘占用）

- 预期效果："节约 IoTDB 的 I/O 资源"；在 Benchmark 配置如下时：**设备数=100000、序列数=10、写入请求大小=1000、每个设备写入的行数=1**，使用**单 HDD** 作为存储盘的情况下，**可以将 I/O 资源节约 30% 左右**。（`WAL 压缩功能设计.md#预期效果`）
- I/O 占比实测（背景实验，**未压缩现状**）：在一个使用 IoTBenchmark 的写入实验中，使用 **InsertTablets 和 InsertRecords 接口分别写入 20 分钟**，然后统计 WAL 的总大小和 TsFile 的总大小；假设以 I/O 吞吐量为磁盘资源使用的指标，**写入 WAL 在 InsertTablets 和 InsertRecords 中分别占据了 67% 和 88% 的磁盘使用量**。（`WAL 压缩功能设计.md#WAL 对 I/O 资源的影响`）
- 该实验还未考虑读取 WAL 的开销："在系统恢复和 IoT Consensus 传输数据时，也可能需要从磁盘上读取 WAL。特别是 IoTDB 在 WAL 堆积导致系统同步变慢时，减小 WAL 的大小可以加速系统恢复正常的速度。"（`WAL 压缩功能设计.md#WAL 对 I/O 资源的影响`）
- **具体压缩率数字：文档未给出**（只有"节约 I/O 资源 30% 左右"这一个数字，且是 I/O 资源而非压缩率）。磁盘占用绝对值 **文档未提及**。

### A.4 对写入/查询性能的影响

- 文档在 `#新增参数` 处留了"（写一写开启之后对系统性能的影响）"占位，**实测数字文档未给出**。
- `#需要确定的内容` 中列了一条待定项："**WAL 压缩对数据库恢复速度的影响**：测试加入压缩以后数据库恢复的速度在不同 WAL 量下的变化情况。"——即**恢复速度影响的数字文档未给出**。
- 查询路径影响 **文档未提及**（该文档只讨论 WAL 写/读与恢复、IoT Consensus、Pipe）。

### A.5 与恢复/重放的关系、兼容性

- 恢复关系：系统恢复和 IoT Consensus 传输数据时可能需要从磁盘上读取 WAL；减小 WAL 大小可加速系统在 WAL 堆积、同步变慢时的恢复。（`WAL 压缩功能设计.md#WAL 对 I/O 资源的影响`）
- 兼容性（核心风险点）："增加压缩以后，WAL 的格式会有所变化，用户升级时我们需要保证兼容性。由于 IoTDB 目前 **WAL 内容中没有版本号这个标识**，我们无法知道恢复时读取的 WAL 是增加压缩功能之后的还是增加压缩功能之前的。我们可以通过尝试的方法，**先尝试将数据解压缩，如果解压缩失败，再按照未压缩的方式进行读取**。"（`WAL 压缩功能设计.md#需要确定的内容`）
  - 即：**旧版本 wal 能否被新版本读 → 依赖"先试解压、失败按未压缩读"的兜底策略，文档把它列为"需要确定的内容"（未定稿）**。
  - 压缩与未压缩 WAL 能否共存（同目录/同文件混合）：**文档未提及**（"允许压缩和未压缩的 WAL 同时存在"是竞品 Prometheus 的描述，不是 IoTDB 自身的结论）。（`WAL 压缩功能设计.md#Prometheus`）
- 竞品参考（仅作设计依据，不是 IoTDB 行为）：
  - Prometheus 默认开启了 WAL 压缩，使用 **Snappy** 算法，并且**会在 WAL 中通过标志符记录 WAL 是否被压缩过，允许压缩和未压缩的 WAL 同时存在**。（`WAL 压缩功能设计.md#Prometheus`）
  - Cassandra 支持对 WAL 进行压缩，由参数 **commitlog_compression** 控制，**默认不压缩**，支持配置成 **LZ4、Snappy、Deflate 和 ZSTD**。（`WAL 压缩功能设计.md#Cassandra`）
  - InfluxDB 2.0 压缩的基本单位是**一个 WALEntry**，压缩之后的每个 Entry 遵循 **TLV** 规则，使用 **1 个字节表示 Entry 类型，4 个字节标识压缩后 entry 的长度**，然后是 entry 压缩后的内容。（`WAL 压缩功能设计.md#InfluxDB`）
  - InfluxDB 3.0 的 WAL **Payload 部分会先压缩以后再写入到磁盘上**。（`WAL 压缩功能设计.md#InfluxDB`）
  - TDEngine：未发现有跟压缩相关的内容；WAL 分为 MNode 的 WAL（记录 DDL）与 VNode 的 WAL（记录 DML）；允许用户暂时关闭实例、跑 WAL 压缩服务、再重启实例；对占据 WAL 写入量大部分的 DML WAL 没有压缩。（`WAL 压缩功能设计.md#TDEngine`）

### A.6 可观测信号（压缩）

- **目录 / 文件大小**：文档未给出压缩后 WAL 目录、WAL 文件命名、文件大小变化的具体观测约定；只给了参数 **walFileSizeThresholdInByte（默认 30MB）** 作为 WAL 封口阈值，可作为"WAL 文件大小"观测的基线。（`WAL 压缩功能设计.md#背景`）
- **日志关键字**：**文档未提及**（无任何 WAL 压缩相关日志文案）。
- **metrics**：**文档未提及**（无 WAL 压缩相关监控面板/指标）。
- 可用的间接信号：WAL 总大小 vs TsFile 总大小之比（文档实验的统计口径）、以及"读 WAL 导致恢复/同步变慢"的耗时。（`WAL 压缩功能设计.md#WAL 对 I/O 资源的影响`）

---

## B. WAL 队列内存控制

### B.1 问题背景（OOM 复现配置与结论）

- 问题单：**TIMECHODB-1116**。环境：**IoTDB 1C1D、DN 堆内存 12G**；Benchmark：**1 database、1 table、1w sensor、100 device、100 batchsize**；**运行 2~4 小时后，DN 出现 OOM**。（`WAL 队列内存控制.md#问题背景`）
- 分析结论：通过分析 dump 文件发现是 **WALBuffer 阻塞队列中积攒的 insertNode 太大导致的 OOM**。（`WAL 队列内存控制.md#分析`）

### B.2 队列结构

- 队列归属：WAL Buffer 内部的阻塞队列；文档描述的处理链路是（`WAL 队列内存控制.md#分析`、`#方案`）：
  1. 写入线程将写入的 InsertNode 包装为 WAL Entry 提交给 **WAL Node**；
  2. WAL Node 将 WAL Entry 传递到 **WAL Buffer** 放入阻塞队列；
  3. WAL 序列化线程从队列中取出 WAL Entry，进行 WAL 的序列化。
- 即队列粒度是**每个 WALBuffer 一个队列**；全局限额是"**当前所有 WAL 队列的总内存大小**"（SystemInfo 中统计）。（`WAL 队列内存控制.md#方案`）
- 是否按 WALNode 或按 region 分队列 / 队列个数：**文档未提及**（文档只说"WAL Node 将 WAL Entry 传递到 WAL Buffer"，未说明 WALNode 与 region 的对应关系）。
- 旧实现：**v1.3.4 版本前**，WALBuffer 中是一个 **ArrayBlockingQueue**，当队列中的 WALEntry 个数超过设置的最大大小（**默认为 500**）时，写入线程放入队列时会进行等待，直到 WAL 序列化线程消费掉队列中的部分 WALEntry 后，写入线程会继续。（`WAL 队列内存控制.md#分析`）
- 旧实现的缺陷（**OOM 直接原因**）：由于 ArrayBlockingQueue 是**使用元素个数进行大小控制**的，当写入请求较大、WAL 所在的磁盘存在性能瓶颈、消费速度较低时，这个阻塞队列的内存大小没有受到控制。dump 中显示 **ArrayBlockingQueue 中存在 339 个 InsertNode，未达到 500 的最大数量，但是这些 InsertNode 中的 Binary 类型数据点的总内存大小就超过了 4GB**。（`WAL 队列内存控制.md#分析`）

### B.3 新实现（MemoryControlledWALEntryQueue）与内存上限

- 将 WALBuffer 中的 ArrayBlockingQueue 换成自己实现的 **MemoryControlledWALEntryQueue**，它是在 **LinkedBlockingQueue** 上进行封装，在队列的**放入和取出方法上进行内存的统计和控制**。（`WAL 队列内存控制.md#方案`）
- 入队流程：放入队列时，**首先计算这个 WAL Entry 的内存大小**（`getElementSize` 使用 **InsertNodeMemoryEstimator** 进行 insertNode 的内存计算，实际调用 `walEntry.getMemorySize()`），然后**获取 SystemInfo 中统计的当前所有 WAL 队列的总内存大小，如果总内存大小超过设置的最大值则进行等待**；当总内存小于最大值时，将 WAL Entry 放入内部队列中，之后向 SystemInfo 中报告新增的内存大小。（`WAL 队列内存控制.md#方案`）
- 出队流程：WAL 序列化线程从 MemoryControlledWALEntryQueue 取出 WAL Entry；从内部队列中拿出 WAL Entry，向 SystemInfo 中报告减少的 WAL Entry 占用内存大小（`updateWalQueueMemoryCost(-getElementSize(e))`），并在 `synchronized (nonFullCondition) { nonFullCondition.notifyAll(); }` 中唤醒等待中的写入线程。（`WAL 队列内存控制.md#方案`）
- 并发控制要点（原文注释）："使用一个全局 Object 进行并发控制，否则多个队列发生阻写时写入线程有可能不会被唤醒"；`nonFullCondition` 是 `private static final Object`。（`WAL 队列内存控制.md#方案`）

### B.4 内存上限相关配置项与默认值

- **`wal_buffer_queue_capacity` 改为 `wal_buffer_queue_proportion`**："原本基于队列元素个数进行控制的方法难以做到精确的内存控制，现改为通过内存比例进行控制，**这个比例的默认值目前为 memtable 内存的 10%（reject 阈值剩余部分的一半）**。"（`WAL 队列内存控制.md#配置参数改动`）
- **2.0 版本中新增 `deletion_ahead_log_buffer_queue_capacity` 参数**："目前代码 IoTV2 中有一个 PageCacheDeleteBuffer 队列是复用 wal_buffer_queue_capacity 来控制大小的，为了不影响 iotv2 的功能，新加这样一个参数来保证这个队列大小可以被调整。**V1.3 无此功能。**"（`WAL 队列内存控制.md#配置参数改动`）
- 内存上限的**绝对字节阈值（byte 单位的 max 值）**：**文档未提及**（只给了"memtable 内存的 10%"这一比例口径）。
- `deletion_ahead_log_buffer_queue_capacity` 的默认值 / 单位：**文档未提及**（正文与图片均未给出数值）。
- `wal_throttle_threshold_in_byte`：**文档未提及**（三份文档全文均无该参数名，也无"threshold""字节阈值"的等价语义描述）。相关度最高的一句是"如果总内存大小超过设置的最大值则进行等待"，但文档没有给出该"最大值"的参数名与取值。（`WAL 队列内存控制.md#方案`）

### B.5 背压 / 阻写（throttle）机制

- 触发条件：放入队列时计算该 WAL Entry 的内存大小后，若"SystemInfo 中统计的当前所有 WAL 队列的总内存大小"会超过设置的最大值（`while (SystemInfo.getInstance().cannotReserveMemoryForWalEntry(elementSize))`）。（`WAL 队列内存控制.md#方案`）
- 触发后表现：**阻塞写入线程**（`nonFullCondition.wait()` 放锁等待），**不是报错、不是拒绝、文档未提及"变慢"以外的降级行为**。（`WAL 队列内存控制.md#方案`）
- 恢复条件：消费线程从队列取出 WAL Entry 并报告减少内存后 `notifyAll()`，写入线程被唤醒并**再次判断 wal 队列总内存是否达到最大值**；未达到则 `queue.put(e)` 并 `updateWalQueueMemoryCost(elementSize)` 继续写入。（`WAL 队列内存控制.md#方案`）
- 阻写是否有超时 / 是否可能死锁 / 是否影响 flush：**文档未提及**。

### B.6 内存溢出的防护设计与可观测信号

- 防护设计：把"按元素个数控制"改为"**按所有 WAL 队列的总内存大小控制**"，入队前预占、出队后释放，配合全局 `nonFullCondition` 唤醒，保证队列内存受控。（`WAL 队列内存控制.md#分析`、`#方案`）
- OOM 风险点（文档明确的）：① 按个数控制的 ArrayBlockingQueue 在"写入请求大 + WAL 盘消费慢"时内存不受控（dump 证据：339 个 InsertNode / 超 4GB）；② 多队列同时阻写时若不用全局锁，写入线程可能不会被唤醒。（`WAL 队列内存控制.md#分析`、`#方案`）
- 有效性的验证结论：**原本会快速 OOM 的场景运行 1 天+ 无 OOM**；**手动 Atmos 测试未发现明显的性能影响**。（`WAL 队列内存控制.md#测试验证`）
- **可观测信号（metrics）**：**"Write Performance 中新增 wal 队列内存大小监控面板"**——文档只给了面板位置（Write Performance），**具体 metric 名 / 导出格式 / Prometheus 指标名文档未提及**。（`WAL 队列内存控制.md#可观测性`）
- **日志关键字**：**文档未提及**（无阻写告警、无 WAL 队列内存相关日志文案）。
- 可用的间接判据（文档口径）：DN 是否 OOM（`OutOfMemoryError`）、堆内 WALBuffer 队列对象数与内存占用（需 dump / 白盒，文档中的证据即为 dump）。（`WAL 队列内存控制.md#问题背景`、`#分析`）

---

## C. OBJECT 类型一期

### C.1 OBJECT 数据的写入/导入路径与 WAL 记录内容

- 功能定义：系统内新增 OBJECT 数据类型，用于存储大对象；不同于 BLOB，"BLOB 类型的二进制数据会被存储在 TsFile 中，而 **OBJECT 数据类型的二进制数据会单独存储，TsFile 中只记录一个指向真实存储位置的引用**"；查询时 BLOB 默认返回真实二进制，OBJECT 仅返回一个引用以及二进制的大小，需用 **READ_OBJECT** 函数读真实内容。（`V2.0.8.1-存储模块-写前日志-新增 OBJECT 类型一期-需求分析.md#功能描述`）
- **WAL 记录内容（本需求的核心差异）**：OBJECT 的写放大说明中明确写"**Wal 中仅存储引用**"；而 BLOB 是"Wal 中直接存储二进制内容（第一遍磁盘写 IO）"。需求来源论证中也写"BLOB 类型的数据会先在 wal 中存储一遍，再在 flush 时写入 tsfile，造成两次磁盘写入"。（`…需求分析.md#功能描述`、`#客户使用场景调研`）
- OBJECT 完整写入链路（原文四条）：**二进制内容单独落盘存储（一次磁盘写 IO）→ Wal 中仅存储引用 → Flush 时在 tsfile 中存储引用 → 合并时对多个 tsfile 进行合并，也仅重写引用**。（`…需求分析.md#功能描述`）
- 真实文件存储路径：**`${data_dir}/object_data`**。（`…需求分析.md#存储`）
- 引用/路径格式（决定文件落盘位置）：
  - 默认（`restrict_object_limit=false`）：基于 **Base32（RFC 4648）** 对路径编码，"编码结果只包含 A-Z 和 2-7"，真实存储路径为 **`${dataregionid}/${B32(tablename)}/${B32(tag1)}/${B32(tag2)}/.../${B32(field)}/${timestamp}.bin`**。（`…需求分析.md#限制`、`#附录：历史内容及讨论记录`）
  - `restrict_object_limit=true` 时不再编码，路径为 **`${dataregionid}/${tablename}/${tag1}/${tag2}/.../${field}/${timestamp}.bin`**。（`…需求分析.md#限制`）
  - **每个 OBJECT 数据点都会在磁盘上生成一个对应文件**（文件数量一节）。（`…需求分析.md#功能描述`）
- 分片写入：
  - SQL：`to_object(isEOF, offset, content)`；参数 `isEOF`（true/false，本次写入内容是否为 Object 的最后一部分）、`offset`（int64，本次写入内容在 Object 中的起始偏移量）、`content`（十六进制(hex)格式）。（`…需求分析.md#SQL 写入`）
  - Java SDK：`iTableSession.insert(Tablet tablet);` + `void addValue(int rowIndex, int columnIndex, boolean isEOF, long offset, byte[] content)`（`Tablet` 中数据类型为 `TSDataType.Object` 时使用）。（`…需求分析.md#Java SDK`）
  - 分段示例（SQL）：总大小 **5 字节**，分成 **2、2、1** 三段：`to_object(false, 0, X'696F')` / `to_object(false, 2, X'7464')` / `to_object(true, 4, X'62')`。（`…需求分析.md#SQL 写入`）
  - 分段示例（Java SDK）：总大小 **100 字节**，分成 **40、40、20** 三段。（`…需求分析.md#Java SDK`）
  - 注意（原文三条）：① 如果某个 Object 值只写入了部分片段，**查询该 Object 值时会显示 null，只有写入完全后才能查询到数据**；② 分段写入时，**如果本次写入的 offset 不等于已写入的 Object 大小，本次写入报错**；③ 如果已写入了部分数据，**本次写入的 offset 为 0，本次写入会清除之前已写入的数据部分，重新写入新的数据**。（`…需求分析.md#SQL 写入`）
  - Java SDK 注意：**需要确保分段的多个 byte[] 总长度与原始 Object 大小相等，否则会导致写入的数据大小不正确**。（`…需求分析.md#Java SDK`）
- **校验和：文档未提及**（三份文档都没有 OBJECT 内容的 checksum/校验和/CRC 描述；也没有 WAL Entry 的校验和描述）。
- 单个对象大小限制：**`max_object_file_size_in_byte`：默认值为 4 GB，该配置参数支持热加载**；该配置项**仅由 SYSTEM 权限的人可改**。（`…需求分析.md#单个对象大小限制`、`#访问控制`）
- 多盘策略："数据文件配置的多盘对 OBJECT 类型的存储生效"。（`…需求分析.md#多盘策略`）
- 合并与 OBJECT 实体文件：**object 对应的真实文件本身不会参与合并过程，合并仅处理 TSFile 中的引用信息（除非该索引因 TTL 被清理，此时合并也会将对应的 OBJECT 实体文件一并删除）**；乱序写入导致的重复时间戳"无需为 OBJECT 文件做额外处理。因为在写入阶段，新的 OBJECT 数据会直接覆盖旧文件，因此 OBJECT 目录下的文件始终保持最新状态"。（`…需求分析.md#合并`）
- 删除 / TTL：删除数据、数据库、表、列、设备、序列均为"无用户感知的新需求，沿用原有删除语句即可，**OBJECT 的真实存储内容也会随之删除**"；TTL "到期后，OBJECT 的真实存储内容也会随之删除"。（`…需求分析.md#删除`、`#TTL`）
- 导入导出 / LOAD：**"二期评审时，继续补充"**（一期未定义）。关联结论：导入导出时，**无需对 tsfile 文件中的内容做任何修改，只需要将 OBJECT 对象的真实二进制内容，放到与接收端 tsfile 所在 region 相对应的目录下即可**。（`…需求分析.md#导入导出`、`#附录：历史内容及讨论记录`）
- tsfile 中 `${dataregionid}` 的地位（影响迁移/导入的判据）："为了兼容性，tsfile 中 OBJECT 类型存储的路径，依然保留 `${dataregionid}`"；"查询和合并时，在 IoTDB 侧将当前 tsfile 所在的 region 传递到 tsfile 的 PageReader 中，对 decode 出来的值做修正"；"**所以 tsfile 中存储的 OBJECT 对象的引用中的 `${dataregionid}` 是一个无用值**，在 IoTDB 层面每次都会被替换，仅仅是为了兼容性才将其保留"。（`…需求分析.md#附录：历史内容及讨论记录`）

### C.2 一致性要求

- **"写入成功但未落盘时重启是否必须可恢复"：文档未提及**——三份文档都没有把"WAL 成功返回 → 重启后 OBJECT 内容必须可恢复"写成显式需求条目。
- 文档中与该问题最接近的、可引用的表述：
  - OBJECT **Wal 中仅存储引用**、真实内容单独落盘（一次磁盘写 IO）；（`…需求分析.md#功能描述`）
  - 一期共识协议章节只写"**无用户感知的新需求**，对应请求的逻辑实现即可"（IoTV1 / Simple / Ratis），IoTV2 "无用户感知的新需求，Pipe 相关逻辑实现即可"；**"Snapshot 的重新设计见 3.2.11 节"**（该 3.2.11 节在本文档中不存在，见"影响最大的文档未提及"）。（`…需求分析.md#共识协议`）
  - 兼容性要求："需要支持旧版本的升级"、"需要兼容气象局的定制分支的升级"、"气象局线上升级，就是滚动升级"，并给出滚动升级步骤（见 C.5）。（`…需求分析.md#兼容性要求`）
  - 性能要求："读写性能不弱于用户当前的定制版本"。（`…需求分析.md#性能要求`）
- 自查表里的相关条目：完整性——"该功能是否能保证数据在传输、计算和存储过程中不被泄露、篡改或越权访问？" 回答 **"否（三期支持透明加密后支持）"**；审计——"该功能的关键操作是否需要被记录到审计日志中？" **"未单独新增"**。（`…需求分析.md#自查内容`）

### C.3 与普通时序数据 WAL 的差异（原文对照）

| 维度 | OBJECT | BLOB（对照，最接近的既有类型） |
| --- | --- | --- |
| 存储方式 | TsFile 中仅存储真实二进制内容的引用，真实内容存储在另一块磁盘空间中 | TsFile 中直接存储真实二进制内容 |
| 写放大（越低越好） | **低（写放大系数永远为 1）** | **高（写放大系数为 2 + 合并次数）** |
| 空间放大（越低越好） | **低（merge & release on write）**；同一序列多次写入同一时间戳时，真实二进制内容仅会维护一份 | **高（merge on read and release on compact）**；同一序列多次写入同一时间戳时，真实二进制内容会维护多份，依赖合并去做磁盘空间的释放 |
| 查询结果 | 默认仅返回一个引用以及二进制的大小，需 `READ_OBJECT` 读真实内容 | 直接返回真实的二进制内容 |
| 查询效率 | 特定 case 下更高，比如某个 OBJECT **100MB**，通过 UDF 用户可以只读中间的几个字节 | **100 MB** 的 BLOB，用户必须完整从磁盘读取 100 MB 后再处理 |
| 文件数量 | 每个 OBJECT 数据点都会在磁盘上生成一个对应文件，**仅适合存储写入频率不高、但单个二进制值很大的场景，且一般都需要搭配 TTL 使用**，自动清除过期文件 | 存储在 tsfile 里，依靠合并将文件数量降低，**适合存储较小的二进制数据（比如小于 512KB）** |

（来源：`…需求分析.md#功能描述`）

- 与 WAL 直接相关的差异（再强调）：OBJECT "Wal 中仅存储引用"；BLOB "Wal 中直接存储二进制内容（第一遍磁盘写 IO）"。（`…需求分析.md#功能描述`）

### C.4 涉及的命令 / 接口

- DDL：`CREATE TABLE table1(device_id STRING TAG, s1 OBJECT FIELD);`；场景示例另含 `CREATE DATABASE test;` / `USE test;`。（`…需求分析.md#元数据相关`、`#场景示例`）
  - 树模型创建 OBJECT 类型的序列："需要考虑在树模型创建序列或写入自动创建时，是否支持给 OBJECT 类型设定编码和压缩类型——**三期评审时，继续补充**"。（`…需求分析.md#创建 OBJECT 类型的序列`）
  - 一期范围：**表模型**（"一期：完成表模型中对于 OBJECT 类型的增删改查操作"）；树模型整体为三期。（`…需求分析.md#完成计划`）
- 写入：`insert into table1(time, device_id, s1) values(now(), 'tag1', to_object(true, 0, X'696F746462'));`；场景示例 `values(1, 'd1', to_object(true, 0, X'696F746462'))`。（`…需求分析.md#SQL 写入`、`#场景示例`）
- 读取真实内容：`READ_OBJECT(s1)`、`READ_OBJECT(s1, 0, 100)`；必选参数 object（OBJECT），可选 `offset`（long/int64，缺省 **0**，"如果 offset 小于 0，或者大于等于全文件长度，则抛异常"）、`length`（long/int64，缺省为全文件长度，"**当长度大于 2^31 - 1 时，报错**"；"当长度大于从 offset 起的剩余文件长度时，会取从 offset 起的文件内容"；"length 小于 0 时，视为读取 offset 开始 object 剩下的所有数据"）；返回 **BLOB**（对象的二进制内容）。（`…需求分析.md#支持的函数`）
- 其他函数支持矩阵（本期新增标黄，README 级要点）：`LENGTH(s1)` 支持 OBJECT 列，**返回 INT64，对象二进制字节的大小；"注意，原来 LENGTH 返回的是 INT32"**；`CAST/TRY_CAST` **仅支持 OBJECT → STRING，不支持任何类型强转成 OBJECT**；`coalesce`（输入均为 OBJECT，返回 OBJECT）；`IS [NOT] NULL`；**其他函数均不支持 OBJECT 类型**。聚合函数支持：`count`、`first`、`last`、`first_by`、`last_by`。窗口函数支持：`first_value`、`last_value`、`nth_value`、`lead`、`lag`。行模式匹配函数：`RPR_FIRST`、`RPR_LAST`、`PREV`、`NEXT`（**第一个参数**支持 OBJECT）。（`…需求分析.md#支持的函数`）
- 子句支持矩阵：FROM 支持；SELECT 支持含 OBJECT 的表达式；WHERE 支持含 OBJECT 的表达式；HAVING 支持；**MATCH_RECOGNIZE / 表值函数 / WINDOW 的 PARTITION BY 和 ORDER BY 不支持 OBJECT**；**GROUP BY 不支持**；**ORDER BY 不支持**；**OFFSET 不支持**；**LIMIT 不支持**；FILL **只支持 PREVIOUS 填充**。（`…需求分析.md#支持的子句`）
- 集合操作类型兼容性：**OBJECT 与任何其他类型（含 null/INT32/…/BLOB）都是 ❌**，OBJECT 与 OBJECT 兼容（原表为一张大矩阵，行列为数据类型）。（`…需求分析.md#集合操作时的数据类型兼容性`）
- UDF（表模型）：标量 `Object evaluate(Record input)`、聚合 `void addInput(State state, Record input); void remove(State state, Record input);`、表值函数；新增接口 `Record.getObjectFile`（返回 `Optional<File>`，当前节点真实存储路径，未在本节点存储返回 `Optional.empty()`）、`Record.objectLength(int columnIndex)`（long）、`Record.readObject(int columnIndex, long offset, long length)`、`Record.readObject(int columnIndex)`（均 Binary，"当长度大于 2^31 - 1 时，报错"）；`Record.getString` 返回 `(Object) XX.XX KB` 形式字符串。**输出 OBJECT 类型：暂不支持，如果声明了返回 OBJECT 类型，则调用时报错。**树模型 UDF 为三期。（`…需求分析.md#用户自定义函数`）
- 气象局定制标量函数 **GEO_PENETRATE**：参数 1 必填 OBJECT 目标列；参数 2 必填 string，格式 `start1,end1,start2,end2,...,startn,endn`（start/end 成对、双闭区间）；参数 3 选填默认 `'COMPRESSED_TSFILE'`，支持 `'COMPRESSED_TSFILE', 'UNCOMPRESSED_TIFF', 'COMPRESSED_TIFF'`；参数 4 选填默认 `'LZ4'`，支持 `'LZ4', 'UNCOMPRESSED', 'SNAPPY', 'GZIP', 'ZSTD', 'LZMA2'`；返回 **BLOB**（`List<float[]>` 的二进制形式）。**不自动作为内置函数**，需在集群首次启动时执行：`create function geo_penetrate as 'org.apache.iotdb.db.queryengine.plan.relational.function.scalar.GeoPenetrate'`。（`…需求分析.md#用户定制的自定义标量函数`）
- 查询展示：CLI / JDBC `getString` / Java SDK（`Field.getStringValue`、`Field.getObjectValue`、`SessionDataSet.DataIterator.getObject/getString/getBlob`）均返回"以 `(Object)` 开头的，以对象大小结尾的字符串，形如：`(Object) XX.XX KB`"；场景示例中 5 字节对象的实际输出是 **`(Object) 5 B`**。（`…需求分析.md#查询`、`#场景示例`）
- 查询写回：**"如果查询写回中包含 OBJECT 类型的列，则抛出 701 异常"**。（`…需求分析.md#查询写回`）
- **导入（LOAD）：二期评审时继续补充**（一期无定义）。（`…需求分析.md#导入导出`）
- 监控："支持展示 object 对象所占的磁盘空间"（一期由 @侯昊男 负责）。（`…需求分析.md#监控`、`#完成计划`）
- benchmark："Benchmark 支持 OBJECT 类型数据的读写（树和表分开排期）"。（`…需求分析.md#benchmark`）
- 统计磁盘空间大小：需适配 OBJECT、需加上 OBJECT 对象真实的磁盘空间占用，但"**不在本次评审中进行**，在 V2.0.8.2-计算模块-查询执行-统计数据的磁盘空间占用-需求分析评审时，同步进行"。（`…需求分析.md#统计磁盘空间大小`）
- 树转表：无用户感知的新语法变化，沿用原有树转表语句即可。Trigger / CQ：只在树模型中存在，树模型的 OBJECT 类型放在三期。（`…需求分析.md#树转表`、`#Trigger`、`#CQ`）

### C.5 配置项与手册要求

- 新增 **`restrict_object_limit=false`**：`effectiveMode: first_start`，**启动后不可修改**；默认 false 表示内部对有 OBJECT 类型的表名、列名以及设备名没有任何特殊限制（IoTDB 内部会对所有 TAG 列对应的 value 以及 tableName 和 fieldName 做 BASE32 编码）。（`…需求分析.md#限制`）
  - 为 true 且表中存在 OBJECT 列时：所有 TAG 列 value 以及 tableName、fieldName **不允许为 "." 或 ".." 或者字符串中包含 "./" 和 ".\"**，否则**元数据创建报错**；"不同的文件系统支持的字符不同，所以如果设备名、表名或者 field 名中有文件系统不支持的字符，则在**写入阶段报错**"。（`…需求分析.md#限制`）
  - 大小写不敏感文件系统上：设备的标识不区分大小写，用户需自己遵循规定，**IoTDB 中不做检查**；若真写了 `'d1'` 和 `'D1'` 两个设备，两个设备的 OBJECT 类型写入**可能会相互覆盖**。（`…需求分析.md#限制`）
  - 各文件系统最大路径长度/支持字符表（可作为特殊字符用例的数据来源）：APFS 无限制（Finder 限制 1024 字节）/禁止 `/:`、回车(CR)、NUL；ext4 **4,096 字节（PATH_MAX）**/禁止 `/` 和 NUL；NTFS Win10 1607 前 **260 字符**、之后 **32,767 字符（每层级 ≤255 字符）**/禁止 `< > : " / \ | ? *`；exFAT 同上长度；FAT32 同上长度、受 OEM 代码页限制。（`…需求分析.md#限制`）
- **新增 `max_object_file_size_in_byte`，默认 4 GB，支持热加载，仅 SYSTEM 权限的人可改**；`restrict_object_limit` **启动后不能修改**。（`…需求分析.md#单个对象大小限制`、`#访问控制`）
- 手册要求：数据类型章节增加 object 类型；函数章节增加"函数及数据类型对应关系表格"；**配置项章节，增加 restrict_object_limit, max_object_file_size_in_byte 配置项的描述**。（`…需求分析.md#手册要求`）
- 兼容性/升级要点：**修改了 length 函数返回值类型（int32 -> int64），length 函数支持 object 数据类型**。滚动升级步骤：① 手动停止一个 DN（如果节点上还有 CN，可以一并停止）；② 修改 `data/confignode/system/confignode-system.properties` 配置文件，新增参数 `restrict_object_limit=true`；③ 替换 lib 包；④ 重启这个 DN（和 CN 如果有的话）。（`…需求分析.md#兼容性要求`）

### C.6 文档给出的测试要点 / 场景（逐条照抄）

`…需求分析.md#自测及测试场景建议` 的"一期自测用例"表（模型 / 一级功能 / 二级功能 / 完成人 / 测试用例），测试用例列逐条原文如下：

**表模型 — 元数据 — 在表中创建 OBJECT 类型的列（@陈哲涵）**
- 手动创建表
- 写入自动创建表
- 写入自动扩展OBJECT列
- 表名包含特殊字符
- 列名包含特殊字符

**表模型 — 存储 — SQL 写入（@侯昊男）**
- 包含不同设备，但忽略大小写后一样的设备名
- TAG 列的值包含特殊字符

**表模型 — 存储 — Java SDK（@侯昊男）**
- 包含不同设备，但忽略大小写后一样的设备名
- TAG 列的值包含特殊字符

**表模型 — 存储 — 单个对象大小限制（@侯昊男）**
- 在大小限制以内
- 超过大小限制

**表模型 — 存储 — Last cache 的更新（@侯昊男）**
- CI 测试默认打开了last cache，可以不用单独测试

**表模型 — 存储 — 多盘策略（@侯昊男）**
- 不配多盘
- 配置多盘

**表模型 — 存储 — 合并（@舒文炜）**
- 顺序空间内合并
- 乱序空间内合并
- 跨空间合并

**表模型 — 查询 — OBJECT 类型的数据在 Cli 中的展示形式（@田原）**
- 手动测试，无法在 CI 中包含

**表模型 — 查询 — OBJECT 类型的数据在 JDBC 中的展示形式（@田原）**
- 包含在支持的子句中的 SELECT 子句

**表模型 — 查询 — OBJECT 类型的数据在 Java SDK 中的展示形式（@田原）**
- 只需补充 ITableSession 的单个查询测试用例即可

**表模型 — 查询 — 支持的函数（@舒文炜）**
- 所有 3.2.3.5 中列举的函数
- READ_OBJECT/SIZE 执行的节点与OBJECT 实际存储节点不在同一个

**表模型 — 查询 — 支持的子句（@舒文炜）**
- 所有3.2.3.6 中列举的子句

**表模型 — 查询 — 用户自定义函数（@舒文炜）**
- 标量函数
- 聚合函数
- 表值函数
- 测试 Record 与 OBJECT 类型相关的 5 个接口

**表模型 — 查询 — 气象局定制的自定义标量函数（@张洪胤）**：测试用例列为空（未列具体用例）

**表模型 — 共识协议 — IoTV1（@江天）**
- 在 Daily IT （有 IoTV1 的多副本环境）中补充写入OBJECT类型的 case

**表模型 — 删除（@侯昊男）**：删除数据库 / 删除表 / 删除表中的列 / 删除数据 / 删除设备 —— 测试用例列均为空

**表模型 — TTL（@舒文炜）**：测试用例列为空

**表模型 — benchmark（@侯昊男）**、**表模型 — 监控（@侯昊男）**、**气象局线上版本兼容性（@侯昊男）**：测试用例列均为空

补充（非表格内的评审结论，可作为用例设计输入）：
- "READ_OBJECT， SIZE以及自定义函数中的 Record，均需支持读取 OBJECT 类型的真实二进制内容，**即使 PROJECT 算子实际执行节点与 OBJECT 对象实际存储节点不在一起**"（2025 年 11 月 26 日内部评审）。（`…需求分析.md#附录：历史内容及讨论记录`）
- "进行自测用例的梳理"（同次评审）。（同上）

---

## D. 可测点清单

判定标记：**[稳]** = 可稳定构造、纯黑盒可观测；**[白]** = 需白盒/源码/dump/配置文件或跨节点文件系统观测；**[不可观测]** = 按当前文档无黑盒信号可判定。

### D.1 WAL 压缩（A 节，共 9 条）

1. - [压缩#背景] WAL 文件封口与 Buffer 刷盘默认值：连续写入直到单个 WAL 文件超过 `walFileSizeThresholdInByte`（**默认 30MB**）→ 期望封口当前 WAL 文件并切换到下一个 WAL 文件（`data/wal` 下出现新文件、旧文件不再增长）；`walBufferSize`（**默认 16MB**）写满或驻留 `walAsyncModeFsyncDelayInMs`（**默认超过 1s**）触发刷盘〔封口 **[稳]**；刷盘时刻 **[白]**，无专用日志关键字〕
2. - [压缩#新增参数] 默认压缩开关：新写入数据后 `data/wal` 下 WAL 体积小于同数据量、关闭压缩时的基线 → 期望默认开启（**`ENABLE_WAL_COMPRESSION` 默认为 true**）〔**[白]**：需与关闭该参数的同数据量基线对比，且"压缩痕迹"本身文档未定义〕
3. - [压缩#新增参数] 热加载：修改 `ENABLE_WAL_COMPRESSION` 后不重启集群 → 期望热加载生效（文档明确"允许热加载"），WAL 体积随之变化〔**[白]**：需先在环境上确认 2.0 分支实际键名/热加载白名单与返回文案，文档只写 `ENABLE_WAL_COMPRESSION=true/false`〕
4. - [压缩#WAL 压缩设计概述] 压缩粒度不是整文件：跨多个 WALBuffer 的数据在压缩开启下全部写入并读取成功 → 期望压缩单位是"每个 WALBuffer / 每个段"（倾向方案二），而非整文件；WALEntry 序列化/反序列化、IoT Consensus、Pipe 无需修改〔**[白]**：粒度不可黑盒直接观测，只能用恢复正确性间接验证；**方案未定稿**〕
5. - [压缩#需要确定的内容] 旧（未压缩）WAL 仍可恢复：把未压缩 WAL 目录用于启动恢复 → 期望"先尝试将数据解压缩，如果解压缩失败，再按照未压缩的方式进行读取"仍然成功、数据不丢〔**[白]**：需构造旧版 WAL 目录；该策略文档标注为"需要确定的内容"，可能尚未实现；文档另注明"WAL 内容中没有版本号这个标识"〕
6. - [压缩#需要确定的内容] 压缩与未压缩 WAL 共存（同目录/同文件混合）→ **文档未提及**（"允许压缩和未压缩的 WAL 同时存在"是竞品 Prometheus 的描述），无断言依据〔**[不可观测]**〕
7. - [压缩#WAL 对 I/O 资源的影响 + #预期效果] 两个 I/O 数字（**只 WARN，不作硬断言**）：未压缩基线实测 **WAL 在 InsertTablets / InsertRecords 中分别占据 67% / 88% 的磁盘使用量**（各写 20 分钟）；压缩开启后（设备数=100000、序列数=10、写入请求大小=1000、每个设备写入的行数=1、单 HDD）**预期 I/O 资源节约 30% 左右**〔**[白]**：需 IoTBenchmark 同口径，环境相关〕
8. - [压缩#需要确定的内容] 压缩对恢复速度的影响：压缩开启下、不同 WAL 量时测恢复耗时 → **文档未给出任何数字**（原文列为"需要确定的内容"），只能记录耗时长做趋势观察，不能断言〔**[白]**〕
9. - [压缩#WAL 对 I/O 资源的影响] 压缩开启时重启一致性：写入后重启 DN 再查询 → 期望结果与重启前一致、无丢失〔**[稳]**〕

### D.2 WAL 队列内存控制（B 节，共 9 条）

10. - [队列#配置参数改动] 默认内存上限口径：`wal_buffer_queue_proportion` 存在且默认值为 **memtable 内存的 10%（reject 阈值剩余部分的一半）** → 配置层可读到该比例口径〔**[白]**：需读 memtable 内存与该键值，绝对字节阈值文档未提及〕
11. - [队列#配置参数改动] 键替换与新增键：`wal_buffer_queue_capacity` 已不再作为队列大小控制项、改为 `wal_buffer_queue_proportion`；2.0 新增 `deletion_ahead_log_buffer_queue_capacity`（**V1.3 无此功能**）〔**[白]**：静态/配置层校验；后者**默认值文档未提及**〕
12. - [队列#问题背景] OOM 场景回归：1C1D、DN 堆内存 12G、1 database+1 table+1w sensor+100 device+100 batchsize 持续写入 → 期望**不出现 OOM**（原缺陷为"运行 2~4 小时后 DN 出现 OOM"，修复后原文验证"运行 1 天+ 无 OOM"）〔**[稳]**（判据 = DN 进程存活 + 无 OutOfMemoryError）/[**只 WARN**]（原文耗时 1 天+，用例必须缩短窗口并降级为 WARN）〕
13. - [队列#分析] 队列改为按内存而非按个数控制：大写入请求 + WAL 盘消费慢时，队列内元素个数未达上限但总内存受控 → 原缺陷 dump 证据为 **339 个 InsertNode、Binary 数据点总内存超过 4GB（旧上限个数 500）**；修复后期望"所有 WAL 队列的总内存不超上限"〔**[白]**：需 dump/白盒或 WAL 队列内存面板读数〕
14. - [队列#可观测性] WAL 队列内存面板存在：Write Performance 中可看到"wal 队列内存大小"监控项且有数值波动〔**[白]**：文档只给面板位置，**具体 metric 名/导出格式文档未提及**，需先在环境上探测〕
15. - [队列#方案] 阻写表现为阻塞写入而非报错：把 WAL 队列压满 → 期望写入线程**阻塞等待**（`nonFullCondition.wait()`），不报错、不拒绝；消费线程取出 WALEntry 后 `notifyAll()` 唤醒，总内存低于上限即继续写入成功，无永久卡死〔**[白]**：需人为放慢 WAL 盘或压满队列才可构造〕
16. - [队列#方案] 多队列同时阻写不丢唤醒：多个 WALBuffer 队列同时打满后写入线程全部被唤醒 → 期望全局 `nonFullCondition`（`private static final Object`）生效、无写入线程永久等待（原文注释明确此风险）〔**[白]**：需白盒/并发压测 + jstack〕
17. - [队列#测试验证] 性能无显著回退："手动 Atmos 测试未发现明显的性能影响" → 期望开启队列内存控制前后写吞吐同量级〔**[白]**/**[只 WARN]**：文档**未给出百分比阈值**〕
18. - [队列#可观测性 + #方案] `wal_throttle_threshold_in_byte` 的精确语义与 WAL 队列相关日志关键字 → **三份文档均未提及该参数名，也未提及任何阻写/队列日志文案**，不可据文档断言〔**[不可观测]**：需查源码/配置模板〕

### D.3 OBJECT 一期（C 节，共 22 条）

19. - [OBJECT#功能描述] WAL 只存引用：同一 time/device 下分别写入小对象与大对象，观察 WAL 目录增量 → 期望 WAL 增量与对象二进制大小不成线性（"**Wal 中仅存储引用**"；BLOB 才是"Wal 中直接存储二进制内容"）〔**[稳]**：可用 WAL 目录体积差近似判定；**引用的具体字节格式文档未提及**〕
20. - [OBJECT#存储 + #限制 + #多盘策略] 真实内容落盘位置：写入 OBJECT 后 `**${data_dir}/object_data**` 下出现文件，每个 OBJECT 数据点一个 `${timestamp}.bin`；默认（`restrict_object_limit=false`）中间各级为 **Base32（RFC 4648，仅 A-Z 和 2-7）** 编码的 `${dataregionid}/${B32(tablename)}/${B32(tag1)}/.../${B32(field)}/${timestamp}.bin`，置 true 时为原始 `${dataregionid}/${tablename}/${tag1}/.../${field}/${timestamp}.bin`；配置多盘时按多盘策略分布〔**[白]**：需登录 DN 主机看文件系统〕
21. - [OBJECT#SQL 写入] SQL 分段写入成功：5 字节拆 **2、2、1** 三段（`to_object(false,0,X'696F')` + `to_object(false,2,X'7464')` + `to_object(true,4,X'62')`）→ 期望 `LENGTH(s1)=5`、`READ_OBJECT(s1)` 返回完整 `X'696F746462'`〔**[稳]**〕
22. - [OBJECT#SQL 写入] 分段写入三条约束：① 只写部分片段时查询该 Object 显示 **null**，写完全后才可查到；② 本次写入 offset **不等于**已写入的 Object 大小时**本次写入报错**；③ 已写入部分数据后本次 offset 为 0 时**清除之前已写入的数据部分、重新写入**〔**[稳]**〕
23. - [OBJECT#Java SDK] Java SDK 分段写入：`Tablet.addValue(rowIndex, columnIndex, isEOF, offset, content)` 按 **40、40、20** 三段写 100 字节对象 → 期望长度 100、内容正确；多段总长度与原始 Object 大小不等时"会导致写入的数据大小不正确"〔**[白]**：后半句文档只说结果不正确，**未定义报错或错误码**〕
24. - [OBJECT#单个对象大小限制 + #访问控制 + #限制] 配置约束：`max_object_file_size_in_byte` **默认 4 GB**、支持热加载、**仅由 SYSTEM 权限的人可改**（非 SYSTEM 修改期望失败）；在限制以内写入成功、超过限制写入失败；`restrict_object_limit`（默认 false、`effectiveMode: first_start`）**启动后不可修改**〔**[稳]**（默认值/权限/不可改）/**[白]**（>4GB 构造，建议改小阈值）〕
25. - [OBJECT#限制] `restrict_object_limit=true` 时非法路径名与特殊字符：TAG value / tableName / fieldName 为 `"."`、`".."` 或含 `"./"`、`".\"` → 期望**元数据创建报错**；含文件系统不支持的字符 → 期望**写入阶段报错**；默认 false 下（Base32 编码）表名/列名/TAG 值含特殊字符 → 期望写入与查询正常〔**[稳]**〕
26. - [OBJECT#限制] 忽略大小写重复设备：同一表写入 `'d1'` 与 `'D1'` → **文档明确 IoTDB 不做检查、二者 OBJECT 写入"可能会相互覆盖，导致文件内容有问题"**（属声明型行为，用例只记录现象，不断言内容正确）〔**[白]**：结果依赖文件系统大小写敏感性；Linux/ext4 默认敏感，不易复现〕
27. - [OBJECT#查询 + #场景示例] 展示形式：CLI / JDBC `getString` / Java SDK（`Field.getStringValue`、`Field.getObjectValue`、`DataIterator.getObject/getString/getBlob`）→ 期望返回以 `(Object)` 开头、以对象大小结尾的字符串（形如 `(Object) XX.XX KB`）；5 字节对象场景示例的实际输出为 **`(Object) 5 B`**〔**[稳]**〕
28. - [OBJECT#支持的函数] `READ_OBJECT` 边界：`offset < 0` 或 `offset >= 全文件长度` → **抛异常**；`length > 2^31 - 1` → **报错**；`length` 超过从 offset 起的剩余长度 → 取剩余内容；`length < 0` → 读取 offset 起剩余全部数据；返回类型 **BLOB**〔**[稳]**〕
29. - [OBJECT#支持的函数] 函数支持矩阵：`LENGTH(s1)` 支持 OBJECT 且返回 **INT64**（**原为 INT32**）；`CAST/TRY_CAST` 仅支持 OBJECT → STRING、**不支持任何类型强转成 OBJECT**；`coalesce`/`IS [NOT] NULL` 支持；聚合 `count/first/last/first_by/last_by`、窗口 `first_value/last_value/nth_value/lead/lag`、行模式匹配 `RPR_FIRST/RPR_LAST/PREV/NEXT`（第一参数）支持；**其他函数均不支持 OBJECT**（期望报错）〔**[稳]**〕
30. - [OBJECT#支持的子句] 子句支持矩阵：FROM / SELECT / WHERE / HAVING 支持含 OBJECT 的表达式；**GROUP BY、ORDER BY、OFFSET、LIMIT 不支持**（期望报错）；`FILL` **只支持 PREVIOUS**；`MATCH_RECOGNIZE` / 表值函数 / `WINDOW` 的 PARTITION BY 与 ORDER BY 不支持 OBJECT〔**[稳]**〕
31. - [OBJECT#查询写回] 查询写回中含 OBJECT 类型列 → 期望**抛出 701 异常**〔**[稳]**〕
32. - [OBJECT#用户自定义函数 + #用户定制的自定义标量函数 + #附录：历史内容及讨论记录] UDF 接口：`Record` 5 个接口中 `getObjectFile` 在本节点未存储该 OBJECT 时返回 `Optional.empty()`、`objectLength` 返回 long、`readObject(col,offset,len)` 在长度 > 2^31-1 时报错；声明返回 OBJECT 类型的 UDF **调用时报错**；`GEO_PENETRATE` 需先 `create function geo_penetrate as '...GeoPenetrate'` 才可用，参数 4 支持 `'LZ4', 'UNCOMPRESSED', 'SNAPPY', 'GZIP', 'ZSTD', 'LZMA2'`；`READ_OBJECT`/`SIZE` 的执行节点与 OBJECT 实际存储节点不在同一节点时仍能读到真实二进制〔**[白]**：需部署 UDF + 多节点，`getObjectFile` 的"未在本节点"要跨节点构造〕
33. - [OBJECT#合并] 合并只重写引用、不动实体文件：顺序空间内合并 / 乱序空间内合并 / 跨空间合并后 object_data 下实体文件的数量与内容不变、`READ_OBJECT` 结果不变；乱序重复时间戳时**写入阶段新数据直接覆盖旧文件**、object 目录始终保持最新状态（无多余文件）〔**[稳]**：合并后 TsFile 数下降 + 数据指纹一致〕
34. - [OBJECT#删除 + #TTL + #合并] 删除与过期的实体清理：删除数据/数据库/表/列/设备/序列、TTL 到期后 → **OBJECT 的真实存储内容也会随之删除**（object_data 下对应 `.bin` 消失）；因 TTL 清理索引时合并也会将对应的 OBJECT 实体文件一并删除〔**[稳]**（删除/TTL）/**[白]**（"因 TTL 清理索引触发合并删实体"需对齐 TTL 与合并时序）〕
35. - [OBJECT#共识协议 + #自测及测试场景建议] IoTV1 多副本写入（原文自测要求"在 Daily IT（有 IoTV1 的多副本环境）中补充写入OBJECT类型的 case"）→ 期望多副本一致、重启后可恢复；一期排期未含 IoTV2（IoTV2 列为二期）〔**[稳]**〕
36. - [OBJECT#兼容性要求] 滚动升级：停一个 DN（如同机有 CN 一并停）→ 在 `data/confignode/system/confignode-system.properties` 新增 `restrict_object_limit=true` → 替换 lib 包 → 重启该 DN → 期望升级后 OBJECT 数据可读、`length` 返回类型为 **int64**（兼容性要求含"支持旧版本升级""兼容气象局定制分支升级"）〔**[白]**：需变更部署，离线/谨慎执行〕
37. - [OBJECT#导入导出] 导出 / 导入（LOAD）→ **一期为"二期评审时，继续补充"，无一期断言依据**；文档内可用的相关结论只有附录："导入导出时无需对 tsfile 文件内容做任何修改，只需将 OBJECT 对象的真实二进制内容放到与接收端 tsfile 所在 region 相对应的目录下"；以及"tsfile 中引用的 `${dataregionid}` 是无用值、IoTDB 层面每次都会被替换，仅为兼容性保留"〔**[不可观测]**（一期功能范围）/**[白]**（按附录结论手工验证）〕
38. - [OBJECT#监控] 监控"支持展示 object 对象所占的磁盘空间" → 期望存在对应展示项且数值与 object_data 目录实际占用一致〔**[白]**：**指标名/接口名文档未提及**〕
39. - [OBJECT#性能要求 + #功能描述] 性能类无阈值项（**均只 WARN**）："读写性能不弱于用户当前的定制版本"；OBJECT 查询效率优势（某个 OBJECT **100MB** 时通过 UDF 只读中间几个字节，而 **100 MB** 的 BLOB 必须完整从磁盘读取 100 MB）〔**[白]**：文档未给出任何耗时或百分比阈值〕
40. - [OBJECT#功能描述] 设计取舍类（不做硬断言，仅记录）：OBJECT **写放大系数永远为 1**、BLOB 为 **2 + 合并次数**；OBJECT 空间放大低（merge & release on write）、BLOB 高（merge on read and release on compact）；OBJECT 每数据点一个文件、需搭配 TTL、适合写频低而单值大的场景，BLOB 适合小于 **512KB** 的二进制数据〔**[白]**：写放大系数需按"合并次数"构造并对照 BLOB；其余为选型结论〕

### D.4 具体阈值 / 数字汇总（后续用例：要么断言，要么只 WARN）

| 数字（原文照抄） | 出处 | 建议 |
| --- | --- | --- |
| 默认 16MB（walBufferSize） | 压缩#背景 | 可断言（配置默认值） |
| 默认超过 1s（walAsyncModeFsyncDelayInMs） | 压缩#背景 | 可断言（配置默认值） |
| 默认 30MB（walFileSizeThresholdInByte） | 压缩#背景 | 可断言（封口阈值，文件大小判据） |
| WAL 占磁盘使用量 67%（InsertTablets）/ 88%（InsertRecords） | 压缩#WAL 对 I/O 资源的影响 | **只 WARN**（benchmark 环境相关） |
| 写入 20 分钟（实验时长） | 压缩#WAL 对 I/O 资源的影响 | 用例参数可复用 |
| 设备数=100000、序列数=10、写入请求大小=1000、每个设备写入的行数=1 | 压缩#预期效果 | 用例参数可复用 |
| I/O 资源节约 30% 左右 | 压缩#预期效果 | **只 WARN**（"左右"，且文档标注为初步实验） |
| GZip（实验所用算法） | 压缩#需要确定的内容 | 仅参考，算法未定稿 |
| 默认 500（队列最大个数，v1.3.4 前） | 队列#分析 | 可断言（历史行为/回归基线） |
| 339 个 InsertNode / 超 4GB（OOM dump） | 队列#分析 | **只 WARN**（缺陷复现证据，不可作为常规阈值） |
| DN 堆内存 12G、运行 2~4 小时后 OOM | 队列#问题背景 | 用例参数；**时长过长，建议缩短并 WARN** |
| 1 database、1 table、1w sensor、100 device、100 batchsize | 队列#问题背景 | 用例参数可复用 |
| 运行 1 天+ 无 OOM | 队列#测试验证 | **只 WARN**（耗时不可接受） |
| memtable 内存的 10%（wal_buffer_queue_proportion 默认） | 队列#配置参数改动 | 可断言（比例口径，需白盒读 memtable 内存） |
| 单个 Object 5 字节分 2、2、1 三段 | OBJECT#SQL 写入 | 可断言（精确） |
| 单个 Object 100 字节分 40、40、20 三段 | OBJECT#Java SDK | 可断言（精确） |
| max_object_file_size_in_byte 默认 4 GB | OBJECT#单个对象大小限制 | 可断言（默认值）；>4GB 构造建议改小配置 |
| length 大于 2^31 - 1 时报错 | OBJECT#支持的函数 | 可断言（边界） |
| 5 字节对象显示为 `(Object) 5 B` | OBJECT#场景示例 | 可断言（精确） |
| length 返回值 int32 -> int64 | OBJECT#兼容性要求 | 可断言（类型变更） |
| BLOB 写放大系数为 2 + 合并次数；OBJECT 写放大系数永远为 1 | OBJECT#功能描述 | 可断言（定性系数，需按合并次数构造） |
| 100MB OBJECT 只读中间几个字节 / 100 MB BLOB 必须完整读 | OBJECT#功能描述 | **只 WARN**（无耗时阈值） |
| BLOB 适合存储小于 512KB 的二进制数据 | OBJECT#功能描述 | 不做断言（选型建议） |
| 一、二、三期排期（一期 12 月底，暂定 2.0.8.1 发版；二期 2.0.9.1；三期 2.0.10.1） | OBJECT#完成计划 | 范围界定，不做断言 |
| APFS 1024 字节（Finder）/ ext4 4,096 字节（PATH_MAX）/ NTFS 260 字符（Win10 1607 前）、32,767 字符（之后，每层级 ≤255 字符） | OBJECT#限制 | 可断言（路径长度边界，需白盒构造） |

---

## E. 影响最大的"文档未提及"（后续 skill 需自行探测或向研发确认）

1. **WAL 压缩的算法与级别未定稿**：`ENABLE_WAL_COMPRESSION` 只给了布尔开关；算法候选 GZIP/LZ4/ZSTD，实验用 GZip，最终选择列在"需要确定的内容"里。→ 用例不能断言压缩算法，也无法断言具体压缩率阈值（文档只有"I/O 资源节约 30% 左右"）。（`WAL 压缩功能设计.md#新增参数`、`#需要确定的内容`、`#预期效果`）
2. **压缩 WAL 的可观测信号完全缺失**：无目录约定、无日志关键字、无 metrics；且"WAL 内容中没有版本号标识"，兼容性靠"先试解压、失败按未压缩读"。→ 压缩用例只能靠 WAL 目录体积 + 重启恢复正确性间接判定，"压缩与未压缩共存"没有任何断言依据。（`WAL 压缩功能设计.md#需要确定的内容`、`#Prometheus`）
3. **WAL 队列内存的绝对阈值参数与 metric 名缺失**：`wal_throttle_threshold_in_byte` 三份文档全文未出现；`wal_buffer_queue_proportion` 只给"memtable 内存的 10%（reject 阈值剩余部分的一半）"这一相对口径，"设置的最大值"没有参数名；可观测性只写"Write Performance 中新增 wal 队列内存大小监控面板"，没有指标名；`deletion_ahead_log_buffer_queue_capacity` 没有默认值。→ 阻写/内存上限用例必须先做环境探测（白盒）才能落地。（`WAL 队列内存控制.md#方案`、`#配置参数改动`、`#可观测性`）
4. **OBJECT 的 WAL 记录格式与一致性要求未展开**：只写"Wal 中仅存储引用"，引用本身的字节格式、"写入成功但未落盘时重启是否必须可恢复"、校验和（checksum）均未提及；共识协议章节只写"无用户感知的新需求"，并把 Snapshot 重新设计指向本文档不存在的 3.2.11 节；导入导出/LOAD 一期"二期评审时继续补充"。→ OBJECT 的"WAL 只存引用"只能用 WAL 体积间接验证，重启恢复用例缺少正式判据，导入导出无一期判据。（`…需求分析.md#功能描述`、`#共识协议`、`#导入导出`）
