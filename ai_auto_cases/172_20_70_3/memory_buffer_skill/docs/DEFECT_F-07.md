# 缺陷报告：非法的内存比例配置导致 DataNode 无法启动（NPE）

| 字段 | 内容 |
|---|---|
| **缺陷编号** | F-07 |
| **标题** | 非法的 `storage_engine_memory_proportion` / `write_memory_proportion` 导致 DataNode 启动即崩溃（`ExceptionInInitializerError`），且日志谎称"已使用默认值" |
| **严重级别** | **高（Blocker）** —— 配置写错会让节点进程直接退出，且**日志里看不到异常**，排查成本极高 |
| **缺陷类型** | 功能缺陷 / 错误处理不当 / 日志误导 |
| **发现版本** | `v20121rc9_1020_d206dc2`（TimechoDB 2.0.12.1，BuildInfo `d206dc2`） |
| **回归确认** | `v20121rc8_1016_ebaf9da`（BuildInfo `ebaf9da`）同样存在，两版该源文件**逐字节相同** |
| **引入提交** | `49c8f004454` — *Add memory metrics and refact memory allocation (#14710)*，ZhangHongYin，2025-03-07 |
| **最早受影响版本** | **v2.0.10.1**（`git tag --contains 49c8f004454`） |
| **当前状态** | **未修复**（RC8、RC9 均复现） |
| **发现用例** | `MB-19`（`cases/common/mb_19_illegal_proportion.sh`） |
| **报告日期** | 2026-10-22 |

---

## 一、问题概述

`DataNodeMemoryConfig.initStorageEngineAllocate()` 在校验 `storage_engine_memory_proportion` 与
`write_memory_proportion` 时，遇到非法的分段值（`<= 0`）会先打一条 **"use default value ..."** 的
`WARN`，然后执行 **`return`**。

但该 `return` 的位置在**整个方法的前 1/3**：`return` 之后还有 **7 个 MemoryManager 的创建语句**。
一旦提前返回，这 7 个 manager 全部保持 `null`，DataNode 后续初始化到
`DataNodeDevicePathCache` 时对 `getDevicePathCacheMemoryManager()` 做解引用，抛
`NullPointerException`，包成 `ExceptionInInitializerError`，**main 线程直接退出，进程起不来**。

核心矛盾：**日志说"已回退到默认值"，代码实际什么都没回退，而是把整个方法腰斩了。**

---

## 二、复现步骤

### 2.1 最小复现（单节点，60 秒）

```bash
# 环境：任意 DataNode，TimechoDB 2.0.12.1 (d206dc2)
V=v20121rc9_1020_d206dc2
CONF=/data/iotdb/$V/conf/iotdb-system.properties

# 1) 停节点
sudo /data/iotdb/$V/sbin/stop-datanode.sh

# 2) 注入非法比例（任选其一即可复现）
sudo sed -i 's|^storage_engine_memory_proportion=.*|storage_engine_memory_proportion=0:10|' $CONF
# 或者：sudo sed -i 's|^write_memory_proportion=.*|write_memory_proportion=0:1|' $CONF

# 3) 启动
sudo setsid nohup /data/iotdb/$V/sbin/start-datanode.sh </dev/null >/tmp/repro.start 2>&1 &

# 4) 观察：进程不存在
sudo jps -l | grep DataNode     # ← 空

# 5) 关键：异常不在 logs/ 里，在启动脚本的 stdout（/tmp/repro.start）
sudo grep -A20 'Exception in thread' /tmp/repro.start
```

### 2.2 集群视角复现

5 个 DataNode 全部配置 `storage_engine_memory_proportion=0:10` 后启动，
`show cluster` 只剩 3 个 ConfigNode 在线，**5 个 DataNode 全部缺失**，集群不可用。

### 2.3 复现结果（RC9 实测，2026-10-22）

**第一次：`storage_engine_memory_proportion=0:10`**

```
2026-10-22 09:25:11,068 [main] WARN  o.a.i.d.c.DataNodeMemoryConfig:413
  - The value of storage_engine_memory_proportion is illegal, use default value 8:2 .

Exception in thread "main" java.lang.ExceptionInInitializerError
	at org.apache.iotdb.db.queryengine.plan.analyze.cache.schema.DataNodeDevicePathCache.getInstance(DataNodeDevicePathCache.java:58)
	at org.apache.iotdb.db.audit.DNAuditLogger.<clinit>(DNAuditLogger.java:132)
	at org.apache.iotdb.db.protocol.session.SessionManager.<clinit>(SessionManager.java:91)
	at com.timecho.iotdb.DataNode.prepare(DataNode.java:70)
	at com.timecho.iotdb.DataNode.AbstractFactory(DataNode.java:83)
	at com.timecho.iotdb.DataNode.main(DataNode.java:66)
Caused by: java.lang.NullPointerException: Cannot invoke
  "org.apache.iotdb.commons.memory.MemoryManager.exactAllocate(String, org.apache.iotdb.commons.memory.MemoryBlockType)"
  because the return value of
  "org.apache.iotdb.db.conf.DataNodeMemoryConfig.getDevicePathCacheMemoryManager()" is null
	at org.apache.iotdb.db.queryengine.plan.analyze.cache.schema.DataNodeDevicePathCache.<init>(DataNodeDevicePathCache.java:46)
	at org.apache.iotdb.db.queryengine.plan.analyze.cache.schema.DataNodeDevicePathCache$DataNodeDevicePathCacheHolder.<clinit>(DataNodeDevicePathCache.java:63)
	... 6 more
```

**第二次：`write_memory_proportion=0:1`（同源问题）**

```
2026-10-22 09:26:22,769 [main] WARN  o.a.i.d.c.DataNodeMemoryConfig:437
  - The value of write_memory_proportion is illegal, use default value 19:1 .

Exception in thread "main" java.lang.ExceptionInInitializerError
Caused by: java.lang.NullPointerException: ... getDevicePathCacheMemoryManager() is null
```

> **两次都复现，且第二个配置项走的是**同一段有缺陷的代码**（两个 `return`，同一后果）。

---

## 三、根因分析（基于 RC9 源码）

文件：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/DataNodeMemoryConfig.java`

### 3.1 缺陷点一（L410–L417）

```java
407  if (valueOfStorageEngineMemoryProportion != null) {
408    String[] storageProportionArray = valueOfStorageEngineMemoryProportion.split(":");
409    int storageEngineMemoryProportion = 0;
410    for (String proportion : storageProportionArray) {
411      int proportionValue = Integer.parseInt(proportion.trim());
412      if (proportionValue <= 0) {
413        LOGGER.warn(
414            DataNodeMiscMessages
415                .MISC_LOG_THE_VALUE_OF_STORAGE_ENGINE_MEMORY_PROPORTION_IS_ILLEGAL_22CA9433);
416        return;          // ★★ 缺陷：本意是"回退默认值"，实际把整个方法腰斩
417      }
418      storageEngineMemoryProportion += proportionValue;
419    }
```

### 3.2 缺陷点二（L433–L441）

```java
433      for (String proportion : writeProportionArray) {
434        int proportionValue = Integer.parseInt(proportion.trim());
435        writeMemoryProportion += proportionValue;
436        if (proportionValue <= 0) {
437          LOGGER.warn(
438              DataNodeMiscMessages
439                  .MISC_LOG_THE_VALUE_OF_WRITE_MEMORY_PROPORTION_IS_ILLEGAL_USE_DEFAULT_EE4FA112);
440          return;          // ★★ 同源缺陷
441        }
442      }
```

### 3.3 被跳过的 7 个 MemoryManager（L454–L471）

这 7 个赋值**全部位于两个 `return` 之后**，一旦提前返回就全部保持 `null`：

| # | 行号 | 字段 |
|---|---|---|
| 1 | L454 | `writeMemoryManager` |
| 2 | L456 | `compactionMemoryManager`（经 `initCompactionMemoryManager`） |
| 3 | L457 | `memtableMemoryManager` |
| 4 | L459 | `timePartitionInfoMemoryManager` |
| 5 | L463 | `devicePathCacheMemoryManager` |
| 6 | L468 | `bufferedArraysMemoryManager` |
| 7 | L471 | `walBufferQueueMemoryManager` |

### 3.4 崩溃链路

```
DataNodeMemoryConfig.initStorageEngineAllocate()      ← L416 / L440 提前 return
        ↓  7 个 manager 全为 null
DataNodeMemoryConfig.getDevicePathCacheMemoryManager()  ← L770 返回 null
        ↓
DataNodeDevicePathCache.<init>()                        ← :46 对 null 调 .exactAllocate(...)
        ↓
DataNodeDevicePathCache$DataNodeDevicePathCacheHolder.<clinit>   ← :63 静态初始化
        ↓
DataNodeDevicePathCache.getInstance()                   ← :58
        ↓
DNAuditLogger.<clinit>                                  ← :132
        ↓
SessionManager.<clinit>                                 ← :91
        ↓
DataNode.prepare() → AbstractFactory() → main()          ← 进程退出
```

### 3.5 为什么"默认值"本来就在手边

注意 L403–L406，**默认值在进入 `if` 之前就已经算好了**：

```java
403  long writeMemorySize          = storageMemoryTotal * 8 / 10;     // ← 8:2 默认
404  long compactionMemorySize     = storageMemoryTotal * 2 / 10;
405  long memtableMemorySize       = writeMemorySize * 19 / 20;       // ← 19:1 默认
406  long timePartitionInfoMemorySize = writeMemorySize / 20;
```

所以"回退默认值"的正确实现就是**跳过这个解析块**，让 L403–L406 的值生效即可 ——
**代码里根本不需要 `return`**。这也说明 L416/L440 的 `return` 是笔误性质的实现错误，
作者的意图（看 WARN 文案）确实是回退默认值。

---

## 四、附带问题：`<=0` 这两条路径的异常不落 `logs/`，只落启动脚本 stdout

> 本节结论已用**配置隔离 + 基线比对**严格复测（2026-10-22，3 轮），
> 并含一个"同类错误有日志"的对照组。详细证据与 PLM 单见 **[PLM_TICKET_F-07_LOGGING.md](PLM_TICKET_F-07_LOGGING.md)**。

### 4.1 实测对照

测法：每例前先把两个配置项重置为合法值，只注入一项；记录 `error.log` 的 size+md5、
`all.log` 的 ERROR 行数、stdout 的异常命中数。

| 用例 | 配置 | 进程 | `error.log` size / md5 | `all.log` 表现 | 异常栈位置 |
|---|---|---|---|---|---|
| **A** | `storage_engine_memory_proportion=0:10` | 退出 | 7226 → 7226，**未变化** | 新增 15 行（14 INFO + 1 误导性 WARN），**无异常、无 ERROR，戛然而止** | 仅 stdout |
| **B** | `write_memory_proportion=0:1` | 退出 | 7226 → 7226，**未变化** | 同上（WARN 落在 `:437`） | 仅 stdout |
| **C（对照）** | `storage_engine_memory_proportion=a:b` | 退出 | 7226 → **8312**，**已变化** | 新增 1 条 ERROR + 完整栈 | **error.log 有完整栈** |

> **注意两个文件都没记录异常栈**：A/B 的 `all.log` 虽然新增了 15 行，但全部是崩溃**之前**的正常日志，
> `ExceptionInInitializerError` / `NullPointerException` / `Caused by` 在 `all.log` 中命中数均为 **0**。
> 详细差分见 [PLM_TICKET_F-07_LOGGING.md](PLM_TICKET_F-07_LOGGING.md) §2.1。

`WARN` 在 A/B 中确实写入了 `all.log`（增量可见），**说明 log4j 当时工作正常** ——
缺日志不是因为日志框架没就绪，而是**没有代码去记录这个异常**。

### 4.2 为什么"这个"异常没被记录

`<=0` 分支执行 `return` 后，错误被吞掉，失败被推迟到 `prepare()` 阶段的静态初始化里：

```
com.timecho.iotdb.DataNode.main()                 L65-67   无 try/catch
  └─ startUp()                                    L82-106  无 try/catch
       ├─ prepare()                               L83  ★ 异常在此抛出（盲区）
       │    └─ SessionManager.<clinit> → DNAuditLogger.<clinit>
       │         → DataNodeDevicePathCache.<init> → NPE
       └─ dataNode.run()                          L102
            └─ DataNode.start()                   L263
                 └─ catch (Throwable e)           L410
                      logger.error(FAIL_TO_START_SERVER, e);   ← 本应记录，但没走到
```

而对照组 C 的 `NumberFormatException` 抛在 `IoTDBDescriptor.loadProperties()` 内部，
被 `IoTDBDescriptor` L320 的 `catch (Exception e) { LOGGER.error(...); System.exit(-1); }` 捕获 →
**能进 `error.log`**。

**一句话根因**：`prepare()` 阶段位于 `DataNode.start()` 的 `catch (Throwable)` **之外**，
`main()` / `startUp()` 也没有兜底，异常因此逃逸到 JVM 默认 handler，只写 stderr。

### 4.3 顺带：退出码也与设计路径不一致

| 路径 | 退出码 |
|---|---|
| A/B（`return` → 后续 NPE） | **1**（JVM 未捕获异常默认值） |
| C（`IoTDBDescriptor` 主动 `System.exit(-1)`） | **255** |

### 4.4 影响

运维按常规查 `logs/log_datanode_error.log`，会看到**没有新增内容**，容易误判为"没有错误、只是启动慢"。
本次测试中用例侧也因此加了"启动崩溃快速失败"逻辑，才没白等 600 秒。

## 五、修复建议

### 5.1 推荐方案：把"回退"真正实现为回退

**要点**：默认值在 L403–L406 已经算好，所以"回退默认值" = **跳过解析块**，
根本不需要 `return`。同时把"段数/格式"校验前置，覆盖 §5.2 的三种崩溃。

建议抽一个小的校验方法，两类比例共用：

```java
/** 校验 "a:b" 形式的比例串；非法返回 null（调用方保持默认值）。 */
private static int[] parseTwoSegmentProportion(
    String raw, String configName, String warnMessage) {
  if (raw == null) {
    return null;
  }
  String[] parts = raw.split(":");
  if (parts.length != 2) {                      // ← 覆盖"单段"（原 AIOOBE）
    LOGGER.warn(warnMessage);
    return null;
  }
  int[] values = new int[2];
  for (int i = 0; i < 2; i++) {
    try {
      values[i] = Integer.parseInt(parts[i].trim());
    } catch (NumberFormatException e) {          // ← 覆盖"非数字"（原 NFE）
      LOGGER.warn(warnMessage);
      return null;
    }
    if (values[i] <= 0) {                        // ← 覆盖 0 / 负数（原 return 致 NPE）
      LOGGER.warn(warnMessage);
      return null;
    }
  }
  return values;
}
```

`initStorageEngineAllocate()` 内改为：

```java
    // 默认值先算好（原 L403-406，保持不变）
    long writeMemorySize             = storageMemoryTotal * 8 / 10;
    long compactionMemorySize        = storageMemoryTotal * 2 / 10;
    long memtableMemorySize          = writeMemorySize * 19 / 20;
    long timePartitionInfoMemorySize = writeMemorySize / 20;

    int[] storageProp =
        parseTwoSegmentProportion(
            properties.getProperty("storage_engine_memory_proportion"),
            "storage_engine_memory_proportion",
            DataNodeMiscMessages
                .MISC_LOG_THE_VALUE_OF_STORAGE_ENGINE_MEMORY_PROPORTION_IS_ILLEGAL_22CA9433);

    int[] writeProp =
        parseTwoSegmentProportion(
            properties.getProperty("write_memory_proportion"),
            "write_memory_proportion",
            DataNodeMiscMessages
                .MISC_LOG_THE_VALUE_OF_WRITE_MEMORY_PROPORTION_IS_ILLEGAL_USE_DEFAULT_EE4FA112);

    if (storageProp != null) {
      int sum = storageProp[0] + storageProp[1];
      writeMemorySize      = storageMemoryTotal * storageProp[0] / sum;
      compactionMemorySize = storageMemoryTotal * storageProp[1] / sum;
    }
    if (writeProp != null) {
      int sum = writeProp[0] + writeProp[1];
      memtableMemorySize          = writeMemorySize * writeProp[0] / sum;
      timePartitionInfoMemorySize = writeMemorySize * writeProp[1] / sum;
    }

    // ↓↓↓ 以下 7 个 manager 必须**无条件**创建（原 L454-471，不要放在任何 if 里）
    writeMemoryManager = ...;
```

**为什么不建议简单地把 `return` 改成 `break`**：

如果只把 L416 的 `return` 换成 `break`，循环会在第一个非法值处跳出，
此时 `storageEngineMemoryProportion` 是**部分和**（对 `0:10` 来说就是 **0**），
随后 L420–L427 会用它做**除数** → `ArithmeticException: / by zero`，仍然崩溃，只是异常换了。
所以 `break` 必须配合"跳过后续计算块"的守卫，或按上面的写法把校验与计算分离。

> 无论选哪个方案，**都必须保证 `initStorageEngineAllocate()` 正常返回时 7 个 manager 非 null**。

### 5.2 同一方法内的其他崩溃路径（已实测确认）

同一段解析代码对"格式不对"的值**没有任何防御**，以下三种写法都会让 main 线程崩溃、
进程起不来，且 `logs/` 里同样看不到异常（与 §四 同一现象）：

| # | 配置示例 | 触发行 | 实测异常（RC9，2026-10-22） |
|---|---|---|---|
| 1 | `storage_engine_memory_proportion=10`（只有 1 段、无冒号） | **L426** `storageProportionArray[1]` | `java.lang.ArrayIndexOutOfBoundsException: Index 1 out of bounds for length 1` |
| 2 | `storage_engine_memory_proportion=a:b`（非数字） | **L411** `Integer.parseInt` | `java.lang.NumberFormatException: For input string: "a"` |
| 3 | `write_memory_proportion=19`（只有 1 段） | **L450** `writeProportionArray[1]` | `java.lang.ArrayIndexOutOfBoundsException: Index 1 out of bounds for length 1` |

三个用例实测结果一致：`jps` 查不到 DataNode 进程，异常只在启动脚本 stdout。

> **注意**：这三种都不是 `return` 引起的 NPE，而是**解析阶段直接抛出未捕获的运行时异常**。
> 即便按 §5.1 修掉两个 `return`，这三条路径仍然会让节点起不来。
> 因此 §5.1 必须与 §5.2 一起改，否则"配置写错就起不来"的问题只解决了一半。

建议：解析前先校验**段数**（`storage` 必须 2 段、`write` 必须 2 段）与**数字格式**，
非法时统一回退默认值并打 WARN（与 §5.1 的回退方式一致）。

### 5.3 备选方案：非法配置直接 fail-fast

如果产品策略是"配置错了就不该启动"，那么应当：

- 明确抛出带配置项名、原始值、期望格式的 `IllegalArgumentException`；
- **同时把 7 个 manager 的创建移到校验之前**（或改为各处懒加载），保证即使抛异常也不会出现
  `null` manager 引发二次 NPE，让错误信息保持"配置非法"这一个原因，而不是被 NPE 掩盖。

> 无论选哪个方案，**都必须保证 `initStorageEngineAllocate()` 正常返回时 7 个 manager 非 null**。

### 5.4 与同文件其他配置的处理方式不一致

同文件的 `resolveQueryMemoryProportions()`（L483 起）对非法 query 比例采用的是
**抛 `IllegalArgumentException` + 明确文案**（L490、L499、L523、L573），
而不是静默回退。建议 `storage`/`write` 两类比例与之统一，避免两套语义。

---

## 六、影响评估

| 维度 | 评估 |
|---|---|
| **触发概率** | 中偏高。默认配置正常；但只要用户手工改这两项且写错（`0`、负数、单段、非数字，**四类写法均已实测必现**），节点即起不来 |
| **影响范围** | 单节点起不来 → 该节点副本缺失；若批量下发同一份错误配置，**整个集群不可用** |
| **数据风险** | 无数据损坏。数据在其它副本上，配置改回正确值后节点可正常启动并追上（本次已验证恢复 8/8） |
| **可恢复性** | 高。修正配置值即可恢复，无需重装或清数据 |
| **排查难度** | **高**。WARN 谎称"已回退"，真实异常不落 `logs/`，容易被误判为环境问题或启动慢 |
| **受影响版本** | v2.0.10.1 起（含 v2.0.10.x / v2.0.11.x / v2.0.12.1 的 rc8、rc9） |

---

## 七、验证方法（修复后如何确认）

修复后，以下三条应同时满足：

```bash
# 1) 注入非法值，节点仍能正常启动
sudo sed -i 's|^storage_engine_memory_proportion=.*|storage_engine_memory_proportion=0:10|' $CONF
sudo /data/iotdb/$V/sbin/start-datanode.sh
sudo jps -l | grep -c DataNode          # 期望 1（进程在）

# 2) 日志确实打了 WARN，且内存分配等于"默认 8:2"那套值
sudo grep 'storage_engine_memory_proportion is illegal' logs/log_datanode_all.log
sudo grep 'initial allocateMemoryForWrite' logs/log_datanode_all.log
#    期望 = maxMemory * 8/10（而非 0，也不是崩溃）

# 3) 7 个 manager 均非 null —— 用现成用例直接回归
bash tools/run_until_done.sh --only MB-19 --ver v20121rc9_1020_d206dc2
```

**回归用例**：`MB-19`（`cases/common/mb_19_illegal_proportion.sh`）。
该用例当前设计为**在缺陷存在时 FAIL、修复后 PASS**，可直接作为本缺陷的验收用例。

修复验收时应覆盖**全部 5 种非法写法**（本次均已实测会崩溃）：

| # | 配置 | 本次实测结果 | 修复后期望 |
|---|---|---|---|
| 1 | `storage_engine_memory_proportion=0:10` | NPE（`return` 致 7 个 manager 为 null） | 启动成功，分配按 8:2 |
| 2 | `write_memory_proportion=0:1` | 同上 NPE | 启动成功，分配按 19:1 |
| 3 | `storage_engine_memory_proportion=10` | `ArrayIndexOutOfBoundsException`（L426） | 启动成功，分配按 8:2 |
| 4 | `storage_engine_memory_proportion=a:b` | `NumberFormatException`（L411） | 启动成功，分配按 8:2 |
| 5 | `write_memory_proportion=19` | `ArrayIndexOutOfBoundsException`（L450） | 启动成功，分配按 19:1 |

建议把这 5 种变体以参数化方式补进 `MB-19`（当前 MB-19 只覆盖 #1）。

---

## 八、附件

| 内容 | 位置 |
|---|---|
| 缺陷源码（RC9） | `git show d206dc2:iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/DataNodeMemoryConfig.java` |
| 复现脚本 | `membuf_skill/cases/common/mb_19_illegal_proportion.sh` |
| RC9 用例结论 | `membuf_skill/results_rc9_20261022/result_MB-19_20261022_031444.txt` |
| 原始异常栈 | 本次已附于 §2.3（节点 `/tmp/f07.start`、`/tmp/wp.start`） |
| 关联发现 | `docs/FINDINGS.md` F-07；`docs/REPORT_RC9.md` §三 |
