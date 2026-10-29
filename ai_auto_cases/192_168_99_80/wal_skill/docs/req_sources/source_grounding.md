# WAL 源码事实印证（IoTDB / TimechoDB 2.0.12.1 RC7）

- 源码根：`D:\IDEA\timechodb_src\v20121\timechodb`（下文所有路径均为**相对源码根**的相对路径）
- 取证方式：只读本地源码（`read`/`grep`），未连接任何集群、未执行任何集群命令、未修改源码树。
- 版本线索：`pom.xml` 中项目版本 2.0.12.1；本次未从源码中另行确认 "RC7" 字面量（见 §14）。
- **模板路径修正**：任务书给的 `iotdb-core/datanode/src/main/resources/iotdb-system.properties.template` **不存在**；
  真实模板在 `iotdb-core/node-commons/src/assembly/resources/conf/iotdb-system.properties.template`。
- `iotdb-core/datanode/.../resources/` 下只有测试用 properties（`src/test/resources/iotdb-system.properties`），不含模板。
- WAL 主实现包：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/storageengine/dataregion/wal/`（共 54 个 java 文件）。
- 日志文案集中在 i18n 常量类：`iotdb-core/datanode/src/main/i18n/en/org/apache/iotdb/db/i18n/StorageEngineMessages.java`（下称 `StorageEngineMessages(en)`），
  调用点则写在业务类里。本文两者都给。

---

## §1 WAL 相关配置项全清单

### 1.1 默认值来源链

- 运行时字段默认值：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/IoTDBConfig.java`
- 启动装载：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/IoTDBDescriptor.java`
  - `loadProps()` → `loadWALProps(properties)`：`IoTDBDescriptor.java:1188`
  - `loadWALProps` 定义：`IoTDBDescriptor.java:1828-1867`
  - 热加载：`loadWALHotModifiedProps` 定义 `IoTDBDescriptor.java:2185-2275`，调用点 `IoTDBDescriptor.java:2712`
- "restart / hot_reload" 的**代码级依据**（不是注释猜测）：`ConfigurationFileUtils` 解析模板里的 `effectiveMode:` 行
  - 常量：`iotdb-core/node-commons/src/main/java/org/apache/iotdb/commons/conf/ConfigurationFileUtils.java:102`
    `private static final String EFFECTIVE_MODE_PREFIX = "effectiveMode:";`
  - 取值解析：`ConfigurationFileUtils.java:665-672`（`HOT_RELOAD` / `FIRST_START` / `FIRST_START_OR_SET_CONFIGURATION` / `RESTART`）
  - `SET CONFIGURATION` 后的提示逻辑：`iotdb-core/confignode/src/main/java/org/apache/iotdb/confignode/manager/ConfigManager.java:1927-1932`
    ```java
    for (String key : req.getConfigs().keySet()) {
      if (ConfigurationFileUtils.EffectiveModeType.RESTART
          == ConfigurationFileUtils.getConfigurationEffectiveMode(key)) {
        restartRequiredKeys.add(key);
      }
    }
    ```
  - `FIRST_START` 的键会被**直接丢弃**（`SET CONFIGURATION` 无效）：`ConfigurationFileUtils.java:384-390`
    ```java
    if (defaultConfigurationItem == null
        || defaultConfigurationItem.effectiveMode == EffectiveModeType.FIRST_START) {
      ignoredConfigItems.add(key);
    }
    ```

### 1.2 清单（共 19 项：17 个 WAL 主键 + 2 个相关键）

| # | 配置键 | 默认值 | 类型 | 生效方式（模板 `effectiveMode:`） | 定义处 | 读取处 |
|---|---|---|---|---|---|---|
| 1 | `wal_mode` | `ASYNC` | enum `WALMode{DISABLE,SYNC,ASYNC}` | **restart** | 模板 `iotdb-system.properties.template:1930`；字段 `IoTDBConfig.java:197` | `IoTDBDescriptor.java:1829-1830` |
| 2 | `max_wal_nodes_num` | `0` | int | **restart** | 模板 `:1939`；字段 `IoTDBConfig.java:200` | `IoTDBDescriptor.java:1832-1838` |
| 3 | `wal_async_mode_fsync_delay_in_ms` | `1000` | long | **hot_reload** | 模板 `:1946`；字段 `IoTDBConfig.java:206` | `IoTDBDescriptor.java:2186-2194`（热加载） |
| 4 | `wal_sync_mode_fsync_delay_in_ms` | `3` | long | **hot_reload** | 模板 `:1953`；字段 `IoTDBConfig.java:212` | `IoTDBDescriptor.java:2196-2204`（热加载） |
| 5 | `wal_buffer_size_in_byte` | `33554432`（32MB） | int | **restart** | 模板 `:1959`；字段 `IoTDBConfig.java:215` | `IoTDBDescriptor.java:1840-1846` |
| 6 | `wal_entry_size_limit_in_byte` | `-1`（≤0 时取 `wal_buffer_size_in_byte`） | int | **restart** | 模板 `:1965`；字段 `IoTDBConfig.java:218` | `IoTDBDescriptor.java:1848-1849` |
| 7 | `wal_file_list_cache_enabled` | `true` | boolean | **restart** | 模板 `:1974`；字段 `IoTDBConfig.java:256` | `IoTDBDescriptor.java:1860-1864` |
| 8 | `wal_cache_shrink_clear_enabled` | `true` | boolean | **restart（且模板里没有，SET CONFIGURATION 会被丢弃）** | 字段 `IoTDBConfig.java:263` | `IoTDBDescriptor.java:1851-1858` |
| 9 | `wal_file_size_threshold_in_byte` | `31457280`（30MB） | long | **hot_reload** | 模板 `:1981`；字段 `IoTDBConfig.java:224` | `IoTDBDescriptor.java:2206-2214`（热加载） |
| 10 | `wal_min_effective_info_ratio` | `0.1` | double | **hot_reload** | 模板 `:1989`；字段 `IoTDBConfig.java:230` | `IoTDBDescriptor.java:2216-2224`（热加载） |
| 11 | `wal_memtable_snapshot_threshold_in_byte` | `8388608`（8MB） | long | **hot_reload** | 模板 `:1996`；字段 `IoTDBConfig.java:247` | `IoTDBDescriptor.java:2226-2234`（热加载） |
| 12 | `max_wal_memtable_snapshot_num` | `1` | int | **hot_reload** | 模板 `:2002`；字段 `IoTDBConfig.java:250` | `IoTDBDescriptor.java:2236-2244`（热加载） |
| 13 | `delete_wal_files_period_in_ms` | `20000` | long | **hot_reload** | 模板 `:2009`；字段 `IoTDBConfig.java:253` | `IoTDBDescriptor.java:2246-2254`（热加载） |
| 14 | `wal_throttle_threshold_in_byte` | `214748364800`（200GB） | long | **hot_reload** | 模板 `:2016`；字段 `IoTDBConfig.java:1084` | `IoTDBDescriptor.java:2256-2264` + `2277-2290`（热加载） |
| 15 | `iot_consensus_throttle_threshold_in_byte` | 无（**已废弃别名**） | long | hot（与 14 同一路径） | `IoTDBDescriptor.java:143-145` | `IoTDBDescriptor.java:2278-2286`（读到即打 WARN 并优先采用） |
| 16 | `iot_consensus_cache_window_time_in_ms` | `-1`（模板）；字段默认 `10000` | long | **hot_reload** | 模板 `:2022`；字段 `IoTDBConfig.java:1087` | `IoTDBDescriptor.java:2266-2274` |
| 17 | `enable_wal_compression` | `true` | boolean | **hot_reload** | 模板 `:2030`；字段 `IoTDBConfig.java:1358` | 启动 `IoTDBDescriptor.java:497-500`；热加载 `IoTDBDescriptor.java:2779-2785` |
| 18 | `dn_wal_dirs` | `data/datanode/wal` | String[]（逗号分隔） | **restart** | 模板 `:293`（注释 `:281-292`）；字段 `CommonConfig.java:745` | `CommonDescriptor.java:124-128` |
| 19 | `wal_buffer_queue_proportion` | `0.1` | double | **restart** | 模板 `:1084`；字段 `DataNodeMemoryConfig.java:55` | `DataNodeMemoryConfig.java:375-378` |

关键原文（模板 WAL 段 `iotdb-system.properties.template:1919-2030`）：

```
1930: wal_mode=ASYNC
1939: max_wal_nodes_num=0
1946: wal_async_mode_fsync_delay_in_ms=1000
1953: wal_sync_mode_fsync_delay_in_ms=3
1959: wal_buffer_size_in_byte=33554432
1965: wal_entry_size_limit_in_byte=-1
1974: wal_file_list_cache_enabled=true
1981: wal_file_size_threshold_in_byte=31457280
1989: wal_min_effective_info_ratio=0.1
1996: wal_memtable_snapshot_threshold_in_byte=8388608
2002: max_wal_memtable_snapshot_num=1
2009: delete_wal_files_period_in_ms=20000
2016: wal_throttle_threshold_in_byte=214748364800
2030: enable_wal_compression=true
```

`wal_mode` 枚举（`.../wal/utils/WALMode.java:23` 起）——**只有 3 个取值**：
```java
public enum WALMode {
```
（`WALMode{DISABLE, SYNC, ASYNC}`；解析用 `WALMode.valueOf(...)`，见 `IoTDBDescriptor.java:1829-1830`，
故非法值直接抛 `IllegalArgumentException`。）

### 1.3 取值校验逻辑（不是"无脑赋值"）

- `wal_mode`：`IoTDBDescriptor.java:1829-1830`
  ```java
  conf.setWalMode(
      WALMode.valueOf((properties.getProperty("wal_mode", conf.getWalMode().toString()))));
  ```
  非枚举值 → `IllegalArgumentException`（启动失败）。
- `max_wal_nodes_num`：`IoTDBDescriptor.java:1836-1838` `if (maxWalNodesNum > 0) { conf.setMaxWalNodesNum(maxWalNodesNum); }`
  → **≤0（含负数）一律回落成默认 0**（0 的语义见 §3）。
- `wal_buffer_size_in_byte`：`IoTDBDescriptor.java:1844-1846` `if (walBufferSize > 0)`。
- `wal_file_size_threshold_in_byte`：`:2212-2214` `if (walFileSizeThreshold > 0)`。
- `wal_min_effective_info_ratio`：`:2222-2224` `if (walMinEffectiveInfoRatio > 0)` → **设 0 或负数不生效，仍为 0.1**。
- `wal_memtable_snapshot_threshold_in_byte`：`:2232-2234` `if (... > 0)`。
- `max_wal_memtable_snapshot_num`：`:2242-2244` `if (... > 0)`。
- `delete_wal_files_period_in_ms`：`:2252-2254` `if (deleteWalFilesPeriod > 0)`。
- `wal_async_mode_fsync_delay_in_ms` / `wal_sync_mode_fsync_delay_in_ms`：`:2192-2194` / `:2202-2204`，均要求 `> 0`。
- `wal_throttle_threshold_in_byte`：`:2257-2264`，`<0` 时取模板默认值，`>0` 才 `setThrottleThreshold`。
- `wal_entry_size_limit_in_byte`：**无校验**，直接 `set`（`:1848-1849`），但仍非正数时由 getter 兜底：
  `IoTDBConfig.java:2244-2246` `return walEntrySizeLimitInByte > 0 ? walEntrySizeLimitInByte : walBufferSize;`
- `wal_buffer_queue_proportion`：与另外两个比例求和的整体校验，`DataNodeMemoryConfig.java:384-392`
  ```java
  if (rejectProportion + walBufferQueueProportion + devicePathCacheProportion >= 1) {
    LOGGER.warn(...MISC_LOG_THE_SUM_OF_REJECT_PROPORTION_WAL_BUFFER_QUEUE_PROPORTION_185B1C49);
  } else {
    setRejectProportion(rejectProportion); setWalBufferQueueProportion(walBufferQueueProportion); ...
  ```
- `iot_consensus_throttle_threshold_in_byte` 废弃告警：`IoTDBDescriptor.java:2280-2285`
  （文案常量 `DataNodeMiscMessages.MISC_LOG_THE_THROTTLE_THRESHOLD_PARAMS_IS_DEPRECATED_PLEASE_USE_AA0E8EC7`）

### 1.4 模板注释原文（"restart required" 之类照抄）

```
1929: # effectiveMode: restart      (wal_mode)
1937: # effectiveMode: restart      (max_wal_nodes_num)
1944: # effectiveMode: hot_reload   (wal_async_mode_fsync_delay_in_ms)
1951: # effectiveMode: hot_reload   (wal_sync_mode_fsync_delay_in_ms)
1957: # effectiveMode: restart      (wal_buffer_size_in_byte)
1963: # effectiveMode: restart      (wal_entry_size_limit_in_byte)
1972: # effectiveMode: restart      (wal_file_list_cache_enabled)
1979: # effectiveMode: hot_reload   (wal_file_size_threshold_in_byte)
1987: # effectiveMode: hot_reload   (wal_min_effective_info_ratio)
1994: # effectiveMode: hot_reload   (wal_memtable_snapshot_threshold_in_byte)
2000: # effectiveMode: hot_reload   (max_wal_memtable_snapshot_num)
2007: # effectiveMode: hot_reload   (delete_wal_files_period_in_ms)
2014: # effectiveMode: hot_reload   (wal_throttle_threshold_in_byte)
2020: # effectiveMode: hot_reload   (iot_consensus_cache_window_time_in_ms)
2028: # effectiveMode: hot_reload   (enable_wal_compression)
```
`dn_wal_dirs`：`iotdb-system.properties.template:287 # effectiveMode: restart`
`wal_buffer_queue_proportion`：`:1082 # effectiveMode: restart`
`max_wal_nodes_num` 的注释原文（`:1933`）：
```
# This parameter is only valid in the standalone mode. IoTConsensus uses one wal per data region and RatisConsensus doesn't use wal.
```

### 1.5 死配置 / 未找到

- `iot_consensus_cache_window_time_in_ms` → 只被 `setCacheWindowTimeInMs` 写入、`getCacheWindowTimeInMs` 读出，
  **全仓无任何消费者**（`grep -rn "getCacheWindowTimeInMs" iotdb-core` 仅 1 处：`IoTDBConfig.java:3885`）→ 配了也没行为差异。
- `wal_cache_shrink_clear_enabled`：**不在模板里**，`SET CONFIGURATION` 会被 `filterInvalidConfigItems` 丢弃；只能改文件+重启。
- `wal_dir`（单数）、`wal_dirs`：**不存在**。搜过的关键词：`"wal_dir"`、`wal_dirs`、`getWalDirs`、`dn_wal_dirs`。
  唯一有效键是 `dn_wal_dirs`（模板 `:286` 注释里也写的是 `wal_dirs`，属注释口误）。
- 加密相关 WAL 配置键：**不存在**。WAL 是否加密完全跟随 TSFile 的 `encrypt_type`（见 §4.4）。
  搜过的关键词：`wal_encrypt`、`wal_encryption`、`enable_wal_encrypt`。

---

## §2 `wal_mode=DISABLE` 在 IoTConsensus / IoTConsensusV2 下被拒绝的代码

**位置不在 `DataNode.java` 的 `pullAndCheckSystemConfigurations` 里直接判，而是在它间接调用的启动检查里。**

- 判定条件：`iotdb-core/datanode/src/main/java/org/apache/iotdb/db/conf/IoTDBStartCheck.java:150-163`
  ```java
  @Override
  protected void validateFirstStart() throws ConfigurationException {
    if ((config.getDataRegionConsensusProtocolClass().equals(ConsensusFactory.IOT_CONSENSUS)
            || (config
                    .getDataRegionConsensusProtocolClass()
                    .equals(ConsensusFactory.IOT_CONSENSUS_V2)
                && config
                    .getIotConsensusV2Mode()
                    .equals(ConsensusFactory.IOT_CONSENSUS_V2_STREAM_MODE)))
        && config.getWalMode().equals(WALMode.DISABLE)) {
      throw new ConfigurationException(
          DataNodeMiscMessages
              .MISC_EXCEPTION_CONFIGURING_THE_WALMODE_AS_DISABLE_IS_NOT_SUPPORTED_UNDER_49298819);
    }
  }
  ```
- 文案常量：`iotdb-core/datanode/src/main/i18n/en/org/apache/iotdb/db/i18n/DataNodeMiscMessages.java:1353-1355`
  ```java
  public static final String MISC_EXCEPTION_CONFIGURING_THE_WALMODE_AS_DISABLE_IS_NOT_SUPPORTED_UNDER_49298819 =
      "Configuring the WALMode as disable is not supported under IoTConsensus and IoTConsensusV2 "
          + "stream mode";
  ```
  （中文版：`.../i18n/zh/.../DataNodeMiscMessages.java:1331-1332`
  `"IoTConsensus 和 IoTConsensusV2 stream mode 下不支持将 WALMode 配置为 disable"`）
- 唯一调用点（全仓只有 1 处引用该常量）：`IoTDBStartCheck.java:161`。
- 调用链：`DataNode.java:282 pullAndCheckSystemConfigurations()` → `DataNode.java:530 IoTDBStartCheck.getInstance().checkSystemConfig()`
  → `AbstractIoTDBStartCheck.java:83-88`
  ```java
  public void checkSystemConfig() throws ConfigurationException, IOException {
    properties = systemPropertiesHandler.read();
    if (systemPropertiesHandler.isFirstStart()) {
      validateFirstStart();
    } else { ... checkImmutableSystemProperties(); }
  ```
- `isFirstStart()` 的语义：`iotdb-core/node-commons/src/main/java/org/apache/iotdb/commons/file/SystemPropertiesHandler.java:140-142`
  ```java
  public boolean isFirstStart() {
    return !fileExist();
  }
  ```
  **⇒ 该 DISABLE 校验只在"该节点还没有 iotdb-system.properties"的首次启动时执行。**
  已初始化节点把 `wal_mode` 改成 `DISABLE` 再重启，会走 `else` 分支，**不会**抛这条异常。
  这是可稳定构造的判定点（新建节点 vs 已运行过的节点，预期不同）。

**"其他协议/单机版是否允许 DISABLE"**：

- **RatisConsensus**：不是"允许"，而是**被强制 DISABLE**，`DataNode.java:971-974`
  ```java
  // Close wal when using ratis consensus
  if (config.getDataRegionConsensusProtocolClass().equals(ConsensusFactory.RATIS_CONSENSUS)) {
    config.setWalMode(WALMode.DISABLE);
  }
  ```
  另有 WAL 目录不检查的对称逻辑：`IoTDBStartCheck.java:219-225`
  ```java
  // check WAL dir
  if (!(config.getDataRegionConsensusProtocolClass().equals(ConsensusFactory.RATIS_CONSENSUS))
      && !config.getWalMode().equals(WALMode.DISABLE)) {
    for (String walDir : commonConfig.getWalDirs()) { ... registerDirectory ... }
  }
  ```
- **IoTConsensus**：`DISABLE` **必定被拒**（上面的条件第一支无条件成立）。
- **IoTConsensusV2**：**取决于 `iot_consensus_v2_mode`**
  - `stream` → 拒绝（`IoTDBStartCheck.java:152-157`）
  - 其它（默认 `batch`）→ **允许**。默认值证据：
    `IoTDBConfig.java:1178 private String iotConsensusV2Mode = ConsensusFactory.IOT_CONSENSUS_V2_BATCH_MODE;`
    常量：`iotdb-core/consensus/src/main/java/org/apache/iotdb/consensus/ConsensusFactory.java:47-48`
    ```java
    public static final String IOT_CONSENSUS_V2_BATCH_MODE = "batch";
    public static final String IOT_CONSENSUS_V2_STREAM_MODE = "stream";
    ```
  - 键的装载：`IoTDBDescriptor.java:1538`（`"iot_consensus_v2_mode"`）
- **DISABLE 生效后的行为**：`WALManager.applyForWALNode` 返回假节点，`:99-105`
  ```java
  public IWALNode applyForWALNode(String applicantUniqueId) {
    if (config.getWalMode() == WALMode.DISABLE) {
      return WALFakeNode.getSuccessInstance();
    }
  ```
  写假节点会失败（`CANNOT_WRITE_WAL_INTO_FAKE_NODE = "Cannot write wal into a fake node. "`，`StorageEngineMessages(en):349`），
  删除日志走 `DataRegion.logDeletionInWAL` 的 `Collections.emptyList()` 短路（`DataRegion.java:3478-3480`、`3521-3523`）。

---

## §3 WAL 目录与文件命名规律

### 3.1 根目录

- 键：`dn_wal_dirs`，默认 `data/datanode/wal`（相对 `<IOTDB_HOME>`）
  - 模板：`iotdb-system.properties.template:293 dn_wal_dirs=data/datanode/wal`
  - 解析：`iotdb-core/node-commons/src/main/java/org/apache/iotdb/commons/conf/CommonDescriptor.java:124-128`
    ```java
    config.setWalDirs(
        properties
            .getProperty("dn_wal_dirs", String.join(",", config.getWalDirs()))
            .trim()
            .split(","));
    ```
  - 目录会在启动检查里注册/创建：`IoTDBStartCheck.java:222-224`

### 3.2 WALNode 子目录 = `<walDir>/<identifier>`

- `AbstractNodeAllocationStrategy.java:62-83`（**非 IoTConsensus**：Elastic / RoundRobin 策略）
  ```java
  return folderManager.getNextWithRetry(
      folder -> new WALNode(identifier, folder + File.separator + identifier));
  ```
- identifier 的取值：
  - **IoTConsensus / IoTConsensusV2**（`FirstCreateStrategy`）：identifier = 数据区域名 `database-<regionId>`
    - 申请：`DataRegion.java:806-812`
      ```java
      if (config.getDataRegionConsensusProtocolClass().equals(ConsensusFactory.IOT_CONSENSUS_V2)) {
        IWALNode walNode =
            WALManager.getInstance()
                .applyForWALNode(databaseName + FILE_NAME_SEPARATOR + dataRegionIdString);
      ```
      （另一处 `DataRegion.java:6134` 同样写法；`FILE_NAME_SEPARATOR = "-"`，`IoTDBConstant.java:297`）
    - 恢复注册用目录名回填：`WALNodeRecoverTask.java:122-127`
      ```java
      WALManager.getInstance()
          .registerWALNode(
              logDirectory.getName(), logDirectory.getAbsolutePath(), lastVersionId + 1, lastSearchIndex);
      ```
    - 策略选择：`WALManager.java:76-85`
      ```java
      if (config.getDataRegionConsensusProtocolClass().equals(ConsensusFactory.IOT_CONSENSUS)
          || config.getDataRegionConsensusProtocolClass().equals(ConsensusFactory.IOT_CONSENSUS_V2)) {
        walNodesManager = new FirstCreateStrategy();
      } else if (config.getMaxWalNodesNum() == 0) {
        walNodesManager = new ElasticStrategy();
      } else {
        walNodesManager = new RoundRobinStrategy(config.getMaxWalNodesNum());
      }
      ```
      **⇒ `max_wal_nodes_num=0` 时用 `ElasticStrategy`（不是固定 0 个、也不是 1 个）**，identifier 是自增整数字符串：
      - `ElasticStrategy.java:62-76`
        ```java
        if (uniqueId2Nodes.size() == walNodes.size() * APPLICATION_NODE_RATIO) {
          nodeIdCounter++;
          IWALNode node = createWALNode(String.valueOf(nodeIdCounter));
        ```
        `ElasticStrategy.java:41 public static final int APPLICATION_NODE_RATIO = 4;`
        → 每 4 个"申请者"（region×sequence/unsequence）开 1 个 WALNode，目录名是 `0`、`1`、`2`…
      - `max_wal_nodes_num>0` 时用 `RoundRobinStrategy`，目录名同样是 `0..N-1`：`RoundRobinStrategy.java:61-68`
        `IWALNode node = createWALNode(String.valueOf(nodeIdCounter));`
  - 申请者唯一 ID 规则（非 IoTConsensus 时为 `region-sequence` / `region-unsequence`）：`WALManager.java:87-96`
    ```java
    return config.getDataRegionConsensusProtocolClass().equals(ConsensusFactory.IOT_CONSENSUS)
            || ... IOT_CONSENSUS_V2 ... ? dataRegionName
        : dataRegionName + IoTDBConstant.FILE_NAME_SEPARATOR + (sequence ? "sequence" : "unsequence");
    ```

### 3.3 目录创建日志

- WALNode 目录：`WALNode.java:143-146`
  ```java
  this.logDirectory = SystemFileFactory.INSTANCE.getFile(logDirectory);
  if (!this.logDirectory.exists() && this.logDirectory.mkdirs()) {
    logger.info(StorageEngineMessages.CREATE_FOLDER_FOR_WAL_NODE, logDirectory, identifier);
  }
  ```
  文案 `StorageEngineMessages(en):350 "create folder {} for wal node-{}."`
- buffer 目录（同一目录）：`AbstractWALBuffer.java:71-75` → 文案 `:370 "Create folder {} for wal node-{}'s buffer."`
- checkpoint 目录：`CheckpointManager.java:86` → 文案 `:335 "create folder {} for wal buffer-{}."`

### 3.4 文件名规律 `_<versionId>-<startSearchIndex>-<statusCode>.wal`

- 前后缀常量：`iotdb-core/node-commons/src/main/java/org/apache/iotdb/commons/conf/IoTDBConstant.java:358-363`
  ```java
  public static final String WAL_FILE_PREFIX = "_";
  public static final String WAL_FILE_SUFFIX = ".wal";
  ...
  public static final String WAL_VERSION_ID = "versionId";
  public static final String WAL_START_SEARCH_INDEX = "startSearchIndex";
  public static final String WAL_STATUS_CODE = "statusCode";
  ```
- 正则：`WALFileUtils.java:65-74`
  ```java
  public static final Pattern WAL_FILE_NAME_PATTERN =
      Pattern.compile(
          String.format(
              "%s(?<%s>\\d+)-(?<%s>\\d+)-(?<%s>\\d+)\\%s(%s)?$",
              WAL_FILE_PREFIX, WAL_VERSION_ID, WAL_START_SEARCH_INDEX, WAL_STATUS_CODE,
              WAL_FILE_SUFFIX, SecretKey.FILE_ENCRYPTED_SUFFIX));
  ```
- 组装格式：`WALFileUtils.java:76-83`
  ```java
  public static final String WAL_FILE_NAME_FORMAT =
      WAL_FILE_PREFIX + "%d" + FILE_NAME_SEPARATOR + "%d" + FILE_NAME_SEPARATOR + "%d" + WAL_FILE_SUFFIX;
  ```
  → 形如 `_0-0-1.wal`；加密时追加 `SecretKey.FILE_ENCRYPTED_SUFFIX`（`WALFileUtils.java:194-202`）。
- statusCode 取值：`WALFileStatus.java:26-31`
  ```java
  CONTAINS_NONE_SEARCH_INDEX(0),
  CONTAINS_SEARCH_INDEX(1),
  ```
  → 文件名第 3 段只有 `0` / `1`。
- 首文件生成：`AbstractWALBuffer.java:81-89`
  ```java
  currentWALFileWriter = new WALWriter(
      SystemFileFactory.INSTANCE.getFile(logDirectory,
          WALFileUtils.getLogFileName(startFileVersion, currentSearchIndex, WALFileStatus.CONTAINS_SEARCH_INDEX)));
  ```
- 文件名里的语义举例（源码注释原文）：`WALFileUtils.java:56-63`
  ```
  _0-0-1.wal: 1, 2, 3, -1, -1, 4, 5, -1
  _1-5-0.wal: -1, -1, -1, -1
  _2-5-1.wal: 6, 7, 8, 9, -1, -1, -1, 10, 11, -1, 12, 12
  _3-12-1.wal: 12, 12, 12, 12, 12
  _4-12-1.wal: 12, 13, 14, 15, 16, -1
  ```

---

## §4 WAL 压缩实现

### 4.1 配置读取处

- 启动：`IoTDBDescriptor.java:497-500`
  ```java
  boolean enableWALCompression =
      Boolean.parseBoolean(properties.getProperty("enable_wal_compression", "true"));
  conf.setWALCompressionAlgorithm(
      enableWALCompression ? CompressionType.LZ4 : CompressionType.UNCOMPRESSED);
  ```
- 热加载：`IoTDBDescriptor.java:2779-2785`（同样映射，默认值取自模板）
- 字段默认：`IoTDBConfig.java:1358 private CompressionType WALCompressionAlgorithm = CompressionType.LZ4;`

### 4.2 压缩算法 = **LZ4**（TSFile 的 `ICompressor`/`CompressionType`），不是 Snappy

- 取算法：`iotdb-core/datanode/.../wal/io/LogWriter.java:110-113`
  ```java
  CompressionType compressionType =
      allowCompress
          ? IoTDBDescriptor.getInstance().getConfig().getWALCompressionAlgorithm()
          : CompressionType.UNCOMPRESSED;
  ```
  （注释原文 `:107-109`：`// To support hot loading, we can't define it as a variable, because we need to dynamically check whether wal compression is enabled each time the buffer is serialized`）
- 压缩单元 = **一次 sync 批次的 buffer（segment）**，按 buffer 切分、**不跨文件**：
  `LogWriter.java:120-135`
  ```java
  if (compressionType != CompressionType.UNCOMPRESSED
      /* Do not compress buffer that is less than min size */
      && bufferSize > MIN_COMPRESSION_SIZE
      && compressedByteBuffer != null) {
    compressedByteBuffer.clear();
    if (compressor.getType() != compressionType) {
      compressor = ICompressor.getCompressor(compressionType);
    }
    compressor.compress(buffer, compressedByteBuffer);
    buffer = compressedByteBuffer;
  ```
  `LogWriter.java:73-74  private static long MIN_COMPRESSION_SIZE = 32 * 1024L;`（<32KB **不压**）
- 段头（每段的压缩标志）：`LogWriter.java:59-65`
  ```java
  /** 1 byte for whether enable compression, 4 byte for compressedSize, 4 byte for uncompressedSize */
  private final int COMPRESSED_HEADER_SIZE = Byte.BYTES + Integer.BYTES * 2;
  /** 1 byte for whether enable compression, 4 byte for uncompressedSize */
  private final int UN_COMPRESSED_HEADER_SIZE = Byte.BYTES + Integer.BYTES;
  ```
  写入：`LogWriter.java:136-152`
  ```java
  headerBuffer.put(compressed ? compressionType.serialize() : CompressionType.UNCOMPRESSED.serialize());
  headerBuffer.putInt(bufferSize);
  if (compressed) { headerBuffer.putInt(uncompressedSize); ... }
  ```
  → **压缩标志是"每段 1 字节"**，不是文件级 magic。

### 4.3 解压路径

- 头解析：`WALInputStream.java:487-504`（`getNextSegmentInfo`，读 `CompressionType.deserialize(...)`）
- 解压：`WALInputStream.java:287-335`（compressed 分支）与 `:520-526`
  ```java
  IUnCompressor unCompressor = IUnCompressor.getUnCompressor(segmentInfo.compressionType);
  ...
  private void uncompressWALBuffer(ByteBuffer compressed, ByteBuffer uncompressed, IUnCompressor unCompressor)
      throws IOException {
    long startTime = System.nanoTime();
    unCompressor.uncompress(compressed, uncompressed);
    WritingMetrics.getInstance().recordWALUncompressCost(System.nanoTime() - startTime);
  ```

### 4.4 "未压缩老文件仍需可读"的兼容逻辑（两种，都不是 WAL 压缩专属标志位）

1. **文件版本 magic（V1/V2/V3）**：`iotdb-core/datanode/.../wal/io/WALFileVersion.java:29-32`
   ```java
   public enum WALFileVersion {
     V1("WAL"),
     V2("V2-WAL"),
     V3("V3-WAL");
   ```
   - 写：头 magic 只在 V2/V3 写，`LogWriter.java:84-91`；尾 magic + 元数据长度：`WALWriter.java:104-111`
   - 读：`WALFileVersion.getVersion(channel)` 先试 V3 再试 V2，都失败按 V1：`WALFileVersion.java:58-81`
   - 运行时回退日志：`WALInputStream.java:392-404`（V1 失败再走 V2，成功打 INFO）
   - 尾 magic 校验失败按"破损文件"处理（`endOffset = channel.size()`）：`WALInputStream.java:116-145`
2. **每段压缩标志**：无压缩段按 `dataInDiskSize` 直读（`WALInputStream.java:336-348`），
   所以**同一个文件里混有压缩段与非压缩段也能读**；恢复时对未压缩的"半截段"做截断兼容：
   `WALInputStream.java:265-270`
   ```java
   if (recoveringEntries && segmentInfo.compressionType == CompressionType.UNCOMPRESSED) {
     // Complete entries in a partially written uncompressed segment remain readable. A compressed
     // segment needs its full payload before any of its entries can be recovered.
     segmentInfo.dataInDiskSize = (int) Math.min(segmentInfo.dataInDiskSize, remainingBytes);
     segmentInfo.uncompressedSize = segmentInfo.dataInDiskSize;
   }
   ```
3. **WAL 加密不是独立开关**：`WALFileUtils.java:326-335`
   ```java
   public static boolean isEnableEncrypt() {
     return !TSFileDescriptor.getInstance().getConfig().getEncryptType()
             .equals(EncryptionType.UNENCRYPTED.getExtension())
         && !TSFileDescriptor.getInstance().getConfig().getEncryptType()
             .equals(IoTDBConstant.UNENCRYPTED_ENCRYPT_TYPE);
   }
   ```
   写加密：`LogWriter.java:153-181`；读解密：`WALInputStream.java:309-335 / 350-375`。
   若 WAL 目录里存在加密文件，`WALManager.existsEncryptedFile()`（`WALManager.java:150-165`）会返回 true。

---

## §5 WAL 写盘 / fsync / 轮转

### 5.1 双缓冲与 buffer 切分

- `buffer = wal_buffer_size_in_byte`；实际切成 **3 份**：`WALBuffer.java:82`
  ```java
  public static final int ONE_THIRD_WAL_BUFFER_SIZE = config.getWalBufferSize() / 3;
  ```
  分配 2 份 direct buffer（working/idle）+ 1 份压缩缓冲：`WALBuffer.java:193-196`
  ```java
  workingBuffer = ByteBuffer.allocateDirect(ONE_THIRD_WAL_BUFFER_SIZE);
  idleBuffer = ByteBuffer.allocateDirect(ONE_THIRD_WAL_BUFFER_SIZE);
  compressedByteBuffer = ByteBuffer.allocateDirect(getCompressedByteBufferSize(ONE_THIRD_WAL_BUFFER_SIZE));
  ```
- 一批最多攒到 1/3 缓冲的 95%：`WALBuffer.java:83 private static final double FSYNC_BUFFER_RATIO = 0.95;`
  `WALBuffer.java:330 while (totalSize < ONE_THIRD_WAL_BUFFER_SIZE * FSYNC_BUFFER_RATIO) {`
- 写满就换缓冲（不落盘，只切缓冲）：`WALBuffer.java:481-490`
  ```java
  private void ensureEnoughSpace(int bytesNum) { if (workingBuffer.remaining() < bytesNum) { rollBuffer(); } }
  private void rollBuffer() { flushedBytesNum += workingBuffer.position(); syncWorkingBuffer(currentSearchIndex, currentFileStatus); }
  ```
- 单条 entry 超限直接失败（**不写 WAL，写请求报错**）：`WALBuffer.java:258-274`
  ```java
  if (!walEntry.isSignal() && walEntry.getType() != WALEntryType.MEMORY_TABLE_CHECKPOINT) {
    final int serializedSize = walEntry.serializedSize();
    final int entrySizeLimit = config.getWalEntrySizeLimitInByte();
    if (serializedSize > entrySizeLimit) {
      walEntry.getWalFlushListener().fail(new IoTDBRuntimeException(
          String.format(StorageEngineMessages
              .EXCEPTION_THE_WAL_ENTRY_SIZE_ARG_EXCEEDS_WAL_ENTRY_SIZE_LIMIT_IN_BYTE_ARG_691BB408,
              serializedSize, entrySizeLimit), WAL_ENTRY_TOO_LARGE.getStatusCode()));
  ```
  文案 `StorageEngineMessages(en):391 "The WAL entry size %d exceeds wal_entry_size_limit_in_byte %d."`

### 5.2 fsync 调用点

| 位置 | 代码 |
|---|---|
| `LogWriter.java:201-203` | `public void force() throws IOException { force(true); }` |
| `LogWriter.java:205-209` | `public void force(boolean metaData) throws IOException { logChannel.force(metaData); }`（注释：`A closed channel is a failed durability operation, not a successful no-op.`） |
| `LogWriter.java:226-236` | `close()` 内 `logChannel.force(true)` 后 `logChannel.close()` |
| `WALBuffer.java:724` | `currentWALFileWriter.force();`（**只有 `forceFlag=true` 的那批同步任务才 fsync**） |
| `WALBuffer.java:675` | `compressionRatio = currentWALFileWriter.write(syncingBuffer, info.metaData);`（写 OS page cache） |
| `CheckpointManager.java:133 / 213` | `fsyncCheckpointFile()` |

调度：`WALBuffer.java:558-567`
```java
private void syncWorkingBuffer(long searchIndex, WALFileStatus fileStatus) {
  syncBufferThread.submit(new SyncBufferTask(searchIndex, fileStatus, false));
}
private void fsyncWorkingBuffer(long searchIndex, WALFileStatus fileStatus, SerializeInfo info) {
  syncBufferThread.submit(new SyncBufferTask(searchIndex, fileStatus, true, info));
}
```
`SyncBufferTask` 里的 fsync/轮转二选一：`WALBuffer.java:697-738`（见 5.3）。

### 5.3 按 `wal_file_size_threshold_in_byte` 轮转

`WALBuffer.java:697-725`
```java
boolean forceSuccess = false;
// try to roll log writer
if ((info.rollWALFileWriterListener != null && (!resumedRoll || hasData))
    // TODO: Control the wal file by the number of WALEntry
    || (forceFlag
        && currentWALFileWriter.originalSize() >= config.getWalFileSizeThresholdInByte())) {
  try {
    rollLogWriter(searchIndex, currentWALFileWriter.getWalFileStatus());
    forceSuccess = true;
  } catch (IOException e) { ... }
} else if (forceFlag) { // force os cache to the storage device, avoid force twice by judging
  // after rolling file
  try { currentWALFileWriter.force(); forceSuccess = true; } ...
```
注意：判据用的是 **`originalSize()`（未压缩累计写入字节）**，不是磁盘文件长度（`LogWriter.java:216-218`）。
另一个使用点（估算平均文件大小）：`WALNode.java:442-445`
```java
long avgFileSize = getFileNum() != 0 ? getDiskUsage() / getFileNum() : config.getWalFileSizeThresholdInByte();
```
轮转实现：`AbstractWALBuffer.java:108-152`（close 老文件 → 视 status 改名 → 建 `versionId+1` 的新文件，
若新文件已存在且长度>0 抛 `FileAlreadyExistsException`，`:143-145`）。
有未消费 entry 时也会强制轮转：`WALNode.java:398-406`
```java
public void rollWalFileIfHaveNoActiveMemTable() {
  long firstVersionId = checkpointManager.getFirstValidWALVersionId();
  if (firstVersionId == Long.MIN_VALUE) {
    // roll wal log writer to delete current wal file
    if (buffer.getCurrentWALOriginalFileSize() > 0) { rollWALFile(); }
```

### 5.4 SYNC / ASYNC 的差异

1. **攒批等待时长不同**：`WALBuffer.java:330-340`
   ```java
   if (config.getWalMode().equals(WALMode.ASYNC)) {
     walEntry = walEntries.poll(config.getWalAsyncModeFsyncDelayInMs(), TimeUnit.MILLISECONDS);
   } else {
     walEntry = walEntries.poll(config.getWalSyncModeFsyncDelayInMs(), TimeUnit.MILLISECONDS);
   }
   ```
2. **写请求是否阻塞等 fsync**：`WALInfoEntry.java:59-60`
   ```java
   public WALInfoEntry(long memTableId, WALEntryValue value) {
     this(memTableId, value, config.getWalMode() == WALMode.SYNC);
   ```
   `AbstractResultListener.java:69-83`
   ```java
   public synchronized Status waitForResult() {
     if (wait) { while (status == Status.RUNNING) { ... this.wait(); ... } }
     return status;
   }
   ```
   调用点（无条件调用 `waitForResult()`，但 ASYNC 时 `wait=false` 立即返回）：`TsFileProcessor.java:355-360`
   ```java
   walFlushListener = walNode.log(workMemTable.getMemTableId(), insertRowNode);
   if (walFlushListener.waitForResult() == AbstractResultListener.Status.FAILURE) {
     throw walFlushListener.getCause();
   ```
3. **DISABLE 时的内存占用为 0**：`DataRegion.java:6183-6186`
   ```java
   if (config.getDataRegionConsensusProtocolClass().equals(ConsensusFactory.IOT_CONSENSUS)
       || ... IOT_CONSENSUS_V2) {
     acquireDirectBufferMemCost = config.getWalMode().equals(WALMode.DISABLE) ? 0 : config.getWalBufferSize();
   ```

---

## §6 检查点与删除无效 WAL

### 6.1 删除线程周期 `delete_wal_files_period_in_ms`

- 注册：`WALManager.java:168-179`
  ```java
  public void start() throws StartupException {
    if (config.getWalMode() == WALMode.DISABLE) { return; }
    try {
      registerScheduleTask(config.getDeleteWalFilesPeriodInMs(), config.getDeleteWalFilesPeriodInMs());
  ```
  `WALManager.java:320-325`
  ```java
  walDeleteThread = IoTDBThreadPoolFactory.newSingleThreadScheduledExecutor(ThreadName.WAL_DELETE.getName());
  ScheduledExecutorUtil.safelyScheduleWithFixedDelay(walDeleteThread, this::deleteOutdatedFiles, initDelayMs, periodMs, TimeUnit.MILLISECONDS);
  ```
- 热改后重启线程：`IoTDBDescriptor.java:2711-2715`
  ```java
  long prevDeleteWalFilesPeriodInMs = conf.getDeleteWalFilesPeriodInMs();
  loadWALHotModifiedProps(properties);
  if (prevDeleteWalFilesPeriodInMs != conf.getDeleteWalFilesPeriodInMs()) {
    WALManager.getInstance().rebootWALDeleteThread();
  ```
  `WALManager.java:182-198`（日志见 §10）

### 6.2 "WAL 文件何时可删"判定

`WALNode.java:671-676`
```java
private boolean canDeleteFile(long fileArrIdx, WALFileStatus walFileStatus, long versionId) {
  return (fileArrIdx < fileIndexAfterFilterSafelyDeleteIndex
          || walFileStatus == WALFileStatus.CONTAINS_NONE_SEARCH_INDEX)
      && versionId < subscriptionRetainedMinVersionId
      && !isContainsActiveOrPinnedMemTable(versionId);
}
```
- `fileIndexAfterFilterSafelyDeleteIndex`：`WALNode.java:499-504`
  ```java
  return safelyDeletedSearchIndex == DEFAULT_SAFELY_DELETED_SEARCH_INDEX
      ? sortedWalFilesExcludingLast.length
      : WALFileUtils.binarySearchFileBySearchIndex(sortedWalFilesExcludingLast, safelyDeletedSearchIndex + 1);
  ```
  `safelyDeletedSearchIndex` 由共识侧下发：`WALNode.java:683-685 setSafelyDeletedSearchIndex(...)`；
  IoTConsensus 下被设为 `Long.MAX_VALUE`（`FirstCreateStrategy.java:60-61`、`DataRegion.java:811`），
  所以**只有 `WALFileStatus.CONTAINS_NONE_SEARCH_INDEX`（文件名第 3 段=0）的文件才会被删**——
  文件 status 变 0 的路径：文件被 seal 时 `WALWriter.updateFileStatus`，仅当整文件无 search 才保持 0
  （`WALWriter.java:139-143`：`if (walFileStatus == WALFileStatus.CONTAINS_SEARCH_INDEX) { this.walFileStatus = CONTAINS_SEARCH_INDEX; }`）
- 订阅保护：`versionId < subscriptionRetainedMinVersionId`（`WALNode.java:687-689`）
- `isContainsActiveOrPinnedMemTable`：`WALNode.java:657-669`（读不出 memTable ids 时**保守保留**，`return true`）

### 6.3 `wal_min_effective_info_ratio`：什么条件下记"无效"/触发快照或 flush

- 触发条件：`WALNode.java:506-510`
  ```java
  /** Return true iff effective information ratio is too small or disk usage is too large. */
  private boolean shouldSnapshotOrFlush() {
    return effectiveInfoRatio < config.getWalMinEffectiveInfoRatio()
        || WALManager.getInstance().shouldThrottle();
  }
  ```
- ratio 定义：`WALNode.java:438-455`
  ```java
  long costOfActiveMemTables = checkpointManager.getTotalCostOfActiveMemTables();
  MemTableInfo oldestUnpinnedMemTableInfo = checkpointManager.getOldestMemTableInfo();
  long avgFileSize = getFileNum() != 0 ? getDiskUsage() / getFileNum() : config.getWalFileSizeThresholdInByte();
  long totalCost = oldestUnpinnedMemTableInfo == null
          ? costOfActiveMemTables
          : (getCurrentWALFileVersion() - oldestUnpinnedMemTableInfo.getFirstFileVersionId()) * avgFileSize;
  if (costOfActiveMemTables == 0 || totalCost == 0) { effectiveInfoRatio = 1.0d; return; }
  effectiveInfoRatio = (double) costOfActiveMemTables / totalCost;
  ```

### 6.4 快照 vs flush 的选择（`wal_memtable_snapshot_threshold_in_byte` / `max_wal_memtable_snapshot_num`）

`WALNode.java:546-559`
```java
// snapshot or flush memTable, flush memTable when it belongs to an old time partition, or
// it's snapshot count or size reach threshold.
int snapshotCount = memTableSnapshotCount.getOrDefault(oldestMemTable.getMemTableId(), 0);
long oldestMemTableTVListsRamCost = oldestMemTable.getTVListsRamCost();
if (TsFileUtils.getTimePartition(new File(oldestMemTableInfo.getTsFilePath()))
        < dataRegion.getLatestTimePartition()
    || snapshotCount >= config.getMaxWalMemTableSnapshotNum()
    || oldestMemTableTVListsRamCost > config.getWalMemTableSnapshotThreshold()) {
  flushMemTable(dataRegion, oldestTsFile, oldestMemTable);
  WRITING_METRICS.recordWalFlushMemTableCount(1);
  WRITING_METRICS.recordMemTableRamWhenCauseFlush(identifier, oldestMemTableTVListsRamCost);
} else {
  snapshotMemTable(dataRegion, oldestTsFile, oldestMemTableInfo);
}
```
- 快照计数内存态：`WALNode.java:116-118`
  ```java
  // memTable id -> memTable snapshot count
  // used to avoid write amplification caused by frequent snapshot
  private final Map<Long, Integer> memTableSnapshotCount = new ConcurrentHashMap<>();
  ```
  自增：`WALNode.java:615 memTableSnapshotCount.compute(memTable.getMemTableId(), (k, v) -> v == null ? 1 : v + 1);`
  **该 Map 不落盘，重启即清零** → 黑盒不可观测（见 §13）。
- 每轮删除任务最多递归 5 次：`WALNode.java:358 private static final int MAX_RECURSION_TIME = 5;` / `:412 while (recursionTime < MAX_RECURSION_TIME)`

---

## §7 WAL 阻写（throttle）

存在**两套**互不相同的 throttle：

### 7.1 WALManager 侧（按 WAL 磁盘占用，`wal_throttle_threshold_in_byte`）

- 判定：`WALManager.java:256-262`
  ```java
  public boolean shouldThrottle() { return getTotalDiskUsage() >= getThrottleThreshold(); }
  public long getThrottleThreshold() { return (long) (config.getThrottleThreshold() * 0.8); }
  ```
  **注意：实际阈值 = 配置值 × 0.8**（与日志文案一致）。
- 使用点 1：删除线程循环（超阈值就继续删过期文件，并打 WARN）：`WALManager.java:200-219`
  ```java
  boolean firstLoop = true;
  while ((firstLoop || shouldThrottle())) {
    deleteOutdatedFilesInWALNodes();
    if (firstLoop && shouldThrottle()) {
      logger.warn(
          StorageEngineMessages
              .STORAGE_LOG_WAL_DISK_USAGE_IS_LARGER_THAN_THE_WAL_THROTTLE_THRESHOLD_2396FFCC,
          getTotalDiskUsage(), getThrottleThreshold());
    }
  ```
  **日志文案原文**（`StorageEngineMessages(en):813-816`）：
  ```
  WAL disk usage {} is larger than the wal_throttle_threshold_in_byte * 0.8 {}, please check your write load, iot consensus and the pipe module. It's better to allocate more disk for WAL.
  ```
- 使用点 2：作为"快照/flush"的触发条件之一：`WALNode.java:507-510`（`|| WALManager.getInstance().shouldThrottle()`）
- **表现**：WALManager 侧**不阻塞、不抛异常**，只是更积极地删过期 WAL + 把 memTable 快照/flush 到 TsFile（见 §6.3/6.4 的日志）。
- 动态阈值（未配置或按磁盘算）：`IoTDBDescriptor.java:2292-2314`
  ```java
  public long getThrottleThresholdWithDirs() {
    ...
    if (dataFileStores.isEmpty()) { dirUseProportion = MAX_DIR_USE_PROPORTION; }   // 0.8
    else { dirUseProportion = MIN_DIR_USE_PROPORTION; }                            // 0.5
  ```
  （常量 `:139-141` `MAX_DIR_USE_PROPORTION = 0.8` / `MIN_DIR_USE_PROPORTION = 0.5`）

### 7.2 IoTConsensus 侧（`consensusReqReader.getTotalSize()`，直接阻塞写）

- 判定与**阻塞写**：`iotdb-core/consensus/src/main/java/org/apache/iotdb/consensus/iot/IoTConsensusServerImpl.java:135-138, 303-322`
  ```java
  if (needBlockWrite()) {
    logger.info(IoTConsensusMessages.THROTTLE_DOWN, getSearchIndex(), getMinSyncIndex());
    try {
      boolean timeout =
          !stateMachineCondition.await(
              config.getReplication().getThrottleTimeOutMs(), TimeUnit.MILLISECONDS);
      if (timeout) {
        return RpcUtils.getStatus(
            TSStatusCode.WRITE_PROCESS_REJECT,
            String.format(
                "The write is rejected because the wal directory size has reached the "
                    + "threshold %d bytes. You may need to adjust the flush policy of the "
                    + "storage storageengine or the IoTConsensus synchronization parameter",
                config.getReplication().getWalThrottleThreshold()));
      }
    } catch (InterruptedException e) {
      logger.error(IoTConsensusMessages.FAILED_TO_THROTTLE_DOWN, e);
  ```
  → **表现：写线程阻塞在 `stateMachineCondition.await`（默认最多 30s）；超时后返回 `WRITE_PROCESS_REJECT` + 上面那段文案。**
- 阈值与超时：`IoTConsensusServerImpl.java:1334-1340`
  ```java
  public boolean needBlockWrite() {
    return consensusReqReader.getTotalSize() > config.getReplication().getWalThrottleThreshold();
  }
  public boolean unblockWrite() {
    return consensusReqReader.getTotalSize() < config.getReplication().getWalThrottleThreshold();
  }
  ```
  默认值：`iotdb-core/consensus/src/main/java/org/apache/iotdb/consensus/config/IoTConsensusConfig.java:450-451`
  ```java
  private long walThrottleThreshold = 50 * 1024 * 1024 * 1024L;
  private long throttleTimeOutMs = TimeUnit.SECONDS.toMillis(30);
  ```
  从 DataNode 配置注入：`DataRegionConsensusImpl.java:205 .setWalThrottleThreshold(CONF.getThrottleThreshold())`；
  `IoTConsensusServerImpl.java:316` 引用 `config.getReplication().getWalThrottleThreshold()`
- **解除条件**：LogDispatcher 在推进 safeIndex 时检查并 `signalAll`：`.../iot/logdispatcher/LogDispatcher.java:424-425`
  ```java
  if (impl.unblockWrite()) {
    impl.signal();
  ```
- 日志常量原文：
  - `IoTConsensusMessages.java:57 public static final String THROTTLE_DOWN = "[Throttle Down] index:{}, safeIndex:{}";`（**INFO**）
  - `IoTConsensusMessages.java:60 public static final String FAILED_TO_THROTTLE_DOWN = "Failed to throttle down because ";`（**ERROR**，注意该文案以空格结尾，异常堆栈跟在后面）
- 阈值来源优先级：`IoTDBDescriptor.java:143-145`
  ```java
  private static final String[] DEFAULT_WAL_THRESHOLD_NAME = {
    "iot_consensus_throttle_threshold_in_byte", "wal_throttle_threshold_in_byte"
  };
  ```
  即旧键 `iot_consensus_throttle_threshold_in_byte` 优先，且会打 WARN（`:2280-2285`）。

---

## §8 恢复路径

### 8.1 入口

- `StorageEngine.asyncRecoverDataRegion()` → `StorageEngine.java:261-268`
  ```java
  // wait until wal is recovered
  if (!CONFIG.getDataRegionConsensusProtocolClass().equals(ConsensusFactory.RATIS_CONSENSUS)) {
    try {
      WALRecoverManager.getInstance().recover();
    } catch (WALException e) {
      LOGGER.error(StorageEngineMessages.FAIL_TO_RECOVER_WAL, e);
    }
  }
  ```
- latch 初始化（等所有 DataRegion 上报完 unsealed TsFile）：`StorageEngine.java:290-291`
  ```java
  WALRecoverManager.getInstance()
      .setAllDataRegionScannedLatch(new ExceptionalCountDownLatch(recoverDataRegionNum));
  ```
- 主流程：`.../wal/recover/WALRecoverManager.java:74-145`
  - 扫描 `<walDir>/*` 子目录作为 WALNode 目录：`:78-90`
  - 每个目录提交一个 `WALNodeRecoverTask`：`:110-113`
- 单节点恢复：`.../wal/recover/WALNodeRecoverTask.java:82-158`
  - 读最后一个 wal 文件信息并修补：`:87, 160-...`（方法名 `readLastFileInfoAndRepairIt`）
  - 从 checkpoint 恢复：`:92 recoverInfoFromCheckpoints();`
  - 重放 TsFile：`:93 recoverTsFiles();`
- TsFile 重放与 redo：`.../wal/recover/file/UnsealedTsFileRecoverPerformer.java:167-175 redoLog(WALEntry)`；
  `AbstractTsFileRecoverPerformer.java:80`（TsFile 丢失则跳过）

### 8.2 恢复日志文案（原文）

| 时机 | file:line（调用点） | 文案 |
|---|---|---|
| 开始恢复 | `WALRecoverManager.java:75` | `StorageEngineMessages.START_RECOVERING_WAL` = `"Start recovering wal."`（`StorageEngineMessages(en):362`） |
| 等齐 unsealed TsFile | `WALRecoverManager.java:103-105` | `"Data regions have submitted all unsealed TsFiles, start recovering TsFiles in each wal node."`（`:1220-1221`） |
| **整体恢复完成** | `WALRecoverManager.java:144` | `SUCCESSFULLY_RECOVER_ALL_WAL_NODES` = `"Successfully recover all wal nodes."`（`:363`） |
| 单节点开始 | `WALNodeRecoverTask.java:84` | `START_RECOVERING_WAL_NODE_IN_DIR` = `"Start recovering WAL node in the directory {}"`（`:357`） |
| 单节点注册完成 | `WALNodeRecoverTask.java:128-131` / `150-153` | `"Successfully recover WAL node in the directory {}, add this node to WALManger."`（`:1212-1213`，注意源码里 `WALManger` 是拼写错误） |
| 单节点文件被删 | `WALNodeRecoverTask.java:134-137` | `"Successfully recover WAL node in the directory {}, so delete these wal files."`（`:1214-1215`） |
| 读日志失败（跳过） | `WALNodeRecoverTask.java:195` / `:343` | `FAIL_TO_READ_WAL_LOGS_SKIP` = `"Fail to read wal logs from {}, skip them"`（`:359`） |
| 恢复元数据失败 | `WALNodeRecoverTask.java:244` | `FAIL_TO_RECOVER_WAL_METADATA` = `"Fail to recover metadata of wal file {}"`（`:361`） |
| 读 WAL 文件失败 | `WALReader.java:90 / 94` | `"Fail to read WALEntry from wal file {}, skip broken WALEntries."`（`:345`） |
| TsFile 未崩无需 redo | `UnsealedTsFileRecoverPerformer.java:170-173` | `"This TsFile {} isn't crashed, no need to redo wal log."`（`:1249-1250`） |
| redo 出错 | `UnsealedTsFileRecoverPerformer.java:237` | `ERROR_REDO_WAL` = `"meet error when redo wal of {}"`（`:369`） |
| **失败的统一文案** | `StorageEngine.java:266`（`FAIL_TO_RECOVER_WAL`） | `"Fail to recover wal."`（`StorageEngineMessages(en):48`） |
| 恢复整体结束（含 WAL） | `StorageEngine.java:276-279` | `"Storage Engine local recovery tasks finished in {}s."`（`:657-658`） |

---

## §9 监控指标

指标名常量枚举：`iotdb-core/node-commons/src/main/java/org/apache/iotdb/commons/service/metric/enums/Metric.java:80-85`
```java
WAL_NODE_NUM("wal_node_num"),
WAL_NODE_INFO("wal_node_info"),
WAL_BUFFER("wal_buffer"),
WAL_COST("wal_cost"),
WAL_QUEUE_MEM_COST("wal_queue_mem_cost"),
```
文件类：`Metric.java:156-157`
```java
FILE_SIZE("file_size"),
FILE_COUNT("file_count"),
```

| 精确指标名（Prometheus 形态：`<Metric>`，tag `name`/`type`/`stage`） | 类型/级别 | 绑定处 | 上报处 |
|---|---|---|---|
| `wal_node_num`，tag `name="wal_nodes_num"` | AutoGauge / IMPORTANT | `WritingMetrics.java:215-221` | `WALManager::getWALNodesNum`（`WALManager.java:268-270`） |
| `wal_buffer`，tag `name="used_ratio"` | Histogram / IMPORTANT | `WritingMetrics.java:222-224` | `WALBuffer.java:663-664 recordWALBufferUsedRatio(usedRatio)` |
| `wal_buffer`，tag `name="entries_count"` | Histogram / IMPORTANT | `WritingMetrics.java:225-230` | `WALBuffer.java:750 recordWALBufferEntriesCount(info.fsyncListeners.size())` |
| `wal_buffer`，tag `name="wal_entry_num_for_one_tsfile"` | Histogram / IMPORTANT | `WritingMetrics.java:231-236` | `WritingMetrics.java:1000-1001` |
| `wal_buffer`，tag `name="serialized_wal_buffer_size"` | Histogram / IMPORTANT | `WritingMetrics.java:238-243` | `WritingMetrics.java:967-970` |
| `wal_buffer`，tag `name="wrote_wal_buffer_size"` | Histogram / IMPORTANT | `WritingMetrics.java:244-249` | 同上 |
| `wal_buffer`，tag `name="wal_compress_cost"` | Histogram / IMPORTANT | `WritingMetrics.java:250-255` | `LogWriter.java:146 recordCompressWALBufferCost(...)` |
| `wal_buffer`，tag `name="wal_uncompress_cost"` | Histogram / IMPORTANT | `WritingMetrics.java:256-261` | `WALInputStream.java:525 recordWALUncompressCost(...)` |
| `wal_buffer`，tag `name="read_wal_buffer_size"` | Histogram / IMPORTANT | `WritingMetrics.java:262-267` | `WritingMetrics.java:977-979` |
| `wal_buffer`，tag `name="read_wal_buffer_cost"` | Histogram / IMPORTANT | `WritingMetrics.java:268-273` | 同上 |
| `wal_buffer`，tag `name="write_wal_buffer_cost"` | Histogram / IMPORTANT | `WritingMetrics.java:274-279` | `WritingMetrics.java:967-970` |
| `wal_queue_mem_cost`，tag `name="wal_queue_max_mem_cost"` | Gauge / IMPORTANT | `WritingMetrics.java:280-286` | `WritingMetrics.java:1004-1006` |
| `wal_queue_mem_cost`，tag `name="wal_queue_current_mem_cost"` | AutoGauge / IMPORTANT | `WritingMetrics.java:288-294` | `SystemInfo::getWalBufferQueueMemoryBlock().getUsedMemoryInBytes()` |
| `wal_node_info`，tag `name="effective_ratio_info"`、`type=<walNodeId>` | Histogram / IMPORTANT | `WritingMetrics.java:592-607`（按 WALNode 创建） | `WritingMetrics.java:768-778`（值 = ratio×100） |
| `wal_node_info`，tag `name="oldest_mem_table_ram_when_cause_snapshot"`、`type=<walNodeId>` | Histogram / IMPORTANT | 同上 | `WALNode.java:649-650` / `WritingMetrics.java:780-790` |
| `wal_node_info`，tag `name="oldest_mem_table_ram_when_cause_flush"`、`type=<walNodeId>` | Histogram / IMPORTANT | 同上 | `WALNode.java:556` / `WritingMetrics.java:792-802` |
| `wal_cost`，tag `stage="make_checkpoint"`、`type=<CheckpointType>` | Timer / IMPORTANT | `WritingMetrics.java:346-369` | — |
| `wal_cost`，tag `stage="serialize_wal_entry"`、`type="serialize_wal_entry_total"` | Timer / IMPORTANT | `WritingMetrics.java:370-377` | `WALBuffer.java:319/353/357 recordSerializeWALEntryTotalCost(...)` |
| `wal_cost`，tag `stage="sync_wal_buffer"`、`type="sync"` / `"fsync"` | Timer / IMPORTANT | `WritingMetrics.java:378-393` | `WALBuffer.java:751 recordSyncWALBufferCost(cost, forceFlag)`（`WritingMetrics.java:982-...`） |
| `file_size`，tag `name="wal"` | AutoGauge / **CORE** | `.../metrics/file/WalFileMetrics.java:35-41` | `WALManager::getTotalDiskUsage` |
| `file_count`，tag `name="wal"` | AutoGauge / **CORE** | `.../metrics/file/WalFileMetrics.java:42-48` | `WALManager::getTotalFileNum` |
| `flush_memtable_count`，tag `type="wal_flush_memtable_count"` | Counter / IMPORTANT | `WritingMetrics.java:647-654` | `WALNode.java:555 recordWalFlushMemTableCount(1)` |

字符串常量定义：`WritingMetrics.java:186-198`（overview）与 `:332-337`（cost）、`:447-459`（node info / flush count）。
指标集注册：`FileMetrics.java:50-57`（`WAL_FILE_METRICS.bindTo(metricService)`，`:43` 常量）。

**监控缺口（源码中确实没有）**：没有"每 WALNode 的文件数"、"WALNode 数量以外的节点信息"、"快照次数"、
"被删除文件数"等指标；`deleteOutdatedFiles` 只更新 `WALManager` 内部计数（`WALManager.java:272-290`），
对外只通过 `file_size`/`file_count` 两个 gauge 暴露总量。

---

## §10 日志关键字清单（可用于测试观测）

### 10.1 WALNode 创建 / 分配

| # | file:line | 级别 | 完整文案 |
|---|---|---|---|
| 1 | `WALNode.java:145` | INFO | `create folder {} for wal node-{}.`（`StorageEngineMessages(en):350`） |
| 2 | `AbstractWALBuffer.java:73-74` | INFO | `Create folder {} for wal node-{}'s buffer.`（`:370`） |
| 3 | `CheckpointManager.java:86` | INFO | `create folder {} for wal buffer-{}.`（`:335`） |
| 4 | `AbstractWALBuffer.java:150` | **DEBUG** | `Open new wal file {} for wal node-{}'s buffer.`（`:371`） |
| 5 | `WALBuffer.java:198` / `:240` | ERROR | `Fail to allocate wal node-{}'s buffer because out of memory.`（`:372`） |
| 6 | `AbstractNodeAllocationStrategy.java:55-58` | ERROR | `Fail to create wal node allocation strategy because all disks of wal folders are full.`（`StorageEngineMessages(en):1247-1248`） |
| 7 | `AbstractNodeAllocationStrategy.java:75` | ERROR | `Fail to create wal node because all disks of wal folders are full.`（`:384`） |
| 8 | `AbstractNodeAllocationStrategy.java:78` | WARN | `Failed to create WAL node after retries for identifier: ` + identifier（`:385`） |
| 9 | `WALManager.java:187 / 192 / 194-197` | INFO | `Start rebooting wal delete thread.` → `Stop wal delete thread successfully, and now restart it.` → `Reboot wal delete thread successfully, current period is {} ms`（`:324 / :325 / :811-812`） |

### 10.2 WAL 文件轮转 / 删除 / 写入

| # | file:line | 级别 | 完整文案 |
|---|---|---|---|
| 10 | `WALNode.java:466-470` | **DEBUG** | `Successfully delete {} outdated wal files for wal node-{}`（`:1181-1182`）←**结论性文案但是 DEBUG** |
| 11 | `WALNode.java:486-491` | INFO | `Fail to delete outdated wal file {} of wal node-{}.`（`:1187-1188`） |
| 12 | `WALNode.java:377-381` | **DEBUG** | `wal node-{}:no wal file or wal file number less than or equal to one was found`（`:1177-1178`） |
| 13 | `WALNode.java:1001-1005` | INFO | `timeout when waiting for next WAL entry ready, execute rollWALFile. Current search index in wal buffer is {}, and next target index is {}`（`:1195-1197`） |
| 14 | `WALNode.java:1249-1253` | ERROR | `Fail to trigger rolling wal node-{}'s wal file log writer.`（`:1208-1209`） |
| 15 | `WALNode.java:621-622` | ERROR | `Fail to roll wal log writer.`（`:355`） |
| 16 | `WALNode.java:637-638` | ERROR | `Fail to snapshot memTable of {}`（`:356`） |
| 17 | `WALBuffer.java:641-645` / `:707-711` | ERROR | `Fail to roll wal node-{}'s log writer, change system mode to error.`（`:1243-1244`） |
| 18 | `WALBuffer.java:677-681` | ERROR | `Fail to sync wal node-{}'s buffer, change system mode to error.`（`:1241-1242`） |
| 19 | `WALBuffer.java:727-731` | ERROR | `Fail to fsync wal node-{}'s log writer, change system mode to error.`（`:1245-1246`） |
| 20 | `WALBuffer.java:251-254` | WARN | `Fail to write WALEntry into wal node-{} because this node is closed. It's ok to see this log during data region deletion.`（`:1230-1232`） |
| 21 | `WALBuffer.java:665-670` | **DEBUG** | `Sync wal buffer, forceFlag: {}, buffer used: {} / {} = {}%`（`:1228-1229`） |
| 22 | `WALBuffer.java:258-274` | 无日志（**抛异常给写请求**） | entry 超限时不打日志，直接 `walEntry.getWalFlushListener().fail(new IoTDBRuntimeException(String.format("The WAL entry size %d exceeds wal_entry_size_limit_in_byte %d.", ...), WAL_ENTRY_TOO_LARGE.getStatusCode()))`（文案 `:391`）→ 客户端收到写失败 |
| 23 | `WALBuffer.java:278-279` / `:342-345` | WARN | `Interrupted when waiting for adding WALEntry to buffer.`（`:373`）/ `Interrupted when waiting for taking WALEntry from blocking queue to serialize.`（`:1233-1234`） |
| 24 | `WALBuffer.java:848` | ERROR | `Fail to put CLOSE_SIGNAL to walEntries.`（`:376`） |
| 25 | `WALBuffer.java:861` | ERROR | `Fail to close wal node-{}'s log writer.`（`:377`） |
| 26 | `DataRegion.java:3509` | INFO | `Writing no-file-related deletion to WAL {}`（`:161`） |

### 10.3 快照 / effective ratio

| # | file:line | 级别 | 完整文案 |
|---|---|---|---|
| 27 | `WALNode.java:456-461` | **DEBUG** | `Effective information ratio is {}, active memTables cost is {}, total cost is {}`（`:1179-1180`） |
| 28 | `WALNode.java:569-577` | INFO | `WAL node-{} flushes memTable-{} to TsFile {} because Effective information ratio {} is below wal min effective info ratio {}, memTable size is {}.`（`:1189-1191`） |
| 29 | `WALNode.java:641-648` | INFO | `WAL node-{} snapshots memTable-{} to wal files because Effective information ratio {} is below wal min effective info ratio {}, memTable size is {}.`（`:1192-1194`） |
| 30 | `WALNode.java:588` / `:592` | WARN | `Waiting too long for memTable flush to be done.`（`:353`）/ `Interrupted when waiting for memTable flush to be done.`（`:354`） |

### 10.4 阻写

| # | file:line | 级别 | 完整文案 |
|---|---|---|---|
| 31 | `WALManager.java:208-213` | WARN | `WAL disk usage {} is larger than the wal_throttle_threshold_in_byte * 0.8 {}, please check your write load, iot consensus and the pipe module. It's better to allocate more disk for WAL.`（`:813-816`） |
| 32 | `IoTConsensusServerImpl.java:304` | INFO | `[Throttle Down] index:{}, safeIndex:{}`（`IoTConsensusMessages.java:57`） |
| 33 | `IoTConsensusServerImpl.java:319` | ERROR | `Failed to throttle down because `（`IoTConsensusMessages.java:60`） |
| 34 | `IoTConsensusServerImpl.java:310-316`（返回给客户端的 message，非日志） | — | `The write is rejected because the wal directory size has reached the threshold %d bytes. You may need to adjust the flush policy of the storage storageengine or the IoTConsensus synchronization parameter` |

### 10.5 恢复

见 §8.2 表格（13 条），代表性 3 条：
- `WALRecoverManager.java:75` INFO `Start recovering wal.`
- `WALRecoverManager.java:144` INFO `Successfully recover all wal nodes.`
- `WALNodeRecoverTask.java:84` INFO `Start recovering WAL node in the directory {}`

### 10.6 压缩 / 文件格式

| # | file:line | 级别 | 完整文案 |
|---|---|---|---|
| 35 | `WALInputStream.java:402` | INFO | `Failed to load WAL segment in V1 way, try in V2 way successfully.`（`:343`） |
| 36 | `WALInputStream.java:381-386` | ERROR | `Unexpected error when loading a wal segment {} in {}@{}`（`:1161-1162`） |
| 37 | `WALFileUtils.java:393-397` | WARN | `Failed to scan WAL file {} for searchable request metadata`（`:1165-1166`） |
| 38 | `WALReader.java:90 / 94` | WARN | `Fail to read WALEntry from wal file {}, skip broken WALEntries.`（`:345`） |
| 39 | `WALNode.java:931-936` | **DEBUG** | `Failed to serialize ObjectNode {} at search index {}, possibly because its object file has been deleted by TTL. Skip this ObjectNode and continue reading the WAL.`（`:1204-1207`） |

### 10.7 关停

| # | file:line | 级别 | 完整文案 |
|---|---|---|---|
| 40 | `WALManager.java:297 / 302 / 305` | INFO | `Stopping WALManager` / `Deleting outdated files before exiting` / `WALManager stopped`（`:328 / :329 / :330`） |
| 41 | `WALManager.java:216` | INFO | `Timed wal delete thread is interrupted.`（`:326`） |
| 42 | `WALManager.java:249` | ERROR | `Interrupted when waiting for all write-ahead logs flushed.`（`:327`） |

### 10.8 可观测性关键结论

- 默认日志级别根为 **info**：`iotdb-core/datanode/src/assembly/resources/conf/logback-datanode.xml:225 <root level="info">`
  → **所有 `logger.debug` 的 WAL 文案（#4、#10、#12、#21、#27、#39 等）在默认部署下不会落盘**。
  写用例时**不要**把断言建立在 "Successfully delete N outdated wal files" 这类 DEBUG 文案上。
- `StorageEngineMessages`/`DataNodeMiscMessages` 都是 i18n 常量类，实际输出取决于 locale（en/zh 两套文件）。
  用例断言建议只用**英文原文的关键子串**，或同时匹配中英文（zh 对照见 §14）。

---

## §11 OBJECT 类型与 WAL

`to_object` SQL 函数识别：`queryengine/plan/relational/sql/util/AstUtil.java:127`
```java
&& "to_object".equals(((FunctionCall) expression).getName().toString())) {
```

WAL 侧路径（链路完整）：

1. **写 WAL**：`IWALNode.java:58 WALFlushListener log(long memTableId, ObjectNode objectNode);`
   → `WALNode.java:286-290`
   ```java
   @Override
   public WALFlushListener log(long memTableId, ObjectNode objectNode) {
     WALEntry walEntry = new WALInfoEntry(memTableId, objectNode);
     return log(walEntry);
   ```
   （WAL DISABLE 时走假节点：`WALFakeNode.java:88`）
2. **entry 类型**：`WALEntry.java:82-83`
   ```java
   } else if (value instanceof ObjectNode) {
     this.type = WALEntryType.OBJECT_FILE_NODE;
   ```
   反序列化：`WALEntry.java:141-143`（`case OBJECT_FILE_NODE: value = (ObjectNode) PlanNodeType.deserializeFromWAL(stream);`）
3. **序列化**：`WALInfoEntry.java:117 ((ObjectNode) value).serializeToWAL(buffer, encodedSearchIndex);`；
   `ObjectNode.java:144-155` —— **只写文件路径 + offset + 长度，不写对象内容本体**：
   ```java
   public void serializeToWAL(IWALByteBufferView buffer, long encodedSearchIndex) {
     buffer.putShort(getType().getNodeType());
     buffer.putLong(encodedSearchIndex);
     buffer.put((byte) (isEOF ? 1 : 0));
     buffer.putLong(offset);
     try { filePath.serialize(buffer); } catch (IOException e) { throw new RuntimeException(e); }
     buffer.putInt(content.length);
   }
   ```
   大小：`ObjectNode.java:157-165 serializedSize()`（不含 content）
4. **内容懒加载**：`ObjectNode.java:178-195 deserializeFromWAL(ByteBuffer)`
   ```java
   Optional<File> objectFile = TierManager.getInstance().getAbsoluteObjectFilePath(filePath.toString());
   ...
   if (objectFile.isPresent()) {
     try (RandomAccessFile raf = new RandomAccessFile(objectFile.get(), "r")) { raf.seek(offset); raf.readFully(contents); }
   } else { ... }
   ```
   （`:195` 之后抛 `ObjectFileNotExist`，`:27 import org.apache.iotdb.commons.exception.ObjectFileNotExist;`）
5. **consensus 转发时重新读文件**：`WALNode.java:911-938`
   ```java
   if (type != WALEntryType.OBJECT_FILE_NODE) { requests.add(new IoTConsensusRequest(buffer)); return buffer.remaining(); }
   final WALEntry walEntry = WALEntry.deserialize(new DataInputStream(new ByteArrayInputStream(buffer.array())));
   final ObjectNode objectNode = (ObjectNode) walEntry.getValue();
   try {
     // A WAL ObjectNode stores only the object-file location and loads its content lazily when
     // the leader sends the request to followers. TTL may delete that external file first.
     requests.add(new IoTConsensusRequest(objectNode.serialize()));
     return objectNode.getMemorySize();
   } catch (SerializationRunTimeException e) { logger.debug(...); return SKIPPED_OBJECT_NODE_MEMORY_SIZE; }
   ```
   `ObjectNode.serialize()` 会重试 2 次（正式文件 → 临时文件）：`ObjectNode.java:287-324`
   ```java
   for (int i = 0; i < 2; i++) {
     Optional<File> objectFile = TierManager.getInstance().getAbsoluteObjectFilePath(filePath.toString());
     ...
     Optional<File> objectTmpFile = TierManager.getInstance().getAbsoluteObjectFilePath(
         ObjectPathNaming.toTempRelativePath(filePath.toString(), filePath.getTime()));
   ```

**测试要点**：OBJECT 的 WAL 只记"外部对象文件位置"，**对象文件被 TTL 删除后 WAL 条目无法重放**（源码注释明说），
所以 OBJECT + WAL 的可测面主要是：写入成功、重启后可查、TTL 删除对象文件后 WAL 转发被跳过且打 DEBUG 日志。

---

## §12 可测点清单（34 条可判定断言）

> 说明：`[路径:行]` 为源码依据；`→` 后为"可观测信号 ⇒ 期望"。
> 「可稳定构造」= 黑盒（SQL/日志/文件/指标/HTTP metrics）可判定；「需白盒或不可观测」= 需要 JDWP/只读 agent 或根本无外部信号。

**A. 配置项存在性与默认值（模板/SHOW）**

1. `- [iotdb-system.properties.template:1919-2030]` 模板内 WAL 段恰好声明 14 个 `wal_*`/`max_wal_*`/`delete_wal_files_*`/`enable_wal_compression` 键 ⇒ 逐键 grep 模板必须命中，缺任一即 FAIL。「可稳定构造」
2. `- [iotdb-system.properties.template:293]` `dn_wal_dirs=data/datanode/wal` 存在且为 `# effectiveMode: restart`（`:287`） ⇒ 全仓检索 `^wal_dir=`/`^wal_dirs=` 必须 0 命中（只有 `dn_wal_dirs`）。「可稳定构造」
3. `- [IoTDBDescriptor.java:1836-1838]` `max_wal_nodes_num<=0` 时保持默认 0 ⇒ 写 `max_wal_nodes_num=-5` 重启后 `show configuration` 中该键值必须不是 -5（仍是 0）。「可稳定构造」
4. `- [IoTDBDescriptor.java:2222-2224]` `wal_min_effective_info_ratio=0` 不生效（`>0` 才 set） ⇒ 设 0 重启后生效值仍为 0.1。「可稳定构造」
5. `- [IoTDBDescriptor.java:2192-2194]` `wal_async_mode_fsync_delay_in_ms` 要求 `>0` ⇒ 设 0 或负数重启后仍为 1000。「可稳定构造」
6. `- [ConfigurationFileUtils.java:136-139 + ConfigManager.java:1927-1932]` 非 HOT_RELOAD 键在热加载时会被跳过、并回提示 restart ⇒ `SET CONFIGURATION 'wal_mode'='SYNC'` 返回串必须含 `restart is required`；`SET CONFIGURATION 'wal_file_size_threshold_in_byte'='1048576'` 返回串**不得**含该提示。「可稳定构造」
7. `- [IoTDBDescriptor.java:2712-2715]` `delete_wal_files_period_in_ms` 改变后重启删除线程 ⇒ 热改该键后日志出现 `Reboot wal delete thread successfully, current period is {} ms`（`StorageEngineMessages(en):811-812`）。「可稳定构造」
8. `- [ConfigurationFileUtils.java:384-390]` 模板中不存在的键（如 `wal_cache_shrink_clear_enabled`）会被 `SET CONFIGURATION` 丢弃 ⇒ 该键 SET 后重启，`show configuration` 里值必须仍为默认 true。「可稳定构造」
9. `- [IoTDBDescriptor.java:2278-2286]` 旧键 `iot_consensus_throttle_threshold_in_byte` 触发废弃 WARN ⇒ 同时配新旧两键时日志出现 `MISC_LOG_THE_THROTTLE_THRESHOLD_PARAMS_IS_DEPRECATED_PLEASE_USE_AA0E8EC7` 文案。「可稳定构造」
10. `- [IoTDBConfig.java:3885-3886 无消费者]` `iot_consensus_cache_window_time_in_ms` 是死配置 ⇒ 设不同值重启后行为（写吞吐/日志）无差异。「需白盒或不可观测」

**B. DISABLE 校验**

11. `- [IoTDBStartCheck.java:151-162]` `wal_mode=DISABLE` + IoTConsensus ⇒ 节点启动失败，日志含 `Configuring the WALMode as disable is not supported under IoTConsensus and IoTConsensusV2 stream mode`。「可稳定构造」
12. `- [AbstractIoTDBStartCheck.java:87-88 + SystemPropertiesHandler.java:140-142]` 该校验只在 `isFirstStart()`（无 `iotdb-system.properties`）时执行 ⇒ **已运行过的节点**改 `wal_mode=DISABLE` 重启**不应**出现 §2 异常文案。「可稳定构造」
13. `- [IoTDBStartCheck.java:151-157 + IoTDBConfig.java:1178]` IoTConsensusV2 默认 `batch` 模式 ⇒ `iot_consensus_v2_mode=batch` + `wal_mode=DISABLE` 启动**不应**出现该异常；`=stream` 时必须出现。「可稳定构造」
14. `- [DataNode.java:971-974]` RatisConsensus 强制 DISABLE ⇒ Ratis 协议下 WAL 目录 `<dn_wal_dirs>/*` 不应产生新 WALNode 子目录。「可稳定构造」
15. `- [IoTDBStartCheck.java:219-225]` Ratis 或 DISABLE 时不注册/创建 WAL 目录 ⇒ 删除 `dn_wal_dirs` 后以 Ratis 启动，节点仍能起来。「可稳定构造」

**C. 目录与文件命名**

16. `- [CommonDescriptor.java:124-128 + AbstractNodeAllocationStrategy.java:72-73]` WALNode 目录 = `<walDir>/<identifier>` ⇒ 自定义 `dn_wal_dirs=<tmp>` 后写入，`<tmp>` 下出现子目录。「可稳定构造」
17. `- [WALManager.java:87-96 + DataRegion.java:809]` IoTConsensus(V2) 下子目录名 = `<database>-<regionId>` ⇒ 建库 `root.w` 写数据后目录名匹配 `^root\.w-\d+$`。「可稳定构造」
18. `- [WALManager.java:80-83 + ElasticStrategy.java:41,67-69]` `max_wal_nodes_num=0` 时用 Elastic，`APPLICATION_NODE_RATIO=4` ⇒ WALNode 目录名是 `0`、`1`…（纯数字），且数量远小于 region 数。「可稳定构造」
19. `- [WALFileUtils.java:65-83 + IoTDBConstant.java:358-359]` WAL 文件名匹配 `^_\d+-\d+-[01]\.wal$` ⇒ `ls <walDir>/<node>/` 全部命中该正则。「可稳定构造」
20. `- [WALFileStatus.java:26-31 + WALFileUtils.java:135-141]` 文件名第 3 段只能是 0/1 ⇒ 解析失败（非 0/1）即 FAIL。「可稳定构造」
21. `- [WALNode.java:143-146 + StorageEngineMessages(en):350]` 首次建目录打 INFO `create folder {} for wal node-{}.` ⇒ 首次启动日志命中；已有目录时**不**打印。「可稳定构造」
22. `- [WALWriter.java:90-96]` 空 WAL 文件是合法文件（只有头 magic，不追加 end marker） ⇒ 静默期目录里允许出现仅含 6 字节（`V3-WAL`，`WALFileVersion.java:32`）的 `.wal`。「需白盒或不可观测」（需 hexdump 才严格）

**D. 压缩**

23. `- [IoTDBDescriptor.java:2779-2785 + LogWriter.java:110-135]` `enable_wal_compression=true` 时算法为 LZ4、且 <32KB 的段**不压** ⇒ 小批量写入的 WAL 文件体积 ≈ 未压缩，大批量（>32KB）明显变小。「可稳定构造」
24. `- [LogWriter.java:136-152 + WALInputStream.java:487-504]` 压缩标志是"每段 1 字节 compressionType 头" ⇒ 同一 .wal 文件内可混有压缩段与未压缩段，且**关闭压缩后老文件仍可读**（重启恢复成功、无 `Failed to load WAL segment` ERROR）。「可稳定构造」
25. `- [WALInputStream.java:265-270]` 恢复时未压缩的半截段被截断容忍，压缩段则需完整 ⇒ 断电/强杀后未压缩写入的数据可恢复（可查），不保证压缩段半截数据。「可稳定构造」
26. `- [WALFileVersion.java:29-32 + 58-81]` magic 依次 V3(`V3-WAL`)/V2(`V2-WAL`)/默认 V1(`WAL`) ⇒ 把 `V3-WAL` 头改成乱码后恢复走"破损文件"分支，出现 WARN `Fail to read WALEntry from wal file {}, skip broken WALEntries.`（`WALReader.java:90/94`）。「需白盒或不可观测」（需改文件字节）

**E. 轮转 / fsync / 快照 / 删除**

27. `- [WALBuffer.java:697-705]` 轮转判据 `originalSize() >= wal_file_size_threshold_in_byte` ⇒ 把阈值设小（如 1MB）+ 持续写入，`.wal` 文件数量持续增长且单文件（未压缩累计）不超过阈值附近。「可稳定构造」
28. `- [WALNode.java:507-510 + 546-559]` 触发快照/flush 的两类可观测 INFO：`WAL node-{} flushes memTable-{} to TsFile {} ...`（`WALNode.java:569`）/ `WAL node-{} snapshots memTable-{} to wal files ...`（`:641`） ⇒ 把 `wal_min_effective_info_ratio` 调大后当天日志必然出现其中之一。「可稳定构造」
29. `- [WALNode.java:548-553]` `snapshotCount >= max_wal_memtable_snapshot_num` 或 `ram > wal_memtable_snapshot_threshold` 时走 flush 而不是 snapshot ⇒ 把 `max_wal_memtable_snapshot_num=1`、`wal_memtable_snapshot_threshold_in_byte` 设很小，日志应出现 flush 文案而非 snapshot 文案。「可稳定构造」
30. `- [WALNode.java:116-118]` `memTableSnapshotCount` 只在内存、重启清零 ⇒ "重启后再触发快照次数"无法从外部观测。「需白盒或不可观测」
31. `- [WALNode.java:671-676 + WALWriter.java:139-143]` IoTConsensus 下 `safelyDeletedSearchIndex=Long.MAX_VALUE` ⇒ 只有文件 status=0（第 3 段为 0）的才被删；status=1 的文件与最后 1 个文件始终保留。「可稳定构造」
32. `- [WALManager.java:256-262 + 200-219]` 实际阻写阈值 = `wal_throttle_threshold_in_byte × 0.8` ⇒ 把阈值调小到很小后，日志出现 WARN `WAL disk usage {} is larger than the wal_throttle_threshold_in_byte * 0.8 {}, please check your write load...`。「可稳定构造」
33. `- [IoTConsensusServerImpl.java:303-317 + 1334-1340 + LogDispatcher.java:424-425]` IoTConsensus 阻写表现为**阻塞**（默认 30s）后返回 `WRITE_PROCESS_REJECT`，解除后继续 ⇒ 写入端可观测到"卡住→报错/恢复"，日志出现 INFO `[Throttle Down] index:{}, safeIndex:{}`。「可稳定构造」

**F. 恢复 / 指标 / OBJECT**

34. `- [StorageEngine.java:264 + WALRecoverManager.java:75,144 + WALNodeRecoverTask.java:84,128-131]` 重启恢复的完整可观测序列 ⇒ 日志依次出现 `Start recovering wal.` → `Start recovering WAL node in the directory {}` → `Successfully recover WAL node in the directory {}, add this node to WALManger.` → `Successfully recover all wal nodes.`；恢复后写入数据不丢。「可稳定构造」
35. `- [WALRecoverManager.java:103-105]` 恢复前置条件日志 `Data regions have submitted all unsealed TsFiles, start recovering TsFiles in each wal node.` 必在 `Successfully recover all wal nodes.` 之前。「可稳定构造」
36. `- [WalFileMetrics.java:35-48 + Metric.java:156-157]` `/metrics`（Prometheus）中 `file_size{name="wal"}` 与 `file_count{name="wal"}` 存在且写入后 >0、flush 后回落。「可稳定构造」
37. `- [WritingMetrics.java:215-221 + Metric.java:80]` `/metrics` 中 `wal_node_num{name="wal_nodes_num"}` 存在 ⇒ IoTConsensus 下其值 = 已分配 WALNode 数（与 §3 目录数一致）。「可稳定构造」
38. `- [WritingMetrics.java:222-294 + Metric.java:82,85]` `wal_buffer{name="used_ratio"}`、`wal_buffer{name="wal_compress_cost"}`、`wal_queue_mem_cost{name="wal_queue_current_mem_cost"}` 等存在。「可稳定构造」
39. `- [WALNode.java:592-607 + WritingMetrics.java:768-802]` `wal_node_info{name="effective_ratio_info", type=<walNodeId>}` 等按 WALNode 动态创建 ⇒ 仅在有 WALNode 分配后出现（由 `/metrics` 观测）。「可稳定构造」
40. `- [ObjectNode.java:144-155 + WALNode.java:911-938]` OBJECT 写 WAL 只存文件路径+offset+长度；对象文件被 TTL 删除后转发被跳过并打 DEBUG 文案 ⇒ 黑盒只能间接判定（重启后对象列可查 / TTL 删除后不可查），跳过日志因 DEBUG 不可见。「需白盒或不可观测」

（共 **40** 条：其中 §12 表格在 A~F 六组，编号 1–40。）

---

## §13 源码结论

### 13.1 真实存在且可稳定黑盒测的

- **配置面**：`wal_mode`（含枚举校验 + 非法值启动失败）、`max_wal_nodes_num`、`wal_buffer_size_in_byte`、
  `wal_file_size_threshold_in_byte`、`wal_min_effective_info_ratio`、`wal_memtable_snapshot_threshold_in_byte`、
  `max_wal_memtable_snapshot_num`、`delete_wal_files_period_in_ms`、`wal_throttle_threshold_in_byte`、
  `wal_async/sync_mode_fsync_delay_in_ms`、`wal_entry_size_limit_in_byte`、`wal_file_list_cache_enabled`、
  `enable_wal_compression`、`dn_wal_dirs`、`wal_buffer_queue_proportion`。
  可测的判定信号：`show configuration` / `SET CONFIGURATION` 的返回串（restart 提示）、节点日志、WAL 目录文件系统状态。
- **DISABLE 校验**：可精确测（含"首次启动才校验"这个**反直觉但可判定**的行为）。
- **目录/文件命名**：`<dn_wal_dirs>/<identifier>/_<version>-<searchIndex>-<0|1>.wal`，正则可硬断言。
- **阻写**：两套机制都有可观测信号（WALManager 的 WARN；IoTConsensus 的 `[Throttle Down]` + `WRITE_PROCESS_REJECT`）。
- **恢复**：4 条 INFO 日志构成完整可判定序列。
- **指标**：`file_size{name="wal"}`、`file_count{name="wal"}`、`wal_node_num{name="wal_nodes_num"}` 等可从 `/metrics` 直接断言。
- **OBJECT + WAL**：写入/重启可查可测；"只存路径不存内容"是源码事实。

### 13.2 黑盒测不了 / 只能白盒的

- **WAL 加密**：没有独立 WAL 加密配置键，跟随 TSFile `encrypt_type`；触发条件与可测面都被 TSFile 加密工程覆盖，
  WAL 侧只能观测到文件名多一个 `FILE_ENCRYPTED_SUFFIX`（`WALFileUtils.java:194-202`）与 `WALManager.existsEncryptedFile()`。
- **快照内部状态**：`memTableSnapshotCount` 是 `ConcurrentHashMap`（`WALNode.java:118`），不落盘、无指标口径
  （只有 `wal_node_info` 的 RAM 直方图），重启即丢；"某 memTable 快照了几次"黑盒不可判定。
- **压缩比/段头/断点恢复的字节级细节**：`CompressionType` 段头、`originalSize()` 与磁盘 size 的差、
  `MIN_COMPRESSION_SIZE=32KB` 的边界，需要 hexdump / 只读 agent，黑盒只能看文件体积趋势。
- **`wal_min_effective_info_ratio` 的精确数值**：`effectiveInfoRatio` 只出现在 DEBUG 日志（`WALNode.java:456`），
  默认 `root level=info`（`logback-datanode.xml:225`）时不落盘；黑盒只能通过是否触发 flush/snapshot 间接判定。
- **"删除过期 WAL"条数**：结论性文案是 DEBUG（`WALNode.java:466`），黑盒只能通过 `file_count{name="wal"}` 与目录文件数间接判定。
- **`wal_cache_shrink_clear_enabled` / `iot_consensus_cache_window_time_in_ms`**：前者模板缺失（SET 无效），
  后者全仓无消费者 → 这两个键**无法构造出行为差异**，不要写功能断言。

---

## §14 未找到 / 存疑清单（含搜过的关键词）

| 项 | 结论 | 搜过的关键词 |
|---|---|---|
| `wal_dir`（单数）配置键 | **未找到**。只有 `dn_wal_dirs`；模板注释里出现 `wal_dirs` 属注释口误（`:286`） | `"wal_dir"`、`wal_dirs`、`getWalDirs`、`dn_wal_dirs` |
| `iot.concurrent.wal` 包 | **未找到**。`iotdb-core/consensus/` 下只有 `common/config/exception/iot/pipe/ratis/simple`；`iot/` 下只有 `client/log/logdispatcher/service/snapshot/subscription` | `iot.concurrent.wal`、`package org.apache.iotdb.consensus.iot.wal`、`iotdb-core/consensus/**/*.java` 内 `WALNode`/`IWALNode`（0 命中） |
| WAL 加密专用配置键 | **未找到**（WAL 加密跟随 TSFile `encrypt_type`） | `wal_encrypt`、`wal_encryption`、`enable_wal_encrypt`、`isEnableEncrypt` |
| DISABLE 校验出现在 `DataNode.pullAndCheckSystemConfigurations` 附近 | **未找到**（在 `IoTDBStartCheck.validateFirstStart`，经 `DataNode.java:530` 间接调用） | `MISC_EXCEPTION_CONFIGURING_THE_WALMODE_AS_DISABLE_...`、`WALMode.DISABLE`、`pullAndCheckSystemConfigurations` |
| `wal_node_info` 之外"WAL 文件数/删除数"专用指标 | **未找到** | `Metric.java` 全量、`WritingMetrics` 内 `WAL_*`、`WalFileMetrics` |
| "RC7" 字面量 | 本次未在源码中定位（未在 `pom.xml`/`iotdb-system.properties.template` 里检索到 `RC7`）；版本号 2.0.12.1 在 `pom.xml` | `RC7`、`2.0.12.1`、`build.version` |
| 中文日志文案对照 | 存在（`.../src/main/i18n/zh/...`），本文只给英文原文 | `StorageEngineMessages.java`(zh)、`DataNodeMiscMessages.java`(zh) |
| `wal_mode` 热改的即时生效 | **未找到**（模板标注 restart；`loadWALHotModifiedProps` 不含 `wal_mode`，`WALManager` 构造时已按启动值选定策略 `WALManager.java:76-85`） | `loadWALHotModifiedProps`、`setWalMode`、`wal_mode` |
