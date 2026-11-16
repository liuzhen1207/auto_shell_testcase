# sec_skill —— 强安全级别密码（身份鉴别）需求回归

> 需求来源：`V2.0.7.1-安全模块-身份鉴别-强安全级别密码-需求分析`（V0.2，2025-10-23，EAL4）
> 需求正文抽取：`docs/req_raw.md`（飞书原文，工具 `tools/fetch_req_doc.py`）
> 被测版本：TimechoDB **2.0.13.1 RC2**（`83183d0`），3C3D（**SR=3 / DR=3**）

## 一、需求点 → 用例映射（全覆盖）

| 需求点 | 内容 | 用例 |
| --- | --- | --- |
| a | 长度 12~32（**即使关闭 `enforce_strong_password` 也生效**） | **SEC-01** |
| b | 大写 + 小写组合 | **SEC-02** |
| c | 至少一个数字 | **SEC-02** |
| d | 至少一个特殊字符 | **SEC-02** |
| e | 不能是用户名 | **SEC-03** |
| f | 密码有效期（`password_expiration_days`）+ 过期拒绝登录 + 3 天内提示 + int64 越界不提示 | **SEC-06** |
| g | 历史口令 N 天内不可重用（`password_reuse_interval_days`） | **SEC-05**（窗口内）+ **SEC-06**（窗口外） |
| 配置项 | `enforce_strong_password` 默认 true、热加载、改配置不追溯已有密码 | **SEC-04 / SEC-07** |
| 权限 | 改安全配置需 SECURITY；三权分立下只有 `security_admin` 可改 | **SEC-07** |
| 审计/日志 | 关键操作留痕、错误不泄密、日志不含明文密码 | **SEC-08** |
| 副本 | SR3/DR3 下策略与用户元数据一致；停 1 DN 策略不降级 | **SEC-09** |

| 编号 | 用例脚本 | 覆盖 |
| --- | --- | --- |
| SEC-01 | `cases/password/sec_password_length.sh` | 11/12/32/33、空/1 字符；开关关闭后长度仍生效 |
| SEC-02 | `cases/password/sec_password_complexity.sh` | 缺大写/小写/数字/特殊字符（逐项点名）、同时缺多项、空格、中文、13 个合法特殊字符、非法字符 |
| SEC-03 | `cases/password/sec_password_username.sh` | 密码==用户名被拒（820 文案）、同密码换用户名放行、包含但不等、大小写不同、ALTER 走同一套校验 |
| SEC-04 | `cases/password/sec_enforce_switch.sh` | 开关关闭/开启、长度不可关、不追溯老密码 |
| SEC-05 | `cases/password/sec_password_reuse.sh` | 默认 0、reuse=1 窗口内 A→B→A 拒绝、多条历史、全新密码放行 |
| SEC-06 | `cases/password/sec_password_expire.sh` | 过期拒绝登录+文案、已登录会话、改密后恢复、窗口外可重用、3 天提示、int64 越界（时钟前移实现） |
| SEC-07 | `cases/config/sec_config_privilege.sh` | 三个默认值、热加载（值+行为）、SECURITY 权限、三权分立职责边界、普通用户被拒 |
| SEC-08 | `cases/audit/sec_audit_logs.sh` | 关键操作留痕、错误信息不泄密、日志无明文密码、CN/DN 日志门禁 |
| SEC-09 | `cases/replica/sec_replica_consistency.sh` | 三 DN 策略一致、三 DN 校验一致、元数据指纹一致、逐停 DN、停 DN 期间策略不降级 |

## 二、两种模式

| 模式 | 账号 | 说明 |
| --- | --- | --- |
| `normal`（普通模式） | `root` | root 通管用户/DDL/审计 |
| `sep`（三权分立） | `security_admin`（用户/权限/安全配置）、`sys_admin`（DDL）、`audit_admin`（审计） | `root` 被禁止登录（803）；`enable_separation_of_powers=true` |

模式由 `--mode normal|sep|auto` 指定（`auto` 自动探测：root 登录 803 → sep）。
切换工具：`bash tools/mode_sep.sh on|off|status`。

## 三、用法

```bash
# 自检（不依赖集群）
bash tools/selftest.sh

# 语法/登录/权限类（快档，不涉及重启与时钟）
bash tools/run_all.sh --set quick --mode sep

# 全量（含 SEC-06 时钟前移，需要 2 次集群重启）
bash tools/run_all.sh --set all --mode sep
bash tools/run_all.sh --set all --mode normal

# 单条
bash tools/run_all.sh --set expire --mode sep      # 或 --only SEC-06
```

结果：`results/test_result.csv`（Time/build/mode/caseName/result/elapsed/failCount/warnCount/artifact/message）
每条用例自己的完整输出：`results/<case>_<run_id>.out`；失败自动打包 CN/DN 日志到 `results/artifact_<case>_<mode>_<run_id>/logs/`。

## 四、踩过的坑（写在前面，避免重复踩）

1. **`password_expiration_days>0` 会让"老密码"立刻过期**：root 的密码是部署时改的（>1 天），一旦设成 1，
   root 立即过期 → 连续登录失败 → 账号被锁（822，`failed_login_attempts=5`、`password_lock_time_minutes=10`，
   锁定是**持久化**的，重启不清）。所以本套件：
   - 每条用例开始都 `sec_conf_restore`（enforce=true / expiry=0 / reuse=0）；
   - 时间类用例只用**专用用户**，绝不拿 root 做被测对象。
2. **`show configuration` 的列是 `| key | 生效值 | 默认值 |`**：取值必须取第 3 列（早期取第 2 列拿到的是键名）。
3. **CLI 会把多条语句的 `Msg` 混在一起**：判定"这条 SQL 是否成功"必须只看**最后一条** Msg。
4. **用户名长度下限 4**：探针里用 3 字符用户名会得到 `820: The length of name must be greater than or equal to 4`，
   容易误判成"密码策略没生效"。
5. **三权分立开启后 root 无法登录**（`803: SUPER USER is not allowed to login when separation of admin powers is enabled`），
   关闭只能改配置 + 重启（`tools/mode_sep.sh off`）。
6. **已知噪声**（日志门禁白名单，`conf/env.conf: SEC_LOG_BENIGN`）：
   - `MemoryManager:285 - getOrRegisterMemoryBlock failed: memory block Consensus already exists`（每个 RPC 都打）
   - `ConfigExecution:223 - Failures happened during running ConfigExecution`（本套件**故意**触发 804/820 失败时产生，
     与 TV-LOG-01 记录的是同一条噪声，研发确认随后续 commit 修）

## 五、时间类需求怎么测（不靠真实等待）

`password_expiration_days` / `password_reuse_interval_days` 单位是**天**，无法等：
用 `sec_stop_cluster` → `sec_clock_shift '+3 days'`（六节点一起前移，保持节点间相对时间一致）→ `sec_start_cluster`
→ 跑过期/提示/重用断言 → 再把时钟回退 3 天并重启。整个过程在 **SEC-06** 内完成，且结束时恢复时钟。

> 注意：时钟前移期间**不要**并行跑其它 skill；本套件串行执行。
