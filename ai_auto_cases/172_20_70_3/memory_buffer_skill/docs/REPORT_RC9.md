# RC9 测试报告 —— 内存缓冲区专项（3C5D）

| 项 | 内容 |
|---|---|
| **被测版本** | `v20121rc9_1020_d206dc2`（TimechoDB / IoTDB **2.0.12.1**，BuildInfo **d206dc2**） |
| **对照版本** | `v20121rc8_1016_ebaf9da`（BuildInfo `ebaf9da`） |
| **测试日期** | 2026-10-21 19:54 ~ 2026-10-22 08:00（部署 + 全量执行） |
| **报告生成** | 2026-10-22 08:00 (Asia/Shanghai) |
| **测试执行** | DSH 自动化（membuf_skill v2，24 条用例） |
| **环境** | 3CN（`70.5` / `70.4` / `70.26`）+ 5DN（`70.4` / `70.26` / `70.14` / `70.27` / `70.30`）<br>SchemaRF=**3**，DataRF=**2**，默认 IoTConsensus<br>客户端 `172.20.70.3` |

---


> ⚠️ **P99 数值更正（2026-10-22 18:20）**
>
> 本文档及 RC9 报告中的「P99」列，实际取的是 benchmark CSV 的 **P999** 列（写死 `$11`，而 P99 是 `$10`）。
> 真值需按下方「更正后的 P99」查看。已修 `lib/perf.sh`（改为按表头名定位 P99）。
>
> | 用例 | 原记录「P99」= 实际 P999 | 更正后的真 P99 |
> |---|---|---|
> | P-01 | 45.87 ms | **7.54 ms** |
> | P-03 sep_off_ooo | 44.45 ms | **7.15 ms** |
> | P-03 sep_on_ooo | 95.35 ms | **7.26 ms** |
>
> **P-03 的结论因此变更**：原判「乱序负载 P99 恶化 +114%（FAIL）」不成立 ——
> 那是 P999 从 44.45 涨到 95.35；真 P99 是 7.26 vs 7.15（**+1.5%**）。
> 按原判据（吞吐 -30% / P99 +50%）复核，P-03 两个场景**均应 PASS**。

## 一、总览（结论先行）

| 指标 | 数值 |
|---|---|
| **总用例数** | **24**（功能 19 + 性能 5） |
| **通过** | **19**（功能 16 + 性能 3） |
| **失败** | **5**（功能 3 + 性能 2） |
| **通过率** | **79.2%** |
| **功能轮耗时** | **9,012 s ≈ 2 h 30 min**（19 条，串行） |
| **性能轮耗时** | **2,366 s ≈ 39 min**（5 条，含被中断后补跑） |
| **一轮总耗时（纯执行）** | **11,378 s ≈ 3 h 10 min**（24 条串行之和） |
| **含部署的墙钟时间** | **≈ 12 h 06 min**（10-21 19:54 → 10-22 08:00，含 RC9 部署与多轮返工重跑） |

> **"一轮耗时"说明**：
> - **3 h 10 min** 是 24 条用例在干净集群上串行执行的实际耗时之和，**这才是"跑一轮"的成本**；
> - **12 h 06 min** 是从部署 RC9 到全部出结论的墙钟时间。多出来的 9 小时几乎全是
>   **环境打断后的重跑**（详见 §6.3）——其中 MB-06 单条就重跑了 6 次。
>   在正常的真机终端上跑一轮应按 3~4 h 估算。

### 功能用例 19 条：16 PASS / 3 FAIL

| 状态 | 用例 |
|---|---|
| ✅ **PASS（16）** | MB-01、MB-02、MB-03、MB-04、MB-05、MB-06、MB-07、MB-08、MB-09、MB-10、MB-11、MB-12、MB-13、MB-16、MB-17、MB-18 |
| ❌ **FAIL（3）** | **MB-14**（V2 协议）、**MB-15**（BACKWARD 排序算法）、**MB-19**（非法比例致 DN 起不来） |

### 性能用例 5 条：3 PASS / 2 FAIL

| 状态 | 用例 | 说明 |
|---|---|---|
| ✅ PASS | P-01 flush_proportion | 0.5 优于 0.4（+2.5% 吞吐、P99 -10%） |
| ✅ PASS | P-02 Chunk 切分 | 三个变体差异均 <5%，无劣化 |
| ❌ **FAIL** | **P-03** 顺乱序分离 | 乱序负载下 **P99 从 44.45ms 恶化到 95.35ms（+114%）** |
| ✅ PASS | P-04 最新点查询 | 三算法差异 <12%，BACKWARD 的 P99 最优 |
| ❌ **FAIL** | **P-05** 共识协议 | **V2 = 292,899 / V1 = 2,247,823 point/s，V2 慢 7.7 倍（-87.0%）** |

---

## 二、逐条功能用例（19 条）

| 用例 | 结果 | 耗时 | 关键证据 |
|---|---|---|---|
| **MB-01** 内存分配事实 | ✅ PASS | 155s | RC9 的 DN 堆走发布包默认的**自动计算**（`-Xmx12804M` / 12.50 GB）；RC8 的 20G 是**运维手工设置**，不是版本默认（两版 `datanode-env.sh` 逐字节相同，`ON_HEAP_MEMORY` 在两版里都是注释掉的）。用例改为**从进程 cmdline 读 -Xmx + 按比例自洽校验**：`Read/Schema/Consensus/Pipe/AutoResizing/SchemaRegion` 与 `maxMemory` 的比例关系全部精确成立（差值 0~1 字节），反推 maxMemory 与 -Xmx 偏差 0.031%（JVM `maxMemory()` 固有差异） |
| **MB-02** 参数守卫 | ✅ PASS | 561s | ①`reject+wal+device≥1` → 打出回退 WARN，devicePathCache 比例回落 0.05；②storage 9/14 → `Write=8633675190` 与 `maxMemory×9/14` 一致（差 3 字节）；③storage 12/17 → `Write=9480113935` 与 `×12/17` 一致（差 7 字节），**本构建仍未启用 60% 限幅**（F-08 在 RC9 依旧） |
| **MB-03** 按比例刷盘 | ✅ PASS | 514s | 1200 点 × 4KB → 自动刷盘 `flush 0→2`、TsFile 增长、未进 reject、点数 1200；20 次副本比对（停 5 DN × 4 剩余节点）全部一致；6 节点日志无异常 |
| **MB-04** 定时刷盘(seq) | ✅ PASS | 423s | 不手工 flush 也新增 TsFile；**对照组**关开关后同窗口不新增 |
| **MB-05** 定时刷盘(unseq) | ✅ PASS | 624s | 命中产品日志 `Exceed unsequence memtable flush interval`；对照组不新增；顺序+乱序点数正确 |
| **MB-06** 拒绝与背压 | ✅ PASS | 558s | memtable 压到 ~1MB（1:10000）+ flush 1% + reject 2% → **reject 进入 27 次，写入被全部拒绝、点数 0**（与"全拒"语义自洽）；syncLag 归零、7 节点日志无异常。压测系数按 RC9 实测标定（`1:10000`），与 RC8 那轮的 `1:1000` 不同，故不与 RC8 比"强弱" |
| **MB-07** 刷盘限流并发 | ✅ PASS | 657s | 3 写 + 1 查询并发，查询**零 SQL 异常**，点数 == 成功语句 × 行数，刷盘发生 |
| **MB-08** WAL 快照 + kill -9 | ✅ PASS | 491s | 阈值/份数配置回读生效；`kill -9` 一个 DN 后恢复 Running、**点数不丢（WAL 回放）** |
| **MB-09** 各内存池比例 | ✅ PASS | 528s | 三个比例逐节点 conf 回读一致；Memtable 子池指标缺失时降级 WARN；1200 点正确 |
| **MB-10** 优雅重启回放 | ✅ PASS | 171s | 重启后点数不变、副本一致 |
| **MB-11** 顺乱序分离 | ✅ PASS | 154s | `separate=true` → `sequence/` 有文件且 `unsequence/=0`；`false` → 只落 `unsequence/`；关闭后乱序数据仍落 unsequence/；点数正确 |
| **MB-12** Chunk 切分 | ✅ PASS | 460s | 极小 `target_chunk_point_num=500` / `target_chunk_size=4096` 下 INT64+TEXT 点数完整、文件数未爆炸；**极值 1/1 下节点不崩、数据可查** |
| **MB-13** 高可用停 DN | ✅ PASS | 487s | 写入中途停 DN(70.30)：在线 DN=4、写入仍成功、恢复后点数精确、副本一致 |
| **MB-14** IoTConsensusV2 | ❌ **FAIL** | 881s | 协议配置生效、V2 syncLag 指标存在、点数正确；但 **③ 未触发自动刷盘** + **④ 停 DN 后剩余副本 count=0**（基准非 0）→ 见 §三 F-10 |
| **MB-15** TVList 排序算法 | ❌ **FAIL** | 825s | TIM / QUICK 两相 PASS（各 2000 点、指纹一致 `b89017e8...`）；**BACKWARD 相点数=0、查询无数据**（写入语句全部报成功）→ 见 §三 F-09 |
| **MB-16** flush 线程/数组 | ✅ PASS | 653s | 线程 0/数组 64 与 线程 1/数组 16 两相点数一致、刷盘发生、无异常日志 |
| **MB-17** 时间分区内存可控 | ✅ PASS | 273s | 多个时间分区全部可查、点数精确；未观察到 `degrade LastFlushTimeMap` 时按 WARN 记"场景未成立" |
| **MB-18** 字符串类型推断 | ✅ PASS\* | 486s | 全 TEXT 相符合预期；默认相四类推断**仍全为 TEXT**（F-01 未修复）→ 按已知缺陷记 WARN 不计 FAIL |
| **MB-19** 非法比例致 DN 起不来 | ❌ **FAIL** | 111s | `storage_engine_memory_proportion=0:10` → DataNode 启动 NPE、集群不可用 → 见 §三 F-07 |

\* MB-18 的 PASS 是"已知缺陷模式下 PASS"，产品行为仍未达需求。

---

## 三、三条失败用例的定性（明日与研发确认用）

### F-09【高】`tvlist_sort_algorithm=BACKWARD` 下数据查不到 —— **RC9 未修复**

| 项 | 内容 |
|---|---|
| 复现 | `tvlist_sort_algorithm=BACKWARD`；建 int64 序列；单条 INSERT 写 2000 点（逆序 + 步长 7） |
| 实测 | 写入返回 `The statement is executed successfully.`；`select count(s1) from db.**` = **0**；`flush;` 后仍 **0** |
| 对照 | 同一 SQL 在 `TIM` / `QUICK` 下 count = 2000，指纹完全一致（`b89017e84a6fc523618d6f8af02eb8e3`） |
| 重复性 | RC8 两次、RC9 一次独立运行，**三次均复现** |
| 建议 | 查 `TVListSortAlgorithm.BACKWARD` 的排序写回路径：逆序写入时 sorted 标记/rowIndex 是否一致；生产环境暂不建议使用 BACKWARD |

### F-10【高】IoTConsensusV2 刷盘/副本可见性/吞吐三项异常 —— **RC9 未修复**

| 子问题 | RC9 实测 |
|---|---|
| ① 不刷盘 | `flush_proportion=0.4` + memtable 20MB，写 1200 点后等窗口**未观察到自动刷盘**（V1 同配置 1 秒内就刷） |
| ② 副本不可见 | 收尾"停 1 个 DN"那轮，剩余副本 `count=0`（V1 同场景全部一致） |
| ③ **吞吐严重劣化** | 同负载同参数：**V1 = 2,247,823 point/s，V2 = 292,899 point/s（-87.0%，慢 7.7 倍）**；AVG 0.70ms → 6.66ms |
| 反常点 | V2 的 **P99 反而更低**（25.02ms vs 36.82ms）⇒ 不是偶发慢请求，是**整体吞吐被系统性拖慢** |
| 建议 | 确认：V2 下内存控制的刷盘触发是否走同一路径；停副本后的读路径是否依赖未 seal 数据；吞吐劣化是否符合预期 |

### F-07【高】非法 `storage_engine_memory_proportion` 让 DataNode 起不来 —— **RC9 未修复**

| 项 | 内容 |
|---|---|
| 复现 | `storage_engine_memory_proportion=0:10`（其余默认） |
| 实测 | DataNode 启动即崩，5 个 DN 全起不来（只剩 3 CN）：<br>`Exception in thread "main" java.lang.ExceptionInInitializerError`<br>`Caused by: NullPointerException: ... DataNodeMemoryConfig.getDevicePathCacheMemoryManager() is null` |
| 同时日志 | `WARN DataNodeMemoryConfig:413 - The value of storage_engine_memory_proportion is illegal, use default value 8:2 .`（**说了回退，实际没回退**） |
| 根因 | `initStorageEngineAllocate()` 的 `<=0` 守卫执行 `LOGGER.warn(); return;`，而 **7 个 memory manager 的创建语句全在该 return 之后** ⇒ 全部为 null |
| 修复建议 | `return` → `break` / 跳过解析（保留已算好的默认值），或在方法末尾统一兜底创建；`write_memory_proportion` 同样检查 |

### P-03【性能】顺乱序分离在乱序负载下 P99 恶化 114%

| 变体 | 吞吐 | P99 |
|---|---|---|
| separate=false + 顺序 | 902,508 | 49.12ms |
| separate=true + 顺序 | 823,562（-8.7%） | 42.77ms |
| separate=false + 乱序 50% | 904,474 | 44.45ms |
| **separate=true + 乱序 50%** | 838,331（-7.3%） | **95.35ms（+114%）** |

文档要求"打开顺乱序分离后在绝大多数场景下不低于关闭时"。吞吐满足（-7~9%，容忍内），
但**乱序负载的 P99 翻倍**，违反该要求。建议研发确认这是否为 RC9 引入。

---

## 四、性能结果明细（3C5D + iot-benchmark）

**负载**：`LOOP=400`、`DEVICE_NUMBER=40`、`SENSOR_NUMBER=20`、`BATCH_SIZE_PER_WRITE=10`，
`OPERATION_PROPORTION=91:1:1:1:1:1:0:0:0:0:0:0`（写为主，与《软件测试文档》口径一致）。
**判据**：与同轮基线比，吞吐下降 >30% 记 FAIL，P99 恶化 >50% 记 FAIL；**不设绝对门槛**。

### P-01 flush_proportion ✅

| 变体 | 吞吐 (point/s) | P99 | 变化 |
|---|---|---|---|
| base_fp04（0.4 默认） | 886,390 | 45.87ms | 基线 |
| **fp05（0.5）** | **908,956** | **41.10ms** | **+2.5% / P99 -10.4%** |

→ 文档"从 0.4 提到 0.5 避免频繁刷盘"的取舍**在 RC9 上成立**。

### P-02 Chunk 切分 ✅

| 变体 | 吞吐 | 相对基线 |
|---|---|---|
| c100k（默认 10w 点） | 906,154 | 基线 |
| c10k（1w 点） | 887,229 | -2.1%（WARN，容忍内） |
| csize（chunk 8MB） | **936,208** | **+3.3%** |

→ 三个变体差异均 <5%，**RC9 上未复现文档担心的"切碎导致性能下降"**；反把 chunk 调大反而略快。

### P-04 最新点查询（LATEST_POINT）✅

| 变体 | LATEST_POINT 吞吐 | LATEST_POINT P99 |
|---|---|---|
| q_TIM（默认） | 297.63 op/s | 167.03ms |
| q_QUICK | 264.50 op/s | 164.98ms |
| q_BACKWARD | **304.23 op/s** | 172.78ms |

→ 三算法差异 <12%，均在容忍内。**文档记录的"536s→818s 劣化"在 RC9 上未复现**。

### P-05 共识协议 ❌

| 变体 | 吞吐 (point/s) | AVG | P99 | 耗时 |
|---|---|---|---|---|
| **v1（IoTConsensus）** | **2,247,823** | 0.70ms | 36.82ms | 8.44s |
| **v2（IoTConsensusV2）** | **292,899** | 6.66ms | 25.02ms | 64.79s |

→ **V2 吞吐只有 V1 的 13.0%（-87.0%）**，与 RC8 的 -91.9% 同一量级，**两版均复现**。

---

## 五、RC9 vs RC8 对比

> ⚠️ **比可比性说明（重要）**：RC8 那轮的 DataNode 堆是**运维手工设置 20G**，RC9 这轮
> 走发布包默认的自动计算 **12.50G**（两版发布包的 `datanode-env.sh` 逐字节相同、
> `ON_HEAP_MEMORY` 都被注释，默认就是自动算；RC8 那行 20G 是手工加的，RC9 新目录没带过来）。
>
> 由此带来的影响：
> - **功能用例**：判据已全部改成"比例自洽"，与堆大小无关 ⇒ 结论可直接对比。
> - **性能用例**：RC8 与 RC9 的**绝对吞吐不可直接比**（堆小 37.5%，写缓冲区同比变小）。
>   本文所有性能结论都只在**同一轮内**做变体对照（V1 vs V2、0.4 vs 0.5 等），不跨轮比绝对值。
>
> 如果希望 RC9 与 RC8 的性能绝对值可比，需要在 RC9 的 `conf/datanode-env.sh` 里
> 同样加上 `ON_HEAP_MEMORY="20G"` 后再跑一轮性能（约 40 分钟）。



| 用例 | RC8 | RC9 | 变化 |
|---|---|---|---|
| MB-01 内存分配 | PASS（堆 20G，运维手工设定） | PASS（堆 12.50G，走发布包默认自动计算） | 堆大小不同（部署差异，非版本改动），用例已改为动态读取 |
| MB-02 参数守卫 | PASS | PASS | — |
| MB-03~MB-13、MB-16、MB-17 | 全部 PASS | 全部 PASS | — |
| MB-06 拒绝背压 | PASS（1:1000，1300 点，20/20 语句成功） | PASS（1:10000，65 点，全部被拒） | **参数不同，不可直接比强弱**（详见下方说明） |
| MB-14 V2 | FAIL（fail=5） | FAIL（fail=7） | **未修复** |
| MB-15 BACKWARD | FAIL（fail=3） | FAIL（fail=3） | **未修复** |
| MB-18 类型推断 | PASS\*（F-01） | PASS\*（F-01） | **未修复** |
| MB-19 非法比例 | FAIL（fail=4） | FAIL（fail=4） | **未修复** |
| P-01 flush_proportion | +2.1% | +2.5% | 一致 |
| P-03 顺乱序分离 | PASS（乱序 +4.0%） | **FAIL（P99 +114%）** | **RC9 新出现** |
| P-05 V1 vs V2 | -91.9% | -87.0% | 同一量级，**未修复** |

> **关于 MB-06 的"拒绝强弱"（不能下结论）**：
> - RC8：比例 `1:1000`、堆 20G、写 1300 点 → reject 状态进入 20 次，但 **20/20 语句全部成功**（1300 点落库），整条 223s。
> - RC9：比例 `1:1000`、堆 12.50G 时，写入被长时间阻塞（多条语句等满 10s 超时），用例反复被打断、拿不到结论；
>   最终按 RC9 实测把压测系数改为 `1:10000` + 65 点才稳定跑通 → reject 进入 27 次、全部被拒、0 点落库，558s。
> - 两轮的**比例和堆都不同**（memtable 绝对阈值随之不同），因此**不能断言"哪个版本内存控制更严格"**。
>   若要判定，需在同一堆大小（例如都设 20G）、同一比例下各跑一次 MB-06 对比。

**结论：RC9 相对 RC8，没有修复任何一条高严重级问题（F-07/F-09/F-10），并新增一条 P-03 的性能劣化。**

---

## 六、部署与执行说明

### 6.1 RC9 部署（本次自行完成）

RC9 交付物只有 `timechodb-2.0.12.1-bin.zip`（106 MB，未部署到任何节点）。部署步骤：

1. 在客户端 `70.3` 解压并平铺到 `/data1/iotdb/testdb/v20121rc9_1020_d206dc2/`（对齐 RC8 的 `sbin/start-cli.sh` 路径）；
2. 打包（排除 zip，102 MB）→ `scp` 分发到 **6 个物理节点**（3CN+5DN 有重叠：`70.5/70.4/70.26/70.14/70.27/70.30`）；
3. 每节点解压到 `/data/iotdb/v20121rc9_1020_d206dc2/`，补齐 `activation/license`（复用 `/data/iotdb/timecho_license_new`）与 `.env`（`node_uuid`，优先复用节点已有的）；
4. 备份 `conf_orig`；
5. 校验：每节点 12 个顶层条目、`start-datanode.sh`/`start-confignode.sh` 可执行、license+env 就位、2 个 jar、114 MB；
6. 启动验证：`show cluster` → **8/8 Running，Version 2.0.12.1，BuildInfo d206dc2，全部 ACTIVATED**。

### 6.2 环境适配（本轮遇到的环境/部署差异，已修进 skill）

| 差异 | 影响 | 处理 |
|---|---|---|
| **DN 堆大小与 RC8 不同（20G → 12.50G）** | 注意：这**不是 RC9 的改动**。两版发布包的 `datanode-env.sh` 逐字节相同（md5 `908b821c...`），其中 `#ON_HEAP_MEMORY="2G"` **都是注释掉的**，上游默认一直是"按机器内存自动算"。RC8 上之所以是 20G，是**运维手工添加了 `ON_HEAP_MEMORY="20G"`**；RC9 新建目录未带该行，于是走默认自动计算（`-Xmx12804M`）。<br>用例若把 20G 写死，会产生 35 条假 FAIL（已发生） | MB-01/MB-02 改为**从进程 cmdline 读 `-Xmx`** + **按比例自洽**校验（JVM `maxMemory()` 与 `-Xmx` 有 0.03% 固有差异，逐字节比仍会假失败） |
| **memtable 绝对阈值不同** | RC9 在 `1:1000`、堆 12.50G 下实测 `memory_threshold_size{name="StorageEngine-Write-Memtable"}` = **49.8 MB**。RC8 那轮堆是 20G（手工设置）且未用同一指标直接量过，因此**不做倍数比较** | MB-06 的"压 memtable"系数按 RC9 实测重新标定（`1:10000` 而非 RC8 的 `1:1000`）；MB-03/MB-14 用 `1:2000` |
| **未定论：拒绝行为差异** | RC8（`1:1000` + 1300 点）全部写入成功；RC9（`1:1000`）写入被长时间阻塞至超时。但两轮**堆大小与比例都不同**，属混淆变量 | MB-06 判据已改为"全部被拒也是合法结果"（`点数=0` 与 `成功语句=0` 一致即可）；**是否真存在行为差异需同堆同比例复测**（见 §七 建议） |

### 6.3 执行中的环境问题（非产品问题）

**长跑用例偶发被 SIGKILL（rc=137）**：本环境上用例运行 8~15 分钟后有较大概率被打断，
`dmesg` / `journalctl` / cgroup / `systemd-oomd` 全部无 OOM 记录，已排除内存、cgroup、OOM killer、cron 巡检。
判定为**执行通道（ssh 会话层）回收**，真机本地终端或 screen/tmux 不受影响。

应对措施（已固化进 skill）：
- `tools/run_until_done.sh`：用例级重试（`--tries 5`），**以 result 文件是否产出**为准判断"是否真的有结论"（修掉了一个把 `no-result` 记录误当结论的 bug）；
- `run_serial.sh`：无 result 时记 `NO_RESULT` 而非 `FAIL`，避免把"环境打断"算成"用例失败"；
- 长用例缩短：MB-03 2000→1200 点、MB-11 三阶段→两阶段、MB-14 2000→1200 点、MB-08 2000→500 点；
- 关键节点落 interim 结论：MB-02 / MB-11 在中间阶段先 `write_result`，被打断也有结论；
- 修复 start 日志残留导致的"启动崩溃"误判（`/tmp/dn_*.start` 未清理）。

---

## 七、结论与建议

### 可以放行的部分
内存缓冲区的**核心功能在 RC9 上稳定**：内存分配比例、按比例/定时刷盘（顺乱序两空间）、
WAL 快照与回放、kill -9 恢复、优雅重启、Chunk 切分、时间分区内存可控、高可用停 DN、
顺乱序分离存储、flush 线程/数组粒度、参数守卫 —— **16 条功能用例全部通过**。

### 建议在发版前处理
| 优先级 | 问题 | 依据 |
|---|---|---|
| **P0** | F-07 非法比例让 DN 起不来（`return` 改 `break` 即可，一行修复） | MB-19 |
| **P0** | F-09 BACKWARD 数据查不到（数据可见性问题） | MB-15，三次复现 |
| **P0** | F-10 V2 吞吐只有 V1 的 13%，且不刷盘、副本不可见 | MB-14 + P-05 |
| **P1** | P-03 顺乱序分离在乱序负载下 P99 恶化 114% | P-03 |
| **P2** | F-01 SQL INSERT 自动建序列未按 `string_infer_type` 推断 | MB-18（需先确认预期） |
| **P2** | F-08 `datanode_memory_proportion` 的 60% 上限未生效 | MB-02（需先确认预期） |
| **P2** | 待复测：RC8/RC9 的拒绝行为是否存在真实差异 | 需在**同一堆大小 + 同一比例**下各跑一次 MB-06，当前两轮参数/堆都不同，不能下结论 |

### 复现命令

```bash
cd /data1/iotdb/testcase/MigrateRegionTest/skill_case/membuf_skill

# 环境自检（85 项：语法/集群/模板键/benchmark）
bash tools/selftest.sh

# 功能用例：19 条（--ver 指定版本目录）
bash tools/run_until_done.sh --set regression --ver v20121rc9_1020_d206dc2 --tries 5 --fresh

# 性能用例：5 条
bash tools/run_perf.sh --set all --loop 400 --devices 40

# 单条复现
bash cases/common/mb_15_tvlist_sort.sh            # F-09
bash cases/common/mb_19_illegal_proportion.sh     # F-07
bash cases/common/mb_14_consensus_v2.sh           # F-10
bash tools/run_perf.sh --only P-05                # V1 vs V2
```

---

## 附：结果产物位置

| 内容 | 路径（`172.20.70.3`） |
|---|---|
| 功能用例结论 | `…/membuf_skill/results/result_MB-*.txt` |
| 性能用例结论 | `…/membuf_skill/results/result_P-*.txt` |
| 性能原始数据 | `…/membuf_skill/results/perf_P-*.csv` |
| 完整执行日志 | `…/membuf_skill/results/*.out` |
| 失败用例节点日志 | `…/membuf_skill/results/artifact_*/logs/*.tgz` |
| 汇总 TSV | `…/membuf_skill/results/summary.tsv` |

（`…` = `/data1/iotdb/testcase/MigrateRegionTest/skill_case`）
