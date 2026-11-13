# LBAC 双模式回归结果（160 条，2026-11-13，RC2 `83183d0`）

| 项目 | 内容 |
| --- | --- |
| 需求 | TDB-415 LBAC |
| 版本 | 2.0.13.1 / `83183d0`（RC2） |
| 集群 | 3 CN + 5 DN，Schema 3 副本 / Data 2 副本，IoTConsensus |
| 用例 | **160 条**（原 141 + 补充 19：LB-142~LB-160） |
| 结果目录 | `results.tsv` / `report_normal.md`、`report_sep.md`、`compare.md`、`log_scan_*.txt` |

## 一、总览

| 模式 | 用例 | PASS | FAIL | SKIP |
| --- | ---: | ---: | ---: | ---: |
| 普通模式 | 160 | **150** | **0** | 10 |
| 三权分立 | 160 | **151** | **0** | 9 |

**两模式唯一差异：LB-157**（普通模式 SKIP，三权分立 PASS —— 该用例只在 SEP=1 下执行，属预期）。

## 二、SKIP 明细（9 条，两模式一致 + LB-157 条件项）

| 用例 | 原因 | 类型 |
| --- | --- | --- |
| LB-109 / LB-122 | 可写视图源为树模型（`VIEW FROM TREE`），不做 LBAC 保护（已确认） | 不适用 |
| LB-143 | TAG / TIME 列是否允许 `SECURED WITH` —— 待需求确认 | 待确认 |
| LB-154 | 同一策略 READ 与 WRITE 能否授不同标签 —— 待需求确认 | 待确认 |
| LB-158 / LB-159 / LB-160 | 导出（EXPORT）、pipe/subscription、LOAD 是否在 LBAC 检查范围 —— 待需求确认 | 待确认 |
| LB-144 / LB-146 | 表模型不支持 `RENAME TABLE`、`CREATE TABLE ... AS SELECT/LIKE`（700） | 语法不支持 |
| LB-157 | 仅三权分立执行（普通模式 SKIP） | 条件项 |

## 三、补充用例（LB-142 ~ LB-160，19 条）

| 分组 | 用例 | 普通 | 三权分立 |
| --- | --- | --- | --- |
| 绑定生命周期 | LB-142 表切换策略并重新保护列 | PASS | PASS |
| | LB-145 DROP COLUMN 后标签可删 | PASS | PASS |
| 查询表达式 | LB-147 聚合 `COUNT/SUM/AVG(受保护列)` | PASS | PASS |
| | LB-148 `GROUP BY / HAVING / ORDER BY` | PASS | PASS |
| | LB-149 `WHERE` 过滤受保护列 | PASS | PASS |
| | LB-150 别名投影不能绕过 | PASS | PASS |
| | LB-151 双表 JOIN（AND 语义，两策略） | PASS | PASS |
| | LB-152 `UNION` / 子查询 | PASS | PASS |
| 权限级联 | LB-153 仅 LBAC 凭证、无 RBAC → 803 | PASS | PASS |
| | LB-155 DROP USER 级联清理授权与豁免 | PASS | PASS |
| | LB-156 `GRANT EXEMPTION TO ROLE`（IGNORE/USE） | PASS | PASS |
| | LB-157 三权分立跨管理员边界 | SKIP | PASS |
| 数据旁路 | LB-158 / LB-159 / LB-160 | SKIP | SKIP |

## 四、日志检查

| 模式 | 总行 | ERROR | WARN |
| --- | ---: | ---: | ---: |
| 普通模式 | 399 | 2 | 397 |
| 三权分立 | 406 | 4 | 402 |

ERROR 全部落在 **HA 用例的节点重启窗口**，均为 `INVALIDATE_LAST_CACHE` / `CHANGE_REGION_LEADER` / `[LeaderBalancer] Failed to change the leader`：

| 模式 | 时间 | 内容 | 对应用例 |
| --- | --- | --- | --- |
| 普通 | 17:26:03、17:33:19 | `Failed to INVALIDATE_LAST_CACHE on DataNode` | LB-132/133（CN/DN 重启） |
| 三权分立 | 20:28:18 | `Timeout during CHANGE_REGION_LEADER` + LeaderBalancer + TransferLeaderRPC + INVALIDATE_LAST_CACHE | LB-138/139（DN 重启） |

WARN 按组件：`GrpcLogAppender`（330/318，Ratis 重启中断）、`CompactionWorker`（20/20）、`AbstractOperateSubscriptionProcedure`（10/10，topic push 重试）、`IoTDBDescriptor`（三权分立启动瞬间 14 条 IOTDB_HOME 告警）。

**结论：无 LBAC 相关 ERROR/WARN。**

## 五、补充过程中确认的产品行为

1. 策略默认模式为 **IGNORE**（`use_role_authorizations=false`）—— 角色授权的标签/豁免默认不参与判定，需显式 `ALTER SECURITY POLICY ... USE ROLE AUTHORIZATIONS`。
2. `ALTER TABLE ... DROP COLUMN` 删除**受保护列**需要该标签的 **WRITE 凭证**（root 直接执行报 2400）。
3. 同一策略下同一用户对同一访问类型只能持有一个标签 —— 双表 JOIN 的“凭证齐全”正向场景必须使用两个策略。
4. 表模型不支持 `RENAME TABLE`、`CREATE TABLE ... AS SELECT`、`CREATE TABLE ... LIKE`（均 700）。
5. 三权分立下 `ALTER TABLE ... DROP SECURITY POLICY` 需 security_admin 自授 `ALTER ON DATABASE` 后执行（LB-107/LB-142 按此实现）。

## 六、复现

```bash
cd /data2/auto_test/lbac_skill
# 普通模式
SEP=0 RESULT_BASE=/data2/auto_test/lbac_results_normal_$(date +%Y%m%d_%H%M%S) \
  nohup setsid bash tools/suite.sh > /tmp/lbac_normal.log 2>&1 &
# 三权分立
bash tools/mode_sep.sh on
SEP=1 RESULT_BASE=/data2/auto_test/lbac_results_sep_$(date +%Y%m%d_%H%M%S) \
  nohup setsid bash tools/suite.sh > /tmp/lbac_sep.log 2>&1 &
```
