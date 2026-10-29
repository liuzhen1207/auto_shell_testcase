# TTL 源码结论（2.0.12.1，源码根 `D:\IDEA\timechodb_src\v20121\timechodb`）

只列出**影响用例设计**的结论，括号内为源码位置。

## 语义与取值
- SQL 里 TTL 单位恒为 **毫秒**，`INF` → `Long.MAX_VALUE`（`ASTVisitor.java:3101-3115`、`ColumnHeaderConstant.java:58`）。
- 树模型：`SET TTL TO <prefixPath> <ms|INF>`、`UNSET TTL (TO|FROM) <path>`、`SHOW TTL ON <path>[,<path>]`、`SHOW ALL TTL`（`IoTDBSqlParser.g4:343-360`）；
  `prefixPath` 允许中间 `*`？→ **不允许**，只允许以 `**` 结尾或不带星的具体 database/device（`TTLManager.java:174-176`，报 `ILLEGAL_PARAMETER` + `Illegal pattern path`）。
- `SET TTL TO root.db` 且 `root.db` 是**已存在库**时，同时写 `root.db` 与 `root.db.**` 两条规则（`TTLManager.java:93`、`TTLInfo.java:87-92`）；库不存在时只写一条 → **用例据此断言两种行为**。
- 继承：`TTLCache.getClosestTTL` 自 root 逐层向下，**子级覆盖父级**（`TTLCache.java:144-164`）。
- `SHOW TTL ON` 只返回**显式设置过**的规则，不含继承（`TTLInfo.java:150-169`）；`SHOW ALL TTL` = `root.**` 匹配全部。
- 规则数上限 1000、不可配，超限 `OVERSIZE_TTL(612)`（`CommonConfig.java:142-143`、`TTLInfo.java:71-85`）；`UNSET` 不存在的规则 → `PATH_NOT_EXIST(508)` + `Not TTL rule set for %s`。
- 错误码：`OUT_OF_TTL=607`、`OVERSIZE_TTL=612`、`TTL_CONFIG_ERROR=613`（`TSStatusCode.java:115,120,121`）。
- 表模型没有 SET/UNSET/SHOW TTL 语句，只有 `CREATE/ALTER ... WITH (ttl=…)`（`RelationalSql.g4:239,253-258,304-305`）；`ttl='INF'`/`default` 合法，非 LongLiteral 报 701（`StatementAnalyzer.java:5601-5628`）。
- 表模型 TTL 存 `TsTable.props["ttl"]`，**建表时从库 TTL 物理拷贝**（`CreateTableProcedure.java:132-142`）；改库 TTL 不影响已建表。

## 清理执行
- 调度：每个 DataNode 一个 `TTLScheduleTask`，周期 `ttl_check_interval`（默认 2h，**restart 生效**），逐 DataRegion `executeTTLCheck()`，仅表模型库再跑 object 文件检查（`TTLScheduleTask.java:45-84`）。
- **settle 选择依赖 `enable_seq_space_compaction` / `enable_unseq_space_compaction`**，两者关掉则 TTL 完全不删（`CompactionScheduler.java:377-379`）→ 用例启动前必须确认这两个开关为 true（默认 true）。
- 选择粒度：按**设备**判过期（`SettleSelectorImpl.java:244-319`）：
  - 文件内所有设 TTL 设备都过期 → `FULLY_DIRTY` → **整文件删除**，日志 `Settle task deletes fully_dirty tsfile ... successfully`；
  - 部分过期 → 需 `deletedDeviceRatio >= expired_data_ratio` 或超期 `> min(max_expired_time, ttlThreshold)`，否则永不重写。
  - ⚠️ **RC4 缺陷**：L294 `long ttlThreshold = 3 * ttl > ttl ? ttl : Long.MAX_VALUE;` —— 真分支本意是 `3 * ttl`（`3*ttl > ttl` 只是防溢出判断），笔误写成 `ttl`。
    由于"设备过期"本身等价于 `now - endTime > ttl`，且 `min(max_expired_time, ttl) <= ttl`，
    ⇒ `max_expired_time != Long.MAX_VALUE` 时 `hasExpiredTooLong` 恒为真，**`expired_data_ratio` 被完全短路**（默认 `max_expired_time=30 天`，即默认就是"过期即清理"）。
    引入提交：`85f4bbbfba`（apache/iotdb #14491，2025-02-18，把 `Math.min(config.getMaxExpiredTime(), 3 * ttl)` 改成当前写法）；上游 master 至今相同。
    想让比例门控生效，必须设 `max_expired_time=9223372036854775807`（`Long.MAX_VALUE`，即关闭强制清理）。
    详见 `docs/CALIBRATION.md` 0.6 节（含 A/B/C 三相隔离实验）与 `tools/probe_ratio_isolate.sh`。
  - ⚠️ **缺陷 2（写放大）**：`expired_data_ratio=0.0` 时 `deletedDeviceRatio(0.0) >= 0.0` 恒真，
    "零脏数据"的 TsFile（甚至完全没设 TTL 的设备所在文件）也会被每个 `ttl_check_interval` 选中并 settle 重写
    （实测同一文件连续 21 代/15s）。代码缺 `deletedDeviceRatio > 0` 保护。用例请用极小正数（默认 `1e-6`）。
- 边界：数据存活判据 `time >= now - TTL`（**相等算存活**，`CommonUtils.java:397-414`、`ArrayDeviceTimeIndex.java:439-442`）；写入早于下界 → `OUT_OF_TTL(607)`（`DataRegion.java:1278-1283`）。
  → **不能靠插入旧时间戳来测清理**（会被拒写）；清理用例必须"写当前时间 → 设小 TTL → 等过期"。
- CN 侧分区表清理边界不同：`partitionEndTime + TTL <= now` **相等即清理**（`SeriesPartitionTable.java:284-292`）。

## OBJECT
- 只在**表模型**存在：树模型 `OBJECT_TYPE_IS_NOT_SUPPORTED_AS_RETURN_TYPE`（`StatementAnalyzer.java:6153-6155`）；object TTL 检查只对表模型库执行（`TTLScheduleTask.java:79-84`）。
- 目录 `data/object/<regionId>/<table>[/tags]/{time}_{tsVersion}.bin`；删除判据 `fileTimestamp < now - ttl - 60s`（**额外 60s 缓冲**，`CompactionUtils.java:591-596,847-855`），删除日志 `Remove object file ... size is ...`（logger `OBJECT_DELETION`）。
- 失败审计事件 `FAILED_TTL_DELETION`（`CompactionUtils.java:647-729`）。

## 表模型库级 TTL 的重要限制
- `PartitionTableAutoCleaner.java:67-71` 明确注释：**database 级 TTL 不影响表模型数据**，只有 table 的 TTL 生效。
- 树模型 `ALTER DATABASE ... WITH(TTL=…)` 直接报错（`"Doesn't support ALTER TTL yet."`，`ConfigNodeRPCServiceProcessor.java:464-469`）；表模型允许但只改 schema、不推 DN（`ClusterSchemaManager.java:252-308`）→ `SHOW TTL` 与 `SHOW DATABASES DETAILS` 可能不一致。
- 因此表模型清理用例**必须把 TTL 设在表上**，库级 TTL 只用于"继承/展示"断言。

## metrics
- `compaction_task_selection_cost{name="settle"|"settle-object"}`、`compaction_task_selected_file{name="settle"}`（`CompactionMetrics.java:889-919`）可作为清理发生的旁证。
