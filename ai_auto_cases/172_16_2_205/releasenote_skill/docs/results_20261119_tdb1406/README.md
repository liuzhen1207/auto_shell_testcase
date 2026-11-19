# TDB-1406 树转表视图元数据导出验证（2.0.13.1 RC3 `ac7f95e`）

| 项 | 内容 |
| --- | --- |
| 来源工作项 | TDB-1406 / 【TIMECHODB-0366】[树转表] export-schema.sh 导出的视图定义不正确，生成的是创建表的 SQL |
| 修复提交 | `#16226` Modified implementation of exporting table schema to sql file using `show create table` |
| 验证版本 | 2.0.13.1 **RC3** `ac7f95e`，3C5D（SR3/DR2，IoTConsensus V1），普通模式 |
| 验证用例 | **RN-215**（与安全无关，单用例 + 干净环境） |
| 结果 | **PASS**（17 项断言全部通过，日志窗口 `err=0 warn=0 unexp=0`） |

## 一、验证步骤

1. 建库 `rn1406_db`、序列 `root.rn1406_db.d1.s1`、树转表视图 `rn1406_db.v1(dev string tag) with(auto_sync_schema = true) as root.rn1406_db.**`；
2. 基线：`show create table rn1406_db.v1` 应为 `CREATE VIEW`；
3. 导出：`tools/schema/export-schema.sh -sql_dialect table ... -t <dir> -db rn1406_db`；
4. 断言导出文件内容：
   - 含 `CREATE VIEW`
   - 含 `auto_sync_schema`
   - 含 `AS root`（视图定义）
   - **不含** `CREATE TABLE ... "v1"`（缺陷现象）
5. 删除视图后用 `import-schema.sh -s <dir> -db rn1406_db` 导入；
6. 断言导入后对象仍是视图（`CREATE VIEW` + `auto_sync_schema` 保留、含 FIELD 列 `s1`）；
7. 自动扩列回归：导入后新建序列 `imported_col`，视图中出现该列。

## 二、实测导出内容

```sql
DROP TABLE IF EXISTS "v1";
CREATE VIEW "v1" ("time" TIMESTAMP TIME,"dev" STRING TAG,"s1" DOUBLE FIELD)
  WITH (ttl='INF', auto_sync_schema=true) AS root."rn1406_db".**;
```

**结论：RC3 已修复** —— 视图导出为 `CREATE VIEW`（含 `AS` 与 `auto_sync_schema`），不再是创建表语句；导入后仍为视图且自动扩列可用。

## 三、日志检查（本轮新增能力）

按「新增用例都必须检查 CN/DN 日志」的要求，给 releasenote_skill 增加了逐用例日志窗口：

- `lib/logcheck.sh`：`log_mark` 记录 3 CN + 5 DN 的 `log_{confignode,datanode}_{error,warn}.log` 行号；`log_check` 扫描窗口新增行，过滤已知噪声（连接拒绝/选主/路由刷新等），输出 `err=N warn=M unexp=K` 并保存样本；
- `tools/suite_rn.sh`：`RN_LOG_CHECK=1` 时自动打点/扫描，`unexp>0` 判为 FAIL，结果写入 `results.tsv` 的 detail（`[LOG err=.. warn=.. unexp=..]`）。

本轮 7 个新增用例实测（每个用例独立 clean reset）：

| 用例 | 工作项 | 结果 | 日志窗口 |
| --- | --- | --- | --- |
| RN-209 | TDB-1497 连接数上限（普通） | PASS | `err=0 warn=0 unexp=0` |
| RN-210 | TDB-1497 连接数上限（三权分立） | PASS | `err=0 warn=0 unexp=0` |
| RN-211 | TDB-1442 DROP USER 断连（普通） | PASS | `err=0 warn=0 unexp=0` |
| RN-212 | TDB-1442 DROP USER 断连（三权分立） | PASS | `err=0 warn=0 unexp=0` |
| RN-213 | TDB-1429 元数据级联删除（普通） | PASS | `err=0 warn=0 unexp=0` |
| RN-214 | TDB-1429 元数据级联删除（三权分立） | PASS | `err=0 warn=0 unexp=0` |
| RN-215 | TDB-1406 视图导出（普通） | PASS | `err=0 warn=0 unexp=0` |

**即 7 个新用例均无不符合预期的 WARN/ERROR。**

## 四、文件

| 文件 | 内容 |
| --- | --- |
| `cases/TIMECHODB_0366_v2.0.13.1.sh` | RN-215 |
| `lib/logcheck.sh` | 日志窗口打点/扫描 |
| `tools/suite_rn.sh` | 接入 `RN_LOG_CHECK=1` |
| `RN-209.out` ~ `RN-215.out` | 7 个用例的断言明细 |
| `results_20261119_tdb1406/` | 本报告与上述证据 |
