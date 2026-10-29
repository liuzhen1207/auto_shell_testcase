# 元数据 DDL 自动化测试 skill（TimechoDB / IoTDB 2.0.12.1）

以**元数据（metadata / schema 定义）**为测试目标的一套可复用用例集：
把"建库/建表/建时序/模板/视图/权限"等 DDL 打上去之后，
用 `SHOW …`、`COUNT …`、`information_schema` 这些**元数据读接口**验证
"写进去的元数据是否如实、一致、可持久、可回滚"。

当前目标版本：**RC5 `v20121rc5_1003_aaf460d`（2.0.12.1 / commit `aaf460d`）**，
被测集群：3C3D（`192.168.99.77/78/79`，每台 1 CN + 1 DN，3 副本，IoTConsensus）。
驱动/框架机：`192.168.99.80`，部署路径 `/data/iotdb/autotest/metadata_skill`。

---

## 1. 这个 skill 测什么（和 TTL skill 的区别）

| | TTL skill | 本 skill |
| --- | --- | --- |
| 测试对象 | 数据**过期清理**行为（TTL 生效、settle 清理、参数热加载） | **元数据本身**：DDL 写入 → 元数据读接口的如实反映 |
| 主要证据 | 日志计数（`Start ttl`、`SettleCompaction`）、TsFile 数 | `SHOW …` / `COUNT …` / `information_schema` 的**排序行集合** |
| 核心判据 | 清理/不清理的差值、比例门控 | 集合相等/包含/不包含、计数自洽、重启前后摘要不变 |
| 收尾三件套 | sync lag → 副本一致性 → 日志异常 | 同左（一致：元数据查询也必须三副本一致、重启后不丢） |

两者共用同一套环境约定与集群生命周期写法，但 **harness 是独立的**（`metadata_skill/lib/common.sh`），
没有做 `ttl_`→`md_` 的机械改名（那会把 `ttl_check_interval` 这类**产品配置名**一起改坏）。

---

## 2. 快速开始

```bash
# 0) 同步到 99.80（本机 → 驱动/框架机）
scp -r metadata_skill root@192.168.99.80:/data/iotdb/autotest/

# 1) 自检 harness（语法、判定逻辑、用例矩阵；不依赖集群）
cd /data/iotdb/autotest/metadata_skill
SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh        # 期望 ok=N failed=0

# 2) 探测被测版本真实支持的 DDL（生成/刷新 docs/DDL_PROBE_RESULT.tsv）
bash tools/probe_ddl.sh

# 3) 跑全量用例（会先把集群停/清/写配置/启动一次，然后复用）
bash tools/run_all.sh --set all
bash tools/run_all.sh --set tree            # 只跑树模型
bash tools/run_all.sh --set common          # 一致性/权限/UDF-Trigger
bash tools/run_all.sh --set scale           # 元数据规模（2000 时序 / 200 表）
bash tools/run_all.sh --only MD-T01,MD-T02  # 指定用例
bash tools/run_all.sh --set all --consensus IoTConsensusV2

# 4) 调试：集群已在跑时复用，不要每次停清启
SKIP_LIFECYCLE=1 bash cases/tree/md_tree_database.sh

# 5) UDF / Trigger 用例需要真实 jar：一次性构建并分发到各节点
bash assets/udf/build_and_deploy.sh          # 用服务端 jar 编译 assets/udf/src 并分发到 /data/iotdb/udf_md/
```

结果位置：
- `results/test_result.csv` —— 汇总（时间/版本/协议/用例/结果/耗时/fail 数/artifact/消息）
- `results/<用例>_<runid>.out` —— 单用例完整输出（含每条断言的 PASS/FAIL）
- `results/SUITE_<set>_<时间>.out` —— 套件级汇总
- 失败时自动把 CN/DN 日志打包到 `results/artifact_<用例>_<runid>/logs/`

---

## 3. 用例清单（13 条）

| 用例 | 覆盖 | 关键判据 |
| --- | --- | --- |
| **MD-T01** 树·DATABASE | 建库三写法、`SHOW DATABASES [DETAILS]`、`COUNT DATABASES`、`ALTER`（支持/不支持）、`DROP` 单/多路径、重复建/删不存在/非法属性/`IF NOT EXISTS` | 集合与计数自洽；`ALTER … NEED_LAST_CACHE` 能在 `DETAILS` 里看到；`ALTER … TTL` 必须报 525 |
| **MD-T02** 树·TIMESERIES | 建时序（完整/简化/对齐/TAGS+ATTRIBUTES）、`SHOW TIMESERIES`（路径/WHERE/LIMIT/ORDER)、`COUNT … LEVEL`、`SHOW DEVICES`、`CHILD PATHS/NODES`、`ALTER` 全系列、`RENAME TO` | `COUNT == SHOW` 行数；ALTER 后 `SHOW` 必须跟着变；`RENAME` 后旧路径从 `SHOW TIMESERIES` 消失但出现在 `SHOW INVALID TIMESERIES` |
| **MD-T03** 树·SCHEMA TEMPLATE | 建模板（普通/ALIGNED/DEVICE）、`SHOW SCHEMA TEMPLATES`、`SHOW NODES IN`、`SET/UNSET`、`SHOW PATHS SET/USING`、`CREATE TIMESERIES USING`、`ALTER … ADD`、占用时的失败路径 | 挂载点与激活路径**分别**在 `SHOW PATHS SET` / `USING` 里体现；占用中 `UNSET` 必须 515 |
| **MD-T04** 树·元数据观测面 | `SHOW CLUSTER[DETAILS]/DATANODES/CONFIGNODES/URLS/REGIONS/REGIONID/TIMESLOTID/VARIABLES/VERSION/ACTIVATION/SYSTEM INFO/QUERIES/CURRENT_*` | **DataRegion 懒创建**（无数据时为空，写入+flush 后出现）；`SHOW VERSION` 的 commit == 安装目录后缀 |
| **MD-T05** 树·失败路径 | 20+ 条"必须失败"的 DDL（错误码 501/503/507/508/513/515/525/700/701/804/808/820/1301/305…） | 每条都要"报错 + 错误码"；失败后**元数据集合与失败前逐行一致**（不被改脏） |
| **MD-T06** 树·VIEW + TTL | `CREATE VIEW`（查询源/路径源）、`SHOW VIEW`、`ALTER VIEW RENAME`（不支持）、`DROP VIEW`、`SET/SHOW/UNSET TTL` | 视图不混进 `SHOW TIMESERIES`；TTL 值 `ms/INF/0` 与 `UNSET` 在 `SHOW TTL ON` 上如实反映 |
| **MD-B01** 表·DATABASE/TABLE/COLUMN | `CREATE DATABASE/TABLE [IF NOT EXISTS] [WITH]`、`SHOW TABLES/DETAILS`、`DESC [DETAILS]`、`SHOW CREATE`、`ADD/DROP/ALTER COLUMN`、`SET PROPERTIES`、`COMMENT ON` | `SHOW CREATE TABLE` 反映 `ttl`；`IF NOT EXISTS` 不产生重复列；表/列改名必须 701 |
| **MD-B02** 表·VIEW + information_schema | 表视图（源必须 `**`）、逻辑视图、`SHOW [TREE] VIEWS`、`SHOW CREATE VIEW`、`information_schema.{databases,tables,columns,views,functions,services}` | `information_schema` 与 `SHOW …` **交叉一致**；索引/区域 id 等未支持项必须 701 |
| **MD-C01** 一致性 + 持久化 | 造一整套树+表元数据 → 逐 DN 停比对 → **重启集群** → 再比 | 元数据**排序行集合摘要（md5）重启前后一字不差**；树/表命名空间互不串味 |
| **MD-C02** 权限元数据 | `CREATE USER/ROLE`、`GRANT/REVOKE`（用户侧+角色侧）、`GRANT ROLE r TO u`、`LIST USER/ROLE/PRIVILEGES`、`ALTER USER`（改密/改名/会话数） | 授权与回收必须**双向**可见（`LIST ROLE OF USER` 与 `LIST USER OF ROLE`）；口令 <12 报 820 |
| **MD-C03** 权限矩阵 | 权限值 `READ/WRITE/ALL/SYSTEM/SECURITY/AUDIT` × 路径粒度（库/设备/序列/`root.**`）× 用户/角色，`WITH GRANT OPTION`，并**以该用户身份**验证越权 | `LIST PRIVILEGES` 的 Role/Scope/Privileges/GrantOption 四列逐条对应（READ→READ_DATA+READ_SCHEMA）；`ALL/SYSTEM/SECURITY/AUDIT` 只能授在 `root.**`；越权写报 **803** |
| **MD-U01** UDF / Trigger 全链路 | 真实 jar（`assets/udf/`）注册 UDF 与 Trigger：`CREATE FUNCTION/TRIGGER` → `SHOW FUNCTIONS/TRIGGERS` → 执行/触发 → **重启后仍生效** → `DROP` + 失败路径 | UDF 必须算出预期结果（值 ×2 / 带属性 ×3）；触发器 `onCreate` 在多节点、`fire` 只在写入节点；重启后仍 fire；错误码 1200/1207/1304/301/1301/1303 |
| **MD-S01** 元数据规模 | 2000 时序（200 设备 × 10 测量）+ 200 张表下的 `SHOW/COUNT/DESC/information_schema` | `COUNT == SHOW 行数 == 理论值`；分页不截断；分层计数口径一致；记录各查询耗时 |

---

## 4. 目录结构

```
metadata_skill/
├── conf/env.conf                 # 唯一需要按环境改的文件（节点/版本/账号/超时/规模）
├── lib/common.sh                 # harness：环境、集群生命周期、SQL 会话、元数据判据与断言、
│                                 #          副本一致性、日志分析、结果记录
├── cases/
│   ├── cases.tsv                 # 机器可读用例矩阵（run_all.sh 的唯一来源）
│   ├── tree/                     # 树模型用例（6）
│   ├── table/                    # 表模型用例（2）
│   └── common/                   # 跨模型/一致性/权限/UDF-Trigger/规模（5）
├── assets/udf/                   # UDF / Trigger 测试用 Java 源码 + 构建分发脚本
│   ├── src/mdskill/*.java        # MdUdtf(×2) / MdTrigger
│   └── build_and_deploy.sh       # 用服务端 jar 编译 → 分发到各节点 /data/iotdb/udf_md/
├── tools/
│   ├── run_all.sh                # 批量运行（--set quick|tree|table|common|all，--only，--consensus）
│   ├── selftest.sh               # harness 自检（不依赖集群）
│   ├── probe_ddl.sh              # DDL 能力探测（生成 docs/DDL_PROBE_RESULT.tsv）
│   └── cluster_prepare.sh        # 只准备集群（停 → 清 → 写配置 → 启动）
├── docs/
│   ├── DDL_INVENTORY.md          # ★ 被测版本支持的 DDL 全清单 + 不支持清单 + 坑
│   ├── NOTE_trigger_path_pattern.md   # 触发器路径模式语义（ON <设备> 为什么不触发，符合文档）
│   ├── refs/06-流计算-触发器.pdf      # 产品文档（判定"是否符合预期"的依据）
│   ├── ddl_probe_list.tsv        # 探测清单（label/dialect/sql）
│   ├── DDL_PROBE_RESULT.tsv      # 探测结果（含错误码与消息）
│   ├── PLAN.md                   # 分阶段计划与后续方向
│   ├── RESULTS.md / P4_RESULTS.md # 实跑报告
│   └── experiments/              # 现场实验脚本（结论可复现）+ 索引 README
└── results/                      # 输出（CSV / 用例日志 / 失败时的 CN-DN 日志包）
```

---

## 5. 迁移到其它环境

只改 `conf/env.conf`：

- `CLUSTER_NODES` / `CN_NODES` / `DN_NODES` + `SSH_USER`：集群节点
- `DB_PARENT_DIR` / `SHELL_CLIENT_DIR` / `V_TESTDB`：安装目录、shell 客户端目录、版本目录名
- `DB_USER` / `ROOT_PW`：账号
- `SCHEMA_RF` / `DATA_RF` / `DATA_CONSENSUS`：副本数与共识协议（`IoTConsensus` / `IoTConsensusV2`）
- `USE_FRAMEWORK=0`：不用 99.80 的 autotest 框架脚本，改用 skill 自带的 ssh 启停

`MD_PREFIX`（默认 `md`）决定用例创建的所有库/表前缀，便于识别与清理（不会碰 TTL skill 的库）。

---

## 6. 已知注意事项（踩过的坑）

1. **成功也会打印 `Msg:`**：CLI 对成功的 DDL 输出 `Msg: The statement is executed successfully.`，
   判定报错必须排除它（`lib/common.sh: is_error`）。
2. **结果表里可能含 `Exception` 字样**（`SHOW PIPES`），表格行不参与报错判定。
3. **clean 掉 data 后集群需要重新激活**：DN 若在"未激活"窗口内注册会被拒并直接退出
   （`Deny DataNode registration: Cluster is unactivated now`）。因此启动顺序固定为
   **先起 CN → 等可连通 → 等激活落定（默认 20s）→ 再起 DN → 未 Running 的节点补起**。
4. **不要在用例运行中覆盖它的脚本**：bash 边读边执行，覆盖后会读到错位内容。
5. **PowerShell 会吞掉 ssh 命令里的双引号**：远端命令尽量走脚本文件或 `bash -s` + heredoc。
6. **`SELFTEST_NO_CLUSTER=1`**：用例运行期间不要跑 `selftest.sh` 的写配置 round-trip（会改集群配置）。
7. 表模型 `USE` 依赖同一个会话：harness 用 `;;` 分隔的多语句会话（`tblsess`）。
