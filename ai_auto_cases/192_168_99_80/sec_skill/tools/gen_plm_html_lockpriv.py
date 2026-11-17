#!/usr/bin/env python3
"""生成 PLM 描述 HTML：三权分立下 security_admin 无法修改防爆破锁定配置。"""
import io

html = """<h3>一、缺陷摘要</h3>
<p><b>三权分立</b>（<code>enable_separation_of_powers=true</code>，root 已禁登 803）下，持有 <b>SECURITY</b> 权限的
<code>security_admin</code> 修改三个防爆破锁定参数返回 <b>803（缺 SYSTEM）</b>，
只有 <code>sys_admin</code>（SYSTEM）能改；与需求“<b>新增配置只可由 root 或安全管理员修改</b>”不符。</p>
<p>受影响配置项：<code>failed_login_attempts</code>、<code>failed_login_attempts_per_user</code>、<code>password_lock_time_minutes</code>。</p>
<p><b>普通模式无此问题</b>：root 修改上述四个键（含 <code>password_stale_warning_days</code>）全部成功（见第五节实测）。</p>
<p><b>研发已提供修复</b>：<a href="https://gitlab.timecho.com/r-d/db/timechodb/-/merge_requests/7532">MR 7532</a>
（给模板补 <code># Privilege: SECURITY</code> 注解，使这三个键的权限映射为 SECURITY）。</p>

<h3>二、环境</h3>
<ul>
<li>版本：TimechoDB <b>V2.0.13.1</b>，BuildInfo <code>83183d0</code>（企业版）。</li>
<li>集群：3 ConfigNode + 3 DataNode（192.168.99.77/78/79），SR=3 / DR=3，IoTConsensus。</li>
<li>模式：三权分立（<code>enable_separation_of_powers=true</code>，root 登录返回 803 属需求行为）。</li>
</ul>

<h3>三、复现步骤</h3>
<pre><code>-- 前置：三权分立已开启（root 禁登）
-- 用 security_admin（持 SECURITY）执行：
set configuration 'failed_login_attempts'='5';
set configuration 'failed_login_attempts_per_user'='5';
set configuration 'password_lock_time_minutes'='5';
-- 对照：同一账号改这个键是成功的
set configuration 'password_stale_warning_days'='5';
</code></pre>

<h3>四、实际结果 vs 期望</h3>
<table border="1" cellspacing="0" cellpadding="4">
<tr><th>执行者</th><th>语句</th><th>实际返回</th></tr>
<tr><td><b>security_admin</b></td><td><code>set configuration 'failed_login_attempts'='5';</code></td><td><b>803: No permissions for this operation, please add privilege SYSTEM</b></td></tr>
<tr><td><b>security_admin</b></td><td><code>failed_login_attempts_per_user</code></td><td><b>803</b> 缺 SYSTEM</td></tr>
<tr><td><b>security_admin</b></td><td><code>password_lock_time_minutes</code></td><td><b>803</b> 缺 SYSTEM</td></tr>
<tr><td>security_admin（对照）</td><td><code>password_stale_warning_days</code></td><td>✅ 成功</td></tr>
<tr><td>sys_admin（对照）</td><td><code>failed_login_attempts</code></td><td>✅ 成功（restart 提示）</td></tr>
<tr><td>sys_admin（对照）</td><td><code>password_stale_warning_days</code></td><td><b>803</b> 缺 SECURITY（与上一行正好镜像）</td></tr>
<tr><td>audit_admin</td><td><code>failed_login_attempts</code></td><td><b>803</b> 缺 SYSTEM</td></tr>
</table>
<p><b>期望</b>：按《V2.0.7.1-安全模块-身份鉴别-防止口令暴力破解-需求分析》“权限要求”——“新增配置只可由 root 或安全管理员修改”。
三权分立下 root 被禁登，因此应由 <code>security_admin</code> 修改。</p>
<p>补充：<code>security_admin</code> 可正常 <code>show configuration</code>（能读到这些行），只是写被拒 → 不是整体缺权，而是这几个键的<b>权限映射</b>问题。</p>

<h3>五、普通模式对照（无此问题）</h3>
<p>干净环境（清库重建）普通模式下，root 修改四个键<b>全部成功</b>：</p>
<pre><code>root&gt; set configuration 'failed_login_attempts'='5';
Msg: ... Configuration has been set successfully, but restart is required ... failed_login_attempts.
root&gt; set configuration 'failed_login_attempts_per_user'='5';   → 同上（restart 提示）
root&gt; set configuration 'password_lock_time_minutes'='5';        → 同上（restart 提示）
root&gt; set configuration 'password_stale_warning_days'='5';      → Msg: successfully（热加载）
</code></pre>
<p>普通模式下三个分权内置账号不存在（<code>804: The user security_admin/sys_admin/audit_admin does not exist</code>），
故本缺陷<b>仅限三权分立模式</b>。</p>

<h3>六、根因（源码）</h3>
<p><b>6.1 配置键的权限来自“模板注解”，缺注解默认 SYSTEM</b></p>
<ul>
<li><code>SetConfigurationStatement.getNeededPrivileges()</code>（<code>SetConfigurationStatement.java:81-91</code>）
按<b>键</b>调 <code>ConfigurationFileUtils.getConfigurationItemPrivilege(key)</code>；</li>
<li>该函数（<code>ConfigurationFileUtils.java:338-347</code>）返回<b>解析配置模板得到的注解值</b>；
解析只认 <code># Privilege:</code>（<code>ConfigurationFileUtils.java:629-634</code>）；</li>
<li><b>缺注解时默认 SYSTEM</b>（<code>ConfigurationFileUtils.java:686</code>）：
<pre><code>this.privilege = privilegeType == null ? PrivilegeType.SYSTEM : privilegeType;</code></pre></li>
<li>鉴权：<code>TreeAccessCheckVisitor.visitSetConfiguration</code>（<code>TreeAccessCheckVisitor.java:2163-2178</code>）
→ <code>AuthorityChecker.checkUserMissingSystemPermissions(...)</code> → 缺 SYSTEM 即返回 803。</li>
</ul>
<p><b>6.2 模板里这三个键没有 <code># Privilege: SECURITY</code></b>（<code>iotdb-system.properties.template</code>，打包在 jar 内资源）：</p>
<pre><code># effectiveMode: restart
# Datatype: Integer
# Note: When enabled, failed_login_attempts_per_user must also be enabled
failed_login_attempts=5          ← 无 # Privilege: SECURITY

# effectiveMode: restart
# Datatype: Integer
password_lock_time_minutes=10    ← 无 # Privilege: SECURITY
</code></pre>
<p>对照（同族安全键，有注解 → 所以 security_admin 可改）：</p>
<pre><code># effectiveMode: hot_reload
# Privilege: SECURITY
# Datatype: Integer
password_stale_warning_days=30
</code></pre>

<h3>七、影响</h3>
<ol>
<li>三权分立设计目标受损：账号锁定属<b>安全策略</b>，安全管理员却无权调整，只能由系统管理员代劳，职责分离被打破。</li>
<li>安全策略不可运维：客户启用三权分立后，锁定阈值/锁定时长无法由安全管理员调整。</li>
<li>审计与合规：安全类配置由系统管理员修改，不符合最小权限/职责分离的审计预期。</li>
<li>不涉及越权（权限偏严，失败即拒绝）。</li>
</ol>

<h3>八、修复方案（研发已提供 MR 7532）</h3>
<ol>
<li><b>主修</b>：在 <code>iotdb-system.properties.template</code> 给三个键补 <code># Privilege: SECURITY</code>：
<code>failed_login_attempts</code>、<code>failed_login_attempts_per_user</code>、<code>password_lock_time_minutes</code>。
注意模板是 <b>classpath 资源</b>（jar 内 <code>iotdb-system.properties.template</code>），需改源码资源并重新打包，改 conf 目录副本无效。</li>
<li><b>关联 MR</b>：<a href="https://gitlab.timecho.com/r-d/db/timechodb/-/merge_requests/7532">7532</a>。</li>
<li><b>建议补单测</b>：断言 <code>getConfigurationItemPrivilege("failed_login_attempts") == PrivilegeType.SECURITY</code>；
sep 下 security_admin 可 SET、sys_admin 应 803 SECURITY（与 <code>password_stale_warning_days</code> 对称）。</li>
<li>顺带建议加一个静态校验：所有“安全类键”在模板中必须带 <code># Privilege: SECURITY</code>，避免后续新增键再漏。</li>
</ol>

<h3>九、验证方法（修复后）</h3>
<ol>
<li>三权分立下 <code>security_admin</code>：三个锁定键 SET → 成功（返回 restart 提示）；</li>
<li>三权分立下 <code>sys_admin</code>：同一语句 → <b>803 缺 SECURITY</b>（与 <code>password_stale_warning_days</code> 现状一致）；</li>
<li>普通模式下 root：仍可修改（回归不退化）；</li>
<li>重启后生效值正确；<code>show configuration</code> 权限与 SET 对齐；</li>
<li>自动化回归：<code>sec_skill</code> 的 <b>SEC-15</b> 第 5 步（当前按“设计/待研发确认”断言，修复后应转为“security_admin 可改”的硬断言）。</li>
</ol>

<h3>十、证据归档（192.168.99.80）</h3>
<ul>
<li><code>/data/iotdb/autotest/rc2_regression_logs/repro_lockpriv.log</code>：三权分立复现日志（权限矩阵 + 模板注解）</li>
<li><code>/data/iotdb/autotest/rc2_regression_logs/confirm_normal_matrix.log</code>：普通模式 root 四键全部成功的实测</li>
<li><code>/data/iotdb/autotest/sec_skill/results/artifact_lockpriv_20261117_113357/</code>（sep 矩阵 CLI 原始输出、模板注解）</li>
<li><code>/data/iotdb/autotest/sec_skill/results/artifact_normal_confirm_20261117_115705/</code>（普通模式矩阵）</li>
<li>脚本：<code>sec_skill/tools/repro_lockpriv.sh</code>、<code>confirm_normal_matrix.sh</code></li>
<li>文档：<code>sec_skill/docs/DEFECT_lock_config_privilege.md</code>、<code>docs/CONFIG_SEMANTICS.md</code></li>
</ul>

<h3>十一、备注</h3>
<ul>
<li>本缺陷与 TDB-1607（普通模式非授权 UNLOCK → NPE/305，鉴权路径）、TDB-1606（reuse=0 被改写）均无关。</li>
<li>普通模式无此问题（root 可改），故本单仅针对三权分立模式的权限映射。</li>
<li>“show configuration 显示原值/生效值差异”已按用户共识不视为缺陷（见 <code>docs/CONFIG_SEMANTICS.md</code>）。</li>
</ul>
"""

out = r"D:\IDEA\deepseek\ip99_80\sec_skill\docs\DEFECT_lock_config_privilege_plm.html"
io.open(out, "w", encoding="utf-8", newline="\n").write(html)
print("written:", out, len(html), "chars")
