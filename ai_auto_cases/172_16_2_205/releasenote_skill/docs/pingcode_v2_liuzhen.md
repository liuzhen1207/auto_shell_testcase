# PingCode V2 项目 · 刘珍创建的缺陷 → 回归用例映射

数据来源：PingCode 项目 `V2`（TimechoDB-V2.x），按 **创建人=刘珍** 过滤，共 93 条（2026-11-04 导出）。

已覆盖（2.0.13.1 实测通过）：**4 条**；其余按可自动化程度分类。

| 编号 | 状态 | 标题（截断） | 分类 | 说明 |
| --- | --- | --- | --- | --- |
| V2-345 | 发版 | 【查询OOM】查询SQL语法错误 (offset X limitY），DN OOM （田原：Fix OOM in SQL Parser Er | 已覆盖 | 用例 RN-129 |
| V2-374 | 发版 | 树模型修改数据类型：数据类型是小写，修改失败：java.lang.IllegalArgumentException: No enum con | 已覆盖 | 用例 RN-126 |
| V2-378 | 发版 | 查询： cast(1.1 as float)  报错Msg: java.lang.UnsupportedOperationException | 已覆盖 | 用例 RN-127 |
| V2-942 | 发版 | 【2.0.10.1】【load balance to datanode 】load balance to datanode 没有语义检查，1 | 已覆盖 | 用例 RN-128 |
| V2-375 | 发版 | 树模型 每修改一次序列类型，CN 对应产生一条ERROR：ERROR o.a.i.c.p.i.StateMachineProcedure:1 | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-377 | 发版 | 修改数据类型 ，CN Follower  节点：java.nio.BufferUnderflowException: null 和 Null | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-380 | 发版 | 日志优化：SELECT_INTO 过程中，drop 写回表 ，DN ERROR 日志可改为INFO 或WARN ：SemanticExcep | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-396 | 发版 | 表视图（定义基于树模型非对齐设备）last查询可优化，当前实现是：没下推，且为正序scan，会扫描所有的数据。田原：对于非对齐设备，虽然聚合 | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-397 | 发版 | 查询失败，sort算子：java.lang.ArithmeticException: / by zero | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-430 | 发版 | 修改数据类型，last查询失败：StatisticsClassException: BLOB statistics does not sup | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-757 | 发版 | 【2.0.9.1】[explain analyze 功能优化] 非对齐序列查询计划中IdentitySinkNode缺失DownStream | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-771 | 发版 | 【2.0.9.1】分区表自动修复,停止DataNode后 ，CN Leader节点刷大量ERROR日志 ：TSStatus类转换异常 | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-774 | 发版 | 【2.0.9.1】分区表自动修复功能，3C3D，stop ConfigNode Leader 进程不退出且持续刷大量日志 | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-801 | 发版 | [2.0.9.1] 时间戳精度是ns ,写入几条数据，  DataNode CommonDateTimeUtils 【报Integer ov | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-803 | 发版 | [2.0.9.1] 分区表自动修复，参数值测试，partition_table_recover_worker_num=0，DN 和 CN 刷 | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-842 | 发版 | 【2.0.9.2】【查询】系统执行过期查询信息清理任务时有WARN ：The memory cost to be released is l | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-861 | 开发 | 【2.0.9.2】【查询】stop DataNode时查询会打印一些error日志 | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-862 | 发版 | 【2.0.9.2】【ConfigNode】stop confignode 过程中有空指针 | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-883 | 发版 | 【2.0.9.2】【表级存储空间统计】stop DN 时 TableDiskUsageIndex 12秒 刷1万多条WARN （服务停止顺序 | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-916 | 发版 | 【master_0525_5caf05a】【time列名字不是time】表模型DELETE ... WHERE <time_column>  | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-976 | 发版 | 【2.0.10.1】【ConfigNode】MIGRATE REGION 在 CN leader 切换期间被提前标记成功，show migr | 可扩展候选 | SQL/CLI 可验证，待评估 |
| V2-1042 | 发版 | 【2.0.10.1】【CompressionRatio】show regions CompressionRatio 显示为0，计算公式中分子 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-1043 | 发版 | 【2.0.10.1】【表模型 show regions中的TsFileSize】TsFileSize 不能把 object size 加进去 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-185 | 发版 | 【OBJECT】[ 2.0.8.1 RC1 ] 没有object数据，运行print-tsfile-resource工具，报磁盘满（实际未满 | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-186 | 发版 | 【object】2.0.8.1 RC1 写入(跨时间分区的)object数据，没用to_object ()写，DN ：BufferUnder | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-343 | 发版 | 2.0.8.1 RC1 ：1用户循环insert/delete 数据场景，DN ERROR：tsfile marking or ending | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-363 | 发版 | [ 合并 ] 并发select/insert/delete数据，合并处理mods文件产生ERROR 日志（NoSuchFileExcepti | 暂不纳入 | 并发/长时稳定性场景，不适合快回归 |
| V2-364 | 发版 | 并发select/insert/delete 数据，查询报错"select time from t1_0 where device_id=' | 暂不纳入 | 并发/长时稳定性场景，不适合快回归 |
| V2-376 | 发版 | dn_data_dirs存储在多块盘，正常状态并发读写+缩容DN ，测试完成，重启DN ：合并报错 sequence files has o | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-383 | 发版 | 查询：1 SQL （无并发）SELECT_INTO 卡死，可复现（田原已定位到2个问题点：最大内存初始化有问题 & 超时检测线程死循环） | 暂不纳入 | 并发/长时稳定性场景，不适合快回归 |
| V2-392 | 发版 | 修改数据类型 有写入失败，DN 空指针 &  ERROR o.a.i.d.s.d.DataRegion:1470 - Data incons | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-400 | 发版 | 并发读写场景，查询有失败：ArrayIndexOutOfBoundsException: Index 5282 out of bounds  | 暂不纳入 | 并发/长时稳定性场景，不适合快回归 |
| V2-412 | 发版 | 并发读写+修改数据类型，读tsfile出错（合并/ 查询失败）：org.apache.tsfile.exception. filter.St | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-427 | 发版 | 【合并】并发查询写入，并发delete数据，并发修改数据类型，合并报错：ArrayIndexOutOfBoundsException: In | 暂不纳入 | 并发/长时稳定性场景，不适合快回归 |
| V2-610 | 发版 | 【2.0.8.2】【用户密码修改工具】 运行get-machine-code-tool.jar获取机器码, 报错: 没有main方法 | 暂不纳入 | 客户端/工具/UI 侧，非 SQL 可验证 |
| V2-666 | 发版 | 【2.0.8.2 】dn_data_dirs配置为多个路径，被误判为多级存储，导致create包含object类型的表失败：701: The | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-671 | 发版 | 【2.0.8.2】Frame size (69670459) larger than protect max size (67108864) | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-674 | 开发 | 【2.0.8.2】root.__audit 的DataRegion Removing 卡死，预期：remove 成功。 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-695 | 发版 | 【2.0.8.2】【合并】并发insert/select 与 修改数据类型，副本数据不一致，预期应一致（复现概率约50%；加日志版本DN E | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-699 | 发版 | 【2.0.8.2】[AUDIT] 缩容DataNode成功后stop datanode 触发了audit空指针： Failed to log | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-707 | 发版 | 【2.0.8.2】元数据3副本，delete timeseries 成功，但是Follower 节点上此序列没有被删除（Leader节点删除 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-712 | 测试 | 【2.0.8.2 IoTV2】3C5D2副本节点,没有故障操作，并发insert/delete 数据，表模型和树模型均有副本间数据不一致的现 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-718 | 发版 | 【2.0.9.1 RC1 新引入问题】数据升级 CN NPE ，copy 1.3.7.1 release版本3C5D2副本的数据备份到2.0 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-719 | 发版 | 【2.0.9.1 RC1 新引入问题】IoTV2 协议，DN 有几千条WARN ：WARN  o.a.i.d.p.s.d.r.a.Disru | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-743 | 发版 | 【2.0.9.1 RC1】开审计日志，数据升级后后，并发写入新数据，DN 有空指针：Cannot invoke "org.apache.io | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-752 | 发版 | [2.0.9.1 ] IoTV2 版本升级后 因PIPE-CONSENSUS-ASYNC-CONNECTOR插件未注册，所有副本间同步失败 | 暂不纳入 | 需双集群/双活环境 |
| V2-754 | 发版 | 【2.0.9.1】 TOE访问历史【数据库CLI登录】 使用不存在的用户登录时 【DN抛出空指针异常：Cannot read the arr | 暂不纳入 | 客户端/工具/UI 侧，非 SQL 可验证 |
| V2-759 | 发版 | 【2.0.9.1】查询模块，并发读写场景，查询报空指针：Cannot invoke "org.apache.tsfile.file.stor | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-762 | 发版 | 【2.0.9.1】IoTV2 协议，系统升级后，旧的consensus pipe 未自动拉起 导致15分钟内数据无法实时同步 | 暂不纳入 | 需双集群/双活环境 |
| V2-763 | 发版 | 【2.0.9.1】TOE访问历史，在 DataNode 并发读写过程中出现 `NullPointerException`，导致用户登录时获取 | 暂不纳入 | 并发/长时稳定性场景，不适合快回归 |
| V2-773 | 发版 | 【2.0.9.1】【订阅模块】停止集群时 CN报StateMachineProcedure未设下一状态但返回HAS_MORE_STATE错误 | 暂不纳入 | 需双集群/双活环境 |
| V2-787 | 取消 | [2.0.9.1] DataRegion为RatisConsensus，3C5D3副本，无故障并发读写过程中，DN 空指针 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-788 | 测试 | [2.0.9.1] IoTV2 协议，集群启动后立即写入数据时 【同步出现长时间延迟】 | 暂不纳入 | 需双集群/双活环境 |
| V2-791 | 发版 | [2.0.9.1] [分区表自动修复] 滚动升级后，依然查询不到丢失的时间分区 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-805 | 发版 | [2.0.9.1] 【CLI工具/参数解析】在Windows CMD中执行start-cli.bat时 -pw参数置于中间位置 报参数格式错 | 暂不纳入 | 客户端/工具/UI 侧，非 SQL 可验证 |
| V2-807 | 发版 | [2.0.9.1] 【用户认证/数据库连接】 10用户并发场景下输入错误密码 ，CN产生ERROR日志 | 暂不纳入 | 并发/长时稳定性场景，不适合快回归 |
| V2-808 | 发版 | [2.0.9.1] 存在建模相同的表模型数据的时候，表模型 Cli 中，带 root. 前缀的树模型风格的写入会写进树模型的 schema  | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-841 | 发版 | 【2.0.9.2】object存储模块，解析object 文件，`substring` 方法的起始索引错误 | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-865 | 发版 | 【2.0.9.2】并发读写与delete 数据，副本间数据同步卡死 | 暂不纳入 | 需双集群/双活环境 |
| V2-874 | 发版 | 【2.0.9.2】【副本间数据同步】5C20D 2节点crash 1小时后恢复，sync lag 未即时归 0 | 暂不纳入 | 需双集群/双活环境 |
| V2-875 | 发版 | 【2.0.9.2】【缩容】5C20D 缩容Unknown DN 失败（且没有回滚） | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-876 | 发版 | 【2.0.9.2】【ConfigNode】5C20D集群，2 CN 故障后恢复， ConfigNodeRPCProcessor 出现线程泄漏 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-881 | 发版 | 【2.0.9.2】【object 导出】导出任务卡死（死锁） | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-885 | 发版 | 【master】【object 缩容/扩容】表模型有TTL , 缩容故障DN  再原样加回，监控面板 object 文件数量出现负数 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-887 | 发版 | 【2.0.9.2】【WAL】5C20D 缩容故障DN ，此DN 再加回集群，WAL 文件有增长，且保持多个，故障前没这个现象 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-888 | 发版 | 【2.0.9.2】【object导出】5C20D 导出object，每个DN 增长约700多个sshd-SshClient 线程 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-889 | 发版 | 【master_20260511_5a0d372】【参数热加载】 region_migration_concurrency_limit 热加 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-890 | 发版 | 【master_20260511_5a0d372】【扩容】【LOAD BALANCE】【object】5C12D 扩容到20D 执行LOAD | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-893 | 发版 | 【master_20250515_e253d04】【object 导入】DN ERROR：org.apache.tsfile.excepti | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-894 | 发版 | 【master_20250515_e253d04】【object 远程备份】备份完成后，1 DN 上有99个sshd-SshClient 线 | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-895 | 待对齐 | 【master_20260515_e253d04】【confignode】私有云环境5C20D，5个CN 磁盘故障，CN LEADER 没更 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-897 | 开发 | 【master_20260515_e253d04】【LOAD BALANCE】新的 region 放置算法会导致 DB 视角的副本不均衡 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-899 | 发版 | 【master_20260515_e253d04】【导入object 内存管理】导入object备份，DN WARN 出现内存释放警告 | 暂不纳入 | 需特殊配置/object 存储/导出环境 |
| V2-904 | 发版 | 【master_0520_29562f8】【DataNode 空指针】气象局50D客户端配置，连5C20D 私有云环境， DN StateM | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-905 | 发版 | 【master_0520_29562f8】【ConfigNode 空指针】气象局50D客户端配置，连5C20D 私有云环境，ConfigNo | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-906 | 发版 | 【master_0520_29562f8】【查询】查询超时，处理异常时出现 NPE，没有把超时异常传递给客户端 | 暂不纳入 | 并发/长时稳定性场景，不适合快回归 |
| V2-907 | 发版 | 【master_0520_29562f8】【审计日志】5C20DIoT 3副本，kill -9 2 DN ，记录审计日志有失败 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-910 | 发版 | 【master_0521_36fb17b】【DataNode  ClientRPC】5C20D 并发读写，DN IoTDB-ClientRP | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-913 | 发版 | 【master_0525_5caf05a】【查询】查询超时有空指针 RelatedMemoryReserved can't be null  | 暂不纳入 | 并发/长时稳定性场景，不适合快回归 |
| V2-918 | 发版 | 【2.0.10.1】【tsfile-backup/TSFILE_REMOTE_SINK】 5C20D集群，导出到单目标机时未限制 SCP/S | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-940 | 发版 | 【2.0.10.1】【ratis】【缩容】3C5D集群，缩容正常DN过程中，kill 1 Adding DN PID ，SchemaRegi | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-941 | 发版 | 【2.0.10.1】【audit】升级1.3.7.1的数据到2.0.10.1（enable_audit_log=true），DN 有10多条 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-964 | 发版 | 【2.0.10.1】【LOAD BALANCE】表模型有object数据，写入停止后，执行2次表模型的LOAD BALANCE，DataRe | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-965 | 发版 | 【2.0.10.1】【load balance】数据无新增写入，负载均衡任务已执行完成，再次重复执行负载均衡，系统仍会触发数据均衡动作（树/ | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-967 | 发版 | 【2.0.10.1】【ConfigNode】5C20D 集群，loadBalance 触发了ConfigNode空指针 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-969 | 发版 | 【2.0.10.1】【ConfigNode】启动5C20D集群，AddConfigNode 在 ADD_CONSENSUS_GROUP 超时 | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-973 | 发版 | 【2.0.10.1】【pipe - 远程导出object】执行备份，数据存放至远端目标机器期间，目标机器磁盘故障导致CN狂刷日志，单条日志1 | 暂不纳入 | 需双集群/双活环境 |
| V2-974 | 发版 | 【2.0.10.1】【load snapshot】集群中存在空DataRegion，缩容过程中（Adding）DN 需要修复load sna | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-978 | 发版 | 【2.0.10.1】【show migrations】extend/remove region期间show migrations 看不到re | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-979 | 开发 | 【2.0.10.1】【region迁移优化】只有1 DR迁移时（object文件较多），只有1个线程在执行SNAPSHOT TRANSMIS | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-987 | 发版 | 【2.0.10.1】【region 迁移】目标 peer snapshot load 失败后仍被标记 active，CN 继续将 AddRe | 暂不纳入 | 需多轮集群重建/长时压测 |
| V2-990 | 发版 | 【2.0.10.1】【缩容】并发读写过程中 kill -9 DN 且 remove datanode 后，系统仍为 root.__syste | 暂不纳入 | 需多轮集群重建/长时压测 |

## 汇总

- 已覆盖: 4
- 可扩展候选: 17
- 暂不纳入: 71
