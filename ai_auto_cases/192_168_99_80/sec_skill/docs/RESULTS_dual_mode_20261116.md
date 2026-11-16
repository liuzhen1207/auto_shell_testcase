# sec_skill 强安全级别密码回归 —— 双模式结果（2026-11-16）

被测：TimechoDB **2.0.13.1 RC2**（`83183d0`），3C3D（**SR=3 / DR=3**），`.80` 驱动
需求源：`docs/req_raw.md`（飞书《V2.0.7.1-安全模块-身份鉴别-强安全级别密码-需求分析》V0.2，EAL4）

## 一、结果总表（9 条 × 2 模式）

| 用例 | 需求点 | 普通模式（normal，root） | 三权分立（sep） |
| --- | --- | --- | --- |
| SEC-01 密码长度 | a | **PASS** 109s（15 断言） | **PASS**（12:32 轮 16 断言；15:45 轮因集群启停噪声误判 4 条，白名单已补） |
| SEC-02 复杂度 | b/c/d | **PASS** 312s（26 断言） | **PASS** 41s（26 断言） |
| SEC-03 密码≠用户名 | e | **PASS** 157s（13 断言） | **PASS** 30s（13 断言） |
| SEC-04 强密码开关 | a + 配置 | **PASS** 163s（14 断言） | **PASS** 31s（14 断言） |
| **SEC-05 历史口令** | g | **FAIL** 150s（fail=2） | **FAIL** 28s（fail=2） |
| SEC-06 有效期 | f + g 正向 | **PASS** 118s（15 断言） | **PASS** 26s（15 断言） |
| SEC-07 配置/权限 | 配置/SECURITY/三权 | **PASS** 150s（13 断言） | **PASS** 31s（15 断言） |
| SEC-08 审计与日志 | 审计/日志 | **PASS** 171s（17 断言） | **PASS** 41s（17 断言） |
| SEC-09 SR3/DR3 | 副本一致 | **PASS** 120s（18 断言） | **PASS** 86s（18 断言） |

**两种模式结论一致：8 PASS / 1 FAIL（SEC-05）**，且失败点在两种模式下表现完全相同。

## 二、⚠️ 唯一产品偏差：SEC-05（两模式一致复现）

```
password_reuse_interval_days = 0     ← show configuration 回显 0（普通/三权分立都一样）
A→B 改密成功
B→A（立即）→ 701: The password has been used recently, and it cannot be reused before Tue Nov 17 15:24:41 CST
把配置改回 0 后再试 B→A → 仍 701 拒绝
```
- 需求原文：`password_reuse_interval_days=0` 表示**无历史密码约束**
- 实测：仍按 **1 天**窗口拒绝，且改回 0 后**不恢复**
- 两种模式（root / security_admin 驱动）表现一致 ⇒ 与三权分立无关
- 初步判断：该配置**未热加载到 DataNode**（DataNode 侧沿用旧值 1），或默认值处理与文档不一致
- 建议研发确认：`CommonDescriptor.passwordReuseIntervalDays` 的 hot-reload 路径、以及 DN 侧 `verifyPasswordReuse` 读取的配置源

## 三、其它观察（非缺陷判定）

1. **过期判定依赖 DN 本地时钟**（SEC-06）：只把 `.77` 时钟前移 3 天后，同一用户在 `.77` 被判过期、在 `.78`（时钟正确）仍可登录。
   节点间时钟偏差会造成登录结论不一致 —— 部署时应保证 NTP 或时钟同步。
2. **三权分立开启后无法用 SQL 关闭**：`security_admin` 缺 SYSTEM、`sys_admin` 返回 `803: No permission to turn off the separation of powers mode`、`root` 被禁登录。
   关闭只能写 `enable_separation_of_powers=false` + 重启；本环境曾出现"写回 false 并重启后仍生效"的现象（`SET CONFIGURATION` 设置的运行时状态优先），最终靠**清空 `data/` 后重建**恢复普通模式。

## 四、日志门禁（每条用例收尾自动执行）

- 判据：用例开始时间之后新增的 `ERROR|WARN`（带时间戳过滤，避免日志轮转/重启把旧行算进来）
- 白名单（`conf/env.conf: SEC_LOG_BENIGN`）：
  - `MemoryManager:285 - getOrRegisterMemoryBlock failed: memory block Consensus already exists`
  - `ConfigExecution:223 - Failures happened during running ConfigExecution`（**本条用例故意触发 804/820**，与 treeview TV-LOG-01 是同一条噪声）
  - 集群启停噪声：`Reporting ConfigNode shutdown failed`、`Failed appendEntr`、`APPEND_ENTRIES onError`、`Cannot find IOTDB_HOME`、Ratis/gRPC/License 等
- 失败自动打包三节点 CN/DN 日志到 `results/artifact_<case>_<mode>_<run_id>/logs/`

## 五、复现方式

```bash
cd /data/iotdb/autotest/sec_skill
bash tools/selftest.sh                      # ok=61 failed=0
bash tools/run_all.sh --set all --mode normal   # 普通模式（root）
bash tools/mode_sep.sh status               # 查看模式
# 三权分立：root 热开（未开启时）
bash tools/mode_sep.sh on
bash tools/run_all.sh --set all --mode sep
```

模式切换说明：
- `on`：`SET CONFIGURATION 'enable_separation_of_powers'='true'`（root，热生效）
- `off`：写 conf `false` + 重启；若仍生效，需清 `data/` 重建（见 `tools/rebuild_normal.sh`）

## 六、用例清单

| 编号 | 脚本 |
| --- | --- |
| SEC-01 | `cases/password/sec_password_length.sh` |
| SEC-02 | `cases/password/sec_password_complexity.sh` |
| SEC-03 | `cases/password/sec_password_username.sh` |
| SEC-04 | `cases/password/sec_enforce_switch.sh` |
| SEC-05 | `cases/password/sec_password_reuse.sh` |
| SEC-06 | `cases/password/sec_password_expire.sh` |
| SEC-07 | `cases/config/sec_config_privilege.sh` |
| SEC-08 | `cases/audit/sec_audit_logs.sh` |
| SEC-09 | `cases/replica/sec_replica_consistency.sh` |
