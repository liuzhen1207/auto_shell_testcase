# TTL 自动化测试用例设计（树模型 / 表模型）

- 被测版本：TimechoDB 2.0.12.1 RC4（`v20121rc4_0924_18cf11b`，Build 18cf11b）
- 环境：99.80 驱动 + 3C3D（CN/DN 同在 .77/.78/.79），SchemaRegion 与 DataRegion 均 3 副本
- 共识协议：默认 `org.apache.iotdb.consensus.iot.IoTConsensus`；可用参数显式切换 `…IoTConsensusV2`
- 资料依据：`D:\IDEA\deepseek\TTL\*.docx`（设备粒度 TTL（新）、表模型总体设计、TTL 删除审计技术设计）、
  `D:\IoTDB\MyTestCase\iotdb_sql_testcase\iotdb-sql-testcase\{tree,table}`（otf SQL 用例的期望值）、
  源码 `D:\IDEA\timechodb_src\v20121\timechodb`、以及 2026-09-29 在 99.80 RC4 上的两轮实测勘察。

## 1. 已确认的 TTL 语义（实测 + 文档）

### 1.1 树模型（设备粒度 TTL）
| 项 | 结论 |
| --- | --- |
| 设置 | `SET TTL TO <prefixPath> <ms>`；`<prefixPath>` 只能是前缀路径（中间不能有 `*`，且以 `**` 结尾），或**不带星**的 database / device 路径 |
| 单位 | 毫秒，**不随** `timestamp_precision` 换算 |
| 关闭/无限 | `SET TTL TO <path> INF`；`UNSET TTL FROM <path>`（新）/`UNSET TTL TO <path>`（旧）取消；取消根路径后回到配置文件默认 TTL |
| 非法路径 | `SET TTL TO root.t1.g1.* 1000`、`SET TTL TO root.t1.**.d1 1000` → `303 Illegal pattern path: …, pattern path should end with **` |
| 查询 | `SHOW ALL TTL`（全部规则，列 `Device | TTL(ms)`）、`SHOW TTL ON <pathPattern>`、`SHOW DEVICES`（每设备必有 TTL，可为 `INF`）、`SHOW DATABASES`（**无** TTL 列） |
| 生效对象 | 规则挂在**设备**上；对不存在的设备设 TTL 合法（不校验存在性）；对序列路径设 TTL 不会命中任何设备 → 不生效 |
| 优先级 | 一个设备命中多条规则时，**更长/更精确**的规则优先（device 级 > group 级 > database 级 > `root.**`） |
| 上限 | 最多 1000 条规则，超限报 621（文档） |
| 生效方式 | 查询侧立即过滤（ScanNode 取本地 TTL 缓存）；**物理删除延迟**，由 Settle 合并任务/被动合并完成，可能"调小或取消 TTL 后旧数据重新可见" |
| 未知/风险 | `SHOW TTL ON <path>.**` 在 RC4 上命中已知缺陷 **TDB-444**（把权限范围路径 `root.**` 下发，返回不相干的全局规则）→ 用例**不**用该语句做严格断言 |

### 1.2 表模型（表/视图/库粒度 TTL）
| 项 | 结论 |
| --- | --- |
| 建库 | `CREATE DATABASE <db> WITH (ttl=<ms>)`；`ALTER DATABASE <db> SET PROPERTIES TTL=<ms>|'INF'` |
| 建表 | `CREATE TABLE <t> (<col> STRING TAG, <col> DOUBLE FIELD …) WITH (TTL=<ms>)`；列约束关键字是 **`TAG` / `FIELD` / `ATTRIBUTE`**（不是 `ID`/`MEASUREMENT`） |
| 改表 | `ALTER TABLE <t> SET PROPERTIES ttl=<ms>` / `ttl='INF'` / `ttl=default` |
| 视图 | `CREATE [OR REPLACE] [WRITABLE] VIEW … WITH (ttl=…)`、`ALTER VIEW … SET PROPERTIES ttl=…` |
| 继承 | 建表未写 TTL → 继承**当前库** TTL；库 TTL 改动**不影响**已建表；`ttl=default` 表示继承 |
| 查询 | `SHOW TABLES`（列 `TableName | TTL(ms)`）、`SHOW DATABASES DETAILS`（含 `TTL(ms)`）、`SELECT database, table_name, "ttl(ms)" FROM information_schema.tables`、`SELECT database, "ttl(ms)" FROM information_schema.databases`（列名含括号，**必须加双引号**） |
| 参数值 | `ttl=-1000` → `701 ttl value must be equal to or greater than 0`；`ttl=0.001` → `701 ttl value must be a LongLiteral`；`ttl=9223372036854775808` → `700 Invalid numeric literal` |
| 过期写入 | 写入时间戳早于 `now()-ttl` 时**直接拒写**（607，历史用例期望；本环境按实测为准） |
| OBJECT | 列类型 `OBJECT FIELD`；必须用 `to_object(true, 0, X'62')` 构造，裸元组 `(true,0,X'..')` 报错。**表模型支持 OBJECT，树模型不支持** |

### 1.3 清理相关配置（`iotdb-system.properties`，实测可写入并生效）
| 参数 | 本次用例取值 | 作用 |
| --- | --- | --- |
| `ttl_check_interval` | `5000`（默认 7200000） | 后台 TTL 检查间隔（ms），**非热加载**，须启动前写 |
| `max_expired_time` | `60000` | 文件内设备过期超过 `min(max_expired_time, ttlThreshold)` → 强制 Settle 清理；**RC4 的 `ttlThreshold` 被误写成 `ttl`，所以默认等价于"过期即清理"**（见 `docs/CALIBRATION.md` 0.6） |
| `expired_data_ratio` | `0.000001`（极小正数） | 过期设备比例阈值；⚠️ RC4 只在 `max_expired_time=Long.MAX_VALUE` 时才真正生效。**不要用 0.0**：会让零脏数据文件每个周期被 settle 重写（写放大） |
| 物理删除条件 | 文档 + 实测 | 文件内**设置了 TTL 的设备全部过期**才可能整文件清理；日志 `[TTL] <db>-<region> Totally select N all-outdated files and M partial-outdated files.` |

### 1.4 实测踩到的坑（写用例必须遵守）
1. **CLI 不能解析 `now()-3000`**：树模型 `INSERT … VALUES(now()-3000, …)` → `700 mismatched input '-'`；表模型 → `305 ArithmeticBinaryExpression cannot be cast to StringLiteral`。→ 用例一律用**显式 epoch 毫秒**（脚本里算好 `$(( $(date +%s%3N) - N ))`）。
2. **`sleep N;` 是 otf 工具的伪指令，不是 SQL**：直接喂给 CLI 会报 700。→ 用例用真实 `sleep`（shell）。
3. `information_schema` 的列名是 `ttl(ms)`，**必须** `"ttl(ms)"` 引起来。
4. 表模型列约束是 `TAG/FIELD`；OBJECT 必须 `to_object(...)`。
5. 树模型 `SHOW DEVICES` 会带上系统设备（`root.__audit.password_history._0` 等），断言时要过滤。
6. `SET TTL` 后要先 `FLUSH`，过期清理才针对已落盘文件；查询过滤则立即生效（不需要 flush）。

## 2. 用例矩阵

维度：**模型**（树/表）× **粒度**（database / 表、视图 / 设备、序列）× **验证点**（基本功能、参数值、过期清理正确性）× **协议**（IoTConsensus 默认、IoTConsensusV2）。

| ID | 用例脚本 | 模型 | 粒度 | 覆盖点 |
| --- | --- | --- | --- | --- |
| TT-01 | `cases/tree/ttl_tree_basic.sh` | 树 | database / 设备 / 序列 | SET/UNSET/SHOW 基本功能；前缀路径规则与 303；INF 与回退默认；规则优先级与继承；`SHOW DEVICES` TTL；删库/删序列后规则保留；1000 条上限（可选，耗时） |
| TT-02 | `cases/tree/ttl_tree_expire.sh` | 树 | 设备 / 序列 | 过期可见性过滤；TTL 内保留 / TTL 外消失（边界双点）；FLUSH 后物理删除（TsFile 计数下降）；`[TTL]` 日志计数；取消 TTL 后新数据不再被清；跨库/未设 TTL 库不受影响 |
| TB-01 | `cases/table/ttl_table_basic.sh` | 表 | 库 / 表 / 视图 | 建库/建表/改表 TTL；`ttl='INF'`/`default`；继承与解耦；`SHOW TABLES` / `SHOW DATABASES DETAILS` / `information_schema`；参数与非法值（701/700）；视图 TTL |
| TB-02 | `cases/table/ttl_table_expire.sh` | 表 | 表 / 视图 | 过期行过滤；TTL 内外边界；FLUSH 后物理删除；改小/取消 TTL 的行为；视图读过期数据 |
| TB-03 | `cases/table/ttl_table_object.sh` | 表 | 表 / OBJECT 列 | OBJECT 列 + TTL：`to_object` 写入、查询、过期后不可见、object 文件随 TTL 清理（目录/日志证据）；树模型不支持 OBJECT 的负向验证 |
| TT-03 | `cases/tree/ttl_tree_dml.sh` | 树 | 库 / 设备 / 序列 | **大数据量**（默认 10 设备 × 200 行 = 2000 点，多值 INSERT）→ 范围 `DELETE FROM dev.** WHERE time<=T` → `DELETE TIMESERIES dev.**`（删设备元数据+数据）→ TTL 过期清理（含物理删除证据）→ `DROP DATABASE` 重建后 TTL 规则保留并对新数据生效 |
| TB-04 | `cases/table/ttl_table_dml.sh` | 表 | 库 / 表 | **大数据量**（默认 2000 行）→ 范围 `DELETE FROM t WHERE time<=T` → `DELETE DEVICES FROM t WHERE dev='dK'`（返回 `num_of_deleted_devices`）→ TTL 过期清理 → `DROP DATABASE` 重建后新库 TTL 继承、新表 TTL 生效 |
| TT-05 | `cases/tree/ttl_show_ttl_scope.sh` | 树 | `root.**`/库/设备 | **TDB-444 回归门禁**：`SHOW TTL ON <db>.<dev>.**` 把权限范围路径当查询路径下发 ⇒ 返回不相干全局规则。判据：输出里**不得**出现不相干库规则 / `root.**` 全局规则（缺陷版本会把所有规则都吐出来，"包含本设备规则"类断言抓不到），并含库级 `.**` 同类检查与"无 `.**` 精确路径"对照组 |
| TP-01 | `cases/common/ttl_param_effect.sh` | 树 | 集群参数 | **TTL 参数值/热加载/重启生效**：① `ttl_check_interval` 实测周期（按 `<db>-<region>` 相邻两条时间差取中位数）≈ 配置值、`SET CONFIGURATION` 返回 `restart is required ...`、重启后新值生效；② `enable_seq/unseq_space_compaction` 热加载门控 TTL 物理清理；③ Part C 三相隔离 `expired_data_ratio`（判据 = **partial 候选行数**；r1 出现 partial 即 **TDB-452** 门禁），每相逐节点用 table 方言 `show configuration` 核对生效值 |
| TP-02 | `cases/common/ttl_cleanup_threshold.sh` | 树 | 文件级 | **清理阈值矩阵 + 写放大守卫**：A 全过期文件 → FULLY_DIRTY 整文件删除（TsFile 归零）；B 部分过期 + `max_expired_time=INF` + ratio=极小正数 → 按比例门控清理；C 清理完成后零脏数据文件在 4 个检查周期内**不得**再被 settle（回归门禁）；D `expired_data_ratio=0.0` 时零脏数据文件被反复重写 → **FAIL 即缺陷复现（写放大）** |
| TP-03 | `cases/common/ttl_param_effect_mode.sh` | 树 | 集群参数 | **`expired_data_ratio` 生效方式与数值语义**（10 设备保证"部分过期"可观测）：A `M=INF`+ratio=1e-6 → 被清理（基线）；B 不重启热改 ratio=0.99 → 仍按旧值清理，且 `SET CONFIGURATION` 返回 `restart is required`（本构建 **restart-only**）；C 重启后 ratio=0.99 → 不清理 + 逐节点核对生效值。⚠️ 教训：**不要用"被 DELETE 删空的设备"来测阈值**——该设备常独占一个 TsFile，`deletedDeviceRatio=1` 直接 FULLY_DIRTY，与参数无关 |
| TT-04 | `cases/tree/ttl_tree_scope.sh` | 树 | `root.**`/库/设备/序列 | **作用域语义**：三级继承与覆盖（`root.**`→库→设备，`SHOW DEVICES` 看生效值、`SHOW ALL TTL` 看显式规则、`SHOW TTL ON` 看单路径）；规则热更新对**已写数据**立即生效；`UNSET` 后未被物理删除的过期数据**重新可见**（前段关 compaction 观察、后段打开验证物理清理仍需 compaction）；预置规则作用于后创建的设备；边界 `TTL=0`/负数(700)/非法 pattern(700)/无规则 UNSET(508)/`Long.MAX` |
| TB-05 | `cases/table/ttl_table_cleanup.sh` | 表 | 表/文件级 | **表模型清理阈值 + 写放大守卫**（与 TP-02 对应，验证表模型走 `getTTLForTable` 同一套逻辑）：A 过期表数据被清理、同库 `ttl='INF'` 表数据完好；C 零脏数据文件不得被反复 settle；D `ratio=0.0` 写放大复现（**FAIL 即缺陷复现**） |
| 通用收尾 | `lib/common.sh` | 全部 | 集群 | ① 等 **sync lag 归 0**（抓每个 DN 自身 exporter 的 `iot_consensus{type="syncLag"}`）；② **副本一致性**（各副本各查一次；逐个停 DN 再查，结果需一致）；③ **CN/DN 异常日志分析**（常见异常 + TTL 相关异常）；④ 失败时打包日志 |

> 数据规模与 TTL 窗口都可用环境变量调：`DATA_DEVICES`、`DATA_ROWS`、`TTL_CASE_MS`（默认 30000，须大于节点间时钟偏差）。
> DELETE 之后统一用 `wait_scalar_tree` / `wait_scalar_table` 轮询等待副本应用变更（DELETE 走共识，立即 count 会偏大）。

每个用例都：
- 从 `conf/env.conf` 读环境；`USE_FRAMEWORK=1` 时复用 99.80 的 `clean_env/prepare_env`，否则用自带的 ssh 启停逻辑（便于迁移到别的环境）。
- 用 `--consensus IoTConsensus|IoTConsensusV2` 切换共识协议（默认 IoTConsensus），结果写入 `results/test_result.csv`（含 build、consensus、用例名、结果、耗时、fail 数、消息）。
- 失败时把 CN/DN 日志打包到 `results/artifact_<case>_<runid>/logs/`，并保留每一步的 SQL 原始输出。

## 3. 断言策略

- **值断言**优先用 `SHOW ALL TTL` / `SHOW TABLES` / `SHOW DEVICES` / `information_schema`（结构化、易解析），不用 RC4 上已知有缺陷的 `SHOW TTL ON <path>.**`。
- **清理正确性**用三条互补证据：
  1. 查询可见性（过期数据查不到，未过期仍在）——立即可见；
  2. 磁盘 TsFile 计数（清理前 ≥1，清理后下降/归零）——需要等 TTL 检查 + Settle；
  3. DN 日志 `[TTL] … Start ttl and modification checking` 与 `Totally select N all-outdated files and M partial-outdated files`——证明 TTL 任务确实选中了过期文件。
- **边界**用双点法：同一设备写 `now()-TTL+Δ`（保留）与 `now()-TTL-Δ`（消失），Δ 取 TTL 的 10% 或 1s（取小者）。
- 期望值尽量从"当前时间"推导，不写死绝对时间戳，保证跨环境可重跑。

## 4. 迁移到其他环境

只改 `conf/env.conf`：
```
CLUSTER_NODES="root@host1 root@host2 root@host3"   # 每台既是 CN 也是 DN（3C3D）
DB_PARENT_DIR=/data/iotdb ; SHELL_CLIENT_DIR=/data/iotdb/testdb ; V_TESTDB=<版本目录>
ROOT_PW=... ; CLUSTER_NAME=timecho
SCHEMA_RF=3 ; DATA_RF=3 ; DATA_CONSENSUS=IoTConsensus
USE_FRAMEWORK=1|0      # 1=复用目标机的 autotest 框架脚本；0=用 skill 自带启停
```
`lib/common.sh` 不依赖 99.80 专有路径；`tools/run_all.sh` 可依次跑全部用例并按模型/协议汇总。
