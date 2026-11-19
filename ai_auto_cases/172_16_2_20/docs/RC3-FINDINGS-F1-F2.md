# RC3 缺陷/风险报告（F-1、F-2）

- **被测版本**：TimechoDB 2.0.13.1 RC3，build `ac7f95e`（源码 HEAD `ac7f95e953`）
- **环境**：3 CN（172.16.2.16/17/18）+ 5 DN（172.16.2.19/21/22/23/24），SR3/DR2，IoTConsensusV2
- **发现时间**：2026-11-18 ~ 2026-11-19
- **发现人**：刘珍
- **状态**：待研发确认（本文仅供评审，暂未提单）

---

## F-1 `CANCEL ALL MIGRATIONS` 没有审计记录

### 1. 级别与结论

| 项 | 内容 |
| --- | --- |
| 级别 | **中**（审计合规缺口） |
| 现象 | 执行 `CANCEL ALL MIGRATIONS` 后，`root.__audit` 中没有任何 CANCEL 相关记录 |
| 影响 | 无法通过审计追溯“谁在什么时候取消了迁移”；TDB-709 的“成功场景应产生审计记录”未达成 |
| 结论 | RC2、RC3 表现一致；疑似**未实现审计埋点**，而非 RC3 回归 |

### 2. 复现步骤

```sql
-- 1) 限速，制造长时间迁移窗口
SET CONFIGURATION "region_migration_speed_limit_bytes_per_second"="256";

-- 2) 建库造数
CREATE DATABASE f4;
CREATE TABLE f4.t (dev STRING TAG, v INT32 FIELD);
INSERT INTO f4.t(time,dev,v) VALUES (...);   -- 900 行
FLUSH;

-- 3) 发起扩副本，随后取消
EXTEND REGION <rid> TO 6;
CANCEL ALL MIGRATIONS;      -- 返回：Successfully signalled 1 migration(s) to cancel
```

### 3. 证据

| 观察 | 数值 |
| --- | ---: |
| CANCEL 前审计总行数 | 3796 |
| CANCEL 后 10 秒审计总行数 | 4083 |
| 增量 | **+287 行**（说明审计链路正常，DDL/登录类都在写） |
| 全量审计 `log` 字段中 `CANCEL ALL MIGRATIONS` 命中 | **0** |
| 全量审计 `log` 字段中 `cancel`（忽略大小写）命中 | **0** |
| RN 冒烟 `AUDIT-4` | **FAIL：未命中**（`rn_rc3_all.log` 第 23 行） |

审计表中同时段存在的事件类型：`LOGIN`、`LOGOUT`、`OBJECT_AUTHENTICATION`、`ENTITY_STATUS_CHANGED`、`USER_DATA_TRANSFER` 等，**唯独没有迁移取消类事件**。

### 4. 代码分析（RC3 `ac7f95e`）

1. `AuditEventType` 枚举中没有迁移/CANCEL 相关事件类型
   （`iotdb-core/node-commons/.../audit/AuditEventType.java`，共 40+ 类型：CHANGE_AUDIT_OPTION、LOGIN、OBJECT_AUTHENTICATION、FAILED_TTL_DELETION 等）；
2. `CANCEL ALL MIGRATIONS` 仅出现在语法定义与 Procedure 注释中：
   - `iotdb-core/antlr/.../IoTDBSqlParser.g4:553`、`relational-grammar/.../RelationalSql.g4:861`
   - `AddRegionPeerProcedure.java:158`、`RegionOperationProcedure.java:31`（协作取消标志）
3. 在 `CancelMigrationsTask` / `ClusterConfigTaskExecutor` 中都**没有**审计埋点调用。

因此“无审计记录”是**当前实现缺失**，需要研发确认：补埋点，或在文档/RN 中明确“该操作不产生控制类审计”。

### 5. 建议

| 方案 | 说明 |
| --- | --- |
| A（推荐） | 新增 `AuditEventType`（如 `CANCEL_MIGRATIONS`/`REGION_OPERATION`），在 CN 执行 CANCEL 成功/失败时写审计，字段含发起用户、目标 region、signalled 数量 |
| B | 若设计上不审计，则在 TDB-709 的 RN 描述和用户文档中明确说明，避免验证预期与实际不一致 |

---

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
