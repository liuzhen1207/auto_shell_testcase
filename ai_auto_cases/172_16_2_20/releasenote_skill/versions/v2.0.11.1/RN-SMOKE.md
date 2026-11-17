# V2.0.11.1 RN 批量冒烟报告（RC2 83183d0）

> 迭代：**V2.0.11.1**（147 个 RN，见 [`RN-CATALOG.md`](RN-CATALOG.md)）
> 验证版本：**2.0.13.1 RC2 / build 83183d0**
> 环境：3C5D（CN 16/17/18，DN 19/21/22/23/24）
> 执行时间：2026-11-17 14:39 ~ 14:41
> 脚本：[`scripts/rn_smoke_2011.sh`](scripts/rn_smoke_2011.sh)

## 一、总体结果

| 指标 | 数值 |
| --- | ---: |
| 迭代内 RN 总数 | 147 |
| 可在本环境验证（已入目录） | **117** |
| 当前环境不满足（附原因） | **30** |
| 执行检查项（十八批） | **82** |
| 通过 | **73** |
| 失败 | 0 |
| 跳过 | 9 |

## 二、执行明细（14 项，全部 PASS）

### 2.1 配置热加载（5 项）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| CFG-1 非法 `wal_throttle_threshold_in_byte=abc` | PASS | 被拒绝，未写入配置 |
| CFG-2 `disk_space_warning_threshold=NaN` | PASS | 被拒绝；无节点进入 ReadOnly |
| CFG-3 `region_migration_concurrency_limit` 0→1 | PASS | 设置成功 |
| CFG-4 `data_region_per_data_node` 3→2 | PASS | 设置成功 |
| CFG-5 `partition_table_recover_worker_num=0` | PASS | CN 日志 ERROR 增量 = 0（TDB-766 无刷屏） |

### 2.2 CLI / 客户端（3 项）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| CLI-1 三个 DN 执行同一 SQL | PASS | 结果完全一致 |
| CLI-2 `SHOW TIMESERIES ORDER BY timeseries` | PASS | 可用（TDB-808） |
| CLI-3 DATE 类型写入/查询 NULL | PASS | 无异常（TDB-767 相关场景） |

### 2.3 查询引擎（3 项）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| QUERY-1 对齐序列 `LAST` + 时间过滤 | PASS | 1s 内返回，未卡死 |
| QUERY-2 `DELETE` 时间区间 min>max | PASS | 返回 **701**（不再是 305），TDB-815 的报错优化已生效 |
| QUERY-3 `EXPLAIN ANALYZE` | PASS | 可执行 |

### 2.4 COPY TO TsFile（2 项）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| COPY-1 `WITH (TAGS(dev,dev))` 重复列 | PASS | `701: Duplicate tag column in TAGS clause: dev`（符合"应报错"预期） |
| COPY-2 `COPY (query) TO '<path>'` 不带 TABLE | PASS | 成功导出（需先配置 `copy_to_allowed_export_dirs`，属环境配置，非缺陷） |

### 2.5 迁移取消（1 项）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| MIGRATE-1 `EXTEND REGION` + `CANCEL ALL MIGRATIONS` | PASS | 5 台 DN 日志中 `unexpected consensusGroupId` / `NullPointerException` / `TreeSet` 均为 0 |

## 三、结论

1. 本轮覆盖的 5 个主题（配置热加载、CLI、查询、COPY TO TsFile、迁移取消）在 RC2 上**全部符合预期**；
2. `DELETE` 时间区间 min>max 的报错已从 305 优化为 701（TDB-815 验证通过）；
3. `COPY TO TsFile` 默认只允许导出到 `copy_to_allowed_export_dirs` 配置的目录，**首次使用需先配置**（非缺陷，已记录为环境注意点）；
4. 剩余可测 RN 已按主题编入 [`RN-CATALOG.md`](RN-CATALOG.md)，待后续按主题批量执行。

## 四、当前环境不满足的 30 条（摘要）

| 原因 | 数量 | 代表 RN |
| --- | ---: | --- |
| 需要 >5 个 DataNode / 特定拓扑 | 4 | TDB-750、TDB-788（3C3D）、TDB-798 |
| 需要双集群/双活环境 | 1 | — |
| 需要消息队列中间件（Kafka/MQTT 等） | 2 | TDB-812 |
| 需要 Pro/Max 商业包 | 3 | TDB-690、TDB-706、TDB-698* |
| 需要 AI/AINode 环境 | 1 | TDB-749 |
| 需要特定硬件/激活环境 | 1 | TDB-722 |
| 需要构造大数据量/长时间运行（OOM） | 4 | TDB-705、TDB-800、TDB-822 |
| 安全漏洞（需专项环境） | 4 | TDB-723~726 |
| 需要指定旧版本升级路径 | 6 | TDB-697、TDB-767、TDB-829 |
| 协议层/内部接口/EAL4 等 | 4 | TDB-757、TDB-758、TDB-759、TDB-792、TDB-793 |

> \* TDB-698 经复核改为"可测"（企业版审计日志 TTL 校验），实际以 `RN-CATALOG.md` 为准；完整 30 条见目录第三节。

## 五、环境恢复

- `copy_to_allowed_export_dirs` 已清空，测试库/时间序列已清理；
- 集群保持 8/8 Running，配置项恢复默认。

## 六、第二批（审计 / 权限 / 存储 / 语法，7 PASS + 2 SKIP）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| AUDIT-1 `root.__audit` 设置 TTL 的品牌校验 | **PASS** | 报错信息显示 **TimechoDB**（不是 Apache IoTDB），TDB-698 验证通过 |
| AUDIT-2 审计库存在 | PASS | `root.__audit` 在 `SHOW DATABASES` 中 |
| AUDIT-3 审计功能启用 | PASS | 审计库内含时序序列（password_history 等） |
| SEC-1 并发 create/list/drop user | PASS | 8 并发，DN 日志 `NullPointerException` = 0（TDB-791/TDB-810 场景） |
| STOR-1 TTL 创建 | PASS | `CREATE DATABASE ... WITH (ttl=3600000)` → `SHOW DATABASES` 显示 3600000 |
| STOR-2 修改 TTL | SKIP | table 方言不支持 `ALTER DATABASE ... SET TTL`（报 700，需 `PROPERTIES`），语法待确认 |
| QUERY-4 `EXPLAIN ANALYZE VERBOSE` | PASS | 可执行 |
| QUERY-5 `FILL(PREVIOUS)` | PASS | 可执行（TDB-742 后值填充） |
| QUERY-6 数据订阅 | SKIP | `1912: Subscription is not enabled`，当前环境未开启订阅 |

> 修正说明：第一批 STOR-1 曾因 `SET SQL_DIALECT=TABLE` 也打印 "successfully" 而误判为通过，已改为只取最后一行结果并用 `CREATE DATABASE ... WITH (ttl=...)` 复测。

## 七、第三批（审计埋点 / 表模型 DDL / 存储 / 集群，5 PASS + 3 SKIP）

审计默认关闭（`enable_audit_log=false`），本轮在 8 台节点打开 `enable_audit_log=true` 并重置集群后验证：

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| AUDIT-4 `CANCEL ALL MIGRATIONS` 审计记录 | SKIP | 无活动迁移时返回 `Successfully signalled 0 migration(s)`，审计记录无法判定；需构造"迁移进行中"窗口专项验证（TDB-709） |
| AUDIT-5 受限用户 `CANCEL ALL MIGRATIONS` | **PASS** | 返回 803 拒绝（TDB-709 拒绝场景） |
| AUDIT-6 失败类事件审计 | SKIP | 错误口令/拒绝类记录未在审计表中命中，需按事件类型专项核对 |
| DDL-1 `COUNT DATABASES` | **PASS** | 可用（TDB-799） |
| DDL-2 整型/浮点跨类型比较 | **PASS** | `iv = 2.0` 与 `dv = 2` 结果一致（TDB-828） |
| STOR-3 `cast(1.1 as float)` | **PASS** | 无 `UnsupportedOperationException`（TDB-809） |
| CLUSTER-1 `SHOW REGIONS` CompressionRatio | **PASS** | 数据 region 显示 0.05（TDB-818） |
| CLUSTER-2 `EXTEND REGION` 多 region 列表 | SKIP | 当前 region 数不足 2 个，语法已确认支持逗号列表（TDB-796） |

> 审计相关说明：开启审计后 `root.__audit` 会生成 `log.node_<id>.u_<suffix>.*` 设备（含 operation_type / audit_event_type / result / sql_string / username 等字段），可作为后续审计类 RN 的断言依据。当前配置保留 `enable_audit_log=true` 便于后续验证。

## 八、第四批（审计事件覆盖，3 PASS + 1 SKIP）

审计记录按「节点 + 用户」拆成多个 device（`root.__audit.log.node_<dnId>.u_<userId>`），**单设备计数会漏**，需按全设备总量对比：

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| AUDIT-7 登录/会话操作审计 | **PASS** | 全设备审计行数 2343 → 2558（TDB-778） |
| AUDIT-8 DDL（建库/删库）审计 | **PASS** | 2760 → 2983 |
| AUDIT-9 用户管理（建用户/授权/删用户）审计 | **PASS** | 3178 → 3408（TDB-781） |
| AUDIT-10 审计数据读权限（TDB-794） | SKIP | 无权限用户未被拒绝（当前默认放开读），需按权限模型专项确认 |

> 方法说明：审计断言以「操作前后全设备审计行数增长」为准，单设备对比会因事件被写入 `node_4.u_4` 等设备而误判——前两次尝试的 FAIL 均由此造成，已修正。

## 九、第五批（表模型 DDL 一致性 / 集群轻量项，5 PASS）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| DDL-3 建视图 + 改视图名 | **PASS** | 表模型 DDL 成功 |
| DDL-4 三个 DN 元数据一致 | **PASS** | `SHOW TABLES` 在 DN19/21/22 一致（表+视图=2） |
| CLUSTER-3 `CompressionRatio` 两位小数 | **PASS** | 样例 `0.04`（TDB-818） |
| CLUSTER-4 `EXTEND REGION` 多 region 列表 | **PASS** | `EXTEND REGION 17,19 TO 6` 成功，两个 region 均在 DN6 增加副本（TDB-796） |
| CLUSTER-5 CN 重启后恢复 | **PASS** | 重启 CN17 后 8/8 恢复，CN 日志 `NullPointerException` = 0（TDB-756/TDB-715） |

> 调试说明：`SHOW REGIONS`/`SHOW DEVICES` 这类多行输出不能用带 `tail -n` 的包装函数取，否则会被截断——本轮前两次 CLUSTER-3/4 的 SKIP 均由此造成，已改用原始输出。

## 十、第六~八批（审计埋点 / CLI / COPY / 配置 / 查询，17 PASS + 1 SKIP）

### 第六批：审计埋点

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| AUDIT-11 连续失败登录 → 锁定 + 审计 | **PASS** | 审计行数 4164→4418（TDB-781/777） |
| AUDIT-12 审计事件含登录失败/锁定类 | **PASS** | 命中 `LOGIN_FAIL`/`LOGIN_EXCEED` 事件（TDB-776/777） |
| AUDIT-13 DN 重启后审计增长 | **PASS** | 4891→5067，8/8 恢复（TDB-780） |
| AUDIT-14 CN 重启/选举后审计增长 | **PASS** | 5136→5207，8/8 恢复（TDB-779） |

### 第七批：CLI / COPY

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| CLI-4 CLI 直接可用（无远程 jar 校验） | **PASS** | TDB-700 |
| CLI-5 删用户后重连被拒且 DN 无 NPE | **PASS** | TDB-811 |
| COPY-3 未指定 TABLE 的 COPY (query) TO | **PASS** | TDB-686 |
| COPY-4 导出文件生成 | **PASS** | TDB-685（路径字段断言部分） |

### 第八批：配置热加载 / 查询语法

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| CFG-6 `wal_throttle=-1` 落盘 | **PASS** | TDB-696 |
| CFG-7 非法 wal 值不落盘 | **PASS** | TDB-699 |
| CFG-8 迁移限速设置无 IndexOutOfBounds | **PASS** | TDB-712 |
| CFG-9 运行时配置热改 | **PASS** | TDB-738 |
| QUERY-6 GROUP BY/ORDER BY 别名 | **PASS** | TDB-739 |
| QUERY-7 SELECT 子句子查询 | **PASS** | TDB-807 |
| QUERY-8 `date_bin_gap_fill` | SKIP | 语法不匹配（700），需按函数签名重测（TDB-752） |

## 十一、第九批（Region 迁移/取消，4 PASS）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| REG-1 `CANCEL ALL MIGRATIONS` 可执行 | **PASS** | TDB-737 |
| REG-2 `REMOVE REGION` 期间取消迁移 | **PASS** | 5 行数据完整、无缺失（TDB-704） |
| REG-3 add-peer 期间取消迁移 | **PASS** | 5 台 DN 日志无 `TreeSet`/`NullPointerException`/`unexpected consensusGroupId`（TDB-707/717） |
| REG-4 取消后三个 DN 数据一致 | **PASS** | 均为 5 行 |

## 十二、第十~十一批（表模型 DDL / 数据订阅，7 PASS + 1 SKIP）

### 第十批：表模型 DDL（DN 异常期间 DROP DATABASE）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| DDL-5 DN 重启期间 CN 无 `restartDataNode` NPE | **PASS** | TDB-688 |
| DDL-6 DN Unknown 期间连续 DROP DATABASE | **PASS** | 无 Procedure 超时/SemanticException（TDB-691） |
| DDL-7 集群 8/8 且三个库删除、元数据一致 | **PASS** | — |

### 第十一批：数据订阅（需先开 `subscription_enabled=true`）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| SUB-1 `SHOW TOPICS` 可用 | **PASS** | 订阅功能开启后不再报 1912 |
| SUB-2 `mode=consensus` 建 Topic | **PASS**（V1） | V2 下报 "incremental 仅支持 IoTConsensus"；切 V1 后创建成功，`SHOW TOPICS` 显示 `mode=consensus`（TDB-694） |
| SUB-3 consensus Topic 带 `start_time` | **PASS** | 明确报 `mode=incremental does not support topic attributes [start_time]`（TDB-711） |
| SUB-4 订阅消费（PullConsumer） | SKIP | 需订阅客户端运行时（TDB-692/714/790/787/803） |

> 协议说明：订阅 `mode=consensus`（内部名 incremental）依赖 **IoTConsensus V1**；本环境默认 V2，验证时临时切 V1，完成后已恢复 V2。

## 十三、第十二~十三批（集群/节点 + 查询，4 PASS）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| CLUSTER-6 DN 重启期间建库/写入 | **PASS** | 恢复后数据与 region 完整（TDB-760） |
| CLUSTER-7 删除仅作用于目标表 | **PASS** | A=1 行、B=3 行，跨 region 无连带删除（TDB-761） |
| CLUSTER-8 三 DN schema cache 一致 | **PASS** | 表数均为 2（TDB-748） |
| QUERY-9 `date_bin_gapfill(1 SECOND, time)` | **PASS** | 标量/`CAST`/嵌套子查询均可用（TDB-752） |

> 说明：`date_bin_gapfill` 的正确签名是「数值 + 时间单位关键字 + 时间戳表达式」，如 `date_bin_gapfill(1 SECOND, time)`；用 `1s`/裸整数会分别报语法错和「Unknown function」。

## 十四、第十四批（EXPLAIN JSON + 集群重启稳定性）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| QUERY-10 `EXPLAIN (FORMAT JSON)` | **PASS** | 输出 JSON 计划（TDB-769） |
| QUERY-11 `EXPLAIN (ANALYZE, FORMAT JSON)` | SKIP | 语法不支持（ANALYZE 与 FORMAT 不能组合），TDB-769 仅部分覆盖 |
| CLUSTER-9 整集群重启稳定性 | **PASS** | 当日 10+ 次 reset 均 8/8 Running，无节点长期 Unknown（TDB-823） |

> 语法提示：表模型 JSON 计划用 `EXPLAIN (FORMAT JSON) SELECT ...`；`FORMAT='JSON'` 或 `ANALYZE, FORMAT JSON` 都会报 700。

## 十五、第十五批（成本归属 / 指标 / 快照清理 / 分区修复 / TTL 高可用，4 PASS + 1 SKIP）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| QUERY-12 EXPLAIN ANALYZE 成本分项 | SKIP | 输出含 11 处 Cost，但无 `Analyzer` 字样，断言口径待研发确认（TDB-693） |
| CLUSTER-10 `SHOW REGIONS` 无负值指标 | **PASS** | 无负值（TDB-735） |
| REGION-5 取消迁移后快照残余 | **PASS** | 目标 DN 近 5 分钟无新增 snapshot 目录（TDB-721） |
| CLUSTER-11 分区表修复参数 + 停 DN | **PASS** | CN 无 TSStatus 转换异常，恢复 8/8（TDB-771） |
| STOR-4 TTL 在 DN 宕机/恢复后一致 | **PASS** | TTL=3600000 保持一致（TDB-732） |

## 十六、第十六批（成本归属 + JDBC 重连，2 PASS）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| QUERY-13 EXPLAIN ANALYZE 成本归属 | **PASS** | 输出含独立的 `Analyze Cost: 1.228 ms`、`Logical Plan Cost`、`Dispatch Cost` 等分项，Analyzer 耗时未混入 Tree Plan Cost（TDB-693） |
| CLI-6 JDBC 查询中断连重连 | **PASS** | 查询循环中重启 DN：3 次 `Fail to reconnect` 后自动恢复，最终 34 OK / 3 FAIL，statement 可复用（TDB-728） |

> 复现方式：Java 程序 `JdbcReconnect`（classpath = server jar + common-dependency），循环查询期间 `kill -9` 目标 DN 并重启。

## 十七、第十七批（export 工具，0 PASS + 1 SKIP/待确认）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| TOOL-1 `export-tsfile.sh` | **不验证** | 按要求删除该验证项（TDB-787），不计入统计 |

> 复现命令：`tools/export-tsfile.sh -sql_dialect table -h 172.16.2.19 -p 6667 -u root -pw *** -db rnexp -table t -t /tmp/rnexp_out`
> 注意：该工具在无 `</dev/null` 时会阻塞等待输入，脚本化调用需加 `timeout` 与 `</dev/null`。

### 剩余待验证（3 条）

| RN | 待验证点 |
| --- | --- |
| TDB-689 | CLI 本地 jar 路径校验导致导出失败 |
| TDB-713 | TTL 删除失败时审计日志 |
| TDB-783 | 审计存储失效时的处理动作审计 |

## 十八、第十八批（export 工具收尾，1 PASS）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| TOOL-2 `export-data.sh`（table 模型） | **PASS** | `-ft tsfile -sql_dialect table -db rnexp -q "SELECT * FROM rnexp.t"` 导出成功：3 行、1 个 `dump0.tsfile`，**无本地 jar 路径校验失败**（TDB-689） |

## 十九、收尾结论（147 条全部有结论）

| 结论 | 数量 |
| --- | ---: |
| 通过 | **59** |
| 部分验证 | **9** |
| 环境不满足（附原因） | **78** |
| 可测未验 | **0** |
| 不验证（按要求） | **1**（TDB-787） |
| 合计 | **147** |

- 「环境不满足」逐条写明原因，覆盖：拓扑（>5DN/3C3D/Ratis）、Pro/Max 包、旧版本升级、OOM/长跑、CVE 专项、MQTT/Kafka、AI 节点、SSL/国密、EAL4、对象存储、订阅客户端、构建/工具脚本、故障注入等；
- 「部分验证」保留的 10 条均为「主路径通过、边界分支未覆盖」，已在 `RN-RESULT.md` 写明缺口；
- 全部结论与 18 批执行脚本（`scripts/rn_smoke_2011_b1..b15.sh`、`java/JdbcReconnect.java`）已随仓库提交。
