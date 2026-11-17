> **🟢 结论更新（2026-11-17 11:40，用户确认）：本条不算缺陷，已撤回。**
>
> - **普通模式（未开三权分立）**：`root` 修改四个键（`failed_login_attempts` / `failed_login_attempts_per_user` /
>   `password_lock_time_minutes` / `password_stale_warning_days`）**全部成功**——今天 11:09 的 `check_stale_mode.sh`
>   就是 root 身份执行并拿到 `The statement is executed successfully.`（含 `restart is required` 提示）。
> - **三权分立模式**：`security_admin` 无 SYSTEM、由 `sys_admin` 承担系统级配置，属**职责分离的预期设计**；
>   用户确认"没这个问题"。
> - 因此下面记录的现象**不是缺陷**，仅作为"角色-配置权限矩阵"的**行为记录**保留；
>   若后续要对齐文档措辞（需求写"root 或安全管理员"，实际 sep 下为"root 或系统管理员"），按文档修订项处理，不建缺陷单。

# 缺陷报告：三权分立下"安全管理员"无法修改防爆破锁定配置（返回 803 缺 SYSTEM）

| 项 | 内容 |
| --- | --- |
| 缺陷标题 | 【V2.0.13.1】【安全模块-身份鉴别】三权分立下 `security_admin` 修改 `failed_login_attempts` / `failed_login_attempts_per_user` / `password_lock_time_minutes` 返回 **803（缺 SYSTEM）**，只有 `sys_admin` 能改；与需求"新增配置只可由 root 或安全管理员修改"不符 |
| 被测版本 | TimechoDB **2.0.13.1 RC2**，BuildInfo **`83183d0`**（企业版） |
| 环境 | 干净集群（3 节点，192.168.99.77/78/79，SR=3/DR=3）；**三权分立**（`enable_separation_of_powers=true`，root 已禁登 803） |
| 复现概率 | **必现**（三个键全部命中） |
| 优先级建议 | ~~P2~~ → **非缺陷（撤回）**：普通模式 root 可改；sep 下由 sys_admin 承担属分权设计 |

## 一、复现步骤（1 分钟）

```sql
-- 前置：enable_separation_of_powers=true（root 已被禁止登录）
-- 用 security_admin（持 SECURITY）执行：
set configuration 'failed_login_attempts'='5';
set configuration 'failed_login_attempts_per_user'='5';
set configuration 'password_lock_time_minutes'='5';
-- 对照：同一账号改这个键是成功的
set configuration 'password_stale_warning_days'='5';
```

## 二、实际结果 vs 期望

| 执行者 | 语句 | 实际返回 |
| --- | --- | --- |
| **security_admin** | `set configuration 'failed_login_attempts'='5';` | ❌ **803: No permissions for this operation, please add privilege SYSTEM** |
| **security_admin** | `set configuration 'failed_login_attempts_per_user'='5';` | ❌ **803** 缺 SYSTEM |
| **security_admin** | `set configuration 'password_lock_time_minutes'='5';` | ❌ **803** 缺 SYSTEM |
| security_admin（对照） | `set configuration 'password_stale_warning_days'='5';` | ✅ **成功** |
| sys_admin（对照） | `set configuration 'failed_login_attempts'='5';` | ✅ 成功（`... restart is required ...`） |
| sys_admin（对照） | `set configuration 'password_stale_warning_days'='30';` | ❌ **803 缺 SECURITY**（与上一行正好镜像） |
| audit_admin | `set configuration 'failed_login_attempts'='5';` | ❌ 803 缺 SYSTEM |

**期望**：按《V2.0.7.1-安全模块-身份鉴别-防止口令暴力破解-需求分析》"权限要求"——
> "新增配置只可由 **root 或安全管理员** 修改"

三权分立下 root 被禁登（803 属需求行为），因此**应由 security_admin 修改**；实际被拒，只有 sys_admin（SYSTEM）可改。

补充：`security_admin` 可以**读** `show configuration`（能看到 `password_stale_warning_days` 等行），但**写**锁定类键被拒 —— 说明不是"整体权限缺失"，而是这些键的**权限映射错误**。

## 三、根因（源码级，确定性）

### 3.1 配置键的权限来自"模板注解"，缺注解默认 SYSTEM

`iotdb-core/datanode/.../statement/sys/SetConfigurationStatement.java:81-91`

```java
public Collection<PrivilegeType> getNeededPrivileges() throws IOException {
  Set<PrivilegeType> neededPrivileges = new HashSet<>();
  for (String key : this.getConfigItems().keySet()) {
    PrivilegeType neededPrivilege = ConfigurationFileUtils.getConfigurationItemPrivilege(key);
    if (neededPrivilege == null) { continue; }
    neededPrivileges.add(neededPrivilege);
  }
  return neededPrivileges;
}
```

`iotdb-core/node-commons/.../conf/ConfigurationFileUtils.java:338-347` → 查模板解析结果：

```java
public static PrivilegeType getConfigurationItemPrivilege(String parameterName) throws IOException {
  ...
  DefaultConfigurationItem defaultConfigurationItem = configuration2DefaultValue.get(parameterName);
  return defaultConfigurationItem == null ? null : defaultConfigurationItem.privilege;
}
```

解析模板时只认 `# Privilege:` 注解（`PRIVILEGE_PREFIX = "Privilege:"`，`ConfigurationFileUtils.java:629-634`），
**缺失时默认 SYSTEM**（`ConfigurationFileUtils.java:686`）：

```java
this.privilege = privilegeType == null ? PrivilegeType.SYSTEM : privilegeType;
```

鉴权：`TreeAccessCheckVisitor.visitSetConfiguration`（`TreeAccessCheckVisitor.java:2163-2178`）→
`AuthorityChecker.checkUserMissingSystemPermissions(username, relatedPrivileges)` → 缺 SYSTEM 即返回 803。

### 3.2 模板里这三个键**没有** `# Privilege: SECURITY`

`conf/iotdb-system.properties.template`（打包在 jar 内的资源，`CommonConfig.SYSTEM_CONFIG_TEMPLATE_NAME`）：

```
# The maximum number of consecutive failed login attempts from a single IP address
# Options:
#   ≤0 = Completely disable IP-level restrictions
#   ≥1 = Custom attempt threshold (default: 5)
# effectiveMode: restart
# Datatype: Integer
# Note: When enabled, failed_login_attempts_per_user must also be enabled
failed_login_attempts=5          ← 没有 # Privilege: SECURITY
```

```
# The lock time duration (in minutes) after reaching failed login attempts threshold
# Options: any positive integer (minimum: 1, default: 10)
# effectiveMode: restart
# Datatype: Integer
password_lock_time_minutes=10    ← 没有 # Privilege: SECURITY
```

对照（同族安全键，有注解）：

```
# The number of days since last password change to trigger a warning
# Options: any positive integer(minimum 1), <= 0 means disabled (no warning)
# effectiveMode: hot_reload
# Privilege: SECURITY            ← 有注解，所以 security_admin 可改
# Datatype: Integer
password_stale_warning_days=30
```

⇒ 三个防爆破锁定键因缺注解被当作 **SYSTEM-only**，于是"安全管理员改不了锁定策略、系统管理员改不了密码策略"的镜像行为。

## 四、影响

1. **三权分立设计目标落空**：安全管理员本应负责"安全策略管控"（账号锁定属安全策略），却无权修改，只能让 sys_admin 代劳 → 职责分离被打破。
2. **安全策略不可运维**：客户启用三权分立后，锁定阈值/锁定时长无法由安全管理员调整，遇到"账号被大量锁定"等场景处置链变长。
3. **审计与合规**：安全类配置由系统管理员修改，不符合"最小权限/职责分离"的审计预期。
4. 不涉及越权（实际是权限偏严，失败即拒绝）。

## 五、修复建议

1. **主修**：在 `iotdb-system.properties.template` 中给三个键补 `# Privilege: SECURITY`（与 `password_stale_warning_days` 一致）：
   - `failed_login_attempts`
   - `failed_login_attempts_per_user`
   - `password_lock_time_minutes`
   注意模板是 **classpath 资源**（jar 内 `iotdb-system.properties.template`），需改源码资源并重新打包，改 `conf/` 下的副本无效。
2. **顺带核对**：所有"安全模块"配置键是否都带 `# Privilege: SECURITY`（建议加一个静态校验/单测，
   遍历模板断言"安全类键必须有 SECURITY 注解"），避免后续新增键再漏。
3. **单测**：
   - `getConfigurationItemPrivilege("failed_login_attempts") == PrivilegeType.SECURITY`；
   - sep 模式下 security_admin 可 SET 三个锁定键、sys_admin 应被拒（803 SECURITY）；
   - `show configuration` 与 SET 的权限模型一致。
4. 若产品坚持"锁定配置属 SYSTEM"，则需**同步修改需求文档**（"仅 root 或系统管理员可修改"）——但这与"安全管理员负责安全策略"的设计冲突，建议前者。

## 六、验证方法（修复后）

1. 三权分立下 `security_admin`：`set configuration 'failed_login_attempts'='7'` → 成功（返回 restart 提示）；三个键均如此；
2. 三权分立下 `sys_admin`：同一语句 → **803 缺 SECURITY**（与 `password_stale_warning_days` 现状一致）；
3. 普通模式下 root：仍可修改；
4. 重启后生效值正确；`show configuration` 权限与 SET 对齐；
5. 回归用例：`sec_skill` 的 **SEC-15** 第 5 步（当前记为"权限边界观察 WARN"，修复后应转为 PASS）。

## 七、证据归档（192.168.99.80）

| 路径 | 内容 |
| --- | --- |
| `/data/iotdb/autotest/rc2_regression_logs/repro_lockpriv.log` | 复现执行日志（模式判定、权限矩阵、模板注解） |
| `/data/iotdb/autotest/sec_skill/results/artifact_lockpriv_20261117_113357/` | 产物目录（CLI 原始输出 `cli_matrix.txt`、模板注解 `template_annot.txt`、日志命中 `logs_hits.txt`、bundle） |
| `sec_skill/tools/repro_lockpriv.sh` | 一键复现脚本（开 sep → 矩阵 → 取证） |

复现时间：2026-11-17 11:34，三权分立（root 803），`security_admin` 三个键全部 803 缺 SYSTEM。

## 八、备注

- 本缺陷与 **TDB-1607**（普通模式非授权 UNLOCK → NPE/305）无关：那是"鉴权路径 NPE + 错误码"，本单是"配置键权限映射（模板注解）"。
- 与 **TDB-1606**（reuse 配置 0 被改写）也无关联。
