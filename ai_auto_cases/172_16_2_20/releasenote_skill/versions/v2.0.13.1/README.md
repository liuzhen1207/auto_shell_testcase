# v2.0.13.1（RC1）

| 项 | 值 |
| --- | --- |
| 版本 | TimechoDB 2.0.13.1 RC1 |
| BuildInfo | `ab6d3de` |
| 包 | `timechodb-2.0.13.1-bin.zip`（`172.16.2.20:/data2/iotdb/v20131rc1_1030_ab6d3de/`） |
| 源码 | `D:\IDEA\timechodb_src\v20131\timechodb`，分支 `rc/2.0.13.1` |
| 环境 | 3 CN（172.16.2.16/17/18）+ 5 DN（172.16.2.19/21/22/23/24），SR3/DR2，`IoTConsensus`，`ClusterID3` |

## 已验 RN

| RN | 标题 | 类型 | 结论 | 报告 |
| --- | --- | --- | --- | --- |
| TDB-65 | 集群节点 ReadOnly 可观测性提升 | 新功能 | 通过 | [TDB-65](TDB-65/release_note_test_report.md) |

## 本版本环境限制（影响后续 RN 验证）

1. 发行包不含 REST 模块（`org.apache.iotdb.rest.RestService`），启用 `enable_rest_service=true` 会导致 DataNode 启动失败，**REST 接口无法覆盖**。
2. 测试机 172.16.2.20 与 172.16.2.205 均无 python3 / go / g++ / thrift / boost，且无外网，**Python / Go / C++ 客户端无法覆盖**。
3. 该集群为已有数据目录，整机停止后**不能只起 seed CN**（无法选出 leader），必须 3 台 CN 同时启动。
