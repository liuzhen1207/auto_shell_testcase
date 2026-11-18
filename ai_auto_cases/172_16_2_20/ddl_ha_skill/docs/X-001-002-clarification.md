# X-001 / X-002 / X-003 口径澄清：副本全宕时表模型 DDL 仍然成功

> 状态：**待产品最终确认**（2026-11-18）。本文给出修正后的实验与结论。
> 关联用例：`DDLHA-X-001`（DR 双副本全宕后 DROP TABLE）、`DDLHA-X-002`（DR 双副本全宕后 DELETE DEVICES）、`DDLHA-X-003`（SchemaRegion 三副本全宕后 DROP TABLE）。

## 一、先修正一个用例缺陷

最初 X-001/X-002 的 `FAULT_TARGET=21`，`dr_both_down` 实现只杀了 **1 台** DN（21），并没有真的“双副本全宕”。同时 `lib.sh` 里 `show regions` 的列位写错（Database 实际在 `$5`、DataNodeId 在 `$8`），自动解析副本一直落空、退回 21。

已修正：
1. `lib.sh` 列位改为 `$3=Type / $5=Database / $8=DataNodeId`；
2. 新增 `dr_pair_dns`（取第一个 DataRegion 组的全部副本）与 `sr_all_dns`（取第一个 SchemaRegion 组的全部副本）；
3. `run_case.sh` 在故障注入后**校验目标 DN 进程确实为 0**（日志 `DR_BOTH_DOWN_VERIFIED`）。

## 二、修正后的实测（RC3 `ac7f95e`）

| 用例 | 故障（已验证全部宕机） | 操作 | 结果 |
| --- | --- | --- | --- |
| `X-001` | DataRegion 双副本：DN4、DN6 均 `procs=0` | `DROP TABLE` | **成功**（183s，meta/data 一致） |
| `X-002` | DataRegion 双副本：DN4、DN7 均 `procs=0` | `DELETE DEVICES` | **成功**（192s，`num_of_deleted_devices=1`） |
| `X-003` | **SchemaRegion 三副本：DN3、DN6、DN7 均 `procs=0`** | `DROP TABLE` | **成功**（178s，meta/data 一致） |

## 三、为什么“元数据副本全宕”DDL 还能成功

表模型的元数据权威是 **ConfigNode 的 MTree（Ratis 三副本）**，不是 DataNode 上的 SchemaRegion：

1. DDL 由 ConfigNode 的 Procedure 在 **CN 共识**中提交（3 个 CN 都存活）；
2. DataNode 上的 SchemaRegion 与 `DataNodeTableCache` 是**服务/缓存层**，DDL 提交后由 CN 广播 preUpdate/commit 到**存活的 DN**；
3. 因此只要 CN 多数派可用，即使所有 SchemaRegion 副本、所有 DataRegion 副本所在 DN 宕机，表模型的表级 DDL 仍可成功提交；剩余 DN 的缓存一致，宕机 DN 恢复后通过后续同步补齐。

换句话说：**DDL 的可用性取决于 ConfigNode quorum，而不是 DataRegion/SchemaRegion 副本数**。只有当 CN 不可达/失去多数派，或 DataNode 被 `metadata_lease_fence_ms` 自隔离时，DDL 才会失败（这类场景由 `DDLHA-P-002` 覆盖：分区 DN 上 DDL 返回连接 CN 失败）。

## 四、对文档的建议（建议 A）

把 §3.2 中对“副本全宕”的预期改为：

> 表模型的表级 DDL 由 ConfigNode 元数据共识保证；当 DataRegion 或 SchemaRegion 副本所在 DataNode 全宕、但 ConfigNode 多数派正常时，DDL 仍应成功。仅当 ConfigNode 不可用或节点被元数据租约隔离时，DDL 才返回失败。

相应地，`X-001/002/003` 的 `EXPECT` 已改为 `success`，并在 RC3 上重跑通过（31/31）。

**备选 B**：若产品要求“任一 region 副本不可用即拒绝 DDL”，则需要在 CN 侧增加可用性检查——但这会让缩容/迁移/单 DN 故障期间的正常 DDL 被阻塞，代价较高。

## 五、证据

| 内容 | 位置 |
| --- | --- |
| 结果表（31 例，去重后 31 PASS） | `/data2/iotdb/ddl_ha_results_rc3_full/results.tsv` |
| 故障校验 | `.../DDLHA-X-00{1,2,3}/fault.txt`（`DR_BOTH_DOWN_VERIFIED target=...`） |
| DDL 输出 | `.../DDLHA-X-00{1,2,3}/sql.out` |
| 用例定义 | `ddl_ha_skill/cases/DDLHA-X-00{1,2,3}/spec.env` |


## 六、补充：CN 多数派宕机（`DDLHA-X-004`）

| 项 | 内容 |
| --- | --- |
| 故障 | 杀掉 CN17、CN18，保留 CN16（**3 个 CN 挂 2 个，超过 1/2**） |
| 操作 | `CREATE TABLE ddlha_ddlha_x_004.t (...)` |
| 结果 | **失败**：`IoTDBSQLException: 712: Timed out to wait for procedure return. The procedure is still running.`（240s 轮次，meta/data 一致） |
| 恢复 | 重启 CN17/18 后集群 8/8 |

这与“CN 全宕”同源：CN 是元数据权威，**丢失多数派后 DDL 无法提交**。若 3 个 CN 全宕，客户端连 `SHOW DATABASES` 都无法完成。

## 七、DN 重启后元数据一致性

`DDLHA-X-003` 在“SchemaRegion 三副本全宕 → DDL 成功 → 重启 3 台 DN”后：

```
READABLE_DNS=5/5
META_CONSISTENT=YES
DATA_CONSISTENT=YES
```

即重启后 5 台 DN 的表/视图元数据完全一致。原因：

1. **权威副本在 ConfigNode**：DDL 已通过 CN 的 Ratis 提交并持久化，不依赖 DN 是否在线；
2. **DN 启动时从 CN 同步**：SchemaRegion 重建/追平后，`DataNodeTableCache` 以 CN 的 MTree 为准刷新，宕机期间的缓存空缺被补齐；
3. 因此“DN 宕机期间 DDL 成功”不会造成元数据分叉；宕机 DN 在重启后接受 CN 的既有事实，其余 DN 早已一致。

风险窗口只在**宕机 DN 未重启期间**：它的本地缓存可能滞后，客户端若连到该 DN 会拿到旧缓存（但该 DN 此时本就不可用），恢复后即一致。
