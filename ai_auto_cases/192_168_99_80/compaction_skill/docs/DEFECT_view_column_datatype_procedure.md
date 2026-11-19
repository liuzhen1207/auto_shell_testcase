# 缺陷候选（待研发确认）：`ALTER VIEW … ALTER COLUMN … SET DATA TYPE` 让 ConfigNode 共识状态机抛 NPE

**发现版本**：`v20121rc6_1010_7ae8713e`（RC6，2.0.12.1 / `7ae8713e`，3C3D + IoTConsensus，ACTIVATED 企业版）
**发现用例**：`cases/common/dt_view.sh`（DT-07，视图列类型修改）
**现象分类**：ConfigNode（ConfigRegion）Ratis 状态机**应用日志失败**并反复抛 NPE（followers 各 18~36 条/次运行）

---

## 1. 现象（实测）

```
java.lang.NullPointerException: Cannot invoke
  "org.apache.iotdb.commons.request.IConsensusRequest.markAsGeneratedByRemoteConsensusLeader()"
  because "<local7>" is null
    at org.apache.iotdb.consensus.ratis.ApplicationStateMachineProxy.applyTransaction(ApplicationStateMachineProxy.java:153)
    at org.apache.ratis.server.impl.RaftServerImpl.applyLogToStateMachine(RaftServerImpl.java:1956)
    at org.apache.ratis.server.impl.StateMachineUpdater.applyLog(StateMachineUpdater.java:255)
    at org.apache.ratis.server.impl.StateMachineUpdater.run(StateMachineUpdater.java:194)

java.io.IOException: Unknown Procedure type: 766
    at org.apache.iotdb.confignode.procedure.store.ProcedureFactory.create(ProcedureFactory.java:452)
    at org.apache.iotdb.confignode.consensus.request.write.procedure.UpdateProcedurePlan.deserializeImpl(UpdateProcedurePlan.java:64)
    at org.apache.iotdb.confignode.consensus.request.ConfigPhysicalPlan$Factory.create(ConfigPhysicalPlan.java:664)
    at org.apache.iotdb.confignode.consensus.statemachine.ConfigRegionStateMachine.deserializeRequest(ConfigRegionStateMachine.java:184)
    at org.apache.iotdb.consensus.ratis.ApplicationStateMachineProxy.applyTransaction(ApplicationStateMachineProxy.java:146)
```

- 触发动作：`CREATE VIEW dtvw.v1 (s1 INT32 FIELD FROM s1, …) AS root.dtvwsrc.d1.**;` + `ALTER VIEW dtvw.v1 ALTER COLUMN s1 SET DATA TYPE DOUBLE;`
- 只在 **ConfigNode follower**（`.78`/`.79`）出现；leader（`.77`）无 NPE（leader 用本地对象应用，不走反序列化）。
- DDL 本身**返回成功**、`desc` 显示新类型、视图读数（`7|8| → 7.0|8.0|`）与底层序列合并都正确 ⇒ 用户可见功能"看起来正常"，
  但 **ConfigRegion 的这条 raft 日志在 follower 上永远应用不了**，每条日志按 apply 重试反复抛 NPE（实测 36 条/节点/轮）。

## 2. 源码根因链（RC6 = `7ae8713ecb`，`iotdb-core`）

| 步骤 | 位置 | 代码/事实 |
| --- | --- | --- |
| ① DDL 入口建 procedure | `confignode/…/manager/ProcedureManager.java:2492` | `new AlterViewColumnDataTypeProcedure(...)`，随后以 `UpdateProcedurePlan` 提交进 ConfigRegion |
| ② 序列化时的类型映射**有** | `…/procedure/store/ProcedureFactory.java:542-543` | `else if (procedure instanceof AlterViewColumnDataTypeProcedure) return ProcedureType.ALTER_VIEW_COLUMN_DATATYPE_PROCEDURE;` |
| ③ 枚举定义 | `…/procedure/store/ProcedureType.java:90` | `ALTER_VIEW_COLUMN_DATATYPE_PROCEDURE((short) 766)` |
| ④ 反序列化的 `switch` **缺 case** | `…/procedure/store/ProcedureFactory.java:450-452` | 落到 `default:` → `LOGGER.error("Unknown Procedure type: …")` + `throw new IOException(UNKNOWN_PROCEDURE_TYPE + typeCode)` |
| ⑤ 异常被吞成 null | `…/consensus/statemachine/ConfigRegionStateMachine.java:185-191` | `catch (Exception e) { LOGGER.error(DESERIALIZATION_ERROR…); return null; }` |
| ⑥ null 上直接调方法 → NPE | `consensus/…/ratis/ApplicationStateMachineProxy.java:145-153` | `deserializedRequest = …deserializeRequest(...)`；`if (!isLeader) deserializedRequest.markAsGeneratedByRemoteConsensusLeader();` |

**对照（同族 case 都在，唯独漏了 view 这一支）**：`create()` 里存在
`ALTER_TABLE_COLUMN_DATATYPE_PROCEDURE`（765，`:279-281` → `new AlterTableColumnDataTypeProcedure(false)`）、
`ADD_VIEW_COLUMN_PROCEDURE`、`RENAME_VIEW_COLUMN_PROCEDURE`、`PIPE_ENRICHED_ALTER_COLUMN_DATATYPE_PROCEDURE`（`:354-356`）、
`PIPE_ENRICHED_ALTER_TIMESERIES_DATATYPE_PROCEDURE`（`:357-359`）、可写视图的 `…_ALTER_WRITABLE_VIEW_COLUMN_DATATYPE_PROCEDURE`（`:680-681`），
**就是没有 `ALTER_VIEW_COLUMN_DATATYPE_PROCEDURE`（766）与 `PIPE_ENRICHED_ALTER_VIEW_COLUMN_DATATYPE_PROCEDURE`（1423）**
⇒ 属**漏写分支**，不是设计如此（`getProcedureType()` 明确会产出 766）。

**master 同样缺**（本地 `D:\IDEA\timechodb_src\master\timechodb` 全文检索两处 case 均为 0 命中）
⇒ 不是"RC 分支漏回合"，而是功能缺陷本身。

## 3. 影响评估

- **直接**：CN 日志被 NPE 刷屏（每轮 18~36 条/节点）；ConfigRegion 状态机在 follower 上**无法应用**该条日志。
- **风险**：leader 切换/重启后，新 leader 需要重放这条日志才能恢复 procedure 状态 —— 该日志反序列化必然失败，
  procedure 状态可能永久停留在"未完成"，并可能阻塞其后的 ConfigRegion 日志应用（Ratis 按序 apply）。
  即 `ALTER VIEW … ALTER COLUMN … SET DATA TYPE` 在**多 CN 集群下不具备真正的持久化一致性**。
- **不存在于兄弟功能**：树模型 `ALTER TIMESERIES … SET DATA TYPE`（302）、表模型 `ALTER TABLE … ALTER COLUMN … SET DATA TYPE`（765）
  都有 case，实测无此 NPE ⇒ 只有**视图**这一支受影响。

## 4. 修复建议（`ProcedureFactory.create()`，建议插在 `:281` 之后）

```java
case ALTER_VIEW_COLUMN_DATATYPE_PROCEDURE:
  procedure = new AlterViewColumnDataTypeProcedure(false);
  break;
case PIPE_ENRICHED_ALTER_VIEW_COLUMN_DATATYPE_PROCEDURE:
  procedure = new AlterViewColumnDataTypeProcedure(true);
  break;
```

> 第二支的类名/构造参数请研发按 pipe 侧既有实现确认（同族写法见 `:354-359`：`new XxxProcedure(true)`）。

## 5. 回归门禁

`bash cases/common/dt_view.sh`（DT-07）：用例在 `④' ConfigNode 侧 NPE 取证` 段落会打印**首条 NPE 的完整堆栈**
（含前 2 行触发日志 + 后 40 行），并在 CN 日志扫描阶段把 `NullPointerException` 计为 FAIL。

判据：
1. **必须**：CN 日志（3 个 CN 的 `log_confignode_all.log`）**不得出现** `NullPointerException` 或 `Unknown Procedure type: 766`；
2. 视图列类型修改的功能面（`desc` 新类型、读数按新类型转换、不兼容 701、不存在列 616、底层合并后读数不变）保持通过。

RC6 实测：`RESULT FAIL fail_flag=3 elapsed=236s`（1 条 = 本用例的 NPE 门禁；另 2 条 = 收尾三件套在 CN `.78`/`.79` 的日志扫描命中同一批 NPE）。
功能面断言全部 PASS ⇒ 修复后用例应当整体转 PASS。

## 6. 最小复现脚本（已实测）

```bash
bash /data/iotdb/autotest/compaction_skill/tools/repro_view_datatype_npe.sh
# 退出码 1 = 已复现；0 = 未复现（已修复）
```

2026-10-15 09:13 实测（RC6 / 3C3D / IoTConsensus，一条命令、约 3 分钟）：

| ConfigNode | `NullPointerException` | `Unknown Procedure type: 766` |
| --- | --- | --- |
| 192.168.99.77（leader） | 0 | 0 |
| 192.168.99.78（follower） | 6 | 12 |
| 192.168.99.79（follower） | 6 | 12 |

同时功能面正常：`create view` / `alter view` 都返回成功、`desc` 变为 `DOUBLE`、视图读数 `7|8| → 7.0|8.0|`。

## 7. 提单状态（**已写入 PLM**，2026-10-15）

| 项目 | 内容 |
| --- | --- |
| PLM 工作项 | **TDB-678**（itemId **1241**）<https://plm.infra.timecho.com/iterations?productId=1&itemId=1241> |
| 字段 | 缺陷 / **P1** / 排期确认；负责人 陈耀斌、所属组长 田原、验证人员 刘珍；迭代 与 问题发现版本 均为 **V2.0.12.1**；模型 表模型、功能模块 存储-元数据管理-视图 |
| 提交方式 | `plm_ops.py record --product-id 1 … --apply`（dry-run 预览 → 落库 → `rn get` 回查通过），再补 `rn update --id 1241 --team-leader … --set cf_6e859ac69388=V2.0.12.1` |
| 提单记录 | 工作区 `ip99_80\plm\records\PLM_submission_TDB-678.md`；材料目录见下表 |

| 位置 | 内容 |
| --- | --- |
| 工作区 `ip99_80\plm\` | `defect_view_column_datatype_npe.md`（描述正文·Markdown）、`defect_view_column_datatype_npe_description.html`（提交用的 HTML 描述）、`DT07_view_column_datatype_record.md`（提单记录）、`records\PLM_submission_TDB-678.md`（提单过程与回查）、`record_apply_out.json`（提交返回）、`repro_view_datatype_npe.sh`、`extract_dt07_npe.sh`、`collect_dt07_logs.sh`、`view_datatype_npe_source_evidence.txt`、`RC6_DT07_log_evidence.txt`（完整堆栈 + 逐节点计数 + 全部出现行号）、`RC6_DT07_cn_logs_20261015_105619.tgz`（原始日志备份）、`RC6_DT07_case_output.out`、`artifacts_DT07\`（用例 FAIL 时的整节点 logs 归档） |
| 交付目录 `D:\IDEA\deepseek\compaction\V2.0.12.1~RC6~视图改列类型CN_NPE\` | 同上（README + 描述正文 + 提单记录 + `scripts/` + `artifacts/evidence/`），与工作区逐文件哈希一致 |
