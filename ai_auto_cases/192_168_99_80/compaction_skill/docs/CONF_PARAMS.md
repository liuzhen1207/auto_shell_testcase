# 合并相关配置参数（conf 模板清单 + 本 skill 的验证方式）

来源：RC6 源码 `iotdb-core/node-commons/src/assembly/resources/conf/iotdb-system.properties.template`
（安装后即 `<DB_DIR>/conf/iotdb-system.properties.template`）。

| # | 参数 | 模板默认值 | 含义（源码注释摘要） | 本 skill 的验证 |
| --- | --- | --- | --- | --- |
| 1 | `enable_seq_space_compaction` | true | 顺序空间内部合并 | CO-09 负/正向、**CO-10 热加载** |
| 2 | `enable_unseq_space_compaction` | true | 乱序空间内部合并 | CO-03 场景开关、CO-10 热加载探针 |
| 3 | `enable_cross_space_compaction` | true | 跨空间合并（unseq → seq） | CO-04 场景开关、CO-10 热加载探针 |
| 4 | `enable_auto_repair_compaction` | true | 自动修复乱序文件 | CO-09 静态（模板存在性） |
| 5 | `cross_selector` | rewrite | 跨空间合并选择器 | CO-09 静态 |
| 6 | `cross_performer` | fast | 跨空间合并执行器 | CO-09 静态 |
| 7 | `inner_seq_selector` | size_tiered_multi_target | 顺序内部合并选择器 | CO-09 静态 |
| 8 | `inner_seq_performer` | read_chunk | 顺序内部合并执行器 | CO-09 静态 |
| 9 | `inner_unseq_selector` | size_tiered_multi_target | 乱序内部合并选择器 | CO-09 静态 |
| 10 | `inner_unseq_performer` | fast | 乱序内部合并执行器 | CO-09 静态 |
| 11 | `compaction_priority` | INNER_CROSS | 合并执行优先级（INNER_CROSS/CROSS_INNER/BALANCE） | CO-10 热加载探针 |
| 12 | `candidate_compaction_task_queue_size` | 50 | 候选任务队列长度 | CO-09 静态 |
| 13 | `target_compaction_file_size` | 2147483648 | 内部合并的目标文件大小（也约束 cross 候选文件大小 ≤ 1.5×） | CO-10 热加载探针 |
| 14 | `inner_compaction_total_file_size_threshold` | 10737418240 | 内部合并总文件大小上限 | CO-09 静态 |
| 15 | `inner_compaction_total_file_num_threshold` | 100 | 内部合并总文件数上限 | CO-09 静态 |
| 16 | `max_level_gap_in_inner_compaction` | 2 | 内部合并选择的最大层级差 | CO-09 静态 |
| 17 | `chunk_size_lower_bound_in_compaction` | 128 | 合并时 chunk 大小下限 | CO-09 静态 |
| 18 | `chunk_point_num_lower_bound_in_compaction` | 100 | 合并时 chunk 点数下限 | CO-09 静态 |
| 19 | `inner_compaction_candidate_file_num` | 30 | 触发内部合并的候选文件数 | **CO-09 负/正向**（100 → 不合并；2 → 合并）、CO-10 探针 |
| 20 | `max_cross_compaction_candidate_file_num` | 500 | cross 候选文件数上限 | CO-10 探针 |
| 21 | `max_cross_compaction_candidate_file_size` | 5368709120 | cross 候选总大小上限 | CO-09 静态 |
| 22 | `min_cross_compaction_unseq_file_level` | 1 | 可被 cross 选中的 unseq 文件最小层级 | **CO-04 负/正对照**（详见下方源码依据） |
| 23 | `compaction_thread_count` | 10 | 合并执行线程数 | CO-10 探针 |
| 24 | `compaction_max_aligned_series_num_in_one_batch` | 10 | 对齐序列每批合并的序列数 | CO-09 静态 |
| 25 | `compaction_schedule_interval_in_ms` | 60000 | 合并任务调度间隔 | **CO-09 生效值**（写 1000）、CO-10 探针 |
| 26 | `compaction_write_throughput_mb_per_sec` | 16 | 合并写限流 | CO-10 探针 |
| 27 | `compaction_read_throughput_mb_per_sec` | 0 | 合并读限流（0=不限） | CO-09 静态 |
| 28 | `compaction_read_operation_per_sec` | 0 | 合并读 IOPS 限流（0=不限） | CO-09 静态 |
| 29 | `sub_compaction_thread_count` | 4 | 子合并线程数（非对齐 cross / unseq 内部合并） | CO-10 探针 |
| 30 | `inner_compaction_task_selection_disk_redundancy` | 0.05 | 磁盘余量冗余（低于阈值时优先选含 mods 的任务） | CO-09 静态 |
| 31 | `inner_compaction_task_selection_mods_file_threshold` | 131072 | mods 文件大小阈值（超过则优先选） | CO-09 静态 |
| 32 | `compaction_schedule_thread_num` | 4 | 合并任务选择线程数 | CO-09 静态 |
| 33 | `target_chunk_point_num` | 100000 | 刷盘/合并时单 chunk 目标点数 | CO-09 静态 |
| 34 | `target_chunk_size` | 1600000 | 刷盘/合并时单 chunk 目标大小 | CO-09 静态 |
| 35 | `chunk_metadata_size_proportion` | 0.1 | 合并时 chunk 元数据常驻内存比例 | CO-09 静态 |

**验证方式说明**

- **静态**：CO-09 逐个断言 `conf/iotdb-system.properties.template` 里存在 `^<键>=` 行（35 项全覆盖）。
- **行为（负/正对照）**：`enable_seq_space_compaction` 与 `inner_compaction_candidate_file_num` 用"关掉/调大 → 不合并；
  打开/调小 → 合并"的对照证明参数真的生效（CO-09）。
- **热加载**：CO-10 对 10 个参数逐个 `SET CONFIGURATION` 并校验不变量
  「CLI 是否返回 `restart is required` ⇔ `show configuration` 的生效值是否立即变化」，
  并对 3 个 `enable_*` 开关做行为级验证（热关 → 不合并；热开 → **不重启**立即合并）。
- 未做行为级断言的参数（19~35 中的多数）只保证"模板存在 + 可写 + 生效值可读"，
  避免把环境相关的阈值/限流值写进硬判据；需要更细的行为验证时可在 CO-09 里扩展。

### `min_cross_compaction_unseq_file_level` 的源码依据（CO-04 的判据来源）

`RewriteCrossSpaceCompactionSelector.java:306`（master；2.0.12.1 同逻辑）：

```java
// we add a hard limit for cross compaction that selected unseqFile should reach a certain size
// or be compacted in inner space at least once. This is used to improve the priority of inne
// compaction and avoid too much cross compaction with small files.
if (unseqFile.getTsFileSize() < targetCompactionFileSize
    && unseqFileName.getInnerCompactionCnt() < config.getMinCrossCompactionUnseqFileLevel()) {
  return false;
}
```

⇒ 小 unseq 文件（size < `target_compaction_file_size`，默认 2GB）**必须**先被内部合并过一次
（文件名第 3 段 `innerCompactionCnt ≥ min_cross_compaction_unseq_file_level`，默认 1）才会被跨空间合并选中。
这解释了一个"看起来像缺陷"的现象：**只有 1 个 unseq 文件/region 时，跨空间合并永远不会发生**
（内部合并需要 ≥2 个文件才成任务 ⇒ 层级升不上去）。写跨空间合并用例时必须显式构造，
或者把 `min_cross_compaction_unseq_file_level` 设为 0（CO-04 的 B 相就是这么做的）。

### 「是否需要重启」是谁决定的（源码依据）

模板里每个键上方都有一行注释 `# effectiveMode: hot_reload` 或 `# effectiveMode: restart`
（`ConfigurationFileUtils.loadConfigurationDefaultValueFromTemplate`，模板解析见该类 L562~L590）。
`SET CONFIGURATION` 之后 CLI 是否提示 `restart is required`，取决于
`ConfigManager.setConfiguration`（confignode，L1893~1908）用
`ConfigurationFileUtils.getConfigurationEffectiveMode(key)` 查到的是 HOT_RELOAD 还是 RESTART：

- 35 个 compaction 键里，**只有 `compaction_schedule_interval_in_ms` 和 `compaction_priority` 是 `restart`**，
  其余 33 个都标了 `hot_reload`（`enable_*`、`*_selector`/`*_performer`、各种阈值/线程数…）。

### ⚠️ 一次事故 + 一次待复核的观察（2026-10-12，RC6，CO-10 首轮）

**事故（harness 自身的问题，已修）**：首轮 CO-10 探测完之后，`probe_hot` 用
`SET CONFIGURATION '<键>'='<原值>'` 还原，而有些键**原来根本不在 properties 里**（读到空字符串），
于是写成了 `compaction_priority=`、`compaction_thread_count=`、`target_compaction_file_size=` 这类**空值行**。
后果很重：

- DN 热加载直接报 `Fail to reload configuration because java.lang.NumberFormatException: For input string ""`
  和 `No enum constant ...CompactionPriority.`；
- **DN 重启后起不来**（`IoTDBDescriptor.loadProps` 抛异常），CO-10 收尾"停 1 个 DN 再起回来"时
  有两个 DN 一直没恢复 ⇒ 后续查询返回 `EMPTY`，CO-10 记了 13 条 FAIL，CO-11 也被拖累。

修法：① 原值为空时**不还原**（保留新值即可，新值都是合法值）；② 探测后重写一遍 conf 覆盖这些键；
③ `cluster_write_conf` 增加**空值守卫**：properties 里出现 `^[a-z_]+=$` 直接 `fail` 并打印行号；
④ 另写了 `tools/fix_broken_conf.sh` 用 `conf_orig` 还原被写坏的 properties。

**结论（复跑后更正）**：首轮那批"SET 成功但读不到新值"的数据**不可信**，根因就是上面的空值事故
（DN 热加载已经被空值写坏 ⇒ 后续 SET 全部无法应用）。把"空值不还原 + 写后重写 conf"修好之后复跑，
**10 个探针全部符合不变量**（RC6 实测，等待 0~1s 内生效）：

| 键 | 模板 effectiveMode | CLI 是否要求重启 | 生效值是否立即变 |
| --- | --- | --- | --- |
| `enable_seq_space_compaction` / `enable_unseq_space_compaction` / `enable_cross_space_compaction` | hot_reload | 否 | **是** |
| `target_compaction_file_size` | hot_reload | 否 | **是**（空 → 1073741824） |
| `compaction_thread_count` | hot_reload | 否 | **是**（空 → 8） |
| `compaction_write_throughput_mb_per_sec` | hot_reload | 否 | **是**（空 → 32） |
| `inner_compaction_candidate_file_num` | hot_reload | 否 | **是**（2 → 4） |
| `max_cross_compaction_candidate_file_num` | hot_reload | 否 | **是**（空 → 400） |
| `sub_compaction_thread_count` | hot_reload | 否 | **是**（空 → 2） |
| `compaction_schedule_interval_in_ms` | **restart** | **是** | 否（保持 1000）✓ |
| `compaction_priority` | **restart** | **是** | 否 ✓ |

⇒ **参数热加载功能正确**（与模板标注一致）；行为级证据另有 `enable_seq_space_compaction`
热关→写入不合并、热开→**不重启**立即合并。
**写用例的启示**：`SET CONFIGURATION` 一旦写坏（空值/非法值），后续所有热加载都会失败，
读回来的值会"看着像产品没生效"——先确认 properties 干净（`cluster_write_conf` 有空值守卫），再谈判定。

### 参数**组合**测试（CO-15 / CO-16）

单参数用例（CO-09/CO-10/CO-04）只能证明"某个键有作用"；参数之间的相互作用由 CO-15/CO-16 覆盖：

| 组合维度 | 取值 | 用例 | 判据 |
| --- | --- | --- | --- |
| 三类合并门控 | `enable_seq_space_compaction` × `enable_unseq_space_compaction` × `enable_cross_space_compaction` 的 **8 种开闭组合** | CO-15 段 1 | 逐组合断言"该跑的跑 / 不该跑的不跑"（按 `Sequence`/`Unsequence InnerSpaceCompaction` 与 `CrossSpaceCompaction` 分开计数）+ 指纹不变 |
| 合并优先级 | `compaction_priority` = INNER_CROSS / CROSS_INNER / BALANCE（restart） | CO-15 段 2 | 三种取值都必须完成 inner+cross 合并且数据一致；优先顺序按语义记录（竞态，仅 WARN） |
| 线程/限流/层级/上限 | `compaction_thread_count=1`、`sub_compaction_thread_count=1`、读/写限流=1、`max_level_gap_in_inner_compaction=1`、`inner_compaction_total_file_num_threshold=1`、`inner_compaction_task_selection_disk_redundancy=0.99` | CO-15 段 3 | 不得卡死、不得损坏数据（合并跑多快按实际记录）。注：`gap`/`文件数上限` 只在默认的 `multi_target` 实现下参与选择（见下方映射表），边界行为由 CO-17 专门覆盖 |
| inner seq 实现类 | `inner_seq_selector` ∈ {`size_tiered_single_target`,`size_tiered_multi_target`} × `inner_seq_performer` ∈ {`read_chunk`,`fast`} = 4 组（全热改） | CO-16 段 1 | 每组都要合并推进 + 指纹不变 |
| inner unseq 实现类 | `inner_unseq_selector` × `inner_unseq_performer` ∈ {`read_point`,`fast`} = 4 组（全热改） | CO-16 段 2 | 同上（⚠️ unseq 内部合并要求文件时间区间**重叠**，造场景时两批乱序数据必须重叠） |
| cross 执行器 | `cross_performer` ∈ {`read_point`,`fast`} | CO-16 段 3 | cross 推进 + 重叠区间取值正确 + 行数不变 |
| chunk 组合 | `target_chunk_size=4096`、`target_chunk_point_num=10`、`chunk_size_lower_bound_in_compaction=8192`、`chunk_point_num_lower_bound_in_compaction=1000`、`chunk_metadata_size_proportion=0.9`（restart） | CO-16 段 4 | 强制走"chunk 反序列化成点再写"的路径，合并仍完成且数据一致 |
| **非法值门禁** | `compaction_priority=BOGUS`、`inner_seq_selector=bogus`、`compaction_thread_count=abc`、`inner_compaction_candidate_file_num=-5` | CO-16 段 5 | 期望被拒绝；实测**未被拒绝**（见下方观察） |

**模板给出的合法取值**（`iotdb-system.properties.template` 的 `# Options:` 注释）：

| 键 | 合法取值 | effectiveMode |
| --- | --- | --- |
| `cross_selector` | `rewrite` | restart |
| `cross_performer` | `read_point`, `fast` | hot_reload |
| `inner_seq_selector` / `inner_unseq_selector` | `size_tiered_single_target`, `size_tiered_multi_target` | hot_reload |
| `inner_seq_performer` | `read_chunk`, `fast` | hot_reload |
| `inner_unseq_performer` | `read_point`, `fast` | hot_reload |
| `compaction_priority` | `INNER_CROSS`, `CROSS_INNER`, `BALANCE` | restart |
| `enable_auto_repair_compaction` | boolean | hot_reload |

#### ⚠️ 选择器取值 → 实现类（决定"哪些参数真的参与选择"）

源码 `storageengine/dataregion/compaction/selector/constant/InnerSequenceCompactionSelector.java:52-60`
（`InnerUnsequenceCompactionSelector` 同构；master 与 rc/2.0.12.1 一致）：

| `inner_seq_selector` 取值 | 实例化实现 | 会读哪些选择参数 |
| --- | --- | --- |
| `size_tiered_multi_target`（**模板默认值**） | `NewSizeTieredCompactionSelector` | `inner_compaction_candidate_file_num`、`inner_compaction_total_file_num_threshold`、`max_level_gap_in_inner_compaction`、`target_compaction_file_size`、`inner_compaction_total_file_size_threshold`（会**跨层级**合并） |
| `size_tiered_single_target` | `SizeTieredCompactionSelector`（经典） | 只有 `inner_compaction_candidate_file_num` + `target_compaction_file_size`（**不跨层级**、不看 gap/文件数上限） |

⇒ 名字的"multi/single target"指**一个任务是否可能产出多个目标文件**（新实现会按
`target_compaction_file_size` 把大任务切成多个产物），不是"多层级/单层级"。
**测 `max_level_gap_in_inner_compaction` / `inner_compaction_total_file_num_threshold` 时必须用默认的
`multi_target`**；用 `single_target` 时这两个键完全不参与选择（CO-17 第一版判据就是因为这个失败的）。

#### ⚠️ `show configuration` 只列"properties 文件里出现过的键"

实测：没写进 `iotdb-system.properties` 的键在 `show configuration`（表方言，第 3 列=当前值）里
读回来是**空串**（`cross_selector=`、`inner_compaction_total_file_num_threshold=`、
`enable_auto_repair_compaction=` 都出现过），`cmp_eff` 因此拿到空值。而 `SET CONFIGURATION`
会同时写文件 ⇒ SET 之后又能读到新值（哪怕新值等于默认值）。
写判据时：① 只对**自己写进 conf** 的键断言"生效值=写入值"；② 默认值场景改用行为判据。

### 已知行为（研发已确认，设计如此）：`SET CONFIGURATION` 不做取值校验

> 2026-10-13 研发反馈：*"设计的时候应该就是按不校验做的，有些不合法检查也没法提前判断出来；先记录为研发已知，设计如此。"*
> ⇒ **不作为缺陷跟踪**，只作为行为说明与使用/测试注意。完整版见
> `docs/NOTE_set_configuration_value_validation.md`。

实测（RC6）：

```
SET CONFIGURATION 'compaction_priority'='BOGUS'                → 成功（仅提示 restart is required），三节点 properties 均写入 BOGUS
SET CONFIGURATION 'inner_seq_selector'='bogus'                 → 报错 301，但三节点 properties 仍写入 bogus
SET CONFIGURATION 'compaction_thread_count'='abc'              → 报错 301，但三节点 properties 仍写入 abc
SET CONFIGURATION 'inner_compaction_candidate_file_num'='-5'   → 成功（无范围校验）
```

后果与**注意事项**（这才是用例要守的部分）：

- 非法值落盘后 **DN 重启在配置加载阶段 `System.exit(-1)`**，节点起不来
  （`No enum constant …CompactionPriority.BOGUS` / `NumberFormatException`）；
- **"报错" ≠ "没写进去"**：DN 侧是"先写文件、再热加载"（`StorageEngine` L790-807），
  返回 301 时文件已被改；
- 节点**离线**时收不到集群配置下发，**不能自愈**：必须手工改该节点 `iotdb-system.properties` 才能起来（已实测）；
- 所以用例里做非法值探针后必须**立刻改回合法值**并在段末校验无残留（CO-16 段 5 已实现），
  收尾的"逐个停/起 DN + 副本一致性"是隐式硬门禁。

源码位置（供参考）：`ConfigManager.setConfiguration`（confignode，写文件 + 热加载，只按模板 `effectiveMode` 提示重启）；
校验钩子 `validateConfigurationBeforeSet` 基类 `return null`（仅 Timecho 侧校验 `dn_rpc_max_concurrent_client_num` 一个键）；
DN 侧解析点在 `IoTDBDescriptor` L553-557 / L671-674 / L1840+。模板里的 `# Datatype:` / `# Options:`
注释本来就被 `ConfigurationFileUtils` 解析，若将来要加校验可直接复用。



### 参数"生效值"怎么读（实测踩坑）

`show configuration`（表方言）**只列出显式写在 `iotdb-system.properties` 里的键**：
35 个 compaction 键里只有 conf 里写过的 5 个能看到，其余 30 个不在返回结果里
（探测脚本 `tools/probe_showconf.sh`）。所以"生效值"断言只能针对显式写入的键；
其余键要靠**行为对照**（负/正向），或先 `SET CONFIGURATION` 再读。
另外：`ttl_check_interval` / `max_expired_time` / `expired_data_ratio` 这三个键在
`cluster_write_conf` 里是**用 env 值逐节点校验**的，必须通过环境变量覆盖
（`export TTL_CHECK_INTERVAL_MS=5000`），写进 `EXTRA_CONF` 会被判"写入不匹配"。
