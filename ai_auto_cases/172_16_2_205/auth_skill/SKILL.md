# auth_skill —— 身份鉴别（认证）回归

被测特性：TimechoDB 安全模块「身份鉴别」——用户名/密码管理、强安全级别密码、密码有效期与定期更改提示、防止口令暴力破解、客户端隐去明文密码、连接失败不返回 IP/端口。

依据：`docs/` 下 16 篇需求/设计/测试文档（飞书），已在 `docs/AUTH_TEST_REPORT.md` 中逐条对应。

## 一键执行

```bash
# 全量 22 条
bash tools/suite_auth.sh

# 指定用例
bash tools/suite_auth.sh AUTH-014 AUTH-017
```

产物：`results/run_<时间戳>/results.tsv` 与逐用例 `<ID>.out`；每条用例都会扫描 8 个 DN 的 `log_datanode_all.log` 增量（白名单见 `lib/lib_auth.sh`）。

## 用例分组（22 条）

| 文件 | 组 | 条数 | 覆盖 |
| --- | --- | --- | --- |
| `cases/g1_base.sh` | 基础鉴别 | 10 | root 登录、错误密码 801、不存在用户 804、CREATE/DROP/ALTER USER、密码修改、LIST USER、GRANT/REVOKE、强密码开关 |
| `cases/g2_policy.sh` | 密码策略 | 6 | 有效期下发、历史口令不可复用、陈旧密码提示、**密码过期校验 ERROR 缺陷回归**、用户重命名、会话数限制 |
| `cases/g3_lock.sh` | 暴力破解与客户端 | 6 | 5 次错误后锁定 822、锁定范围（用户级）、ACCOUNT UNLOCK、重启 DN 清锁、连接失败不暴露 IP:端口、不回显明文密码 |

## 已知缺陷（AUTH-014）

`DataNodeAuthUtils.checkPasswordExpiration` 在「可容忍降级」时仍打印 ERROR + 完整堆栈：

```
ERROR o.a.i.d.u.DataNodeAuthUtils:522 - Fail to check password expiration
java.util.concurrent.TimeoutException
    at ...DataNodeAuthUtils.executeLoginHistory(DataNodeAuthUtils.java:108)
    at ...DataNodeAuthUtils.checkPasswordExpiration(DataNodeAuthUtils.java:519)
    at ...SessionManager.login(SessionManager.java:170)
```

- 触发条件（实测）：**DataNode 启动窗口内的首次登录**，内部 `queryPasswordExpiration` 的 Future 超时；
- 代码随后走 `mayBypass` 放行（同一秒 `Login successfully`），却已记 ERROR；
- `AUTH-014` 用「重启全部 DN + 立即持续登录」复现，命中即 FAIL（本版本稳定复现，约 4 分钟）；
- 期望：降级放行时降为 WARN（不带堆栈）或对启动期超时做重试/短路。

## 运行注意

1. `AUTH-017/018/019` 会锁定账号、`AUTH-020` 与 `AUTH-014` 会重启 DataNode，需在专用测试集群执行；
2. `AUTH-020`、`AUTH-014` 重启后会自动等待集群恢复 8 节点；
3. 锁定为**用户级**（同 IP 其他用户不受影响），重启 DN 可清除内存计数；
4. 强密码最小长度 **12**，复杂度要求大写/小写/数字/特殊字符；
5. `AUTH-008` 未授权读返回空集（不报错），断言以「是否查到数据」为准。

## 目录

```
auth_skill/
├── SKILL.md                本文件
├── README.md               安装/配置/产物说明
├── cases.tsv               用例矩阵（机器可读）
├── cases/                  g1~g3 + MANIFEST.md5
├── conf/env.conf           环境配置（拓扑、版本路径、账号）
├── lib/lib_auth.sh         断言、登录助手、日志增量与白名单
├── tools/                  suite_auth.sh / deploy_build.sh / hard_reset.sh
└── docs/AUTH_TEST_REPORT.md 测试报告（22 条结果、缺陷定位、观察项）
```
