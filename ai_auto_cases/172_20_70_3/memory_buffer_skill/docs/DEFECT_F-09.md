# 缺陷报告：BACKWARD 排序算法下逆序写入导致查询报 301 且数据丢失

| 字段 | 内容 |
|---|---|
| **缺陷编号** | F-09（待分配 PLM 编号） |
| **标题** | 【内存缓冲区】`tvlist_sort_algorithm=BACKWARD` 时，时间戳严格递减的多语句写入导致查询抛 `301: blocks should never be zero`，flush 后数据丢失 |
| **严重级别** | **高（P0）** —— 写入全部报成功，但数据不可读且最终丢失 |
| **缺陷类型** | 功能缺陷 / 数据丢失 / 算法边界 |
| **发现版本** | `v20121rc9_1020_d206dc2`（TimechoDB 2.0.12.1，BuildInfo `d206dc2`） |
| **回归确认** | RC8（`ebaf9da`）同样存在；两版 `BackwardSort.java` 逐字节相同 |
| **RC10 说明** | **RC10 尚未发布**（二进制下载站最高 `rc9_202610202209`，源码仓库无 RC10 标签）。`TVList`/`BackwardSort` 相关源码在 RC9→分支 HEAD（`c60ce63`）的 14 个提交中**零改动**，故本次 RC9 结论对 HEAD 同样适用 |
| **复现环境** | 3C5D 干净集群（详见 §一） |
| **复现概率** | **100%**（本节条件满足即必现，已 3 次验证） |
| **报告日期** | 2026-10-22 |
| **验证人员** | 刘珍 |

---

## 一、测试环境

1. 版本：TimechoDB **V2.0.12.1**（build `d206dc2`，RC9 目录 `v20121rc9_1020_d206dc2`），企业版，已激活。
2. 部署：3 ConfigNode（`172.20.70.5` / `172.20.70.4` / `172.20.70.26`）+ 5 DataNode（`172.20.70.4` / `172.20.70.26` / `172.20.70.14` / `172.20.70.27` / `172.20.70.30`）。
3. 副本：`schema_replication_factor=3`，`data_replication_factor=2`；共识协议 IoTConsensus。
4. 模型：树模型；序列类型 INT64（`root.*.d1.s1`）。
5. 关键配置：`tvlist_sort_algorithm=BACKWARD`；`primitive_array_size=64`（默认值，**本缺陷的触发与该值强相关**）。
6. 内存比例：`datanode_memory_proportion=1:500:1:1:1:1`（memtable 阈值约 20 MB），`flush_proportion=0.5`；关闭定时刷盘（`enable_timed_flush_seq_memtable=false`、`enable_timed_flush_unseq_memtable=false`）。
7. 客户端：`172.20.70.3`，JDK 17.0.9。
8. 集群状态：每次复现前均为干净环境（停止 → 清 `data`/`logs` → 写配置 → 启动 → 确认 `show cluster` 为 8/8 Running）。

---

## 二、复现步骤

1. 集群按 §一 配置启动，确认 5 个 DataNode 的 `conf/iotdb-system.properties` 中 `tvlist_sort_algorithm=BACKWARD`：

```bash
V=v20121rc9_1020_d206dc2
for h in 172.20.70.4 172.20.70.26 172.20.70.14 172.20.70.27 172.20.70.30; do
  ssh cluster@$h "sudo grep '^tvlist_sort_algorithm=' /data/iotdb/$V/conf/iotdb-system.properties"
done
```

2. 建库建序列：

```sql
create database root.f09e;
create timeseries root.f09e.d1.s1 with datatype=int64;
```

3. 生成 4 条 INSERT 语句、每条 500 点，共 2000 点，时间戳**全局严格递减**（首点 `1700000013993`、末点 `1700000000000`，步长 7，**中间不允许出现跳升**）：

```bash
BASE=1700000000000; ROWS=2000
: > /tmp/fe.sql
for b in 0 1 2 3; do
  printf 'insert into root.f09e.d1(time,s1) values ' >> /tmp/fe.sql
  for k in $(seq 0 499); do
    idx=$(( b*500 + k ))
    ts=$(( BASE + (ROWS-1-idx)*7 ))
    printf '(%d,%d)' "$ts" "$idx" >> /tmp/fe.sql
    [ $k -lt 499 ] && printf ',' >> /tmp/fe.sql
  done
  printf ';\n' >> /tmp/fe.sql
done
```

4. 用**同一个会话**连续执行这 4 条语句（`start-cli.sh < /tmp/fe.sql`），全部返回 `The statement is executed successfully.`。

5. 立即查询：

```sql
select count(s1) from root.f09e.**;
select s1 from root.f09e.d1 order by time limit 3;
```

6. 再执行 `flush;` 并复查。

---

## 三、实际现象

1. 4 条写入语句**全部报成功**（`Msg: The statement is executed successfully.`），无任何警告。
2. 查询**直接报错**，不是返回空结果：

```
Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 301: blocks should never be zero.
```

3. 换成只查单序列的 `select count(s1) from root.f09e.d1.s1;` 时，返回 `Empty set.`（**不报错**），容易误判为"没有数据"。
4. 执行 `flush;` 后再查，异常消失，但 **count = 0**，明细为 `Empty set.`。
5. **flush 未生成任何 TsFile**：`find … -path '*f09e*' -name '*.tsfile'` 结果为 0。
6. 重启集群（走 WAL 回放）后仍为 0 —— 数据实际丢失。
7. 同样数据在 `TIM` / `QUICK` 下完全正常（同一轮 MB-15 用例中 TIM 与 QUICK 阶段均 `点数=2000`、指纹一致 `b89017e8…`）。

### 3.1 DataNode 侧日志（完整异常栈）

```
2026-10-22 11:59:57,236 [pool-57-IoTDB-ClientRPC-Processor-1] WARN  o.a.i.d.u.ErrorHandlingUtils:146 - Status code: 301, Query Statement: "select count(s1) from root.f09e.**". executeStatement failed because blocks should never be zero.
org.apache.iotdb.commons.exception.IoTDBException: org.apache.iotdb.db.queryengine.execution.fragment.FragmentInstanceFailureInfo$FailureException: blocks should never be zero.
	at org.apache.iotdb.db.queryengine.plan.execution.QueryExecution.dealWithException(QueryExecution.java:566)
	at org.apache.iotdb.db.queryengine.plan.execution.QueryExecution.getResult(QueryExecution.java:539)
	at org.apache.iotdb.db.queryengine.plan.execution.QueryExecution.getByteBufferBatchResult(QueryExecution.java:585)
	at org.apache.iotdb.db.utils.QueryDataSetUtils.convertQueryResultByFetchSize(QueryDataSetUtils.java:534)
	at org.apache.iotdb.db.protocol.thrift.impl.ClientRPCServiceImpl.lambda$static$0(ClientRPCServiceImpl.java:322)
	at org.apache.iotdb.db.protocol.thrift.impl.ClientRPCServiceImpl.executeStatementInternal(ClientRPCServiceImpl.java:585)
	at org.apache.iotdb.db.protocol.thrift.impl.ClientRPCServiceImpl.executeStatementV2(ClientRPCServiceImpl.java:1262)
	at org.apache.iotdb.service.rpc.thrift.IClientRPCService$Processor$executeStatementV2.getResult(IClientRPCService.java:4834)
	at org.apache.iotdb.service.rpc.thrift.IClientRPCService$Processor$executeStatementV2.getResult(IClientRPCService.java:4806)
	at org.apache.thrift.ProcessFunction.process(ProcessFunction.java:40)
	at org.apache.iotdb.db.protocol.thrift.ProcessorWithMetrics.process(ProcessorWithMetrics.java:66)
	at org.apache.thrift.server.TThreadPoolServer$WorkerProcess.run(TThreadPoolServer.java:264)
	at java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1136)
	at java.base/java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:635)
	at java.base/java.lang.Thread.run(Thread.java:840)
Caused by: org.apache.iotdb.db.queryengine.execution.fragment.FragmentInstanceFailureInfo$FailureException: blocks should never be zero.
	at org.apache.iotdb.db.utils.datastructure.BackwardSort.setBlockLength(BackwardSort.java:120)
	at org.apache.iotdb.db.utils.datastructure.BackwardSort.setBlockLength(BackwardSort.java:129)
	at org.apache.iotdb.db.utils.datastructure.BackwardSort.setBlockLength(BackwardSort.java:129)
	at org.apache.iotdb.db.utils.datastructure.BackwardSort.backwardSort(BackwardSort.java:86)
	at org.apache.iotdb.db.utils.datastructure.BackLongTVList.sort(BackLongTVList.java:31)
	at org.apache.iotdb.db.storageengine.dataregion.memtable.ReadOnlyMemChunk.sortTvLists(ReadOnlyMemChunk.java:141)
	at org.apache.iotdb.db.schemaengine.schemaregion.utils.MeasurementResourceByPathUtils.generateTimeSeriesMetadata(ResourceByPathUtils.java:771)
	at org.apache.iotdb.db.storageengine.dataregion.tsfile.TsFileResource.lambda$getTimeSeriesMetadata$0(TsFileResource.java:1213)
	at java.base/java.util.concurrent.ConcurrentHashMap.computeIfAbsent(ConcurrentHashMap.java:1708)
	at org.apache.iotdb.db.storageengine.dataregion.tsfile.TsFileResource.getTimeSeriesMetadata(TsFileResource.java:1207)
	at org.apache.iotdb.db.queryengine.execution.operator.source.FileLoaderUtils.loadTimeSeriesMetadata(FileLoaderUtils.java:144)
	at org.apache.iotdb.db.queryengine.execution.operator.source.SeriesScanUtil.loadTimeSeriesMetadata(SeriesScanUtil.java:2072)
	at org.apache.iotdb.db.queryengine.execution.operator.source.SeriesScanUtil.unpackSeqTsFileResource(SeriesScanUtil.java:2022)
```

### 3.2 各 DataNode 的异常分布

| DataNode | 首次出现 | 命中次数 |
|---|---|---|
| 172.20.70.4 | 2026-10-22 11:54:22 | 24 |
| 172.20.70.30 | — | 14 |
| 172.20.70.27 | — | 6 |
| 172.20.70.26 | — | 2 |
| 172.20.70.14 | — | 2 |

即**持有该 DataRegion 副本的节点全部触发**，与副本一致性无关。

---

## 四、根因分析（基于 RC9 源码 `d206dc2`）

### 4.1 缺陷代码

文件：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/utils/datastructure/BackwardSort.java`

```java
106  public int setBlockLength(List<long[]> timestamps, int step) {
107    double overlap = 0;
108    long last_time = timestamps.get(0)[0];
109    int i = step, blocks = 0;
110    while (i < timestamps.size()) {          // ★ 循环条件依赖 step
111      long cur_time = timestamps.get(i)[0];
112      if (last_time > cur_time) {
113        overlap += 1;
114      }
115      last_time = cur_time;
116      i += step;
117      blocks += 1;
118    }
119    if (blocks == 0.0) {                     // ★ blocks 恒为 0 时抛异常
120      throw new IllegalStateException(DataNodeMiscMessages.BLOCKS_SHOULD_NEVER_BE_ZERO);
121    }
122    double ratio = overlap / blocks;
123    int mul = (int) Math.ceil(ratio / INVERSION_RATIOS_THRESHOLD);   // ★ 1.0/0.004 = 250
124    if (mul <= 1) {
125      return step * ARRAY_SIZE;
126    }
127    return setBlockLength(timestamps, mul * step);                  // ★ 递归，step 被放大
128  }
```

### 4.2 触发链（逐行推演）

以本次复现的 2000 点、`primitive_array_size=64` 为例：

1. 2000 行数据在 TVList 中占用 ⌈2000/64⌉ = **32 个** `long[]` 数组，即 `timestamps.size() = 32`。
2. 首轮调用 `setBlockLength(timestamps, 1)`：`i` 从 1 迭代到 31，共 **31** 次，`blocks = 31`；由于数据**全局严格递减**，每次比较都是逆序，故 `overlap = 31`。
3. `ratio = 31 / 31 = 1.0`；`mul = ceil(1.0 / 0.004) = **250**`。
4. `mul > 1`，进入递归：`setBlockLength(timestamps, 250 * 1 = **250**)`。
5. 第二轮：`i = 250`，而 `timestamps.size() = 32`，`250 < 32` 为 **false** ⇒ **循环体一次都不执行**，`blocks` 保持初始值 **0**。
6. 命中第 119 行 `if (blocks == 0.0)` ⇒ 抛出 `IllegalStateException("blocks should never be zero.")`。

> 异常栈中 `setBlockLength(BackwardSort.java:129)` 出现**两次**，正是上述递归放大 `step` 的过程。

### 4.3 缺陷本质

`setBlockLength()` 的递归没有校验 `step` 与 `timestamps.size()` 的关系：

- `step` 的语义是"每隔多少个 array 取一个采样点"；
- 一旦 `step >= timestamps.size()`，采样点数量必然为 0；
- 代码把这个"采样不足"的正常情形当作**不可能发生的非法状态**，用 `IllegalStateException` 抛给上层。

而 `mul = ceil(ratio / 0.004)` 在逆序程度高时可达数百，**只要 `mul * step >= timestamps.size()` 就必然崩溃**。逆序越彻底、数据量越小（数组数越少），越容易触发。

### 4.4 为什么只在查询时报错

异常栈显示调用点在**读取路径**：

```
TsFileResource.getTimeSeriesMetadata
  → MeasurementResourceByPathUtils.generateTimeSeriesMetadata (ResourceByPathUtils.java:771)
    → ReadOnlyMemChunk.sortTvLists (ReadOnlyMemChunk.java:141)
      → BackLongTVList.sort (BackLongTVList.java:31)
        → BackwardSort.backwardSort (BackwardSort.java:86)
          → setBlockLength (BackwardSort.java:120) 抛异常
```

即：**写入阶段不排序**（数据按写入顺序堆在 TVList 里），只有在生成 `TimeSeriesMetadata` 时才惰性排序。因此写入全部成功，错误延后到第一次查询才暴露。

### 4.5 为什么会导致数据丢失

1. `sortTvLists` 抛异常 ⇒ 该 memtable chunk 无法生成元数据 ⇒ 查询失败。
2. `flush` 走同一条排序路径，排序失败后 **未写出 TsFile**（实测 TsFile 数为 0）。
3. memtable 随后被释放，WAL 亦未保留有效数据（实测 `root.f09e*` 下 WAL 文件仅 6 字节）。
4. 重启后 WAL 回放也无法恢复 ⇒ **数据永久丢失**。

> 这一条是本次复现才发现的：此前几轮只看到"查询不到数据"，误以为是用例判据问题；实际是**查询报错 + 落盘失败 + 数据丢失**的连续结果。

---


### 4.6 精确触发条件（本次实验收敛出的结论）

一开始用"4 条语句、每条 500 点、`ts = BASE + b*1000000 + …`"复现不出来（点数 2000 正常），
换成"单条语句 2000 点"也正常。逐个变量排除后，收敛为**两个必要条件**：

| # | 条件 | 说明 |
|---|---|---|
| 1 | 时间戳**全局严格递减**，中间不得出现跳升 | 若写成 `BASE + b*1000000 + (1999-(b*500+k))*7`，每批之间时间戳会跳高，逆序比例下降，`mul` 变小，不再触发 |
| 2 | 数据经**多条 INSERT 语句**写入（≥2 条） | 单条 2000 点语句不触发；4×500 触发 |

满足这两条后，`ratio = 1.0` ⇒ `mul = ceil(1.0/0.004) = 250` ⇒ 递归调用的 `step` 从 1 放大到 250，
而 `timestamps.size() = ⌈2000/64⌉ = 32`，`250 < 32` 为假 ⇒ `blocks = 0` ⇒ 抛异常。

一个可直接复现的最小写法（已实测 3 次稳定复现）：

```sql
-- 4 条语句，时间戳从 1700000013993 严格递减到 1700000000000，步长 7
insert into root.f09e.d1(time,s1) values (1700000013993,0),(1700000013986,1),...;   -- 第 1 条：idx 0..499
insert into root.f09e.d1(time,s1) values (1700000010493,500),(1700000010486,501),...; -- 第 2 条：idx 500..999
insert into root.f09e.d1(time,s1) values (1700000006993,1000),...;                    -- 第 3 条：idx 1000..1499
insert into root.f09e.d1(time,s1) values (1700000003493,1500),...;                    -- 第 4 条：idx 1500..1999
```

> 条件 2 的成因推断：多条语句会让 memtable 内形成多个 `ReadOnlyMemChunk`，从而在
> `sortTvLists` 阶段真正走到 `BackwardSort.sort()`；单条语句的数据顺序在写入路径上已满足
> 某种有序性，`sorted` 标记为真，`sort()` 直接返回，绕过了缺陷代码。
> 这一点尚未从源码逐行确认，供研发参考。

---

## 五、期望结果

1. `tvlist_sort_algorithm=BACKWARD` 下，任意合法的时间戳分布（含全局严格递减）都应能正常写入与查询，不得抛 301。
2. 查询结果应与 `TIM` / `QUICK` 完全一致（同一份数据、按时间排序后逐行相同）。
3. 逆序写入后 `flush` 必须正常生成 TsFile，数据不得丢失。
4. 若算法确实无法处理某种分布，应给出明确的、可定位的业务错误（含配置项与数据特征），而不是抛出内部 `IllegalStateException` 并以 `301` 暴露给用户。
5. 修复后需覆盖以下边界：数据量 64 / 1000 / 2000 / 10000 行，逆序比例 0% / 50% / 100%，以及多条语句分批写入的场景。

---

## 六、影响面

1. **数据丢失**：BACKWARD 配置下，逆序写入的数据在查询时报错、flush 无法落盘、重启后不可恢复。
2. **写入假成功**：4 条语句全部返回成功，用户侧无任何异常提示，直到查询才发现问题，**容易造成数据静默丢失**。
3. **排查困难**：单序列 `select count` 返回 `Empty set.`（不报错），只有通配 `select … from db.**` 才暴露 301；用户很难第一时间判断是"没数据"还是"查询崩了"。
4. **触发条件**：`tvlist_sort_algorithm=BACKWARD` 为非默认值（默认 `TIM`），因此**默认配置不受影响**；但一旦开启该算法，任何时间戳基本逆序的写入（例如设备补传历史数据、批量回灌）都可能命中。
5. **受影响版本**：`BackwardSort.java` 自引入以来未见修复；RC8、RC9 均已复现。

---

## 七、修复建议

### 7.1 立即修复：`setBlockLength` 增加边界守卫

`step >= timestamps.size()` 是**合法的采样结果**（采样点不足），应按"不切块"处理，而不是抛异常：

```java
public int setBlockLength(List<long[]> timestamps, int step) {
  int size = timestamps.size();
  if (step >= size) {
    // 采样步长已覆盖全部数组，无需再细分，直接按一个块处理
    return Math.max(size, 1) * ARRAY_SIZE;
  }
  double overlap = 0;
  long last_time = timestamps.get(0)[0];
  int i = step, blocks = 0;
  while (i < size) {
    long cur_time = timestamps.get(i)[0];
    if (last_time > cur_time) {
      overlap += 1;
    }
    last_time = cur_time;
    i += step;
    blocks += 1;
  }
  if (blocks == 0) {
    return Math.max(size, 1) * ARRAY_SIZE;   // 兜底，不再抛
  }
  ...
}
```

> 注意：仅把 `blocks == 0` 的 `throw` 改成 `return` 仍不够 —— 调用方 `backwardSort`（L88）用 `block_size` 计算 `B = rowCount / block_size + 1`，若返回值不合理会导致越界。需同时确认 `block_size > 0` 且 `B >= 1`。

### 7.2 加固：`backwardSort` 入口防御

```java
public void backwardSort(List<long[]> timestamps, int rowCount) {
  int block_size = setBlockLength(timestamps, 1);
  if (block_size <= 0) {
    block_size = Math.max(rowCount, 1);      // 兜底：整体当一块
  }
  ...
}
```

### 7.3 建议：把内部异常转成可定位的业务错误

即便保留异常，也应携带 `rowCount`、`timestamps.size()`、`step`、`ratio`、`mul` 等上下文，便于现场快速判断，而不是只输出 `blocks should never be zero.`。

### 7.4 建议：补充单测

`BackwardSortTest` 覆盖：全正序、全逆序、逆序比例 50%、行数 1 / 64 / 65 / 2000 / 10000，断言 `sort()` 不抛异常且结果有序。

---

## 八、用例侧需要同步修正的问题（测试侧，非产品）

1. 原 MB-15 用例只用 `select count(s1) from db.**` 取值，并用 `grep -oE '\| *[0-9]+'` 提取数字。**查询报 301 时提取结果为空，被当成 `0`**，于是报告成"点数=0"，把"查询报错"误判成"数据丢失"。
2. 已确认的正确现象是：**查询抛 `301: blocks should never be zero`**，而单序列 `count` 返回 `Empty set.`（不报错）。
3. **已修复并通过实测**（2026-10-22）：`lib/common.sh` 的 `mb_count_all` 改为先匹配错误特征，命中即返回字面量 `QUERY_ERROR` 并把原文打到 stderr；新增 `mb_count_all_strict`（报错返回非 0 退出码）。

实测结果：

| 场景 | 新实现返回 | 旧实现返回 |
|---|---|---|
| 查询报 301 | **`QUERY_ERROR`**（stderr 带 `301: blocks should never be zero.`） | `0` |
| 正常 2000 点 | `2000` | `2000` |
| 结果为空集 | 空（语义上就是"无数据"） | `0` |

> 这条也解释了历史上几轮的困惑：MB-15 报"点数=0"其实是**查询抛 301**，
> 旧判据把错误文本清洗掉后得到 0，于是把"查询崩溃"写成了"数据丢失"。
> 现象方向没判错（确实是异常），但错误类型被掩盖了，差点让排查走错方向。

---

## 九、证据归档

1. 证据包：`f09_rc9_evidence.tgz`（1.5 KB），含：
   - `dn_exception_stack.txt`：DataNode 侧完整异常栈（含 20+ 层调用帧）
   - `dn_301_stats.csv`：5 个 DataNode 的首次出现时间与命中次数
   - `BackwardSort_L85-131.java`：缺陷源码片段（RC9）
   - `env.txt`：`tvlist_sort_algorithm=BACKWARD`、`primitive_array_size=64`、版本信息
2. 复现脚本：本节 §二 的代码块可直接照抄执行。
3. 关联材料：
   - `docs/DEFECT_F-07.md`（同轮发现的另一个缺陷）
   - `docs/REPORT_RC9.md`（RC9 全量测试报告）
   - `cases/common/mb_15_tvlist_sort.sh`（回归用例，当前在 BACKWARD 阶段 FAIL）

---

## 十、附：与 RC8 的复现一致性

| 版本 | 配置 | 结果 |
|---|---|---|
| RC8 `ebaf9da` | `tvlist_sort_algorithm=BACKWARD`，4×500 逆序 | 查询不可用（当时误记为 count=0） |
| RC9 `d206dc2` | 同上 | `301: blocks should never be zero` + flush 后 0 点 + 无 TsFile |

两版 `BackwardSort.java` 逐字节相同，md5 均为 `c1bc2409af25737423cc1b24f769a9c0`；
`git diff ebaf9da d206dc2 -- '*BackwardSort.java'` 为空，`git diff d206dc2 HEAD` 同样为空
⇒ 缺陷在 RC8 / RC9 / 分支 HEAD 三处完全一致，RC9 的结论对 HEAD 也成立。
