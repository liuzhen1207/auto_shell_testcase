# 根因分析（RCA）：IoTConsensusV2 副本复制通道未建立

> 分析方式：**基于在线集群实测取证**（不只是读源码）。
> 环境：TimechoDB 2.0.12.1 / RC9 `d206dc2`，3 ConfigNode + 5 DataNode，`data_replication_factor=2`，`iot_consensus_v2_mode=batch`（默认）。
> 日期：2026-10-22　验证人员：刘珍

---

## 一、结论先行

**根因**：`data_region_consensus_protocol_class` 的**归一化只做了两条路径，唯独"ConfigNode 判定该 region 是否为 V2"这条路径没做**。

结果：当配置值是非规范写法（`org.apache.iotdb.consensus.pipe.IoTConsensusV2` 或更旧的
`org.apache.iotdb.consensus.pipe.PipeConsensus`）时——

- **DataNode 侧归一化成功**，按 V2 正常运行；
- **ConfigNode 侧判定失败**，认为"这不是 V2 的 DataRegion"，**从不创建 consensus pipe**；
- 于是 V2 的写路径（只写本地 state machine）+ 缺失的 pipe ⇒ **副本之间没有任何数据传输通道**；
- 全程**没有 ERROR、没有相关 WARN**，`syncLag` 反而报 0。

一句话：**同一份配置被两处以不同方式解读，导致"节点都在按 V2 跑，但复制链路根本没搭"。**

---

## 二、在线取证：三个状态的对照

同集群、同步骤，只改 `data_region_consensus_protocol_class` 一处：

| 观测项 | ① 规范值 `iot.IoTConsensusV2` | ② 别名 `pipe.IoTConsensusV2` | ③ 旧别名 `pipe.PipeConsensus` |
|---|---|---|---|
| DN 是否按 V2 运行（`iot_consensus_v2` 指标行数） | 有 | 有 | **21 行（说明按 V2 起来了）** |
| CN 日志 `consensus pipe` 命中 | **4（提交创建）** | **0** | **0** |
| `show pipes` | **2 条 `__consensus.*`，RUNNING** | **Empty set** | **Empty set** |
| CN 归一化告警命中 | — | **0** | **0** |
| 两个副本 TsFile | **完全一致（各 3 个）** | 仅 leader 有（3 / 0） | 仅 leader 有 |
| 数据可读性 | 正常 | 正常（leader 在线时） | 正常（leader 在线时） |

### 2.1 正常状态（①）的正面证据

CN 日志出现明确的 pipe 提交记录：

```
2026-10-22 16:32:41,278 [ProcedureCoreWorker-4] INFO ProcedureManager:1577
  - Submitted async consensus pipe creation: __consensus.DataRegion[1]_3_5
2026-10-22 16:32:41,278 [ProcedureCoreWorker-4] INFO RegionMaintainHandler:773
  - [REGION_MIGRATE_PROCESS], Submitted async consensus pipe creation: __consensus.DataRegion[1]_3_5
2026-10-22 16:32:41,282 ... __consensus.DataRegion[1]_5_3（反向）
```

`show pipes` 能看到它们（**这就是诊断根因的关键入口**）：

```
|__consensus.DataRegion[1]_3_5| 2026-10-22T16:32:41.289 | RUNNING |
  extractor.consensus.sender-dn-id=3, receiver-dn-id=5, extractor.realtime.mode=batch ...
|__consensus.DataRegion[1]_5_3| 2026-10-22T16:32:41.459 | RUNNING |
  sender-dn-id=5, receiver-dn-id=3 ...
```

即：一个 V2 的 DataRegion 应有 **2 条双向 `__consensus.*` pipe**（`a_b` 与 `b_a`）。

### 2.2 异常状态（②③）的静默证据

- CN 日志 `consensus pipe` **命中 0**（连"尝试创建"都没有，因为判定直接返回 false，代码路径没进去）；
- `show pipes` **Empty set**；
- CN WARN 总计仅 2 条，**都与 pipe 无关**（一条是 Ratis 配置回显，一条是下述"leader 未确定"）；
- **没有出现** `SYSTEMPROPERTIES_NORMALIZE_FROM_TO_FOR_COMPATIBILITY` 归一化告警。

唯一的间接线索是这条 WARN（实测在旧别名场景出现）：

```
WARN LoadCache:882 - [RegionElection] The leader of RegionGroups:
  [TConsensusGroupId(type:DataRegion, id:1)] is not determined
```

> 这与之前观察到的"`show regions` 里两个副本 Role 都是 Follower、没有 Leader"一致 ——
> 因为 leader 的确定依赖复制通道，通道不存在就选不出来。

---

## 三、代码层面的完整因果链

### 3.1 三个类名常量与归一化函数

`iotdb-core/consensus/.../ConsensusFactory.java`

```java
42  public static final String LEGACY_IOT_CONSENSUS_V2 = "org.apache.iotdb.consensus.pipe.PipeConsensus";
44  public static final String REAL_IOT_CONSENSUS_V2   = "org.apache.iotdb.consensus.pipe.IoTConsensusV2";
46  public static final String IOT_CONSENSUS_V2        = "org.apache.iotdb.consensus.iot.IoTConsensusV2"; // 规范值

// 设计意图（源码注释原文）：
//   Downstream code compares against IOT_CONSENSUS_V2 directly, so persisted legacy names must be
//   normalized to the canonical constant before they fan out.
public static String normalizeConsensusProtocolClass(String className) {
  if (LEGACY_IOT_CONSENSUS_V2.equals(className) || REAL_IOT_CONSENSUS_V2.equals(className)) {
    return IOT_CONSENSUS_V2;
  }
  return className;
}
```

注释把要求写得非常明确：**"下游代码直接拿 `IOT_CONSENSUS_V2` 做比较，因此旧名必须在扩散前被归一化"**。

### 3.2 路径 A：DataNode —— 归一化了 ✅

```java
// ConsensusFactory.getConsensusImpl()
className = normalizeConsensusProtocolClass(className);   // ← 归一生效
if (IOT_CONSENSUS_V2.equals(className)) {
  className = REAL_IOT_CONSENSUS_V2;                      // 映射到真正实现类
  IoTV2GlobalComponentContainer.build();
  IoTConsensusV2SyncLagManager.build();
}
```

⇒ 配别名时 DataNode 依然加载 V2 实现、注册 `syncLag` 指标、暴露 `replicateMode=2`。**看起来一切正常。**

### 3.3 路径 B：ConfigNode 持久化属性 —— 归一化了 ✅

`SystemPropertiesUtils`（约 L128-170）：

```java
// Only the data region protocol could have been persisted as the old PipeConsensus name
// during a jar-only upgrade, so only that field needs compatibility normalization.
String persistedDataRegionConsensusProtocolClass = systemProperties.getProperty(DATA_CONSENSUS_PROTOCOL, null);
String dataRegionConsensusProtocolClass =
    ConsensusFactory.normalizeConsensusProtocolClass(persistedDataRegionConsensusProtocolClass);
if (!Objects.equals(persistedDataRegionConsensusProtocolClass, dataRegionConsensusProtocolClass)) {
  systemProperties.setProperty(DATA_CONSENSUS_PROTOCOL, dataRegionConsensusProtocolClass);
  LOGGER.warn(ConfigNodeMessages.SYSTEMPROPERTIES_NORMALIZE_FROM_TO_FOR_COMPATIBILITY, ...);
}
...
conf.setDataRegionConsensusProtocolClass(dataRegionConsensusProtocolClass);
```

⇒ **只看 `data/system.properties` 里持久化的那个值**，且带 WARN。

### 3.4 路径 C：ConfigNode 判定 V2 region —— **没有归一化** ❌

`RegionMaintainHandler.java`

```java
676  private boolean isIoTConsensusV2DataRegion(TConsensusGroupId regionId) {
677    return TConsensusGroupType.DataRegion.equals(regionId.getType())
678        && IOT_CONSENSUS_V2.equals(CONF.getDataRegionConsensusProtocolClass());   // ★ 直接比原始字符串
679  }
```

而 `CONF` 的值来自**配置文件原样读取**，不做归一化：

```java
// ConfigNodeDescriptor
conf.setDataRegionConsensusProtocolClass(
    properties.getProperty("data_region_consensus_protocol_class",
                           conf.getDataRegionConsensusProtocolClass()));   // 无 normalize
```

⇒ 只要配置文件里写的是别名，`isIoTConsensusV2DataRegion()` 就返回 **false**。

### 3.5 判定失败后的连锁反应

`buildConsensusPipeReq()` 的两个调用点都带前置判断：

```java
490  public void createConsensusPipesForAddPeer(...) {
492    if (!isIoTConsensusV2DataRegion(regionId)) { return; }   // ← 直接返回，无日志

561  // 另一个调用点同样先判 isIoTConsensusV2DataRegion(regionId)
```

于是 `createSingleConsensusPipe()` / `createSingleConsensusPipeAsync()` **根本不会被调用**，
`__consensus.DataRegion[x]_a_b` pipe 不存在。

### 3.6 最终表现

V2 的写路径（`IoTConsensusV2ServerImpl.write()`，L142-166）只做 `stateMachine.write(request)`
就返回成功，**不等任何副本确认**；复制完全依赖 pipe。

pipe 不存在 ⇒

| 环节 | 表现 |
|---|---|
| 写入 | 成功（本地 memtable） |
| 刷盘 | 正常（leader 上生成 TsFile） |
| 复制 | **不存在通道** |
| follower | 永远为空（连 `root.<db>` 目录都没有） |
| 查询 | 正常（只要 leader 在线） |
| `syncLag` | **0**（读的是不存在的 pipe 的进度） |
| ERROR / error.log | **0 条 / 0 字节**（没有任何代码"失败"，只是没被调用） |

---

## 四、为什么在线环境会踩到（触发场景）

1. **按 jar 里的类名配置**：`org.apache.iotdb.consensus.pipe.IoTConsensusV2` 是 jar 内真实存在的类，
   运维/实施查 jar 后照着写是非常自然的做法 —— 但配置项要求的是 `...iot.IoTConsensusV2`。
2. **从旧版本沿用配置**：`pipe.PipeConsensus` 是源码明确保留的旧名。
   源码只对"持久化在 `system.properties` 里的旧名"做了归一化；
   若该值写在**配置文件** `iotdb-system.properties` 里（或运维照旧文档填写），就不会被归一化。
3. **手工/脚本批量改配置**：直接用 sed 写入别名，绕过了任何校验。

以上三种都会导致：**集群看起来完全正常，实际只有一个副本有数据。**

---

## 五、故障识别方法（给运维/测试用）

按可靠性排序：

| # | 检查项 | 正常 | 异常 |
|---|---|---|---|
| 1 | **`show pipes;`** 是否含 `__consensus.*` | 每个 V2 DataRegion **2 条**（`a_b`、`b_a`），状态 RUNNING | **Empty set** |
| 2 | `show regions;` 第二副本 `TsFileSize` | 与 leader 同量级 | **`Unknown`** |
| 3 | CN 日志 `Submitted async consensus pipe creation` | 建库/建 region 时出现 | **无** |
| 4 | CN 日志 `[RegionElection] The leader ... is not determined` | 不应长期出现 | 反复出现 |
| 5 | `syncLag` 指标 | 0 | **也是 0 —— 不可作为健康依据** |
| 6 | ERROR / `log_*_error.log` | — | **均为 0 —— 不可依赖** |

> 第 1 条最直接：**`show pipes` 里没有 `__consensus.*`，就说明 V2 的复制通道没搭起来。**
> 本次分析中我最初看到 `show pipes` 为空，却误判为"V2 的 pipe 不在 show pipes 中暴露"，
> 从而把方向带偏 —— 这个信号本身是准确的，是我解读错了。

---

## 六、修复建议

### 6.1 一行修复（消除根因）

```java
private boolean isIoTConsensusV2DataRegion(TConsensusGroupId regionId) {
  return TConsensusGroupType.DataRegion.equals(regionId.getType())
      && ConsensusFactory.IOT_CONSENSUS_V2.equals(
             ConsensusFactory.normalizeConsensusProtocolClass(
                 CONF.getDataRegionConsensusProtocolClass()));
}
```

这正好落实源码注释里那句"persisted legacy names must be normalized to the canonical constant
before they fan out" —— 目前 fan out 到 region 判定这一步漏了。

### 6.2 配置读取时统一归一化（更彻底）

在 `ConfigNodeDescriptor` 读到该字段时就归一化并回写，使 `CONF` 内部只保存规范值，
下游所有比较自然一致。建议同时打一条 INFO 说明"已将 X 归一化为 Y"。

### 6.3 启动自检（防静默）

启动完成后校验：若 `data_replication_factor > 1` 且 V2 模式下某 DataRegion 的 `__consensus.*` pipe
数量不足（应为 `2 × (副本数-1)` 量级），则打 **ERROR** 并将该 region 标记降级。

### 6.4 `syncLag` 语义

pipe 不存在时不应上报 0，应上报 `-1`/`NaN` 或直接缺失。

### 6.5 文档

明确写出配置项**只接受** `org.apache.iotdb.consensus.iot.IoTConsensusV2`，
并说明 `pipe.*` 两个名字虽然存在于 jar / 源码常量中，但不应写入配置文件。

---

## 七、本次分析的自我修正记录

| 阶段 | 曾有过的错误判断 | 实际 |
|---|---|---|
| 初判 | "V2 复制功能失效（P0）" | V2 复制正常，是配置类名导致 pipe 未创建 |
| 对空 `show pipes` | "V2 的 pipe 不通过 show pipes 暴露" | **错误**。正确配置下能正常显示 `__consensus.*`，空 = 没建 |
| 对重启/刷盘/全量重启 | 当作 3 个独立证据 | 都是"pipe 没建"的同一个必然结果 |
| 严重级别 | P0 | **P2**（配置一致性 + 可观测性；不丢数据、不影响读写） |

**方法论教训**：出现"副本完全没有数据"这种极端结果时，应先怀疑配置/环境，
并用最小对照（只改一个变量）验证，再下缺陷结论；同时应优先采用产品自带的诊断入口（`show pipes`）。

---

## 八、附：本次取证脚本要点

```bash
# 1) 建库，触发 region 与 pipe 创建
start-cli.sh -h <cn> -p 6667 -u root -pw <pwd> -e "create database root.rca;"

# 2) 关键诊断：是否出现 __consensus.* pipe
start-cli.sh ... -e "show pipes;"

# 3) CN 是否提交了 pipe 创建
grep -iE "consensus pipe" <dn_dir>/logs/log_confignode_all.log

# 4) 两个副本是否都有数据
for h in <dn_a> <dn_b>; do
  ssh $h "sudo find <dn_dir>/data/datanode/data -path '*root.rca*' -name '*.tsfile' | wc -l"
done
```
