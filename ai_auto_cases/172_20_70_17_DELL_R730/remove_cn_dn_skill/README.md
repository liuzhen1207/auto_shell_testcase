# remove_cn_dn_skill

摘除 ConfigNode / DataNode（`REMOVE CONFIGNODE` / `REMOVE DATANODE`、`MIGRATE REGION`、缩容）的回归用例包，
以及 OBJECT 字段在迁移/缩容下的正确性与空间用例。python3 实现，一键跑：`tools/run_regression.sh`。

## 目录

| 路径 | 内容 |
|---|---|
| `scripts/rcdn.sh` | 入口（`run` / `list-cases` / `prepare` / `deploy` / `doctor` / `selftest` …） |
| `scripts/rcdn/` | 框架与 33 条用例的实现（`cases.py` 里的 `extras` 分支即专项用例） |
| `cases/remove_cases.tsv` | 本环境矩阵（33 条，默认用这个） |
| `cases/remove_cases_generic.tsv` | 通用矩阵（其他版本复用） |
| `conf/cluster.conf` | 本环境配置（**唯一需要改的文件**：`HOSTS`/`DB_DIR`/RF/协议） |
| `conf/cluster.{bigobj,manyobj,tdb861,matrix}.conf` | OBJECT 大对象/海量小文件/TDB-861 探针与全量矩阵的专用配置 |
| `tools/run_regression.sh` | 一键回归（`all` 会依次跑矩阵 + 三个专用配置 + 探针） |
| `tools/selftest.sh` | 离线自检（不需要集群） |
| `docs/` | 用例说明、已知缺陷、故障排查、本模块的缺陷单（TDB-893） |
| `SKILL.md` | 完整技能说明书（部署、参数、每个 `extras` 的含义） |

## 快速开始

```bash
# 0) 改 conf/cluster.conf 里的 HOSTS 与 DB_DIR
bash tools/selftest.sh                 # 离线自检
bash scripts/rcdn.sh --conf conf/cluster.conf doctor      # ssh/端口/JDK 体检
bash scripts/rcdn.sh --conf conf/cluster.conf prepare     # 部署 + 激活 + 建库
bash tools/run_regression.sh           # 全量矩阵（33 条）
bash tools/run_regression.sh all       # 矩阵 + OBJECT 大对象/海量小文件/TDB-861 探针
bash tools/run_regression.sh --case dn_object_single_4g   # 单跑一条
```

产物在 `results/<run-id>/`：`summary.tsv`（逐条 PASS/FAIL/耗时）、`cases/<case>/`（SQL 结果与 `result.json`）、
`node_logs/<host>/`（迁移类失败时自动抓的全部节点日志）。这些目录不提交到本仓库。

## 用例清单（33 条）

| 组 | 用例 |
|---|---|
| DataNode 摘除（17） | `dn_running_remove`、`dn_unknown_remove`、`dn_readonly_remove`、`dn_running_remove_1rep`、`dn_nonexistent_remove`、`dn_multi_remove`、`dn_concurrent_remove`、`dn_added_dn_remove`、`dn_remove_rf_limit`、`dn_remove_load_balance`、`dn_remove_other_readonly`、`dn_remove_other_unknown`、`dn_remove_other_diskfull`、`dn_remove_restart_storm`、`dn_remove_restart_sweep`、`dn_concurrent_remove_writes_tdb116`、`dn_remove_kill9_target/dn_remove_kill9_other/dn_remove_restart/dn_remove_twice` |
| ConfigNode 摘除（8） | `cn_follower_remove`、`cn_leader_remove`、`cn_stopped_remove`、`cn_nonexistent_remove`、`cn_leader_remove_kill9_follower`、`cn_follower_remove_restart`、`cn_remove_below_quorum`、`cn_shrink_leader_first` |
| OBJECT（4） | `dn_object_single_4g`、`dn_object_big_migrate`、`dn_object_manyfiles_residue`、`dn_object_delete_residue`（+ `dn_object_size_after_migration` 为 TDB-835 守卫，归在 DataNode 组内） |

四条 OBJECT 用例**默认参与全量回归**（不再 skip）。它们证明：

- `dn_object_single_4g`：单点 OBJECT 写到 **4 GiB**（512 段 `to_object(isEOF, offset, X'..')`，8 MiB/段），
  用 `read_object(o, offset, length)` 按 16×256 MiB 分段读回，逐段比对 `length()` 与 `sha256()`，
  再 `MIGRATE REGION` 后重复同一校验；整文件 `read_object(o)` 对 >2 GiB 才报 701，分段读不受限。
- `dn_object_big_migrate`：~4 GiB 分散在 12 MiB 对象文件里，逐个 region 迁移并逐行 sha256 校验。
- `dn_object_manyfiles_residue`：~1e5 个小对象文件，删除 + 迁移后新副本不得残留。
- `dn_object_delete_residue`：TDB-861 快照/GC 竞争窗口，新增副本不得保留 leader 已删除的文件。

## 已跑版本与结论

| 版本 | 矩阵 | 结论 |
|---|---|---|
| V2.0.12.1 RC11（`ea4f835`，2026-10-23） | 2026-10-24 全量 30 条 | 27 PASS / 1 FAIL / 2 SKIP；FAIL 为 `dn_remove_restart_sweep`（节点停机期间 replica 不一致，另案）；OBJECT 三条当时 skip |
| 同上 | 2026-10-29 四条 OBJECT 单独跑 | 全部 PASS：`single_4g` 1419.5 s、`big_migrate` 5320.5 s、`manyfiles` 998.2 s、`delete_residue` 805.1 s |
| 同上 | 2026-10-29 流式读回 | 4 GiB 单点 16/16 段一致（迁移前/后），两副本 `.bin` 均 4 294 967 296 字节 |

## 已发现的缺陷（本模块产出）

| 单号 | 标题 | 状态 |
|---|---|---|
| TDB-893 | OBJECT 文件无法硬链接时 region 迁移整体失败，错误信息无法定位 | 已录入 PLM，排期确认（负责人 高宏志，迭代 V2.0.13.1） |
| TDB-861 | OBJECT 快照/GC 竞争导致新副本残留已删除的对象文件 | 已有探针用例守护（`dn_object_delete_residue`） |
| TDB-835 | 迁移后 `ObjectSize` 统计为 0（`<time>_<version>.bin` 未被索引） | 已有守卫用例 `dn_object_size_after_migration` |

缺陷详情见 `docs/defect-TDB-893-object-snapshot-hardlink.md` 与 `docs/known-defects.md`。

## 环境说明

`conf/cluster.conf` 里保留的是本模块实测所用 RC11 集群（3 ConfigNode + 5 DataNode，SR=3/DR=2，
IoTConsensus，双数据目录）。换到别的测试机（例如 172.20.70.17）时只需要改：

```conf
HOSTS=10.0.0.1,10.0.0.2,...      # 你的节点
DB_DIR=/data/...                 # 版本安装目录
```

其余（用例矩阵、OBJECT 分块大小 `OBJECT_SINGLE_*`、迁移等待时间等）都有默认值，见 `SKILL.md`。
driver 机器要求 python3 ≥ 3.9，无第三方依赖；iot-benchmark 由框架按版本自动获取。
