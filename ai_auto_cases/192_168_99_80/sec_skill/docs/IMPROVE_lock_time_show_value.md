# 待改进描述（给研发）：`password_lock_time_minutes` 回退生效但 `show configuration` 仍显示原值

> 性质：**小问题 / 展示不一致**（用户确认：保留为观察项，单独提给研发改一下，不占缺陷单）
> 版本：V2.0.13.1 RC2，BuildInfo `83183d0`
> 环境：3C3D（192.168.99.77/78/79），SR=3/DR=3，普通模式

## 一、现象

把 `password_lock_time_minutes` 配成 `< 1`（例如 `0`）后重启：

**DN 日志证明已回退生效**：

```
2026-11-17 14:30:55,118 [pool-52-IoTDB-ClientRPC-Processor-1] WARN  o.a.i.d.a.LoginLockManager:105
  - Invalid lock time value (0), reset to default (10 minutes)
2026-11-17 14:30:55,118 ... INFO  o.a.i.d.a.LoginLockManager:112
  - Login lock manager initialized with: IP-level attempts=disabled, User-level attempts=1000, Lock time=10 mi...
```

**但 `show configuration` 仍显示 0**：

```
| password_lock_time_minutes | 0 |
```

## 二、期望

`show configuration` 应显示**实际生效值 10**（或至少在该行体现"已被回退为 10"），
使运维看到的配置与真实行为一致。

## 三、影响

- 运维按 `show configuration` 判断锁定时长会**误判**：以为 0 = 不锁定/立即解锁，实际按 **10 分钟**执行；
- 与同类键的处理不一致：`failed_login_attempts` / `failed_login_attempts_per_user` 已被纳入"生效值覆盖"逻辑（见下），
  唯独 `password_lock_time_minutes` 漏了。

## 四、根因（源码）

1. **回退只发生在运行期对象内部**：`LoginLockManager` 构造器
   （`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/auth/LoginLockManager.java:102-109`）

```java
this.passwordLockTimeMinutes = passwordLockTimeMinutes >= 1 ? passwordLockTimeMinutes : 10;
if (passwordLockTimeMinutes < 1) {
  LOGGER.warn(MISC_LOG_INVALID_LOCK_TIME_VALUE_RESET_TO_DEFAULT_10_MINUTES_8DCE21EF, passwordLockTimeMinutes);
}
```

   生效值只写进 `LoginLockManager.passwordLockTimeMinutes`，**没有回写** `IoTDBConfig` / `ConfigurationFileUtils`。

2. **`show configuration` 读的是 applied properties**：
   `IoTDBDescriptor.overlayEffectiveConfigurationValues()`（`IoTDBDescriptor.java:3154-3225`）会把"setter/loader 改写过"的键
   用生效值覆盖进 `ConfigurationFileUtils`，注释明确写了
   `local *and* remote 'show configuration' (which reads each node's own map over RPC) stay correct`。

   当前该 overlay **包含**：
   - `failed_login_attempts`（`IoTDBDescriptor.java:3205-3206`）
   - `failed_login_attempts_per_user`（`:3207-3208`）
   - `password_expiration_days`（`:3209-3211`）

   但**不包含** `password_lock_time_minutes`（全文件仅 `:890` 的 loadProps 一次出现）。
   ⇒ 该键没有覆盖，`show configuration` 显示文件/模板原始值 `0`。

3. 补充：`LoginLockManager` 目前只暴露了 `getFailedLoginAttempts()`（`:192`），
   **没有** `getPasswordLockTimeMinutes()` / `getFailedLoginAttemptsPerUser()` 的 getter，做 overlay 时需要补。

## 五、修复建议

在 `IoTDBDescriptor.overlayEffectiveConfigurationValues()` 里补一条（并把 getter 补上）：

```java
ConfigurationFileUtils.updateAppliedProperties(
    "password_lock_time_minutes",
    Integer.toString(LoginLockManager.getInstance().getPasswordLockTimeMinutes()));
```

`LoginLockManager` 增加：

```java
public int getPasswordLockTimeMinutes() { return passwordLockTimeMinutes; }
```

**顺带建议**（同族一致性问题，可与上条一起改）：
- `failed_login_attempts` / `failed_login_attempts_per_user` 的 overlay 现在用的是 `conf.getFailedLoginAttempts()`（原始值），
  而 `LoginLockManager` 内部把 `<=0` 归一成 `-1`（禁用）；因此 `failed_login_attempts=-5` 时
  `show configuration` 显示 **-5**、实际生效是 **禁用**。若希望"展示=生效"，应改为读 `LoginLockManager` 的生效值；
  或按产品决定：`<=0` 时显示 `-1`（禁用）。

## 六、验证方法（改完后）

1. `password_lock_time_minutes=0` → 重启 → `show configuration` 应显示 **10**，WARN 仍在；
2. 锁定时长实测为 10 分钟（触发锁定后等 10 分钟自动解锁，或用 `password_lock_time_minutes=1` 做快速验证）；
3. 恢复默认为 10 时，`show configuration` 仍显示 10（无副作用）；
4. 回归用例：`sec_skill` 的 **SEC-15**（可加一条断言：`lock_time=0` 重启后 `show` 值 = 10）。

## 七、证据

- 复现日志：`/data/iotdb/autotest/rc2_regression_logs/repro_invalidcfg.log`
  （场景 B：14:30:41 重启 → `show: password_lock_time_minutes = 0` + WARN `Invalid lock time value (0)`）
- 产物：`/data/iotdb/autotest/sec_skill/results/artifact_invalidcfg_20261117_142928/`
- 复现脚本：`sec_skill/tools/repro_invalidcfg.sh`
- 详细报告（含三组场景对比）：`docs/DEFECT_invalid_config_handling.md`
