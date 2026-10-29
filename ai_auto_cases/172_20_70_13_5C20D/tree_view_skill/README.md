# tree_view_skill —— 树转表视图（Tree View）自动化回归

被测特性：图模型 → 表模型的**树转表视图**，重点覆盖 V2.0.13.1 的
`auto_sync_schema`（自动检测新增测点并扩列）以及 **Pipe 数据同步**场景。

| 项 | 值 |
|---|---|
| 版本 | `master_1026_dc11a35`（`2.0.11-SNAPSHOT`，BuildInfo **`dc11a35`**） |
| 环境 | 5 CN + 20 DN（172.20.70.100–119），SR3 / DR3，`IoTConsensus` |
| Pipe 场景 | 20 节点拆两套：发送端 .100–.109 / 接收端 .110–.119，各 **5CN+10DN、SR5/DR3** |
| 用例数 | **55 条** = 单集群 46（BASE 15 / SYNC 16 / HA 3 / LEAK 1 / REF 6 / REPRO 5）+ Pipe 9 |
| 需求来源 | docx《树转表——需求分析》/ PLM doc 90、doc 913 / TDB-343 |

## 目录

| 路径 | 说明 |
|---|---|
| `scripts/pgkit/` | 用例与 harness（`cases_treeview.py`、`cases_tv_repro.py`、`cases_tv_pipe.py` + 通用执行/校验/报告） |
| `cases/MANIFEST.md5` | **用例模块清单**（preflight 用；用例源码就在 `scripts/pgkit/cases_*.py`） |
| `MANIFEST.md5` | 本 skill 全量文件清单（可用于部署后自检） |
| `conf/` | 档位配置：`cluster.treeview_5c20d.conf`（单集群 5C20D）、`cluster.pipe_sender.conf` / `cluster.pipe_receiver.conf`（pipe 双集群）、`nodes*.conf` |
| `docs/` | 结果报告、需求覆盖矩阵、缺陷报告、回归入口说明 |
| `references/` | 语法/语义速查 |
| 根目录 `*.sh` | 执行入口（见下） |

## 运行入口

| 脚本 | 用途 |
|---|---|
| `regress_all.sh` | **总入口**：单集群 46 条 → 停干净两套 → pipe 组 9 条 → 停干净两套 |
| `run_case_clean.sh <conf> <prefix> <case>` | 单条单集群用例（干净集群：停 25 节点→清 data/logs→起→跑→收尾三件套） |
| `run_pipe_case.sh <sender-conf> <prefix> <case>` | 单条 pipe 用例（**两端都 prepare**） |
| `run_pipe_group.sh` | pipe 组（组前后各 teardown 两端） |
| `queue_treeview*.sh` / `queue_pipe*.sh` / `queue_repro*.sh` | 分批串行队列 |
| `aggregate_tv.py` | 结果汇总（按 result.json 修改时间取最新一轮） |
| `probe_conflict.sh` / `pipe_probe*.sh` | 手工探针（类型冲突语义、pipe inclusion 语义） |

## 每条用例固定的收尾三件套

1. **syncLag 归 0**（有界等待，超时 FAIL）；
2. **副本一致性**：全在线查询结果为基线 → **一次性停 2 台 DN** → 与基线逐字比对；
3. **CN/DN ERROR·WARN 扫描**：单集群 25 节点；**pipe 用例为两端共 30 节点**
   （`LOG_SCAN_EXTRA_CONFS=conf/cluster.pipe_receiver.conf`，接收端命中带 `R:` 前缀）。

FAIL/无结果时自动把该用例的 **CN+DN 日志**打包进 `results/<run>/cases/<CASE>/evidence/logs/`
（pipe 用例两端都备）。

## 结果（最新一轮）

- 单集群 41 条：**35 PASS / 6 FAIL**（5 条归属 TDB-890、1 条归属 TV-D3，均为日志类）；
- Pipe 9 条：**6 PASS / 3 FAIL**（2 条 TDB-890、1 条 TV-D6），**功能断言 9/9 全过**；
- 详见 `docs/REPORT_TREEVIEW_FINAL.md`、`docs/REPORT_PIPE.md`。

## 已提交缺陷

| 编号 | 问题 | 状态 |
|---|---|---|
| TDB-890 | auto_sync 补列已存在时报 ERROR（552/305），功能正确 | 已录 PLM（陈耀斌） |
| TDB-894 | CREATE VIEW 预期失败（类型冲突）被 CN 记 ERROR | 已录 PLM（陈耀斌 / V2.0.13.1） |
| TV-D3 / TV-D4 / TV-D6 | 日志级别类 | 见 `docs/`，D3=TDB-894 |
| ~~D2~~ / ~~D5~~ | D2 研发确认符合预期；D5 测试并发误报 | 已关闭 |

## 部署前提

```bash
# 测试机上（默认装到 /data/iotdb/master_1026_dc11a35）
cd tree_view_skill
bash scripts/pg.sh --conf conf/cluster.treeview_5c20d.conf deploy --clean
bash scripts/pg.sh --conf conf/cluster.treeview_5c20d.conf selftest
```

> 依赖：driver 机（本仓库 172.20.70.13 一类的跳板机）可免密 ssh 到 25 个节点；
> 部署包 `timechodb-2.0.11-SNAPSHOT-bin.zip` 放在 `DEPLOY_TARBALL` 指定位置。
