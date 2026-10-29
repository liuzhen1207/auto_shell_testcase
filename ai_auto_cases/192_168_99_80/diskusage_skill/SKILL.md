# 磁盘占用统计 skill（IoTDB / TimechoDB 2.0.12.1）

面向 **磁盘空间占用统计**（`SHOW DISK_USAGE` / `information_schema.table_disk_usage`）的自动化用例集：
既验证统计功能本身的正确性（树模型 + 表模型、有数据），也用**合并是否被卡死**作为门禁回归
已登记缺陷 **TDB-629**。

- 目标版本：**RC6 `v20121rc6_1010_7ae8713e`（2.0.12.1 / `7ae8713e`）**；门禁用例需在**修复前版本**
  （RC5 `v20121rc5_1003_aaf460d`）上也跑一遍做对照。
- 运行环境：99.80 框架机 + 3C3D 集群（192.168.99.77/78/79，各 1 CN + 1 DN，RF=3，IoTConsensus）。
- 本机路径：`D:\IDEA\deepseek\ip99_80\diskusage_skill`；交付/归档：`D:\IDEA\deepseek\compaction\`
- 99.80 部署路径：`/data/iotdb/autotest/diskusage_skill`

## 快速开始

```bash
# 0) 部署（本机 -> 99.80）
scp -r D:\IDEA\deepseek\ip99_80\diskusage_skill root@192.168.99.80:/data/iotdb/autotest/

# 1) 在 99.80 上跑（每条用例自己 清集群/写配置/启动；串行执行）
cd /data/iotdb/autotest/diskusage_skill
bash tools/run_all.sh --set gate            # DU-01/DU-02（TDB-629 门禁）
bash tools/run_all.sh --set stats           # DU-03/DU-04/DU-05（统计正确性 + 权限）
bash tools/run_all.sh --set all             # 全部
bash tools/run_all.sh --only DU-03 --ver v20121rc6_1010_7ae8713e

# 2) 双版本门禁（先在修复前版本复现，再在 RC6 验证修复）
bash tools/run_gate_versions.sh             # 默认 RC5 -> RC6，自动切/还原 conf/test.conf
```

结果：`results/test_result.csv`（build/用例/结果/耗时/fail 数/产物/message）+ `results/<ID>_<runid>.out`。
用例判定行格式：`RESULT PASS|FAIL fail_flag=N case=... build=... elapsed=...s`。

## 用例清单（`cases/cases.tsv`）

| ID | 脚本 | 模型 | 覆盖 |
| --- | --- | --- | --- |
| **DU-01** | `cases/tree/du_tree_merge_after_stats.sh` | 树 | **TDB-629 门禁**：`SHOW DISK_USAGE` 之后合并必须仍能推进（阶段 A 正向对照 + 阶段 B 缺陷触发） |
| **DU-02** | `cases/table/du_table_merge_after_stats.sh` | 表 | **TDB-629 门禁**（表模型接口）：`information_schema.table_disk_usage` 之后合并必须仍能推进 |
| DU-03 | `cases/tree/du_tree_stats.sh` | 树 | 统计正确性（有数据）：表头/列语义、值>0 且 ≤ 物理文件大小、`*`/`**`/设备级 pattern 作用域、多库隔离、ORDER BY/LIMIT、空结果集 |
| DU-04 | `cases/table/du_table_stats.sh` | 表 | 统计正确性（有数据）：表头/列语义、表间差异、where database/table_name、GROUP BY 聚合一致性、不存在的表→空集、视图不出现 |
| DU-05 | `cases/common/du_privilege.sh` | 树+表 | 权限与错误路径：无 SYSTEM 权限被拒、授权后可执行、非法 pattern 报错、表模型越权行为 |

## 本轮实测发现（2.0.12.1 RC6，写断言前必读）

- **树模型 pattern 的匹配对象是"设备路径"**（源码 `TreeDiskUsageStatisticUtil.matchPathPattern` →
  `pathPattern.matchFullPath(devicePath)`），所以只有"深度等于设备路径"的 pattern 才有数：
  | pattern | 实测合计（库内 3 设备有数据） | 说明 |
  | --- | --- | --- |
  | `root.db.**` | **2952** | 库内所有设备（基准） |
  | `root.db.*` | **2952** | 一层通配正好落到设备名 |
  | `root.db.d1` | **912** | **精确设备路径可用**（设备级统计的正确写法） |
  | `root.db.d1.**` / `root.db.d1.*` | **0** | `**`/`*` 需要至少一层，设备路径下没有子层 ⇒ 匹配不到设备本身 |
  | `root.db`（无通配） | 0 | 库路径比设备路径浅 |
  | `root.*` | 0 | 一层通配落在**库名**上，不是设备名 |
  | `root.db.nosuchdev` / `.**` | 0 | 无设备匹配时**仍按 region/时间分区出行**，只是 `SizeInBytes=0` |
  ⇒ 需求文档只说"中间节点支持 `*`/`**`"，没写这个边界；`.<设备>.**` 会得到 0 是**最容易被误用的写法**，用例里已记录该观察。
- **表模型结果集比需求文档多一列 `table_type`**（实测表头：
  `database|table_name|table_type|datanode_id|region_id|time_partition|size_in_bytes`）。
  ⇒ **取值一律按列名解析**（`du_col_idx`/`du_col_vals`/`du_col_sum_*`/`du_group_val`），写死列号会取错。
- **表模型聚合列是 double**（`sum(size_in_bytes)` 实测输出形如 `1698.0`）。
  ⇒ 数值解析必须用 awk 的 `+0`，**不要用 `gsub(/[^0-9-]/,"")`**（会把小数点也去掉，结果放大 10 倍——本项目踩过）。
- **表模型接口没有复现 TDB-629**（`information_schema.table_disk_usage` 统计后合并照常推进，卡死线程 0）：
  表模型统计有一条"免打开文件"快路径（命中大小索引时直接取索引值），不打开文件就不泄漏读锁；
  树模型 `calculateWithoutOpenFile()` 恒返回 false，必然打开文件 ⇒ 门禁以树模型为准。
- 权限：**表模型接口同样要求 SYSTEM 权限**（零权限用户实测 `803: Access Denied: No permissions for this operation,
  please add privilege SYSTEM`）；用 `sq_as`/`sqt_as` 以指定用户执行时**必须把 SQL 一起传下去**
  （曾写成 `du_tree_as(){ sq_as "$1" "$2"; }` 丢掉 SQL，表现为 `$3: unbound variable` 且静默返回空）。
- `show tables from <db>`、`create table <db>.<表> (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD)` 可用来校验表模型场景是否真的建好了
  （用例把"场景有效性"做成硬断言，避免 DDL 写错却一路 PASS）。

## 关键实测结论（写用例/看结果前必读）

- **TDB-629 的触发与观测**：统计查询在采集阶段泄漏读锁（详见 `docs/DESIGN.md`），
  被扫过的 TsFile 之后再也拿不到写锁 ⇒ 合并任务永久阻塞。**光看"统计结果对不对"是发现不了的**——
  必须把合并开成"很容易触发"（`inner_compaction_candidate_file_num=2`、`compaction_schedule_interval_in_ms=1000`），
  在统计之后观察"合并完成行数增加 + 该库 TsFile 数下降"。
- **必须先关合并再写数据**：否则数据在统计前就合并完了，阶段 B 没有"未合并文件"可观察。
  合并开关（`enable_seq_space_compaction` / `enable_unseq_space_compaction`）实测**可热加载**
  （`SET CONFIGURATION 'k'='v'`，树方言）。
- **两个独立信号同时成立才算合并发生**：`InnerSpaceCompaction task finishes successfully` 行数
  与"该库 TsFile 数下降"。只看其中一个会把 flush 落盘误判成合并。
- **树模型必扫**：`TreeDiskUsageStatisticUtil.calculateWithoutOpenFile()` 恒返回 `false`，
  所以任何 `SHOW DISK_USAGE` 都会打开并"扫过"该库所有已关闭 TsFile ⇒ 泄漏是必然的。
- **表模型有快路径**：`TableDiskUsageStatisticUtil.calculateWithoutOpenFile()` 在
  ①该 TsFile 已在大小索引里、或 ②库内只有一张表且无 mods 时返回 true（不打开文件、不泄漏）。
  所以表模型门禁必须：**库内 ≥2 张表** + **统计发生在这些 TsFile 还没进索引时**（集群刚起、此前没跑过统计查询）。
- **判定前先确认 TsFile 已落盘**：未 `Async close` 的文件不参与合并选择；用例用 `ensure_closed`
  反复 flush 并等 `Async close tsfile: ...<db>` 事件（`flush;` 不保证三副本及时关闭）。
- **别让 TTL/settle 合并混进来**：`conf/env.conf` 把 TTL 参数设成中性值
  （`expired_data_ratio=1.0`、`max_expired_time=INF`、检查间隔 2h），观测只针对 inner compaction。
- **数据目录布局**：`data/datanode/data/{sequence,unsequence}/<db>/<timePartition>/<regionId>/<*.tsfile>`；
  按库统计 TsFile 用 `-path '*/<db>/*'`（整段匹配，避免 `root.db` 命中 `root.db2`）。
- **合并日志文案**（源码 `StorageEngineMessages`）：
  `{db}-{region} [Compaction] {Sequence|Unsequence} InnerSpaceCompaction task starts with N files, ...` /
  `... task finishes successfully, ...`；表模型库在日志里可能带 `root.` 前缀，正则统一写 `(root\.)?<db>`。

## harness 说明

- `lib/common.sh` 是**与 TTL skill 共用的通用 harness**（函数前缀 `ttl_`：环境加载、ssh/SQL、
  断言、集群生命周期、收尾三件套、结果 CSV）。本 skill 在 `lib/du.sh` 里提供 `du_*` 别名
  以及磁盘占用/合并观测的专用 helper。
- 覆盖的通用能力：`du_load_env` / `du_parse_args` / `du_case_init` / `du_cluster_prepare` /
  `du_case_finish`；`sq`/`sqt`/`sq_as`/`sqt_as`；`log/pass/fail/warn`；
  `assert_contains`/`assert_not_contains`/`assert_eq`/`assert_error_code`；
  `post_checks`（sync lag → 副本一致性 → CN/DN 日志扫描）；`ensure_closed`。
- 专用 helper：`du_tree` / `du_table_all` / `du_table_where` / `du_table_sql`、`du_header`、
  `du_tree_row_cnt|size_sum|col_uniq`、`du_table_row_cnt|size_sum`、`du_tsfile_*`（数量/字节/清单）、
  `du_cmp_start_sum|finish_sum|log_tail`、`du_wait_merge`、`du_stuck_writelock_sum`/`du_stuck_stack`（jstack）、
  `du_set_hot`、`du_cmp_conf`、`du_make_tree_db`/`du_write_tree_batch`/`du_make_table_db`/`du_write_table_batch`。

## 目录

```
diskusage_skill/
├── conf/env.conf              # 环境 + 合并参数 + 观察窗口（迁移只改这里）
├── lib/common.sh              # 通用 harness（与 TTL skill 共用）
├── lib/du.sh                  # 本 skill 专用 helper
├── cases/cases.tsv            # 用例矩阵（机器可读）
├── cases/tree/du_tree_merge_after_stats.sh    # DU-01 门禁（树）
├── cases/table/du_table_merge_after_stats.sh  # DU-02 门禁（表）
├── cases/tree/du_tree_stats.sh                # DU-03
├── cases/table/du_table_stats.sh              # DU-04
├── cases/common/du_privilege.sh               # DU-05
├── tools/run_all.sh           # 用例集合入口
├── tools/run_gate_versions.sh # 双版本门禁（修复前复现 → RC6 验证）
├── docs/DESIGN.md             # 功能、代码链、TDB-629 根因与修复、门禁设计
├── docs/REQ_diskusage.md      # 需求文档要点（含原文抽取件 req_disk_usage.txt）
└── results/                   # 运行产物与 test_result.csv
```
