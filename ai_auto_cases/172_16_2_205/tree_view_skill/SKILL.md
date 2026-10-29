# tree_view_skill —— 树转表视图 auto_sync_schema 回归

被测特性：树转表视图的 `WITH (auto_sync_schema = true)` 自动识别树模型新增测点并补列（PLM **TDB-343**，V2.0.13.1，P0）。

## 一键回归

```bash
# 全量（67 条，含重建、执行、归因、汇总）
bash tools/run_regression.sh <build_dir> IoTConsensusV2 TDB-343

# 只跑某组 / 某条
bash tools/suite.sh TV-080 TV-081 TV-090
bash tools/suite.sh TV-0
```

`run_regression.sh` 串起：部署校验（给了 `PKG_ZIP` 且未安装时先部署）→ 切协议 → 清库重建 → 激活校验 → 跑全部用例 → 归因 → 写 `results/REGRESSION_<build>_<协议>_<时间戳>/summary.md`。

退出码：`0` 无新增失败；`10` 有新增失败（已知缺陷按 `conf/known_failures.conf` 排除）；`3/4/5` 部署/集群就绪/激活不通过。

## 用例分组（67 条）

| 文件 | 组 | 条数 | 覆盖 |
| --- | --- | --- | --- |
| `cases/g1_attr.sh` | 属性与语法 | 8 | `WITH(auto_sync_schema)` 语法、默认值、`SHOW CREATE VIEW`、仅树转表视图可设 |
| `cases/g2_entries.sh` | 补列入口 | 8 | CREATE TIMESERIES / ALIGNED / INSERT 自动建序列 / 多设备 / 模板激活 / 模板扩展 |
| `cases/g3_conflict.sh` | 冲突与类型 | 7 | 同名不同类型、仅大小写不同、original name、FIELD 类型择优 |
| `cases/g4_query_toggle.sh` | 查询与生命周期 | 9 | 查询语义、开关切换与回填、改名、删视图/库、重启持久化、RESTRICT 正交 |
| `cases/g5_ddl.sh` | DDL 组合 | 8 | 手动 ADD/DROP/RENAME COLUMN（含 tag、object）与 auto 开关的组合 |
| `cases/g6_ha.sh` | 高可用 | 7 | DN 停机、CN 切主、kill -9、双 DN 停机 |
| `cases/g7_isolate.sh` | DN 隔离 | 1 | 元数据租约失效（535/536）时建序列失败、恢复后补列 |
| `cases/g8_rename.sh` | 序列改名×视图 | 10 | `ALTER TIMESERIES ... RENAME TO` 后 TAG、跨库改名、清理链、RESTRICT、持久化 |
| `cases/g9_load.sh` | LOAD TSFILE×视图 | 8 | `LOAD` 触发补列、已存在列、前缀外、auto_sync=false、RESTRICT、重复 LOAD、重启 |

## 每条用例的收尾检查

1. 8 个节点日志增量，按「功能路径 / HA 噪声 / 其它」归因；
2. 各 DN `iot_consensus{type="syncLag"}` 归零；
3. 有 `一致性校验 SQL` 的用例：全在线结果作基线 → 停 `172.16.2.2` 比对 → 停 `172.16.2.5` 比对 → 恢复；
4. 判 FAIL 的用例自动备份 CN/DN 日志到 `results/fail_logs/<用例ID>/`。

## 已知缺陷（不阻断流水线）

| 缺陷 | 用例 | 说明 |
| --- | --- | --- |
| [TDB-888](https://plm.infra.timecho.com/iterations?productId=1&itemId=1480) | TV-080/081/082/088 | 树模型改名后视图不同步（TAG 旧设备名、跨库改名后目标库视图 0 行） |
| [TDB-890](https://plm.infra.timecho.com/iterations?productId=1&itemId=1485) | TV-003/010/011/012/014/015/016/018/020/022/030/033/034/038/050/053/060 | 自动补列在「列已存在」时报 ERROR（552/305），功能正确、日志异常 |

缺陷修复后把对应行从 `conf/known_failures.conf` 删掉，这些用例即转为正向回归。

## 目录

```
tree_view_skill/
├── SKILL.md                本文件
├── README.md               安装/运行/产物说明
├── cases.tsv               用例矩阵（机器可读）
├── cases/                  g1..g9 + MANIFEST.md5
├── conf/env.conf           环境配置（拓扑、版本路径、账号、协议）
├── conf/known_failures.conf 已知缺陷白名单
├── lib/lib.sh              断言、日志增量、sync lag、副本一致性、DN/CN 启停
├── tools/                  suite / hard_reset / deploy_build / run_regression / classify_run
└── docs/                   回归报告、改名报告、LOAD 报告、缺陷报告、RUNBOOK
```
