# 修改数据类型 × 合并 并发 / 高可用 用例设计（依据《修改数据类型手册更新内容》）

手册原文抽取：`docs/req_datatype_change.txt`（用户提供 `D:\IDEA\deepseek\compaction\修改数据类型手册更新内容.docx`）。
本文件把手册里**每个需求点**映射到用例与判据，并记录实测结论。用例实现见 `cases/common/dt_*.sh`（DT-01 ~ DT-09）。

## 一、需求点 → 用例 → 判据

| # | 手册需求点 | 出处 | 用例 | 判据（全部要求"三副本一致 + 无异常日志"） |
| --- | --- | --- | --- | --- |
| R1 | 支持 `ALTER TIMESERIES fullPath SET DATA TYPE newType`（V2.0.8+，**企业版**，树模型/表模型） | 树 2.3 | **DT-01** / **DT-02** | 响应成功 + `show timeseries` 的 `DataType` 列 = 目标类型 + 数据仍可读 |
| R2 | 变更过程中若该序列被**并发删除**，会报错提示 | 树 2.3 / 表 1.4 | **DT-04**（树）/ **DT-06 C**（表） | 先删后改必须 508；N 轮 `ALTER ∥ DELETE` 每轮必须有一方明确成功、无损坏/卡死 |
| R3 | 兼容性表：INT32→{INT64,FLOAT,DOUBLE,TIMESTAMP,STRING,TEXT}、INT64→{TIMESTAMP,DOUBLE,STRING,TEXT}、FLOAT→{DOUBLE,STRING,TEXT}、DOUBLE→{STRING,TEXT}、BOOLEAN→{STRING,TEXT}、TEXT→{BLOB,STRING}、STRING→{TEXT,BLOB}、BLOB→{STRING,TEXT}、DATE→{STRING,TEXT}、TIMESTAMP→{INT64,DOUBLE,STRING,TEXT} | 树 2.3 | **DT-01** | 兼容表里**每一条**转换都要成功（10 种原始类型、共 30 条转换） |
| R4 | 原始类型→不兼容类型必须被拒绝 | 树 2.3 | **DT-02** | 6 组负向（DOUBLE→FLOAT / TEXT→INT32 / BOOLEAN→INT32 / TIMESTAMP→FLOAT / STRING→INT32 / BLOB→INT64）必须失败，且**失败后类型与数据不变** |
| R5 | `ALTER TABLE ... ALTER COLUMN col SET DATA TYPE new_type`，**只支持 Category=FIELD**，TAG 不支持 | 表 1.4 / 2.4 | **DT-05** | FIELD 列正向成功；TAG 列/时间列报 `701: Can only alter datatype of FIELD columns`；不兼容报 `701: New type X is not compatible with the existing one Y` |
| R6 | 表模型变更过程中表/列被并发删除应报错 | 表 1.4 | **DT-06 C** | 并发 `DROP TABLE ∥ ALTER COLUMN` ⇒ 必须给出明确结果（改成功或 550 表不存在），不得残留元数据/数据复活 |
| R7 | 表模型兼容性表（同 R3） | 表 1.4 | **DT-05** | 正向抽样 + 不兼容负向 + `desc` 显示新类型 + 旧值按新类型可读（如 11 → 11.0） |
| R8 | `ALTER VIEW ... ALTER COLUMN col SET DATA TYPE`（树转表视图，V2.0.8+，仅 FIELD 列） | 视图 2.2 | **DT-07** | 建视图正确语法 `CREATE VIEW <表库>.<视图> (col TYPE FIELD FROM <测量>) AS root.path.**`；改列类型成功且 `desc` 更新；不兼容 701；不存在的列 616/701 |
| R9 | 视图其余操作：改名 / 加列 / 列重命名 / 删列 / TTL / 注释 | 视图 2.2 | **DT-07**（部分）/ 现有 MD 系列 skill 覆盖 DDL 语法 | 本 skill 只覆盖与"改类型"直接相关的部分；完整 DDL 语法见 `metadata_skill`（MD-T06/MD-B02 视图用例） |
| R10 | 类型变更后的**数据可读性与转换语义** | 通用 | **DT-01** / **DT-02** / **DT-05** | 数值→数值保留数值、布尔/时间→字符串取字面量；行数不减、值可读（具体字面量形态打日志） |
| R11 | **与合并的并发/交叉**（用户重点要求） | 用户追加 | **DT-03**（树）/ **DT-06**（表）/ **DT-07**（视图×底层合并） | 改类型前后文件混合合并、合并进行中改类型、同库混合数据类型文件一起合并、混合 schema 无 `DataTypeInconsistentException`/`CompactionTableSchemaNotMatchException` |
| R12 | **高可用**：磁盘 readonly、节点正常下线 | 用户追加 | **DT-08** / **DT-09** | 合并期间把一个 DN 的 `/data` `remount,ro` ⇒ 数据不丢不坏、恢复后追赶一致；合并/改类型期间优雅 stop 1 DN、停 1 个 CN（仍可用）、停 2 个 CN（无多数派时必须明确失败且不损坏）⇒ 恢复后三副本一致 |

## 二、实测结论（RC6 `v20121rc6_1010_7ae8713e` / 3C3D / IoTConsensus）

| 用例 | 覆盖需求点 | 结果 | 耗时 | 关键实测值 |
| --- | --- | --- | --- | --- |
| **DT-01** 树模型基础 + 兼容矩阵 | R1/R3/R10 | **PASS** fail_flag=0 | 693s | 10 种原始类型全部建成并写入（设备名用 `t_<TYPE>`，TIMESTAMP 列用**不带引号**字面量）；兼容表里 **30/30** 条转换全部成功，`show timeseries` 的 `DataType` 三副本一致；转换后行数不减、值可读（如 `11 → 11.0`） |
| **DT-02** 树模型负向 | R2/R4/R10 | **PASS** fail_flag=0 | 299s | 6 组不兼容转换全部被拒（507，消息带 per-DataNode 详情），**失败后类型与数据均未变**；不存在的序列/库明确 508 |
| **DT-03** 树模型 × 合并 | R11 | **PASS** fail_flag=0 | 752s | A 相：一个文件里"改类型前 INT32 写的 11/12 + 改后 DOUBLE 写的 1.25/2.75"**顺利合并**（finishes 0→6、TsFile 6→3），读数 `11.0|12.0|1.25|2.75|` 合并前后一致；B 相：限流 1MB/s 下 TEXT 大序列（6 行 × 100KB）合并（30→6 个文件，finishes 0→12）**进行中** `ALTER` 成功，b1 载荷签名与 b2 指纹均不变；C 相：INT32/DOUBLE/TEXT 混合 schema 同库合并（finishes 0→4、8→6），三条序列指纹全一致；全程无 `DataTypeInconsistentException`/`CompactionTableSchemaNotMatchException` |
| **DT-04** 树模型并发 | R2 | **PASS** fail_flag=0 | 265s | ①先删后改 → 508；②`ALTER ∥ DELETE TIMESERIES` 8 轮：每轮**最终态都自洽**（3 轮 DOUBLE / 5 轮序列已删除），0 轮不明确；③改类型 ∥ 连续写入：10/10 写入报成功、1s 内可见、类型保持 DOUBLE；④无 `TsFileResource.writeLock` 卡死 |
| **DT-05** 表模型基础 | R1/R5/R7/R10 | **PASS** fail_flag=0 | 236s | FIELD 列正向转换成功（`i32` INT32→INT64→DOUBLE、`f32`→DOUBLE、`str`→TEXT、`dbl`→STRING），**值转换硬断言**：`42\|43\| → 42.0\|43.0\|`、`abc\|def\|` 保持、`2.5\|3.5\|` 保持；TAG/时间列报 `701: Can only alter datatype of FIELD columns`；不兼容报 `701: New type X is not compatible with the existing one Y`；不存在列 616、不存在表 550 |
| **DT-06** 表模型 × 合并 | R11 | **PASS** fail_flag=0 | 297s | A 相：改类型前后文件合并（finishes 0→2、TsFile 6→5），值 `11.0\|12.0\|1.25\|2.5\|` 合并前后一致；B 相：**与 seq 时间范围重叠**的乱序数据（unseq=4）经跨空间合并归零（**真实 `CrossSpaceCompaction` finishes 0→8**），值 `1.0\|1.5\|4.5\|2.5\|5.5\|2.0\|` 不变；C 相：并发 `DROP TABLE ∥ ALTER COLUMN` 双方都成功、删除后查询明确 550、`SHOW TABLES` 不再有该表 |
| **DT-07** 树转表视图 | R8/R9 | **FAIL** fail_flag=3（**功能面全 PASS，3 条全部来自 CN NPE 门禁**，缺陷候选见 §三.1） | 236s | 视图建成功后改列类型成功、`desc` 更新为 DOUBLE、读数 `7\|8\| → 7.0\|8.0\|`（硬断言）、不兼容 701、不存在列 616、底层合并后视图读数不变；**ConfigNode follower 抛 `NullPointerException`/`Unknown Procedure type: 766`**（根因已定位到源码，见 `docs/DEFECT_view_column_datatype_procedure.md`） |
| **DT-08** 磁盘 readonly（高可用） | R12 | **PASS** fail_flag=0 | 1022s | 只读注入**硬校验成功**（数据根下 `touch` 返回 `Read-only file system`）→ 只读窗口内：其它两副本各并成 1 个文件、**受害副本仍是 2/0/0/0**（合并写不了新目标文件）、数据指纹/行数/1KB 载荷原文全部不变；恢复可写（RW_OK）后自动回到 Running；**180s 内该 region 不自动重试**（WARN，见 §三.12）⇒ 重启该 DN 触发 region 恢复，**4s 内三副本布局收敛一致 `0/1/0/0`**、TsFile 6→3、finishes 4→6；收尾三件套全绿、无残留 target |
| **DT-09** 节点正常下线（高可用） | R12 | **PASS** fail_flag=0 | 852s | A 合并中优雅停 1 DN（TERM）⇒ 恢复后指纹/行数一致、合并收敛；B 停 1 CN（多数派仍在）写入成功且**合并仍推进**（finishes 6→10、TsFile 9→6）；C 停 2 CN（无 CN 多数派）⇒ DML 与已有库上的 DDL **都返回成功且数据/元数据一致**（数据区与模式区共识都在 DN 上，架构如此）、读可用；D 改类型期间优雅停 DN ⇒ 恢复后类型仍 DOUBLE、三副本各见 2 行；E `kill -9` 对照 ⇒ 恢复后指纹/行数一致、无残留 |

> 结果同时写进 `docs/RESULTS.md` 与 `results/final_results.csv`（`bash tools/final_summary.sh` 汇总）。

## 三、实测发现

1. **ConfigNode 在"视图改列类型"路径上抛 NullPointerException（已定位到源码，缺陷候选，待研发确认）**
   - 现象：DT-07 执行 `create view` + `alter view ... alter column ... set data type` 后，**ConfigNode follower（`.78`/`.79`）各出现 18~36 条**
     `java.lang.NullPointerException: Cannot invoke "org.apache.iotdb.commons.request.IConsensusRequest.markAsGeneratedByRemoteConsensusLeader()" because "<local7>" is null`
     （leader `.77` 无 —— leader 用本地对象应用，不走反序列化）。
   - **根因（RC6 `7ae8713ecb` 源码，完整链条见 `docs/DEFECT_view_column_datatype_procedure.md`）**：
     `AlterViewColumnDataTypeProcedure` 序列化时映射为 `ALTER_VIEW_COLUMN_DATATYPE_PROCEDURE(766)`
     （`ProcedureFactory.java:542-543`），但 `ProcedureFactory.create()` 的 `switch` **没有 766 的 case**（`:450-452` 落到 `default` 抛
     `IOException: Unknown Procedure type: 766`）→ `ConfigRegionStateMachine.deserializeRequest():185-191` **吞异常返回 null**
     → `ApplicationStateMachineProxy.applyTransaction():153` 对 null 调方法 ⇒ NPE。
     同族 case（`ALTER_TABLE_COLUMN_DATATYPE_PROCEDURE` 765、`ADD/RENAME_VIEW_COLUMN`、pipe-enriched 各支、可写视图各支）**都在**，只漏了普通视图这一支与 `PIPE_ENRICHED_…(1423)`；**master 同样缺失**（不是回合遗漏）。
   - 影响：DDL 返回成功、视图读数正确（用户可见功能"看起来正常"），但 **ConfigRegion 该条日志在 follower 上永远应用不了**，
     每条日志按 apply 重试反复抛 NPE；leader 切换/重启后需重放该日志才能恢复 procedure 状态 ⇒ 该功能在多 CN 集群下**不具备真正的持久化一致性**。
   - 修复建议：`create()` 里补 `case ALTER_VIEW_COLUMN_DATATYPE_PROCEDURE: procedure = new AlterViewColumnDataTypeProcedure(false);`
     （及 pipe-enriched 一支）。
   - 门禁：DT-07 已把它做成硬断言（CN 日志出现 NPE / `Unknown Procedure type: 766` 即 FAIL），取证堆栈写进用例输出。
   - 复现：`bash cases/common/dt_view.sh`（需 ACTIVATED 企业版；本环境 RC6）。RC6 实测 `FAIL fail_flag=3 elapsed=236s`（功能面断言全 PASS）。
2. **不兼容转换的错误码在树/表两个模型不一致（观察）**：树模型 `ALTER TIMESERIES` 返回 **507**（消息里带 per-DataNode 详情
   `Failures: {DataNodeId: x=[TSStatus(code:507, message:The timeseries ... is not compatible ...)]}`），
   表模型 `ALTER TABLE` 返回 **701**（消息 `New type X is not compatible with the existing one Y`）。功能语义一致，仅错误码/文案不同。
3. **树方言查询要用设备路径**（harness 经验，非产品问题）：`select s1 from root.db.dev` ✅；
   写成序列路径 `select s1 from root.db.dev.s1` 会返回 `Empty set`（同一份数据用 `select count(s1) from root.db.**` 能看到行数）。
   已固化到 `lib/cmp.sh` 的 `cmp_fp_series/cmp_vals_series/cmp_rows_series`（自动把序列路径转成设备路径 + 测量名）。
4. **TIMESTAMP 类型测量列只接受"不带引号"的字面量**（RC6 实测，`tools/probe_timestamp.sh`）：
   | 写入写法 | 结果 |
   | --- | --- |
   | `insert ... values (t, 2026-01-01T00:00:00)` | ✅ 成功（按 ISO 字面量解析） |
   | `insert ... values (t, '2026-01-01T00:00:00')` | ❌ `507: ... data type is not consistent, input '2026-01-...'` |
   | `insert ... values (t, '2026-01-01 00:00:02')`（引号+空格） | ❌ 507 |
   | `insert ... values (t, '<epoch ms>')`（引号数字串） | ❌ 507 |
   | `insert ... values (t, <epoch ms>)`（不带引号） | ✅ 成功 |
   | `insert ... values (t, CAST('...' AS TIMESTAMP))` | ❌ `700` 解析失败（`mismatched input 'CAST'`） |
   同一序列上"先无引号成功、再引号写入"仍报 507（E1/E2 对照）⇒ 是**列类型严格校验**，不是首写格式记忆。
   对数据类型变更用例的影响：DT-01 的 `TIMESTAMP` 源序列必须用不带引号的字面量（已修）。
5. **`stop-datanode.sh` / `stop-confignode.sh` 的 `-f` 是 `kill -9`（强制），不带 `-f` 才是 `kill -s TERM`（正常 stop）**
   —— 源码 `sbin/stop-datanode.sh`：`if [ "${force}" == "yes" ]; then kill -9 "$PID" else kill -s TERM "$PID"`。
   DT-09 早期把 `-f` 当"优雅停"，已纠正为：A~D 用**优雅停**（TERM），另加 E 场景专门做 `kill -9` 对照。
6. **表模型 `SELECT` 只返回投影列（不自动带 `Time`）**（harness 关键坑，DT-05/DT-07 的判据曾因此空转）：
   `select v from dtcmix.t1 order by time` 每行只有 1 列（`|11|`），所以按列序号取值的 helper 会取到空串
   —— DT-05/DT-07 曾打印出 `i32=||`、`视图读数=||` 却"PASS"。现在统一用 `lib/cmp.sh` 的
   `cmp_tbl_col_vals / cmp_tbl_coltype / cmp_tbl_rows`（**按表头列名定位**，且行数用 `table_rows` 剔除表头），
   并给"初始值/转换后值"加了硬断言（如 `i32: 42|43| → 42.0|43.0|`、视图 `7|8| → 7.0|8.0|`）。
7. **表模型 Compaction 日志的库名前缀与树模型同形**：`dtprobe-3 [Compaction] Sequence InnerSpaceCompaction task
   finishes successfully` ⇒ `cmp_inner_finish`/`cmp_all_sum`/`cmp_lay` 这些按库统计的 helper 对**表模型库名**
   同样可用（实测 `cmp_inner_finish` 0→2、`cmp_all_sum` 4→3）。
8. **设备名与类型关键字同名时的解析差异（观察）**：`create timeseries root.db.TIMESTAMP.s1 ...` 被解析器拒绝
   （`700: Error occurred while parsing SQL to physical plan: line 1:3...`），而 `INT32/INT64/FLOAT/DOUBLE/BOOLEAN/TEXT/STRING/BLOB/DATE`
   作为设备名都可以正常建/写。DT-01 原先把设备名直接取成类型名，`TIMESTAMP` 那一路全部失败（create=0/insert=0）——
   这是**用例侧命名问题**，不是产品缺陷；已把设备名改成 `t_<TYPE>`。
   顺带核实：TIMESTAMP 序列用 `encoding=PLAIN, compression=UNCOMPRESSED` **也能建成**（此前"编码不兼容"的猜测是错的）。
9. **DML 与"已有库上的 DDL"都不依赖 ConfigNode 多数派（架构事实，DT-09 C 相实测）**：停掉 2/3 个 ConfigNode
   （无 CN 多数派）后，`INSERT` **返回成功且数据真的落盘可见**（行数 +1、指纹一致），
   `CREATE TIMESERIES`（已有库上的 schema 变更）**也返回成功**，恢复 CN 后复查元数据确实存在（`d9probe=INT32`）。
   原因：数据写入走 **DataNode 侧的数据区共识**、`root.*` 库的模式变更走 **DN 上的 SchemaRegion 共识**，
   ConfigNode 主要负责集群级元数据/分区分配。所以"无 CN 多数派"的正确判据是
   **明确结果 + 恢复后元数据/数据一致**，而不是"必须失败"；DT-09 首轮写成"写入必须失败"是**用例判据错误**（已改）。

10. **"磁盘 readonly" 故障注入：整盘 `mount -o remount,ro /data` 在本环境**不可用**（DT-08 实测）**：
   ext4 在**有进程持有可写 fd**（IoTDB 常驻打开 TsFile/WAL/日志）时拒绝整盘转只读，
   报 `mount: /data: mount point is busy.`，`findmnt` 仍是 `rw,relatime`。
   ⇒ 改用"**自绑定挂载 + `remount,ro,bind`**"：`mount --bind <数据根> <数据根>; mount -o remount,ro,bind <数据根>`，
   之后在该子树下**新建/改名/删除都返回 `Read-only file system`**（实测 `touch` 被拒），
   而**已经打开的 fd 仍可写**（该注入方式的已知边界，已写进用例注释）。
   用例**必须硬校验注入生效**（探针写入被拒才算成功），否则判"场景无效 FAIL"——首轮只 WARN，
   出现过"注入没生效却 PASS"的假通过。
11. **只读盘期间产品会把该节点切成 `ReadOnly` 模式，且磁盘恢复可写后不会自动回到 Running（DT-08 实测）**：
   DN 日志 `o.a.i.c.conf.CommonConfig:896 - Set system mode from Running to ReadOnly` +
   `Change system status to ReadOnly! Only query statements are permitted!`，`show cluster` 里该节点状态为 **`ReadOnly`**；
   恢复可写（`remount,rw,bind` + `umount -l` 后探针写入 OK）**仍需重启该 DataNode 才会回到 Running**
   （实测 JVM 起来约 110s，所以恢复等待窗口要给足，用例给了 420s）。
   只读期间的合并会留下预期 ERROR：`[Compaction] INNER_SEQ task meets error`、
   `CompactionRecoverException: failed to delete target file …`（用例已把这些列入 benign）。

12. **观察（待研发确认是否预期）：只读盘导致合并失败后，该 region 在"重开/重启"之前不会重试合并**（DT-08 实测）：
   - 证据链（`results/NEWCHAIN_20261014_212059.out` + .79 的 `log_datanode_compaction.log`）：
     21:29:39 `Sequence InnerSpaceCompaction task starts with 2 files` → 21:29:50
     `INNER_SEQ task meets error: java.nio.file.FileSystemException: …-1-1-0.tsfile: Read-only file system` +
     `[Compaction][Recover] Failed to recover compaction … CompactionRecoverException: failed to delete target file`
     → 之后**磁盘已在 21:30:56 恢复可写（RW_OK）**，但到 21:38 的 8 分钟里该 region **没有任何新的 `task starts`**
     （调度器每 1s 一轮、其它 region 正常合并）→ 21:38:06 region 被重开（`CompactionRecoverManager: recover compaction` →
     `Recover compaction successfully`）→ 21:38:07 新任务开始、**21:38:19 合并成功**（2 文件 → 1 文件）。
   - 源码侧：`CompactionRecoverManager.recoverCompaction()` 只在 **DataRegion 构造/恢复** 路径被调用
     （`CompactionRecoverManager.java:70`），运行期没有"发现残留 `*.inner-compaction.log` 就重试"的入口。
   - 影响：真实场景里"磁盘故障修复后"，若运维不重启该 DataNode，失败过的那批文件会**长期不再被合并**
     （数据不丢、读正常，只是文件数不收敛）。
   - 用例处理：DT-08 先给 **180s 自动重试窗口**（把该行为记成 WARN），不收敛则**重启该 DN 触发 region 恢复**，
     之后要求三副本布局一致（重启后实测 12s 内完成）；这样既如实记录行为，又能验证"恢复后一致"。

## 四、本轮 harness 经验（写新用例前必读）
1. **SQL 里路径层级要分清**：库 `root.dtc` + 设备 `root.dtc.a` + 测量 `s1`；把 `root.dtcX` 当设备用会静默失败
   （`create timeseries`/`insert` 的错误被 `>/dev/null` 吞掉 ⇒ 后面 ALTER 报 508、查询空集）。
   本轮 DT-02/DT-03/DT-09 都踩过，已修为"库名 + 设备名"两段式。
2. **写 TIMESTAMP 测量列的字面量语法**（已由上节实测确定）：只能用**不带引号**的 ISO 字面量或 epoch 毫秒数；
   带引号一律 507。写用例时别再按"字符串字面量"处理 TIMESTAMP。
3. **不要在运行中/用 PowerShell 重写用例文件**：`Set-Content -Encoding UTF8` 会把 UTF-8 中文变成 mojibake
   并破坏部分 ASCII（实测 4 个 DT 用例被写坏，只能整文件重写）。改文件一律用编辑工具或 `sed`（LF）。
4. **负向用例要自带 benign 正则**：故意触发的 `not compatible with the existing one` / `Alter timeseries ... in schema regions failed` /
   `Status code: 507|508|701|616` 属预期噪声，需 `CMP_LOG_BENIGN_EXTRA` 排除，否则收尾日志扫描会误判。
