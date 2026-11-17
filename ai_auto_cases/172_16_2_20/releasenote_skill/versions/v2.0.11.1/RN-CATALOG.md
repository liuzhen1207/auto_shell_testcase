# V2.0.11.1 RN 全量目录与可行性（147 条）

> 数据来源：PLM `rn list --product-id 1`，迭代 `V2.0.11.1`，共 **147** 条。
> 目标版本：2.0.13.1 RC2（build 83183d0），3C5D。
> 可行性判定：可在 3C5D 上用 SQL/CLI 黑盒验证 = 可；需要额外拓扑/中间件/商业包/特殊环境 = 不能（附原因）。
> 生成时间：2026-11-17。

## 一、总览

| 项 | 数量 |
| --- | ---: |
| RN 总数 | 147 |
| 可加入本环境验证 | **117** |
| 当前环境不满足 | **30** |

## 二、按主题分布

| 主题 | RN 数 | 可测 | 不可测 | 对应用例 |
| --- | ---: | ---: | ---: | --- |
| 集群/节点 | 22 | 17 | 5 | `RN-2.0.11.1-CLUSTER` |
| 其它 | 20 | 8 | 12 | `RN-2.0.11.1-CLUSTER` |
| 审计日志 | 18 | 18 | 0 | `RN-2.0.11.1-AUDIT` |
| CLI/客户端 | 13 | 12 | 1 | `RN-2.0.11.1-CLI` |
| 安全/权限 | 13 | 5 | 8 | `RN-2.0.11.1-SEC` |
| 表模型 DDL/Procedure | 10 | 10 | 0 | `RN-2.0.11.1-DDL` |
| Region 迁移/取消 | 9 | 9 | 0 | `RN-2.0.11.1-MIGRATE` |
| 查询引擎 | 9 | 9 | 0 | `RN-2.0.11.1-QUERY` |
| 配置热加载 | 8 | 8 | 0 | `RN-2.0.11.1-CFG` |
| 数据订阅 | 7 | 6 | 1 | `RN-2.0.11.1-SUB` |
| 激活/打包 | 6 | 4 | 2 | `RN-2.0.11.1-CLUSTER` |
| 存储/TsFile | 6 | 5 | 1 | `RN-2.0.11.1-STORAGE` |
| COPY TO TsFile | 5 | 5 | 0 | `RN-2.0.11.1-COPY` |
| Pipe/同步 | 1 | 1 | 0 | `RN-2.0.11.1-CLUSTER` |

## 三、不能加入当前环境的 RN（30 条）

| 编号 | 原因 | 标题 |
| --- | --- | --- |
| TDB-690 | 需要 Pro/Max 商业包 | 【V2.0.11.1】【Max包】password_expiration_seconds 配置未按秒生效，口令过期时间仍按 password_expiratio |
| TDB-697 | 需要指定旧版本升级路径 | 【V2.0.11.1】【升级兼容/Schema Snapshot】旧版本混合模型数据升级启动 DataNode【恢复表设备统计时空指针导致启动失败】 |
| TDB-705 | 需要构造大数据量/长时间运行 | 【2.0.11.1】【数据订阅】mode=consensus无内存控制，3分钟队列积压导致OOM |
| TDB-706 | 需要 Pro/Max 商业包 | 【V2.0.11.1】【更新打包命令】Pro 包 ConfigNode/DataNode 启动横幅均显示 TimechoDB 品牌 |
| TDB-722 | 需要特定硬件/激活环境 | 【V2.0.10.1】【激活模块】 跨机器部署V02忽略硬件激活码后启动 【校验失败，L4标志双层不生效】 |
| TDB-723 | 安全漏洞（需专项环境） | CVE-2026-59562 旧版pipe sendFile RPC 中存在未认证路径遍历 |
| TDB-724 | 安全漏洞（需专项环境） | CVE-2026-41114 修复JDBC 驱动 BigDecimal toPlainString 接口存在大规模内存耗尽的问题 |
| TDB-725 | 安全漏洞（需专项环境） | CVE-2026-59229  修复 Apache IoTDB Legacy Pipe 权限提升问题 |
| TDB-726 | 安全漏洞（需专项环境） | CVE-2026-58663 Apache IoTDB pipeTransfer ()  接口未鉴权 |
| TDB-736 | 需要高负载 + 监控压测环境 | 修复高负载下情况下 ，使用 iotdb 监控配置参数 dn_metric_level=IMPORTANT ，CPU的使用率非常高的问题 |
| TDB-741 | 需要指定旧版本升级路径 | JDK 升级为 17 并且更新第三方依赖 |
| TDB-746 | 日常维护类，无可验证功能点 | 存储组 2.0.11 日常维护 |
| TDB-749 | 需要 AI/AINode 环境 | 【AINode】非 root 用户启动 AINode 识别不到显卡 |
| TDB-757 | 需要协议层构造非法 thrift 请求 | 增加协议层的内存控制 |
| TDB-758 | 需要协议层构造非法 thrift 请求 | thrift 协议请求的识别加强 |
| TDB-759 | 内部接口未对外暴露，无 SQL 入口 | CN 提供直接删除指定数据库的接口，但不对外暴露 |
| TDB-767 | 需要双版本滚动升级编排 | [2.0.9.1] [分区表自动修复] 滚动升级后，依然查询不到丢失的时间分区 |
| TDB-773 | 需要用开源版安装包验证 | 【只测开源】开源版代码移除密码历史功能 |
| TDB-788 | 需要 3C3D 拓扑（当前 3C5D） | 【TIMECHODB-0049】 [rc/2.0.1.2rc2][IoTConsensus] 3C3D2副本读写+delete 数据+stop 某DN , 有一 |
| TDB-789 | 需要协议层抓包对比压缩前后报文 | RPC 压缩 |
| TDB-792 | EAL4 认证项，需要认证测试环境与用例集 | 【EAL4】USB.1 用户-主体绑定 |
| TDB-793 | EAL4 认证项，需要认证测试环境与用例集 | 【EAL4】【UID.1 标识的时机】针对未登录的用户的操作进行日志记录 |
| TDB-798 | 需要多目录磁盘布局与快照传输 | IoTConsensus 接收快照时支持多目录 |
| TDB-800 | 需要构造大数据量/长时间运行 | 【TIMECHODB-0570】 PipeTsFileEpochProgressIndexKeeper 持有5万多个TsFileResource , DN OO |
| TDB-805 | 逻辑视图为规划项，当前版本无 SQL 入口 | 支持逻辑视图 |
| TDB-806 | 需先构造分区表损坏（人工改元数据） | 使用 SQL 手动修复分区表功能 |
| TDB-812 | 需要消息队列中间件 | 【TIMECHODB-0583】 IoTDB 的 MQTT 服务在解析 不合规的JSON 消息时，空指针异常：NullPointerException: Can |
| TDB-822 | 需构造 OOM（31G dump）与循环重启 | 【TIMECHODB-0359】 3C5D2副本，并发读写过程中 对NODE-1 间隔3分钟 循环重启 ，NODE-1 有OOM （dump 31G） |
| TDB-825 | 需要 SSL 双向认证服务端配置 | 【TIMECHODB-0668】 2.0.7.1 ssl 空指针（目前看影响不大）: NullPointerException: Cannot invoke " |
| TDB-829 | 需要 V2.0.7.1 历史数据升级 | 【TIMECHODB-0665】 【V2.0.7.1_RC10_三权分立】历史版本数据升级到V2.0.7.1后，通过show configuration查看en |

## 四、可测 RN 全量清单（按主题）

### 集群/节点（17）— 用例 `RN-2.0.11.1-CLUSTER`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-730 | 缺陷 | P1 | 【2.0.10.1】【CompressionRatio】show regions CompressionRatio 显示为0，计算公式中分子没有加object大小（分母加了） |
| TDB-748 | 缺陷 | P0 | 修复集群中schema cache 不一致的问题 |
| TDB-756 | 代码优化 | P1 | 【2.0.9.2】【ConfigNode】stop confignode 过程中有空指针 |
| TDB-760 | 缺陷 | P0 | DN 重启恢复过程中收到region创建请求，可能会导致该 region 的信息永久丢失 |
| TDB-761 | 功能迭代 | P0 | 删除时只针对当前表所属的 region group 发起请求 |
| TDB-768 | 缺陷 | P1 | [2.0.9.1] DataRegion为RatisConsensus，3C5D3副本，无故障并发读写过程中，DN 空指针 |
| TDB-770 | 缺陷 | P0 | 【2.0.9.1】分区表自动修复功能，3C3D，stop ConfigNode Leader 进程不退出且持续刷大量日志 |
| TDB-771 | 缺陷 | P0 | 【2.0.9.1】分区表自动修复,停止DataNode后 ，CN Leader节点刷大量ERROR日志 ：TSStatus类转换异常 |
| TDB-796 | 功能迭代 | P00 | extend region 和 remove region 语法支持传入 regionId list ，一次处理多个 region |
| TDB-797 | 缺陷 | P1 | 【TIMECHODB-0313】 [2.0.4.1 RC1] 3C21D集群读写完成后，多次停止/重启整个集群，出现集群重启失败（可复现，不是每次都失败），研发：cn 共识层不可用 |
| TDB-813 | 缺陷 | P1 | 【TIMECHODB-0397】 confignode 线程泄漏 2.0.5.1 RC3 IoTV2 3C3D3副本 运行sql覆盖树模型用例，ConfigNodeRPC-Proc |
| TDB-814 | 缺陷 | P1 | 【TIMECHODB-1043】 【ratis】rc/1.3.3.3 rc6 DataRegion是ratis协议，stop datanode 24小时才完成（shutdown t |
| TDB-817 | 缺陷 | P2 | 【TIMECHODB-0567】 2.0.6.1 RC4 缩容场景 重启集群 show regions 大部分DataRegion的CompressionRatio 字段值是NaN |
| TDB-818 | 缺陷 | P2 | 【TIMECHODB-0563】 [ 建议 ] show regions 结果中 CompressionRatio 字段 保留2位小数 |
| TDB-819 | 缺陷 | P2 | 【TIMECHODB-0562】 2.0.6.1 RC4 缩容场景 Adding 状态的DataRegion ，show regions CompressionRatio 字段显示 |
| TDB-821 | 缺陷 | P2 | 【TIMECHODB-0387】 2.0.5.1 RC1 验证RN: 缩容场景 有delete 数据操作， 遇到removing卡死 （及监控IoTConsensus Used M |
| TDB-827 | 缺陷 | P1 | 【TIMECHODB-0346】 2.0.5.1 RC1 验证缩容场景RN  监控面板IoTConsensus Used Memory中的IoTConsensusQueue  是负 |

### 其它（8）— 用例 `RN-2.0.11.1-CLUSTER`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-742 | 功能迭代 | P1 | 支持后值填充 |
| TDB-747 | 功能迭代 | P0 | 修改实时数据定义逻辑 |
| TDB-766 | 缺陷 | P0 | [2.0.9.1] 分区表自动修复，参数值测试，partition_table_recover_worker_num=0，DN 和 CN 刷大量ERROR |
| TDB-769 | 功能迭代 | P2 | EXPLAIN [ANALYZE]? 支持输出格式为 JSON |
| TDB-791 | 缺陷 | P3 | 【TIMECHODB-0586】 list user 和create user 或 drop user 并发有报错：301: Ratis request failed Unknow |
| TDB-808 | 功能迭代 | P2 | show timeseries 支持按测点名排序 |
| TDB-810 | 缺陷 | P1 | 【TIMECHODB-0778】 master 2025-12-18_55b32fe8 : 并发读写过程中 drop user ，DN 空指针需处理：insertTablet fa |
| TDB-815 | 缺陷 | P3 | 【TIMECHODB-0686】 【数据删除】WHERE子句后使用and连接两个原子表达式情况，时间的最小值大于最大值报错信息为305，需要优化 |

### 审计日志（18）— 用例 `RN-2.0.11.1-AUDIT`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-698 | 代码优化 | P0 | 【企业版-Master】【审计日志】针对root.__audit路径设置TTL时，校验信息错误显示为Apache IoTDB（应显示为TimechoDB） |
| TDB-702 | 缺陷 | P3 | 【开源版审计日志】执行删除/创建序列操作时，提示数据库只读，仍沿用旧逻辑代码 |
| TDB-703 | 缺陷 | P3 | 【开源版审计日志】在日志目录中存在审计的log日志文件，容易让用户产生分歧，建议去除 |
| TDB-709 | 缺陷 | P1 | 【V2.0.11.1】【审计日志】Tree 模型执行 CANCEL ALL MIGRATIONS【成功和 803 拒绝均未生成操作审计记录】 |
| TDB-713 | 功能迭代 | P0 | TTL 删除失败时记录审计日志 |
| TDB-715 | 缺陷 | P2 | 【V2.0.11.1 RC1】【ConfigNode审计日志】顺序停止3C集群使最后一个Leader退主【CNAuditLogger连续抛出NullPointerException |
| TDB-763 | 新功能 | P1 | 【开源版】删除审计相关代码及功能 |
| TDB-764 | 代码优化 | P1 | 【开源版】【审计日志】在开源版中对审计库使用创建删除语句会有审计库的鉴权内容，需要后续版本移除 |
| TDB-775 | 功能迭代 | P2 | 【审计日志埋点】基于黑白名单拒绝特定ip的数据库连接 |
| TDB-776 | 功能迭代 | P2 | 【审计日志埋点】原发会话超时锁定时记录审计日志 |
| TDB-777 | 功能迭代 | P2 | 【审计日志埋点】超出为该用户配置的最大连接数时，拒绝该用户的新连接请求时记录审计日志 |
| TDB-778 | 功能迭代 | P2 | 【审计日志埋点】连接数、密码、黑白名单校验的审计日志 |
| TDB-779 | 功能迭代 | P2 | 【审计日志埋点】重新选举leader记录审计 |
| TDB-780 | 功能迭代 | P2 | 【审计日志埋点】状态机感知各节点状态，还有region和region group的审计日志 |
| TDB-781 | 功能迭代 | P2 | 【审计日志埋点】鉴别失败达到阈值、达到阈值后所采取的动作(如锁定账户),及后来(适当时)还原到正常状态(如解锁)的审计日志 |
| TDB-782 | 功能迭代 | P2 | 【审计日志埋点】密钥生成/销毁时，记录成功/失败的审计日志 |
| TDB-783 | 功能迭代 | P2 | 【审计日志埋点】审计日志模块：新增审计存储失效时处理动作的审计日志 |
| TDB-794 | 安全相关 | P1 | 【EAL4】审计数据可用（权限） |

### CLI/客户端（12）— 用例 `RN-2.0.11.1-CLI`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-689 | 缺陷 | P0 | CLI本地校验Jar路径 2.0.11.1rc导出失败 |
| TDB-700 | 缺陷 | P0 | 取消客户端对远程导出依赖的jar包是否存在的校验逻辑 |
| TDB-718 | 缺陷 | P0 | 修复 CLI 连接不同 DN 执行相同 SQL 返回结果不一致问题 |
| TDB-728 | 缺陷 | P2 | 【V2.0.10.1】【JDBC客户端】查询执行过程中重启 DataNode，JDBC 自动重连后复用旧 statementId 重发查询 【报错 INTERNAL_SERVER_ |
| TDB-740 | 新功能 | P0 | 支持 nodejs 语言的客户端（ 仅支持2.x 的版本） |
| TDB-743 | 安全相关 | P0 | 客户端通信加密双向认证 |
| TDB-751 | 功能迭代 | P1 | udf api 增加一个 InternalSession 接口 |
| TDB-753 | 代码优化 | P2 | 【master_20250515_e253d04】【object 远程备份】备份完成后，1 DN 上有99个sshd-SshClient 线程，24个Pipe-Processor- |
| TDB-765 | 缺陷 | P1 | [2.0.9.1] 【CLI工具/参数解析】在Windows CMD中执行start-cli.bat时 -pw参数置于中间位置 报参数格式错误 |
| TDB-811 | 缺陷 | P1 | 【TIMECHODB-0766】 多用户并发连接数据库，DN 空指针：Cannot invoke "org.apache.iotdb.commons.auth.entity.Use |
| TDB-820 | 缺陷 | P2 | 【TIMECHODB-0508】 [sql 覆盖] 2.0.6.1 RC2 3C3D3副本 DN 有空指针：NullPointerException: Cannot invoke  |
| TDB-824 | 缺陷 | P1 | 【TIMECHODB-0676】 [报错信息优化] 2.0.7.1 安全包 开启SSL，CLI 登录集群不指定SSL 的ERROR信息可优化（更明确） |

### 安全/权限（5）— 用例 `RN-2.0.11.1-SEC`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-744 | 安全相关 | P0 | 支持国密通信加密 |
| TDB-772 | 缺陷 | P1 | 【2.0.9.1】【pipe-writeback-sink】树模型修改sink内使用的用户和password时，报错801 |
| TDB-774 | 安全相关 | P1 | 通信加密回归验证 |
| TDB-816 | 缺陷 | P2 | 【TIMECHODB-0578】 日志优化：sink.username是普通用户且没有被赋予任何权限，发送端WARN 日志刷的太多，30分钟30GB ，WARN  o.a.i.c. |
| TDB-826 | 缺陷 | P1 | 【TIMECHODB-0655】  [2.0.7.1][tree][table]接收端有写权限，load tsfile: No permissions for this opera |

### 表模型 DDL/Procedure（10）— 用例 `RN-2.0.11.1-DDL`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-688 | 缺陷 | P1 | 【V2.0.11.1】【表模型】数据库删除 Procedure 执行期间重启 DataNode【ConfigNode restartDataNode 持续 NPE 导致节点约 10 |
| TDB-691 | 缺陷 | P1 | 【V2.0.11.1】【Procedure框架】单DN Unknown 场景连续 DROP DATABASE【RemoveRegionGroupProcedure 长期占用线程导致 |
| TDB-693 | 缺陷 | P1 | 【V2.0.11.1】【查询引擎】表模型执行查询分析时【Analyzer耗时错误记录到Tree Plan Cost】 |
| TDB-729 | 缺陷 | P1 | 【2.0.10.1】【表模型 show regions中的TsFileSize】TsFileSize 不能把 object size 加进去 |
| TDB-731 | 新功能 | P0 | 【高可用测试】数据库管理的高可用 |
| TDB-733 | 新功能 | P0 | 【高可用测试】可写视图管理的高可用 |
| TDB-734 | 新功能 | P0 | 【高可用测试】设备管理的高可用 |
| TDB-745 | 新功能 | P0 | 【高可用测试】表管理的高可用 |
| TDB-799 | 功能迭代 | P3 | 表模型增加 count database 语句 |
| TDB-828 | 缺陷 | P2 | 【TIMECHODB-0761】 树表模型在查询的过滤条件中需要将整形和浮点型进行对比时的表现不一致现象 |

### Region 迁移/取消（9）— 用例 `RN-2.0.11.1-MIGRATE`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-704 | 缺陷 | P0 | 【V2.0.11.1】【迁移取消】REMOVE Peer 异步任务执行期间取消迁移【远端任务仍删除副本并造成数据缺失】 |
| TDB-707 | 缺陷 | P1 | 【V2.0.11.1】【IoTConsensus】取消 Region 迁移并发清理同一 Peer 时【TreeSet.remove 触发 NPE】 |
| TDB-717 | 缺陷 | P3 | [master][cancel迁移日志优化]执行 CANCEL ALL MIGRATIONS 取消 add-peer 阶段迁移【unexpected consensusGroupI |
| TDB-720 | 缺陷 | P0 | 使用多级存储后，如果TsFileResource 的时间索引降级成FileTimeIndex后，tsFile 无法迁移到远端存储 |
| TDB-721 | 缺陷 | P2 | [master][CANCEL ALL MIGRATIONS] 取消迁移后接收端snapshot残余文件未清理 |
| TDB-735 | 缺陷 | P1 | 【V2.0.10.1】【多盘存储/Region迁移】show regions 与 Prometheus object_file_global_count 出现负值 |
| TDB-737 | 功能迭代 | P00 | CANCEL ALL MIGRATIONS 全局中止迁移指令 |
| TDB-784 | 缺陷 | P1 | 【2.0.8.2】Frame size (69670459) larger than protect max size (67108864) 导致查询卡死，预期应返回正确的报错信息 |
| TDB-795 | 缺陷 | P1 | 【TIMECHODB-703】 【Migrate Region】传输SNAPSHOT过程中stop Add Coord和CN Leader 节点，再重启stopped节点，继续执行 |

### 查询引擎（9）— 用例 `RN-2.0.11.1-QUERY`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-716 | 缺陷 | P0 | 修复对齐序列多测点 LAST 查询在特定时间过滤条件下可能卡死的问题 |
| TDB-719 | 缺陷 | P1 | 修复 DATE 类型空值占位符1000-01-01时，查询逻辑未适配出现异常的问题 |
| TDB-739 | 功能迭代 | P2 | GROUP BY & ORDER BY 支持 select 中 as 的别名 |
| TDB-750 | 代码优化 | P1 | 【master_0525_5caf05a】【查询】查询超时有空指针 RelatedMemoryReserved can't be null when freeing memory |
| TDB-752 | 缺陷 | P0 | date_bin_gap_fill 嵌套查询报错：Cannot invoke "java.lang.Integer.intValue()" because the return v |
| TDB-762 | 功能迭代 | P0 | 加强查询中涉及 mods 的内存控制，对单个较大的 GB 级别的 mods2 也需要能控制住 |
| TDB-801 | 缺陷 | P2 | 【TIMECHODB-0344】 [ratis npe] 2.0.5.1 RC1 验证并发读写+缩容 ratis NullPointerException: Cannot invo |
| TDB-807 | 功能迭代 | P2 | 支持查询 SQL 仅包含 SELECT 子句 |
| TDB-830 | 缺陷 | P2 | 【TIMECHODB-0405】 【树模型-RESTAPI】通过RESTAPI工具执行查询时，log中有UNKNOWN |

### 配置热加载（8）— 用例 `RN-2.0.11.1-CFG`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-695 | 缺陷 | P1 | 【V2.0.11.1】【配置项热加载】Ratis Region 迁移时，大 snapshot 在低速传输下因重配置重试窗口过短被提前回滚，导致迁移失败 |
| TDB-696 | 缺陷 | P0 | 【V2.0.11.1】【配置项热加载】热加载 wal_throttle_threshold_in_byte=-1 后有效值显示为 200 GiB，但运行时仍沿用修改前的 WAL 阈 |
| TDB-699 | 缺陷 | P0 | 【V2.0.11.1】【配置项热加载】热加载 WAL 阈值参数 wal_throttle_threshold_in_byte，使用非法值写入返回301状态码后仍写入配置文件，导致  |
| TDB-701 | 缺陷 | P1 | 【2.0.11.1】【配置项热加载】热加载 disk_space_warning_threshold参数，当值是NaN这个非法值时未被拒绝，导致全部 DataNode 进入 Rea |
| TDB-708 | 缺陷 | P0 | 【V2.0.11.1】【配置项热加载】热加载 ConfigNode 迁移并发上限参数 region_migration_concurrency_limit 从 0 修改为 1 后， |
| TDB-710 | 缺陷 | P0 | 【V2.0.11.1】【配置项热加载】热加载 data_region_per_data_node 后，已有数据库的 MaxDataRegionGroupNum 重算结果错误 |
| TDB-712 | 缺陷 | P1 | 【V2.0.11.1】【配置热加载】执行 set configuration region_migration_speed_limit_bytes_per_second 时【Obj |
| TDB-738 | 功能迭代 | P00 | 支持集群运行时配置的热加载（cluster runtime configs hot reload） |

### 数据订阅（6）— 用例 `RN-2.0.11.1-SUB`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-692 | 缺陷 | P0 | 【2.0.11.1】【数据订阅】无间隔写入5分钟，2小时消费仍未完成 |
| TDB-694 | 功能迭代 | P0 | 【数据订阅】mode 值的关键字修改 |
| TDB-711 | 缺陷 | P1 | 【2.0.11.1】【数据订阅】mode=consensus 的topic不支持除 db，table，format，column外的配置，希望报错 |
| TDB-714 | 缺陷 | P0 | 【V2.0.11.1】【Subscription consensus】使用 PullConsumer 订阅含非空 DATE FIELD 的 Tablet【持续空轮询且无消息】 |
| TDB-787 | 功能迭代 | P3 | 数据订阅： 重构export-tsfile脚本 |
| TDB-803 | 功能迭代 | P0 | 参考 表模型 Java Session 接口 重构 Subscription Session，删除旧的订阅接口，将订阅所有接口聚合到一个主类，该主类不能露普通 Session 的接 |

### 激活/打包（4）— 用例 `RN-2.0.11.1-CLUSTER`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-727 | 新功能 | P00 | 修改打包脚本，使不同参数去判断是否阉割安全功能 + 修改控制台的展示 |
| TDB-754 | 缺陷 | P3 | tsfile-backup.sh工具导出树模型数据时提示路径匹配错误 |
| TDB-786 | 缺陷 | P1 | 激活的序列及其子路径禁止创建设备 |
| TDB-802 | 缺陷 | P2 | 【TIMECHODB-0321】 【封装订阅tsfile的脚本】按照测点、设备导出耗时过长、不可控 |

### 存储/TsFile（5）— 用例 `RN-2.0.11.1-STORAGE`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-732 | 新功能 | P0 | 【高可用测试】TTL管理的高可用 |
| TDB-790 | 功能迭代 | P0 | 封装订阅tsfile的脚本 |
| TDB-804 | 缺陷 | P1 | 【TIMECHODB-0496】 pipe 接收端 1分钟刷出1万多条 WARN  o.a.i.d.s.l.m.LoadTsFileDataCacheMemoryBlock:63  |
| TDB-809 | 缺陷 | P2 | 查询： cast(1.1 as float)  报错Msg: java.lang.UnsupportedOperationException: org.apache.tsfile. |
| TDB-823 | 缺陷 | P2 | 【TIMECHODB-0264】 [ 2.0.3.1 RC2 ] 验证issue 0228 遇到新问题：重启集群有1个节点一直是Unknown 且没有enjoy 日志（新宇看到ma |

### COPY TO TsFile（5）— 用例 `RN-2.0.11.1-COPY`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-684 | 缺陷 | P0 | 【V2.0.11.1】【支持用 SQL 将查询结果写回到指定路径的 tsfile 中】查询中调用返回 STRING 的 ScalarFunction UDF 时，SELECT 报  |
| TDB-685 | 缺陷 | P1 | 【V2.0.11.1】【支持用 SQL 将查询结果写回到指定路径的 tsfile 中】COPY TO TsFile 返回结果集 path 字段类型错误，JDBC/ITableSes |
| TDB-686 | 缺陷 | P1 | 【V2.0.11.1】【支持用 SQL 将查询结果写回到指定路径的 tsfile 中】COPY TO TsFile 未指定 TABLE 时自动生成目标表名，结果集 table_na |
| TDB-687 | 缺陷 | P1 | 【V2.0.11.1】【支持用 SQL 将查询结果写回到指定路径的 tsfile 中】TAGS 中指定重复列时被静默去重，未按需求报错 |
| TDB-785 | 新功能 | P0 | 支持用 SQL 将查询结果写回到指定路径的 tsfile 中 |

### Pipe/同步（1）— 用例 `RN-2.0.11.1-CLUSTER`

| 编号 | 类型 | 优先级 | 标题 |
| --- | --- | --- | --- |
| TDB-755 | 缺陷 | P1 | 【2.0.9.2】并发读写与delete 数据，副本间数据同步卡死 |
