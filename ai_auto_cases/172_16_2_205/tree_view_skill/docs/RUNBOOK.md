# 树转表视图 auto_sync_schema 回归套件（runbook）

本目录是 TDB-343「树转表视图自动识别树模型新增测点」的回归测试套件，可在**任意新 build** 上一条命令跑完：部署 → 激活校验 → 清库重建 → 49 条用例 → 分类归因 → 汇总。

## 一条命令跑一个版本

```bash
# 版本已安装在 /data{,1,2}/iotdb/<build> 下
ssh root@172.16.2.205 'bash /data2/auto_test/treeview_suite/run_regression.sh master_1026_dc11a35 IoTConsensusV2 TDB-343'

# 版本还没部署：给包路径，脚本会先部署（保留原集群激活身份再覆盖二进制）
ssh root@172.16.2.205 'NEW=master_XXXX_yyyyyyy PKG_ZIP=/data2/iotdb/master_XXXX_yyyyyyy/timechodb-*-bin.zip \
  bash /data2/auto_test/treeview_suite/run_regression.sh master_XXXX_yyyyyyy IoTConsensus TDB-343'
```

参数：`<build_dir> [protocol] [plm_item]`；协议取值 `IoTConsensus` / `IoTConsensusV2`。

产物落在 `results/REGRESSION_<build>_<protocol>_<时间戳>/`：

| 文件 | 内容 |
| --- | --- |
| `summary.md` | 通过数、断言失败、功能路径日志缺陷、HA 噪声、总耗时、失败清单 |
| `results.tsv` / `classified.tsv` | 逐用例结果与归因（断言 / 功能路径 ERROR / HA 噪声） |
| `regression.log`、`reset.log`、`suite.log`、`classify.log` | 各阶段日志 |
| `show_cluster.txt` | 运行前 8 节点版本与激活状态快照 |

退出码：0 全通过；10 有断言失败；11 有功能路径日志缺陷；3/4/5 部署、集群就绪、激活不通过。

## 每个版本需要改什么

| 项 | 位置 | 说明 |
| --- | --- | --- |
| build 目录名 | 命令参数（或 `env.sh` 的 `NEW` 默认值） | `/data{,1,2}/iotdb/<build>` |
| 协议 | 命令参数 | 会改 `data_region_consensus_protocol_class` 并清库 |
| PLM 工作项 | 命令参数 | 写进 `summary.md` 便于追溯 |
| 拓扑/账号 | `env.sh`（`CN_LIST`/`DN_LIST`/`PW`） | 默认 3C5D、172.16.2.26-28 + .2-.6 |
| 需求/设计文档 | `records/` | 换版本时同步 PLM doc 与开发自测 IT |

## 环境前提

1. 3C5D 集群、SchemaRegion 3 副本 / DataRegion 2 副本；
2. **可激活**：部署沿用旧集群的 `activation/`（license 绑定集群身份，全新安装会激活失败）；
3. 节点有 `iptables`（TV-060 的 DN 隔离用）与 JDK17；
4. 172.16.2.205 能免密 ssh 到 8 个节点。

## 套件结构

| 路径 | 内容 |
| --- | --- |
| `run_regression.sh` | 一条命令入口 |
| `env.sh` | 全部可覆盖参数 |
| `deploy_build.sh` | 部署（保留激活身份、覆盖 lib/sbin/tools/conf、写 properties） |
| `hard_reset.sh` | 杀重复进程、清 data/logs、按序启动、等 8 节点就绪 |
| `suite.sh` / `lib.sh` | 用例执行器与公共断言、sync lag、副本一致性、日志增量、DN/CN 启停 |
| `cases/g1..g9` | 67 条用例（属性语法 / 补列入口 / 冲突类型 / 查询与生命周期 / DDL 组合 / 高可用 / DN 隔离 / 序列改名×视图 / LOAD TSFILE×视图） |
| `classify_run.sh` | 归因：断言失败 / `ViewColumnAutoSyncTrigger` 功能路径 ERROR / HA 噪声 |
| `records/` | 需求（PLM doc 90）、技术设计（doc 913）、开发自测 IT、关键源码 |

## 已知结论（2026-10-28, dc11a35）

1. 功能断言全通过；两种协议行为一致；
2. 缺陷：自动补列路径在“列已存在”时打 ERROR（`552 Column already exist` + `305 Internal server error`），两协议均复现；
3. `ALTER VIEW ... ADD COLUMN o1 OBJECT FIELD` 在树模型视图上被接受但恒为 null，口径待研发确认；
4. DN 隔离（元数据租约 535/536）时创建序列失败，恢复后重试可正常补列；
5. 序列改名（`ALTER TIMESERIES ... RENAME TO`）后视图不同步：TAG 返回旧设备名、跨库改名后目标库视图 0 行（TDB-888；改名组用例 TV-080~089）。
