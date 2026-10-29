# ai_auto_cases

AI 辅助生成 / 维护的自动化回归用例集，按**被测环境**分目录存放。

## 目录

| 目录 | 环境 | 内容 |
| --- | --- | --- |
| `192_168_99_80/` | 跳板机 192.168.99.80 + 3C3D 集群（192.168.99.77 / .78 / .79，RF=3） | TimechoDB 2.0.12.1 专项回归：compaction 52、crud 15、ttl 15、wal 27、metadata 13、diskusage 5 |
| `172_16_2_205/` | 跳板机 172.16.2.205 + 3C5D 集群（CN .26/.27/.28，DN .2~.6，SR=3 / DR=2） | 树转表视图 `auto_sync_schema` 回归（tree_view_skill，67 条）+ 身份鉴别回归（auth_skill，22 条） |
| `172_16_2_20/` | 跳板机 172.16.2.20 + 3C5D 集群（CN .16/.17/.18，DN .19/.21~.24，SR=3 / DR=2） | DELETE 语义全量回归（delete_skill，85 个 CASE / 163 个协议轮次：IoTConsensus 85 + IoTV2 78） |
| `172_20_70_13_5C20D/` | 跳板机 172.20.70.13 + 5CN20DN 集群（172.20.70.100–119，SR3/DR3；pipe 场景拆两套 5CN10DN、SR5/DR3） | 树转表视图（含 Pipe 数据同步，55 条）+ 主动扩容 PROACTIVE（约 170 条） |
| `172_20_70_17_DELL_R730/` | 跳板机 172.20.70.17（DELL R730） | 摘除 ConfigNode/DataNode、MIGRATE REGION、缩容，及 OBJECT 在迁移/缩容下的正确性与空间（remove_cn_dn_skill，33 条） |
| `172_20_70_3/` | 跳板机 172.20.70.3 | 内存缓冲区（membuf，24 条）、查询调度（query scheduler / MLFQ，15 条）、Region 迁移（TC-54，1 条） |

## 用例统计（2026-10-29）

| 环境 | 模块 | 用例数 | 来源 |
| --- | --- | ---: | --- |
| `172_16_2_20/` | delete_skill | 85 | `cases.tsv` 精确（**163 个协议轮次** = IoTConsensus 85 + IoTV2 78） |
| `172_16_2_205/` | auth_skill | 22 | `cases.tsv` 精确 |
| | tree_view_skill | 67 | `cases.tsv` 精确 |
| `172_20_70_13_5C20D/` | tree_view_skill | 55 | README 声明（46 单集群 + 9 Pipe） |
| | proactive_skill | ≈170 | README 声明（python harness，未逐条数） |
| `172_20_70_17_DELL_R730/` | remove_cn_dn_skill | 33 | `cases/remove_cases.tsv` 精确 |
| `172_20_70_3/` | memory_buffer_skill | 24 | `cases.tsv` 精确 |
| | query_schedule_skill | 15 | `cases.tsv` 精确 |
| | region_migrate_skill | 1 | `cases.tsv` 精确（TC-54） |
| `192_168_99_80/` | compaction_skill | 52 | `cases/cases.tsv` 精确 |
| | crud_skill | 15 | `cases/cases.tsv` 精确 |
| | ttl_skill | 15 | `cases/cases.tsv` 精确 |
| | wal_skill | 27 | `cases/cases.tsv` 精确 |
| | metadata_skill | 13 | `cases/cases.tsv` 精确 |
| | diskusage_skill | 5 | `cases/cases.tsv` 精确 |
| **合计** | 15 个 skill | **≈599 条** | 精确 374 + 声明 225 |

口径说明：

- **599 是"用例条数"**；delete_skill 的 85 条中有 78 条需跑两遍协议，故实际执行 **163 轮**。
  若全目录统一按执行轮次计：`599 - 85 + 163 = 677 轮`。
- "精确"指脚本从各模块用例矩阵直接统计（剔注释行、空行、表头后取唯一 case_id）；
  `proactive_skill` 与 `172_20_70_13` 的 `tree_view_skill` 为 python harness（`CaseSpec(...)` 注册），
  两个模块共用同一套 `pgkit` 框架，无法从代码区分模块归属，故采用各自 README 的声明值。
- `metadata_skill/docs/` 下的 `ddl_probe_list*.tsv`、`DDL_PROBE_RESULT*.tsv` 是探测清单与结果，**不计入用例数**。

## 与原 `auto_shell_testcase/` 的关系

`auto_shell_testcase/` 下是历史手工维护的用例（按机房/集群分目录）。
本目录是**新的组织方式**：用例以 skill（可独立运行、带自检与清单校验的用例包）为单位提交，
每个 skill 自带 `lib/`、`conf/`、`tools/`、`docs/`，可直接拷到测试机上跑。

## 约定

- 用例源码与 `cases/MANIFEST.md5` 必须同步提交（清单用于 preflight 校验）。
- 不提交 `results/`、`*.out`、日志与 artifact（运行产物）。
- 每个环境目录下写一份 `README.md`，说明用例清单、运行方式、已跑版本与结论。
- 用例矩阵只保留一份：放在代码实际读取的路径（通常 `cases/cases.tsv`），不要在同一 skill 内留同名副本。
