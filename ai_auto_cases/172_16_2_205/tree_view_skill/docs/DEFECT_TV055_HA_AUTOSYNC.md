# 缺陷描述（待登记）：kill -9 一台 DataNode 后，树转表视图未补列 / 建序列误报 503

> 状态：**未登记**（缺 PLM 字段：迭代、负责人、所属组长、验证人员待填）
> 关联用例：`tree_view_skill/cases/g6_ha.sh::case_TV055`（"kill -9 一台 DN 后序列创建与补列"）
> 复现环境：TimechoDB **2.0.13.1 / ab6d3de**，3C5D，IoTConsensusV2

## 一、建议字段

| 字段 | 建议值 |
| --- | --- |
| 标题 | 【V2.0.13.1】【树转表视图】kill -9 一台 DataNode 后视图未补列，且建序列偶发误报 `503 already exist` |
| 类型 | 缺陷 |
| 优先级 | **P1**（功能缺失：DN 单点故障时视图列缺失，查询结果不完整；且 503 误报会误导客户端重试/判定失败） |
| 严重程度 | 严重 |
| 复现概率 | 必现（隔离复跑仍失败）；两种表现随执行时机不同 |
| 产品/企业开源 | TimechoDB / TimechoDB |
| 模型 | 通用（树模型 → 表视图） |
| 问题发现版本 | V2.0.13.1（BuildInfo ab6d3de） |
| 需求来源 | 测试需求（TDB-343 树转表视图） |

## 二、环境

| 项目 | 值 |
| --- | --- |
| 版本 | 2.0.13.1，BuildInfo **ab6d3de**，安装目录 `v20131rc1_1030_ab6d3de` |
| 集群 | 3 ConfigNode（172.16.2.26/27/28）+ 5 DataNode（172.16.2.2~6），SR=3 / DR=2 |
| 共识协议 | **IoTConsensusV2**（`data_region_consensus_protocol_class`） |
| 关键配置 | 视图 `CREATE VIEW ... WITH (auto_sync_schema=true)`；其余默认 |

## 三、复现步骤

```sql
CREATE DATABASE root.tv055;
CREATE TIMESERIES root.tv055.d1.s1 INT32;
CREATE VIEW tv055.v(dev STRING TAG) WITH (auto_sync_schema=true) AS root.tv055.**;
-- 在 DataNode 172.16.2.5 上强制杀进程
--   ssh root@172.16.2.5 "pkill -9 -f 'com.timecho.iotdb.DataNode'"
-- 等 8 秒后创建新序列
CREATE TIMESERIES root.tv055.d2.s2 DOUBLE;
-- 等 12 秒后检查视图列
DESC tv055.v;   -- 期望出现 s2:DOUBLE
```

脚本：`tree_view_skill/tools/manual_tv060.sh` 同类探针；用例本体 `cases/g6_ha.sh::case_TV055`。

## 四、实际现象（两次执行，两种表现）

### 表现 A：`CREATE TIMESERIES` 误报 503 already exist（全量回归，2026-10-30 16:2x）

```
[FAIL] kill -9 一台 DN 后创建序列应成功: unexpected error ->
Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 503: Path [root.tv055.d2.s2] already exist
```

该序列此前**从未创建**（用例刚建 `d1.s1`，`d2.s2` 是新路径）。错误返回给客户端，用例判失败，后续补列断言未执行。

### 表现 B：创建成功但视图未补列（隔离复跑，2026-10-30 18:46，耗时 520s）

```
[FAIL] 其余副本应触发补列: column s2:DOUBLE absent, got [ ]
```

同时查询确认序列**已存在**：

```
+----------------+-----+----------+--------+--------+...
|root.tv055.d1.s1| ... |   INT32|...
|root.tv055.d2.s2| ... |  DOUBLE|...
```

即：树模型序列创建成功，但 `auto_sync_schema` 的**视图补列没有发生**（视图仍只有 `s1`）。

## 五、期望结果

1. 一台 DataNode 被强制杀掉后，只要 SR=3/DR=2 多数派可用，`CREATE TIMESERIES` 应返回成功（不应返回 503 already exist）；
2. 新序列创建后，`auto_sync_schema=true` 的视图应在秒级内补齐对应列（`s2:DOUBLE`），与 DN 是否全部在线无关（与单 DN 正常场景行为一致）；
3. 若补列确实无法完成，应返回明确错误，而不是静默不补。

## 六、影响

1. **查询结果不完整**：视图缺列，上层按列查询/写入会报列不存在或丢数据；
2. **故障场景放大**：DN 单点故障是生产常态（OOM、掉电、重启），该缺陷使视图在故障期间"半可用"；
3. **误导客户端**：503 already exist 会让客户端判定创建失败并重试，可能放大写入压力。

## 七、代码线索（供研发参考）

1. 视图补列入口：`ViewColumnAutoSyncTrigger.sync()`（DN 侧，按副本异步触发）→ CN `ProcedureManager.autoSyncViewColumns`；
2. 已知同类缺陷 **TDB-890**：CN `ClusterSchemaManager` 在"列已存在"时返回 `COLUMN_ALREADY_EXISTS(552)`，最终暴露为 `INTERNAL_ERROR(305)`（日志级问题，功能正确）；
3. 本单不同点：**功能缺失**（视图确实没补列）+ 503 误报。建议重点看：
   - DN 宕机时 `auto_sync` 触发器在哪个副本执行、失败后是否有重试/补偿；
   - `CREATE TIMESERIES` 在 SR/DR 副本切换窗口的失败重试是否把成功结果误判为 already exist；
   - 触发器是否依赖"所有 DN 在线"（若依赖，应改为多数派）。

## 八、证据

| 内容 | 位置 |
| --- | --- |
| 全量回归结果（表现 A） | `/data2/auto_test/treeview_suite/results/REGRESSION_v20131rc1_1030_ab6d3de_IoTConsensusV2_20261030_154808/`（`results.tsv` TV-055 行、`suite.log` 17:07:03 段） |
| 隔离复跑（表现 B） | `/data2/auto_test/treeview_suite/results/run_20261030_183758/`（TV-055 fails=1，detail 见 §四） |
| 失败现场日志 | `results/fail_logs/TV-055/`（每次失败自动备份 8 节点日志） |
| 用例源码 | `tree_view_skill/cases/g6_ha.sh::case_TV055` |
| 回归报告 | `REPORT_2.0.13.1_RC1.md` §2.3 |

## 九、备注

1. 同一轮回归中还有 **TV-037**（集群重启后 357 条 HA 日志、断言全通过），是否属预期待研发确认，与本单分开跟踪；
2. **两协议均复现（2026-11-02 补测）**：

| 协议 | 用例结果 | 表现 | 失败清单分类 |
| --- | --- | --- | --- |
| IoTConsensusV2（10-30） | 67 条：49 PASS / 18 FAIL（16 已知 + 2 新增） | TV-055 表现 A：`503 already exist`；隔离复跑表现 B：视图未补列 | FAIL_ASSERT |
| IoTConsensus 经典（11-02） | 67 条：47 PASS / 20 FAIL（19 已知 + **1 新增 = TV-055**） | TV-055 表现 A：**同样是 `503: Path [root.tv055.d2.s2] already exist`** | FAIL_ASSERT |

→ 结论：**与共识协议无关**（V2 与经典均复现），问题在「DN 强杀后建序列/补列」这条通用路径，而非 IoTConsensusV2 复制实现。

3. 附带观察：TV-037（集群重启后 HA 日志）在 V2 下 357 条被计入"新增/需人工确认"，在经典协议下 120 条被归为良性（未进失败清单）——倾向为重启窗口的预期噪声，建议研发确认后统一加白名单。
