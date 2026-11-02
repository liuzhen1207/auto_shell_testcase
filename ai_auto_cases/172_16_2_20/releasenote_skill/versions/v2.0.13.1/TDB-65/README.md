# TDB-65 集群节点 ReadOnly 可观测性提升 — 验证记录

| 项 | 值 |
| --- | --- |
| RN | TDB-65（功能迭代，P0，迭代 V2.0.13.1） |
| 结论 | **通过** |
| 验证版本 | 2.0.13.1 RC1，BuildInfo `ab6d3de` |
| 验证RC | RC1 |
| PLM 文档 | https://plm.infra.timecho.com/docs/1370 |
| PLM 回填 | 验证结果=通过；工作流 测试 → 走查（PLM 规则自动流转） |
| 与 RN 同 commit | `017b1191b4e00f7f0c41d4f91a2b51102ab940db`（PR #18801，与 TDB-312 同 commit） |

## 环境

3 CN（172.16.2.16/17/18）+ 5 DN（172.16.2.19/21/22/23/24），SR3/DR2，`IoTConsensus`，DN 堆 12 GB。
版本身份核对：`SHOW CLUSTER` 8 台全部 `2.0.13.1 / ab6d3de`。

## 验证内容

| 用例 | 结果 |
| --- | --- |
| TC-65-01 基线列数（无原因） | 通过：8 / 6 / 5 |
| TC-65-02 `SET SYSTEM TO READONLY ON CLUSTER` | 通过：9 / 7，DN `ReadOnly` + `Manual` |
| TC-65-03 ConfigNode 行与 `SHOW CONFIGNODES` | 通过：CN 行 `null`；`SHOW CONFIGNODES` 恒 5 列 |
| TC-65-04 状态与原因分离 | 通过：`Status=ReadOnly`，无 `ReadOnly(Manual)` |
| TC-65-05 `SHOW CLUSTER DETAILS` | 通过：14→15 列 |
| TC-65-06 `SET SYSTEM TO RUNNING ON CLUSTER` | 通过：原因清除，回到 8 / 6 / 5 |
| TC-65-07 三接口 × 两方言一致性 | 通过：54 组结果完全一致 |
| TC-65-08 CN leader 切换持久化 | 通过：leader 0→1 后仍 `Manual`；CN16 重启后仍 `Manual` |
| TC-65-09 节点重启清除 | 通过：DN19 重启后 `Running/null`，其余 4 台仍 `ReadOnly/Manual` |
| TC-65-10 原因优先级 | 源码级通过：`Stopping > Manual > UnrecoverableError > DiskFull > null` |

## 未覆盖接口（下轮补测入口）

| 接口 | 原因 | 补测方式 |
| --- | --- | --- |
| REST | 发行包无 `org.apache.iotdb.rest.RestService`；启用后 DN `Fail to start server` | 换含 REST 模块的包，或确认该版本不支持 REST |
| Python | 无 python3 / pip / 外网 | 提供 python3 + `apache-iotdb` 后可复用 TC-65-01/02/03/04/06/07 |
| Go | 无 go（yum 仅 1.8.3，低于 client 要求） | 提供 go ≥1.19 + iotdb-client-go |
| C++ | 无 g++ / thrift / boost | 提供预编译 client-cpp 或完整工具链 |

## 取证

- 全量证据：`172.16.2.20:/data2/iotdb/rc10_matrix/rn_verify/TDB-65/evidence/`（74 个文件）
- 入库关键证据：`evidence/`（17 个文件）
- 报告：[release_note_test_report.md](release_note_test_report.md)
