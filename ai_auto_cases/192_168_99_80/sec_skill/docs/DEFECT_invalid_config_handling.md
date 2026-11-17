# 缺陷/核查报告：非法或越界配置的处理与日志留痕（防爆破三参数）

| 项 | 内容 |
| --- | --- |
| 标题 | 【V2.0.13.1】【安全模块-身份鉴别】`failed_login_attempts` 等防爆破参数的非法值处理与需求不一致：非数字值直接 `System.exit(-1)` 拒绝 DataNode 启动、`<=0` 静默按"禁用"处理、回退默认时 `show configuration` 仍显示非法值 |
| 被测版本 | TimechoDB **2.0.13.1 RC2**，BuildInfo **`83183d0`**（企业版） |
| 环境 | 干净集群（3 节点 192.168.99.77/78/79，SR=3/DR=3，普通模式），仅改 `conf/iotdb-system.properties` 后重启 |
| 需求依据 | 《V2.0.7.1-安全模块-身份鉴别-防止口令暴力破解-需求分析》自查表：**"对超出预期的输入是否直接拒绝，而非仅做警告处理？ → 否，不合理的配置项会转用默认值"**；技术设计 §4.1.3："支持非法配置回退到默认值，并写入错误日志" |
| 复现概率 | **必现** |

## 一、三组实测（干净集群，逐组改 conf + 重启）

| 场景 | 配置 | 实际行为 | DN 日志 | 是否符合需求 |
| --- | --- | --- | --- | --- |
| **A** | `failed_login_attempts=-5` | **被接受**，按"禁用"处理；`show configuration` 显示 **-5** | `INFO LoginLockManager:80 - IP-level login attempts disabled (set to -5)`；**无 WARN/ERROR** | ❌ 未回退默认、无错误日志 |
| **B** | `password_lock_time_minutes=0` | **回退生效**（内部按 10 分钟），但 `show configuration` 仍显示 **0** | `WARN LoginLockManager:105 - Invalid lock time value (0), reset to default (10 minutes)` | ⚠️ 回退有 WARN，但**展示值未回写** |
| **C** | `failed_login_attempts=abc`（非数字） | **DataNode 拒绝启动**（`System.exit(-1)`），每节点只剩 ConfigNode 进程 | `ERROR IoTDBDescriptor:319 - Incorrect format in config file, reject DataNode startup.` + `java.lang.NumberFormatException: For input string: "abc"` | ❌ 未回退默认，直接拒绝启动；错误信息**不含键名** |

### 场景 C 的日志与堆栈（192.168.99.78 / .79）

```
2026-11-17 14:31:51,993 [main] ERROR o.a.i.d.c.IoTDBDescriptor:319 - Incorrect format in config file, reject DataNode startup.
java.lang.NumberFormatException: For input string: "abc"
	at java.base/java.lang.NumberFormatException.forInputString(NumberFormatException.java:67)
	...
```

结果：三节点进程数 `1/1/1`（只有 ConfigNode），DN 全部未起；恢复 `failed_login_attempts=5` 并重启后 `6/6` 恢复。

### 场景 A 的日志（192.168.99.77）

```
2026-11-17 14:29:53,598 [pool-52-IoTDB-ClientRPC-Processor-1] INFO  o.a.i.d.a.LoginLockManager:80 - IP-level login attempts disabled (set to -5)
2026-11-17 14:29:53,598 [pool-52-IoTDB-ClientRPC-Processor-1] INFO  o.a.i.d.a.LoginLockManager:112 - Login lock manager initialized with: IP-level attempts=disabled, User-level attempts=1000, Lock time=10 mi...
```

`show configuration` 同时显示 `failed_login_attempts = -5`（配置对象保留原值，内部实际用 `-1`）。

### 场景 B 的日志（192.168.99.77）

```
2026-11-17 14:30:55,118 [pool-52-IoTDB-ClientRPC-Processor-1] WARN  o.a.i.d.a.LoginLockManager:105 - Invalid lock time value (0), reset to default (10 minutes)
2026-11-17 14:30:55,118 ... INFO  LoginLockManager:112 - Login lock manager initialized with: ... Lock time=10 mi...
```

但 `show configuration` 仍输出 `password_lock_time_minutes = 0`（生效值 10 未回写展示层）。

## 二、根因（源码级）

### 2.1 场景 A / B：`LoginLockManager` 构造器对边界的处理

`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/auth/LoginLockManager.java:75-118`

```java
if (failedLoginAttempts <= 0) {
  this.failedLoginAttempts = -1;                       // ≤0 一律当"禁用"
  LOGGER.info(DataNodeMiscMessages.IP_LOGIN_ATTEMPTS_DISABLED, failedLoginAttempts);   // 只 INFO
} else { ... }

if (failedLoginAttemptsPerUser <= 0) { ... LOGGER.info(USER_LOGIN_ATTEMPTS_DISABLED, ...); ... }

this.passwordLockTimeMinutes = passwordLockTimeMinutes >= 1 ? passwordLockTimeMinutes : 10;
if (passwordLockTimeMinutes < 1) {
  LOGGER.warn(MISC_LOG_INVALID_LOCK_TIME_VALUE_RESET_TO_DEFAULT_10_MINUTES, passwordLockTimeMinutes);  // 只在这有 WARN
}
```

- `<=0` 的语义是**禁用**（与模板注释 `≤0 = Completely disable IP-level restrictions` 一致），**不是"非法"**，所以没有回退、没有 ERROR；
- 只有 `password_lock_time_minutes` 有"回退默认 + WARN"，但**没有把生效值回写**到 `ConfigurationFileUtils.updateAppliedProperties(...)`，导致 `show configuration` 显示原值 0。

⇒ **A 是"需求措辞 vs 模板语义"冲突**（需求笼统要求"不合理转默认并记错误日志"，模板明确"≤0=禁用"）；
**B 是展示层未回写生效值**（小缺陷）。

### 2.2 场景 C：解析异常被当成"配置文件格式错误"直接退出

`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/IoTDBDescriptor.java:297-321`

```java
properties.load(...);
commonProperties.putAll(properties);
loadInitialProperties(commonProperties);          // ← 内部对 failed_login_attempts 做 Integer.parseInt
...
} catch (Exception e) {
  LOGGER.error(DataNodeMiscMessages.INCORRECT_FORMAT_CONFIG_FILE, e);   // "Incorrect format in config file, reject DataNode startup."
  System.exit(-1);                                                      // ← 直接退出，无回退
}
```

- 数值解析在 `loadInitialProperties` → `Integer.parseInt(properties.getProperty("failed_login_attempts", ...))`，
  非数字抛 `NumberFormatException`；
- 被最外层 `catch (Exception)` 捕获 → 统一打成"配置文件格式错误"并 `System.exit(-1)`；
- **没有任何"回退默认值"的兜底**，错误信息**不含具体键名**（用户只看到 "Incorrect format in config file"）。

## 三、影响

1. **可用性**：一个字符写错（如 `failed_login_attempts=abc`）就让 **DataNode 拒绝启动**；若批量下发配置，可能整集群 DN 起不来。
2. **可运维性**：错误日志不含键名，只给 `NumberFormatException` 堆栈，排障需自行翻源码/试错。
3. **与需求不符**：需求明确"不合理的配置项会转用默认值，并写入错误日志"，实际为"拒绝启动"（C）或"静默禁用/仅 INFO"（A）。
4. **展示不一致**：B 场景回退到 10 分钟生效，但 `show configuration` 仍显示 0，运维会误判。

## 四、修复建议

1. **数值型配置统一兜底**（对应场景 C）：
   - 解析失败时回退"模板默认值"，并打 `ERROR` 日志，**日志里带键名与原始值**（例如
     `Invalid value 'abc' for failed_login_attempts, fallback to default 5`）；
   - 不要因单个键解析失败 `System.exit(-1)`；若产品坚持 fail-fast，至少把键名/原始值写进 ERROR 与异常消息。
2. **明确 `<=0` 的语义**（对应场景 A）：
   - 若沿用模板"≤0=禁用"：把需求文档的"不合理配置转默认值"限定为"非数字/类型错误"，并为 `<=0` 打 `WARN`（提示"已被解释为禁用"）；
   - 若需求要求"≤0 也回退默认"：改 `LoginLockManager` 构造器。
3. **回退后回写生效值**（对应场景 B）：`password_lock_time_minutes` 回退为 10 后调用
   `ConfigurationFileUtils.updateAppliedProperties`，让 `show configuration` 显示 10。
4. **补单测**（`LoginLockManagerTest` / `IoTDBDescriptorTest`）：
   - `failed_login_attempts=abc` → 回退 5 + ERROR 含键名，进程仍能启动；
   - `failed_login_attempts=-5` → 明确"禁用"并 WARN；
   - `password_lock_time_minutes=0` → 生效 10 且 `show configuration` 显示 10。
5. 回归：`sec_skill` 的 **SEC-15** 第 4 步（当前对负值只记 WARN，修复后应能断言"回退默认 + ERROR 含键名"）。

## 五、优先级与结论

- **建议 P2**：需要人为写错配置才触发，但后果是 DataNode 拒绝启动（可用性），且与需求明确条款不符。
- **A/B/C 三条应按不同性质分别处理**：
  - **C = 缺陷**（非法值未回退、直接退出、错误信息缺键名）；
  - **B = 小缺陷**（回退生效但展示值未回写）；
  - **A = 需求/文档措辞冲突**（模板已定义 `≤0=禁用`，需求笼统写"转默认"）。

## 六、证据归档（192.168.99.80）

| 路径 | 内容 |
| --- | --- |
| `/data/iotdb/autotest/rc2_regression_logs/repro_invalidcfg.log` | 三组场景完整执行日志（含 show configuration 回显、DN 日志、进程数） |
| `/data/iotdb/autotest/sec_skill/results/artifact_invalidcfg_20261117_142928/` | 产物目录（`stack_numberformat.txt` 场景 C 堆栈、bundle） |
| `sec_skill/tools/repro_invalidcfg.sh` / `stack_nf_and_restore.sh` | 一键复现 / 抓堆栈并恢复脚本 |

实测时间：2026-11-17 14:29–14:41；恢复后集群 6/6、`failed_login_attempts=5`、`password_lock_time_minutes=10`。
