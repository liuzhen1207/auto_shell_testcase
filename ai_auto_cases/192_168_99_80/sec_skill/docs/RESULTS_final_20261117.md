# 安全模块用例总览与双模式结果（截至 2026-11-17）

## 一、规模

- **16 条用例**（SEC-01 ~ SEC-16），覆盖 6 份需求/设计文档的全部需求点。
- **关闭三权分立（normal）16/16 PASS；开启三权分立（sep）16/16 PASS**（合计 32/32）。
- 每条用例收尾统一执行：sync lag 归零 → CN/DN 日志门禁（当天、用例开始后、白名单过滤）→ 失败自动打包日志。

## 二、分组与覆盖

| 组 | 用例 | 覆盖 |
| --- | --- | --- |
| 密码策略（强密码） | SEC-01 长度 12~32（关闭 enforce 仍生效）<br>SEC-02 复杂度四要素 + 特殊字符集<br>SEC-03 密码≠用户名<br>SEC-04 enforce 开关语义<br>SEC-05 历史口令重用（0/-1/1）<br>SEC-06 有效期 + 复用窗口外（单 DN 时钟偏移） | 需求 a~g |
| 密码定期提示 / 客户端 | SEC-10 `password_stale_warning_days`（提示文案、重复触发、<=0 禁用、热加载）<br>SEC-11 `-pw` 隐式输入（提示、保留 `-pw value`、错误 801） | 密码定期更改提示 & 隐式密码 |
| 配置与权限 | SEC-07 默认值/热加载/SECURITY 权限/三权分立职责边界<br>SEC-15 防爆破参数边界（-1/0/负数/restart 语义）+ 双模式角色矩阵 | 配置项与越权 |
| 审计与日志 | SEC-08 关键操作留痕、错误不泄密、日志无明文密码<br>SEC-16 锁定/解锁 INFO、非法配置留痕、无明文密码 | 审计/运营日志 |
| 副本一致性 | SEC-09 SR3/DR3：三 DN 策略/校验/元数据指纹一致 | 副本 |
| 身份鉴别基础 | SEC-12 root 不可删、CRUD、大小写敏感、804/801、profile 哈希存储 | identityAuthentication-001/002 |
| 防爆破锁定 | SEC-13 阈值边界（第 N 次 801、N+1 次 822）、锁定期拒绝、手动解锁、计数清零、非授权解锁<br>SEC-14 本机管理员豁免、自动解锁、DROP USER 清锁 | 防止口令暴力破解 |

## 三、双模式结果（每个 (用例,模式) 的最新一次）

| 用例 | normal | sep |
| --- | --- | --- |
| SEC-01 | PASS 109s | PASS 22s |
| SEC-02 | PASS 312s | PASS 41s |
| SEC-03 | PASS 157s | PASS 30s |
| SEC-04 | PASS 163s | PASS 31s |
| SEC-05 | PASS 31s | PASS 138s |
| SEC-06 | PASS 118s | PASS 26s |
| SEC-07 | PASS 150s | PASS 31s |
| SEC-08 | PASS 171s | PASS 41s |
| SEC-09 | PASS 120s | PASS 86s |
| SEC-10 | PASS 38s | PASS 29s |
| SEC-11 | PASS 80s | PASS 75s |
| SEC-12 | PASS 23s | PASS 23s |
| SEC-13 | PASS 30s | PASS 21s |
| SEC-14 | PASS 30s | PASS 25s |
| SEC-15 | PASS 23s | PASS 25s |
| SEC-16 | PASS 26s | PASS 20s |

> 说明：耗时差异主要来自"是否包含时钟偏移/重启/停 DN"等操作；同一用例在不同轮次的耗时可能不同。
> 历史记录中曾有 3 条"陈旧结果"（SEC-01/02 的 sep 轮被时钟实验污染的日志门禁误判、SEC-05 的 normal 轮为两级判定改造前），
> 已于 2026-11-17 17:13–17:21 补跑干净：SEC-05 normal PASS、SEC-01 sep PASS、SEC-02 sep PASS。

## 四、缺陷 / 已知问题（详见 `docs/KNOWN_DEFECTS.md`）

| 编号 | 摘要 | 状态 |
| --- | --- | --- |
| TDB-1606 | `password_reuse_interval_days` 显式 0 被改写为 1 天 | 已提单，P3，V2.0.14.1 |
| TDB-1607 | 普通模式无权限用户 `ACCOUNT UNLOCK` → NPE/305（应 803） | 已提单，P2，V2.0.14.1 |
| TDB-1610 | 三权分立下 security_admin 无法修改锁定配置（803 缺 SYSTEM） | 已提单，P2，V2.0.13.1；研发 MR 7532 |
| TDB-899 | 三权分立下 UNLOCK 返回 701（无解锁入口） | 保持打开，待 V2.0.14.1 验证后关闭（RC2 实测已修复） |
| 已知问题 #4 | 明文口令写入 ConfigNode 共识日志 | 研发确认不修复；SEC-12 记 WARN 基线 |

## 五、复跑方式

```bash
cd /data/iotdb/autotest/sec_skill
bash tools/selftest.sh                       # ok=76
bash tools/run_all.sh --set all --mode normal
bash tools/run_all.sh --set all --mode sep
# 单组：--set password|auth|config|audit|replica|stale|cli|identity|lock|exempt|lockparam|authlog
```
