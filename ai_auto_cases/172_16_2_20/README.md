# 172_16_2_20（3C5D 集群）

| 项目 | 内容 |
| --- | --- |
| 跳板/客户端 | `172.16.2.20`（用例、客户端、证据都在这台） |
| ConfigNode | `172.16.2.16` / `.17` / `.18`（内部端口 10710） |
| DataNode | `172.16.2.19` / `.21` / `.22` / `.23` / `.24`（RPC 6667，内部 10730） |
| 副本 | SchemaRegion 3 副本、DataRegion 2 副本 |
| 数据面协议 | `IoTConsensus` / `IoTConsensusV2` 按轮次切换（切换需清数据目录重建） |
| 集群名 | `ClusterID3` |
| 当前被测版本 | TimechoDB 2.0.12.1 RC10，BuildInfo `c60ce63`，实例 `/data1/iotdb/v20121rc10_1021_c60ce63` |
| 监控 | 每台 DN `http://<ip>:9092/metrics`（直接抓，不经 Prometheus 汇总） |

## 模块

| 目录 | 内容 | 用例规模 |
| --- | --- | --- |
| `delete_skill/` | DELETE 语义全量回归：内存/落盘/混合阶段、时间与谓词、列类别、OBJECT、mods、恢复、副本、并发、负向、清理、树模型、内存泄漏 | 85 个 CASE ID / 163 个协议轮次 |

## 说明

- 每个模块是一个 `*_skill/` 包，拷到测试机 `/data2/iotdb/rc10_matrix` 即可按 README 直接跑。
- 运行产物（`results/`、`logs/`、`*.out`、`artifacts/`）不提交，见仓库根 `.gitignore`；证据留在测试机。
- 口令不写入仓库，脚本从测试机既有 `conf/test.conf` 读取 `root_pw`。
