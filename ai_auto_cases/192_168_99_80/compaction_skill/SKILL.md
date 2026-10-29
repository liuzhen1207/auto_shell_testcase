# 合并专项 skill —— 操作手册（SKILL）

## 0. 一句话

3C3D 三副本上跑**合并**的回归用例：先保证"合并基本功能没问题"（smoke），再验证参数/热加载、
提供性能基准、覆盖缩容场景；**每条用例都做统一收尾**（sync lag → 副本一致性 → 日志异常）。

## 1. 快速开始

```bash
# 部署（本机 -> 99.80）
scp -r D:\IDEA\deepseek\ip99_80\compaction_skill root@192.168.99.80:/data/iotdb/autotest/

# 自检（不需要集群）
cd /data/iotdb/autotest/compaction_skill && SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh   # 期望 ok=132 failed=0

# 必跑集合（基本功能冒烟，8 条）
bash tools/run_all.sh --set smoke
# 其它集合
bash tools/run_all.sh --set param                 # CO-09/CO-10 参数与热加载
bash tools/run_all.sh --set perf                  # CO-11 性能基准
bash tools/run_all.sh --set remove                # CO-12 缩容（跑完集群变 2C2D，放最后）
bash tools/run_all.sh --set ttl                   # CO-13/CO-14 TTL 场景（TTL 过期清理 + 在线合并）
bash tools/run_all.sh --set combo                 # CO-15/CO-16/CO-17 参数**组合**测试（门控矩阵/优先级/selector×performer/chunk/非法值/层级边界/cross 上限）
bash tools/run_all.sh --set param2                # CO-18~CO-26/CO-32 **逐参数基础功能**（优先级/乱序选择/目标文件大小/总大小上限/候选队列/线程族/对齐批量/限流/settle 门控/自动修复）
bash tools/run_all.sh --set scene                 # CO-27~CO-31 基础形态与生命周期（no-op/空库/全删/多时间分区/表模型 unseq+cross/崩溃恢复/插入式 cross/并发读写）
bash tools/run_all.sh --set all                   # 全部 16 条

# 单条 / 换协议 / 换版本
bash tools/run_all.sh --set smoke --only CO-01
bash tools/run_all.sh --set smoke --consensus IoTConsensusV2
bash tools/run_all.sh --set smoke --ver v20121rc5_1003_aaf460d

# 无人值守跑完整套（冒烟 → 参数 → 性能 → 缩容，单进程串行；约 1.5h）
setsid nohup bash tools/run_full_chain.sh /tmp/co_full.log >/dev/null 2>&1 &
bash tools/progress.sh /tmp/co_full.log          # 看阶段 / 各用例 PASS-FAIL / 当前用例 tail
```

> **绝对不要同时跑两个 `run_all.sh`**：每条用例都会"停集群 → 清 data/logs → 重启"，
> 并发时后启动的那个会把先启动的用例数据清掉（表现为离奇的 `550: Table ... does not exist`、
> 合并计数突然归零、集群被对方停掉）。`tools/run_all.sh` 已内置 `flock` 并发锁，
> 第二个实例会直接 `exit 2`；分批调试请**等前一批跑完**再启下一批。

结果：`results/test_result.csv`（build/协议/用例/结果/耗时/fail 数/产物/message）、
`results/<ID>_<runid>.out`（完整输出）、`results/SUITE_*.out`（集合汇总）、`results/perf_baseline.csv`（性能基线）。
用例判定行：`RESULT PASS|FAIL fail_flag=N case=... consensus=... build=... elapsed=...s`。

## 2. 结果怎么读

1. 先看 `results/test_result.csv` 的 `result/failCount`；
2. 再看 `<ID>_*.out` 里 `FAIL` 行 —— 每条 FAIL 都写了"实际 vs 期望"；
3. 收尾三件套的顺序固定：`sync lag` → `副本一致性`（逐个停 DN）→ `CN/DN 日志异常`；
4. 失败时会自动把三节点 `logs/` 打包到 `results/artifact_<case>_<runid>/logs/`；
5. 合并是否真的发生：搜 `合并任务累计（全部 DN、全部库）：starts=… finishes=…` 与 `InnerSpaceCompaction task finishes successfully`。

## 3. 判据要点（写新用例时照抄）

- **合并发生**：`finishes` 行数增加 **且** 该库 TsFile 数下降（两个信号同时成立）；
- **数据不变**：同一条 SQL 的归一化结果（`cmp_fingerprint`）合并前后**完全一致**；
- **数据不复活**：DELETE / DELETE TIMESERIES / DROP TABLE 之后合并，被删对象/行数不得回退；
- **无卡死**：`jstack` 里卡在 `TsFileResource.writeLock` 的线程数为 0；
- **参数生效**：`show configuration` 的生效值 = 写入值；负向对照（关掉/调大 → 不合并）；
- **热加载**：CLI 响应不含 `restart is required` ⇒ 生效值必须**立即**变化；含 ⇒ 生效值必须**保持不变**。

## 4. 踩坑清单（本轮实测，新增用例前先读）

| 坑 | 现象 | 处理 |
| --- | --- | --- |
| **多值 INSERT 少了元组间逗号** | 写入报 `700 … mismatched input '(' expecting {<EOF>, ';'}`，TsFile 一直为 0 | 多值必须是 `values (t1,v1),(t2,v2),…`（`cmp_write_tree_batch` 已修） |
| **节点上有残留 CN/DN 进程** | 框架 `start_cluster_v20.sh` 的 `while true; do show cluster; done` **永久卡住**（它没有超时） | `cmp_cluster_prepare` 启动前 `pkill` 残留进程；并给框架启动脚本加 `timeout` |
| **逐条 `sq` 写入太慢** | 每条语句都会新起 CLI/JVM，写入耗时被启动开销主导 | 性能/大批量写入用 `cmp_bulk_tree_session`（单会话喂多条语句） |
| **表模型建表语法** | `create table t (time timestamp, dev tag, v int64)` 会静默失败（CLI 退出码仍 0） | 用 `create table <db>.<表> (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD)`，并校验 `show tables` |
| **建用户密码长度** | `<12` 位报 `820: The length of password must be greater than or equal to 12` | 用 ≥12 位密码 |
| **表模型结果集列序** | 实际列比需求文档多一列 | 取值按**列名**解析（`du_col_*`/`cmp_*` 的做法） |
| **Windows 换行** | 脚本带 CRLF 时远端 `bash` 报 `syntax error near unexpected token '${\r''` | 写入后统一 LF（本仓库脚本已是 LF；用工具改文件后注意检查） |
| **`flush;` 不保证马上落盘** | 未 `Async close` 的文件不参与合并选择 | `ensure_closed`（反复 flush + 等新的 close 事件），失败只 WARN |
| **停 DN 后立即查询** | 可能查到"还没停干净"的节点 | `wait_dn_state` 等 `show cluster` 状态变更后再查 |
| **缩容后不能再用全量节点列表** | 被移除节点上的进程/数据仍在本地，会把计数与一致性判据带偏 | REMOVE 之后把 `DN` 数组切换为剩余节点，收尾用 `check_sync_lag_on`/`consistency_check_on`/`cmp_check_logs_on` |
| **并发跑两个 `run_all`（2026-10-12 真实踩到）** | 后启动的用例 `cmp_cluster_prepare` 清 data/logs 时把先启动用例的数据清掉：CO-02 收尾"停 1 个 DN 再查"报 `550: Table 'cosmoketb.t1' does not exist`（假 FAIL），合并计数同时变成 `starts=0 finishes=0`；先启动用例收尾的"停止集群"又把后启动用例刚起好的集群停掉 | `tools/run_all.sh` 加 `flock -n` 并发锁（`results/.run_all.lock`，拿不到锁 `exit 2` 并提示持有者）；整套跑用 `tools/run_full_chain.sh`；**不要手工分批并发启动** |
| **收尾的一致性校验要停/起 3 轮 DN** | 每组"停 1 个 DN → 查 → 起回来"约 6s~90s（起回 DN 要等注册），整段收尾可能 3~5 分钟 | 这是正常的，别以为卡住；调 `CO_MERGE_WAIT_SEC` 之类不解决，看 `<ID>*.out` 的 `--- 停 DataNode x.x.x.x ---` 行判断进度 |
| **多相用例：每一相写入前都要重新关一次合并** | 上一相 `cmp_compaction_on` 之后没关，下一相的数据在**写入期间**就被合并完 ⇒ 记完基线不再推进 ⇒ 假 FAIL（CO-05/CO-06 首轮各中一次） | 每一相写入前显式 `cmp_compaction_off` |
| **指纹要在本相"全部写入完成之后"采集** | 先取指纹、后补写同一设备 ⇒ 合并后比对必然不一致（CO-06 首轮假 FAIL） | 指纹一律放在写完之后、`cmp_compaction_on` 之前 |
| **设备级通配计数恒 0** | `select count(s1) from db.d1.**` 实测返回 0 | 用显式序列路径 `select count(s1) from db.d1.s1` |
| **DELETE 边界差 1 行** | 写入时间戳从 `k=0` 开始，`delete … where time <= BASE+HALF*10` 会多删 1 行/设备 | 用严格小于 `<`，期望值 `DEVS*(ROWS-HALF)` |
| **DELETE 元数据后整批重写** | `DELETE TIMESERIES d2.**` / `DELETE DEVICES …dev='d1'` 之后写回 `d1..dN`，插入会把被删的时序/设备**自动建回来** ⇒ "合并后不得复活"的断言被自己的写入打破 | 跳过被删设备逐设备写入 |
| **跨空间合并"不触发"像缺陷其实是参数** | 只有 1 个 unseq 文件/region 时 cross 永不发生：小文件必须先内部合并过（`min_cross_compaction_unseq_file_level`，默认 1，源码 `RewriteCrossSpaceCompactionSelector:306`） | 构造 ≥2 个 unseq 文件让它升级，或把该参数设为 0（CO-04 两相就是这么做的） |
| **TTL 三个参数不能用 `EXTRA_CONF` 写** | `cluster_write_conf` 用 **env 值**逐节点校验 `ttl_check_interval`/`max_expired_time`/`expired_data_ratio` ⇒ 写进 EXTRA_CONF 会报"写入不匹配" | `export TTL_CHECK_INTERVAL_MS=5000` 等环境变量覆盖 |
| **改正在跑的用例脚本** | 就地 `scp` 覆盖会让运行中的 bash 读到错位内容 | `tools/install_staged.sh`：暂存 → 同目录 `cp` 隐藏名 → `mv -f` 原子替换 |
| **`SET CONFIGURATION '<键>'=''`（空值）会把 DN 起挂** | 用于"还原一个原本不存在的键"时写成 `key=` 行 ⇒ DN 热加载报 `NumberFormatException: For input string ""`／`No enum constant CompactionPriority.`，**重启直接起不来**（实测 CO-10 首轮把 2 个 DN 搞挂，后续用例连锁 FAIL） | 原值为空时**不要还原**；探测后重写一遍 conf；`cluster_write_conf` 已加空值守卫（`^[a-z_]+=$` 直接 fail）；救急用 `tools/fix_broken_conf.sh`（`conf_orig` 还原） |
| **树方言：具体设备路径上的聚合返回空集** | `select count(s1) from db.d1.s1` 与 `select count(s1) from db.d1.**` 都返回 `\|Time\| Empty set.`（聚合被当原始查询，**忽略聚合**）；只有 `select count(s1) from db.**` 通配才给每序列一列 | 单设备行数用**原始查询数行**：`sq "select s1 from db.d1 order by time;" \| table_rows \| wc -l` |
| **未来时间戳永远不过期** | TTL 用例里把批次写成 `NOW + 1000000`（未来 16 分钟）⇒ `now-ts<0<ttl` 恒不过期，"TTL 调小后 count 应为 0"永远不成立 | 新鲜批次写"过去但很近"的时间戳（`NOW-20s` / `NOW-10s`） |
| **TTL/settle 是"文件级"的，不是逐行** | `SettleSelectorImpl.selectFileBaseOnDirtyData()` L255~260：设了 TTL 的文件里**只要有一个设备还有未过期数据，整个文件直接 NOT_SATISFIED**。所以"同一设备写 48h 前的点 + 当前点"或"过期设备与新鲜设备被合并进同一文件"都会得到 `[TTL] … Totally select 0 all-outdated files and 0 partial-outdated files`，永不清理 | 构造 TTL 清理场景必须让**过期数据单独成文件**：先写过期数据 → 等 settle 清完 → 再写新鲜数据（CO-13/CO-14 的做法）；另注意 settle 需要 `enable_seq_space_compaction`/`enable_unseq_space_compaction` 至少一个为 true |
| **"重启后再取基线"会漏掉已完成的事** | CO-04 Phase B：`min_cross_compaction_unseq_file_level=0` 重启后 cross 在几秒内就做完了（finishes 0→12），此时再取基线 ⇒ 永远"没有推进" | 基线一律取**动作发生之前**的值（CO-04 用 Phase A 的 `cross0`） |
| **3 副本 + 3 DN 不允许 REMOVE DATANODE** | `1003: Cannot remove 1 DataNode(s): the cluster has 3 available DataNode(s) and must retain at least 3 …` | 这是产品该有的保护：CO-12 先做"负向守卫"断言被拒，再把 `SCHEMA_RF/DATA_RF` 降到 2 重启后做真正的缩容 |
| **`SET CONFIGURATION` 不校验取值（研发已确认：设计如此）** | 非法值（`compaction_priority=BOGUS`、`inner_seq_selector=bogus`、`compaction_thread_count=abc`）会被写进各节点 properties（有的连 CLI 都返回成功，有的返回 301 但**文件已改**）⇒ 之后 DN 热加载报 `IllegalCompactionSelectorNameException` / `NumberFormatException`、**重启起不来**（`System.exit(-1)`；CO-16 第一次跑把 2 个 DN 搞挂） | **不作为缺陷跟踪**（研发已知）。用例侧必须自清理：非法值探针后**立刻 SET 回合法值** + 段末逐节点 grep 复查（只查未注释行）；收尾"停/起 DN + 一致性"就是隐式硬门禁。详见 `docs/NOTE_set_configuration_value_validation.md` |
| **unseq 内部合并要求文件区间重叠** | 两批"都更早但互不重叠"的乱序数据（`now-40000` 与 `now-20000`）不会触发 unseq 内部合并（CROSS/seq 场景里 non-overlap 的 unseq 反而能被 cross 处理），造场景时易误判成"合并没跑" | 造 unseq 场景：先写 1 批**水位**（当前时间）→ 再写 2 批**互相重叠**的更早数据（如 `now-20000`、`now-19500`） |
| **组合参数用逗号分隔时别忘了拆词** | `for kv in $EXTREME`（`EXTREME="a=1,b=2"`）拿到的是**一整个字符串**，逐键校验恒 WARN | `for kv in $(printf '%s' "$EXTREME" \| tr ',' ' ')` |
| **`inner_seq_selector` 的取值 ↔ 实现类是反直觉的**（2026-10-13 定位） | `size_tiered_multi_target`（**模板默认值**）→ `NewSizeTieredCompactionSelector`：**只有它会读** `max_level_gap_in_inner_compaction` 与 `inner_compaction_total_file_num_threshold`，也才会把不同层级的文件并到一起；`size_tiered_single_target` → 经典 `SizeTieredCompactionSelector`：只用 `inner_compaction_candidate_file_num` + `target_compaction_file_size`，**完全不跨层级**。第一版 CO-17 §1 把 selector 设成 `single_target` 去测 gap ⇒ 等于把被测参数摘掉，判据必然失败（我当时还怀疑是产品缺陷） | 测这两个键必须用**默认的 multi_target**；权威映射见 `compaction/selector/constant/InnerSequenceCompactionSelector.java:52-60`（master 同） |
| **`show configuration` 只列"properties 文件里出现过的键"** | 没写进文件的键读回来是**空串**（实测 `cross_selector=`、`inner_compaction_total_file_num_threshold=` 都是空）；`cmp_eff` 拿它判"生效值"会假 FAIL。而 `SET CONFIGURATION` 会把键写进文件 ⇒ SET 之后又能读到 | 只对**自己写进 conf** 的键断言生效值；默认值场景改用行为判据（或先 SET 一次把键落进文件） |
| **副本布局不可控：`flush;` 返回后 TsFile 仍是 UNCLOSED/可追加** | 只等"文件出现"就写下一批 ⇒ leader 2 个文件、follower 1 个文件（两批数据被追加进同一个 TsFile，数据都在但布局乱了）⇒ 层级/合并判据全乱（CO-17 第二次跑就是这么挂的） | 每批写完先 `ensure_closed`（等 close 事件）**再**写下一批；用**单设备**（只落 1 个 region）让布局可预测；并把"各副本布局一致"作为**场景有效性**断言（CO-17 的 `co17_wait_lay`） |
| **写 in-order 数据才落 `sequence/`** | 时间戳比已落盘水位更早的批次落 `unsequence/`（两个空间各自独立合并、层级互不相干）——把 seq/unseq 文件混在一个场景里判"层级分布"必然错 | 造层级（段 1/2）：批次时间戳严格递增；造 unseq（段 3）：先写"水位"批（当前时间）再写更早且**互相重叠**的批次 |

## 5. TTL 场景用例（CO-13/CO-14）的设计要点

要验证的是"**TTL 过期清理（settle 合并）与在线合并的组合**"，判据分六段：

1. 两批数据都可见（TTL 未设时 count = 2×DEVS×ROWS）；
2. 设 TTL 后过期批次在**查询侧**被过滤（count = DEVS×ROWS）；
3. settle 合并**物理清理**过期文件：`SettleCompaction task starts` 行数增加 **且** 该库 TsFile 数下降；
4. TTL 生效期间热开在线合并（seq/unseq/cross）→ 合并完成、未过期数据指纹不变、过期数据不复活；
5. 把 TTL 调到 30s → **合并产物**也必须被 TTL 清理（count=0、TsFile 归零）——
   这条专门盯"合并产物是否带对了 TTL/脏数据信息"；
6. UNSET TTL / 改回 `'INF'` 后 count 必须仍为 0（过期数据已被物理删除，合并没有复活它）。

设计上的两个关键点：

- **时间戳一次算好，不靠"写完等过期"**：批次 B1 = `now - 48h`、批次 B2 = `now`，TTL=24h
  ⇒ B1 必然过期、B2 在用例期间必然不过期。这样既不用等待，也规避节点间 ±20s 时钟偏差
  （TTL skill 里为了构造"刚过期"要等 TTL+25s，这里不需要）。
  TTL 必须在写入之后才设（`set ttl to <db> <ms>`），否则写 `now-TTL` 之前的数据会被 607 拒绝。
- **TTL 三个参数走环境变量**：`export TTL_CHECK_INTERVAL_MS=5000`、
  `export MAX_EXPIRED_TIME_MS=9223372036854775807`、`export EXPIRED_DATA_RATIO=0.000001`
  （`cluster_write_conf` 用 env 值逐节点校验这三个键，写进 `EXTRA_CONF` 会报"写入不匹配"；
  ratio 用 `1e-6` 而不是 `0`，避免 TTL skill 记录的"零脏数据文件被反复 settle"写放大）。

## 6. 如何扩展用例

1. 新建 `cases/<tree|table|common>/co_xxx.sh`，骨架固定：

```bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"; . "$HERE/../../lib/cmp.sh"
cmp_load_env; cmp_parse_args "$@"; cmp_case_init "co_xxx_${DATA_CONSENSUS}"
EXTRA_CONF="$CMP_EXTRA_CONF" cmp_cluster_prepare      # 需要自定义参数就改 EXTRA_CONF
... 造场景 / 触发合并 / 断言 ...
post_checks "<带 ORDER BY 的确定性 SQL>" tree|table   # 统一收尾（必写）
cmp_case_finish "" tree|table ""
```
2. 在 `cases/cases.tsv` 增加一行（ID、脚本、模型、粒度、是否自启停、关键参数、说明）；
3. `tools/run_all.sh` 的集合里挂上新 ID（`smoke`/`basic`/…）；
4. 跑 `SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh`（会检查语法、矩阵一致性、统一收尾是否漏写）；
5. 先在集群上单跑一遍（`--only`），再纳入集合。

## 7. 环境信息（当前）

- 集群：3C3D（192.168.99.77/78/79，各 1 CN + 1 DN），RF=3，data region 协议默认 `IoTConsensus`；
- 版本开关：`/data/iotdb/autotest/conf/test.conf` 的 `v_testdb`/`v_commit`（`--ver` 会覆盖 skill 侧变量，但框架启停仍读 test.conf，
  换版本时请同时改 test.conf，或参考磁盘占用 skill 的 `run_gate_versions.sh` 写法自动切换）；
- 部署路径：`/data/iotdb/autotest/compaction_skill`；本机：`D:\IDEA\deepseek\ip99_80\compaction_skill`；
  交付归档：`D:\IDEA\deepseek\compaction\compaction_skill`。

## 8. 层级 gap / 任务文件数上限 / cross 候选上限的**边界**用例（CO-17，2026-10-13）

`cases/common/co_param_level_boundary.sh`。CO-09/CO-10/CO-15/CO-16 只能证明这些键"改了有变化"，
CO-17 用精细场景把**边界值**顶住：

| 段 | 场景 | 断言（都在 RC6 实测过） |
| --- | --- | --- |
| 1-A | 各副本造 `[L1(旧), L0(新)]`（写 2 批 → 合并出 L1 → 关合并 → 再写 1 批） | `gap=0`：`\|0-1\|=1 > 0` ⇒ **不合并**（finishes 不增 + 布局不变）；热改 `gap=1` ⇒ 合并并产出 **L2** |
| 1-B | 再造 `[L2(旧), L0(新)]` | `gap=1`：`\|0-2\|=2 > 1` ⇒ **不合并**；热改 `gap=2` ⇒ 合并并产出 **L3** |
| 2① | `threshold=2` + `candidate=3` + 3 个 L0 | 任务**最多 2 个文件**（日志 `starts with 2 files`）、3→2 个文件；2 < 门槛 3 **仍被提交** ⇒ 非活跃分区时 `candidate` 门槛被绕过（源码 `\|\| !isActiveTimePartition`） |
| 2② | `threshold=100` + `candidate=2` + 3 个 L0 | 一个任务收 **3 个文件**（`starts with 3 files`）、3→1 个文件 ⇒ 上限随配置放大 |
| 3-A | 1 seq 水位 + 3 个落在水位区间内、互相重叠的更早 unseq | `max_cross_compaction_candidate_file_num=2` ⇒ 每个任务只收 **1 个 unseq**（分布 `1×18`）、任务数 18 |
| 3-B | 同上 | `num=500`（默认）⇒ 一个任务收下**全部 3 个 unseq**（分布 `3×6`）、任务数 6 |
| 3-C | 同上 | `num=500` 但 `max_cross_compaction_candidate_file_size=1B` ⇒ 仍只收 **1 个 unseq**（第一个 unseq 无条件入选，其余被 size 卡住） |

> 日志里"每任务 unseq 数"来自 `[Compaction] CrossSpaceCompaction task starts with N seq files and M unsequence files`；
> `cmp_log_files` 同时含 `log_datanode_all.log` ⇒ 绝对条数按 2 倍记（`1×18` = 9 个真实任务），
> 所以 CO-17 的断言只看分布最大值与任务数的相对大小。
> **unseq 必须与 seq 时间区间重叠**：不重叠时会走 `getLatestSealedSeqFile()` 特殊路径，上限给 500 也收不满 3 个。

**场景构造三要素**（换成别的环境/版本照抄这三条，否则场景会退化）：
① 单设备 → 每个副本只有一个 data region，文件数可控；
② 批次时间戳**严格递增**（落 `sequence/`），要 unseq 就写"比水位更早且互相重叠"的批次；
③ 每批 `ensure_closed`（等 close 事件）之后才写下一批，并断言**各副本层级布局一致**（场景有效性）。
另外段 2 的两个子场景必须把 `max_level_gap_in_inner_compaction` 固定为 0，否则合并后的
`[L1, L0]` 会在同一段里继续并成 L2，布局断言就不成立了。

