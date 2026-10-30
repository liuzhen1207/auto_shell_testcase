# OBS-13 专项验证记录：用户级全局锁

- 日期：2026-10-30
- 目的：验证需求 L120「同一用户从任意地址累计 failed_login_attempts_per_user 次失败后，全局锁定该用户」
- 手法：**启动集群前**把 `failed_login_attempts_per_user` 改为 3（默认 1000），重启后用两个不同来源 IP 累计 3 次失败
- 脚本：`tools/probe_obs13_global_lock.sh`
- 收尾确认：2026-10-30 15:08（网络中断恢复后复核，集群 8/8、配置已还原、无残留用户）

## 结果

| 步骤 | 操作 | 结果 |
| --- | --- | --- |
| 1 | 改配置为 3 → 重启集群 | 8/8 Running，配置生效 |
| 2 | 建用户 lockglobal | 成功 |
| 3 | 205 错 2 次、.3 错 1 次（合计 3，单 IP 均 < 5） | 第 3 次返回 801 认证失败（正常） |
| 4 | 205 用正确密码 | **822 Account is blocked** |
| 5 | **全新来源 .4** 用正确密码（该 IP 从未失败过） | **822 Account is blocked** → **全局锁生效** |
| 6 | root 执行 `ALTER USER lockglobal ACCOUNT UNLOCK` | 成功 |
| 7 | .4 再登录 | 登录成功（返回 803 是因为普通用户无 SYSTEM 权限执行 `show cluster`，非认证失败） |
| 8 | 还原阈值 1000 并重启 | ✅ 已确认：8/8 Running（`READY` / `还原后就绪: 8`），所有节点配置文件均为 `failed_login_attempts=5 / failed_login_attempts_per_user=1000`；仅剩 root 用户，测试用户已清理；AUTH-001 / AUTH-017 健康检查 PASS |

## 结论

- 用户级全局锁**按需求生效**，与"用户@IP 精细锁"相互独立（单 IP 未达 5 次仍被全局锁拦截）；
- 阈值修改**必须重启**才生效（SQL 提示 restart required），因此不纳入日常回归；
- 手动解锁对全局锁同样有效（normal 模式 root）。
