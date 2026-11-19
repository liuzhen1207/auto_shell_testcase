# 2.0.13.1 RC3 全量回归报告（2026-11-18）

| 项目 | 内容 |
| --- | --- |
| 版本 | 2.0.13.1 **RC3**，BuildInfo **`ac7f95e`**（源码 HEAD `ac7f95e953`，8 节点一致） |
| 集群 | 3 CN（172.16.2.26/27/28）+ 5 DN（172.16.2.2~6），Schema 3 副本 / Data 2 副本，DataRegion = IoTConsensus V1 |
| 执行时间 | 2026-11-18 11:23 – 19:28（约 8 小时 05 分） |
| 套件 | tree_view_skill / releasenote_skill / auth_skill / lbac_skill |
| 结果目录 | `/data2/auto_test/rc3_regression_20261118_112344` |

## 一、总览

| 套件 | 模式 | 用例 | PASS | FAIL | 已知缺陷 | SKIP |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| tree_view_skill | 普通 | 67 | **63** | **0** | 4（TDB-888） | 0 |
| releasenote_skill | 普通 | 147 | **130** | **0** | 1 | 16 |
| auth_skill | 普通 | 27 | **27** | **0** | 0 | 0 |
| auth_skill | 三权分立 | 34 | **34** | **0** | 0 | 0 |
| lbac_skill | 普通 | 197 | **187** | **0** | 0 | 10 |
| lbac_skill | 三权分立 | 197 | **188** | **0** | 0 | 9 |
| **合计** | — | **669** | **629** | **0** | **5** | **35** |

**结论：RC3 全量回归 0 新增失败**；5 条已知缺陷失败、35 条 SKIP 均为既有条件/限制，与 RC2 基线一致。

## 二、分套件说明

### 2.1 tree_view_skill（67 条，优先执行）

- 结果：**63 PASS / 4 已知失败（TDB-888）/ 0 新增**；
- 执行 11:27 – 12:46（约 79 分钟）；
- 4 条失败均为「改名后视图 TAG 不同步」：TV-080、TV-081、TV-082、TV-088；
- 日志：功能路径（`ViewColumnAutoSyncTrigger`）ERROR **0 条**；6 条用例日志窗口命中 HA 噪声（`CREATE_SCHEMA_REGION`、`UPDATE_REGION_ROUTE_MAP`、`CHANGE_REGION_LEADER`、`Timeout during ...`），归因后 PASS；
- 与 RC2 逐条一致，无回归；
- 已在 PLM 文档 `docs/3653` 追加「RC3 回归结果」章节（标题已改为“测试记录（2.0.13.1 RC2/RC3）”）。

### 2.2 releasenote_skill（147 条）

- 结果：**130 PASS / 0 FAIL / 1 KNOWN / 16 SKIP**；
- KNOWN：RN-111（非法值 5.61 写入 `iotdb-system.properties`，已知问题）；
- 与 RC2 基线一致。

### 2.3 auth_skill

| 模式 | 用例 | 结果 |
| --- | ---: | --- |
| 普通 | 27 | **27 PASS / 0 FAIL** |
| 三权分立 | 34 | **34 PASS / 0 FAIL** |

### 2.4 lbac_skill

| 模式 | 用例 | PASS | FAIL | SKIP | 带 `LOG{}` 标记 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 普通 | 197 | **187** | **0** | 10 | 0 |
| 三权分立 | 197 | **188** | **0** | 9 | 0 |

- 两模式唯一差异 LB-157（仅三权分立执行）；
- 与 RC2/DR2 基线完全相同（普通 187 PASS / 0 FAIL / 10 SKIP；三权分立 188 / 0 / 9）；
- 逐用例日志窗口：**无一带 `LOG{}` 标记**；三权分立轮 `log_scan` 486 行、ERROR 2 条，均落在 HA 重启窗口。

## 三、SKIP 汇总（35 条）

| 套件 | 数量 | 主要类别 |
| --- | ---: | --- |
| lbac_skill 普通 | 10 | 可写视图源不适用（LB-109/122）、TAG/TIME 待确认（LB-143）、语法不支持（LB-144/146）、已替代（LB-154）、仅三权分立（LB-157）、导出/pipe/LOAD 待确认（LB-158~160） |
| lbac_skill 三权分立 | 9 | 同上（LB-157 在三权分立下执行） |
| releasenote_skill | 16 | 版本特性/环境条件不适用（详见 `releasenote.tsv`） |

## 四、本轮发现的工具问题（已修复）

| 问题 | 影响 | 修复 |
| --- | --- | --- |
| `tree_view_skill/tools/suite.sh` 把 `BASE` 硬编码为 `/data2/auto_test/treeview_suite` | 结果落到 runtime 目录，`run_regression.sh` 找不到 → 报告用例数 0 | `BASE` 改为可覆盖；`RESULTS` 支持指定 |
| `run_regression.sh` 调 `classify_run.sh` 时 `$RUN` 为空，退回旧目录 | 归因失败，10 条 FAIL 未分类 | 增加 `RUN` 兜底 + `RESULTS=$B/results` |
| `run_regression.sh` 依赖 `$B/env.sh` 提供 `proto_short` | `proto_short: command not found`，汇总段报错 | 增加 `proto_short` 兜底定义 |

修复后脚本语法检查通过；运行期验证待下次普通模式回归。

## 五、环境状态

- 回归结束时集群处于**三权分立模式**（LBAC 三权分立轮在最后执行）；
- 如需恢复普通模式：`bash /data2/auto_test/lbac_skill/tools/mode_sep.sh off`（或 hard_reset）。

## 六、文件

| 文件 | 内容 |
| --- | --- |
| `tree_view_classified.tsv` / `tree_view_raw.tsv` | 树转表视图（归因后 / 原始） |
| `releasenote.tsv` | 版本回归 147 条 |
| `auth_normal.tsv` / `auth_sep.tsv` | 权限套件两模式 |
| `lbac_normal.tsv` / `lbac_sep.tsv` | LBAC 两模式 197 条 |
| `lbac_sep_log_scan.txt` | LBAC 三权分立轮 CN/DN 日志窗口 |
