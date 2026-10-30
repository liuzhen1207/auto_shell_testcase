# 缺陷描述（待确认后登记）：三权分立下 `ALTER USER ... ACCOUNT UNLOCK` 报 `701 Unsupported author type`

> 状态：**未登记**。你说之前验证过这个功能，所以我在 §七 单独列了"可能与你那次验证的差异点"，方便你直接找研发对口径。
> 关联用例：`auth_skill/cases/g3_lock.sh::AUTH-019`（separation 模式下 FAIL）；复现脚本：`auth_skill/tools/probe_obs10_11.sh`

## 一、建议字段

| 字段 | 建议值 |
| --- | --- |
| 标题 | 【V2.0.12.1】【安全模块-身份鉴别】开启三权分立后 `ALTER USER ... ACCOUNT UNLOCK` 返回 `701 Unsupported author type`，账号锁定后无解锁入口 |
| 类型 | 缺陷 |
| 优先级 | **P1**（功能不可用且无替代路径：三权分立下 root 禁止登录、sys_admin 缺 SECURITY，导致被锁账号永远无法解锁） |
| 严重程度 | 严重 |
| 复现概率 | 必现（三权分立模式下 100%） |
| 产品名称 / 企业开源 | TimechoDB / TimechoDB |
| 模型 | 通用 |
| 问题发现版本 | V2.0.12.1（BuildInfo c05111d） |
| 需求来源 | 测试需求 |
| 迭代 / 负责人 / 验证人员 | 待定（你确认后填） |

## 二、环境

| 项目 | 值 |
| --- | --- |
| 版本 | TimechoDB **2.0.12.1**，BuildInfo **c05111d** |
| 集群 | 3 ConfigNode（172.16.2.26/27/28）+ 5 DataNode（172.16.2.2~6），SR=3 / DR=2 |
| 客户端 | 172.16.2.205 `start-cli.sh`（tree / table 方言均试过） |
| 相关配置 | 默认；三权分立通过 `SET CONFIGURATION 'enable_separation_of_powers'='true'` 开启（热生效） |

## 三、复现步骤

```sql
-- 1. root 身份开启三权分立（开启后 root 立即禁止登录）
SET CONFIGURATION 'enable_separation_of_powers'='true';

-- 2. 用 security_admin 建一个普通用户
CREATE USER probe_u 'Probe@123456';

-- 3. 用 security_admin 执行手动解锁
ALTER USER probe_u ACCOUNT UNLOCK;
```

命令行：

```bash
start-cli.sh -h 172.16.2.2 -p 6667 -u security_admin -pw 'TimechoDB@2021' \
  -e "alter user probe_u account unlock"
```

## 四、实际现象

三权分立模式下，同一语句按身份不同全部失败：

| 身份 | 结果 |
| --- | --- |
| `root`（超级用户） | `803: SUPER USER is not allowed to login when separation of admin powers is enabled.`（无法登录，属需求行为） |
| `security_admin`（安全管理员，唯一有 SECURITY 的身份） | **`701: Unsupported author type.`** |
| `sys_admin`（系统管理员） | `803: No permissions for this operation, please add privilege SECURITY` |

对 `security_admin` 的失败点判定：

1. **权限检查已经通过**（否则会像 sys_admin 一样返回 803 缺 SECURITY）；
2. 失败发生在**执行阶段**：语句被解析、进入授权流程后，严格鉴权路径未处理 `ACCOUNT_UNLOCK` 这个 author type，返回语义错误（701 = `SEMANTIC_ERROR`）。

****写法矩阵（security_admin 执行，三权分立开启）**：

| 写法 | 结果 |
| --- | --- |
| `ALTER USER u @ '172.16.2.205' ACCOUNT UNLOCK`（IP 级，TC-01652 写法） | ❌ `701: Unsupported author type.` |
| `ALTER USER u @ '10.0.0.9' ACCOUNT UNLOCK`（任意 IP） | ❌ `701: Unsupported author type.` |
| `ALTER USER u ACCOUNT UNLOCK`（全局锁，TC-01654 写法） | ❌ `701: Unsupported author type.` |
| `sys_admin` 执行任意一种 | ❌ `803`（缺 SECURITY，属三权设计） |

→ 三种写法全部失败，说明问题不在语法/参数，而在三权分立鉴权路径未实现 `ACCOUNT_UNLOCK` 这一 author type。

对照组实验（同一集群、normal 模式）**：

| 执行者 | 结果 |
| --- | --- |
| root | ✅ `Msg: The statement is executed successfully.`（tree / table 方言均成功） |
| **有 SECURITY 权限的普通用户**（`grant security on root.** to user sec_exec`） | ✅ **成功** |

→ 由此排除"非 root 身份执行"这一变量：**701 只在三权分立开启后出现**，属模式特有路径未覆盖 `ACCOUNT_UNLOCK`，而非通用权限问题。

## 五、期望结果

1. 三权分立下 `security_admin` 执行 `ALTER USER u ACCOUNT UNLOCK` 应成功（与 normal 模式一致的解锁语义）；
2. 至少不应返回 `701 Unsupported author type`（这是内部 author type 未覆盖，不是用户输入错误）；
3. 需求依据：
   - 《V2.0.7.1-安全模块-身份鉴别-防止口令暴力破解-需求分析》明确要求提供**手动解锁 UNLOCK 语句**（变更记录 V1.0「新增手动解锁 UNLOCK 语句」、V1.1「修改解锁 SQL 语法」）；
   - 《V2.0.7.1-安全模块-权限管理-三权分立-需求分析》：安全管理员负责权限与安全策略管控；
   - 因此"三权分立下无法解锁"与需求冲突，且**没有任何替代入口**（root 禁登、sys_admin 无 SECURITY）。

## 六、代码线索（供研发参考）

1. `iotdb-core/datanode/src/main/java/org/apache/iotdb/db/auth/ClusterAuthorityFetcher.java:444` `handleAccountUnlock(...)`：
   识别 `ACCOUNT_UNLOCK` 后把**登录地址塞进 roleName**，再转给 CN 的 `operatePermission`；
2. `iotdb-core/confignode/src/main/java/org/apache/iotdb/confignode/persistence/auth/AuthorInfo.java:81`
   与 `AuthorPlanExecutor.java:261` 有 `AccountUnlock` 分支（普通模式的解锁逻辑在这里）；
3. 推测：三权分立启用时走的是**严格鉴权分支**，该分支的 author type 映射/switch 未包含 `ACCOUNT_UNLOCK`，于是落到 "Unsupported author type"；
4. 建议顺带检查：`ConfigManager` / `PermissionManager` 中与三权分立方相关的新分支是否需要补 `ACCOUNT_UNLOCK` 的权限判定（谁能解锁：security_admin？是否需要 SYSTEM？）。

## 七、可能与你那次验证的差异点（建议先和研发对齐）

| 可能差异 | 本次实测 |
| --- | --- |
| **带 host 的解锁语法** `ALTER USER u @ '172.16.2.205' ACCOUNT UNLOCK` | **可用，但 `@` 两边必须有空格**（与 TC-01652 用例写法一致）。写成 `u@'ip'`、`u@"ip"`、`u@ip` 都会 700 解析失败——这是语法书写问题，不是缺陷 |
| 验证时的模式 | 若当时**未开启三权分立**（normal + root），解锁是正常的，本次对照实验也成功——差异只在三权分立 |
| 验证时的版本 | 若是更早的 2.0.x build，可能是**回归**；建议对比 `AccountUnlock` 相关提交 |
| 验证时的锁类型 | 本次未依赖"真的锁住"：即使账号未锁定，三权分立下该语句同样返回 701（说明是语句层面的问题，不是锁状态问题） |

## 八、证据

| 内容 | 位置 |
| --- | --- |
| 用例 | `auth_skill/cases/g3_lock.sh::AUTH-019`（`MODE=separation` 下 FAIL） |
| 复现脚本 | `auth_skill/tools/probe_obs10_11.sh`（含三身份对照 + UNLOCK 变体） |
| 语法探测 | `scripts/probe_unlock_syntax.sh`（normal 模式 5 种写法结果） |
| 日志 | 172.16.2.2 `logs/log_datanode_all.log`（701 仅在客户端返回，DN 日志无对应 ERROR） |
| 测试报告 | `auth_skill/docs/AUTH_TEST_REPORT.md` §11、`coverage_matrix.md` §三 OBS-11 |

## 九、备注

1. 本单只覆盖"三权分立下 UNLOCK 语句报 701"这一条；AUTH-014（密码过期校验 ERROR，已登记 TDB-896）与本单无关；
2. 另一条待确认项 OBS-9：文档称 root 与安全管理员**豁免暴力破解锁定**，实测 root 连续 6 次错误后仍被锁 822——与文档不符，建议一并问研发（若是文档过时请更新文档）。
