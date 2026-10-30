# 文档与实现不一致（doc gaps）

**性质**：这些是**文档问题**，不作为产品缺陷登记；但必须在报告里明确，避免后续回归按错误文档判定。

| 编号 | 位置 | 文档说法 | 实现（源码证据） | 处置 |
| --- | --- | --- | --- | --- |
| G-01 | 设计 docs/341 §4.1.3 | `T = min(K, R)`（只按不同 slot 数与上限取小；并据此说"首次只建 1 个"） | `PartitionManager.java:670-681`：`T = min(R, max(min(minNum, G+|P|), K))`，即**先增量逼近最小组数再按 slot 取大**。首次 `G=0,K=1` 仍只 1 个（两口径一致），但 `G≥1`、`minNum > G+|P| > K` 时不同（`PG-MIN-02` 期望 2 组而非 1 组） | 用例按**代码**判定；报告注明文档需修正 |
| G-02 | `RegionGroupExtensionPolicy.java:42-50` + `ManagerMessages(en).properties:78-79` | 需求 §3.2 要求非法值"拒绝并给出既有配置错误" | 拒绝行为正确，但错误消息**恒为** `DataRegionGroupExtensionPolicy %s doesn't exist.`，即使解析的是 `schema_region_group_extension_policy` ⇒ 提示误导 | 用例 `PG-DFT-07` 记录原文；报告注明文案缺陷（非功能缺陷） |
| G-03 | `series_slot_num` | 需求 §3.2"首次启动确定"，模板标注 `first_start` | 一致；但阈值计算存在**两个来源**：`DataPartitionPolicyTable.java:46` 用 `static final SERIES_SLOT_NUM = CONF.getSeriesSlotNum()`（类加载时快照），`PartitionManager.java:745` 用 `CONF.getSeriesSlotNum()`（实时）。非 PROACTIVE 的 `mu = SERIES_SLOT_NUM / G` 因此与"当前配置"可能不一致 | 用例 `PG-LIM-13/14` 记录实际行为；报告注明来源分裂 |
| G-04 | 发行包默认值 | 设计 §4.3.3"参数初始值与发布配置模板均为 PROACTIVE" | 标准包成立（`conf/iotdb-system.properties.template:848/891`，生效文件不含键 ⇒ 走代码默认）；**edge/精简包**为 `CUSTOM`（`node-commons/assembly/resources/conf/edge/iotdb-system.properties:137/139`） | 本次只覆盖标准包；报告注明 edge 包需单独确认 |
| G-05 | 设计 §4.3.3 自述 | "该记录不包含此后默认值改为 PROACTIVE 的专项验证" | — | 本次 `PG-DFT-01/02`、`PG-SMK-01` 正是该专项验证 |
| G-06 | 需求 §3.3.2 升级 | "旧版本不能解析新策略值，混合版本阶段应显式保持旧版本支持的策略" | 与实现一致（枚举严格匹配）；但需求未说明**回退失败时的报错形态** | `PG-UPG-04/11` 记录实际报错 |

## G-07 表方言不支持区域/时间槽观测子句（harness 必须按方言分流）

`AstBuilder.java:1781/1785`：`SHOW (DATA|SCHEMA) REGIONID` 与 `SHOW (TIMESLOTID|TIMEPARTITION)`
在**表方言**被判定 not supported（抛 `SemanticException`），因此"三大观测面交叉验证"
（`SHOW DATABASES DETAILS` ↔ `SHOW … REGIONS` ↔ `SHOW … REGIONID`）**只在树模型成立**；
表模型只有前两面。用例不得在表方言下发 `SHOW … REGIONID`/`SHOW TIMESLOTID` 并期望成功。

## G-08 `SHOW DATABASES DETAILS` 按方言过滤，而产品的 databaseNum 合并计数

`ColumnHeaderConstant.showDatabasesDetailColumnHeaders:521-534` 的 `SHOW DATABASES DETAILS`
按当前方言列出库（树方言只列树库、表方言只列表库）；但上限公式的分母 `databaseNum`
（`ClusterSchemaManager.java:520-550`）把**树 + 表两类普通库一起**计数。
⇒ harness 估算上限时必须取两个方言的**并集**，否则"树库 root.pg + 表库 pg 并存"时
分母少算一半、上限算大，造成假 FAIL。`cases.expected_cap()` 已按并集实现（2026-10-14 修）。

## G-09 `time_partition_interval` 的单位是**毫秒**（harness 曾写错 1000 倍）

1.3.7 与 2.0.11 的发布模板默认值都是 `time_partition_interval=604800000`（= 7 天，**毫秒**）。
构建期 conf 曾写成 `604800`（≈10 分钟），会让"时间分区边界/跨分区"类用例落在与设计
意图不符的窗口上（用例读 `SHOW DATABASES DETAILS` 的 `TimePartitionInterval` 实时自洽，
但语义漂移）。已修为 `604800000`。**该键非热加载**，改后需重启（prepare/重启生效）。

## G-10 1.3 → 2.0 升级时"策略默认值"会发生语义变化（升级族核心测点）

1.3.7 的模板里策略键存在但默认是 **AUTO**（`iotdb-system.properties.template:699/:723`，
注释只列 CUSTOM/AUTO），且**随包发布的生效文件 `conf/iotdb-system.properties` 里没有策略键**
⇒ 1.3 cluster 实际按 AUTO 运行。升级到 2.0.11 后同样的配置文件（无策略键）会走 2.0 的代码
默认 **PROACTIVE** ⇒ **升级后行为从"不积极扩容"变为"积极扩容"**。这是升级族可精确断言的点：
① 无显式配置 ⇒ 升级后为 PROACTIVE；② 1.3 里显式写过 `=AUTO` ⇒ 升级后仍为 AUTO（文件优先于默认值）。
