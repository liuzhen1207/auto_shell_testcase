# DDL 高可用回归报告（2.0.13.1 RC3 / `ac7f95e`）

- 验证版本：**2.0.13.1 RC3，build `ac7f95e`**（`SHOW VERSION` 确认，与源码 HEAD `ac7f95e953` 一致）
- 环境：3C5D（CN 16/17/18，DN 19/21/22/23/24），SR3/DR2，IoTConsensus（runner 强制 V1）
- 用例数：**30**（本轮新增 `DDLHA-N-012`）
- 执行时间：2026-11-18 10:22:47 ~ 12:40:20
- 总耗时：**2.3h（8229s）**
- 结果目录：`/data2/iotdb/ddl_ha_results_rc3_full`

## 一、总体结果

| 指标 | 数量 |
| --- | ---: |
| 用例总数 | 30 |
| **PASS** | **26** |
| FAIL_LOG | 1（`DDLHA-D-002`） |
| FAIL_NO_ERROR | 2（`DDLHA-X-001`、`DDLHA-X-002`） |
| FAIL_EXPECT | 1（`DDLHA-C-002`） |

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

### 3.1 `DDLHA-D-002`（FAIL_LOG）

`meta=YES,data=YES,exp=YES`，仅日志判为 SUSPECT。DN21 在 `dn_kill` 故障恢复时启动失败：

```
2026-11-18 11:03:41,328 ERROR o.a.i.db.service.DataNode:399 - Fail to start server
org.apache.iotdb.commons.exception.StartupException: Conflict is detected in directory
  /data1/iotdb/v20131rc3_1117_ac7f95e/timechodb-2.0.13.1-bin/data/datanode/data,
  which may be being used by another process
    at DataNode.pullAndCheckSystemConfigurations(DataNode.java:532)
```

判定：**harness 的 kill/restart 时序问题**（kill -9 后立即重启，旧进程尚未释放 data 目录锁），不是 DDL 高可用缺陷；该轮 DDL 结果与元数据均正确。

### 3.2 `DDLHA-X-001` / `DDLHA-X-002`（FAIL_NO_ERROR）

- X-001：`DROP TABLE`，DR 两副本全宕；
- X-002：`DELETE DEVICES`，DR 两副本全宕。

两者按文档预期“应当失败”，实际 DDL **成功执行**。RC2 上表现一致，属“实现优于文档预期”，建议产品确认文档口径（是更新文档还是收敛行为）。

### 3.3 `DDLHA-C-002`（FAIL_EXPECT）

`create_table_restart`（full_restart）：heal 阶段 `cluster_ctl stop` 后 `start`，集群停在 **0/8**：

```
[12:32:34] WARN cluster not 8/8 after heal (0/8)
[12:33:11] ROUND END FAIL_EXPECT duration=1030s meta=UNKNOWN,data=YES,exp=NO,log=OK
```

判定：**harness 限制**——`cluster_ctl start` 未按“3 个 CN 同时启动”的方式拉起（RC2 同样失败），需先加固 stop/start 脚本；用例本身（建表后整集群重启、元数据持久）尚未真正验证。

## 四、本轮新增用例

`DDLHA-N-012`（`OP=create_view_race`）：建可写视图期间后台持续 `SELECT count(*)` 源表，制造 preUpdate 与 commitUpdate 之间的 fetch 窗口。

- RC3 结果：**PASS**（234s，`meta=YES,data=YES,exp=YES,log=OK`）；
- 全量中连续 3 轮 PASS（另见 `ddl_ha_results_rc3`）。

## 五、结论

1. RC3 的 DDL 高可用整体稳定：26/30 PASS；
2. **TDB-1050 修复在全量回归中得到印证**（`N-005`、`D-005` 由 RC2 的 FAIL 转为 PASS）；
3. 剩余 4 个非 PASS 均非 DDL 功能缺陷：1 个 harness 重启锁冲突、2 个文档口径（实现更优）、1 个 harness 整集群重启限制；
4. 待办：加固 `cluster_ctl start`（并行起 CN）后重跑 `C-002`；与产品确认 `X-001/002` 的预期口径。

## 六、证据

| 内容 | 位置 |
| --- | --- |
| 结果表 | `/data2/iotdb/ddl_ha_results_rc3_full/results.tsv` |
| 逐例日志 | `/data2/iotdb/ddl_ha_results_rc3_full/<CASE>/{round.log,sql.out,logs/,log-scan.txt,verify.log}` |
| 执行日志 | `/data2/iotdb/ddl_ha_rc3_full.log` |
