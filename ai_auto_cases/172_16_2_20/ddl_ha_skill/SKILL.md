# SKILL — DDL 高可用验证方法

## 1. 需求本质

集群模式下，元数据操作（表模型的 DDL）由 ConfigNode 的 procedure 驱动、依赖 DataNode 上的 SchemaRegion 副本执行。旧行为：只要有一台 DN 宕机、或某个 DN 与 CN 失联，procedure 就会失败并回滚。新需求：

1. **DN 宕机（未达多数派）时 DDL 仍成功**；
2. **DN 网络分区时**，正常 DN 上执行成功；连到分区 DN 的客户端得到明确的隔离提示；
3. DN 与 CN 失联超过 `metadata_lease_fence_ms`（默认 20s）后**自我隔离**，不再提供服务；
4. 删除类 procedure 在"副本多数不可用"时允许失败，但必须**不回滚 + 用户可感知**，且后续访问给出"正在被删除"的提示。

## 2. 每轮固定流程

```
重置集群(wipe+start, 8/8) → setup SQL → 注入故障 → 等待触发条件 → 执行受测 DDL
  → 恢复故障(重启 DN / 解分区 / 重启 CN) → 等 8/8 → 三项校验 → 判定
```

关键点：

1. **必须恢复故障后再校验**。宕机用例若直接校验，会把"DN 不可达"误判成元数据/数据不一致（本次调试即踩过）。
2. 分区用例要等 **> `metadata_lease_fence_ms`**（这里等 25s），否则测的是"还没隔离"的中间态。
3. 每轮独立重置，避免上一轮的库表残留影响 `SHOW TABLES` 比对。

## 3. 故障注入

| 类型 | 手段 | 目标选择 |
| --- | --- | --- |
| `dn_kill` | `pkill -9` DataNode | `SHOW REGIONS` 里该库 SchemaRegion 的一个副本 DN |
| `dn_partition` | 目标 DN 上 iptables 阻断与 3 台 CN 的 **10710** 双向流量（放行 SSH） | 同上 |
| `cn_leader_kill` | 杀当前 CN leader | `SHOW CONFIGNODES` 中 Role=Leader |
| `dr_both_down` | 杀该表 DataRegion 的**两台**副本 | `SHOW REGIONS` 中该库 DataRegion 的 DN 列表 |
| `full_restart` | DDL 后整集群 stop+start（不 wipe） | — |

> 分区只阻断 CN 端口，不阻断 DN 之间的 6667/10730，避免把"CN 失联"和"副本失联"混在一起。

## 4. 三项校验

1. **元数据一致性**：每台 DN 执行 `SHOW TABLES FROM db`、`SHOW CREATE TABLE db.t`（以及视图），归一化后 5 台必须完全一致；再按用例期望判"表/视图/列/TTL/设备"是否符合。
2. **数据一致性**：每台 DN 执行 `count(*)` 与 `GROUP BY dev`，5 台必须一致（DR=2，两台副本都读）。
3. **日志扫描**：6 台节点最近 4000 行里的 ERROR，白名单外计 `LOG_SUSPECT`。白名单包含故障注入的预期噪声：`Failed to ... on DataNode`（CN 重试已宕 DN）、`LeaderBalancer`/`CHANGE_REGION_LEADER`（leader 迁移）、`some other task is operating ... please retry`（procedure 串行）。

## 5. 判定码

| 判定 | 含义 |
| --- | --- |
| `PASS` | SQL 符合预期 + 元数据一致 + 数据一致 + 日志无白名单外异常 |
| `FAIL_SQL` | 期望成功但 DDL 报错 |
| `FAIL_NO_ERROR` | 期望失败但 DDL 成功 |
| `FAIL_ERROR_KIND` | 失败但报错不是隔离类（分区 DN 用例要求提到隔离/无法连接） |
| `FAIL_META` / `FAIL_DATA` | 5 台 DN 元数据 / 数据不一致 |
| `FAIL_EXPECT` | 期望对象未达成（表/列/TTL/设备） |
| `FAIL_LOG` | 日志出现白名单外 ERROR |

## 6. 已知坑

1. `ALTER VIEW <db>.v RENAME TO v2` —— 目标名**不能带库前缀**，否则语法错误。
2. `DROP DATABASE` 紧跟在表级 DDL 后会返回 `304: Some other task is operating table under the database ... please retry`，属 procedure 串行，用例里要么等待、要么单独起一轮。
3. `DROP VIEW` 的 `schema_cascade=true` 在"表先存在、后建视图"的场景下**不会**删掉原表（与文档表述不一致，`DDLHA-N-009` 专门记录实际行为）。
4. 分区 DN 上的元数据操作**不一定**抛"隔离"异常，可能长时间卡在联系 CN（实测 423 秒）后返回 301 或 305 —— 研发 2026-11-11 确认为符合预期，`DDLHA-P-002` 只断言"失败"，不再要求隔离文案。
