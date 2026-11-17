# 配置语义对照表（原值 → 实际生效语义）

> **判读原则（2026-11-17 与用户确认）**：
> `show configuration` / 配置文件里的是**原值**；实际行为按本表解释。
> **原值与生效值不一致不算缺陷**，只要本表（文档/共识）说清楚。
> 回归时依据本表判读，不把"show 显示 0/-5"当问题。

## 一、身份鉴别 / 防爆破

| 配置项 | 原值 | 实际生效语义 | 代码位置 | 日志 |
| --- | --- | --- | --- | --- |
| `failed_login_attempts` | `≤ 0` | **完全禁用** IP 级锁定（内部 `-1`） | `LoginLockManager.java:78-83` | `INFO IP-level login attempts disabled (set to {})` |
| | `≥ 1` | IP 级阈值 = 原值 | 同上 | — |
| `failed_login_attempts_per_user` | `≤ 0` | **禁用**用户级锁定（内部 `-1`）；但若 IP 级 `>1`，**自动启用为 1000** | `LoginLockManager.java:86-100` | `INFO User-level login attempts disabled` / `WARN User-level attempts auto-enabled with default 1000 because IP-level is enabled` |
| | `≥ 1` | 用户级阈值 = 原值 | 同上 | — |
| `password_lock_time_minutes` | `< 1` | **回退为 10 分钟** | `LoginLockManager.java:102-109` | `WARN Invalid lock time value ({}), reset to default (10 minutes)` |
| | `≥ 1` | 锁定时长 = 原值 | 同上 | — |
| `password_stale_warning_days` | `≤ 0` | 关闭"密码陈旧提示" | `SessionManager` / `CommonConfig` | — |
| | `≥ 1` | 超过天数登录时提示 | 同上 | — |
| `password_expiration_days` | `≤ 0` | 不过期 | `DataNodeAuthUtils` | — |
| | `≥ 1` | 超过天数拒绝登录并提示 `ALTER USER` | 同上 | — |
| `password_reuse_interval_days` | `-1`（或 conf 中无该键） | **不限制**历史口令重用 | `DataNodeAuthUtils.verifyPasswordReuse` | — |
| | `0` | **被 setter 改写为 1 天**（`CommonConfig.setPasswordReuseIntervalDays`，见 TDB-1606） | `CommonConfig.java:3428` | — |
| | `≥ 1` | N 天内禁止重用 | `DataNodeAuthUtils` | 拒绝时 `701 The password has been used recently...` |
| `enforce_strong_password` | `true` / `false` | 复杂度(大写/小写/数字/特殊字符/≠用户名)是否校验；**长度 12~32 始终校验** | `AuthUtils.validatePassword` | `820 ...` |
| `enable_separation_of_powers` | `true` | root 禁止登录（803），由 `security_admin`/`sys_admin`/`audit_admin` 分权 | `DataNode.java:147-157` | — |

## 二、由本表演绎出的两条判读规则

1. **`show configuration` 显示原值**（如 `lock_time=0`、`failed_login_attempts=-5`）**不是缺陷**；
   只要本表明确"生效语义"，就按本表判读。
2. 若**本表与需求文档冲突**（例如需求笼统写"不合理配置转默认值"，而模板定义 `≤0=禁用`），
   处理方式是**改文档/本表**，而不是改实现（D1/D2 两个文档修订项即此类）。

## 三、典型示例（实测）

| 原值 | `show configuration` | 实际行为 | 依据 |
| --- | --- | --- | --- |
| `failed_login_attempts=-5` | `-5` | 不限制 IP 级失败次数（禁用） | `INFO IP-level login attempts disabled (set to -5)` |
| `password_lock_time_minutes=0` | `0` | 锁定时长 **10 分钟** | `WARN Invalid lock time value (0), reset to default (10 minutes)` |
| `password_reuse_interval_days=0` | `0` | 实际 **1 天**内禁止重用旧口令 | TDB-1606 |
| conf 无 `password_reuse_interval_days` | 不列出 | 不限制 | `CommonConfig` 字段默认 `-1` |

> 备注：`password_reuse_interval_days=0` 之所以仍作为缺陷（TDB-1606）跟踪，是因为**需求原文明确写"0 = 无历史约束"**，
> 属"文档承诺的行为"与实现不符；与本表的"原值/生效值展示"原则无关。
