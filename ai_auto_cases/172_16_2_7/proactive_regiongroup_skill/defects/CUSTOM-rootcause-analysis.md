# CUSTOM 行为确认（2.0.13.1 RC1 `ab6d3de`）— 设计如此，非缺陷

> 产品确认：CUSTOM 的 SchemaRegionGroup/DataRegionGroup 数量**独立于 AUTO 资源公式**计算；两个参数都为 CUSTOM 时 ConfigNode 跳过 max 重算，混合配置只重算 AUTO 的一侧；CUSTOM 通过 `ALTER DATABASE ... WITH MAX_*_REGION_GROUP_NUM` 修改上限，只能增大或保持，不能降低。

## 1. 结论

| 原疑点 | 结论 |
| --- | --- |
| CUSTOM 下 Schema=3 超过公式上限 2 | **设计如此**：CUSTOM 不参与资源上限重算，按用户 max 建组 |
| MAX_DATA=1 变成 2 | **不是缺陷**：建库被 525 拒绝，后续写入自动建了默认库 |

## 2. 源码依据

1. `PartitionManager.customExtendRegionGroupIfNecessary`（`PartitionManager.java:704`）：
   目标 = 数据库 `maxRegionGroupNum`，一次补齐，不看 slot 数、不看资源公式。
2. `ClusterSchemaManager.adjustMaxRegionGroupNum`（`ClusterSchemaManager.java:521-528`）：
   策略为 CUSTOM 的类型**跳过** `adjustRegionGroupNum`，max 保持用户设置值。
   混合配置时 `isAdjustSchemaRegionGroupNum` / `isAdjustDataRegionGroupNum` 独立判断，只重算 AUTO 的一侧。
3. `ClusterSchemaManager.validateMaxRegionGroupNum`（`ClusterSchemaManager.java:1052`）：
   `ALTER` 时校验 `max >= 当前 max`（错误 525：`should be greater than or equal to current max ...`），以及 `max >= 默认最小值`。
   因此**即使空库、尚未创建任何组**，从 4 降到 3 也会返回 525。

## 3. 实测验证（3C5D，RC1）

| # | 场景 | 实测 | 结论 |
| --- | --- | --- | --- |
| 1 | CUSTOM 建库 MAX_SCHEMA=2、MAX_DATA=3，首个分区 | **2/3** | 一次补齐到用户 max |
| 2 | `ALTER ... MAX_DATA=5, MAX_SCHEMA=3`（增大） | 仍 **2/3** | 修改上限不立即建组 |
| 3 | 再写一个新 slot | **3/5** | 新分区请求一次补齐到目标 |
| 4 | `ALTER ... MAX_DATA=2`（5→2，降低） | **525**：`should be greater than or equal to current max DataRegionGroupNum: 5` | 不能降低 |
| 5 | 空库 MAX=4，`ALTER` 到 3 | **525**：`... current max DataRegionGroupNum: 4` | 空库也不能降低 |
| 6 | `ALTER` 到 1（< 默认 2） | **525**：`... default DataRegionGroupNum: 2` | 不能低于默认最小值 |
| 7 | 混合：Schema=CUSTOM(MAX=3)、Data=AUTO，9 slot | **3/2** | Schema 保持 CUSTOM，Data 按 AUTO（9/1000 未达比例，仍为 min=2） |
| 8 | 双 CUSTOM，新增第二个库 | **1/2 不变** | 双 CUSTOM 不触发 max 重算 |

## 4. 对测试与文档的建议

1. 用例预期改为“CUSTOM 不受资源上限约束”，不再按 AUTO 公式断言；
2. 补充 `ALTER` 边界：增大不即时建组、新分区一次补齐、降低 525（含空库、含低于默认值）；
3. 文档可在 CUSTOM 说明中明确“用户配额优先、跳过资源上限重算”，避免与 3.2 的“上限控制分配数量”混淆。
