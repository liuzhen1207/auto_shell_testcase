# 元数据 DDL 清单（TimechoDB / IoTDB 2.0.12.1 RC5 = `v20121rc5_1003_aaf460d` / `aaf460d`）

本文件是"以元数据为测试目的"的第一层产出：**先把被测版本真实支持的 DDL 面钉死**，
用例只写在支持面上，不支持的部分作为**产品边界断言**写进用例（见 `MD-T05`）。

## 0. 清单是怎么得到的（可复现）

两条独立来源交叉验证，避免"凭印象写 SQL"：

1. **语法源**（权威，决定"能解析什么"）
   - 树模型：`iotdb-core/antlr/src/main/antlr4/org/apache/iotdb/db/qp/sql/IoTDBSqlParser.g4`
     - `ddlStatement`（第 38–85 行）穷举了所有 DDL 分支
     - `dclStatement`（91–95）、`utilityStatement`（97–104）
   - 表模型：`iotdb-core/relational-grammar/src/main/antlr4/org/apache/iotdb/db/relational/grammar/sql/RelationalSql.g4`
     - `statement`（第 45 行起）穷举了所有分支
   - 源码目录：`D:\IDEA\timechodb_src\v20121\timechodb`（分支 `rc/2.0.12.1`）
2. **实测**（决定"能执行什么 / 报什么错"）
   ```bash
   # 99.80 上，集群运行时
   cd /data/iotdb/autotest/metadata_skill
   bash tools/probe_ddl.sh                                       # 主清单 docs/ddl_probe_list.tsv
   PROBE_LIST=docs/ddl_probe_list_r3.tsv \
     PROBE_OUT=docs/DDL_PROBE_RESULT_r3.tsv bash tools/probe_ddl.sh
   ```
   - 全量结果：[`DDL_PROBE_RESULT.tsv`](DDL_PROBE_RESULT.tsv)（251 条：OK 166 / ERR 85）
   - 补充结果：[`DDL_PROBE_RESULT_r3.tsv`](DDL_PROBE_RESULT_r3.tsv)（48 条：OK 31 / ERR 17）
   - 每条记录：`label / dialect / sql / status / code / msg`

> 注意：语法里"有"不等于服务端"实现了"。本版本里有**一批语句能过语法、执行时报"未支持"**
> （计算点、服务管理、索引、表改名…），这些是最容易被漏测的边界，已单独列在第 4 节。

---

## 1. 树模型（`sql_dialect=tree`）—— 支持

### 1.1 Database
| 语句 | 备注 |
| --- | --- |
| `CREATE DATABASE <path> [WITH <k>=<int> …]` | 属性仅 `TTL` / `TIME_PARTITION_INTERVAL` / `MAX_SCHEMA_REGION_GROUP_NUM` / `MAX_DATA_REGION_GROUP_NUM`；`NEED_LAST_CACHE=<bool>` |
| `CREATE STORAGE GROUP <path>` / `SET STORAGE GROUP TO <path>` | 等价旧写法 |
| `DROP DATABASE <p>[, <p> …]` / `DELETE STORAGE GROUP …` | **支持一次删多个** |
| `ALTER DATABASE <path> WITH <k>=<v>` | 只有 `NEED_LAST_CACHE` 真正生效 |
| `SHOW DATABASES` / `SHOW STORAGE GROUP` / `… DETAILS` / `SHOW DATABASES <path>` | `DETAILS` 多出 region group 数与 `need_last_cache` 等列 |
| `COUNT DATABASES [<path>]` | |
| `DROP PARTITION <path> <n>` | |

### 1.2 Timeseries / Path
| 语句 | 备注 |
| --- | --- |
| `CREATE TIMESERIES <fullPath> <attrClauses>` | 完整写法 `WITH DATATYPE=…, ENCODING=…, COMPRESSOR=…, MAX_POINT_NUMBER=…`；简化写法 `INT64` |
| `CREATE TIMESERIES … TAGS(k=v) ATTRIBUTES(a=b)` | **`ALIAS=` 不能出现在 CREATE 里**（`alias is not a legal prop.`） |
| `CREATE ALIGNED TIMESERIES <dev>(m1 INT32, m2 FLOAT …)` | 每个测量可带自己的编码/压缩 |
| `(DELETE\|DROP) TIMESERIES <p>[, <p> …]` | 支持通配（`dev.**`）与一次多条 |
| `ALTER TIMESERIES <p> …` | `SET DATA TYPE <type>` / `RENAME TO <newPath>` / `RENAME <attr> TO <attr>` / `SET <k>=<v>` / `DROP <attr>` / `ADD TAGS …` / `ADD ATTRIBUTES …` / `UPSERT [ALIAS=…] [TAGS(…)] [ATTRIBUTES(…)]` |
| `ALTER TIMESERIES [IF EXISTS] <p> SET STORAGE_PROPERTIES k=v …` | 改编码/压缩 |
| `SHOW TIMESERIES [<path>] [WHERE …] [ORDER BY TIMESERIES] [LIMIT/OFFSET]` | 行内含 `datatype/encoding/compressor/tags/attributes/alias/dead` 等列 |
| `SHOW LATEST TIMESERIES` / `SHOW INVALID TIMESERIES` | **`INVALID` 能看到 `RENAME TO` 留下的死路径**（很有价值的元数据判据） |
| `SHOW DEVICES [<path>] [WITH DATABASE] [WHERE DEVICE CONTAINS '…' \| TEMPLATE = '…']` | |
| `COUNT TIMESERIES [<path>] [WHERE …] [GROUP BY LEVEL=n]` | |
| `COUNT NODES <path> LEVEL = <n>` | |
| `COUNT DEVICES [<path>]` | |
| `SHOW CHILD PATHS [<path>]` / `SHOW CHILD NODES [<path>]` | |

### 1.3 Schema Template
| 语句 | 备注 |
| --- | --- |
| `CREATE SCHEMA\|DEVICE TEMPLATE <name> [ALIGNED] [(m1 INT32, …)]` | **`ALIGNED` 必须在名字之后、测量列表之前** |
| `SHOW SCHEMA\|DEVICE TEMPLATES` | **必须用复数 `TEMPLATES`**；单数 `TEMPLATE` 是语法错误 |
| `SHOW NODES IN SCHEMA\|DEVICE TEMPLATE <name>` | |
| `ALTER SCHEMA\|DEVICE TEMPLATE <name> ADD (m INT32, …)` | **只有 ADD，没有"删除测量"** |
| `SET SCHEMA\|DEVICE TEMPLATE <name> TO <path>` | |
| `UNSET SCHEMA\|DEVICE TEMPLATE <name> FROM <path>` | |
| `SHOW PATHS [<path>] USING SCHEMA\|DEVICE TEMPLATE <name>` | 已创建设备的前缀 |
| `SHOW PATHS SET SCHEMA\|DEVICE TEMPLATE <name>` | 挂载点（还没建设备） |
| `CREATE TIMESERIES (OF\|USING) SCHEMA\|DEVICE TEMPLATE ON <path>` | |
| `(DELETE\|DROP) TIMESERIES OF \| DEACTIVATE SCHEMA\|DEVICE TEMPLATE [<name>] FROM <p>` | |
| `DROP SCHEMA\|DEVICE TEMPLATE <name>` | |

### 1.4 TTL
`SET TTL TO <path> <ms|INF>`、`UNSET TTL (TO|FROM) <path>`、`SHOW TTL ON <p>[, <p>]`、`SHOW ALL TTL`

### 1.5 View / Trigger / CQ / Function
| 语句 | 备注 |
| --- | --- |
| `CREATE VIEW <targetPaths> AS <sourcePaths \| SELECT … FROM …>` | 源可以是路径序列 |
| `SHOW VIEW [<path>] [WHERE …]` / `DROP VIEW <p>[, <p>]` | |
| `ALTER VIEW <p> RENAME TO …` | **不支持**（701 `Renaming view is not supported.`） |
| `CREATE [STATELESS\|STATEFUL] TRIGGER <n> BEFORE\|AFTER INSERT\|DELETE ON <p> AS '<class>' [USING URI '…'] [WITH (…)]` | 类型关键字在 `TRIGGER` **之前** |
| `DROP TRIGGER <n>` / `SHOW TRIGGERS` | |
| `CREATE (CONTINUOUS QUERY\|CQ) <id> [RESAMPLE …] [TIMEOUT POLICY …] BEGIN <selectStatement> END` | 必须有 `EVERY`/`GROUP BY` 间隔，且 query body 必须带 `INTO` |
| `DROP (CONTINUOUS QUERY\|CQ) <id>` / `SHOW (CONTINUOUS QUERIES\|CQS)` | |
| `CREATE FUNCTION <n> AS '<class>' [USING URI '…']` / `DROP FUNCTION <n>` / `SHOW FUNCTIONS` | |

### 1.6 集群 / 会话 / 观测
`SHOW CLUSTER [DETAILS]`、`SHOW CLUSTERID`、`SHOW DATANODES`、`SHOW CONFIGNODES`、`SHOW AVAILABLE URLS`、
`SHOW REGIONS`、`SHOW SCHEMA REGIONS`、`SHOW DATA REGIONS OF DATABASE <p>`、`SHOW REGIONS ON NODEID <n>`、
`SHOW SCHEMA\|DATA REGIONID WHERE DATABASE=<p>`、`SHOW TIMESLOTID\|TIMEPARTITION WHERE DEVICE=<p>|REGIONID=<n>`、
`SHOW MIGRATIONS`、`CANCEL ALL MIGRATIONS`、`SHOW VARIABLES`、`SHOW VERSION`、`SHOW ACTIVATION`、`SHOW SYSTEM INFO`、
`SHOW QUERIES`、`SHOW CURRENT_USER`、`SHOW CURRENT_SQL_DIALECT`、`SHOW CURRENT_TIMESTAMP`、`SHOW AINODES`、
`FLUSH`、`CLEAR [SCHEMA|QUERY|AUTH|ALL] CACHE`、`SET CONFIGURATION '…'='…'`、`SETTLE <p>`、`KILL QUERY`、
`SHOW SPACE QUOTA`、`SHOW THROTTLE QUOTA`、`SHOW USER QUOTA`（后三者需 `quota_enable=true`）

### 1.7 权限（DCL）
`CREATE USER <u> '<pw≥12>'`、`CREATE ROLE <r>`、`ALTER USER <u> SET PASSWORD '<pw>'`、
`ALTER USER <u> SET MAX_SESSION_PER_USER <n>` / `MIN_SESSION_PER_USER`、`ALTER USER <u> RENAME TO <u2>`、
`ALTER USER <u> ACCOUNT UNLOCK`、
`GRANT <priv,…> ON <p>[, <p>] TO USER <u>|ROLE <r> [WITH GRANT OPTION]`、
`REVOKE <priv,…> ON <p>[, <p>] FROM USER <u>|ROLE <r>`、
`GRANT ROLE <r> TO <u>`（**不能写 `TO USER`**）、`REVOKE ROLE <r> FROM <u>`、
`DROP USER <u>`、`DROP ROLE <r>`、
`LIST USER [OF ROLE <r>]`、`LIST ROLE [OF USER <u>]`、`LIST PRIVILEGES OF USER <u>|ROLE <r>`
> **`SHOW USER` 不存在**（它被解析成 `SHOW USER QUOTA` 的前缀，报 700 `missing QUOTA at '<EOF>'`）。

---

## 2. 表模型（`sql_dialect=table`）—— 支持

| 类别 | 语句 |
| --- | --- |
| 库 | `CREATE DATABASE [IF NOT EXISTS] <db> [WITH (…)]`、`ALTER DATABASE [IF EXISTS] <db> SET PROPERTIES k=v`、`DROP DATABASE [IF EXISTS] <db>`、`SHOW DATABASES [DETAILS]`、`SHOW CREATE DATABASE <db>`、`COUNT DATABASES`、`USE <db>` |
| 表 | `CREATE TABLE [IF NOT EXISTS] <t> (列定义…) [WITH (ttl=…, need_last_cache=…)]`、`DROP TABLE [IF EXISTS] <t>`、`SHOW TABLES [DETAILS] [FROM\|IN <db>]`、`(DESC\|DESCRIBE) <t> [DETAILS]`、`SHOW CREATE TABLE <t>` |
| 列 | `ALTER TABLE <t> ADD COLUMN [IF NOT EXISTS] …`、`DROP COLUMN [IF EXISTS] <c>`、`ALTER COLUMN <c> SET DATA TYPE <type>`、`SET PROPERTIES …`、`COMMENT ON TABLE\|VIEW\|COLUMN … IS '…'` |
| 视图 | `CREATE [OR REPLACE] VIEW <v> (列定义) [WITH (…)] AS <prefixPath 需以 ** 结尾>`、`CREATE VIEW <v> AS SELECT …`、`SHOW [TREE\|WRITABLE] VIEWS [FROM <db>]`、`SHOW CREATE VIEW <v>`、`DROP VIEW [IF EXISTS] <v>`、`ALTER VIEW … RENAME TO / ADD COLUMN / DROP COLUMN / SET PROPERTIES / ALTER COLUMN` |
| 设备 | `SHOW DEVICES FROM <表名> [WHERE …]`、`COUNT DEVICES FROM <表名> [WHERE …]`（**FROM 后面是表不是库**） |
| information_schema | `databases` / `tables` / `columns` / `views` / `services` / `functions`（`indexes` **不存在**） |
| 观测 | `SHOW CONFIGURATION`、`SHOW CURRENT_DATABASE`、`SHOW CURRENT_USER`、`SHOW CURRENT_SQL_DIALECT`、`SHOW CURRENT_TIMESTAMP`、`SHOW CLUSTER`、`SHOW DATANODES`、`SHOW CONFIGNODES`、`SHOW REGIONS`、`SHOW QUERIES`、`SHOW VERSION`、`SHOW VARIABLES`、`SHOW ACTIVATION`、`SHOW AINODES` |
| 函数/服务 | `SHOW FUNCTIONS`、`CREATE/DROP FUNCTION`、`SHOW SERVICES` |

---

## 3. 树 / 表模型的差异（写用例时的坑）

| 主题 | 树模型 | 表模型 |
| --- | --- | --- |
| 库名 | 必须 `root.` 前缀 | 普通标识符 |
| 建库幂等 | `IF NOT EXISTS` **不支持** | `IF NOT EXISTS` **支持** |
| 删库幂等 | `IF EXISTS` **不支持** | `IF EXISTS` **支持** |
| 删除语法 | `DROP DATABASE a, b` 支持多路径 | 一次一个 |
| 表/设备 | 设备是路径一级 | `SHOW TABLES` 需会话库或 `FROM <db>`；`SHOW DEVICES` 需 `FROM <表>` |
| 改列 | `ALTER TIMESERIES … SET DATA TYPE` | `ALTER TABLE … ALTER COLUMN … SET DATA TYPE` |
| 重命名 | 时序可 `RENAME TO`，视图**不行** | 表和列**都不行**（701） |
| 索引 | — | 语法有（`CREATE INDEX idx ON t c1, c2`，**列不套括号**），但执行报"未支持" 701 |
| 命名空间 | `root.*`（`SHOW DATABASES` 只列 `root.*`） | 独立命名空间（不含 `root.__system`） |

---

## 4. 明确"不支持 / 未实现"（作为边界断言写进用例）

| 语句 | 错误码 | 消息（实测） |
| --- | --- | --- |
| `CREATE DATABASE IF NOT EXISTS …`（树） | 700 | `mismatched input 'IF' expecting ROOT` |
| `DROP DATABASE IF EXISTS …`（树） | 700 | `mismatched input 'IF' expecting ROOT` |
| `CREATE TIMESERIES IF NOT EXISTS …` | 700 | `no viable alternative at input 'CREATE TIMESERIES IF'` |
| `CREATE TIMESERIES a INT32, b INT64`（一次多条） | 700 | `mismatched input ',' expecting {<EOF>, ';'}` |
| `CREATE TIMESERIES … COMMENT='…'` | 507 | `comment is not a legal prop.` |
| `CREATE TIMESERIES … ALIAS=…` | 507 | `alias is not a legal prop.` |
| `ALTER DATABASE … WITH TTL=…` | 525 | `Failed to alter database. Doesn't support ALTER TTL yet.` |
| `ALTER DATABASE … WITH TIME_PARTITION_INTERVAL=…` | 525 | `… Doesn't support ALTER TimePartitionInterval yet.` |
| 建库带 `MAX_*_REGION_GROUP_NUM`（默认策略下） | 525 | `… can only be set when …extension_policy is CUSTOM.` |
| `SHOW SCHEMA TEMPLATE`（单数） | 700 | `no viable alternative at input 'SHOW SCHEMA TEMPLATE'` |
| `CREATE SCHEMA TEMPLATE … (…) ALIGNED`（顺序错） | 700 | `extraneous input 'ALIGNED'` |
| `ALTER SCHEMA TEMPLATE … DROP (…)` | 700 | `mismatched input 'DROP' expecting ADD` |
| `CREATE SCHEMA TEMPLATE IF NOT EXISTS …` | 700 | `extraneous input 'IF' expecting {ID, QUOTED_ID}` |
| `ALTER VIEW … RENAME TO …` | 701 | `Renaming view is not supported.` |
| `START/STOP TRIGGER …` | 700 | `This operation type is not supported` |
| `CREATE CALCULATION POINT …` / `SHOW CALCULATION POINTS …` | 700 | `This operation type is not supported` |
| `CREATE/START/STOP/DROP SERVICE …` | 305 | `Service management SQLs are not supported now!` |
| `SHOW FLUSH INFO` / `SHOW QUERY RESOURCE` | 700 | `This operation type is not supported` |
| `SHOW LOCK INFO <path>` | 700 | `This operation type is not supported` |
| `SHOW SPACE/THROTTLE/USER QUOTA`（未开配额） | 701 | `Limit configuration is not enabled…` |
| AI 相关（`SHOW MODELS` / `SHOW AI_DEVICES`） | 1011 | `Failed to connect to AINode…`（本环境未部署 AINode） |
| 触发器加载不存在的类 | 1303/1304 | `Failed to load class '…'` / `Failed to get executable for Trigger` |
| `ALTER TABLE … RENAME TO`（表） | 701 | `The renaming for base table is currently unsupported` |
| `ALTER TABLE … RENAME COLUMN`（表） | 701 | `The renaming for base table column is currently unsupported` |
| `CREATE/DROP/SHOW INDEX`（表） | 701 | `… is not supported yet.` |
| `information_schema.indexes` | 550 | `Table 'information_schema.indexes' does not exist.` |
| `SHOW REGION ID` / `SHOW TIME SLOT`（表方言） | 701 | `… is not supported yet.` |
| 表列带 `ATTRIBUTES(...)` | 700 | `mismatched input 'ATTRIBUTES'. Expecting: ')', ','` |
| `SET PROPERTIES ttl='3600000'`（带引号数字） | 701 | `ttl value must be 'INF' or a long literal…` |
| `CREATE TABLE … WITH (comment='…')` | 701 | `Table property 'comment' is currently not allowed.` |
| 表视图源不以 `**` 结尾 | 701 | `The last node must be '**'` |
| `SHOW TABLES`（会话未指定库） | 701 | `database is not specified` |
| `SHOW DEVICES FROM <库>`（表） | 701 | `Database must be specified when session database is not set` |
| `GRANT ROLE r TO USER u` | 700 | `extraneous input '<u>' expecting {<EOF>, ';'}`（正确写法 `TO <u>`） |
| `SHOW USER` | 700 | `missing QUOTA at '<EOF>'`（应为 `LIST USER`） |

---

## 5. 写用例前必须知道的行为细节

1. **`SHOW DATA REGIONS` 是懒创建的**：库里只有时序、没有写入数据时为空；写入 + `FLUSH` 后才出现 DataRegion
   （`MD-T04` 就以此作为判据）。
2. **`ALTER TIMESERIES … RENAME TO` 会留下"死路径"**：旧路径从 `SHOW TIMESERIES` 消失，但在
   `SHOW INVALID TIMESERIES` 里仍可查到（末列给出新路径）。这是元数据迁移的正面证据（`MD-T02`）。
3. **树模型建时序会自动建库**：`CREATE TIMESERIES root.autodb.d1.s1 INT32` 会顺带创建 `root.autodb`。
4. **在已有库前缀下不能再建库**：已存在 `root.db` 时 `CREATE DATABASE root.db.sub` 报 `501`。
5. **`SHOW DATABASES DETAILS` 是 `SHOW DATABASES` 的加宽版**（多出 region group 数、`need_last_cache`），
   可以用来验证 `ALTER DATABASE … WITH NEED_LAST_CACHE=…` 是否真的生效。
6. **`SHOW CLUSTER` 末列是 `ActivateStatus`**（本环境 `ACTIVATED`）；`SHOW CLUSTER DETAILS` 会插入
   internal/consensus 端口等列，**列数变多、行数不变**。
7. **模板占用会影响删库/卸模板**：设备还在用时 `UNSET` 报 `515`；模板挂载中删库前要先卸载。
8. **CLI 对成功的 DDL 也会打印 `Msg: The statement is executed successfully.`** ——
   判定"是否报错"不能只看有没有 `Msg:`（harness 里 `is_error()` 已按此实现，见 `lib/common.sh`）。
9. **`SHOW PIPES` / `SHOW PIPE PLUGINS` 的结果表里含 `Exception` 字样**（列名/插件信息），
   同样是"看到 Exception 就当失败"的陷阱（本轮踩到并修掉）。
10. **表模型 `USE <db>` 必须走同一会话**：`SHOW TABLES` / `SHOW DEVICES` / 相对表名都依赖会话库；
    harness 用 `sql_on <node> tblsess "USE db;;SHOW TABLES;"`（`;;` 分隔语句，走同一个 CLI 连接）。
11. **`SHOW VERSION` 的 commit 必须与安装目录名一致**（`v20121rc5_1003_aaf460d` → `aaf460d`），
    可以当作"环境有没有跑错版本"的自检（`MD-T04` 已断言）。

---

## 6. 后续可继续分解的方向（本清单已铺好路）

- 模板 + 视图 + 触发器在同一库上的**组合元数据**一致性
- 触发器/UDF 用**真实 jar** 注册后的元数据（需要准备 jar 包）
- 权限矩阵（`ALL/READ/WRITE/SYSTEM/SECURITY/AUDIT` × 路径通配）与 `LIST PRIVILEGES` 的对应关系
- 配额语句（`quota_enable=true` 时）的元数据
- 大规模元数据（万级时序/表）下 `SHOW`/`COUNT` 的正确性与耗时
- 元数据 DDL 与**并发**（同时建/删同库）的一致性
