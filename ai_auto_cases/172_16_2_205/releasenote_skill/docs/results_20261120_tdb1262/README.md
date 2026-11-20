# TDB-1262 数据升级 / 滚动升级验证（2.0.12.1 RC12 → 2.0.13.1 RC3）

| 项 | 内容 |
| --- | --- |
| 来源工作项 | TDB-1262【2.0.9.1 RC1 新引入问题】数据升级 CN NPE；滚动升级（CN follower → leader → DN） |
| 升级路径 | **2.0.12.1 RC12 `c05111d` → 2.0.13.1 RC3 `ac7f95e`** |
| 环境 | 3 CN（172.16.2.26/27/28）+ 5 DN（172.16.2.2~6），SR3/DR2 |
| 用例 | **RN-219 数据升级（PASS）**、**RN-220 滚动升级（FAIL，已定位根因）** |

## 一、RN-219 数据升级（整体替换二进制）—— PASS

流程：RC12 集群造树模型 + 表模型（含 OBJECT）数据 → 停全部节点 → 就地替换 lib/sbin 为 RC3 →
启动 → 校验。

| 检查点 | 实测 |
| --- | --- |
| 升级前基线 | 树 count=3、表 count=2（OBJECT 列用 `to_object(true,0,X'cafebabe')` 写入） |
| 升级后集群 | 8/8，BuildInfo=**ac7f95e** |
| 旧树数据 | count=3 ✅ |
| 旧表数据 | count=2 ✅ |
| OBJECT 列 | `length(read_object(obj))=4` ✅ |
| 写入新树数据 | 成功 ✅ |
| 写入新表数据（含 OBJECT） | 成功，count=3 ✅ |
| CN 错误日志 NPE / 数组越界 | **0 条** ✅ |
| 日志窗口 | `[LOG err=0 warn=0 unexp=0]` |

**结论：数据升级（整体替换）通过，未复现 CN NPE/数组越界。**

## 二、RN-220 滚动升级 —— FAIL（根因：cluster key-domain identity）

按需求流程执行：旧集群在线 + 并发读写负载 → 先升级 CN follower（27、28）→ 再 CN leader（26）→ 最后串行升级 DN。

**结果：第一个 CN follower（172.16.2.27）替换为 RC3 二进制后启动即失败并 deactivate：**

```
ERROR o.a.i.c.s.ConfigNode:323 - Meet error while starting up.
org.apache.iotdb.commons.exception.StartupException:
    Failed to initialize the cluster key-domain identity.
  at org.apache.iotdb.confignode.service.ConfigNode.validateClusterKeyManagementState(ConfigNode.java:637)
```

随后 CN follower 升级后集群无法恢复到 8/8，用例判定失败（详见 `cn27_startup_error.log`）。

**分析**：RC3 ConfigNode 启动时新增 **cluster key-domain identity 校验**（2.0.13 引入的密钥管理状态，
由 `UpdateKeyManagementStatePlan` 持久化）。RC12 集群没有该状态，因此在
「2 个 RC12 CN + 1 个 RC3 CN」的混布阶段，升级后的 CN 无法完成初始化 → 退出。

对比：RN-219 是**全部节点同时替换**，RC3 的第一个 CN 能作为初始化者建立 key-domain 状态，所以能起来。

## 三、需要研发确认的问题

滚动升级 2.0.12.1 → 2.0.13.1 是否**支持**？从本次实测看，第一个升级的 CN 会因
`Failed to initialize the cluster key-domain identity` 起不来，导致滚动升级在 CN 阶段就中断。

请确认属于哪种情况：

1. **产品限制/缺陷**：2.0.13 起 CN 需要 key-domain，旧版本集群滚动升级需特殊处理（如先初始化 key-domain、
   或配置关闭该校验），需研发给出方案/补丁；
2. **流程预期**：滚动升级应**先升级 CN leader**（或需停机初始化 key-domain），用例流程需按实际支持的方式调整；
3. **仅支持整体替换升级**（如 RN-219），滚动升级不在支持范围。

确认后我再调整 RN-220 的期望或改为已知限制（known_failures），避免全量回归被它拖红。

## 四、文件

| 文件 | 内容 |
| --- | --- |
| `cases/V2_1262_v2.0.13.1.sh` | RN-219 / RN-220 |
| `lib/upgrade_lib.sh` | 停节点、就地替换 lib/sbin、启动、等待 8/8、版本查询 |
| `tools/upgrade_workload.sh` | 滚动升级期间的并发读写负载（树 + 表含 OBJECT） |
| `RN-219.out` / `RN-219.tsv` | 数据升级结果（PASS，含日志窗口） |
| `RN-220.out` | 滚动升级失败明细 |
| `cn27_startup_error.log` | CN follower 启动失败堆栈（key-domain identity） |
