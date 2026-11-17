#!/usr/bin/env python3
"""生成 PLM 缺陷单描述 HTML（305 NPE / 普通模式 / 与 TDB-899 区分）。"""
import io, os

html = """<h3>一、缺陷摘要</h3>
<p><b>普通模式</b>（未开启三权分立）下，<b>无 SECURITY 权限</b>的用户执行 <code>ALTER USER &lt;u&gt; [@ 'ip'] ACCOUNT UNLOCK</code>，
在鉴权阶段抛 <code>NullPointerException</code>，被兜成 <b>305 INTERNAL_SERVER_ERROR</b>（期望 803 权限错误），
并在 DataNode 打印完整 ERROR 堆栈；任何低权限用户可反复触发刷日志。</p>
<p><b>与 TDB-899 不是同一个问题</b>：TDB-899 是"三权分立下 security_admin 执行解锁返回 701 Unsupported author type"（功能不可用，P1），
经本次实测在 <b>2.0.13.1 RC2 上已修复</b>（真锁定→解锁→登录成功，DN 日志 Unsupported author type = 0）；
本缺陷是<b>普通模式 + 无权限用户 + 鉴权 NPE</b>，属另一条代码路径，需单独修复。</p>

<h3>二、环境</h3>
<ul>
<li>版本：TimechoDB <b>V2.0.13.1</b>，BuildInfo <code>83183d0</code>（企业版）。</li>
<li>集群：<b>干净环境</b>（3 节点 data/logs 全部清空后重建）；3 ConfigNode + 3 DataNode（192.168.99.77/78/79），SR=3 / DR=3，IoTConsensus。</li>
<li>模式：<b>普通模式</b>（<code>enable_separation_of_powers=false</code>），root 为管理账号。</li>
<li>其余配置默认（<code>failed_login_attempts=5</code>、<code>password_lock_time_minutes=10</code>），与锁定阈值无关。</li>
</ul>

<h3>三、复现步骤（约 30 秒，必现）</h3>
<pre><code>-- 前置：enable_separation_of_powers=false（普通模式）
-- 1) root 建一个普通用户（无任何权限）
create user sec_uo 'Abcdefgh123!';

-- 2) 用该普通用户登录，执行解锁（三种写法均复现）
alter user sec_uo account unlock;                     -- 对自己
alter user root account unlock;                        -- 对管理员
alter user sec_uo @ '192.168.99.80' account unlock;    -- 带 IP
</code></pre>

<h3>四、实际结果 vs 期望</h3>
<p><b>实际</b>（三种写法一致）：</p>
<pre><code>305: [INTERNAL_SERVER_ERROR(305)] Exception occurred: "alter user sec_uo account unlock".
executeStatement failed. Cannot read the array length because "array" is null
</code></pre>
<p><b>期望</b>：<code>803: No permissions for this operation, please add privilege SECURITY</code>
（与同一用户执行 <code>create user</code> / <code>grant</code> 的行为一致）。</p>

<h3>五、对照实验（同一干净集群）</h3>
<table border="1" cellspacing="0" cellpadding="4">
<tr><th>#</th><th>执行人</th><th>语句</th><th>实际返回</th><th>结论</th></tr>
<tr><td>1</td><td>root</td><td><code>alter user sec_uo account unlock;</code></td><td><b>成功</b></td><td>管理员路径正常</td></tr>
<tr><td>2</td><td>无权限用户</td><td><code>create user sec_tmp 'Abcdefgh123!';</code></td><td><b>803</b> SECURITY</td><td>同类 SECURITY 语句正常拒绝码</td></tr>
<tr><td>3</td><td>无权限用户</td><td><code>grant read on root.** to user sec_uo;</code></td><td><b>803</b> GRANT_USER</td><td>GRANT/REVOKE 分支正常</td></tr>
<tr><td>4</td><td>无权限用户</td><td><code>alter user sec_uo account unlock;</code></td><td><b>305</b> + NPE</td><td><b>本缺陷</b></td></tr>
</table>
<p><b>三权分立下不复现</b>（热开一轮 + 重启后一轮，日志增量均为 +0）：</p>
<table border="1" cellspacing="0" cellpadding="4">
<tr><th>场景</th><th>执行者</th><th>结果</th></tr>
<tr><td>三权分立</td><td>security_admin（全局 / IP 级）</td><td><b>成功</b></td></tr>
<tr><td>三权分立</td><td>授予 SECURITY 的普通用户（全局 / IP 级）</td><td><b>成功</b></td></tr>
<tr><td>三权分立</td><td>sys_admin / audit_admin / 普通用户（全局 / IP 级 / 解锁 root）</td><td><b>803</b></td></tr>
<tr><td>三权分立</td><td>security_admin 解锁不存在用户</td><td><b>804</b> No such user</td></tr>
</table>

<h3>六、完整异常堆栈（DataNode 192.168.99.77，原样）</h3>
<pre><code>2026-11-17 09:25:06,630 [pool-43-IoTDB-ClientRPC-Processor-1] ERROR o.a.i.d.u.ErrorHandlingUtils:75 - Status code: INTERNAL_SERVER_ERROR(305), operation: "alter user sec_uo account unlock". executeStatement failed
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
</code></pre>
<p>ConfigNode 日志无该异常——异常发生在接收语句的 DataNode 侧。</p>

<h3>七、根因（源码定位）</h3>
<p><b>7.1 为什么只在普通模式：</b>两种模式使用不同的鉴权实现。</p>
<ul>
<li>普通模式默认：<code>iotdb-core/datanode/.../auth/AuthorityChecker.java:118-119</code>
<pre><code>private static volatile AccessControl accessControl =
    new AccessControlImpl(new ITableAuthCheckerImpl(), new TreeAccessCheckVisitor());</code></pre></li>
<li>三权分立开启时替换为严格实现：<code>timecho-server/.../DataNode.java:147-157</code>
<pre><code>if (runtimeConfiguration.isSetEnableSeparationOfAdminPowers()
    &amp;&amp; runtimeConfiguration.isEnableSeparationOfAdminPowers()) {
  AuthorityChecker.setAccessControl(
      new StrictAccessControlImpl(new ITableAuthCheckerImpl(), new StrictTreeAccessCheckVisitor()));
}</code></pre>
严格 visitor 把 <code>ACCOUNT_UNLOCK</code> 归入 <code>CREATE_USER/DROP_USER</code> 组，走全局 SECURITY 鉴权
（<code>StrictTreeAccessCheckVisitor.java:109-121</code>），因此返回 803 或成功。</li>
</ul>
<p><b>7.2 标准 visitor 的直接缺陷：</b><code>TreeAccessCheckVisitor.java:793-811</code></p>
<pre><code>      case REVOKE_USER:
      case GRANT_USER:
      case GRANT_ROLE:
      case REVOKE_ROLE:
      case ACCOUNT_UNLOCK:                       // ← ACCOUNT_UNLOCK 被并入 GRANT/REVOKE 分支
        ...
        if (checkHasGlobalAuth(..., PrivilegeType.SECURITY, auditObject)) {
          return RpcUtils.SUCCESS_STATUS;        // 管理员在此提前返回
        }
        return checkPermissionsWithGrantOption(
            context,
            authorType,
            Arrays.stream(statement.getPrivilegeList())   // ← 第 808 行：privilegeList 为 null
                .map(s -&gt; PrivilegeType.valueOf(s.toUpperCase()))
                .collect(Collectors.toList()),
            statement.getNodeNameList());</code></pre>
<p><code>ALTER USER ... ACCOUNT UNLOCK</code> 没有"权限列表"概念：<code>setPrivilegeList()</code> 只在 GRANT/REVOKE 解析路径被调用
（<code>AuthorStatement.java:229-231</code>），<code>ACCOUNT_UNLOCK</code> 构造只设 statementType（<code>AuthorStatement.java:126-128</code>），
故 <code>privilegeList == null</code>；非管理员走到 <code>Arrays.stream(null)</code> → NPE → 305。</p>

<h3>八、影响</h3>
<ol>
<li>错误码语义错误：应 803（权限不足），实际 305（内部错误），客户端/运维无法区分权限问题与服务故障。</li>
<li>日志污染：每次触发在 DataNode 打一条 ERROR + 完整堆栈，任何无权限用户可反复触发，干扰"ERROR 零容忍"巡检。</li>
<li>审计分类失真：鉴权失败被记为内部错误。</li>
<li>不构成提权：语句最终失败，未解锁任何账号。</li>
</ol>

<h3>九、修复建议</h3>
<ol>
<li><b>主修（标准 visitor 对齐严格 visitor）</b>：在 <code>TreeAccessCheckVisitor.visitAuthor</code> 为 <code>ACCOUNT_UNLOCK</code> 增加独立分支，并从 GRANT/REVOKE 分支移除：
<pre><code>      case ACCOUNT_UNLOCK:
        return checkGlobalAuth(
            context.setAuditLogOperation(AuditLogOperation.DDL),
            PrivilegeType.SECURITY,
            statement::getUserName);</code></pre></li>
<li><b>防御加固</b>：<code>Arrays.stream(p == null ? new String[0] : p)</code>，避免同类 NPE。</li>
<li><b>单测</b>（<code>TreeAccessTest</code> / <code>AuthTest</code> 已有直测框架）：无权限用户执行 UNLOCK（含 <code>@ 'ip'</code>）必须 803；root / 有 SECURITY 者成功；断言日志无 <code>NullPointerException</code> / <code>INTERNAL_SERVER_ERROR(305)</code>。</li>
<li>顺带核对标准 visitor 中 <code>ENABLE_TOTP / RESET_TOTP / DISABLE_TOTP</code> 分支（严格 visitor 已覆盖）。</li>
<li><b>不要改动严格 visitor</b>（避免回退 TDB-899 的修复）；两者可在同一 PR 内一起过。</li>
</ol>

<h3>十、验证方法（修复后）</h3>
<ol>
<li>普通模式：无权限用户执行 <code>alter user u account unlock;</code>（含 <code>@ 'ip'</code>）→ <b>803</b>；</li>
<li><code>grep -c "Cannot read the array length" log_datanode_all.log</code> → <b>0</b>；</li>
<li>root 执行同一语句 → 成功；</li>
<li>三权分立回归：security_admin 解锁仍成功、普通用户仍 803（不得回退 TDB-899 修复）；</li>
<li>自动化回归：<code>sec_skill</code> 的 SEC-13 第 7 步（当前记 WARN，修复后应转 PASS）。</li>
</ol>

<h3>十一、证据归档（192.168.99.80）</h3>
<ul>
<li><code>/data/iotdb/autotest/sec_skill/results/artifact_305_20261117_092359/</code>：普通模式干净环境复现产物
（三种写法 CLI 输出、<b>完整堆栈</b>、三节点 CN/DN 日志 tgz、整体 bundle）</li>
<li><code>/data/iotdb/autotest/rc2_regression_logs/repro_305.log</code>：清库重建→启动→复现→抽堆栈→打包全过程</li>
<li><code>/data/iotdb/autotest/rc2_regression_logs/tdb899_vs_305.log</code>：两种模式的权限矩阵对照</li>
<li><code>/data/iotdb/autotest/rc2_regression_logs/tdb899_fixed_check.log</code>：TDB-899 在 RC2 已修复的验证（真锁定→解锁→登录）</li>
<li><code>/data/iotdb/autotest/rc2_regression_logs/sep_305_check.log</code>、<code>sep_305_after_restart.log</code>：三权分立下不复现（日志增量 +0）</li>
</ul>

<h3>十二、关联与备注</h3>
<ul>
<li>关联 TDB-899（同一功能族、不同路径）：TDB-899 修的是三权分立严格 visitor/执行路径（701 Unsupported author type），
本单修的是普通模式标准 visitor/鉴权路径（NPE/305）；建议 TDB-899 按 RC2 验证关闭。</li>
<li>附带观察（非本单缺陷）：三权分立下 root 因连续密码错误被锁时返回 822（锁定）而非 803，说明锁定检查先于"禁止 SUPER USER 登录"检查。</li>
</ul>
"""

out = r"D:\IDEA\deepseek\ip99_80\sec_skill\docs\DEFECT_unlock_305_npe_plm.html"
io.open(out, "w", encoding="utf-8", newline="\n").write(html)
print("written:", out, len(html), "chars")
