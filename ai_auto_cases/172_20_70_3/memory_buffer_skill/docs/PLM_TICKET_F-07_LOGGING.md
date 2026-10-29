# PLM 缺陷单：配置校验失败导致启动退出时，异常未写入 logs/

> 本单**只针对"异常没有写入 logs/"**这一个问题。
> 研发已确认"配置非法时拒绝启动并退出"是**预期行为**，本单不对此提出异议。
> 但当前实现"退出"的方式使**真正的失败原因完全丢失**，影响现场定界，故单独提单。

---

## 一、缺陷基本信息

| 字段 | 内容 |
|---|---|
| **缺陷标题** | 内存比例配置非法导致 DataNode 启动失败时，异常栈未写入 `logs/`：`log_datanode_error.log` **零新增**、`log_datanode_all.log` **只记录到崩溃前最后一条正常 INFO 便戛然而止**（两个文件均无异常栈），仅启动脚本 stdout 有 |
| **严重级别** | **中高** —— 不影响数据，但直接导致现场问题无法定界 |
| **缺陷类型** | 可维护性 / 日志缺失 / 错误处理 |
| **发现版本** | `v20121rc9_1020_d206dc2`（TimechoDB 2.0.12.1，BuildInfo `d206dc2`） |
| **回归版本** | `v20121rc8_1016_ebaf9da`（BuildInfo `ebaf9da`）同样存在；两版 `DataNodeMemoryConfig.java` **逐字节相同** |
| **引入提交** | `49c8f004454` — *Add memory metrics and refact memory allocation (#14710)*，2025-03-07 |
| **最早受影响版本** | **v2.0.10.1**（`git tag --contains 49c8f004454` 确认） |
| **复现环境** | 3CN + 5DN，节点 `172.20.70.30`，JDK 17.0.9，堆 12.50G |
| **复现概率** | **100%**（本次 3 轮独立复现，配置隔离） |
| **发现途径** | 内存缓冲区专项测试用例 `MB-19` |

---

## 二、问题现象

将 `storage_engine_memory_proportion` 或 `write_memory_proportion` 配成非法值后启动 DataNode：

1. `logs/log_datanode_all.log` 里**有** `WARN`（说明 log4j 此时工作正常）；
2. `logs/log_datanode_all.log` 里**没有** `ERROR`，也**没有**任何异常栈；该文件在崩溃前最后一条正常 INFO 之后**直接中断**；
3. `logs/log_datanode_error.log` **大小、md5 完全不变**（零新增内容）；
4. 进程退出（退出码 1，非设计路径的 255）；
5. **完整异常栈只出现在启动脚本的 stdout/stderr**（`start-datanode.sh` 的输出重定向文件）。

现场运维的常规动作是查 `logs/log_datanode_error.log`，会看到一个**没有新内容**的文件，
从而误判为"没有任何错误 / 只是启动慢"，无法定界。

### 2.1 三个日志文件的精确表现（差分实测）

方法：记录启动前 `all.log` 的行数/大小/md5 作为基线，复现后只取**新增行**比对。

| 文件 | 本次新增 | 是否含异常栈 | 运维看到的现象 |
|---|---|---|---|
| `log_datanode_error.log` | **0 字节**（size 7226→7226，md5 不变） | ❌ 无 | 完全静默 |
| `log_datanode_all.log` | **15 行** | ❌ 无 | **日志戛然而止** |
| `log_datanode_warn.log` | **1 行** | ❌ 无 | 只有一条"已回退"的假消息 |

`all.log` 新增的 15 行**全文**（`0:10` 用例，10:12:21）：

```
INFO  IoTDBDescriptor:271        - Start to read config file ...
INFO  DataNodeMemoryConfig:236   - initial allocateMemoryForWrite = 1343016140
INFO  DataNodeMemoryConfig:239   - initial allocateMemoryForRead = 6715080704
INFO  DataNodeMemoryConfig:242   - initial allocateMemoryForSchema = 1343016140
INFO  DataNodeMemoryConfig:245   - initial allocateMemoryForConsensus = 1343016140
INFO  DataNodeMemoryConfig:248   - initial allocateMemoryForPipe = 1343016140
INFO  DataNodeMemoryConfig:251   - initial allocateMemoryForAutoResizingBuffer = 671508070
INFO  DataNodeMemoryConfig:358   - allocateMemoryForSchemaRegion = 671508070
INFO  DataNodeMemoryConfig:361   - allocateMemoryForSchemaCache = 537206456
INFO  DataNodeMemoryConfig:364   - allocateMemoryForPartitionCache = 134301614
WARN  DataNodeMemoryConfig:413   - The value of storage_engine_memory_proportion is illegal, use default value 8:2 .
INFO  TSFileDescriptor:141       - try loading iotdb-system.properties from ...
INFO  IoTDBDescriptor:2502       - MQTT host is not configured, will use dn_rpc_address.
INFO  CommonConfig:1962          - pipeAirGapRetryMaxMs is set to 720000.
INFO  IoTDBDescriptor:1400       - [DelayAnalyzer] Set delay_analyzer_window_size to 10000
```

**最后一行是正常 INFO，之后就断了** —— 没有异常、没有 ERROR、没有任何"进程正在退出"的标记。

在该窗口内对 `all.log` 逐项检查：

| 关键字 | 命中数 |
|---|---|
| `ExceptionInInitializerError` | **0** |
| `NullPointerException` | **0** |
| `getDevicePathCacheMemoryManager` | **0** |
| `Exception in thread` | **0** |
| `Caused by` | **0** |
| 新增 `ERROR` 行 | **0** |

> 说明：事后 `grep -c ERROR all.log` 会看到 9 条历史 ERROR，它们是**此前测试"解析期非法值"（`a:b` 等）留下的**，
> 时间戳均为 09:29–10:08；本次复现窗口 **10:12:21 内 ERROR = 0**。请勿误认为本次有记录。

### 2.2 为什么这个表现比"完全没日志"更危险

`all.log` 是**看起来在正常记录**的（15 行日志齐整），唯一的异常线索是那条
`WARN ... use default value 8:2`——语义是"我发现配置非法，已回退，没事了"。
紧接着日志正常继续，然后**毫无征兆地停止**。

运维面对的是**两条互相矛盾的线索**：

1. 日志明说"已使用默认值 8:2"（暗示配置问题已被自动修正、启动应能继续）；
2. 进程却消失了，且没有任何结束原因。

而且这条 WARN 同时写入 `all.log` 与 `warn.log` 两个文件，
等于**用一个"我已自愈"的假信号覆盖了真正的失败原因**。

---

## 三、复现步骤

```bash
V=v20121rc9_1020_d206dc2
CONF=/data/iotdb/$V/conf/iotdb-system.properties
L=/data/iotdb/$V/logs

# 1) 停节点
sudo pkill -9 -f 'com.timecho.iotdb.DataNode'      # 或用 stop-datanode.sh
sleep 3

# 2) 记录基线（重点：error.log 的 size 与 md5）
sudo ls -la $L/
sudo md5sum $L/log_datanode_error.log

# 3) 注入非法值（两种均可复现，务必分别测试、测前重置另一个配置项）
sudo sed -i 's|^storage_engine_memory_proportion=.*|storage_engine_memory_proportion=0:10|' $CONF
#   或 sudo sed -i 's|^write_memory_proportion=.*|write_memory_proportion=0:1|' $CONF

# 4) 启动，并把 stdout/stderr 单独留存
sudo setsid nohup /data/iotdb/$V/sbin/start-datanode.sh </dev/null >/tmp/dn.start 2>&1 &
sleep 50
sudo jps -l | grep -c DataNode        # 期望 0（进程已退出）

# 5) 观察三处
sudo grep -c 'is illegal' $L/log_datanode_all.log        # WARN 在 → log4j 正常
sudo grep -c 'ERROR'      $L/log_datanode_all.log        # 不增加
sudo md5sum $L/log_datanode_error.log                    # 与步骤 2 完全一致（没有新内容）
sudo stat -c %s $L/log_datanode_error.log                # 大小不变
grep -c 'ExceptionInInitializerError' /tmp/dn.start       # 异常在这里
```

---

## 四、实测证据（配置隔离，逐项对照）

测法：每个用例前**先重置两个配置项为合法值**，只注入一项，再启动；
每例记录 `error.log` 的 size 与 md5、`all.log` 的 ERROR 行数、stdout 的异常命中数。

| 用例 | 配置 | 进程 | `error.log` size | `error.log` md5 | `all.log` ERROR 行数 | 异常栈位置 |
|---|---|---|---|---|---|---|
| **A** | `storage_engine_memory_proportion=0:10` | 退出 | 7226 → **7226** | **未变化** | 7 → **7**（+0） | 仅 stdout |
| **B** | `write_memory_proportion=0:1` | 退出 | 7226 → **7226** | **未变化** | 7 → **7**（+0） | 仅 stdout |
| **C（对照）** | `storage_engine_memory_proportion=a:b` | 退出 | 7226 → **8312** | **已变化** | 7 → **8**（+1） | **error.log 有完整栈** |

### 用例 A 的实测量（隔离，仅改 storage 一项）

```
conf: storage_engine_memory_proportion=0:10
conf: write_memory_proportion=19:1
DataNode 存活=0
error.log 大小      : 7226 -> 7226
error.log md5 变化  : 未变（无新内容）
all.log ERROR 行数  : 7 -> 7
启动 stdout 中本用例触发的 WARN:
  DataNodeMemoryConfig:413 - The value of storage_engine_memory_proportion is illegal
启动 stdout 中 ExceptionInInitializerError 行数: 1
logs/ 中是否出现该异常栈关键字: 0 个文件
```

### 用例 B 的实测量（隔离，仅改 write 一项）

```
conf: storage_engine_memory_proportion=8:2
conf: write_memory_proportion=0:1
DataNode 存活=0
error.log 大小      : 7226 -> 7226
error.log md5 变化  : 未变（无新内容）
all.log ERROR 行数  : 7 -> 7
启动 stdout 中本用例触发的 WARN:
  DataNodeMemoryConfig:437 - The value of write_memory_proportion is illegal
启动 stdout 中 ExceptionInInitializerError 行数: 1
logs/ 中是否出现该异常栈关键字: 0 个文件
```

### 用例 C（对照）证明了"同一个函数、同类错误，有日志"

`logs/log_datanode_error.log` 新增内容（完整）：

```
2026-10-22 10:05:54,821 [main] ERROR o.a.i.d.c.IoTDBDescriptor:321 - Incorrect format in config file, reject DataNode startup.
java.lang.NumberFormatException: For input string: "a"
	at java.base/java.lang.NumberFormatException.forInputString(NumberFormatException.java:67)
	at java.base/java.lang.Integer.parseInt(Integer.java:668)
	at java.base/java.lang.Integer.parseInt(Integer.java:786)
	at org.apache.iotdb.db.conf.DataNodeMemoryConfig.initStorageEngineAllocate(DataNodeMemoryConfig.java:411)
	at org.apache.iotdb.db.conf.DataNodeMemoryConfig.init(DataNodeMemoryConfig.java:256)
	at org.apache.iotdb.db.conf.IoTDBDescriptor.loadProperties(IoTDBDescriptor.java:416)
	at org.apache.iotdb.db.conf.IoTDBDescriptor.loadProps(IoTDBDescriptor.java:312)
	at org.apache.iotdb.db.conf.IoTDBDescriptor.<init>(IoTDBDescriptor.java:164)
	at org.apache.iotdb.db.conf.IoTDBDescriptor$IoTDBDescriptorHolder.<clinit>(IoTDBDescriptor.java:4009)
	at org.apache.iotdb.db.conf.IoTDBDescriptor.getInstance(IoTDBDescriptor.java:197)
	at org.apache.iotdb.db.service.DataNode.<clinit>(DataNode.java:169)
```

> 关键：**这是同一个 `initStorageEngineAllocate()`（L411），只是取值不同、走的代码路径不同**。
> 走 `Integer.parseInt` 抛异常时**有完整 ERROR 日志**；走 `<=0` 的 `return` 分支时**一条都没有**。

### 退出码也不一致

| 路径 | 退出码 |
|---|---|
| A/B（`return` → 后续 NPE） | **1**（JVM 未捕获异常默认值） |
| C（对照，`IoTDBDescriptor` 主动 `System.exit(-1)`） | **255** |

若"拒绝启动"是设计行为，C 的路径（`LOGGER.error(...)` + `System.exit(-1)`）才是设计好的形态；
A/B 目前是"意外崩溃退出"，连退出码都不是设计值。此点请研发确认是否也需对齐。

---

## 五、根因分析（基于 RC9 源码 `d206dc2`）

### 5.1 直接原因：`return` 吞掉了错误，失败被推迟到 `try/catch` 之外

`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/DataNodeMemoryConfig.java`：

```java
407  if (valueOfStorageEngineMemoryProportion != null) {
410    for (String proportion : storageProportionArray) {
411      int proportionValue = Integer.parseInt(proportion.trim());
412      if (proportionValue <= 0) {
413        LOGGER.warn(... "use default value 8:2" ...);
416        return;        // ← 只打 WARN，不上抛、不记录 ERROR
417      }
...
433      for (String proportion : writeProportionArray) {
436        if (proportionValue <= 0) {
437          LOGGER.warn(... "use default value 19:1" ...);
440          return;        // ← 同上
441        }
```

`return` 使方法带着**未完成初始化**的状态正常返回，调用方毫无感知。

### 5.2 后果：7 个 MemoryManager 全为 `null`，稍后 NPE

`return` 之后的 L454–L471 才是 7 个 manager 的创建：

```
454  writeMemoryManager              ← 被跳过
456  compactionMemoryManager        ← 被跳过
457  memtableMemoryManager          ← 被跳过
459  timePartitionInfoMemoryManager ← 被跳过
463  devicePathCacheMemoryManager   ← 被跳过 ← NPE 源头
468  bufferedArraysMemoryManager    ← 被跳过
471  walBufferQueueMemoryManager    ← 被跳过
```

崩溃链：

```
DataNodeMemoryConfig.initStorageEngineAllocate()   L416 / L440 提前 return
        ↓  devicePathCacheMemoryManager == null
com.timecho.iotdb.DataNode.prepare()               DataNode.java:70
        ↓
SessionManager.<clinit>()                          SessionManager.java:91
        ↓
DNAuditLogger.<clinit>()                           DNAuditLogger.java:132
        ↓
DataNodeDevicePathCache.getInstance()              DataNodeDevicePathCache.java:58
        ↓
DataNodeDevicePathCache.<init>()                   DataNodeDevicePathCache.java:46
        ↓  devicePathCacheMemoryManager.exactAllocate(...)
NullPointerException → ExceptionInInitializerError → main 线程终止
```

### 5.3 为什么"这次"没有日志（核心）

对比两条路径所处的**代码位置**：

| 路径 | 异常发生位置 | 是否在已部署的 try/catch 内 | 结果 |
|---|---|---|---|
| **C（对照）** | `IoTDBDescriptor.loadProperties()` 内部 | **是** —— `IoTDBDescriptor` L320 `catch (Exception e) { LOGGER.error(INCORRECT_FORMAT_CONFIG_FILE, e); System.exit(-1); }` | 写入 `error.log` ✅ |
| **A/B（本单）** | `prepare()` → `SessionManager.<clinit>` | **否** —— 见下 | 无日志 ❌ |

`prepare()` 的调用时机与日志保护范围：

```java
// timecho-server/src/main/java/com/timecho/iotdb/DataNode.java
65  public static void main(String[] args) {
66    startUp(args, DataNode::new);          // ← 无 try/catch
67  }
82  protected static void startUp(String[] args, Supplier<DataNode> dataNodeSupplier) {
83    prepare();                              // ★ 异常在此抛出，不受任何 try/catch 保护
...
101   DataNode dataNode = dataNodeSupplier.get();
102   int returnCode = dataNode.run(args);   // ← run() 内部才有 catch(Throwable)
```

而 `org.apache.iotdb.db.service.DataNode` 的 `catch (Throwable)` 位于 `start()` 内（L410–L415），
**`start()` 在 `prepare()` 之后才被调用**：

```java
// iotdb-core/datanode/src/main/java/org/apache/iotdb/db/service/DataNode.java
263  public void start() {
...
410    } catch (Throwable e) {
411      int exitStatusCode = retrieveExitStatusCode(e);
412      logger.error(DataNodeMiscMessages.FAIL_TO_START_SERVER, e);   // ← 这里本该记录
413      stop();
414      System.exit(exitStatusCode);
415    }
```

**结论**：`prepare()` 阶段（`SessionManager` / `DNAuditLogger` / `DataNodeDevicePathCache` 的静态初始化）
处于**日志保护的盲区**——它在 `start()` 的 `catch (Throwable)` 之外，`main()` / `startUp()` 也没有兜底
`try/catch`，因此异常直接逃逸到 JVM 默认 handler，只写 stderr。

### 5.4 为什么 WARN 能进日志，而异常不能

`WARN` 由 `DataNodeMemoryConfig` 通过 log4j **主动**写出，此时 log4j 已初始化完成 → 正常落 `all.log` / `warn.log`。
而后续的 `ExceptionInInitializerError` 发生在静态初始化链中且**无人捕获**，没有任何代码去调用 `LOGGER.error`，
JVM 只能打印到 `System.err`。**不是 log4j 没初始化，而是没有代码记录它。**

---

## 六、影响评估

| 维度 | 评估 |
|---|---|
| 数据安全 | 无影响（配置错误，不涉及数据损坏） |
| 服务影响 | 单节点无法启动；批量下发同一错误配置时整集群不可用 |
| **定界成本** | **高**。`logs/` 无 ERROR、`error.log` 无新增，现场只能看到进程"静默退出"；需登录机器翻启动脚本 stdout 才能定位，远高于常规日志排查 |
| 误导风险 | `WARN` 文案写"use default value 8:2"，会让人以为已回退、可以正常启动，与随后退出的事实矛盾 |
| 受影响版本 | v2.0.10.1 起 |

---

## 七、修复建议

### 7.1 必做（本单核心）：给 `prepare()` 阶段加日志兜底

在 `com.timecho.iotdb.DataNode.main()` / `startUp()` 外包一层 `try/catch (Throwable)`，
捕获后**先写日志再退出**。log4j 此时已可用（`WARN` 已能正常落盘，可作为依据）。

```java
// timecho-server/src/main/java/com/timecho/iotdb/DataNode.java
public static void main(String[] args) {
  try {
    startUp(args, DataNode::new);
  } catch (Throwable e) {
    // prepare() 阶段（SessionManager / DNAuditLogger / DataNodeDevicePathCache
    // 等静态初始化）在 DataNode.start() 的 catch(Throwable) 之外，
    // 必须在这里兜底记录，否则异常只会打到 stderr，logs/ 里看不到。
    logger.error(TimechoServerMessages.FAIL_TO_START_DATANODE, e);
    System.exit(-1);
  }
}
```

**注意**：`logger` 若在极端场景（更早的静态初始化）也未就绪，应增加降级：
写 `System.err` 的同时，直接以 `FileOutputStream` 追加到 `logs/log_datanode_error.log`，确保"任何启动失败都必须有落盘痕迹"。

### 7.2 建议同时修（消除错误源头，可选）

`initStorageEngineAllocate()` 的两个 `return`（L416、L440）改为"标记 + 跳过解析块"。
默认值在 L403–L406 已算好，`return` 并不必要。

> ⚠️ **不能简单把 `return` 改成 `break`**：对 `0:10` 而言 `storageEngineMemoryProportion` 会变成部分和 **0**，
> 随后 L423 用它作除数 → `ArithmeticException: / by zero`，异常类型变了但仍在盲区里、仍然无日志。

### 7.3 建议同时修（同类问题一次性覆盖）

同一函数对"格式非法"无任何防御，以下写法同样会让节点退出，且同样**不写 logs/**（已实测）：

| 配置 | 异常 |
|---|---|
| `storage_engine_memory_proportion=10`（单段） | `ArrayIndexOutOfBoundsException`（L426） |
| `storage_engine_memory_proportion=a:b` | `NumberFormatException`（L411）→ 此条**有**日志（走 5.3 的 C 路径） |
| `write_memory_proportion=19`（单段） | `ArrayIndexOutOfBoundsException`（L450） |

> 注意：`a:b` 会在解析期抛出并被 `IoTDBDescriptor` 捕获（有日志）；
> 但**单段（越界）** 与 **`<=0`** 这两类不抛异常或抛在盲区，**都没有日志**。
> 修 7.1 的兜底可一次性覆盖全部情况。

---

## 八、验收标准

修复后需同时满足：

| # | 验收项 | 判定方法 |
|---|---|---|
| 1 | `storage_engine_memory_proportion=0:10` 时，`logs/log_datanode_error.log` **有新增内容** | 比对 size / md5 变化 |
| 2 | 该文件内包含 `ExceptionInInitializerError`（或等价明确错误）与 `DataNodeMemoryConfig` 调用帧 | `grep` 命中 |
| 3 | `logs/log_datanode_all.log` 中出现对应 `ERROR` 行（含异常栈） | ERROR 计数 +1，且新增行中含异常类名 |
| 3b | `logs/log_datanode_all.log` **不再"戛然而止"**：进程退出前有明确的失败/退出记录 | 最后一条日志不是普通 INFO |
| 4 | `write_memory_proportion=0:1` 同样满足 1–3 | 同上 |
| 5 | 单段（`=10` / `=19`）同样满足 1–3 | 同上 |
| 6 | 合法配置下启动不受影响，`logs/` 无新增 ERROR | 回归 |
| 7 | （若采纳 7.1 的退出码建议）退出码与设计路径一致 | 对比 `a:b` 路径的 255 |

**回归用例**：`membuf_skill/cases/common/mb_19_illegal_proportion.sh`（当前覆盖 `0:10`），
建议扩充为 5 种非法写法的参数化用例。

---

## 九、附件

| 内容 | 位置 |
|---|---|
| 缺陷源码（RC9） | `git show d206dc2:iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/DataNodeMemoryConfig.java` |
| 启动入口源码 | `git show d206dc2:timecho-server/src/main/java/com/timecho/iotdb/DataNode.java`（L65-106） |
| 日志保护位置 | `git show d206dc2:iotdb-core/datanode/src/main/java/org/apache/iotdb/db/service/DataNode.java`（L263 start / L410 catch） |
| 配置加载 catch | `git show d206dc2:iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/IoTDBDescriptor.java`（L320-322） |
| 复现脚本 | 本单 §三；节点留档 `/tmp/verify5.sh`、`/tmp/v5_{A,B,C}.start` |
| 关联文档 | `docs/DEFECT_F-07.md`（含 NPE 根因与 `return` 引发的 manager-null 完整分析） |
