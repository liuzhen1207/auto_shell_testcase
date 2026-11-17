# 缺陷报告：普通用户执行 `ALTER USER … ACCOUNT UNLOCK` 触发 NPE，返回 305 INTERNAL_SERVER_ERROR（应 803）

| 项 | 内容 |
| --- | --- |
| 缺陷标题 | 【V2.0.13.1】【安全-身份鉴别】普通用户执行 `ALTER USER <u> [@ 'ip'] ACCOUNT UNLOCK` 触发 `NullPointerException`，返回 **305 INTERNAL_SERVER_ERROR**（期望 803 权限错误），并在 DataNode 打印完整 ERROR 堆栈 |
| 被测版本 | TimechoDB **2.0.13.1 RC2**，BuildInfo **`83183d0`**（企业版） |
| 环境 | **干净环境**：3 节点 data/logs 已全部清空后重建；3 ConfigNode + 3 DataNode（192.168.99.77/78/79），SR=3 / DR=3，IoTConsensus；普通模式（root 管理） |
| 复现概率 | **必现**（3 种写法均复现） |
| 优先级建议 | **P2**：不涉及提权（失败即拒绝），但错误码语义错误（305 而非 803）、每次触发都在 DN 打一条 ERROR + 完整堆栈，污染日志/告警，且可被低权限用户反复触发刷日志 |
| 负责人 / 验证人员 | 江天 / 刘珍（待确认） |

## 一、复现步骤（最小，约 30 秒）

```sql
-- 1) root 建一个普通用户（无任何权限）
create user sec_uo 'Abcdefgh123!';

-- 2) 用这个普通用户登录，执行解锁（三种写法都试）
alter user sec_uo account unlock;                     -- 3a 对自己
alter user root account unlock;                        -- 3b 对管理员
alter user sec_uo @ '192.168.99.80' account unlock;    -- 3c 带 IP
```

## 二、实际结果 vs 期望

**实际**（三种写法一致）：

```
305: [INTERNAL_SERVER_ERROR(305)] Exception occurred: "alter user sec_uo account unlock".
executeStatement failed. Cannot read the array length because "array" is null
```

**期望**：`803: No permissions for this operation, please add privilege SECURITY`
（与同一用户执行 `create user` / `grant` 的行为一致）

## 三、对照实验（同一干净集群、同一用户）

| # | 执行人 | 语句 | 实际返回 | 结论 |
| --- | --- | --- | --- | --- |
| 1 | root | `alter user sec_uo account unlock;` | **成功**（Executed successfully） | 管理员路径正常 |
| 2 | sec_uo（无权限） | `create user sec_tmp 'Abcdefgh123!';` | **803** No permissions … SECURITY | 同类 SECURITY 语句的正常拒绝码 |
| 3 | sec_uo（无权限） | `grant read on root.** to user sec_uo;` | **803** Has no permission to execute GRANT_USER … | GRANT/REVOKE 分支正常 |
| 4 | sec_uo（无权限） | `alter user sec_uo account unlock;` | **305** + NPE | **本缺陷** |

## 四、DataNode 完整异常堆栈（原样摘录，节点 192.168.99.77）

```
2026-11-17 09:25:06,630 [pool-43-IoTDB-ClientRPC-Processor-1] ERROR o.a.i.d.u.ErrorHandlingUtils:75 - Status code: INTERNAL_SERVER_ERROR(305), operation: "alter user sec_uo account unlock". executeStatement failed
java.lang.NullPointerException: Cannot read the array length because "array" is null
	at java.base/java.util.Arrays.stream(Arrays.java:5428)
	at org.apache.iotdb.db.queryengine.plan.relational.security.TreeAccessCheckVisitor.visitAuthor(TreeAccessCheckVisitor.java:808)
	at org.apache.iotdb.db.queryengine.plan.relational.security.TreeAccessCheckVisitor.visitAuthor(TreeAccessCheckVisitor.java:220)
	at org.apache.iotdb.db.queryengine.plan.statement.sys.AuthorStatement.accept(AuthorStatement.java:267)
	at org.apache.iotdb.db.queryengine.plan.statement.StatementVisitor.process(StatementVisitor.java:189)
	at org.apache.iotdb.db.queryengine.plan.relational.security.AccessControlImpl.checkPermissionBeforeProcess(AccessControlImpl.java:683)
	at org.apache.iotdb.db.auth.AuthorityChecker.checkAuthority(AuthorityChecker.java:256)
	at org.apache.iotdb.db.protocol.thrift.impl.ClientRPCServiceImpl.executeStatementInternal(ClientRPCServiceImpl.java:431)
	at org.apache.iotdb.db.protocol.thrift.impl.ClientRPCServiceImpl.executeStatementV2(ClientRPCServiceImpl.java:1240)
	at org.apache.iotdb.service.rpc.thrift.IClientRPCService$Processor$executeStatementV2.getResult(IClientRPCService.java:4834)
	at org.apache.iotdb.service.rpc.thrift.IClientRPCService$Processor$executeStatementV2.getResult(IClientRPCService.java:4806)
	at org.apache.thrift.ProcessFunction.process(ProcessFunction.java:40)
	at org.apache.iotdb.db.protocol.thrift.ProcessorWithMetrics.process(ProcessorWithMetrics.java:67)
	at org.apache.thrift.server.TThreadPoolServer$WorkerProcess.run(TThreadPoolServer.java:264)
	at java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1136)
	at java.base/java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:635)
	at java.base/java.lang.Thread.run(Thread.java:840)
```

（`alter user root account unlock` / 带 `@ 'ip'` 的两次同样堆栈，仅 operation 文本不同；ConfigNode 日志无该异常——异常发生在接收语句的 DataNode 侧。）

## 五、根因（源码级，确定性）

### 5.1 直接原因

`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/queryengine/plan/relational/security/TreeAccessCheckVisitor.java:793-811`

```java
      case REVOKE_USER:
      case GRANT_USER:
      case GRANT_ROLE:
      case REVOKE_ROLE:
      case ACCOUNT_UNLOCK:                       // ← ACCOUNT_UNLOCK 被并入 GRANT/REVOKE 分支
        auditObject = ...;
        if (checkHasGlobalAuth(
            context.setAuditLogOperation(AuditLogOperation.DDL),
            PrivilegeType.SECURITY,
            auditObject)) {
          return RpcUtils.SUCCESS_STATUS;        // 管理员在这里提前返回，不会走到下面
        }
        return checkPermissionsWithGrantOption(
            context,
            authorType,
            Arrays.stream(statement.getPrivilegeList())   // ← 第 808 行：privilegeList 为 null
                .map(s -> PrivilegeType.valueOf(s.toUpperCase()))
                .collect(Collectors.toList()),
            statement.getNodeNameList());
```

`ALTER USER … ACCOUNT UNLOCK` 语句里没有"权限列表"概念，`AuthorStatement.privilegeList` **恒为 null**：
`setPrivilegeList()` 只在 GRANT/REVOKE 的解析路径被调用（`AuthorStatement.java:229-231`），
`ACCOUNT_UNLOCK` 的构造只设置 statementType（`AuthorStatement.java:126-128`）。

于是：**非管理员**（`checkHasGlobalAuth` 为 false）会走到 `Arrays.stream(null)` → NPE → 由
`ErrorHandlingUtils` 统一兜成 **305 INTERNAL_SERVER_ERROR**。

### 5.2 为什么管理员不触发

管理员在 `checkHasGlobalAuth(..., PrivilegeType.SECURITY, ...)` 处直接 `return SUCCESS`，
不会执行下面的 `Arrays.stream(...)` —— 这解释了"root 执行成功、普通用户 305"。

### 5.3 同一产品里的正确写法（修复参照）

`timecho-server/src/main/java/com/timecho/iotdb/auth/StrictTreeAccessCheckVisitor.java:109-121`
（严格模式 visitor）把 `ACCOUNT_UNLOCK` 归到 `CREATE_USER / DROP_USER` 一组：

```java
      case CREATE_USER:
      case DROP_USER:
      case ACCOUNT_UNLOCK:
      case ENABLE_TOTP:
      ...
        return checkGlobalAuth(
            context.setAuditLogOperation(AuditLogOperation.DDL),
            PrivilegeType.SECURITY,
            statement::getUserName);
```

即 `ACCOUNT_UNLOCK` 应走 **全局 SECURITY 鉴权**、返回 803，**不应进入 GRANT/REVOKE 的 privilegeList 逻辑**。
标准 visitor 显然漏掉了这个 case（严格模式对了，标准模式错了）。

## 六、影响

1. **错误码语义错误**：应 803（权限不足），实际 305（服务端内部错误），客户端/运维无法据此判断是权限问题还是服务故障。
2. **日志污染**：每次触发都在 DN 打一条 `ERROR … INTERNAL_SERVER_ERROR(305)` + 完整堆栈；任何无权限用户都可反复触发，形成日志噪声/刷盘，干扰"ERROR 必须为零"的巡检口径。
3. **审计可观测性受损**：鉴权失败被记为内部错误，审计/告警的分类失真。
4. **不构成提权**：语句最终失败，未解锁任何账号；属健壮性/语义缺陷。

## 七、修复建议

1. **主修**：在 `TreeAccessCheckVisitor.visitAuthor` 中为 `ACCOUNT_UNLOCK` 增加**独立分支**（与 `StrictTreeAccessCheckVisitor` 对齐）：

```java
      case ACCOUNT_UNLOCK:
        return checkGlobalAuth(
            context.setAuditLogOperation(AuditLogOperation.DDL),
            PrivilegeType.SECURITY,
            statement::getUserName);
```

   并从 `REVOKE_USER/GRANT_USER/GRANT_ROLE/REVOKE_ROLE` 分支中移除 `case ACCOUNT_UNLOCK`。

2. **防御式加固**（可选，避免同类 NPE 再次出现）：

```java
    final String[] privileges = statement.getPrivilegeList();
    Arrays.stream(privileges == null ? new String[0] : privileges)
```

3. **补单测**（放在 `TreeAccessCheckVisitor` 或 `AuthorPlanExecutorTest`）：
   - 普通用户执行 `ALTER USER x ACCOUNT UNLOCK` → 必须返回 **803**，不得 305；
   - 普通用户执行带 `@ 'ip'` 的同一语句 → 803；
   - root/安全管理员执行 → 成功；
   - 断言 DN 日志中**不出现** `NullPointerException` 与 `INTERNAL_SERVER_ERROR(305)`。

4. 顺带核对 **TOTP 三类语句**（`ENABLE_TOTP/RESET_TOTP/DISABLE_TOTP`）在标准 visitor 中的分支，避免同类漏 case（严格模式已覆盖，标准模式需确认）。

## 八、验证方法（修复后）

1. 干净集群 → `create user u 'Abcdefgh123!'`；
2. 以 `u` 执行 `alter user u account unlock;` → 期望 **803**；带 `@ 'ip'` 同样 803；
3. `grep -c "Cannot read the array length" log_datanode_all.log` → **0**；
4. root 执行同一语句 → 成功；
5. 回归用例：`sec_skill` 的 **SEC-13** 第 7 步（当前记为 WARN"缺陷候选"，修复后应转为 PASS）。

## 九、证据归档（192.168.99.80）

| 路径 | 内容 |
| --- | --- |
| `/data/iotdb/autotest/sec_skill/results/artifact_305_20261117_092359/` | 本次干净环境复现产物目录 |
| `…/cli_3a_self_unlock.txt`、`cli_3b_unlock_root.txt`、`cli_3c_unlock_ip.txt` | 三种写法的 CLI 原始输出 |
| `…/stack_77_log_datanode_all.log.txt` | **完整堆栈**（含前后 80 行上下文） |
| `…/logs_77.tgz`、`logs_78.tgz`、`logs_79.tgz` | 三节点 CN/DN 日志打包 |
| `…/bundle_305.tgz` | 以上全部打包（便于直接转研发） |
| `/data/iotdb/autotest/rc2_regression_logs/repro_305.log` | 复现脚本执行日志（含清库重建、启动、三种写法、堆栈抽取） |
| `sec_skill/tools/repro_305_unlock.sh` | 一键复现脚本（清 data → 起集群 → 复现 → 抓堆栈 → 打包） |

## 十、备注

- 该缺陷是"三权分立/最小权限"相关回归中发现的：需求要求解锁语句**仅 root 或安全管理员可执行**，
  当前行为虽拒绝执行，但以 305 内部错误形式拒绝，属实现缺陷（错误码 + 日志），不是权限放行。
- 本次复现环境为**清库后的干净集群**，配置为默认（`failed_login_attempts=5`、`password_lock_time_minutes=10`），
  与锁定阈值无关，纯属授权检查路径的空指针。
