---
name: iotdb-crud
description: "Deploy a TimechoDB/IoTDB release from a tarball onto given hosts (ssh key or password, install path), activate the licence, configure schema/data replication factors and the data-region consensus protocol, then verify CRUD semantics end to end on a real 3-ConfigNode + 5-DataNode cluster as a conf-driven, IP-agnostic case matrix (75 cases): tree/table-model insert variants, overwrite and out-of-order writes, delete granularity (time range, device, database, idempotency, metadata retention), NULL and OBJECT columns, timestamp and type boundaries, query features (LAST, ranges, LIMIT/OFFSET, aggregation, GROUP BY LEVEL/time, ALIGN BY DEVICE, expressions, filter), ALTER TABLE add/drop column, cross-database and long-path cases, concurrency (parallel writers, delete vs query/insert) and restart/WAL-replay consistency, each case producing SQL-level logs and a Chinese report with graded evidence."
whenToUse: "When asked to verify IoTDB/TimechoDB create/read/update/delete behaviour on a real cluster: write path variants, overwrite and partial-column semantics, out-of-order writes, delete granularity, NULL/OBJECT handling, timestamp/type boundaries, query features, ALTER TABLE column changes, cross-database and long-path queries, concurrency or restart/WAL consistency; or to re-check PLM CRUD regressions such as TDB-442 (deleted data reappearing after compaction), TDB-352 (small-OBJECT write/delete cost), TDB-423 (mixed timestamp precision), TDB-116 (moved to the iotdb-remove-cn-dn skill) and the RC5 OBJECT NULL write PATH."
metadata:
  version: "1.0.0"
  category: "iotdb-cluster-testing"
---

# iotdb-crud — TimechoDB/IoTDB CRUD 用例矩阵 skill

参照 `iotdb-remove-cn-dn`、`iotdb-ttl` 两个 skill 的结构设计：**conf 驱动、IP 无关、用例矩阵 + 真实执行 + 证据分级 + 中文报告**。

## 目录

```
cases/crud_cases.tsv        用例矩阵（75 条；格式：优先级 用例ID 模型 领域 标题，空白分隔）
conf/crud.rc5.conf          运行配置（RC5：包/DB_DIR/RESULT_DIR/BM_HOME/参数；克隆自 TTL skill）
conf/nodes.conf             3 ConfigNode + 5 DataNode 的节点定义（IP 无关，仅改此文件即可换集群）
references/design-notes.md  设计说明、覆盖依据、证据分级、错误码表、执行器移植计划
results/                    每次运行的 run.log / summary.tsv / cases/<id>/ / REPORT.md
```

## 状态（截至 2026-10-08）

- ✅ 用例已全部实现并在 RC5 真实执行（74 条，无 SKIP；领域分布见下"覆盖范围"）
- ✅ 运行配置 `conf/crud.rc5.conf`（RC5：`timechodb-2.0.12.1-bin.zip` / `aaf460d`）与 `conf/nodes.conf` 就绪
- ✅ 执行器已派生并可运行：`scripts/crud.sh` + `scripts/crudkit`（复用 TTL 的 cfg/ssh/api/runner，用例实现自写）
- ✅ 已在 RC5 真机跑通全链路（deploy → prepare → matrix → REPORT.md），**74 条用例在 RC5 真实 PASS（0 FAIL）**
  - 环境：`/data/mpp_test/v20121rc5_crud`，3 CN + 5 DN，IoTConsensus，激活通过
  - 运行：`results/20261007_200207_matrix/`（74 PASS / 0 FAIL / 0 SKIP）
  - 覆盖：树模型单行写入回读、同设备多行批量、同时间戳覆盖、时间区间删除、时间区间左闭右开查询、树模型无模式写入+元数据自动创建、表模型建表写入回读、表模型时间区间删除
- ✅ **无 SKIP**：原先 10 条能力缺口已全部补齐（Session/Tablet 通道、合并参数组合、benchmark 表模型负载、TTL×CRUD、表模型删除粒度、Schema 变更后写入等）；唯一需要破坏性集群操作的 TDB-116 已移交 `iotdb-remove-cn-dn`（该侧用例行尚未执行，不计入 CRUD 结果）

## 覆盖范围（75 条 · 按最新矩阵统计）

| 领域 | 条数 | 内容 |
|---|---|---|
| 写入基础 | 16 | 单行/多行/Tablet 批量（tree+table）、NULL 字段、OBJECT/Binary（含写 NULL）、全类型往返、时间戳精度与边界、空批次、对齐序列 |
| 覆盖语义 | 3 | 同时间戳覆盖、部分列覆盖保留原值、批内重复时间戳 |
| 乱序写入 | 3 | `enable_ooo` 开/关、乱序与覆盖交叉 |
| 元数据 | 5 | 无模式写入开/关、未建库写入、特殊字符与超长路径 |
| 错误处理 | 3 | 类型不匹配、超长 TEXT、NaN/Inf |
| 边界 | 1 | 大批量写入 |
| 查询 | 15 | LAST、时间区间边界、LIMIT/OFFSET、聚合与空结果、GROUP BY LEVEL/TIME、ALIGN BY DEVICE、表达式、WHERE、NULL 语义、OBJECT 列、表视图一致性、倒序分页、跨库、与 TTL 交互 |
| 删除 | 8 | 时间区间（tree/table）、设备粒度、删库、幂等、保留元数据、乱序删除、OBJECT 数据 |
| 更新 | 2 | `ALTER TABLE ADD/DROP COLUMN` 后的读写行为 |
| 并发 | 4 | 同设备并发写、同时间戳并发写、删除与写/查并发 |
| 一致性 | 6 | 重启、WAL 回放、flush、合并、多副本读、**建组窗口内整体 kill -9 后重启恢复（RATIS-2661 / TDB-372）** |

| TTL交叉 | 1 | SET TTL 后删除：数据清空但 TTL 元数据保留、重写仍可读 |
| Schema变更 | 1 | 类型不匹配被拒 + 新测量点自动建后写入 |
| 表模型删除 | 1 | 时间范围删除行数正确 + drop table 后重建可写 |
| 回归 | 6 | TDB-442（MERGE 版与参数组合版）、TDB-352、TDB-423、TDB-184 等 PLM 回归 |

设计取向（与 remove/ttl skill 一致）：**树模型与表模型并测**，表模型侧重点在 OBJECT/Binary 与 NULL 语义
（RC5 上 OBJECT 写路径出现过 NPE，见 `crud_insert_null_object_table` / `crud_object_column_table`）；
一致性与并发域直接复用 remove skill 的观测手法（写负载下快照比对、重启/回放后比对）。

## 新增能力（均已真机验证）

- **逐用例 props 覆盖 + 重启**：`_param_override(ctx, {...})` —— 写配置 → `cluster.stop_all()/start_all()` → 跑断言 →
  `finally` 还原并再次重启；键原本不在配置文件时按 **RC5 源码默认值**还原（`enable_*_space_compaction=true`、
  `inner_compaction_candidate_file_num=30`、`enable_auto_create_schema=true`），不删改原有配置项。
  用例：`crud_regr_tdb442_combo`（TDB-442 参数组合版）、`crud_schema_auto_create_off`。
- **原生 Session/Tablet 写入通道**：`tools/tablet_probe/TabletProbe.java`（本机 JDK17 + 同版本客户端 jar，见
  `tools/tablet_probe/lib_rc5/`），模式 `tree`（真机 `insertTablet`）、`empty`（0 行）、`table`（表模型）。
  表模型用**裸 Session 未打通**：三种 `IDeviceID` 形态 + `use db` + `Session.Builder.sqlDialect("table")` 均报
  `508: Path does not exist`（已记档，未作产品结论）；OBJECT 列经 Tablet 被**客户端**类型检查拒绝
  （该检查不在 IoTDB 源码树内）——故 remove-cn-dn 轮次的 `Binary.getLength()` NPE **不属此路径**（B/C 级区分）。
- **benchmark 表模型写入路径**：移植 `start_object_load`/`table_databases`，用 conf 的 `BM_HOME` 指向的
  iotdb-2.0 表模型负载，覆盖 `crud_tablet_batch_table`、`crud_regr_tdb352_object_write_delete`。
- **耗时实测**（`date +%s`，非估算）：一轮完整 `deploy → prepare → doctor → matrix` ≈ **35 分 42 秒**
  （deploy 29s / prepare 128s / doctor 6s / matrix 1979s）；瓶颈是两条 props+重启用例，合计 686s（约占矩阵 35%）。
- **外部依赖（均为 conf 键，非硬编码）**：`DEPLOY_TARBALL`、`DEPLOY_HOSTS`、`LICENSE_CODE_FILE`、`BM_HOME`。

## 建组窗口内整体 kill -9（RATIS-2661 / TDB-372）

`crud_schema_region_group_bootstrap_restart`：新数据库的 SchemaRegionGroup 正在建组（Ratis
configuration entry 尚未落盘）时，对**全部 CN+DN `kill -9`**，再按 **CN 先起、DN 后起** 重启，
要求该库的 SchemaRegionGroup 恢复为 3 个 Running 副本、恰好 1 个 Leader、schema 读写可用，
且 DataNode 日志不出现 `NOT_IN_CONF` / `SetConfiguration` 被拒（`ServerNotReadyException: ... is not in [RUNNING]`）。

- **注入方式不是固定延时**：DN 日志一出现 `addNew group-<id>:`（`tail -F -n 0 | grep -m1`，5 台 DN 并行守候）
  即锁定注入点，再按 `CRUD_WINDOW_KILL_DELAYS`（默认 `0,0.3,0.6,0.9` 秒）逐级滞后并行 `pkill -9` 全部节点
  （下发实测 0.05–0.06s）。固定延时只能猜 CLI 启动耗时，换机器就漂；而"命中即杀"又常常早于 CN 把区域分配落盘，
  导致重启后没有 region 可判——滞后梯级正好停在"分配已落盘、configuration entry 未提交"的窗口里。
- **可判定性**：命中后若重启日志出现 `for NOT_IN_CONF` 或 region 视图没有 Leader → FAIL；
  若该库重启后连 region 都没有（kill 早于区域分配落盘）→ 换更大的滞后重试，全都不成立则 SKIP，
  绝不把"没注入进去"当 PASS。
- **conf 键**：`CRUD_WINDOW_KILL_DELAYS`（默认 `0,0.3,0.6,0.9`）、`CRUD_WINDOW_KILL_ATTEMPTS`
  （默认取梯级长度）。用例重启集群，`run --skip-restart` 会跳过它。
- **真机对照（2026-10-30，3C5D）**：
  - 2.0.13.1 RC1（ratis 3.3.1）：PASS —— `results/20261030_190549_run/`（49.6s），命中 `group-000200000015`，
    重启后 3 Running / 1 Leader / 写入回读成功，本组日志无 `NOT_IN_CONF`。连续 3 次运行均 PASS。
  - 2.0.10.2（ratis 3.2.2）：FAIL（负向对照）—— `results/20261030_190944_run/`（41.7s），重启后该库 region
    视图为空、DN 日志 `changes role from null to FOLLOWER at term 0 for NOT_IN_CONF`（多轮运行命中 1–3 台 DN），
    另一轮写入探针返回 `906: The consensus group SchemaRegion[8] doesn't exist`（与 PLM TDB-372 现场一致）：
    旧版把区域分配和建组配置一起丢了，只能靠后续写入懒建新组兜底。
- 版本配置：`conf/crud.v20131rc1.conf`（2.0.13.1 RC1，ab6d3de）、`conf/crud.v20102.conf`（2.0.10.2，负向对照）。

## 执行模型（与 TTL skill 同构）

```
scripts/crud.sh --conf conf/crud.rc5.conf deploy     # 解包 + 配置 + 激活
scripts/crud.sh --conf conf/crud.rc5.conf prepare    # DESTRUCTIVE：清库 + CRUD 开关 + 启动
scripts/crud.sh --conf conf/crud.rc5.conf list-cases
scripts/crud.sh --conf conf/crud.rc5.conf matrix     # 全部 75 条
scripts/crud.sh --conf conf/crud.rc5.conf run --case crud_insert_null_object_table
scripts/crud.sh --conf conf/crud.rc5.conf report results/<run-dir>
```

每条用例产出 `cases/<id>/{result.json,actions.log}`（含 SQL 原文与返回值），判定分 PASS/FAIL/SKIP，
报告含逐条结果、版本与提交、证据等级、未闭环项。

> 注：以上计数来自 `results/20261007_212130_matrix/`（2026-10-08 认证，74 PASS / 0 FAIL / 0 SKIP）。
