# 树转表视图 × Pipe（数据同步）场景 —— 用例与实测结论

被测版本：`master_1026_dc11a35`（BuildInfo **dc11a35**）
环境：**20 个节点拆成两套独立集群**（10 + 10），每套 **5 CN + 10 DN / SchemaRegion 5 副本 / DataRegion 3 副本**：

| 角色 | 节点 | conf | 说明 |
|---|---|---|---|
| **发送端** sender | 172.20.70.100–109 | `conf/cluster.pipe_sender.conf`（`NODES_FILE=conf/nodes.pipe_sender.conf`） | 建视图、写数据、建 pipe |
| **接收端** receiver | 172.20.70.110–119 | `conf/cluster.pipe_receiver.conf`（`NODES_FILE=conf/nodes.pipe_receiver.conf`） | 只读副本，校验同步结果 |

pipe sink 目标：`PIPE_RECEIVER_NODES=172.20.70.110:6667`（写在 sender conf 里）。

## 1. 关键实测结论（本环境已验证）

| # | 结论 | 证据 |
|---|---|---|
| 1 | **视图元数据可经 pipe 同步**：`with source ('inclusion'='schema')` 的 pipe 能在接收端建出同名视图（列定义一致） | TV-PIPE-01 PASS |
| 2 | **视图数据可同步**：另建一条树数据 pipe（`inclusion='data.insert, schema.timeseries'`）后，接收端 `select` 视图结果与发送端逐行一致 | TV-PIPE-02 |
| 3 | **auto_sync 新列随 pipe 下发**：发送端 `auto_sync_schema=true` 自动加列 `s9`，接收端视图同步出现 `s9` 且类型 `INT64` 一致 | TV-PIPE-03（功能三项全 ok） |
| 4 | **`inclusion='all'` 不同步视图**（与需求 doc 90 §3.3 一致，属**预期行为**） | TV-PIPE-04（负向） |
| 5 | `inclusion='schema.table'` **不包含视图**，必须用 `'schema'` | 探针实测：`schema.table` → 接收端 `Unknown database`；`schema` → 建库+建视图成功 |
| 6 | pipe 名称带 `sql_dialect` 语义：发送端用 **table 方言**建的 pipe 才会同步表模型对象（`show pipes` 里可见 `__system.sql-dialect=table`） | `show pipes` |

> ⚠️ 一个容易踩的坑：`inclusion` 多值要用 **逗号+空格**（`'data.insert, schema.timeseries'`）。
> 写成 `'data.insert,schema.timeseries'`（无空格）会报 `1107: The 'inclusion' string contains illegal path`，
> 但报错后 pipe **可能已经建出来**（`create pipe` 部分成功），后续 `show pipes` 看不到预期状态。

## 2. 用例（`scripts/pgkit/cases_tv_pipe.py`，9 条）

| 用例 | 覆盖点 | 判定 |
|---|---|---|
| `TV-PIPE-01` | 视图元数据（CREATE VIEW）同步 | 接收端能 `desc` 且列集合与发送端一致 |
| `TV-PIPE-02` | 视图数据一致（元数据 pipe + 树数据 pipe） | 接收端 `select` 与发送端逐行相同 |
| `TV-PIPE-03` | **auto_sync 自动加列 → 接收端**（核心） | 接收端 `desc` 出现新列且类型一致 |
| `TV-PIPE-04` | `inclusion='all'` 不同步视图（需求负向） | 接收端仍无该视图 |
| `TV-PIPE-05` | ALTER VIEW `RENAME COLUMN` / `DROP COLUMN` 同步 | 接收端列变化跟随 |
| `TV-PIPE-06` | `DROP VIEW` 同步 | 接收端视图消失 |
| `TV-PIPE-07` | 接收端**只读**：对视图写入失败且不影响发送端 | 写入报错、发送端数据不变 |
| `TV-PIPE-08` | 接收端 DN 停机期间发送端继续写+扩列，恢复后**追平** | 恢复后新列/新数据在接收端可见 |
| `TV-PIPE-09` | pipe 健康度：两条 pipe RUNNING、无 ExceptionMessage | `show pipes` 状态 |

## 3. 运行方式

pipe 用例**必须两端都 prepare**，用专用驱动（不要用 `run_case_clean.sh`）：

```bash
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW
# 单条（内部会先 prepare 发送端、再 prepare 接收端，然后跑用例）
bash treeview_5c20d/run_pipe_case.sh conf/cluster.pipe_sender.conf pipe TV-PIPE-03
# 批量（严格串行）
bash treeview_5c20d/queue_pipe.sh
```

日志与结果：
- 运行日志：`/data1/iotdb/5c20dtest/testcase/PIPE/logs/<run>_<CASE>.log`
- 结果：`TREEVIEW/treeview_5c20d/results/<run>_<CASE>/`（`result.json`、`actions.log`、`evidence/`）
- FAIL 时自动备份**两端**（sender + receiver）的 CN/DN 日志到 `evidence/logs/`

## 4. 与既有缺陷的关系

pipe 用例触发的产品问题与单集群回归一致，不新增独立缺陷：

| 现象 | 归属 |
|---|---|
| `ViewColumnAutoSyncTrigger:141/149` ERROR（发送端 DN） | **TV-D1**（见 `DEFECT_TV_D1_final.md`） |
| `SET PROPERTIES auto_sync_schema=true` 类型冲突静默成功 | **TV-D2** |
| 建视图预期失败记 ERROR | **TV-D3** |

`TV-PIPE-03` 的 3 项功能断言全部通过，用例整体 FAIL 仅因 TV-D1 日志噪声（与单集群口径一致）。

## 5. 覆盖矩阵更新

原 `COVERAGE_TREEVIEW.md` §1.5 里"未覆盖"的两项，现已覆盖：

| 原未覆盖项 | 现状 |
|---|---|
| 表模型 pipe 同步 VIEW；树模型 inclusion=all 的 pipe 不同步 view | ✅ `TV-PIPE-01/02/04` |
| auto_sync 与 pipe 的联动（新列能否下发到下游） | ✅ `TV-PIPE-03`（已验证可下发） |

仍未覆盖：鉴权（需多用户）、`SQL SECURITY invoker/definer`、老版本升级兼容、未命中视图的写入性能基线。
