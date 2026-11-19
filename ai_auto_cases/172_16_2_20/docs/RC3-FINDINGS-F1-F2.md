# RC3 缺陷/风险报告（F-1、F-2）

- **被测版本**：TimechoDB 2.0.13.1 RC3，build `ac7f95e`（源码 HEAD `ac7f95e953`）
- **环境**：3 CN（172.16.2.16/17/18）+ 5 DN（172.16.2.19/21/22/23/24），SR3/DR2，IoTConsensusV2
- **发现时间**：2026-11-18 ~ 2026-11-19
- **发现人**：刘珍
- **状态**：待研发确认（本文仅供评审，暂未提单）

---

## F-1 `CANCEL ALL MIGRATIONS` 审计记录：脚本误判，TDB-709 修复在 RC3 已验证

> **结论修正（2026-11-19）**：TDB-709（【V2.0.11.1】【审计日志】Tree 模型执行 CANCEL ALL MIGRATIONS，成功和 803 拒绝均未生成操作审计记录）的修复代码在 RC3 中存在且**已生效**。此前“无审计记录”是验证脚本的断言方式错误导致的**假失败**。

### 1. 修复代码（RC3 `ac7f95e`）

`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/queryengine/plan/relational/security/TreeAccessCheckVisitor.java`

```java
@Override
public TSStatus visitCancelMigrations(
    CancelMigrationsStatement statement, TreeAccessCheckContext context) {
  return checkGlobalAuth(
      context.setAuditLogOperation(AuditLogOperation.CONTROL), PrivilegeType.MAINTAIN, () -> "");
}
```

即 TDB-709 建议的 `context.setAuditLogOperation(AuditLogOperation.CONTROL)` 已合入。

### 2. RC3 实测（2026-11-19 16:28~16:30）

| 场景 | 审计记录 |
| --- | --- |
| root（有 MAINTAIN）执行 `CANCEL ALL MIGRATIONS` | `OBJECT_AUTHENTICATION \| [MAINTAIN] \| CONTROL \| "User root (ID=0) requests authority on object  with result true"`（16:28:06.102） |
| `cam_den2`（无 MAINTAIN）执行，返回 **803** | `OBJECT_AUTHENTICATION \| [MAINTAIN] \| CONTROL \| "User cam_den2 (ID=10001) re..."`（16:29:36.978，devices `root.__audit.log.node_4.u_10001`） |

**成功与 803 拒绝均产生审计记录**，与 TDB-709 的修复目标一致。

### 3. 之前为什么误判

1. 审计记录里**不含** `CANCEL ALL MIGRATIONS` 文本：`sql_string` 为空，`log` 为 “requests authority on object ... with result true/false”；
2. RN 冒烟 `AUDIT-4` 的断言是 `grep -ci 'cancel'`，因此永远命中不到 → 报“未命中”；
3. 脚本查询审计时用了 `tail -n 4` 截断（审计写入量大，`root.__audit.log.**` 一次返回上千行），进一步降低了命中概率。

### 4. 脚本修复

`rn_smoke_2011_b3.sh` 的 `AUDIT-4` 改为按 **事件 + 权限 + 操作类型** 断言，且不再截断输出：

```bash
T0=$(date -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S)
aud_cancel=$(bash "$CLI" ... -e "SET SQL_DIALECT=TREE; SELECT audit_event_type, privilege_type, operation_type, result FROM root.__audit.log.** WHERE time > $T0;")
cnt_cancel=$(echo "$aud_cancel" | grep -E 'OBJECT_AUTHENTICATION' | grep -c '\[MAINTAIN\]')
```

复跑结果：`PASS | AUDIT-4 CANCEL ALL MIGRATIONS 产生审计记录（命中 9 行，TDB-709）`。

### 5. 结论

- **TDB-709 在 RC3 上验证通过**，无需提单；
- 该条应从“已知缺口”中移除，改为“已验证通过（断言已修正）”。

## F-2 EXTEND + CANCEL 竞态下出现 `unexpected consensusGroupId` ERROR

### 1. 级别与结论

| 项 | 内容 |
| --- | --- |
| 级别 | **低**（日志噪声 + 失败 RPC 重试；无数据不一致） |
| 现象 | `EXTEND REGION` 后立即 `CANCEL ALL MIGRATIONS`，DN 日志出现 `unexpected consensusGroupId ... for set active request` ERROR，伴随 `ConsensusGroupModifyPeerException` |
| 影响 | 迁移取消流程中出现一次失败 RPC（内部重试/清理后成功）；数据一致性、集群状态均正常 |
| 复现率 | **1 / 7**（首跑命中，后续 6 次全部 PASS） |

### 2. 复现步骤

```sql
EXTEND REGION <rid> TO 6;     -- 发起 add-peer
-- 2 秒后
CANCEL ALL MIGRATIONS;        -- 取消
-- 等待 10 秒后扫描 Datanode 日志
```

### 3. 证据（2026-11-18 17:55:55，IoTConsensusV2）

DN21：

```
ERROR o.a.i.c.p.s.IoTConsensusV2RPCServiceProcessor:91 -
  unexpected consensusGroupId DataRegion[24] for set active request
  TSetActiveReq(consensusGroupId:..., isActive:true, ...)
```

DN22（调用方栈）：

```
org.apache.iotdb.consensus.exception.ConsensusGroupModifyPeerException:
  error when set peer Peer{groupId=DataRegion[24], endpoint=TEndPoint(ip:172.16.2.21, port:10760), nodeId=6}
  to active true. result status: ...
```

同轮校验：`REG-2`（取消迁移数据完整）、`REG-4`（三 DN 数据一致）均 **PASS**；集群 8/8。

### 4. 代码分析（RC3 `ac7f95e`）

`iotdb-core/consensus/src/main/java/org/apache/iotdb/consensus/pipe/service/IoTConsensusV2RPCServiceProcessor.java`

```java
public TSetActiveResp setActive(TSetActiveReq req) {
  ConsensusGroupId groupId = ...;
  IoTConsensusV2ServerImpl impl = iotConsensusV2.getImpl(groupId);
  if (impl == null) {                                  // ← 目标 DN 上该 group 已被清理
    String message = String.format(UNEXPECTED_GROUP_SET_ACTIVE, groupId, req);
    LOGGER.error(message);                             // ← 记为 ERROR
    TSStatus status = new TSStatus(INTERNAL_SERVER_ERROR);
    status.setMessage(message);
    return new TSetActiveResp(status);                 // ← 调用方抛 ConsensusGroupModifyPeerException
  }
  impl.setActive(req.isActive);
  ...
}
```

竞态链路：
1. CN 发起 `EXTEND REGION`（add-peer），目标 DN 创建 group；
2. 用户 `CANCEL ALL MIGRATIONS`，CN 清理/取消该 Procedure，目标 DN 的 group 被删除；
3. 未完成的 add-peer 流程仍向目标 DN 发 `setActive`，此时 `getImpl(groupId) == null`；
4. 返回 `INTERNAL_SERVER_ERROR` 并打 ERROR，调用方包装为 `ConsensusGroupModifyPeerException`。

结果：失败 RPC 被上层吸收（最终数据一致、副本状态正确），但产生 ERROR 级日志与异常栈，容易被误判为缺陷。

### 5. 建议

| 方案 | 说明 |
| --- | --- |
| A（推荐） | `setActive` 在 `impl == null` 且请求来自已取消的迁移时，返回“已失效/幂等成功”而非 INTERNAL_SERVER_ERROR，并把日志降为 INFO/WARN |
| B | 保留 ERROR，但在日志中标注“region 已取消，属预期”，同时让 `ConsensusGroupModifyPeerException` 在取消路径上被静默处理 |
| C | 若判定为无害，纳入日志白名单（验证脚本已临时处理），并在文档中说明 |

---

## 附：本次验证的其它观察（供参考，不单列缺陷）

| 编号 | 内容 | 级别 |
| --- | --- | --- |
| F-3 | CN 全宕时 DDL 报 thrift 原始异常（305 + `Connection refused`） | 低 |
| F-4 | delete 回归脚本 `norm()` 未过滤 CLI `Time:`/会话提示行，导致 12 例误判（已修） | 低（脚本缺陷） |
| — | TDB-1050 在 RC3 已验证修复；TDB-1104、TDB-65 行为符合预期 | — |

## 证据文件

| 内容 | 路径 |
| --- | --- |
| F-1 审计实验（before/after 3796→4083） | `/tmp/f1_exp2.sh` 输出；审计导出于 `/tmp/audit_all2.txt` |
| F-1 RN 结果 | `/data2/iotdb/rn_rc3_all.log`（AUDIT-4 行） |
| F-2 首跑命中 | 2026-11-18 17:55:55 DN21/DN22 日志（已按上文摘录） |
| F-2 复现统计 | 首跑 1 次 FAIL + 后续 6 次 PASS（`REG-3`） |
| 全量回归报告 | `ai_auto_cases/172_16_2_20/docs/RC3-FULL-REPORT.md` |
