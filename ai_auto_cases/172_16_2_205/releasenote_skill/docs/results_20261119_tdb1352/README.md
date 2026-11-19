# TDB-1352 非对齐设备表视图 last 查询验证（2.0.13.1 RC3 `ac7f95e`）

| 项 | 内容 |
| --- | --- |
| 来源工作项 | TDB-1352：表视图（基于树模型非对齐设备）last 查询可优化——原实现不下推、正序扫描全部数据；期望 last 走倒序/末尾读取 |
| 修复提交 | `6edf43a9ff` Support aggregation push-down optimize for table view of non aligned series (#17294) |
| 验证版本 | 2.0.13.1 **RC3** `ac7f95e`，3C5D（SR3/DR2，IoTConsensus V1），普通模式 |
| 验证用例 | **RN-216**（干净环境 + CN/DN 日志窗口） |
| 结果 | **PASS**（下推生效、读取量仅为全量 4%、结果正确、日志 0 异常） |

> **本报告为更正版**。首轮验证曾误判为 FAIL，原因见文末「五、首轮误判与更正」。

## 一、验证方法

1. 建库 `rn1352_db`，创建**非对齐设备** `root.rn1352_db.d1.s1`、`root.rn1352_db.d2.s1`（各自独立 timeseries）；
2. 每设备写 **100,000 行**（合计约 200,000 行）；
3. 创建表视图 `rn1352_db.v1(dev string tag) with(auto_sync_schema=true) as root.rn1352_db.**`；
4. `EXPLAIN` 检查聚合是否下推；
5. `EXPLAIN ANALYZE` 对比 `last` 与 `count` 的**扫描输出行数**（稳健判据）；
6. 校验 `last` 结果正确性。

## 二、实测结果

### 2.1 聚合下推 ✅

```
│NonAlignedAggregationTreeDeviceViewScanNode-71│
│OutputSymbols: [last_0]                       │
│Aggregator-0: last(DOUBLE, TIMESTAMP):DOUBLE  │
│Step: PARTIAL                                 │
│DeviceNumber: 2                               │
```

`last` 聚合已下推到 scan 节点内完成。

### 2.2 非全量扫描 ✅

`EXPLAIN ANALYZE` 统计（200,000 行数据）：

| 查询 | 扫描节点输出行数 | 占比 | Next() 次数 | Wall Time（参考） |
| --- | ---: | ---: | ---: | ---: |
| `select last(s1)` | **8,192** | **4.1%** | 3 | 212 ms |
| `select count(s1)` | **200,000** | 100% | 331 | 36 ms |

`last` 只读取一个 chunk（8,192 行）即结束，**未全量扫描**；`count` 扫描全部 200,000 行。放大到 55 万行/设备（110 万行）时同样只读 8,192 行（4 ms vs count 50 ms）。

> 说明：`EXPLAIN` 中的 `ScanOrder: ASC` 表示**输出顺序**，不代表内部读取方向；内部按末尾 chunk 优先读取，因此不再以该字段作为“是否倒序”的判据。

### 2.3 功能正确性 ✅

`select last(s1) from rn1352_db.v1` 返回 `53.0`，等于最大时间点值（100000 % 89 = 53）。

## 三、日志检查

`RN_LOG_CHECK=1` 逐用例窗口：**`err=0 warn=0 unexp=0`**（无不符预期的 WARN/ERROR）。

## 四、结论

**TDB-1352 在 RC3 已验证通过**：
- 非对齐设备视图的 last 聚合已下推（`NonAlignedAggregationTreeDeviceViewScanNode`）；
- last 查询不再全量扫描（读取量为全量的 4%）；
- 结果正确、日志无异常。

## 五、首轮误判与更正

首轮验证判为 FAIL（“ScanOrder=ASC、耗时与 count 相当”），实际是**测试侧问题**：

| 误判原因 | 说明 |
| --- | --- |
| 用 CLI 墙钟时间对比 | `start-cli.sh` 每次启动 JVM 约 1s，把真实的 4ms vs 50ms 完全掩盖，导致“耗时相当”的错误结论 |
| 把 `ScanOrder: ASC` 当作未倒序 | 该字段是输出顺序；内部读取方向需看 `EXPLAIN ANALYZE` 的实际读取行数 |
| 数据量偏小 | 首次仅 2 万行/设备，且数据全在缓存，耗时差异不可见 |

更正后用 `EXPLAIN ANALYZE` 的**扫描行数**作为判据，结论为 PASS。

## 六、文件

| 文件 | 内容 |
| --- | --- |
| `cases/V2_1352_v2.0.13.1.sh` | RN-216（更正的断言：下推 + 读取量 + 结果 + 日志） |
| `RN-216.out` | 断言明细（PASS） |
| `RN-216.tsv` | 结果行（PASS，含 `[LOG err=0 warn=0 unexp=0]`） |
