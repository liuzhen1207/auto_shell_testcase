# TDB-1104 变体验证：3C4D 启动 → 扩容第 5 台 DN → 空 region 迁移/缩容

> 本目录是 [`../TDB-1104/`](../TDB-1104/README.md) 的**副本变体**，原用例保持不变。
> 目的：补上原用例的缺口——原用例用 `EXTEND/REMOVE REGION` 模拟"缩容（Adding）"，没有走**真实扩容**（先 4D 再扩第 5 台 DN）。

## 一、为什么需要这个变体

RN 的原始场景是：**扩容 1 台 DN 后**集群里出现空 DataRegion（CN 预创建、未分配 series slot），随后对该 region 做迁移/缩容时，目标 DN 在 Adding 状态 load snapshot 抛空指针。

原用例在 5D 集群上用 CUSTOM 策略造出空 region，再 `EXTEND/REMOVE REGION`——覆盖了 Adding 代码路径，但**没有覆盖"扩容动作本身"**。

本变体改为：

```
3C4D（DN 19/21/22/23）启动
  → CUSTOM 10 组造出 9 个空 region
  → 启动 DN24，真实扩容到 5D（8/8）
  → 把空 region 迁到新 DN（EXTEND → Adding → load snapshot → REMOVE 缩容）
  → LOAD BALANCE TO DATANODE <新DN>
```

## 二、执行结果

| 阶段 | 关键结果 |
| --- | --- |
| 3C4D 启动 | **7/7 Running**（3 CN + 4 DN） |
| 4D 时造空 region | 10 个 DataRegion 组，其中 **9 个 `SeriesSlotNum=0`**（region 3/4/6/7/8/9/10/11/12） |
| 扩容第 5 台 DN | `SHOW CLUSTER` **8/8 Running**，DN24 的 nodeId=7 |
| 空 region 迁移到新 DN | region 10/11/12/3/4 各 `EXTEND → REMOVE`，全部 successfully |
| `LOAD BALANCE TO DATANODE 7` | 执行成功，新 DN 承接 region 3/4/6/7/9 的副本 |
| 异常扫描（5 台 DN × 2 阶段） | `NullPointerException` / `snapshot.*(fail|error|exception)` / `addPeer.*(fail|error)` 合计 **0** |

## 三、结论

**RC2（83183d0）在"真实扩容 + 空 region 迁移/缩容"场景下同样不出现 load snapshot 空指针**，与主用例结论一致，且补上了"扩容动作"这一环。

## 四、脚本

| 脚本 | 用途 |
| --- | --- |
| [`scripts/start_3c4d.sh`](scripts/start_3c4d.sh) | 3C4D 启动：停止全部、清空 data/logs（含 DN24）、起 3 CN + 4 DN，等到 7/7 |
| [`scripts/run_tdb1104_expand.sh`](scripts/run_tdb1104_expand.sh) | 完整流程：3C4D → CUSTOM 10 组 → 扩容 DN24 → 空 region 迁移/缩容 → LOAD BALANCE → 异常扫描 |

执行方式：

```bash
NEW=/data1/iotdb/v20131rc2_1110_83183d0 \
CLI=/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh \
bash run_tdb1104_expand.sh
```

## 五、证据

- [`evidence/run.log`](evidence/run.log)：完整执行日志（含 4D region 清单、扩容、迁移、LOAD BALANCE、异常计数）
- 服务器原始 DN 日志：`/data1/iotdb/v20131rc2_1110_83183d0/logs/log_datanode_all.log`，检索标记 `TDB1104X-*`

## 六、清理

执行后已恢复：`data_region_group_extension_policy=PROACTIVE`、`default_data_region_group_num_per_database=2`，测试库 `tdb1104x` 已 drop，集群 8/8 Running。
