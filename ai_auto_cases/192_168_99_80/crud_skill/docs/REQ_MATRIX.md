# CRUD 需求覆盖矩阵（需求点 → 用例 → 判据草案）

> 目标：把 `feishu_docs_crud\` 下的飞书设计/需求文档抽成"需求点 → 用例 → 判据"覆盖矩阵，供后续实现自动化用例。
> 本文件只做**抽取与建议**，不含实测结果；所有原文引用均为**逐字**（含错别字、阈值、错误码、接口名，不做改写）。

---

## §0 环境、基线与阅读说明

| 项 | 值 |
| --- | --- |
| 被测集群 | 3C3D（192.168.99.77/78/79），**三副本**，共识协议 **IoTConsensus** |
| 被测版本 | **RC7 `v20121rc7_1014_7c61428`**（任务给定；本文件未在本环境实跑验证） |
| 跳板机 | `192.168.99.80`（`/data/iotdb/autotest/`），**本文件编写期间未启停集群、未跑用例**（99.80 正在跑合并长回归） |
| 源码基线 | `D:\IDEA\timechodb_src\v20121\timechodb`，git HEAD `67bb5ced2b93ea9a3d388ae0ae5a75a27a353659`（`rc/2.0.12.1`，2026-10-15） |
| 源码与 RC7 的关系 | `git merge-base --is-ancestor 7c61428 HEAD` = **0**（RC7 是 HEAD 的祖先）；`7c61428..HEAD` 对 `TsFileResource.java`、`.../dataregion/modification/**` **零改动** ⇒ 本文件引用的行号对 RC7 成立 |
| 源码路径约定 | §3 中所有 `file:line` 均相对 `D:\IDEA\timechodb_src\v20121\timechodb\` 展开 |

**输入篇目统计（如实标注差异）**

- `_manifest.json` 共 **16 个条目 = 6 个目录 + 10 篇文档**；10 篇中 **9 篇抓取成功、1 篇失败**。
- 任务描述写"共 15 篇"，与实际不符（**差异已记录，不擅自补齐**）。
- 任务描述把 `数据删除\数据删除功能V2 设计文档.md` 与 `数据删除\意见讨论稿\数据删除功能V2 设计文档.md` 当成两篇，磁盘上实为**同一篇**（落在 `数据删除_意见讨论稿\`），未重复计数。
- **缺篇（已标注）**：`写入流程\【1.0.0.1】写入内存控制-技术设计`（旧版飞书 doc，跨租户 `apache-iotdb.feishu.cn`，`_manifest.json` 中 `ok=false`）——本次未取得正文，**该篇没有任何需求点被抽取**。
- **空白篇**：`V2.x.x.x-存储模块-CRUD操作-Object类型导入导出-技术设计` 全篇为模板占位文字，抽不出需求点（见 §4-D）。

**飞书导出格式说明**：markdown 由飞书 docx 导出，**表格被拍平成一行一格**（配置项表格表现为"名称/释义/数据类型/默认值"逐行铺开，多列表被横向串联），§1 引用时按"逐行原文"拼接，并在必要时标注这是表格拍平结果。

**缩写**：Mod = Modification 文件；N_Mod = Normal Mod 文件；C_Mod = Compaction Mod 文件；Res = TsFileResource 文件；RF = 副本数。

---

## §1 需求点清单（R-01 … R-72）

> 分组：**A 写入流程**（R-01–R-15）/ **B 数据删除**（R-16–R-52）/ **C 文件加载（Load TsFile 时更新 LastCache）**（R-53–R-72）/ **D Object 导入导出**（0 条，见 §4-D）。
> 每条格式：`R-xx` + **原文关键句（逐字）** + 出处文件。**宁多勿漏**，含设计论证类条目（这类会在 §4 说明为何没有客观判据）。

### A. 写入流程（15 条）

| ID | 原文关键句（逐字引用） | 出处 |
| --- | --- | --- |
| **R-01** | 「提供一个配置项，使系统可以检查用户数据时间戳与时间精度配置项不匹配的问题。」表（拍平）：`timestamp_precision_check_enabled` / `是否打开对于时间戳精度的检查` / `布尔` / `true` | 【1.3.0.1】写入时检查时间戳精度-需求分析（功能描述/功能定义） |
| **R-02** | 「iotdb 配置为 ms 精度时，当前的时间戳 1693987852987 的位数为 13 位。当写入的时间戳位数超过 13 时，给用户返回错误信息（系统当前时间戳精度为xx，请检查时间戳是否正确，可通过 time_precision 参数设置精度），这次写入失败。」 | 同上（功能定义） |
| **R-03** | 「iotdb 配置为 us 精度时，当前的时间戳 1693987852987000 的位数为 16 位，当写入的时间戳位数超过 16 时，给用户返回错误信息（系统当前时间戳精度为xx，请检查时间戳是否正确，可通过 time_precision 参数设置精度），这次写入失败。」 | 同上 |
| **R-04** | 「iotdb 配置为 ns 精度时，Long.maxValue 已经是19位了，因此用户时间戳不可能超过19位，无需额外处理。」 | 同上 |
| **R-05** | 「时间戳精度检查不会显著影响写入性能。」 | 同上（非功能定义/性能需求） |
| **R-06** | 「默认开启精度检查会使得之前的一些写入操作变为非法。如果确有必要执行这些操作，可以在升级后关闭该配置项。」 | 同上（兼容性需求） |
| **R-07** | 「只用系统管理员可以修改该配置。」 | 同上（安全性需求） |
| **R-08** | 「观察 data 目录发现创建了 10 个时间分区。时间分区的间隔 7 天被缩小了 100_000 倍。」／「因此问题 2 是一个我们需要去解决的问题。」 | 同上（问题 2） |
| **R-09** | 「在大请求的场景下，RPC 模块由于 buffer 扩容所带来的内存开销需要进一步监控；」 | 写入内存实例分析（总结） |
| **R-10** | 「需要对公式模块的内存监控进行改造。」（**原文如此，逐字保留，“公式”疑为“共识”笔误**；同段另有「在这个例子中，共识仅被分配了约 100MB 内存，而实际由共识请求所引用的内存量远高于该值」） | 同上 |
| **R-11** | 「理论上，在触发JVM OOM之前应该能触发内存控制机制，从而避免进一步的内存使用。」 | 同上（内存分配） |
| **R-12** | 「在 https://github.com/apache/iotdb/pull/15017 PR 中，我们拒绝了不带 field 列的写入请求和不带 field 列的 TsFile 的 load 请求。」 | 是否允许表模型写入请求只有 Time 列（问题描述） |
| **R-13** | 「Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 1100: Loading file /Users/ht/Documents/iotdb/data/datanode/data/sequence/test1/1/0/1742800146352-1-1-0.tsfile failed. Detail: No column other than Time present, please check the request」 | 同上（场景1/场景2 两处**同一段原文**） |
| **R-14** | 场景 1：「执行下面的sql，写入后 drop 掉所有field 列，等待文件执行合并。」+ `alter table t1 drop column s1` / `alter table t1 drop column s2`；场景 2：「执行下面的sql，写入的 field 值都为 null，等待文件执行合并。」+ `insert into t1(time,s1,s2) values(1,null,null)`；结论句：「依然会生成不带 field 列的 TsFile，这样的 TsFile 无法load 进 IoTDB。」 | 同上（场景1、场景2） |
| **R-15** | 「方案2 允许写入请求只有 Time 列。可以解决生成的 TsFile 无法 load 的问题，但是需要改变对外表现。不会对常规使用产生负面影响。」（**讨论稿候选方案，文档未记录评审结论** —— 见 §4-A3） | 同上（解决方案） |

### B. 数据删除（37 条）

| ID | 原文关键句（逐字引用） | 出处 |
| --- | --- | --- |
| **R-16** | 「对于同一个时间分区内的 TsFile ，仍然令每个 TsFile 对应一个 Mod 文件，但是不同 TsFile 可以对应同一个 Mod 文件。每一个层级可能会有若干个 Mod 文件。」 | 数据删除功能V2 设计文档（共用的 Mod 文件） |
| **R-17** | 「Mod 文件的前缀名不再与 TsFile 保持一致，而是更换为 <level>-<modFileNum>，其中<level>对应 TsFile 的层级，<modFileNum>为每一个层级内的自增整数。为了支持表模型和优化存储效率，Mod 文件的结构将有一定修改，为何之前的文件进行区分，后缀名变更为mods2」（**“为何”原文如此**） | 同上 |
| **R-18** | 「TsFile 通过 Res 文件存储对应 Mod 文件的绝对路径。因为共享同一个 Mod 文件的若干文件可能处于多个 Data 目录，无法通过只记录文件名的方式找到对应的文件。」 | 同上 |
| **R-19** | 「Mod 文件分配的触发时机为某 TsFile 第一次接收到删除操作时，在此前该 TsFile 不存在对应的 Mod 文件。」 | 同上（Mod 文件分配的要点） |
| **R-20** | 「Mod 文件分配是按 TsFile 的层级进行的，因为每次合并后，TsFile 中被删除的数据将不复存在，因此新产生的文件与原先的 Mod 文件将没有关联。」 | 同上 |
| **R-21** | 「如果 n_modf >= 一个层级 Mod 文件数阈值 n_threshold， 则返回 false，否则返回 size(mod_last) >= Mod 大小阈值 size_threshold；n_threshold 和 size_threshold 均为可配置参数。」 | 同上（should_allocate 的基本实现） |
| **R-22** | 「一个 Table Deletion 包含一个表示 Entry 类型的字节 （0x00）、删除的起始时间 State Time 、终止时间 End Time 和序列化后的删除谓词 Predicate。」／「一个 Tree Deletion 包含一个表示 Entry 类型的字节 （0x01）、删除的起始时间 State Time 、终止时间 End Time 和删除路径模式（形如“root.sg1.*.dev_test.**”）。」／「对于整个表或者整条序列的删除，同样使用 Table Deletion Entry 或 Tree Deletion Entry，只是将删除时间范围设置为 [Long.MIN_VALUE, Long.MAX_VALUE]。」／谓词「形如“id1=xxx and id2=yyy or id3=zzz”，可以为空，为空时匹配所有设备；测点列表形如“s1,s2,s3”，可以为空时匹配所有测点。」 | 同上（Mod 文件的格式修改） |
| **R-23** | 「在合并开始时，合并线程会为所有目标文件分配一个相同的 Mod 文件（分配策略与前述基本相同，层级以目标文件中已有 Mod 文件数最小的层级为准），并且将该 Mod 文件记录为所有合并源文件的 Compaction Mod 文件。因此，实际上每个 TsFile 可能会指向两个 Mod 文件，一个记录所有的删除操作，称为 Normal Mod 文件（简称 N_Mod 或 Mod 文件）；另一个记录合并期间的删除操作，称为 Compaction Mod 文件（简称C_Mod 文件）。」 | 同上（删除操作和合并的并发处理） |
| **R-24** | 「为了保证在向一个 TsFile 的 Mod 写入时，可以感知到并发生成的 C_MOD，需要在开始写入前加锁，避免中间生成 C_MOD 文件且完成合并。」 | 同上 |
| **R-25** | 「还有一种比较极端的情况是合并目标文件也在删除操作写入前被删除。……为了避免这种情况，在完成对一个 TsFile 的删除后，需要检查其存在性，如果其已经被删除，就需要重新获取 TsFile 列表，并对列表中产生的新文件进行删除。」 | 同上 |
| **R-26** | 删除写入流程：「置 anyTsFileRemoved 为 false；」「对 DataRegion 加写锁，避免写入修改 MemTable；」「将 e 加入到 f 的内存删除缓冲 flushingMods 中；」「刷出中写出 Mod 文件时会对 f 的 flushQueryLock 加写锁；」「如果 anyTsFileRemoved 为 true，将从上次执行第 4 步到现在产生的已关闭 TsFile 记为 files，然后回到第4步。」 | 同上（删除操作的写入流程） |
| **R-27** | 无需重组：「发送端将 modSet 整合传输到接收端，形成 x-y.mods2 文件；」「整合后的文件只包含与 fileSet 相关的 Deletion Entry;」「接收端加载 TsFile，并在生成 Res 文件时令其中的 Mod 文件指向传输形成的 Mod 文件。」需重组：「重新组织的过程中，使用 temp.mods2 对数据进行过滤；」 | 同上（Pipe 对 Mod 文件的处理） |
| **R-28** | 「为此，需要在 TsFileResource 中增加一个内存字段 oldModificationFile 用于指向可能存在的旧 Mod 文件。」／「读取旧的 Mod 文件时，所有删除操作记录均会被返回；读取新的 Mod 文件时，只有出现在该 TsFileResource 对应的 File Entry 之后的删除记录会被返回。」 | 同上（对旧 Mod 文件的兼容 / 删除操作的查询流程） |
| **R-29** | 「首先文件的版本号从1更新为2；然后 progressIndex 和 modFilePath 的位置发生了交换，使得 modFilePath 处于最后，便于对其单独修改；并且在其后追加了指向 modFilePath 起始位置的指针，便于找到 modFilePath 所处位置；最后，有一个指针指向该 TsFile 被分配一个 Mod 文件时，该 Mod 文件的长度中，便于读取该 TsFile 的删除记录时跳过一部分无效的删除记录。」 | 同上（Res 文件的格式变更） |
| **R-30** | 「因此我们限定删除操作只有在 TsFileResource 异步恢复结束后才能进行。如果一个 DataRegion 在异步恢复完成前接收到删除请求，则抛出一个异常。」 | 同上（重启恢复） |
| **R-31** | 「每一个时间分区使用一个 Map<Integer, TreeMap<Integer, ModificationFile>> partitionModFiles 来管理其下的 Mod 文件，其 key 分别为层级数和 Mod 文件编号，为方便找到最后一个 Mod 编号以分配新的 Mod 文件，内层 Map 使用 TreeMap。」／「每个 ModificationFile 中使用一个 Set<TsFileResource> 指向引用其的 TsFileResource。」 | 同上（Mod 文件的管理和删除/管理） |
| **R-32** | 「当一个 DataRegion 的所有 TsFileResource 恢复后，首先扫描每个时间分区的目录，将所有不存在于 partitionModFiles 中的 .mods2 文件删除，然后启动一个定时线程，该线程将每个时间分区中已不包含任何 TsFileResource 的 Mod 文件删除。」 | 同上（管理/删除） |
| **R-33** | 「为了避免一个 Mod 文件在被分配给一个 TsFile 的同时被删除，判断 Mod 文件是否包含 TsFileResource 与向其中加入 TsFileResource 的过程需要加锁。如果在其中加入 TsFileResource 的过程中加锁后，已经发现该 Mod 文件不存在任何对应的 TsFileResource，则取消这一次分配，尝试分配一个新的 Mod 文件或者另外的 Mod 文件。」 | 同上 |
| **R-34** | 「本文档所提出的数据删除功能 V2 主要解决以下三个问题：TsFile 数较多，删除范围较大时，进行删除会产生大量 IO，影响系统性能；支持表模型的删除；解决数据删除中“删除与合并的协同”一节提到的问题。」 | 同上（问题） |
| **R-35** | 「图18(c)说明，在对写入耗时进行100倍的加权后，V2删除要优于V1，并且较小的 size_threshold (<= 64KB) 有比较好的总体效果。」 | 同上（仿真实验） |
| **R-36** | 「为什么不使用一个分区一个 Mod 文件的设计」+ 四条弊端：①「删除对查询的负面影响最大化」②「无法通过合并及时移除删除记录」③「需要不断重写 Mod 文件」④「难以支持历史数据同步」 | 同上（待讨论的问题） |
| **R-37** | 「should_allocate() 函数的主要思路为，通过上一个时间分区或系统整体的统计信息，获取计算 n_IO_sum 所需的 spd_deletion，spd_tsfile，n_query，n_query_file 等参数，然后计算出使得 n_IO_sum 最小的 n_threshold 和 size_threshold，应用到下一个时间分区。」 | 同上（进阶实现的主要思路） |
| **R-38** | 「在delete 操作记录 mods 文件时，其操作耗时与 tsfile 文件数量成正比，且该阶段会一直持有RegionWriteValidationRWLock().writeLock()，而写入也会拿这把锁，所以 delete 会阻塞实时写入。」／「单个 region 的单次 delete 操作的耗时 = region 内 tsfile 文件数量 * 单次写 mods 文件的耗时」 | Delete 性能优化（问题分析/问题一） |
| **R-39** | 「中冶赛迪的场景，单个region内包含大约800多个tsfile，单次写 mods 文件的耗时为5-10ms，所以 单个 region 的单次 delete 操作的耗时在 4-8 s，这4-8s内，是阻塞该region的」 | 同上 |
| **R-40** | 「Delete 命令在 ConfigNode 的 DeleteTimeseriesProcedure 中被发向所有副本，每个副本又会将 delete 记到 log 中，并向其他副本同步。」／「一条delete命令被记录多次」 | 同上（问题二） |
| **R-41** | 「加快删除序列操作的效率，使其对 IoTDB 实时写入影响尽量小。」 | 同上（优化目标） |
| **R-42** | 「mods 文件改成分区级别，每个region的每个时间分区单独维护一个mods文件，而非每个tsfile对应一个mods文件。」／「单个 region 的单次 delete 操作的耗时 = region 内时间分区的数量 * 单次写 mods 文件的耗时」 | 同上（思路二） |
| **R-43** | 「如果单纯只考虑中冶赛迪的 delete timeseries场景，则可以考虑 CN 上发送 delete 操作时，只往 follower 上发，而写入是在leader上进行的，这两者的过程是互斥的。」+ 劣势：「当用户收到 delete timeseries 完成的消息后，有可能 follower 还未来得及将 delete 操作同步给 leader……则可能查出陈旧的历史数据。」+「可能的解决方案：CN 去等待 follower 向 leader 同步完成后再进入流程的下一步。」 | 同上（思路三） |
| **R-44** | 「不能解决问题，因为 delete 操作跟写入操作是互斥的，且 delete 操作目前是一个不可中断的操作（对应一条raft log 的 apply），对 delete 操作做了限流后，反而会让 delete 操作更慢的完成，导致写入被阻塞更长时间」 | 同上（思路一） |
| **R-45** | 「对于问题二，既然往多个副本发，也无法彻底解决写写冲突带来的副本一致性的问题，可以修改CN的逻辑，使其只往 leader 上发送 delete 操作。」／「所以可以只往 leader 上发送，能减少集群整体 1/2 的 IO 消耗」 | 同上（问题二优化思路 / 问题分析） |
| **R-46** | 「不新增删除语法，可以支持通过 delete 语句删除表模型 OBJECT 类型的数据」 | V2.0.8.1-存储模块-CRUD-Object类型数据手动删除-技术设计（设计目标/设计目标） |
| **R-47** | 「删除执行后，OBJECT 的真实存储内容也会随之删除」 | 同上 |
| **R-48** | 「对已有的功能没有负面性能影响」 | 同上 |
| **R-49** | 「拿 dataRegion 写锁。」「记录 delete 操作的 WAL。」「根据删除请求中的 tablename 判断该 dataRegion 的object 文件夹如object/{dataRegionID}/{tablename}是否存在。」 | 同上（DataRegion 中的删除表、列、数据执行流程/执行流程） |
| **R-50** | 「如果是删除全表，直接物理删除掉 object/{dataRegionID}/{tablename} 文件夹」／「如果不是删除全表，遍历 object/{dataRegionID}/{tablename} 文件夹下的所有 .bin 和 .tmp文件。根据 .bin 和 .tmp文件的文件路径获得该 object 文件的 IDeviceID，measurement 名和 timestamp，通过判断该文件是否应该被删除。如果满足删除条件，执行文件物理删除。」 | 同上 |
| **R-51** | DataRegion 删除 database 执行流程：「拿 dataRegion 写锁。」「释放 memtable 。」「拿到所有 tsfileresource ，删除所有mods 文件。」「删除数据目录sequense和unsequense下该 region 的所有 TsFile 和 resource 文件及目录。」「删除object目录下该 database 对应的 data region 的所有文件及目录。」 | 同上（DataRegion 中的删除 database 执行流程） |
| **R-52** | 「如果删除某个 OBJECT 文件时出现异常，则跳过该文件的删除，继续剩下的文件删除。同时向客户端返回报错异常。」 | 同上（异常处理） |

### C. 文件加载（Load TsFile 时更新 LastCache）（20 条）

| ID | 原文关键句（逐字引用） | 出处 |
| --- | --- | --- |
| **R-53** | 「目前在加载 TsFile 时，如果 LastCache 为打开状态，会清空整个 LastCache 来保证加载后的 TsFile 内的数据可以被 Last 查询访问。对于 Load 操作比较频繁的场景，例如使用了 Pipe，LastCache 会因为频繁清空而近乎失效，导致 Last 查询效率低下。」 | 【2.0.5.1】文件加载时更新 LastCache-需求分析（需求描述） |
| **R-54** | 「因此，需要将 Load 之后对于 LastCache 的行为从整个清空修改为部分更新，从而提高 Load 频繁场景下 LastCache 的命中率。考虑到 Load 上下文中不一定可以直接获取 TsFile 所包含的最新值，读取 TsFile 并获取最新值的代价可能较高，除了部分更新以外，也需要提供部分清除的策略来避免读取 TsFile 最新值的过程影响写入。」 | 同上 |
| **R-55** | 「在 iotdb-system.properties 增加新的配置项，使用时修改配置项即可调整加载 TsFile 后 LastCache 的行为。」表（拍平）：`last_cache_operation_on_load` / 「加载 TsFile 后对 Last Cache 执行的操作。UPDATE：读取 TsFile 的内容并用其更新 LastCache；UPDATE_NO_BLOB：读取 TsFile 的内容并用其更新 LastCache，对于 BLOB 类型；CLEAR_DEVICE：清空与该 TsFile 相关的设备的 LastCache；CLEAR_ALL：清空所有 LastCache。」/ `枚举字符串` / `UPDATE, UPDATE_NO_BLOB, CLEAR_DEVICE, CLEAR_ALL` / `UPDATE_NO_BLOB` | 同上（功能定义） |
| **R-56** | `cache_last_values_for_load` /「是否在 Load 过程中缓存最新值用于最后的更新。只对 UPDATE 或 UPDATE_NO_BLOB 策略生效。如果设置为真，即使是 UPDATE 策略也不会更新 Blob 类型的最新值。」/ `布尔` / `True/False` / `True` | 同上 |
| **R-57** | `cache_last_values_memory_budget_in_byte` /「当 cache_last_values_for_load 为真时，每个 Load 操作可用来缓存最新值的内存大小。已缓存的部分超过该大小时，将会丢弃已缓存的最新值，改为使用流式读取的方式更新最新值。」/ `INT64` / `INT64` / `4MB` | 同上 |
| **R-58** | 「使用 UPDATE 或者 UPDATE_NO_BLOB 策略会一定程度增加文件加载的耗时，但是会降低加载以后进行最新值查询的耗时。使用 CLEAR_DEVICE 或者 CLEAR_ALL 策略不会影响文件加载耗时，但是会增加加载以后进行最新值查询的耗时。」 | 同上（性能要求） |
| **R-59** | 「上述配置仅允许系统管理员修改。」 | 同上（安全性要求） |
| **R-60** | 「默认场景使用 UPDATE_NO_BLOB 策略；」「确认需要查询 BLOB 类型的最新值时，更换为 UPDATE 策略；（后续可以考虑替换为黑白名单或者更详细的配置）」「当通过火焰图等发现更新 LastCache 时读取 TsFile 的过程开销极大，或者 Last 查询的频率远小于 TsFile 的加载频率（例如每 5 秒加载一个 TsFile，而 Last 查询每分钟仅执行一次）时使用 CLEAR_DEVICE 策略；」「上述策略均失效，或者设备数过多导致 CLEAR_DEVICE 策略也会导致系统受影响时，使用 CLEAR_ALL 策略（即回退到原有策略）。」 | 同上（场景示例） |
| **R-61** | 接口签名表（拍平）：「Iterator<Pair<IDeviceID, List<TimeseriesMetadata>>> TsFileSequenceReader.iterAllTimeseriesMetadata(boolean needChunkMetadata)」／「流式获取每条时间序列的 TimeseriesMetadata，按设备分组。」／「needChunk: 返回的 TimeseriesMetadata 是否包含 ChunkMetadata」 | LastCache-技术设计（UPDATE 策略） |
| **R-62** | 「然后在 TsFile 侧增加可以快速获取最新值的类 TsFileLastReader。该类提供以下接口：」表（拍平）：「TsFileLastReader(String filePath)」＝「构造函数。默认使用异步 IO 并且不忽略 Blob。」；「TsFileLastReader(String filePath, boolean asyncIO, boolean ignoreBlob)」；「boolean hasNext()」＝「是否还有剩余数据。」；「Pair<IDeviceID, List<Pair<String, TimeValuePair>>> next()」＝「返回下一个设备的最新点，返回值中的 String 为测点名。对于对其序列，返回结果包含时间列（测点名为空字符串）。」（**“对其序列”原文如此**） | 同上 |
| **R-63** | 「在 IoTDBConfig 中增加布尔配置项 cacheLastValuesForLoad，并在 TsFileResource 中增加字段 Map<IDeviceID, List<Pair<String, TimeValuePair>>> lastValues。如果 cacheLastValuesForLoad 为真并且当前策略为 UPDATE 或 UPDATE_NO_BLOB，则在 Load 创建 TsFileResource 时，会将各非 Blob 序列的最新值缓存在其中。」 | 同上 |
| **R-64** | 「当一个 TsFile 被加载到文件列表后，如果其 TsFileResource 中存在 lastValues，则用其更新 LastCache。否则创建一个对应的 TsFileLastReader，并遍历其最新值，通过已有的 TableDeviceSchemaCache.updateLastCacheIfExists() 或 TreeDeviceSchemaCacheManager.updateLastCacheIfExists() 接口更新最新值。」 | 同上 |
| **R-65** | 「UPDATE_NO_BLOB 策略：类似于 UPDATE 策略，只是遇到 Blob 类型序列时不更新最新值而是使对应 LastCache 失效。」 | 同上 |
| **R-66** | 「CLEAN_DEVICE 策略：当一个 TsFile 被加载到文件列表后，通过查询其对应的 TsFileResource，如果它具有设备级的时间索引，则将所有相关的设备的 LastCache 清空，否则回退到 CLEAN_ALL 策略。」 | 同上 |
| **R-67** | 「CLEAN_ALL 策略：当一个 TsFile 被加载到文件列表后，清空整个 LastCache。」 | 同上 |
| **R-68** | 「在三种策略下，Load 前后 Last 查询的正确性」「首先向 IoTDB 通过 Session 写入一定的数据，然后对写入的数据进行 Last 查询。然后生成一个包含更新数据的 TsFile，将其加载到 IoTDB 中，再进行 Last 查询。」「详见 org/apache/iotdb/db/it/IoTDBLoadLastCacheIT.java」 | 同上（测试计划） |
| **R-69** | 「在三种策略下，同时进行 Load 和 Last 查询的读写性能」「写入线程 A 不断生成包含固定时间序列的 TsFile，并将其加载到 IoTDB 中，每个文件的数据时间戳递增，直至加载完 n 个文件。十个查询线程 B1-B10 不断随机查询由线程 A 产生的一条时间序列的最新值……并在此过程中记录查询的平均延迟。」「详见 org.apache.iotdb.db.it.IoTDBLoadLastCacheIT#testTableLoadPerformance。」 | 同上 |
| **R-70** | 「在三种策略下，使用 Pipe 进行数据同步的读写性能」「在 192.168.130.15（简称15）、192.168.130.16（简称16） 分别启动 1C1D ；」「100 device，1000 measurement，20 clients；」「观察在三种策略下 bm1 的写入速率和 bm2 的查询延迟。默认没有 blob 数据，所以 UPDATE_NO_BLOB 与 UPDATE 等效。」 | 同上 |
| **R-71** | 1C1D 实测表（拍平）：「bm1 写入吞吐率（点/秒） 15824725 / 16020262」「bm2 查询延迟（ms） 52.50 / 120.54」（两列分别对应 `UPDATE_NO_BLOB` / `CLEAN_DEVICE`）；另一组 172.20.31.60-62：「33152169 / 31500205 / 37000195」与「36.01 / 332.64 / 477.95」 | 同上 |
| **R-72** | 配置模板（逐字）：「last_cache_operation_on_load=UPDATE_NO_BLOB」「cache_last_values_for_load=true」「cache_last_values_memory_budget_in_byte=4194304」「The operation performed to LastCache when a TsFile is successfully loaded.」+ 三处均为「# effectiveMode: restart」 | 源码模板 `iotdb-core/node-commons/src/assembly/resources/conf/iotdb-system.properties.template:2894-2913`（**作为 R-55..R-57 的落地值交叉印证**；文档侧出处为 R-55..R-57 三行） |

### D. Object 导入导出（0 条）

该篇（`V2.x.x.x-存储模块-CRUD操作-Object类型导入导出-技术设计.md`，1369 字）**全篇为设计说明书模板占位文字**，例如逐字：

> 「设计背景 / 说明： / 1. 需求关联：链接本设计说明书相关的需求说明书 / 2. 专有词汇与技术背景：详细定义和解释本设计中涉及的所有专有词汇和技术术语」
> 「设计目标 / 说明： / 分条列点明确本设计需要解决的问题 …」
> 「模块1 / 说明：推荐以架构图结合描述的方式展开下列内容 …」
> 「xxxx年x月x日 内部讨论 / 讨论录屏： / 讨论关键记录及结论：」

⇒ **抽不出任何 R-xx**。同时在源码全仓检索 `exportObject|ObjectExport|importObject|ObjectImport|EXPORT OBJECT` **零命中**，说明该功能在 RC7 源码中尚不存在。相关说明见 §4-D。

---

## §2 需求点 → 建议用例映射

14 条建议用例（CR-01 … CR-14），覆盖 §1 中全部 **62** 条可构造 R-xx；其余 **10** 条（R-09/10/11/35/36/37/42/43/44/45）按"不可构造/无客观判据"处理，见 §4。

| 用例 | 一句话目标 | 覆盖的 R-xx | 模型 | 建议集合 | 预估耗时 |
| --- | --- | --- | --- | --- | --- |
| **CR-01** | 时间戳精度检查门禁：配置开关 + ms/us 位数阈值（含边界与负值）+ ns 放行 + 错误文案/码 + 仅管理员可改 | R-01, R-02, R-03, R-04, R-07 | tree | `write` | 20 min |
| **CR-02** | 精度检查的兼容性与时间分区膨胀对照：关闭=放行、开启=拦截（同一 SQL），关闭态复现"10 个时间分区" | R-05, R-06, R-08 | tree | `write` | 20 min |
| **CR-03** | 表模型"只有 Time 列"门禁：写入拒绝 vs load 拒绝（含 `DROP COLUMN` 全删 / field 全 null 两条产文件路径） | R-12, R-13, R-14, R-15 | table | `write` | 25 min |
| **CR-04** | `.mods2` 基础形态：命名/位置/共享性/Entry 类型字节（0x00 表、0x01 树）与"首次删除才分配" | R-16, R-17, R-18, R-19, R-20, R-22 | tree+table | `delete` | 25 min |
| **CR-05** | Mod 文件分配阈值（`n_threshold`/`size_threshold` / `should_allocate`）对删除写入与查询读取的影响 | R-21 | tree+table | `delete` | 25 min |
| **CR-06** | 删除 × 合并并发：合并期间删除不得丢（N_Mod + C_Mod / cascade），合并目标被再次合并后重试仍不丢 | R-23, R-24, R-25 | tree+table | `delete` | 25 min |
| **CR-07** | 删除写入流程中间态：未落盘 memtable / 正在 flush 的文件也被删除覆盖（`flushingMods` 路径） | R-26, R-33 | tree+table | `delete` | 20 min |
| **CR-08** | Pipe 传输带删除操作的 TsFile：接收端整合出 `temp.mods2`，删除语义在接收端保持 | R-27 | tree | `delete` | 25 min |
| **CR-09** | 旧 Mod 兼容 + Res 变更 + 重启恢复 + Mod 文件生命周期（孤儿 `.mods2` 清理、无引用删除） | R-28, R-29, R-30, R-31, R-32 | tree+table | `delete` | 25 min |
| **CR-10** | DELETE 阻塞写入的量化：单次 `delete timeseries` 耗时随 TsFile 数增长、写入被阻塞；重复记录/IO 减半观测 | R-38, R-39, R-40, R-41 | table | `delete` | 25 min |
| **CR-11** | OBJECT 手动删除：`DELETE FROM t`（整表）/ 部分时间范围 / 整库删除后，磁盘 object 真实文件被物理清理且不可再查 | R-34, R-46, R-47, R-49, R-50, R-51 | table | `object` | 25 min |
| **CR-12** | OBJECT 删除的异常路径与开销对照：单文件删除异常被跳过、其余继续、客户端收到报错 | R-48, R-52 | table | `object` | 20 min |
| **CR-13** | Load 时 LastCache 三/四策略正确性：UPDATE / UPDATE_NO_BLOB / CLEAN_DEVICE（含回退 CLEAN_ALL）/ CLEAN_ALL，Load 前后 Last 结果正确 | R-53, R-54, R-55, R-56, R-57, R-61, R-62, R-63, R-64, R-65, R-66, R-67, R-68, R-72 | tree+table | `load` | 25 min |
| **CR-14** | Load × Pipe + Last 查询性能与内存预算：三策略下写入/查询耗时关系、`cache_last_values_memory_budget_in_byte` 触发流式回退、配置重启生效 | R-58, R-59, R-60, R-69, R-70, R-71 | tree | `load` | 25 min |

**建议集合口径**：`smoke`（5 min 级冒烟）/ `write` / `delete` / `load` / `object` —— CR-01..CR-03 归 `write`，CR-04..CR-10 归 `delete`，CR-11..CR-12 归 `object`，CR-13..CR-14 归 `load`；建议另配 1 条 `smoke`（可复用 CR-04 的最小相：建库→写→flush→DELETE→看 `.mods2` 出现，≤5 min），本次不单列 CR 号以免超出 14 条上限。

**未映射到用例的 R-xx**：R-09、R-10、R-11（写入内存分析，无客观判据）；R-35、R-36、R-37（仿真/设计论证）；R-42、R-43、R-44、R-45（Delete 性能优化的候选思路与已否定思路）——逐条原因见 §4。

**⚠️ 编号冲突提示（需与骨架搭建方对齐）**：本文件写作期间，`crud_skill\cases\cases.tsv`（**并行任务维护，本任务未改动**）里 **`CR-01` 已被占用于"骨架 fallback 冒烟 `cases/common/cr_smoke.sh`"**（该文件自述"其余 CRUD 用例待补齐…需求矩阵与出处见 docs/REQ_MATRIX.md"）。因此本节 `CR-01 … CR-14` 与骨架里的 `CR-01` **同号不同义**。两种收敛方式，请择一确认：

- **(a) 骨架让号**（推荐）：骨架的 fallback 冒烟改编号为 `CR-00`（或 `CR-smoke`），本节 `CR-01…CR-14` 作为正式编号。
- **(b) 本表让号**：本节整体后移为 `CR-02…CR-15`，`CR-01` 保留给 fallback 冒烟；同时 §2/§3/§5 的全部引用号同步 +1。

另注：`cases.tsv` 记明 `--set smoke|write|delete|load|object` **目前是"编号区间占位实现"**。本节给出的集合归属是**语义归属**（CR-01..03 属 `write`、CR-04..10 属 `delete`、CR-11..12 属 `object`、CR-13..14 属 `load`），**不保证与骨架的区间实现一致**；补齐用例时请一并确定"集合 → 编号区间"的映射，或把 `run_all.sh` 改为按 `cases.tsv` 的集合列选择。

---

## §3 逐用例构造与判据草案

**通用约定（所有 CR 共用，正文不再重复）**

- **集群/协议**：3C3D、**三副本**、`IoTConsensus`。用例开始前记录"集群 3/3 就绪"；结束做收尾三件套（sync lag 归零 → 逐个停 1 个 DN 比对副本一致 → CN/DN 日志扫异常）。
- **客户端**：`<IOTDB_HOME>/sbin/start-cli.sh -h <dn>`；`<IOTDB_HOME>` 指该节点上的版本目录（本环境形如 `/data/iotdb/v20121rc7_1014_7c61428`）。
- **配置**：每节点 `<IOTDB_HOME>/conf/iotdb-system.properties`；`effectiveMode: hot_reload` 的键可用 `SET CONFIGURATION` 热改，标 `restart` 的必须重启。
- **日志（权威信号）**：`<IOTDB_HOME>/logs/log_datanode_all.log`（`DataRegion` 类 logger，含全部 `[Deletion] …`）、`log_datanode_object_deletion.log`（logger 名 `OBJECT_DELETION`）、`log_datanode_compaction.log`。**基线必须在触发动作之前采集**（行数增量才是信号）。
- **数据目录**：`<IOTDB_HOME>/data/datanode/data/{sequence,unsequence}/<db>/<regionId>/<timePartition>/`（TsFile / `.resource` / `.mods2`）；object 文件在 `.../data/object/<regionId>/<base32(table)>[/tags]/{pointTime}_{tsVersion}.bin`。
- **双信号判据**：一律要求"日志行数变化 **且** 文件/行数变化"同时成立，缺一即判**场景未成立**（不判产品问题）。
- **数据面**：行数用"原始查询数行"而**不要**用聚合（本环境下 `select count(s1) from db.d1.**` 会退化成 `|Time| Empty set.`，见 `compaction_skill/docs/RESULTS.md` 踩坑 #4）；等价性用归一化指纹。
- **tree 方言 DELETE 语法**：必须带 `.**`（`DELETE FROM root.db.d1.** WHERE time<=T`），否则删的是不存在的序列路径、**0 行被删且不报错**。
- **删除走共识**：DELETE 后必须轮询等三副本应用完成再计数，否则 count 偏大。

---

### CR-01 时间戳精度检查门禁

- **模型/集合/耗时**：tree / `write` / 20 min（含 3 次重启：ms→us→ns）
- **前置**
  - 配置 `timestamp_precision=ms`、`timestamp_precision_check_enabled=true`（模板默认，`iotdb-core/node-commons/src/assembly/resources/conf/iotdb-system.properties.template:1558,1564`）。
  - `timestamp_precision`（即 `time_precision`）在 `TimestampPrecisionUtils` 的 **static 块**里只读一次（`TimestampPrecisionUtils.java:28-58`）⇒ **改精度必须重启三节点**；`timestamp_precision_check_enabled` 在 hot-modify 分支里读取（`IoTDBDescriptor.java:2804-2811`）⇒ **可热改**。
  - 三副本；无需额外共识要求。
  - 库：`root.cr01`（tree）。
- **构造步骤**
  1. **ms 合法/非法相**：`INSERT INTO root.cr01.d1(time,s1) VALUES(1693987852987,1)`（13 位）→ 期望成功；`INSERT INTO root.cr01.d1(time,s1) VALUES(16939878529870,1)`（14 位）→ 期望失败。
  2. **边界相**（源码判据是 `time > 10_000_000_000_000L`，不是"位数"）：写 `10000000000000`（=10^13，**恰好等于阈值 ⇒ 期望放行**）、`10000000000001`（⇒ 期望拒绝）、`-10000000000001`（⇒ 期望拒绝）。**需求文档写"位数超过 13 位"，源码写 `>10^13`，两者在"恰好 10^13"这一点上不一致 —— 用例按源码断言，并把差异回报研发**。
  3. **关闭相**：`SET CONFIGURATION 'timestamp_precision_check_enabled'='false'` → 重放第 1 步的 14 位时间戳 ⇒ 期望**成功**；然后置回 `'true'` 并重放 ⇒ 期望**失败**（证明开关真的起作用，而不是"碰巧成功"）。
  4. **us 相**：改 `timestamp_precision=us` → 重启三节点 → 写 16 位 `1693987852987000` 期望成功、17 位 `16939878529870000` 期望失败（源码阈值 `10_000_000_000_000_000L`）。
  5. **ns 相**：改 `timestamp_precision=ns` → 重启三节点 → 写 `9223372036854775807`（19 位）期望成功（源码 ns 分支直接 `break`，不检查）。
  6. **权限相**：用**非 SYSTEM 用户**执行 `SET CONFIGURATION 'timestamp_precision_check_enabled'='false'` ⇒ 期望被拒。
- **判据**
  - **双信号**：`log_datanode_all.log` 中 `SemanticException` / 精度报错文案行数 +N；该库 `SELECT s1 FROM root.cr01.d1`（原始查询数行）行数 = 合法写入条数（被拒的**不落任何行**）。
  - **数据面**：成功写入的 `(time,value)` 与语料逐字节一致；`FLUSH` 前后行数不变；三副本一致。
  - **错误码**：预期报错的必须写明 —— 期望 **507**（`SemanticException`）且文案逐字含：
    `The timestamp is unexpectedly large, you may forget to set the timestamp precision.Current system timestamp precision is ms, please check whether the timestamp 16939878529870 is correct.If you insist to insert this timestamp, please set timestamp_precision_check_enabled=false and restart the server.`
    （文案来源 `iotdb-core/node-commons/src/main/i18n/en/org/apache/iotdb/commons/i18n/QueryMessages.java:241-245`；中文版 `.../zh/.../QueryMessages.java:242-246` 为「请设置 timestamp_precision_check_enabled=false 并重启服务。」——注意**中英文案不一致**，用例只断言"含关键字"而不是整句）。
  - **场景有效性硬断言**：① 每次改 `timestamp_precision` 后必须**逐节点**确认生效值（table 方言 `show configuration;` 三列，或 `SHOW VARIABLES`）；不一致 ⇒ 判"场景未成立"。② 关闭相必须同时拿到"开启时同一 SQL 失败 / 关闭时成功"两侧，只测一侧 ⇒ 判"场景未成立"。③ 若非法写入在 CN/解析层就被挡、DN 日志无该 SQL 的 `SemanticException`，则记 WARN（检查点位置与需求预期不同），不直接判 FAIL。④ 权限相若返回码未在文档中给出，只断言"非零且非成功"，并把实际码记录为待研发确认。
  - **源码出处**：`iotdb-core/node-commons/src/main/java/org/apache/iotdb/commons/queryengine/utils/TimestampPrecisionUtils.java:66-90`（阈值与 ns 短路）；`.../commons/conf/CommonConfig.java:204`（`private boolean timestampPrecisionCheckEnabled = true;`）；`.../commons/conf/CommonDescriptor.java:266`（键名）；`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/IoTDBDescriptor.java:2804-2811`（热改）；`.../i18n/en/.../QueryMessages.java:241-245`。

---

### CR-02 精度检查的兼容性与时间分区膨胀对照

- **模型/集合/耗时**：tree / `write` / 20 min
- **前置**：`timestamp_precision=ms`（restart 生效，确认后不再改）；`timestamp_precision_check_enabled` 可热改；三副本；库 `root.cr02`。
- **构造步骤**
  1. `timestamp_precision_check_enabled=true`；连续写 10 条 ns 精度时间戳（相邻间隔 1s，如 `1693987852987000000 + k*1_000_000_000`, k=0..9）⇒ 期望**全部被拒**。
  2. 数时间分区目录：`ls -d <IOTDB_HOME>/data/datanode/data/sequence/root.cr02/<regionId>/*/` ⇒ 记录基线。
  3. `SET CONFIGURATION 'timestamp_precision_check_enabled'='false'`；重放同样 10 条 ⇒ 期望**全部成功**；`FLUSH`。
  4. 再数时间分区目录 ⇒ 断言**显著增多**（需求原文现象为 10 个）。同时 `SELECT s1 FROM root.cr02.**` 数行。
- **判据**
  - **双信号**：时间分区目录数（`find … -maxdepth 1 -mindepth 1 -type d | wc -l`）与 `log_datanode_all.log` 中报错行数（开启相 +10、关闭相 +0）。
  - **数据面**：关闭相写入的 10 行 `(time,value)` 与语料逐字节一致、三副本一致；开启相 0 行。
  - **错误码**：开启相 10 次全部 **507** + 上述逐字文案。
  - **场景有效性硬断言**：① 必须**先**证明开启相真的拦住（0 行、10 条报错），**再**证明关闭相放行（10 行）—— 顺序反了会互相掩盖。② 分区数必须用**该库自己的** region 目录统计（`SHOW DATA REGIONS`/`SHOW REGIONS` 拿 regionId），不能用全局目录数。③ 若关闭相分区数没有明显增长：先查 `FLUSH` 是否真的落盘（`Async close`）、`dn_data_dirs` 层数，仍不成立 ⇒ 判"场景未成立"（旧版行为或分区策略变更），**不要**判产品缺陷。④ **R-05 性能项只做弱判据**：同一 10 万点写入在开关两态下计时对照，**仅当关闭态比开启态快 >30% 时 WARN**（原文只写"不会显著影响"，无阈值依据），不判 FAIL。
  - **源码出处**：`TimestampPrecisionUtils.java:66-90`；时间分区由 `newTsFileResource.getTimePartitionWithCheck()` 派生（`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/storageengine/dataregion/DataRegion.java:4935`，用于注册的分区 id 见 `:5027`）。

---

### CR-03 表模型"只有 Time 列"门禁（写入 + load）

- **模型/集合/耗时**：table / `write` / 25 min
- **前置**：table 方言；无需重启；三副本；库 `cr03`（写入相）、`cr03b`（load 相来源库）、`cr03c`（load 目标库）。
- **构造步骤**
  1. **写入相**：`create table t0(s1 int32 field, s2 int32 field)` → `insert into t0(time) values(1)` ⇒ 期望**被拒**；`insert into t0(time,s1,s2) values(1,null,null)` ⇒ 期望**成功**（有 field 列，只是值为 null）。
  2. **场景 1（DROP 全部 field 列后合并）**：逐字复刻文档 SQL ——
     `create database cr03b` / `use cr03b` / `create table t1(s1 int32 field, s2 int32 field)` / `insert into t1(time,s1,s2) values(1,2,3)` / `flush` / `insert into t1(time,s1,s2) values(2,2,3)` / `flush` / `alter table t1 drop column s1` / `alter table t1 drop column s2`。
     开合并（`enable_seq_space_compaction=true`，写入期先关，写完记基线再热开）→ 等 `log_datanode_compaction.log` 出现 `Sequence InnerSpaceCompaction task finishes successfully` 且该库 TsFile 数 **2→1**；把合并产物 `.tsfile` 从 DN 的 `sequence/cr03b/<regionId>/<tp>/` 拷到 `/tmp`。
  3. 在 `cr03c` 上执行 `load '<path>'` ⇒ 期望**失败**。
  4. **场景 2（field 全 null 后合并）**：同 2/3，但写入用文档原文 `insert into t1(time,s1,s2) values(1,null,null)` / `values(2,null,null)`。
  5. **对照组**（场景有效性关键）：同一份语料但**不 DROP COLUMN**（`cr03d`），同样 `flush`×2 + 合并，把产物 `load` 到 `cr03c` ⇒ 期望**成功**。
- **判据**
  - **双信号**：合并日志 `finishes successfully` 行数 +1 **且** 该库 TsFile 数下降；load 相 `log_datanode_all.log` 报错行 +1。
  - **数据面**：`DROP COLUMN` 前后 `select count(time) from t1` 行数不变（1、2 两行都在）；load 失败后目标库 `select count(time)` 不增加。
  - **错误码**：写入相期望 **507**；load 相 **必须实测确认是 1100 还是 507** —— **需求文档给的是 `1100`（逐字见 R-13），但源码里 load 路径 `validateTableHeaderSchema4TsFile` 抛的是 `SemanticException`（≈507），写入路径是同一文案**（`TableHeaderSchemaValidator.java:116-119` 与 `:361-364`）。⇒ 判据写成「错误码 ∈ {1100, 507} **且** Detail 逐字含 `No column other than Time present, please check the request`」，并把实测码回报研发。
  - **场景有效性硬断言**：① 必须证明"合并真的产出了文件，且该文件确实只有 Time 列"——用 `desc t1` 只剩 time 列 + 对照组 load 成功/实验组 load 失败形成 **A/B 对照**；② 若合并产物仍能被 load（旧版行为）⇒ 判"场景未成立"并 WARN，**不判**产品缺陷；③ 必须证明合并真推进（finishes +1 且文件数下降），否则判"场景未成立"。
  - **源码出处**：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/queryengine/plan/relational/metadata/fetcher/TableHeaderSchemaValidator.java:102-119`（`validateTableHeaderSchema4TsFile`，load 路径）、`:350-364`（写入路径 `measurementCount == 0`）；消息常量 `iotdb-core/datanode/src/main/i18n/en/org/apache/iotdb/db/i18n/DataNodeQueryMessages.java:917-920`（另有 `NO_FIELD_COLUMN_PRESENT_PLEASE_CHECK_THE_REQUEST` = `No Field column present, please check the request`）；集成测试的期望码 `integration-test/src/test/java/org/apache/iotdb/relational/it/db/it/IoTDBInsertTableIT.java:1103`。

---

### CR-04 `.mods2` 基础形态与共享性

- **模型/集合/耗时**：tree + table / `delete` / 25 min
- **前置**：三副本 IoTConsensus；无需重启；库 `root.cr04`（tree）+ `cr04b`（table）。
- **构造步骤**
  1. **tree**：`CREATE DATABASE root.cr04` → `INSERT INTO root.cr04.d1(time,s1) VALUES(...)`（100 行）→ `FLUSH` → 再写 100 行 → `FLUSH`（造 2 个 TsFile）。
  2. `DELETE FROM root.cr04.d1.** WHERE time<=50`（**必须带 `.**`**）。
  3. 到各 DN 的 `data/datanode/data/sequence/root.cr04/<regionId>/<tp>/` 下 `ls -l`：期望出现 `<tsfile全名>.mods2`（`ModificationFile.getExclusiveMods`：`new File(tsFile.getPath() + ".mods2")`）。
  4. **共享性硬探针**：检查**是否**出现 `<level>-<modFileNum>.mods2`（`composeFileName(level, modFileNum)`）。**本构建 `useSharedModFile=false` ⇒ 期望"每 TsFile 一个 `.mods2`"、不出现 `<level>-<n>.mods2`**（见判据中的场景有效性断言）。
  5. **Entry 类型字节**：`od -An -tx1 -N1 <file>.mods2` ⇒ tree 期望首字节 `0x01`；table 库（`DELETE FROM tb WHERE time<=T`）期望 `0x00`。
  6. **首次删除才分配**：在**未删过**的第三个 TsFile 上确认其无 `.mods2`；对其做一次删除后再看 ⇒ 才出现 `.mods2`。
  7. **重复删除**：重放同一条删除 ⇒ `.mods2` **文件数不变**、字节数增加（entry 追加）。
- **判据**
  - **双信号**：`log_datanode_all.log` 中 `[Deletion] Deletion {} is written into {} mod files`（`StorageEngineMessages.java:737-738`）行数 +1；`.mods2` 文件数（步骤 2/6）/ 字节数（步骤 7）变化。
  - **数据面**：`SELECT s1 FROM root.cr04.d1`（原始数行）== 50；三副本一致。
  - **错误码**：删除语句本身成功（无错误码）；重放第 7 步也不得报错。
  - **场景有效性硬断言**：① 必须先证明"删除真的落到 Mod 文件"（`.mods2` 存在且 `stat -c %s` > 0），否则判"场景未成立"。② **构建假设断言**：若发现 `<level>-<n>.mods2`，说明构建已切到 V2 共享方案 ⇒ 本用例判"**场景假设失效（构建变更）**"并转用共享方案判据（此时 R-16/R-18 才可观测）。③ `DELETE` 前后必须 `FLUSH` 完成并等三副本 apply（删除走共识），否则行数偏大 ⇒ 判"场景未成立"。
  - **源码出处**：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/storageengine/dataregion/modification/ModificationFile.java:64-65`（`.mods2` / `.compaction.mods2`）、`:406-408`（`getExclusiveMods`）、`:257-267`（`composeFileName` / `parseFileName`）；`.../modification/ModEntry.java:148-149`（`TABLE_DELETION((byte) 0x00)` / `TREE_DELETION((byte) 0x01)`）、`:64-70`（serialize：type + min + max）；**共享开关** `.../dataregion/tsfile/TsFileResource.java:153` `public static final boolean useSharedModFile = false;`（**编译期常量，不可配置**）；`.../modification/PartitionLevelModFileManager.java:61-140`。

---

### CR-05 Mod 文件分配阈值（`n_threshold` / `size_threshold`）

- **模型/集合/耗时**：tree + table / `delete` / 25 min
- **前置**：三副本；**无需重启**（阈值在源码里是实例字段，**不可配置** —— 见下）；库 `root.cr05`。
- **构造步骤**
  1. 关合并（三类合并全关），连续"写一批 + `FLUSH`"造 N（≥10）个同层 TsFile。
  2. 对**第一个** TsFile 做一次删除 ⇒ 触发首次分配（`allocateFor` → `prev/next` 链条找已持有 Mod 文件的邻居 → `tryShare` → 失败则 `allocateNew`）。
  3. 反复对**新** TsFile 做删除，制造"上一文件已有 Mod 文件"的局面，观察是否被共享：由于 `singleModFileSizeThresholdByte = 16 * 1024L`、`levelModFileNumThreshold = 30`（**硬编码**），小 `.mods2` 会被共享 ⇒ 期望**多个 TsFile 指向同一个 `.mods2`**（用 `grep -l` 同一文件内容 / 数 `.mods2` 文件数 < 被删 TsFile 数来证明"共享发生"）。
  4. 用 `INSERT` 大 payload（TEXT）把某 `.mods2` 写到 >16KB（大量删除条目），再对下一个 TsFile 删除 ⇒ `tryShare` 返回 false ⇒ 期望**新分配**一个 `.mods2`（文件数 +1）。
- **判据**
  - **双信号**：`log_datanode_all.log` 中 `[Deletion] Deletion … is written into … mod files` 行数；`.mods2` 文件数（相对"被删除影响的 TsFile 数"的比值）。
  - **数据面**：`SELECT` 行数在删除后 = 期望值、三副本一致、合并前后指纹不变。
  - **错误码**：无预期报错。
  - **场景有效性硬断言**：① 必须证明"上一个 TsFile 确实已有 Mod 文件"（`ls` 出该 `.mods2`），否则"共享"分支根本没被走到 ⇒ 判"场景未成立"。② 必须证明"删除覆盖了 ≥2 个 TsFile"（否则只涉及 1 个文件，分配策略无从体现）。③ **原文说 `n_threshold`/`size_threshold` 是"可配置参数"，但 RC7 源码是 `PartitionLevelModFileManager.java:36-37` 的 `private final int levelModFileNumThreshold = 30;` / `private final long singleModFileSizeThresholdByte = 16 * 1024L;`，且配置模板中**查不到**对应键** ⇒ 用例**不得**依赖配置项；断言写成"在硬编码阈值下共享/新分配行为符合 `tryShare` 语义"，并把"文档称可配置 / 实现为硬编码"作为**实现偏差**单列回报（见 §4-B2）。
  - **源码出处**：`.../modification/PartitionLevelModFileManager.java:36-37`（硬编码阈值）、`:61-95`（`allocateFor` 沿 prev/next 找邻居）、`:97-120`（`tryShare`：引用为空→不共享；`idModificationMap.size() > levelModFileNumThreshold` → 共享；`getFileLength() < singleModFileSizeThresholdByte` → 共享；否则不共享）、`:122-140`（`allocateNew`，编号 = 该层最大编号 +1）、`:142-149`（`releaseFor`：引用清空 ⇒ `modificationFile.remove()`）。

---

### CR-06 删除 × 合并并发（N_Mod / C_Mod / 目标再被合并）

- **模型/集合/耗时**：tree + table / `delete` / 25 min
- **前置**：三副本；三类合并**先关**（`enable_seq_space_compaction=false` 等），写完记基线再热开；库 `root.cr06`。
- **构造步骤**
  1. 关合并，写 4 批 + `FLUSH` 造 4 个 L0 seq TsFile（对应原文 1-1-0-0 … 4-4-0-0）。
  2. 热开 `enable_seq_space_compaction=true`，轮询 `log_datanode_compaction.log` 直到出现 `Sequence InnerSpaceCompaction task starts` 且**文件数尚未下降**（这是"合并确实进行中"的硬证据）。
  3. 在合并窗口内立刻执行 `DELETE FROM root.cr06.d1.** WHERE time<=T`（T 落在源文件范围中部）。
  4. 等合并完成（`finishes successfully` + 文件数下降 + 连续两次稳定）。
  5. 查询被删范围 ⇒ 期望**仍被删除**（删除没有因为合并而丢失）。
  6. **目标再被合并相**：制造"删除执行前，合并目标文件又被另一个合并吃掉"的时序（反复：开着合并连续 flush + 逐步 DELETE），断言最终查询结果与"删除后不应存在的数据"一致；重点断言**最终文件集合里没有复活的行**。
- **判据**
  - **双信号**：合并日志 `starts`/`finishes successfully` 行数；TsFile 数下降 + `.mods2`（或 cascade 目标）状态变化（**本构建 `useSharedModFile=false` ⇒ 不要断言 `.compaction.mods2` 文件存在**，改断言"合并后目标文件仍受删除约束"这一**语义**判据）。
  - **数据面**：删除范围内的行在合并后**不得复活**；未删除范围的行数/指纹与合并前完全一致；`FLUSH` 后三副本一致；停 1 DN 后另两副本结果一致。
  - **错误码**：无预期报错（尤其不得出现 `CompactionTableSchemaNotMatchException` 等）。
  - **场景有效性硬断言**：① 必须拿到"合并确实进行中"的直接证据（`task starts` 且文件数未降），否则删除可能落在合并之后 ⇒ 判"场景未成立"。② 必须证明删除**真的涉及了正在被合并的源文件**（`.mods2` 里出现该时间范围），否则"并发"根本没发生 ⇒ 判"场景未成立"。③ 若窗口太短抓不到（合并 1s 内完成），用 `compaction_schedule_interval_in_ms` 或大数据量把窗口拉长，而不是降低断言强度。
  - **源码出处**：`.../compaction/execute/utils/CompactionUtils.java:231-254`（`prepareCompactionModFiles`：**`useSharedModFile=false` 时走 `setCascadeFile` cascade 路径并 return**，`:264-271` 的 `setCompactionModFile` **只在共享模式下执行**）、`:199-229`（`combineModsInCrossCompaction` 读 `.compaction.mods2`，共享模式下直接 return）、`:280-292`（`combineModsInInnerCompaction`）；`.../modification/ModificationFile.java:65,410-417`（`.compaction.mods2`）；`TsFileResource.java:601-617`（`getCompactionModFile`/`removeCompactionModFile`，`:613` 有 `&& !useSharedModFile` 条件）。

---

### CR-07 删除写入流程的中间态（未落盘 / 正在 flush）

- **模型/集合/耗时**：tree + table / `delete` / 20 min
- **前置**：三副本；**关合并**（避免合并把"未关闭文件"提前处理掉）；库 `root.cr07`。
- **构造步骤**
  1. 写入若干行但**不 flush**（数据只在 memtable）⇒ `DELETE FROM root.cr07.d1.** WHERE time<=T`（覆盖 memtable 里的行）。
  2. **立即查询** ⇒ 期望 memtable 中的行已被删除（对应原文"将 e 应用到 f 的 MemTable"）。
  3. 制造"正在 flush"窗口：连续 `INSERT` + `FLUSH`，在 flush 进行中下发 DELETE（用较大 payload 把 flush 拉长），覆盖正在刷出的文件的时间范围。
  4. `FLUSH` 完成后查询 ⇒ 期望被删行不在。
  5. 再做一次"删除 → 检查文件存在性 → 文件已被合并/删除 → 重新获取列表"的循环触发（提高合并频率 + 反复删除），断言无遗漏。
- **判据**
  - **双信号**：`log_datanode_all.log` 中 `[Deletion] Deletion with {} in workMemTable, {} points deleted`（`StorageEngineMessages.java:841-842`）与 `[Deletion] Deletion : {} written when flush memtable`（`:292`）行数变化；TsFile/`.mods2` 侧面变化。
  - **数据面**：删除后 `SELECT`（原始数行）== 期望值；flush 完成后与 flush 前一致；三副本一致；合并前后指纹不变。
  - **错误码**：无预期报错。
  - **场景有效性硬断言**：① 步骤 1 必须先证明"数据只在 memtable"（`SELECT` 能查到、数据目录无新 TsFile），否则 memtable 分支没被走到 ⇒ 判"场景未成立"。② 步骤 3 必须先证明"flush 确实在进行中"（日志有 flush 开始/`Async close` 相关信息、文件状态为未关闭），否则 ⇒ 判"场景未成立"。③ 若日志里那两条 `[Deletion] …` 在当前构建**不存在**（文案/级别变更），以"删除语义正确"为主判据、将日志判据降级为 WARN，并把缺失写进报告。
  - **源码出处**：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/storageengine/dataregion/DataRegion.java:3241-3301`（`deleteByDevice`：`writeLock("delete")` → `logDeletionInWAL` → `deleteDataInUnsealedFiles` → 释放写锁 → `deleteDataInSealedFiles`）、`:3303-3419`（`deleteByTable`）、`:3854-3886`（`deleteDataInUnsealedFiles` → `tsFileProcessor.deleteDataInMemory(deletion)`）、`:3889-…`（`deleteDataInSealedFiles`）；消息串 `StorageEngineMessages.java:157,288,292,841-842`。

---

### CR-08 Pipe 传输带删除操作的 TsFile

- **模型/集合/耗时**：tree / `delete` / 25 min
- **前置**：需要**第二个接收端实例**（本 3C3D 环境下可用同一集群的另一个库/另一台机器上的 1C1D；若无法提供独立接收端，见 §4-B5 替代方案）；`enable_last_cache=true`（与 CR-13 联动）；库 `root.cr08`。
- **构造步骤**
  1. 在源端建库写入 + `FLUSH` 造 ≥2 个 TsFile，对其中一部分做 `DELETE`（产生 `.mods2`）。
  2. 建 Pipe：`create pipe cr08 with extractor (...) with sink (...)`（全量同步 + 按 TsFile 传输），等同步完成并确认接收端行数正确（删除语义保持）。
  3. 校验接收端：被删行**不得**出现；`SELECT` 行数与源端一致；接收端自身磁盘上能看到接收到的 `.mods2`/Res 指向。
  4. **需重组路径**：构造源端 TsFile 在接收端分区规则下需要拆分的数据（跨时间分区/跨设备组），重复 1-3，断言拆分后删除语义仍保持（对应原文"使用 temp.mods2 对数据进行过滤"）。
- **判据**
  - **双信号**：源端/接收端 `[Deletion] …` 与 Pipe 传输日志行数；接收端 TsFile 数 + 行数。
  - **数据面**：接收端 `SELECT` 行数/指纹与源端**完全一致**（含被删行的缺失）；被删行不得复活。
  - **错误码**：无预期报错。
  - **场景有效性硬断言**：① 必须证明"源端确实有 `.mods2` 且删除覆盖了被传输的文件"；② 必须证明"传输真的走了该路径"（全量 vs 实时；是否需要重组由接收端分区规则决定，要有日志/文件证据），否则判"场景未成立"；③ 若环境无法提供独立接收端 ⇒ 按 §4-B5 处理，**不硬凑**单机"自己同步给自己"。
  - **源码出处**：**待查源码**（Pipe 侧的 `temp.mods2` 整合逻辑在 RC7 源码中未定位到与设计文档一字对应的实现；已确认相关入口：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/pipe/sink/util/builder/PipeTsFileBuilder.java:135,204-242`、`.../pipe/sink/protocol/tsfile/PipeTsFileLocalSink.java:288-327`、`ModificationFile.java:269-277`（`readAllCompactionModifications`））。

---

### CR-09 旧 Mod 兼容 + Res 变更 + 重启恢复 + Mod 文件生命周期

- **模型/集合/耗时**：tree + table / `delete` / 25 min
- **前置**：三副本；需要**一次重启**；库 `root.cr09`。
- **构造步骤**
  1. 写入 + `FLUSH` + `DELETE`（产生 `.mods2`）；记录删除后行数与 `.mods2` 列表、`md5sum`。
  2. **重启集群**（停 → 起）⇒ 断言：`SELECT` 行数与重启前完全一致（删除语义在 `TsFileResource` 异步恢复后被正确读回）；`.mods2` 仍在且被引用。
  3. **异步恢复窗口探针**：重启后**立刻**（恢复未完成时）下发 DELETE ⇒ 期望**要么正常完成、要么明确报"恢复未完成"类异常**（对应原文"如果一个 DataRegion 在异步恢复完成前接收到删除请求，则抛出一个异常"）。
  4. **孤儿 `.mods2` 清理**：人为在 region 目录里造一个不属于任何 TsFile 的 `.mods2`（如 `999-999.mods2`）→ 重启/等恢复完成 ⇒ 断言被清掉（原文"将所有不存在于 partitionModFiles 中的 .mods2 文件删除"）。
  5. **无引用 Mod 文件被删**：把所有引用某 `.mods2` 的 TsFile 通过合并清掉（合并会清理被删数据并释放引用）⇒ 断言该 `.mods2` 最终被删除（引用计数归零）。
  6. 重启后再查一次行数，断言与步骤 1 一致（持久性）。
- **判据**
  - **双信号**：重启前后 `log_datanode_all.log` 的恢复相关行 + `.mods2` 文件数/内容变化；`SELECT` 行数。
  - **数据面**：重启前后行数/指纹完全一致；三副本一致；合并前后指纹不变。
  - **错误码**：步骤 3 若报错，必须是"恢复未完成/删除不可用"语义的**明确**异常码（实测记录真实码）；不得是 NPE/静默失败。
  - **场景有效性硬断言**：① 步骤 3 的窗口极难命中：必须**先**证明"恢复确实未完成"（日志/文件证据），抓不到窗口就如实记"未构造成功"（**WARN**，不判 FAIL）。② 步骤 4 的孤儿文件必须确认重启前**确实存在**（`ls` 证据），否则"清理"无从谈起。③ `VERSION_NUMBER` 在 RC7 源码里**仍是 1**（`TsFileResource.java:129`），与原文"版本号从1更新为2"**不符** ⇒ 本用例**不要**断言 Res 文件二进制格式，只断言"重启后删除语义保持 + 孤儿清理 + 无引用删除"这些**可观测语义**；Res 二进制布局的断言留给 §4-B3。
  - **源码出处**：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/storageengine/dataregion/tsfile/TsFileResource.java:129`（`public static final byte VERSION_NUMBER = 1;`）、`:512-526`（`setSharedModFile` 记录 `sharedModFileOffset`）、`:528-572`（`prepareModFileForWrite` / `getSharedModFile`：`modFileManagement.recover(sharedModFilePathFuture.get(), this)`）、`:574-599`（`getExclusiveModFile`，含从 V1 升级的 future 与 `UPGRADING_MOD_FILE_INTERRUPTED` 日志）、`:619-626`（`resetModFile`）；管理/删除 `.../modification/PartitionLevelModFileManager.java:42-58`（`recover`）、`:142-149`（`releaseFor` → `remove()`）；V1 侧 `.../modification/v1/ModificationFileV1.java:58,203`（`.mods` / `.compaction.mods`）、`ModificationFile.java:282-296`（同时读 V1 与 V2 删除记录）。

---

### CR-10 DELETE 阻塞写入的量化与 IO 对照

- **模型/集合/耗时**：table / `delete` / 25 min
- **前置**：三副本；**关合并**（隔离变量）；库 `cr10`；需要一个"轻量写入线程 + 一个 DELETE"的并发脚本。
- **构造步骤**
  1. 建表 `cr10.t(id tag, s1 int32 field, ts timestamp time)`，写入 N 个设备 × M 行并 `FLUSH`，使**单个 region 内 TsFile 数分层**：分别构造 ~10 个 / ~100 个 / ~800 个 TsFile 三种布局（用"写一批 + `FLUSH`"循环，800 个文件可能耗时较长，可降到能观察到趋势的量级并**如实记录实际文件数**）。
  2. 每种布局下：
     a. 记录该 region 的 TsFile 数（`find ... -name '*.tsfile' | wc -l`）；
     b. 后台以固定速率 `INSERT`（轻量），同时执行一次 `DELETE TIMESERIES`（或 `DELETE FROM t WHERE time<=T`），计时该 DELETE 耗时；
     c. 记录后台写入在这段时间内的**成功写入条数**（吞吐）与最大无进展间隔。
  3. 对照：同一布局下不并发 DELETE 时的写入吞吐基线。
  4. 记录 `log_datanode_all.log` 中 `[Deletion] Deletion {} is written into {} mod files` 的 `{}` 数量（覆盖了几个 mod 文件）——作为 R-40/R-45 的"重复记录"证据面。
- **判据**
  - **双信号**：`[Deletion] Deletion … written into … mod files` 行数/参数；TsFile 数（布局证据）+ 删除耗时（秒）。
  - **数据面**：DELETE 后行数 == 期望；未删数据指纹不变；三副本一致。
  - **错误码**：无预期报错。
  - **量化判据（弱，只做趋势）**：删除耗时随"该 region TsFile 数"**单调不减**、并发 DELETE 期间写入吞吐**明显低于**基线 ⇒ 支持 R-38/R-39；由于原文的绝对数值（800 tsfile / 5-10ms / 4-8s）来自**客户现场**，本环境仅作**趋势对照**，不设绝对阈值。
  - **场景有效性硬断言**：① 必须证明"TsFile 数确实按预期分层"（打印实际值）；② 必须证明"后台写入在 DELETE 期间确实在跑"（有成功写入的行数增量），否则"阻塞"无从体现；③ `delete timeseries` 在 tree/table 方言下的可用性需先探测（若语法不支持 ⇒ 改用 `DELETE FROM`（表）/`DELETE FROM ….**`（树）并如实标注语义差异）；④ 若删除耗时小到噪声级（<100ms）⇒ 判"场景未成立/分辨率不足"，**不要**据此判"未阻塞"。
  - **源码出处**：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/storageengine/dataregion/DataRegion.java:3253`（`writeLock("delete")`）、`:3318`（`writeLock("delete")`，table 路径）；日志串 `StorageEngineMessages.java:737-738`。**`RegionWriteValidationRWLock().writeLock()` 这一精确锁名在 RC7 源码中未定位到**（现为 `DataRegion#writeLock`）⇒ **待查源码**（锁实现可能已重构）。

---

### CR-11 OBJECT 手动删除（整表 / 部分 / 整库）

- **模型/集合/耗时**：table / `object` / 25 min
- **前置**：三副本；`<IOTDB_HOME>/data/datanode/data/object/` 目录可读（**只读观测**）；库 `cro11`；表 `cro11.t(id tag, s1 int32 field, o object field, ts timestamp time)`。
  - OBJECT 写入语法（本环境实测，见 `compaction_skill/cases/common/co_object_ttl.sh`）：`insert into t(ts,id,s1,o) values(..., to_object(true,0,X'62'))`。
  - object 真实文件路径（实测）：`data/datanode/data/object/<regionId>/<base32(table)>[/tags]/{pointTime}_{tsVersion}.bin`，临时/回滚后缀 `.tmp` / `.back`（`ObjectTypeUtils.java:46-48`）。
- **构造步骤**
  1. 写入 K 个设备的若干行 OBJECT 数据（多批 + `FLUSH`），让 object 目录里出现多个 `.bin`；记**全局 object 文件总数**基线（`find <object dir> -name '*.bin' | wc -l`）与**本库 region 目录内的精确计数**。
  2. **部分时间范围删除**：`DELETE FROM cro11.t WHERE time <= T1`（只删一部分）⇒ 轮询等 object GC 结束。
  3. **整表删除**：`DELETE FROM cro11.t`（无 WHERE ⇒ `isDroppingTable()` 为真：无 tag 谓词 + 测点列表为空 + `[Long.MIN, Long.MAX]`）⇒ 轮询等 object GC 结束。
  4. **整库删除**：`DROP DATABASE cro11`（或另建 `cro11b` 后 DROP）⇒ 断言该 database 对应 data region 的 object 目录被清理（对应 R-51）。
  5. 每一步后查询：被删数据**查不到**，且 object 目录中对应 `.bin` **已消失**。
- **判据**
  - **双信号**（**双面**）：① `log_datanode_object_deletion.log`（logger 名 `OBJECT_DELETION`，`IoTDBConstant.java:150`）中 `Failed to remove object file {}`（`StorageEngineMessages.java:237`）行数**不得增加**（增加即异常路径）；② object `.bin` 文件计数**下降** + 查询行数**下降**。
  - **数据面**：删除范围外的行数与取值完全不变；同库其他表的数据/object **完全不受影响**（隔离性）；三副本一致。
  - **错误码**：删除语句成功；若出现 `getAllMatchedObjectDirs`/列目录失败（`Failed to list object directory: {}`，`StorageEngineMessages.java:238`）必须记为 FAIL。
  - **场景有效性硬断言**：① 必须**先**证明 object 文件确实存在于磁盘（否则"删除"没有对象）；② 删除后 object 数量**必须**下降，若数量不变但查询已查不到 ⇒ 说明只是"逻辑删除"（元数据行删掉但 `.bin` 残留）⇒ 这**正是 R-47 的失败模式**，判 FAIL 并附文件清单；③ **必须给足够等待窗口**：RC7 的物理删除是**异步**的（`ObjectGcJournal` + `ObjectGcWorker`，非文档所述"直接物理删除"），需轮询到稳定（连续两次计数不变）再判定；④ 若 object 文件**根本没生成**（`enable_object_storage`/tier 未配置、`dn_data_dirs` 无 object 层）⇒ 判"场景未成立"，先解决前置。
  - **源码出处**：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/storageengine/dataregion/DataRegion.java:3303-3419`（`deleteByTable`：WAL → `initializeObjectGc()` → `getAllMatchedObjectDirs` → `ObjectDirectoryScanner.renameTableDirForDrop` **墓碑改名**（`:3351-3362`）→ `ObjectDirectoryScanner.unlinkMatchingTempAndBack`（`:3384-3390`）→ `enqueueObjectGcAfterSealedDelete`（`:3407`，`ObjectGcJournal.append(ObjectGcRecord.dropTable/scan)`））、`:3568-3572`（`unlinkSidecarObjectFiles`，未落盘 memcrable 路径）、`:3626-3650`（`unlinkObjectPath`）、`:3683-3719`（`enqueueObjectGcAfterSealedDelete`）、`:3721-3779`（`recoverObjectGc` / `initializeObjectGc` / `stopObjectGc`）、`:2513,2552-2570`（`deleteAllObjectFiles`，整库/整 region 删除路径）；`.../dataregion/objectgc/ObjectDirectoryScanner.java:58`（`OBJECT_GC_TOMBSTONE_DIR = ".iotdb-objectgc"`）、`:62`（`scanAndDelete`）、`:223`（`unlinkMatchingTempAndBack`）、`:323`（`renameTableDirForDrop`）、`:403`（`dropTableDirs`）；`.../dataregion/modification/TableDeletionEntry.java:157-163`（`isDroppingTable()`）；`.../calc/utils/ObjectTypeUtils.java:46-48`；对象目录解析 `.../rescon/disk/TierManager.java:414-434`。

---

### CR-12 OBJECT 删除的异常路径与开销对照

- **模型/集合/耗时**：table / `object` / 20 min
- **前置**：同 CR-11；库 `cro12`。
- **构造步骤**
  1. **隔离性相**：建两个表 `t_keep` / `t_drop`，都写 OBJECT；只对 `t_drop` 做 `DELETE FROM t_drop`（或 `DROP TABLE t_drop`）⇒ 断言 `t_keep` 的 object 文件一个都不少、`t_keep` 查询结果不变。
  2. **异常路径**：在删除前把某个 `.bin` 所在的父目录改成不可写/不可删（`chattr +i` 或把目录 `remount,ro`；**注入必须硬校验生效**），然后 `DELETE FROM` ⇒ 期望：**其余文件仍被删除**、客户端**收到明确报错**、`log_datanode_object_deletion.log` 出现 `Failed to remove object file {}`。恢复权限后重试/等 GC ⇒ 残留文件最终被清理（或如实记录为"需人工介入"）。
  3. **开销对照（R-48）**：同一负载下，有 OBJECT 列 / 无 OBJECT 列两张表的 `DELETE FROM t WHERE time<=T` 各跑 3 次，记录耗时分布。
- **判据**
  - **双信号**：`log_datanode_object_deletion.log` 的 `Failed to remove object file {}` 行数（异常相期望 +1，其余相期望 +0）；object `.bin` 计数变化。
  - **数据面**：`t_keep` 行数/取值/object 文件数**完全不变**；异常相中 `t_drop` 的**其他** object 文件确实被删；被删行查不到。
  - **错误码**：异常相 **必须**出现"向客户端返回报错异常"（R-52 逐字要求）——实测记录真实错误码并写进报告（文档未给码）。**若客户端静默成功（无报错）⇒ 判 R-52 不满足**（前提是注入的只读/不可删确实生效，见场景有效性）。
  - **场景有效性硬断言**：① 只读/不可删注入**必须**硬校验（在目标目录里新建/删除文件必须报 `Read-only file system` / `Operation not permitted`），否则判"场景未成立"；② 必须有 `trap` 保证恢复权限；③ 开销对照为**弱判据**：只在"有 OBJECT 的删除耗时持续 >2× 无 OBJECT"时 WARN，**不判 FAIL**（原文只说"没有负面性能影响"，无阈值）；④ 若本环境无法对单文件做定向只读注入（object 目录与数据目录同盘）⇒ 如实列 §4，**不硬凑**。
  - **源码出处**：`DataRegion.java:3640-3650`（`unlinkObjectPath` 逐文件 try/catch + `objectDeletionLogger.error(FAILED_TO_REMOVE_OBJECT_FILE, bin, e)`）、`:3739-3779`（ObjectGc 初始化失败抛 `EXCEPTION_CANNOT_CREATE_OBJECT_GC_DIR_ARG_055D7364`）、`:4704-4757`（`insertAndRemoveObjectOnException` / `deleteUnregisteredObjectPath` / `deleteUnregisteredObjectFileWithRetry`，落盘后元数据插入失败则删文件）；`.../utils/DataNodeObjectFileService.java:195-203,219,369-374`（`deleteObjectFileForGc`、`FAILED_REMOVE_EMPTY_OBJECT_DIR`）。

---

### CR-13 Load 时 LastCache 三/四策略正确性

- **模型/集合/耗时**：tree + table / `load` / 25 min（4 个策略相 × 至少 1 次重启）
- **前置**
  - 配置（**均 `effectiveMode: restart`**，模板 `iotdb-system.properties.template:2894-2913`）：`last_cache_operation_on_load`（默认 `UPDATE_NO_BLOB`）、`cache_last_values_for_load`（默认 `true`）、`cache_last_values_memory_budget_in_byte`（默认 `4194304`）；`enable_last_cache=true`（模板 `:1353`）。
  - **每改一次策略必须重启三节点**；每次重启后**逐节点**核对生效值。
  - 三副本；库 `root.cr13`（tree）+ `cr13b`（table）。
  - 造一个"只含新数据"的 TsFile 作为 load 源（可用另一套/另一库写入后 `FLUSH`，把 `.tsfile`（+`.resource`，如需 object 还要带 object 目录）拷出）。
- **构造步骤**（对 `UPDATE` / `UPDATE_NO_BLOB` / `CLEAN_DEVICE` / `CLEAN_ALL` 四策略各跑一遍）
  1. 重启到目标策略，逐节点确认生效值。
  2. 写基础数据（时间戳 T1..Tn）→ `SELECT LAST s1 FROM root.cr13.d1` ⇒ 记结果 A。
  3. `load '<含更新数据的 tsfile 路径>'`（新数据时间戳 Tn+1..Tm **大于**已有水位）。
  4. 立刻（不重启、不清缓存）`SELECT LAST s1 FROM root.cr13.d1` ⇒ 记结果 B。
  5. 断言：
     - `UPDATE`：B == 新数据的最新值（含 BLOB 序列也被更新）。
     - `UPDATE_NO_BLOB`：非 BLOB 序列 B == 新值；**BLOB 序列**的 LastCache 被**失效**（不返回旧值）。
     - `CLEAN_DEVICE`：该 TsFile 所含设备的 LastCache 被清空；**未包含设备**的 LastCache 保持（用另一设备 d2 的 Last 作为"未被清"的证据）；`SELECT LAST` 仍返回**正确**值（清空只影响缓存，不影响结果）。
     - `CLEAN_ALL`：整库 LastCache 清空；`SELECT LAST` 仍返回**正确**值。
  6. **CLEAN_DEVICE 回退相**：构造"该 TsFileResource 没有设备级时间索引"的场景（可用 `LOAD` 时禁用/不生成设备级索引的路径，或直接以单设备极简文件 + 代码路径探针），断言回退到 `CLEAN_ALL`（脚本中若无法稳定构造 ⇒ 按 §4-C3 记为"部分未构造"）。
  7. **内存预算相**（R-57）：把 `cache_last_values_memory_budget_in_byte` 调到很小（如 `1024`）并重启，加载一个"最新值总量远超该预算"的 TsFile ⇒ 断言**最终 Last 结果仍然正确**（说明"丢弃缓存 + 流式读取"回退生效）；同时该相不得出现 OOM/异常。
- **判据**
  - **双信号**：`log_datanode_all.log` 中 load 相关行 + `Async close`/`Files to be loaded` 计数；LastCache 命中/失效可通过"`SELECT LAST` 结果是否正确" + 表模型 `information_schema`/`SHOW` 侧面观测；**核心是结果面**。
  - **数据面**：`SELECT LAST` 的 `(time,value)` **逐字**正确；`SELECT *` 全量行数与指纹在 load 前后 = 基础数据 ∪ 新数据，**无丢失、无重复**；三副本一致（逐个停 1 DN 比对）。
  - **错误码**：无预期报错；`load` 成功（不得出现 `1100`/`507` 等 schema 类错误，若出现即场景/前置问题）。
  - **场景有效性硬断言**：① **每个策略相都必须证明策略真的生效**：重启后逐节点读出生效值 == 设定值（`show configuration`/配置文件双证），不一致 ⇒ 判"场景未成立"；② 必须证明 **load 真的加载了新数据**（`SELECT` 全量行数增加 == 新文件行数），否则 LastCache 无更新对象；③ **LastCache 必须真的处于开启且已被填充**：在 load **之前**必须先做一次 `SELECT LAST`（把缓存填上），否则"清空/更新"无对象 ⇒ 判"场景未成立"；④ **必须证明 last 查询真的走了缓存**——用"load 后不重启立即查 Last 且结果正确"来证明；若怀疑未命中缓存，追加一轮"`CLEAR CACHE` 后重查必须同结果"的对照；⑤ BLOB 相需要表模型 OBJECT/BLOB 列（`to_object(...)`）才能构造，若 tree 侧无 BLOB 序列类型 ⇒ 该相只在 table 上跑并如实标注。
  - **源码出处**：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/IoTDBDescriptor.java:3461-3475`（三键读取）、`.../db/conf/IoTDBConfig.java:1360`（`private LastCacheLoadStrategy lastCacheLoadStrategy = LastCacheLoadStrategy.UPDATE;`）、`:1369`（`cacheLastValuesMemoryBudgetInByte = 4 * 1024 * 1024`）、`:5110-5123`（getter/`isUpdateLastCacheInLoad` 判定 `UPDATE || UPDATE_NO_BLOB`）；`.../queryengine/plan/relational/metadata/fetcher/cache/LastCacheLoadStrategy.java:21-30`（四枚举）；`.../storageengine/dataregion/DataRegion.java:4948-4964`（构造 `TsFileLastReader(filePath, true, strategy==UPDATE_NO_BLOB)`）、`:5048`（`onTsFileLoaded(newTsFileResource, isFromConsensus, lastReader)`）、`:5226-5256`（按策略分支 + 未识别策略回退 `CLEAN_ALL`，日志 `Unrecognized LastCacheLoadStrategy: {}, fall back to CLEAN_ALL`，`StorageEngineMessages.java:758`）、`:5277-5302`（`updateLastCacheIfExists` 两个调用点）；缓存侧 `.../metadata/fetcher/cache/TableDeviceSchemaCache.java:312-378`、`.../cache/TreeDeviceSchemaCacheManager.java:425-469`；**`TsFileLastReader` 类本身在 RC7 源码中未定位到**（`grep class TsFileLastReader` 在 `iotdb-core` 下零命中，但 `DataRegion.java:4948,4957` 有引用 ⇒ 可能在其他模块/包名不同）⇒ **待查源码**。

---

### CR-14 Load × Pipe + Last 查询性能与内存预算

- **模型/集合/耗时**：tree / `load` / 25 min
- **前置**：同 CR-13；另需 Pipe 接收端（同 CR-08 的限制）；`last_cache_operation_on_load` 四个取值各需一次重启。
- **构造步骤**
  1. **性能对照（R-58 / R-69 / R-71）**：对四策略各跑一次"写入线程 A 不断 load 增量 TsFile + 10 个查询线程随机查最新值"，记录：① 加载总耗时；② 平均 Last 查询延迟；③ 是否服务端出现异常。断言**方向性**：`UPDATE`/`UPDATE_NO_BLOB` 的加载耗时 **≥** `CLEAN_*`（同量级即算通过，原文只说"一定程度增加"），且 `UPDATE*` 的查询延迟 **≤** `CLEAN_*`。**绝对数值（如 52.50ms / 120.54ms）来自文档的 1C1D 实验环境，本环境不作绝对断言**，只记录到 `results/` 供跨版本比较。
  2. **`cache_last_values_for_load` 对照（R-56）**：`true` / `false` 两相（各一次重启），同一负载下比较加载耗时与查询延迟，断言方向与原文一致（`true` 更利于查询）。
  3. **内存预算触发相（R-57）**：`cache_last_values_memory_budget_in_byte` = 极小值 vs 默认值 两相，断言两相 **Last 结果一致**（预算只影响实现路径，不影响语义），且小预算相**无 OOM**、无异常日志。
  4. **Pipe × Last（R-70）**：建 Pipe 同步到接收端，接收端持续做 Last 查询；四策略各跑一遍，记录接收端查询延迟与源端写入吞吐。
  5. **权限相（R-59）**：以非 SYSTEM 用户 `SET CONFIGURATION 'last_cache_operation_on_load'='UPDATE'` ⇒ 期望被拒；以 SYSTEM 用户执行 ⇒ 期望成功（并验证返回"需重启"提示）。
- **判据**
  - **双信号**：load 相关日志行数 + 加载文件数/落盘 TsFile 数；查询延迟/加载耗时统计。
  - **数据面**：所有相位结束后 `SELECT LAST` 与 `SELECT *` 结果**完全正确**（不得因策略不同而结果不同）；三副本一致。
  - **错误码**：权限相期望明确拒绝码（实测记录）；小预算相期望**无** OOM/异常。
  - **场景有效性硬断言**：① 每个策略相都必须逐节点确认生效值 + 重启（含"重启前改、重启后验"两步）；② 查询线程必须**真的查到过数据**（有命中计数 >0），否则"查询延迟"无意义 ⇒ 判"场景未成立"；③ 内存预算相必须证明"预算真的被触发"（构造的最新值总量 > 预算），否则该相只是默认路径的重复 ⇒ 判"场景未成立"；④ 性能方向性不达预期时，先排除环境干扰（本环境节点间时钟已校正但在 ±1.5s 量级、后台可能有其他回归任务），**只 WARN 不 FAIL**；⑤ Pipe 相若无法提供独立接收端 ⇒ 按 §4-B5 处理。
  - **源码出处**：`IoTDBDescriptor.java:3461-3475`；`IoTDBConfig.java:1360,1369,5110-5123`；`DataRegion.java:4948-4964,5226-5256,5277-5302`；`StorageEngineMessages.java:758`；模板 `iotdb-system.properties.template:2894-2913`（`effectiveMode: restart`）。**性能测试的官方实现入口**：`org/apache/iotdb/db/it/IoTDBLoadLastCacheIT` / `...IoTDBLoadLastCacheIT#testTableLoadPerformance`（文档 R-68/R-69 指明）——**待查源码**（未在本地源码树定位到该类）。

---

## §4 不可构造 / 不可观测清单

> 环境：3C3D、三副本、IoTConsensus、RC7 `v20121rc7_1014_7c61428`。以下逐条写**原因**，不硬凑。

### A. 写入流程

| 编号 | 需求点 | 为什么不可构造 / 无客观判据 |
| --- | --- | --- |
| **A1** | **R-09 / R-10 / R-11**（写入内存实例分析的三条结论） | 该篇是**一次历史 OOM 堆转储的复盘**（1.3.2.3 rc1、单机 1GB 实例、`iotdb_6340.conf` 负载），不是需求条目。判据"RPC buffer 扩容开销需进一步监控""需要对公式（共识）模块的内存监控进行改造""应在 JVM OOM 前触发内存控制"都是**方向性改进建议**，没有可验收的量化口径（没有目标值、没有接口、没有错误码）。本环境也没有对应的 1GB 单机复现拓扑。⇒ **不做用例**，只作为"内存控制/共识内存监控"的长期观察项登记。 |
| **A2** | **R-05**（"不会显著影响写入性能"） | 只有定性表述，**无阈值、无基线版本**。本环境节点间存在后台长回归任务，耗时对比噪声大。⇒ 降级为 CR-02 内的**弱判据（仅 WARN）**，不设独立用例、不判 FAIL。 |
| **A3** | **R-15**（方案 2：允许写入请求只有 Time 列） | **讨论稿候选方案，文档未记录评审结论**，且源码现状是 **方案 1（拒绝）**：`TableHeaderSchemaValidator.java:116-119/361-364` 抛 `SemanticException`（`No column other than Time present…`）。没有"允许"的实现 ⇒ 无法构造正向用例。⇒ 需要**人工确认该讨论稿的最终结论**（见文末待确认清单）。 |

### B. 数据删除

| 编号 | 需求点 | 为什么不可构造 / 无客观判据 |
| --- | --- | --- |
| **B1** | **R-16 / R-17 / R-18**（共享 Mod 文件 + `<level>-<modFileNum>.mods2` 命名 + Res 记录 Mod 绝对路径） | **本构建该方案被编译期关闭**：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/storageengine/dataregion/tsfile/TsFileResource.java:153` → `public static final boolean useSharedModFile = false;`（**static final，不可配置、不可运行时切换**）。该常量在 `7c61428..HEAD` 区间**无改动** ⇒ 对 RC7 同样成立。此时走的是 `getExclusiveModFile()`（`<tsfile>.mods2`，每 TsFile 一个），**不会**出现 `<level>-<modFileNum>.mods2`，**也无法观测"不同 TsFile 共享同一 Mod 文件"**。⇒ CR-04 只能断言"当前形态"，并把"A/B 两形态的差异"作为**实现偏差**回报；真正的共享语义**不可构造**。 |
| **B2** | **R-21 后半句**（"n_threshold 和 size_threshold **均为可配置参数**"）与 **R-37**（`should_allocate` 进阶实现：自动算出 `n_IO_sum` 最小的阈值并应用到下一个时间分区） | 实现与文档不符：RC7 里两个阈值是**硬编码常量**——`PartitionLevelModFileManager.java:36-37`：`private final int levelModFileNumThreshold = 30;` / `private final long singleModFileSizeThresholdByte = 16 * 1024L;`；配置模板中**查不到**任何对应键。**进阶实现（自动计算）在源码中完全不存在**（全仓 `grep n_threshold|size_threshold|should_allocate` 只命中无关项与 V1 遗留）。⇒ "可配置"与"自动调参"**不可构造**，只能构造"硬编码阈值下的共享/新分配行为"（CR-05）。**建议作为设计-实现偏差回报研发**。 |
| **B3** | **R-29**（Res 文件版本号 1→2、`progressIndex`/`modFilePath` 位置交换、追加指针、记录 Mod 文件长度） | 实现与文档不符：RC7 的 `TsFileResource.java:129` 仍是 `public static final byte VERSION_NUMBER = 1;`；共享 Mod 文件路径改由 `sharedModFilePathFuture` + `sharedModFileOffset` + `ModFileManagement.recover()` 承担（`:143,151,528-572`），**不是**文档描述的"文件尾部截断重写 modFilePath + 指针"方案。⇒ 二进制布局断言**不可构造**（也无必要）；只能断言"重启后删除语义保持 + 孤儿清理 + 无引用删除"等语义（CR-09）。 |
| **B4** | **R-23 / R-24 中"C_Mod 文件（`.compaction.mods2`）"这一具体形态** | 同样受 `useSharedModFile=false` 约束：`CompactionUtils.prepareCompactionModFiles`（`:231-254`）在非共享模式下**直接 return**，改用 `setCascadeFile(compactionModFileSet)`（cascade 级联），`:264-271` 的 `setCompactionModFile(modificationFile)` **只在共享分支执行**。⇒ **`.compaction.mods2` 文件在本构建不会被创建**，无法按文件断言"每个 TsFile 指向两个 Mod 文件"。**语义（并发删除不丢）可构造**（CR-06），**文件形态不可构造**。 |
| **B5** | **R-27**（Pipe 传输 Mod 文件：整合出 `x-y.mods2` / `temp.mods2`）—— 部分受限 | 需要**两个独立集群实例 + 全量同步 + 需要拆分的分区规则**才能走完两种流程。本环境是单一 3C3D；用"同集群内 A 库→B 库"同步不能等价复现"跨集群 + 重组织"路径。且 RC7 源码里**未定位到与文档逐字对应的 `temp.mods2` 整合实现**。⇒ 列为**受限**：只能在能提供独立接收端时做 CR-08；否则如实记为"未构造"，**不硬凑**。 |
| **B6** | **R-35**（仿真结论："较小的 size_threshold (<= 64KB) 有比较好的总体效果"） | 来自**事件队列仿真**（`表1 仿真实验中使用的部分参数`），不是产品行为。判据是"写入耗时/读取耗时/加权总时间的相对优劣"，需要大规模负载与可控的删除/查询到达率，本环境（3 节点、共享）无法复用其实验条件。⇒ 不可构造。**另注**：该结论的 `size_threshold` 在实现里是硬编码 16KB（见 B2），与 64KB 结论对不上。 |
| **B7** | **R-36**（"为什么不使用一个分区一个 Mod 文件的设计"的四条理由） | **纯设计论证**（对备选方案的否定），没有对应的产品行为可观测。唯一的间接观测点是"Mod 文件是否按分区合并"——本构建已是"每 TsFile 一个".mods2（`useSharedModFile=false`），**与"一个分区一个 Mod 文件"两种方案都不是**。⇒ 不可构造。 |
| **B8** | **R-42**（思路二：mods 文件改成分区级别，每 region 每时间分区一个 mods 文件） | **未采纳的候选思路**（原文自身写着「需要继续设计，比如mods文件里存储的内容，对其他模块的影响 … 与原来的兼容」）。RC7 里没有任何"分区级单一 mods 文件"的实现痕迹。⇒ 不可构造。 |
| **B9** | **R-43**（思路三：CN 只往 follower 发 delete）+ **R-45**（只往 leader 发 delete，减少 1/2 IO） | 两条是**互相对立**的候选优化方向，文档未给出最终结论；而且 R-45 的收益判据（"减少集群整体 1/2 的 IO 消耗"）需要统计"一次 delete 被写到几个副本/几份 raft log"，属于**内部行为计数**，本环境没有稳定的只读观测面（`DeleteTimeseriesProcedure` 的下发目标不体现在用户可见输出里）。⇒ 不可构造/不可观测。**R-40（"一条 delete 命令被记录多次"）作为现象可由 CR-10 间接观测**，但"优化是否落地"不可判。 |
| **B10** | **R-44**（限流思路被否定） | **被否定的思路**，其"证据"是推理（「因为 delete 操作跟写入操作是互斥的，且 delete 操作目前是一个不可中断的操作（对应一条 raft log 的 apply）」），不是待实现需求。⇒ 无可验收对象。 |
| **B11** | **R-38 中精确锁名 `RegionWriteValidationRWLock().writeLock()`** | 该锁名在 RC7 源码中**未定位到**（现为 `DataRegion#writeLock("delete")`，见 `DataRegion.java:3253,3318`），说明锁实现可能已重构。⇒ CR-10 只能做**耗时的与阻塞的行为层面对照**，"确实持有这把锁"的源码级断言 **待查源码**。 |
| **B12** | **R-30** 的"异步恢复未完成时收到删除请求 ⇒ 抛异常" | 窗口极短（`TsFileResource` 异步恢复），在 3C3D 小数据量下**难以稳定命中**。⇒ 列为"不可稳定构造"：CR-09 步骤 3 抓不到窗口时如实记 WARN，**不判 FAIL**。 |

### C. 文件加载（LastCache）

| 编号 | 需求点 | 为什么不可构造 / 无客观判据 |
| --- | --- | --- |
| **C1** | **R-71**（文档实测性能数值：`UPDATE_NO_BLOB` 52.50ms / `CLEAN_DEVICE` 120.54ms 等） | 数据来自文档指定的另一套环境（`192.168.130.15/16` 1C1D、`172.20.31.60-62`、双活 `172.20.70.19/21`），且文档自身记录了"15 上的 jvm 会因为原因不明的 SIGSEGV 发生崩溃"等环境问题。本环境（3C3D、三副本、IoTConsensus、后台有长回归）**无法复现同样数值**。⇒ 只把本环境数值写入 `results/` 供跨版本比较，**不做绝对断言**（见 CR-14 判据）。 |
| **C2** | **R-61 / R-62 的接口级断言**（`iterAllTimeseriesMetadata` 签名、`TsFileLastReader` 的 `hasNext()`/`next()` 语义、"对齐序列返回结果包含时间列（测点名为空字符串）"） | 这是**内部 Java 接口**，不是 SQL 可观测面。`TsFileLastReader` 类在本地源码树 `iotdb-core` 下 `grep class TsFileLastReader` **零命中**（但 `DataRegion.java:4948,4957` 有引用）⇒ 类可能在其他模块/包名不同，**待查源码**。在本环境要做到接口级断言需要只读 Java agent（本任务禁止在 77/78/79/80 上跑东西）。⇒ **不可观测**，只做**端到端语义**断言（CR-13）。 |
| **C3** | **R-66 的"否则回退到 CLEAN_ALL 策略"**（TsFileResource 没有设备级时间索引时的回退分支） | 需要构造"某 TsFile 的 Res 里没有设备级时间索引"的状态。RC7 里这取决于异步恢复进度/文件生成路径（`TsFileResource` 的 level-1/level-2 索引），**没有公开 SQL 或配置能把文件固定在这个状态**。⇒ 列为"**部分未构造**"：CR-13 步骤 6 尝试构造，构不出来就如实记录，不硬凑。 |
| **C4** | **R-57 的"已缓存的部分超过该大小时，将会丢弃已缓存的最新值，改为使用流式读取的方式更新最新值"** | **语义结果**（Last 值正确）可构造（CR-13 步骤 7 / CR-14 步骤 3），但"**确实走了流式回退路径**"这一实现细节需要 `tsfile_size_threshold` 级日志或 agent 观测；RC7 源码里未定位到该分支的可观测日志。⇒ 路径本身**不可观测**，只断言语义等价 + 无异常。 |
| **C5** | **R-53 的前提（"Load 频繁到 LastCache 近乎失效"）** | 这是**性能退化现象**，其判据（"命中率"）需要缓存命中计数暴露面；RC7 没有把 LastCache 命中率作为可查指标暴露（`information_schema`/`SHOW` 无对应列）。⇒ 只能把"Load 后 Last 结果正确 + 延迟趋势"作为代理判据（CR-13/CR-14），**命中率本身不可观测**。 |

### D. Object 导入导出

| 编号 | 需求点 | 为什么不可构造 / 无客观判据 |
| --- | --- | --- |
| **D1** | **整个"Object 类型导入导出"方向（0 条 R-xx）** | 该篇（1369 字）**全篇为设计说明书模板占位文字**，逐字如「说明： / 分条列点明确本设计需要解决的问题」「模块1 / 说明：推荐以架构图结合描述的方式展开下列内容」「xxxx年x月x日 内部讨论 / 讨论录屏： / 讨论关键记录及结论：」——**没有任何需求或设计内容**。同时在 RC7 源码全仓检索 `exportObject|ObjectExport|importObject|ObjectImport|EXPORT OBJECT` **零命中**，说明该功能尚未实现。⇒ **既无需求可抽，也无实现可测**。**需要人工确认**：是"文档还没写"还是"需求已取消/改到别处"（见文末待确认清单）。 |
| **D2** | 与 D 相关的**间接可测点** | 唯一沾边的是 **OBJECT 的 load/传输**：`LoadSingleTsFileNode.java:164-168`（load 时按 `object` 目录名在 TsFile 同级找 object 目录）、`DataRegion.java:4936-4983`（`installPendingObjectFilesIntoTier`）、`Pipeline` 的 object 目录拷贝（`LocalFileTransfer.java:52-60`）。这属于 **CR-11/CR-08 的边角**，不是"导入导出"功能 ⇒ 不为此单列用例。 |

---

## §5 与已有 skill 的关系（去重）

参考文件（**只读**）：`compaction_skill\cases\cases.tsv`、`compaction_skill\docs\RESULTS.md`、`compaction_skill\results\final_results.csv`。

| 本文件用例 / R-xx | 已被 compaction_skill 覆盖的部分 | 处理 |
| --- | --- | --- |
| **CR-04**（`.mods2` 出现与内容） | **CO-05**「DELETE 数据后合并」已覆盖"删除后合并、被删行不复活、带 mods 文件参与合并"（RC6 `PASS` 523s，见 `RESULTS.md` 行 27）；**CO-26**「settle 选择门控」已覆盖 `.mods` 文件的阈值/磁盘冗余门控与"清理 `.mods`"（`PASS` 541s，`RESULTS.md` 行 193） | **参考/复用 CO-05、CO-26 的断言与 helper**；CR-04 只补"Mod 文件命名/共享性/Entry 首字节"这一**未覆盖**角度。**不重复**"删除后合并不复活"这条（直接复用 CO-05）。 |
| **CR-06**（删除 × 合并并发） | **CO-05**（删除后合并）+ **CO-40**（合并临时态与恢复四分支，含"预批→DELETE 造 `.mods`（`MODS>0` 硬断言）"） | **复用 CO-40 的"先造 `.mods` 并硬断言存在"手法与 BENIGN 噪声清单**；CR-06 只补"**合并进行中**下发删除"这一时序（CO-05/CO-40 都是"删除在前、合并在后"）。 |
| **CR-09**（Mod 文件生命周期/重启） | **CO-40** 已覆盖"合并中 `kill -9` 后残留文件/句柄、无孤儿 `.mods`"；**CO-29** 覆盖"合并进行中 kill -9 一个 DN → 重启恢复" | **复用 CO-40 的"无孤儿 `.mods`"断言**；CR-09 只补"**人为造孤儿 `.mods2` 必须被清**"与"引用归零后被删"这两个**正向清理**判据。 |
| **CR-11 / CR-12**（OBJECT 删除与清理语义） | **CO-41** `co_object_ttl.sh` 已覆盖大量 OBJECT 现场机制：object 目录形态 `data/datanode/data/object/<regionId>/<base32(table)>[/tags]/{pointTime}_{tsVersion}.bin`；**D7-2「合并只清理因 TTL 过期的 object，不清理因 deletion 删除的」**；**DELETE 后的 object 回收由独立 GC 线程完成**（线程 `pool-*-IoTDB-Object-GC-*`、logger `o.a.i.d.u.DataNodeObjectFileService`，DELETE 后 ~6s）、TTL 路径删除数需为 0；**CO-06** 覆盖 `DROP TABLE` / `DROP DATABASE` 重建 / `DELETE DEVICES` 后元数据不复活 | **强烈建议复用**：CR-11/CR-12 直接沿用 CO-41 的 object 计数 helper 与"TTL 路径删除数 vs GC 路径删除数"的分离口径（否则会把 GC 的正常删除误判成缺陷）。CR-11 的**新增点**只有：`DELETE FROM t`（整表）→ **墓碑改名 + 异步 GC** 后 object 目录必须消失；`DROP DATABASE` → 整个 region 的 object 目录被清；以及"object 数量不降但查询为空"这一**失败模式**的显式判据。 |
| **CR-13 / CR-14**（Load 时 LastCache） | **未覆盖**。compaction_skill 中无任何 Load/LastCache 相关用例（`cases.tsv` 43 条用例全部围绕合并/改类型，唯一沾边的是 CO-41 的 table TTL 与 object）。TTL skill 里有 `enable_last_cache` 相关但无 Load 策略。 | **全部新增**，不重复造。仅复用通用的收尾三件套（sync lag / 副本一致性 / 日志扫描）与 `cmp_fp_*` 指纹 helper。 |
| **CR-01 / CR-02 / CR-03**（写入精度、无 field 列） | **未覆盖**（metadata_skill 覆盖 DDL 元数据，compaction_skill 覆盖合并，均无写入侧校验）。 | **全部新增**。 |
| **CR-10**（DELETE 阻塞写入量化） | **CO-11 / CO-42 / CO-35** 提供了"写入→计时→记录到 `results/perf_baseline.csv`"的性能基线范式 | **复用其计时与 CSV 记录格式**（便于跨版本对比），判据内容新增。 |
| 通用（收尾三件套） | **CO-\* 全系列**统一收尾：`check_sync_lag` → `consistency_check`（逐个停 1 DN）→ `check_logs`（含 NPE/OOM/越界/overlap 等 BENIGN 清单） | **直接复用 compaction_skill 的 `lib/common.sh` helper 与 BENIGN 正则清单**，不要重写；注意 `MD_LOG_BENIGN_EXTRA` 那类"只看本用例新增行"的做法（避免跨用例日志污染导致误判）。 |

**结论**：本文件 14 条用例中，**CR-13 / CR-14 完全新增**（LastCache-on-Load 方向此前无人覆盖）；**CR-11 / CR-12 需与 CO-41 严格去重**（CO-41 已覆盖 OBJECT 的 TTL/deletion 分离语义与 GC 线程观测口径，本文件只补"整表/整库删除后的物理清理判据"）；**CR-04 / CR-06 / CR-09 / CR-10 部分复用 CO-05 / CO-26 / CO-29 / CO-40 / CO-11 的断言与 helper**；**CR-01 / CR-02 / CR-03 / CR-05 / CR-07 / CR-08 为新增**。

---

## 附：待人工确认的点（尤其"这条到底算需求还是历史讨论"）

1. **R-15（方案 2：允许写入请求只有 Time 列）**：讨论稿给了两个方案但**没写结论**。源码现状 = 方案 1（拒绝，507）。**请确认该讨论稿最终采纳哪个方案**；若采纳方案 2，则 R-12/R-13 的"必须拒绝"判据要反过来写。
2. **`数据删除功能V2 设计文档` 的定位**：该篇放在 `数据删除_意见讨论稿\` 目录下（**意见讨论稿**），但内容是一份完整的总体设计（背景/方案/仿真/待讨论问题），且其中"共享 Mod 文件"方案在 RC7 被 `useSharedModFile=false` **编译期关闭**。**请确认**：(a) 它算"待实现需求"还是"历史讨论稿"？(b) 共享 Mod 文件方案是"已决定不做/延后"还是"已实现但开关默认关闭、后续打开"？这直接决定 §4-B1/B2/B4 是"不可构造"还是"待开开关后回归"。
3. **`写入内存实例分析` 的定位**：该篇是**一次 OOM 复盘**（1.3.2.3 rc1），三条结论都是方向性建议。我按"非需求"处理（§4-A1）。**请确认**是否要把它当作"内存控制"方向的验收需求。
4. **`Delete 性能优化` 的定位**：三条思路里思路一被**明确否定**、思路二/三**未定论**。我按"讨论稿"处理（§4-B8/B9/B10），只把"delete 阻塞写入"这一**现象**做成可构造用例（CR-10）。**请确认**是否有已落地的优化点需要专门的"优化生效"判据。
5. **mods2 / `useSharedModFile` 是否为已知状态**：RC7 里 `.mods2` 已落地，但**共享 Mod 文件是硬编码关闭**；`n_threshold`/`size_threshold` 是**硬编码 30 / 16KB**而文档称"可配置"；`Res` 版本号仍是 `1` 而文档称"1→2"。这三条是**设计-实现偏差**，需研发确认是"文档滞后"还是"实现未完成"。
6. **load 侧"无 field 列"的真实错误码**：文档逐字给 `1100`，源码同一文案在 `TableHeaderSchemaValidator` 抛的是 `SemanticException`（≈507）。**请在环境上实测一次 load 确认码**（本任务禁止跑用例，故未实跑）。
7. **篇目数差异**：任务描述"共 15 篇"，实际 `_manifest.json` = 6 目录 + 10 文档（9 成功 + 1 失败）。**请确认**是否有我未看到的第 11–15 篇（若是，请提供抓取路径）。
8. **`Object 导入导出` 篇**：**空白模板**，且源码无对应实现。**请确认**是"文档未写"还是"需求已取消"。
9. **CR-13 的 `TsFileLastReader` 与 CR-14 的 `IoTDBLoadLastCacheIT`**：本地源码树中**未定位到类文件**（`DataRegion` 有引用、源码树 grep 不到）。**请确认**是否需要我去别的分支/模块（如 `iotdb-core/datanode` 之外）定位，或直接标"待查源码"。
