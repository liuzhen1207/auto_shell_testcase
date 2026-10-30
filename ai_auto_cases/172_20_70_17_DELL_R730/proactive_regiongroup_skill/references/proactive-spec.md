# PROACTIVE（RegionGroup 积极扩容）判定规格

本文件是 `references/` 的**唯一判定口径来源**：所有用例的期望值、三档处置、开放歧义都以它为准。
来源与出处：

| 代号 | 来源 | 落盘 |
| --- | --- | --- |
| 需求 | PLM docs/360《…积极的RegionGroup分配策略-需求分析》 | `docs/doc_360.md` |
| 分槽 | PLM docs/127《…slot分布和验证》 | `docs/doc_127.md` |
| 设计 | PLM docs/341《…技术设计》 | `docs/doc_341.md` |
| RN | TDB-367（P0，新功能，V2.0.13.1；负责人 王頔，组长 陈荣钊，验证 刘珍） | `docs/rn_TDB-367.json` |
| 包 | `timechodb-2.0.11-SNAPSHOT-bin.zip`（master `3bbeea656114`，2026-10-14 构建） | 实测：`conf/iotdb-system.properties.template:848/891` |

## 1. 被测对象与版本事实

1. 两个配置键的**合法值**：`CUSTOM`、`AUTO`、`PROACTIVE`，**区分大小写**；非法值（含 `proactive`）必须被拒绝，不得解释为 PROACTIVE。
2. 本构建的**发布模板默认值已是 PROACTIVE**（`iotdb-system.properties.template:848` 与 `:891`），
   且生效文件 `conf/iotdb-system.properties` **不含**这两个键 ⇒ 全新部署走**代码默认**，无需显式设置。
3. 设计文档 §4.3.3 自述"该记录不包含此后默认值改为 PROACTIVE 的专项验证"⇒ **默认值生效性是本次首要验证点**。
4. 语义：PROACTIVE 按**不同 series slot 数**（不是设备数、不是测点数、不是时间分区数）决定常规目标组数，
   上限沿用 AUTO 的资源上限公式；新增组只承接**后续**分区，不迁移历史数据、不自动缩容。

## 2. 配置项（键名与默认值均以发布模板为准）

| 键 | 合法值/类型 | 默认 | 热加载 | 作用 |
| --- | --- | --- | --- | --- |
| `schema_region_group_extension_policy` | `CUSTOM`/`AUTO`/`PROACTIVE` | `PROACTIVE` | 是 | SchemaRegionGroup 扩容决策 |
| `data_region_group_extension_policy` | 同上 | `PROACTIVE` | 是 | DataRegionGroup 扩容决策 + 策略表保留阈值选型 |
| `default_schema_region_group_num_per_database` | 正整数 | `1` | 是 | Schema 最小组数 / 上限下界 |
| `default_data_region_group_num_per_database` | 正整数 | `2` | 是 | Data 最小组数 / 上限下界 |
| `schema_region_per_data_node` | 正整数 | `1` | 是 | Schema 上限：每 DN 配额 |
| `data_region_per_data_node` | 非负整数 | `0` | 是 | Data 上限：>0 用该值，=0 用 **0.5×DN 上报 CPU 核数** |
| `series_slot_num` | 正整数 | `1000` | **否（首次启动确定）** | 总槽数；改它必须换新集群 |
| `time_partition_interval` | 秒 | `604800` | 见实现 | 时间分区间隔；跨分区用例需要调小 |
| `schema_replication_factor` / `data_replication_factor` | 正整数 | 3 / 2（本任务口径） | 否 | 副本数，参与上限换算 |

热更新纪律（需求 §3.1/§3.2）：`SET CONFIGURATION 'k'='v';` **一次只写一个键**、**不允许 `ON <nodeId>`**、
需要 **SYSTEM 权限**、**全集群一致**；两份参数可分别切换。运行中切换策略**不会立即建组**。

## 3. 扩容计算（设计 §4.1.3 为权威实现口径）

对单个数据库、单种 Region 类型：

1. `S` = 同类型分区表已有 series key 集合（Schema 取 Schema 分区表，Data 取 Data 分区表）。
2. `P` = 本次请求的 slot 集合（Data 请求按 `Map<slot, timeSlots>` 的 key 集合提取）。
3. `K = |S ∪ P|`（并集去重；请求内重复、与已有重合都只计一次）。
4. `R` = 该库该类型**组数上限**（见 §4）。
5. `G` = 该库该类型**已有组数**。
6. 目标 `T` 与新增 `delta`（**源码为权威口径**，`PartitionManager.java:654-699`）：

   ```
   minimumTarget = min(minNum, G + |P|)                 // 670-673：只数"本次请求"的不同 slot
   T             = min(R, max(minimumTarget, K))        // 674-681
   delta         = max(0, T - G)                        // 683-684
   ```

   - 即"**先增量逼近最小组数，再按不同 slot 数取大，最后封顶上限**"，与发布模板注释一致；
     设计文档 §4.1.3 写的 `T = min(K, R)` 是**简化写法**，在"`G≥1` 且 `minNum > G+|P| > K`"时与代码不同
     （已登记 `references/doc-gaps.md` G-01）。
   - 推论：首次请求 `G=0`、`|P|=K=1` ⇒ `T=min(R, max(min(minNum,1), 1))=1` ⇒ **首次只建 1 个**（不预建到 min）；
     已有 1 组、min=4、上限 5、同 slot 申请新时间分区（`|P|=K=1`）⇒ `T=min(5, max(min(4,2),1))=2` ⇒ **补到 2 个**
     （用例 `PG-MIN-02` 的期望值）。
7. Disabled 补组（与常规扩容**互斥**分支）：常规 `delta=0` 且同时满足
   ①`P` 非空 ②`G>0` ③`G<R` ④该库该类型**全部组**为 Disabled ⇒ 追加 1 个组（可超过 `T`，不得超过 `R`）。
8. 触发条件：请求需要创建**缺失分区**时才计算；**空库不预建**；重复访问已有分区**不触发**；
   同设备加测点、同 slot 新时间分区**不增加** `K`（但"已有 slot 申请新时间分区"仍可触发**逼近最小组数**的补组）。
9. Schema 与 Data 独立计数；切换策略本身不建组；切换后"已有 slot 申请新时间分区"可补 Data 组，
   而 Schema 组必须由**缺失元数据分区请求**触发。

## 4. 组数上限（`R`）

```
schema: R = max(min_schema, ceil(schema_region_per_data_node × DN数 ÷ 参与分摊库数 ÷ rf_schema), G)
data  : data_region_per_data_node > 0 :
        R = max(min_data, ceil(data_region_per_data_node × DN数 ÷ 参与分摊库数 ÷ rf_data), G)
        data_region_per_data_node = 0 :
        R = max(min_data, ceil(0.5 × DN上报CPU总核数 ÷ 参与分摊库数 ÷ rf_data), G)
```

1. **参与分摊库数** = 树模型 + 表模型的**普通库一起计数**；**系统库、审计库、已预删除库不参与**。
2. 上游文档给出的 3D/5D/9D 参考上限（每 DN 32 核、单库、副本 3）：Schema 1/2/3，Data 16/27/48。
3. `R` 是**分配数量上限**，不是物理预算：多库最小数量、向上取整、历史组都可能把总量抬高。
4. `R` 使用**数据库实际的最小数量**（用户为该库单设过就用该设置）。

## 5. 分配策略表重平衡与 Leader 恢复（设计 §4.2）

1. 触发：`CreateRegionGroupsProcedure` 在 Data 组**持久化成功后、激活前**调用 `reBalanceDataPartitionPolicy`。
2. 每组保留阈值：
   - PROACTIVE：`mu = max(1, floor(A / G))`，`A` = 策略表中**组 ID 非空**的 slot 数，`G` = 参与分配的组数；
   - AUTO/CUSTOM：`mu = floor(总槽数 M / G)`（**沿用旧口径，不用实际 slot 数**）。
3. 超过 `mu` 的优选映射被移除（只影响**后续分配**），历史时间分区映射不变。
4. ConfigNode 重启/Leader 切换：`setupPartitionBalancer` 先注册已有组，再按"每个 slot **最后一次**分配的组"
   以**同一阈值**重建策略表（超过阈值的条目暂不建映射）。
5. 只作用于 `INHERIT` 的优选组选择；`SHUFFLE` 不受影响。

## 6. 兼容、升级、回退（需求 §3.3.2 / 设计 §4.3.3）

1. 升级：**显式**设置过的 `AUTO`/`CUSTOM` 保留；**未显式**设置的参数在新版本启动后采用默认 `PROACTIVE`；
   启用后**无需重建库或迁移历史数据**。
2. 旧版本**不能解析** `PROACTIVE` ⇒ **混合版本阶段必须显式保持旧版本支持的策略**；
   **回退前必须恢复旧策略**，并核对运行配置与启动配置。
3. 切回 `AUTO`/`CUSTOM` **不回收**已创建的 RegionGroup，也不回滚已有分区映射。
4. 权限：改策略需 `SYSTEM`；三权分立开/关都不改变该要求；普通业务用户仅需既有库读写权限。
5. 审计：记录**操作人、时间、配置键及请求值、客户端 IP、最终结果**（含权限拒绝与执行失败）；
   自动扩容走运行日志（库、Region 类型、组、slot、节点、失败原因），**不新增**独立审计事件类型。

## 7. 可观测量（用例断言的唯一依据）

| 目的 | SQL | 备注 |
| --- | --- | --- |
| 组清单（去重后才是组数） | 树：`SHOW SCHEMA REGIONS OF DATABASE <db>` / `SHOW DATA REGIONS OF DATABASE <db>`；表：`SHOW … REGIONS FROM <db>` | 返回**副本行**，3 副本 = 3 行/组 ⇒ 必须按 region id 去重 |
| 设备落在哪个组 | `SHOW (DATA\|SCHEMA) REGIONID WHERE DEVICE=<path> [AND timeRange]` | 用于验证"映射保留/新分区用新组" |
| 数据中心的时间分区 | `SHOW TIMESLOTID WHERE DEVICE=<path>\|REGIONID=<id>\|DATABASE=<db>`、`COUNT TIMESLOTID WHERE …` | 跨时间分区用例的判据 |
| 配置读回 | `SHOW CONFIGURATION`（或 conf 文件逐节点读取） | 默认值/热加载/一致性的自证 |
| 写入与查询正确性 | 常规 `INSERT`/`SELECT`/`COUNT` | 每例收尾必查 |

设备→slot：**BKDR131**（`BKDRHashExecutor.java`）：`hash = hash*131 + char`，`hash &= Integer.MAX_VALUE`，
`slot = hash % series_slot_num`；树模型按 `root.db.device` 全路径字符流，表模型按 `IDeviceID` 分段
（段间以 `PATH_SEPARATOR` 参与哈希，null 段以 `NULL_SEGMENT_HASH_NUM` 参与）。harness 侧实现见 `pgkit/slots.py`，
并**必须**用 `SHOW DATA REGIONID` 做交叉验证（用例 `PG-OBS-01`），不允许只信 harness 自己的哈希。

## 8. 研发自测已给出的期望值（可直接作为对照，但不是判据上限）

1. 稀疏场景（1000 槽、6 设备各占不同 slot、3 副本、2 库、每节点 Schema/Data 配额 6）：
   DN 数 3/6/9 时**每库上限 3/6/9**；AUTO Data 组数恒为 **2**，PROACTIVE Data 为 **3/6/6**；
   AUTO Schema 恒为 **1**，PROACTIVE Schema 为 **3/6/6**。
2. 逐设备写入的组数序列：AUTO Data `1,2,2,2,2,2`；PROACTIVE Data 3 节点 `1,2,3,3,3,3`、6/9 节点 `1,2,3,4,5,6`。
3. 9 节点只有 6 个不同 slot 时常规目标 6；再追加不同 slot 的批量请求可达上限 9 且不超。
4. 各组 slot 数与各节点副本数**最大差不超过 1**（该结论仅在测试规模内成立）。
5. 分槽理论（docs/127）：1000 槽下激活 100 槽平均需 **105.3** 个设备；1000 设备平均只占 **632.3** 槽；
   连续编号比随机命名覆盖更多槽。⇒ 用例设计"恰好 K 个不同 slot"时**不能**用设备数硬凑，要用 harness 计算。

## 9. 开放歧义与探针用例（结论必须写进报告，不得含糊）

| 编号 | 歧义 | 探针用例 | 判定方式 |
| --- | --- | --- | --- |
| A-01 | ~~`T = min(K,R)`（设计文档）vs 模板的"增量逼近最小组数"~~ | `PG-MIN-02` | **已由源码定案**：实现取 `T = min(R, max(min(minNum, G+\|P\|), K))`（`PartitionManager.java:670-681`）⇒ 期望 **2 组**；设计文档 §4.1.3 为简化写法，记入 `doc-gaps.md` G-01 |
| A-05 | **Disabled 误判风险（产品缺陷候选）**：`LoadCache.java:798-802` 对未缓存组返回 Disabled、`RegionGroupStatistics.java:44-46` 默认即 Disabled ⇒ ConfigNode 重启后或新组心跳未到齐时 `allMatch(Disabled)` 可能成立而**多补 1 组**（研发 IT 用"先等 Running 再请求"规避：`ExtensionIT:234-235`、`DistributionIT:934`） | `PG-DIS-07`（ConfigNode 重启后**立即**写新 slot，不等 Running）、`PG-RCV-07` | 与"重启完成后（等 Running）再请求"的对照组比较；若多补组则记为产品缺陷候选（超配），并保留 conf/日志/组快照 |
| A-02 | 需求文档 §3.2 给出"逐步满足最小组数"，设计文档 §4.1.3 说首次只建 1 个 | `PG-MIN-01` | 以两者一致的"首次只 1 个"为准 |
| A-03 | 系统库/审计库是否与用户库同一套 region 分配代码（用户提出） | `PG-SYS-01..04` | 观测系统库组数与策略生效情况，如实记录，不下"必须等于 X"的断言 |
| A-04 | `IoTConsensusV2` 下本功能是否有差异（`IoTConsensusV2ServerImpl` 提到 proactive） | 全量 V2 轮 + `PG-PROTO-01` | 源码结论 + 双协议对照表 |

## 10. 用例判定纪律（沿用既有技能口径）

1. 每个用例：**干净集群**开始（停集群 → 清 data/logs → 写 conf → 启集群 → 执行）。
2. 收尾三件套，缺一不可，且都是普通 check（任一失败则整例不得 PASS）：
   ① sync lag 有界归 0；② 全节点在线结果为基准 → 逐次 stop 1 个 DataNode 查询对比；③ ERROR/WARN 扫描三档处置。
3. `SKIP`（前置不成立，写明原因）≠ `PASS`；被不可逆操作污染的轮次记 `INVALID`，既不算 PASS 也不算 FAIL。
4. 日志三档：未预期 → `evidence/log_findings.txt`；harness 自身动作窗口内且命中归因表 → `log_attributed.txt`；
   产品自声明跳过/可忽略（需源码出处）→ `log_by_design.txt`，仅 WARN 可入此档。
5. **假 PASS 与假 FAIL 同样不可接受**：期望值不得依赖环境（例如组的物理分布、region 放置）。
6. 产品缺陷与 harness 缺陷分开登记（`DEFECT_CANDIDATES.md` vs `HARNESS_FINDINGS.md`）。

## 12 实测修正（2026-10-14，2.0.11-SNAPSHOT / master 3bbeea656114）

1. **`time_partition_interval` 单位是毫秒**，1.3.7 与 2.0.11 模板默认 `604800000`（7 天）。
   构建期曾误写 `604800`（≈10 分钟）⇒ 已修；该键**非热加载**，改后必须重启集群。
   用例必须用 `SHOW DATABASES DETAILS.TimePartitionInterval`（`ctx.api.db_time_partition_interval`）
   实时读取，**禁止硬编码**（`references/doc-gaps.md` G-09）。
2. **组数与上限可直接观测**：`SHOW DATABASES DETAILS` 的 `SchemaRegionGroupNum` /
   `MaxSchemaRegionGroupNum` / `DataRegionGroupNum` / `MaxDataRegionGroupNum`
   （`ColumnHeaderConstant.java:521-534`）。因此上限断言不必"写满逼近"，直接与
   `max(min, ceil(weight×resource/(分摊库数×rf)))` 对比即可（`cases.expect_cap`）。
3. **分摊库数必须取树+表两方言并集**：`SHOW DATABASES DETAILS` 按方言过滤，而产品
   `databaseNum` 合并计数（G-08）。已在 `cases.expected_cap()` 修。
4. **表方言不支持 `SHOW … REGIONID` / `SHOW … TIMESLOTID`**（`AstBuilder.java:1781/1785`
   抛 SemanticException）⇒ "三大观测面交叉验证"只在树模型成立（G-07）。
5. **1.3.7 没有 PROACTIVE**：模板策略默认 **AUTO**，且随包生效文件里没有策略键 ⇒
   同样的 conf 在 2.0 下语义变为 PROACTIVE（G-10，升级族核心断言点）。
6. **副本行数口径**：`SHOW … REGIONS` 一行 = 一个副本（不是逻辑组）；
   逻辑组数 = 去重 `RegionId` 数 = `SHOW DATABASES DETAILS` 的计数，两者必须一致（已实测）。
7. **收尾②口径**（用户要求）：`REPLICA_MODE=both` = 全在线基线（在每个存活 DN 上各查一遍）
   + 停 `CONSISTENCY_STOP_NODES`(默认 1) 台 DataNode 再查一遍；停全部 5 台会把每个用例
   拖到 4~5 分钟（每台都要再等一次 sync lag 归零），且不是用户口径。
8. **fixture 的 drop 会产生固有 WARN**（drop 不存在的库），已由 `reset_db` 的
   `mark_harness_action` 归因窗口覆盖；负向用例（非法值/无权限/`ON <nodeId>`）会让 DN 记录
   `ConfigExecution` WARN + 栈，必须在语句前开归因窗口，否则收尾③误判 FAIL。
9. **集群独占**：任何并发触达集群的动作（包括"另一个人/子代理跑负向 SQL"）都会污染
   当前用例的日志窗口并造成假 FAIL —— 执行纪律：一个集群只有一个 runner（实测教训）。

## 13. 首轮实测修正（2026-10-14，2.0.11 干净集群 + 209 用例集）

1. **`Max*RegionGroupNum` 是"直接可观测的上限"**：`SHOW DATABASES DETAILS` 返回
   `SchemaRegionGroupNum|MaxSchemaRegionGroupNum|DataRegionGroupNum|MaxDataRegionGroupNum`，
   不必再靠"写满看停在哪"。所有上限类断言改为"产品自报 max vs 公式实时值"对拍。
2. **`SHOW DATABASES DETAILS` 的分摊库数口径**：该表按方言过滤（树只列树库），
   而产品 `databaseNum` 把树+表普通库**一起计数**（docs/360 §253 亦如此要求）。
   ⇒ harness 的 `expected_cap()` 必须取两方言**并集**，否则上限断言会随环境残留库而假 FAIL。
3. **`time_partition_interval` 单位是毫秒**（模板默认 `604800000`=7 天）。写成 `604800`
   会让"跨时间分区"用例退化为同一分区，属 harness 缺陷（已修）。
4. **表方言没有 `… REGIONID` / `SHOW TIMESLOTID`**（`AstBuilder` 抛 SemanticException）：
   三大观测面（库详情 / `SHOW … REGIONS` 去重 / `… REGIONID`）只在树模型齐全；
   表模型用例只断言前两面 + 写入行数。
5. **`series_slot_num`、`time_partition_interval` 不可热加载**（只有 6 个 RegionGroup 键可），
   因此需要非默认槽数的用例必须换档位重启（`PG-SERIES-SLOT-NUM=100` 档）。
6. **热加载改的是节点上的 conf 文件**：`SET CONFIGURATION` 会持久化到
   `conf/iotdb-system.properties`，且 `start_all` 不会重写 conf ⇒
   "切换策略后重启"的期望值应取 `conf` 里的值，用例改过的键必须在结束前写回。
7. **表模型库的上限恒等于最小组数**（首轮实测，高置信产品缺陷，见 `DEFECT_CANDIDATES.md` D-04）：
   树库 `Max=5/60` 而表库 `Max=1/2`（= min），写 4 个不同 slot 完全不扩容。
8. **收尾③ 的日志窗口必须留"收敛尾窗"**：用例自己停 DataNode（收尾②对拍 / HA 用例）之后，
   LeaderBalancer 迁移重试、MPP 对被停节点的 block 重发会持续数分钟，甚至越界落进
   **下一个**用例的扫描窗口。归因仍要求"模式 + 窗口"双命中（`verify.extra_windows`），
   尾窗之外同样的行依旧 FAIL。
9. **V2 轮的收尾①会被单个恒 lag 的实例卡死**（D-06）：V2 干净集群上
   `DataRegion[5]` 的 `syncLag` 恒为 1.0。门禁不放宽，但要把 `SYNC_MAX_WAIT_SEC` 收紧，
   并把该轮标为"被收尾①阻塞"，不能当作 PROACTIVE 的功能结论。
10. **写入成功不等于 `select count(*)` 可读回**：首轮实测 `insert into root.pg.pgd0(...)` 成功、
    `SHOW DATA SERIESSLOTID` 可见 slot，但 `select count(*) from root.pg.pgd0.s0` 返回空集
   （列名 `Time`，非聚合列）；同轮 `root.pg.d0.s0` 正常。判定用例 `PG-OBS-06`（D-05）。
