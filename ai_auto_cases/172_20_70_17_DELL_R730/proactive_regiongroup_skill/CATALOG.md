# RegionGroup 积极扩容（PROACTIVE）用例目录

- 用例总数：**216**（原 217，`PG-REB-08` 与 REB-01 完全同构、已删除）
- 族模块：cases_cfg(18), cases_dev(22), cases_msr(28), cases_lim(34), cases_ops(26), cases_ops2(20), cases_swch(20), cases_upg(16)
- 扩容参数（本轮 conf 写入值）：`schema_region_group_extension_policy=PROACTIVE`，`data_region_group_extension_policy=PROACTIVE`，`default_schema_region_group_num_per_database=1`，`default_data_region_group_num_per_database=2`，`schema_region_per_data_node=3`，`data_region_per_data_node=0`，`series_slot_num=1000`，`time_partition_interval=604800000`

## 冒烟（6 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-SMK-01 | P0 | tree | 未显式配置时默认策略即 PROACTIVE（默认值路径） | smoke |
| PG-SMK-02 | P0 | tree+table | 空库不预建 RegionGroup（树+表） | smoke |
| PG-SMK-03 | P0 | tree | 单设备单测点：Schema/Data 各 1 组且数据可查 | smoke |
| PG-SMK-04 | P0 | tree | 树模型 4 个不同 slot 逐个增长到 min(K, 上限) | smoke |
| PG-SMK-05 | P0 | table | 表模型 4 个不同 slot 逐步扩容（与树同口径） | smoke |
| PG-SMK-06 | P0 | tree | 热加载 PROACTIVE→AUTO 保留已有组、切回后继续扩容 | smoke |

## 空库（12 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-EMPTY-05 | P0 | tree | drop 全部库后重建同名库不残留映射 | — |
| PG-EMPTY-01 | P0 | tree+table | 无任何用户库时不产生用户 RegionGroup | — |
| PG-EMPTY-03 | P0 | tree | 写后删除数据不回收 RegionGroup | — |
| PG-EMPTY-04 | P0 | tree | drop 一个库不影响另一个库的组与映射 | — |
| PG-EMPTY-07 | P1 | tree | 建库后只 flush 不写数据仍是 0 组 | — |
| PG-EMPTY-09 | P0 | tree | 三个库并存各自独立计数且上限按 3 库分摊 | — |
| PG-EMPTY-10 | P1 | tree | drop 全部用户库后系统库仍正常 | — |
| PG-EMPTY-11 | P1 | tree | 反复建/删 4 轮每轮组数一致（无泄漏） | — |
| PG-EMPTY-12 | P1 | tree | 只写深层子路径：Schema/Data 各 1 组 | — |
| PG-EMPTY-14 | P1 | tree | 删除测量点不回收 RegionGroup | — |
| PG-EMPTY-06 | P1 | tree | 建库→写→drop→再建→再写 两轮行为一致 | — |
| PG-EMPTY-08 | P0 | tree | 仅建序列不写数据：Schema 1 组、Data 0 组 | — |

## 资源上限（21 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-LIM-21 | P0 | tree+table | 表模型库上限是否按公式计算（隔离判定，实测疑为缺陷） | — |
| PG-LIM-01 | P0 | tree | 空库上限 = 公式 max(min, ceil(权重×资源/(库数×rf))) | smoke |
| PG-LIM-02 | P0 | table | 表模型上限同口径（直接断言 Max*） | — |
| PG-LIM-03 | P0 | tree | 写满 cap+3 个 slot：组数恰好封顶、不再增长 | smoke |
| PG-LIM-04 | P1 | table | 单批写 cap+3 个 slot：恰好封顶 | — |
| PG-LIM-05 | P2 | tree | 上限随 DataNode 数变化（需换档位 ⇒ SKIP） | — |
| PG-LIM-06 | P0 | tree | schema_region_per_data_node 热加载驱动上限 | — |
| PG-LIM-07 | P0 | tree | data_region_per_data_node 0→非0 切换 resource 口径 | — |
| PG-LIM-08 | P1 | tree | min_schema 支配公式项 ⇒ 上限吃 min | — |
| PG-LIM-09 | P1 | table | 到达上限后新 slot 写入成功、组数不变 | — |
| PG-LIM-10 | P1 | table | 到达上限后新时间分区不建组 | — |
| PG-LIM-11 | P1 | tree | max 永不小于 min（两方向） | — |
| PG-LIM-12 | P0 | tree | 多库分摊：2 库上限减半、drop 后回升 | — |
| PG-LIM-13 | P1 | tree+table | 树库+表库混合分摊（并集分母） | — |
| PG-LIM-14 | P0 | tree+table | 非 CUSTOM 下 ALTER MAX_*_REGION_GROUP_NUM 被拒 | — |
| PG-LIM-15 | P1 | tree | CUSTOM 显式 max：一次补齐；配额不覆盖 stored max | — |
| PG-LIM-16 | P1 | tree | 配额调小 ⇒ 上限不低于已分配组数 G | — |
| PG-LIM-17 | P1 | table | 单次批量请求 delta>1 且恰好封顶 | — |
| PG-LIM-18 | P2 | tree | 跨库同设备名：slot 与组独立计数 | — |
| PG-LIM-19 | P2 | tree | series_slot_num=100 档位（需重部署 ⇒ SKIP） | — |
| PG-LIM-20 | P2 | tree | 3 库 → drop 回 1 库：上限逐级回升 | — |

## 观测（7 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-OBS-06 | P0 | tree | 写入后立即 count(*) 回读（三类设备名对照） | — |
| PG-OBS-07 | P0 | tree+table | 全集群 syncLag 逐实例明细（非零即 FAIL，V2 阻塞项 D-06 的可复现证据） | — |
| PG-OBS-08 | P1 | tree | 写入后 syncLag 是否回落（区分永久缺口与指标假象） | — |
| PG-OBS-01 | P0 | tree | harness BKDR131 与 SHOW DATA REGIONID 交叉验证 | smoke |
| PG-OBS-04 | P0 | tree | 组数去重口径自证：副本行 = 组数 × 副本数 | smoke |
| PG-OBS-02 | P0 | tree+table | 三大观测面口径一致（DETAILS/REGIONS/REGIONID WHERE DATABASE） | — |
| PG-OBS-03 | P0 | tree | REGIONID WHERE DEVICE= ⊆ WHERE DATABASE= 且时间分区计数与写入一致 | — |

## 高可用（14 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-HA-14 | P2 | tree | 只读 1 台 DN 期间新建库（空库也要建 Schema/Data RegionGroup） | — |
| PG-HA-13 | P2 | tree | 1 台 DN 置 READONLY（ON LOCAL）后扩容仍按 min(K,R) 并恢复 | — |
| PG-HA-01 | P0 | tree+table | 停 1 DN 紧接写 3 个新 slot：写入成功且组数 = min(K, expected_cap) | — |
| PG-HA-02 | P0 | tree+table | 在线副本数 == min(DataRF, 存活 DN 数)（不断言恒等于 RF） | — |
| PG-HA-03 | P0 | tree+table | 恢复节点后组状态回 Running（statuses 只允许 Running） | — |
| PG-HA-04 | P0 | tree+table | 所有副本的 DataNodeId 都在当前在线节点集合内 | — |
| PG-HA-05 | P0 | tree+table | 停 1 DN 期间新时间分区写入（同 slot 新分区）仍补组到公式值 | — |
| PG-HA-06 | P0 | table | 停 1 DN 期间 Schema 扩容（新 slot）：组数 = min(K, expected_cap(SCHEMA)) | — |
| PG-HA-07 | P0 | tree+table | 恢复后 sync lag 归 0（收尾①自动查，本用例保证恢复并留证） | — |
| PG-HA-08 | P0 | tree+table | 停 1 DN + 只读 1 DN：cluster.py 缺只读接口 ⇒ SKIP | — |
| PG-HA-09 | P0 | tree+table | 停 1 DN 后 drop+create 库再写：扩容在新库上仍正常 | — |
| PG-HA-10 | P0 | tree+table | 连续两轮「停→写→恢复」，每轮组数 = min(K, expected_cap) | — |
| PG-HA-11 | P0 | tree+table | 停 DN 期间不出现组数超过上限（逐 slot 断言 ≤ 上限） | — |
| PG-HA-12 | P0 | table | 停 DN 期间写入不丢数据：恢复后 count_rows == 写入行数 | — |

## 测点规模（20 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-MSR-17 | P2 | tree | 1 设备 × 20 万测点（benchmark） | — |
| PG-MSR-18 | P2 | table | 1 设备 × 20 万测点（benchmark） | — |
| PG-MSR-19 | P2 | tree | 1 设备 × 50 万测点（benchmark） | — |
| PG-MSR-20 | P2 | table | 1 设备 × 50 万测点（benchmark） | — |
| PG-MSR-01 | P0 | tree | 1 设备 × 1 测点：组数只由 1 个 slot 决定（min(1,R)） | smoke |
| PG-MSR-02 | P1 | table | 表模型 1 设备 × 1 测点（与树同口径） | — |
| PG-MSR-03 | P1 | tree | 1 设备 × 10 测点 × 3 时间分区（同请求）仍 min(1,R) | — |
| PG-MSR-04 | P1 | table | 表模型 1 设备 × 10 测点 × 3 时间分区仍 min(1,R) | — |
| PG-MSR-05 | P1 | tree | 1 设备 × 100 测点：测点数不增加 slot | — |
| PG-MSR-06 | P1 | table | 表模型 1 设备 × 100 测点 | — |
| PG-MSR-07 | P0 | tree | 1 设备 × 1000 测点：组数仍 min(1,R) | — |
| PG-MSR-08 | P1 | table | 表模型 1 设备 × 1000 测点 | — |
| PG-MSR-09 | P1 | tree | 1 设备 × 1 万测点（benchmark，K 实测=1） | — |
| PG-MSR-10 | P1 | table | 表模型 1 设备 × 1 万测点（benchmark，K 实测=1） | — |
| PG-MSR-11 | P2 | tree | 1 设备 × 10 万测点（benchmark，full 档） | — |
| PG-MSR-12 | P2 | table | 表模型 1 设备 × 10 万测点（benchmark，full 档） | — |
| PG-MSR-13 | P1 | tree | 多设备 × 多测点：100 设备 × 100 测点（K=100） | — |
| PG-MSR-14 | P1 | table | 多设备 × 多测点：100 TAG × 100 FIELD（K=100） | — |
| PG-MSR-15 | P2 | tree | ≥1 万设备 × 1 测点（benchmark，K 由产品侧实测） | — |
| PG-MSR-16 | P1 | tree | 同一设备跨 3 分区 + 新增测点 + 新增时间分区 | — |

## 共槽（23 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-DEV-13 | P0 | tree | 两设备共槽只建 1 组（slot 计数口径） | — |
| PG-DEV-15 | P0 | table | 单次批量请求含 3 个新 slot 一次补齐 | — |
| PG-DEV-16 | P1 | table | 批量含已有+新 slot 按并集计、请求内重复去重 | — |
| PG-DEV-01 | P0 | tree | 树 K=1（1 设备 1 测点）：组数 = min(1, R) | — |
| PG-DEV-02 | P1 | tree | 树 K=2（首设备 3 测点）：测点数不增 slot，组数 = min(2, R) | — |
| PG-DEV-03 | P1 | tree | 树 K=3（首设备 10 测点）：组数 = min(3, R) | — |
| PG-DEV-04 | P1 | tree | 树 K=6（首设备 100 测点）：组数 = min(6, R) | — |
| PG-DEV-05 | P0 | tree | 树 K=10 逐个写入：每步 = min(i, R) | — |
| PG-DEV-06 | P1 | tree | 树 K=20：终值 min(20, R)（Schema 先封顶、Data 继续） | — |
| PG-DEV-07 | P0 | table | 表 K=1（1 TAG 1 列）：组数 = min(1, R) | — |
| PG-DEV-08 | P1 | table | 表 K=2（首 TAG 3 列）：列数不增 slot，组数 = min(2, R) | — |
| PG-DEV-09 | P1 | table | 表 K=3（首 TAG 10 列）：组数 = min(3, R) | — |
| PG-DEV-10 | P1 | table | 表 K=6（首 TAG 100 列）：组数 = min(6, R) | — |
| PG-DEV-11 | P0 | table | 表 K=10 逐个写入：每步 = min(i, R) | — |
| PG-DEV-12 | P1 | table | 表 K=20：终值 min(20, R) | — |
| PG-DEV-17 | P1 | tree | 连续编号设备（含共槽编号）：组数 = 实测不同 slot 数，不断言设备数 | — |
| PG-DEV-18 | P0 | tree | K > R：Schema 封顶 R 后不再增长（K=8→12） | — |
| PG-DEV-19 | P1 | tree | 逐个写入的增长序列 = min(i, R)（Schema 与 Data 分别对拍） | — |
| PG-DEV-20 | P0 | tree | 共槽设备 + 跨时间分区：同 slot 不新增组、时间分区不增 slot | — |
| PG-DEV-21 | P0 | tree+table | 1000 个不同 slot 封顶 min(1000, R)；兼两库独立计数（先写树库再写表库） | smoke |
| PG-DEV-22 | P1 | tree | 单设备多层级路径 d0.sub1.sub2：整条路径 1 个 slot ⇒ 1 组 | — |
| PG-DEV-23 | P1 | tree | 中文设备名 + 名称边界（d_1/d-1/超长）：组数 = 实测不同 slot 数 | — |
| PG-DEV-24 | P1 | table | 表模型 null TAG：null 段参与哈希，组数 = 实测不同 slot 数 | — |

## 默认值与配置（12 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-DFT-01 | P0 | tree | 默认值路径（Data）：conf 无策略键 ⇒ PROACTIVE，3 slot 建 min(3,R) 组 | — |
| PG-DFT-02 | P0 | tree | 默认值路径（Schema）：3 slot 建 min(3,R) 组且 Max*RegionGroupNum=公式值 | — |
| PG-DFT-03 | P0 | tree | conf 显式 AUTO：6 个不同 slot 后 Data 组数 = 最小组数（不积极扩容） | — |
| PG-DFT-04 | P1 | tree | conf 显式 CUSTOM：6 个不同 slot 后 Data 组数 = 最小组数 | — |
| PG-DFT-05 | P0 | tree | 热加载合法值 AUTO 成功、读回 AUTO，随后恢复 conf 原值并读回自证 | — |
| PG-DFT-06 | P0 | tree | 非法值小写 proactive 被拒（不得解释为 PROACTIVE）且文件值未变 | — |
| PG-DFT-07 | P1 | tree | 非法值 PROACTIVE2 被拒且文件值未变（明确报错、非静默降级） | — |
| PG-DFT-08 | P1 | tree | schema 键写非法值被拒、文件未变；报错文案疑似 G-02，只记原文 | — |
| PG-DFT-09 | P1 | tree | 一条 SET CONFIGURATION 设两个键被拒（实测 700），两个键文件值均未变 | — |
| PG-DFT-10 | P1 | tree | SET CONFIGURATION ... ON 1 单节点提交被拒（实测 701），文件值未变 | — |
| PG-DFT-11 | P1 | tree | 数值键 schema_region_per_data_node 写 abc 被拒且文件值未变 | — |
| PG-DFT-12 | P0 | tree | 两类策略独立：仅 data 切 AUTO（不积极扩容），schema 仍按 PROACTIVE（min(6,R)） | — |

## 最小数量（6 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-MIN-01 | P0 | tree | min_data=2、首个 slot 首次请求只建 1 组（不预建到 min） | — |
| PG-MIN-02 | P0 | tree | 探针 A-01：G=1、同 slot 新时间分区 ⇒ 源码口径 2 组（非 1 组） | — |
| PG-MIN-03 | P0 | tree | min_data=3、逐个写 3 个不同 slot：1→2→3 逐步逼近 min | — |
| PG-MIN-04 | P0 | tree | Schema 侧逐步逼近：min_schema=3、上限取 expected_cap(SCHEMA) | — |
| PG-MIN-05 | P1 | tree | min 大于公式上限 ⇒ 上限吃 min：MaxDataRegionGroupNum=min 且写满 min slot 得 min 组 | — |
| PG-MIN-06 | P1 | tree | min 调大后同 slot 申请新时间分区（不新增 slot）也向 min 增长：G=2、min=5 ⇒ 3 | — |

## 时间分区（12 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-TIME-01 | P0 | tree | 同 slot 新时间分区按 T=min(R,max(min(minNum,G+|P|),K)) 补组 | smoke |
| PG-TIME-02 | P1 | table | K 个已存在 slot 同时写新时间分区 | — |
| PG-TIME-03 | P0 | tree | 时间分区边界由实测 TimePartitionInterval 计算 | — |
| PG-TIME-04 | P1 | tree | 同一 slot 跨 6 个时间分区（组数不随分区增长） | — |
| PG-TIME-05 | P1 | table | 新时间分区 + 新 slot 混合请求：K 取并集 | — |
| PG-TIME-06 | P1 | tree | SHOW TIMESLOTID 行数 = 写入分区数（DEVICE/DATABASE） | — |
| PG-TIME-07 | P1 | tree | COUNT TIMESLOTID 口径一致（库级去重 = P、逐设备 = P） | — |
| PG-TIME-08 | P1 | tree | 老时间分区追加：已有分区不触发扩容 | — |
| PG-TIME-09 | P1 | tree | 乱序写（老分区新数据）：组数与老分区映射不变 | — |
| PG-TIME-10 | P0 | tree | 分区数增长不使组数无限增长（封顶 min(K,R)） | — |
| PG-TIME-11 | P1 | table | 表模型同 TAG 新时间分区（与树同口径） | — |
| PG-TIME-12 | P1 | tree | 单设备 100 个时间分区：组数收敛到 min(minNum,R) | — |

## Disabled补组（7 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-DIS-01 | P0 | tree | 全部 Data 组 Disabled ⇒ 补 1 组（≤R） | smoke |
| PG-DIS-02 | P1 | tree | 全部 Schema 组 Disabled ⇒ 补 1 组（≤R） | — |
| PG-DIS-03 | P1 | tree | 仅部分组 Disabled ⇒ 不补组 | — |
| PG-DIS-04 | P1 | tree | 已达上限 R ⇒ 即使全 Disabled 也不补组 | — |
| PG-DIS-05 | P1 | tree | 无 pending slot（P 为空）⇒ 不补组 | — |
| PG-DIS-06 | P1 | tree | 补组后完整性：状态回 Running、组不回收、数据完整 | — |
| PG-DIS-07 | P1 | tree | CN 重启后立即写新 slot：组数应为 min(K,R)（A-05 歧义探针） | — |

## 重平衡与恢复（7 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-RCV-01 | P0 | tree | CN 全重启：组数/组 id/设备→组映射保留 | smoke |
| PG-RCV-02 | P0 | tree | DN 重启：组状态回到 Running、组数映射不变 | — |
| PG-RCV-03 | P1 | tree | 重启后新时间分区仍按策略扩容 | — |
| PG-RCV-04 | P1 | table | 恢复期上限不变且与公式一致 | — |
| PG-RCV-05 | P1 | tree | Disabled→Running 后组数不回收 | — |
| PG-RCV-06 | P1 | tree+table | 重启后 库详情 与 SHOW REGIONS 计数仍一致 | — |
| PG-RCV-07 | P1 | tree | 领导者变更后 设备→组 映射不变 | — |

## 重平衡（14 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-REB-01 | P0 | tree+table | 均衡后每组槽数 ≤ mu（mu 由实测 slot/组数现算） | — |
| PG-REB-02 | P0 | tree+table | 组间分布不畸变：max-min ≤ 1 且与 mu 口径一致 | — |
| PG-REB-03 | P0 | tree+table | 新增 Data 组后被分摊到槽（新组槽数 > 0） | — |
| PG-REB-04 | P0 | tree+table | 热加载切 AUTO 再切回 PROACTIVE：重分摊仍 ≤ mu，结束恢复 conf 原值 | — |
| PG-REB-05 | P0 | tree+table | K < 上限：组数 = min(K, expected_cap)，非空组槽数和 == K | — |
| PG-REB-06 | P0 | tree+table | 空库重平衡无副作用：0 组、0 槽、mu 退化不崩 | — |
| PG-REB-07 | P0 | tree+table | 单 slot 库：1 组、1 槽、mu == 1 | — |
| PG-REB-09 | P0 | tree+table | 多次写入后分布仍守恒（逐批断言 slot 和 == 累计 K） | — |
| PG-REB-10 | P0 | tree+table | 组数变化后 mu 随之变化（mu 始终按实测 slot/组数现算） | — |
| PG-REB-11 | P0 | tree+table | 树/表两模型分布口径一致（同 K 同组数同均衡条件） | — |
| PG-REB-12 | P0 | tree+table | 写入→均衡→再写入 累积守恒（三段并集 == slot 总数） | — |
| PG-REB-13 | P0 | tree+table | 单设备多测点不改变分布（1→N 测点 slot/组数不变） | — |
| PG-REB-14 | P0 | tree+table | flush 后分布与组数不变（落盘不触发重平衡） | — |

## TTL（8 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-TTL-01 | P0 | tree | 设 TTL 后写 4 个不同 slot：组数仍 = min(4, 上限) | smoke |
| PG-TTL-02 | P0 | tree | 小 TTL(1000ms)+等 4s 后再写：写入成功、组数仍按公式 | — |
| PG-TTL-03 | P0 | tree | 过期删除后组数与设备→组映射不变（RegionId 集合对拍） | — |
| PG-TTL-04 | P1 | tree | unset ttl 后继续写新 slot：正常扩容到 min(K, 上限) | — |
| PG-TTL-05 | P1 | tree | TTL 与时间分区叠加：分区边界前后写行，组数仍 min(K, 上限) | — |
| PG-TTL-06 | P2 | table | 表模型 TTL：语法未确认 ⇒ SKIP（不试探性 DDL） | — |
| PG-TTL-07 | P1 | tree | TTL 生效期间同 slot 新增测点不建组 | — |
| PG-TTL-08 | P1 | tree | 过期清理后集群健康、RegionGroup 不回收（sync lag 归 0 见收尾①） | — |

## 系统库（6 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-SYS-01 | P0 | tree | 单用户库：实测上限 = 只计普通库的公式值（系统库未进分母） | smoke |
| PG-SYS-02 | P0 | tree | 再建第 2 个用户库：上限按新分母实时下降 | — |
| PG-SYS-03 | P0 | tree | 系统库 Max*RegionGroupNum 是否为固定 1（源码 :973-995） | smoke |
| PG-SYS-04 | P1 | tree | 用户库写入不影响系统库组数（只读观测） | — |
| PG-SYS-05 | P0 | tree | 系统库组数恒为 1（Data/Schema 各 1，只读观测） | — |
| PG-SYS-06 | P1 | tree | 用户库写 6 个 slot 前后系统库组数/上限不变 | — |

## 重启（6 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-RST-01 | P0 | tree | 整集群重启后组数与设备→组映射不变 | 需重启 |
| PG-RST-02 | P0 | tree | 重启后 SHOW DATABASES DETAILS 与 SHOW REGIONS 口径仍一致 | 需重启 |
| PG-RST-03 | P0 | tree | 重启后继续写新 slot 仍按 min(K, 上限) 扩容 | 需重启 |
| PG-RST-04 | P1 | tree | 热加载改过的策略重启后回到 conf 文件的值 | 需重启 |
| PG-RST-05 | P0 | tree | 空库重启后仍是 0 组（不补建） | 需重启 |
| PG-RST-06 | P1 | tree | 重启后写新时间分区的新 slot：补组到 min(K, 上限) | 需重启 |

## 策略切换（12 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-SWCH-01 | P0 | tree | AUTO（N slot 只到 min）→ 切 PROACTIVE → 已有 slot 写新时间分区按公式补到 min(K,R) | — |
| PG-SWCH-02 | P0 | tree | PROACTIVE → AUTO：已有组保留不回收，新 slot 不再积极扩容 | — |
| PG-SWCH-03 | P0 | tree | PROACTIVE → CUSTOM：已有组保留，新 slot 由 CUSTOM（逼近 minNum）接管 | — |
| PG-SWCH-04 | P0 | tree | CUSTOM（配额=minNum）→ PROACTIVE：不回收，新 slot 恢复积极扩容到 min(K,R) | — |
| PG-SWCH-05 | P0 | tree | 只切 data 策略：schema 组数不受影响，严格按原策略公式增长 | — |
| PG-SWCH-06 | P0 | tree | 只切 schema 策略：data 组数不受影响，严格按原策略公式增长 | — |
| PG-SWCH-07 | P0 | tree | 切换动作本身不建组：切换前后 SHOW DATABASES DETAILS 组数完全不变（需求 §3.1） | — |
| PG-SWCH-08 | P0 | tree | 历史映射不变：切换前后设备→Data RegionGroup 逐一相同 | — |
| PG-SWCH-09 | P0 | tree | 切换 + 整集群重启：重启按 conf 文件生效，断言重启后 == ctx.cfg.raw(PG_DATA_POLICY) | 需重启 |
| PG-SWCH-10 | P0 | tree | 非法值切换被拒（ok is False）、文件未变，且行为仍按原策略 | — |
| PG-SWCH-11 | P0 | tree | AUTO 下仅新增测点（同 slot、K 不变）不建组：Schema/Data 组数均不变 | — |
| PG-SWCH-12 | P0 | tree | 切换后新增 slot 按新策略：PROACTIVE→AUTO 不增；再切回 PROACTIVE 增到公式值 | — |

## 权限（8 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-PRV-01 | P0 | tree | 普通用户热加载策略被拒（not .ok）且配置未变（props 读回） | — |
| PG-PRV-02 | P0 | tree | 授 SYSTEM 的用户热加载成功并读回自证，结束恢复 conf 原值 | — |
| PG-PRV-03 | P1 | tree | 普通用户建库/写入：明确二选一结论（被拒 A / 产品允许 B 的事实记录） | — |
| PG-PRV-04 | P0 | tree | 普通用户对已授权库写入成功，对未授权库写入被拒（授权边界对照） | — |
| PG-PRV-05 | P0 | tree | 权限拒绝后配置与组数（双口径）均未变 | — |
| PG-PRV-06 | P0 | tree | 撤销 SYSTEM 后热加载被拒（grant 生效 → revoke → 被拒 闭环） | — |
| PG-PRV-07 | P1 | tree | 组数与上限对普通用户是否可观测：明确断言可见（A）或不可见且为权限拒绝（B） | — |
| PG-PRV-08 | P1 | tree | SHOW REGIONS 类观测对普通用户是否可见：明确断言可见（A）或不可见且为权限拒绝（B） | — |

## 升级（16 条）

| 用例 | 优先级 | 模型 | 标题 | 标记 |
|---|---|---|---|---|
| PG-UPG-01 | P0 | tree | 1.3 基线：建树库写 1 设备 1 测点并记录组数 | — |
| PG-UPG-02 | P0 | tree | 1.3 默认 AUTO：6 个不同 slot 只到最小组数（升级前不积极扩容） | smoke |
| PG-UPG-03 | P0 | tree | 1.3 conf 策略键不存在或为 AUTO，且模板不认 PROACTIVE | — |
| PG-UPG-04 | P1 | tree | 1.3 用 db_time_partition_interval 算分区边界并写分区 0/1 数据 | — |
| PG-UPG-05 | P1 | tree | 1.3 建多个库（升级后对比上限分摊） | — |
| PG-UPG-06 | P0 | tree | 记录 SHOW DATABASES DETAILS 快照与行数（升级前） | — |
| PG-UPG-07 | P1 | tree | 记录设备→RegionGroup 映射（升级前） | — |
| PG-UPG-08 | P0 | tree | 升级后版本号为 2.0（SHOW CLUSTER 的 Version 列） | smoke |
| PG-UPG-09 | P0 | tree | 【核心】升级后已有库写新 slot 按 PROACTIVE 扩容（含 无键⇒PROACTIVE / 显式AUTO⇒保持AUTO 的独立性断言） | smoke |
| PG-UPG-10 | P0 | tree | 升级后新时间分区写入触发补组 | — |
| PG-UPG-11 | P0 | tree | 升级后 Max*RegionGroupNum 与公式一致 | — |
| PG-UPG-12 | P0 | tree | 升级后热加载策略：set_config + 读回自证 + 恢复 | — |
| PG-UPG-13 | P1 | tree | 升级后新增测点（同 slot）不建组 | — |
| PG-UPG-14 | P1 | tree | 升级后 drop 库再建再写仍正常（PROACTIVE 扩容） | — |
| PG-UPG-15 | P0 | tree | 升级后升级前的行数不丢（与 06 快照一致） | — |
| PG-UPG-16 | P1 | tree | 升级后 Schema 侧同样按 PROACTIVE 扩容 | — |
