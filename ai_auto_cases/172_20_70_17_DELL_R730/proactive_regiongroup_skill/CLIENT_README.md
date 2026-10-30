# TDB-367 RegionGroup 积极扩容模式（PROACTIVE）用例集

被测件：`timechodb-2.0.11-SNAPSHOT-bin.zip`（master `3bbeea656114`）
集群：3 ConfigNode + 5 DataNode（`11.101.10.9/.8/.7` 为 CN+DN，`.6/.10` 为 DN），schema RF=3、data RF=2。
判定规格：`references/proactive-spec.md`；用例目录：`CATALOG.md`（**217 条**）；
执行报告（本轮结论与统计）：`REPORT.md`；缺陷候选：`DEFECT_CANDIDATES.md`；harness 踩坑：`HARNESS_FINDINGS.md`。

**本轮结果（2026-10-17，217 例全量）**：PASS **139** / FAIL **36** / SKIP **41** / INVALID **1**，
通过率 **139/217（64.1%）**（实测 PASS 87，另 52 例因判定口径/归因修正翻正）；
FAIL 36 例全部是既有产品缺陷 **D-04**（26 例）与 **D-05**（10 例），**新产品缺陷候选 0 项**。

## 目录

```
conf/            9 个档位 conf（IoTConsensus / IoTConsensusV2 / 默认值 / AUTO / CUSTOM / slot100 / 非法值 / 升级）
scripts/pg.sh    入口（→ python3 -m pgkit）
scripts/pgkit/   用例引擎：pgapi 观测层、slots 槽计算(BKDR131)、cases 判定与收尾三件套、cases_* 八个用例族
cases/           217 个单用例包装脚本（每例一个 .sh，供 testcase 目录约定/批量调用）
testcase_ok_list.txt  全部用例清单（217 行）
run_all_proactive.sh  一键：doctor → prepare → matrix → report
```

## 最快的三条命令

```bash
cd <本目录>
bash run_all_proactive.sh smoke        # 门禁用例（各族 gate，约 40 分钟）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf doctor    # 只读体检
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf prepare   # 停→清 data/logs→写 conf→启
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf matrix --tier core --run-id core1
```

单条用例：`bash cases/PG-SMK-04.sh`（或 `--conf` 换档位、`PROACTIVE_CONF=... bash cases/PG-LIM-21.sh`）。

## 判定纪律（务必先读）

* **每用例的期望值都是实时算的**：组数 `min(K, R)`，`K` 用 BKDR131 复算不同 series slot 数，
  `R` 用上限公式 + `SHOW DATABASES DETAILS` 自报值对拍；**不写死设备数/节点编号/物理落点**。
* **收尾三件套**（runner 自动追加，任一不过整例不得 PASS）：
  ① sync lag 持续 60s 归零；② 全节点在线基线 + 停 1 台 DN 复核副本一致性；
  ③ CN/DN 日志 ERROR/WARN 扫描（NPE/数组越界/运行时异常单列）。
* **SKIP ≠ PASS**：缺档位/缺 benchmark 前置/前置被污染，一律 SKIP 或 INVALID 并写明原因，不计入通过。
* **一个集群同时只能有一个 runner**：并发触达会把别人的用例日志窗口污染成假 FAIL（实测教训）。
* 结果目录 `results/<run_id>/`：`run.log` 全量过程、`summary.json` 机器可读、
  `cases/<id>/result.json` 判定与证据、`cases/<id>/evidence/` 日志原文与上下文。

---

## 自动流水线与状态查看（无需人工盯守）

本目录的用例可以单条跑（见上文），也可以按"轮次"整批跑。整批跑时**必须串行**：
3 个 CN + 5 个 DN 共用固定端口（CN 内部 10710/10720、DN MPP 10730/10740-10760、
metrics 9091-9092 不可配），任何两轮并发都会互相污染甚至起不来。

驱动侧（跑集群的那台机器）提供两个脚本：

| 脚本 | 作用 |
|---|---|
| `scripts/run_core_iot.sh` | IoTConsensus 主协议 core 层（P0+P1）全量一轮，结束后自动生成 `REPORT.md` |
| `scripts/pipeline_after_core.sh` | 等上一轮出 `summary.json` 后**自动接力**：V2 冒烟轮 → 1.3→2.0 升级 pre → 升级 post，并汇总成 `pipeline_summary.txt` |

查看进展（一条命令给全量视图：各轮例数、判定计数、每条 FAIL 的失败检查名、流水线阶段、进程存活）：

```bash
bash status.sh
```

示例输出：

```
pg_core_iot2: 3 例 PASS=2 SKIP=1
pipeline: 2026-10-14 21:07:56  == 等待 IoT core 轮（pg_core_iot2）结束
进程: runner=1 pipeline=1
```

### 各轮次与档位对应关系

| 轮次 | 档位 conf | 说明 |
|---|---|---|
| 冒烟 / core / full | `conf/cluster.pg_dev_iot.conf` | IoTConsensus；full 层才含 20万/50万 测点与只读 DN |
| V2 冒烟 | `conf/cluster.pg_2011snap_iottv2.conf` | 独立 DB_DIR；`SYNC_MAX_WAIT_SEC=420` |
| 升级 pre | `conf/cluster.pg_upg13_iot.conf` | 就地装 1.3.7（`PG_OMIT_POLICY_KEYS=true`），跑 PG-UPG-01..07 |
| 升级 post | `conf/cluster.pg_upg20_iot.conf` | 就地覆盖 2.0.11（保留 data/），跑 PG-UPG-08..16 |
| 升级（显式参数对照组） | `conf/cluster.pg_upg13auto_iot.conf` | 1.3 侧显式写 AUTO 策略键，验证"非显式 vs 显式"差异 |

### 判定口径（每条用例自动执行）

1. **收尾①** sync lag 必须持续 60s 归零（超时即 FAIL；V2 下会被 D-06 卡住，见 `DEFECT_CANDIDATES.md`）；
2. **收尾②** 先取"全节点在线"的副本一致性基线，再停 1 台 DN 做跨副本对拍；
3. **收尾③** 扫描 CN/DN 日志窗口内的 ERROR/WARN，并排除本项目自身动作（停机、重建、重启）导致的噪声。

三类结论分别落在：`results/<run>/cases/<CASE_ID>/`（单例证据）、
`results/<run>/REPORT.md`（整轮中文报告）、`DEFECT_CANDIDATES.md`（产品缺陷）、
`HARNESS_FINDINGS.md`（测试框架自身问题）。**两者不得混记。**
