# 追加用例结果（SEC-10 ~ SEC-16，两种模式）

被测：TimechoDB **2.0.13.1 RC2**（`83183d0`），3C3D（SR=3 / DR=3）
需求来源（6 份飞书文档，正文已存 `docs/req_src/`）：

| 文档 | 内容 | 对应用例 |
| --- | --- | --- |
| `LgbfdWLmioe91BxWbVpclBWPnxd` | 密码定期更改提示 & 客户端隐去明文密码-需求分析 | SEC-10 / SEC-11 |
| `KJUSddMeQoEBiNxRtjXc1FQ6nde` | 同上-技术设计（passwordStaleWarningDays 判定逻辑） | SEC-10 |
| `NK8VdM8Y8o6sw0xD2mOcjbwvn4e` | 身份鉴别功能-需求分析 V1.0.0.1 | SEC-12 |
| `FxwrdKMnsoYuNNxyrfwcj3lznie` | 身份鉴别功能-技术设计（用户/密码管理、哈希、协议接入） | SEC-12 / SEC-16 |
| `FwHWdCDKmoSxJAxr8aWc96XnnYf` | 防止口令暴力破解-需求分析 | SEC-13 / SEC-14 / SEC-15 |
| `NKm0dsyiDoMJ5RxZVlIc3AounMb` | 防止口令暴力破解-技术设计（LoginLockManager / UNLOCK 语法） | SEC-13 / SEC-14 / SEC-15 / SEC-16 |

## 一、新增用例与需求点映射

| 用例 | 需求点 | 覆盖内容 |
| --- | --- | --- |
| **SEC-10** | 密码定期提醒 | `password_stale_warning_days` 默认 30；超期登录提示 `Your password has not been changed for 30 days. For security best practices, please consider updating your password.`；**不修改则重复触发**；改密后不再提示；`<=0` 禁用；参数语义（实测热加载，见观察 3） |
| **SEC-11** | 客户端隐去明文密码 | `-pw` 不带值 → `please input your password:` 并从 stdin 读取；保留 `-pw <password>`；交互式错误密码 → 801；PTY 回显（受 `script` 自身回显干扰，仅记录） |
| **SEC-12** | identityAuthentication-001/002 | `root` 存在且不可删除（803 `Cannot drop admin user or yourself`）；CREATE/ALTER/LIST/DROP 语义；新用户初始无权限；用户名/密码大小写敏感；用户不存在 804、密码错误 801；日志无明文密码、**共识日志中是否明文（观察 2）** |
| **SEC-13** | 防爆破（user@IP） | 阈值内 801；**第 N+1 次 822** + 文案 `Account is blocked due to consecutive failed logins`；锁定期正确密码仍 822；手动解锁 `ALTER USER u ACCOUNT UNLOCK` 后可登录；`ALTER USER u @ 'ip' ACCOUNT UNLOCK` 语法；登录成功清零计数；普通用户执行解锁的权限（观察 1） |
| **SEC-14** | 豁免/自动解锁/DROP 清锁 | 本机登录的 root/安全管理员不因密码错误被锁（`isFromLocalhost` 匹配本机网卡地址）；锁定时长到期自动解锁；DROP USER 清理锁（同名重建后立即可登录）；"锁名单不持久化"按文档记录 |
| **SEC-15** | 参数边界与权限 | 三参数存在性 + 模板默认值；`SET CONFIGURATION` 的 restart 语义；`per_user=-1/0/1000`；非法值（负数）处理（观察 5）；**权限边界**（观察 4） |
| **SEC-16** | 审计与日志 | 锁定/解锁事件 INFO 留痕；认证失败响应不泄露密码/哈希、不暴露用户存在性；异常行为 WARN（构造受限，记录规格）；非法配置回退留痕；日志无明文密码；CN/DN 门禁 |

## 二、两种模式实测结果

| 用例 | 普通模式（root） | 三权分立（security_admin / sys_admin / audit_admin） |
| --- | --- | --- |
| SEC-10 | **PASS** 29s（15 断言，2 WARN） | **PASS** 29s（15 断言，2 WARN） |
| SEC-11 | **PASS** 80s（11 断言，1 WARN） | **PASS** 75s（11 断言，1 WARN） |
| SEC-12 | **PASS** 34s（22 断言，2 WARN） | **PASS** 23s（22 断言，2 WARN） |
| SEC-13 | **PASS** 30s（13 断言，1 WARN） | **PASS** 21s（14 断言） |
| SEC-14 | **PASS** 30s（10 断言，2 WARN） | **PASS** 25s（10 断言，2 WARN） |
| SEC-15 | **PASS** 34s（14 断言，1 WARN） | **PASS** 20s（13 断言，2 WARN） |
| SEC-16 | **PASS** 26s（8 断言，2 WARN） | **PASS** 20s（8 断言，2 WARN） |

**两种模式均 7/7 PASS**；WARN 全部是"记录下来的观察/待确认项"，不判失败。

## 三、CN/DN 日志门禁

- 判据：**只统计当天**、且时间 ≥ 用例开始的 `ERROR|WARN` 行（避免日志轮转、时钟实验期的"未来日期"旧行混入）
- 白名单：`MemoryManager:285`、`ConfigExecution:223`（本套件故意触发 804/820/822 产生）、`GrpcLogAppender`、
  `Reporting ConfigNode shutdown failed`、`Failed appendEntr`、`APPEND_ENTRIES onError`、`Cannot find IOTDB_HOME`、
  `License will expire at`（时钟前移用例的必然副作用）、`Status code: INTERNAL_SERVER_ERROR`（观察 1 触发）
- 实测：7 条用例在两种模式下**门禁全部 PASS**

## 四、待研发确认的观察/缺陷候选（**未提单**）

1. **非授权 UNLOCK 返回 305 内部错误**：普通用户执行 `ALTER USER <u> ACCOUNT UNLOCK` 返回
   `305: [INTERNAL_SERVER_ERROR(305)] Exception occurred: "..." Cannot read the array length because "arr..."`，
   期望 **803 权限错误**；同时在 DN 打 ERROR 日志（`ErrorHandlingUtils:75 - Status code: INTERNAL_SERVER_ERROR`）。
2. **明文密码写入 ConfigNode 共识（Raft）日志**：`create user` 后可在
   `data/confignode/consensus/.../current/log_0-*` 与 `log_inprogress_*` 中 `grep` 到明文密码
   （需求：密码应以哈希方式存储、不得明文存储）。DN 日志与 conf 中未发现。
3. **`password_stale_warning_days` 生效方式与文档不一致**：文档 `effectiveMode: restart`，实测 `SET CONFIGURATION`
   即时生效（热加载，且 `=0` 立即禁用提示）。
4. **三权分立下"安全管理员"无法修改锁定配置**：`security_admin` 设置 `failed_login_attempts` 等返回
   `803: No permissions for this operation, please add privilege SYSTEM`（需 `sys_admin`）；
   需求原文为"新增配置只可由 root 或安全管理员修改"。
5. **非法配置无 ERROR 日志留痕**：`failed_login_attempts=-5` 被接受且未在 DN 日志看到
   `Invalid config / fallback to default`（需求：不合理配置转默认值并写错误日志）。

另外两条**符合预期、已转硬断言**的行为：
- 锁定语义为"第 N 次失败把计数打到阈值（仍返回 801），第 N+1 次才返回 822"。
- 树模型新用户查询 `root.**` 返回空集而非 803（读写权限表现差异，属既有设计）。

## 五、复现方式

```bash
cd /data/iotdb/autotest/sec_skill
bash tools/run_all.sh --set auth --mode normal      # SEC-11..16
bash tools/run_all.sh --only SEC-10 --mode normal   # 密码定期提示（含单 DN 时钟前移）
bash tools/run_all.sh --set auth --mode sep         # 三权分立再跑一遍
```

前置：锁定阈值类用例需要 `failed_login_attempts=3 / failed_login_attempts_per_user=1000 / password_lock_time_minutes=1`
（`tools/prepare_lock.sh` 写入并重启；这些键是 restart-only）。
