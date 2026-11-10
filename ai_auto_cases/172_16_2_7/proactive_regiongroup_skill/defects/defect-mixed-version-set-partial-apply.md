# 缺陷报告：混合版本集群 SET CONFIGURATION 部分应用（Leader 已生效、返回失败、旧 CN 未生效）

| 项 | 内容 |
| --- | --- |
| 编号 | 待分配（建议 P1/P2） |
| 标题 | 混合版本集群执行 `SET CONFIGURATION ...='PROACTIVE'`，旧 ConfigNode 报错但新 Leader 已应用配置，集群配置不一致 |
| 版本 | 2.0.13.1 RC1 `ab6d3de`（新）+ 2.0.12.1 RC12 `c05111d`（旧） |
| 环境 | 3C5D：CN .8/.9 为 2.0.13.1，CN .10 为 2.0.12.1；DN 混合 |
| 严重级别 | 高（配置漂移、行为不一致，客户端收到失败但实际已生效） |
| 发现时间 | 2026-11-06，升级验证 PGC-09/PGC-58 |
| 状态 | 待修复/待产品确认 |

## 1. 复现步骤

1. 搭建混合版本集群：2 个 CN 升级到 2.0.13.1，保留 1 个 CN 为 2.0.12.1；
2. 连接任意节点执行：
   ```sql
   SET CONFIGURATION 'data_region_group_extension_policy'='PROACTIVE';
   ```
3. 观察返回结果；
4. 执行 `SHOW CONFIGURATION` 查看生效值；
5. 继续写入新 slot，观察扩容行为。

## 2. 实际结果

返回失败：

```text
Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 301:
[TSStatus(code:301, message:DataRegionGroupExtensionPolicy PROACTIVE doesn't exist.)]
```

但随后 `SHOW CONFIGURATION` 显示：

```text
| data_region_group_extension_policy | PROACTIVE | PROACTIVE |
```

且后续扩容按 PROACTIVE 行为执行（新建库 9 slot 建到 cap）。

即：**客户端收到失败，但 Leader 已生效，旧 CN 未生效**。

## 3. 预期结果

二选一：

1. 整体失败且所有节点保持原值（强一致）；或
2. 返回“部分成功”并明确列出未生效节点，不能只返回失败却已修改 Leader。

不应出现“返回失败 + Leader 已生效 + 旧节点未生效”的静默不一致。

## 4. 根因分析（源码）

### 4.1 SET CONFIGURATION 是“先本地、后广播”，没有回滚

`ConfigManager.setConfiguration`（`ConfigManager.java:1951`）流程：

1. `validateConfigurationBeforeSet(req)`：仅校验值本身；
2. `ConfigurationFileUtils.updateConfiguration(...)` 写本地配置文件；
3. `ConfigNodeDescriptor.getInstance().loadHotModifiedProps(...)`：**Leader 内存配置立即生效**；
4. `handleRegionGroupConfigHotReload(...)`（`ConfigManager.java:2158`）：立即执行 `adjustMaxRegionGroupNum()` 和策略表 rebalance，**行为立即改变**；
5. 之后才广播：
   ```java
   // ConfigManager.java:2071
   List<TSStatus> statusListOfOtherNodes = nodeManager.setConfiguration(req);
   ...
   TSStatus status = RpcUtils.squashResponseStatusList(statusList); // 2075
   ```
6. 聚合失败后**直接返回错误，没有恢复第 2~4 步的本地修改**。

### 4.2 旧 CN 解析失败

`NodeManager.setConfiguration`（`NodeManager.java:1373`）向其他 CN 发送 `TSetConfigurationReq(configs, APPLY_CONFIG_LOCALLY)`（`NodeManager.java:1433`）。

旧版本 2.0.12.1 的 `RegionGroupExtensionPolicy` 枚举没有 `PROACTIVE`，`RegionGroupExtensionPolicy.parse`（`RegionGroupExtensionPolicy.java:49`）抛出：

```java
throw new IOException(String.format(
    ManagerMessages.DATAREGIONGROUPEXTENSIONPOLICY_DOESN_T_EXIST, policy));
```

即 `DataRegionGroupExtensionPolicy PROACTIVE doesn't exist.`，旧 CN 返回 301。

### 4.3 结果

`squashResponseStatusList` 把 301 返回给客户端，但 Leader 侧第 2~4 步已生效 → **部分应用**。

## 5. 影响

1. 配置漂移：不同 CN 的 `SHOW CONFIGURATION` 与行为不一致；
2. 客户端收到失败后可能重试或回滚，实际配置已被修改，造成二次不一致；
3. 若旧 CN 之后成为 Leader，可能按旧值执行扩容/重平衡，导致组数与预期不符；
4. 升级窗口内运维误判“配置未生效”，重复操作。

## 6. 修复建议

1. **前置兼容性检查**：广播前检查所有 CN 版本/策略枚举支持，发现混合版本直接拒绝，不修改本地；
2. **先远端、后本地**：先收集其他 CN 的应用结果，全部成功后再应用 Leader 本地；
3. **失败回滚**：聚合失败时恢复本地配置（`loadHotModifiedProps(previous)` + 重写文件），并撤销 `handleRegionGroupConfigHotReload` 的副作用（`adjustMaxRegionGroupNum`/rebalance）；
4. **返回部分成功**：若产品允许部分应用，返回明确的 per-node 状态，而不是笼统 301。

## 7. 证据

- 返回：`301 DataRegionGroupExtensionPolicy PROACTIVE doesn't exist.`
- `SHOW CONFIGURATION` 第一列（生效值）：PROACTIVE
- `show cluster`：CN0/1 为 2.0.13.1，CN2 为 2.0.12.1
- 升级与混合版本记录：[PGC-09-upgrade-result.md](PGC-09-upgrade-result.md)

## 8. 关联用例

- PGC-09 升级场景（发现）
- PGC-58 混合版本下写 PROACTIVE 配置
- PGC-77 配置热更新时 Leader 切换（同类一致性风险）
