# TDB-1352 非对齐设备表视图 last 查询验证（2.0.13.1 RC3 `ac7f95e`）

| 项 | 内容 |
| --- | --- |
| 来源工作项 | TDB-1352：表视图（定义基于树模型非对齐设备）last 查询可优化——原实现不下推、正序 scan 扫全部数据；期望 last 走倒序查 |
| 关联修复提交 | `6edf43a9ff` Support aggregation push-down optimize for table view of non aligned series (#17294)（**仅覆盖聚合下推**） |
| 验证版本 | 2.0.13.1 **RC3** `ac7f95e`，3C5D（SR3/DR2，IoTConsensus V1），普通模式 |
| 验证用例 | **RN-216**（干净环境 + CN/DN 日志窗口） |
| 结果 | **FAIL（2 项断言）**：下推已生效；**倒序扫描未生效** |

## 一、验证方法

1. 建库 `rn1352_db`，创建**非对齐设备**：`root.rn1352_db.d1.s1`、`root.rn1352_db.d2.s1`（各自独立 timeseries）；
2. 每台设备写 **50,000 行**（5,000 行/批）；
3. 创建表视图 `rn1352_db.v1(dev string tag) with(auto_sync_schema=true) as root.rn1352_db.**`；
4. `EXPLAIN select last(s1) from rn1352_db.v1`，检查算子与扫描顺序；
5. 对比耗时：`last` vs `count`（全量扫描）vs `first`；
6. 校验结果正确性。

## 二、实测结果

### 2.1 聚合下推：已生效 ✅

```
│NonAlignedAggregationTreeDeviceViewScanNode-71 │
│OutputSymbols: [last_0]                        │
│Aggregator-0: last(DOUBLE, TIMESTAMP):DOUBLE   │
│Step: PARTIAL                                  │
│DeviceNumber: 2                                │
│ScanOrder: ASC                                 │
```

`last` 聚合已下推到 scan 节点（PARTIAL 阶段在 scan 节点内完成）。

### 2.2 倒序扫描：未生效 ❌

| 检查点 | 期望 | 实测 |
| --- | --- | --- |
| `ScanOrder` | `DESC` | **`ASC`** |
| `last` 耗时（50k×2 行） | 明显低于全量扫描 | **1316 ms** |
| `count` 全量扫描 | 基准 | 1073 ms |
| `first`（正序） | 基准 | 1017 ms（100k 行探测） |

`last` 与 `count`/`first` 耗时相当（甚至略高），说明仍在**正序全量扫描**，未按 TDB-1352 的优化目标改为倒序读取。

### 2.3 功能正确性：✅

`select last(s1) from rn1352_db.v1` 返回 `71.0`，与写入的最大时间点值一致（50000 % 89 = 71）。

## 三、结论（当前 RC3 状态）

| 优化点 | 状态 |
| --- | --- |
| 聚合下推（避免逐行回传、在 scan 节点内完成 last） | **已实现**（`NonAlignedAggregationTreeDeviceViewScanNode`） |
| last 倒序扫描（避免扫描全部数据） | **未实现/未生效**（`ScanOrder: ASC`，耗时与全量扫描相同） |

> 源码侧也印证：`TreeNonAlignedDeviceViewAggregationScanOperator` 与 `NonAlignedAggregationTreeDeviceViewScanNode` 中没有倒序（descending/reverse）相关逻辑；`checkStatisticAndScanOrder` 的 DESC 选择只作用于普通 `AggregationTableScanNode`，未覆盖该新节点。

## 四、日志检查

`RN_LOG_CHECK=1` 逐用例窗口：**`err=0 warn=0 unexp=0`**（无不符预期的 WARN/ERROR）。

## 五、文件

| 文件 | 内容 |
| --- | --- |
| `cases/V2_1352_v2.0.13.1.sh` | RN-216（下推 + 倒序 + 功能 + 日志） |
| `RN-216.out` | 断言明细 |
| `RN-216.tsv` | 结果行（FAIL，含 `[LOG err=0 warn=0 unexp=0]`） |
