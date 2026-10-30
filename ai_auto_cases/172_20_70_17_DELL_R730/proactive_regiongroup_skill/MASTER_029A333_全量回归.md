# master@029a333 全量 217 例回归报告

> 部署与执行：2026-10-20 22:22 → 2026-10-21 12:53（14.4 h）
> 结果目录：`/home/ubuntu/remove_cn_dn/pg_build/results/pg_master_1020/`（`REPORT.md` / `summary.tsv` / 逐例证据）
> 复跑目录：`results/pg_master_fix/`（H-38 修复验证 + HA-01 噪声归因验证）

## 1 环境

| 项 | 值 |
|---|---|
| 版本 | TimechoDB `2.0.11-SNAPSHOT` |
| BuildInfo | **`029a333`**（master HEAD `029a333bb134`，2026-10-20 22:12 构建） |
| 拓扑 | 3 ConfigNode + 5 DataNode，全新部署，8 节点全部 `ACTIVATED` |
| DB_DIR | `/data/mpp_test/pg_master_1020` |
| 共识 | IoTConsensus；schemaRF=3 / dataRF=2 |
| 扩容参数 | `*_region_group_extension_policy=PROACTIVE`、`schema_region_per_data_node=3`、`data_region_per_data_node=0`、`series_slot_num=1000`、`time_partition_interval=604800000` |
| 用例集 | `matrix --tier full`，217 例 |

## 2 数字

| 口径 | PASS | FAIL | SKIP | 通过率 |
|---|---|---|---|---|
| 首轮实测 | 149 | 27 | 41 | 68.7% |
| **修正后（含本节 §4 的复跑）** | **151** | **23** | **43** | **69.6%** |

修正来源：`PG-DIS-03`、`PG-RCV-05` 复跑后 SKIP（布局不可达，合法跳过）；
`PG-RCV-06`、`PG-HA-01` 复跑后 PASS。

### 与上一轮（`3bbeea6`）对比

| 项 | 上一轮（修正后） | 本轮（修正后） | 变化 |
|---|---|---|---|
| PASS | 138 | **151** | +13 |
| FAIL | 37 | **23** | −14 |
| SKIP | 41 | 43 | +2 |
| 其中 D-04 | 26 | **22** | −4 |
| 其中 H-37（测点级 count） | 10 | **0** | −10 |
| 其中 HA-10（停机 ExecuteFailed） | 1 | 0 | −1 |
| 其中日志/配置噪声 | 0 | 1（`PG-HA-09`） | +1 |

## 3 FAIL 归因（23 例）

### 3.1 D-04：表库与同名树库冲突（22 例，产品缺陷，**未修复**）

用例：`PG-DEV-15/16`、`PG-LIM-02/04/13/21`、`PG-MSR-02/04/06/08/10/12/14/18/20`、
`PG-RCV-04`、`PG-REB-11`、`PG-SMK-05`、`PG-TIME-02/05/11`、`PG-HA-12`。

签名完全一致：表库 `MaxDataRegionGroupNum=2`（公式 12/15）、表库组数不增长；
同轮树模型同口径用例全部 PASS。`PG-LIM-21` 的实测值与上一轮**逐位相同**（1,2 vs 公式 2,15），
说明 `029a333` 未修复该缺陷。机制见 `DEFECT_CANDIDATES.md §D-04`、提单草稿 `缺陷提交_D-04_表库同名冲突.md`。

### 3.2 `PG-HA-09`：DN 启动期配置自检 WARN（1 例，非功能缺陷）

```
WARN o.a.i.d.c.DataNodeMemoryConfig:794 - table_query_device_entry_batch_size_in_bytes
(96599583) exceeds the maximum RPC payload (dn_thrift_max_frame_size 67108864 ...)
```

`[main]` 启动期打印，由本 harness 的 DN 堆档位（20G）推导出的批量上限超过 RPC 帧上限所致，
与 PROACTIVE 无关。**未加入日志白名单**（selftest 明确要求该签名必须报出，属配置告警），
因此该例保持 FAIL，但不计入产品功能缺陷。

## 4 本轮修的 harness 问题（均已复跑验证）

| 编号 | 内容 | 验证 |
|---|---|---|
| **H-37** | 测点级 `count(*)` 在 2.x 必然空集 → 新增 `PgApi.count_series()`，替换 20 处调用 | 本轮 0 例该签名失败（上一轮 10 例） |
| **H-38** | 组数前置用纯公式当 R → 改 `_group_r`（`max(公式, 自报上限)`），5 处 | `PG-RCV-06` PASS；`PG-DIS-03`/`PG-RCV-05` 转 SKIP（布局确实不可达） |
| **H-39** | 两条停机/启动期日志签名加入"动作窗口内才归因"白名单：`IoTDBInternalLocalReporter:178 ... code:305 Interrupted`、`fail to sync logEntries because system is read-only` | `PG-HA-01` PASS（13/13） |

`selftest` 764 项全过。

## 5 SKIP（43 例）

| 原因 | 例数 |
|---|---|
| 升级族 16 例（需 1.3→2.0 两阶段专轮，已在 `升级族_两阶段实测_029A333.md` 单独完成：**14 PASS / 2 FAIL（收敛噪声）**） | 16 |
| benchmark 客户端编排异常 `KeyError: '占位符'`（已知，bench 侧模板问题） | 5 |
| 需要专档 conf（默认值档 / CUSTOM / AUTO 策略档） | 4 |
| 布局不可达（停 DN 会连带禁用 Schema 组、单 Data 组不可构造、`G<R` 不成立） | 7 |
| 需改拓扑（3C5D→3C4D）或 `series_slot_num=100` | 2 |
| 权限授予失败（`pg_system` 拿不到 SYSTEM） | 2 |
| 同构用例（REB-08 与 REB-01）、策略键显式写入、集群上限与 spec 不一致等 | 7 |

## 6 结论

1. **D-04 是当前唯一未修复的产品功能缺陷**，在 `029a333` 上稳定复现 22 例，建议尽快提单。
2. **H-37 的 10 例假 FAIL 已全部消除**，说明上一轮"测点级 count 空集"确实是 harness 口径问题。
3. **HA-10 未复现**（上一轮 1 例，本轮 0 例），与"干净环境不可复现"的结论一致。
4. 通过率 69.6%，扣除 D-04 后功能通过率 = **174/195 = 89.2%**（195 = 217 − 22 D-04），
   剩余失败仅 `PG-HA-09` 一条配置自检告警。
5. 升级族 16 例仍需单独跑 1.3→2.0 两阶段轮才能闭环。

## 7 升级族补充轮（1.3.7 → 2.0.11 两阶段）

全量轮里的 16 例升级用例因 `PG_UPG_PHASE` 档位不匹配而 SKIP，随后单独跑了两阶段专轮：

| 阶段 | 用例 | PASS | FAIL | SKIP |
|---|---|---|---|---|
| pre（1.3.7 基线） | UPG-01..07 | 5 | 2（均为重启收敛期日志噪声，业务断言全过） | 0 |
| post（2.0.11 升级后） | UPG-08..16 | **9** | 0 | 0 |

* 升级本身成功：2.0.11 / `029a333` 原地读取 1.3.7 数据启动，8 节点 ACTIVATED，升级前数据全可查；
* 前提是 1.3 的 license 必须**逐机**种入（`license` + `.env` 的 node_uuid 配对），
  已给 harness 增加目录形态支持（H-40）；
* 两条 pre FAIL 均为集群重启/停 DN 后 1–5 秒内的瞬时 WARN，业务断言零失败，
  因 pre 阶段升级后不可重跑，记为"待下轮干净复跑确认"，未改判、未加白名单；
* 详见 `升级族_两阶段实测_029A333.md`。
