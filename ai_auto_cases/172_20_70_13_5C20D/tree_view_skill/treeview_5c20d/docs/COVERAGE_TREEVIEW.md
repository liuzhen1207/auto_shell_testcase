# 树转表视图（Tree View）测试用例 —— 需求点覆盖矩阵

被测版本：`master_1026_dc11a35`（2.0.11-SNAPSHOT，BuildInfo `dc11a35`）
环境：5 ConfigNode + 20 DataNode，**SchemaRegion 3 副本 / DataRegion 3 副本**，共识协议 `IoTConsensus`（默认值）
用例集：`scripts/pgkit/cases_treeview.py`（34 条，ID 前缀 `TV-`）

需求来源：
1. `树转表——需求分析（V2.0.5.1-开源）.docx`（/data/deepseek/skill_case/tree_view）
2. PLM doc 90：`V2.0.13.1-…-树转表视图自动检测新增测点-需求分析`
3. PLM doc 913：同名技术设计
4. PLM 测试项 **TDB-343**

## 1. 需求点 → 用例映射

### 1.1 docx 需求（基础树转表视图）

| # | 需求点（原文要点） | 用例 |
|---|---|---|
| R1 | CREATE VIEW 语法：`viewColumnDefinition` 支持 TAG / FIELD / TIME，`FROM original_measurement`，COMMENT，RESTRICT，WITH properties | TV-BASE-01、TV-BASE-04、TV-BASE-15 |
| R2 | `prefixPath` 必须以 `**` 结尾，且其它层级不能出现 `*`/`**` | TV-BASE-02 |
| R3 | 未指定 FIELD 时扫描 prefixPath 下全部测点；列名取测点名、类型由扫描决定 | TV-BASE-03 |
| R4 | 列只支持 tag/field/time，**不支持 attribute**（树模型无 attribute 概念） | TV-BASE-05 |
| R5 | TAG 数量决定设备层级；`RESTRICT` 只匹配层级**严格等于** tag 数的设备 | TV-BASE-06 |
| R6 | 同名但不同类型测点 → 创建报错 | TV-BASE-07 |
| R7 | 未扫描到任何测点 → 创建报错 | TV-BASE-08 |
| R8 | `OR REPLACE`：替换 view；同名 table 报错；无 OR REPLACE 时同名报错 | TV-BASE-09 |
| R9 | WITH ttl：视图 TTL 生效；**不改变**树模型设备的真实 TTL；与树 TTL 取更小 | TV-BASE-10 |
| R10 | 对齐设备全 null 行**保留**（表模型语义）；非对齐设备全 null 行不保留 | TV-BASE-11（对齐）、TV-BASE-01（普通查询） |
| R11 | show tables details 增加 `TableType`：BASE TABLE / VIEW FROM TREE / SYSTEM VIEW | TV-BASE-12 |
| R12 | show create view / show create table（view 两者一致；base table、information_schema 报错） | TV-BASE-13 |
| R13 | ALTER VIEW：RENAME TO / RENAME COLUMN / ADD COLUMN(TAG,FIELD) / DROP COLUMN / SET PROPERTIES | TV-BASE-14 |
| R14 | COMMENT ON VIEW / COMMENT ON COLUMN | TV-BASE-15 |

### 1.2 doc 90（`auto_sync_schema`，TDB-343 核心）

| # | 需求点（原文要点） | 用例 |
|---|---|---|
| S1 | `auto_sync_schema` 默认 **false**；show create view 能查看该属性 | TV-SYNC-01、TV-SYNC-02 |
| S2 | 显式 false 时行为与默认一致（新测点不加列） | TV-SYNC-02 |
| S3 | true 时新增测点自动成为视图列（`create timeseries`） | TV-SYNC-03 |
| S4 | true + 对齐序列 / 批量多测点 → 多列自动补齐 | TV-SYNC-04 |
| S5 | true + `insert` 自动建测点（含多设备）→ 自动加列且数据可查 | TV-SYNC-05 |
| S6 | 模板：激活模板（含批量/内部批量）与 `ALTER SCHEMA TEMPLATE` 扩列 → 视图自动加列 | TV-SYNC-06 |
| S7 | 该属性**只对树转表视图**生效；base table / 逻辑视图加该属性报错 | TV-SYNC-07 |
| S8 | 新序列名小写与已有列冲突 → **不加列**，记 warn（日志不暴露原序列名） | TV-SYNC-08 |
| S9 | 新序列名已作为某列的 `original_name` → 不加列，但查询仍能取到该列数据 | TV-SYNC-09 |
| S10 | 序列名含大写 → 列名取小写，原序列名记为 `original_name` | TV-SYNC-10 |
| S11 | 与 `RESTRICT` **正交**（两个配置互不影响） | TV-SYNC-11 |
| S12 | `SET PROPERTIES auto_sync_schema`：false→true 需扫描合并；true→false 直接关闭 | TV-SYNC-12 |
| S13 | false→true 时列类型冲突的处理 | TV-SYNC-13 | ✅ **研发确认口径（2026-10-29）**：**仅创建视图时**校验类型冲突（无 dataType 时失败 614）；`SET PROPERTIES`/自动加列**默认忽略冲突**（跳过该列，属性照常置 true，冲突列取 NULL） |
| S14 | 删除测点**不会**自动删列；该列查询为 null | TV-SYNC-14 |
| S15 | 建序列时若序列已在视图列中则不加列；扩列失败只记日志、不影响序列创建（尽力而为） | TV-SYNC-08（不加列）、TV-HA-01/02（部分副本不可用仍成功） |
| S16 | 类型系统：树模型不支持 OBJECT 类型测点；视图声明 OBJECT 列需给出明确错误 | TV-SYNC-15 |
| S17 | 新建序列命中视图 → 先扩列再建序列；失败重试后仍失败则记 error（不影响写入） | TV-HA-01、TV-HA-02（间接覆盖失败/重试路径） |

### 1.3 doc 913（技术设计约束）

| # | 设计约束 | 用例 |
|---|---|---|
| D1 | DN 侧用**前缀树**把序列路径匹配到视图：RESTRICT/非 RESTRICT、多层路径都要正确匹配 | TV-BASE-06、TV-SYNC-11 |
| D2 | `addViewColumn` 由 **CN procedure** 驱动，异步生效（需有界等待后可见） | TV-SYNC-03/04/05/06（`_await_cols` 等 60s） |
| D3 | 同一日志在 leader/follower 各执行一次，CN 用 queryId 去重；并发 procedure 冲突重试 | TV-SYNC-04（一次建多列）、TV-LEAK-01（连续多轮） |
| D4 | 扩列是**尽力而为**：失败只记日志、绝不阻断写入 | TV-HA-01、TV-HA-02（停 1/2 台 DN 仍写入并扩列） |
| D5 | 视图卸载/重命名/删库后前缀树要清理（避免残留匹配） | TV-BASE-09（replace）、TV-BASE-14（rename）、TV-LEAK-01（反复建删） |
| D6 | 重启后从前缀树重建、属性持久化 | TV-HA-03（整集群重启） |

### 1.4 非功能（doc 90 §3.3）

| # | 要求 | 用例 / 说明 |
|---|---|---|
| N1 | 未命中视图时写入性能与原来一致 | 未做基准对比（需 `BENCH_CMD`），列为后续项 |
| N2 | 兼容性：老版本升级后可用 | 需要 1.3 → 2.0 升级环境，本轮不做，记为后续项 |
| N3 | 新功能无内存/线程泄漏 | **TV-LEAK-01** |
| N4 | 高可用：部分副本不可用、整集群重启 | **TV-HA-01 / TV-HA-02 / TV-HA-03** |

### 1.5 明确暂不覆盖（需要额外环境）

| 需求点 | 原因 |
|---|---|
| 权限（create/alter/drop 需 CREATE/ALTER/DROP；select view 只需 view 的 SELECT，不需源序列 READ_DATA） | 需要开启鉴权并建多用户；单集群默认 root 下无法验证 |
| 元数据同步（表模型 pipe 同步 VIEW；树模型 inclusion=all 的 pipe 不同步 view） | 需要两个集群 + pipe |
| `SQL SECURITY invoker/definer` | 需要鉴权环境 |
| 老版本升级兼容 | 需要 1.3/2.0 升级链路 |
| 未命中视图的写入性能 | 需要 benchmark 环境 |

## 2. 用例纪律（每条用例都执行）

1. **干净集群**：与其它用例无关的用例都从 `prepare` 出来的干净集群开始（停 25 节点 → 清 data/logs → 写 conf → 启动）。
2. **收尾三件套**（框架自动追加）：
   - ① `sync lag` 等到归 0（有界超时）；
   - ② 副本一致性：**全在线查询结果为基线**，然后**一次性停 2 台 DN** 再查同一数据集，与基线逐字比对（20D 下只停一次，避免逐台停导致耗时过长）；
   - ③ CN/DN 日志扫描 ERROR/WARN，命中未归因的异常即 FAIL。
3. **FAIL 时备份日志**：`run_case_clean.sh` 在判定 FAIL 后把 CN/DN 的 `log_*` 目录打包到
   `results/<run>/cases/<CASE>/evidence/logs_<host>.tar.gz`，并附 `log_findings.txt`（命中行）
   与 `log_context.txt`（异常栈上下文）。
4. **判定口径**：只按 SQL 实际输出判定；`SKIP`（环境不具备）不等于 PASS。

## 3. 运行方式

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW
# 部署（一次性）
cd treeview_5c20d && bash scripts/pg.sh --conf conf/cluster.treeview_5c20d.conf deploy --clean && cd ..
# 单条（干净集群）
bash run_case_clean.sh conf/cluster.treeview_5c20d.conf tv1 TV-BASE-01
# 批量
CASES="TV-BASE-01 TV-BASE-02 TV-SYNC-03"
for c in $CASES; do bash run_case_clean.sh conf/cluster.treeview_5c20d.conf tv1 "$c"; done
```
