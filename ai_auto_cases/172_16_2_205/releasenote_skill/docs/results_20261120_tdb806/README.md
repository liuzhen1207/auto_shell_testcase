# TDB-806（V2-423）使用 SQL 手动修复分区表 —— RC3 自动化回归

| 项 | 内容 |
| --- | --- |
| 功能 | Tree 方言 `REPAIR DATA PARTITION TABLE` + `SHOW REPAIR DATA PARTITION TABLE PROGRESS` |
| 参考记录 | PLM `docs/708`（2.0.11.1 RC5，62 项：58 PASS） |
| 验证版本 | 2.0.13.1 RC3 `ac7f95e`，3C5D（SR3/DR2，IoTConsensus V1） |
| 用例 | RN-223 ~ RN-227 |
| 结果 | **RN-223 / 224 / 226 / 227 PASS**；RN-225（权限）受环境账号锁定阻塞，待复测 |

## 一、用例设计（依据 docs/708 的 6 类场景精简）

| 用例 | 场景 | 断言要点 | 结果 |
| --- | --- | --- | --- |
| RN-223 | 基础修复 + 进度 | 触发前 IDLE/0%；`REPAIR DATA PARTITION TABLE` 成功；修复过程结束；树/表数据完整 | PASS |
| RN-224 | 幂等 / 重复触发 | 连续触发两次均成功；数据不丢 | PASS |
| RN-225 | 权限 | 无 SYSTEM 用户被拒（803）；授予 SYSTEM 后可执行并完成 | **阻塞**（见三） |
| RN-226 | 方言 / 语法 | Table 方言拒绝修复与进度语句；Tree 方言 `TABLES`、缺少 `TABLE` 报 700 | PASS |
| RN-227 | worker 参数 | `partition_table_recover_worker_num=4` 下修复正常完成、数据完整 | PASS |

## 二、实测要点

1. **健康集群（无缺失分区）时**：`REPAIR DATA PARTITION TABLE` 会立即完成，CN 日志记录
   `No databases have lost data partitions, terminating procedure`，**进度保持 IDLE/0%**。
   因此用例以「过程结束（日志标志）或进度=100」为完成判据，而非强制 100%。
2. 进度查询：`SHOW REPAIR DATA PARTITION TABLE PROGRESS` 返回 `Status / Progress(%) / Message`。
3. 方言：Table 方言执行 `REPAIR DATA PARTITION TABLE` 与进度语句均返回 700（符合 docs/708 记录）。
4. 参数：`partition_table_recover_worker_num` 可通过 `SET CONFIGURATION` 生效，修复正常完成。
5. 日志窗口（`RN_LOG_CHECK=1`）：4 个 PASS 用例均为 `err=0 warn=0 unexp=0`。

## 三、RN-225 阻塞说明（需复测/确认）

现象：suite 内执行 `list user` / `create user` 返回
`801: Authentication failed`，随后多次失败会升级为
`822: Account is blocked due to consecutive failed logins`；
但在同一时刻用 CLI 手工执行同样语句却成功。

分析：
- 与 `enable_audit_log` 无关（已实测：审计关闭时同样出现；审计开启时手工创建用户正常）；
- 与 `enable_separation_of_powers=false` 无关（conf 已确认关闭）；
- 更像是**账号锁定状态的残留/高频 CLI 连接触发**：一旦出现 801，后续尝试会累积为 822，且
  重置数据后仍可能短暂保留。

处理：用例已改为「先检查 root 可用性，不可用则立即失败并提示」，**不再重试**（避免继续累积锁定）。
待环境完全解锁后复跑即可；功能本身（权限拒绝/允许）在 docs/708 中已验证通过。

## 四、文件

| 文件 | 内容 |
| --- | --- |
| `cases/V2_806_v2.0.13.1.sh` | RN-223~227 |
| `RN-223/224/226/227.out` `.tsv` | PASS 证据（含日志窗口） |
| `RN-225_fail.tsv` | 本次阻塞结果（801/822） |
