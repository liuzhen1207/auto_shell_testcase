# 【环境受限】树转表视图 + 模板（device template）链路在 2.0.13.1 无法组合验证

| 项目 | 内容 |
| --- | --- |
| 需求 | TDB-343 树转表视图自动扩列 |
| 需求文档 | PLM `docs/90` §3.2.2 第 7 条、§3.4 场景 2（模板交互） |
| 验证版本 | TimechoDB 2.0.13.1 / `ab6d3de`，3C5D |
| 结论 | **当前版本中「模板」只支持树模型库，而「树转表视图」必须建在表模型库，二者不能同时成立**，故场景 2（模板激活/模板扩展触发补列）无法在本环境验证 |
| 对应用例 | RN-173、RN-174（已标记 `SKIP_OF`，默认跳过并带原因） |

---

## 一、文档怎么说

需求文档 §3.2.2：

> - 和模板 template 的交互：当激活模板，或者给模板新增新测点，则激活该模板的路径下就多了测点，同样视为新增测点，相关的树转表视图也会自动检测并新增列；

§3.4 场景 2 给出了完整 SQL：

```sql
CREATE DEVICE TEMPLATE t1 (s1 FLOAT, s2 DOUBLE);
SET DEVICE TEMPLATE t1 TO root.autoDB;
CREATE VIEW view_03 (dev STRING TAG) WITH (auto_sync_schema = true) AS root.autoDB.**;
CREATE TIMESERIES USING DEVICE TEMPLATE ON root.autoDB.dev04;
ALTER SCHEMA TEMPLATE t1 ADD (s3 INT64);
```

设计文档 §4.3.3 也写了模板激活（`visitBatchActivateTemplate`）与模板扩展（`UPDATE_TEMPLATE_INFO`）两条触发路径。

## 二、实测被卡在哪

### 2.1 表模型库中设置模板失败

```sql
CREATE DATABASE db1;                                  -- 表模型库（视图必须建在这里）
CREATE DEVICE TEMPLATE tpl(ta FLOAT, tb DOUBLE);      -- 成功
SET DEVICE TEMPLATE tpl TO root.db1.dev05;
-- 500: Database is not set for current seriesPath: [root.db1.dev05]
```

### 2.2 树模型库中建视图失败

```sql
CREATE DATABASE root.db2;                             -- 树方言建库
CREATE DEVICE TEMPLATE tpl2(ta FLOAT);                -- 成功
SET DEVICE TEMPLATE tpl2 TO root.db2.dev05;           -- 成功
CREATE TIMESERIES USING DEVICE TEMPLATE ON root.db2.dev05;  -- 成功
CREATE VIEW db2.v1(dev STRING TAG) WITH (auto_sync_schema = true) AS root.db2.**;
-- 500: Unknown database db2
```

`show databases`（表方言）也看不到 `root.db2`：

```
（root.db2 不出现）
```

### 2.3 结论

| 需求 | 所属模型 | 结果 |
| --- | --- | --- |
| `SET DEVICE TEMPLATE ... TO root.db.dev` | 要求树模型库 | 表模型库 → 500 Database is not set |
| `CREATE VIEW db.v(...) AS root.db.**` | 要求表模型库 | 树模型库 → 500 Unknown database |
| 二者组合（文档场景 2） | — | **无法构造** |

## 三、影响与建议

### 影响

- 需求文档 §3.2.2「模板交互」与 §3.4「场景 2」在本版本**无法落地验证**；
- 若用户按文档操作（树模型库 + 模板 + 视图），会在建视图这一步失败；
- 用例 RN-173/RN-174 已在套件中标记 `SKIP_OF`，不参与 PASS 判定，但会以 `SKIP（模板仅支持树模型库，树转表视图需表模型库）` 出现在结果里，不会静默消失。

### 建议确认（给研发）

1. 树转表视图是否支持树模型库？若支持，正确的建视图语法/前置条件是什么（例如需要 `USE db` 或某个开关）；
2. 若只支持表模型库，那么模板链路（§3.2.2 第 7 条）在表模型下应如何触发？是否需要先把模板能力扩展到表模型库；
3. 文档 §3.4 场景 2 的示例 SQL 是否在某个特定构建/配置下才成立，若是请补充前置条件说明；
4. 若确认本版本不支持模板触发，建议在需求文档与手册中标注「本版本暂不支持」，避免用户按文档操作踩坑。

## 四、复现材料

```bash
# 环境
172.16.2.205 集群（3 CN + 5 DN），TimechoDB 2.0.13.1 / ab6d3de

# 关键命令
create database db1;                                          # 表方言
create device template tpl(ta float, tb double);              # 树方言
set device template tpl to root.db1.dev05;                    # -> 500 Database is not set

create database root.db2;                                     # 树方言
set device template tpl to root.db2.dev05;                    # 成功
create timeseries using device template on root.db2.dev05;     # 成功
create view db2.v1(dev string tag) with(auto_sync_schema=true) as root.db2.**;  # -> 500 Unknown database
```
