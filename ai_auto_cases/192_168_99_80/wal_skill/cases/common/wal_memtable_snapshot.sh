#!/bin/bash
# ============================================================================
# W-16 MemTable 快照（tree / cleanup）
#   目标（cases/cases.tsv W-16）：`wal_memtable_snapshot_threshold_in_byte`（hot_reload）+
#     `max_wal_memtable_snapshot_num`（hot_reload）→ WAL 删除线程该走"快照"还是"刷盘"、
#     快照次数是否受上限约束、超上限/超阈值后是否转为刷盘（文件面变化）、数据面是否一致。
#   判据（FAIL 只来自数据面 / 场景有效性）：
#     1) 场景有效性（硬）：两个键在本版本**存在且生效值 == 写入值**（`cmp_eff`，回退 properties）；
#        窗口内**确实发生**了快照或刷盘动作（INFO 日志事件数或指标增量 > 0）——两者都没有 ⇒ 场景无效；
#        且窗口内 WAL 总字节确实达到过触发条件（`shouldThrottle()`：`>= 阈值*0.8`，源码 `WALManager.java:256-262`）。
#     2) 场景有效性（硬，上限）：**同一 memTable 的快照次数不得超过 `max_wal_memtable_snapshot_num`**
#        （逐 memTableId 从 INFO 日志数出来，精确可判，见 `w16_snap_per_mt_dump`）；收紧上限到 1 之后，
#        每个 memTable 的**新增**快照次数 ≤ 1。
#     3) 数据面（硬）：写入点全部可见（≥ 基线 + 已确认）、不超上界、值总和在区间内、基线批逐设备精确。
#     4) 超上限/超阈值 → 刷盘（硬，附条件）：先收紧 `max_wal_memtable_snapshot_num=1`；
#        若半个窗口内仍无刷盘，再热改 `wal_memtable_snapshot_threshold_in_byte=1KB`（源码
#        `ram > threshold` ⇒ flush）强制走刷盘路径；出现 `flushes memTable` + `flush_memtable_count`
#        增量 + 文件面变化（TsFile 数/字节/`Async close` 事件任一增加）才算转刷盘成功。
#     5) 只 WARN：文档等号边界（"超过该次数" vs "累计 ≥"、"小于阈值" vs "≥"）、快照内部计数
#        （`WALNode.java:116-118` 内存 Map、不落盘无指标）、各相耗时、指标是否存在（历史版本差异）。
#   ⚠️ harness 口径（RC8 首轮踩过，已修）：
#     a) 聚合值必须查**设备路径**（`select count(s1) from <db>.d1`）；树方言把测量名写成序列路径
#        （`… from <db>.d1.s1`）会**恒返回 Empty set** ⇒ 可见性/逐设备行数恒判 0 ⇒ 假 FAIL。
#     b) "值总和"期望值按**离线核算公式**算（正确），实际值必须用 `row_sum`——CLI 把 `sum()` 按
#        double 打印（`80400.0`，≥1e7 时是 `2.4018E7`），老 `row_sum` 按字符剥数字会 ×10 / ÷100
#        （修法见 `lib/wal_ext.sh` 末尾对 `row_sum` 的覆写）。
#   源码/文档依据：
#     · 判据分支：`WALNode.java:546-559`（时间分区旧 / `snapshotCount >= max` / `ram > threshold` → flush，
#       否则 snapshot）；触发条件：`WALNode.java:506-510 shouldSnapshotOrFlush()`（ratio < min 或 throttle）；
#       逐轮最多 `MAX_RECURSION_TIME=5`（`WALNode.java:358,412`）；快照计数自增 `WALNode.java:615`；
#       **删除线程要求 WAL 文件数 ≥ 2**（`WALNode.java:376`）⇒ 必须把轮转阈值调小，否则永远不会动作。
#     · 文案（INFO，`StorageEngineMessages(en)`）：`WAL node-{} snapshots memTable-{} to wal files because …`
#       / `WAL node-{} flushes memTable-{} to TsFile {} because …`（source_grounding.md §10.3 #28/#29）。
#     · 指标：`wal_node_info{name="oldest_mem_table_ram_when_cause_snapshot"|"…_flush"}`（Histogram）、
#       `flush_memtable_count{type="wal_flush_memtable_count"}`（Counter）——source_grounding.md §9。
#     · 配置默认值与生效方式：source_grounding.md §1.2 #11/#12（均 **hot_reload**）；design_extract.md §5.3。
#     · ⚠️ **不要**拿 `WALNode.java:466-470`"删除过期 WAL 条数"文案当判据（DEBUG 级、默认不落盘）。
#   ⚠️ 本脚本**未在集群实跑**（harness 阶段）。首轮 watch list：
#     ① 触发到底靠哪条路：本用例刻意把 `wal_file_size_threshold_in_byte` 调小（要 ≥2 个 WAL 文件）+ 把
#        `wal_throttle_threshold_in_byte` 调小（让 `shouldThrottle()` 为真）——首轮看采样行里的
#        `walB=`（WAL 总字节）是否真的越过 `0.8×阈值`；没越过就是"场景未成立"，先调 THR/ROT 再重跑。
#     ② 走的是 snapshot 还是 flush：若第一相直接出现 `flushes memTable`（时间分区条件命中或 ram 超阈值），
#        本用例会**如实 WARN 场景退化**并跳过"快照上界"的判定（不把退化当缺陷）。
#     ③ 逐 memTable 计数是否可解析：日志里必须是 `snapshots memTable-<id>`/`flushes memTable-<id>` 形态；
#        解析不出来（文案变化）时 `w16_snap_per_mt_dump` 为空 ⇒ 上界判定降级为 WARN + 打印原始日志行。
#     ④ 文件面变化用"TsFile 数 ↑ 或 字节 ↑ 或 `Async close tsfile` 事件 ↑"三者取或，避免"刷进同一个
#        未封口 TsFile"被误判成"没刷盘"。
#     ⑤ 压力相写入可能被 throttle **阻塞**（不是报错）：块记录里出现 `status=PARTIAL`/rc=124 只 WARN，
#        不当产品报错；数据面按"已确认（status=OK）"记账，另有上界断言防凭空多出。
#   用法：bash cases/common/wal_memtable_snapshot.sh [--consensus IoTConsensus|IoTConsensusV2]
#   时长大致：集群准备 ~4min + 基线 ~1min + 快照相窗口 ≤W16_WIN_SEC + 刷盘相 ≤W16_PHASE_B_WIN
#             + 排空 + 收尾三件套 ~4min。可调：W16_DEVS/W16_PER/W16_MAX_CHUNKS/W16_THROTTLE_BYTES/
#             W16_ROTATE_BYTES/W16_MAX_SNAPSHOT_A/W16_MAX_SNAPSHOT_B/W16_WIN_SEC/W16_PHASE_B_WIN。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_memtable_snapshot_${DATA_CONSENSUS}"

# 环境兜底：conf/env.conf 没有这三个 TTL 键，而 lib/common.sh 的 cluster_set_conf 会引用它们（set -u 下会中断准备）
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"

DB=root.walsnap                                  # 用例约定的库名（tree 模型）
DEVS=${W16_DEVS:-4}                              # 设备数
PER=${W16_PER:-500}                              # 每条 INSERT 的行数
STMTS=${W16_STMTS_PER_DEV:-4}                    # 每设备每块语句数 ⇒ 每块点数 = DEVS×STMTS×PER
MAXCH=${W16_MAX_CHUNKS:-40}                      # 每相最多写几块（硬上限，避免无限写）
WIN=${W16_WIN_SEC:-240}                          # 快照相窗口（秒）
BWIN=${W16_PHASE_B_WIN:-240}                     # 刷盘相窗口（秒）
GRACE=${W16_GRACE_SEC:-90}                       # 窗口之外给写入器收尾的时间
DRAIN_WIN=${W16_DRAIN_WIN_SEC:-300}              # 停写后等"已确认数据全部可见"的窗口
PERIOD_MS=${W16_DELETE_MS:-2000}                 # delete_wal_files_period_in_ms（hot_reload，调快）
THR_BIG=${W16_SNAPSHOT_THRESHOLD_BYTES:-268435456}   # 256MB：ram 不超阈值 ⇒ 走快照（源码 > 才 flush）
THR_TINY=${W16_SNAPSHOT_THRESHOLD_TINY:-1024}        # 1KB：ram 必然超阈值 ⇒ 强制走刷盘
MAXA=${W16_MAX_SNAPSHOT_A:-5}                    # 快照相的次数上限（放宽，允许同一 memTable 多次快照）
MAXB=${W16_MAX_SNAPSHOT_B:-1}                    # 刷盘相的次数上限（收紧 ⇒ 超上限转 flush）
THROTTLE=${W16_THROTTLE_BYTES:-4194304}          # 4MB：让 shouldThrottle() 成为触发闸门（0.8×=3.2MB）
ROT=${W16_ROTATE_BYTES:-${WAL_ROTATE_THRESHOLD_SMALL}}   # 1MB：让 WAL 文件数 ≥2（删除线程的前置条件）
ROWS_PER_CHUNK=$(( DEVS * STMTS * PER ))
BASE_ROWS=${W16_BASE_ROWS:-200}
BASE_TS=$(( ($(date +%s) - 3600) * 1000 ))       # 基线批时间戳（与压力批同一个时间分区）
WTS_BASE=$(( BASE_TS + 1000000 ))
BASE_COUNT=$(( DEVS * BASE_ROWS ))
BASE_SUM=$(( BASE_ROWS * (BASE_ROWS + 1) / 2 * DEVS ))
TRIG_BYTES=$(awk -v a="$THROTTLE" 'BEGIN{printf "%d", a*0.8}')   # 源码：实际阈值 = 配置值 × 0.8

W16_EXTRA="wal_mode=${WAL_MODE},enable_wal_compression=false,wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${ROT},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES},wal_throttle_threshold_in_byte=${THROTTLE},wal_memtable_snapshot_threshold_in_byte=${THR_BIG},max_wal_memtable_snapshot_num=${MAXA},wal_min_effective_info_ratio=${WAL_MIN_EFF_RATIO},${CMP_EXTRA_WRITE}"

CHUNKLOG="$ART/w16_chunks.txt"
SAMPLELOG="$ART/w16_samples.txt"
STOPF="$ART/w16_stop"
KEY_THR="wal_memtable_snapshot_threshold_in_byte"
KEY_MAX="max_wal_memtable_snapshot_num"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 配置面：生效值（show configuration）→ 配置文件值 ----
w16_conf(){ local h=$1 k=$2 v
  v=$(cmp_eff "$h" "$k"); [ -n "${v:-}" ] || v=$(wal_props_get "$h" "$k")
  printf '%s' "${v:-}"; }
w16_conf_check(){ local k=$1 want=$2 got
  got=$(w16_conf "${DN[0]}" "$k")
  log "    [配置] $k：生效值/配置值='${got:-（读不到）}' 期望=$want"
  [ "${got:-}" = "$want" ]; }

# ---- ② 指标面（**前缀容忍**：Histogram 会导出 `_count`/`_sum`/`_bucket`，不能只 grep `名{`）----
w16_msum(){ local h=$1 pat=$2 tag=${3:-} v
  if [ -n "$tag" ]; then
    v=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '^$pat' | grep -F '$tag' | awk '{s+=\$NF} END{print s+0}'" 2>/dev/null | tr -dc '0-9.\-')
  else
    v=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '^$pat' | awk '{s+=\$NF} END{print s+0}'" 2>/dev/null | tr -dc '0-9.\-')
  fi
  echo "${v:-0}"; }
w16_msum_all(){ local pat=$1 tag=${2:-} h s=0; for h in "${DN[@]}"; do s=$(( s + $(w16_msum "$h" "$pat" "$tag") )); done; echo "$s"; }
# 快照/刷盘指标（跨 DN 求和；同时打印 lib 的权威 helper 值以便对照）
w16_snap_metric(){ w16_msum_all 'wal_node_info' 'oldest_mem_table_ram_when_cause_snapshot'; }
w16_flush_metric(){ w16_msum_all 'wal_node_info' 'oldest_mem_table_ram_when_cause_flush'; }
w16_flushcnt_metric(){ w16_msum_all 'flush_memtable_count' "$1"; }

# ---- ③ 日志面：INFO 事件数（每事件一行；权威可数）----
# 只数 log_datanode_all.log：lib 的 wal_log_sum 会把 all + wal 两个文件一起数，
# 若同一条文案落进两个 appender 会翻倍 ⇒ 会让"逐 memTable ≤ 上限"出现假 FAIL。
w16_log_all(){ local pat=$1 h s=0 n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -ahE '$pat' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done
  echo "${s:-0}"; }
# 逐 memTable 快照/刷盘次数（**上界判定的核心**）：输出 `节点:memTableId 次数`
w16_per_mt_dump(){ local pat=$1 f=$2 h
  : >"$f"
  for h in "${DN[@]}"; do
    sshx "$h" "grep -ahE '$pat' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | sed -E 's/.*memTable-([0-9]+).*/\1/' | grep -E '^[0-9]+\$' | sort | uniq -c" 2>/dev/null \
      | tr -d '\r' | awk -v n="${h##*.}" 'NF>=2{print n":"$2, $1}' >>"$f"
  done
  log "    逐 memTable 计数（$pat）共 $(grep -c . "$f" 2>/dev/null) 行（明细见 $f）"
  sed 's/^/        /' "$f" >>"$OUT" 2>/dev/null; }
# 两张逐 memTable 计数表求"新增次数"的最大值（第二张 − 第一张；第一张没有的按 0 算）
w16_mt_delta_max(){ local a=$1 b=$2
  awk 'NR==FNR{A[$1]=$2; next} { d=$2-(($1 in A)?A[$1]:0); if (d>m) m=d } END{ printf "%d", m+0 }' "$a" "$b" 2>/dev/null; }
w16_mt_delta_rows(){ local a=$1 b=$2
  awk 'NR==FNR{A[$1]=$2; next} { d=$2-(($1 in A)?A[$1]:0); printf "      %s 新增 %d 次（累计 %d）\n", $1, d, $2 }' "$a" "$b" 2>/dev/null; }
w16_mt_max(){ local f=$1
  awk '{ if ($2+0 > m) m=$2+0 } END{ printf "%d", m+0 }' "$f" 2>/dev/null; }

# ---- ④ 文件面：TsFile 数 / 字节 / Async close 事件 ----
w16_file_face(){ printf '%s|%s|%s' "$(cmp_all_sum "$DB")" "$(cmp_bytes_sum "$DB")" "$(wal_sum_over_dn ttl_close_cnt_db)"; }
ttl_close_cnt_db(){ ttl_close_cnt "$1" "$DB"; }

# ---- ⑤ 数据面 ----
w16_total(){ row_sum "$(sq "select count(s1) from $DB.**;")"; }
w16_total_sum(){ row_sum "$(sq "select sum(s1) from $DB.**;")"; }
w16_wait_ge(){ local label=$1 sql=$2 want=$3 win=$4 dl got
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(row_sum "$(sq "$sql")")
    [ "${got:-0}" -ge "$want" ] && { pass "  $label: $got（≥ $want）"; return 0; }
    log "    等 $label: 实际=${got:-?} 目标≥$want（$(date '+%T')）"
    sleep 5
  done
  fail "  $label: 实际=${got:-?} 目标≥$want（等 ${win}s 仍未达标）"
  return 1; }
w16_dev_exact(){ local d n ok=0
  for (( d=1; d<=DEVS; d++ )); do
    n=$(scalar "$(sq "select count(s1) from $DB.d$d;")")
    [ "${n:-0}" = "$BASE_ROWS" ] && ok=$(( ok + 1 )) || warn "  基线批设备 d$d 行数 ${n:-?} ≠ $BASE_ROWS（该设备可能被压力批覆盖/共享 memTable）"
  done
  log "  基线批逐设备行数精确的设备数：$ok/$DEVS（基线批每设备 $BASE_ROWS 行）"; }
# 压力相之后：每设备行数只应 ≥ 基线批（只增不减；不判等号，因为同一设备还会有压力批数据）
w16_dev_min(){ local d n bad=0
  for (( d=1; d<=DEVS; d++ )); do
    n=$(scalar "$(sq "select count(s1) from $DB.d$d;")")
    [ "${n:-0}" -ge "$BASE_ROWS" ] || { bad=$(( bad + 1 )); warn "  设备 d$d 行数 ${n:-?} < 基线批 $BASE_ROWS（数据丢失迹象）"; }
  done
  assert_eq "  数据面：行数 ≥ 基线批的设备个数" "$(( DEVS - bad ))" "$DEVS"; }

# ---- ⑥ 写入器（后台；按块记账，块记录进 CHUNKLOG）----
# 每块：DEVS 设备 × STMTS 条语句 × PER 行；值 = 全局自增 g，时间戳 = WTS_BASE + g*10
w16_writer(){ local db=$1 stopf=$2 logf=$3 maxch=$4 win=$5 t0=$6
  local c=0 d s k g=0 rows gs ts vals rc ms0 ms1 errs
  local -a ST=()
  while :; do
    [ -f "$stopf" ] && { printf 'stop=stopfile\n' >>"$logf"; break; }
    [ "$c" -ge "$maxch" ] && { printf 'stop=maxchunks\n' >>"$logf"; break; }
    [ $(( $(date +%s) - t0 )) -ge "$win" ] && { printf 'stop=window\n' >>"$logf"; break; }
    c=$(( c + 1 )); rows=0; gs=0; ST=()
    for (( d=1; d<=DEVS; d++ )); do
      for (( s=1; s<=STMTS; s++ )); do
        vals=""
        for (( k=0; k<PER; k++ )); do
          g=$(( g + 1 )); rows=$(( rows + 1 )); gs=$(( gs + g ))
          ts=$(( WTS_BASE + g * 10 ))
          vals="$vals($ts,$g),"
        done
        ST+=("insert into $db.d$d(time,s1) values ${vals%,};")
      done
    done
    ms0=$(date +%s%3N)
    printf '%s\n' "${ST[@]}" | session_tree >"$ART/w16_chunk.out" 2>&1; rc=$?
    ms1=$(date +%s%3N)
    errs=$(grep -cE 'Exception|ERROR' "$ART/w16_chunk.out" 2>/dev/null)
    if [ "${rc:-0}" != "0" ] || [ "${errs:-0}" -gt 0 ]; then
      printf 'chunk=%s rows=%s gsum=%s ms=%s status=PARTIAL rc=%s errs=%s\n' "$c" "$rows" "$gs" "$(( ms1 - ms0 ))" "$rc" "$errs" >>"$logf"
      grep -E 'Exception|ERROR' "$ART/w16_chunk.out" 2>/dev/null | head -3 >>"$logf"
      break
    fi
    printf 'chunk=%s rows=%s gsum=%s ms=%s status=OK\n' "$c" "$rows" "$gs" "$(( ms1 - ms0 ))" >>"$logf"
  done }
w16_field_sum(){ local f=$1 key=$2 fst=$3
  grep -F "status=$fst" "$f" 2>/dev/null | sed -n "s/.* $key=\([0-9]*\) .*/\1/p" | awk '{s+=$1} END{print s+0}'; }
w16_all_sum(){ local f=$1 key=$2
  sed -n "s/^chunk=.* $key=\([0-9]*\) .*/\1/p" "$f" 2>/dev/null | awk '{s+=$1} END{print s+0}'; }

# ---- ⑦ 采样一行（快照相/刷盘相共用；事件数由调用方算好放进全局，避免一次采样打十几次 ssh）----
w16_sample(){ local tag=$1 t0=$2 bl=0 qc qm wb wf ch
  bl=$(wal_sum_over_dn wal_blocked_writers)
  qc=$(wal_metric_sum_over_dn wal_metric_queue_cur); qm=$(wal_metric_sum_over_dn wal_metric_queue_max)
  wb=$(wal_metric_sum_over_dn wal_metric_file_bytes)
  [ "${wb:-0}" -gt 0 ] || wb=$(wal_sum_over_dn wal_dir_bytes)
  wf=$(wal_sum_over_dn wal_file_cnt)
  ch=$(grep -c '.' "$CHUNKLOG" 2>/dev/null)
  printf 'phase=%s t=%s chunks=%s blocked=%s q=%s/%s walB=%s walF=%s snap_evt=%s flush_evt=%s\n' \
    "$tag" "$(( $(date +%s) - t0 ))" "${ch:-0}" "${bl:-0}" "${qc:-0}" "${qm:-0}" "${wb:-0}" "${wf:-0}" \
    "${W16_SNAP_EVT:-0}" "${W16_FLUSH_EVT:-0}" >>"$SAMPLELOG"
  log "    [采样 $tag t=$(( $(date +%s) - t0 ))s] 块=${ch:-0} 阻塞线程=${bl:-0} 队列内存=${qc:-0}/${qm:-0} WAL=${wb:-0}B/${wf:-0}f 快照事件=${W16_SNAP_EVT:-0} 刷盘事件=${W16_FLUSH_EVT:-0}"; }
w16_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(dn_state "$h") 进程：$(sshx "$h" "pgrep -af com.timecho.iotdb.DataNode | head -2" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-160)"
    log "  [$h] 快照/刷盘 INFO 事件（尾部）："
    sshx "$h" "grep -ahE 'snapshots memTable|flushes memTable' $(wal_log_files) 2>/dev/null | tail -6" 2>/dev/null | tr -d '\r' | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] 指标原文（wal_node_info / flush_memtable_count）："
    sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '^(wal_node_info|flush_memtable_count)' | head -12" 2>/dev/null | tr -d '\r' | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] WAL 清单（前 10）："
    wal_ls "$h" | head -10 | sed 's/^/        /' >>"$OUT" 2>&1
  done
  log "  show cluster："
  sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"
  log "=== 逐副本证据结束（$tag）==="; }

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-16 MemTable 快照：库=$DB 规模=${DEVS}设备×${ROWS_PER_CHUNK}点/块 ==="
log "  快照相：$KEY_THR=${THR_BIG}B（ram 不超阈值）+ $KEY_MAX=${MAXA}；刷盘相：$KEY_MAX=${MAXB}（必要时 $KEY_THR=${THR_TINY}B 强制）"
log "  触发条件：WAL 文件数 ≥2（轮转阈值 ${ROT}B）+ shouldThrottle()（WAL ≥ ${TRIG_BYTES}B = ${THROTTLE}×0.8）"
log "  WAL 参数组合：$W16_EXTRA"

log "--- ① 集群准备（清集群 → 写 WAL 参数 → 启动；写入期关三类合并，避免合并干扰文件面）---"
EXTRA_CONF="$W16_EXTRA" cmp_cluster_prepare
log "  合并参数生效值（抽查）：$(cmp_eff_all "${DN[0]}")"
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done

log "--- ② 场景有效性：两个快照键必须存在且生效值 == 写入值 ---"
n_ok=0
for k in "$KEY_THR" "$KEY_MAX"; do
  case "$k" in
    "$KEY_THR") want=$THR_BIG ;;
    *)          want=$MAXA ;;
  esac
  if w16_conf_check "$k" "$want"; then n_ok=$(( n_ok + 1 )); else fail "  场景无效：$k 未生效（读不到或与写入值不一致）"; fi
done
assert_eq "  场景有效性：生效的快照相关键个数（阈值 + 次数上限）" "$n_ok" "2"
log "  旁证（触发闸门）：wal_throttle_threshold_in_byte=$(w16_conf "${DN[0]}" wal_throttle_threshold_in_byte)（实际阈值×0.8=$TRIG_BYTES）wal_file_size_threshold_in_byte=$(w16_conf "${DN[0]}" wal_file_size_threshold_in_byte)"
[ "$(w16_conf "${DN[0]}" enable_wal_compression)" = "false" ] && pass "  enable_wal_compression=false（WAL 体积与写入量成正比，便于达到触发条件）" \
  || warn "  enable_wal_compression 不是 false ⇒ WAL 体积增长慢，可能压不到触发阈值（记录，可通过 W16_THROTTLE_BYTES 调小重跑）"

log "--- ③ 造库 + 建序列 + 确定性基线批（${DEVS} 设备 × ${BASE_ROWS} 点，值 1..${BASE_ROWS}）---"
cmp_make_tree_db "$DB" "$DEVS"
{
  for (( d=1; d<=DEVS; d++ )); do
    vals=""
    for (( k=1; k<=BASE_ROWS; k++ )); do vals="$vals($(( BASE_TS + k * 10 )),$k),"; done
    printf 'insert into %s.d%s(time,s1) values %s;\n' "$DB" "$d" "${vals%,}"
  done
} >"$ART/w16_base.sql"
session_tree <"$ART/w16_base.sql" >"$ART/w16_base.out" 2>&1
if grep -qE 'Exception|ERROR' "$ART/w16_base.out"; then fail "  基线批写入报错（见 $ART/w16_base.out）"; else pass "  基线批写入完成（$BASE_COUNT 点）"; fi
# ⚠️ 可见性一律查**设备路径** `$DB.d1`：树方言把测量名写成序列路径
#    （`select count(s1) from <db>.d1.s1`）会**恒返回 Empty set**（本 skill 已踩过，
#    见 wal_compress_toggle.sh 里同一处注释）⇒ 会让"可见性"断言恒判 0 而**假 FAIL**。
wait_scalar_tree "select count(s1) from $DB.d1;" "$BASE_ROWS" 90 "基线批可见性（$DB.d1 设备路径）"
PRE_COUNT=$(w16_total); PRE_SUM=$(w16_total_sum)
assert_eq "  场景有效性：基线点数" "${PRE_COUNT:-0}" "$BASE_COUNT"
assert_eq "  场景有效性：基线值总和" "${PRE_SUM:-0}" "$BASE_SUM"
w16_dev_exact
log "  基线 WAL：本库=$(wal_sum_over_dn wal_file_cnt)f/$(wal_sum_over_dn wal_dir_bytes)B 指标 file_count=$(wal_metric_sum_over_dn wal_metric_file_cnt) file_size=$(wal_metric_sum_over_dn wal_metric_file_bytes)"
log "  指标存在性（缺失只 WARN，历史版本差异）：snapshot=$(wal_metric_exists "${DN[0]}" wal_node_info) flush_cnt=$(wal_metric_exists "${DN[0]}" flush_memtable_count)"
log "  lib helper 对照（**只作证据**：helper 精确匹配「指标名{」，Histogram 若被导成「名_count」会读成 0）：wal_metric_snapshot_ram=$(wal_metric_sum_over_dn wal_metric_snapshot_ram) wal_metric_flush_ram=$(wal_metric_sum_over_dn wal_metric_flush_ram) wal_metric_flush_memtable_cnt=$(wal_metric_sum_over_dn wal_metric_flush_memtable_cnt)"

log "--- ④ 快照相：max_wal_memtable_snapshot_num=$MAXA + 阈值=$THR_BIG（期望出现 snapshots memTable）---"
: >"$CHUNKLOG"; : >"$SAMPLELOG"; rm -f "$STOPF"
SNAP0=$(w16_log_all 'snapshots memTable'); FLUSH0=$(w16_log_all 'flushes memTable')
SNAPM0=$(w16_snap_metric); FLUSHM0=$(w16_flush_metric); FLCNT0=$(w16_flushcnt_metric wal_flush_memtable_count)
FACE0=$(w16_file_face)
w16_per_mt_dump 'snapshots memTable' "$ART/snap_mt_A0.txt"
log "  基线事件数：快照=$SNAP0 刷盘=$FLUSH0；指标：snapshot_ram=$SNAPM0 flush_ram=$FLUSHM0 flush_memtable_count=$FLCNT0；文件面=$FACE0"
T_A=$(date +%s)
( w16_writer "$DB" "$STOPF" "$CHUNKLOG" "$MAXCH" "$WIN" "$T_A" ) &
WPA=$!
TRIG_A=0; MAXWAL_A=0; SNAP_INC=0
while kill -0 "$WPA" 2>/dev/null; do
  sleep 5
  W16_SNAP_EVT=$(w16_log_all 'snapshots memTable'); W16_FLUSH_EVT=$(w16_log_all 'flushes memTable')
  w16_sample A "$T_A"
  wb=$(wal_metric_sum_over_dn wal_metric_file_bytes); [ "${wb:-0}" -gt 0 ] || wb=$(wal_sum_over_dn wal_dir_bytes)
  [ "${wb:-0}" -gt "$MAXWAL_A" ] && MAXWAL_A=$wb
  [ "${wb:-0}" -ge "$TRIG_BYTES" ] && TRIG_A=1
  SNAP_INC=$(( W16_SNAP_EVT - SNAP0 ))
  [ "$SNAP_INC" -ge 2 ] && { log "  已观测到 $SNAP_INC 次快照事件 ⇒ 提前结束快照相（上界判定需要 ≥2 次）"; break; }
  [ $(( $(date +%s) - T_A )) -ge $(( WIN + GRACE )) ] && { log "  快照相达到窗口上限（${WIN}+${GRACE}s）⇒ 通知写入器停止"; break; }
done
: >"$STOPF"; wait "$WPA" 2>/dev/null
sed 's/^/      /' "$CHUNKLOG" >>"$OUT"
if [ "$TRIG_A" = 1 ]; then pass "  场景有效性：快照相 WAL 总字节峰值 ${MAXWAL_A}B ≥ 触发阈值 ${TRIG_BYTES}B（shouldThrottle 条件成立）"
else warn "  场景未完全成立：快照相 WAL 总字节峰值 ${MAXWAL_A}B < ${TRIG_BYTES}B（未观测到 throttle 闸门命中）——记录，下面按日志/指标的实际动作判定"; fi
SNAP1=$(w16_log_all 'snapshots memTable'); FLUSH1=$(w16_log_all 'flushes memTable')
SNAPM1=$(w16_snap_metric); FLUSHM1=$(w16_flush_metric); FLCNT1=$(w16_flushcnt_metric wal_flush_memtable_count)
SNAP_A_INC=$(( SNAP1 - SNAP0 )); FLUSH_A_INC=$(( FLUSH1 - FLUSH0 ))
log "  快照相结束：快照事件 +$SNAP_A_INC 刷盘事件 +$FLUSH_A_INC；指标 snapshot_ram $SNAPM0→$SNAPM1 flush_ram $FLUSHM0→$FLUSHM1 flush_memtable_count $FLCNT0→$FLCNT1"
log "  lib helper 对照（同上，只作证据）：snapshot_ram=$(wal_metric_sum_over_dn wal_metric_snapshot_ram) flush_ram=$(wal_metric_sum_over_dn wal_metric_flush_ram) flush_memtable_cnt=$(wal_metric_sum_over_dn wal_metric_flush_memtable_cnt)"
w16_per_mt_dump 'snapshots memTable' "$ART/snap_mt_A1.txt"
log "  快照相逐 memTable 快照次数明细："
w16_mt_delta_rows "$ART/snap_mt_A0.txt" "$ART/snap_mt_A1.txt" | sed 's/^/    /' >>"$OUT"

log "--- ⑤ 快照相判定（场景有效性 + 上限，等号边界不判）---"
if [ "$SNAP_A_INC" -gt 0 ]; then
  pass "  场景有效性：观测到快照相动作（snapshots memTable 事件 +$SNAP_A_INC）"
  if [ "${SNAPM1:-0}" -gt "${SNAPM0:-0}" ]; then pass "  指标面方向一致：oldest_mem_table_ram_when_cause_snapshot 变化 $SNAPM0→$SNAPM1"
  else warn "  指标面未见变化（$SNAPM0→$SNAPM1）：可能是 Histogram 尚未导出/指标名差异 ⇒ 只记录（日志事件已作主判据）"; fi
  MTA_MAX=$(w16_mt_max "$ART/snap_mt_A1.txt")
  log "  同一 memTable 快照次数最大值=$MTA_MAX（上限 MAX=$MAXA）"
  if [ "${MTA_MAX:-0}" -le "$MAXA" ]; then pass "  上限生效：没有任何 memTable 的快照次数超过 $MAXA"
  else fail "  同一 memTable 的快照次数 $MTA_MAX 超过上限 $MAXA（逐 memTable 明细见 $ART/snap_mt_A1.txt）"; fi
  if [ "${MTA_MAX:-0}" -ge "$MAXA" ]; then warn "  有 memTable 达到上限 $MAXA（等号边界：文档参数条目写「超过该次数」、章节写「累计 ≥」）⇒ 本用例**不判**等号归属，仅记录"; fi
else
  if [ "$FLUSH_A_INC" -gt 0 ]; then
    warn "  场景退化：快照相未出现快照，直接出现刷盘 +$FLUSH_A_INC（可能是时间分区条件命中或 ram 超阈值）⇒ 跳过快照上界判定，只记录（不当缺陷）"
  else
    fail "  场景无效：快照相窗口内既无 snapshots memTable 也无 flushes memTable（阈值/负载/轮转未满足触发条件，WAL 峰值 ${MAXWAL_A}B vs 阈值 ${TRIG_BYTES}B）"
  fi
fi

log "--- ⑥ 刷盘相：收紧 $KEY_MAX=${MAXB}（超上限应转刷盘；半个窗口无效果再用 $KEY_THR=${THR_TINY}B 强制）---"
RESP=$(wal_set "$KEY_MAX" "$MAXB"); log "  SET $KEY_MAX=$MAXB 返回：$(printf '%s' "$RESP" | cut -c1-200)"
EFF_MAX=$(w16_conf "${DN[0]}" "$KEY_MAX")
if [ "${EFF_MAX:-}" = "$MAXB" ]; then pass "  上限已收紧到 $MAXB（生效值=$EFF_MAX）"
else warn "  收紧上限后读到的值是 '${EFF_MAX:-空}'（≠$MAXB）⇒ 记录；仍继续观察是否转刷盘"; fi
# 【2026-10-23 修】换相前不要把账本清成空：相 A 已经写进库里的行必须继续算进"上界"，
# 否则 UPPER = PRE_COUNT(相 A 之前) + 相 B 记账 ⇒ 相 A 的行被当成"凭空多出"（实测差值恰为一个 chunk 8000）。
# 这里先把相 A 的记账存下来，⑧ 段再与相 B 相加。
W16_A_ROWS=$(w16_all_sum "$CHUNKLOG" rows)
W16_A_OKROWS=$(w16_field_sum "$CHUNKLOG" rows OK)
W16_A_SUM=$(w16_all_sum "$CHUNKLOG" gsum)
W16_A_OKSUM=$(w16_field_sum "$CHUNKLOG" gsum OK)
log "  相 A 记账（两相时间戳重叠 ⇒ 最终取两相较大值）：rows=${W16_A_ROWS:-0} okRows=${W16_A_OKROWS:-0} gsum=${W16_A_SUM:-0}"
: >"$CHUNKLOG"; rm -f "$STOPF"
T_B=$(date +%s)
( w16_writer "$DB" "$STOPF" "$CHUNKLOG" "$MAXCH" "$BWIN" "$T_B" ) &
WPB=$!
TRIG_B=0; MAXWAL_B=0; THR_FORCED=0; FLUSH_B_INC=0; FACE_B="$FACE0"
: >"$ART/snap_mt_B0.txt"; cat "$ART/snap_mt_A1.txt" >"$ART/snap_mt_B0.txt" 2>/dev/null
while kill -0 "$WPB" 2>/dev/null; do
  sleep 5
  W16_SNAP_EVT=$(w16_log_all 'snapshots memTable'); W16_FLUSH_EVT=$(w16_log_all 'flushes memTable')
  w16_sample B "$T_B"
  wb=$(wal_metric_sum_over_dn wal_metric_file_bytes); [ "${wb:-0}" -gt 0 ] || wb=$(wal_sum_over_dn wal_dir_bytes)
  [ "${wb:-0}" -gt "$MAXWAL_B" ] && MAXWAL_B=$wb
  [ "${wb:-0}" -ge "$TRIG_BYTES" ] && TRIG_B=1
  FLUSH_B_INC=$(( W16_FLUSH_EVT - FLUSH1 ))
  w16_per_mt_dump 'flushes memTable' "$ART/flush_mt_B.txt"
  [ "$FLUSH_B_INC" -gt 0 ] && { log "  刷盘相已观测到 flushes memTable +$FLUSH_B_INC ⇒ 提前结束刷盘相"; break; }
  el=$(( $(date +%s) - T_B ))
  if [ "$THR_FORCED" = 0 ] && [ "$el" -ge $(( BWIN / 2 )) ]; then
    log "  半个窗口（${el}s）内没有刷盘 ⇒ 热改 $KEY_THR=$THR_TINY 强制走「ram 大于 threshold ⇒ flush」路径"
    RESP2=$(wal_set "$KEY_THR" "$THR_TINY"); log "    SET $KEY_THR=$THR_TINY 返回：$(printf '%s' "$RESP2" | cut -c1-200)"
    THR_FORCED=1
  fi
  [ "$el" -ge $(( BWIN + GRACE )) ] && { log "  刷盘相达到窗口上限（${BWIN}+${GRACE}s）⇒ 通知写入器停止"; break; }
done
: >"$STOPF"; wait "$WPB" 2>/dev/null
sed 's/^/      /' "$CHUNKLOG" >>"$OUT"
FACE_B=$(w16_file_face)
SNAP2=$(w16_log_all 'snapshots memTable'); FLUSH2=$(w16_log_all 'flushes memTable')
FLUSHM2=$(w16_flush_metric); FLCNT2=$(w16_flushcnt_metric wal_flush_memtable_count)
FLUSH_B_INC=$(( FLUSH2 - FLUSH1 )); SNAP_B_INC=$(( SNAP2 - SNAP1 ))
FACE_A=$FACE0
log "  刷盘相结束：刷盘事件 +$FLUSH_B_INC 快照事件 +$SNAP_B_INC；指标 flush_ram $FLUSHM1→$FLUSHM2 flush_memtable_count $FLCNT1→$FLCNT2"
log "  文件面（TsFile数|字节|Async close 事件）：相前=$FACE_A 相后=$FACE_B"

log "--- ⑦ 刷盘相判定：超上限/超阈值 ⇒ 转刷盘 + 文件面变化 ---"
if [ "$FLUSH_B_INC" -gt 0 ]; then
  pass "  转刷盘：flushes memTable 事件 +$FLUSH_B_INC（$( [ "$THR_FORCED" = 1 ] && echo "由 max=$MAXB + 阈值=$THR_TINY 共同促成" || echo "由 max 收紧到 $MAXB 促成" )）"
  [ "$THR_FORCED" = 1 ] && warn "  注意：本次是靠「阈值调小（ram 大于 threshold ⇒ flush）」才拿到刷盘证据 ⇒ max 上限单独作用未观测到（记录，不判缺陷）"
  if [ "${FLCNT2:-0}" -gt "${FLCNT1:-0}" ]; then pass "  指标面方向一致：flush_memtable_count 变化 $FLCNT1→$FLCNT2"
  else warn "  指标面未见变化（$FLCNT1→$FLCNT2）：flush_memtable_count 缺失/标签差异 ⇒ 只记录（日志事件已作主判据）"; fi
  F1=${FACE_A%%|*}; REST=${FACE_A#*|}; F2=${REST%%|*}; F3=${REST#*|}
  G1=${FACE_B%%|*}; RESTB=${FACE_B#*|}; G2=${RESTB%%|*}; G3=${RESTB#*|}
  if [ "${G1:-0}" -gt "${F1:-0}" ] || [ "${G2:-0}" -gt "${F2:-0}" ] || [ "${G3:-0}" -gt "${F3:-0}" ]; then
    pass "  文件面变化：TsFile 数 $F1→$G1 字节 $F2→$G2 AsyncClose $F3→$G3（三者任一增加即成立）"
  else
    if [ "$TRIG_B" = 1 ]; then fail "  刷盘后文件面无变化（TsFile 数 $F1→$G1 字节 $F2→$G2 AsyncClose $F3→$G3），且触发条件已命中所致"
    else warn "  刷盘后文件面无变化且未观测到触发条件命中（WAL 峰值 ${MAXWAL_B}B < ${TRIG_BYTES}B）⇒ 场景未成立，仅记录"; fi
  fi
else
  if [ "$TRIG_B" = 1 ]; then
    fail "  触发条件已命中（WAL 峰值 ${MAXWAL_B}B ≥ ${TRIG_BYTES}B）但窗口内没有 flushes memTable ⇒ 超上限/超阈值未转为刷盘"
  else
    warn "  场景未成立：刷盘相未再触发（WAL 峰值 ${MAXWAL_B}B < ${TRIG_BYTES}B），也无 flushes memTable ⇒ 不判 FAIL（可调小 W16_THROTTLE_BYTES / W16_MAX_CHUNKS 重跑）"
  fi
fi
w16_per_mt_dump 'snapshots memTable' "$ART/snap_mt_B1.txt"
MT_DELTA=$(w16_mt_delta_max "$ART/snap_mt_B0.txt" "$ART/snap_mt_B1.txt")
log "  收紧上限后：单个 memTable 的最大新增快照次数=$MT_DELTA（上限 MAX=$MAXB）"
if [ "$(grep -c . "$ART/snap_mt_B1.txt" 2>/dev/null)" -gt 0 ]; then
  if [ "${MT_DELTA:-0}" -le "$MAXB" ]; then pass "  上限生效：收紧到 $MAXB 后每个 memTable 的新增快照次数 ≤ $MAXB"
  else fail "  收紧到 $MAXB 后仍有 memTable 新增 $MT_DELTA 次快照（逐 memTable 明细见 $ART/snap_mt_B1.txt）"; fi
else
  warn "  逐 memTable 快照计数解析为空（日志文案可能变化）⇒ 上界判定降级为 WARN，原始日志行见 ④/⑤ 段"
fi

log "--- ⑧ 数据面（硬）：已确认数据全部可见 + 不凭空多出 + 总和在区间内 ---"
_b_okrows=$(w16_field_sum "$CHUNKLOG" rows OK 2>/dev/null); _b_okrows=${_b_okrows:-0}
_b_allrows=$(w16_all_sum "$CHUNKLOG" rows); _b_allrows=${_b_allrows:-0}
_a_allrows=${W16_A_ROWS:-0}; _a_okrows=${W16_A_OKROWS:-0}
# 【2026-10-26 修正】两相写入用的是**同一个 WTS_BASE 且 g 都从 0 起** ⇒ 两相时间戳完全重叠，
# 后相会把前相同时间戳的行**覆盖**掉，最终可见行数 ≈ PRE + max(相A, 相B)，不是相加。
# 上一版按"相加"处理，把目标值直接翻倍（168800），造出"数据丢失"的假 FAIL。
if [ "$_a_allrows" -gt "$_b_allrows" ]; then ALLROWS=$_a_allrows; else ALLROWS=$_b_allrows; fi
if [ "$_a_okrows" -gt "$_b_okrows" ]; then OKROWS=$_a_okrows; else OKROWS=$_b_okrows; fi
TARGET=$(( PRE_COUNT + OKROWS ))
w16_wait_ge "停写后可见点数（≥ 基线 + 已确认）" "select count(s1) from $DB.**;" "$TARGET" "$DRAIN_WIN"
CUR_COUNT=$(w16_total); CUR_SUM=$(w16_total_sum)
UPPER=$(( PRE_COUNT + ALLROWS ))
if [ "${CUR_COUNT:-0}" -le "$UPPER" ]; then pass "  可见点数未超上界（$CUR_COUNT ≤ 基线$PRE_COUNT + 全部块$ALLROWS）"
else fail "  可见点数超上界（$CUR_COUNT > $UPPER）——出现凭空多出的数据"; fi
if [ "${CUR_COUNT:-0}" -ge "$TARGET" ]; then pass "  数据一条不丢：可见点数 $CUR_COUNT ≥ 已确认 $TARGET"
else fail "  数据丢失：可见点数 $CUR_COUNT < 已确认 $TARGET"; fi
_b_allsum=$(w16_all_sum "$CHUNKLOG" gsum); _b_allsum=${_b_allsum:-0}
_b_oksum=$(w16_field_sum "$CHUNKLOG" gsum OK); _b_oksum=${_b_oksum:-0}
_a_sum=${W16_A_SUM:-0}; _a_oksum=${W16_A_OKSUM:-0}
if [ "$_a_sum" -gt "$_b_allsum" ]; then ALLSUM=$_a_sum; else ALLSUM=$_b_allsum; fi
if [ "$_a_oksum" -gt "$_b_oksum" ]; then OKSUM=$_a_oksum; else OKSUM=$_b_oksum; fi
# 下界用"已确认块的值总和"（OKSUM），旧版用的是行数 OKROWS，量纲不对（恒被满足）
if [ "${CUR_SUM:-0}" -ge "$(( PRE_SUM + OKSUM ))" ] && [ "${CUR_SUM:-0}" -le "$(( PRE_SUM + ALLSUM ))" ]; then
  pass "  值总和在区间内（$CUR_SUM ∈ [$(( PRE_SUM + OKSUM )), $(( PRE_SUM + ALLSUM ))]）"
else fail "  值总和越界（$CUR_SUM ∉ [$(( PRE_SUM + OKSUM )), $(( PRE_SUM + ALLSUM ))]）"; fi
w16_dev_min
n_run=0; for h in "${DN[@]}"; do [ "$(dn_state "$h")" = "Running" ] && n_run=$(( n_run + 1 )); done
assert_eq "  结束后仍 Running 的 DataNode 个数" "$n_run" "${#DN[@]}"
log "  结束后仍阻塞在 WAL 队列代码里的线程（宽口径）：$(wal_sum_over_dn wal_blocked_writers)（throttle 阻塞属预期，只记录）"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w16_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 失败类正则：本用例不故意触发 WAL 错误）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|Connection reset by peer|Connection refused|Waiting too long for memTable flush to be done'
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
