# DN 失联期间新建序列，树转表视图会静默丢列（含日志证据）

| 项目 | 内容 |
| --- | --- |
| 需求 | TDB-343 树转表视图自动扩列 |
| 设计文档 | PLM `docs/913` §4.2.3（隔离状态）、§4.3.3（尽力而为 / 重试） |
| 复现版本 | **RC1** 2.0.13.1 / `ab6d3de`；**RC2** 2.0.13.1 / `83183d0`（两版均复现） |
| 复现概率 | RC1：4 轮丢 2；RC2：7 轮丢 3（约 40~50%） |
| 关联用例 | RN-204（稳定断言 + 丢列观察项） |
| 严重程度 | 建议 P2：数据不丢，但**视图永久缺列且用户无感知**，需人工干预 |

---

## 一、现象

1. 视图已开启 `auto_sync_schema=true`；
2. `kill -STOP` 冻结一台 DN（等价于该节点失联/无响应，集群 20s 后标记 `Unknown`）；
3. 冻结期间在视图 prefix 下 `create timeseries`，**返回成功**；
4. `kill -CONT` 恢复，集群回到 8/8；
5. 该测点对应的列**没有**出现在视图里，等待 120s 仍不出现；
6. 之后新建的其他测点正常补列。

**关键点：客户端全程无任何错误提示**，只有服务端日志里的 WARN/ERROR。

## 二、复现步骤

```bash
NEW=<build>; CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
Q() { $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "$1"; }
T() { $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree  -e "$1"; }

D=demo_$(date +%H%M%S)
Q "CREATE DATABASE $D"
T "create timeseries root.$D.dev01.s1 double"
Q "create view $D.v1(dev string tag) with(auto_sync_schema = true) as root.$D.**"

PID=$(ssh root@172.16.2.6 "pgrep -f com.timecho.iotdb.DataNode | head -1")
ssh root@172.16.2.6 "kill -STOP $PID"; sleep 12
T "create timeseries root.$D.dev01.frozen_col double"    # 返回 successfully
ssh root@172.16.2.6 "kill -CONT $PID"
# 等 8/8 后 25s 检查：
Q "desc $D.v1"      # 约 40~50% 的情况看不到 frozen_col
```

复现脚本（跨版本）：`/tmp/verify_frozen_rc2.sh <build_dir>`、`/tmp/collect_defect_logs.sh <build_dir>`。

## 三、实测数据

### RC1（ab6d3de，4 轮）

| 轮次 | 冻结期间写入 | 恢复后 120s | 之后新建测点 |
| --- | --- | --- | --- |
| 1 | 成功 | 有列 | 正常 |
| 2 | 成功 | **丢列** | 正常 |
| 3 | 成功 | 有列 | 正常 |
| 4 | 成功 | **丢列** | 正常 |

### RC2（83183d0，7 轮）

| 轮次 | DB | 结果 |
| --- | --- | --- |
| 1 | defect_frozen_173243 | 有列（procedure 重试成功） |
| 2 | defect_frozen_173551 | 有列 |
| 3 | **defect_frozen_173705** | **丢列** |
| 4 | defect_frozen_173812 | 有列 |
| 5~7 | verify_frozen_rc2 三轮 | 丢 2 次 |

## 四、根因链（RC2 丢列轮 defect_frozen_173705，时间轴）

扩列不是 DN 直接写元数据，而是走 CN 的 `AddTableColumnProcedure`（三阶段：pre-release → add column → commit-release）。
当有 DN 处于 `Unknown` 时，pre-release 需要「证明该 DN 已被 fence」，这一步会反复超时：

```
# CN 172.16.2.26（ProcedureCoreWorker-8）
17:37:23,052 INFO  AddTableColumnProcedure:83  - Column check for table defect_frozen_173705.v1 when adding column
17:37:23,056 INFO  AddTableColumnProcedure:88  - Pre release info of table ... when adding column
17:37:28,056 ERROR AsyncRequestManager:155    - Timeout during UPDATE_TABLE. Retry: 0/2
17:37:28,057 ERROR DataNodeTSStatusRPCHandler:101 - Failed to UPDATE_TABLE on DataNode: {id=7, ...172.16.2.6:10730},
                  exception: ...updateTable_call timed out after 5000 ms
17:37:33,057 ERROR AsyncRequestManager:155    - Timeout during UPDATE_TABLE. Retry: 1/2
17:37:33,058 WARN  AsyncRequestManager:170    - Failed to UPDATE_TABLE after 2 retries, requestIndices: [7]
17:37:33,058 WARN  AbstractAlterOrDropTableProcedure:183 - Failed to pre-release add view column
                  for table defect_frozen_173705.v1 to DataNode, failure results: Failed to prove DN is fenced
17:37:33,068 INFO  AddTableColumnProcedure:249 - Start rollback pre release info of table ...
17:37:38,069 ERROR ... updateTable_call timed out after 5001 ms
17:37:43,070 WARN  AbstractAlterOrDropTableProcedure:274 - Failed to rollback pre-release add view column
                  ... failure results: Failed to prove an unreachable DataNode is fenced
```

DN 侧：健康副本先 pre-update 成功，随后回滚也成功；**最终因 CN 返回 507 而放弃扩列**：

```
# DN 172.16.2.3 / .4 / .5（健康副本）
17:37:23,055~060 INFO DataNodeTableCache:247 - Pre-update table defect_frozen_173705.v1 successfully
17:37:33,067~072 INFO DataNodeTableCache:331 - Rollback-update table defect_frozen_173705.v1 successfully
17:37:43,089~094 ERROR ViewColumnAutoSyncTrigger:156 - Failed to add a column to the view
                  defect_frozen_173705.v1 for operation 1,
                  ConfigNode returned TSStatus(code:507, message:Rollback pre-release add view column failed).
```

**结论**：一个 DN 不可达 → pre-release 与 rollback 都因「无法证明该 DN 已 fence」失败 → 扩列整体失败 →
DN 侧 `ViewColumnAutoSyncTrigger` 收到 507 后**放弃该类（不再重试）** → 该列永久缺失。

### 与「重试成功」轮次的对比（defect_frozen_173243，同一环境）

```
17:33:22,349 INFO  AddTableColumnProcedure:83  - Column check ... v1
17:33:22,356 INFO  DataNodeTableCache:247 - Pre-update table ... successfully
17:33:32,358 WARN  AbstractAlterOrDropTableProcedure:183 - Failed to pre-release ... (Failed to prove DN is fenced)
17:33:32,370 INFO  AddTableColumnProcedure:249 - Start rollback ...
17:33:42,372 WARN  AbstractAlterOrDropTableProcedure:274 - Failed to rollback ...
17:33:42,728 INFO  AddTableColumnProcedure:83  - Column check ... v1            ← 第二次 procedure
17:33:42,733 INFO  DataNodeTableCache:247 - Pre-update table ... successfully
17:33:42,736 INFO  AddTableColumnProcedure:93  - Add column to table ... v1
17:33:42,742 INFO  AddTableColumnProcedure:97  - Commit release info ... v1
```

即：**重试确实存在，但只有约一半概率赶上**；没赶上的那次列就丢了。

## 五、日志位置（重要更正）

| 日志 | 位置 | 内容 |
| --- | --- | --- |
| **专门日志（有！）** | DN：`logs/log_datanode_view_column_auto_sync_error.log` | `ViewColumnAutoSyncTrigger:156 - Failed to add a column to the view <db>.<view> for operation N, ConfigNode returned TSStatus(code:507, ...)` |
| DN 主日志 | `logs/log_datanode_all.log` | 同上 ERROR |
| CN 主日志 | `logs/log_confignode_all.log` | `AbstractAlterOrDropTableProcedure:183/274` WARN + `AsyncRequestManager` 超时 ERROR |

> 更正说明：早前结论"日志完全静默"是**错误**的——当时只 grep 了 `log_datanode_all.log` 且关键词写成
> `add view column`，实际文案是 `Failed to add a column to the view`；专门日志文件确实存在。

## 六、与需求/设计文档的差异

设计文档 §4.2.3：

> - 集群模式（DN 数量 >=3）：DN 上的 follower 和 leader 存在一个健康的节点，apply log 的时候都会去触发扩列，
>   **所以一个 DN 处于隔离状态不影响视图去自动扩列**。

实测：3C5D（远超 3 个 DN）下仍会丢列，原因是 **CN 侧 procedure 的 fence 证明失败**，而不是"没有副本触发"。
即文档对故障域的判断不完整：只考虑了 DN 侧触发，没考虑 CN 侧元数据 procedure 在 DN 不可达时的可用性。

另外文档提到"视图永远缺少该列，会在专门的日志文件中记录" —— 日志这部分属实（见第五节），
但"永久缺失"这一点**没有任何补偿机制**，也**没有用户可见提示**。

## 七、建议

1. **确认是否属于缺陷**：在 ≥3 DN 的集群里，单 DN 短暂失联不应导致扩列失败（按文档表述）；
2. **降低 fence 依赖**：pre-release 阶段是否必须等不可达 DN 的 fence 证明？可考虑对不可达节点快速跳过（该 DN 恢复后由 init 重建索引即可）；
3. **恢复后补偿**：DN 恢复（`kill -CONT` / 重连）后触发一次 `detectMissingColumnsAfterCreation()` 补扫，可自动补齐；
4. **用户可见性**：至少提供可查询的"补列失败"信息（指标或 `show` 命令），而不是只写日志；
5. **文档**：若确认为"尽力而为"的正常语义，请在需求/手册中写明「节点失联期间的扩列可能丢失，需人工 `ALTER VIEW ADD COLUMN`」，并给出命令示例。

## 八、附件（日志切片）

目录：`docs/logs/defect_617_173705/`

| 文件 | 说明 |
| --- | --- |
| `cn_26_warn_err.log` | CN26 窗口内全部 WARN/ERROR（含 `Failed to prove DN is fenced`、RPC 超时） |
| `cn_26_dbmention.log` | CN26 窗口内提及该库的全部行（含 procedure 各阶段耗时） |
| `dn_{2,3,4,5,6}_dbmention.log` | 各 DN 窗口内提及该库的行（pre-update / rollback / ViewColumnAutoSyncTrigger ERROR） |
| `dn_{2,3,4,5,6}_warn_err.log` | 各 DN 窗口内 WARN/ERROR（含 Raft heartbeat 超时） |

专门日志抽样（`log_datanode_view_column_auto_sync_error.log`）：

```
17:36:29,112 [3@group-...] ERROR ViewColumnAutoSyncTrigger:156 - Failed to add a column to the view
             defect_frozen_173551.v1 for operation 1, ConfigNode returned TSStatus(code:507, message:Rollback pre-release add view column failed).
17:37:43,089 [4@group-...] ERROR ... defect_frozen_173705.v1 ... (code:507, Rollback pre-release add view column failed)
17:39:18,118 [3@group-...] ERROR ... defect_frozen_173812.v1 ... (code:507, Pre-release add view column failed)
```
