# 缺陷 TV-D5 —— **已撤回（误报）**：重启后"表库丢失"系测试并发事故

> 结论先说：**产品没有这个问题**。之前观察到的 `500: Unknown database tv_ha03`
> 是我在测试编排上的错误——**两个队列并发跑**，另一个用例的 `prepare` 把数据目录清了。
> 本文件保留完整证据链，避免后续同学再把它当成真缺陷去查。

## 1. 最初的观察

2026-10-28 10:26:04，运行 `TV-HA-03`（整集群重启用例）时，重启后查询：

```
SQL> desc tv_ha03.v
Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 500: Unknown database tv_ha03
```

连续 6 次 `desc` 都是该错误，于是初步判定为"整集群优雅重启后表模型库/视图丢失"，
当时记为疑似 P1。

## 2. 复盘：同一时刻还有另一个队列在跑

| 时间 | 事件 | 来源 |
|---|---|---|
| 10:14:08 | `TV-HA-03` 用例体开始 | `logs/tv4_TV-HA-03.log` |
| 10:14:24 | 用例内触发整集群重启（停 25 节点） | 同上 |
| 10:19:09 | 用例内 `start_all`，CN 起来 | 同上 |
| **10:20:43** | **我在另一个窗口启动了 `queue_treeview5.sh`（TV-BASE-08）** | 手工操作 |
| **10:24:29** | **该队列的 `prepare` 完成"停全部节点 + 删 data/ 与 logs/ + 重启"**，CN 起来 | `logs/tv5_TV-BASE-08.log` |
| **10:26:04** | **`TV-HA-03` 此时才查询 `desc tv_ha03.v`** → `500 Unknown database` | `logs/tv4_TV-HA-03.log` |

`prepare` 的第一步就是 `wipe()`：`rm -rf $DB_DIR/data`（见 `scripts/pgkit/cluster.py:524-536`）。
所以 10:24:29 之后集群是**全新的空集群**，10:26:04 查不到 10:14 之前建的库，是完全正常的。

**时间戳对得上，误报成立。**

## 3. 复测（干净、严格串行）

| 执行 | 时间 | 结果 |
|---|---|---|
| 主队列第 1 次 `TV-HA-03` | 10-27 18:5x | PASS（视图定义不变、重启后扩列仍生效） |
| 主队列第 3 次（误报那次） | 10-28 10:14 | FAIL（并发 prepare 导致，见 §2） |
| 复跑 1 | 10-28 11:03 | PASS |
| 复跑 2 | 10-28 11:31 | PASS |
| **`TV-REPRO-D5`（4 轮重启专项）** | 10-28 14:12–15:15 | **4/4 轮全部 OK**：每轮 `table_db_exist=True`，视图列 `['s1'] -> ['s1']` 不变 |

`TV-REPRO-D5` 的专项结论（`results/rp_TV-REPRO-D5/.../evidence/repro_d5_summary.txt`）：

```
round 1: table_db_exist=True cols=['s1'] -> ['s1'] => OK
round 2: table_db_exist=True cols=['s1'] -> ['s1'] => OK
round 3: table_db_exist=True cols=['s1'] -> ['s1'] => OK
round 4: table_db_exist=True cols=['s1'] -> ['s1'] => OK
```

累计 **8 次整集群重启（不含误报那次）全部通过**，未再出现元数据丢失。

## 4. 顺带修掉的测试侧问题

`TV-REPRO-D5` 这次唯一的 FAIL 来自收尾③ 命中的 harness 自身噪声：

```
WARN o.a.i.d.c.IoTDBDescriptor:225
  - Cannot find IOTDB_HOME or IOTDB_CONF environment variable when loading config file iotdb-system.prop
```

原因是 harness 启动节点时用 `-D` 传路径、没有导出 `IOTDB_HOME/IOTDB_CONF` 环境变量。
已加入 `HARNESS_INDUCED_PATTERNS`（`scripts/pgkit/verify.py`），按 harness 自伤归因，
不再让用例 FAIL。

## 5. 教训（写进测试纪律）

1. **同一环境严禁并发跑两个队列**：`prepare` 会 `rm -rf data/`，
   并发时会把另一个用例的库"删掉"，表现出来极像产品丢数据；
2. 判定"元数据丢失"这类问题前，**必须先核对同一时间段是否有 prepare/wipe 动作**
   （`logs/*.log` 里有 `started cn on ...`、`prepare complete` 时间戳）；
3. 后续给驱动脚本加锁（`flock`），从机制上避免重复启动队列。

## 6. 当前状态

- 该条**不作为缺陷提交**；
- `TV-HA-03` 在当前版本 `dc11a35` 上判定为 **PASS**（重启后视图定义不变、自动扩列仍生效）；
- 相关能力（整集群重启后的视图与属性持久化）由 `TV-HA-03` + `TV-REPRO-D5` 覆盖，
  建议纳入 CI 的 HA 套件并重复 5 次。
