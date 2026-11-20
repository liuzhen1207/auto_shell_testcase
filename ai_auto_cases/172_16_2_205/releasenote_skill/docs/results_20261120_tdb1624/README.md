# TDB-1624 自动化回归用例（旧快照缺密钥元数据 → 滚动升级 CN 启动失败）

| 项 | 内容 |
| --- | --- |
| 缺陷 | TDB-1624【2.0.13.1-RC2】【密钥管理】旧快照缺少密钥元数据时提交旧版 CN 不支持的计划，导致 ConfigNode 启动失败 |
| 复现版本 | RC2（83183d0）上报；**RC3（ac7f95e）实测仍复现**（修复版本 RC4） |
| 升级路径 | 2.0.12.1 RC12 `c05111d` → 2.0.13.1 RC3 `ac7f95e` |
| 回归用例 | **RN-220 滚动升级（完整流程 + 并发读写）**、**RN-221 聚焦复现（只升级一个 CN follower）** |
| 当前状态 | 两例均 **KNOWN**（已在 `conf/known_failures.conf` 登记，不计入回归失败）；RC4 修复后重跑应转 PASS |

## 一、用例设计

### RN-221（聚焦复现，约 8 分钟）

1. 旧集群（2.0.12.1 RC12）8/8，记录 3 台 CN 的 `log_confignode_all.log` 行号基线；
2. 只把 **一个 CN follower（172.16.2.27）** 就地替换为 RC3 二进制并启动；
3. 断言（期望为“修复后应满足”，当前全部不满足 → 复现缺陷）：
   - 升级后 CN 正常运行（进程 + 10710 监听）；
   - 升级后 CN 日志无 `Failed to initialize the cluster key-domain identity`；
   - 旧 CN（.26/.28）在升级窗口内**无** `Unrecognized log configPhysicalPlanType: -898/-899`；
   - 旧 CN **无** ConfigRegion 状态机 NPE（`markAsGeneratedByRemoteConsensusLeader`）；
   - 集群恢复 8/8；
4. 清理：回滚该 CN 到 RC12 并恢复集群。

### RN-220（完整滚动升级，约 20 分钟）

旧集群造树模型 + 表模型（含 OBJECT）数据 → 启动并发读写 → CN follower → CN leader → DN 串行升级 → 校验数据完整、版本、日志。

## 二、RN-221 实测（RC3，KNOWN）

```
[ok]   当前为旧版本 RC12（BuildInfo=c05111d）
[ok]   已记录 CN 日志基线（升级窗口起点）
[FAIL] 升级后 CN follower 未正常运行（java=0, port10710=0）——TDB-1624 现象
[FAIL] 升级后 CN 报 'Failed to initialize the cluster key-domain identity'（TDB-1624 核心现象）
[FAIL] 旧 CN 172.16.2.26 出现未识别计划 -898/-899（1 条）
[FAIL] 旧 CN 172.16.2.26 出现 ConfigRegion 状态机 NPE（1 条）
[FAIL] 旧 CN 172.16.2.28 出现未识别计划 -898/-899（1 条）
[FAIL] 旧 CN 172.16.2.28 出现 ConfigRegion 状态机 NPE（1 条）
[FAIL] 升级后集群未恢复 8/8（滚动升级中断）
[LOG err=0 warn=0 unexp=0]
```

与 TDB-1624 描述链路完全一致（`-898` 计划 → 旧 CN 状态机 NPE → 升级后 CN key-domain 启动失败 → 升级中断）。

## 三、判定口径

- 用例的断言按“**修复后的期望**”编写：旧 CN 不出现 -898/-899、无 NPE，升级后 CN 正常启动、集群恢复 8/8；
- 当前 RC3 不满足 → FAIL；为避免全量回归长期变红，已登记 `conf/known_failures.conf`，判定为 **KNOWN**；
- RC4 修复后重跑 RN-220/RN-221，若断言通过则自动转 **PASS**，无需改用例。

## 四、文件

| 文件 | 内容 |
| --- | --- |
| `cases/V2_1262_v2.0.13.1.sh` | RN-219 / RN-220 / **RN-221** |
| `lib/upgrade_lib.sh` | 停节点 / 就地换 lib-sbin / 启动 / 等待 8-8 / 版本查询 |
| `tools/upgrade_workload.sh` | 滚动升级期间的并发读写 |
| `conf/known_failures.conf` | RN-220、RN-221 的 KNOWN 说明（TDB-1624） |
| `RN-221.out` / `RN-221.tsv` | 本次复现结果（KNOWN，含日志窗口） |
| `docs/results_20261120_tdb1262/` | 完整证据：旧 CN `-898/-899`、NPE、升级后 CN key-domain 堆栈 |

## 五、环境前置（重要）

升级类用例要求**旧集群版本纯正**。实测发现：`deploy_build.sh` 在目标 `lib` 已存在时会跳过复制，
导致节点残留上一轮的 RC3 二进制（表现为 `show cluster` 里 CN=RC12、DN=RC3 的混合版本）。

因此新增 `tools/force_align_build.sh`（本次以脚本 `/tmp/force_align_build.sh` 运行）：
停止全部节点 → 检查每节点 `lib/timechodb-server-*.jar` 版本 → 不一致则用打包好的
`lib+sbin` tar 覆盖 → 重启并校验 8 节点 BuildInfo 全部为 `c05111d`。

RN-221 已在该纯 RC12 环境（8/8 全部 `c05111d`）复跑，结果与混合环境一致（7 项断言全中，KNOWN），
说明复现结论不受此前的混合版本干扰。
