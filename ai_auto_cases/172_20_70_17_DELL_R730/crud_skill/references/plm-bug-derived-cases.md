# 由 PLM 已有缺陷派生的 CRUD 回归用例候选

数据来源：PLM 产品 1 全量工作项（408 条），筛出类型=缺陷且标题命中 CRUD 关键字者共 **96** 条；按“是否 V2.0.12.1”优先排序。ID 规则：`crud_regr_tdb<seq>`。

| PLM 编号 | 迭代 | 优先级 | 功能模块 | 标题 | 建议回归用例 ID |
|---|---|---|---|---|---|
| TDB-7 | V2.0.12.1 | P1 |  | [2.0.11.1][修复分区表] repair SQL 应该只放开树模型入口但实际树表一块生效 [旧数据未清理导致一个分区表 cell 同时写入两个 Region，查询返回重复记录] | `crud_regr_tdb7` |
| TDB-8 | V2.0.12.1 | P1 |  | 【V2.0.10.1】【root.__audit DataRegion】root.__audit 在树模型批量写入场景下，会把完整路径列表写入 audit log 的对象/日志字段，导致单条审计记录异常膨胀 | `crud_regr_tdb8` |
| TDB-45 | V2.0.12.1 | P2 |  | 【TIMECHODB-0539】 [2.0.6.1]2.0.6.1 rc4 表模型 10个匹配table的pipe, 写入结束后同步5分钟，pipe stopped(rc3没有这个问题) | `crud_regr_tdb45` |
| TDB-47 | V2.0.12.1 | P3 |  | 【TIMECHODB-0531】 [2.0.6.1] 表模型，batch模式，1pipe table正则匹配，rc1可以同步完成，rc3不能在预计时间内完成 | `crud_regr_tdb47` |
| TDB-48 | V2.0.12.1 | P1 |  | [2.0.8.1][write-back-sink][tree]修改source用户密码后，不论是否重启，不影响数据同步 | `crud_regr_tdb48` |
| TDB-69 | V2.0.12.1 | P1 |  | 【企业版-MASTER】树模型中，show regions返回结果集列表中，新增的ObjectSize对应的值，不应该出现Unknown | `crud_regr_tdb69` |
| TDB-70 | V2.0.12.1 | P1 |  | 【V2.0.10.2】【ConfigNode】执行 remove confignode 删除当前 Leader【transfer leader 失败导致删除失败】 | `crud_regr_tdb70` |
| TDB-73 | V2.0.12.1 | P1 |  | 【TIMECHODB-0673】 [2.0.7.1][用户连接数限制]集群部署,重启后所有用户配置被初始化，未被保留 | `crud_regr_tdb73` |
| TDB-74 | V2.0.12.1 | P2 |  | 【V2.0.10.1】【ConfigNode/Procedure】MIGRATE REGION 中途 stop CN leader 触发 ConfigNode 重新选主时，Prometheus 抓取指标 【报 NullPointerException：ProcedureExecutor.getActiveWorkerThreadCount 的 workerThreads 为 null】 | `crud_regr_tdb74` |
| TDB-81 | V2.0.12.1 | P2 |  | 【TIMECHODB-0312】 [2.0.4.1 RC2 ] 3C3DIoT3副本，1用户set system to readonly /running 前后执行写入与查询单个表数据，DN 出现空指针 NullPointerException: Cannot invoke "org.apache.iotdb.commons.schema.table.TsTable.getTableNam | `crud_regr_tdb81` |
| TDB-90 | V2.0.12.1 | P1 |  | 合并打硬链接失败时没有转为复制 | `crud_regr_tdb90` |
| TDB-91 | V2.0.12.1 | P1 |  | 【2.0.10.1】当 Operator 执行内存不足时，show queries 返回 719，无法用于查询问题排查 | `crud_regr_tdb91` |
| TDB-99 | V2.0.12.1 | P1 |  | OSS 映射到本地服务器挂载卷，预期 IoTDB 可支持合并，需补充测试（如长时测试） | `crud_regr_tdb99` |
| TDB-105 | V2.0.12.1 | P2 |  | 【V2.0.9.1-RC6】【数据查询】pattern_match对应的SQL语句中，pattern对应的参数值非法时，返回301异常 | `crud_regr_tdb105` |
| TDB-106 | V2.0.12.1 | P2 |  | 【2.0.9.1-RC6】【数据查询】pattern_match参数值非DOUBLE数据类型时，返回的校验信息需优化 | `crud_regr_tdb106` |
| TDB-109 | V2.0.12.1 | P0 |  | Pipe 删除时有异步处理的流程（如：recover），需告知用户异步执行结果 | `crud_regr_tdb109` |
| TDB-110 | V2.0.12.1 | P0 |  | 优化Pipe 创建、开始、停止、删除 命令报错的内容要明确 | `crud_regr_tdb110` |
| TDB-112 | V2.0.12.1 | P0 |  | 修复了Pipe 执行创建、开始、停止、删除 命令卡顿 assigner 部分的优化 | `crud_regr_tdb112` |
| TDB-117 | V2.0.12.1 | P0 |  | 修复同一对齐设备先写少列多行的请求，再写个多列一行的请求生成的 wal，重启 datanode 时导致 memtable 空值膨胀严重，最终导致重启 datanode 卡住 | `crud_regr_tdb117` |
| TDB-119 | V2.0.12.1 | P1 |  | 表模型 root 用户的UDF操作会漏记审计日志 | `crud_regr_tdb119` |
| TDB-126 | V2.0.12.1 | P0 |  | 修复使用多级存储后，如果删除表，监控文件大小会显示负数的问题 | `crud_regr_tdb126` |
| TDB-130 | V2.0.12.1 | P0 |  | 修复 pipe 对 partial insert 的写入转换成 tablet 时，对于为 null 的测点报出 NPE 的问题 | `crud_regr_tdb130` |
| TDB-135 | V2.0.12.1 | P2 |  | 【TIMECHODB-0301】 [2.0.4.1][tree]带有50%乱序的场景，Sink内配置format=tsfile的数据同步，接收端文件数量大大增加 | `crud_regr_tdb135` |
| TDB-136 | V2.0.12.1 | P2 |  | 【TIMECHODB-0460】 [2.0.5.2][tree]双活，分别写入表和树，写入过程中，将树模型的pipe修改，修改后树模型数据不能同步完成 | `crud_regr_tdb136` |
| TDB-137 | V2.0.12.1 | P2 |  | 【TIMECHODB-0461】 [2.0.5.2][metric]当某region得写入停止了，Pipe Extractor TsFileEpoch State这个指标的值不会改变 | `crud_regr_tdb137` |
| TDB-139 | V2.0.12.1 | P1 |  | 【TIMECHODB-0465】 [2.0.5.2][table][tree][pipe]重启接收端(stop receiver 5 分钟)，发送端未 flush 时，接收端查询不到完整数据 | `crud_regr_tdb139` |
| TDB-140 | V2.0.12.1 | P1 |  | [2.0.8.1]树模型写入，inclusion=all, 2个benchmark写入,接收端元数据没有及时创建，监控有断点，confignode连接不上 | `crud_regr_tdb140` |
| TDB-146 | V2.0.12.1 | P1 |  | 【2.0.9.2】【树模型】【元数据同步】tsfile同步，含有特殊字符路径的设备数据同步失败,接收端报错：database null not exists | `crud_regr_tdb146` |
| TDB-147 | V2.0.12.1 | P1 |  | 【2.0.10.1】【数据同步】表模型1张表 3 device 10w 列，无间隔写入，同步性能下降，transferTime是2.0.9.1的2倍 | `crud_regr_tdb147` |
| TDB-152 | V2.0.12.1 | P1 |  | 【V2.0.11.1】【Pipe同步-realtime tablet传输】 tree模型下用pattern.exclusion创建pipe并高频写入时 【发送端Pipe内存池耗尽自死锁，RemainingEventCount冻结、IsDegraded=true、接收端零数据】 | `crud_regr_tdb152` |
| TDB-153 | V2.0.12.1 | P2 |  | 【V2.0.11.1】【Pipe写入后查询-树模型】 tree-stream 写入后查询 P99 latency 【由基线<1s 回归至 ~12s(tc1271)/~2.5s(tc1270)】 | `crud_regr_tdb153` |
| TDB-154 | V2.0.12.1 | P1 |  | 【V2.0.11.1】【Pipe write-back-sink-树模型】 rename databse 不生效 | `crud_regr_tdb154` |
| TDB-155 | V2.0.12.1 | P0 |  | 数据同步表模型+ DELETE 相关场景测试 | `crud_regr_tdb155` |
| TDB-157 | V2.0.12.1 | P1 |  | 【TIMECHODB-0762】 master 启动2 benchmark共100用户并发读写，CLI多用户并发更改用户名， CN 空指针 : Cannot invoke "org.apache.iotdb.commons.auth.entity.User.getMinSessionPerUser()" because "<local7>" is null (可复现） | `crud_regr_tdb157` |
| TDB-158 | V2.0.12.1 | P2 |  | 【TIMECHODB-1058】 【内存控制】rc/1.3.3.3 rc7 写入+单用户循环迁移+单用户delete 1设备少量数据 , 运行37个多小时，有1个DataNode OOM | `crud_regr_tdb158` |
| TDB-174 | V2.0.12.1 | P0 |  | 修复同步任务进度不更新问题 | `crud_regr_tdb174` |
| TDB-178 | V2.0.12.1 | P0 |  | 【V2.0.11.1】【支持用 SQL 将查询结果写回到指定路径的 tsfile 中】磁盘空间已满时，COPY 导出仍提示成功并生成 0 字节 TsFile 文件 | `crud_regr_tdb178` |
| TDB-216 | V2.0.12.1 | P0 |  | 【V2.0.11.1】【订阅消费】批量写入期间强杀一个consumer【其他consumer无message且停止消费】 | `crud_regr_tdb216` |
| TDB-217 | V2.0.12.1 | P0 |  | 【2.0.11.1】【数据订阅】3c3d stream写入数值+大batch string(3M)，节点会fencing unknown | `crud_regr_tdb217` |
| TDB-218 | V2.0.12.1 | P1 |  | 【V2.0.11.1-RC1】【逻辑视图】创建逻辑视图时，不能使用DBNAME.VIEWNAME，目前只能通过USE DBNAME才可以创建 | `crud_regr_tdb218` |
| TDB-229 | V2.0.12.1 | P0 |  | 两个类加载器加载的同一个类，即使全类名一样，JVM也会判定成两个类，插件 Jar 误放入DataNode lib/，引发ClassLoader冲突，导致object数据类型导出失败 | `crud_regr_tdb229` |
| TDB-241 | V2.0.12.1 | P2 |  | 【V2.0.11.1】【查询执行】DataNode 元数据租约 fencing 后处理 FragmentInstance 失败 【抛出 NullPointerException 而非对应业务异常】 | `crud_regr_tdb241` |
| TDB-242 | V2.0.12.1 | P1 |  | 【2.0.11.1】【数据订阅】stream模式写入数据，同样场景3c3d 订阅时间是 1c1d 的 3倍+ | `crud_regr_tdb242` |
| TDB-243 | V2.0.12.1 | P2 |  | 【2.0.11.1】【数据订阅】1000 张表、10 万 device、20 个写客户端高频写入，需要精简日志，当前1次commit 114条WARN | `crud_regr_tdb243` |
| TDB-246 | V2.0.12.1 | P0 |  | 【2.0.11.1】【数据订阅】大batch写入，数据订阅可能丢数据 | `crud_regr_tdb246` |
| TDB-295 | V2.0.12.1 | P00 |  | 【2.0.11.1】【数据订阅】参数开关subscription_enabled在参数模版中不存在，且默认开启（默认应该关闭）占用查询20%内存 | `crud_regr_tdb295` |
| TDB-301 | V2.0.12.1 | P1 |  | 未激活或ReadOnly的企业版，可以创建和删除数据库和表等元数据，且操作可以通过pipe进行同步，可能存在安全隐患 | `crud_regr_tdb301` |
| TDB-309 | V2.0.12.1 | P0 |  | 未激活状态的DN节点，重启不校验cpu核数信息 | `crud_regr_tdb309` |
| TDB-352 | V2.0.12.1 | P0 |  | 【2.0.12.1】高频写入小 Object 时，删除旧 Object 开销过大导致写入较慢 | `crud_regr_tdb352` |
| TDB-358 | V2.0.12.1 |  |  | 【V2.0.12.1】【MQTT】树模型 JSON 写入后客户端立即断开触发 DataNode NPE(session is null)且数据丢失 | `crud_regr_tdb358` |
| TDB-374 | V2.0.12.1 | P0 |  | 【V2.0.12.1-RC1】【TAG+ATTRIBUTE属性列过滤删除数据】执行FLUSH操作之后，查询的数据显示异常 | `crud_regr_tdb374` |
| TDB-376 | V2.0.12.1 |  |  | 【V2.0.12.1】【MQTT】树模型 JSON 写入后客户端立即断开触发 DataNode NPE(session is null)且数据丢失 | `crud_regr_tdb376` |
| TDB-378 | V2.0.12.1 | P1 |  | 【2.0.12.1】【数据订阅】pipe同步后接收端未落盘memtable数据对count查询不可见，校验查询少点（非丢数，27066/27067复现） | `crud_regr_tdb378` |
| TDB-381 | V2.0.12.1 | P0 |  | 【V2.0.12.1】【查询优化】SELECT 查询列过多报 719 时，文案中「本次请求内存」出现两个互相矛盾的数值，且「请加内存」未给出具体金额 | `crud_regr_tdb381` |
| TDB-402 | V2.0.12.1 |  |  | [V2.0.12.1]【remove cn】摘除 ConfigNode 后，表模型查询收到不可重试的 301（ConfigRegion 不存在） | `crud_regr_tdb402` |
| TDB-405 | V2.0.12.1 | P1 |  | 【2.0.12.1】【集群负载均衡】存在ReadOnly副本时执行树模型LOAD BALANCE 【ConfigManager.loadBalance空指针并返回305】 | `crud_regr_tdb405` |
| TDB-407 | V2.0.12.1 | P2 |  | 【V2.0.12.1】【WAL】空 WAL 文件被误判为损坏：WALMetaData 长度下界少算一个 Integer.BYTES，使 84% 的健康 WAL 文件报 Broken wal file …, size 6 | `crud_regr_tdb407` |
| TDB-410 | V2.0.12.1 | P1 |  | [2.0.12.1][Pipe][表模型] InsertTabletStatement 重定向时接收端持续打印 Unsupported statement type WARN | `crud_regr_tdb410` |
| TDB-414 | V2.0.12.1 | P0 |  | 【2.0.12.1】【数据订阅】实时快通道队列满后永久熔断，退化为 WAL 回放（~0.7k 行/s），高写入速率下积压永不追平（1k/1w/10w 三档实测） | `crud_regr_tdb414` |
| TDB-428 | V2.0.12.1 | P1 |  | 【V2.0.12.1-RC3】HighPass和LowPass函数WPASS传入NULL返回305内部服务器异常，错误信息不明确 | `crud_regr_tdb428` |
| TDB-430 | V2.0.12.1 | P1 |  | 【2.0.12.1】【数据同步】pipe 传输中节点重启后接收端 OBJECT 分段写入 offset 校验失败，对象内容永久缺失（LENGTH=null） | `crud_regr_tdb430` |
| TDB-433 | V2.0.12.1 |  |  | [三级存储] OBJECT_STORAGE 形态下对象层副本共享合并 SharedStorageCompaction 全部失败（NoSuchKeyException 404） | `crud_regr_tdb433` |
| TDB-435 | V2.0.12.1 |  |  | [查询] DeviceEntrySpillManager 清理竞态按 WARN 打印且无限流，单节点 4.4 天 112 万条（占全部 WARN 99.998%） | `crud_regr_tdb435` |
| TDB-437 | V2.0.12.1 | P2 |  | 【V2.0.12.1】【表模型】INSERT 的 time 列使用表达式报 305 内部错误 【AstBuilder.toInsertRowStatement 强转 StringLiteral 抛 ClassCastException】 | `crud_regr_tdb437` |
| TDB-438 | V2.0.12.1 | P0 |  | 【2.0.12.1】【数据订阅】WAL 回放读到大 entry（> wal_buffer_size_in_byte/3）后永久卡死，大 batch/大字段库数据静默不投递（writer_B 93% 未达） | `crud_regr_tdb438` |
| TDB-440 | V2.0.12.1 | P0 |  | 【2.0.12.1】【数据订阅】WAL 回放起点跳过不可用 searchIndex 区间，订阅数据静默永久丢失（RC4 同套件 4 例，28325 丢 57/3999 行） | `crud_regr_tdb440` |
| TDB-442 | V2.0.12.1 | P0 |  | 删除后的数据在合并后重新出现 | `crud_regr_tdb442` |
| TDB-444 | V2.0.12.1 | P1 |  | 【V2.0.12.1】【树模型】SHOW TTL ON root.tree.g_0.** 返回不相干的全局 TTL 规则（把权限范围路径当查询路径下发） | `crud_regr_tdb444` |
| TDB-448 | V2.0.12.1 | P2 |  | 【2.0.12.1】【计算-查询执行-OBJECT 二进制函数】查询写回含 OBJECT 列报 301「Unknown data type: OBJECT」，与需求要求的 701 不符 | `crud_regr_tdb448` |
| TDB-449 | V2.0.12.1 | P0 |  | 【2.0.12.1】【存储-CRUD操作-测点粒度删除】3 节点集群上表模型 DELETE 返回成功但不删除任何数据（静默失效） | `crud_regr_tdb449` |
| TDB-450 | V2.0.12.1 | P2 |  | 【2.0.12.1】【存储-CRUD操作-基础写入】DataNode kill -9 后经 ssh/ansible 用 start-datanode.sh -d 重启会静默退出（会话断开时被 SIGHUP 打死 rc=129；10730 不监听、无 hs_err） | `crud_regr_tdb450` |
| TDB-454 | V2.0.12.1 | P1 |  | 【V2.0.12.1】【表模型】Binary(OBJECT) 为 NULL 时调用 getLength() 触发 NPE，tablet 写入失败 | `crud_regr_tdb454` |
| TDB-66 | V2.0.13.1 | P0 |  | 【master_20260515_e253d04】【confignode】私有云环境5C20D，5个CN 磁盘故障，CN LEADER 没更新状态 | `crud_regr_tdb66` |
| TDB-116 | V2.0.14.1 | P1 |  | 【V2.0.11.1】【ConfigNode】并发 REMOVE REGION 跨时间分区写入时【分区申请超时导致全节点写入失败】 | `crud_regr_tdb116` |
| TDB-122 | V2.0.13.1 | P1 |  | 【2.0.9.2】【查询】stop DataNode时查询会打印一些error日志 | `crud_regr_tdb122` |
| TDB-148 | V2.0.13.1 | P2 |  | 【2.0.10.1】【数据同步】树模型100pipe pattern=ts 对齐序列，接收端数据少点 | `crud_regr_tdb148` |
| TDB-151 | V2.0.13.1 | P2 |  | 【master】【数据同步】带pattern多pipe, remaining event 归零，且接收端写入归零后，不能代表同步完成 | `crud_regr_tdb151` |
| TDB-184 | V1.3.8.1 | P0 |  | 树模型的多设备超时的查询才会小概率触发，每次触发 reservedSize 就会增加一点，直到max capacity 就会导致后续查询报错 | `crud_regr_tdb184` |
| TDB-186 | V1.3.8.1 | P0 |  | Pipe 同步支持顺序发送，保证接收端同一时间戳的覆盖顺序 | `crud_regr_tdb186` |
| TDB-188 | V1.3.8.1 | P0 |  | 修复 TsFile 拆分 tablet 时，等待内存超时导致问题上报，停止 Pipe 的问题 | `crud_regr_tdb188` |
