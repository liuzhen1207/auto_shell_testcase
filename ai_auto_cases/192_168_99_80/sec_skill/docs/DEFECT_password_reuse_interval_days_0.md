# 缺陷报告：password_reuse_interval_days=0（需求规定的"无历史约束"）被内部改写为 1 天

| 项 | 内容 |
| --- | --- |
| 缺陷标题 | 【V2.0.13.1】【安全模块-身份鉴别】`password_reuse_interval_days=0` 被内部改写为 1 天：默认即禁止重用历史口令，且 `show configuration` 与实际行为不一致 |
| 被测版本 | TimechoDB **2.0.13.1 RC2**，BuildInfo **`83183d0`** |
| 环境 | 3C3D：3 ConfigNode + 3 DataNode（192.168.99.77/78/79），**SR=3 / DR=3**，IoTConsensus；驱动机 .80 |
| 模式 | **普通模式（root）与三权分立模式（security_admin）均复现**，与三权分立无关 |
| 严重程度 | **P2（中）**：功能与需求不符、默认即生效、且运行期无法通过配置关闭（策略偏严，非绕过类安全问题） |
| 状态 | 待研发确认 |

## 一、需求原文

《V2.0.7.1-安全模块-身份鉴别-强安全级别密码-需求分析》V0.2（2025-10-23）三、功能定义：

> 在 `iotdb-system.properties` 配置文件中增加配置项 `password_reuse_interval_days`，**默认值为 0（代表无历史密码约束）**。
> 当设置值大于 0 时，用户修改密码后将对旧密码进行记录与匹配，如果新密码与某一个历史密码相同，并且该历史密码的最后一次修改时间至今的时间跨度小于该配置值，
> 则拒绝本次密码修改并报错：`The password has been used recently, and it cannot be reused before <下次可用时间>`。

配置模板（`iotdb-system.properties.template:2297`）同样写的是：
```
# When > 0, the old password of a user cannot be reused within the days specified by this item,
# after a successful password change.
password_reuse_interval_days=0
```

## 二、最小复现（1 分钟，默认配置即可）

```sql
-- 0) 确认配置（默认 0）
show configuration;                    -- | password_reuse_interval_days | 0 | 0 |
-- conf 文件：password_reuse_interval_days=0（三节点一致）

-- 1) 建用户（密码 A）
create user u1 'Abcdefgh123!';         -- 成功
-- 2) 改成 B
alter user u1 set password 'Abcdefgh456@';   -- 成功
-- 3) 改回 A（重用创建时的密码）
alter user u1 set password 'Abcdefgh123!';
```

**期望**：第 3 步成功（0 = 无历史密码约束）
**实际**：第 3 步被拒
```
701: The password has been used recently, and it cannot be reused before Tue Nov 17 16:09:46 CST 2026
```
（提示时间点 = 密码 A 的最后修改时间 **+ 1 天** ⇒ 实际生效窗口是 **1 天**，不是 0）

## 三、对照实验（定位到"0 被改写为 1"）

| 配置值（`show configuration` 回显） | A→B→A 结果 | 说明 |
| --- | --- | --- |
| `password_reuse_interval_days = 0` | **701 拒绝**（窗口 1 天） | 与需求冲突 |
| `password_reuse_interval_days = -1` | **成功**（不限制） | 与"<=0 即禁用"的代码逻辑一致 |
| 设回 `0` 再试 | **立刻又被拒**（1 天） | 不是热加载问题 |
| 改 conf=0 后**整集群重启**再试 | **仍被拒**（1 天） | 排除"热加载/缓存"可能 |

- `-1` 放行、`0` 拒绝，两者仅差在 setter 对 0 的特殊处理 ⇒ 根因唯一
- `show configuration` 对 `-1` 与 `0` 都如实回显，说明**配置展示值 ≠ 实际判定值**

## 四、根因（源码级，确定性）

`iotdb-core/node-commons/src/main/java/org/apache/iotdb/commons/conf/CommonConfig.java:3428`

```java
public void setPasswordReuseIntervalDays(long passwordReuseIntervalDays) {
  this.passwordReuseIntervalDays = passwordReuseIntervalDays == 0 ? 1 : passwordReuseIntervalDays;
}
```

- 任何来源的 `0`（模板默认值 0、conf 文件 0、`SET CONFIGURATION ... '0'`）都会被改写成 **1**；
- 启动加载（`IoTDBDescriptor.loadProps` → `setPasswordReuseIntervalDays`，`IoTDBDescriptor.java:1196`）与热加载（`IoTDBDescriptor.java:2880`）都会经过这个 setter，所以**重启也无法恢复**；
- 消费侧本来就把 `<=0` 当"不限制"：`DataNodeAuthUtils.verifyPasswordReuse()`（`DataNodeAuthUtils.java:186-206`）

```java
long passwordReuseIntervalDays = CommonDescriptor.getInstance().getConfig().getPasswordReuseIntervalDays();
if (password == null || passwordReuseIntervalDays <= 0) {
  return;                       // <=0 即禁用，说明 setter 的 0→1 改写纯属多余
}
```
- 对照：`setPasswordExpirationDays()` 走 `EditionGate.forceValueInIoTDB(...)`，**没有**这种 0→1 改写（`CommonConfig.java:3418`），说明这不是统一约定，而是该 setter 的个例。

## 五、影响

1. **默认配置即生效**：新装集群（模板默认 0）就带 1 天历史口令限制，与需求"默认 0 = 无约束"不符；文档/配置无法表达"真正关闭"。
2. **配置不可控 + 展示不一致**：`show configuration` 显示 0，实际按 1 天判定；运维无法通过配置关闭该策略，排障时会被配置值误导（本次排查即因此耗时）。
3. **运维可用性风险**：应急回滚密码、同一密码轮换回退在 24 小时内会被拒绝（例如变更失败想回退到原密码）。
4. 策略偏**严**而非绕过，不构成安全漏洞，但与需求/文档不一致，属功能缺陷。

## 六、修复建议

1. **最小修复**（推荐）：
   ```java
   public void setPasswordReuseIntervalDays(long passwordReuseIntervalDays) {
     this.passwordReuseIntervalDays = passwordReuseIntervalDays;   // 去掉 0 → 1
   }
   ```
   `verifyPasswordReuse()` 已有 `<= 0 → return`，行为即符合"0/-1 = 不限制、>0 = N 天"。
2. 若历史上有"0 表示 1 天"的兼容诉求，应改为：`0 → 0`（禁用）、用 `-1` 表示"未配置"（与字段默认值 `-1` 一致），并在 `show configuration` 中体现**生效值**而非文件值。
3. **补单测**：
   - `setPasswordReuseIntervalDays(0)` 后 `getPasswordReuseIntervalDays() == 0`；
   - 默认配置启动后 A→B→A 必须成功；
   - `>0` 时窗口内拒绝、窗口外允许（可用时钟偏移或注入时钟）；
   - `show configuration` 的生效值与实际判定一致。
4. 兼容性检查：确认没有环境依赖"写 0 得到 1 天"的旧行为（不太可能，因为文档明确 0=无约束）。

## 七、验证方法（修复后）

1. 默认配置（0）：`create u1 A` → `alter u1 B` → `alter u1 A` 必须**成功**；
2. `SET CONFIGURATION 'password_reuse_interval_days'='0'` 后立即复测，必须**成功**；
3. `SET ... ='1'` 后立即 `B→A` 必须**被拒**（文案带 +1 天时间点）；时钟前移 2 天后 `B→A` 必须**成功**；
4. `show configuration` 回显值 = 实际判定值；
5. 回归用例：`sec_skill` 的 **SEC-05** 应由 FAIL 转 **PASS**（当前两模式均 FAIL，fail_flag=2）。

## 八、证据文件（192.168.99.80）

| 文件 | 内容 |
| --- | --- |
| `/data/iotdb/autotest/rc2_regression_logs/sec05_rootcause.log` | 复现 + 三节点生效值/conf 值 + `SET 0` 后仍拒绝 |
| `/data/iotdb/autotest/rc2_regression_logs/sec05_restart_test.log` | conf=0 且整集群重启后仍拒绝（排除热加载） |
| `/data/iotdb/autotest/rc2_regression_logs/sec05_minus1.log` | `-1` 放行、改回 `0` 立刻又拒绝（定位到 setter） |
| `/data/iotdb/autotest/sec_skill/cases/password/sec_password_reuse.sh` | 回归用例 SEC-05 |
| `/data/iotdb/autotest/sec_skill/docs/RESULTS_dual_mode_20261116.md` | 双模式结果（普通 + 三权分立均复现） |

源码位置（本地 `D:\IDEA\timechodb_src\v20131\timechodb`）：
- `iotdb-core/node-commons/src/main/java/org/apache/iotdb/commons/conf/CommonConfig.java:3428`（缺陷点）
- `iotdb-core/datanode/src/main/java/org/apache/iotdb/db/utils/DataNodeAuthUtils.java:186-206`（消费侧，`<=0` 即禁用）
- `iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/IoTDBDescriptor.java:1196、2880`（启动/热加载都经 setter）
- `iotdb-core/node-commons/src/assembly/resources/conf/iotdb-system.properties.template:2290-2297`（默认值 0 与注释）
