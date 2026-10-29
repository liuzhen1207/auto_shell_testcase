# WAL（写前日志）专项 skill —— 需求追溯矩阵（REQ_MATRIX）

> **用途**：把「需求/设计文档 + 源码事实」拆成可追溯编号条目（§1），逐条映射到已登记的 27 条用例（§2），
> 给出每条用例的构造与判据（§3），并把未覆盖/不可构造项（§4）与首轮实跑口径风险（§6）如实列出。
> **本文档只从下面这些本地文件取材**（全部只读，未连集群、未执行任何集群命令、未改任何用例脚本）：

| 简称 | 文件 | 提供什么 |
| --- | --- | --- |
| `design_extract.md` | `docs/req_sources/design_extract.md` | 飞书《写前日志》技术设计 / WAL 预写日志 / 写前日志 三篇的抽取（34 条可测点 TP-01~TP-34） |
| `feature_extract.md` | `docs/req_sources/feature_extract.md` | WAL 压缩 / WAL 队列内存控制 / OBJECT 一期（40 条可测点） |
| `source_grounding.md` | `docs/req_sources/source_grounding.md` | **源码印证**：19 项配置清单 + `file:line` + 40 条可测点 + 指标名 + §8/§10 日志文案 |
| `cases.tsv` | `cases/cases.tsv` | **27 条已登记用例** W-00…W-26（脚本名 / 模型 / 集合 / 关键参数 / 覆盖说明） |
| `DECISIONS.md` | `docs/DECISIONS.md` | 口径决策：只 WARN 清单、文档矛盾、不可构造项、去重边界 |
| `env.conf` | `conf/env.conf` | 用例可调参数与默认值（`WAL_*` / `CMP_*`） |
| `wal_ext.sh` | `lib/wal_ext.sh` | WAL 观测 helper 名（§3 里的"信号"引用的函数名） |

**纪律**：本文档**不新增**任何 `file:line`、章节号、默认值或指标名 —— 每条来源都可回指到上面这些文件；
查不到依据的一律写「未确认」「文档未提及」，**不编造、不静默通过**。
27 条用例的 ID 与脚本名与 `cases.tsv` **逐字一致**。

**标记约定**：

- `[口径待标定]`：文档之间（或文档与源码之间）**自相矛盾**；用例必须**先现场读生效值再断言**，不写死数值、不判等号边界。
- `[需白盒]`：黑盒无外部信号，需要 `jstack` / JDWP / 只读 agent / hexdump / 离线解析才能判定。
- `[不可观测]`：按现有文档与源码**根本没有外部信号**，或语义未定义到可断言的粒度。
- 覆盖方式只有三档：**硬断言（可判 FAIL，进 `fail_flag`）** / **仅 WARN（进 `v_warnMessage`）** / **仅记录证据（只打日志）**；口径见 `DECISIONS.md §1`、`§2`。
- 判据来源写法：`源码文件:行`（仅取自 `source_grounding.md`）、`文件名#章节`（飞书文档原文标题）、指标名、或 helper 名（`lib/wal_ext.sh`）。

**§1 分组一览（共 68 条）**：

| 组 | 名称 | 编号 | 条数 |
| --- | --- | --- | --- |
| A | 机制与写入路径 | R-W01 ~ R-W06 | 6 |
| B | WALNode 分配与目录 | R-W07 ~ R-W16 | 10 |
| C | 文件命名与记录格式 | R-W17 ~ R-W21 | 5 |
| D | 写入模式与持久化 | R-W22 ~ R-W30 | 9 |
| E | 重启恢复 | R-W31 ~ R-W34 | 4 |
| F | 清理 / 快照 / 阻写 | R-W35 ~ R-W42 | 8 |
| G | 内存与队列 | R-W43 ~ R-W46 | 4 |
| H | 指标与日志可观测 | R-W47 ~ R-W51 | 5 |
| I | 参数合法性与热加载 | R-W52 ~ R-W56 | 5 |
| J | OBJECT 一期 | R-W57 ~ R-W63 | 7 |
| K | 安全 / 性能 / 兼容 | R-W64 ~ R-W68 | 5 |

类型分布：**功能 43 / 可观测 11 / 兼容 10 / 安全 2 / 性能 2**（统计口径见 §1 末）。
标 `[口径待标定]` 的共 **11 条**：R-W13、R-W14、R-W17、R-W26、R-W27、R-W28、R-W29、R-W38、R-W39、R-W41、R-W66。

---

## §1 需求条目清单

> 每条一行：`编号 | 来源 | 需求描述（一句） | 类型`。**文档间矛盾的条目分开列**（不把两种口径混在一条里），并标 `[口径待标定]`。

### A 组：机制与写入路径（R-W01 ~ R-W06）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W01 | `WAL 预写日志.md#1.1. 简介`（`design_extract.md#1.1`） | WAL 只做 redo（无 undo log），原因是"IoTDB 不支持事务"。 | 功能 |
| R-W02 | `WAL 预写日志.md#1.1. 简介`（`design_extract.md#1.2`） | 数据在**实际修改数据库文件前**先写入 WAL 文件；重启恢复阶段读 WAL，恢复未落盘的数据。 | 功能 |
| R-W03 | `…技术设计.md#概述`、`#4.2 文件格式`（`design_extract.md#1.2`/`#3.1`） | 一个 WAL Entry 对应一个写入相关物理计划（`InsertRowNode`/`InsertTabletNode`/`DeleteDataNode`），另有一类是 MemTable 快照（`Type=0x03`）。 | 功能 |
| R-W04 | `…技术设计.md#写入流程`、`#设计细节`（`design_extract.md#1.2`/`#3.6`） | 写入链路：WAL Entry → WALBuffer 阻塞队列 → 序列化到 Working Buffer → 切 Syncing Buffer → 压缩 → 写 WAL 文件（fsync）；总代价 = `t_enqueue + t_dequeue + t_serialize + t_compress + t_IO`。 | 功能 |
| R-W05 | `…技术设计.md#设计细节`（`design_extract.md#3.6`） | 三 Buffer 状态机不变量：任意时刻**恰有 1 个 working**；compressed buffer **不参与状态切换、恒占 1 个**。 | 功能 `[需白盒]` |
| R-W06 | `…技术设计.md#WAL 相关线程`（`design_extract.md#1.4`） | 线程模型：`WAL-Serialize`/`WAL-Sync` 个数 = WALNode 数，`WAL-Delete` 恒 1 个，`WAL-Recover` 仅在重启恢复阶段存在。 | 可观测 `[需白盒]` |

### B 组：WALNode 分配与目录（R-W07 ~ R-W16）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W07 | `…技术设计.md#概述`（`design_extract.md#2.1`） | 每个 WAL Node 代表一个 WAL 目录，每个目录下有多个 WAL 文件；同一时刻只有 1 个检查点文件。 | 功能 |
| R-W08 | `…技术设计.md#概述`（`design_extract.md#1.3`） | WALNode 数由协议决定：IoTConsensus 中每个 DataRegion 拥有一个；RatisConsensus 不使用 WAL；SimpleConsensus 一般为 `[data region num / 2, data region num]`。 | 兼容 |
| R-W09 | `…技术设计.md#WAL Node 分配策略`（`design_extract.md#2.1`） | 三种策略语义：Elastic 按 unique id 个数决定 node 数（每 node 默认 4 个）/ RoundRobin 定 node 数后轮转 / FirstCreate 每 unique id 一 node；**MultiLeader 只能使用 FirstCreate**；**策略选择用的配置项名文档未提及**。 | 功能 |
| R-W10 | `WALManager.java:76-85`、`ElasticStrategy.java:41,62-76`、`RoundRobinStrategy.java:61-68`（`source_grounding.md §3.2`） | 源码实际选择：`IoTConsensus`/`IoTConsensusV2` → `FirstCreateStrategy`；否则 `max_wal_nodes_num=0` → `ElasticStrategy`（`APPLICATION_NODE_RATIO=4`，即每 4 个申请者开 1 个 node，目录名为自增整数 `0/1/2…`）；`>0` → `RoundRobinStrategy`。 | 功能 |
| R-W11 | `WALManager.java:87-96`（`source_grounding.md §3.2`） | 申请者 unique id 规则：IoTConsensus(V2) 下 = `dataRegionName`（即 `databaseName`），其它情况 = `dataRegionName-{sequence/unsequence}`。 | 功能 |
| R-W12 | `AbstractNodeAllocationStrategy.java:62-83`、`DataRegion.java:806-812`（`source_grounding.md §3.2`） | WALNode 目录 = `<walDir>/<identifier>`；IoTConsensus(V2) 下 identifier = `<database>-<regionId>`（`FILE_NAME_SEPARATOR="-"`）。 | 可观测 |
| R-W13 | 模板 `iotdb-system.properties.template:1933,1939`、`IoTDBDescriptor.java:1836-1838`（`source_grounding.md §1.2#2`/`§1.4`）；`…技术设计.md#参数配置`（`design_extract.md#2.2`） | `max_wal_nodes_num` 默认 0（"由系统针对负载自行决定"），**≤0（含负数）一律回落成 0**；模板注释写明"**该参数仅在 standalone 模式有效**，IoTConsensus 每个 data region 一个 wal、RatisConsensus 不用 wal" —— 即集群下 `>0` 也不改变 WALNode 数。 | 兼容 `[口径待标定]` |
| R-W14 | `CommonDescriptor.java:124-128`、模板 `:293`、`source_grounding.md §1.5`；`…技术设计.md#参数配置`（`design_extract.md#2.3`） | 唯一有效的 WAL 目录键是 **`dn_wal_dirs`**（默认 `data/datanode/wal`，restart-only，逗号分隔多目录）；`wal_dir`（单数）/`wal_dirs` **键不存在** —— 文档写的是 `wal_dirs` 默认 `data/wal`（模板注释里出现的 `wal_dirs` 是注释口误）。 | 兼容 `[口径待标定]` |
| R-W15 | `DataNode.java:971-974`、`IoTDBStartCheck.java:219-225`（`source_grounding.md §2`） | RatisConsensus 下**强制** `wal_mode=DISABLE`；且 Ratis 或 DISABLE 时**不注册/不创建** WAL 目录。 | 功能 |
| R-W16 | `WALNode.java:143-146`、`AbstractWALBuffer.java:71-75`、`CheckpointManager.java:86`（`source_grounding.md §3.3`/`§10.1`）；`design_extract.md#9.1-3`、`#2.3`（TP-07） | 目录/命名可观测项：首次创建目录打 INFO `create folder {} for wal node-{}.` / `Create folder {} for wal node-{}'s buffer.` / `create folder {} for wal buffer-{}.`；但 **WALNode↔DataRegion/时间分区的完整映射与目录命名规则文档未给出**（细节只在图片里）⇒ 目录级断言前必须现场标定。 | 可观测 |

### C 组：文件命名与记录格式（R-W17 ~ R-W21）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W17 | 文档 `…技术设计.md#4.1 文件滚动命名`（`design_extract.md#2.3`）vs `WALFileUtils.java:65-83`、`IoTDBConstant.java:358-363`（`source_grounding.md §3.4`） | 文件名格式：文档写 `_[version_id].wal`（version_id 从 0 开始递增，正则 `^_\d+\.wal$`）；源码实现为 `_<versionId>-<startSearchIndex>-<statusCode>.wal`（形如 `_0-0-1.wal`）。两种写法**并存**，用例取并集校验并记录实测形态。 | 功能 `[口径待标定]` |
| R-W18 | 文档 `…技术设计.md#6.2 检查点文件`（`design_extract.md#2.4`） | 检查点文件名 `_[version_id].checkpoint`（从 0 递增）；每个 WALNode **同一时刻只有一个**检查点文件；其大小超过 **3 MB** 时滚动（向新文件写 MemTable 全局信息检查点后删除上一个）。 | 功能 |
| R-W19 | `WALFileUtils.java:65-83,135-141`、`WALFileStatus.java:26-31`（`source_grounding.md §3.4`） | 源码文件名正则可解析：`^_\d+-\d+-[01]\.wal$`，第 3 段 statusCode ∈ {`CONTAINS_NONE_SEARCH_INDEX(0)`, `CONTAINS_SEARCH_INDEX(1)`}；加密时追加 `SecretKey.FILE_ENCRYPTED_SUFFIX`。 | 可观测 |
| R-W20 | 文档 `…技术设计.md#4.2 文件格式`（`design_extract.md#3.1`~`#3.3`、`#4.2`） | WAL 文件二进制格式：尾部 Metadata（`Marker` 1 字节 `-126`、`FirstSearchIndex` 8B、`WALEntrySizes` 4k B、`MemTableIds` 8q B、`MetadataSize` 4B、`MagicString="WAL-V2"`）；Segment 条件长度字段（`Compression Type` 1B + `Compressed Size` 4B + 〔压缩时才有〕`Uncompressed Size` 4B + s 字节），即未压缩段 `1+4+s`、压缩段 `1+4+4+s`；WAL Entry = `Type`(0x03 快照/0x04 InsertRow/0x05 InsertTablet/0x06 DeleteData，0x00~0x02 已废弃) + `MemtableId` 8B + `Value` 不定长。 | 功能 `[需白盒]` |
| R-W21 | `WALFileVersion.java:29-32,58-81`、`LogWriter.java:84-91`、`WALWriter.java:104-111`、`WALInputStream.java:392-404`、`:116-145`（`source_grounding.md §4.4`） | 文件版本 magic：V1(`WAL`)/V2(`V2-WAL`)/V3(`V3-WAL`)；读侧**先试 V3 再试 V2、都失败按 V1**（回退成功打 INFO `Failed to load WAL segment in V1 way, try in V2 way successfully.`）；尾 magic 校验失败按"破损文件"处理（`endOffset = channel.size()`）。 | 兼容 |

### D 组：写入模式与持久化（R-W22 ~ R-W30）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W22 | `…技术设计.md#参数配置`（`design_extract.md#4.1`）；`WALMode.java:23`、模板 `:1929-1930`（`source_grounding.md §1.2#1`/`§1.4`） | `wal_mode` 只有三值 `{DISABLE, SYNC, ASYNC}`、默认 `ASYNC`、**restart-only**；`SYNC` = 写入需等 WAL 成功刷盘才返回，`ASYNC` = 不等待刷盘、成功后立即返回。 | 功能 |
| R-W23 | `WALManager.java:99-105`、`StorageEngineMessages(en):349`、`DataRegion.java:3478-3480,3521-3523`（`source_grounding.md §2`） | `wal_mode=DISABLE` 生效后 `applyForWALNode` 返回 **`WALFakeNode`**；向假节点写 WAL 会失败（`Cannot write wal into a fake node. `）；删除类操作走 `Collections.emptyList()` 短路、不写 WAL。 | 功能 |
| R-W24 | `IoTDBStartCheck.java:150-163`、`DataNodeMiscMessages.java:1353-1355`、`DataNode.java:530`（`source_grounding.md §2`） | 集群下 DISABLE **必须被拒**：条件 =（`IoTConsensus` 或（`IoTConsensusV2` 且 `iot_consensus_v2_mode=stream`））且 `wal_mode=DISABLE` ⇒ DN **启动失败**，文案含 `Configuring the WALMode as disable is not supported under IoTConsensus and IoTConsensusV2 stream mode`。 | 功能 |
| R-W25 | `AbstractIoTDBStartCheck.java:83-88`、`SystemPropertiesHandler.java:140-142`（`source_grounding.md §2`） | 上述 DISABLE 校验**只在 `isFirstStart()`**（该节点还没有 `iotdb-system.properties`）执行 ⇒ 已初始化节点改成 DISABLE 再重启**不会**被拒（走 `checkImmutableSystemProperties()` 分支）。 | 功能 |
| R-W26 | `IoTDBConfig.java:1178`、`ConsensusFactory.java:47-48`、`IoTDBDescriptor.java:1538`、`IoTDBStartCheck.java:151-157`（`source_grounding.md §2`） | IoTConsensusV2 的 `iot_consensus_v2_mode` **默认 `batch`**，该模式下 `wal_mode=DISABLE` **被允许**（只有 `stream` 才拒绝）—— 与 R-W24 的拒绝条件并列成立。 | 兼容 `[口径待标定]` |
| R-W27 | 源码 模板 `:1946,:1953`、`IoTDBDescriptor.java:2186-2204`、`WALBuffer.java:330-340`、`WALInfoEntry.java:59-60`（`source_grounding.md §1.2#3/#4`、`§5.4`）vs 文档 `…技术设计.md#参数配置`（`design_extract.md#4.2`） | fsync 延迟：源码有**两个热加载键** `wal_async_mode_fsync_delay_in_ms`（默认 1000）/ `wal_sync_mode_fsync_delay_in_ms`（默认 3），分别用于 ASYNC/SYNC 的攒批等待，SYNC 下写入等 `waitForResult()`；文档**只有单一** `fsync_wal_delay_in_ms`（默认 1500ms），且明确"两个模式的键三份文档均未提及"。 | 功能 `[口径待标定]` |
| R-W28 | 源码 模板 `:1959`、`IoTDBDescriptor.java:1840-1846`、`WALBuffer.java:82-83,193-196`（`source_grounding.md §1.2#5`、`§5.1`）vs 文档 `…技术设计.md#参数配置`（`design_extract.md#2.5`） | `wal_buffer_size_in_byte`：源码默认 `33554432`（32 MB，restart-only），实际被切成 **3 份**（`ONE_THIRD_WAL_BUFFER_SIZE`），一批最多攒到 1/3 的 **95%**（`FSYNC_BUFFER_RATIO`）；文档写默认 16 MB。 | 功能 `[口径待标定]` |
| R-W29 | 源码 模板 `:1981`、`IoTDBDescriptor.java:2206-2214`、`WALBuffer.java:697-725`（`source_grounding.md §1.2#9`、`§5.3`）vs `WAL 压缩功能设计.md#背景`（`feature_extract.md#A.1`）vs `…技术设计.md#参数配置`（`design_extract.md#2.5`） | `wal_file_size_threshold_in_byte`（**hot_reload**）：源码/压缩文档写默认 **30 MB**（`31457280`），技术设计文档写 **10 MB**；轮转判据用的是 `originalSize()`（未压缩累计写入字节），不是磁盘文件长度。 | 功能 `[口径待标定]` |
| R-W30 | 模板 `:1965`、`IoTDBDescriptor.java:1848-1849`、`IoTDBConfig.java:2244-2246`、`WALBuffer.java:258-274`（`source_grounding.md §1.2#6`、`§1.3`、`§5.1`） | `wal_entry_size_limit_in_byte` 默认 `-1`（≤0 时 getter 兜底取 `wal_buffer_size_in_byte`）；单条 entry 序列化超过上限 ⇒ **写请求直接失败**（`The WAL entry size %d exceeds wal_entry_size_limit_in_byte %d.`，`WAL_ENTRY_TOO_LARGE`），该分支**不打日志**。 | 功能 |

### E 组：重启恢复（R-W31 ~ R-W34）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W31 | `…技术设计.md#WAL 重启恢复` + `WAL 预写日志.md#1.1. 简介`（`design_extract.md#4.3`、TP-29） | 未刷盘的数据在重启后应被重放（redo）并可查 —— 这是不依赖日志/白盒的最强黑盒判据。 | 功能 |
| R-W32 | `…技术设计.md#WAL 重启恢复`、`#概述`（`design_extract.md#4.3`、`§9.2`）；`WALNodeRecoverTask.java:134-137`（`source_grounding.md §8.2`） | 恢复流程：等各 DataRegion 提交 0 层未封口 TsFile → 按 **WALNode 粒度**读 checkpoint + 重放 WAL Entry → **删除 WAL Node 下的所有文件**，恢复后直接把这些 MemTable 刷盘；但"删除文件"是否严格发生在恢复成功之后（失败是否也删）**文档未声明** ⇒ 不可作硬判据。 | 功能 |
| R-W33 | `WALRecoverManager.java:75,103-105,144`、`WALNodeRecoverTask.java:84,128-131`、`StorageEngine.java:266`（`source_grounding.md §8.2`、`§10.5`） | 恢复的可观测 INFO 序列：`Start recovering wal.` → `Data regions have submitted all unsealed TsFiles, start recovering TsFiles in each wal node.` → `Start recovering WAL node in the directory {}` → `Successfully recover WAL node in the directory {}, add this node to WALManger.` → `Successfully recover all wal nodes.`（失败统一文案 `Fail to recover wal.`）。 | 可观测 |
| R-W34 | `…技术设计.md#检查点类型`（`design_extract.md#4.3`） | 检查点用于恢复的过滤算法：先按 MemTable 全局信息检查点恢复全局未刷盘 MemTable，再从前往后读"新建/刷盘"检查点增删，据此从 WAL 文件中过滤出有效 WAL Entry。 | 功能 `[需白盒]` |

### F 组：清理 / 快照 / 阻写（R-W35 ~ R-W42）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W35 | `…技术设计.md#WAL 检查点及 MemTable 快照`、`#WAL 文件没法被删除的原因`（`design_extract.md#5.1`/`#5.4`）；`WALNode.java:657-676`（`source_grounding.md §6.2`） | 无效定义：某 WAL 文件对应的 MemTable **只要有一个没刷盘，该文件就不能被删**；三种不可删原因 = ①未刷盘（`flushed=false`）②已刷盘但被 pipe 模块 pin 住（`pinCount>0`）③已刷盘但未被 IoTConsensus 消费完（`endFileIndex < filesToDelete.length`）。 | 功能 |
| R-W36 | 模板 `:2009`、`IoTDBDescriptor.java:2246-2254,2711-2715`、`WALManager.java:168-198,320-325`（`source_grounding.md §1.2#13`、`§6.1`） | `delete_wal_files_period_in_ms` 默认 `20000`、**hot_reload**；热改后周期变化会**重启删除线程**并打 INFO `Reboot wal delete thread successfully, current period is {} ms`。 | 功能 |
| R-W37 | `…技术设计.md#6.3.1 常规整理`（`design_extract.md#5.2`）；`WALNode.java:671-676`、`WALWriter.java:139-143`（`source_grounding.md §6.2`） | 常规整理规则：删除 version_id **小于** `min(各 MemTable 首个 WAL 文件的 version_id)` 的所有 WAL 文件；IoTConsensus 下 `safelyDeletedSearchIndex=Long.MAX_VALUE` ⇒ **只有 statusCode=0 的文件才会被删**，statusCode=1 与最后一个文件恒保留。 | 功能 |
| R-W38 | `…技术设计.md#参数配置`、`#MemTable 快照`（`design_extract.md#5.3`）；`WALNode.java:506-510,438-455`、`IoTDBDescriptor.java:2222-2224`（`source_grounding.md §6.3`） | `wal_min_effective_info_ratio` 默认 `0.1`、hot_reload；有效信息比低于该值（或触发了 throttle）⇒ 触发快照或刷盘。**文档两种写法并存**（参数条目 `<`、章节 `≤`）；源码要求 `> 0` 才 set（**设 0/负数不生效、仍为 0.1**）。 | 功能 `[口径待标定]` |
| R-W39 | `…技术设计.md#参数配置`、`#MemTable 快照`（`design_extract.md#5.3`）；`WALNode.java:546-559`（`source_grounding.md §6.4`） | 快照相关两个 default：`wal_memtable_snapshot_threshold_in_byte` 默认 `8388608`（8 MB，文档 `>` 与 `≥` 并存）、`max_wal_memtable_snapshot_num` 默认 `1`（文档"超过该次数"与"累计 ≥"并存）⇒ **默认 1 时"允许 1 次快照"还是"首次即刷盘"存在歧义**。 | 功能 `[口径待标定]` |
| R-W40 | `WALNode.java:546-559,569-577,641-650`、`WritingMetrics.java:647-654`（`source_grounding.md §6.4`、`§10.3`） | 快照 vs 刷盘的选择逻辑：时间分区落后 / 快照次数 ≥ 上限 / MemTable RAM > 阈值 ⇒ flush（并记 `flush_memtable_count{type="wal_flush_memtable_count"}`），否则 snapshot；两条 INFO 文案：`WAL node-{} flushes memTable-{} to TsFile {} because …` / `WAL node-{} snapshots memTable-{} to wal files because …`。 | 可观测 |
| R-W41 | 源码 模板 `:2016`、`IoTDBDescriptor.java:2256-2264,2277-2290`、`WALManager.java:256-262`（`source_grounding.md §1.2#14/#15`、`§7.1`）vs 文档 `…技术设计.md#WAL 文件总大小限制`（`design_extract.md#5.5`） | `wal_throttle_threshold_in_byte` 默认 `214748364800`（200 GB）、**hot_reload**；**实际判定阈值 = 配置值 × 0.8**；旧键 `iot_consensus_throttle_threshold_in_byte` **已废弃**且优先级更高、读到即打 WARN —— 文档只写了旧键（`iot_consensus_throttle_threshold_in_byte`）且未给默认值。 | 功能 `[口径待标定]` |
| R-W42 | `WALManager.java:200-219`（WARN 文案 `StorageEngineMessages(en):813-816`）、`IoTConsensusServerImpl.java:303-322,1334-1340`、`IoTConsensusConfig.java:450-451`、`LogDispatcher.java:424-425`（`source_grounding.md §7.1`/`§7.2`、`§10.4`）；`…技术设计.md#WAL 文件总大小限制`（`design_extract.md#5.5`） | 存在**两套互不相同**的阻写：WALManager 侧（按 WAL 磁盘占用）**不阻塞、不抛异常**，只更积极地删过期文件 + 快照/刷盘，并打 WARN `WAL disk usage {} is larger than the wal_throttle_threshold_in_byte * 0.8 {}, please check your write load…`；IoTConsensus 侧**阻塞写线程**（默认 30s）后返回 `WRITE_PROCESS_REJECT`，日志 INFO `[Throttle Down] index:{}, safeIndex:{}`；文档口径"由 IoTConsensus 导致则阻止客户端写入，否则不影响写入线程"。 | 功能 |

### G 组：内存与队列（R-W43 ~ R-W46）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W43 | `WAL 队列内存控制.md#分析`/`#方案`（`feature_extract.md#B.2`/`#B.3`）；`…技术设计.md#内存控制`（`design_extract.md#3.6`） | 队列控制从"按元素个数"改为"**按当前所有 WAL 队列的总内存**"：`MemoryControlledWALEntryQueue` 封装 `LinkedBlockingQueue`，入队前计算 entry 内存并预占（`cannotReserveMemoryForWalEntry`）、出队后报告释放。 | 功能 `[需白盒]` |
| R-W44 | `WAL 队列内存控制.md#配置参数改动`（`feature_extract.md#B.4`）；模板 `:1084`、`DataNodeMemoryConfig.java:55,375-392`、`IoTDBConfig.java:1084`（`source_grounding.md §1.2#19`）；`…技术设计.md#参数配置`/`#内存控制`（`design_extract.md#2.5`/`#3.6`） | 队列容量键由 `wal_buffer_queue_capacity`（默认 50）改为 **`wal_buffer_queue_proportion`**（默认 `0.1`，即 memtable 内存的 10%，**restart-only**）；与另两个比例之和 ≥1 时只打 WARN；**内存上限的绝对字节阈值文档未提及**。另有 2.0 新增键 `deletion_ahead_log_buffer_queue_capacity`（默认值文档未给）。 | 兼容 `[口径待标定]` |
| R-W45 | `WAL 队列内存控制.md#方案`（`feature_extract.md#B.5`）；`…技术设计.md#内存控制`（`design_extract.md#3.6`） | 阻写（背压）表现 = **阻塞写入线程**（`nonFullCondition.wait()`）而非报错/拒绝；消费线程取出 entry 后 `notifyAll()` 唤醒；`nonFullCondition` 是全局 `private static final Object`，用于避免多队列同时阻写时写入线程收不到唤醒。 | 功能 |
| R-W46 | `WAL 队列内存控制.md#测试验证`（`feature_extract.md#B.6`）；`…技术设计.md#测试计划`（`design_extract.md#6.5`）、TP-16 | 内存受控、防 OOM：原缺陷（`TIMECHODB-1116`：1C1D、DN 堆 12 G、1 database+1 table+1w sensor+100 device+100 batchsize，运行 2~4 小时后 DN OOM，dump 显示 339 个 InsertNode 内存超 4 GB）修复后"运行 1 天+ 无 OOM"；长稳时长**不可在用例里硬等**。 | 性能 |

### H 组：指标与日志可观测（R-W47 ~ R-W51）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W47 | `Metric.java:156-157`、`WalFileMetrics.java:35-48`、`WALManager::getTotalDiskUsage/getTotalFileNum`（`source_grounding.md §9`） | 文件面权威指标：`file_count{name="wal"}` 与 `file_size{name="wal"}`（AutoGauge，**CORE** 级），分别由 `WALManager::getTotalFileNum`/`getTotalDiskUsage` 上报。 | 可观测 |
| R-W48 | `Metric.java:80`、`WritingMetrics.java:215-221`、`WALManager.java:268-270`（`source_grounding.md §9`） | `wal_node_num{name="wal_nodes_num"}` 存在，值 = 已分配 WALNode 数（应与 §3 目录数一致）。 | 可观测 |
| R-W49 | `Metric.java:82,85`、`WritingMetrics.java:222-294,346-393`（`source_grounding.md §9`） | `wal_buffer{name=…}`：`used_ratio`、`entries_count`、`wal_entry_num_for_one_tsfile`、`serialized_wal_buffer_size`、`wrote_wal_buffer_size`、`wal_compress_cost`、`wal_uncompress_cost`、`read_wal_buffer_size`、`read_wal_buffer_cost`、`write_wal_buffer_cost`；`wal_cost{stage=make_checkpoint\|serialize_wal_entry\|sync_wal_buffer}`；`wal_queue_mem_cost{name=wal_queue_current_mem_cost\|wal_queue_max_mem_cost}`。 | 可观测 |
| R-W50 | `WritingMetrics.java:592-607,768-802,647-654`、`WALNode.java:556,649-650`（`source_grounding.md §9`） | `wal_node_info{name=effective_ratio_info\|oldest_mem_table_ram_when_cause_snapshot\|oldest_mem_table_ram_when_cause_flush, type=<walNodeId>}` 按 WALNode **动态创建**（仅在有 WALNode 后出现）；`flush_memtable_count{type="wal_flush_memtable_count"}` 为 Counter。 | 可观测 |
| R-W51 | 文档 `design_extract.md#6.1`/`#6.2`/`#9.1-1`、`feature_extract.md#A.6`/`#B.6`/`#E`；`logback-datanode.xml:225`、`source_grounding.md §10.8`/`§13.2` | 日志/指标口径事实：三份文档**零日志关键字、零指标名**（唯一监控项名在图片里）；源码中"删除 N 个过期 WAL 文件""effective information ratio"等**结论文案是 DEBUG 级**，默认 `root level="info"` **不落盘**；i18n 有 en/zh 两套；监控缺口 = 无"每 WALNode 文件数""快照次数""被删除文件数"指标。 | 可观测 |

### I 组：参数合法性与热加载（R-W52 ~ R-W56）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W52 | `source_grounding.md §1.2`（模板 `iotdb-system.properties.template:1919-2030`）、`§12-1` | 模板 WAL 段恰好声明 **14 个 WAL 主键**；`source_grounding.md §1.2` 给出 **19 项**完整清单（17 个 WAL 主键 + `dn_wal_dirs` + `wal_buffer_queue_proportion`），逐键 grep 模板应命中。 | 功能 |
| R-W53 | 模板 `:1929-2014`、`:287`、`:1082`（`source_grounding.md §1.4`）、`DECISIONS.md §3.1-1` | **restart-only 8 键**：`wal_mode`、`max_wal_nodes_num`、`wal_buffer_size_in_byte`、`wal_entry_size_limit_in_byte`、`wal_file_list_cache_enabled`、`wal_cache_shrink_clear_enabled`、`dn_wal_dirs`、`wal_buffer_queue_proportion`；其余（含 `wal_file_size_threshold_in_byte`、`wal_throttle_threshold_in_byte`、`enable_wal_compression`、`delete_wal_files_period_in_ms`、`wal_min_effective_info_ratio`、`*_snapshot_*`、两个 fsync 键）为 **hot_reload**。 | 兼容 |
| R-W54 | `ConfigurationFileUtils.java:102,665-672`、`ConfigManager.java:1927-1932`（`source_grounding.md §1.1`、`§12-6`） | `SET CONFIGURATION` 对 `effectiveMode: restart` 的键会返回 `restart is required` 提示；hot_reload 键即时生效、**不得**出现该提示。 | 功能 |
| R-W55 | `IoTDBDescriptor.java:1829-1830,1836-1838,1844-1846,2212-2224,2232-2254,2257-2264`、`DataNodeMemoryConfig.java:384-392`（`source_grounding.md §1.3`） | 取值校验不是"无脑赋值"：多数键要求 `> 0` 才 set（0/负数**静默回落默认值**）；`wal_mode` 用 `WALMode.valueOf(...)`，非法值抛 `IllegalArgumentException`（启动失败）；`wal_buffer_queue_proportion` 与另两比例之和不小于 1 时只打 WARN（不拒绝）。 | 功能 |
| R-W56 | `ConfigurationFileUtils.java:384-390`、`IoTDBConfig.java:3885`、`§1.5` | `FIRST_START` 键与**模板中不存在的键**会被 `SET CONFIGURATION` 直接丢弃（如 `wal_cache_shrink_clear_enabled` 不在模板里，只能改文件+重启）；`iot_consensus_cache_window_time_in_ms` 全仓无消费者（**死配置**，配了行为无差异）。 | 功能 |

### J 组：OBJECT 一期（R-W57 ~ R-W63）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W57 | `V2.0.8.1-…新增 OBJECT 类型一期-需求分析.md#功能描述`（`feature_extract.md#C.1`） | OBJECT 的二进制内容**单独存储**，TsFile 中只记一个指向真实存储位置的引用；查询默认只返回引用与二进制大小，需 `READ_OBJECT` 才能读真实内容（对照 BLOB：TsFile 直接存真实内容）。 | 功能 |
| R-W58 | `ObjectNode.java:144-155,157-165,178-195`、`WALNode.java:286-290,911-938`、`WALEntry.java:82-83,141-143`、`WALInfoEntry.java:117`（`source_grounding.md §11`） | **WAL 中只存引用**：`ObjectNode.serializeToWAL` 只写 `isEOF`+`offset`+`filePath`+`content.length`（不写内容本体）；entry 类型 `WALEntryType.OBJECT_FILE_NODE`；共识转发时懒加载对象文件内容，**对象文件已被 TTL 删除则跳过该条目**（源码注释明说，跳过文案为 DEBUG）。 | 功能 |
| R-W59 | `…需求分析.md#存储`/`#限制`/`#多盘策略`（`feature_extract.md#C.1`） | 真实文件根目录 `${data_dir}/object_data`；默认（`restrict_object_limit=false`）各级为 **Base32（RFC 4648，仅 A-Z 与 2-7）** 编码：`<dataRegionId>/${B32(tableName)}/${B32(tag1)}/…/${B32(field)}/<timestamp>.bin`；置 true 时不做编码（原始名，含非法字符则元数据/写入报错）；多盘配置对 OBJECT 生效。 | 功能 |
| R-W60 | `…需求分析.md#功能描述`（`feature_extract.md#C.1`、`#C.3`） | **每个 OBJECT 数据点都会在磁盘上生成一个对应文件**；写放大系数恒为 1（BLOB 为 2+合并次数）；该类型仅适合"写频低、单值大"且一般搭配 TTL 使用。 | 功能 |
| R-W61 | `…需求分析.md#SQL 写入`（`feature_extract.md#C.1`） | `to_object(isEOF, offset, content)` 分段写入三条约束：①只写了部分片段时查询该 Object 显示 **null**，写完才能查到；②本次 `offset` **不等于**已写入大小 ⇒ **本次写入报错**；③已写入部分数据后本次 `offset=0` ⇒ **清除之前已写入的部分、重新写入**。 | 功能 |
| R-W62 | `…需求分析.md#单个对象大小限制`/`#访问控制`/`#限制`（`feature_extract.md#C.5`） | `max_object_file_size_in_byte` 默认 **4 GB**、**hot_reload**、**仅 SYSTEM 权限可改**；`restrict_object_limit` 默认 `false`、`effectiveMode: first_start`（**启动后不可修改**）。 | 安全 |
| R-W63 | `…需求分析.md#导入导出`/`#共识协议`（`feature_extract.md#C.1`/`#C.2`）；`source_grounding.md §11` | 导入导出/LOAD 一期为"**二期评审时，继续补充**"（无一期断言依据）；"写入成功但未落盘时重启是否必须可恢复"文档**未提及**；附录可用结论：导入导出无需改 TsFile 内容，只需把实体文件放到接收端 tsfile 所在 region 对应目录，且 TsFile 里的 `${dataregionid}` 是"无用值、每次被替换"。 | 兼容 |

### K 组：安全 / 性能 / 兼容（R-W64 ~ R-W68）

| 编号 | 来源 | 需求描述（一句） | 类型 |
| --- | --- | --- | --- |
| R-W64 | `WAL 预写日志.md#1.4. 数据安全`/`#4.2`/`#5`/`#7`、`…技术设计.md#安全性设计`（`design_extract.md#7.1-14`）；`WALFileUtils.java:326-335`、`WALManager.java:150-165`、`§13.2` | WAL 含用户操作，高安全场景**需加密**（自查表："数据存储是否需加密"=是、"敏感数据是否需加密"=是、"加密算法是否符合安全标准"=否）；**文档未给参数名/默认值/算法**；源码中**没有独立 WAL 加密开关**，跟随 TSFile `encrypt_type`，加密时文件名追加后缀、`existsEncryptedFile()` 可判定。 | 安全 |
| R-W65 | `…技术设计.md#设计目标`/`#WAL 压缩`/`#测试计划`（`design_extract.md#6.5`）、`WAL 压缩功能设计.md#WAL 对 I/O 资源的影响`/`#预期效果`（`feature_extract.md#A.3`、`#C.3`） | 性能/选型量级（**只作方向性，不作门禁**）：WAL 占 `InsertTablets`/`InsertRecords` 磁盘使用量 **67% / 88%**（各写 20 分钟）；压缩开启后"节约 I/O 资源 30% 左右"（10 万设备/10 序列/请求 1000/每设备 1 行/单 HDD）；"原本会快速 OOM 的大请求场景运行 1 天+ 无 OOM"；OBJECT 写放大恒 1 vs BLOB `2+合并次数`。 | 性能 |
| R-W66 | `IoTDBDescriptor.java:497-500,2779-2785`、`IoTDBConfig.java:1358`、`LogWriter.java:73-74,107-152`（`source_grounding.md §4.1`/`§4.2`）；`WAL 压缩功能设计.md#新增参数`/`#需要确定的内容`（`feature_extract.md#A.2`/`#A.5`） | 压缩实现：算法 = **LZ4**（`CompressionType.LZ4`），开关 `enable_wal_compression` 默认 `true` 且 **hot_reload**；压缩单元 = **一次 sync 批次的 buffer 段**，**段 < 32 KB（`MIN_COMPRESSION_SIZE=32*1024`）不压**，段头 1 字节标 `compressionType` —— 文档算法**未定稿**（候选 GZIP/LZ4/ZSTD，实验用 GZip），压缩率数字未给。 | 功能 `[口径待标定]` |
| R-W67 | `WALInputStream.java:265-270,287-335,487-504`、`WALFileVersion.java:29-32,58-81`（`source_grounding.md §4.3`/`§4.4`）；`WAL 压缩功能设计.md#需要确定的内容`（`feature_extract.md#A.5`） | 兼容/共存：段级压缩标志使"同一文件内既有压缩段又有未压缩段"可读；恢复时未压缩的"半截段"被截断容忍（压缩段需完整 payload）；旧文件兼容靠**文件级 magic**（V1/V2/V3）而非压缩标志 —— 文档给的"先尝试解压、失败按未压缩读"仍列在"需要确定的内容"（未定稿）。 | 兼容 |
| R-W68 | `design_extract.md#1.3`（"IoTConsensusV2：文档未提及"）、`#9.2`、`DECISIONS.md §4.5` | IoTConsensusV2 与"单机模式 vs 分布式模式"的差异在三份文档中**完全未提及**（只出现 IoTConsensus / RatisConsensus / SimpleConsensus / MultiLeader）⇒ 双协议对照只作差异记录，不作文档符合性判定。 | 兼容 |

**§1 统计**：共 **68 条**；类型分布 **功能 43 / 可观测 11 / 兼容 10 / 安全 2 / 性能 2**；
其中 `[口径待标定]` **11 条**、`[需白盒]` **5 条**（R-W05、R-W06、R-W20、R-W34、R-W43）。
来源分布（按"来源"列出现的文件计）：引用 `source_grounding.md` 的 **43 条**、引用 `design_extract.md` 的 **36 条**、引用 `feature_extract.md` 的 **15 条**（部分条目同时引用源码与飞书文档，故三者之和大于 68）。

---

## §2 覆盖矩阵

> - 覆盖方式：**硬断言**（可判 `FAIL`）/ **仅 WARN**（进 `v_warnMessage`）/ **仅记录证据**（只打日志，供事后复核）。
> - 未覆盖的行写 `—`，并在 §4 单列条目号、原因与所需条件。
> - 「数据面」= `count/sum/min/max` + 单设备全序列指纹（`cmp_fp_tree` / `cmp_fingerprint` / `cmp_tree_table` 等 `lib/cmp.sh` helper），是**唯一能判 FAIL 的面**（`DECISIONS.md §1`）。
> - 用例集合与脚本名以 `cases.tsv` 为准；`--set` 集合见 `tools/run_all.sh`（`smoke|mode|recover|file|compress|cleanup|mem|object|param|observe|ha|all`）。
> - **首轮实跑范围（用户 2026-10-16 决定）**：核心 12 条、单协议 IoTConsensus = `W-00, W-01, W-02, W-03, W-04, W-05, W-08, W-11, W-12, W-14, W-17, W-23`（下表用 **★** 标出这 12 条）。

### A 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W01 redo-only | ★W-04, W-05, W-07 | 硬断言 | 用"故障/重启后可完整恢复"反证 redo 生效；无 undo 无法直接断言（本来就不该有） |
| R-W02 先写 WAL | ★W-00, ★W-04, W-05 | 硬断言 | "未 flush + kill -9 后数据不丢"是"先写 WAL"的最强黑盒证据 |
| R-W03 Entry ↔ WritePlanNode | ★W-04, W-05, W-07, W-19 | 硬断言 | 覆盖 InsertRow/InsertTablet/DeleteData/OBJECT 四类 entry 的**应用结果**（不解析字节） |
| R-W04 写入链路与代价 | ★W-00, ★W-11, ★W-23 | 仅记录证据 | 链路无黑盒直读点；只用 `file_count{name="wal"}` 增长与日志计数佐证"WAL 子系统确实在动" |
| R-W05 三 Buffer 不变量 | — | — | 见 §4-U01（`[需白盒]`） |
| R-W06 线程模型 | — | — | 见 §4-U02（`[需白盒]`；W-17 只数"阻塞写入线程"，不足以覆盖线程模型） |

### B 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W07 一个 WALNode = 一个目录 | ★W-00, ★W-04, W-10 | 硬断言 | 目录存在 + 目录内多文件；"每 node 一个目录"由目录层级验证 |
| R-W08 协议与 WALNode 数 | W-06, W-10, W-26 | 硬断言 | IoTConsensus 下用目录数佐证"每 region 一个"；Ratis/Simple 见 §4-U03 |
| R-W09 三策略语义 | W-10 | 仅记录证据 | MultiLeader 环境不存在（§4-U03）；策略选择配置项文档未给 ⇒ 只记录 |
| R-W10 源码策略选择 | W-10 | 硬断言 | `max_wal_nodes_num=0` 相：目录名为纯整数（Elastic）；集群下 FirstCreate 优先（§6-13） |
| R-W11 unique id 规则 | W-10 | 仅记录证据 | 由目录名反推 `<db>-<regionId>` 或纯整数，不做 FAIL |
| R-W12 目录 = `<walDir>/<identifier>` | ★W-00, W-10, W-24 | 硬断言 | 目录存在 + 命名匹配（正则见 §6-6 现场标定） |
| R-W13 `max_wal_nodes_num` 默认/回落/standalone | W-10, W-21, W-22 | 硬断言 | 生效值读取 + `-5` 回落 0；"集群下不生效"作 WARN 记录（§6-13） |
| R-W14 `dn_wal_dirs` vs `wal_dirs` | W-22, W-24 | 硬断言 | 静态 grep：只有 `dn_wal_dirs`；自定义目录确实生效；默认值 `data/datanode/wal` 首轮实测回填（§6-6） |
| R-W15 Ratis 强制 DISABLE | — | — | 见 §4-U03（环境无 RatisConsensus 集群） |
| R-W16 目录/命名可观测项 | ★W-00, W-10, W-24 | 仅记录证据 | 创建 INFO 文案计数 + 真实目录树打印（首轮回填 `wal_dir_roots`） |

### C 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W17 文件名格式（文档 vs 源码） | ★W-00, ★W-08 | 硬断言 | 取并集校验：文件名必须匹配源码正则 `^_\d+-\d+-[01]\.wal$`，并同时记录是否符合文档的 `^_\d+\.wal$` |
| R-W18 checkpoint 命名/唯一/3MB 滚动 | ★W-00, ★W-14 | 硬断言（唯一性）+ 仅记录证据（3 MB 滚动） | 每个 WALNode 目录 `.checkpoint` 计数 ≤1 且 ≥1；>3 MB 滚动见 §4-U06 |
| R-W19 文件名正则 + statusCode | ★W-00, ★W-08, ★W-23 | 硬断言 | 第 3 段非 0/1 即 FAIL |
| R-W20 Metadata / Segment / Entry 二进制字段 | W-04, W-12 | 仅记录证据 | 需离线解析；用"恢复结果 + `wal_magic_cnt`（`WAL-V2`）"替代，严格判定见 §4-U07 |
| R-W21 文件版本 magic V1/V2/V3 | W-04, W-12 | 仅记录证据 | `wal_magic_cnt` 命中数即"确实是 WAL 文件"的过程证据；破损/回退分支见 §4-U07 |

### D 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W22 `wal_mode` 枚举/语义 | ★W-01, W-21 | 硬断言 | 生效值必须等于配置值；三值枚举外的值启动失败 |
| R-W23 DISABLE → WALFakeNode | ★W-02 | 仅记录证据 | DISABLE 生效相记录"无 `.wal` 文件"；假节点失败文案只作证据 |
| R-W24 集群拒 DISABLE | ★W-02, W-26 | 硬断言 | 启动失败 + 文案子串（源码原文，双语匹配） |
| R-W25 校验只在 `isFirstStart()` | ★W-02 | 硬断言 | "已初始化节点不被拒"必须作为独立相记录（反直觉但源码确定） |
| R-W26 V2 `batch` 允许 DISABLE | ★W-02, W-26 | 仅记录证据 | V2 相未显式写 `stream` 时如实记"该模式允许 DISABLE，不成立"，不判 FAIL |
| R-W27 fsync 延迟键（文档 vs 源码） | ★W-01, W-22 | 仅记录证据 | 两个键只对**实测存在**者断言存在性/生效值；文档缺口如实记录（§6-8） |
| R-W28 `wal_buffer_size_in_byte` 32M vs 16M | W-09, W-22 | 硬断言 | 先读生效值再断言；数值冲突记 WARN |
| R-W29 `wal_file_size_threshold_in_byte` 30M vs 10M | ★W-08, W-22 | 硬断言 | 只断言"调小后文件数变多"+生效值；不写死 30M/10M（§6-2） |
| R-W30 `wal_entry_size_limit_in_byte` 超限写失败 | — | — | 见 §4-U04（需构造超大单条 entry） |

### E 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W31 未刷盘数据重放可查 | ★W-04, W-05, W-06, W-07, ★W-12, W-13, W-19, W-20 | 硬断言 | 本 skill 的**核心判据**：kill -9 / 重启后 count/sum/指纹一条不少 |
| R-W32 恢复流程/粒度/删文件 | ★W-04, W-05 | 仅记录证据 | 流程步骤不可逐步断言；"删文件是否等于恢复成功"文档未声明（§4-U08） |
| R-W33 恢复 INFO 序列 | ★W-04, W-06, ★W-12 | 硬断言 | 4 条完成序列 + 1 条前置条件（源码 `source_grounding.md §8.2`）按序出现 |
| R-W34 checkpoint 过滤算法 | W-05, W-14 | 仅记录证据 | 需解析 checkpoint 的 `Type` 字节序列（§4-U07） |

### F 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W35 无效定义 + 三种不可删原因 | ★W-05, ★W-14, ★W-17 | 硬断言（原因①）+ 仅记录证据（②③） | 反向断言"未 flush 部分不得被误删"优先级最高；pin/共识未消费见 §4-U09 |
| R-W36 `delete_wal_files_period_in_ms` | ★W-14, W-22 | 硬断言 | 默认 20000 + hot_reload 生效（调小后更快删）+ 热改日志文案 |
| R-W37 常规整理 + statusCode=0 才可删 | ★W-14 | 硬断言 | `min(version_id)` 需白盒读 checkpoint（§4-U09）；"statusCode=1 与最后一个文件恒保留"作不判清零的依据 |
| R-W38 `wal_min_effective_info_ratio` | W-15, W-22 | 硬断言（方向） | 只判"占比变化 → 快照/刷盘行为方向"，不判 `<`/`≤` 等号；"最宽松相"用 0.01 而非 0（§6-9） |
| R-W39 快照阈值/次数（含歧义） | W-16, W-22 | 硬断言（方向） | 只判"次数上限起作用（转 flush）"，不判默认 1 的归属（§6-10） |
| R-W40 快照 vs 刷盘 + INFO 文案 | W-15, W-16 | 硬断言 | 日志二选一（`snapshots memTable` / `flushes memTable`）+ `flush_memtable_count{type="wal_flush_memtable_count"}` 增量 |
| R-W41 `wal_throttle_threshold_in_byte` | ★W-17, W-22 | 硬断言 | 只配新键；旧键触发废弃 WARN 作"配错键"的旁证（§6-7） |
| R-W42 两套 throttle 表现 | ★W-17, W-25 | 硬断言 | WALManager WARN（不阻塞）与 IoTConsensus `[Throttle Down]`（阻塞）"任一出现即场景成立"（§6-8） |

### G 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W43 按总内存控制队列 | W-18 | 仅记录证据 | 队列内部实现需 dump/白盒；黑盒只记录堆与 `wal_queue_mem_cost` 指标 |
| R-W44 队列容量键替换 + 绝对阈值缺失 | W-18, W-22 | 硬断言（键存在性）/ 仅 WARN（绝对上限） | 生效键必须是 `wal_buffer_queue_proportion`（restart-only，默认 0.1）；旧键与绝对字节阈值如实记录 |
| R-W45 阻写 = 阻塞 + 唤醒 | ★W-17, W-18 | 硬断言 | `wal_blocked_writers`>0 / 写入变慢 / 解除后数据一条不丢 |
| R-W46 防 OOM / 长稳 | W-18, W-25 | 硬断言（无 OOM）+ 仅 WARN（长稳） | `wal_oom_cnt` 必须为 0 是硬断言；绝对内存值与"1 天+"时长只 WARN |

### H 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W47 `file_count`/`file_size{name="wal"}` | ★W-00, ★W-11, ★W-14, ★W-23 | 硬断言（存在性 + 方向） | 写入后 >0、清理/压缩对照后回落；V2 口径差异见 §6-1 |
| R-W48 `wal_node_num{name="wal_nodes_num"}` | W-10, ★W-23 | 硬断言 | 存在且与目录数一致；不一致先按 §6-13 标定 |
| R-W49 `wal_buffer` / `wal_cost` / `wal_queue_mem_cost` | ★W-11, ★W-12, ★W-17, W-18, ★W-23 | 硬断言（存在性） | 标签逐个存在性检查；数值方向只 WARN |
| R-W50 `wal_node_info` / `flush_memtable_count` | W-15, W-16, ★W-23 | 硬断言（存在性） | 动态创建特性：仅在有 WALNode 后出现，首轮打印清单 |
| R-W51 日志口径（DEBUG/零关键字/i18n） | ★W-14, ★W-23 | 硬断言（禁令）+ 仅 WARN（缺失） | **断言不得建立在 DEBUG 文案**（如"删除 N 个过期 WAL 文件"）；指标缺失只 WARN（版本差异） |

### I 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W52 模板 14 键 / 19 项清单 | W-22 | 硬断言 | 逐键 grep 模板，缺任一即 FAIL |
| R-W53 restart-only 8 键 vs hot_reload | ★W-03, W-22 | 硬断言 | 与源码 restart-only 清单逐项核对 SET 返回串 |
| R-W54 SET 的 `restart is required` 提示 | ★W-03, W-22 | 硬断言 | 双向断言：restart-only 键**必须含**、hot_reload 键**不得含** |
| R-W55 取值校验（静默回落 / 启动失败） | W-21, W-22 | 硬断言 | 越界取值不得静默接受（启动失败或回落默认值 + 文案） |
| R-W56 `FIRST_START`/模板缺失键被丢弃 + 死配置 | W-21, W-22 | 硬断言 | SET 后生效值必须仍为默认 |

### J 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W57 OBJECT 单独存储/READ_OBJECT | W-19 | 硬断言 | `READ_OBJECT(s1)` 返回内容与写入字节一致 |
| R-W58 WAL 只存引用 | W-19 | 硬断言（方向性） | 同时间戳小/大对象的 WAL 体积差 **远小于**内容差；不做线性阈值（§6-14） |
| R-W59 `object_data` 路径 + Base32 | W-19 | 硬断言 | 存在数字层 + Base32 层 + `.bin`；**不**校验 `${dataRegionId}` 精确值 |
| R-W60 每个数据点一个文件 / 写放大 | W-19 | 仅记录证据 | 文件数与数据点数量级对照；写放大系数只记录（§4-U15） |
| R-W61 `to_object` 分段写入三条约束 | W-19 | 硬断言 | 5 字节分 2/2/1 段写入后 `LENGTH`=5、内容为 `X'696F746462'` |
| R-W62 `max_object_file_size_in_byte` / SYSTEM 权限 | W-22 | 仅记录证据 | 默认值与"仅 SYSTEM 可改"记录；>4 GB 构造见 §4-U15 |
| R-W63 LOAD/导入 + 重启一致性未定义 | W-20 | 仅记录证据 | 只断言"可读且与写入前一致"；不可构造时 `warn "场景不可构造"`（§4-U16） |

### K 组

| 条目 | 覆盖用例 | 覆盖方式 | 备注 |
| --- | --- | --- | --- |
| R-W64 WAL 加密 | — | — | 见 §4-U05（无独立开关，需求未给参数名；需 TSFile 加密环境） |
| R-W65 性能量级（67%/88%、30%、1 天+） | ★W-01, W-09, ★W-11 | 仅 WARN | 环境与负载口径不可复现（`DECISIONS.md §2`） |
| R-W66 压缩 = LZ4 段级 + <32 KB 不压 | ★W-11, W-12, W-13, W-22 | 硬断言（开关/体积方向 + `wal_compress_cost`） | 具体压缩率只 WARN；场景有效性先确认段 >32 KB（§6-3） |
| R-W67 压缩/未压缩共存 + 旧文件兼容 | W-13 | 硬断言 | "老段未压缩 + 新段压缩"两批数据都必须完整恢复，失败留逐副本证据、不预先降级 |
| R-W68 IoTConsensusV2 / 单机差异未提及 | W-26 | 仅记录证据 | 只作协议间差异记录，不作符合性判定 |

**§2 统计**：覆盖行 **63 条**（按"覆盖方式"首档计：**硬断言 46 条 / 仅记录证据 16 条 / 仅 WARN 1 条**；
另有 **4 条**同时含"仅 WARN"作为次要档，如 R-W44、R-W46、R-W51、R-W65）；
未覆盖行 **5 条**（R-W05、R-W06、R-W15、R-W30、R-W64）；首轮 12 条核心用例覆盖到的条目共 **35 条**。

---

## §3 逐条用例的构造与判据（27 条）

> 27 条全部登记；脚本名与 ID 与 `cases.tsv` **逐字一致**。其中 **12 条脚本尚未落地**
> （`W-11`、`W-14`、`W-15`、`W-16`、`W-18`、`W-19`、`W-20`、`W-21`、`W-22`、`W-23`、`W-25`、`W-26`；
> `cases.tsv` 注明"未落地的由 selftest 报 `planned`，不算失败"），本节按**已设计的判据**全部登记，落地时以本节为准。
> 每条格式：`覆盖 / 场景与相位 / 关键配置 / 硬判据（FAIL） / 只 WARN / 场景有效性断言 / 风险依赖`。
> **信号来源**只有五类：**目录面**（`wal_dir_roots`/`wal_file_cnt`/`wal_dir_bytes`/`wal_ckpt_cnt`/`wal_node_dirs`/`wal_ls`/`wal_magic_cnt`）、
> **指标面**（`wal_metric_*` 系列，`http://<dn>:9092/metrics`，端口 `DN_METRIC_PORT=9092`）、
> **日志面**（`wal_log_sum`/`wal_log_tail`，文件 `log_datanode_all.log`/`log_datanode_wal.log`）、
> **数据面**（`count/sum` + 指纹，`count(*)/row_sum`/`cmp_fp_tree`/`cmp_fingerprint`）、
> **配置面**（`wal_eff`=`cmp_eff`（table 方言 `show configuration` 读运行期生效值）/`wal_props_get`（读配置文件落盘值）/`wal_set`）。
> 所有用例串行执行（并行会互相污染 WAL 文件与日志计数），库名一律 `root.wal…`。

#### W-00 冒烟（骨架门禁）（脚本：`cases/common/wal_smoke.sh`）

- 覆盖：R-W02, R-W04, R-W07, R-W12, R-W16, R-W17, R-W18, R-W19, R-W47
- 场景与相位：清集群 → 写 DN 配置 → 启动 → 建库 `root.walsmoke` + `WAL_DEVS` 个设备 → 写 `WAL_BATCHES` 批（每批 `WAL_ROWS` 点）
  → **记 WAL 目录基线**（`wal_ls` / `wal_file_cnt` / `wal_dir_bytes` / `wal_ckpt_cnt` / `wal_magic_cnt` + 指标口径 `wal_metric_file_cnt` / `wal_metric_file_bytes`）
  → `flush` → 读数与指纹 → 收尾三件套。单相位、无重启、无参数变更，目的是保证 harness 端到端可用。
- 关键配置：`WAL_EXTRA_DEFAULT`（`wal_mode=ASYNC`〔模板 `:1930`，restart-only〕、`enable_wal_compression=true`〔`:2030`，hot_reload〕、
  `wal_file_size_threshold_in_byte=31457280`〔`:1981`，hot_reload〕、`wal_buffer_size_in_byte=33554432`〔`:1959`，restart-only〕、
  `delete_wal_files_period_in_ms=20000`〔`:2009`，hot_reload〕、`max_wal_nodes_num=0`〔`:1939`，restart-only〕，全部见 `source_grounding.md §1.2`）；
  写入期用 `CMP_EXTRA_WRITE`（三类合并全关）避免合并把 WAL 变无效而干扰观测。
- 硬判据（FAIL）：① **场景有效性**：`flush` 后 `wal_file_cnt` 跨 DN 求和 ≥1（目录面，否则 `fail "场景无效：WAL 目录没有文件"`）；
  ② 目录名匹配 `<db>-<regionId>` 或纯整数（R-W12，目录面）；③ 文件名匹配源码正则 `^_\d+-\d+-[01]\.wal$`（R-W19，目录面，并同时打印是否符合文档的 `^_\d+\.wal$`，见 §6-2）；
  ④ 每个 WALNode 目录 `.checkpoint` 计数 ≤1（R-W18，目录面）；⑤ 数据面 `count/sum/min/max` + `cmp_fp_tree` 与写入值一致（R-W02，数据面）；
  ⑥ 收尾三件套：`check_sync_lag` 归零、`consistency_check` 逐 DN 比对一致、`check_logs` 无异常（数据面 + 日志面）。
- 只 WARN：WALNode↔DataRegion 映射与目录命名规则（R-W16，文档未给）；目录创建 INFO 文案命中数（`create folder {} for wal node-{}.`）；
  `file_count{name="wal"}` 与 `find` 计数是否一一对应（R-W47，口径见 §6-1）；出现 6 字节量级的空 `.wal` 文件（源码 `WALWriter.java:90-96` 允许）。
- 场景有效性断言：WAL 文件数为 0 / `flush` 未完成 / 数据面读数与写入不符 / `wal_dir_roots` 返回空 ⇒ 直接 `fail "场景无效：…"`（`DECISIONS.md §1`）。
- 风险/依赖：`wal_dir_roots` 定位靠"配置键（`dn_wal_dirs`，兼容旧名 `wal_dirs`）→ 探测 `data/wal`、`data/datanode/wal` → `find` 兜底"；
  `dn_wal_dirs` 真实默认值 `data/datanode/wal`（模板 `:293`）**尚未在集群 `show configuration` 实测**，本用例第一轮必须把真实目录树打印并回填 §6-6 与 `wal_dir_roots` 优先级。

#### W-01 wal_mode 模式矩阵（脚本：`cases/common/wal_mode_matrix.sh`）

- 覆盖：R-W22, R-W27, R-W65
- 场景与相位：A 相 `wal_mode=ASYNC`：清集群/写配置/启动 → 写入 → 记 WAL 目录、指标与耗时 → **优雅重启**（`cluster_stop`/`cluster_start`）→ 复查数据不丢；
  B 相 `wal_mode=SYNC` 同流程。两相各自独立清集群，保证"生效值"干净。
- 关键配置：`WAL_MODE=ASYNC|SYNC`（`env.conf` 默认 `ASYNC`）；`wal_mode` 三值枚举 `{DISABLE,SYNC,ASYNC}`（`WALMode.java:23`）、默认 `ASYNC`、**restart-only**（模板 `:1929`）；
  `wal_async_mode_fsync_delay_in_ms`=1000（模板 `:1946`，hot_reload）、`wal_sync_mode_fsync_delay_in_ms`=3（`:1953`，hot_reload）；
  SYNC 下写入等 `waitForResult()`、ASYNC 下立即返回（`WALInfoEntry.java:59-60`、`AbstractResultListener.java:69-83`）。
- 硬判据（FAIL）：① 两模式重启后数据面指纹与写入一致（R-W22，数据面）；② 两模式 WAL 目录都应有 ≥1 个 `.wal` 且文件名合规（目录面）；
  ③ `wal_eff <h> wal_mode` 读回的生效值必须等于配置值（配置面 —— 不等于即 FAIL，防"配置没写进去"）；
  ④ `wal_async_mode_fsync_delay_in_ms` / `wal_sync_mode_fsync_delay_in_ms` 在模板中必须存在（配置面，静态 grep）。
- 只 WARN：两模式的耗时/文件数/字节数对照（R-W65，环境噪声大、文档只给方向性结论）；两个 fsync 键只在源码存在、飞书文档不存在（R-W27）⇒ 只记录 `SET CONFIGURATION` 返回串。
- 场景有效性断言：指定模式后 `wal_eff` 读回的生效值不等于该模式 ⇒ `fail "场景无效：模式未生效"`；两相写入量差异 >20% ⇒ 记录并以较小者为准重跑对照。
- 风险/依赖：**假设**框架 `cluster_write_conf` 能正确落盘 restart-only 键并重启生效；优雅重启会正常刷盘，因此本用例**不能**判 ASYNC 的持久性边界（那由 W-04 覆盖）；
  集群端 `SET CONFIGURATION`/`show configuration` 是否暴露这两个 fsync 键未实测（§6-5）。

#### W-02 集群下 DISABLE 必须被拒绝（负向门禁）（脚本：`cases/common/wal_mode_disable_rejected.sh`）

- 覆盖：R-W23, R-W24, R-W25, R-W26
- 场景与相位：**必须清 data 后首启**（校验只在 `isFirstStart()` 执行）→ 写 `wal_mode=DISABLE` → 启动 → 期望 DN 启动失败；
  对照相写 `wal_mode=ASYNC` 期望正常起；第三相把已初始化节点的 `wal_mode` 改为 DISABLE 再重启，**记录"未被拒"**（源码确定的预期行为）。
  V2 相必须显式写 `iot_consensus_v2_mode=stream` 才期望被拒。
- 关键配置：`WAL_MODE=DISABLE`；判定条件在 `IoTDBStartCheck.java:150-163`（经 `DataNode.java:530 checkSystemConfig()` → `AbstractIoTDBStartCheck.java:83-88`）；
  `iot_consensus_v2_mode` 默认 `batch`（`IoTDBConfig.java:1178`），`batch`/`stream` 常量在 `ConsensusFactory.java:47-48`。
- 硬判据（FAIL）：① `IoTConsensus` 相：DN **启动失败**且日志含
  `Configuring the WALMode as disable is not supported under IoTConsensus and IoTConsensusV2 stream mode`（`DataNodeMiscMessages.java:1353-1355`，日志面；中文 locale 命中 zh 文案）；
  ② V2 + `stream` 相同文案；③ 对照相 `ASYNC` 能正常起并写入成功（数据面）；④ 清 data 后 `iotdb-system.properties` 确实不存在（前提硬断言）。
- 只 WARN：V2 相若未显式写 `stream`（默认 `batch`）⇒ 如实记"该模式允许 DISABLE，不成立"（R-W26），**不判 FAIL**；
  DISABLE 生效后 `WALFakeNode` 的行为（R-W23）只记录"无新增 `.wal` 文件"与失败文案。
- 场景有效性断言：**若节点不是首次启动**（`iotdb-system.properties` 仍存在）⇒ 校验被跳过 ⇒ `fail "场景无效：非首次启动，DISABLE 校验被跳过"`；
  `kill_stale_nodes`/端口占用导致"启动失败"另有他因时，必须在日志里确认失败原因是该文案而不是端口/激活问题。
- 风险/依赖：`isFirstStart()` 依赖 `iotdb-system.properties` 是否存在（`SystemPropertiesHandler.java:140-142`）；"清数据后首启是否足以让该文件消失"未在集群实测（框架 `clean_env` 行为见 `DECISIONS.md`）；
  本用例的"启动失败"相会与 `check_logs` 的异常扫描冲突 ⇒ 该相必须单独排除预期 ERROR（参考 `metadata_skill` 的 `MD_LOG_BENIGN_EXTRA` 做法）。

#### W-03 wal_mode 的 restart-only 语义（脚本：`cases/common/wal_mode_restart_only.sh`）

- 覆盖：R-W53, R-W54
- 场景与相位：启动（`ASYNC`）→ 记基线 → `wal_set wal_mode SYNC` 记录返回文案 → **不重启**继续写入（运行期应仍按 ASYNC）→
  重启 → 逐节点 `wal_eff_all` 核对生效值（两相各一次重启）。
- 关键配置：`wal_mode` restart-only（模板 `:1929 # effectiveMode: restart`）；提示逻辑 `ConfigManager.java:1927-1932`，模式解析 `ConfigurationFileUtils.java:665-672`；
  `FIRST_START` 键会被丢弃（`ConfigurationFileUtils.java:384-390`）。
- 硬判据（FAIL）：① `SET CONFIGURATION 'wal_mode'='SYNC'` 返回串**必须含** `restart is required`（R-W54，配置面文案）；
  ② 不重启期间逐节点 `wal_eff wal_mode` 仍为 `ASYNC`（R-W53，配置面）；③ 重启后逐节点生效值均为 `SYNC`（配置面）；
  ④ `wal_props_get wal_mode` 显示配置文件已写入新值（配置面，证据）；⑤ 两相数据面一致（数据面）。
- 只 WARN：运行期"行为差异"（写入耗时/刷盘节奏）无法硬判，只记录；返回文案的精确措辞（英文/中文）只记录。
- 场景有效性断言：返回串既无 `restart is required` 也无"设置成功"字样 ⇒ `fail "场景无效：SET CONFIGURATION 未生效"`；
  不重启期间生效值就变成了 `SYNC`（说明该键实际是热加载）⇒ 也不能算场景无效，但必须记 WARN 并回填 §6-5。
- 风险/依赖：**假设** `wal_mode` 的模板 `effectiveMode` 真为 `restart`（源码已确认，且 `loadWALHotModifiedProps` 不含 `wal_mode`，`WALManager` 构造时已按启动值选定策略）；
  本用例与 W-22 的全键热加载清单有重叠 —— W-22 覆盖全部 19 键、本用例只深挖 `wal_mode` 的"不重启不变 / 重启生效"两段语义。

#### W-04 掉电恢复（WAL 重放）（脚本：`cases/common/wal_recovery_kill9.sh`）

- 覆盖：R-W01, R-W02, R-W03, R-W07, R-W20, R-W21, R-W31, R-W32, R-W33
- 场景与相位：清集群/写配置/启动 → 建库写数据（**不 flush**）→ 等 `WAL_KILL_WAIT_SEC`（默认 60s）写入稳定 →
  记录目录面 + 指标面基线 → `wal_kill9_dn` **逐个** `kill -9` 全部 DN（`WAL_KILL_MODE=9`；`cases.tsv` 明确"只杀 1 个只验证共识补齐，不是掉电语义"）→
  全集群拉起 → `wal_wait_replay`（窗口 `WAL_REPLAY_WIN_SEC=300`）→ 数据面逐设备比对。
- 关键配置：`wal_mode=ASYNC`（默认 ASYNC 相）+ 可选 `SYNC` 相；`WAL_KILL_MODE=9`；**不 flush** 是场景成立的前提；
  恢复入口 `StorageEngine.java:261-268`、`WALRecoverManager.java:74-145`、`WALNodeRecoverTask.java:82-158`。
- 硬判据（FAIL）：① 重启后 `count/sum` + `cmp_fp_tree` 逐设备与写入完全一致（R-W31，**数据面 = 最终判据**）；
  ② **场景有效性**：kill 前 WAL 目录非空（R-W02，目录面）且 `wal_metric_file_cnt`>0（指标面）；
  ③ 恢复日志序列按序出现：`Start recovering wal.` → `Data regions have submitted all unsealed TsFiles, …` →
  `Start recovering WAL node in the directory {}` → `Successfully recover WAL node …, add this node to WALManger.` → `Successfully recover all wal nodes.`（R-W33，日志面，`source_grounding.md §8.2`）；
  ④ 前置条件文案必须出现在"恢复完成"文案之前（顺序断言）。
- 只 WARN：`R-W32`（恢复流程逐步不可断言）；`R-W20`/`R-W21`（Entry 类型与 Metadata 需离线解析）；`wal_magic_cnt` 命中数；
  恢复后 WAL 文件数是否下降（恢复后直接刷盘，`design_extract.md §4.3`；且 statusCode=1 与最后一个文件恒保留，`source_grounding.md §6.2`）。
- 场景有效性断言：kill 前 WAL 文件数为 0、`kill -9` 未真的杀掉进程（`pgrep com.timecho.iotdb.DataNode` 仍在）、DN 未在 `DN_DOWN_WAIT_SEC` 内退出 ⇒
  `fail "场景无效：故障未发生 / WAL 不存在"`；重启未完成（`dn_state` 非 Running）⇒ 同样 fail。
- 风险/依赖：**假设** RF=3 下 kill 全部 DN 后仍能靠各自的 WAL + 共识完整恢复；节点时钟偏差不影响本用例（不用时间戳判定）；
  恢复文案取自 i18n 英文原文，中文 locale 需双语匹配（`source_grounding.md §10.8`）；若 V2 相出现"单副本不落盘"，按 `DECISIONS.md §2` 只 WARN。

#### W-05 flush 边界对照（脚本：`cases/common/wal_recovery_flush_boundary.sh`）

- 覆盖：R-W01, R-W02, R-W03, R-W31, R-W32, R-W34, R-W35
- 场景与相位：A 相"写入后立刻 `kill -9` 全部 DN"（数据只能靠 WAL 重放）；B 相"写入 + `flush` + 等 TsFile `Async close` 后 `kill -9`"
  （数据已在 TsFile、对应 WAL 记录已失效）。两相各自独立清集群/启动，避免残留 WAL 干扰。
- 关键配置：同 W-04；B 相需 `WAL_CLOSE_WIN_SEC=60` 等落盘（沿用 `cmp_wait_close`/`ensure_closed` 的"反复 flush + 等新 `Async close`"经验，见 TTL skill 踩坑）；
  失效定义见 `…技术设计.md#WAL 检查点及 MemTable 快照`（`design_extract.md#5.1`）。
- 硬判据（FAIL）：① 两相数据面都完整一致（R-W31，数据面）；② A 相 kill 前 WAL 非空，而 B 相 `flush` 后 `wal_file_cnt`/`wal_dir_bytes` 明显下降（R-W35 正向侧，目录面 + `file_size{name="wal"}` 指标面）；
  ③ B 相 TsFile 确有新 `Async close` 证据（场景有效性前置，文件面）；
  ④ B 相不得因"数据只在 TsFile 里"而查不到（数据面）。
- 只 WARN：`R-W32`/`R-W34`（流程与 checkpoint 过滤算法无外部信号）；B 相"是否还有残余 WAL 文件"（`safelyDeletedSearchIndex=Long.MAX_VALUE` 下 statusCode=1 与最后一个文件恒保留，`source_grounding.md §6.2`）只记录，不判"必须清零"；
  "B 相重放量比 A 相小"只作对照证据。
- 场景有效性断言：B 相 `flush` 后无任何 TsFile `Async close` 证据 ⇒ `fail "场景无效：数据未落盘"`；
  A 相 kill 前 WAL 文件数为 0 ⇒ `fail "场景无效：WAL 不存在"`。
- 风险/依赖：**假设** flush 后对应 WAL 记录确实失效；`flush` 不保证三副本同时关闭 TsFile（TTL skill 实测某副本晚 5 分钟）⇒ 断言按"已落盘副本"算并打印逐副本证据；
  两相写入量必须严格一致，否则文件数对照无意义。

#### W-06 DN 正常下线期写入 + 恢复（脚本：`cases/common/wal_recovery_dn_down.sh`）

- 覆盖：R-W08, R-W31, R-W33
- 场景与相位：启动 3C3D → `wal_stop_dn`（**优雅停**，对照 W-04 的 kill -9）→ 期间继续写入（RF=3 应成功）→
  等 `DN_DOWN_WAIT_SEC`（180s）/ `DN_RECOVER_WAIT_SEC`（300s）→ `wal_start_dn` 拉起 → 等数据补齐 → 逐个停 DN 比对副本。
- 关键配置：`DN_DOWN_WAIT_SEC=180`、`DN_RECOVER_WAIT_SEC=300`、`DATA_RF=3`、协议默认 `IoTConsensus`；`wal_stop_dn` 用 `sbin/stop-datanode.sh -f`。
- 硬判据（FAIL）：① 下线期间写入不报错且写入量达到目标（数据面）；② 拉起后该 DN 数据补齐、`consistency_check`（逐个停 DN 后查询并与全在线基准比对）一致（数据面）；
  ③ 该 DN 重启时出现 WAL 恢复日志序列（R-W33，日志面）；④ `wal_metric_file_cnt`/`wal_file_cnt` 在下线→恢复过程中有非零波动（指标面/目录面）。
- 只 WARN：补齐耗时段（环境相关）；`R-W08` 的"每 region 一个 WALNode"只通过目录数佐证，不判精确值；上线期间可能出现 `Failed to CHANGE_REGION_LEADER` 类噪声（参照 `metadata_skill` 的 BENIGN 清单）。
- 场景有效性断言：DN 未真正停止（`pgrep` 仍有进程）/ 写入在单副本下被拒 / 恢复后 `check_sync_lag` 未归零 ⇒ `fail "场景无效：…"`。
- 风险/依赖：**假设** IoTConsensus 在 1 副本短暂离线时仍可写入（RF=3 → 2/3 多数派）；优雅停会触发 flush，
  因此本用例考察的是"共识补偿 + WAL/快照补齐"，**不是掉电语义**（掉电语义归 W-04）；停机期间该 DN 的 WAL 目录状态只作证据。

#### W-07 元数据变更后的 WAL 恢复（脚本：`cases/common/wal_recovery_metadata.sh`）

- 覆盖：R-W01, R-W03, R-W31
- 场景与相位：启动 → 建库/建序列/写数据 → `DELETE TIMESERIES` / `DROP DATABASE` 相关操作（**不 flush**）→ `kill -9` 全部 DN → 重启 →
  校验 schema 与数据一致。
- 关键配置：同 W-04；库名 `root.walmeta…`（避免跨用例污染）；schema 比对用排序后的行集合（`SHOW TIMESERIES` / `COUNT TIMESERIES`）。
- 硬判据（FAIL）：① 重启后 schema 行集合与 kill 前一致（R-W03，元数据面/数据面，用集合比对而非 grep）；
  ② 存活序列的数据面 `count/sum` 一致（R-W31，数据面）；③ 恢复日志序列出现（R-W33，日志面）；④ kill 前 WAL 非空（场景有效性，目录面）。
- 只 WARN：元数据恢复的**不可恢复项**（DROP 后重建的库/序列语义）如实 WARN；`DeleteDataNode` 类型只记录"删除生效"这一行为面，不解析 Entry 字节；
  **文档未明确 schema 变更是否走客户端 WAL**（只写"WAL Entry 对应一个 WritePlanNode"）⇒ schema 侧判据降级为"记录 + WARN"。
- 场景有效性断言：kill 前 WAL 目录为空 / 元数据变更未真正执行（`SHOW TIMESERIES` 行数无变化） ⇒ `fail "场景无效：…"`。
- 风险/依赖：**假设**元数据与数据共用同一条共识/恢复链路；若实测发现 schema 恢复不依赖 WAL，按"记录 + WARN"处理，不判产品缺陷；
  元数据面断言依赖 CN 与 DN 的 schema 一致（收尾 `consistency_check` 已覆盖）。

#### W-08 WAL 文件轮转阈值（脚本：`cases/common/wal_file_rotate.sh`）

- 覆盖：R-W17, R-W19, R-W29
- 场景与相位：A 相 `wal_file_size_threshold_in_byte=WAL_ROTATE_THRESHOLD_SMALL`（默认 1048576，1 MB，**hot_reload**，用 `wal_set` 热改）→ 同写入量；
  B 相用默认生效值 → 同写入量；两相对照文件数与单文件大小。**同一用例内先读生效值**（`wal_eff`）再写断言。
- 关键配置：`wal_file_size_threshold_in_byte` 源码默认 `31457280`（模板 `:1981`，hot_reload），文档另写 10 MB（`design_extract.md#2.5`）⇒ `[口径待标定]`；
  轮转判据 `originalSize() >= threshold`（`WALBuffer.java:697-725`）；`WAL_ROTATE_MIN_FILES=2`。
- 硬判据（FAIL）：① A 相 `.wal` 文件数 ≥ `WAL_ROTATE_MIN_FILES` 且**显著多于** B 相（R-W29，目录面 + `file_count{name="wal"}` 指标面）；
  ② 文件名全部匹配 `^_\d+-\d+-[01]\.wal$`（R-W19，目录面）；③ A 相生效值必须等于写入值（配置面，hot_reload ⇒ 热改后不重启即读）；
  ④ 轮转前后数据面指纹一致（轮转不得丢数据，数据面）。
- 只 WARN：`R-W17` 的"文档 `^_\d+\.wal$` vs 源码三段式"如实记录（两写法并存，取并集）；单文件"未压缩累计写入量不超过阈值 + 余量"无法黑盒直读（判据用 `originalSize()`，压缩态磁盘长度更小，见 §6-3）；
  小体积空 `.wal` 文件现象。
- 场景有效性断言：A 相只产生 1 个 WAL 文件（阈值没生效 / 写入量不足）⇒ `fail "场景无效：阈值未触发轮转"`；
  生效值不等于写入值 ⇒ `fail "场景无效：阈值配置未生效"`。
- 风险/依赖：**假设** 1 MB 阈值下 `WAL_ROWS × WAL_DEVS × WAL_BATCHES` 的写入量足以触发多次轮转（需首轮实测校准）；
  `wal_set` 的返回串若不提示 restart，说明该键确为 hot_reload（与源码一致）；压缩开启时磁盘文件增长慢于未压缩累计量 ⇒ 只按"文件数"判轮转，不按磁盘字节判阈值。

#### W-09 `wal_buffer_size_in_byte`（脚本：`cases/common/wal_buffer_size.sh`）

- 覆盖：R-W28, R-W65
- 场景与相位：A 相 `wal_buffer_size_in_byte=WAL_BUFFER_SMALL`（默认 262144，256 KB，**restart-only**）→ 重启 → 写入 → 记录文件数/字节/耗时；
  B 相用默认生效值（源码 33554432，32 MB）同写入量对照。
- 关键配置：`wal_buffer_size_in_byte` 源码默认 33554432（模板 `:1959`，restart-only），文档写 16 MB（`design_extract.md#2.5`）⇒ `[口径待标定]`；
  buffer 实际切成 3 份、一批最多攒 1/3 的 95%（`WALBuffer.java:82-83,193-196`）。
- 硬判据（FAIL）：① 重启后 `wal_eff` 读回值必须等于 256 KB（R-W28，配置面，restart-only ⇒ 必须重启后读）；
  ② 写入后数据面一致（数据面）；③ 两相 WAL 目录都非空、文件名合规（目录面）；④ A 相不得出现 `Fail to allocate wal node-{}'s buffer because out of memory.`（`WALBuffer.java:198/240`，日志面：出现即 FAIL 并保留证据）。
- 只 WARN：文件数/轮转次数/耗时对照（R-W65、`design_extract.md#1.3`）；`R-W28` 的 16M/32M 冲突如实记录；
  buffer 变小是否改变 `wal_buffer{name="used_ratio"}` 分布只作证据。
- 场景有效性断言：重启后生效值不等于配置值 ⇒ `fail "场景无效：buffer 大小未生效"`（restart-only 键热改不生效属预期，但本用例是写配置后重启，必须生效）。
- 风险/依赖：**假设** 256 KB buffer 在 3C3D 下不会引发写入失败；若出现 buffer 分配 OOM，属真实观察 —— 先保留日志与堆证据，再决定是否记为缺陷（`env.conf` 里 `WAL_HEAP_WARN_RATIO=0.9` 只用于 WARN）。

#### W-10 WALNode 分配（脚本：`cases/common/wal_node_alloc.sh`）

- 覆盖：R-W07, R-W08, R-W09, R-W10, R-W11, R-W12, R-W13, R-W16, R-W48
- 场景与相位：A 相 `max_wal_nodes_num=0`（`WAL_MAX_NODES=0`）→ 多库写入 → 记录 WALNode 子目录名与个数（`wal_node_dirs`/`wal_ls`）；
  B 相 `max_wal_nodes_num=2`（restart-only，需重启）→ 同写入 → 记录目录个数。两相都打印 `wal_node_num{name="wal_nodes_num"}`。
- 关键配置：`max_wal_nodes_num` 默认 `0`（模板 `:1939`，restart-only）；策略选择 `WALManager.java:76-85`；Elastic `APPLICATION_NODE_RATIO=4`（`ElasticStrategy.java:41`）；
  IoTConsensus(V2) 下 identifier = `<database>-<regionId>`（`DataRegion.java:806-812`）；模板注释"仅 standalone 有效"（`:1933`）。
- 硬判据（FAIL）：① A 相目录名必须是**纯整数**或 `<db>-<regionId>`（R-W12，目录面），且目录数 ≥1；
  ② `wal_node_num{name="wal_nodes_num"}` 存在且值 = 目录数（R-W48，指标面）；
  ③ 写入后数据面一致（数据面）；④ B 相重启后 `wal_eff max_wal_nodes_num` = 2（配置面）。
- 只 WARN：`R-W13`：**IoTConsensus 下策略恒为 FirstCreate，`max_wal_nodes_num` 不改变 WALNode 数**（`WALManager.java:76-85`）⇒
  B 相"目录数 ≤ 2"预期**不成立**，必须记 `WARN 场景未成立（FirstCreateStrategy 优先）`，**不判 FAIL**（见 §6-13）；
  `R-W09`/`R-W11`（三策略语义、unique id 规则）由目录名反推，只记录；创建 INFO 文案（R-W16）。
- 场景有效性断言：WALNode 子目录数为 0 ⇒ `fail "场景无效：未分配 WALNode"`；A 相生效值不为 0 ⇒ `fail "场景无效：max_wal_nodes_num 未生效"`。
- 风险/依赖：**依赖"先记录真实目录数再判定"**的写法；B 相结论直接决定 §6-13 的标定结果，首轮必须回填；
  若多库写入后目录数仍为 1，属 Elastic 每 4 个申请者开 1 node 的正常表现（`cases.tsv` W-10 已明确"不判场景失败"）。

#### W-11 WAL 压缩开关对照（脚本：`cases/common/wal_compress_toggle.sh`）

- 覆盖：R-W04, R-W47, R-W49, R-W65, R-W66
- 场景与相位：A 相 `enable_wal_compression=true`（默认）→ 写 `WAL_COMPRESS_DEVS × WAL_COMPRESS_ROWS × WAL_COMPRESS_BATCHES`
  → 记 `wal_dir_bytes`/`wal_metric_file_bytes`/`wal_buffer{name="wal_compress_cost"}` 基线；B 相 `enable_wal_compression=false` 同数据量；两相数据面指纹一致。
  **先确认单批段 >32 KB** 再谈压缩率。
- 关键配置：`enable_wal_compression` 默认 `true`、**hot_reload**（模板 `:2030`、`IoTDBDescriptor.java:497-500,2779-2785`，映射为 `CompressionType.LZ4`）；
  段 <32 KB 不压（`LogWriter.java:73-74`）；`WAL_COMPRESS_RATIO_MIN=1.2`（低于此只 WARN）；`WAL_COMPRESS_DEVS=10`/`WAL_COMPRESS_ROWS=2000`/`WAL_COMPRESS_BATCHES=4`。
- 硬判据（FAIL）：① A 相 `wal_buffer{name="wal_compress_cost"}` 必须有非零累计（R-W49，指标面：证明"确实发生了压缩"）；
  ② 两相 `file_size{name="wal"}` / `wal_dir_bytes` 都非零（R-W47，指标面/目录面）；③ A 相总体积**不得大于** B 相（"压缩后反而更大"不合逻辑，R-W66 方向断言）；
  ④ 两相数据面指纹一致（数据面）。
- 只 WARN：具体压缩率/比值（R-W66 只判方向，不达标只 WARN —— 文档算法未定稿、数据可压性差异极大，`DECISIONS.md §2`）；
  段 <32 KB 导致小批量下两相无差异（§6-3）；`R-W65`（文档"节约 I/O 30%"只作方向性）；`R-W04`（链路无黑盒直读点）。
- 场景有效性断言：A 相 `wal_compress_cost` 为 0 **且** 单文件普遍 <32 KB ⇒ `fail "场景无效：压缩未发生（段太小）"` —— 这是本用例最容易出问题的地方（§6-3）；
  两相写入量不一致 ⇒ `fail "场景无效：写入量不可比"`。
- 风险/依赖：**假设**上述写入量能产生 >32 KB 的 sync 批次段（`WALBuffer` 一批最多 1/3 buffer 的 95%，32 MB/3×0.95 ≈ 10 MB 上限，故需保证单批足够大）；
  B 相 `enable_wal_compression=false` 后必须确认生效值（`wal_eff`）；压缩率达不到 `WAL_COMPRESS_RATIO_MIN` 只 WARN，不得据此判产品问题。

#### W-12 压缩态掉电恢复（脚本：`cases/common/wal_compress_recovery.sh`）

- 覆盖：R-W20, R-W21, R-W31, R-W33, R-W49, R-W66
- 场景与相位：`enable_wal_compression=true` + 未 flush 写入（单批 >32 KB）→ `kill -9` 全部 DN → 重启 → 数据面完整校验（走段解压路径 `WALInputStream.java:487-504`）。
- 关键配置：`WAL_COMPRESSION=true`；`wal_mode=ASYNC`；`WAL_REPLAY_WIN_SEC=300`；段头 1 字节 compressionType、`Uncompressed Size` 仅压缩段存在（R-W20 的白盒口径）。
- 硬判据（FAIL）：① 重启后数据一条不少（R-W31，数据面）；② 恢复日志序列出现（R-W33，日志面）；
  ③ **场景有效性**：WAL 文件存在且开启压缩时的总体积小于未压缩基线（需 >32 KB 单批，R-W66，目录面/指标面）；
  ④ 不得出现 `Unexpected error when loading a wal segment {} in {}@{}` / 大量 `Fail to read WALEntry from wal file …`（日志面）。
- 只 WARN：`wal_buffer{name="wal_uncompress_cost"}` 是否有非零累计（R-W49 侧，解压成本只在恢复期产生，可能采不到）；
  `R-W20`/`R-W21`（段/魔数二进制细节）只记录 `wal_magic_cnt`。
- 场景有效性断言：WAL 目录为空 ⇒ `fail "场景无效：无 WAL 可重放"`；压缩态体积不小于未压缩基线 ⇒ 记 `warn "场景未成立（段 <32KB 未压）"` 并按 §6-3 重设写入量。
- 风险/依赖：**假设**压缩段在 kill -9 后能被完整恢复（源码 `WALInputStream.java:265-270` 只对**未压缩**半截段做截断容忍，压缩段需完整 payload）
  ⇒ 若丢的正是最后一批半截压缩段，需区分"半个段不可恢复（源码设计如此）"与"已 sync 成功的数据丢失（真缺陷）"，判据以 sync 完成后的批次为准。

#### W-13 压缩开关切换后的共存恢复（脚本：`cases/common/wal_compress_mixed.sh`）

- 覆盖：R-W31, R-W66, R-W67
- 场景与相位：未压缩态写入（不 flush）→ **重启并开启压缩** → 再写一批 → `kill -9` 全部 DN → 重启 → 两批数据都必须完整。
- 关键配置：`enable_wal_compression` hot_reload（可热改，但本用例故意重启切换，模拟"升级/改配置"路径）；段级压缩标志（`LogWriter.java:136-152`）+
  文件级 `WALFileVersion` magic（`WALFileVersion.java:29-32`）⇒ "老段未压缩 + 新段压缩"是**设计支持**的组合（`DECISIONS.md §4.3` 已把 W-13 从"无依据"升级为"设计支持、可构造"）。
- 硬判据（FAIL）：① 重启后两批数据（老批 + 新批）都完整（R-W31，数据面，硬断言）；
  ② 恢复过程不得出现段加载失败 ERROR（`Unexpected error when loading a wal segment …`，日志面）；
  ③ 切换前后生效值符合预期（配置面）；④ kill 前 WAL 非空（场景有效性，目录面）。
- 只 WARN：`R-W66`（切换前后体积对照只作参考）；`R-W67` 中"文档要求的先试解压、失败按未压缩读"是否真正实现无法黑盒区分 ⇒ 只记录恢复是否成功。
- 场景有效性断言：切换后生效值未变（压缩开关没生效）⇒ `fail "场景无效：压缩开关切换未生效"`；两批写入量过小（<32 KB）⇒ 记 WARN 并重设。
- 风险/依赖：**失败即真发现**（留逐副本证据），不预先降级 WARN —— 本用例测的是"老段与新段共存恢复"这一文档标注为"需要确定的内容"（`feature_extract.md#A.5`）的路径，
  属于文档未定稿但源码有实现的分支；与 W-12 的区别是"同一 WALNode 目录内混合两种段"。

#### W-14 无效 WAL 清理（脚本：`cases/common/wal_cleanup_period.sh`）

- 覆盖：R-W18, R-W34, R-W35, R-W36, R-W37, R-W47, R-W51
- 场景与相位：写入 → `flush`（数据落盘后对应 WAL 记录即无效）→ `wal_set delete_wal_files_period_in_ms WAL_CLEAN_PERIOD_SMALL_MS`（默认 2000，hot_reload）
  → 在 `WAL_CLEAN_WIN_SEC=180` 窗口内观察文件数/字节下降（三口径交叉：`wal_file_cnt` 目录 + `file_count{name="wal"}` + `file_size{name="wal"}`）；
  **反向相位**：未 flush 的部分不得被误删。
- 关键配置：`delete_wal_files_period_in_ms` 默认 `20000`（模板 `:2009`，hot_reload）；热改后删除线程重启（`IoTDBDescriptor.java:2711-2715`），日志应出现
  `Reboot wal delete thread successfully, current period is {} ms`；清理规则 `WALNode.java:671-676`（statusCode=0 且 version_id < `subscriptionRetainedMinVersionId` 且无 active/pinned memTable）。
- 硬判据（FAIL）：① 窗口内 `file_count{name="wal"}` 或目录文件数**下降**（R-W47/R-W37，指标面 + 目录面）；
  ② 出现 `Reboot wal delete thread successfully, current period is {} ms`（R-W36，日志面）；③ **反向断言**：未 flush 的数据对应 WAL 不得被删（R-W35，目录面：发一批新数据后立即记录文件数，确认清理周期内该批对应文件仍在）；
  ④ 清理前后数据面一致（数据面）。
- 只 WARN：`R-W34`（checkpoint 的 `min(version_id)` 需白盒读）；`R-W18` 的"3 MB 滚动"（§4-U06）；
  **不得**断言 `WALNode.java:466-470` 的 `Successfully delete {} outdated wal files for wal node-{}` —— 该文案是 **DEBUG、默认不落盘**（R-W51，§6-12）。
- 场景有效性断言：热改后生效值不是 2000 ⇒ `fail "场景无效：删除周期未生效"`；`flush` 后 TsFile 无 `Async close` 证据 ⇒ `fail "场景无效：数据未落盘，WAL 不可能无效"`。
- 风险/依赖：**IoTConsensus 下 `safelyDeletedSearchIndex=Long.MAX_VALUE`** ⇒ 只有 statusCode=0 的文件可删、statusCode=1 与最后一个文件恒保留
  （`source_grounding.md §6.2`）⇒ **不得**断言"WAL 目录清零"（§6-13）；`flush` 不保证三副本同时关闭 TsFile（按已落盘副本判定并打印逐副本证据）。

#### W-15 `wal_min_effective_info_ratio`（脚本：`cases/common/wal_min_effective_ratio.sh`）

- 覆盖：R-W38, R-W40, R-W50
- 场景与相位：写入使 WAL 出现"有效信息占比低"的形态（长尾 MemTable 不刷盘）→ 热改 `wal_min_effective_info_ratio` 调大/调小
  → 观察"快照 vs 刷盘"的选择方向变化（判据 = 指标方向 + INFO 文案 + 文件面）。
- 关键配置：`wal_min_effective_info_ratio` 默认 `0.1`、**hot_reload**（模板 `:1989`）；触发条件 `WALNode.java:506-510`；ratio 定义 `WALNode.java:438-455`；
  **设 0/负数不生效**（`IoTDBDescriptor.java:2222-2224`，`>0` 才 set）⇒ "最宽松相"用 0.01 而不是 0（§6-9）。
- 硬判据（FAIL）：① 调大阈值后出现 `WAL node-{} snapshots memTable-{} to wal files because …` 或 `WAL node-{} flushes memTable-{} to TsFile {} because …` 之一（R-W38/R-W40，日志面，两句都是 INFO）；
  ② `wal_node_info{name="oldest_mem_table_ram_when_cause_snapshot"|"oldest_mem_table_ram_when_cause_flush", type=<walNodeId>}` 之一出现非零值（R-W50 侧，指标面）；
  ③ 数据面全程一致（数据面）；④ 阈值生效值 = 写入值（配置面）。
- 只 WARN：**`<` 与 `≤` 的等号边界不判**（R-W38 `[口径待标定]`，文档两种写法并存）；`WALNode.java:116-118` 的 `memTableSnapshotCount`（内存 `ConcurrentHashMap`、不落盘、无指标）**不作判据**（R-W51，`DECISIONS.md §3.1-6`）；
  `effectiveInfoRatio` 精确值只出现在 DEBUG 文案（`WALNode.java:456-461`），不落盘 ⇒ 只判"是否触发了快照/刷盘"这一方向。
- 场景有效性断言：调大阈值后既无快照也无刷盘文案、且生效值正确 ⇒ `fail "场景无效：未构造出低有效占比场景"`（需先增大写入量/减少 MemTable 刷盘）；
  用 0 当"最宽松"相导致配置未生效 ⇒ `fail "场景无效：ratio=0 被忽略仍为 0.1"`。
- 风险/依赖：**依赖"抑制刷盘"的手段在集群上可构造**（`design_extract.md` TP-22 也标注"抑制刷盘手段需现场标定"）；
  若长尾 MemTable 迟迟不出现，本用例应如实记 WARN 并回填经验窗口，**不得**把"没触发"直接判成产品问题。

#### W-16 MemTable 快照（脚本：`cases/common/wal_memtable_snapshot.sh`）

- 覆盖：R-W39, R-W40, R-W50
- 场景与相位：`wal_memtable_snapshot_threshold_in_byte` 调小（`WAL_SNAPSHOT_THRESHOLD_BYTES`）→ 触发快照 → 再逼近 `max_wal_memtable_snapshot_num`
  边界 → 观察"超上限转 flush"（文件面出现新 TsFile）。
- 关键配置：`wal_memtable_snapshot_threshold_in_byte` 默认 `8388608`（8 MB，hot_reload，模板 `:1996`）、`max_wal_memtable_snapshot_num` 默认 `1`（hot_reload，模板 `:2002`）；
  选择逻辑 `WALNode.java:546-559`。
- 硬判据（FAIL）：① 出现快照或刷盘 INFO 文案之一（R-W40，日志面）；② `wal_node_info{name="oldest_mem_table_ram_when_cause_snapshot"|"…cause_flush"}` 出现非零（R-W50，指标面）；
  ③ `flush_memtable_count{type="wal_flush_memtable_count"}` 在因 WAL 触发刷盘时递增（R-W40，指标面）；④ 数据面一致（数据面）。
- 只 WARN：**默认 `max_wal_memtable_snapshot_num=1` 的归属不判**（"允许 1 次快照后刷盘" vs "首次即刷盘"，文档两种写法并存，R-W39 `[口径待标定]`）；
  阈值 `>` 与 `≥` 的等号边界不判；快照次数本身无指标（R-W51）⇒ 只判"次数上限起作用（转 flush）"。
- 场景有效性断言：阈值调小后既不出现快照也不出现刷盘 ⇒ `fail "场景无效：快照/flush 均未触发"`；生效值未变 ⇒ `fail "场景无效：阈值未生效"`。
- 风险/依赖：触发条件难以精确控制（`design_extract.md` TP-26 评注"触发条件难精确控制"）；快照期间"MemTable 不可修改"的语义文档未定义
  （TP-27 判为"不可观测"）⇒ 本用例只断言"不丢数据、最终一致"，不对并发写入的表现下结论。

#### W-17 WAL 阻写（throttle / 背压）（脚本：`cases/common/wal_throttle.sh`）

- 覆盖：R-W35, R-W41, R-W42, R-W45, R-W49
- 场景与相位：`wal_set wal_throttle_threshold_in_byte WAL_THROTTLE_SMALL`（默认 10485760，10 MB，**hot_reload**）+ 持续高速写入
  → 观察阻写迹象 → 停止压力后校验数据一条不丢。
- 关键配置：真实键 **`wal_throttle_threshold_in_byte`**（默认 `214748364800`，200 GB，hot_reload，模板 `:2016`）；**实际阈值 = 配置值 × 0.8**（`WALManager.java:256-262`）；
  `iot_consensus_throttle_threshold_in_byte` **已废弃**且优先级更高、读到即打 WARN（`IoTDBDescriptor.java:143-145,2278-2286`）⇒ 仅作旁证；
  IoTConsensus 侧阈值默认 50 GB、超时 30s（`IoTConsensusConfig.java:450-451`）。
- 硬判据（FAIL）：① 出现阻写迹象之一：`wal_blocked_writers`>0（jstack 计数）/ 写入明显变慢 / `wal_queue_mem_cost{name="wal_queue_current_mem_cost"}` 上升（R-W45/R-W49，指标面 + 线程面）；
  ② 出现 WALManager WARN `WAL disk usage {} is larger than the wal_throttle_threshold_in_byte * 0.8 {}, please check your write load…` 或
  IoTConsensus INFO `[Throttle Down] index:{}, safeIndex:{}` 之一（R-W42，日志面，"任一出现即场景成立"）；
  ③ 阻写解除后数据一条不丢（数据面）；④ 全程不得出现 `OutOfMemoryError`（数据面/日志面）。
- 只 WARN：阻写在小规模下**能否触发**（R-W41 `[口径待标定]` —— 文档阈值语义/默认值在文档间不一致，无法触发时记"场景未成立"+WARN）；
  "谁先触发"（WALManager 磁盘侧 vs IoTConsensus 队列侧，两套机制互不相同）只记录，不判机制差异为缺陷；
  写入耗时绝对值只作证据。
- 场景有效性断言：阈值热改后生效值不等于 10 MB ⇒ `fail "场景无效：阻写阈值未生效"`；压力足够但 `file_size{name="wal"}` 与队列内存都无上升 ⇒ `fail "场景无效：未制造出 WAL 压力"`；
  若日志出现 `iot_consensus_throttle_threshold_in_byte` 的废弃 WARN ⇒ 说明键配错，先纠正再判场景（§6-7）。
- 风险/依赖：**假设**在 3C3D（内存充足）下能用 10 MB 阈值 + 高速写入触发阻写；`×0.8` 的折扣意味着实际触发点更低（更易触发）；
  阻写语义是"阻塞写入线程（`nonFullCondition.wait()`）、消费后唤醒、不报错"（R-W45），因此**不能**把"写入变慢/卡住"判成缺陷，除非超时不返回或数据丢失。

#### W-18 大压力下 WAL 队列内存受控（脚本：`cases/common/wal_queue_memory.sh`）

- 覆盖：R-W43, R-W44, R-W45, R-W46, R-W49
- 场景与相位：高并发大写入（`WAL_PRESSURE_DEVS`/`WAL_PRESSURE_ROWS`，窗口 `WAL_PRESSURE_WIN_SEC=300`）→ 期间采集
  `wal_queue_mem_cost{name="wal_queue_current_mem_cost"|"wal_queue_max_mem_cost"}` + `wal_heap_ratio` + `wal_blocked_writers` → 结束后校验写入成功与数据一致。
- 关键配置：`wal_buffer_queue_proportion` 默认 `0.1`（模板 `:1084`，**restart-only**，桶 = memtable 内存的 10%；与另两比例之和 ≥1 只打 WARN，`DataNodeMemoryConfig.java:384-392`）；
  旧键 `wal_buffer_queue_capacity`（默认 50）已被替换；绝对字节阈值**文档未提及**。
- 硬判据（FAIL）：① `wal_oom_cnt` 必须为 **0**（R-W46，日志面硬断言，扫描 `OutOfMemoryError|GC overhead limit exceeded`）；
  ② DN 进程全程存活（`dn_state` Running，进程面）；③ 压力结束后写入最终成功且数据面一致（数据面）；
  ④ `wal_queue_mem_cost` 两个标签存在（R-W49，指标面）；⑤ 生效键必须是 `wal_buffer_queue_proportion`（R-W44，配置面）。
- 只 WARN：内存绝对值（`wal_queue_current_mem_cost`/`wal_heap_ratio` 与 `WAL_HEAP_WARN_RATIO=0.9`）**只作证据**（R-W44：文档只给相对口径"memtable 内存的 10%"，无绝对字节阈值）；
  `R-W43`（队列内部实现需 dump/白盒）；旧键 `wal_buffer_queue_capacity` 与 `deletion_ahead_log_buffer_queue_capacity` 只记录存在性（默认值文档未给）。
- 场景有效性断言：压力期间 `wal_metric_queue_max` 始终为 0 且 `wal_blocked_writers` 为 0 ⇒ `fail "场景无效：未制造出队列内存压力"` 或如实记 WARN 并加大压力；
  `/metrics` 不可达 ⇒ `fail "场景无效：指标端点不可用"`（环境问题必须显式暴露）。
- 风险/依赖：**假设**该压力规模能在 3C3D 上把队列内存推高（否则只 WARN 不判 FAIL）；`wal_buffer_queue_proportion` 是 restart-only ⇒ 改它必须重启；
  本用例**不判**"队列内存上限是否等于 memtable 内存的 10%"（无绝对阈值可校验），只判"不 OOM + 指标存在"。

#### W-19 OBJECT 写入的 WAL 恢复（脚本：`cases/common/wal_object_recovery.sh`）

- 覆盖：R-W03, R-W31, R-W57, R-W58, R-W59, R-W60, R-W61
- 场景与相位：表模型建库建表（OBJECT 列）→ `to_object(isEOF,offset,content)` 分段写入（如 100 字节分 40/40/20；参考场景 5 字节分 2/2/1）
  → **不 flush** → `kill -9` 全部 DN → 重启 → `READ_OBJECT` / `LENGTH` 校验。
- 关键配置：`restrict_object_limit` 默认 `false`（Base32 编码路径）、`max_object_file_size_in_byte` 默认 4 GB（两者口径见 `feature_extract.md#C.5`）；
  真实文件根 `${data_dir}/object_data`（`wal_object_root` 探测 `data/datanode/object_data`、`data/object_data`、`object_data`）；`READ_OBJECT(s1)` 返回 BLOB。
- 硬判据（FAIL）：① 重启后 `READ_OBJECT(s1)` 与写入字节**逐字节一致**、`LENGTH(s1)` 正确（R-W57/R-W61，数据面）；
  ② `object_data` 下确有 `.bin`（R-W59，文件面：`wal_object_cnt`>0，且路径层级含数字层 + Base32 层）；
  ③ **WAL 只存引用**：同时间戳分别写小对象与大对象时，WAL 体积增量 **远小于**内容差（R-W58，目录面/指标面，方向性证据）；
  ④ kill 前 WAL 非空（场景有效性，目录面）。
- 只 WARN：`R-W60`（每个数据点一个文件：文件数与数据点数的量级对照只记录）；`R-W61` 三条约束中"offset 不连续报错"的**文案/错误码**只记录；
  `${dataRegionId}` 在 TsFile 中是"无用值、每次被替换"（`feature_extract.md#C.1` 附录）⇒ 路径断言**不校验** dataRegionId 精确值。
- 场景有效性断言：`kill -9` 前 `wal_object_cnt` 为 0（对象没落盘）⇒ `fail "场景无效：OBJECT 实体文件不存在"`；未写完的对象查询应为 null（写入约束三之①，作为反向断言）。
- 风险/依赖：**假设** `object_data` 根目录与 Base32 层级如文档所述（`wal_object_root` 是三个候选路径的经验探测，需首轮实测回填 §6-14）；
  与 `crud_skill` CR-11/CR-12（OBJECT 删除与 GC）严格去重：本用例只做"WAL/重启恢复"这一面（§5）。

#### W-20 导入 OBJECT 数据后重启一致性（脚本：`cases/common/wal_object_load_restart.sh`）

- 覆盖：R-W31, R-W63
- 场景与相位：走 LOAD/导入路径写入 OBJECT（或以等价写入 + 导入语句）→ 完整重启（`wal_restart_all`）→ 校验数据与元数据一致。
- 关键配置：同 W-19；一期文档中"导入导出"明确为"二期评审时继续补充"（`feature_extract.md#C.1`）⇒ **无强语义依据**。
- 硬判据（FAIL）：① 重启后 OBJECT 列可读且与写入前一致（R-W31，数据面）；② schema/表结构一致（元数据面）；
  ③ 场景有效性：导入动作确实执行成功（返回成功且影响行数 >0，不得静默失败）。
- 只 WARN：`R-W63`（"写入成功未落盘时重启是否必须可恢复"文档未提及）⇒ 只断言"可读且一致"，**不声称覆盖全部语义**；
  导入路径是否与普通写入共用同一 WAL 链路（文档未写）只作记录。
- 场景有效性断言：导入命令返回失败 / 影响 0 行 / 版本不支持该语法 ⇒ 如实 `warn "场景不可构造（原因+证据）"` 并记录，**不判 FAIL**（`cases.tsv` W-20 明确要求）。
- 风险/依赖：**关键依赖**：一期 LOAD 对 OBJECT 的语义未定义；历史上 `LOAD` 与 LAST 缓存曾有交叉缺陷（`crud_skill` CR-14）
  ⇒ 若导入路径不可用，与 `crud_skill` CR-14 对齐边界，只记录"OBJECT 写入 → 重启可读"这一面（§5）。

#### W-21 参数合法性（负向）（脚本：`cases/common/wal_param_invalid.sh`）

- 覆盖：R-W13, R-W22, R-W55, R-W56
- 场景与相位：逐项写非法值 → 重启或热改 → 断言"启动失败 + 明确文案"或"回落默认值"，**不得静默接受**：
  `wal_mode=XXX`（枚举外）、负数字节、`0` 阈值、超范围 ratio、`max_wal_nodes_num=-1`。
- 关键配置：校验逻辑全部来自 `source_grounding.md §1.3`：`wal_mode` 用 `WALMode.valueOf(...)` ⇒ `IllegalArgumentException`（启动失败）；
  `max_wal_nodes_num ≤ 0 → 0`；`wal_buffer_size_in_byte`/`wal_file_size_threshold_in_byte`/`wal_min_effective_info_ratio`/`wal_memtable_snapshot_threshold_in_byte`/`max_wal_memtable_snapshot_num`/`delete_wal_files_period_in_ms`/两个 fsync 键均要求 `> 0`；
  `wal_entry_size_limit_in_byte` 无校验但 getter 兜底（`IoTDBConfig.java:2244-2246`）；`wal_buffer_queue_proportion` 与另两比例之和 ≥1 只 WARN。
- 硬判据（FAIL）：① `wal_mode=XXX` ⇒ 节点启动失败且日志有明确异常（R-W55，日志面）；
  ② 负数字节 / 0 阈值写入后，`wal_eff` 生效值**必须等于默认值**（R-W55，配置面，逐键断言）；
  ③ `wal_min_effective_info_ratio=0` ⇒ 生效值仍为 `0.1`（配置面）；④ `max_wal_nodes_num=-1` ⇒ 生效值为 `0`（R-W13，配置面）；
  ⑤ 数据面在合法回落配置下仍可用（数据面）。
- 只 WARN：比例之和 ≥1 的 WARN 文案（R-W55）只记录，不判"必定不生效"；非法值的**措辞**只记录；
  模板缺失键/FIRST_START 键的 SET 被丢弃（R-W56）只判"生效值仍为默认"，不判返回文案。
- 场景有效性断言：写入非法值后 `wal_eff` **读不到该键**（键名写错 / 未落盘）⇒ `fail "场景无效：配置未写入"`；
  期望"启动失败"的相里节点正常起来了，也必须按"场景结果"如实记录（可能真的静默接受 ⇒ 真发现）。
- 风险/依赖：**假设** `show configuration`（table 方言，`cmp_eff` 使用）能列出这些 WAL 键（§6-5）；不在其中时改用 `wal_props_get` 读配置文件对比；
  memory 类键（`wal_buffer_queue_proportion`）可能只在 memory 配置区，需按 `show configuration` 实测决定断言方式。

#### W-22 参数热加载语义（脚本：`cases/common/wal_param_hotload.sh`）

- 覆盖：R-W13, R-W14, R-W27, R-W28, R-W29, R-W36, R-W38, R-W39, R-W41, R-W44, R-W52, R-W53, R-W54, R-W55, R-W56, R-W62, R-W66
- 场景与相位：逐键 `wal_set <k> <v>` → 记录返回文案（哪些含 `restart is required`）→ 与源码 **restart-only 清单**逐项核对
  → 不重启验证行为/生效值不变 → 重启后逐节点核对生效值（`wal_eff_all`）。
- 关键配置：19 项清单（`source_grounding.md §1.2`）；restart-only 8 键（R-W53）；模板 14 键（`:1919-2030`）；`FIRST_START` 键被丢弃（`ConfigurationFileUtils.java:384-390`）；
  `wal_cache_shrink_clear_enabled` 不在模板、`iot_consensus_cache_window_time_in_ms` 死配置（`§1.5`）；非 SYSTEM 用户 SET 必须被拒。
- 硬判据（FAIL）：① 每个 restart-only 键的返回串**必须含** `restart is required`；每个 hot_reload 键**不得含**（R-W54，配置面双向断言）；
  ② 模板逐键 grep 必须命中 14 个 WAL 主键（R-W52，静态检查）；③ 死配置/模板缺失键 SET 后重启生效值仍为默认（R-W56，配置面）；
  ④ 越界值回落（R-W55，配置面）；⑤ 非 SYSTEM 用户 SET 被拒（权限面/错误码）；⑥ restart-only 键热改后不重启期间生效值不变、重启后改变（R-W53）。
- 只 WARN：`R-W28`/`R-W29`/`R-W27`/`R-W38`/`R-W39`/`R-W41`/`R-W44`/`R-W66` 的文档冲突/未给默认值**如实记录生效值**（以集群实测为准）；
  `R-W13` 的"仅 standalone 有效"；`R-W62`（`max_object_file_size_in_byte` 仅 SYSTEM 可改、`restore_object_limit` first_start）只记录；
  `deletion_ahead_log_buffer_queue_capacity` 是否存在只记录；审计日志（配置修改需审计）环境不具备时 WARN。
- 场景有效性断言：`wal_set` 返回空/报错 ⇒ `fail "场景无效：SET 未执行"`；`wal_eff` 读不到被 SET 的键 ⇒ `fail "场景无效：无生效值可核对"`。
- 风险/依赖：**假设**集群端 `show configuration` 覆盖全部 WAL 键（§6-5）；返回文案措辞来自源码 `ConfigurationFileUtils`/`ConfigManager` 逻辑，
  **尚未在集群实测** ⇒ 断言用大小写不敏感子串（`restart is required` / `restart required` 任一命中），中文环境需双语匹配。

#### W-23 WAL 可观测性（脚本：`cases/common/wal_metrics.sh`）

- 覆盖：R-W04, R-W19, R-W47, R-W48, R-W49, R-W50, R-W51
- 场景与相位：启动 → 写入 → **动态发现** `/metrics` 里全部含 `wal` 的时间序列名（`wal_metric_names`）→ 再写入 / `flush` → 对比各指标变化方向；
  同时打印逐 DN 的指标值与目录计数（口径对照）。
- 关键配置：指标名全部来自 `source_grounding.md §9`（`Metric.java:80-85,156-157`）：`file_count{name="wal"}`、`file_size{name="wal"}`、
  `wal_node_num{name="wal_nodes_num"}`、`wal_buffer{name=…10 个}`、`wal_cost{stage=…3 个}`、`wal_queue_mem_cost{name=…2 个}`、
  `wal_node_info{name=…3 个}`、`flush_memtable_count{type="wal_flush_memtable_count"}`；端点 `http://<dn>:$DN_METRIC_PORT/metrics`（默认 9092）。
- 硬判据（FAIL）：① `file_count{name="wal"}` 与 `file_size{name="wal"}` 存在，且写入后 >0、清理后回落（R-W47，指标面）；
  ② `wal_node_num{name="wal_nodes_num"}` 存在且与目录数一致（R-W48，指标面）；③ `wal_buffer` / `wal_cost` / `wal_queue_mem_cost` 各标签存在（R-W49，指标面）；
  ④ `wal_node_info` 与 `flush_memtable_count` 存在（R-W50，指标面）；⑤ 断言中**不得**出现 DEBUG 日志文案（R-W51，禁令）。
- 只 WARN：指标**缺失只 WARN**（版本差异，`DECISIONS.md §2`）；指标数值方向（非存在性）只记录；i18n 双语（R-W51）；
  监控缺口清单（无"每 WALNode 文件数/快照次数/删除数"）作为证据打印（R-W51）；`R-W04` 的链路证据、`R-W19` 的文件名细节只记录。
- 场景有效性断言：`/metrics` 端点不可达或返回空 ⇒ `fail "场景无效：指标端点不可用"`（环境问题必须显式暴露）；
  `wal_metric_names` 一个 `wal` 指标都没发现 ⇒ 先 `fail`（连 `file_count` 都没有说明抓取方式错），再按 WARN 处理缺失项。
- 风险/依赖：**假设** DN metrics 端口暴露 Prometheus 文本格式且含全部 WAL 指标；**V2 下 `file_count`/`file_size` 口径可能不同**
  （单副本不落盘，`DECISIONS.md §2`）⇒ 本用例首轮必须逐 DN 打印指标值 + `find` 计数做对照（§6-1）。

#### W-24 WAL 目录配置（脚本：`cases/common/wal_dir_config.sh`）

- 覆盖：R-W12, R-W14, R-W16
- 场景与相位：把 `dn_wal_dirs` 指向自定义目录（绝对路径，**restart-only**）→ 启动 → 写入 → 断言 WAL 文件落在该目录且默认目录不再新增
  → 重启 → 数据可恢复。
- 关键配置：`dn_wal_dirs` 默认 `data/datanode/wal`（相对 `<IOTDB_HOME>`，模板 `:293`，restart-only，`CommonDescriptor.java:124-128`，逗号分隔多目录）；
  `wal_dir`/`wal_dirs` **键不存在**（`source_grounding.md §1.5`）；目录在启动检查里注册（`IoTDBStartCheck.java:222-224`）。
- 硬判据（FAIL）：① 自定义目录下存在 `<identifier>/_<v>-<i>-<0|1>.wal`（R-W12，目录面）；
  ② 默认目录下**不再**新增 WAL 文件（目录面：需先清空/记基线，旧文件可能残留）；
  ③ 静态检查：模板/配置里只能 grep 到 `dn_wal_dirs`，`wal_dir`/`wal_dirs` 命中必须为 0（R-W14）；
  ④ 重启后数据面一致（数据面）。
- 只 WARN：多目录（逗号分隔）时如何分配文档未提（R-W14）⇒ 只断言"各目录都非空"；目录创建 INFO 文案（R-W16）；`R-W16` 的目录树全量打印。
- 场景有效性断言：自定义目录压根没被创建（该键未生效）⇒ `fail "场景无效：dn_wal_dirs 未生效"`；重启后生效值不等于自定义路径 ⇒ 同样 fail。
- 风险/依赖：**假设**框架 `cluster_write_conf` 能在 restart-only 键上正确落盘并重启生效；目标目录必须已存在或可创建
  （`registerDirectory` 失败会打 `Fail to create wal node allocation strategy because all disks of wal folders are full.` 类 ERROR，`source_grounding.md §10.1-6/7`）。

#### W-25 WAL 盘只读/写不进去（高可用）（脚本：`cases/common/wal_disk_readonly.sh`）

- 覆盖：R-W42, R-W46
- 场景与相位：**探测-判定-降级三段式**：先探测能否让 WAL 目录不可写（DN 以 root 运行 ⇒ `chmod` 无效；按序尝试 `chattr +i` / 独立小文件系统写满造 `ENOSPC`）
  → 可构造则以写入表现（阻塞/报错/降级）如实记录 → 恢复可写 → 校验数据一致；不可构造 ⇒ 如实 `warn "不可构造（原因+证据）"` 并跳过。
- 关键配置：`wal_mode=ASYNC`；`wal_throttle_threshold_in_byte` 默认 200 GB（hot_reload）—— 只读盘是 **I/O 失败**，与主动阻写（R-W42）表现必须区分。
- 硬判据（FAIL）：① 恢复可写后数据面完整一致，或明确报错后无脏数据（R-W46，数据面）；
  ② **不得出现静默丢数据**（写入返回成功但重启后消失）—— 这是本用例唯一能判 FAIL 的点（数据面）；③ 恢复后 `file_count{name="wal"}` 恢复非零（指标面）。
- 只 WARN：写入是"阻塞"还是"报错"本身（文档未定义只读盘行为）⇒ 只记录 + 日志证据；`WALBuffer.java:677-681`/`:727-731`（`Fail to sync/fsync wal node-{}'s log writer, change system mode to error.`）
  等 ERROR 文案如实收集；`chattr +i` 在 ext4 上的可用性只作探测结论。
- 场景有效性断言：目录**并未真的变成只读**（写入照常成功且文件正常增长）⇒ `fail "场景无效：只读未生效"`；
  探测阶段发现无法构造 ⇒ 跳过并记 WARN，**不得**因此记 PASS。
- 风险/依赖：**假设**在 3C3D 上可以安全地把 WAL 目录置只读/写满而不影响 CN 与其他节点（需在恢复阶段确保完全可写）；
  **与 `compaction_skill` 的 DT 系列（磁盘 readonly 高可用）严格去重**：本用例只看"WAL 写入受阻后的数据一致性"（§5）。

#### W-26 双协议对照（脚本：`cases/common/wal_consensus_matrix.sh`）

- 覆盖：R-W08, R-W24, R-W26, R-W68
- 场景与相位：同一 WAL 场景（写入 → 不 flush → `kill -9` 全部 DN → 重启 → 数据完整 + 压缩对照）在 `IoTConsensus` 与 `IoTConsensusV2` 下各跑一遍
  （相位间用 `DATA_CONSENSUS=… cmp_cluster_prepare` 切换），逐项对照并如实记录差异。
- 关键配置：`DATA_CONSENSUS` 由 `tools/run_all.sh --consensus IoTConsensus|IoTConsensusV2` 指定（`env.conf` 默认 `IoTConsensus`）；
  `iot_consensus_v2_mode` 默认 `batch`（`IoTDBConfig.java:1178`）；V2 相**不要设 DISABLE**（R-W26）。
- 硬判据（FAIL）：① 两种协议下数据面各自完整一致（R-W68 佐证，数据面）；② 每种协议 kill 前 WAL 非空（场景有效性，目录面）；
  ③ 指定的协议确实生效（`show cluster`/配置面能看到 `IoTConsensusV2`，配置面）；④ 两相 `file_count{name="wal"}` 口径差异必须打印对照（§6-1）。
- 只 WARN：协议间差异（R-W68：IoTConsensusV2 文档完全未提及 ⇒ 只作差异记录，不作符合性判定）；V2 单副本不落盘导致的 `close 未达 N`（`DECISIONS.md §2`，非本 skill 判据）；
  `R-W08` 的"每 region 一个 WALNode"在 V2 下的目录数差异；V2 相若显式设 `iot_consensus_v2_mode=stream` 才会被拒 DISABLE（R-W24/R-W26）。
- 场景有效性断言：指定的协议未真正生效（看不到对应协议）⇒ `fail "场景无效：协议未切换"`；切换后集群未就绪（`cluster_start` 未达 6/6）⇒ 同样 fail。
- 风险/依赖：**假设** `--consensus` 会落到 `DATA_CONSENSUS` 并写入节点配置；两种协议的 WAL 目录命名规则（`<db>-<regionId>`）已由源码确认（`DataNode.java:806-812`），
  但 **V2 下 `file_count{name="wal"}` 的口径**需逐 DN 对照（§6-1）；V2 相不得设 DISABLE（`cases.tsv` W-26 明确）。

---

## §4 未覆盖 / 不可构造清单

> 逐条给：**条目号**、**原因**、**要覆盖需要什么条件**。共 **20 条**：
> **U-01 ~ U-05 = 完全未被任何用例覆盖**（§2 中标 `—`）；
> **U-06 ~ U-20 = 有覆盖但判据降级**（只能 WARN / 只能记录证据 / 只能部分断言），原因与补齐条件同样列出。
> 判定口径与 `DECISIONS.md §4`（文档未提及 ⇒ 不可构造）一致：**宁可少判，不可错判，也不静默通过**。

### §4.1 完全未被覆盖（5 条）

| 序 | 条目号 | 原因 | 要覆盖需要什么条件 |
| --- | --- | --- | --- |
| U-01 | R-W05（三 Buffer 状态机不变量） | `[需白盒]`：任意时刻"恰有 1 个 working / 1 个 compressed、compressed 不参与切换"是内存内部状态，黑盒（SQL/日志/目录/指标）**无任何读数** | 需要 JDWP / 只读 agent attach（可复用 `ttl_skill` 的 `ttl_full_rc5\agent\` 只读 agent 思路）或 `WALBuffer` 内部状态 dump；或产品在 `/metrics` 上暴露 buffer 状态计数 |
| U-02 | R-W06（线程模型：Serialize/Sync = Node 数、Delete = 1、Recover 仅恢复期） | `[需白盒]`：线程名与计数只能 `jstack` 导出；本 skill 的 `wal_blocked_writers` 只数"阻塞在 `MemoryControlledWALEntryQueue`/`nonFullCondition` 的线程"，**覆盖不了线程模型** | 需要在写入期与恢复期各做一次全量 `jstack`，并解析 `WAL-Serialize`/`WAL-Sync`/`WAL-Delete`/`WAL-Recover` 前缀的线程计数；属只读操作，可作为 W-17/W-04 的附加证据落地 |
| U-03 | R-W15（Ratis 强制 DISABLE + 不注册 WAL 目录）；并含 R-W08 的 SimpleConsensus / MultiLeader 部分 | **环境不支持**：当前 3C3D 只有 `IoTConsensus` / `IoTConsensusV2`；Ratis 强制 DISABLE（`DataNode.java:971-974`）与"Ratis/DISABLE 不创建 WAL 目录"（`IoTDBStartCheck.java:219-225`）都需要 Ratis 集群；MultiLeader 需要支持 MultiLeader 的部署（`FirstCreateStrategy` 强制） | 需要一台可切 RatisConsensus 的集群（WAL 侧只需"节点能起 + WAL 目录不产生 WALNode 子目录"两个断言）+ 一套 standalone/单机版环境（覆盖 R-W13 的"仅 standalone 有效"） |
| U-04 | R-W30（`wal_entry_size_limit_in_byte` 超限写失败） | **构造成本**：默认 `-1` → getter 兜底取 `wal_buffer_size_in_byte`（32 MB，`IoTDBConfig.java:2244-2246`），要写一条序列化后 >32 MB 的单条 entry；该分支**不打日志**，只能从客户端写失败 + 错误码 `WAL_ENTRY_TOO_LARGE` 判定 | 需要先把 `wal_buffer_size_in_byte` 调小（restart-only，可构造，如 1 MB）再写超限的单个 `InsertTablet`/`InsertRecord`；同时要先标定 `-1` 的兜底语义（`wal_eff`/`wal_props_get` 只能看到 `-1`，兜底值需按源码推断） |
| U-05 | R-W64（WAL 加密） | **需求未给 + 环境不支持**：三份文档只写"高安全场景需要加密"，**未给参数名/默认值/算法**；源码中 **没有独立 WAL 加密配置键**，WAL 加密完全跟随 TSFile 的 `encrypt_type`（`WALFileUtils.java:326-335`）⇒ 本 skill 无法独立构造，也没有可断言的开关 | 需要 TSFile 加密集群环境（属 TSFile 加密工程范围）才能测"WAL 文件名出现 `FILE_ENCRYPTED_SUFFIX`"与加密态恢复；参数与算法口径需产品在需求侧补齐 |

### §4.2 有覆盖但判据降级（15 条）

| 序 | 条目号（覆盖用例） | 降级原因 | 要覆盖需要什么条件 |
| --- | --- | --- | --- |
| U-06 | R-W18 的"checkpoint >3 MB 滚动"（W-00/W-14） | **不可稳定构造**：`design_extract.md#2.4` 的 3 MB 常量不可配置，需要海量 MemTable 信息才能把 checkpoint 推过 3 MB | 需要大规模多库/多 region 写入（成本高）或离线构造 checkpoint 文件；当前只为"每 node 目录 checkpoint 计数 ≤1 且 ≥1"保留硬断言 |
| U-07 | R-W20 / R-W21（W-04/W-12） | `[需白盒]`：`Marker=-126`、`MagicString="WAL-V2"`、`WALEntrySizes`/`MemTableIds`、Segment 条件长度字段、Entry 的 `Type` 字节，都需要字节级解析；破损/回退分支需要改文件字节 | 需要 hexdump / 离线 WAL 解析工具（可把文件只读拉到本机解析）；黑盒侧目前只保留 `wal_magic_cnt`（命中 `WAL-V2`）+"恢复结果正确"作为替代证据 |
| U-08 | R-W32 的"删除 WAL Node 下所有文件 ≡ 恢复成功"（W-04/W-05） | **文档未声明因果**：源码只有成功文案 `Successfully recover WAL node in the directory {}, so delete these wal files.`（`WALNodeRecoverTask.java:134-137`），失败路径是否也删未说明 | 需要产品/源码明确失败路径行为；或构造一次"恢复失败"的 WAL 目录观察是否仍被删（属破坏性实验，需独立环境与快照备份） |
| U-09 | R-W35 的原因②③（pipe pin / 未被 IoTConsensus 消费完）+ R-W37 的 `min(version_id)`（W-05/W-14/W-17） | `[需白盒]`：`MemTableInfo.pinCount`、`endFileIndex`、`safeIndex`、`searchIndex` 无外部读数；`min(各 MemTable 首个 WAL version_id)` 需解析 checkpoint 的 `VersionId` 字段 | 需要只读 agent 读 `WALNode`/`CheckpointManager` 内部状态，或离线解析 checkpoint；当前只硬断言原因①（未刷盘不得删）这一条 |
| U-10 | R-W34（checkpoint 过滤算法，W-05/W-14） | `[需白盒]`：需要解析 checkpoint 文件里 `CheckpointEdit.Type`（`0x00` 全局信息 / `0x01` 新建 / `0x02` 刷盘）的**字节序列与顺序** | 需要离线 checkpoint 解析器（可与 U-07 共用一个解析工具）；当前只用"刷盘后清理 + 恢复正确"间接反映 |
| U-11 | R-W39（快照阈值 `>` vs `≥`；`max_wal_memtable_snapshot_num=1` 的归属，W-16） | **文档自相矛盾**（参数条目 vs 章节两种写法），等号边界不可判，且"默认 1 时首次即刷盘还是允许 1 次快照"需实测推断 | 需要产品澄清口径，或做源码级/白盒实验（读 `memTableSnapshotCount` 与 flush/snapshot 分支）；当前只判"调小阈值更易触发"与"次数上限起作用（转 flush）"这两个方向 |
| U-12 | R-W38（`wal_min_effective_info_ratio` 的 `<` vs `≤`，W-15） | 同上（文档两种写法并存）；另有"设 0 不生效"的源码坑（`> 0` 才 set）⇒ 用 0 当"最宽松相"会静默失效 | 需要产品澄清等号口径；实验侧"最宽松相"必须用 0.01 而不是 0，并在断言前核对生效值 |
| U-13 | R-W43（`MemoryControlledWALEntryQueue` 内部实现，W-18） | `[需白盒]`：队列的预占/释放、`SystemInfo` 统计值、`nonFullCondition` 唤醒路径都在内存里；黑盒只有 `wal_queue_mem_cost` 指标与堆使用率 | 需要 dump/只读 agent 或产品补"队列条目数/队列内存上限"指标；当前只记录堆与指标证据 |
| U-14 | R-W44 的"绝对字节上限"与 `deletion_ahead_log_buffer_queue_capacity`（W-18/W-22） | **文档未提及**：只有相对口径"memtable 内存的 10%（reject 阈值剩余部分的一半）"；新增键的默认值文档未给 | 需要产品补文档或在 `show configuration` 中确认该键的存在与默认值；当前只断言 `wal_buffer_queue_proportion` 的存在与生效值 |
| U-15 | R-W60 的写放大系数、R-W62 的 >4 GB 构造（W-19/W-22） | 写放大系数需按"合并次数"构造并与 BLOB 对照（属合并语义）；>4 GB 对象不现实（需先把 `max_object_file_size_in_byte` 改小，hot_reload 可行但会改变判据语义） | 需要单列小用例：把 `max_object_file_size_in_byte` 改小 → 写超限对象 → 断言失败与错误码；权限相（非 SYSTEM 改该键必须被拒）可在 W-22 内覆盖 |
| U-16 | R-W63（LOAD/导入 OBJECT，W-20） | **一期未定义**（"二期评审时，继续补充"），本环境可能根本没有可用的 OBJECT 导入路径 | 需要一期实现落地 + 语法/语义明确；在此之前 W-20 只断言"写入 → 重启可读且一致"，不可构造时 `warn "场景不可构造"` |
| U-17 | R-W67 的"先试解压、失败按未压缩读"（W-13） | **文档未定稿**（列在"需要确定的内容"），且黑盒无法区分"走的是压缩读还是未压缩读" | 需要旧版本 WAL 目录样本（未压缩、无压缩标志）做恢复实验，或产品明确兼容策略；当前只断言"老段 + 新段共存时可完整恢复" |
| U-18 | R-W68 的 IoTConsensusV2 / 单机差异（W-26） | **文档完全未提及** V2 与"单机 vs 分布式"差异；且当前只有 IoTConsensus/V2 两套协议可切 | 需要产品补文档；用例侧只能做"差异记录"（同一场景两协议各跑一遍，逐项对照），不作符合性判定 |
| U-19 | R-W51 的 i18n 与监控缺口（W-14/W-23） | **环境相关**：`StorageEngineMessages`/`DataNodeMiscMessages` 有 en/zh 两套文件，实际输出取决于 locale；缺失指标（每 WALNode 文件数、快照次数、删除数）源码确实没有 | 断言统一用英文原文关键子串或双语匹配；监控缺口只作"证据清单"打印（可作为给研发的观察项），不判缺陷 |
| U-20 | R-W46 的"1 天+ 长稳"、R-W65 的 67%/88% 与"节约 I/O 30%"（W-18/W-25/W-01/W-09/W-11） | **时长与负载不可复现**：文档数字来自特定 Benchmark（10 万设备/单 HDD）与 1 天+ 长稳；本 skill 单条用例窗口为分钟级 | 需要独立的 benchmark/长稳环境与同口径负载；当前一律只 WARN（`DECISIONS.md §2`），硬断言只保留"无 `OutOfMemoryError`"这一条 |

---

## §5 与其它 skill 的去重

> 原则：**同一事实只在一个 skill 里判 FAIL**。相邻 skill 的能力与本 skill 的边界各一句；`DECISIONS.md §6` 是口径来源。

| 相邻 skill | 边界（各一句） |
| --- | --- |
| `crud_skill`（CR-11/CR-12 OBJECT 删除、CR-14 Load×Last） | OBJECT 的**删除与 GC**（CR-11/CR-12）以及 `LOAD` 与 LAST 缓存的交叉缺陷（CR-14）归 `crud_skill`；本 skill 的 W-19/W-20 只覆盖"OBJECT 写入 → WAL 只存引用 → 故障/重启后可读"这一面，不重复删除/缓存判据。 |
| `compaction_skill`（CO-41 OBJECT TTL、DT 系列磁盘 readonly） | OBJECT 的 **TTL 与实体文件回收**（CO-41）以及"磁盘 readonly/写满"的**高可用门禁**（DT 系列）归 `compaction_skill`；本 skill 的 W-25 只断言"WAL 写入受阻后的数据一致性"，W-13/W-19 不重复"合并是否重写引用"的判据。 |
| `ttl_skill` | 过期数据清理链路（`[TTL] … Start ttl`、settle 候选、`FileTimeIndexCache` 重复注册等）归 `ttl_skill`；本 skill 只在 W-19 引用一条**交叉结论**——"对象文件被 TTL 删除后 WAL 条目无法重放"（`source_grounding.md §11` 源码注释），不重复 TTL 门禁。 |
| `metadata_skill` | DDL/元数据一致性与权限元数据（`SHOW …`、`information_schema`、权限矩阵）归 `metadata_skill`；本 skill 的 W-07 只看"元数据变更后 WAL 恢复是否一致"，W-22 的权限相只做"非 SYSTEM 用户改 WAL 配置必须被拒"这一条。 |
| `diskusage_skill` | `show disk_usage` 的统计正确性与读锁泄漏（TDB-629）归 `diskusage_skill`；本 skill 不调用该接口，WAL 体积一律用 `file_size{name="wal"}` 指标 + `find` 目录口径。 |
| 所有 skill 共用的**收尾三件套** | sync lag 归零（`check_sync_lag`）→ 逐个停 DN 比对副本（`consistency_check`）→ CN/DN 日志异常（`check_logs`）在本 skill 每条用例中照旧执行，**不算重复覆盖**，只作为"不引入回归"的公共基线（`DECISIONS.md §6`）。 |

---

## §6 口径风险清单（首轮实跑最可能出问题的地方）

> 每条 = "最可能出问题的地方" + "**如何先标定**"。总原则：**先读生效值 / 先确认场景成立 / 再写断言**；
> 标定不了的，降级为 WARN 或"场景未成立"，**绝不允许静默通过**（`DECISIONS.md §1`）。
> 首轮实跑范围是**核心 12 条、单协议 IoTConsensus**（`W-00, W-01, W-02, W-03, W-04, W-05, W-08, W-11, W-12, W-14, W-17, W-23`），
> 下面前 8 条会在首轮直接暴露，**建议按顺序逐条标定并回填本文档**。

1. **`file_count{name="wal"}` / `file_size{name="wal"}` 在 V1/V2 下的口径**。V2 有"单副本不落盘"的已知现象（`DECISIONS.md §2`），
   指标可能只统计已落盘/已封口文件，与 `find -name '*.wal' | wc -l`、与逐副本实际文件数**不一致**。
   *先标定*：W-00/W-23/W-26 对每个 DN **同时**打印三口径 —— `wal_metric_file_cnt`、`wal_file_cnt`、`wal_ls` 明细；
   不一致时以"**目录面 + 数据面**"为准，并把这组对照值写进 RESULTS（不要改判据去迁就指标）。
2. **`wal_file_size_threshold_in_byte` 的实际默认值：30 M vs 10 M**（`source_grounding.md §1.2#9` 与 `WAL 压缩功能设计.md#背景`=30 MB
   vs `design_extract.md#2.5`=10 MB）。*先标定*：W-08/W-22 先用 `wal_eff` 读运行期生效值并打印，用例**不写死**；
   断言只用"调小到 1 MB 后文件数变多"这一相对关系，并记录实测默认值（回填本节与 §1 的 R-W29 备注）。
3. **段 <32 KB 不压 ⇒ 压缩对照场景可能根本不成立**（`LogWriter.java:73-74`，`MIN_COMPRESSION_SIZE = 32 * 1024`）。
   小写入量下压缩态与未压缩态体积几乎相同，会把"没触发压缩"误判成"压缩无效"。
   *先标定*：W-11 先确认 `wal_buffer{name="wal_compress_cost"}` 有非零累计**且**单文件远大于 32 KB；
   否则 `fail "场景无效：压缩未发生（段太小）"` —— 这比"压缩率不达标"更该报出来；必要时加大 `WAL_COMPRESS_*` 写入量。
4. **`isFirstStart()` 限制 ⇒ W-02 的 DISABLE 负向场景不成立**（`SystemPropertiesHandler.java:140-142`：`isFirstStart() = !fileExist()`）：
   已初始化节点改 `wal_mode=DISABLE` 重启**不会**被拒（走 `checkImmutableSystemProperties()`）。
   *先标定*：W-02 必须在"清 data 且确认 `iotdb-system.properties` 不存在"后首启；否则 `fail "场景无效：非首次启动"`，
   同时把"已初始化节点不被拒"作为**独立相**记录（源码已确认是预期行为，不是缺陷）。
5. **`cmp_eff` / `show configuration` 是否暴露 WAL 键**（配置面判据的可用性）。`wal_eff`=`cmp_eff` 走 table 方言 `show configuration`，
   但部分键可能不在其中：`wal_buffer_queue_proportion` 属 memory 配置（`DataNodeMemoryConfig.java:375-378`）、
   两个 fsync 键与 `wal_throttle_threshold_in_byte` 的可见性**未在集群实测**。
   *先标定*：W-22 第一步先 dump 一次全量 `show configuration`，与 `source_grounding.md §1.2` 的 19 项清单**逐键比对**，
   列出"能读到 / 读不到"两张表；读不到的键改用 `wal_props_get`（配置文件口径）并降级为"仅记录证据"。
6. **WAL 目录识别（`dn_wal_dirs` 默认值）**：文档写 `wal_dirs` 默认 `data/wal`，源码真实键是 `dn_wal_dirs` 默认 `data/datanode/wal`
   （模板 `:293`、`CommonDescriptor.java:124-128`，`wal_dir`/`wal_dirs` 键不存在（`§1.5`））。
   *先标定*：W-00 首轮打印真实目录树（含 WALNode 子目录名）与 `wal_eff dn_wal_dirs` 的生效值，
   回填 `wal_dir_roots` 的优先级与本文档 §1-R-W14 / §6-6；确认后再收紧目录与文件名正则。
7. **`wal_mode` 在 V2 `batch` 下允许 DISABLE**（`IoTDBConfig.java:1178`，默认 `batch`；只有 `stream` 被拒）：
   V2 相若不显式写 `iot_consensus_v2_mode=stream`，"DISABLE 被拒"的预期**不成立**（W-02）。
   *先标定*：W-02/W-26 的 V2 相显式写 `stream` 并打印生效的 `iot_consensus_v2_mode`；
   如刻意用默认 `batch`，则如实记 `WARN 该模式允许 DISABLE，场景未成立`，**不得**记 PASS 也不得记 FAIL。
8. **阻写键名与实际阈值**：真实键是 `wal_throttle_threshold_in_byte`（hot_reload，默认 200 GB），
   `iot_consensus_throttle_threshold_in_byte` **已废弃**且优先级更高、读到即打 WARN（`IoTDBDescriptor.java:143-145,2278-2286`）；
   **实际判定阈值 = 配置值 × 0.8**（`WALManager.java:256-262`）；且存在**两套互不相同**的 throttle
   （WALManager 侧不阻塞不报错 vs IoTConsensus 侧阻塞 30s 后 `WRITE_PROCESS_REJECT`）。
   *先标定*：W-17 只配新键；若日志出现旧键的废弃 WARN，说明键写错，先纠正再判场景；
   同时采集 WARN 文案、`[Throttle Down]` INFO、`wal_blocked_writers`，"任一出现即场景成立"，避免把机制差异当缺陷。
9. **`wal_min_effective_info_ratio` 的双重坑**：文档 `<` 与 `≤` 并存（`design_extract.md#5.3`），
   且源码要求 `> 0` 才 set（`IoTDBDescriptor.java:2222-2224`）⇒ **用 0 当"最宽松相"会静默失效、仍用 0.1**。
   *先标定*：W-15/W-22 先读生效值；"最宽松"相用 **0.01**；断言只判行为方向，不判等号边界。
10. **`max_wal_memtable_snapshot_num` 默认 1 的归属**（"超过该次数" vs "累计 ≥"，`design_extract.md#5.3`）
    与 `wal_memtable_snapshot_threshold_in_byte` 的 `>` vs `≥`：默认 1 下很可能**第一次就刷盘**（`snapshotCount(0) >= 1` 不成立、需按
    `WALNode.java:546-559` 实测确认）。*先标定*：W-16 第一轮**只观察**日志出现的是 `flushes memTable` 还是 `snapshots memTable`，
    再决定断言方向；不预先假定"一定会快照"。
11. **DEBUG 级文案不可作判据**：`Successfully delete {} outdated wal files for wal node-{}`（`WALNode.java:466-470`）与
    `Effective information ratio is {}…`（`:456-461`）都是 **DEBUG**，默认 `logback-datanode.xml:225` 的 `<root level="info">` **不落盘**。
    *先标定*：W-23 用 `wal_metric_names` dump 全量 WAL 指标名；清理类断言一律用 `file_count{name="wal"}` 指标 + 目录计数；
    可用的日志面断言只有 **INFO/WARN**：恢复 5 条序列、`Reboot wal delete thread successfully…`、快照/刷盘两条文案、阻写 WARN/`[Throttle Down]`。
12. **`flush` 后 WAL 未必立刻消失**：IoTConsensus 下 `safelyDeletedSearchIndex=Long.MAX_VALUE`（`FirstCreateStrategy.java:60-61`、`DataRegion.java:811`）
    ⇒ **只有 statusCode=0 的文件会被删**，statusCode=1 与最后一个文件恒保留（`WALNode.java:671-676`、`WALWriter.java:139-143`）。
    *先标定*：W-14 先观测"flush → 文件数下降"的真实窗口与可删文件数，再设 `WAL_CLEAN_WIN_SEC`；
    **反向断言（未 flush 不得删）优先级高于正向断言**，且**禁止**断言"WAL 目录清零"。
13. **`wal_node_num` / `max_wal_nodes_num` 在 IoTConsensus 下可能不生效**：`WALManager.java:76-85` 对 IoTConsensus(V2) 直接选
    `FirstCreateStrategy`（每 region 一个 WALNode），**不读** `max_wal_nodes_num`；模板注释也写明"仅 standalone 模式有效"。
    *先标定*：W-10 先打印真实目录数与 `wal_node_num{name="wal_nodes_num"}`；若 B 相（指定 N=2）不生效，
    记 `WARN 场景未成立（FirstCreateStrategy 优先）`，并把结论回填 §1-R-W13 与 §2 的 R-W13 备注。
14. **OBJECT 判据的路径与"体积非线性"**：`${data_dir}/object_data` 的真实根目录在 2.0 布局下**未确认**
    （`wal_object_root` 是三个候选路径的经验探测）；Base32 层级与 `${dataRegionId}` 的精确值也不可依赖
    （附录说 `dataregionid` "是无用值、每次会被替换"）。
    *先标定*：W-19 先探测根目录并打印 `find` 结构（只校验"存在数字层 + Base32 层 + `.bin`"）；
    "WAL 只存引用"用同时间戳小/大对象的 WAL 体积差值做**方向性**证据，**不设**硬阈值（避免把"引用也有开销"误判成"存了内容"）。
15. **语言 locale 与其它环境噪声**：日志文案来自 i18n（en/zh 两套，`source_grounding.md §10.8`）⇒ 断言用英文原文关键子串或双语匹配；
    节点间**时钟偏差**（`AGENTS.md` 记录曾达 20 s 以上）⇒ WAL 用例一律**不用时间戳**做判据，只用"文件数/字节数/指标/日志行数增量"；
    `WALNode.java` 里 `WALManger` 是源码拼写错误（`StorageEngineMessages(en):1212-1213`）⇒ 匹配时**照抄错拼**，不要"纠正"成 `WALManager`。

---

### 附 A：本文档与其它文档的对应关系

| 本文档 | 上游依据 | 下游产物 |
| --- | --- | --- |
| §1 编号条目（R-W01 ~ R-W68） | `design_extract.md`（TP-01~TP-34）/ `feature_extract.md`（D.1~D.3 共 40 条）/ `source_grounding.md`（§1 配置项 19 项 + §12 共 40 条 + §9 指标 + §8/§10 日志） | `cases.tsv` 的"期望/说明"列、每条用例头部的"覆盖"行 |
| §2 覆盖矩阵 | `cases.tsv`（27 条 + 首轮 12 条核心范围）+ `DECISIONS.md §2`（只 WARN 清单） | `tools/selftest.sh` 的 `planned` 计数与"脚本缺失"检查 |
| §3 逐条构造与判据 | `cases.tsv` 每行 + `lib/wal_ext.sh` / `lib/cmp.sh` / `lib/common.sh` helper + `conf/env.conf` 默认值 | 用例脚本 `cases/common/wal_*.sh` 的断言实现（12 条待落地） |
| §4 未覆盖/降级清单 | `DECISIONS.md §4`（文档未提及 ⇒ 不可构造）、`§3.1-6`（不可作判据项） | 后续版本 backlog / 白盒 agent 计划（U-01/U-02/U-09/U-13） |
| §5 去重边界 | `DECISIONS.md §6` + `crud_skill` / `compaction_skill` / `ttl_skill` / `metadata_skill` / `diskusage_skill` 的既有编号 | 各 skill 的 `SKILL.md` 交叉引用 |
| §6 口径风险 | `DECISIONS.md §2`/`§3` + §3 各用例的"风险/依赖" | 首轮实跑（核心 12 条）的**标定动作清单** |

### 附 B：自检与核对方法（提交前跑一遍）

```bash
# ① 27 条用例 ID/脚本名与 cases.tsv 一致性（逐字）
awk -F'\t' '/^W-[0-9]/{print $1"\t"$2}' cases/cases.tsv
grep -c '^#### W-' docs/REQ_MATRIX.md          # 期望 27

# ② §1 条目数（期望 68）与类型分布
grep -cE '^\| R-W[0-9]{2} ' docs/REQ_MATRIX.md

# ③ §2 覆盖矩阵的未覆盖行（期望 5 条：R-W05/R-W06/R-W15/R-W30/R-W64）
grep -E '^\| R-W[0-9]{2}.*\| — \| — \|' docs/REQ_MATRIX.md

# ④ §2 引用的用例号必须都在 cases.tsv 里（避免写错 ID）
grep -oE 'W-[0-9]{2}' docs/REQ_MATRIX.md | sort -u | tr '\n' ' '

# ⑤ 脚本落地情况（未落地的脚本应由 selftest 报 planned，不算失败）
bash tools/selftest.sh 2>/dev/null | tail -5
```

**首轮实跑建议顺序**（与 §6 的标定动作对齐）：
`W-00`（目录/文件名/指标三口径标定 → §6-1/§6-6）→ `W-23`（指标名全集 → §6-11）→ `W-04`（恢复序列 + 数据面核心判据）
→ `W-05`（flush 边界 → §6-12）→ `W-02`（DISABLE 负向，含 `isFirstStart` 前提 → §6-4/§6-7）→ `W-03`（restart-only 文案 → §6-5）
→ `W-08`（阈值生效值 → §6-2）→ `W-11`/`W-12`（压缩段大小 → §6-3）→ `W-14`（清理窗口 → §6-12）→ `W-17`（阻写 → §6-8）
→ `W-01`（模式矩阵）。每条跑完把"实测生效值/真实目录结构/真实文案"回填本节与对应 §1 备注。
