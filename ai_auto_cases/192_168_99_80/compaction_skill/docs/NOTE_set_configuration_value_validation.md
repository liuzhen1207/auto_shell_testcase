# 说明（NOTE）：`SET CONFIGURATION` 不做取值校验 —— **研发已确认，设计如此**

> 结论更新时间：2026-10-13（研发反馈：*"这个只能说设计的时候应该就是按不校验做的，有些不合法检查也没法提前判断出来，"
> "这个先记录为研发已知，设计如此"*）
> ⇒ **不作为缺陷跟踪**，本文件只作为"行为说明 + 使用/测试注意事项"留档。
> 发现版本：TimechoDB 2.0.12.1 / RC6 `v20121rc6_1010_7ae8713e`（`7ae8713`），3C3D + `IoTConsensus`。

## 1. 行为（已确认，按现状记录）

`SET CONFIGURATION '<key>'='<value>'` 在写入前**不校验取值**：

| 探针 | CLI 返回 | 是否写进各节点 properties | 之后 DN 重启 |
| --- | --- | --- | --- |
| `compaction_priority=BOGUS` | **成功**（只提示 `restart is required`） | 是（三节点） | **起不来**：`No enum constant …CompactionPriority.BOGUS` + `System.exit(-1)` |
| `inner_seq_selector=bogus` | 报错 301（`IllegalCompactionSelectorNameException`） | **是**（报错也落盘） | **起不来** |
| `compaction_thread_count=abc` | 报错 301（`NumberFormatException`） | **是**（报错也落盘） | **起不来** |
| `inner_compaction_candidate_file_num=-5` | 成功、无报错 | 是 | 可启动（无范围校验，负数被接受） |

要点：
1. **"报错" ≠ "没写进去"**：DN 侧是"先写文件、再热加载"，热加载失败返回 301，但文件已被改；
2. 非法值经集群配置下发写进**所有**节点，`SET` 一次影响全集群；
3. 节点**离线**后收不到后续配置下发，无法自愈 —— 只能手工改该节点的 `iotdb-system.properties` 才能起来（已实测）。

## 2. 使用注意事项（运维/测试）

- 不要用枚举名/数字键做"试错式"配置下发；写错了要**逐节点**检查
  `grep -nE '^<key>=' conf/iotdb-system.properties` 并手工修正（含被 `#` 注释掉的历史行不必管）。
- 改动生产线配置前先确认取值来源（模板 `iotdb-system.properties.template` 的
  `# Datatype:` / `# Options:` 注释就是权威取值集合）。
- 一旦某个 DN 因非法配置起不来：**停掉它 → 手工改回合法值 → 再启动**；
  不要在它离线时反复 SET 期望它自己恢复。

## 3. 源码位置（供后续需要时参考）

| 环节 | 位置 | 说明 |
| --- | --- | --- |
| SET 入口（CN） | `confignode/.../manager/ConfigManager.java` **L1837** `setConfiguration`；**L1882** `ConfigurationFileUtils.updateConfiguration(file, props, merged -> loadHotModifiedProps(merged))`（先写文件再热加载）；**L1893-1908** 只按模板 `effectiveMode` 拼 `restart is required` | 设计上不做取值校验 |
| 校验钩子（留有空位） | 同上 **L1961-1963** `validateConfigurationBeforeSet(...) { return null; }`；唯一实现 `timecho-confignode/.../TimechoConfigManager.java:665`（只校验 `dn_rpc_max_concurrent_client_num`） | 若将来要加校验，这里就是入口 |
| DN 落盘 | `datanode/.../storageengine/StorageEngine.java` **L790-807** | 先写文件，callback 热加载失败 → 返回 301（文件已污染） |
| 启动失败点 | `datanode/.../conf/IoTDBDescriptor.java` **L164-180** | 加载配置异常 → `System.exit(-1)`（无回落） |
| 取值解析点 | `IoTDBDescriptor.java` **L553-557**（`CompactionPriority.valueOf`）、**L671-674**（`int` 解析）、**L1840+**（`inner_compaction_candidate_file_num`，无范围校验）；`.../selector/constant/*Selector.java`、`.../performer/constant/*Performer.java` | 非法值在这里炸 |

> 附：模板里每个键上方的 `# Datatype:` / `# Options:` 注释**已经被** `ConfigurationFileUtils.loadConfigurationDefaultValueFromTemplate`
> 解析（用于 `effectiveMode`）——如果哪天决定要加取值校验，直接复用这两项元数据即可，无需额外维护一份白名单。

## 4. 测试侧约束（本 skill 已实现）

因为"非法值会被接受且落盘"，用例**不能**把它当断言前提，必须保证自己不留脏数据：

- **CO-16 段 5「非法值门禁」**（`cases/common/co_param_selector.sh`）：
  ① 每个探针**记录 CLI 原始返回**并原样打进日志（当前实测：`compaction_priority=BOGUS`、
  `inner_compaction_candidate_file_num=-5` 返回成功；selector/线程数返回 301）；
  ② 探针后**立刻 `SET` 回合法值**（原值为空时写模板默认的合法值，绝不写空值）；
  ③ 段末逐节点校验 `grep -cE '^[a-z_]+=(BOGUS|bogus|abc|-5)$'` 必须为 0（只查未注释行——
  `SET` 覆盖旧值是"注释掉旧行 + 追加新行"）；
  ④ 收尾的"逐个停/起 DataNode + 副本一致性"本身就是**隐式硬门禁**：只要有残留非法值，DN 就起不来，
  一致性校验必然 FAIL。
- 受控复现脚本（含 DN 起不来与手工恢复全过程）：`tools/repro_set_bad_value.sh`；
  本次证据原文：`evidence/repro_bad_value.out`。
