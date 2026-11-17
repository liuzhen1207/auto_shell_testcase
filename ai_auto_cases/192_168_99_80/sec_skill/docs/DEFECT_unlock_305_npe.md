# 缺陷报告：普通模式下无 SECURITY 权限用户执行 `ALTER USER … ACCOUNT UNLOCK` 触发 NPE，返回 305（应 803）

| 项 | 内容 |
| --- | --- |
| 缺陷标题 | 【V2.0.13.1】【安全-身份鉴别】**普通模式（未开三权分立）**下，无 SECURITY 权限的用户执行 `ALTER USER <u> [@ 'ip'] ACCOUNT UNLOCK` 触发 `NullPointerException`，返回 **305 INTERNAL_SERVER_ERROR**（期望 803 权限错误），并在 DataNode 打印完整 ERROR 堆栈 |
| 被测版本 | TimechoDB **2.0.13.1 RC2**，BuildInfo **`83183d0`**（企业版） |
| 环境 | **干净环境**：3 节点 data/logs 已全部清空后重建；3 ConfigNode + 3 DataNode（192.168.99.77/78/79），SR=3 / DR=3，IoTConsensus；**普通模式**（`enable_separation_of_powers=false`） |
| 复现概率 | **必现**（3 种写法：对自己 / 对 root / 带 `@ 'ip'`） |
| 优先级建议 | **P2**：不涉及提权（最终拒绝执行），但①错误码语义错误（305 内部错误 vs 803 权限不足）；②每次触发在 DN 打一条 ERROR + 完整堆栈，任何低权限用户可反复触发刷日志，干扰"ERROR 零容忍"巡检；③与同类 SECURITY 语句（CREATE USER/GRANT）返回 803 的行为不一致 |
| 负责人 / 验证人员 | 待定 / 刘珍 |

## 〇、与 TDB-899 的关系（已核对，**不是同一个问题**）

TDB-899 的现象是"**三权分立**下 `security_admin`（持有 SECURITY 权限）执行解锁返回 **701 Unsupported author type**，账号无解锁入口"。
本缺陷是"**普通模式**下**无权限**用户执行解锁，鉴权阶段 NPE → **305**"。

同一集群（2.0.13.1 RC2 `83183d0`）上的实测矩阵：

| 场景 | 执行者 | 本缺陷版本实测 | 说明 |
| --- | --- | --- | --- |
| **三权分立** | `security_admin`（全局解锁） | **成功** | TDB-899 的 701 在 RC2 **已修复** |
| **三权分立** | `security_admin`（`@ 'ip'` IP 级解锁） | **成功** | 同上 |
| **三权分立** | `sys_admin` / `audit_admin` / 普通用户 | **803**（缺 SECURITY） | 走严格 visitor，行为正确 |
| **普通模式** | `root` | 成功 | 管理员提前返回，不进 privilegeList 分支 |
| **普通模式** | 普通用户（无 SECURITY） | **305 + NPE** | **本缺陷** |

补充证据：在同一集群上跑"真锁定 → 解锁 → 登录"验证 TDB-899 是否已修复：

```
建用户 lock899 → 连续 5 次错误密码（801×5）→ 第 6 次 822（已锁定）
security_admin 执行 ALTER USER lock899 ACCOUNT UNLOCK  → 成功
用正确密码登录 → 成功（无错误码）
再锁一次 → ALTER USER lock899 @ '192.168.99.80' ACCOUNT UNLOCK → 成功 → 登录成功
DN 日志 "Unsupported author type" 计数 = 0
```

**结论**：TDB-899 描述的 701 问题在 2.0.13.1 RC2 上已修复（建议在 PLM 上按 RC2 验证关闭或更新状态）；
本缺陷是**另一条路径**（普通模式 + 无权限用户 + 鉴权 NPE），需单独记录。
两者同属"`ACCOUNT_UNLOCK` 在部分 visitor/switch 分支未显式处理"这一族，可在同一个 PR 内一起收拾。


### 0.1 三权分立模式下**不复现**（热开 + 重启后各测一轮）

| 场景 | 执行者 | 结果 | 是否产生 NPE/305 |
| --- | --- | --- | --- |
| 三权分立（root `SET CONFIGURATION` 热开） | `security_admin` 全局 / IP 级解锁 | **成功** | 否 |
| 同上 | 授予 `SECURITY` 的普通用户（全局 / IP 级） | **成功** | 否 |
| 同上 | `sys_admin` / `audit_admin` / 普通用户（全局 / IP 级 / 解锁 root） | **803** 缺 SECURITY | 否 |
| 同上 | `security_admin` 解锁**不存在**的用户 | **804** No such user | 否 |
| 三权分立（**重启后**，走 startup 路径） | `security_admin` 解锁 | **成功** | 否 |
| 同上 | 普通用户（全局 / IP 级）、`sys_admin` | **803** | 否 |

日志增量核对（节点 192.168.99.77 的 `log_datanode_all.log`，以两次测量差值计）：

```
热开三权分立一轮：NPE 4 → 4（+0）   305 4 → 4（+0）   701 0 → 0（+0）
重启后再一轮    ：NPE 4 → 4（+0）
```

> 这 4 条 NPE 的时间戳是 **09:25:06 / 09:25:07 ×2 / 09:33:25**，全部来自**普通模式**下的复现；
> 三权分立期间（09:51 起，含 09:52 重启后）**没有任何新增**。
> 结论：本缺陷**仅在普通模式**出现；三权分立走 `StrictAccessCheckVisitor`，鉴权路径正确返回 803。
> 因此修复只需改标准 visitor，**不得改动**严格 visitor（否则可能回退 TDB-899 的修复）。

### 0.2 附带观察（非本缺陷）

三权分立下若 `root` 因连续密码错误被锁定，登录返回的是 **822**（锁定）而不是 **803**（禁止 SUPER USER 登录）
——说明登录锁定检查发生在"三权分立禁止 root 登录"检查之前。语义上可接受（都属于拒绝登录），仅记录。


## 一、复现步骤（最小，约 30 秒，普通模式）

```sql
-- 前置：enable_separation_of_powers=false（默认）
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
| 1 | root | `alter user sec_uo account unlock;` | **成功** | 管理员路径正常 |
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

### 5.1 为什么只有"普通模式 + 无权限用户"会触发

- **普通模式**下 AccessControl 用的是标准实现：
  `iotdb-core/datanode/.../auth/AuthorityChecker.java:118-119`
  ```java
  private static volatile AccessControl accessControl =
      new AccessControlImpl(new ITableAuthCheckerImpl(), new TreeAccessCheckVisitor());
  ```
- **三权分立**开启时才替换为严格实现：
  `timecho-server/.../DataNode.java:147-157`
  ```java
  if (runtimeConfiguration.isSetEnableSeparationOfAdminPowers()
      && runtimeConfiguration.isEnableSeparationOfAdminPowers()) {
    AuthorityChecker.setAccessControl(
        new StrictAccessControlImpl(new ITableAuthCheckerImpl(), new StrictTreeAccessCheckVisitor()));
  }
  ```
  严格 visitor 把 `ACCOUNT_UNLOCK` 归到 `CREATE_USER/DROP_USER` 一组，走 `checkGlobalAuth(SECURITY)` → 正确返回 803 或成功
  （`timecho-server/.../auth/StrictTreeAccessCheckVisitor.java:109-121`）。
  ⇒ 这解释了"三权分立下普通用户是 803、普通模式下是 305"。

### 5.2 标准 visitor 的直接缺陷

`iotdb-core/datanode/.../relational/security/TreeAccessCheckVisitor.java:793-811`

```java
      case REVOKE_USER:
      case GRANT_USER:
      case GRANT_ROLE:
      case REVOKE_ROLE:
      case ACCOUNT_UNLOCK:                       // ← ACCOUNT_UNLOCK 被并入 GRANT/REVOKE 分支
        auditObject = ...;
        if (checkHasGlobalAuth(..., PrivilegeType.SECURITY, auditObject)) {
          return RpcUtils.SUCCESS_STATUS;        // 管理员在这里提前返回
        }
        return checkPermissionsWithGrantOption(
            context,
            authorType,
            Arrays.stream(statement.getPrivilegeList())   // ← 第 808 行：privilegeList 为 null
                .map(s -> PrivilegeType.valueOf(s.toUpperCase()))
                .collect(Collectors.toList()),
            statement.getNodeNameList());
```

`ALTER USER … ACCOUNT UNLOCK` 没有"权限列表"概念：`setPrivilegeList()` 只在 GRANT/REVOKE 解析路径被调用
（`AuthorStatement.java:229-231`），`ACCOUNT_UNLOCK` 的构造只设 statementType（`AuthorStatement.java:126-128`），
因此 `privilegeList == null`；**非管理员**（`checkHasGlobalAuth` 为 false）走到 `Arrays.stream(null)` → NPE → 被
`ErrorHandlingUtils` 兜成 **305**。

## 六、影响

1. **错误码语义错误**：应 803（权限不足），实际 305（服务端内部错误），客户端/运维无法区分"权限问题"与"服务故障"。
2. **日志污染**：每次触发在 DN 打一条 `ERROR … INTERNAL_SERVER_ERROR(305)` + 完整堆栈；任何无权限用户都可反复触发，形成噪声、干扰巡检。
3. **审计分类失真**：鉴权失败被记为内部错误。
4. **不构成提权**：语句最终失败，未解锁任何账号；属健壮性/语义缺陷。
5. 与 TDB-899 不同：TDB-899 是"三权分立下管理员无法解锁"（功能不可用，P1），已在 RC2 修复；本缺陷是"普通模式下无权限用户得到错误码 + 堆栈"。

## 七、修复建议

1. **主修**（标准 visitor 对齐严格 visitor）：在 `TreeAccessCheckVisitor.visitAuthor` 增加独立分支，并从 GRANT/REVOKE 分支移除 `case ACCOUNT_UNLOCK`：

```java
      case ACCOUNT_UNLOCK:
        return checkGlobalAuth(
            context.setAuditLogOperation(AuditLogOperation.DDL),
            PrivilegeType.SECURITY,
            statement::getUserName);
```

2. **防御式加固**（避免同类 NPE 再现）：

```java
    final String[] privileges = statement.getPrivilegeList();
    Arrays.stream(privileges == null ? new String[0] : privileges)
```

3. **补单测**（`TreeAccessTest` / `AuthTest` 已有 visitor 直测框架）：
   - 无权限用户执行 `ALTER USER x ACCOUNT UNLOCK` → **803**，不得 305；
   - 带 `@ 'ip'` 同一断言；
   - root / 有 SECURITY 的用户 → 成功；
   - 断言日志无 `NullPointerException` / `INTERNAL_SERVER_ERROR(305)`。

4. **顺带核对**标准 visitor 中 `ENABLE_TOTP / RESET_TOTP / DISABLE_TOTP` 的分支（严格 visitor 已覆盖，避免同类漏 case）。

5. 与 TDB-899 的修复合并考虑：TDB-899 修的是严格 visitor/执行路径，本缺陷修的是标准 visitor/鉴权路径，两者改动不冲突，建议同一 PR 一起过。

## 八、验证方法（修复后）

1. 普通模式：`create user u 'Abcdefgh123!'` → 以 `u` 执行 `alter user u account unlock;` → 期望 **803**；带 `@ 'ip'` 同样 803；
2. `grep -c "Cannot read the array length" log_datanode_all.log` → **0**；
3. root 执行同一语句 → 成功；
4. 三权分立回归：`security_admin` 全局/IP 级解锁 → 仍成功；普通用户 → 仍 803（不得因本次修改回退 TDB-899 的修复）；
5. 回归用例：`sec_skill` 的 **SEC-13** 第 7 步（当前记为 WARN"缺陷候选"，修复后应转 PASS）。

## 九、证据归档（192.168.99.80）

| 路径 | 内容 |
| --- | --- |
| `/data/iotdb/autotest/sec_skill/results/artifact_305_20261117_092359/` | 普通模式干净环境复现产物 |
| `…/cli_3a_self_unlock.txt`、`cli_3b_unlock_root.txt`、`cli_3c_unlock_ip.txt` | 三种写法的 CLI 原始输出 |
| `…/stack_77_log_datanode_all.log.txt` | **完整堆栈**（含前后 80 行上下文） |
| `…/logs_77.tgz`、`logs_78.tgz`、`logs_79.tgz`、`…/bundle_305.tgz` | 三节点 CN/DN 日志与整体打包 |
| `/data/iotdb/autotest/rc2_regression_logs/repro_305.log` | 复现脚本日志（清库重建 → 启动 → 复现 → 抽堆栈 → 打包） |
| `/data/iotdb/autotest/rc2_regression_logs/tdb899_vs_305.log` | 本报告第〇节的权限矩阵（两种模式对照） |
| `/data/iotdb/autotest/rc2_regression_logs/tdb899_fixed_check.log` | TDB-899 在 RC2 已修复的验证（真锁定→解锁→登录） |
| `sec_skill/tools/repro_305_unlock.sh` / `compare_899_305.sh` / `check_899_fixed.sh` | 一键复现与对照脚本 |

## 十、备注

- 本次复现为**清库后的干净集群**、默认配置（`failed_login_attempts=5`、`password_lock_time_minutes=10`），与锁定阈值无关，纯属授权检查路径的空指针。
- TDB-899 建议按 RC2 验证关闭（证据见第九节 `tdb899_fixed_check.log`）；本缺陷建议**单独建单**，并在描述中关联 TDB-899（同一功能族、不同路径）。
