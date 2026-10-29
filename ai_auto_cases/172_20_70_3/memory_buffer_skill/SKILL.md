# 内存缓冲区（MemTable / 写内存控制）专项 skill —— 操作手册（SKILL）

## 0. 一句话

3C5D（SchemaRegion 3 副本 / DataRegion 2 副本）上对 **内存缓冲区** 做可重复回归：
参数与比例 → 分配事实 → 刷盘（按比例/定时）→ 拒绝与背压 → WAL 快照与恢复 → 高可用 →
两套数据共识协议（**默认 IoTConsensus，其次 IoTConsensusV2**）；**每条用例都从干净集群开始**，
收尾固定三件套：`sync lag 归零` → `副本一致性（逐个停 5 个 DN）` → `CN/DN ERROR/WARN 异常日志分析`。

## 1. 快速开始（在客户端机 172.20.70.3 上）

```bash
cd /data1/iotdb/testcase/MigrateRegionTest/skill_case/membuf_skill

# 自检（不需要集群）
SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh
# 带集群/网络的自检
bash tools/selftest.sh

# 快速门禁（4 条，约 40~60 分钟）
bash tools/run_all.sh --set quick
# 全量回归（18 条）
bash tools/run_all.sh --set regression
# 按研发文档新增的 7 条
bash tools/run_all.sh --set doc
# 只跑某几条
bash tools/run_all.sh --only MB-01,MB-03
# 换协议（V2 必须单独跑一轮）
bash tools/run_all.sh --set regression --consensus IoTConsensusV2
# 换版本目录
bash tools/run_all.sh --set quick --ver v20121rc8_1016_ebaf9da

# 无人值守（注意：**不要** 用 setsid nohup + 断开 ssh，实测会被 SIGKILL；用 screen/tmux 或保持 ssh 存活）
screen -dmS mb bash tools/run_all.sh --set regression
```

> **绝对不要同时跑两个 `run_all.sh`**：每条用例都会"停集群 → 清 data/logs → 重启"，
> 并发时后启动的会把先启动的用例数据清掉。`tools/run_all.sh` 已内置 `flock`，第二个实例直接 `exit 2`。

## 2. 每条用例做了什么（固定骨架）

```bash
mb_load_env; mb_parse_args "$@"      # 读 conf/env.conf，解析 --consensus/--ver
mb_case_init MB-xx                   # 建 results/ 产物、清零 fail_flag
export MB_MEM_PROPORTION=...         # 本用例要测的参数（其余用 env.conf 默认）
mb_cluster_prepare                   # 停集群 → 清理 → 校验无残留进程 → 写配置 → 启动 → 核对干净
... 造数据 / 观测 / 断言 ...
mb_case_finish "<一致性校验 SQL>" tree   # sync lag → 逐个停 DN 比副本 → 日志异常 → 停集群 → 写结果
```

`mb_cluster_prepare` 的"干净"是**硬检查**：
1. 调框架 `clean_env/stop_cluster.sh`，再 `pkill -9` 兜底，然后**逐个节点校验 `jps` 里没有 IoTDB 进程**；
2. 调 `clean_env/clean_cluster.sh` 删 `data/` 与 `logs/`，再**逐节点断言 `data/` 目录已消失**；
3. **不调 `reset_conf.sh`**（见 §4 坑表第 1 条），改为按 `conf/env.conf` **全量生成** `iotdb-system.properties`，
   写完逐节点回读校验（含空值守卫）；
4. 启动后 `show cluster` 必须 8/8 Running，并核对"库数量 ≤ 2（`__audit`/`__system`）"。

## 3. 判据要点（写新用例照抄）

- **干净集群**：`data/` 不存在、无残留 JVM、启动后只有 `__audit`/`__system`；
- **参数生效**：逐节点 `grep` 回读 conf == 写入值；非法值场景要能看到对应的 WARN；
- **刷盘发生**：`flush_memtable_count_total` 增加 **且** TsFile 数增加；
- **定时刷盘**：在窗口内**不手工 flush** 也出现新 TsFile；关掉开关后同窗口不出现（对照组）；
- **数据不丢**：`select count(s1)` == 成功语句数 × 每语句行数（一条 INSERT 原子，不允许部分写）；
- **reject 可观测**：出现 `Change system to reject status`；压力解除后出现 `set system to normal status`；
- **WAL 回放**：kill -9 / 优雅重启后点数不变；
- **收尾三件套顺序固定**：sync lag（连续 3 次全 0）→ 副本一致性（基准取自"flush + 逐副本可见 + syncLag 归零"之后）
  → 日志（`ERROR|WARN` 行里命中异常特征才算失败，已排除已知正常日志）；
- **协议口径**：V2(batch) 只复制已 seal 的 TsFile，未 seal 的 memtable 尾部**不在 follower、也不计入 syncLag**
  ⇒ 取一致性基准前必须先 `flush` 并等逐副本行数收敛，否则必然假不一致。

## 4. 踩坑清单（本轮实测，新增用例前先读）

| 坑 | 现象 | 处理 |
| --- | --- | --- |
| **框架 `reset_conf.sh` 会把集群配坏** | 本环境 `conf_orig/iotdb-system.properties` 是 tar 包原始配置（`cn_seed=127.0.0.1`、`schema/data_replication_factor=1`）。调用后 CN 互相找不到、RF 变单副本 | 本 skill **不调** `reset_conf.sh`；每次从 `conf/env.conf` 全量生成 conf |
| **memtable 默认 ~1.9GB，写满要 GB 级写入** | 本环境堆 20G（手工设置；发布包默认按机器内存自动算）、比例 `1:5:1:1:1:1` ⇒ write≈2G、memtable≈1.9G；按比例刷盘要写 760MB，单条用例不可接受 | 用"放大比例分母"把 memtable 压到 20~100MB（如 `1:1000:1:1:1:1` ⇒ write≈21MB），再配合 `flush_proportion`/`reject_proportion` 压阈值 |
| **`reject + wal + device >= 1` 会整体回退默认值** | 想靠 `reject_proportion=0.95` 造场景时，三项相加 ≥1 ⇒ 打 WARN 并全部回退成 0.8/0.1/0.05，场景失效 | `reject_proportion` 必须 < 0.85；造压力宁可缩小 memtable |
| **比例写入非法值不会报错，只 WARN 回退** | `storage_engine_memory_proportion=0:10`、`write_memory_proportion=0:1` 都被静默回退默认值（`use default value 8:2` / `19:1`） | 这类"非法值"用例的判据就是**找那条 WARN**，不要期待 INSERT 报错 |
| **`datanode_memory_proportion` 的 storage 占比 > 60% 会被限幅** | `dangerous_mode=false` 时 storage engine 最大只给堆的 60%，并打 `limited to 60% of the DataNode heap` | 用例要么断言"被限幅到 60%"，要么把比例控制在 60% 以内 |
| **树方言 `show configuration` 直接语法错** | `show configuration` 在 tree 方言下报 `700: no viable alternative at input 'show configuration'` | 一律用表方言：`start-cli.sh -sql_dialect table -e "show configuration;"`（`sqt`/`sqt_node`） |
| **TEXT 写入必须分片**（客户端侧限制） | 单条 INSERT 1.96MB 实测 52s 且 **ok=0 静默失败**；一次喂 10MB SQL 直接客户端 `OutOfMemoryError` | `mb_bulk_text` 已固化：单语句载荷 ≤256KB、每次 CLI 调用 4 条语句；2000 点×4KB 实测 146s 全成功 |
| **大结果集查询会被截断** | `select s1 ...` 输出 ~8MB 时只回 1000/2000 行 ⇒ 假"数据丢失"；大 bash 变量还可能把用例 OOM 成 rc=137 | 数据量/一致性判据一律用通配聚合 `select count(s1) from <db>.**`（`mb_data_sql`） |
| **树方言聚合只有 `<db>.**` 可用** | `from db.d1.s1`、`from db.*.**` 都是 `Empty set.` | 同上，统一走 `mb_data_sql` |
| **`pkill -f 'mb_xx.sh'` 会自杀** | 在 run_all 里"清理遗留用例"会误杀正在跑的用例 | 已移除；用 `tools/cleanup_strays.sh --force` 人工清理 |
| **`rc=137` 不等于用例死了（孤儿进程）** | run_all 报 `Killed`，但用例继续以 PPID=1 孤儿身份跑完并写 `RESULT PASS`；孤儿会在下一轮与新用例抢同一集群 ⇒ 新用例"莫名 Killed / 写入=0" | `run_all.sh` 启动时 `cleanup_orphans`（只杀 PPID==1）；`rc=137` 时改为轮询用例自己的 `result_*.txt`，以用例结论为准 |
| **远程 `setsid nohup ... &` 起的用例会在写入阶段被 SIGKILL（rc=137）** | 同样的命令"保持 ssh 会话"前台跑 100% 正常（MB-03 前台实测 162s 写完 2000 点、31 条语句全成功）；断链方式跑的会在写入阶段被 kill，且 dmesg 无 OOM 记录 ⇒ 属 ssh 会话/cgroup 回收，不是用例本身的问题 | 用 `screen -dmS mb ...` 或让发起端 ssh 一直挂着；`tools/run_all.sh` 顶部注释已写明 |
| **多值 INSERT 少逗号** | `700 ... mismatched input '('`，TsFile 一直为 0 | 多值必须 `values (t1,v1),(t2,v2),…`（`mb_bulk_text`/`mb_bulk_int` 已处理） |
| **框架 `start_cluster.sh` 会打 `801 Authentication failed`** | 它先用 `root/root` 改密码；本版本默认口令已是 `TimechoDB@2021`，于是这一步必失败（但不影响启动） | 本 skill 用**自己的** `cluster_start`，只起进程 + 轮询 `show cluster`，不碰口令 |
| **停节点后立刻查询会查到"还没停干净"的节点** | 副本一致性会假 PASS | `wait_dn_state <ip> notrunning` 等到 `show cluster` 变 `Unknown` 再查 |
| **`stop-datanode.sh -f` 是 `kill -9`** | 想"优雅重启"却用了 `-f`，语义写错 | 优雅重启不带 `-f`（`mb_restart_dn`）；要模拟宕机才用 `pkill -9`（`mb_kill9_dn`） |
| **并发跑两个 run_all** | 互相清 data/logs，表现为离奇的 `550: Table does not exist`、点数突然归零 | 已加 `flock`；分批调试等前一批跑完 |
| **收尾一致性要停/起 5 轮 DN** | 每轮约 10~60s，整段 3~6 分钟，属正常 | 看 `<CASE>_*.out` 里 `--- 停 DataNode x.x.x.x（第 n/5 轮）---` 判断进度，别以为卡住 |
| **`show cluster` 里被停节点会短暂保持 Running** | 判定"停成功"过早 | `wait_dn_state` 轮询到状态变化，窗口 `DN_DOWN_WAIT_SEC` |

## 5. 结果怎么读

1. `results/test_result.csv`：`Time,build,consensus,caseName,result,elapsedSeconds,failCount,artifact,message`；
2. `results/<CASE>_<runid>.out`：完整输出，用例判定行是
   `RESULT PASS|FAIL fail_flag=N case=... consensus=... build=... elapsed=...s`；
3. FAIL 行都写了"实际 vs 期望"；
4. 失败时自动把各节点 `logs/` 打包到 `results/artifact_<case>_<runid>/logs/`；
5. `results/SUITE_<set>_<runid>.out`：整个集合的串行汇总。

## 6. 覆盖矩阵与配套文档

| 文档 | 内容 |
|---|---|
| [INDEX.md](INDEX.md) | 用例清单、参数覆盖矩阵、观测手段、**研发文档条目→用例映射**、性能对比口径 |
| [docs/FINDINGS.md](docs/FINDINGS.md) | 本轮发现的 11 条结论，含 **3 条高严重级**（F-07 起不来 / F-09 BACKWARD 查不到 / F-10 V2 劣化） |
| [docs/PLM_TICKET_F-07_LOGGING.md](docs/PLM_TICKET_F-07_LOGGING.md) | **PLM 提单**：配置非法致启动退出时异常未写入 logs/（含隔离复现与对照组证据） |
| [docs/DEFECT_F-09.md](docs/DEFECT_F-09.md) | **缺陷报告**：BACKWARD 排序导致查询 301「blocks should never be zero」+ flush 不落盘、数据丢失 |
| [docs/RCA_IOTV2_PIPE.md](docs/RCA_IOTV2_PIPE.md) |
| [docs/ANALYSIS_WRITE_SLOW.md](docs/ANALYSIS_WRITE_SLOW.md) | 写入慢的根因：CLI 经 JLine 逐字符处理脚本输入（客户端 CPU 打满、约 57KB/s），DataNode 空闲；非死锁、非内存、与 V1/V2 无关 |
 根因分析：V2 复制通道未建立——归一化只覆盖 DN 实例化与持久化属性，唯 ConfigNode 的 V2 region 判定漏做；含在线取证与诊断方法 |
| [docs/DEFECT_F-10.md](docs/DEFECT_F-10.md) | **缺陷报告**：IoTConsensusV2 BATCH 模式下 DataRF=2 实际只有一个副本有数据，停该副本即不可见 |
| [docs/DEFECT_F-07.md](docs/DEFECT_F-07.md) | **缺陷报告**：非法内存比例致 DN 起不来（源码定位 + 调用栈 + 修复补丁 + 验收矩阵） |
| [docs/REPORT_RC9.md](docs/REPORT_RC9.md) | **RC9 测试报告**（最新）：24 条用例、总耗时、逐条结果、失败定性、RC8→RC9 对比 |
| [docs/RESULTS.md](docs/RESULTS.md) | RC8 全量实跑结果：19 条功能 + 5 条性能 |
| [docs/CALIBRATION.md](docs/CALIBRATION.md) | 本环境实测数字（内存分配基线、写入吞吐、分片口径、协议类名） |
| [docs/VALIDATION.md](docs/VALIDATION.md) | 本轮哪些用例真正跑过、结果与证据、哪些判据被修正 |
| [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) | 环境坑与处置（含 rc=137 与 systemd-run 的定位过程） |
| [docs/PERF.md](docs/PERF.md) | 性能对比（iot-benchmark）的口径、变体、判据与限制 |

## 7. 边界（本 skill 不覆盖）

- **老化长测**：文档要求"长时间运行无异常"，本 skill 只有单次用例，不含 24h+ 长跑；
- ~~性能倍数判定~~：已由 `tools/run_perf.sh` + `cases/perf/P-01..P-05` 覆盖（见 `docs/PERF.md`），
  判据是"相对同轮基线不显著劣化"，不是绝对吞吐；
- **部署/安装与手册一致性**：不属于本 skill 范围。

> 研发文档已抓取到 `../feishu_docs/membuf/`（8 篇），**覆盖矩阵按文档逐条对齐**，
> 映射表见 `INDEX.md` §五；实测中发现的与文档不一致之处见 `docs/FINDINGS.md`。
- **性能基线/吞吐对比**：内存缓冲区有自己的 benchmark 场景（`benchmark/bm_20251017_b6be9bd`），
  本 skill 只做功能与稳定性回归，不做吞吐门槛判定。
- **极端 OOM**：不制造真正的堆 OOM（会把节点打挂、污染后续用例）；只覆盖"内存控制拒绝写入"这条受控路径。
