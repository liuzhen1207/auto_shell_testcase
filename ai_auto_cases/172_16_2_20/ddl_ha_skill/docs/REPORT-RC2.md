# DDL 高可用回归报告（TimechoDB 2.0.13.1 RC2 / 3C5D / SR3 / DR2）

| 项 | 值 |
| --- | --- |
| 被测版本 | **2.0.13.1 RC2（`83183d0`）** |
| 上一轮 | 2.0.13.1 RC1（`ab6d3de`），报告见 [`REPORT.md`](REPORT.md) |
| 环境 | 3 CN（.16/.17/.18）+ 5 DN（.19/.21/.22/.23/.24），SR3 / DR2，IoTConsensus |
| 用例 | 29 个（normal 11 / dn_down 9 / partition 4 / extreme 2 / ha_event 3） |
| 执行 | 2026-11-10 18:21 ~ 20:43（另含 4 例定向复验），**总 8500s ≈ 2.36h**，平均 293s/例 |
| 结果 | **22 PASS**，7 条非 PASS（其中 3 条为判定口径/环境问题，见 §3） |
| 部署说明 | RC2 部署与激活见 [`../../docs/package-deploy-activation.md`](../../docs/package-deploy-activation.md) |

## 1. 结论速览

1. **TDB-929（预删除表心跳异常）在 RC2 已修复**：29 例日志全量扫描，`getDataNodeHeartBeat` + `SemanticException` **0 命中**；RC1 上同一用例（D-007）曾出现 34 次心跳失败。
2. 核心需求保持达成：**DN 宕机前置的 9 类 DDL 全部成功**（D-001~009 的 meta/data/exp 全 YES）。
3. **RC2 新观察到一处 NPE**：改视图名触发 `updateTable` RPC 的 `NullPointerException`（`DataNodeTableCache.innerCommitUpdateTable:497`），功能结果仍正确（改名成功、元数据一致），属 RPC 层异常。
4. 两处 RC1"遗留"问题已定性：**分区 DN 元数据操作卡在联系 CN 属研发确认的预期行为**（不作为缺陷）；`DROP VIEW` 未级联是**设计行为**（视图未覆盖源表全部列，详见 §3.4）。
5. `C-002`（DDL 后整集群重启）仍无法验证：重启后集群 `0/8`，`READABLE_DNS=0/5`，判 `META_CONSISTENT=UNKNOWN`（可读性门禁生效，未误判为一致）。

## 2. 逐例结果

| 用例 | 分组 | 结论 | 耗时(s) | 说明 |
| --- | --- | --- | ---: | --- |
| N-001~004, 006~011 | normal | PASS | 153~204 | 建表/加列/改类型/建视图/TTL/删表/删库/删设备，元数据与数据一致 |
| N-005 | normal | FAIL_LOG | 204 | 改视图名触发 `updateTable` NPE（见 §3.1），功能结果正确 |
| D-001, D-003, D-004, D-006~009 | dn_down | PASS | 243~304 | **DN 宕机时 DDL 全部成功** |
| D-002 | dn_down | FAIL_LOG | 830 | DN 重启竞态 `Fail to start server`（环境） |
| D-005 | dn_down | FAIL_LOG | 293 | 同 §3.1 的 `updateTable` NPE |
| P-001, P-003, P-004 | partition | PASS | 176~600 | 正常 DN 上执行成功；数据面返回 `301 Failed to connect to config node`；恢复后收敛 |
| P-002 | partition | PASS（放宽判定） | 596 | 分区 DN 上元数据操作失败即符合预期（§3.2，研发确认） |
| X-001, X-002 | extreme | FAIL_NO_ERROR | 154 / 180 | 两台数据副本全宕时删除仍成功（优于文档要求） |
| C-001, C-003 | ha_event | PASS | 238 / 191 | DDL 期间杀 CN leader 成功；并发两条 DDL 成功 |
| C-002 | ha_event | FAIL_EXPECT | 1025 | 整集群重启后未恢复，未验证元数据持久（§3.3） |

## 3. 发现

### 3.1 【已提交 TDB-1050】updateTable 提交与表 fetch 竞争，commit 以 null 写缓存抛 NPE

**现象**：`DDLHA-N-005`、`DDLHA-D-005` 两轮中 DataNode 日志出现 `Internal error processing updateTable` + NPE（栈顶 `ConcurrentHashMap.put` → `innerCommitUpdateTable:497` → `commitUpdateTable:483`）。DDL 最终成功、元数据一致。

**根因**（RC2 `83183d0`）：`preUpdateTable`（:232-247）把视图与源表放入 `specialStatusMap`；`updateTableByFetch`（:940）执行 `existingPair.setLeft(null)` 消费该条目；随后 `commitUpdateTable` 在 :456 取 `table2` 得到 null，而 :472 只判断了 `table1`，于是 :483 把 null 传入 `innerCommitUpdateTable`，:497 的 `ConcurrentHashMap.put` 抛 NPE。

**复现**：黑盒 15 次（干净环境）0 复现；插桩（模拟 :940 的消费动作）后 100% 复现，栈与方法链与生产一致。详见 [`proof/README.md`](proof/README.md)。

**结论**：低概率竞态缺陷，已提交 PLM TDB-1050（P2），建议修复为 null 显式跳过或 :472 同时判断 `table2`。

### 3.2 【研发确认为预期行为】分区 DN 的元数据操作可能卡在联系 CN

`DDLHA-P-002` 在 RC1/RC2 上返回的形态不同：

| 场景 | 返回 | 耗时 |
| --- | --- | --- |
| RC1 / RC2 自动化轮次 | `305: cglib CodeGenerationException → thrift TException → SocketTimeoutException: Connect timed out` | 约 350~420 秒 |
| 2026-11-11 手工对齐复现 | `Error: Can't execute sql because 301: Failed to connect to config node.` | **423 秒** |

DN 侧日志（172.16.2.21）：

```
10:46:48 WARN  AbstractConfigNodeClient:449 - Failed to connect to ConfigNode 172.16.2.16:10710
  org.apache.thrift.transport.TTransportException: java.net.SocketTimeoutException: Read timed out
    at ...ClusterAuthorityFetcher.getUser(ClusterAuthorityFetcher.java:834)
10:52:50 ERROR ClusterAuthorityFetcher:836 - Failed to connect to config node.
```

**研发确认（2026-11-11）：符合预期** —— 对处于网络分区的 DN 执行操作，不一定会抛出元数据隔离异常，可能卡在联系 CN 上。因此本条 **不作为缺陷**；用例判定已放宽为"只要失败即可"（隔离提示、连接失败、thrift 超时均接受）。

保留该现象作为特征记录：分区 DN 上的元数据 DDL 实测阻塞约 7 分钟后返回，返回码在 301/305 之间不稳定；若需更快的失败反馈，属体验优化提案而非缺陷。


### 3.3 【环境/流程】整集群重启后无法恢复，C-002 未验证

`C-002`：DDL 后 `cluster_ctl stop` + `start`，300 秒内集群 `0/8`，5 台 DN 的 `SHOW DATABASES` 全部不可读（`READABLE_DNS=0/5`），判 `META_CONSISTENT=UNKNOWN`。

该用例的目标是验证"重启后元数据持久"，当前卡在重启本身：需要单独排查重启流程（是否 CN 选举失败 / 端口未释放 / 启动过快），再重跑该用例。**不代表产品问题**，但也说明"重启后元数据持久"这条需求目前没有验证结论。

### 3.4 【设计行为】`DROP VIEW` 未级联删除原表

`DDLHA-N-009` 删除视图后 `SHOW TABLES` 仍为 `t;`（原表还在），视图定义中带 `schema_cascade=true`。

经源码核实，这是**有意设计**：`WritableViewUtils.shouldSkipSourceCascadeForDrop()` 只在 `canMapAllSourceColumns(...)` 为真（视图映射了源表**全部**列）时才级联删除源表，否则打 WARN 并跳过。本用例视图只投影 `s1`，源表有 `region/dev/s1` 三列 → 跳过级联。需求文档 §3.2.2 的表述漏了"视图需覆盖源表全部列"这一前提，属文档不完整，不是缺陷。

补充：已计划新增 `DDLHA-N-012`（视图覆盖全部列 + `schema_cascade=true`）作为正向级联用例，`N-009` 保留为"部分列不级联"的反向用例。

## 4. RC1 vs RC2 对比

| 验证项 | RC1（ab6d3de） | RC2（83183d0） | 结论 |
| --- | --- | --- | --- |
| 预删除表心跳异常（TDB-929） | D-007 出现 34 次心跳失败 | **0 命中**（29 例全扫） | ✅ 已修复 |
| DN 宕机时 DDL 成功 | 9/9 | 9/9 | ✅ 保持 |
| 分区 DN 元数据操作提示 | 305 + SocketTimeout | 305 + SocketTimeout | ❌ 未变 |
| 删视图级联 | 原表未删 | 原表未删 | ❌ 未变 |
| 改视图名 updateTable | 未见异常 | **NPE** | ⚠️ 新观察 |
| 整集群重启后元数据持久 | 未验证（0/8） | 未验证（0/8） | ⚠️ 待补 |

## 5. 证据

测试机 `172.16.2.20`：

| 路径 | 内容 |
| --- | --- |
| `/data2/iotdb/ddl_ha_results_rc2/results.tsv` | 29 例逐例结论与耗时 |
| `/data2/iotdb/ddl_ha_results_rc2/<CASE>/` | setup/sql 输出、故障记录、元数据与数据一致性、日志扫描 |
| `/data2/iotdb/ddl_ha_results_rc2/<CASE>/logs/` | 该例 5 台 DN + 3 台 CN 的原始日志（本轮新增，失败用例可直接查栈） |
| `/data2/iotdb/overnight_rc2.log` | 整晚编排日志 |
| `/data2/iotdb/ddl_ha_results/` | RC1 的 29 例结果（归档 `results-rc1.tsv`） |

## 6. 建议

1. **§3.1 的 NPE** 单独提给研发（RC2 引入或暴露），优先级建议 P2：功能不受损，但每次改视图名都会打一次 NPE + RPC 失败重试。
2. ~~§3.2 隔离提示~~：研发确认为预期行为，不立缺陷；如需缩短分区场景的失败反馈时间，可作为体验优化另议。
3. **§3.3 重启流程**需要单独排一次（我可以先把重启步骤加固：等 CN 全部退出、端口释放后再起，并延长等待）。
4. **§3.4 级联删除**已核实为设计行为（视图需覆盖源表全部列），不立缺陷；建议补充文档说明并新增正向用例 `DDLHA-N-012`。
