# 实测校准与坑（99.80 / 2.0.12.1 RC4 / 3C3D 三副本）

本文件记录 2026-09-29 在 99.80 上把用例调通时踩到的每一个坑，以及对应的写法。改用例前先看这里。

## 0. 测试环境时钟（已校正）+ DELETE 语法实测

### 时钟
校正前（相对本机北京时间，UTC+8）：99.80 **−7.2s**、.77 **+8.0s**、.78 **+0.8s**、.79 **−15.8s**，
**节点间最大差 23.8s**（没有任何"12 小时"级别的偏差，四台机器时区都是 Asia/Shanghai）。
已用 `date -s @<epoch>` + `hwclock -w` 校到北京时间，校正后四台偏差都在 **±1.5s** 内；
但 `timedatectl` 显示 `System clock synchronized: no / NTP service: inactive`，
**没有 NTP 在跑**，长时间测试前建议重新校一次或自行配上 NTP。

因为时钟已校正，`TTL_CASE_MS` 默认值可以取小（用例现用 30000，等待窗口 = TTL + 25s）；
若在未校正的环境跑，把 `TTL_CASE_MS` 放大到大于节点间最大偏差。

### DELETE / 元数据语句（本版本实测）
| 模型 | 语句 | 结果 |
| --- | --- | --- |
| 树 | `DELETE FROM <db>.<device>.** WHERE time <= T` | ✓ 生效；**注意必须带 `.**`**，写 `root.db.d1`（没有 `.**`）会被当成序列路径，0 行被删且不报错 |
| 树 | `DELETE TIMESERIES <device>.**` | ✓ 同时删数据与元数据，之后 `SHOW DEVICES` 不再列出该设备 |
| 表 | `DELETE FROM <table> WHERE time <= T` | ✓（需先 `use <db>`；DELETE 后要等同步收敛再断言） |
| 表 | `DELETE DEVICES FROM <table> WHERE dev = 'dN'` | ✓ 返回 `num_of_deleted_devices`；`WHERE dev IN (...)` 也可用 |
| 树/表 | `DROP DATABASE` 再 `CREATE DATABASE` | 树：TTL 规则**保留**（`SHOW ALL TTL` 仍有），重建后新数据按原规则过期；表：重建库的 TTL 会被新表继承 |
| 树/表 | 多值 INSERT（一条语句 500 行） | ✓ 2000 点约 7-9s；500 行 ≈ 0.6-2s |

DELETE 之后**必须等同步**：DELETE 走共识，目标副本可能尚未应用，立刻 count 会得到偏大的值
（实测表模型 DELETE 后立刻查是 1500/2000，等几秒后才是 1000/2000）。
`lib/common.sh` 提供 `wait_scalar_tree` / `wait_scalar_table` 做轮询等待（空结果按 0 处理）。

## 0.5 TTL 参数值 / 热加载（用例 `cases/common/ttl_param_effect.sh`，实测结论）

| 参数 | 热加载？ | 实测行为 |
| --- | --- | --- |
| `ttl_check_interval` | **否（需重启）** | `SET CONFIGURATION 'ttl_check_interval'='15000'` 返回 `Configuration has been set successfully, but restart is required for the following parameters to take effect: ttl_check_interval.`；**它会把新值写进 `iotdb-system.properties`**，重启后实测周期由 5s 变 15s（用该库 `[TTL] ... Start ttl and modification checking` 行数推算） |
| `enable_seq_space_compaction` / `enable_unseq_space_compaction` | **是（热加载）** | 关掉后：过期数据查询**仍被过滤**，但**不再物理清理**（无 settle 任务、TsFile 数不变）；`SET CONFIGURATION ...='true'` 后**立刻恢复清理**（几秒内出现 settle 任务、TsFile 减少）→ 证明热加载生效，也证明 TTL 物理清理受这两个开关门控 |
| `expired_data_ratio` | 否（重启） | ⚠️ **RC4 实测被短路，见 0.6 节（缺陷）**：只有把 `max_expired_time` 设为 `Long.MAX_VALUE`（`9223372036854775807`）时它才真正起作用 |
| `max_expired_time` | 否（重启） | 与 ttl 一起构成部分过期文件的**强制清理**条件：超期时间 `> min(max_expired_time, ttlThreshold)`。源码 L294 写的是 `ttlThreshold = 3 * ttl > ttl ? ttl : Long.MAX_VALUE`（本意 `3*ttl`，笔误成 `ttl`）⇒ 实际等价于"过期即清理" |

（三个键都可以用 **table 方言 `show configuration;`** 逐节点核对生效值与默认值：`lib/common.sh: ttl_effective_conf`；
tree 方言的 `show variables` 只返回集群级参数，不含这三个键。）

### 候选 ≠ 真任务，也 ≠ "门控生效"（判据别写错）
`[TTL] <db>-<region> Totally select N all-outdated files and M partial-outdated files.` 只是**选择器的候选统计**；
真正落地的是 `SettleCompaction task starts with X fully_dirty files and Y partially_dirty files`。统计口径：
`lib/common.sh: settle_task_for_db`（真任务）与 `ttl_sel_for_db`（候选）。

⚠️ **"没有 settle 任务"不能直接等同于"比例门控生效"**：还要先确认该副本的 TsFile **已落盘（Async close）**，
未关闭的文件根本不会进入选择（见 0.6 节实测：三个副本里只有先落盘的那个被选中）。
辅助函数：`ttl_close_cnt` / `ttl_close_snapshot` / `wait_ttl_closed`。

## 0.6 ⚠️ 缺陷：`expired_data_ratio` 对 TTL 过期设备失效（RC4 实测，2026-09-30）

`SettleSelectorImpl.selectFileBaseOnDirtyData()`（`iotdb-core/datanode/.../compaction/selector/impl/`）L276-L318：

```java
if (hasSetTTL) {
  if (!isDeleted) return NOT_SATISFIED;                    // 带 TTL 的设备还没过期 → 整个文件不选
  if (currentTime > endTime) {
    outdatedTimeDiff = currentTime - endTime;
    ttlThreshold = 3 * ttl > ttl ? ttl : Long.MAX_VALUE;   // ← 本意 3*ttl，实测写成 ttl
    hasExpiredTooLong |= outdatedTimeDiff > Math.min(max_expired_time, ttlThreshold);
  }
}
hasExpiredTooLong = (max_expired_time != Long.MAX_VALUE) && hasExpiredTooLong;
if (hasExpiredTooLong || deletedDeviceRatio >= expired_data_ratio) → PARTIALLY_DIRTY
```

`isDeviceAlive(device, ttl)` ⟺ `endTime >= now - ttl`，所以"设备被判过期"本身就等价于 `now - endTime > ttl`；
又 `min(max_expired_time, ttl) <= ttl` ⇒ `max_expired_time != Long.MAX_VALUE` 时
`hasExpiredTooLong` **恒为真**，比例门控被短路。责任提交：apache/iotdb **#14491**（`85f4bbbfba`，2025-02-18），
把 `Math.min(max_expired_time, 3 * ttl)` 改成上面的写法；上游 master 至今相同。

隔离实验（`tools/probe_ratio_isolate.sh`，TTL=120s、3 设备中 1 个带 TTL，文件内过期占比 1/2）：

| 相位 | `max_expired_time` | `expired_data_ratio` | 期望 | 实测 settle 增量 |
| --- | --- | --- | --- | --- |
| A | `3600000`（1h） | `0.99` | 不清理 | **1（被清理 = 缺陷）** |
| B | `9223372036854775807`（INF，关闭强制规则） | `0.99` | 不清理 | 0 |
| C | `9223372036854775807`（INF） | `0.0` | 清理 | 1 |

A 相证据：region 10 的 TsFile 里是 `d1`(有 TTL，已过期) + `d3`(无 TTL)，过期占比 1/2 = 0.5 ≪ 0.99，
日志 `[TTL] root.probe_a-10 Totally select 0 all-outdated files and 1 partial-outdated files`
→ `SettleCompaction task starts with 0 fully_dirty files and 1 partially_dirty files`，
清理后 `.resource` 里只剩 `d3`。而 `max_expired_time=1h` 也没到（elapsed ≈ 127s）。
⇒ 判定为**产品缺陷**（非用例语义问题）：`3*ttl` → `ttl` 的笔误；
**要用 `expired_data_ratio` 就必须先把 `max_expired_time` 设为 `Long.MAX_VALUE`**（默认 30 天 ≠ INF，所以默认就是"过期即清理"）。
`cases/common/ttl_param_effect.sh` Part C 已改成上述三相隔离（C1 断言不清理 → 当前版本 FAIL 即缺陷复现）。

### 修复后仍然稳健的写法（重要）
其余清理用例（`ttl_tree_expire` / `ttl_table_expire` 等）把 `expired_data_ratio` 设成**极小正数（默认 `0.000001`）**，
任何有设备过期的文件都满足 `ratio >= 1e-6` ⇒ 无论 `ttlThreshold` 是 `ttl` 还是（修复后的）`3*ttl`，
**过期后第一次检查就会清理**，所以这些用例在修复前后都能稳定 PASS。
⚠️ **绝对不要用 `expired_data_ratio=0.0`**：`deletedDeviceRatio(0.0) >= 0.0` 恒真，会让**零脏数据**文件
也被每个检查周期 settle 重写（见下），带来持续写放大，还会干扰 TsFile 计数类断言。
反之，**如果用例依赖"强制清理"分支**（例如 ratio 设得较大、只等 `max_expired_time`），
那就要注意修复后阈值会从 `min(max_expired_time, ttl)` 变成 `min(max_expired_time, 3*ttl)`，
等待窗口需要 ≥ `min(max_expired_time, 3*ttl)`（或干脆用"极小正 ratio" / 相位对照，不要依赖单一分支）。
判断某个文件该不该清理由哪条分支决定时，用 `tools/probe_ratio_isolate.sh` 的三相法最快。

### ⚠️ 缺陷 2：`expired_data_ratio=0.0` ⇒ "零脏数据文件"被反复 settle 重写（写放大）
同一函数 L306-L317：`deletedDeviceCount = 0` 时 `deletedDeviceRatio = 0.0`，
而 `0.0 >= expired_data_ratio(0.0)` 为真 ⇒ 返回 `PARTIALLY_DIRTY(dirtyDataSize=0)` ⇒ 生成 settle 任务。
实测（`max_expired_time=Long.MAX_VALUE`、`ratio=0.0`、`ttl_check_interval=15s`，节点 .78 的 `root.param_r3-14`）：

```
11:34:49 [TTL] root.param_r3-14 Totally select 0 all-outdated files and 1 partial-outdated files.
11:34:49 delete file: .../root.param_r3/14/2960/1790739278797-1-0-0.tsfile
11:35:04 delete file: .../1790739278797-1-1-0.tsfile
   ……每 15s 一代，到 11:40:12 已是 …-1-21-0.tsfile（21 代）
```

该文件里只有无 TTL 的设备 `d2`（`print-tsfile.sh` 可见），**没有任何需要清理的数据**却一直被重写。
规避：`expired_data_ratio` 用极小正数（本 skill 默认已改为 `0.000001`）；
断言 TsFile 数量/清理次数时，避免在 `ratio=0.0` 下取值。

### 测 TTL 检查周期的前提
DN 只对**既有数据、又挂了 TTL 规则**的 DataRegion 打 `[TTL] ... Start ttl and modification checking`。
空库（只有序列、没有写入）或没设 TTL 规则的库**不会**有这些行，
所以测周期前必须：建库 → 建序列 → `SET TTL` → 写 1 个点 → `FLUSH`，再开始计数。

⚠️ **测周期不要用"窗口内行数做除法"**：一个库可能有多个 DataRegion 各打一行，会把周期算成 1/N
（实测：配置 15s 被测成 6.7s，就是按 2 个 region 除了）。`lib/common.sh: measure_ttl_interval` 已改为
"取同一 `<db>-<region>` 相邻两条 `[TTL] ... Start ttl` 的时间差、只统计结束时间落在观察窗口内的差、取中位数"。

### ⚠️ 设备可能"独占一个 TsFile"（测比例门控必须注意）
设备按 hash 落到不同 DataRegion/TsFile。若某个"被判定过期/被删空"的设备**独占**一个 TsFile，
则 `deletedDeviceRatio == 1` ⇒ 直接 `FULLY_DIRTY`，`expired_data_ratio` / `max_expired_time` **都不参与判定**。
实测两种踩法：
- 用 `DELETE` 删空一个设备来测阈值 → 该设备独占文件 ⇒ `ratio=1` ⇒ 无论 `M=INF` 还是 `ratio=0.99` 都会被清理；
- 只建 3 个设备、仅 d1 有 TTL，d1 恰好独占文件 ⇒ 期望的"部分过期"没有出现。
⇒ 测比例门控请用**多设备**（本 skill 默认 12 个设备、仅 d1 有 TTL），并在判定失败时检查日志里是
`N all-outdated files`（整文件全过期 ⇒ 场景退化，结论无效）还是 `M partial-outdated files`。

### `flush;` 不保证所有副本"及时关闭"（实测踩坑，2026-09-30）
`Async close tsfile`（真正落盘）才让 TsFile 进入 settle 选择，但**一次 `flush;` 不保证三副本都在同一时刻关闭**：
实测同一库上 .78 在过期后 7s 就完成 settle，而 .77/.79 直到 **5 分钟后**才关闭/被 settle
（settle 任务排队 + 第二次 flush 触发关闭）。因此：
- 判定清理前用 `ensure_closed <db> [次数] [每次等待秒]`（内部反复 `flush;` + 等新的 close 事件）、
  `ttl_close_snapshot` / `wait_ttl_closed` 确认落盘；
- 断言"文件被删净"时，**只对 `ttl_close_cnt > 0` 的副本判定**，并给足窗口（实测需要 ≥5 分钟）；
- 反之，断言"没有清理"前若副本尚未落盘，结论是无效的（会误判成"门控生效"）。

## 1. 节点间时钟偏差 → TTL 观察窗口必须放大

实测 99.80 与三个节点、以及节点彼此之间的系统时间：

| 对比 | 偏差 |
| --- | --- |
| 99.80 → 192.168.99.77 | 节点快约 +15s |
| 99.80 → 192.168.99.78 | 节点快约 +9s |
| 99.80 → 192.168.99.79 | 节点慢约 -7s |
| 节点之间最大 | 约 22s |

TTL 判定用的是**执行节点自己的时钟**（`now - TTL`），而用例的时间戳是驱动机上 `date +%s%3N` 生成的，
因此 TTL 只要和偏差同量级，就会出现：

- **写完立刻查不到**（查询 DN 时钟快 → 数据"早就过期了"）：TTL=3000/10000 时反复出现；
- **该过期却还能查到**（查询 DN 时钟慢 → 数据"还没过期"）：TTL=3000 等 8s 仍可见。

**写法**：用例统一用 `TTL_MS=${TTL_CASE_MS:-60000}`（60s）与 `sleep TTL+6s`；
需要更快复跑时 `TTL_CASE_MS=45000`（仍要大于最大偏差 ~22s）。插入时间戳尽量**现算**（`$(now_ms)` 紧贴 INSERT）。

## 2. `SELECT count(*) FROM root.db.**` 返回**多列**（每序列一列）

```
|count(root.probe_c.d1.s1)|count(root.probe_c.d2.s1)|
|                        1|                        1|
```
所以不能拿"第一列"当总数。用例里：
- 需要总数 → `row_sum <输出>`（把第一行所有数值列相加）；
- 需要单值 → 直接查单设备/单表 `select count(*) from root.db.d1;`。

## 3. 过期清理的三类证据（用例都用）

| 证据 | 怎么取 | 说明 |
| --- | --- | --- |
| TTL 任务在跑 | DN `log_datanode_all.log` 里 `[TTL] <db>-<region> Start ttl and modification checking` 行数 | 每 `ttl_check_interval` 一轮，行数单调递增 |
| 挑中了过期文件 | 同上日志 `[TTL] ... Totally select N all-outdated files and M partial-outdated files.`，其中 `N>0` 的行数 | 用**行数**做基线比较，不要对"最近若干行求和"（会随时间漂移，曾导致误判超时） |
| 文件被物理删除 | **权威信号**：DN `log_datanode_all.log` 里 `SettleCompaction task starts with N fully_dirty files and M partially_dirty files`（N 或 M > 0 即选中）；配合 `find ... -name '*.tsfile' \| wc -l` 下降 | ⚠️ RC4 的 `log_datanode_compaction.log` 里**没有** `Settle task deletes fully_dirty tsfile` 这行（旧笔记写错了），不要用它当判据 |

注意：**部分过期文件是否清理由"比例门控 / 过期太久强制清理"决定**（见 0.6 节的缺陷说明）。
本 skill 把 `expired_data_ratio=0.0`、`max_expired_time=60000` 写进配置，让清理尽快发生（默认配置下"过期即清理"，所以清理类用例很稳）；
`ttl_check_interval=5000`（非热加载，必须启动前写）。
另外：**未落盘（未 Async close）的 TsFile 不参与选择**，用例等清理前必须先确认该副本的 TsFile 已落盘
（`ttl_close_snapshot` / `wait_ttl_closed`），否则会把"还没落盘"误判成"门控生效"。

## 4. 过期数据不能靠"插入旧时间戳"来构造

写入早于 `now - TTL` 的时间戳会**直接被拒**：树模型/表模型都是 `607`（`OUT_OF_TTL`）。
所以清理用例必须是：**写当前时间 → 设/调小 TTL → FLUSH → 等过期 → 查可见性 + 等 settle 删文件**。

## 5. 表模型语法与查询

| 项 | 实测写法 |
| --- | --- |
| 列约束 | `TAG` / `FIELD` / `ATTRIBUTE`（**不是** `ID`/`MEASUREMENT`；用 `id` 会报 700） |
| 建表带 TTL | `CREATE TABLE t (dev STRING TAG, v DOUBLE FIELD) WITH (TTL=60000)` |
| 改表 TTL | `ALTER TABLE t SET PROPERTIES ttl=60000` / `ttl='INF'` / `ttl=default` |
| 非法值 | `ttl=-1000` → 701；`ttl=0.001` → 701（DoubleLiteral）；`ttl=9223372036854775808` → 700 |
| 需要当前库 | 每条语句前要有 `use <db>;`；本 skill 用 `sql_lines_table` 把 `use` 和语句放**同一个 CLI 会话** |
| 看 TTL | `SHOW TABLES`（`TableName|TTL(ms)`）、`SHOW DATABASES DETAILS`、`select table_name, "ttl(ms)" from information_schema.tables`（**列名必须加双引号**）、`information_schema.databases` |
| 视图 | `CREATE WRITABLE VIEW v AS SELECT ... WITH (ttl=…)`、`ALTER VIEW v SET PROPERTIES ttl=…`；视图在 `information_schema.tables` 里 `table_type=WRITABLE VIEW`，`show tables` 也会列出 |
| OBJECT | 列类型 `OBJECT FIELD`；写入必须 `to_object(true, 0, X'62')`，裸元组 `(true,0,X'62')` 报错 |
| 库级 TTL | `CREATE DATABASE db WITH (ttl=…)` 只用于"继承/展示"；**表模型库级 TTL 不影响数据**，清理要靠**表**上的 TTL |

`information_schema.databases ... where database='x'` 这类过滤在本环境不可靠（返回空），
用例改成**查全量再用 `row_col` 按名字取行**。

## 6. 日志误报要过滤

`UNSET TTL` 一个不存在的规则会打 INFO：

```
SetTTLProcedure:110 - Failed to execute plan ...SetTTLPlan@... because Not TTL rule set
```

它的 logger 名里含 `SetTTL`、报文里含 `Failed`，会被 `TTL.*(failed|Failed)` 这类宽泛正则误判成异常。
`lib/common.sh` 里用 `BENIGN_PAT='Not TTL rule set|Failed to execute plan ...SetTTLPlan'` 过滤，
并把"忽略了多少条已知正常 INFO"打进 PASS 文案，便于审计。

## 7. 环境/框架相关

- 99.80 的 `clean_env/*.sh`、`prepare_env/start_cluster_v20.sh` 可能没有 +x 位 → 用 `-f` 判断存在性后 `bash <脚本>`，不要用 `-x`。
- 写配置文件必须 `ssh` + heredoc（`ssh host "DB=...; bash -s" <<EOF`）；**不能用带 `-n` 的 ssh 封装**，`-n` 会把 stdin 接到 /dev/null，heredoc 直接丢掉（曾导致配置没写进去、集群起不来）。
- 节点列表必须真拆分：`read -ra CN <<<"$CN_NODES"`（用 `printf '%s\n' "$CN_NODES"` 会把整串当一行）。
