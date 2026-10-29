# 缺陷报告：IoTConsensusV2 配置项类名不一致导致副本静默失去冗余

> **重要更正（2026-10-22 16:15）**
>
> 本报告的前一版本把现象定性为「IoTConsensusV2 的副本复制功能失效（P0）」。该结论**是错的**，
> 根因是**测试配置写错了类名**，已由实测推翻：
>
> | 配置值 | 70.14 TsFile | 70.30 TsFile | CN 日志 `consensus pipe` 命中 |
> |---|---|---|---|
> | `org.apache.iotdb.consensus.**pipe**.IoTConsensusV2`（我先前用的） | 3 个 | **0 个** | **0** |
> | `org.apache.iotdb.consensus.**iot**.IoTConsensusV2`（规范值） | 3 个 | **3 个（尺寸完全一致）** | **28** |
>
> 换成规范值后，两个副本都持有完整数据、CN 正常创建 consensus pipe。**V2 的复制功能是正常的。**
>
> 因此本缺陷**降级**为「配置项类名不一致导致静默失去冗余」，严重级别从 P0 降为 **P2**。
> 下文保留完整排查过程，便于研发判断是否值得做一次配置归一化/校验。

---

## 一、缺陷基本信息

| 字段 | 内容 |
|---|---|
| **缺陷标题** | `data_region_consensus_protocol_class` 配成 `...consensus.pipe.IoTConsensusV2` 时，ConfigNode 不创建 consensus pipe，副本静默失去冗余（DataNode 侧却仍按 V2 正常启动） |
| **严重级别** | **P2** —— 功能不失效（数据可写可查），但副本冗余静默缺失，且无任何 ERROR |
| **缺陷类型** | 配置一致性 / 可观测性 |
| **发现版本** | `v20121rc9_1020_d206dc2`（TimechoDB 2.0.12.1，BuildInfo `d206dc2`） |
| **责任归属** | 主因是测试侧配置错误；产品侧存在"类名不归一化 + 无校验 + 无日志"的可改进点 |
| **报告日期** | 2026-10-22 |
| **验证人员** | 刘珍 |

---

## 二、问题本质：同一份配置被两处以不同方式解读

### 2.1 源码里的三个 V2 类名常量

`iotdb-core/consensus/src/main/java/org/apache/iotdb/consensus/ConsensusFactory.java`

```java
39  public static final String IOT_CONSENSUS = "org.apache.iotdb.consensus.iot.IoTConsensus";
42  public static final String LEGACY_IOT_CONSENSUS_V2 =
43      "org.apache.iotdb.consensus.pipe.PipeConsensus";
44  public static final String REAL_IOT_CONSENSUS_V2 =
45      "org.apache.iotdb.consensus.pipe.IoTConsensusV2";
46  public static final String IOT_CONSENSUS_V2 = "org.apache.iotdb.consensus.iot.IoTConsensusV2";  // ← 规范值
```

### 2.2 DataNode 侧会归一化（所以配错也能启动）

```java
// ConsensusFactory.getConsensusImpl()
className = normalizeConsensusProtocolClass(className);   // pipe.IoTConsensusV2 → iot.IoTConsensusV2
if (IOT_CONSENSUS_V2.equals(className)) {
  className = REAL_IOT_CONSENSUS_V2;                      // 再映射到真正的实现类
  ...
}
```

`normalizeConsensusProtocolClass()` 把 `LEGACY_*` 与 `REAL_*` 都映射到 `IOT_CONSENSUS_V2`。
因此**配 `...pipe.IoTConsensusV2` 时 DataNode 完全正常**：V2 实现被实例化、`syncLag` 指标出现、
写入与查询都正常。

### 2.3 ConfigNode 侧**不**归一化（所以 pipe 建不出来）

```java
// RegionMaintainHandler.isIoTConsensusV2DataRegion()
private boolean isIoTConsensusV2DataRegion(TConsensusGroupId regionId) {
  return TConsensusGroupType.DataRegion.equals(regionId.getType())
      && IOT_CONSENSUS_V2.equals(CONF.getDataRegionConsensusProtocolClass());   // ★ 直接比原始字符串
}
```

而 `ConfigNodeDescriptor` 读配置时也是原样存入：

```java
conf.setDataRegionConsensusProtocolClass(
    properties.getProperty("data_region_consensus_protocol_class",
                           conf.getDataRegionConsensusProtocolClass()));   // 无 normalize
```

⇒ 配置成 `...pipe.IoTConsensusV2` 时，`isIoTConsensusV2DataRegion()` 返回 **false**，
ConfigNode 认为"这不是 V2 的 DataRegion"，**从不创建 consensus pipe**
（`buildConsensusPipeReq()` 的调用点都带这个前置判断）。

### 2.4 结果：静默失去冗余

| 观测面 | 现象 |
|---|---|
| DataNode 启动 | 正常（按 V2 运行） |
| 写入 / 查询 | 正常 |
| 副本数 | `show regions` 显示 2 个副本（`DataRF=2`） |
| **第二副本数据** | **从未收到任何 TsFile**（连目录都没有） |
| `syncLag` | **0（零延迟）** |
| ERROR / `error.log` | **0 条 / 0 字节** |
| CN 日志 `consensus pipe` | **0 条**（规范值下是 28 条） |

**唯一能发现异常的途径**：`show regions` 里第二副本的 `TsFileSize = Unknown`；或停掉有数据的副本做故障演练。

---

## 三、复现步骤

1. 6 个节点（3CN+5DN）的 `conf/iotdb-system.properties` 都写：

```properties
data_region_consensus_protocol_class=org.apache.iotdb.consensus.pipe.IoTConsensusV2
data_replication_factor=2
```

2. 清 `data`/`logs` 后启动，确认 8/8。
3. 建库写入 600 点（TEXT，4KB），执行 `flush;`。
4. 检查两个副本的 TsFile 数：

```bash
for h in 172.20.70.14 172.20.70.30; do
  ssh cluster@$h "sudo find /data/iotdb/<ver>/data/datanode/data -path '*root.f10*' -name '*.tsfile' | wc -l"
done
```

5. 再查 `show regions` 的 `TsFileSize` 列、`syncLag` 指标、CN 日志中 `consensus pipe` 的命中数。

---

## 四、实测对照（关键证据）

同一套集群、同一套步骤，**只改配置项的一处类名**：

| 配置值 | 70.14（leader） | 70.30（follower） | CN `consensus pipe` 命中 | 点数 |
|---|---|---|---|---|
| `...consensus.pipe.IoTConsensusV2` | 3 个（8552/9338/32611 B） | **0 个** | **0** | 600 |
| `...consensus.iot.IoTConsensusV2` | 3 个（8552/9338/32611 B） | **3 个（同尺寸）** | **28** | 600 |

另外，配错时还验证过：

1. 重启 follower —— 不补齐；
2. **全集群重启** —— 不补齐；
3. **显式 `flush;` 并等 3 分钟** —— 不触发复制；
4. 重启后的**新写入**同样不复制。

这些都只是"pipe 没建"的必然结果，**不是独立的产品缺陷**。

---

## 五、影响面

1. **不会丢数据、不影响读写**：数据完整写在 leader 副本上，可正常读写。
2. **静默失去冗余**：`DataRF=2` 实际只有 1 份数据；leader 所在节点故障即该 region 数据不可读，且剩余副本无法补齐。
3. **无任何告警**：ERROR=0、`syncLag=0`、`error.log` 0 字节。**这是最需要改进的点** —— 运维无法感知。
4. **触发条件**：仅当配置项写成 `...pipe.IoTConsensusV2`（或更旧的 `...pipe.PipeConsensus`）时命中。写规范值完全正常。

---

## 六、建议（按价值排序）

### 6.1 必做：ConfigNode 侧也做归一化（一行修复）

```java
private boolean isIoTConsensusV2DataRegion(TConsensusGroupId regionId) {
  return TConsensusGroupType.DataRegion.equals(regionId.getType())
      && ConsensusFactory.IOT_CONSENSUS_V2.equals(
             ConsensusFactory.normalizeConsensusProtocolClass(
                 CONF.getDataRegionConsensusProtocolClass()));
}
```

DataNode 已把 `LEGACY_*`/`REAL_*` 都当作合法输入，ConfigNode 不跟进就是**同一份配置被两处不同解读**，
属明显的实现不一致。修掉即可彻底消除本问题。

### 6.2 建议：启动时校验配置项并告警

`data_region_consensus_protocol_class` 落在 `pipe.*` 系列别名上时，启动日志应明确提示
"该值等价于 `iot.IoTConsensusV2`，但 ConfigNode 判定可能不生效"，或直接拒绝启动并给出正确值。

### 6.3 建议：副本数据就绪可观测

1. `TsFileSize=Unknown`（或为 0 而 leader 非 0）在启动后 N 分钟内未收敛，应打 ERROR 并将 region 标记为降级。
2. `syncLag` 在 pipe 未建立时应为 `-1`/`NaN`，而不是 0。

这一条对"配置写错"和"pipe 异常"都有效，价值独立于 6.1。

### 6.4 文档

`data_region_consensus_protocol_class` 的可选值应明确写"必须使用
`org.apache.iotdb.consensus.iot.IoTConsensusV2`"，并说明 `pipe.*` 别名存在但可能导致 ConfigNode 判定失效。

---

## 七、测试侧已修正的内容

| 位置 | 修正 |
|---|---|
| `lib/common.sh` 的 `mb_consensus_class()` | V2 类名从 `...pipe.IoTConsensusV2` 改为 `...iot.IoTConsensusV2`，并加注释说明原因 |
| `cases/common/mb_14_consensus_v2.sh` | 注释同步更正 |
| `cases/perf/p_05_consensus_v2.sh` | 协议回读断言改为规范值 |
| `docs/CALIBRATION.md` | 原先写的"包名是 pipe 不是 iot"是**错的**，已更正 |

> 该错误影响了 **MB-14**（V2 功能用例）与 **P-05**（V1 vs V2 性能对比）的既有结论：
> 两者都是在错误配置下跑的，**结论作废，需用正确配置重跑**。MB-14 已重跑，见 §八。

---

## 八、重跑结果

用正确配置（`...iot.IoTConsensusV2`）重跑 MB-14：

| 断言 | 结果 |
|---|---|
| ①5 个 DN 协议配置回读 = `org.apache.iotdb.consensus.iot.IoTConsensusV2` | **PASS** |
| ②V2 专属 `syncLag` 指标存在 | **PASS（14 条 series）** |
| ③自动刷盘发生 | **PASS** |
| 写入语句成功数 | **PASS（19 ≥ 1）** |
| ④数据点数正确 | **PASS（1200）** |
| **整体** | **RESULT PASS fail_flag=0** |

> 首次重跑曾出现"写入语句成功数=0、点数 260/1200"，写入 11 秒即中止。
> 单独复测该写入可正常完成（1200/1200，约 108 秒）；再整例重跑即 **PASS**。
> 故判定为**一次性执行中断**（本环境已知的 CLI/会话被杀问题），
> **不是产品缺陷、也不是配置问题**。

### 8.1 顺带确认：V2 写入速率与 V1 基本一致

同一份数据（1200 点 × 4KB，19 条语句）：

| 协议 | 总耗时 | 速率 |
|---|---|---|
| IoTConsensus（V1） | **108 s** | 11 点/s |
| IoTConsensusV2 | **110 s** | 11 点/s |

⇒ 慢的根源是**每点 4KB 的 payload + CLI 逐条语句串行提交**，与共识协议无关；V2 无额外退化。

### 8.2 补充：写入慢不是死锁、也不是内存不足

写入过程中对 3 个 DataNode 做了 3 轮在线采样：

| 观测 | 实测 |
|---|---|
| `jstack -l` 死锁检测 | **0**（无 `Found one Java-level deadlock`） |
| `Thread.State: BLOCKED` 线程数 | **0 / 0 / 0** |
| G1 堆使用 | 13.1 GB 中仅用 **250→390 MB（约 3%）** |
| 写入推进 | 25s→260 点、45s→520、65s→780、**110s→1200**（持续前进） |

⇒ 写入是**慢而匀速**，不是卡住；内存无压力，无锁竞争。

## 九、证据归档

| 文件 | 内容 |
|---|---|
| `docs/f10_logs.tgz` | 配错时的日志证据（各节点 ERROR=0、源码方法名 0 命中、节点日志尾部），用于说明"静默" |
| §四 的对照表 | 配置修正前后的 TsFile / CN 日志对比（本次实测） |

---

## 十、结论一句话

**V2 的复制功能正常；问题出在同一配置项被 DataNode（归一化）与 ConfigNode（不归一化）两种方式解读，
形成"能启动但没冗余"且完全静默的状态。** 建议 ConfigNode 补一次 `normalizeConsensusProtocolClass`，
并给副本就绪状态加可观测性。
