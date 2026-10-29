# 分析：大 payload 写入慢的根因（不是死锁、不是内存）

> 起因：MB-14 出现"写入语句成功数=0、1200 点只进 260 点"，怀疑死锁或内存不足。
> 结论：**都不是**。真正的瓶颈在 **CLI 客户端**，服务端全程空闲。
> 环境：TimechoDB 2.0.12.1 / RC9 `d206dc2`，3C5D。日期：2026-10-22。

---

## 一、先排除死锁与内存

写入进行中，对 3 个 DataNode 各做 3 轮 `jstack -l` + `jcmd GC.heap_info`：

| 观测项 | 实测 |
|---|---|
| `Found one Java-level deadlock` | **0**（三轮全部无） |
| `Thread.State: BLOCKED` 线程数 | **0 / 0 / 0** |
| G1 堆（总 13.1 GB）使用 | 250 MB → 390 MB，**约 3%** |
| 写入推进 | 25s→260 点、45s→520、65s→780、**110s→1200**（匀速前进） |

⇒ **不存在死锁，也不存在内存压力。写入是"慢"，不是"卡住"。**

---

## 二、瓶颈在客户端，不在服务端

### 2.1 服务端线程栈：一直在"等客户端"

密集采样（1.5s 一次，共 14 次）中，处理写入的
`pool-42-IoTDB-ClientRPC-Processor-1` 多数采样停在：

```
java.lang.Thread.State: RUNNABLE
  at sun.nio.ch.SocketDispatcher.read0(Native Method)
  ...
  at org.apache.thrift.protocol.TBinaryProtocol.readMessageBegin(TBinaryProtocol.java:252)
  at org.apache.iotdb.db.protocol.thrift.ProcessorWithMetrics.process(ProcessorWithMetrics.java:51)
  at org.apache.thrift.server.TThreadPoolServer$WorkerProcess.run(TThreadPoolServer.java:264)
```

即：**上一个请求已处理完，正在等客户端发下一个**。而且该线程 18 秒只累计 55ms CPU，
是"RUNNABLE 但阻塞在原生 socket 读"，不是计算。

### 2.2 CPU 归属：客户端打满、服务端空转

同一时刻的 `top`：

| 侧 | 进程 | %CPU |
|---|---|---|
| **客户端 172.20.70.3** | `java`（CLI，PID 27855，RSS 916 MB） | **106.7%** |
| 服务端 172.20.70.4 | DataNode | **未进入 top 前 12（≈0%）** |

⇒ **CPU 全耗在 CLI 上，DataNode 几乎不干活。**

---

## 三、耗时规律：只与 SQL 总字节数成正比

### 3.1 与语句条数/行长无关

总数据量近似相同（325 点 × 4KB），只改语句切分方式：

| 切分 | 条数 × 每行 | 总耗时 | 每条耗时 |
|---|---|---|---|
| 长语句 | 5 × 65 行（约 260 KB/条） | **27.6 s** | 5514 ms |
| 中语句 | 25 × 13 行（约 52 KB/条） | **29.0 s** | 1161 ms |
| 短语句 | 65 × 5 行（约 20 KB/条） | **29.0 s** | 445 ms |

⇒ 总耗时几乎恒定（约 28 s）⇒ **与语句条数、单条长度都无关**，只看总字符数。

### 3.2 与 payload 大小成正比

同一批 19 条语句 × 65 行（1235 点），只改每点 payload：

| payload/点 | 总耗时 | 每条耗时 | 折合 SQL 文本吞吐 |
|---|---|---|---|
| 10 B | 6.6 s | 349 ms | — |
| 500 B | 16.2 s | 854 ms | ≈38 KB/s |
| 4000 B | 91.8 s | 4832 ms | **≈57 KB/s** |

线性拟合：`每条耗时 ≈ 286 ms + 1.14 ms × 每点字节数`
⇒ **每字节约 17.4 秒/MB，即约 57 KB/s**。这个量级既不像网络，也不像磁盘，是典型的**客户端逐字符处理**。

### 3.3 与共识协议无关

同一份数据（1200 点 × 4KB，19 条语句）：

| 协议 | 总耗时 |
|---|---|
| IoTConsensus（V1） | 108 s |
| IoTConsensusV2 | 110 s |

⇒ 完全一致，**与 V1/V2 无关**。

---

## 四、源码层面的根因

### 4.1 CLI 的所有输入都走 JLine，没有"非交互/管道"分支

`iotdb-client/cli/src/main/java/org/apache/iotdb/cli/Cli.java`

```java
103  LineReader lineReader = JlineUtils.getLineReader(ctx, username, host, port);  // ← 无条件构建
107  ctx.setLineReader(lineReader);
...
254  private static boolean readerReadLine(CliContext ctx, IoTDBConnection connection) {
257    s = ctx.getLineReader().readLine(cliPrefix + "> ", null);   // ← 主循环永远走 JLine
258    boolean continues = processCommand(ctx, s, connection);
```

`JlineUtils.getLineReader()` 里也没有按 TTY 分流：

```java
57  public static LineReader getLineReader(CliContext ctx, ...) {
61    // Defaulting to a dumb terminal when a supported terminal can not be correctly created
66    if (ctx.getIn() == System.in && ctx.getOut() == System.out) {
67      terminal = TerminalBuilder.builder().dumb(true).build();
68    } else {
69      terminal = TerminalBuilder.builder().streams(ctx.getIn(), ctx.getOut()).dumb(true).build();
    }
81    LineReaderBuilder builder = LineReaderBuilder.builder();
119   LineReader lineReader = builder.build();
```

即：**无论是交互输入还是 `start-cli.sh < script.sql` 的脚本重定向，输入都被送入
JLine 的 `LineReaderImpl.readLine()`**，进入逐字符的行编辑处理（键盘映射分派、
buffer 插入、光标/显示更新等），而不是简单的 `BufferedReader.readLine()`。

这就是为什么：
- CPU 100% 在客户端；
- 吞吐只有约 57 KB/s，且严格正比于字符数；
- 与语句怎么切分无关（JLine 是逐字符处理，总字符数不变则总开销不变）；
- 与服务端、共识协议、内存都无关。

### 4.2 为什么这会让用例"看起来像挂住"

用例普遍用 4 KB TEXT payload。按 ≈57 KB/s 估算：

| 数据量 | SQL 文本 | 预计耗时 |
|---|---|---|
| 1200 点 × 4 KB | ≈4.9 MB | **≈90–110 s** |
| 2000 点 × 4 KB | ≈8.2 MB | **≈150–190 s** |

而 MB-14 的写入窗口按"几秒"设计，于是出现"写入还没跑完就被判定失败/点数只有 260"。
**这不是产品问题，也不是环境卡死。**

---

## 五、对测试用例的影响与处置

1. **给足时间**：任何使用 4 KB 级 payload 的用例，写入预算按 `总KB × 0.018` 秒估算，再留 2 倍余量。
   本次 MB-14 重跑（写入窗口充足）结果为 **PASS fail_flag=0**（19/19 语句、1200 点、耗时 108 s）。
2. **或降低 payload**：把 `MB_PAYLOAD_BYTES` 从 4000 调小可线性加速（10 B 时快约 14 倍）。
   注意：涉及 memtable 阈值/刷盘的用例仍需足够字节数，不能一味调小。
3. **不要把"慢"当成"卡"**：判定用例前先看点数是否仍在增长；若在增长，应延长等待而不是判失败。

---

## 六、可以反馈给研发的 CLI 改进点（非缺陷，属体验/性能）

`start-cli.sh` 以脚本方式（stdin 非 TTY）执行时，输入其实不需要行编辑能力。
建议在检测到 stdin 不是 TTY 时，改用 `BufferedReader` 逐行读取，可望把脚本导入速度
从约 57 KB/s 提升到与磁盘/网络相当的量级。这对批量导入、回归脚本、CI 都收益明显。

> 说明：本条仅为工程改进建议，不作为缺陷。当前行为不影响数据正确性。

---

## 七、结论一句话

**慢的根因是 CLI 用 JLine 逐字符处理脚本输入（客户端 CPU 打满、约 57 KB/s），DataNode 全程空闲；
既不是死锁，也不是内存问题，更与 IoTConsensus V1/V2 无关。**
