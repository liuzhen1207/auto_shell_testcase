# 刘珍提出/创建的问题 — 自动化回归用例目录

数据源：PingCode V2 项目，创建人或提出人=刘珍；抓取时间 2026-11-04。

共 **131** 条（缺陷 114）。

## 自动化判定汇总

| 判定 | 数量 | 说明 |
| --- | --- | --- |
| 待人工确认 | 35 | 需读描述 |
| 可自动化(待设计) | 29 | 需补操作序列 |
| 已自动化(日志门禁) | 23 | 标准负载后扫日志特征（checks.json） |
| 需并发负载 | 15 | 需 benchmark 并发+数据断言 |
| 非缺陷 | 14 | 需求/史诗 |
| 环境不可复现 | 6 | 特殊环境 |
| 需升级场景 | 5 | 依赖旧版本升级 |
| 工具类 | 2 | 独立工具 |
| 已自动化 | 2 | 场景用例（QA-LZ） |

## 明细

| 编号 | 类型 | 迭代 | 状态 | 标题 | 自动化判定 | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| V2-1004 | bug | V2.0.10.1 | 发版 | [2.0.10.1]【审计日志】openSession期间审计日志写入再次触发慢请求审计【deadlock导致查询卡住】 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-1006 | bug | V2.0.10.1 | 取消 | 【V2.0.10.1】【Pipe-远程导出Object】目标端磁盘故障后连接资源未正确回收，导致Pipe STOPPED且故障恢复后仍无法重新启动 | 已自动化(日志门禁) | 日志门禁 CHK-1006 |
| V2-1007 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【Pipe】【TSFILE_REMOTE_SINK】DataNode异常信息明文打印sink.scp.password | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-1008 | bug | V2.0.10.1 | 发版 | 【V2.0.10.1】【load balance】扩容后手动执行LOAD BALANCE，CN leader日志中diskCounter显示全为0MB | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-1015 | bug | V2.0.10.1 | 发版 | 【V2.0.10.1】【多盘存储/Region迁移】DataRegion迁移后同一 tsfile 的 tsfile/resource/mods2 分散到不同 data dir【delete 数据重新可见】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1016 | bug | V2.0.10.2 | 走查 | 【2.0.10.1】【LOAD BALANCE】执行一次LOAD BALANCE ConfigNode 日志记录两段日志但未区分 DataRegion / SchemaRegion | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-1017 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【选盘策略优化】 IoTConsensus addPeer 在object海量小文件场景下 snapshot 接收端选盘开销过大，导致 peer 长时间 inactive、syncLag 长时间不下降 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1019 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【5C20D缩容1 故障DN 回归测试】region迁移并发执行时 sendSnapshotFragment 因 UncheckedIOException(NoSuchFileException) 失败 | 已自动化(日志门禁) | 日志门禁 CHK-1019 |
| V2-1021 | bug | V2.0.10.2 | 发版 | 【V2.0.10.1】【Snapshot传输海量小文件】发送端每文件固定分配10MB Buffer导致迁移耗时长 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1022 | bug | V2.0.10.2 | 发版 | 【V2.0.10.1】【Snapshot迁移日志】info级别输出全量文件列表导致日志量暴涨 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-1029 | bug | V2.0.10.2 | 发版 | 【V2.0.10.1】【多目录快照加载】SnapshotLoader 创建 tsfile 硬链接失败，fallback to copy | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1032 | bug | V2.0.11.1 | 发版 | 【V2.0.10.1】【多盘存储/Region迁移】show regions 与 Prometheus object_file_global_count 出现负值 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1038 | bug | V2.0.12.1 | 测试 | 【V2.0.10.1】【root.__audit DataRegion】root.__audit 在树模型批量写入场景下，会把完整路径列表写入 audit log 的对象/日志字段，导致单条审计记录异常膨胀 | 已自动化(日志门禁) | 日志门禁 CHK-1038 |
| V2-1039 | bug | V2.0.12.1 | 测试 | 【V2.0.10.1】【ConfigNode/Procedure】MIGRATE REGION 中途 stop CN leader 触发 ConfigNode 重新选主时，Prometheus 抓取指标 【报 NullPointerException：ProcedureExecutor.getActiveWorkerThreadCount 的 workerThreads 为 null】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1042 | bug | V2.0.11.1 | 发版 | 【2.0.10.1】【CompressionRatio】show regions CompressionRatio 显示为0，计算公式中分子没有加object大小（分母加了） | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1043 | bug | V2.0.11.1 | 发版 | 【2.0.10.1】【表模型 show regions中的TsFileSize】TsFileSize 不能把 object size 加进去 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1046 | bug | V2.0.11.1 | 发版 | 【V2.0.10.1】【JDBC客户端】查询执行过程中重启 DataNode，JDBC 自动重连后复用旧 statementId 重发查询 【报错 INTERNAL_SERVER_ERROR(305)：StatementId doesn't exist in this session】 | 已自动化(日志门禁) | 日志门禁 CHK-1046 |
| V2-1056 | bug | V2.0.10.2 | 发版 | 【2.0.10.2】【5C20D缩容故障DN回归测试】文件夹管理/磁盘空间策略：并发迁移时目标DN的snapshot目录选址遇并发删除子目录，误判磁盘满切ReadOnly致迁移失败、remove datanode失败 | 已自动化(日志门禁) | 日志门禁 CHK-1056 |
| V2-1059 | bug | V2.0.12.1 | 测试 | 【V2.0.10.2】【ConfigNode】执行 remove confignode 删除当前 Leader【transfer leader 失败导致删除失败】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1067 | bug | V2.0.12.1 | 待对齐 | 【V2.0.10.2】【region迁移回归测试】CN leader 切换后，同一轮 Region 1 迁移中 AddRegionPeerProcedure 出现 rollback/fail 与后续 success 并存，随后重试迁移因残留 AddRegionPeerProcedure 占用 Region 操作锁失败 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1082 | bug | V2.0.10.2 | 发版 | [2.0.10.2]【root.__audit系统表】 DNAuditLogger创建审计数据库时硬编码MAX_DATA_REGION_GROUP_NUM=1 【data_region_group_extension_policy非CUSTOM时校验报错525】 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-1083 | bug | V2.0.11.1 | 发版 | [master][CANCEL ALL MIGRATIONS] 取消迁移后接收端snapshot残余文件未清理 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1090 | bug | V2.0.11.1 | 走查 | [master][cancel迁移日志优化]执行 CANCEL ALL MIGRATIONS 取消 add-peer 阶段迁移【unexpected consensusGroupId 以 ERROR 连续输出】 | 已自动化(日志门禁) | 日志门禁 CHK-1090 |
| V2-1094 | bug | V2.0.12.1 | 测试 | [2.0.11.1][修复分区表] repair SQL 应该只放开树模型入口但实际树表一块生效 [旧数据未清理导致一个分区表 cell 同时写入两个 Region，查询返回重复记录] | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1095 | bug | V2.0.11.1 | 走查 | 【V2.0.11.1 RC1】【ConfigNode审计日志】顺序停止3C集群使最后一个Leader退主【CNAuditLogger连续抛出NullPointerException】 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-1100 | bug | V2.0.11.1 | 走查 | 【V2.0.11.1】【配置热加载】执行 set configuration region_migration_speed_limit_bytes_per_second 时【Object 写入触发 IndexOutOfBoundsException】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1108 | bug | V2.0.11.1 | 走查 | 【V2.0.11.1】【审计日志】Tree 模型执行 CANCEL ALL MIGRATIONS【成功和 803 拒绝均未生成操作审计记录】 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-1109 | bug | V2.0.13.1 | 待对齐 | 【V2.0.11.1】【SchemaRegion资源释放】table模型show regions为空时残留大量Region对象【DataNode触发direct buffer OOM】 | 已自动化(日志门禁) | 日志门禁 CHK-1109 |
| V2-1126 | bug | V2.0.11.1 | 走查 | 【V2.0.11.1】【IoTConsensus】取消 Region 迁移并发清理同一 Peer 时【TreeSet.remove 触发 NPE】 | 已自动化(日志门禁) | 日志门禁 CHK-1126 |
| V2-1132 | bug | V2.0.11.1 | 走查 | 【V2.0.11.1】【迁移取消】REMOVE Peer 异步任务执行期间取消迁移【远端任务仍删除副本并造成数据缺失】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1143 | bug | V2.0.12.1 | 测试 | 【V2.0.11.1 RC3】【ConfigNode监控指标】Follower晋升Leader期间持续抓取Procedure指标【workerThreads未初始化导致NullPointerException】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1148 | bug | V2.0.11.1 | 走查 | 【V2.0.11.1】【升级兼容/Schema Snapshot】旧版本混合模型数据升级启动 DataNode【恢复表设备统计时空指针导致启动失败】 | 需升级场景 | 需要旧版本数据/升级路径，当前 3C5D 单版本环境不具备 |
| V2-1151 | bug | V2.0.12.1 | 待对齐 | 【V2.0.11.1】【ConfigNode】并发 REMOVE REGION 跨时间分区写入时【分区申请超时导致全节点写入失败】 | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-1160 | bug | V2.0.11.1 | 走查 | 【V2.0.11.1】【查询引擎】表模型执行查询分析时【Analyzer耗时错误记录到Tree Plan Cost】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1161 | 6916ce7189a8f973bfebf24b | V2.0.13.1 | 排期确认 | 【逻辑视图查询】查询逻辑视图时【Analyze与LogicalPlan额外耗时导致性能低于原表】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1207 | bug | V2.0.11.1 | 走查 | 【V2.0.11.1】【Procedure框架】单DN Unknown 场景连续 DROP DATABASE【RemoveRegionGroupProcedure 长期占用线程导致后续 Procedure 调度超时】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1211 | bug | V2.0.11.1 | 走查 | 【V2.0.11.1】【表模型】数据库删除 Procedure 执行期间重启 DataNode【ConfigNode restartDataNode 持续 NPE 导致节点约 10 分钟无法注册】 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-1215 | bug | V2.0.13.1 | 待对齐 | 【V2.0.11.1】【REMOVE DATANODE】缩容过程中其他副本为 ReadOnly 时移除 DataNode【缩容卡死】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1220 | bug | V2.0.13.1 | 待对齐 | 【V2.0.11.1 RC7】【IoTConsensusV2】 持续写入含OBJECT数据时 【Pipe解析TsFile内存超时并跳过事件导致副本数据严重不一致】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-1221 | bug | V2.0.13.1 | 待对齐 | 【V2.0.11.1 RC7】【OBJECT/Pipe】 跨数据盘处理OBJECT文件时 【创建硬链接报Invalid cross-device link并导致事件引用失败】 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-185 | bug | V2.0.8.1 | 发版 | 【OBJECT】[ 2.0.8.1 RC1 ] 没有object数据，运行print-tsfile-resource工具，报磁盘满（实际未满）: All disks of tier 0 are full. | 已自动化(日志门禁) | 日志门禁 CHK-185 |
| V2-186 | bug | V2.0.8.1 | 发版 | 【object】2.0.8.1 RC1 写入(跨时间分区的)object数据，没用to_object ()写，DN ：BufferUnderflowException: null | 已自动化(日志门禁) | 日志门禁 CHK-186 |
| V2-343 | bug | V2.0.8.1 | 发版 | 2.0.8.1 RC1 ：1用户循环insert/delete 数据场景，DN ERROR：tsfile marking or ending file meet error（研发：Fix concurrent delete and flush error） | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-345 | bug | V2.0.8.1 | 发版 | 【查询OOM】查询SQL语法错误 (offset X limitY），DN OOM （田原：Fix OOM in SQL Parser ErrorHandler due to infinite loop in ATN traversal） | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-363 | bug | V2.0.8.1 | 发版 | [ 合并 ] 并发select/insert/delete数据，合并处理mods文件产生ERROR 日志（NoSuchFileException）需修复 | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-364 | bug | V2.0.8.1 | 发版 | 并发select/insert/delete 数据，查询报错"select time from t1_0 where device_id='d_143' order by time desc limit 1". executeStatement failed because Index 0 out of bounds for length 0 | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-374 | bug | V2.0.8.1 | 发版 | 树模型修改数据类型：数据类型是小写，修改失败：java.lang.IllegalArgumentException: No enum constant org.apache.tsfile.enums.TSDataType.text | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-375 | bug | V2.0.8.1 | 发版 | 树模型 每修改一次序列类型，CN 对应产生一条ERROR：ERROR o.a.i.c.p.i.StateMachineProcedure:181 - StateMachineProcedure pid=XX not set next state | 已自动化(日志门禁) | 日志门禁 CHK-375 |
| V2-376 | bug | V2.0.8.1 | 发版 | dn_data_dirs存储在多块盘，正常状态并发读写+缩容DN ，测试完成，重启DN ：合并报错 sequence files has overlap （可复现） | 已自动化(日志门禁) | 日志门禁 CHK-376 |
| V2-377 | bug | V2.0.8.1 | 发版 | 修改数据类型 ，CN Follower  节点：java.nio.BufferUnderflowException: null 和 NullPointerException: Cannot invoke "org.apache.iotdb.consensus.common.request.IConsensusRequest.markAsGeneratedByRemoteConsensusLeader()" because "deserializedRequest" is null | 已自动化(日志门禁) | 日志门禁 CHK-377 |
| V2-378 | bug | V2.0.11.1 | 发版 | 查询： cast(1.1 as float)  报错Msg: java.lang.UnsupportedOperationException: org.apache.tsfile.read.common.block.column.DoubleColumn（预期应该成功） | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-380 | story | V2.0.8.1 | 发版 | 日志优化：SELECT_INTO 过程中，drop 写回表 ，DN ERROR 日志可改为INFO 或WARN ：SemanticException: org.apache.iotdb.commons.exception.table.TableNotExistsException | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-383 | bug | V2.0.8.1 | 发版 | 查询：1 SQL （无并发）SELECT_INTO 卡死，可复现（田原已定位到2个问题点：最大内存初始化有问题 & 超时检测线程死循环） | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-392 | bug | V2.0.8.1 | 发版 | 修改数据类型 有写入失败，DN 空指针 &  ERROR o.a.i.d.s.d.DataRegion:1470 - Data inconsistent exception is not supposed to be triggered twice | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-396 | epic | V2.0.9.1 | 发版 | 表视图（定义基于树模型非对齐设备）last查询可优化，当前实现是：没下推，且为正序scan，会扫描所有的数据。田原：对于非对齐设备，虽然聚合不能下推，但last查询，可优化为倒序查，避免扫描所有数据 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-397 | bug | V2.0.9.1 | 发版 | 查询失败，sort算子：java.lang.ArithmeticException: / by zero | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-400 | bug | V2.0.8.1 | 发版 | 并发读写场景，查询有失败：ArrayIndexOutOfBoundsException: Index 5282 out of bounds for length 5282 | 已自动化(日志门禁) | 日志门禁 CHK-400 |
| V2-412 | bug | V2.0.8.2 | 发版 | 并发读写+修改数据类型，读tsfile出错（合并/ 查询失败）：org.apache.tsfile.exception. filter.StatisticsClassException | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-427 | bug | V2.0.8.2 | 发版 | 【合并】并发查询写入，并发delete数据，并发修改数据类型，合并报错：ArrayIndexOutOfBoundsException: Index 1 out of bounds for length 1，可复现（舒文炜：修改数据类型和 delete 同时存在可能有此问题） | 已自动化(日志门禁) | 日志门禁 CHK-427 |
| V2-430 | bug | V2.0.8.2 | 发版 | 修改数据类型，last查询失败：StatisticsClassException: BLOB statistics does not support: last | 已自动化(日志门禁) | 日志门禁 CHK-430 |
| V2-610 | bug | V2.0.9.1 | 发版 | 【2.0.8.2】【用户密码修改工具】 运行get-machine-code-tool.jar获取机器码, 报错: 没有main方法 | 工具类 | 验证对象是独立工具/脚本，需单独搭建 |
| V2-666 | bug | V2.0.8.2 | 发版 | 【2.0.8.2 】dn_data_dirs配置为多个路径，被误判为多级存储，导致create包含object类型的表失败：701: The tiered storage does not support object type yet. | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-671 | bug | V2.0.11.1 | 发版 | 【2.0.8.2】Frame size (69670459) larger than protect max size (67108864) 导致查询卡死，预期应返回正确的报错信息（region迁移自动化环境） | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-674 | bug | V2.0.12.1 | 开发 | 【2.0.8.2】root.__audit 的DataRegion Removing 卡死，预期：remove 成功。 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-695 | bug | V2.0.8.2 | 发版 | 【2.0.8.2】【合并】并发insert/select 与 修改数据类型，副本数据不一致，预期应一致（复现概率约50%；加日志版本DN ERROR：java.lang.RuntimeException: data type not matched） | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-699 | bug | V2.0.9.1 | 发版 | 【2.0.8.2】[AUDIT] 缩容DataNode成功后stop datanode 触发了audit空指针： Failed to log audit events ，because "this.asyncBatchUtils" is null | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-707 | bug | V2.0.8.2 | 发版 | 【2.0.8.2】元数据3副本，delete timeseries 成功，但是Follower 节点上此序列没有被删除（Leader节点删除成功），重启集群，依然可以查询到此序列，预期应查询不到 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-712 | bug | V2.0.13.1 | 测试 | 【2.0.8.2 IoTV2】3C5D2副本节点,没有故障操作，并发insert/delete 数据，表模型和树模型均有副本间数据不一致的现象，必现（IoTV2和IoT各测试3次，IoT没有这个问题） | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-718 | bug | V2.0.9.1 | 发版 | 【2.0.9.1 RC1 新引入问题】数据升级 CN NPE ，copy 1.3.7.1 release版本3C5D2副本的数据备份到2.0.9.1RC1 启动成功，使用benchmark写入一些新数据（原树/新表），CN 有数组越界及空指针（2.0.8.2 RC6 没这个问题） | 需升级场景 | 需要旧版本数据/升级路径，当前 3C5D 单版本环境不具备 |
| V2-719 | bug | V2.0.9.1 | 发版 | 【2.0.9.1 RC1 新引入问题】IoTV2 协议，DN 有几千条WARN ：WARN  o.a.i.d.p.s.d.r.a.DisruptorQueue:116 - The assigner queue content has exceeded half, it may be stuck and may block insertion. regionId: 5, capacity: 127, bufferSize: 128（2.0.8.2 RC7 没这个问题） | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-743 | bug | V2.0.9.1 | 发版 | 【2.0.9.1 RC1】开审计日志，数据升级后后，并发写入新数据，DN 有空指针：Cannot invoke "org.apache.iotdb.db.protocol.session.IClientSession.addStatementId(long)" because "<parameter1>" is null | 已自动化(日志门禁) | 日志门禁 CHK-743 |
| V2-752 | bug | V2.0.9.1 | 发版 | [2.0.9.1 ] IoTV2 版本升级后 因PIPE-CONSENSUS-ASYNC-CONNECTOR插件未注册，所有副本间同步失败 | 需升级场景 | 需要旧版本数据/升级路径，当前 3C5D 单版本环境不具备 |
| V2-754 | bug | V2.0.9.1 | 发版 | 【2.0.9.1】 TOE访问历史【数据库CLI登录】 使用不存在的用户登录时 【DN抛出空指针异常：Cannot read the array length because "this.measurements" is null】 | 已自动化 | QA-LZ-001：不存在用户 CLI 登录，DN 不得出现 measurements null NPE |
| V2-757 | bug | V2.0.9.1 | 发版 | 【2.0.9.1】[explain analyze 功能优化] 非对齐序列查询计划中IdentitySinkNode缺失DownStreamPlanNodeId | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-759 | bug | V2.0.9.1 | 发版 | 【2.0.9.1】查询模块，并发读写场景，查询报空指针：Cannot invoke "org.apache.tsfile.file.storageengine.data.read.QueryDataSource.hasNextSeqResource(int, boolean, org.apache.tsfile.file.metadata.IDeviceID)" | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-762 | bug | V2.0.9.1 | 发版 | 【2.0.9.1】IoTV2 协议，系统升级后，旧的consensus pipe 未自动拉起 导致15分钟内数据无法实时同步 | 需升级场景 | 需要旧版本数据/升级路径，当前 3C5D 单版本环境不具备 |
| V2-763 | bug | V2.0.9.1 | 发版 | 【2.0.9.1】TOE访问历史，在 DataNode 并发读写过程中出现 `NullPointerException`，导致用户登录时获取访问历史失败。 | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-771 | bug | V2.0.11.1 | 发版 | 【2.0.9.1】分区表自动修复,停止DataNode后 ，CN Leader节点刷大量ERROR日志 ：TSStatus类转换异常 | 已自动化(日志门禁) | 日志门禁 CHK-771 |
| V2-773 | story | V2.0.9.1 | 发版 | 【2.0.9.1】【订阅模块】停止集群时 CN报StateMachineProcedure未设下一状态但返回HAS_MORE_STATE错误 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-774 | bug | V2.0.11.1 | 发版 | 【2.0.9.1】分区表自动修复功能，3C3D，stop ConfigNode Leader 进程不退出且持续刷大量日志 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-787 | bug | V2.0.11.1 | 取消 | [2.0.9.1] DataRegion为RatisConsensus，3C5D3副本，无故障并发读写过程中，DN 空指针 | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-788 | story | V2.0.12.1 | 测试 | [2.0.9.1] IoTV2 协议，集群启动后立即写入数据时 【同步出现长时间延迟】 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-791 | bug | V2.0.11.1 | 发版 | [2.0.9.1] [分区表自动修复] 滚动升级后，依然查询不到丢失的时间分区 | 需升级场景 | 需要旧版本数据/升级路径，当前 3C5D 单版本环境不具备 |
| V2-801 | story | V2.0.9.1 | 发版 | [2.0.9.1] 时间戳精度是ns ,写入几条数据，  DataNode CommonDateTimeUtils 【报Integer overflow警告】 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-803 | bug | V2.0.11.1 | 发版 | [2.0.9.1] 分区表自动修复，参数值测试，partition_table_recover_worker_num=0，DN 和 CN 刷大量ERROR | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-805 | bug | V2.0.11.1 | 发版 | [2.0.9.1] 【CLI工具/参数解析】在Windows CMD中执行start-cli.bat时 -pw参数置于中间位置 报参数格式错误 | 工具类 | 验证对象是独立工具/脚本，需单独搭建 |
| V2-807 | bug | V2.0.9.1 | 发版 | [2.0.9.1] 【用户认证/数据库连接】 10用户并发场景下输入错误密码 ，CN产生ERROR日志 | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-808 | bug | V2.0.9.2 | 发版 | [2.0.9.1] 存在建模相同的表模型数据的时候，表模型 Cli 中，带 root. 前缀的树模型风格的写入会写进树模型的 schema region 里面，重启后查询不到树模型的设备，报非法路径 ，DN 有空指针 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-841 | bug | V2.0.9.2 | 发版 | 【2.0.9.2】object存储模块，解析object 文件，`substring` 方法的起始索引错误 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-842 | bug | V2.0.9.2 | 发版 | 【2.0.9.2】【查询】系统执行过期查询信息清理任务时有WARN ：The memory cost to be released is larger than the memory cost of memory block | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-861 | story | V2.0.12.1 | 开发 | 【2.0.9.2】【查询】stop DataNode时查询会打印一些error日志 | 已自动化 | QA-LZ-002：查询负载中停 DN/集群，无 Clear DriverTask/deRegister FI/NPE（复用 RN-TDB-122） |
| V2-862 | story | V2.0.11.1 | 发版 | 【2.0.9.2】【ConfigNode】stop confignode 过程中有空指针 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-865 | bug | V2.0.11.1 | 发版 | 【2.0.9.2】并发读写与delete 数据，副本间数据同步卡死 | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-874 | story | V2.0.10.1 | 发版 | 【2.0.9.2】【副本间数据同步】5C20D 2节点crash 1小时后恢复，sync lag 未即时归 0 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-875 | bug | V2.0.10.1 | 发版 | 【2.0.9.2】【缩容】5C20D 缩容Unknown DN 失败（且没有回滚） | 环境不可复现 | 依赖 5C20D/磁盘故障/机房等特殊环境 |
| V2-876 | bug | V2.0.10.1 | 发版 | 【2.0.9.2】【ConfigNode】5C20D集群，2 CN 故障后恢复， ConfigNodeRPCProcessor 出现线程泄漏 | 环境不可复现 | 依赖 5C20D/磁盘故障/机房等特殊环境 |
| V2-881 | bug | V2.0.10.1 | 发版 | 【2.0.9.2】【object 导出】导出任务卡死（死锁） | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-883 | bug | V2.0.10.1 | 发版 | 【2.0.9.2】【表级存储空间统计】stop DN 时 TableDiskUsageIndex 12秒 刷1万多条WARN （服务停止顺序问题） | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-885 | bug | V2.0.10.1 | 发版 | 【master】【object 缩容/扩容】表模型有TTL , 缩容故障DN  再原样加回，监控面板 object 文件数量出现负数 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-887 | bug | V2.0.10.1 | 发版 | 【2.0.9.2】【WAL】5C20D 缩容故障DN ，此DN 再加回集群，WAL 文件有增长，且保持多个，故障前没这个现象 | 环境不可复现 | 依赖 5C20D/磁盘故障/机房等特殊环境 |
| V2-888 | bug | V2.0.10.1 | 发版 | 【2.0.9.2】【object导出】5C20D 导出object，每个DN 增长约700多个sshd-SshClient 线程 | 环境不可复现 | 依赖 5C20D/磁盘故障/机房等特殊环境 |
| V2-889 | bug | V2.0.10.1 | 发版 | 【master_20260511_5a0d372】【参数热加载】 region_migration_concurrency_limit 热加载报错 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-890 | bug | V2.0.10.1 | 发版 | 【master_20260511_5a0d372】【扩容】【LOAD BALANCE】【object】5C12D 扩容到20D 执行LOAD BALANCE ，region Adding 卡死 | 环境不可复现 | 依赖 5C20D/磁盘故障/机房等特殊环境 |
| V2-893 | bug | V2.0.10.1 | 发版 | 【master_20250515_e253d04】【object 导入】DN ERROR：org.apache.tsfile.exception.filter.StatisticsClassException: OBJECT statistics does not support: last | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-894 | story | V2.0.11.1 | 发版 | 【master_20250515_e253d04】【object 远程备份】备份完成后，1 DN 上有99个sshd-SshClient 线程，24个Pipe-Processor-Executor 线程不释放，可以设置一个不活跃时间 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-895 | bug | V2.0.12.1 | 待对齐 | 【master_20260515_e253d04】【confignode】私有云环境5C20D，5个CN 磁盘故障，CN LEADER 没更新状态 | 环境不可复现 | 依赖 5C20D/磁盘故障/机房等特殊环境 |
| V2-897 | story | V2.0.13.1 | 开发 | 【master_20260515_e253d04】【LOAD BALANCE】新的 region 放置算法会导致 DB 视角的副本不均衡 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-899 | bug | V2.0.10.1 | 发版 | 【master_20260515_e253d04】【导入object 内存管理】导入object备份，DN WARN 出现内存释放警告 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-904 | bug | V2.0.10.1 | 发版 | 【master_0520_29562f8】【DataNode 空指针】气象局50D客户端配置，连5C20D 私有云环境， DN StateMachine 获取 data region 时的 NPE | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-905 | bug | V2.0.10.1 | 发版 | 【master_0520_29562f8】【ConfigNode 空指针】气象局50D客户端配置，连5C20D 私有云环境，ConfigNode 空指针 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-906 | bug | V2.0.10.1 | 发版 | 【master_0520_29562f8】【查询】查询超时，处理异常时出现 NPE，没有把超时异常传递给客户端 | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-907 | bug | V2.0.10.1 | 发版 | 【master_0520_29562f8】【审计日志】5C20DIoT 3副本，kill -9 2 DN ，记录审计日志有失败 | 已自动化(日志门禁) | 日志门禁 CHK-907 |
| V2-910 | bug | V2.0.10.1 | 发版 | 【master_0521_36fb17b】【DataNode  ClientRPC】5C20D 并发读写，DN IoTDB-ClientRPC-Processor openSession 空指针 | 已自动化(日志门禁) | 日志门禁 CHK-910 |
| V2-913 | story | V2.0.11.1 | 发版 | 【master_0525_5caf05a】【查询】查询超时有空指针 RelatedMemoryReserved can't be null when freeing memory | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-916 | bug | V2.0.10.1 | 发版 | 【master_0525_5caf05a】【time列名字不是time】表模型DELETE ... WHERE <time_column> BETWEEN ... 报错：The column 'd_datetime' does not exist or is not a tag column | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-918 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【tsfile-backup/TSFILE_REMOTE_SINK】 5C20D集群，导出到单目标机时未限制 SCP/SSH 会话并发，导致目标机 sshd Established 过多，后续 SSH 连接失败 | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-940 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【ratis】【缩容】3C5D集群，缩容正常DN过程中，kill 1 Adding DN PID ，SchemaRegion Adding 卡死 | 已自动化(日志门禁) | 日志门禁 CHK-940 |
| V2-941 | story | V2.0.10.1 | 发版 | 【2.0.10.1】【audit】升级1.3.7.1的数据到2.0.10.1（enable_audit_log=true），DN 有10多条audit 空指针 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-942 | story | V2.0.10.1 | 发版 | 【2.0.10.1】【load balance to datanode 】load balance to datanode 没有语义检查，1C1D load balance to datanode 999 ( 不存在的DN ID），返回结果为成功 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-964 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【LOAD BALANCE】表模型有object数据，写入停止后，执行2次表模型的LOAD BALANCE，DataRegion数均衡，但data size 极其不均衡 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-965 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【load balance】数据无新增写入，负载均衡任务已执行完成，再次重复执行负载均衡，系统仍会触发数据均衡动作（树/表都存在这个问题） | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-967 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【ConfigNode】5C20D 集群，loadBalance 触发了ConfigNode空指针 | 已自动化(日志门禁) | 日志门禁 CHK-967 |
| V2-969 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【ConfigNode】启动5C20D集群，AddConfigNode 在 ADD_CONSENSUS_GROUP 超时重试后触发重复建组，导致回滚失败，ConfigNode 进程存活但未入集群 | 已自动化(日志门禁) | 日志门禁 CHK-969 |
| V2-973 | 6916ce7189a8f973bfebf24b | V2.0.10.1 | 发版 | 【2.0.10.1】【pipe - 远程导出object】执行备份，数据存放至远端目标机器期间，目标机器磁盘故障导致CN狂刷日志，单条日志182K | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
| V2-974 | story | V2.0.10.1 | 发版 | 【2.0.10.1】【load snapshot】集群中存在空DataRegion，缩容过程中（Adding）DN 需要修复load snapshot 空指针 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-976 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【ConfigNode】MIGRATE REGION 在 CN leader 切换期间被提前标记成功，show migrations 已空但目标 peer 尚未 active（此时查询，结果不对） | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-978 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【show migrations】extend/remove region期间show migrations 看不到region迁移的进度，返回Empty set | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-979 | story | V2.0.12.1 | 开发 | 【2.0.10.1】【region迁移优化】只有1 DR迁移时（object文件较多），只有1个线程在执行SNAPSHOT TRANSMISSION，严重影响迁移进度，需要优化 | 非缺陷 | 需求/史诗，不做缺陷回归 |
| V2-987 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【region 迁移】目标 peer snapshot load 失败后仍被标记 active，CN 继续将 AddRegion/MigrateRegion 判成功，最终 检查数据时 root.test 数据缺失 | 待人工确认 | 标题不足以判定场景，需要读描述后决定 |
| V2-990 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【缩容】并发读写过程中 kill -9 DN 且 remove datanode 后，系统仍为 root.__system 新建 region 并错误分配副本到待缩容 DN，导致缩容卡住 | 需并发负载 | 需要 benchmark/并发写入场景，已具备框架但需逐条设计断言 |
| V2-999 | bug | V2.0.10.1 | 发版 | 【2.0.10.1】【表模型可写视图】schema_cascade=true 下 ADD COLUMN 后视图查询新增列报错：humidity cannot be resolved | 可自动化(待设计) | 日志断言可自动化，但需复现该条目的具体操作序列 |
