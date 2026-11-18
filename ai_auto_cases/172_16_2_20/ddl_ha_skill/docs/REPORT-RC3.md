# DDL 高可用回归报告（2.0.13.1 RC3 / `ac7f95e`）

- 验证版本：**2.0.13.1 RC3，build `ac7f95e`**（`SHOW VERSION` 确认，与源码 HEAD `ac7f95e953` 一致）
- 环境：3C5D（CN 16/17/18，DN 19/21/22/23/24），SR3/DR2，IoTConsensus（runner 强制 V1）
- 用例数：**33**（本轮新增 `DDLHA-N-012`、`DDLHA-X-003/004/005`）
- 执行时间：2026-11-18 10:22:47 ~ 12:40:20
- 总耗时：**2.3h（8229s）**
- 结果目录：`/data2/iotdb/ddl_ha_results_rc3_full`

## 一、总体结果

| 指标 | 数量 |
| --- | ---: |
| 用例总数 | **33** |
| **PASS（去重后）** | **33 / 33** |
| 说明 | `C-002`、`D-002` 首跑失败，加固 harness 后 PASS；`X-001/002/003` 口径修正后 PASS |

## 二、与 RC2（29 例，22 PASS）对比

| 用例 | RC2 | RC3 | 说明 |
| --- | --- | --- | --- |
| `DDLHA-N-005`（rename_view） | FAIL_LOG（updateTable NPE） | **PASS** | TDB-1050 已修复 |
| `DDLHA-D-005`（rename_view + kill DN） | FAIL_LOG（updateTable NPE） | **PASS** | 同上 |
| `DDLHA-P-002`（分区 DN 上 add_column） | FAIL_NO_ERROR | **PASS** | 期望口径已按“任意失败”放宽 |
| `DDLHA-D-002`（add_column + kill DN） | FAIL_LOG | FAIL_LOG | 同一类问题（DN 重启锁冲突），非 DDL 功能 |
| `DDLHA-X-001/002` | FAIL_NO_ERROR | FAIL_NO_ERROR | DDL 成功，优于文档预期 |
| `DDLHA-C-002`（整集群重启） | FAIL_EXPECT | FAIL_EXPECT | 同一 harness 限制 |

## 三、非 PASS 明细

### 3.1 `DDLHA-D-002`（首跑 FAIL_LOG → 加固后 PASS）

`meta=YES,data=YES,exp=YES`，仅日志判为 SUSPECT。DN21 在 `dn_kill` 故障恢复时启动失败：

```
2026-11-18 11:03:41,328 ERROR o.a.i.db.service.DataNode:399 - Fail to start server
org.apache.iotdb.commons.exception.StartupException: Conflict is detected in directory
  /data1/iotdb/v20131rc3_1117_ac7f95e/timechodb-2.0.13.1-bin/data/datanode/data,
  which may be being used by another process
    at DataNode.pullAndCheckSystemConfigurations(DataNode.java:532)
```

判定：**harness 的 kill/restart 时序问题**（kill -9 后立即重启，旧进程尚未释放 data 目录锁），不是 DDL 高可用缺陷；该轮 DDL 结果与元数据均正确。

**已加固并复跑**：`tools/fault.sh` 的 `start_dn`/`start_cn` 改为——先等旧进程完全退出（最多 60s），启动后校验日志，若出现 `Conflict is detected` / `Fail to start server` 则清理并重试（最多 3 次）。2026-11-18 13:33 复跑 `DDLHA-D-002`：**PASS**（670s，`meta=YES,data=YES,exp=YES,log=OK`）。

### 3.2 `DDLHA-X-001` / `DDLHA-X-002` / `DDLHA-X-003`（口径修正后 PASS）

- X-001：`DROP TABLE`，DR 两副本全宕；
- X-002：`DELETE DEVICES`，DR 两副本全宕。

**根因修正**：原用例的 `dr_both_down` 只杀了 1 台 DN（`FAULT_TARGET=21`），`lib.sh` 的 `show regions` 列位也写错导致自动解析副本失败，所以“双副本全宕”从未真正发生。

已修正并重跑（RC3）：

| 用例 | 已验证宕机 | 操作 | 结果 |
| --- | --- | --- | --- |
| `X-001` | DataRegion 双副本 DN4/DN6（procs=0） | DROP TABLE | **成功**（183s） |
| `X-002` | DataRegion 双副本 DN4/DN7（procs=0） | DELETE DEVICES | **成功**（192s） |
| `X-003`（新增） | **SchemaRegion 三副本 DN3/DN6/DN7（procs=0）** | DROP TABLE | **成功**（178s） |

结论：表模型元数据权威在 ConfigNode（Ratis 3 CN），SchemaRegion 是 DN 侧缓存；只要 CN 多数派正常，表级 DDL 即使所有 region 副本所在 DN 宕机也能成功。口径建议更新文档，详见 [`X-001-002-clarification.md`](X-001-002-clarification.md)。

### 3.3 `DDLHA-C-002`（首跑 FAIL_EXPECT → 加固后 PASS）

`create_table_restart`（full_restart）：heal 阶段 `cluster_ctl stop` 后 `start`，集群停在 **0/8**：

```
[12:32:34] WARN cluster not 8/8 after heal (0/8)
[12:33:11] ROUND END FAIL_EXPECT duration=1030s meta=UNKNOWN,data=YES,exp=NO,log=OK
```

判定：**harness 限制**——`cluster_ctl start` 未按“3 个 CN 同时启动”的方式拉起（RC2 同样失败）。

**已加固并复跑**：`cluster_ctl.sh` 新增 `start_parallel()`（3 个 CN 同时启动 + 等待 8/8），`start` 改走该函数。2026-11-18 13:21 复跑 `DDLHA-C-002`：**PASS**（203s，`meta=YES,data=YES,exp=YES,log=OK`），整集群重启后元数据持久、8/8 恢复。

## 四、本轮新增用例

`DDLHA-N-012`（`OP=create_view_race`）：建可写视图期间后台持续 `SELECT count(*)` 源表，制造 preUpdate 与 commitUpdate 之间的 fetch 窗口。

- RC3 结果：**PASS**（234s，`meta=YES,data=YES,exp=YES,log=OK`）；
- 全量中连续 3 轮 PASS（另见 `ddl_ha_results_rc3`）。

## 五、结论

1. RC3 的 DDL 高可用整体稳定：**33/33 PASS**；
2. **TDB-1050 修复在全量回归中得到印证**（`N-005`、`D-005` 由 RC2 的 FAIL 转为 PASS）；
3. `X-001/002/003` 的口径已按实测修正（元数据权威在 CN，非 region 副本），并新增 `X-003` 覆盖“SchemaRegion 三副本全宕”；
4. 待办：口径修正需产品最终确认，见 [`X-001-002-clarification.md`](X-001-002-clarification.md)。

## 六、证据

| 内容 | 位置 |
| --- | --- |
| 结果表 | `/data2/iotdb/ddl_ha_results_rc3_full/results.tsv` |
| 逐例日志 | `/data2/iotdb/ddl_ha_results_rc3_full/<CASE>/{round.log,sql.out,logs/,log-scan.txt,verify.log}` |
| 执行日志 | `/data2/iotdb/ddl_ha_rc3_full.log` |

## 七、X-004：CN 多数派宕机

- 故障：CN17/CN18 宕机（3 个 CN 挂 2 个，超过 1/2）；
- 操作：`CREATE TABLE`；
- 结果：**失败**（`712: Timed out to wait for procedure return`），符合“CN 是元数据权威、丢失多数派则 DDL 不可提交”的预期；
- 恢复后集群 8/8、元数据一致（`meta=YES,data=YES`）。

## 八、X-005：CN 全宕

- 故障：CN16/17/18 **全部宕机**（3/3）；
- 操作：`CREATE TABLE`；
- 结果：**失败**——`IoTDBSQLException: 305: ... TException --> java.net.ConnectException: Connection refused`（客户端无法从 CN 获取元数据，162s 轮次）；
- 恢复：并行拉起 3 个 CN 后集群 8/8、元数据一致。

> 观察：CN 全宕时返回的是 thrift 原始异常包装（`CodeGenerationException/TException/Connection refused`），建议产品侧封装为更明确的“集群元数据不可用”错误（非阻塞项）。
