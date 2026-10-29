---
name: ttl-autotest
description: TimechoDB/IoTDB TTL（数据过期清理）自动化测试 skill：在 3C3D 三副本集群上跑树模型/表模型的 TTL 基本功能、参数值、过期数据清理正确性用例，并统一做 sync lag 归零、副本一致性、CN/DN 异常日志分析。默认 data consensus=IoTConsensus，可用 --consensus IoTConsensusV2 显式切换。表模型覆盖 OBJECT，树模型覆盖 OBJECT 不支持的负向验证。可整体拷到其他环境，只改 conf/env.conf。
---

# TTL 自动化测试 skill

## 何时用
- 需要在集群上验证 TTL（`SET TTL` / 表 TTL / 视图 TTL / OBJECT TTL）的功能与**过期数据清理正确性**；
- 需要把 TTL 用例做成可重复、可迁移、带证据（查询结果 + 磁盘文件 + 日志）的自动化用例；
- 需要在 TTL 场景下同时验证 **sync lag 归零、副本一致性、CN/DN 无异常日志**。

## 依赖
- 目标集群：TimechoDB/IoTDB 2.0.12.1（本 skill 在 RC4 `v20121rc4_0924_18cf11b` 上验证），3C3D、SchemaRegion/DataRegion 3 副本。
- 驱动机（跑脚本的机器）：
  - 能 ssh 到所有节点（默认 `BatchMode=yes` 免密；可用 `SSH_OPTS` 覆盖）；
  - 有该版本的 shell 客户端（`SHELL_CLIENT_DIR/<V_TESTDB>/sbin/start-cli.sh`）；
  - `USE_FRAMEWORK=1` 时目标机上还要有 autotest 框架（`clean_env/`、`prepare_env/start_cluster_v20.sh`），99.80 就是这种；其他环境用 `--framework 0` 走 skill 自带的 ssh 启停逻辑。
- 节点上 `find`/`grep`/`sed`/`tar` 可用；sync lag 检查需要 DataNode exporter（`dn_metric_prometheus_reporter_port`，默认 9092）可从驱动机访问。

## 快速开始
```bash
cd <skill>/ttl-autotest-skill
vi conf/env.conf                 # 改集群 IP、版本目录、密码、副本数、共识协议、TTL 参数
bash tools/run_all.sh --set quick                # 冒烟：树+表基本功能（IoTConsensus）
bash tools/run_all.sh --set all                  # 全部用例（默认 IoTConsensus）
bash tools/run_all.sh --set threshold            # 只跑文件级清理阈值/写放大守卫（缺陷回归门禁）
bash tools/run_all.sh --consensus IoTConsensusV2 # 同用例集换成 IoTConsensusV2
bash tools/run_all.sh --consensus IoTConsensus,IoTConsensusV2   # 两种协议各跑一遍
# 单跑某个用例：
bash cases/tree/ttl_tree_expire.sh --consensus IoTConsensusV2
# 调试：复用当前已运行集群，不重启（快很多）
SKIP_LIFECYCLE=1 bash cases/table/ttl_table_basic.sh
```

## 目录
```
conf/env.conf                  环境与参数（迁移只改这里）
lib/common.sh                  公共库：生命周期/SQL/断言/TTL 证据/sync lag/副本一致性/日志/结果
cases/tree/ttl_tree_basic.sh   树模型 TTL 基本功能与参数值（database/设备/序列）
cases/tree/ttl_tree_expire.sh  树模型 过期清理正确性（可见性/边界/物理删除）
cases/tree/ttl_tree_scope.sh   树模型 作用域语义（root.**→库→设备 继承与覆盖、热更新、UNSET 后重新可见、边界错误码）
cases/tree/ttl_tree_dml.sh     树模型 大数据量 + DELETE 数据/元数据 + DROP 重建 × TTL
cases/table/ttl_table_basic.sh 表模型 TTL 基本功能与参数值（库/表/视图）
cases/table/ttl_table_expire.sh表模型 过期清理正确性
cases/table/ttl_table_cleanup.sh 表模型 清理阈值 + 写放大守卫（与 TP-02 对应）
cases/table/ttl_table_object.sh表模型 OBJECT × TTL
cases/table/ttl_table_dml.sh   表模型 大数据量 + DELETE 数据/DELETE DEVICES + DROP 重建 × TTL
cases/cases.tsv                 机器可读用例矩阵（case_id/脚本/模型/粒度/是否重启/参数/期望），脚本走查与回归选型看它
cases/common/ttl_param_effect.sh TTL 参数值/热加载/重启生效（ttl_check_interval、compaction 开关门控、expired_data_ratio 三相隔离）
cases/common/ttl_cleanup_threshold.sh 文件级清理阈值矩阵 + 零脏数据写放大守卫（缺陷回归门禁）
cases/common/ttl_param_effect_mode.sh expired_data_ratio 的生效方式（restart-only）+ 数值语义（10 设备保证"部分过期"可观测）
cases/common/ttl_dup_region_register.sh **TDB-610 门禁**：同一 DataRegion 是否被重复注册到压缩/TTL 调度列表（判据=每 region 的 Start ttl 行数÷不同秒数，1.00 正常 / 2.00 命中）
cases/common/ttl_tier_warn_key.sh **TDB-611 门禁**：tier_ttl_in_ms 与 dn_data_dirs 不匹配时的 WARN 文案必须写 tier_ttl_in_ms、不得写已移除的 default_ttl_in_ms
tools/run_all.sh               批量执行 + 汇总（--set quick|tree|table|dml|param|threshold|defect|all）
tools/selftest.sh              harness 自检：用例语法、日志正则、show configuration 解析、assert 框架、跨用例重名、写配置 round-trip
tools/probe_ratio_isolate.sh   单点诊断：expired_data_ratio 生效条件三相隔离（A/B/C），出表直接给研发
tools/probe_sql.sh             语法/行为探针：作用域继承、SHOW 语句列、表模型属性、边界错误码（写新用例前先跑）
docs/DESIGN.md                 用例矩阵与断言策略（先读这个）
docs/CALIBRATION.md            实测校准与坑（时钟、DELETE 语法、清理判据、0.6 节：expired_data_ratio 缺陷）
docs/TTL_SOURCE_FINDINGS.md    源码级语义结论（影响断言的关键点）
results/                       运行产物：<case>_<runid>.out、artifact_*/、test_result.csv
```

## 每个用例都做什么
1. **集群准备**：停集群 → 清 data/logs → 恢复 `conf_orig` → 写参数（IP/3 副本/共识协议/metrics 端口 + `ttl_check_interval` / `max_expired_time` / `expired_data_ratio`）→ 启动 → 等 `show cluster` 全 Running。
2. **功能/参数断言**：TTL 规则增删查、参数边界、错误码（303/508/607/612/700/701）。
3. **数据正确性断言**：过期数据查询不可见、未过期数据仍在、过期时间戳写入被拒、FLUSH 后物理清理（TsFile 计数 + `[TTL]`/`Settle task deletes fully_dirty tsfile` 日志）。
4. **收尾三件套**（每个用例都跑）：
   - `check_sync_lag`：抓每个 DataNode 自身 exporter 的 `iot_consensus{type="syncLag"}`，要求全部为 0 且连续 3 次稳定；
   - `consistency_check <SQL> <tree|table>`：全部在线时各副本比对，再**逐个停 DataNode** 用剩余副本查，结果必须与基准一致；
   - `check_logs`：扫 CN/DN 日志的常见异常 + TTL 专项异常（`FAILED_TTL_DELETION`、`TTL.*failed` 等），并统计 `Start ttl and modification checking` 次数作为 TTL 任务确实跑过的正证据。
5. **失败留证**：把 CN/DN 日志打包到 `results/artifact_<case>_<runid>/logs/`，并保留每一步 SQL 原始输出与断言明细。

## 结果
- `results/test_result.csv`：`Time,build,consensus,caseName,result,elapsedSeconds,failCount,artifact,message`
- `results/result_<case>_<runid>.txt`：单次结果（含 artifact 路径）
- `results/<case>_<runid>.out`：完整过程日志（含每条 SQL 输出与 FAIL/WARN 原因）

## 写用例时必须知道的坑
1. CLI **不解析** `now()-3000`：树模型报 700、表模型报 305。用例一律用**显式 epoch 毫秒**（`now_ms` 辅助函数）。
2. `sleep N;` 是 otf 工具的伪指令，不是 SQL；脚本里用真实 `sleep`。
3. `information_schema` 的列名是 `"ttl(ms)"`，**必须加双引号**。
4. 表模型列约束是 `TAG/FIELD/ATTRIBUTE`（不是 ID/MEASUREMENT）；OBJECT 列必须用 `to_object(true, 0, X'62')` 写入。
5. 表模型每条语句前要有当前库：本 skill 用 `use <db>;` + 语句在**同一个 CLI 会话**里执行（`sql_lines_table`）。
6. **不能靠插入旧时间戳测清理**（早于 `now-TTL` 会被 607 拒写）；清理用例 = 写当前时间 → 设小 TTL → `flush` → 等过期 → 查可见性 + 等 settle 删文件。
7. **节点间时钟最大差 ~22s（本环境实测）**，TTL 判定用执行节点自己的时钟，所以观察窗口必须远大于偏差：用例默认 `TTL_CASE_MS=60000`；要跑快可用 `TTL_CASE_MS=45000`（仍须 > 22s）。
8. `SELECT count(*) FROM root.db.**` 返回**每序列一列**的多列结果，取总数要用 `row_sum`。
9. TTL 物理删除依赖 seq/unseq compaction 开启（默认 true）与 `ttl_check_interval`；本 skill 把 `ttl_check_interval` 调到 5s、`expired_data_ratio` 调到 0 让清理尽快发生（**非热加载，必须启动前写**）。
10. OBJECT 文件删除有 **60s 缓冲**（`now-TTL-60s`），用例需等 ~T T L+60s 以上，可用 `OBJ_WAIT` 调整（默认 240s）。
11. `SHOW TTL ON <path>.**` 命中已知缺陷 **TDB-444**（【V2.0.12.1】【树模型】把权限范围路径当查询路径下发，
    于是 `SHOW TTL ON root.tree.g_0.**` **返回一堆不相干的全局 TTL 规则**）。
    用例**不**用它做"包含类"断言；该缺陷的回归门禁是 `cases/tree/ttl_show_ttl_scope.sh`（TT-05），
    判据是"**输出里不得出现不相干库的规则 / `root.**` 全局规则**"——只断言"包含本设备规则"抓不到它
    （缺陷版本会把所有规则都吐出来）。规则断言用 `SHOW ALL TTL` / `SHOW DEVICES` / `information_schema`。
11b. 四个 TTL 相关缺陷的回归门禁（PLM 单号见括号，可用 `--set defect` 一次跑完）：
    **TDB-452** ① 过期比例门控失效 → `cases/common/ttl_param_effect.sh` r1（判据看 `partial 候选` 数）；
    **TDB-452** ② `ratio=0` 时反复重写无脏数据文件 → `cases/common/ttl_cleanup_threshold.sh` D 相、`cases/table/ttl_table_cleanup.sh` D 相；
    **TDB-610** 同一 DataRegion 被注册两次（每周期检查两遍）→ `cases/common/ttl_dup_region_register.sh`（判据=每 region `Start ttl` 行数÷不同秒数，≥1.5 命中）；
    **TDB-611** tier 校验 WARN 文案写已移除的旧键 → `cases/common/ttl_tier_warn_key.sh`（判据=WARN 里不得出现 `default_ttl_in_ms`、应出现 `tier_ttl_in_ms`）。
    修复后这些断言应从 FAIL 转 PASS。
12. 表模型**库级 TTL 不影响数据**（只有表 TTL 生效），库级 TTL 只用于"继承/展示"断言。
13. `UNSET TTL` 不存在的规则会打 INFO `SetTTLProcedure ... Not TTL rule set`，日志扫描里已按 `BENIGN_PAT` 过滤。
14. ⚠️ **`expired_data_ratio` 在 RC4 上被短路**（缺陷，`SettleSelectorImpl` L294 `ttlThreshold` 把本意的 `3*ttl` 写成了 `ttl`）：
    `max_expired_time != Long.MAX_VALUE`（默认 30 天）时，只要文件里有一个 TTL 设备过期，下一次 `ttl_check_interval` 就会被 settle
    ⇒ **默认行为就是"过期即清理"**。要验证比例门控必须设 `max_expired_time=9223372036854775807`。
    用例 Part C 用 A/B/C 三相隔离该机制（详见 `docs/CALIBRATION.md` 0.6）。
15. **"没有清理" ≠ "门控生效"**：只有 `Async close`（落盘）过的 TsFile 才进入 settle 选择。
    判定前先确认目标副本已落盘（`ttl_close_snapshot` / `wait_ttl_closed`），否则会把"还没落盘"误判成"门控生效"（本项目踩过）。
16. 核对参数**真正生效**的值要用 **table 方言 `show configuration;`**（三列 `name|value|default_value`，含上述三个键）；
    tree 方言 `show variables` 只返回集群级参数，不含它们（helper：`ttl_effective_conf`）。
17. ⚠️ **`expired_data_ratio` 不要设 0.0**：`deletedDeviceRatio(0.0) >= 0.0` 恒真，会让"零脏数据"文件
    每个检查周期都被 settle 重写一次（实测 21 代/15s 的写放大）。本 skill 默认已改为极小正数 `0.000001`。

## harness 自身的坑（改 lib/用例前必看；`bash tools/selftest.sh` 会自检其中大部分）
1. `set -u` 下不要写 `local a=$1 b=$(( ... a ... ))`：bash 先展开全部词再执行赋值，会报 `a: unbound variable`
   （本项目在 `wait_ttl_closed` 里踩过，整条用例直接中断）。拆成两句赋值。
2. `cluster_set_conf` 的远端脚本用**未加引号的 heredoc** 传递：heredoc 内的变量会被**本地**展开，
   未定义变量在 `set -u` 下会让**所有**用例写配置失败（`EXTRA_CONF` 就这么踩过）。
   需要追加配置请用 `EXTRA_CONF="k1=v1,k2=v2"`（lib 会在 heredoc 之外用独立 ssh 追加并逐节点校验）。
3. 用例必须**串行**跑：日志计数（`settle_task_for_db` 等）与 TsFile 计数是全库/全节点维度，并行或叠加会互相污染。
   外部强杀用例时记得 `pkill` 掉集群进程（`pkill -f '[c]om.timecho.iotdb.DataNode'`，用 `[]` 防止匹配自身）。
4. 断言"没有清理"之前，必须确认目标副本的 TsFile 已 `Async close`（`ttl_close_snapshot` / `wait_ttl_closed`），
   未落盘的文件不参与 settle 选择——否则会把"还没落盘"误判成"门控生效"。
5. 参数**真正生效**的值要用 table 方言 `show configuration;` 逐节点核对（`ttl_effective_conf`）；
   写文件成功 ≠ 生效（用例在每相都会逐节点断言）。
6. `tools/selftest.sh` 里有一条"故意失败必须让 `fail_flag>0`"的检查——对应"用例什么都不跑却 exit 0 看起来像通过"这一类陷阱。
7. **不要在用例运行中修改该用例的脚本文件**：bash 是边读边执行的，覆盖文件会让它读到错位内容并报莫名其妙的语法错
   （本项目实测：用例跑完收尾时崩在 `|| fail ...` 上，且不会写 CSV 结果）。调度新版本请等当前用例结束。
8. **测 TTL 检查周期不要用"窗口内行数 ÷ 窗口"**：多 DataRegion 各打一行会把周期算成 1/N（实测 15s → 6.7s）。
   用 `measure_ttl_interval`（按 `<db>-<region>` 相邻两条的时间差取中位数）。
   **IoTConsensusV2 下每个检查周期会打两条 `Start ttl`（相差约 1ms）**，相邻差里会混进 0s 把中位数拉低
   （实测 15s 被测成 7.5→8s）⇒ `measure_ttl_interval` 已过滤 < 2s 的差（等价"同一 tick 只算一次"）。
9. **测比例门控必须避免"设备独占 TsFile"**：设备独占时 `deletedDeviceRatio = 1` ⇒ `FULLY_DIRTY`，
   `expired_data_ratio`/`max_expired_time` 都不参与判定（用 DELETE 删空设备、或只给 1 个设备挂 TTL 都踩过）。
   请用多设备（`RATIO_DEVS` 默认 12），**并且给多数设备挂 TTL**（TP-03 现在挂前 `DEVS-2` 个），
   然后检查日志是 `partial-outdated` 还是 `all-outdated`。
10. **判"比例门控是否生效"只看"含部分过期文件"的 settle**：`settle_partial_task_for_db`（日志里
    `SettleCompaction task starts with ... and [1-9]+ partially_dirty files`）。整文件全过期走 `FULLY_DIRTY`、
   **合法绕过** ratio，用 `settle_task_for_db` 总数判定会把这种合法清理误判成门控失效（V2 实测踩到）。
   用例在只出现整文件全过期时会 PASS + `WARN ... 场景退化`，看到该 WARN 说明**本相没有验证到门控**。

11. **不要用 `$(函数)` 捕获"函数内部还会 log 的返回值"**：`log()` 同时写 stdout 与 `$OUT`，命令替换会把日志文本
    和返回值一起捕获（TP-04 首跑因此把"最大比值"读成一段文本、判定分支走错）。这类函数请改成**写全局变量**
    （如 `MEASURE_MAX=$v`）而不是 `echo`。
12. **`consistency_check` 需要"数据查询"**：给它 `show cluster;` 这类输出会把刚停掉的节点算成不一致
    （TP-05 首跑因此多出 6 条 FAIL）。没有业务数据的用例请用 `post_checks ""` 跳过副本一致性那一步。
13. **复现 TDB-610 的构造手法**：把某库所有 region 的 `system/databases/<db>/<regionId>/FileTimeIndexCache_0`
    挪走再启动，即可让该 region 走「同步恢复」⇒ 触发重复注册；该文件只是时间索引缓存，用例结束务必还原
    （`ttl_drop_time_index_cache` / `ttl_restore_time_index_cache`）。判据：`ttl_check_ratio`（每 region
    `Start ttl` 行数 ÷ 不同秒数）最大值为 1.00 正常、≥1.5 命中。

更细的实测校准（时钟偏差数值、清理三类证据、表模型语法与查询、日志误报）见 `docs/CALIBRATION.md`。

## 迁移到其他环境
1. 拷贝整个 `ttl-autotest-skill/` 目录；
2. 改 `conf/env.conf`：`CLUSTER_NODES/CN_NODES/DN_NODES`、`DB_PARENT_DIR`、`SHELL_CLIENT_DIR`、`V_TESTDB`、`ROOT_PW`、`SCHEMA_RF/DATA_RF`、`DATA_CONSENSUS`；
3. 非 99.80 框架环境加 `--framework 0`（或 `USE_FRAMEWORK=0`）；
4. 先 `bash tools/run_all.sh --set quick` 验证连通性，再跑全量。
