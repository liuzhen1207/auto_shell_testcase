# 树转表视图 × Pipe（数据同步）—— 执行结果报告

- 版本：`master_1026_dc11a35`（2.0.11-SNAPSHOT，BuildInfo **dc11a35**）
- 环境：**20 节点拆两套集群**，每套 **5 CN + 10 DN / SchemaRegion 5 副本 / DataRegion 3 副本**，`IoTConsensus`
  - 发送端 172.20.70.100–109（`conf/cluster.pipe_sender.conf`）
  - 接收端 172.20.70.110–119（`conf/cluster.pipe_receiver.conf`）
- 用例：`scripts/pgkit/cases_tv_pipe.py`（9 条）
- 驱动：`run_pipe_case.sh`（每条两端 prepare）；组：`run_pipe_group.sh`；总入口 `regress_all.sh`
- 收尾：① syncLag=0 ② 副本一致性（全在线基线 + 一次性停 2 台 DN）③ **CN/DN 日志扫描：两端共 30 节点**

## 1. 结果总览

| 用例 | 覆盖点 | 结果 | 说明 |
|---|---|---|---|
| TV-PIPE-01 | 视图元数据（CREATE VIEW）经 pipe 同步 | **PASS** | 接收端 `desc` 列集合与发送端一致 |
| TV-PIPE-02 | 视图数据一致（元数据 pipe + 树数据 pipe） | **PASS** | 接收端查询与发送端逐行一致 |
| TV-PIPE-03 | **auto_sync 自动加列随 pipe 下发** | FAIL | 功能 3 项全 ok；仅因发送端 **TV-D1** 日志 |
| TV-PIPE-04 | `inclusion='all'` 不同步视图（需求负向） | FAIL | 功能 ok；仅因接收端 **TV-D6** 日志 |
| TV-PIPE-05 | ALTER VIEW rename / drop column 同步 | **PASS** | 接收端列变化跟随 |
| TV-PIPE-06 | DROP VIEW 同步 | **PASS** | 接收端视图消失 |
| TV-PIPE-07 | 接收端只读（写入失败且不影响发送端） | **PASS** | 写入被拒，发送端数据不变 |
| TV-PIPE-08 | 接收端 DN 停机期间继续写+扩列，恢复后追平 | FAIL | 功能 2 项全 ok（s7 追平、d7=7.5 追平）；仅因发送端 **TV-D1** 日志；重连噪声已归因 |
| TV-PIPE-09 | pipe 健康度（RUNNING/无异常） | **PASS** | 需按方言分别查 `show pipes` |

**功能面结论：9/9 的检查项全部符合需求**（含"`all` 不同步视图"这条负向需求）。

| 统计 | 值 |
|---|---|
| PASS | **6**（01/02/05/06/07/09） |
| FAIL | **3**（03/08 → TV-D1；04 → TV-D6） |
| 功能断言通过率 | **9/9 用例全过**（3 条 FAIL 全部是日志层面，且都能归属到已有缺陷） |

## 2. 关键实测语义（供研发/后续用例参考）

| # | 结论 |
|---|---|
| 1 | 同步**视图元数据**必须用 `with source ('inclusion'='schema')`；`schema.table` 与 `all` 都**不会**同步视图 |
| 2 | 同步**视图数据**需要另一条树数据 pipe：`'data.insert, schema.timeseries'` |
| 3 | **auto_sync 自动加列能随 pipe 下发**（列名小写映射、类型都一致） |
| 4 | `show pipes` 是**方言相关**的：表 pipe 只在 table 方言、树 pipe 只在 tree 方言可见 |
| 5 | `inclusion` 多值必须"逗号 + 空格"；无空格会报 `1107 illegal path`（但 pipe 可能已部分建成） |

## 3. 缺陷归属

| 现象 | 用例 | 归属 |
|---|---|---|
| 发送端 `ViewColumnAutoSyncTrigger:141/149` ERROR（305/552） | TV-PIPE-03、TV-PIPE-08 | **TV-D1（已录 PLM `TDB-890`，陈耀斌）**（`DEFECT_TV_D1_final.md`） |
| 接收端 `ClusterConfigTaskExecutor:523` WARN（501 already exists） | TV-PIPE-04 | **TV-D6** —— 已由上游 [PR #19054](https://github.com/apache/iotdb/pull/19054) 修复（open），`TV-PIPE-04` 作为回归验证点 |
| 接收端停机期间的 `PipeConnectionException` / handshake retry / subtask retry WARN | TV-PIPE-08 | **非缺陷**：fault injection 必然产物，已加入 harness 归因窗口 |

## 4. 双集群日志检查的价值

`TV-D6` 是**单集群回归永远扫不到**的问题（只有接收端才有该日志）。
本次把 `LOG_SCAN_EXTRA_CONFS=conf/cluster.pipe_receiver.conf` 加进发送端 conf 后，
收尾③ 一次扫描 **30 个节点**，接收端命中以 `R:` 前缀标注，报告中可直接区分。

## 5. 复现

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW
# 单条
bash treeview_5c20d/run_pipe_case.sh conf/cluster.pipe_sender.conf pipe TV-PIPE-03
# 整组（组前后各 teardown 两端）
bash treeview_5c20d/run_pipe_group.sh
# 全量回归（单集群 46 条 → pipe 组 9 条）
bash treeview_5c20d/regress_all.sh
```

证据：`TREEVIEW/treeview_5c20d/results/<run>_<CASE>/{result.json,actions.log,evidence/}`；
FAIL 时 `evidence/logs/` 含**两端** node 级日志归档。

## 6. 未覆盖（需额外条件）

| 项 | 原因 |
|---|---|
| 双向 pipe（接收端也写回发送端） | 需求未要求，且与本特性的"只读下游"定位不符 |
| 视图 TTL(`ttl`) 属性跨集群一致性 | 当前 pipe 只同步 table/view 的 schema 与数据；ttl 是否随 `schema` 下发未验证 |
| 断链期间的**数据不丢**（精确条数） | 本用例只校验"追平后可见"，未做逐条计数 |
