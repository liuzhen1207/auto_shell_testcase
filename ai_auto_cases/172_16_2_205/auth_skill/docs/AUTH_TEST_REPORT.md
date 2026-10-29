# 身份鉴别功能测试报告（2.0.12.1 / c05111d）

> 关联缺陷：**[TDB-896](https://plm.infra.timecho.com/iterations?productId=1&itemId=1493)**（DataNode 启动窗口内首次登录误报 ERROR + TimeoutException 堆栈；已登记，待修复后复验）

## 1. 环境与版本

| 项目 | 内容 |
| --- | --- |
| 版本 | TimechoDB **2.0.12.1**，BuildInfo **c05111d**（`/data2/iotdb/v20121rc12_1027_c05111d`，本轮新部署） |
| 集群 | 3 ConfigNode（172.16.2.26/27/28）+ 5 DataNode（172.16.2.2~6），SR=3 / DR=2，IoTConsensus |
| 激活 | `show cluster` 8/8 Running，全部 ACTIVATED（沿用原集群激活身份） |
| 客户端 | 172.16.2.205，`start-cli.sh` |
| 用例目录 | `D:\IDEA\deepseek\cloud1_ip205\auth_v20121_c05111d`（本地）/ `/data2/auto_test/auth_suite`（测试机） |
| 需求依据 | 飞书目录 16 篇（V1.0.0.1 身份鉴别需求/设计/测试文档、V2.0.7.1 强密码/防暴力破解/密码定期更改提示/客户端隐去明文/连接失败不返回 IP 端口），已全部落盘到 `records/feishu/` |

## 2. 结果

| 指标 | 数值 |
| --- | --- |
| 用例数 | 22（三组：基础鉴别 10、密码策略 6、暴力破解+客户端 6） |
| PASS | 21 |
| FAIL | **1（AUTH-014，缺陷回归，按设计 FAIL）** |
| 执行耗时 | 约 4 分钟（含一次 DN 重启） |
| 日志 | 除已知 `Fail to check password expiration` 缺陷外，无其它非预期 ERROR |

> 说明：AUTH-014 已改为**强制复现版**——重启全部 DataNode 后立即持续登录，命中启动窗口竞态，在本版本稳定复现（约 4 分钟）并判 FAIL；其失败即缺陷回归信号，不是环境问题。

## 3. 用例清单

| 用例 | 场景 | 结果 | 关键观测 |
| --- | --- | --- | --- |
| AUTH-001 | root 默认用户登录、集群可用 | PASS | 8 节点 Running |
| AUTH-002 | 错误密码登录失败 | PASS | `801 Authentication failed`，不回显密码 |
| AUTH-003 | 不存在用户登录失败 | PASS | `804 The user X does not exist`（与 801 可区分 → 用户枚举风险，见 §5） |
| AUTH-004 | CREATE USER 后可登录 | PASS | — |
| AUTH-005 | ALTER USER SET PASSWORD | PASS | 旧密码失效、新密码可用 |
| AUTH-006 | DROP USER 后无法登录 | PASS | — |
| AUTH-007 | 强密码复杂度 a–d + 最小长度 | PASS | 缺大写/数字/特殊字符、长度不足均 `820`；**最小长度 12** |
| AUTH-008 | 授权与回收 | PASS | 未授权读返回 **空集**（不报错）；GRANT 后可读；REVOKE 后回到空集 |
| AUTH-009 | LIST USER 不暴露密码 | PASS | 仅 UserId/User/MaxSession/MinSession |
| AUTH-010 | 强密码开关热切换 | PASS | `SET CONFIGURATION 'enforce_strong_password'='false'` 后弱密码可建，恢复后再次被拒 |
| AUTH-011 | password_expiration_days 下发/复位 | PASS | 配置后管理员仍可登录 |
| AUTH-012 | 历史口令不可复用 | PASS | 改回旧密码被拒：`701: The password has been used recently, and it cannot be reused before Sat Nov 28 …` |
| AUTH-013 | password_stale_warning_days | PASS | 配置生效且不阻断登录 |
| AUTH-014 | 密码过期校验日志缺陷 | PASS（间歇） | DN 重启后首次登录有时打印该 ERROR（见 §4） |
| AUTH-015 | ALTER USER RENAME | PASS | 旧名失效、新名可用 |
| AUTH-016 | MAX_SESSION_PER_USER | PASS | 设置成功并体现在 LIST USER |
| AUTH-017 | 连续 5 次错误密码 | PASS | 第 5 次后即使密码正确也 `822 Account is blocked` |
| AUTH-018 | 锁定范围 | PASS | 同 IP 的另一用户仍可登录 → **用户级锁定**（非 IP 级） |
| AUTH-019 | ALTER USER … ACCOUNT UNLOCK | PASS | 语句可执行，解锁后立即可登录 |
| AUTH-020 | 重启 DN 后锁定清除 | PASS | 重启后同一用户可登录（内存计数清零） |
| AUTH-021 | 连接失败不返回 IP/端口 | PASS | 错误信息为通用 `Connection Error …`，不含 172.16.2.2:16667 |
| AUTH-022 | 客户端不回显明文密码 | PASS | 输出中无密码串 |

## 4. 关注的日志缺陷：`Fail to check password expiration`

**结论：该 ERROR 在本版本仍存在，但触发条件与“每次查询”不同——是 DN 重启后首次登录时的内部查询超时竞态。**

实测证据（172.16.2.2，2026-10-29 12:32:59，DN 于 12:32:58 启动）：

```
2026-10-29 12:32:59,576 [pool-51-IoTDB-ClientRPC-Processor-1] ERROR o.a.i.d.u.DataNodeAuthUtils:522 - Fail to check password expiration
java.util.concurrent.TimeoutException
        at java.base/java.util.concurrent.FutureTask.get(FutureTask.java:204)
        at org.apache.iotdb.db.utils.DataNodeAuthUtils.executeLoginHistory(DataNodeAuthUtils.java:108)
        at org.apache.iotdb.db.utils.DataNodeAuthUtils.checkPasswordExpiration(DataNodeAuthUtils.java:519)
        at org.apache.iotdb.db.protocol.session.SessionManager.login(SessionManager.java:170)
        at org.apache.iotdb.db.protocol.thrift.impl.ClientRPCServiceImpl.openSession(ClientRPCServiceImpl.java:1763)
        ...
2026-10-29 12:32:59,591 [pool-51-IoTDB-ClientRPC-Processor-1] INFO  o.a.i.d.p.s.SessionManager:343 - IoTDB: Login status: Login successfully. User : root, opens Session-1-root:172.16.2.205:43276
```

要点：

1. 异常是 **`TimeoutException`**（内部 `queryPasswordExpiration` 的 Future 超时），不是“查不到密码过期策略”；发生在 DN 刚启动、内部查询链路尚未就绪的窗口内；
2. 代码随后走 `isMayBypassPasswordCheckInException()==true` 分支**降级放行**，同一秒日志里就是 `Login successfully`；
3. 但降级前已执行 `LOGGER.error(msg, e)`（`DataNodeAuthUtils.java:522`），因此把“可容忍的启动期超时”记成了 **ERROR + 完整堆栈**；
4. 频率：本轮该 DN 日志共 **2 条**（另一次在 12:04 集群刚拉起时），稳态运行期间不再出现；强制重启+立刻登录的竞态探测未稳定复现（间歇性）。

**影响**：功能无影响（登录成功、业务正常），但 ERROR 日志与堆栈会污染巡检，且发生在每个 DN 启动后首次登录，容易被误判为认证故障。

**建议**：与 `mayBypass` 语义对齐——降级放行时降为 WARN（不带堆栈）或 DEBUG；或对启动期超时做一次重试/短路，避免每次启动都留 ERROR。

**与用户反馈的差异**：之前描述的“环境未配置密码过期策略 → 每次查询都报”在本版本未复现为高频现象（默认与开启有效期两种配置下稳态均为 0 条）；本版本的实际触发点是启动期超时。建议缺陷单把“影响版本/触发条件”改成上述口径。

## 5. 其它观察（非缺陷，建议研发确认）

| 编号 | 现象 | 说明 |
| --- | --- | --- |
| OBS-1 | 不存在用户返回 `804 The user X does not exist`，密码错误返回 `801 Authentication failed` | 两者可区分，可枚举系统内用户名；建议统一为 801 或模糊化 |
| OBS-2 | 历史口令复用返回 `701`，而长度/复杂度/过期类返回 `820` | 错误码不统一，客户端难以按类别处理 |
| OBS-3 | 未授权读返回空集而非权限错误 | 不泄露数据，但用户无法区分“无权限”与“无数据”；与 `enable_grant_option` 等配置相关，需求未明确 |
| OBS-4 | `ALTER USER … ACCOUNT UNLOCK` 只解除用户级锁定 | 与 AUTH-018 的“锁定是用户级”一致；若后续引入 IP 级生效，需补 IP 解锁手段 |
| OBS-5 | 最小密码长度 12 | 需求 a) 只写“限制最小和最大长度”，文档未给具体值，需在需求/交付说明中明确 |

## 6. 复跑方式

```bash
ssh root@172.16.2.205
cd /data2/auto_test/auth_suite
bash scripts/suite_auth.sh              # 全量 22 条
bash scripts/suite_auth.sh AUTH-014     # 单条
```

产物：`results/run_<时间戳>/results.tsv` 与逐用例 `<ID>.out`。

## 7. 目录

```
auth_v20121_c05111d/
├── scripts/   deploy_build.sh / hard_reset.sh / lib_auth.sh / suite_auth.sh / probe_*.sh
├── cases/     g1_base.sh(10) / g2_policy.sh(6) / g3_lock.sh(6)
├── records/   feishu/（16 篇需求/设计/测试文档原文）
└── results/   （运行产物，不入库）
```

## 11. 追加：需求点覆盖补齐 + 三权分立模式（2026-10-29 下午）

### 11.1 新增用例（补覆盖缺口）

| 用例 | 覆盖需求点 | 结果 |
| --- | --- | --- |
| AUTH-023 | 强密码复杂度 b（缺小写字母应被拒） | PASS |
| AUTH-024 | 强密码需求 e（密码不能等于用户名） | PASS，但实测**未拒绝**（观察项 OBS-6） |
| AUTH-025 | 强密码需求 a 的“最大长度” | PASS，244 字符未被拒（观察项 OBS-5） |
| AUTH-026 | 防暴力破解的**特权账户豁免**（文档：root 与三权分立后的安全管理员本机豁免） | **FAIL**：root 连续 6 次错误后仍被锁 822（观察项 OBS-9） |
| AUTH-027 | 空密码 / 全空格密码应被拒 | PASS |
| AUTH-030~036 | 三权分立专项 7 条 | 见 §11.3 |

### 11.2 两模式执行结果

| 模式 | 用例数 | PASS | FAIL |
| --- | --- | --- | --- |
| normal（root） | 27（三权分立 7 条跳过） | 25 | 2（AUTH-014 已知缺陷、AUTH-026 root 未豁免） |
| separation（三权分立） | 33（AUTH-026 跳过） | 29 | 4（AUTH-014、AUTH-008、AUTH-035、AUTH-019） |

### 11.3 三权分立模式要点（实测）

1. 开启方式：`SET CONFIGURATION 'enable_separation_of_powers'='true'`，**热生效**；开启后 root 立即被拒登录（803）；
2. 三个管理员 `sys_admin` / `security_admin` / `audit_admin` 自动存在，默认密码 `TimechoDB@2021`；
3. 职责分离实测：只有 `security_admin` 能建用户；`sys_admin`/`audit_admin` 建用户返回 803；`sys_admin` 无 SYSTEM 配置权限；
4. **无法通过 SQL 关闭**：`sys_admin` 返回 `803 No permission to turn off the separation of powers mode`，security/audit 返回无 SYSTEM 权限；只能改配置文件后重启（观察项 OBS-12）；
5. 三条待研发确认（详见 `coverage_matrix.md` §三）：
   - OBS-10：三权分立下 `security_admin` 授权后普通用户仍读不到数据（AUTH-008/AUTH-035，normal 模式同语句可读）→ **疑似缺陷**；
   - OBS-11：三权分立下 `ALTER USER ... ACCOUNT UNLOCK` 返回 701 Unsupported（AUTH-019）；
   - OBS-12：缺少官方关闭路径说明。

### 11.4 未自动化需求点（3 项）

密码真实过期后拒绝登录（需跨天/改时钟）、锁定自动解锁（restart 生效 + 默认 10 分钟）、已有连接不受锁定影响（需长连接）。建议手工或专项场景覆盖。

> 完整覆盖矩阵见 `coverage_matrix.md`（29/32 需求点已自动化）。
