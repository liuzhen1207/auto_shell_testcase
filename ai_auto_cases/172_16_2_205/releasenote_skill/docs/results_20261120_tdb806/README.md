# TDB-806（V2-423）使用 SQL 手动修复分区表 —— RC3 自动化回归

| 项 | 内容 |
| --- | --- |
| 功能 | Tree 方言 `REPAIR DATA PARTITION TABLE` + `SHOW REPAIR DATA PARTITION TABLE PROGRESS` |
| 参考记录 | PLM `docs/708`（2.0.11.1 RC5，62 项：58 PASS） |
| 验证版本 | 2.0.13.1 RC3 `ac7f95e`，3C5D（SR3/DR2，IoTConsensus V1） |
| 用例 | RN-223 ~ RN-227 |
| 结果 | **RN-223 / 224 / 225 / 226 / 227 全部 PASS**（日志窗口均 `err=0 warn=0 unexp=0`） |

## 一、用例设计（依据 docs/708 的 6 类场景精简）

| 用例 | 场景 | 断言要点 | 结果 |
| --- | --- | --- | --- |
| RN-223 | 基础修复 + 进度 | 触发前 IDLE/0%；`REPAIR DATA PARTITION TABLE` 成功；修复过程结束；树/表数据完整 | PASS |
| RN-224 | 幂等 / 重复触发 | 连续触发两次均成功；数据不丢 | PASS |
| RN-225 | 权限 | 无 SYSTEM 用户被拒（803）；授予 SYSTEM 后可执行并完成 | PASS |
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

## 三、RN-225 的 801/822 排查结论（用例自身缺陷，非产品问题）

现象：`list user` / `create user` 在 suite 内返回 `801: Authentication failed`，反复尝试后升级为
`822: Account is blocked due to consecutive failed logins`；而手工 CLI 同一语句成功。

根因：**用例把全局 root 密码变量 `$PW` 遮蔽了**。原实现写成

```bash
local U=rn806_u PW='Rn806@123456'   # ← 覆盖了全局 root 密码
create_out=$(T "create user $U '$PW'")   # root 实际用普通用户密码登录 → 801
```

`T()` 内部使用 `-pw "$PW"`，因此后续所有 root 操作都在用错误密码登录；连续失败触发服务端
暴力破解保护，锁定后连正确密码也返回 822，故手工复测也会短暂失败。

修复：
1. 局部变量改名 `UPW`，不再遮蔽全局 `PW`；
2. 用修复语句本身区分「803 无权限」与「801/822 登录失败」，不再用 `show cluster` 做登录探测（普通用户无权）；
3. `304 already submitted` 视为修复程序已在运行，复用现有过程继续等待完成。

修复后 RN-225 PASS（`create user` → 803 拒绝 → `grant system` → 修复成功）。

## 四、文件

| 文件 | 内容 |
| --- | --- |
| `cases/V2_806_v2.0.13.1.sh` | RN-223~227 |
| `RN-223/224/226/227.out` `.tsv` | PASS 证据（含日志窗口） |
| `RN-225.out` `.tsv` | PASS 证据 |
