# TDB-65 / 集群节点 ReadOnly 可观测性提升 Release Note 测试报告

| 项目 | 内容 |
| --- | --- |
| 测试日期 | 2026-11-02 |
| 测试仓库 | `/data1/iotdb/v20131rc1_1030_ab6d3de`（源码 `D:\IDEA\timechodb_src\v20131\timechodb`，分支 `rc/2.0.13.1`） |
| RN 编号 | TDB-65 |
| 关联 Issue / PR / CVE | commit `017b1191b4e00f7f0c41d4f91a2b51102ab940db`（PR #18801，与 TDB-312 同 commit） |
| 影响模块 | 集群管理 / 节点状态机（ConfigNode 心跳、节点状态展示） |
| 测试类型 | 新功能验证（可观测性：ReadOnly 原因分类、上报与展示） |

## 1. 测试结论

| 结论项 | 结果 |
| --- | --- |
| 修复版本验证（功能验证） | **通过** |
| 旧版本复现 | 不适用：新功能型，旧版无 `StatusReason` 能力 |
| 是否需要启动服务 | 是 |
| 是否建议 release note 结论通过 | 是 |

结论摘要：

1. 2.0.13.1 RC1 上 `SET SYSTEM TO READONLY ON CLUSTER` 后，DataNode 报 `ReadOnly` 且 `StatusReason=Manual`，三条 SHOW 语句按契约新增列，`SET SYSTEM TO RUNNING` 后恢复。
2. 状态与原因分离展示（`Status` 列仍为 `ReadOnly`，不合并成 `ReadOnly(Manual)`），ConfigNode 行 `StatusReason` 为 `null`，`SHOW CONFIGNODES` 列数恒为 5。
3. CLI、Java Session、JDBC 三接口在树/表两种方言下行为完全一致；ReadOnly 原因在 CN leader 切换后仍保持，节点重启后清除。

## 2. RN 信息

RN 原文 / 任务描述：

> 集群节点 ReadOnly 可观测性提升。commit 和 TDB-312 相同：017b1191b4e00f7f0c41d4f91a2b51102ab940db

公开信息 / 外部链接：

1. commit：`https://gitlab.timecho.com/r-d/db/timechodb/-/commit/017b1191b4e00f7f0c41d4f91a2b51102ab940db`
2. 同 commit 的父 RN：TDB-312《集群节点状态机 V2》（DN 停止时向集群报备 Stopped）

RN 描述要点：

1. 对本地 ReadOnly 的原因分类（`DiskFull` / `Manual` / `Stopping` / `UnrecoverableError`），并通过心跳上报到 ConfigNode。
2. 原因与状态分开存储与展示，SHOW 结果在有节点上报原因时追加 `StatusReason` 列。
3. ReadOnly 状态与原因持久化，CN leader 切换后可恢复；节点恢复/重启后清除。

## 3. 测试版本与修复提交

### 3.1 测试版本与包来源

| 项 | 值 |
| --- | --- |
| 版本 | TimechoDB **2.0.13.1 RC1** |
| BuildInfo | `ab6d3de` |
| 包 | `timechodb-2.0.13.1-bin.zip`（97,594,039 B），测试机 `172.16.2.20:/data2/iotdb/v20131rc1_1030_ab6d3de/` |
| 部署 | 3 CN（172.16.2.16/17/18）+ 5 DN（172.16.2.19/21/22/23/24），SchemaRegion 3 副本 / DataRegion 2 副本，`IoTConsensus` |
| 激活 | 逐节点继承旧实例身份，`ACTIVATED` / `ACTIVATED(W)` |

### 3.2 修复提交

`017b1191b4e00f7f0c41d4f91a2b51102ab940db`，标题 *Extend the node state machine and persist node statuses (#18801)*。其中与 TDB-65 直接相关的三段：

1. `feature: add ReadOnly status reasons` —— 分类本地 ReadOnly 原因，经心跳与节点展示 API 传播，`StatusReason` 追加到 SHOW 结果。
2. `feat: persist ReadOnly node status and reasons` —— 经 ConfigNode 共识持久化，leader 变化/快照恢复后可重建。
3. 状态与原因分离（不合并成 `ReadOnly(Manual)`）。

### 3.3 改动模块

- `iotdb-core/confignode`：`LoadCache` / `BaseNodeCache` / `DataNodeHeartbeatCache` / `ConfigManager` / `NodeManager` / `NodeInfo` / `UpdateNodeStatusPlan`
- `iotdb-core/node-commons`：`NodeStatus`（原因常量与优先级）
- `iotdb-core/datanode`：本地状态与原因上报
- 查询层：SHOW 结果列拼装

## 4. 问题描述与理解

本 RN 不是修复缺陷，而是提升"节点为什么变成 ReadOnly"的可观测性。旧版只能看到 `ReadOnly` 一个状态，无法区分是磁盘写满、人工设置、停机中还是不可恢复错误。新版要求：

1. 状态列语义不变（仍为 `ReadOnly`），原因放在独立列 `StatusReason`；
2. 只有在至少一个节点上报原因时才出现该列（不改变无原因时的既有列数，避免破坏老客户端解析）；
3. 原因需能跨越 CN leader 切换存活，并在节点恢复后清除。

## 5. 测试分析与测试方向

### 5.1 功能设计分析

- 原因优先级（源码 `NodeStatus.getReadOnlyReasonPriority`）：`Stopping(4) > Manual(3) > UnrecoverableError(2，前缀匹配) > DiskFull(1) > null/未分类(0)`；同级保留旧原因。
- 该优先级只用于**本地 ReadOnly→ReadOnly** 的更新，不用于接收心跳的原因（远端已决定）。
- `ReadOnly` 属于持久化状态（与 `Stopped`、`Removing` 同类），原因随状态一起持久化。

### 5.2 测试方向

1. 列契约：`SHOW CLUSTER` 8→9、`SHOW DATANODES` 6→7、`SHOW CLUSTER DETAILS` 14→15、`SHOW CONFIGNODES` 恒 5。
2. 展示语义：`Status=ReadOnly`、`StatusReason=Manual`；CN 行为 `null`；不得合并成 `ReadOnly(Manual)`。
3. 生命周期：`SET SYSTEM TO RUNNING ON CLUSTER` 清除；节点重启清除。
4. 持久化：CN leader 切换后原因仍在；CN 重启后仍在。
5. 接口一致性：CLI / Java Session / JDBC × 树/表方言。
6. 优先级：源码级核对（运行时无法在不破坏磁盘的前提下触发 `DiskFull`）。

### 5.3 判定标准

- 有节点上报原因时三条 SHOW 的列数与列名严格符合上述契约，原因值正确；
- 无原因时列数回到基线，老客户端不受影响；
- 三接口 × 两方言结果完全一致；
- leader 切换与节点重启行为符合"持久化 / 恢复即清除"。

## 6. 测试程序与测试数据

### 6.1 测试产物

| 产物 | 路径 |
| --- | --- |
| 证据目录（全部 SHOW 原始输出） | `172.16.2.20:/data2/iotdb/rc10_matrix/rn_verify/TDB-65/evidence/` |
| Java Session 客户端 | `java/SessionShow.java` |
| Java JDBC 客户端 | `java/JdbcShow.java` |
| 矩阵执行脚本 | `scripts/run_matrix.sh` |

### 6.2 复现程序或补丁（如适用）

无补丁。Java 客户端直接编译在发行包 classpath 上：

```bash
CLIENT=/data2/iotdb/v20131rc1_1030_ab6d3de/timechodb-2.0.13.1-bin
javac -cp "$CLIENT/lib/*" -d out SessionShow.java JdbcShow.java
java -cp "$CLIENT/lib/*:out" SessionShow 172.16.2.19 6667 table "show cluster"
```

### 6.3 测试用例

| 用例 | 场景 | 期望 |
| --- | --- | --- |
| TC-65-01 | 基线（无节点上报原因） | `SHOW CLUSTER` 8 列、`SHOW DATANODES` 6 列、`SHOW CONFIGNODES` 5 列，无 `StatusReason` |
| TC-65-02 | `SET SYSTEM TO READONLY ON CLUSTER` | DataNode `Status=ReadOnly`、末列 `StatusReason=Manual`；`SHOW CLUSTER` 9 列、`SHOW DATANODES` 7 列 |
| TC-65-03 | ConfigNode 行语义 | CN 行 `StatusReason=null`；`SHOW CONFIGNODES` 仍 5 列（该语句不受影响） |
| TC-65-04 | 状态与原因分离 | `Status` 列值为 `ReadOnly`，不出现 `ReadOnly(Manual)` 合并形式 |
| TC-65-05 | `SHOW CLUSTER DETAILS` | 列数 14→15，末列 `StatusReason` |
| TC-65-06 | `SET SYSTEM TO RUNNING ON CLUSTER` | 原因清除，列数回到 8/6/5 |
| TC-65-07 | 多接口一致性 | CLI / Java Session / JDBC × 树/表方言，三种状态下列数与列名完全一致 |
| TC-65-08 | CN leader 切换持久化 | kill CN leader 后新 leader 仍展示 `Manual`；CN 重启后仍展示 |
| TC-65-09 | 节点重启清除 | 重启单台 DN 后该 DN 回 `Running`、`StatusReason=null`，其余 DN 仍 `ReadOnly/Manual` |
| TC-65-10 | 原因优先级 | 源码核对 `Stopping > Manual > UnrecoverableError > DiskFull > null`，同级保留旧值（运行时不可控触发 DiskFull） |

完整矩阵（3 接口 × 2 方言 × 3 条 SHOW × 3 状态）共 54 组，原始输出全部落盘。

### 6.4 复现脚本说明（如适用）

`scripts/run_matrix.sh`：依次在 baseline / readonly / restored 三种状态下，用 CLI、Java Session、Java JDBC 分别在树/表方言执行三条 SHOW，输出列数与列名到 `evidence/`。

## 7. 验证方式

### 7.1 执行顺序

1. 核对集群版本：`SHOW CLUSTER` 显示 `2.0.13.1 / ab6d3de`，8/8 Running。
2. 基线取证（TC-65-01）：三接口 × 两方言 × 三条 SHOW。
3. `SET SYSTEM TO READONLY ON CLUSTER`，等待 8 秒，取证（TC-65-02/03/04/05）。
4. 停 CN leader（172.16.2.16）→ 等新 leader（172.16.2.17）→ 取证（TC-65-08）→ 重启 CN16。
5. 重启单台 DN19 → 取证（TC-65-09）。
6. `SET SYSTEM TO RUNNING ON CLUSTER` → 取证（TC-65-06）。
7. 源码核对优先级（TC-65-10）。

### 7.2 环境与工具说明

- 集群：3CN/5DN，DN 堆 12 GB，`IoTConsensus`，`ClusterID3`。
- 工具：发行包自带 CLI；Java 客户端用发行包 `lib/*` 编译运行（OpenJDK 17.0.8）。
- **无法覆盖的接口及原因**（详见 §9）：REST（发行包不含 `org.apache.iotdb.rest.RestService`，启用后 DN 启动失败）、Python / Go / C++（测试机与 172.16.2.205 均无 python3 / go / g++ / thrift，且无外网）。

## 8. 测试结果

### 8.1 用例结果

| 用例 | 实际结果 | 结论 | 证据 |
| --- | --- | --- | --- |
| TC-65-01 | CLI/Session/JDBC × 树/表：8 / 6 / 5 列，无 `StatusReason` | 通过 | `baseline-*.out` |
| TC-65-02 | 9 / 7 列，末列 `StatusReason`；DN 行 `ReadOnly` + `Manual` | 通过 | `readonly-*.out` |
| TC-65-03 | CN 行 `StatusReason=null`；`SHOW CONFIGNODES` 5 列 | 通过 | `readonly-*-show_confignodes.out` |
| TC-65-04 | `Status` 为 `ReadOnly`，无合并形式 | 通过 | `readonly-*-show_cluster.out` |
| TC-65-05 | `SHOW CLUSTER DETAILS` 15 列，末列 `StatusReason` | 通过 | `10-show-cluster-details.out` |
| TC-65-06 | 恢复后 8 / 6 / 5 列，原因清除 | 通过 | `restored-*.out` |
| TC-65-07 | 54 组矩阵结果完全一致 | 通过 | `evidence/` 全部 |
| TC-65-08 | CN leader 0→1 切换后仍 9 列 + `Manual`；CN16 重启后仍 `Manual` | 通过 | `07-*`、`08-*`、`09-*` |
| TC-65-09 | 重启 DN19 后其 `Running` + `null`，其余 4 台仍 `ReadOnly` + `Manual` | 通过 | `12-datanodes-after-dn19-restart.out` |
| TC-65-10 | 源码优先级与注释一致 | 通过（源码级） | 源码 `NodeStatus.getReadOnlyReasonPriority` |

### 8.2 汇总结果（可选，避免与第 1 章重复）

三种状态下三接口 × 两方言的列数完全一致，无方言差异、无接口差异。

## 9. 限制与风险

1. **REST 接口无法验证**：发行包 `lib/` 中无 `org.apache.iotdb.rest.RestService`（只有 `timechodb-server-2.0.13.1.jar`），配置 `enable_rest_service=true` 后 DataNode 启动报 `ClassNotFoundException: org.apache.iotdb.rest.RestService` 并 `Fail to start server`。已回滚该配置。若产品宣称该版本支持 REST，需确认打包遗漏。
2. **Python / Go / C++ 客户端无法验证**：测试机 172.16.2.20 与 172.16.2.205 均无 python3、go、g++、thrift、boost，且无外网/内网 pip 源；yum 仅有 golang 1.8.3（低于 iotdb-client-go 要求）与 gcc 4.8.5（缺 thrift/boost）。需要提供可用的客户端运行时或预编译客户端后才能覆盖。
3. `DiskFull` 原因因无法在不破坏磁盘的前提下触发，只做了源码级核对；`Stopping` / `UnrecoverableError` 同理。
4. 未做升级场景（旧版本数据目录直接换包）验证，RN 未要求。
5. 优先级规则中的 `UnrecoverableError` 为前缀匹配，仅源码核对，未运行时构造。

## 10. 复验交接

本轮无需复验。若后续补上 REST / Python / Go / C++ 运行时，按 §6.3 的 TC-65-01/02/03/04/06/07 在对应接口重跑即可，判定标准不变；证据目录与脚本可直接复用。

## 11. 最终结论

- **功能是否按预期**：是。ReadOnly 原因分类、上报、展示、持久化与清理均符合设计；三条 SHOW 的列契约与源码一致。
- **旧版本是否可复现**：不适用（新功能型）。
- **建议**：TDB-65 验证通过，可放行；同时请研发确认 §9 第 1 条（REST 模块是否应随包分发），以及提供 Python/Go/C++ 客户端环境以便后续版本回归覆盖全部接口。
