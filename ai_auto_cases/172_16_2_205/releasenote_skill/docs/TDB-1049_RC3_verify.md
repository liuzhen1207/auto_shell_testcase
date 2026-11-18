# TDB-1049 验证报告（2.0.13.1 RC3 / `ac7f95e`）

| 项目 | 内容 |
| --- | --- |
| 缺陷 | TDB-1049【V2.0.13.1】【树转表视图】DN 无响应且未标记 Unknown 期间建序列，自动扩列静默丢列且无补偿 |
| 验证版本 | 2.0.13.1 **RC3**，BuildInfo **`ac7f95e`**（源码 `D:\IDEA\timechodb_src\v20131\timechodb` HEAD = ac7f95e953，与构建一致） |
| 集群 | 3 CN（172.16.2.26/27/28）+ 5 DN（172.16.2.2~6），Schema 3 副本 / Data 2 副本，DataRegion = IoTConsensus V1，8/8 Running |
| 验证人 | 刘珍 |
| 验证日期 | 2026-11-18 |
| 结论 | **通过（未复现）** |

## 一、复现方法（与 RC1/RC2 缺陷报告一致）

1. 新建库 `D`，写入一条序列，创建开启自动扩列的视图：

```sql
CREATE DATABASE <D>;
create timeseries root.<D>.dev01.s1 double;
create view <D>.v1(dev string tag) with(auto_sync_schema = true) as root.<D>.**;
```

2. 找到该库 SchemaRegion 的 leader 所在 DN，`kill -STOP` 冻结（DN 无响应，尚未被标记 Unknown）；
3. 冻结 12s 后，在视图前缀下建新序列 `root.<D>.dev01.frozen_col`（记录返回结果）；
4. `kill -CONT` 恢复，等待集群回到 8/8；
5. 恢复后 30s 检查 `desc <D>.v1` 是否出现 `frozen_col`；若缺失再等 120s（观察是否有补偿）；
6. 同时校验新序列确实创建成功（`show timeseries`），排除“序列没建成功”的假阴性。

**测试有效性确认**：`show regions` 显示被冻结的 node 7（172.16.2.6）正是该库 SchemaRegion 的 **Leader**，冻结确实打在 schema 写入路径上。

## 二、RC3 实测结果

| 批次 | 轮次 | 有效轮次 | 有列 | 丢列 | 备注 |
| --- | ---: | ---: | ---: | ---: | --- |
| 第一批 | 6 | 6 | 6 | 0 | 30s 检查点 |
| 第二批（严格版，含序列存在性校验 + 30s/150s 双检查点） | 12 | 11 | 11 | **0** | 1 轮因序列未创建被排除 |
| **合计** | 18 | **17** | **17** | **0** | 丢列率 **0%** |

- 所有有效轮次均在 30s 检查点即有列，**未观察到 150s 才补列的延迟补偿**；
- 有效轮次中客户端建序列返回 `The statement is executed successfully.`，与 RC2 一致，但列正常补齐。

## 三、A/B 对照（同一脚本、同一环境、同一冻结目标）

为排除“脚本已失效”的可能，用**完全相同的脚本**在 **RC2（`83183d0`）** 上执行 12 轮：

| 版本 | 轮次 | 有列 | 丢列 | 丢列率 |
| --- | ---: | ---: | ---: | ---: |
| RC2 `83183d0` | 12 | 8 | **4** | **33%** |
| RC3 `ac7f95e` | 17 | **17** | **0** | **0%** |

RC2 丢列轮次的 CN 日志出现与缺陷报告一致的线索：

```
WARN o.a.i.c.c.r.AsyncRequestManager:170 - Failed to UPDATE_TABLE after 2 retries, requestIndices: [7]
```

RC3 的 17 轮窗口内未出现同类 `Failed to UPDATE_TABLE` 告警。

## 四、源码层面观察（供研发参考）

`83183d0..ac7f95e` 之间（61 个提交）**没有直接修改** `ViewColumnAutoSyncTrigger` 或 `TreeToTableViewCache` 的提交，也没有标题含 1049 / 补偿 / 丢列的提交。可能的改善来源（需研发确认）：

- `34965fcf35 Preserve accepted table attribute versions across schema fetches`（#19134）
- `b9e09d6321 Fix active load retries while table schema regions recover`（#19201）
- `47e1a19426 Fix NPE in paired commit of schema-cascaded writable views`

建议研发确认本次修复是否覆盖了“DN 无响应且未标记 Unknown 期间 schema 写入与视图列同步的补偿”，以决定是否需要补充针对该场景的单测/IT。

## 五、结论

- 在 3C5D（SR3/DR2、IoTConsensus V1）环境下，RC3 **17 轮有效复现全部未丢列**；
- 同脚本在 RC2 上 12 轮丢 4（33%），说明测试方法有效、对比可信；
- **TDB-1049 在 RC3 验证通过**。

> 证据文件：`/tmp/tdb1049_rc3_114...`（RC3 两批原始输出）、`/tmp/tdb1049_strict.sh`（复现脚本，支持 `NEW=<build>` 切换版本）。
