# QA-LZ-003 串行缩容/加回 DataNode 两轮循环（含并发读写与一致性校验）

- 来源：3C5D 缩容/迁移回归需求（V2-940、V2-1019、V2-1215 等缩容类缺陷的扩展场景）
- 集群：3C5D（CN 172.16.2.8/9/10，DN 172.16.2.11~15），DR=2 / SR=3
- 负载：weather `conf_rw`（HOST 5 个 DN、PORT 5 个），全程并发读写
- 版本基线：2.0.13.1 RC1 `ab6d3de`（IoTConsensusV2）

## 1. 场景

对 5 个 DN 逐个执行两轮：

1. `remove datanode <id>`，等待节点从 `show datanodes` 消失；
2. 停止该 DN 进程，校验数据目录已清理（`data/datanode/data/sequence` 下无 region 目录、`data/datanode` 体积 < 200MB）；
3. 重新 `start-datanode.sh` 加回，等待 `Running`；
4. 进入下一个 DN，第二轮重复。

全程 weather benchmark 持续写入/查询。

## 2. 结束后校验

1. 停止 benchmark；
2. 等待所有 DN 的 `iot_consensus{type="syncLag"}` 归零（最多 600s）；
3. `show datanodes` 5 个节点全部 `Running`，无 `Unknown`；
4. 统计窗口内 CN/DN 日志 `ERROR`/`WARN` 数量，人工核对是否有不符合预期的日志。

## 3. 判定

| 检查 | PASS 条件 |
| --- | --- |
| 缩容 | 每轮每个 DN 都能在 1200s 内从集群移除 |
| 数据清理 | 移除后该 DN 无 region 数据目录、data 体积 < 200MB |
| 加回 | 900s 内重新 `Running` |
| 一致性 | 全部 DN `syncLag=0`，5 节点 Running |
| 日志 | 无不符合预期的 ERROR/WARN（缩容/迁移/连接拒绝类需人工归类） |

## 4. 执行

```bash
cd skills/timechodb-rn-verify/cases/qa-liuzhen
bash run_scale_cycle.sh
```

结果：`results/scale_cycle_<版本>_<时间>.log`。

## 5. 历史结果

| 日期 | 版本 | 协议 | 结果 |
| --- | --- | --- | --- |
| 2026-11-05 | 2.0.13.1 RC1 `ab6d3de` | IoTConsensusV2 | **FAIL**：.11 通过；.12 迁移 DataRegion[6] 失败回滚，缩容未完成（见 results/2026-11-05_RC1_scale_cycle.md） |
| 2026-11-05 | 2.0.13.1 RC1 `ab6d3de` | IoTConsensus（V1） | **PASS**：两轮 × 5 节点全部缩容成功、数据清理干净、加回 Running（见 results/2026-11-05_RC1_scale_cycle_iocv1.md） |
