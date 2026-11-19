# TDB-1442 DROP USER 断连与僵尸会话验证（2.0.13.1 RC3 `ac7f95e`）

| 项 | 内容 |
| --- | --- |
| 来源工作项 | TDB-1442 / 【TIMECHODB-0479】drop user 成功后应断开其连接，否则仍可继续操作；再建同名用户时僵尸会话复活 |
| 修复提交 | `ff2f6120b9` Add auto-log-out for stale/invalid sessions（AuthOperationProcedure 关闭被删用户会话；IoTDBStatement 失效会话自动登出报 802） |
| 验证版本 | 2.0.13.1 **RC3** `ac7f95e`，3C5D（SR3/DR2，IoTConsensus V1） |
| 验证用例 | **RN-211（普通模式）**、**RN-212（三权分立）**，各自独立、每次从 clean reset 开始 |
| 结果 | **2/2 PASS**（2026-11-19 13:38 / 13:42） |

## 一、验证场景

1. 管理员（普通模式 root / 三权分立 security_admin）创建用户 `rn1442_u`；
2. 用户 `rn1442_u` 用 JDBC 建立连接，执行 `show databases` 成功；
3. 管理员 `DROP USER rn1442_u`；
4. **用原连接**再次执行语句 → 期望被拒（`802: Log in failed. Either you are not authorized or the session has timed out.`）；
5. 管理员重建**同名同密码**用户；
6. **用原连接**再次执行 → 期望仍被拒（僵尸会话不复活）；
7. 用户新建连接 → 期望正常执行；
8. 清理用户。

## 二、实测结果（两模式一致）

| 检查点 | 普通模式 RN-211 | 三权分立 RN-212 |
| --- | --- | --- |
| drop 前原连接执行 | `QUERY_OK rows=1` | `QUERY_OK rows=1` |
| drop 后原连接执行 | `802: Log in failed...` | `802: Log in failed...` |
| 重建同名用户 | 成功 | 成功 |
| 重建后原连接执行 | `802: Log in failed...` | `802: Log in failed...` |
| 重建后新连接执行 | `QUERY_OK rows=1` | `QUERY_OK rows=1` |

**结论：RC3 已验证修复**——DROP USER 会立即使原会话失效，重建同名用户不会让僵尸会话复活，新连接不受影响。

## 三、用例与环境

| 项 | 值 |
| --- | --- |
| 用例文件 | `cases/TIMECHODB_0479_v2.0.13.1.sh`（RN-211 / RN-212） |
| 工具 | `tools/UserSessionProbe.java`（自包含：建用户→用户连接→删用户→原连接探测→重建→再探测→新连接）、`tools/user_session_probe.sh`（编译并驱动） |
| 三权分立下的管理账号 | `security_admin`（具备 SECURITY，可 `create user` / `drop user` / `list user`） |
| 驱动脚本 | `/tmp/run_tdb1442.sh`：每个用例前 `reset_cluster.sh` 干净重建；RN-212 由用例内部开启三权分立 |
| 结果目录 | `/data2/auto_test/tdb1442_20261119_133509`（RN-211.out / RN-212.out / 结果 TSV） |

## 四、备注

- 三权分立下 `sys_admin` 只有 SYSTEM 权限，不能 `create/drop user`，也不能 `show cluster`；本用例的管理操作使用 `security_admin`，登录性检查用 `list user`；
- 用例只依赖 `show databases`（无需额外授权），避免因授权语法（表/树方言差异）干扰会话有效性判定。
