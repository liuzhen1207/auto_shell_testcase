# TDB-367 PROACTIVE 回归 —— 交接说明

> 本文档面向"接手继续跑/复核"的人。全部结论的出处：`docs/报告_TDB-367_PROACTIVE回归.md`、
> `DEFECT_CANDIDATES.md`（产品缺陷）、`HARNESS_FINDINGS.md`（测试框架问题）。

## 1. 已交付

* **用例集 216 条**（`PG-REB-08` 与 REB-01 同构，已删除）（8 个用例族 + 手写用例），逐需求点（PLM 360 §3.1–§9）≥2 条覆盖，矩阵见报告 §1。
  注册表 `bash scripts/pg.sh --conf <conf> list-cases`；目录 `CATALOG.md`；客户端机另有对应单例 `.sh`。
* **11 个 conf 档位**：`conf/cluster.pg_{dev,2011snap_iot,2011snap_iottv2,default,auto,custom,slot100,badcase,upg13,upg20,upg13auto}_iot.conf`
  （IoT / IoTConsensusV2 / 默认值与最小数量 / AUTO / CUSTOM / 小 slot 数 / 坏用例对照 / 1.3→2.0 两阶段升级）。
* **判定纪律**：每例固定收尾三件套 —— ① sync lag 持续 60s 归零；② 先取"全节点在线"副本一致性基线，
  再停 1 台 DN 做跨副本对拍；③ 扫 CN/DN 日志 ERROR/WARN（仅"模式 + 本用例动作窗口"双命中才归因自身动作）。
* **证据包**：`results/<run>/cases/<ID>/{actions.log, evidence/, result.json}` + 整轮 `REPORT.md`。

## 2. 已定性的结论（截至 7 例落定，详见报告 §5.8）

* **产品缺陷（保留）**：`D-04` —— **表模型库的 Schema/Data RegionGroup 数被钉在最小值**，
  写 2/3/4 个不同 slot 都不增长（`PG-SMK-05` 四条断言实证）；同源证据指向
  `adjustRegionGroupNum` 内 `getRegionGroupCount` 抛 `DatabaseNotExistsException` 被静默 `continue`，
  上限停留在建库默认最小值；产品自家 IT `IoTDBDatabaseIT:1004` 只触发调整、不断言表库上限。
  另 `D-06`：V2 全新集群 `DataRegion[5]` 的 `syncLag` 恒为 1.0（源码语义已排除"指标口径"解释）。
* **harness 问题（已全部修复并验证）**：`H-08`（分摊库数取树∪表）、`H-09`（收尾②停机动作 +300s 归因窗口）、
  `H-09b`（MPP Source 侧取数失败模式）、`H-10`（组数期望改用产品自报上限 `group_ceiling`，41 处）、
  `H-11`（切回 PROACTIVE 按全量 K 补齐，已升级为显式断言）。
  **安全性质**：`group_ceiling` 只能抬高期望，不会掩盖 D-04 这类"产品给得更少"的真缺陷（附运行反证）。

## 3. 正在跑 / 待跑

| 轮次 | 状态 | 命令 |
|---|---|---|
| IoTConsensus core（P0+P1） | **运行中**（约 17h，~5 分钟/例） | `bash run_core_iot.sh`（已启动；结束自动出 `REPORT.md`） |
| V2 冒烟 | 排队（受 `D-06` 阻塞，功能断言仍会执行留证） | `bash run_v2_smoke.sh` |
| 1.3→2.0 升级 pre/post | 排队 | `conf/cluster.pg_upg13_iot.conf` → `upgrade` → 跑 area=升级 用例 → 换 `pg_upg20_iot.conf` 再 `upgrade` → 再跑 |
| full 层（20万/50万 测点、1DN readonly） | 待跑 | `matrix --tier full` |

**串行约束**：3 CN + 5 DN 共用固定端口（CN 10710/10720、DN 10330/10730/10740-10760、metrics 9091-9092），
**任何两轮并发都会互相污染**。接力脚本 `pipeline_after_core.sh` 已按此顺序自动串起来（含最终汇总）。

## 4. 接手后建议的下一步

1. `bash status.sh` 看进度；`bash classify_fails.sh <run-id>` 一键列出所有 FAIL 的检查名/实测值/日志首命中。
2. **复跑 smoke 验收**修正效果：期望 `PG-SMK-04`/`PG-SMK-06` 转 **PASS**、`PG-SMK-05` **只剩 D-04 的 4 条组数断言**、
   `D-05` 等真实缺陷仍在（若真缺陷一起消失，说明改口径改坏了，必须回滚重做）。
3. 每有一个新 FAIL，先过 `classify_fails.sh`，再按 `DEFECT_CANDIDATES.md` / `HARNESS_FINDINGS.md` 定性，
   **两者不得混记**；定性前的条目一律写成"候选/待核"。
4. 全部轮次结束后 `FINAL_SUMMARY.md` 会自动生成（也可手动 `bash scripts/consolidate.sh <results根>`），
   把合计与新增条目补进报告 §5.4/§5.8 后重新同步交付物。

## 5. 环境限制（不是产品行为，勿记为缺陷）

* 第二块盘实际是**根盘**：`/dev/sda1`(938G,`/`) 与 `/dev/sdb1`(19T,`/data`)；`/ssd_data` 无独立挂载点、
  落在 sda1。kit 写的两个 `dn_data_dirs` 正好跨这两块物理盘（所有用例都在双盘条件下执行），
  但第二块盘容量有限，大规模档位需留意 `/` 余量。
* 节点间不能互相 ssh；客户端机 `11.101.10.11` 仅能通过 `SSH_ASKPASS` 方式访问。
* 默认口径是"**每轮**干净集群 + **每例**清库"；需要字面"每例干净集群"时用
  `bash scripts/run_strict_percase.sh <conf> [case-id ...]`（代价 5~10×）。
