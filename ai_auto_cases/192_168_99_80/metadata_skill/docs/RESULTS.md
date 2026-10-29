# 元数据 DDL 自动化测试 skill —— 实跑报告（TimechoDB 2.0.12.1 RC5）

| 项 | 值 |
| --- | --- |
| 被测版本 | `v20121rc5_1003_aaf460d`（2.0.12.1，commit `aaf460d`） |
| 集群 | 3C3D：`192.168.99.77/78/79`，每台 1 ConfigNode + 1 DataNode，3 副本，`IoTConsensus` |
| 驱动/框架机 | `192.168.99.80`（免密到三台节点），skill 路径 `/data/iotdb/autotest/metadata_skill` |
| 运行命令 | `bash tools/run_all.sh --set all` |
| 时间窗（P0-P3 首轮 10 条） | 2026-10-10 11:51:55 → 12:12:00（约 20 分钟） |
| 时间窗（含 P4 的 13 条全量，最终轮） | 2026-10-10 21:29:46 → 21:59:15（约 30 分钟，含集群准备 140s） |
| **结论** | **13 / 13 PASS，fail_flag 全 0，rc 全 0** |
| 证据 | `results/test_result.csv`、`results/SUITE_all_final.out`、`results/final13/MD-*_run.out` |
| P4 三条（UDF/Trigger、权限矩阵、规模） | 见 [`P4_RESULTS.md`](P4_RESULTS.md) |

> 10 条 → 13 条的增量就是 `docs/PLAN.md` P4 的三项优先方向：`MD-U01` UDF/Trigger 全链路、
> `MD-C03` 权限矩阵、`MD-S01` 元数据规模。三条在 13 条全量里同样 PASS。

---

## 1. 逐用例结果

| 用例 | 覆盖 | 结果 | 耗时 | 收尾三件套 |
| --- | --- | --- | --- | --- |
| **MD-T01** `md_tree_database` | 建库 3 种写法、`SHOW DATABASES [DETAILS] [<path>]`、`COUNT DATABASES`、`ALTER`（支持/不支持）、`DROP` 单/多路径、重复建 501、删不存在 508、非法属性 700、`IF NOT EXISTS` 700、子库 501 | **PASS** | 77s | sync lag 归零 ✓ 副本一致 ✓ 日志无异常 ✓ |
| **MD-T02** `md_tree_timeseries` | 建时序（完整/简化/属性/TAGS+ATTRIBUTES/对齐）、`SHOW TIMESERIES`（路径/WHERE DATATYPE/WHERE TAGS/LIMIT/ORDER）、`COUNT TIMESERIES`（全量/`*.*`/`GROUP BY LEVEL`）、`COUNT NODES`、`SHOW DEVICES`（路径/`WITH DATABASE`/`WHERE DEVICE CONTAINS`）、`COUNT DEVICES`、`CHILD PATHS/NODES`、ALTER 全系列、`RENAME TO` 死路径 | **PASS** | 101s | ✓ ✓ ✓ |
| **MD-T03** `md_tree_template` | 建模板（普通/ALIGNED/DEVICE）、`SHOW SCHEMA TEMPLATES`、`SHOW NODES IN`、`SET/UNSET`、`SHOW PATHS SET`、`SHOW PATHS USING`、`CREATE TIMESERIES USING`、`ALTER … ADD`、占用 515、未挂载 513、重复 507 | **PASS** | 86s | ✓ ✓ ✓ |
| **MD-T04** `md_tree_observe` | `SHOW CLUSTER [DETAILS]`、`CLUSTERID`、`DATANODES`、`CONFIGNODES`、`AVAILABLE URLS`、`REGIONS`、`SCHEMA REGIONS`、`DATA REGIONS OF DATABASE`、`SCHEMA REGIONID`、`TIMESLOTID`、`VARIABLES`、`VERSION`、`ACTIVATION`、`SYSTEM INFO`、`QUERIES`、`CURRENT_*` | **PASS** | 88s | ✓ ✓ ✓ |
| **MD-T05** `md_tree_ddl_negative` | 30 条"必须失败"的 DDL（501/503/507/508/513/515/525/700/701/804/808/820/1301/301/305），并复查失败后元数据集合逐行不变 | **PASS** | 91s | ✓ ✓ ✓ |
| **MD-T06** `md_tree_view_ttl` | `CREATE VIEW`（查询源 / 路径序列源 / 个数不匹配 300）、`SHOW VIEW [<path>]`、`ALTER VIEW RENAME` 701、`DROP VIEW` 508、`SET/SHOW/UNSET TTL`（ms/INF/0） | **PASS** | 98s | ✓ ✓ ✓ |
| **MD-B01** `md_table_ddl` | `CREATE DATABASE/TABLE [IF NOT EXISTS] [WITH]`、`SHOW DATABASES [DETAILS]`、`SHOW CREATE DATABASE/TABLE`、`USE`+`SHOW CURRENT_DATABASE`、`SHOW TABLES [DETAILS] FROM`、`DESC [DETAILS]`、`ADD/DROP COLUMN [IF NOT EXISTS]`、`ALTER COLUMN SET DATA TYPE`、`SET PROPERTIES`（含带引号数字 701）、`COMMENT ON`、表/列改名 701、重名 501/551、删不存在 500/550 | **PASS** | 90s | ✓ ✓ ✓ |
| **MD-B02** `md_table_view_schema` | 表视图（源需 `**`）、逻辑视图、`SHOW [TREE] VIEWS`、`SHOW CREATE VIEW`、`ALTER VIEW RENAME`（表模型**支持**）、`information_schema.{databases,tables,columns,views,functions,services}` 与 `SHOW` 交叉校验、index 未支持 701、`SHOW DEVICES FROM <表>`、`SHOW MODELS` 1011 | **PASS** | 90s | ✓ ✓ ✓ |
| **MD-C01** `md_meta_consistency` | 造一整套树+表元数据 → 三副本逐 DN 停/启比对 → **重启集群** → 元数据摘要 md5 前后必须一字不差 → 跨模型命名空间隔离 | **PASS** | 256s | ✓ ✓ ✓ |
| **MD-C02** `md_dcl_user_role` | `CREATE USER/ROLE`、`GRANT/REVOKE`（用户侧+角色侧）、`GRANT ROLE r TO u`、`LIST USER/ROLE`、`LIST PRIVILEGES OF`、`LIST ROLE OF USER`/`LIST USER OF ROLE`、`ALTER USER`（改密/改名/会话数）、口令 <12 → 820、删不存在 804/808 | **PASS** | 87s | ✓ ✓ ✓ |
| **MD-C03** `md_privilege_matrix`（P4） | 权限值 `READ/WRITE/ALL/SYSTEM/SECURITY/AUDIT` × 路径粒度（库/序列/`root.**`）× 用户/角色、`WITH GRANT OPTION`、**以用户身份**验证越权 | **PASS** | 109s | ✓ ✓ ✓ |
| **MD-U01** `md_udf_trigger`（P4） | 真实 jar 注册 UDF/Trigger → `SHOW FUNCTIONS/TRIGGERS` → 执行/触发 → **重启后仍生效** → `DROP` + 错误码 1200/1207/1304/301/1301/1303 | **PASS** | 243s | ✓ ✓ ✓ |
| **MD-S01** `md_scale_bulk`（P4） | 2000 时序（200 设备 × 10 测量）+ 200 表下 `COUNT/SHOW/DESC/information_schema` 与分页 | **PASS** | 91s | ✓ ✓ ✓ |

集群准备（停 → 清 → 写配置 → 启动）140s；13 条用例耗时合计 1625s。

---

## 2. 本次实跑**发现的产品行为**（已固化为用例断言）

### 2.1 观察项：**0 条**

本轮跑出来的 4 条"与直觉不符"的行为**全部经产品文档/研发确认属于设计如此**，
并且都已从 WARN 改成用例里的**硬断言**（将来行为变了会直接 FAIL）：

| 行为 | 依据 | 固化为断言 |
| --- | --- | --- |
| 视图出现在 `SHOW TIMESERIES` 列表 | 研发确认符合预期 | `MD-T06` 第 3 步 |
| 多路径 `DROP DATABASE` 静默跳过不存在的路径（单路径报 508） | 研发确认符合预期 | `MD-T01` 第 7 步 |
| 权限：树模型 WRITE 隐含 READ + 读按权限过滤；表模型读写都硬校验 | 源码 `PathPrivilege.checkPrivilege` + 研发确认 | `MD-C03` 第 10~12 步 |
| **触发器 `ON <设备>` 不触发**（侦听对象是**序列**，设备节点自身没有序列） | **文档《06-流计算-触发器》**（`docs/refs/06-流计算-触发器.pdf`）明确；见 [`NOTE_trigger_path_pattern.md`](NOTE_trigger_path_pattern.md) | `MD-U01` 第 11 步（A/B 硬断言） |

> **教训（写给下一次）**：第 4 条曾被读成"源码漏收集设备节点自身的值"并当成疑似缺陷，还把
> `searchDeviceOverlapped:267` 的 `addAll(node.getValues())` 当作"实现不一致"的佐证——这是**错的**：
> 那个方法服务的是**设备级**用途（`getDeviceOverlapped`，当前只被单测使用）。
> **源码行为与直觉不符时，先对照产品文档/设计说明，再判缺陷。**

#### 多路径 `DROP DATABASE` 的行为（研发确认**符合预期**，已写成断言）

| 写法 | 返回 | 库 a 的下场 |
| --- | --- | --- |
| `DROP DATABASE a, <不存在>` | `Msg: The statement is executed successfully.` | **被删除** |
| `DELETE DATABASE a, <不存在>` | 成功 | **被删除** |
| `DROP STORAGE GROUP a, <不存在>` | 成功 | **被删除** |
| `DELETE STORAGE GROUP a, <不存在>` | 成功 | **被删除** |
| `DROP DATABASE a, b`（都真实存在，对照组） | 成功 | a、b 都删 |
| **`DROP DATABASE <不存在>`（单路径，对照组）** | **`508: Path [...] does not exist`** | 不删 |
| 表方言 `DROP DATABASE a, b` | `700: mismatched input ','`（表方言只接受单库） | 不删 |

- 语义：**多路径形式逐个删除并静默跳过不存在的路径；只有单路径形式才做存在性校验并报 508**。
- 与位置、空格、个数无关；混入非库路径（设备路径）同样静默跳过。
- 复现脚本：`docs/experiments/_dropmulti.sh`（V1-V6）与 `_dropmulti2.sh`（10 种写法）。

#### 已确认的设计行为（**不是缺陷**，已写成断言）

| 行为 | 实测 |
| --- | --- |
| **树模型：WRITE 隐含 READ** | 只授 `WRITE`（= WRITE_DATA + WRITE_SCHEMA）的用户能 `SELECT` 到数据、能 `count(*)`、能 `SHOW TIMESERIES`；三个 DataNode 结果一致。源码依据：`PathPrivilege.checkPrivilege()` 中 `READ_DATA` 检查会回退到 `WRITE_DATA`（`READ_SCHEMA` ← `WRITE_SCHEMA`） |
| **树模型：读是"按权限过滤"，写才是硬校验** | 零权限用户 `SELECT` **返回空集、不报错**（`SELECT s1 FROM db1.d1, db2.d1` 只返回有权限那个；`SELECT * FROM root.**` 只展开出有权限的序列列）；而 `INSERT` 报 **803** |
| **表模型：读写都是硬校验，且权限模型与树模型完全不同** | 零权限读 **803**、写 **803**；只授 `SELECT ON DATABASE <库>` 能读不能写（803）；只授 `INSERT` 能写不能读（803）；权限名是 `SELECT/INSERT/CREATE/DROP/ALTER/DELETE`（不是 `READ_DATA/…`），Scope 是 `<库>.*`（不是 `root.**`） |

### 2.2 已固化为断言的元数据语义（写用例/验收时的依据）

1. **DataRegion 懒创建**：库里只有时序、未写数据时 `SHOW DATA REGIONS OF DATABASE` 为空；写入 + `FLUSH` 后出现 DataRegion 与 TimeSlot（MD-T04）。
2. **`RENAME TO` 留下死路径**：旧路径从 `SHOW TIMESERIES` 消失，但在 `SHOW INVALID TIMESERIES` 里仍可查到（末列给出新路径）（MD-T02）。
3. **建时序会自动建库**：`CREATE TIMESERIES root.autodb.d1.s1 INT32` 会顺带创建 `root.autodb`（MD-T02）。
4. **库不能再嵌套**：已存在 `root.db` 时 `CREATE DATABASE root.db.sub` 报 501（MD-T01）。
5. **`SHOW DATABASES DETAILS` 是加宽版**，可用于验证 `ALTER DATABASE … WITH NEED_LAST_CACHE=…` 是否生效（MD-T01）。
6. **模板挂载点与激活路径分开**：`SHOW PATHS SET SCHEMA TEMPLATE`（挂载但未建设备）与 `SHOW PATHS USING SCHEMA TEMPLATE`（已激活设备）语义不同；设备未清理时 `UNSET` 报 515（MD-T03）。
7. **`SHOW PATHS <前缀> USING …` 返回空集**，不带前缀才列出全部激活路径（MD-T03 实测，用例已按此写）。
8. **树/表 DDL 差异**：`IF NOT EXISTS`/`IF EXISTS` 树模型不支持、表模型支持；表模型 `ALTER VIEW RENAME TO` **支持**，树模型 `ALTER VIEW RENAME TO` 报 701；表/列改名都不支持（MD-B02 已分别断言）。
9. **视图多源必须目标数 == 源数**，否则报 300（MD-T06）。
10. **`SHOW VERSION` 的 commit 与安装目录后缀一致**（`aaf460d`），可作环境自检（MD-T04）。
11. **权限回收必须双向可见**：`LIST ROLE OF USER` 与 `LIST USER OF ROLE` 都要同步（MD-C02）。
12. **重启持久化**：树 + 表两套元数据摘要（多条 `SHOW` 的排序行集合 md5）在重启前后**完全一致**（MD-C01）。

---

## 3. 过程中修掉的 harness 问题（都写进了 `lib/common.sh` 的注释与 `README.md`）

| # | 问题 | 症状 | 修法 |
| --- | --- | --- | --- |
| 1 | `is_error()` 把成功的 DDL 当报错 | CLI 对成功语句也打印 `Msg: The statement is executed successfully.` | 只有"`Msg:` 不是成功句"或"非表格行里出现 Exception"才算报错 |
| 2 | `SHOW PIPES` 结果表里含 `Exception` 字样 | 被误判为报错 | 表格行（`^\|`）不参与报错判定 |
| 3 | 集群启动被"未激活"窗口挡住 | `Deny DataNode registration: Cluster is unactivated now` → DN 进程直接退出，集群永远起不来 | CN 先起 → 等端口 → 等激活落定 → 再起 DN → 6 轮补起缺失进程 |
| 4 | 上一个 JVM 没退干净占着 Raft 文件锁 | 新 CN 启动 `OverlappingFileLockException` | 启动前 `kill_stale_nodes` 强制清理残留进程 |
| 5 | 用 `show cluster` 判断 CN 是否就绪 | CLI 连的是 DN 的 RPC 端口，DN 没起时一定 Connection Error → 白等 300s（准备集群从 92s 变 410s） | 改判 **CN 内部端口是否监听** |
| 6 | `local a=… b=$(( … a … ))` 同行引用 | `set -u` 下 `secs: unbound variable`，集群启动直接中断 | 拆成两条 `local`；selftest 增加静态检查 |
| 7 | 用例继承了 runner 的 stdin | CLI 把 `cases.tsv` 读空 → 只跑第一条用例就"汇总" | runner 先 `mapfile` 读入数组；子进程一律 `</dev/null` |
| 8 | 每条用例收尾都关集群 | 下一条又要停/清/启 ≈5 分钟 | 套件模式导出 `MD_NO_STOP_AFTER=1`，用例间复用集群，套件结束再停 |
| 9 | 一致性校验的噪声日志 | 逐个停 DN 会引发 `Failed to CHANGE_REGION_LEADER` / `RatisRequestFailedException: transferLeader` → 日志检查误报 | 加入 `BENIGN_PAT`（测试动作引起，非产品缺陷） |
| 10 | 用 `SHOW CLUSTER` 做副本比对 | 该输出随节点在线状态变化，停机时各节点结果天然不同 → 5 条误报 | 改用稳定的 `SHOW DATABASES` |
| 11 | `LIST USER` 第 1 列是 id 不是用户名 | `assert_set_has` 永远找不到用户 | 新增 `md_names_of <列号>`，用户名单取第 2 列 |

harness 自检：`SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh` → **ok=39 failed=0**。

---

## 4. 产物清单（可直接交付）

```
metadata_skill/
├── README.md                     使用说明（含快速开始、用例清单、迁移方法、踩坑）
├── SKILL.md                      skill 说明（面向使用者/维护者）
├── conf/env.conf                 唯一需要按环境改的配置
├── lib/common.sh                 harness（约 620 行）
├── cases/cases.tsv               机器可读用例矩阵（10 条）
├── cases/tree/*.sh               6 条树模型用例
├── cases/table/*.sh              2 条表模型用例
├── cases/common/*.sh             2 条一致性/权限用例
├── tools/{run_all,selftest,probe_ddl,cluster_prepare}.sh
├── docs/DDL_INVENTORY.md         ★ 被测版本 DDL 全清单（支持/不支持/坑）
├── docs/PLAN.md                  分阶段计划 + 后续可分解方向
├── docs/ddl_probe_list*.tsv      探测清单
├── docs/DDL_PROBE_RESULT*.tsv    探测结果（OK/ERR + 错误码 + 消息）
├── docs/RESULTS.md               本报告
└── results/
    ├── test_result.csv           最终一轮 10 条用例的结果
    ├── SUITE_all_final.out       套件级汇总
    └── final13/MD-*_run.out      每条用例的完整断言日志（13 条）
```

---

## 5. 建议的下一步（P4）

1. **真实 jar 的 UDF / Trigger 全链路**（现在只验证了"类不存在"的失败路径）；
2. **权限矩阵**（`ALL/READ/WRITE/SYSTEM/SECURITY/AUDIT` × 路径通配）；
3. **元数据规模**（`MD_BULK_SERIES=2000` / `MD_BULK_TABLES=200` 下的 `SHOW`/`COUNT` 正确性与耗时）；
4. 元数据 DDL **并发**（多会话同时建/删同库同表）；
5. 同套用例在 `IoTConsensusV2` 下复跑做双协议对照（`--consensus IoTConsensusV2`，无需新增用例）。
