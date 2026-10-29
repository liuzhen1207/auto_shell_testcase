#!/bin/bash
# ============================================================================
# W-14 无效 WAL 清理（delete_wal_files_period_in_ms 热加载；树模型；库名 root.walcln）
#
# 【用例】W-14（集合 cleanup；cases/cases.tsv W-14 行）
#   目标：**同一次运行内 A/B 对照** ——
#     · A 段（库 root.walcln）：写入后**不 flush**（MemTable 未刷盘 ⇒ 其覆盖的 WAL 记录仍有效，**不得被删**）；
#     · B 段（库 root.walclnb）：写入后 `flush` + `ensure_closed`（数据落盘 ⇒ 对应 WAL 记录变**无效**）
#       → 把 `delete_wal_files_period_in_ms`（hot_reload）调小 → 观察窗口内 B 的文件数/字节**下降**。
#   反向断言（本用例的灵魂）：**A 段未被 flush 的 WAL 一个字都不得少**。
#
# 【覆盖需求 / 源码依据】
#   · design_extract.md §5.1（无效的定义）：「一个 WAL 文件是否可以被删除由其对应的 MemTable 刷盘状态决定：
#     其对应的 memtable 中只要有一个没有刷盘，此 WAL 文件就不能被删除」；记录级定义：「当数据成功落盘后，
#     其对应的 WAL 日志记录就是无效的」。
#   · design_extract.md §5.2：`delete_wal_files_period_in_ms`（**热加载**，默认 20000ms）——
#     "对 WAL 文件进行归档，删除无效的 WAL 文件的间隔"；（§8.3 TP-19/TP-21/TP-22）。
#   · source_grounding.md §6.1（**定案**）：删除线程注册与热改后**重启线程**：
#     `WALManager.java:168-179/320-325`（`SafelyScheduleWithFixedDelay`，period = 该键）；
#     `IoTDBDescriptor.java:2711-2715` 热改后 `rebootWALDeleteThread()`；日志文案
#     `Reboot wal delete thread successfully, current period is {} ms`（INFO，§10.1 第 9 条）——
#     **仅作"热加载确实重启了删除线程"的弱证据**。
#   · source_grounding.md §6.2（**可删判定**）：`WALNode.java:671-676 canDeleteFile()` =
#     （`fileArrIdx < fileIndexAfterFilterSafelyDeleteIndex` **或** `walFileStatus == CONTAINS_NONE_SEARCH_INDEX`）
#     **且** `versionId < subscriptionRetainedMinVersionId` **且** `!isContainsActiveOrPinnedMemTable(versionId)`；
#     候选集合是 `sortedWalFilesExcludingLast`（**最后一个/活动文件不参与删除** ⇒ 场景必须让 B 段**发生轮转**，
#     否则每个库只有 1 个文件，什么都不可能被删）；IoTConsensus 下 `safelyDeletedSearchIndex` 被设为
#     `Long.MAX_VALUE`（`FirstCreateStrategy.java:60-61`、`DataRegion.java:811`）⇒ 该合取项退化为
#     "**只有文件名第 3 段 = 0（statusCode=0）的文件可删**"；`isContainsActiveOrPinnedMemTable` 读不出时
#     **保守保留**（`WALNode.java:657-669`）。
#   · source_grounding.md §6.3/§6.4 与 design_extract.md §5.4：文件"删不掉"的三种正交原因
#     （MemTable 未刷盘 / 被 pipe pin 住 / 已被 IoTConsensus 消费完之前）——三种**都没有对外指标**，
#     所以本用例的判定必须落到"目录面 + 权威文件指标"上。
#   · source_grounding.md §9：`file_count{name="wal"}` / `file_size{name="wal"}`（CORE 级 AutoGauge）
#     是最权威的文件面证据（**全局口径**，不含库维度）。
#   · source_grounding.md §3.4 与 **REQ_MATRIX 源码复核**：文件名 = `_<versionId>-<startSearchIndex>-<statusCode>.wal`
#     （statusCode ∈ {0,1}，`WALFileUtils.java:65-83`）；**文档口径分裂**：设计文档写的是 `_[version_id].wal`
#     —— 本用例一律按**源码形态**解析，并在现场对不匹配的名字记 WARN（不当判据）。
#
# 【⚠️ 本版本无法成立的期望（务必不要写成"文件清零"）】
#   `WALNode.java:671-676`：**statusCode=1 的文件、以及"最后一个 WAL 文件"恒被保留**
#   （候选集合是 `sortedWalFilesExcludingLast`）⇒ 在 IoTConsensus 下"flush 之后 WAL 目录清零/为空"
#   **永远不成立**。所以本用例的断言只能是 **"文件数/字节相比基线下降"**（② 就是这么写的），
#   并把**基线值与当前值两套数字 + 保留下来的文件名**都打印出来；清掉的应是
#   "version_id 小于 min(各 MemTable 首个 WAL version_id)" 的那些文件（design_extract §5.2）。
#
# 【判据（硬/软分明；FAIL 只来自清理方向 / 反向误删 / 数据面 / 场景有效性）】
#   ① 场景有效性（硬）：
#      a) A/B 两段写入点数与值总和都等于离线核算值（写入丢失/被拒 ⇒ 场景无效）；
#      b) A 段与 B 段的**本库** WAL 都 ≥ WAL_CLEAN_MIN_FILES（默认 2）且字节 > 0
#         —— 必须发生轮转：候选集合排除了最后一个文件，只有 1 个文件时"删除"根本无从发生；
#      c) `delete_wal_files_period_in_ms` 调小后**运行期生效值 == 目标值**（读不到或没变 ⇒ 配置没生效 ⇒ FAIL；
#         用例会先按 hot_reload 直接热改，失败再补一次 stop/start，仍不行才判 FAIL）。
#   ② 清理方向（硬）：观察窗口内 B 段"目录口径"文件数**或**字节下降。
#      若一个都没降：先探测 B 段是否存在 `statusCode=0` 的文件（IoTConsensus 下唯一可删形态，§6.2）——
#      · 有 status=0 文件 ⇒ `fail`（可删的无效 WAL 没被清理）；
#      · 完全没有 status=0 文件 ⇒ 记 `warn "不可构造（原因+证据）"`（本环境 WAL 文件全为 status=1，
#        `canDeleteFile` 的第一个合取项对 IoTConsensus 退化为只认 status=0），不判 FAIL。
#   ③ 反向断言（硬）：A 段未被 flush 的 WAL **不得被误删** —— A 段文件数与字节都不小于清理前。
#      若 A 段反而下降，先用"该库是否出现了新的 `Async close`（TsFile 落盘）事件 / TsFile 数是否增加"
#      判断 A 段的 MemTable 是否被系统自己刷盘了：是 ⇒ 记 `warn "场景退化（A 段已被刷盘，前提不再成立）"`；
#      否 ⇒ `fail "未 flush 的 WAL 被误删"`（这是本用例要守的正确性）。
#   ④ 数据面（硬）：窗口前后 A/B 的 count/sum 与指纹完全一致、且等于期望值（清理不得动数据）。
#   ⑤ 只 WARN：指标口径（全局 `file_count`/`file_size`）与目录口径方向不一致；
#      单次窗口内没等到清理（网络/负载引起的延迟）；V2 单副本不落盘。
#
# 【刻意不做的事（口径纪律）】
#   · **不断言** `WALNode.java:466-470` "Successfully delete {} outdated wal files" 文案
#     —— 源码 §10.8 定案：DEBUG 级、默认 `<root level="info">` **不落盘**，拿它当判据必然恒为 0。
#     （用例只统计删除线程重启的 INFO 文案作弱证据，且不据此判 PASS/FAIL。）
#   · 不把 "WAL 文件数必须降到 0" 当判据（活动文件 + 未过期文件本来就该保留）。
#   · 为了把"定期删除"与"有效信息比触发的快照/刷盘"两条机制隔离开，本用例把
#     `wal_min_effective_info_ratio` 设成极小值（1e-6，源码校验 `> 0` 才生效）⇒ 删除线程不会走
#     `shouldSnapshotOrFlush()` 分支（`WALNode.java:506-510`），A 段不会被系统主动刷盘。
#   · 不改 lib/、tools/、conf/、cases.tsv、docs/（只新增本文件）。
#
# 【时长大致】≈22~30 分钟（准备 ~4min + A 段写入/稳定 ~5min + B 段写入/flush/落盘 ~6min
#   + 热改周期 + 观察窗口 ≤${WAL_CLEAN_WIN_SEC}s + 收尾三件套 ~4min）。
#
# 【⚠️ 首轮 watch list（先看这些才知道"场景真的成立了"）】
#   1) **B 段到底有没有可删文件**：看产物里 B 段（${DBB}）的文件清单与第 3 段（statusCode）分布。
#      若全为 1 ⇒ 用例按 ② 的降级分支记 WARN；若存在 0 却仍未下降 ⇒ 看三种"删不掉"的原因
#      （尤其 IoTConsensus 未消费完 `endFileIndex < filesToDelete.length`，§5.4 原因 3）。
#   2) **轮转是否真的发生**：两段的文件数都应 ≥ 2（阈值 = WAL_ROTATE_THRESHOLD_SMALL 默认 1MB）。
#      若文件数恒 1 ⇒ 数据量不足或目录/库名过滤不对（会以"场景无效"FAIL，此时看打印的文件清单）。
#   3) **热改生效链**：`SET CONFIGURATION 'delete_wal_files_period_in_ms'` 的返回文案 + 生效值 +
#      各 DN 日志里 `Reboot wal delete thread successfully` 的行数（三条一起看）。
#   4) **A 段会不会被系统刷盘**：窗口结束时 A 段的 `Async close` 事件数/TsFile 数是否变化 ——
#      若变了说明"未刷盘"前提没保住（用例会记场景退化 WARN，不会误判成误删）。
#   5) **指标口径**：`file_count{name="wal"}`/`file_size{name="wal"}` 是**全局**口径（不含库），
#      首轮把窗口前后的原始值记下来，确认它与目录口径（本库/整目录）的方向关系。
#
# 用法： bash cases/common/wal_cleanup_period.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 本文件**未在真实集群实跑过**（99.80 正在跑合并长回归，禁止任何集群启停/清库动作）；
#     只保证逻辑自洽 + `bash -n` 通过 + harness 自检不退化。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"

# harness 侧防御：conf/env.conf 未定义这三个 TTL 键，而 lib/common.sh 的 cluster_set_conf 会引用它们
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"
export TTL_CHECK_INTERVAL_MS MAX_EXPIRED_TIME_MS EXPIRED_DATA_RATIO

cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_cleanup_period_${DATA_CONSENSUS}"

DB=root.walcln                        # A 段：写入后**不 flush**
DBB=root.walclnb                      # B 段：写入后 flush + ensure_closed（库名仍在 root.wal* 约定内）
DEVS=${W14_DEVS:-${WAL_ROTATE_DEVS:-10}}
ROWS=${W14_ROWS:-${WAL_ROTATE_ROWS:-4000}}            # 每条 INSERT 的行数（大语句 ⇒ 撑起 WAL 轮转）
BATCHES=${W14_BATCHES:-${WAL_ROTATE_BATCHES:-3}}
THRESH=${W14_WAL_THRESHOLD:-${WAL_ROTATE_THRESHOLD_SMALL:-1048576}}   # 1MB：让两段都发生轮转
MINF=${WAL_CLEAN_MIN_FILES:-2}                        # 候选集合排除最后一个文件 ⇒ 至少要有 2 个
SMALL=${WAL_CLEAN_PERIOD_SMALL_MS:-2000}              # 调小的删除周期（hot_reload）
WIN=${WAL_CLEAN_WIN_SEC:-180}                         # 观察窗口（秒）
STABLE_WIN=${W14_STABLE_WIN_SEC:-60}                  # WAL 观测量稳定窗口
CLOSE_WIN=${WAL_CLOSE_WIN_SEC:-60}
RATIO_TINY=0.000001                                   # 把"有效信息比"门控关掉（源码校验 > 0 才生效）
WANT=$(( DEVS * ROWS * BATCHES ))
BASE_TS=$(( ($(date +%s) - 3600) * 1000 ))
W14_FILES=0; W14_BYTES=0
SAMPLES="$ART/w14_samples.txt"

# 配置串（**显式列全所有键**，避免与 WAL_EXTRA_DEFAULT 同名键重复 ⇒ cluster_write_conf 假 FAIL）
W14_EXTRA="wal_mode=${WAL_MODE},enable_wal_compression=${WAL_COMPRESSION},wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${THRESH},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},wal_min_effective_info_ratio=${RATIO_TINY},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 写入（无 flush 变体；每个设备每批一条大 INSERT）---------------------
w14_write_nf(){ local db=$1 base=$2 b d k vals ts logf n=0
  local -a S=()
  logf="$ART/w14_write_${db##*.}.log"; : >"$logf"
  for (( b=1; b<=BATCHES; b++ )); do
    S=()
    for (( d=1; d<=DEVS; d++ )); do
      vals=""
      for (( k=0; k<ROWS; k++ )); do
        ts=$(( base + b * 1000000 + k * 10 ))
        vals="$vals($ts,$(( k + b ))),"
      done
      S+=("insert into $db.d$d(time,s1) values ${vals%,};")
      n=$(( n + 1 ))
    done
    sql_lines_tree "${S[@]}" >>"$logf" 2>&1 || return 1
  done
  if grep -qiE 'IoTDBSQLException|Exception|ERROR' "$logf"; then
    fail "  [$db] 写入出现异常：$(grep -iE 'Exception|ERROR' "$logf" | head -2 | tr '\n' ' ' | cut -c1-200)"
    return 1
  fi
  log "  [$db] 写入完成：$n 条大语句 × $ROWS 行 = ${WANT} 点"
  return 0; }
w14_exp_sum(){ local s
  s=$(( BATCHES * ROWS * (ROWS - 1) / 2 + ROWS * BATCHES * (BATCHES + 1) / 2 ))
  echo $(( DEVS * s )); }

# ---- ② 库级 WAL 文件面（identifier = <database>-<regionId>）----------------
w14_db_files(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$db-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w14_db_bytes(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$db-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w14_names(){ local h=$1 db=$2
  sshx "$h" "find $(wal_roots_arg "$h") -path '*/$db-*/*' -name '*.wal' -printf '%f\n' 2>/dev/null" 2>/dev/null | tr -d '\r'; }
w14_ident_dirs(){ local h=$1 db=$2
  sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 2 -type d -name '$db-*' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w14_cnt(){ local f=$1 db=$2 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h" "$db") )); done; echo "$s"; }
w14_per_node(){ local db=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(w14_db_files "$h" "$db")f/$(w14_db_bytes "$h" "$db")B "; done; echo "$out"; }
# statusCode（文件名第 3 段）分布：跨 DN 求和，输出 "s0=.. s1=.. other=.."
w14_status_sum(){ local db=$1 h names t s0 s1 tot=0 m0=0 m1=0
  for h in "${DN[@]}"; do
    names=$(w14_names "$h" "$db")
    t=$(printf '%s\n' "$names" | grep -cE '^_')
    s0=$(printf '%s\n' "$names" | grep -cE '^_[0-9]+-[0-9]+-0\.wal$')
    s1=$(printf '%s\n' "$names" | grep -cE '^_[0-9]+-[0-9]+-1\.wal$')
    tot=$(( tot + ${t:-0} )); m0=$(( m0 + ${s0:-0} )); m1=$(( m1 + ${s1:-0} ))
  done
  echo "s0=$m0 s1=$m1 other=$(( tot - m0 - m1 ))"; }
# 本文件内的指纹一致性断言（cmp_assert_same 的文案是"与合并前一致"，这里用中性文案）
w14_assert_same(){ local label=$1 a=$2 b=$3
  if [ "$a" = "$b" ]; then pass "$label：一致"; else
    fail "$label：不一致"
    printf '  前: %s\n  后: %s\n' "$(printf '%s' "$a" | tr '\n' ' ' | cut -c1-300)" "$(printf '%s' "$b" | tr '\n' ' ' | cut -c1-300)" >>"$OUT"
  fi; }
w14_snap(){ local tag=$1 af ab bf bb
  af=$(w14_cnt w14_db_files "$DB");  ab=$(w14_cnt w14_db_bytes "$DB")
  bf=$(w14_cnt w14_db_files "$DBB"); bb=$(w14_cnt w14_db_bytes "$DBB")
  W14_A_FILES=$af; W14_A_BYTES=$ab; W14_B_FILES=$bf; W14_B_BYTES=$bb
  W14_MFC=$(wal_metric_sum_over_dn wal_metric_file_cnt)
  W14_MFS=$(wal_metric_sum_over_dn wal_metric_file_bytes)
  printf 'tag=%s A=%sf/%sB B=%sf/%sB metric_count=%s metric_size=%s\n' \
    "$tag" "$af" "$ab" "$bf" "$bb" "$W14_MFC" "$W14_MFS" >>"$SAMPLES"
  log "  [WAL 快照/$tag] A(未 flush)=${af}f/${ab}B B(已 flush)=${bf}f/${bb}B | 指标 file_count=${W14_MFC} file_size=${W14_MFS}" ; }
w14_wait_stable(){ local label=$1 db=$2 dl f0="" b0="" f b n=0
  dl=$(( $(date +%s) + STABLE_WIN ))
  while (( $(date +%s) < dl )); do
    f=$(w14_cnt w14_db_files "$db"); b=$(w14_cnt w14_db_bytes "$db")
    if [ "$f" = "$f0" ] && [ "$b" = "$b0" ]; then
      n=$(( n + 1 )); [ "$n" -ge 2 ] && { log "  [$label] WAL 观测量已稳定（files=$f bytes=$b）"; return 0; }
    else
      n=0
    fi
    f0=$f; b0=$b
    sleep 5
  done
  warn "  [$label] WAL 观测量在 ${STABLE_WIN}s 内未稳定（files=$f bytes=$b）——继续，数值仅供记录"; return 0; }
# 该库"数据真的落盘"的证据：各 DN 上 `Async close tsfile: ...<db>` 的行数（helper ttl_close_cnt）
w14_close_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $(ttl_close_cnt "$h" "$db") )); done; echo "$s"; }
# 生效值：运行期 show configuration 优先，读不到退回 properties
w14_eff(){ local h=$1 k=$2 v; v=$(wal_eff "$h" "$k"); [ -n "$v" ] || v=$(wal_props_get "$h" "$k"); printf '%s' "$v"; }

# ---- ③ 证据 ----------------------------------------------------------------
w14_evidence(){ local tag=$1 h names
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(dn_state "$h")；WAL 根目录=$(wal_dir_roots "$h" | tr '\n' ' ')"
    log "  [$h] identifier 目录 A=$(w14_ident_dirs "$h" "$DB" | tr '\n' ' ') B=$(w14_ident_dirs "$h" "$DBB" | tr '\n' ' ')"
    log "  [$h] A 段文件=$(w14_db_files "$h" "$DB")f/$(w14_db_bytes "$h" "$DB")B | B 段文件=$(w14_db_files "$h" "$DBB")f/$(w14_db_bytes "$h" "$DBB")B"
    names=$(w14_names "$h" "$DBB" | sort | tr '\n' ' ')
    log "  [$h] B 段文件清单（前 12）：$(printf '%s' "$names" | cut -c1-400)"
    log "  [$h] WAL 清单（含大小，前 20）："
    wal_ls "$h" | head -20 | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] WAL 相关日志尾部："
    wal_log_tail "$h" 15 | sed 's/^/        /' >>"$OUT" 2>&1
  done
  log "  删除线程重启证据（跨 DN 累计 'Reboot wal delete thread successfully' 行数）= $(wal_log_sum 'Reboot wal delete thread successfully')"
  log "  show cluster："
  sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"
  log "=== 逐副本证据结束（$tag）==="; }

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-14 无效 WAL 清理：A 段(不 flush)=$DB / B 段(flush+close)=$DBB；规模 ${DEVS} 设备 × ${ROWS} 行 × ${BATCHES} 批 = ${WANT} 点/段 ==="
log "  轮转阈值=${THRESH}B（两段都必须轮转出 ≥${MINF} 个文件：候选集合排除最后一个活动文件，§6.2）"
log "  删除周期：初始=${WAL_DELETE_PERIOD_MS}ms → 调小到 ${SMALL}ms（hot_reload）；观察窗口 ${WIN}s"
log "  配置串：$W14_EXTRA"

log "--- ① 集群准备（含 w14 参数；写入期关三类合并，避免合并把 WAL 变无效而干扰观测）---"
EXTRA_CONF="$W14_EXTRA" cmp_cluster_prepare
P0=$(w14_eff "${DN[0]}" delete_wal_files_period_in_ms)
R0=$(w14_eff "${DN[0]}" wal_min_effective_info_ratio)
log "  运行期生效：delete_wal_files_period_in_ms=${P0:-<读不到>} wal_min_effective_info_ratio=${R0:-<读不到>}（后者设为 ${RATIO_TINY} 以隔离'有效信息比'触发的快照/刷盘机制）"
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done
: >"$SAMPLES"

log "--- ② A 段（**不 flush**）：写库 $DB ---"
cmp_make_tree_db "$DB" "$DEVS"
w14_write_nf "$DB" "$BASE_TS" || true
wait_scalar_tree "select count(s1) from $DB.d1;" "$(( ROWS * BATCHES ))" 120 "[A] 写入后可见性（$DB.d1）"
A_CNT0=$(row_sum "$(sq "select count(s1) from $DB.**;")")
A_SUM0=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
assert_eq "  [A] 未 flush 段写入点数（场景有效性）" "${A_CNT0:-0}" "$WANT"
assert_eq "  [A] 未 flush 段值总和（离线核算）" "${A_SUM0:-0}" "$(w14_exp_sum)"
A_FP0=$(cmp_fp_tree "$DB"); A_SEQ0=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
w14_wait_stable "A 写入后" "$DB"

log "--- ③ B 段（**flush + ensure_closed**）：写库 $DBB ---"
cmp_make_tree_db "$DBB" "$DEVS"
w14_write_nf "$DBB" "$BASE_TS" || true
wait_scalar_tree "select count(s1) from $DBB.d1;" "$(( ROWS * BATCHES ))" 120 "[B] 写入后可见性（$DBB.d1）"
B_CNT0=$(row_sum "$(sq "select count(s1) from $DBB.**;")")
B_SUM0=$(row_sum "$(sq "select sum(s1) from $DBB.**;")")
assert_eq "  [B] 已 flush 段写入点数（场景有效性）" "${B_CNT0:-0}" "$WANT"
assert_eq "  [B] 已 flush 段值总和（离线核算）" "${B_SUM0:-0}" "$(w14_exp_sum)"
log "  对 $DBB 执行 flush + ensure_closed（数据落盘 ⇒ 其 WAL 记录变为无效）"
sq "flush;" >/dev/null
if ensure_closed "$DBB" 3 "$CLOSE_WIN"; then
  pass "  [B] 各 DN 都出现了新的 'Async close tsfile' 事件（数据确实落盘）"
else
  warn "  [B] 有 DN 未在 ${CLOSE_WIN}s 内出现新的 Async close（只影响'已落盘'这一过程证据；下面仍按目录面判定）"
fi
B_CLOSE0=$(w14_close_sum "$DBB")
B_TS0=$(cmp_all_sum "$DBB")
A_CLOSE0=$(w14_close_sum "$DB"); A_TS0=$(cmp_all_sum "$DB")
log "  落盘证据：B 段 close事件=${B_CLOSE0} TsFile=${B_TS0}；A 段 close事件=${A_CLOSE0} TsFile=${A_TS0}（A 段**不应**落盘）"
w14_wait_stable "B flush 后" "$DBB"

log "--- 判据 ① 场景有效性：两段都轮转出 ≥${MINF} 个文件（硬）---"
w14_snap "清理前"
A_FILES0=$W14_A_FILES; A_BYTES0=$W14_A_BYTES; B_FILES0=$W14_B_FILES; B_BYTES0=$W14_B_BYTES
MFC0=$W14_MFC; MFS0=$W14_MFS
A_ST0=$(w14_status_sum "$DB"); B_ST0=$(w14_status_sum "$DBB")
log "  A 段文件 statusCode 分布：$A_ST0 ｜ B 段：$B_ST0"
if printf '%s' "$A_ST0$B_ST0" | grep -qE 'other=[1-9]'; then
  warn "有 WAL 文件名不匹配源码形态 _<versionId>-<startSearchIndex>-<statusCode>.wal（WALFileUtils.java:65-83）⇒ 文档口径 _[version_id].wal 与源码不一致（记 WARN，不当判据）；现场看上面的文件清单"
fi
for h in "${DN[@]}"; do
  log "  [$h] A 段文件清单：$(w14_names "$h" "$DB" | sort | tr '\n' ' ' | cut -c1-300)"
done
if [ "${A_FILES0:-0}" -ge "$MINF" ] && [ "${A_BYTES0:-0}" -gt 0 ]; then
  pass "场景有效性：A 段（未 flush）WAL = ${A_FILES0}f/${A_BYTES0}B（≥${MINF} 文件 ⇒ 有非最后一个文件可参与判定）"
else
  fail "场景无效：A 段 WAL = ${A_FILES0}f/${A_BYTES0}B（要求 ≥${MINF} 文件且字节 > 0）⇒ 未发生轮转或目录/库名过滤不对（看上面的文件清单）"
fi
if [ "${B_FILES0:-0}" -ge "$MINF" ] && [ "${B_BYTES0:-0}" -gt 0 ]; then
  pass "场景有效性：B 段（已 flush）WAL = ${B_FILES0}f/${B_BYTES0}B（≥${MINF} 文件 ⇒ 有可删候选）"
else
  fail "场景无效：B 段 WAL = ${B_FILES0}f/${B_BYTES0}B（要求 ≥${MINF} 文件且字节 > 0）⇒ 无候选文件，清理无从发生"
fi

log "--- ④ 热改 delete_wal_files_period_in_ms = ${SMALL}ms（hot_reload）---"
RESP=$(wal_set delete_wal_files_period_in_ms "$SMALL")
log "  SET CONFIGURATION 'delete_wal_files_period_in_ms'='${SMALL}' → $(printf '%s' "$RESP" | cut -c1-200)"
NEED_RESTART=0
case "$RESP" in *"restart is required"*|*"Restart is required"*) NEED_RESTART=1 ;; esac
P1=$(w14_eff "${DN[0]}" delete_wal_files_period_in_ms)
if [ "${P1:-}" = "$SMALL" ] && [ "$NEED_RESTART" = 0 ]; then
  pass "  场景有效性：删除周期已热改生效（生效值=$P1，无需重启）"
else
  warn "  热改未直接生效（生效值='${P1:-空}' 返回要求重启=$NEED_RESTART）⇒ 补一次 stop/start（不清 data）"
  cluster_stop; cluster_start
  P1=$(w14_eff "${DN[0]}" delete_wal_files_period_in_ms)
  if [ "${P1:-}" = "$SMALL" ]; then
    pass "  场景有效性：重启后删除周期生效（生效值=$P1）"
  else
    fail "场景无效：delete_wal_files_period_in_ms 未生效（实测 '${P1:-空}'，目标 ${SMALL}）⇒ 清理节奏无法判定"
  fi
fi
log "  删除线程重启日志（跨 DN 累计）= $(wal_log_sum 'Reboot wal delete thread successfully')（弱证据：INFO，§10.1 第 9 条）"

log "--- ⑤ 观察窗口（≤${WIN}s，每 5s 采样；B 段一降就提前结束）---"
T0=$(date +%s); DROP_SEEN=0; A_MIN_FILES=$A_FILES0; A_MIN_BYTES=$A_BYTES0
while [ $(( $(date +%s) - T0 )) -lt "$WIN" ]; do
  sleep 5
  w14_snap "t=$(( $(date +%s) - T0 ))s"
  [ "${W14_A_FILES:-0}" -lt "$A_MIN_FILES" ] && A_MIN_FILES=$W14_A_FILES
  [ "${W14_A_BYTES:-0}" -lt "$A_MIN_BYTES" ] && A_MIN_BYTES=$W14_A_BYTES
  if [ "${W14_B_FILES:-0}" -lt "${B_FILES0:-0}" ] || [ "${W14_B_BYTES:-0}" -lt "${B_BYTES0:-0}" ]; then
    DROP_SEEN=1
    log "  已观测到 B 段下降（files ${B_FILES0}→${W14_B_FILES}，bytes ${B_BYTES0}→${W14_B_BYTES}）⇒ 提前结束窗口"
    break
  fi
done
w14_snap "窗口结束"
B_FILES1=$W14_B_FILES; B_BYTES1=$W14_B_BYTES; MFC1=$W14_MFC; MFS1=$W14_MFS
A_FILES1=$W14_A_FILES; A_BYTES1=$W14_A_BYTES

log "--- 判据 ② 正向：B 段（已 flush，WAL 已无效）应被清理（硬；先探测可删性再降级）---"
log "  ⚠ 期望形态：**下降**（不是清零）——statusCode=1 的文件与最后一个文件恒被保留（WALNode.java:671-676）"
log "  B 段基线（清理前）=${B_FILES0}f/${B_BYTES0}B；窗口结束=${B_FILES1}f/${B_BYTES1}B"
log "  B 段保留下来的文件名（${DN[0]}）：$(w14_names "${DN[0]}" "$DBB" | sort | tr '\n' ' ' | cut -c1-400)"
B_DROP=0
{ [ "${B_FILES1:-0}" -lt "${B_FILES0:-0}" ] || [ "${B_BYTES1:-0}" -lt "${B_BYTES0:-0}" ]; } && B_DROP=1
if [ "$B_DROP" = 1 ]; then
  pass "清理发生：B 段 WAL 下降 files ${B_FILES0}→${B_FILES1}，bytes ${B_BYTES0}→${B_BYTES1}（删除周期 ${P1}ms）"
else
  if printf '%s' "$B_ST0" | grep -qE 's0=[1-9]'; then
    fail "B 段存在 statusCode=0 的可删文件（$B_ST0），但 ${WIN}s 窗口内文件数/字节都没下降（files ${B_FILES0}→${B_FILES1}，bytes ${B_BYTES0}→${B_BYTES1}）⇒ 无效 WAL 未被清理；另核实三种'删不掉'原因（未刷盘 / pipe pin / IoTConsensus 未消费完，design_extract §5.4）"
  else
    warn "不可构造：B 段文件全部为 statusCode=1（$B_ST0），而 IoTConsensus 下 canDeleteFile 的第一个合取项退化为只认 status=0（source_grounding §6.2）⇒ 判据改为过程证据：指标 file_count ${MFC0}→${MFC1} file_size ${MFS0}→${MFS1}"
  fi
fi
if [ "${MFC1:-0}" -lt "${MFC0:-0}" ] || [ "${MFS1:-0}" -lt "${MFS0:-0}" ]; then
  pass "指标口径交叉验证：全局 file_count ${MFC0}→${MFC1} / file_size ${MFS0}→${MFS1}（与目录口径同向下降）"
else
  if [ "$B_DROP" = 1 ]; then
    warn "指标口径与目录口径方向不一致：目录面 B 段下降，但全局 file_count ${MFC0}→${MFC1} / file_size ${MFS0}→${MFS1} 未下降（只 WARN：指标/导出时机差异，不判产品）"
  else
    log "  指标口径：全局 file_count ${MFC0}→${MFC1} / file_size ${MFS0}→${MFS1}（与目录口径一致：都没降）"
  fi
fi

log "--- 判据 ③ 反向：A 段未被 flush 的 WAL 不得被误删（硬）---"
A_FLUSHED=0
A_CLOSE1=$(w14_close_sum "$DB"); A_TS1=$(cmp_all_sum "$DB")
if [ "${A_CLOSE1:-0}" -gt "${A_CLOSE0:-0}" ] || [ "${A_TS1:-0}" -gt "${A_TS0:-0}" ]; then
  A_FLUSHED=1
  log "  A 段出现了新的落盘事件：close事件 ${A_CLOSE0}→${A_CLOSE1}，TsFile ${A_TS0}→${A_TS1}"
fi
if [ "${A_MIN_FILES:-0}" -ge "${A_FILES0:-0}" ] && [ "${A_MIN_BYTES:-0}" -ge "${A_BYTES0:-0}" ]; then
  pass "反向成立：A 段（未 flush）WAL 未被误删（files ${A_FILES0}→${A_FILES1}，bytes ${A_BYTES0}→${A_BYTES1}；窗口内最小 files=${A_MIN_FILES} bytes=${A_MIN_BYTES}）"
else
  if [ "$A_FLUSHED" = 1 ]; then
    warn "场景退化（原因+证据）：A 段 WAL 在窗口内减少（files ${A_FILES0}→${A_FILES1}，bytes ${A_BYTES0}→${A_BYTES1}；最小 files=${A_MIN_FILES} bytes=${A_MIN_BYTES}），但同一窗口内 A 段**自己也落盘了**（close事件 ${A_CLOSE0}→${A_CLOSE1}、TsFile ${A_TS0}→${A_TS1}）⇒ 'MemTable 未刷盘' 的前提不再成立，本反向断言本次不可判定（不判 FAIL）"
  else
    fail "未 flush 的 WAL 被误删：A 段 WAL 减少（files ${A_FILES0}→${A_FILES1}，bytes ${A_BYTES0}→${A_BYTES1}；窗口内最小 files=${A_MIN_FILES} bytes=${A_MIN_BYTES}），而 A 段没有任何新的落盘事件（close事件 ${A_CLOSE0}→${A_CLOSE1}、TsFile ${A_TS0}→${A_TS1}）⇒ 违反 '覆盖的 MemTable 任一未刷盘就不可删'（design_extract §5.1）"
  fi
fi

log "--- 判据 ④ 数据面：清理不得动数据（硬）---"
A_CNT1=$(row_sum "$(sq "select count(s1) from $DB.**;")"); A_SUM1=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
B_CNT1=$(row_sum "$(sq "select count(s1) from $DBB.**;")"); B_SUM1=$(row_sum "$(sq "select sum(s1) from $DBB.**;")")
assert_eq "  [A] 清理后点数" "${A_CNT1:-0}" "${A_CNT0:-0}"
assert_eq "  [A] 清理后值总和" "${A_SUM1:-0}" "${A_SUM0:-0}"
assert_eq "  [B] 清理后点数" "${B_CNT1:-0}" "${B_CNT0:-0}"
assert_eq "  [B] 清理后值总和" "${B_SUM1:-0}" "${B_SUM0:-0}"
assert_eq "  [A] 清理后点数（离线核算）" "${A_CNT1:-0}" "$WANT"
assert_eq "  [B] 清理后点数（离线核算）" "${B_CNT1:-0}" "$WANT"
w14_assert_same "[A] 清理前后 count/sum 指纹" "$A_FP0" "$(cmp_fp_tree "$DB")"
A_SEQ1=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
B_FP0=$(cmp_fp_tree "$DBB"); B_SEQ0=$(cmp_fingerprint tree "select s1 from $DBB.d1 order by time")
w14_assert_same "[A] 清理前后 d1 全序列指纹" "$A_SEQ0" "$A_SEQ1"
w14_assert_same "[B] 清理前后 count/sum 指纹" "$B_FP0" "$(cmp_fp_tree "$DBB")"
w14_assert_same "[B] 清理前后 d1 全序列指纹" "$B_SEQ0" "$(cmp_fingerprint tree "select s1 from $DBB.d1 order by time")"
if [ "$DROP_SEEN" = 0 ]; then
  warn "观察窗口 ${WIN}s 内未提前观测到 B 段下降（可能是清理周期/负载延迟；判定已用窗口结束值）"
fi
OOM=$(wal_oom_cnt); assert_eq "  WAL 相关 OOM 日志行数（必须 0）" "${OOM:-0}" "0"

log "--- 采样序列（$SAMPLES）---"
sed 's/^/      /' "$SAMPLES" >>"$OUT"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w14_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 专属异常正则）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat 'Fail to delete outdated wal file|Fail to trigger rolling wal node|Fail to roll wal|Fail to sync wal node|Fail to fsync wal node|Failed to load WAL segment'
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader|Connection reset by peer'
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
