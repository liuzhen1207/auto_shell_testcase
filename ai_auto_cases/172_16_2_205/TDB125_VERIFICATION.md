# TDB-125 验证记录（2.0.13.1 RC1）

- 工作项：TDB-125 ——「修复某个 DN 异常时，实际授权成功但是提示授权超时的问题」
- 验证环境：TimechoDB **2.0.13.1 / ab6d3de**，3C5D（CN 172.16.2.26-28，DN 172.16.2.2-6），IoTConsensus 经典协议
- 验证时间：2026-11-02 14:00~14:26
- 脚本：`scripts/verify_tdb125.sh`

## 场景与结果

| # | 场景 | GRANT 耗时 | GRANT 返回 | 权限生效 | 读取数据 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 基线（DN 全部正常） | — | `The statement is executed successfully.` | — | — | 正常 |
| 1 | **kill -9** 一台 DN（172.16.2.5，进程数=0）后授权 | **989 ms** | 成功 | `LIST PRIVILEGES OF USER` 可见 | `select s1 from root.tv125.d1` 正常返回 | **PASS** |
| 2 | **SIGSTOP** 一台 DN（进程存活但无响应，最接近 unknown）后授权 | **1037 ms** | 成功 | 可见 | 正常返回 | **PASS** |
| 3 | kill -9 后重复授权（再次确认） | **986 ms** | 成功 | 可见 | 正常返回 | **PASS** |

## 判定标准（对照原缺陷）

| 原缺陷现象 | 本次实测 |
| --- | --- |
| 某 DN/C N 处于 unknown 时，`GRANT` 提示**超时** | 未出现超时；1 秒内返回成功 |
| 但权限实际已生效（"底层已成功"） | 权限确实生效，且与返回值一致 |
| CN 日志出现 `INVALIDATE_PERMISSION_CACHE failed ... retrying 7/8/9` → `Connection refused` | 本次未因授权阻塞（如需要可进一步比对该日志） |

## 结论

**通过**。在 DN 被 kill -9（不可达）与 SIGSTOP（无响应）两种异常下，`GRANT` 均在约 1 秒内成功返回，且权限立即生效、可正常读取数据，未复现"提示超时"现象。

> 按用户要求：**通过则不回填 PLM**，仅记录本验证结果。

## 附：日志与源码侧佐证（2026-11-02 14:55 补查）

| 检查项 | 结果 |
| --- | --- |
| CN 日志中 `INVALIDATE_PERMISSION_CACHE`（14:00~14:26，三台 CN） | **0 行** —— 不再出现旧版的同步重试风暴 |
| CN 日志中 `SyncDataNodeClientPool ... retrying 7/8/9` | **0 行** |
| 相邻的 last-cache 失效日志 | 存在（`AsyncRequestManager:170 - Failed to INVALIDATE_LAST_CACHE after 1 retry`），走异步路径，不影响 GRANT 返回 |
| 源码（2.0.13.1，`/iotdb-core`） | 权限缓存失效已改为**异步发送**：`AuthOperationProcedure.java:214` → `CnToDnAsyncRequestType.INVALIDATE_PERMISSION_CACHE`、`CnToDnInternalServiceAsyncRequestManager.java:607`；旧同步路径 `SyncDataNodeClientPool.java:104` 仍保留但授权流程不再阻塞其上 |

→ 结论与实测一致：授权 procedure 不再同步等待所有 DN 的缓存刷新，因此 DN 不可达时 `GRANT` 仍在约 1 秒内成功返回。
