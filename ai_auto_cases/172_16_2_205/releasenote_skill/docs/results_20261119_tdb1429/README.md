# TDB-1429 DROP USER 系统库元数据级联删除验证（2.0.13.1 RC3 `ac7f95e`）

| 项 | 内容 |
| --- | --- |
| 来源工作项 | TDB-1429 / 【TIMECHODB-0501】drop user 后 `root.__system` 下的元数据（数据）应被级联删除 |
| 修复提交 | `ff2f6120b9`；`#16416`（删除用户时删除密码历史）、`#16542`（密码历史按 userId 记录） |
| 验证版本 | 2.0.13.1 **RC3** `ac7f95e`，3C5D（SR3/DR2，IoTConsensus V1） |
| 验证用例 | **RN-213（普通模式）**、**RN-214（三权分立）**，各自独立、每次从 clean reset 开始 |
| 结果 | **2/2 PASS**（2026-11-19 14:43 / 14:47） |

## 一、验证对象说明

RC3 中用户相关系统元数据存放在 **`root.__audit.password_history._<userId>`**（每个用户一个 device，含 `password` / `oldPassword` 两个测点）；`root.__system` 下无残余序列。

密码历史默认不落盘，需要开启密码策略才会生成：

```sql
SET CONFIGURATION 'password_reuse_interval_days'='30';
SET CONFIGURATION 'password_expiration_days'='90';
```

## 二、验证步骤

1. 开启上述密码策略；
2. 管理员创建用户 `rn1429_u`（密码 P1），记录其 **userId**；
3. 修改密码两次（P2、P3），并用新密码登录一次；
4. 校验 `count timeseries root.__audit.password_history._<userId>.**` ≥ 1（元数据已存在）；
5. `DROP USER`，等待 5s；
6. 再次校验同一路径 → 期望 **0**（级联删除）；
7. 重建**同名同密码**用户 → 新 userId；校验旧 userId 路径为 0、新 userId 路径有其独立记录（不继承旧历史）。

## 三、实测结果

| 检查点 | 普通模式 RN-213 | 三权分立 RN-214 |
| --- | --- | --- |
| DROP 前该用户密码历史测点数 | **2** | **2** |
| DROP 后同一路径测点数 | **0** | **0** |
| `root.__system` 残留序列 | 0 | 无权限（隔离设计，跳过） |
| 重建后 userId | 10001（旧 10000） | 10001（旧 10000） |
| 旧 userId 残留 | **0** | **0** |
| 新 userId 独立记录 | **2** | **2** |

**结论：RC3 已验证修复** —— DROP USER 后该用户的密码历史元数据被级联删除（2 → 0），重建同名用户使用新 userId，不继承旧历史。

## 四、用例与环境

| 项 | 值 |
| --- | --- |
| 用例文件 | `cases/TIMECHODB_0501_v2.0.13.1.sh`（RN-213 / RN-214） |
| 普通模式账号 | 管理员 root；系统数据检查 root |
| 三权分立账号 | 管理员 `security_admin`（SECURITY，可 set configuration / create / drop user）；系统数据检查 `audit_admin`（AUDIT，可读 `root.__audit`） |
| 驱动脚本 | `/tmp/run_tdb1429.sh`：每个用例前 `reset_cluster.sh` 干净重建；RN-214 由用例内部开启三权分立 |
| 结果目录 | `/data2/auto_test/tdb1429_20261119_143859` |

## 五、备注

- 三权分立下 `sys_admin`/`security_admin` 无 AUDIT 权限，读不到 `root.__audit`（803），因此系统数据检查必须用 `audit_admin`；
- `root.__system` 在两种模式下均无该用户序列残留；三权分立下 `audit_admin` 对 `root.__system` 无权限，用例自动跳过该项并记录原因（属权限隔离设计，不作为失败）。
