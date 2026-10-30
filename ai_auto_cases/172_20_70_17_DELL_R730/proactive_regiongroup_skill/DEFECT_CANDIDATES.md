# 产品缺陷候选（需在确认集群上复现后报 PLM）

> 口径：**只有"期望值来自需求/设计文档或源码公式"且"在干净集群上可稳定复现"的偏差才登记为候选**。
> harness 自身的假 FAIL / 环境噪声一律不登记（见 `HARNESS_FINDINGS.md`）。

## D-01（待复现）CN 重启后心跳未到时补组判定可能多建 1 组

* 现象预期：`ConfigNode` 重启后，`LoadCache` 对未缓存组返回 `Disabled`（`LoadCache.java:798-802`），
  而 `RegionGroupStatistics` 默认值也是 `Disabled`（`:44-46`）；于是
  `PartitionManager.java:685-696` 的"全部组 Disabled 时 +1"分支会被**误触发**，在有 pending 的
  请求上多建 1 个组（上限内）。
* 期望：刚重启后组状态未知不应等价于 Disabled；应等心跳回填后再判定，或对"未知"单独处理。
* 观测手段：重启 CN 后**立即**写新 slot，比较组数与 `min(K,R)`；IT 里通过等待 Running 规避
  （`ExtensionIT:234-235`、`DistributionIT:934`），说明产品侧已知该窗口。
* 用例：`PG-DIS-06`、`PG-RCV-01`（若观测到多建 1 组，按 FAIL 记录并在此处登记）。
* 状态：**待复现**（需要"重启后立刻写入"的时序，成功率受心跳间隔影响）。

## D-02（待确认）1.3 → 2.0 升级后同一份 conf 的扩容语义发生变化

* 事实：1.3.7 模板策略默认 `AUTO` 且生效文件无策略键；2.0.11 代码默认 `PROACTIVE`（模板 `:848/:891`）。
  ⇒ 用户升级后**未改任何配置**，扩容行为从"不积极扩容"变为"积极扩容"。
* 这属于**行为变更**：需求本身可能就是要它变（TDB-367 的意图），但 RN 中未显式提示
  "升级即改变默认行为"，建议在 RN/升级说明中明确。
* 用例：`PG-UPG-09`（升级后已有数据 + 新 slot ⇒ 必须按 PROACTIVE 增长）。
* 状态：**待执行升级轮确认**（机制已实现，见 `scripts/pgkit/upgrade.py`）。

## D-03（文档/文案，非功能缺陷）非法 schema 策略值报错文案复用了 DataRegion 类型名

* 实测：`SET CONFIGURATION "schema_region_group_extension_policy"="proactive"` 报
  `DataRegionGroupExtensionPolicy proactive doesn't exist.`
* 源码：`RegionGroupExtensionPolicy.java:42-50` 的异常文案写死为 DataRegion。
* 影响：误导运维定位；属文案问题，已记 `references/doc-gaps.md` G-02。
* 用例：`PG-DFT-08`。

## D-04（已提单：PLM **TDB-862**，父 RN TDB-367，迭代 V2.0.13.1，负责人 王頔，验证 刘珍，P1）（**已确证 2026-10-20**）表库与树库同名时表库被树库覆盖，**永不参与上限调整** ⇒ 上限恒等于最小组数

* **实测（`results/pg_smoke_2`，干净集群、conf 显式 PROACTIVE、`schema_region_per_data_node=3`、
  `data_region_per_data_node=0`、5 DN、schemaRF=3、dataRF=2，树表两库并存）**：

  | 库 | 实测 `MaxSchemaRegionGroupNum` | 实测 `MaxDataRegionGroupNum` | 公式（分摊库数=2） |
  | --- | --- | --- | --- |
  | 树 `root.pg` | 5 | 60 | 3 / 30 |
  | 表 `pg` | **1**（=最小组数） | **2**（=最小组数） | 3 / 30 |

* 表库写入 4 个互不相同 series slot（`PG-SMK-05`、`PG-LIM-21`）后：`SchemaRegionGroupNum` 恒 1、
  `DataRegionGroupNum` 恒 2 —— **完全不积极扩容**；树库同口径正常增长到 `min(K, 上限)`。
* **根因（2026-10-20 干净集群实锤，取代原假设）**：`ClusterSchemaInfo.enrichSchemaMap()` 以
  `path.getFullPath()` 作为结果 map 的 key（`ClusterSchemaInfo.java:679-693`）。表库 `pg` 与
  树库 `root.pg` 的 full path 归一为同一字符串 ⇒ 两条目**互相覆盖**（表先插入、树后覆盖）；
  `ClusterSchemaManager.adjustMaxRegionGroupNum()` 只遍历该 map（`:544-590`），
  表库**不在 map 中**，于是永远不会被调整，上限停在建库默认 `setMax*(min*)`；
  同时 `databaseNum = map.size()` 每冲突一次少计 1，**其余库的上限被抬高**。
  原"`getRegionGroupCount` 抛 `DatabaseNotExistsException` 被 `continue`"的解释**不成立、已废弃**：
  `PartitionInfo.createDatabase()` 对树/表库都会写入 `databasePartitionTables`（`:180-184`），
  `isDatabaseExisted()` 为 true，不会抛异常。
* **需求侧**：`docs/360` 第 20 行覆盖矩阵列出"树模型、表模型"，第 253 行明确
  "统计参与分摊的数据库：树模型和表模型的普通数据库一起计数" ⇒ 表模型在功能范围内。
* 产品自测覆盖不足：`IoTDBDatabaseIT:1004` 附近只"触发"一次 `adjustMaxRegionGroupNum`
  （`create database test1`），**不断言表库的上限值**，因此该问题不会被现有 IT 拦住。
* 判定实验：`PG-LIM-21`（触发一次调整后表库上限是否变为公式值）+ 2026-10-20 干净环境 A/B（见下节）。
* 影响：表模型（含 OBJECT 表）用户的 RegionGroup 数量被钉死在最小组数，**积极扩容需求对表模型完全失效**；
  且上限不可观测地"偏低"会让用户误以为已到容量上限。
* 状态：**已确证（26 例 + 干净环境 A/B），建议提单**；提单要素与最小复现见 §D-04 实锤实验。
* **触发条件（重要，提单必须写明）**：表库与其同名树库**同时存在**（如树 `root.pg` + 表 `pg`）。
  没有同名树库时表库**能正常参与**上限分摊（见下节 `exp_tab` 对照）——这正是 26 例全落在
  同一形状、而单独建表库不复现的原因。

### D-04 补强证据（2026-10-17，`pg_full_iot_final` 63 例 + `pg_iot_resume` 154 例）

1. **主动触发一次调整后仍被钉死**（排除"只是还没触发"的解释）——
   `PG-LIM-21` 的 `checks[3]`「触发一次调整后表库上限仍为公式（否则 = 表库被整体跳过）」：
   `触发前=(1, 2)` → **`触发后=(1, 2)`** → `公式=(2,15)`；同例 `checks[4]` 写 4 个不同 slot 后
   Data 组数 **2** vs 期望 **4**（`../results/pg_full_iot_final/cases/PG-LIM-21/result.json`；
   `TRIAGE_full_round.md:230`）。
2. **"写很多 slot 也不涨"不是 slot 太少**——`PG-HA-12`（停机期间写 **5 个 slot**）Data 组数 **2** vs 期望 **5**、
   `PG-REB-11`（表库 5 slot）同样 **2** vs 期望 **5**，而**同一次运行里树库同条件为 5**
   （`../results/pg_iot_resume/cases/PG-HA-12/result.json:checks[1]`、`PG-REB-11/result.json:checks[6]`；
   `TRIAGE_full_round.md:235`、`:251`）。
3. **53 个失败 check 是同一签名、无第二种成因**：表库一律 `实测={SCHEMA:1, DATA:2}` vs
   `公式={SCHEMA:3, DATA:30}`（或组数停在 2 而非 `min(K,R)`），覆盖 26 例、8 个用例族，
   且跨"重启 / 热加载 / 换策略"均不变（`TRIAGE_full_round.md:110`、§4.1 表 227–254 行、`:256`）。
   ⇒ D-04 是唯一能同时解释"表库恒 1/2""树库同条件正常""重启后仍 1/2"的成因。

### D-04 实锤实验（2026-10-20，干净 3C5D / 2.0.11-SNAPSHOT 3bbeea6，ACTIVATED）

环境：3 CN（.7/.8/.9）+ 5 DN（.6..10），`PROACTIVE`、`schema_region_per_data_node=3`、
`data_region_per_data_node=0`、schemaRF=3 / dataRF=2，新建库全为全新库。
原始证据：`results/exp_d04_d05_1020/EVIDENCE.md`。

| 库 | 同名树库存在？ | `MaxSchemaRegionGroupNum` | `MaxDataRegionGroupNum` | 是否出现在调整日志 |
| --- | --- | --- | --- | --- |
| 表 `exp_tab` | 否 | 1（=公式） | 12（=公式） | ✅ |
| 表 `solo_tab`（先建） | 否 | 1（=公式） | 12（=公式） | ✅（20:06:03） |
| 树 `root.solo_tab`（后建，造成同名） | — | 1 | 12 | ✅（20:06:04） |
| 表 `solo_tab`（冲突后） | **是** | 1 | **12→不再更新** | ❌（20:06:04 起消失） |
| 表 `pg` | **是**（树 `root.pg`） | **1**（=最小组数） | **2**（=最小组数） | ❌（全程未出现） |
| 树 `root.pg` / `root.d05` / `root.exp_tree` | — | 1 | 12 | ✅ |

**A/B 在 1 秒内完成**（`log_confignode_all.log`）：
`20:06:03 solo_tab -> 1 / 12`（无冲突，正常调整）→ 建 `root.solo_tab` →
`20:06:04 root.solo_tab -> 1 / 12`，此后 `solo_tab` **再未出现**。

**分母被少计的直接证据**：7 个库、2 组同名冲突时，日志给出的上限
`1 / 12` 对应 `databaseNum=5`（`ceil(3×5/(5×3))=1`、`ceil(24×5/(5×2))=12`），
而实际库数为 7 ⇒ 冲突的两条表库记录被树库覆盖。

**影响**：表库上限钉死在 (1, 2)，`DataRegionGroupNum` 永远到不了 3；其余库的上限被抬高
（分摊不均）。任何"树库 `root.x` + 表库 `x`"并存的用户都会命中。

**规避验证（反向确认根因）**：删除同名树库 `root.pg` 后再触发调整，表库 `pg` **重新出现**在
`[AdjustRegionGroupNum]` 日志（`1/12` → `1/10`）⇒ 冲突解除即恢复。**临时规避手段**：避免
树库 `root.x` 与表库 `x` 同名（改任一库名即可）。

**建议提单要素**：标题"表库与同名树库共存时，表库不参与 RegionGroup 上限调整（PROACTIVE 失效）"；
复现：建 `root.x`（树）+ `x`（表）→ `SHOW DATABASES DETAILS` 表库恒 1/2；
验证修复：调整后表库上限应与其他库同公式值，且日志出现 `[AdjustRegionGroupNum] ... x`。

## D-05（**2026-10-20 撤销：非产品缺陷**）测点级 `select count(*)` 返回空集 = 2.x `count(*)` 语义

* 实测（`PG-MSR-01`）：`insert into root.pg.pgd0(timestamp, s0) values(1, 1.0)` →
  `Msg: The statement is executed successfully.`；`show data seriesslotid where database=root.pg`
  → `SeriesSlotId=502`（1 行）；紧接着 `select count(*) from root.pg.pgd0.s0`
  → 返回**空集**且列名是 `Time`（不是聚合列），cost 0.054s；同一轮对 `root.pg.d0.s0` 的
  同样语句返回 `count(...)=1`。
* **本轮定性（2026-10-17，`pg_iot_resume` 154 例）**：原列"两种可能"已排除②（harness 语句构造）——
  `count_rows`（`scripts/pgkit/pgapi.py:444-453`）**只在结果集为空时**返回 `-1`，SQL 本身返回成功；
  10 例各自独立复现，形状完全一致（`TRIAGE_full_round.md:291`、§4.2）。
* **最小复现**（同一库 `root.pg`、同一设备 `pgd0`、同一序列 `root.pg.pgd0.s0`）：

  ```sql
  insert into root.pg.pgd0(timestamp, s0) values(1, 1.0);   -- Msg: The statement is executed successfully.
  select count(*) from root.pg.pgd0.s0;   -- 测点级：+----+ |Time| +----+ Empty set.  （异常）
  select s0 from root.pg.pgd0 where time=1; -- 同路径取数：1970-01-01T08:00:00.001+08:00 | 1.0（有数据）
  select count(*) from root.pg.pgd0;      -- 设备级：|count(root.pg.pgd0.s0)| = 1（正常）
  ```

  证据：`../results/pg_iot_resume/cases/PG-MSR-01/actions.log:69-72`（空集 + 随后同路径取到 1.0）、
  `../results/pg_iot_resume/cases/PG-RCV-01/actions.log:117-118`（设备级 `select count(*) from root.pg.pgd0`
  → `|count(root.pg.pgd0.s0)|count(root.pg.pgd0.s1)|count(root.pg.pgd0.s2)| = |1|1|1|`）。
* **规模**：resume 轮对"`<db>.<device>.<measurement>` 测点级 `count(*)`"形状共 **10 次查询 / 10 次全部
  `Empty set`**（10 个用例各 1 次，即本轮 10 个 FAIL 的那 10 条断言）；全量轮该形状 **0 次查询**
  （故"全量轮没报"不能用来否定）。同一轮设备级 `<db>.<device>` 的 `count(*)` 共 21 次**全部有数据**；
  其中 `root.pg.pgd0` 设备级 3 次（`PG-RCV-01:117`、`PG-RCV-03:77`、`PG-RCV-06:306`）全部成功。
* **形态边界（已核验，避免误扩范围）**：带层级的**设备**路径（`root.pg.d0.sub1.sub2`、`root.pg.sub.d0`）
  的 `count(*)` 正常返回数据（`../results/pg_iot_resume/cases/PG-DEV-22/actions.log:50,52`、`../results/pg_full_iot_final/cases/PG-EMPTY-12/actions.log:27,29`）
  ⇒ 触发条件是"路径落到**测点**"，不是"路径段数多"。
* 影响面：写后可读性（聚合查询返回空集，明细查询正常），与 PROACTIVE 无关但同批发现。
  另注：`PG-OBS-06/07/08` 三个本该做对照实验的用例本轮因 `NameError: name 're' is not defined` 未跑到（H-28），
  10 例独立复现已足够定性。
* 状态：**撤销（非产品缺陷）**。2026-10-20 干净集群复现实验给出定性（`results/exp_d04_d05_1020/EVIDENCE.md`）：

  ```text
  select count(*) from root.d05.dev1        -> |count(root.d05.dev1.s1)| 1   （设备级：每测点一列）
  select count(*) from root.d05.dev1.s1     -> Empty set                    （测点路径下没有子测点）
  select count(s1) from root.d05.dev1       -> 1                            （正确写法）
  select s1   from root.d05.dev1.s1         -> Empty set                    （FROM 是测点路径，1.x/2.x 同）
  select s1   from root.d05.dev1            -> 1.0                          （数据本身可查）
  ```

  2.x 的 `count(*)` = "FROM 路径下**各测点**的行数"（H-31 已记录），因此路径落到**测点**时没有子测点，
  返回空集是**语义一致**的结果，不是写后不可读。用例把 1.x 口径（`count(*) from <db>.<device>.<sensor>`）
  直接搬过来才产生 10 例 FAIL。
* 处置：harness 侧新增 `PgApi.count_series()`（`select count(<sensor>) from <db>.<device>`），
  已替换 20 处测点级 `count_rows(...)` 调用（详见 `HARNESS_FINDINGS.md` H-37），并复跑确认。
* 建议：在 RN/升级说明补一条 **1.3→2.0 兼容性提示**："`select count(*) from <db>.<device>.<measurement>`
  在 2.0 返回空集，请改为 `select count(<measurement>) from <db>.<device>`"（文档缺口，不记功能缺陷）。

## D-06（待定性，V2 专属）IoTConsensusV2 全新集群上单个 DataRegion 的 syncLag 恒为 1.0

* 环境：V2 轮刚部署完成的干净集群（`DB_DIR=/data/mpp_test/pg_2011snap_3bbeea656114_v2`），
  未写入任何业务数据，5 台 DN 全部在线。
* 原始证据（`curl http://127.0.0.1:9092/metrics`，逐台抓取）：
  * `11.101.10.6`（nodeId=4）：
    `iot_consensus_v2{...name="IoTConsensusV2ServerImpl",region="DataRegion[5]",type="syncLag",} 1.0`
  * `.9/.8/.7/.10` 各自 3~4 条 syncLag 序列全部为 `0.0`；只有上述 1 条非零且**持续不降**。
* 影响：V2 轮所有用例的"收尾① sync lag → 0"必然超时 FAIL（严格门禁下如实失败），
  PROACTIVE 在 V2 上的功能结论被这一条阻塞，无法判定。
* **机制已查清（源码 `iotdb-core/consensus/.../pipe/metric/IoTConsensusV2SyncLagManager.java:99-118`）**：
  `calculateSyncLag()` = "无复制管道时返回 0，否则取所有管道 `leaderReplicateProgress - followerApplyProgress`
  的最大值（并夹到 ≥0）"；`getSyncLagForSpecificConsensusPipe` 同样用
  `userWriteProgress - replicateProgress`。**语义上"非零"就等于"还有 entry 没有 apply 到 follower"**，
  不存在"learner 空闲天然不为零"的口径 ⇒ **排除可能②**。
* 因此 D-06 判定为**产品问题**：全新集群、无业务写入，`DataRegion[5]` 仍有 1 个 entry 永不 apply
  （永久 1.0）。影响：① V2 下"sync lag 归零"这一收尾门禁永远不通过；② 该 region 的副本之间存在
  永久一致的 1-entry 缺口（数据面风险取决于这 1 个 entry 的内容，需产品侧定位是 region 创建期的
  记账偏差还是真实未复制数据）。
* 可复现证据用例：`PG-OBS-07`（逐实例抓取 5 台 DN 的 `type="syncLag"`，非零即 FAIL 并落盘 region 名）。
* 判定动作（受会话时间限制未完成）：`show regions` 查 DataRegion[5] 的副本分布与状态、
  对照 leader/follower 两侧 syncLag、查 .6 的 datanode 日志中该 region 的复制记录。
* 处置：V2 档 `SYNC_MAX_WAIT_SEC` 由 1800 收紧到 420（把"每例烧 30 分钟"降到可控），
  **门禁本身没有放宽**（仍要求持续 60s 为 0，否则 FAIL）。

## D-07（**已关闭**：定性为 harness 缺陷 H-10，见 HARNESS_FINDINGS.md）

> 结论：产品给 4 正确（上限是每库单调存量），是用例用"现场重算上限"当期望值所致。原始证据保留如下。
SchemaRegionGroup 实测 4 而用例期望 3 —— iOS/产品还是用例口径？

* 证据（run `pg_core_iot2` / `PG-SMK-04`，2026-10-14）：
  `写入第 4 个 slot 后（min 增长+新增 slot）：SchemaRegionGroup 数应为 3`；
  实际 `库详情={"schema": 4, "data": 4}`、`区域去重={"schema": 4, "data": 4}`（两口径一致）。
* **尚未定性**，两种可能必须分清、不得含糊：
  1. **产品**：按公式 `T = min(R, max(min(minNum, G+|P|), K))`，K=4 个不同 slot、schema 上限 R=5，
     预期应为 `min(4, 5) = 4`；若产品给 4 反而是**正确**的，那么就是**用例期望值算错**（harness 问题）。
  2. 若该用例的场景设计是"min 增长本身不应超过某值"（例如断言 min=3 时组数应停在 3），
     则产品给 4 属真实超额，应记产品缺陷。
* 判定方法（下一轮执行）：打开 `scripts/pgkit/cases.py` 的 `PG-SMK-04` 主体，确认它在此步用的是
  `min(K, expected_cap(...))` 还是硬编码 3；若为硬编码，直接按公式改正并用例自证（H 类）；
  若确为公式且产品仍多给，则升级为 D-07（产品）。
* 影响：该例其余检查（含收尾①②）不受影响；**在定性前不得把它写成产品缺陷**。

## D-08（**已降级：harness 归因，见 H-25，不再是产品候选**）`MemoryManager` 记 WARN

* **证据（原始）**：`pg_core_iot2` 有 **8 例**收尾③命中
  `WARN o.a.i.c.m.MemoryManager:256 - getOrRegisterMemoryBlock failed: memory block Consensus already exists`
  （`PG-MIN-05`、`PG-LIM-08`、`PG-LIM-10` 等，时间点分散在 23:00、02:50、03:00 等）。
* **本轮定性修订（2026-10-17，6 例可逐条归因）**：该 WARN 全部紧跟**本用例自己的热加载动作**——
  命中距同用例 `[harness 动作] 热加载 <quota>` **26–152s**：`LIM-06` +152s、`LIM-07` +144s、
  `LIM-09` +61s、`LIM-10` +42s、`LIM-17` +51s、`SWCH-06` +26s。机制是热加载会批量新建组，
  各 DN 随后重新注册同名 `Consensus` 内存块（**幂等路径**）。
  ⇒ 触发源是 harness 的 `set configuration` 热加载，而非"快速 drop/create"（原判断被推翻）。
* **处置**：**降级为 harness 归因**（`H-25` 的窗口 pad 太小：`set configuration` 类窗口 ±20s 盖不住
  26–152s 的尾巴，且用例的**恢复**动作根本没开窗）。收尾③ 该命中应计入 `log_attributed.txt`，
  不再作为产品缺陷候选（`TRIAGE_full_round.md:524`、§4.6 中 `LIM-06/07/09/10/17`、`SWCH-06` 六行）。
* 若产品后续要求"热加载不得留 WARN"，应另立**"日志卫生（低危）"**条目，而不是功能缺陷。

## D-09（新，低危/日志卫生）TTL 生效下写入成功但 DN 仍记 `Error in executing plan node`

* **观测**：`PG-TTL-02`（TTL=1000ms）中 `pgs2`/`pgs3` 两次 `insert` **客户端返回 ok**（用例断言通过），
  但 DN 日志出现 `WARN o.a.i.d.c.s.d.DataExecutionVisitor:85 - Error in executing plan node:
  InsertRowNode{insertTarget=root.pg.pgs2, …}`（`TTL-01/03/08` 同族亦有）。
* **定性**：写路径先失败（TTL 边界亚秒竞态）后内部重试成功，客户端结果为成功但服务端留下 WARN 痕迹；
  对用户表现为"写入成功却报错日志"，属**日志卫生**问题，不影响数据正确性。
* **处理**：**不加入白名单**，收尾③ 检查保持 FAIL；待产品确认是"重试留痕"还是"重复执行"。

## D-10（**归因修订：按 `drop database` 归因，见 H-24 F 族；不再是"无 harness 触发"**）`[LeaderBalancer]` 无 leader 可选

* **观测（原始）**：`PG-TTL-03`（TTL=1000ms，功能断言**全部通过**）收尾③ 命中 CN 日志
  `WARN o.a.i.c.m.l.b.r.l.AbstractLeaderBalancer:95/109/116 - [LeaderBalancer]
  Region: TConsensusGroupId(type:DataRegion, id:1120) not in …` 与
  `The following RegionGroups' leader cannot be selected because …`（14:21:51，TTL 过期/区域变化阶段）。
* **本轮定性修订（2026-10-17）**：该签名在 resume 轮的 2 例**都落在 `drop database` 动作窗口内**：
  * `PG-DEV-18`：`删除另一模型测试库 pg` **Δ=-2s**（命中 2026-10-16 21:25:16，×10）；
  * `PG-OBS-02`：`删除另一模型测试库 root.pg` **Δ=+1s**（命中 2026-10-16 21:58:35，×4）。
  日志点名的 `DataRegion id=21` / `id=126` 正是刚被删掉的组 ⇒ 组被销毁、路由尚未收敛时的
  "无 leader 可选"是**删库动作的必然尾巴**，把"非 harness 触发"的旧结论推翻。
  （`TRIAGE_full_round.md:393`、`:374`、§6 第 525 行）
* **处置**：改按 `drop database` 归因（`H-24` 的 **F 族**：`drop/create database` 引发元数据/协调器噪声），
  该签名应进白名单的 F 族并按动作窗口限流；**只有"热集群、无任何 harness 动作"时**出现该签名，
  才回到产品噪声候选（原 14:21:51 那次因用例只设 TTL、未删库，仍按"待产品确认"保留为观察项，
  不因本次修订而认定为产品缺陷）。
