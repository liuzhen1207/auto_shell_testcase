# TDB-367「RegionGroup 积极扩容（PROACTIVE）」回归 —— 本轮执行报告

> **本文件是本轮（2026-10-16 ~ 10-17，217 例全量）的执行结论交付入口。**
>
> * **判决依据（权威、只读）**：`../TRIAGE_full_round.md`（618 行，下称 TRIAGE）。本文每条结论都指到它的
>   小节 / 行号，或指到 `results/<run>/cases/<ID>/` 下的 `result.json`（`checks[i].detail`）与 `actions.log`。
> * **逐例证据**：`../results/pg_full_iot_final/cases/<ID>/`（63 例）+ `../results/pg_iot_resume/cases/<ID>/`（154 例）。
> * **历史轮次**：2026-10-14 的完整过程记录（需求点覆盖矩阵、§5 分轮纪要、§6 环境限制）在
>   `docs/报告_TDB-367_PROACTIVE回归.md`，本轮**未改动、未删除**，本文只在需要处引用它。
> * **范围**：本轮只做**分诊与结论收口** —— 未改集群、未重跑用例、未改 harness 代码（TRIAGE:5）。

---

## 1 最终结论（一屏）

### 1.1 用例级最终判定

| 轮次 | 执行例数 | PASS | FAIL | SKIP | INVALID |
|---|---|---|---|---|---|
| `pg_full_iot_final`（2026-10-16 16:06 → 19:50，暂停于 `PG-DEV-17`） | 63 | 41 | 14 | 8 | 0 |
| `pg_iot_resume`（2026-10-16 20:49 → 2026-10-17 07:56） | 154 | 46 | 75 | 33 | 0 |
| **实测合计** | **217** | **87** | **89** | **41** | **0** |
| **按本轮分诊口径修正后** | **217** | **139** | **36** | **41** | **1** |
| **harness 修复复跑后（2026-10-20 现值）** | **217** | **138** | **37** | **41** | **1** |

* **通过率：87/217（40.1%）→ 139/217（64.1%）**
* **harness 修复复跑（2026-10-20）：12 个受影响用例 → 11 PASS / 1 FAIL**，唯一残余 `PG-HA-10`（`AbstractDriverThread:123 - [ExecuteFailed]`，干净环境 3 轮停机与 1.3→2.0 升级均未复现，故保持 FAIL、不计为通过）；据此现值 **138 PASS / 37 FAIL**（37 = D-04 26 + D-05 10 + HA-10 1）。
* 本轮新增口径：H-33（副本先归一化到 IP 再比较）、H-34（RF=2 掉单副本转 readonly 属正确降级）、H-35（组数上限一律取产品自报 `Max*RegionGroupNum`）、H-36（升级族日志窗口按版本横幅分段）。（分母取全部 217 例；SKIP 计入分母、不计为通过）。
* 37 个 FAIL = **既有产品缺陷 36 例**（D-04 26 例、D-05 10 例）+ **1 例 `PG-HA-10` 日志签名**（干净环境未复现，按纪律不归因、不计为通过），**新产品功能缺陷候选 0 项**。
* 52 例 FAIL 经判定口径 / 归因 / 用例实现修正后翻为 PASS（清单见 §4.2）。
* 1 例 INVALID：`PG-HA-01`（收尾① 采样面失效，`last samples: []`）。

### 1.1.1 2026-10-20 实锤更新（干净 3C5D / 2.0.11）

重新部署并激活干净 3C5D 集群做了两个决定性实验（`results/exp_d04_d05_1020/EVIDENCE.md`）：

* **D-04 已确证，且根因与旧文档不同**：表库 `pg` 与树库 `root.pg` 在
  `ClusterSchemaInfo.enrichSchemaMap()` 的 Map 里 key 相同（`path.getFullPath()`，`:679-693`），
  表库条目被树库覆盖 ⇒ 表库**永不参与** `adjustMaxRegionGroupNum()`，上限停在 (1, 2)，
  且 `databaseNum` 每冲突一次少计 1。A/B 在 1 秒内完成：
  表库 `solo_tab`（无同名树库）被正常调整到 1/12 → 建 `root.solo_tab` 后从日志消失。
  **触发条件**：树库 `root.x` 与表库 `x` 并存。原"`DatabaseNotExistsException` 被跳过"的解释**作废**。
* **D-05 撤销**：2.x `count(*)` = "FROM 路径下各测点的行数"，路径落到测点即无子测点 ⇒ 空集属语义一致；
  已新增 `PgApi.count_series()` 并替换 20 处调用（H-37）。10 个用例的 FAIL 是 harness 口径问题，不是产品缺陷。

因此现值口径修正为：**37 FAIL = 26 D-04（产品缺陷，已确证）+ 10 例 harness 口径（H-37，已修待复跑）+ 1 HA-10（不归因）**。
D-04 提单要素见 `DEFECT_CANDIDATES.md §D-04 实锤实验`。

### 1.1.2 2026-10-21 master `029a333` 全量 217 例结果

| 口径 | PASS | FAIL | SKIP | 通过率 |
|---|---|---|---|---|
| 首轮实测 | 149 | 27 | 41 | 68.7% |
| **修正后（H-38 复跑 + HA-01 噪声归因复跑）** | **151** | **23** | **43** | **69.6%** |

* 23 个 FAIL = **22 例 D-04**（表库同名冲突，`029a333` 仍未修复）+ **1 例 `PG-HA-09`**
  （DN 启动期配置自检 WARN，非功能缺陷）；
* 上一轮 10 例"测点级 count 空集"**全部消失**（H-37 修复生效）；HA-10 **0 复现**；
* 扣除 D-04 后功能通过率 = **174/195 = 89.2%**；
* 详细报告：`MASTER_029A333_全量回归.md`；原始结果：`results/pg_master_1020/`。

### 1.2 定性汇总（用例数 / 失败 check 数）

| 结论 | 用例数 | 失败 check |
|---|---|---|
| **产品缺陷，维持 FAIL** | **36** | **63** |
| ├ 既有 **D-04**：表模型上限/组数钉死在下限（1 / 2） | 26 | 53 |
| └ 既有 **D-05**：测点级 `count(*)` 返回空集 | 10 | 10 |
| **判据 / 环境 / 归因修正后 PASS** | **52** | **147** |
| ├ **H-19**：实测 > 源码公式即判失败（产品上限是每库单调存量） | 17 | 69 |
| ├ **H-22b**：`drop database` 后 `show databases details` 返回 `-1` 被判失败 | 1 | 4 |
| ├ **H-26/27/28**：用例期望值 / 前置 / 辅助解析缺陷 | 22 | 37 |
| └ **收尾③ 日志归因**：命中均可追到 harness 动作（H-23…H-27） | 37 | 37 |
| **INVALID**：判据不可评估（指标采样面失效） | 1 | 1 |
| **新产品缺陷候选** | **0** | **0** |
| **合计** | **217（89 FAIL + 41 SKIP + 87 PASS）** | **211** |

> 子行的用例数按"含该定性 check 的用例数"统计，**彼此可重叠**（如 `PG-LIM-06` 同时计入 H-19 与日志类），
> 总数以 **36 + 52 + 1 = 89** 个 FAIL、**63 + 147 + 1 = 211** 个失败 check 为准（TRIAGE:24、§2.2）。

### 1.3 失败 check 的机器核对

两个 run 的 `result.json` 中 `ok=false` 的 check 合计 **211** 个，与 TRIAGE §2.2 逐项相加一致
（53 D-04 + 10 D-05 + 69 H-19 + 4 H-22b + 37 H-26/27/28 + 37 日志 + 1 INVALID）。

---

## 2 两轮执行说明（为什么是 63 + 154）

| 项 | `pg_full_iot_final`（全量轮） | `pg_iot_resume`（续跑轮） |
|---|---|---|
| 起点 | 2026-10-16 16:06:04（`run.log:1`：`running 217 case(s)`） | 2026-10-16 20:49:50（`run.log:1`：`running 154 case(s)`） |
| 终点 | 2026-10-16 19:50 暂停（`full_run_paused.txt`：`done=63 pass=41 fail=14 skip=8`） | 2026-10-17 07:56:25 写出 `report written` |
| 落定例数（有 `result.json`） | 63 | 154 |
| PASS / FAIL / SKIP | 41 / 14 / 8 | 46 / 75 / 33 |
| 共识协议 / 版本 | IoTConsensus / 2.0.11-SNAPSHOT（`3bbeea656114`），3 CN + 5 DN，schemaRF=3、dataRF=2 | 同左（同一集群、同一 conf 档位） |
| 扩容参数 | `schema_region_per_data_node=3`、`data_region_per_data_node=0`、`series_slot_num=1000`、`time_partition_interval=604800000` | 同左 |

* 全量轮跑到 `PG-DEV-17` 时被暂停（该例目录 `cases/PG-DEV-17/` **无 `result.json`**），
  resume 轮**从 `PG-DEV-17` 起跑**并补齐其余 154 例。
* 已核验：两轮 `result.json` 的用例集合**交集为空**、**并集 = 217**，即 217 例各被执行恰好一次，无重复计数。
* 两轮之间 `cases.py` 有改动（`mtime 2026-10-16 20:03:55`，补 `import re`），但**本轮未重跑、未改代码**；
  该事实及其风险由 H-30 登记，`OBS-06/07/08` 的三个 `NameError` 因此已不复现（仍需重跑验证，见 §4.1 的 H-26/27/28 一行）。

---

## 3 失败项（36 例）：只有两个既有产品缺陷

### 3.1 D-04 表模型上限/组数钉死在下限 —— 26 例 / 53 check（维持 FAIL）

**共同签名**：同条件树库 `公式={SCHEMA:3, DATA:30}`，表库 `实测={SCHEMA:1, DATA:2}`；
或表库写 N 个 slot 后组数停在 2 而不是 `min(K, R)`。树模型在同一轮、同一"参与分摊库数"下**全部正确**
（TRIAGE §4.1:225-226、§3:110）。逐例失败 check：

| # | 用例 | run | 失败 check（`checks[i]`） | 实测 vs 期望（`detail` 要点） |
|---|---|---|---|---|
| 1 | `PG-DEV-16` | full | `[3]` | Data 组数 **2** vs 期望 **3**（库详情=2、区域去重=2） |
| 2 | `PG-LIM-21` | full | `[2]` `[3]` `[4]` | 表库上限 触发前=(1,2)、**主动触发后仍=(1,2)**、公式=(2,15)；写 4 slot 组数 **2** vs 期望 **4** |
| 3 | `PG-MSR-18` | full | `[0]` | 实测 `{'DATA':2}` vs 公式 `{'SCHEMA':1,'DATA':12}` |
| 4 | `PG-MSR-20` | full | `[0]` | 实测 `{'DATA':2}` vs 公式 `{'SCHEMA':1,'DATA':12}` |
| 5 | `PG-SMK-05` | full | `[2]` `[4]` `[5]` `[6]` `[7]` | Schema **1** vs **2**；Data **2** vs **3** / **4** |
| 6 | `PG-HA-06` | resume | `[1]` `[2]` | 停机期间 Schema 组数 **1** vs 期望 **3** |
| 7 | `PG-HA-12` | resume | `[1]` `[2]` `[5]` | 停机期间写 **5 个 slot** 后 Data 组数 **2** vs 期望 **5** |
| 8 | `PG-LIM-02` | resume | `[0]` `[1]` `[4]` `[5]` `[6]` `[7]` | SCHEMA **1** vs 公式 **3**；DATA **2** vs 公式 **30**（写入 1 slot 后同值） |
| 9 | `PG-LIM-04` | resume | `[0]` `[1]` `[2]` `[3]` | 写满 33 slot：SCHEMA **1** vs **3**、DATA **2** vs **30**；达上限后再写仍同值 |
| 10 | `PG-LIM-09` | resume | `[1]` | SCHEMA **1** vs 公式 **3** |
| 11 | `PG-LIM-10` | resume | `[1]` | SCHEMA **1** vs 公式 **3**（`[6]` 属 H-27，见 §4.1） |
| 12 | `PG-LIM-13` | resume | `[2]` `[3]` `[6]` | 表库 SCHEMA **1** vs **3**、DATA **2** vs **30**；两库同口径下 60 vs 2 |
| 13 | `PG-LIM-17` | resume | `[1]` | SCHEMA **1** vs 公式 **3** |
| 14 | `PG-MSR-02` | resume | `[0]` | 实测 `{'SCHEMA':1,'DATA':2}` vs 公式 `{'SCHEMA':3,'DATA':30}` |
| 15 | `PG-MSR-04` | resume | `[0]` | 同上签名 |
| 16 | `PG-MSR-06` | resume | `[0]` | 同上签名 |
| 17 | `PG-MSR-08` | resume | `[0]` | 同上签名 |
| 18 | `PG-MSR-10` | resume | `[0]` | 同上签名 |
| 19 | `PG-MSR-12` | resume | `[0]` | 同上签名 |
| 20 | `PG-MSR-14` | resume | `[0]` | 同上签名 |
| 21 | `PG-RCV-04` | resume | `[0]` `[1]` `[4]` `[5]` | CN 重启**前后**均 SCHEMA **1** vs **3**、DATA **2** vs **30** |
| 22 | `PG-RCV-06` | resume | `[2]` `[9]` | 表库 Schema 组数 **1** vs 期望 **2**（重启前 / 重启后同值） |
| 23 | `PG-REB-11` | resume | `[6]` `[7]` `[9]` `[12]` `[13]` | 表库写 **5 个 slot** 后 Data 组数 **2** vs 期望 **5**；tree=5、table=2 |
| 24 | `PG-TIME-02` | resume | `[0]` | 实测 `{'SCHEMA':1,'DATA':2}` vs 公式 `{'SCHEMA':3,'DATA':30}` |
| 25 | `PG-TIME-05` | resume | `[0]` | 同上签名 |
| 26 | `PG-TIME-11` | resume | `[0]` | 同上签名 |

小计 **53** check（行内 check 数相加 = 53；逐行数据取自 `TRIAGE_full_round.md` §4.1 表 227–254 行，`checks[i]` 与 `detail` 可在对应 `result.json` 复核）。D-04 是**唯一**能同时解释"表库恒 1/2""树库同条件正常"
"热加载 / 换策略 / 重启后仍 1/2"三种现象的共同成因；表模型 53 个 check **无第二种成因**（TRIAGE:110、:256）。
补强证据与机制线索见 `DEFECT_CANDIDATES.md` D-04 的"本轮补强证据"小节。

### 3.2 D-05 测点级 `count(*)` 返回空集 —— 10 例 / 10 check（维持 FAIL，本轮确证）

形状固定：`select count(*) from <db>.<device>.<measurement>` → `Empty set`，`count_rows` 取不到行返回 `-1`
（`scripts/pgkit/pgapi.py:444-453` **只在结果集为空时**返回 `-1`），而同一路径 `select <m>` 有数据、
设备级 `count(*)` 正常（TRIAGE §4.2:258-291）。

| # | 用例 | run | 失败 check（`checks[i]`） | 实测 vs 期望 |
|---|---|---|---|---|
| 1 | `PG-MSR-01` | resume | `[8]` 行数 = 1 | **-1** vs **1** |
| 2 | `PG-MSR-03` | resume | `[9]` 行数 = 3 | **-1** vs **3** |
| 3 | `PG-MSR-13` | resume | `[9]` 首个设备行数 = 1 | **-1** vs **1** |
| 4 | `PG-MSR-16` | resume | `[11]` 行数 = 4 | **-1** vs **4** |
| 5 | `PG-TIME-01` | resume | `[9]` 行数 = 3 | **-1** vs **3** |
| 6 | `PG-TIME-03` | resume | `[12]` 行数 = 4 | **-1** vs **4** |
| 7 | `PG-TIME-04` | resume | `[12]` 行数 = 6 | **-1** vs **6** |
| 8 | `PG-TIME-08` | resume | `[10]` 行数 = 5（3 首次 + 2 追加） | **-1** vs **2** |
| 9 | `PG-TIME-09` | resume | `[10]` 行数 = 5 | **-1** vs **5** |
| 10 | `PG-TIME-12` | resume | `[107]` 行数 = 100 | **-1** vs **100** |

小计 **10** check（逐行数据取自 `TRIAGE_full_round.md` §4.2 表 278–289 行，实测值均为 `checks[i].detail` 的 `-1`）。决定性对照、最小复现与"10/10 空集"的机器核对见 `DEFECT_CANDIDATES.md` D-05
（已升级为**已确证 P1**）。全量轮该形状 **0 次查询**，因此"全量轮没报"不能用来否定本缺陷。

---

## 4 判定口径修正：52 例由 FAIL 翻为 PASS（147 check）

### 4.1 修正了什么（四类，均为 harness / 口径问题，不是产品问题）

| 类 | 规则 | 例数 | check | 依据（TRIAGE） |
|---|---|---|---|---|
| **H-19** | 产品为每库保留**单调不减的历史上限**，`实测 > 源码公式` 是预期；只有 `实测 < 公式` 才算失败 | 17 | 69 | §1.2:54、§4.3:293-317、§6:526 |
| **H-22b** | `drop database` 后 `show databases details` 返回 `-1`、区域去重 0 是**正确结果**；把 `-1` 判失败是 harness | 1 | 4 | §1.2:55、§4.4:319-328 |
| **H-26/27/28** | 用例自身的辅助解析缺陷（`count_rows` 只取首列、`_replica_rows` 缺 `raw` 键、`_effective_settings` 依赖 `show configuration`）、期望值/状态建模错（硬编码显式上限、CUSTOM 语义、双写记账、简化公式…）、前置缺失/断言矛盾（未建表、`re` 未 import、非法建库、缺授权、自相矛盾） | 22 | 37 | §4.5:330-357、§5 H-26/27/28 |
| **收尾③ 日志归因** | 命中逐行读：能指到 harness 动作（建库 / 停节点 / `set configuration` / 删库 / 只读 / 重启）即归因；归因器缺陷为 H-23（跨用例窗口死代码 3 例）、H-24（正则表漏 6 族 18 例）、H-25（窗口 pad 太小 15 例），另有 1 例是用例自写过期数据（`TTL-02`） | 37 | 37 | §4.6:359-406、§5 H-23/24/25 |

> 归因类合计 37 例（H-23 3 例 + H-24 18 例 + H-25 15 例 + `TTL-02` 1 例），
> **均可在 `run.log` 里找到同一用例 5 分钟内的 `[harness 动作]` 锚点**（TRIAGE:112），
> 因此"产品噪声大"不成立，问题是归因器覆盖面与窗口（详见 `HARNESS_FINDINGS.md` H-23…H-25）。
>
> **标签口径注明**：`PG-HA-05` 在 TRIAGE §4.0 与附录 A 中写作 `H-19+LOG(harness)`，但它的 2 个失败 check
> 在 TRIAGE §4.5 被归入"期望公式漏 `minNum` 项"，并已计入本行 **H-26/27/28 的 37 check**；而
> **H-19 的 17 例 / 69 check** 与 TRIAGE §4.3 表逐行一致（该表不含 `PG-HA-05`）。两处标签不一致属 TRIAGE
> 内部口径差异，本文用例数/check 数以 **17 / 69** 为准（若按 §4.0 标签计，H-19 会是 18 例）。

### 4.2 翻正清单（52 例，与 TRIAGE 附录 A 逐行一致）

| # | 用例 | run | 定性 | # | 用例 | run | 定性 |
|---|---|---|---|---|---|---|---|
| 1 | `PG-DEV-12` | full | 日志归因 | 27 | `PG-LIM-11` | resume | H-19 + 日志 |
| 2 | `PG-DEV-15` | full | H-28 | 28 | `PG-LIM-12` | resume | H-19 |
| 3 | `PG-EMPTY-10` | full | H-22b | 29 | `PG-LIM-15` | resume | H-27 + 日志 |
| 4 | `PG-HA-13` | full | H-28 + 日志 | 30 | `PG-LIM-16` | resume | H-19 |
| 5 | `PG-HA-14` | full | 日志归因 | 31 | `PG-LIM-18` | resume | H-19 |
| 6 | `PG-MIN-06` | full | H-27 | 32 | `PG-LIM-20` | resume | H-19 |
| 7 | `PG-OBS-06` | full | H-28 | 33 | `PG-OBS-02` | resume | 日志归因 |
| 8 | `PG-OBS-07` | full | H-28 | 34 | `PG-PRV-07` | resume | H-28 |
| 9 | `PG-OBS-08` | full | H-28 | 35 | `PG-RCV-01` | resume | 日志归因 |
| 10 | `PG-DEV-18` | resume | 日志归因 | 36 | `PG-RCV-02` | resume | 日志归因 |
| 11 | `PG-DEV-19` | resume | 日志归因 | 37 | `PG-RCV-07` | resume | 日志归因 |
| 12 | `PG-DIS-02` | resume | H-27 | 38 | `PG-REB-13` | resume | H-27 |
| 13 | `PG-HA-02` | resume | H-26 | 39 | `PG-RST-04` | resume | H-26 |
| 14 | `PG-HA-03` | resume | 日志归因 | 40 | `PG-SWCH-03` | resume | H-27 |
| 15 | `PG-HA-04` | resume | H-26 | 41 | `PG-SWCH-04` | resume | H-27 |
| 16 | `PG-HA-05` | resume | H-19 + 日志 | 42 | `PG-SWCH-05` | resume | H-27 + 日志 |
| 17 | `PG-HA-07` | resume | 日志归因 | 43 | `PG-SWCH-06` | resume | H-27 + 日志 |
| 18 | `PG-HA-09` | resume | H-28 | 44 | `PG-SWCH-11` | resume | H-27 |
| 19 | `PG-HA-10` | resume | 日志归因 | 45 | `PG-SYS-01` | resume | H-19 |
| 20 | `PG-HA-11` | resume | 日志归因 | 46 | `PG-SYS-02` | resume | H-19 |
| 21 | `PG-LIM-01` | resume | H-19 | 47 | `PG-SYS-06` | resume | 日志归因 |
| 22 | `PG-LIM-03` | resume | H-19 | 48 | `PG-TIME-07` | resume | 日志归因 |
| 23 | `PG-LIM-05` | resume | H-19 | 49 | `PG-TIME-10` | resume | H-19 |
| 24 | `PG-LIM-06` | resume | H-19 + 日志 | 50 | `PG-TTL-02` | resume | 日志归因（用例自写过期数据） |
| 25 | `PG-LIM-07` | resume | H-19 + 日志 | 51 | `PG-TTL-03` | resume | 日志归因 |
| 26 | `PG-LIM-08` | resume | H-19 + 日志 | 52 | `PG-TTL-07` | resume | H-26 |

合计 **52** 例（full 9 例 + resume 43 例）。加上这 52 例，通过率由 87/217（40.1%）变为 139/217（64.1%）。

> **H-19 的 69 个 check 内部结构**：68 条为 `实测 > 公式`（每库单调存量），1 条为 `实测 < 公式`
> —— `PG-LIM-07[8]` 的瞬时读（该步读到 5，紧接的"恢复 data=0 后"立刻读到 60，属产品异步调整、
> 用例缺等待），两类都不构成产品缺陷（TRIAGE:295、:317）。

---

## 5 INVALID（1 例 / 1 check）

| 用例 | run | 失败 check | `detail` 原文 | 为什么 INVALID |
|---|---|---|---|---|
| `PG-HA-01` | resume | `收尾① sync lag 必须等到归 0（超时即 FAIL）` | `worst=1.0 detail=syncLag did not stay at 0 for 60s within 1800s (last samples: [])` | `last samples: []` ⇒ 30 分钟窗口**一个样本都没采到**，判据不可评估。`run.log` 显示 03:47:31 采到过一次 `instances=11 worst=1.0`，此后每 12–16s 都是 `sync lag: no series yet (empty result)` 直到 1800s 超时；同一 run 其它用例共 704 次成功采样 ⇒ 是本用例窗口内的采样面失效（刚停/启过 DN `11.101.10.9`），不是全局抓取面故障。产品侧同期写入、查询、`收尾②` 对拍全部通过（TRIAGE §4.7:408-412）。 |

> 该例的 `收尾③` 日志命中（37 行）已归因到 harness 动作（H-24），因此本轮的 INVALID **只由收尾①** 造成。
> 归因器在"采样面失效"时不 fail-fast 的缺陷登记为 H-29；修复后应直接判 INVALID 而不是烧满 1800s。

---

## 6 SKIP（41 例）原因分布

40 个 SKIP 与"档位缺失 / 前置不可构造"相关，1 个是刻意的用例合并；**SKIP ≠ PASS，且全部计入 217 分母**。

| 类别 | 例数 | 用例 | 原因（`result.json.skipped` 原文要点） |
|---|---|---|---|
| 升级族档位未启用 | 16 | `PG-UPG-01`…`PG-UPG-16` | `PG_UPG_PHASE` 为空，需 `<pre\|post>` 档位 |
| 需专用 conf 档位 / 重部署 | 6 | `PG-DFT-01/02`（默认值路径）、`PG-DFT-03/04`（AUTO / CUSTOM）、`PG-SMK-01`、`PG-LIM-19`（`series_slot_num=100`） | 本轮 conf 显式 `PROACTIVE`；`series_slot_num` 首次启动确定、不可热加载 |
| Disabled 布局不可构造 | 6 | `PG-DIS-01/03/04/05/06`、`PG-RCV-05` | 停 DN 后未形成"部分组 Disabled"（观测 `{'346':'running','348':'unknown'}`）或"单 Data 组且元数据可用"布局 |
| benchmark 客户端编排异常 | 5 | `PG-MSR-09/11/15/17/19` | `KeyError: '占位符'` |
| 权限语句语法不支持 | 2 | `PG-PRV-02`、`PG-PRV-06` | `grant system to …` → `700: … no viable alternative at input 'grant system to'` |
| 产品自报上限 > spec 公式 ⇒ 期望不可信 | 1 | `PG-DEV-21` | 产品自报 `{'SCHEMA':5,'DATA':60}` vs 公式 `{'SCHEMA':3,'DATA':30}`（即 H-19 的单调存量），按纪律 SKIP 而非降级判定 |
| harness 缺只读接口（P0 用例） | 1 | `PG-HA-08` | `cluster.py` 无 `set_readonly` 类方法，无法制造"只读副本" |
| 表模型 TTL 语法未确认 | 1 | `PG-TTL-06` | 按纪律不做试探性 DDL |
| 上限 R=2 < 3，无法验证 min 逐步逼近 | 1 | `PG-MIN-04` | `schema 上限 R=2 < 3` |
| 设备→RegionGroup 映射不可见 | 1 | `PG-SWCH-08` | 观测到 `{'pgd0':'','pgd1':'','pgd2':'','pgd3':''}` |
| 与 `PG-REB-01` 同构，按"不重复计数"合并 | 1 | `PG-REB-08` | 保留 id 占位以免矩阵出现缺口 |

按 run 拆分：`pg_full_iot_final` 8 例（`PG-DFT-01/02/03/04`、`PG-MIN-04`、`PG-MSR-17/19`、`PG-SMK-01`），
`pg_iot_resume` 33 例。

---

## 7 复核方法（可重放，不改集群）

```bash
cd /home/ubuntu/remove_cn_dn/pg_build
# 1) 基数校验：217 = 87 PASS / 89 FAIL / 41 SKIP，两轮用例集不相交
python3 - <<'PY'
import json,glob,collections
c=collections.Counter(); ids=set()
for r in ('pg_full_iot_final','pg_iot_resume'):
    for d in glob.glob(f'results/{r}/cases/*/result.json'):
        j=json.load(open(d)); c[j['status']]+=1; ids.add(j['case_id'])
print(c, len(ids))      # Counter({'PASS': 87, 'FAIL': 89, 'SKIP': 41}) 217
PY
# 2) 单例：失败 check + detail（把 PG-LIM-01 换成任意 case_id）
python3 - <<'PY2'
import json
j=json.load(open('results/pg_iot_resume/cases/PG-LIM-01/result.json'))
for c in j['checks']:
    if not c['ok']: print(c['name'],'::',c['detail'])
PY2
# 3) 收尾③ 首命中与锚点对拍
grep -n 'harness 动作' results/pg_iot_resume/run.log | head -20
# 4) 全量轮为何只有 63 例（暂停点）
cat full_run_paused.txt
```

**本报告不含修复方案与重跑结果**；产品缺陷登记在 `DEFECT_CANDIDATES.md`，harness 修正登记在
`HARNESS_FINDINGS.md`（本轮补全 H-19、补录 H-08/H-15/H-16/H-22 定义、新增 H-22b 与 H-23…H-30），两者不得混记。

## 附：升级族实测（1.3.7.1 → 2.0.11-SNAPSHOT `3bbeea6`）

升级路径：`/data/mpp_test/pg_upg_13` 原地升级，数据与账号保留（升级后仍 `root/root`），
3 CN + 5 DN 全部 `Running` / `ACTIVATED`。执行说明：脚本 `upgrade` 先等 seed CN 应答，
但单 CN 缺 Raft 多数派无法选主（死锁）→ 改为手工按序拉起 3 CN + 5 DN。

| 阶段 | 用例 | 结果 |
|---|---|---|
| pre（1.3.7.1 上建立基线） | UPG-01~05、07 | PASS（1.3 兼容分支：`SHOW REGIONS` 试算组数、`select *` 计数、1.3 等价同步判据） |
| | UPG-06 | **FAIL（仅收尾③日志卫生）**：`AsyncRequestManager:147` leader 变更重试 WARN、`FragmentInstanceDispatcherImpl:545` 查询分片路由重试 WARN |
| post（2.0.11 上验证升级后语义） | UPG-08~12、14、16 | PASS |
| | UPG-13 | PASS（原 FAIL 经 H-31 修口径后复跑通过：`count(*)` 是每测点一列，"行数不变"不是产品问题） |
| | UPG-15 | **FAIL（仅收尾③日志卫生）**：`dn@11.101.10.9` `FragmentInstanceDispatcherImpl` WARN |

**结论**：16 例中 15 PASS / 1 FAIL；唯一 FAIL 为日志卫生类 WARN（路由/leader 重试噪音），
无升级数据丢失、无扩容行为回归。产品侧新增缺陷：**0**；harness 新增修复：H-31。

## 附：已知可接受日志（评估为噪声，**不白名单、不改判**）

| 家族 | 日志签名 | 出现面 | 评估依据 | 处置 |
|---|---|---|---|---|
| L-1 | `AsyncRequestManager:147 - Failed to CHANGE_REGION_LEADER on ConfigNode after 1 retries` | 6 个 run、约 52 处证据文件，集中在停机对拍/HA 停机窗口与建 region 期 | WARN 级；固定"重试 1 次后放弃"路径；均为 leader 迁移目标不可达（节点被停/正在切换），后续由 LeaderBalancer 再平衡 | 记录，保持 FAIL 判定；报告中单列清单 |
| L-2 | `FragmentInstanceDispatcherImpl:545 - can't execute request on node <TEndPoint>` | 4 例（DEV-12/TIME-07/UPG-06/UPG-15），常规写查流程亦有 | WARN 级；查询分片被派到不持有该 region 副本的 DataNode（DR2/DR3 下 5~20 DN 中多数无副本），调度器转投其它节点后成功 | 同上；不进入白名单，判 FAIL 但标注为"路由重试噪声" |

判定原则：这两类**只是被分类记录，不会让用例转 PASS**；若后续要放宽，需显式打开配置项并写明理由。
