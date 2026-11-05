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

## 已登记缺陷

本版本回归期间发现并录入 PLM 的缺陷，详见 [KNOWN-DEFECTS.md](KNOWN-DEFECTS.md)。

| 缺陷 | 优先级 | 标题 | 状态 |
| --- | --- | --- | --- |
| [TDB-939](https://plm.infra.timecho.com/iterations?productId=1&itemId=1562) | P1 | DELETE 后紧跟 FLUSH 时删除标记未落盘，已删数据重新可见且多副本不一致 | 排期确认（江天，迭代 V2.0.15.1） |

> TDB-939 不是 RN 验证发现的，而是本版本 `delete_skill` 全量回归（IoTConsensus 85 轮）发现的，登记在此以便下个版本回归时一并复核。

## 本版本环境限制（影响后续 RN 验证）

1. 发行包不含 REST 模块（`org.apache.iotdb.rest.RestService`），启用 `enable_rest_service=true` 会导致 DataNode 启动失败，**REST 接口无法覆盖**。
2. 测试机 172.16.2.20 与 172.16.2.205 均无 python3 / go / g++ / thrift / boost，且无外网，**Python / Go / C++ 客户端无法覆盖**。
3. 该集群为已有数据目录，整机停止后**不能只起 seed CN**（无法选出 leader），必须 3 台 CN 同时启动。
