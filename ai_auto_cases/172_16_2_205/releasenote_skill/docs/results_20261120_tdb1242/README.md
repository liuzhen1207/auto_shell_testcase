# TDB-1242 开审计 + 数据升级后并发写入验证（2.0.12.1 RC12 → 2.0.13.1 RC3）

| 项 | 内容 |
| --- | --- |
| 来源工作项 | TDB-1242【2.0.9.1 RC1】开审计日志，数据升级后并发写入新数据，DN 空指针：`IClientSession.addStatementId(long) ... "<parameter1>" is null` |
| 升级路径 | **2.0.12.1 RC12 `c05111d` → 2.0.13.1 RC3 `ac7f95e`** |
| 环境 | 3 CN + 5 DN，SR3/DR2；审计通过 `enable_audit_log=true` 在 8 个节点开启 |
| 用例 | **RN-222** |
| 结果 | **PASS**（2026-11-20，两次执行一致；日志窗口 `err=0 warn=0 unexp=0`） |

## 一、验证流程

1. 前置：纯 RC12 集群（8/8 全部 `c05111d`）；
2. 在 3 CN + 5 DN 的 `conf/iotdb-system.properties` 写入 `enable_audit_log=true`，重启集群 → 8/8；
3. 旧集群造数（树 + 表），确认审计已记录（`__audit.audit_log` 有数据）；
4. **数据升级**：停全部节点 → 就地替换 lib/sbin 为 RC3 → 启动 → 8/8，版本 `ac7f95e`；
5. 升级后做**并发写入**：6 个写手并行 30 秒，各写树（`root.rn1242_tree.dN.s1`）与表（`rn1242_table.t1`）；
6. 断言：
   - 并发写入无失败（树 54 次 / 表 54 次全部成功）；
   - 升级后审计仍持续记录（`audit_log` 行数增长）；
   - **DN 错误日志无 `addStatementId` NPE**（TDB-1242 现象）；
   - 数据完整（逐设备合计 = 基线 + 并发写入数）；
   - 日志窗口无不符合预期的 WARN/ERROR。

## 二、实测结果

| 检查点 | 实测 |
| --- | --- |
| 审计开启 | 8/8 节点 `enable_audit_log=true`，重启后 8/8 |
| 升级前审计记录 | `audit_log=193` 行 |
| 升级后集群/版本 | 8/8，`ac7f95e` |
| 旧数据 | 树 count=2 可查 |
| 并发写入 | **tree_ok=54 / tree_err=0，table_ok=54 / table_err=0** |
| 升级后审计增长 | `audit_log` **193 → 1637** |
| **DN `addStatementId` NPE** | **0 条**（TDB-1242 现象未复现） |
| 数据完整性 | 逐设备合计 count=**56**（2 基线 + 54 并发） |
| 日志窗口 | `err=0 warn=0 unexp=0` |

## 三、结论

**RC3 已验证通过**：开启审计日志并完成数据升级后，并发写入新数据（树/表）无失败，审计持续记录，
DN 未出现 `IClientSession.addStatementId` 空指针，数据完整、日志无异常。

## 四、文件

| 文件 | 内容 |
| --- | --- |
| `cases/V2_1242_v2.0.13.1.sh` | RN-222 |
| `lib/upgrade_lib.sh` | 停节点 / 就地换 lib-sbin / 启动 / 等待 8-8 / 版本查询（复用） |
| `RN-222.out` / `RN-222.tsv` | 断言明细与结果（PASS） |
