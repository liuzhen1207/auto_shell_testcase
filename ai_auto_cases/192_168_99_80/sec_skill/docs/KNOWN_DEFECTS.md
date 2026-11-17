# 安全模块缺陷 / 已知问题台账（sec_skill）

> 维护约定：
> - **缺陷**：已建 PLM 单，按单号跟踪；
> - **已知问题**：研发确认**不修复**（Won't Fix）或属设计约束，测试侧按"基线行为"记录，不判 FAIL，但保留探测（若行为变化会提示复核）。
> - 回归用例统一在 `sec_skill` 内，`bash tools/run_all.sh --set all` 可覆盖。

| # | 类型 | 编号 | 摘要 | 优先级 | 迭代/版本 | 负责人 | 验证 | 回归用例 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 缺陷 | **TDB-1606** | `password_reuse_interval_days` 显式配置为 0（需求「无历史约束」）被内部改写为 1 天；不显式设置（默认无该键）时无此问题 | P3 | V2.0.14.1 / V2.0.13.1 | 江天 | 刘珍 | `SEC-05`（默认/-1/=1 硬门禁；显式 0 仅 WARN） |
| 2 | 缺陷 | **TDB-1607** | 普通模式下无 SECURITY 权限用户执行 `ALTER USER … ACCOUNT UNLOCK` 触发 NPE，返回 305（应 803） | P2 | V2.0.14.1 / V2.0.13.1 | 高宏志 | 刘珍 | `SEC-13` 第 7 步（当前 WARN，修复后转 PASS） |
| 3 | 缺陷（待验证关闭） | **TDB-899** | 三权分立下 `ALTER USER … ACCOUNT UNLOCK` 返回 701 Unsupported author type，账号锁定后无解锁入口（RC2 实测已修复，**按用户决定保持打开，待 V2.0.14.1 验证后再关闭**） | P1 | V2.0.14.1 / V2.0.12.1 | 舒文炜 | 刘珍 | `SEC-13` / 专项 5 项检查（见 `PLM_TDB-1607.md` 第 5 节） |
| 4 | **已知问题（不修复）** | —（研发确认改不了） | `CREATE USER` / `ALTER USER SET PASSWORD` 的**明文口令写入 ConfigNode 共识（Raft）日志** `data/confignode/consensus/*/current/log_inprogress_*`，三副本可读 | P2（原建议） | V2.0.13.1 RC2 `83183d0` 复现 | 研发：改不了 | 刘珍 | `SEC-12`（共识日志明文 → 已知行为 WARN 基线） |

## 已知问题 #4 详情与处置

- 报告：`docs/DEFECT_plaintext_password_raft_log.md`（含字节级证据、源码根因、缓解措施）
- 复现：`create user u '<唯一口令>'` 后 `grep -ra -l -F -- '<口令>' data/` → 命中
  `data/confignode/consensus/47474747-…/current/log_inprogress_<N>`（三节点同偏移 2372187）
- 根因：`AuthorTreePlan.serializeImpl`（`AuthorTreePlan.java:167-172`）明文序列化 `password`/`newPassword`；
  哈希只在应用阶段（`AuthorPlanExecutor.java:396` → `UserManager.createUser(..., true, true)`）
- **为什么不判 FAIL**：研发确认受 Raft 重放语义约束、不修复；测试侧按"已知行为"记录
- **探测保留**：SEC-12 仍每次检查；若某版本**不再命中**明文 → 打 WARN「已知问题已变化，请复核台账」（不静默通过）
- **缓解措施**：见报告第 6.1 节（数据目录权限、卷加密、TDE/配置文件加密、日志段轮转、口令不复用、访问审计、合规披露）

## 维护记录

| 日期 | 变更 |
| --- | --- |
| 2026-11-17 | 建台账：TDB-1606 / TDB-1607 / TDB-899（待验证关闭）/ 明文口令入 Raft 日志（研发确认不修复，转已知问题） |

## 文档修订项（非缺陷，需研发改文档）

| 项 | 文档 | 位置 | 现状 | 应改为 | 依据（实测/对照） |
| --- | --- | --- | --- | --- | --- |
| D1 | 《V2.0.7.1-安全模块-身份鉴别-密码定期更改提示&客户端隐去明文密码-需求分析》（飞书 LgbfdWLmioe91BxWbVpclBWPnxd） | 三、功能定义 → 功能定义 → 配置项，password_stale_warning_days=30 上方注释第 3 行 | # effectiveMode: restart | # effectiveMode: hot_reload | 实测 SET CONFIGURATION 'password_stale_warning_days'='31' → 仅返回 \The statement is executed successfully.\（无 restart 提示）；对照组 \ailed_login_attempts\ 返回 \... restart is required ...\；产品 conf 模板 \iotdb-system.properties.template:2301\ 已写 \# effectiveMode: hot_reload\ |

> 注意：**不要**把《防止口令暴力破解-需求分析》（飞书 FwHWdCDKmoSxJAxr8aWc96XnnYf）里的 3 处 effectiveMode: restart 一起改——
> ailed_login_attempts / ailed_login_attempts_per_user / password_lock_time_minutes 实测确实需要重启才生效（已验证）。
