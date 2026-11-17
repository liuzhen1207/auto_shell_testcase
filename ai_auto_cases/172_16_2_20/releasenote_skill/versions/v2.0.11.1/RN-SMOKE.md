# V2.0.11.1 RN 批量冒烟报告（RC2 83183d0）

> 迭代：**V2.0.11.1**（147 个 RN，见 [`RN-CATALOG.md`](RN-CATALOG.md)）
> 验证版本：**2.0.13.1 RC2 / build 83183d0**
> 环境：3C5D（CN 16/17/18，DN 19/21/22/23/24）
> 执行时间：2026-11-17 14:39 ~ 14:41
> 脚本：[`scripts/rn_smoke_2011.sh`](scripts/rn_smoke_2011.sh)

## 一、总体结果

| 指标 | 数值 |
| --- | ---: |
| 迭代内 RN 总数 | 147 |
| 可在本环境验证（已入目录） | **117** |
| 当前环境不满足（附原因） | **30** |
| 本轮执行检查项 | **14** |
| 通过 | **14** |
| 失败 | 0 |
| 跳过 | 0 |

## 二、执行明细（14 项，全部 PASS）

### 2.1 配置热加载（5 项）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| CFG-1 非法 `wal_throttle_threshold_in_byte=abc` | PASS | 被拒绝，未写入配置 |
| CFG-2 `disk_space_warning_threshold=NaN` | PASS | 被拒绝；无节点进入 ReadOnly |
| CFG-3 `region_migration_concurrency_limit` 0→1 | PASS | 设置成功 |
| CFG-4 `data_region_per_data_node` 3→2 | PASS | 设置成功 |
| CFG-5 `partition_table_recover_worker_num=0` | PASS | CN 日志 ERROR 增量 = 0（TDB-766 无刷屏） |

### 2.2 CLI / 客户端（3 项）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| CLI-1 三个 DN 执行同一 SQL | PASS | 结果完全一致 |
| CLI-2 `SHOW TIMESERIES ORDER BY timeseries` | PASS | 可用（TDB-808） |
| CLI-3 DATE 类型写入/查询 NULL | PASS | 无异常（TDB-767 相关场景） |

### 2.3 查询引擎（3 项）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| QUERY-1 对齐序列 `LAST` + 时间过滤 | PASS | 1s 内返回，未卡死 |
| QUERY-2 `DELETE` 时间区间 min>max | PASS | 返回 **701**（不再是 305），TDB-815 的报错优化已生效 |
| QUERY-3 `EXPLAIN ANALYZE` | PASS | 可执行 |

### 2.4 COPY TO TsFile（2 项）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| COPY-1 `WITH (TAGS(dev,dev))` 重复列 | PASS | `701: Duplicate tag column in TAGS clause: dev`（符合"应报错"预期） |
| COPY-2 `COPY (query) TO '<path>'` 不带 TABLE | PASS | 成功导出（需先配置 `copy_to_allowed_export_dirs`，属环境配置，非缺陷） |

### 2.5 迁移取消（1 项）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| MIGRATE-1 `EXTEND REGION` + `CANCEL ALL MIGRATIONS` | PASS | 5 台 DN 日志中 `unexpected consensusGroupId` / `NullPointerException` / `TreeSet` 均为 0 |

## 三、结论

1. 本轮覆盖的 5 个主题（配置热加载、CLI、查询、COPY TO TsFile、迁移取消）在 RC2 上**全部符合预期**；
2. `DELETE` 时间区间 min>max 的报错已从 305 优化为 701（TDB-815 验证通过）；
3. `COPY TO TsFile` 默认只允许导出到 `copy_to_allowed_export_dirs` 配置的目录，**首次使用需先配置**（非缺陷，已记录为环境注意点）；
4. 剩余可测 RN 已按主题编入 [`RN-CATALOG.md`](RN-CATALOG.md)，待后续按主题批量执行。

## 四、当前环境不满足的 30 条（摘要）

| 原因 | 数量 | 代表 RN |
| --- | ---: | --- |
| 需要 >5 个 DataNode / 特定拓扑 | 4 | TDB-750、TDB-788（3C3D）、TDB-798 |
| 需要双集群/双活环境 | 1 | — |
| 需要消息队列中间件（Kafka/MQTT 等） | 2 | TDB-812 |
| 需要 Pro/Max 商业包 | 3 | TDB-690、TDB-706、TDB-698* |
| 需要 AI/AINode 环境 | 1 | TDB-749 |
| 需要特定硬件/激活环境 | 1 | TDB-722 |
| 需要构造大数据量/长时间运行（OOM） | 4 | TDB-705、TDB-800、TDB-822 |
| 安全漏洞（需专项环境） | 4 | TDB-723~726 |
| 需要指定旧版本升级路径 | 6 | TDB-697、TDB-767、TDB-829 |
| 协议层/内部接口/EAL4 等 | 4 | TDB-757、TDB-758、TDB-759、TDB-792、TDB-793 |

> \* TDB-698 经复核改为"可测"（企业版审计日志 TTL 校验），实际以 `RN-CATALOG.md` 为准；完整 30 条见目录第三节。

## 五、环境恢复

- `copy_to_allowed_export_dirs` 已清空，测试库/时间序列已清理；
- 集群保持 8/8 Running，配置项恢复默认。
