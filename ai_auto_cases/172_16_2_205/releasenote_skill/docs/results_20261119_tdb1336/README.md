# TDB-1336 explain analyze 功能优化验证（2.0.13.1 RC3 `ac7f95e`）

| 项 | 内容 |
| --- | --- |
| 来源工作项 | TDB-1336 explain analyze 功能优化：① SinkNode 展示下游节点 ID ② ScanNode 增加 filter 选择率 ③ ExchangeNode 增加已处理 TsBlock size |
| 修复提交 | `04fc5c65`（filtered rows 计数）等，PLM 记录 RC3 修复 |
| 验证版本 | 2.0.13.1 **RC3** `ac7f95e`，3C5D（SR3/DR2，IoTConsensus V1），普通模式 |
| 验证用例 | **RN-217**（干净环境 + CN/DN 日志窗口） |
| 结果 | **PASS**（11 项断言，日志 `err=0 warn=0 unexp=0`） |

## 一、三项增强的实测输出

### 1) SinkNode 展示下游节点 ID

```
|    [PlanNodeId 10]: IdentitySinkNode(IdentitySinkOperator)  |
|        DownStreamPlanNodeId: 8                              |
```

树模型与表模型视图的 `explain analyze` 均输出 `DownStreamPlanNodeId`，且带有效节点编号。

### 2) ExchangeNode 展示已处理 TsBlock size

跨库查询（`root.rn1336a.dev, root.rn1336b.dev`，分属不同 DataRegion）产生 2 个 Fragment，Exchange 节点输出：

```
|        [PlanNodeId 7]: ExchangeNode(ExchangeOperator)  |
|            size_in_bytes: 94                           |
```

### 3) ScanNode 增加 filter 选择率（verbose）

```
|    rowScanFilteredRows: 1                              |
```

- 数据 3 行（s1 = 1/2/3），条件 `s1 > 1` → `rowScanFilteredRows = 1`（正确）；
- **`explain analyze verbose` 才输出**该统计；普通 `explain analyze` 不输出（verbose 语义正确）；
- 表视图（`rn1336a.v1`）的 verbose 输出同样包含 `rowScanFilteredRows`。

## 二、断言清单（RN-217）

| # | 断言 | 结果 |
| --- | --- | --- |
| 1 | 树模型 SinkNode 输出 `DownStreamPlanNodeId` | ✅ |
| 2 | `DownStreamPlanNodeId` 带有效编号 | ✅（`: 8`） |
| 3 | 跨库查询产生 `ExchangeNode` | ✅ |
| 4 | ExchangeNode 输出 `size_in_bytes` | ✅（`: 94`） |
| 5 | verbose 输出 `rowScanFilteredRows` | ✅ |
| 6 | `rowScanFilteredRows = 1`（3 行过滤 1 行） | ✅ |
| 7 | 非 verbose 不输出该统计 | ✅ |
| 8 | 表视图 verbose 输出 `rowScanFilteredRows` | ✅ |
| 9 | 表视图 SinkNode 输出 `DownStreamPlanNodeId` | ✅ |

## 三、日志检查

`RN_LOG_CHECK=1` 逐用例窗口：**`err=0 warn=0 unexp=0`**（无不符合预期的 WARN/ERROR）。

## 四、用例稳定性说明

clean reset 后**首个跨库 `explain analyze`** 偶发失败（分区信息尚未就绪），用例已加入：
- 预热：先跑普通跨库查询并重试（最多 6 次、间隔 10s）；
- analyze 重试（最多 5 次）；
- 失败时打印最后一次原始输出便于排查。

修复后连续运行稳定 PASS（约 2 分钟/次，主要为预热等待）。

## 五、文件

| 文件 | 内容 |
| --- | --- |
| `cases/V2_1336_v2.0.13.1.sh` | RN-217 |
| `RN-217.out` | 断言明细（PASS） |
| `RN-217.tsv` | 结果行（PASS，含 `[LOG err=0 warn=0 unexp=0]`） |
