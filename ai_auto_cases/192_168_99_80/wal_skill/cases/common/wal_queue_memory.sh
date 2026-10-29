#!/bin/bash
# ============================================================================
# W-18 大压力下 WAL 队列内存受控（tree / mem）
#   目标（cases/cases.tsv W-18）：`WAL_PRESSURE_DEVS × WAL_PRESSURE_ROWS` 高并发大写入期间
#     反复采集 WAL 队列内存（`wal_queue_mem_cost{name="wal_queue_current_mem_cost"|"wal_queue_max_mem_cost"}`）
#     + DN 堆使用率 + 阻塞写入线程数 → 证明"队列内存受控、不 OOM、写入最终成功"。
#   判据（FAIL 只来自数据面 / 场景有效性）：
#     1) 场景有效性（硬）：压力窗口内写入**确实发生**（已确认块 ≥1 且已确认点数 ≥ DEVS×PER×2）；
#        结束时 3/3 DataNode 仍 Running；`wal_buffer_queue_proportion`（restart-only，真实键）能读到
#        生效值/配置值（读不到只 WARN，见 DECISIONS §2"指标/键是否存在只 WARN"）。
#     2) **无 OOM（硬）**：`wal_oom_cnt`（跨全部 DN 的 `OutOfMemoryError|Java heap space|GC overhead limit exceeded`
#        行数）必须 **0**（DECISIONS §5 明确的硬断言；`COMMON_ERR_PAT` 也会在收尾复扫一遍）。
#     3) DN 进程存活（硬）：结束后 3/3 Running；采样期间若某 DN 掉过 → 打印证据 + WARN「场景受扰」，
#        结束时仍未恢复 → FAIL。
#     4) 写入最终成功（硬）：以写入器自己记账的"已确认（status=OK）点数"为准——
#        可见点数 ≥ 基线 + 已确认、≤ 基线 + 全部块点数（不得凭空多出）、值总和在区间内。
#        写入报错时**先把证据打出来**（chunk 输出 + 各 DN 日志尾部 + 指标 + jstack 片段 + show cluster）
#        再判定：`WRITE_PROCESS_REJECT / The write is rejected because the wal directory size has reached
#        the threshold`（文档 §7.2/§10.4 允许的阻写拒绝）只 WARN 且要求后续能恢复（有 OK 块）；
#        其它 Exception（真正的写失败）判 FAIL。
#     5) 只 WARN：队列内存/堆内存的**绝对值**（文档只给相对口径"memtable 内存的 10%"，
#        `feature_extract.md#B.4`；堆使用率超 `WAL_HEAP_WARN_RATIO` 只 WARN）、是否观测到阻写
#        （R-W85：小规模/大堆环境下压不满，属"场景未成立"）、耗时（R-W123）、指标是否存在。
#   源码/文档依据：
#     · feature_extract.md#B：旧实现 ArrayBlockingQueue 按**元素个数**（默认 500）控制 ⇒ 339 个 InsertNode
#       就超 4GB 内存（TIMECHODB-1116 的 OOM 直接原因）；新实现 `MemoryControlledWALEntryQueue`
#       入队先算内存、超上限 `while (cannotReserveMemoryForWalEntry(size)) nonFullCondition.wait();`
#       ⇒ **阻塞写入线程（不是报错）**，出队后 `notifyAll()` 唤醒；全局 `nonFullCondition` 防多队列漏唤醒。
#     · 配置：`wal_buffer_queue_proportion` 默认 `0.1`（memtable 内存的 10%，**restart-only**，
#       `source_grounding.md §1.2#19`；旧键 `wal_buffer_queue_capacity` 已被替代，仅作旁证打印）。
#     · 指标：`wal_queue_mem_cost{name="wal_queue_current_mem_cost"}`（AutoGauge）/
#       `{name="wal_queue_max_mem_cost"}`（Gauge）——`source_grounding.md §9`（WritingMetrics.java:280-294）。
#     · 文档给出的验证结论：原本会快速 OOM 的场景跑 1 天+ 无 OOM（`WAL 队列内存控制.md#测试验证`）
#       ⇒ 本用例只做**短窗口**回归，长稳另议（R-W123）。
#   ⚠️ 本脚本**未在集群实跑**（harness 阶段）。首轮 watch list：
#     ① 队列内存指标到底叫什么：`wal_metric_exists`/`wal_metric_names` 是否能看到 `wal_queue_mem_cost`；
#        看不到时用例只 WARN（不判 FAIL），但要把 `wal_buffer{name="used_ratio"|"entries_count"}` 一并打出来。
#     ② 是否真的出现阻写：3C3D 的 DN 堆大小未知，堆大时队列内存永远压不到上限 ⇒ 记"场景未成立"+WARN，
#        **不要**据此判缺陷；先看采样行里的 `heapPct` 与 `q=cur/max` 走势，再决定是否调大
#        W18_TARGET_ROWS / PAYLOAD_LEN / 调小 W18_QUEUE_PROP 重跑。
#     ③ DN 堆口径：`jcmd GC.heap_info` 在 G1 下是 `total …K, used …K`，非 G1 的格式解析不出来 ⇒
#        `heapPct` 会显示 `?`（只 WARN），此时用 lib 的 `wal_heap_ratio`（used KB）看趋势。
#     ④ 写入被阻塞（throttle/队列满）会让 CLI 变慢甚至 rc=124：这属"阻写=阻塞"，不当产品报错，
#        但若出现真正异常（除了 WRITE_PROCESS_REJECT 类）要按 FAIL 处理，并先打全证据。
#     ⑤ 收尾三件套会逐个停/起 DN（约 4min）：停 DN 期间的 `Failed to CHANGE_REGION_LEADER` 属测试动作噪声。
#   用法：bash cases/common/wal_queue_memory.sh [--consensus IoTConsensus|IoTConsensusV2]
#   时长大致：集群准备 ~4min + 基线 ~1min + 压力 ≤WAL_PRESSURE_WIN_SEC + 排空 + 收尾 ~4min。
#     可调：W18_DEVS/W18_PER/W18_STMTS_PER_DEV/W18_MAX_CHUNKS/W18_TARGET_ROWS/W18_WIN_SEC/
#           W18_QUEUE_PROP/W18_PAYLOAD_LEN/W18_DRAIN_WIN_SEC/W18_SAMPLE_SEC。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_queue_memory_${DATA_CONSENSUS}"

# 环境兜底：conf/env.conf 没有这三个 TTL 键，而 lib/common.sh 的 cluster_set_conf 会引用它们（set -u 下会中断准备）
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"

DB=root.walmem                                    # 用例约定的库名（tree 模型）
DEVS=${W18_DEVS:-$WAL_PRESSURE_DEVS}              # 并发设备数（默认 20）
ROWS=${W18_ROWS:-$WAL_PRESSURE_ROWS}              # 每设备目标点数（默认 20000）⇒ 目标 = DEVS×ROWS
PER=${W18_PER:-200}                               # 每条 INSERT 的行数
STMTS=${W18_STMTS_PER_DEV:-2}                     # 每设备每块语句数 ⇒ 每块点数 = DEVS×STMTS×PER
TARGET=${W18_TARGET_ROWS:-$(( DEVS * ROWS ))}     # 压力目标点数
WIN=${W18_WIN_SEC:-${WAL_PRESSURE_WIN_SEC:-300}}  # 压力窗口（秒）
GRACE=${W18_GRACE_SEC:-120}                       # 窗口外给写入器收尾的时间
SAMPLE=${W18_SAMPLE_SEC:-5}                       # 采样间隔（秒）
DRAIN_WIN=${W18_DRAIN_WIN_SEC:-300}               # 停写后等"已确认数据全部可见"的窗口
QUEUE_PROP=${W18_QUEUE_PROP:-0.1}                 # wal_buffer_queue_proportion（restart-only，默认 0.1）
PAYLOAD_LEN=${W18_PAYLOAD_LEN:-256}
ROWS_PER_CHUNK=$(( DEVS * STMTS * PER ))
MAXCH=${W18_MAX_CHUNKS:-0}
[ "${MAXCH:-0}" -gt 0 ] || MAXCH=$(( (TARGET + ROWS_PER_CHUNK - 1) / ROWS_PER_CHUNK ))
[ "$MAXCH" -lt 1 ] && MAXCH=1
HEAP_WARN=${WAL_HEAP_WARN_RATIO:-0.9}
PAYLOAD=$(printf 'z%.0s' $(seq 1 "$PAYLOAD_LEN"))
BASE0=$(( ($(date +%s) - 3600) * 1000 ))
BASE_ROWS=${W18_BASE_ROWS:-100}
BASE_COUNT=$(( DEVS * BASE_ROWS ))
BASE_SUM=$(( BASE_ROWS * (BASE_ROWS + 1) / 2 * DEVS ))

# 压力相：关三类合并（避免合并把 WAL 变无效而干扰观测）；关 WAL 压缩（让 WAL 消费更慢 ⇒ 队列更容易积压）
W18_EXTRA="wal_mode=${WAL_MODE},enable_wal_compression=false,wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_FILE_THRESHOLD_BYTES},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES},wal_throttle_threshold_in_byte=${WAL_THROTTLE_BYTES},wal_buffer_queue_proportion=${QUEUE_PROP},${CMP_EXTRA_WRITE}"

KEY_PROP="wal_buffer_queue_proportion"            # 真实键（restart-only）
KEY_OLD="wal_buffer_queue_capacity"               # 旧键（已被替代，只作旁证）

CHUNKLOG="$ART/w18_chunks.txt"
SAMPLELOG="$ART/w18_samples.txt"
STOPF="$ART/w18_stop"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 配置面：先看运行期生效值，再看配置文件；读不到只 WARN ----
w18_conf(){ local h=$1 k=$2 v
  v=$(cmp_eff "$h" "$k"); [ -n "${v:-}" ] || v=$(wal_props_get "$h" "$k")
  printf '%s' "${v:-}"; }
w18_probe_key(){ local h=$1 k=$2 p v
  for p in "$DB_DIR/conf/iotdb-system.properties" "$DB_DIR/conf/iotdb-system.properties.template"; do
    v=$(sshx "$h" "grep -hE '^[[:space:]]*$k[[:space:]]*=' $p 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r')
    [ -n "${v:-}" ] && { printf '%s=%s' "${p##*/}" "$v"; return 0; }
  done
  printf ''; return 1; }

# ---- ② 内存/队列观测 ----
# DN 堆 used/total（jcmd GC.heap_info；G1 形态解析不出来时输出 "?"，只记录）
w18_heap_raw(){ local h=$1 pid
  pid=$(wal_dn_pid "$h")
  [ -n "${pid:-}" ] || { printf ''; return 1; }
  sshx "$h" "jcmd $pid GC.heap_info 2>/dev/null" 2>/dev/null | tr -d '\r'; }
w18_heap_pct(){ local raw=$1
  printf '%s\n' "$raw" | awk '{ t=""; u="";
      for (i=1;i<=NF;i++){ if ($i=="total"){ t=$(i+1); sub(/K,?$/,"",t) } if ($i=="used"){ u=$(i+1); sub(/K,?$/,"",u) } }
      if (t != "" && u != "" && t+0 > mt) { mt=t+0; mu=u+0 }
    } END { if (mt>0) printf "%.3f", mu/mt; else printf "?" }'; }
w18_q_cur(){ wal_metric_sum_over_dn wal_metric_queue_cur; }
w18_q_max(){ wal_metric_sum_over_dn wal_metric_queue_max; }
w18_q_per_node(){ local h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(wal_metric_queue_cur "$h")/$(wal_metric_queue_max "$h") "; done; echo "$out"; }
w18_blocked(){ wal_sum_over_dn wal_blocked_writers; }
w18_blocked_snippet(){ local h=$1 pid
  pid=$(wal_dn_pid "$h")
  [ -n "${pid:-}" ] || return 0
  sshx "$h" "jstack $pid 2>/dev/null | grep -B3 -A8 'nonFullCondition' | head -40" 2>/dev/null | tr -d '\r'; }

# ---- ③ WAL 面（目录 + 指标口径）----
w18_ident_dirs(){ local h=$1
  sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 2 -type d -name '$DB-*' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w18_db_files(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w18_db_bytes(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w18_db_sum(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h") )); done; echo "$s"; }
w18_wal_report(){ local tag=$1
  log "  [WAL/$tag] 本库=$(w18_db_sum w18_db_files)f/$(w18_db_sum w18_db_bytes)B 整目录=$(wal_sum_over_dn wal_file_cnt)f/$(wal_sum_over_dn wal_dir_bytes)B；指标 file_count=$(wal_metric_sum_over_dn wal_metric_file_cnt) file_size=$(wal_metric_sum_over_dn wal_metric_file_bytes)"; }

# ---- ④ 写入器（后台；按块记账）----
# 每块：DEVS 设备 × STMTS 条语句 × PER 行；值 = 全局自增 g；s2 是大 payload（撑内存/WAL 体积）
w18_writer(){ local db=$1 stopf=$2 logf=$3 maxch=$4 win=$5 t0=$6
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
          ts=$(( BASE0 + g * 10 ))
          vals="$vals($ts,$g,'$PAYLOAD'),"
        done
        ST+=("insert into $db.d$d(time,s1,s2) values ${vals%,};")
      done
    done
    ms0=$(date +%s%3N)
    printf '%s\n' "${ST[@]}" | session_tree >"$ART/w18_chunk.out" 2>&1; rc=$?
    ms1=$(date +%s%3N)
    errs=$(grep -cE 'Exception|ERROR' "$ART/w18_chunk.out" 2>/dev/null)
    if [ "${rc:-0}" != "0" ] || [ "${errs:-0}" -gt 0 ]; then
      printf 'chunk=%s rows=%s gsum=%s ms=%s status=PARTIAL rc=%s errs=%s\n' "$c" "$rows" "$gs" "$(( ms1 - ms0 ))" "$rc" "$errs" >>"$logf"
      grep -E 'Exception|ERROR' "$ART/w18_chunk.out" 2>/dev/null | head -5 >>"$logf"
      break
    fi
    printf 'chunk=%s rows=%s gsum=%s ms=%s status=OK\n' "$c" "$rows" "$gs" "$(( ms1 - ms0 ))" >>"$logf"
  done }
w18_field_sum(){ local f=$1 key=$2 fst=$3
  grep -F "status=$fst" "$f" 2>/dev/null | sed -n "s/.* $key=\([0-9]*\) .*/\1/p" | awk '{s+=$1} END{print s+0}'; }
w18_all_sum(){ local f=$1 key=$2
  sed -n "s/^chunk=.* $key=\([0-9]*\) .*/\1/p" "$f" 2>/dev/null | awk '{s+=$1} END{print s+0}'; }

# ---- ⑤ 数据面 ----
w18_total(){ row_sum "$(sq "select count(s1) from $DB.**;")"; }
w18_total_sum(){ row_sum "$(sq "select sum(s1) from $DB.**;")"; }
w18_wait_ge(){ local label=$1 sql=$2 want=$3 win=$4 dl got
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(row_sum "$(sq "$sql")")
    [ "${got:-0}" -ge "$want" ] && { pass "  $label: $got（≥ $want）"; return 0; }
    log "    等 $label: 实际=${got:-?} 目标≥$want（$(date '+%T')）"
    sleep 5
  done
  fail "  $label: 实际=${got:-?} 目标≥$want（等 ${win}s 仍未达标）"
  return 1; }

# ---- ⑥ 采样一行 ----
w18_sample(){ local tag=$1 t0=$2 up=0 h st pct raw qc qm bl wb
  for h in "${DN[@]}"; do [ "$(dn_state "$h")" = "Running" ] && up=$(( up + 1 )); done
  pct="?"; raw=$(w18_heap_raw "${DN[0]}"); [ -n "${raw:-}" ] && pct=$(w18_heap_pct "$raw")
  qc=$(w18_q_cur); qm=$(w18_q_max); bl=$(w18_blocked)
  wb=$(wal_metric_sum_over_dn wal_metric_file_bytes); [ "${wb:-0}" -gt 0 ] || wb=$(wal_sum_over_dn wal_dir_bytes)
  printf 'phase=%s t=%s chunks=%s dn_up=%s heapPct=%s heapKB=%s q=%s/%s blocked=%s walB=%s\n' \
    "$tag" "$(( $(date +%s) - t0 ))" "$(grep -c '.' "$CHUNKLOG" 2>/dev/null)" "${up:-0}" "${pct:-?}" \
    "$(wal_heap_ratio "${DN[0]}")" "${qc:-0}" "${qm:-0}" "${bl:-0}" "${wb:-0}" >>"$SAMPLELOG"
  log "    [采样 $tag t=$(( $(date +%s) - t0 ))s] 块=$(grep -c '.' "$CHUNKLOG" 2>/dev/null) DN在线=${up:-0}/${#DN[@]} 堆=${pct:-?}($(wal_heap_ratio "${DN[0]}")K) 队列=${qc:-0}/${qm:-0} 阻塞=${bl:-0} WAL=${wb:-0}B"
  W18_UP_NOW=$up; W18_PCT_NOW=$pct; W18_QC_NOW=$qc; W18_QM_NOW=$qm; W18_BL_NOW=$bl; }

# ---- ⑦ 写入失败/异常时的全证据（先取证再判定）----
w18_evidence(){ local tag=$1 h
  log "=== 证据（$tag）==="
  log "  chunk 记录（$CHUNKLOG）："; sed 's/^/      /' "$CHUNKLOG" >>"$OUT" 2>&1
  log "  最后一次 chunk 原始输出（$ART/w18_chunk.out）尾部 30 行："
  tail -30 "$ART/w18_chunk.out" 2>/dev/null | sed 's/^/      /' >>"$OUT" 2>&1
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(dn_state "$h") 进程：$(sshx "$h" "pgrep -af com.timecho.iotdb.DataNode | head -2" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-160)"
    log "  [$h] GC.heap_info：$(w18_heap_raw "$h" | tr '\n' ' ' | cut -c1-300)"
    log "  [$h] 队列内存 cur/max=$(wal_metric_queue_cur "$h")/$(wal_metric_queue_max "$h") used_ratio=$(wal_metric_buffer "$h" used_ratio) entries=$(wal_metric_buffer "$h" entries_count)"
    log "  [$h] log_datanode_all.log 尾部 25 行（含 OOM/WARN 证据）："
    sshx "$h" "tail -25 $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -d '\r' | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] OOM 相关行："
    sshx "$h" "grep -ahE 'OutOfMemoryError|Java heap space|GC overhead limit exceeded' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -5" 2>/dev/null | tr -d '\r' | sed 's/^/        /' >>"$OUT" 2>&1
  done
  log "  jstack（WAL 队列阻塞现场，${DN[0]}）："; w18_blocked_snippet "${DN[0]}" | sed 's/^/      /' >>"$OUT" 2>&1
  log "  show cluster："; sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"
  log "=== 证据结束（$tag）==="; }

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-18 WAL 队列内存受控：库=$DB 压力=${DEVS}设备×${ROWS}点（目标 ${TARGET} 点）每块 ${ROWS_PER_CHUNK} 点 ==="
log "  WAL 参数组合（关压缩 ⇒ WAL 消费更慢，队列更易积压）：$W18_EXTRA"

log "--- ① 集群准备（清集群 → 写 WAL 参数 → 启动；写入期关三类合并）---"
EXTRA_CONF="$W18_EXTRA" cmp_cluster_prepare
log "  合并参数生效值（抽查）：$(cmp_eff_all "${DN[0]}")"
log "  队列内存键探测：$KEY_PROP=$(w18_conf "${DN[0]}" "$KEY_PROP")（期望 $QUEUE_PROP，restart-only）文件/template=$(w18_probe_key "${DN[0]}" "$KEY_PROP")"
log "  旁证（已被替代的旧键，只打印不使用）：$KEY_OLD=$(w18_conf "${DN[0]}" "$KEY_OLD") 文件/template=$(w18_probe_key "${DN[0]}" "$KEY_OLD")"
V_PROP=$(w18_conf "${DN[0]}" "$KEY_PROP")
if [ "${V_PROP:-}" = "$QUEUE_PROP" ]; then pass "  场景有效性：$KEY_PROP 生效值=$V_PROP（本次写入 $QUEUE_PROP，restart-only 已由启动带生效）"
elif [ -n "${V_PROP:-}" ]; then warn "  $KEY_PROP 读到的值是 $V_PROP（≠ 写入的 $QUEUE_PROP）⇒ 记录：队列上限口径可能被环境覆盖，不影响本用例的硬判据"
else warn "  本版本读不到 $KEY_PROP（show configuration 与 properties 都没有）⇒ 只记录，不判 FAIL（口径待标定）"; fi
[ "$(w18_conf "${DN[0]}" enable_wal_compression)" = "false" ] && pass "  enable_wal_compression=false 已生效" \
  || warn "  enable_wal_compression 不是 false ⇒ WAL 消费更快，队列更难积压（记录）"
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done
log "  指标存在性（缺失只 WARN）：wal_queue_mem_cost=$(wal_metric_exists "${DN[0]}" wal_queue_mem_cost) wal_buffer=$(wal_metric_exists "${DN[0]}" wal_buffer) wal_node_num=$(wal_metric_exists "${DN[0]}" wal_node_num)"
log "  首轮 WAL 指标名动态发现（含 wal 的时间序列名）：$(wal_metric_names "${DN[0]}" | tr '\n' ' ' | cut -c1-400)"

log "--- ② 造库/建序列 + 基线小批（$BASE_COUNT 点；只为数据完整性判据提供 PRE_COUNT/PRE_SUM）---"
{
  printf 'create database %s;\n' "$DB"
  for (( d=1; d<=DEVS; d++ )); do
    printf 'create timeseries %s.d%s.s1 with datatype=INT64 encoding=PLAIN compression=SNAPPY;\n' "$DB" "$d"
    printf 'create timeseries %s.d%s.s2 with datatype=TEXT encoding=PLAIN compression=UNCOMPRESSED;\n' "$DB" "$d"
  done
} >"$ART/w18_ddl.sql"
session_tree <"$ART/w18_ddl.sql" >"$ART/w18_ddl.out" 2>&1
if grep -qE 'Exception|ERROR' "$ART/w18_ddl.out"; then fail "  建库/建序列报错（见 $ART/w18_ddl.out）"; else pass "  建库/建序列完成（${DEVS} 设备 × 2 序列）"; fi
{
  for (( d=1; d<=DEVS; d++ )); do
    vals=""
    for (( k=1; k<=BASE_ROWS; k++ )); do vals="$vals($(( BASE0 + k * 10 )),$k),"; done
    printf 'insert into %s.d%s(time,s1) values %s;\n' "$DB" "$d" "${vals%,}"
  done
} >"$ART/w18_base.sql"
session_tree <"$ART/w18_base.sql" >"$ART/w18_base.out" 2>&1
if grep -qE 'Exception|ERROR' "$ART/w18_base.out"; then fail "  基线小批写入报错"; else pass "  基线小批写入完成（$BASE_COUNT 点）"; fi
wait_scalar_tree "select count(s1) from $DB.d1;" "$BASE_ROWS" 90 "基线小批可见性（$DB.d1 设备路径）"
PRE_COUNT=$(w18_total); PRE_SUM=$(w18_total_sum)
assert_eq "  场景有效性：基线点数" "${PRE_COUNT:-0}" "$BASE_COUNT"
assert_eq "  场景有效性：基线值总和" "${PRE_SUM:-0}" "$BASE_SUM"
w18_wal_report "压力前基线"
log "  压力前堆/队列基线：$(for h in "${DN[@]}"; do printf '%s=heap:%sK,q:%s/%s ' "${h##*.}" "$(wal_heap_ratio "$h")" "$(wal_metric_queue_cur "$h")" "$(wal_metric_queue_max "$h")"; done)"

log "--- ③ 压力写入（后台写入器 + 前台采样：队列内存 / 堆 / 阻塞线程 / WAL 曲线 / DN 在线数）---"
: >"$CHUNKLOG"; : >"$SAMPLELOG"; rm -f "$STOPF"
W18_T0=$(date +%s)
( w18_writer "$DB" "$STOPF" "$CHUNKLOG" "$MAXCH" "$WIN" "$W18_T0" ) &
WPID=$!
log "  写入器已启动（pid=$WPID；每块 ${ROWS_PER_CHUNK} 点、最多 ${MAXCH} 块、窗口 ${WIN}s、目标 ${TARGET} 点）"
MAXQC=0; MAXQM=0; MAXBL=0; MAXPCT=0; MINUP=${#DN[@]}; DN_DROP=0; SNIP=0
while kill -0 "$WPID" 2>/dev/null; do
  sleep "$SAMPLE"
  w18_sample P "$W18_T0"
  [ "${W18_QC_NOW:-0}" -gt "$MAXQC" ] && MAXQC=$W18_QC_NOW
  [ "${W18_QM_NOW:-0}" -gt "$MAXQM" ] && MAXQM=$W18_QM_NOW
  [ "${W18_BL_NOW:-0}" -gt "$MAXBL" ] && MAXBL=$W18_BL_NOW
  case "${W18_PCT_NOW:-?}" in ''|'?') ;; *) awk -v a="$W18_PCT_NOW" -v b="$MAXPCT" 'BEGIN{exit !(a+0>b+0)}' && MAXPCT=$W18_PCT_NOW ;; esac
  [ "${W18_UP_NOW:-0}" -lt "$MINUP" ] && MINUP=$W18_UP_NOW
  [ "${W18_UP_NOW:-0}" -lt "${#DN[@]}" ] && { DN_DROP=1; warn "  采样发现 DataNode 在线数 ${W18_UP_NOW}/${#DN[@]}（场景受扰，先取证）"; }
  if [ "${W18_BL_NOW:-0}" -gt 0 ] && [ "$SNIP" = 0 ]; then
    log "    [队列阻写现场 jstack 片段（${DN[0]}）]"; w18_blocked_snippet "${DN[0]}" | sed 's/^/        /' >>"$OUT" 2>&1; SNIP=1
  fi
  [ $(( $(date +%s) - W18_T0 )) -ge $(( WIN + GRACE )) ] && { log "  达到总窗口上限（${WIN}+${GRACE}s）⇒ 通知写入器停止"; : >"$STOPF"; break; }
done
: >"$STOPF"; wait "$WPID" 2>/dev/null
log "  写入器结束（$(grep -m1 '^stop=' "$CHUNKLOG" 2>/dev/null)）；块记录："
sed 's/^/      /' "$CHUNKLOG" >>"$OUT"

log "--- ④ 写入结果分类（先取证再判定：阻写拒绝 = WARN，其它真异常 = FAIL）---"
OKROWS=$(w18_field_sum "$CHUNKLOG" rows OK); OKSUM=$(w18_field_sum "$CHUNKLOG" gsum OK)
ALLROWS=$(w18_all_sum "$CHUNKLOG" rows); ALLSUM=$(w18_all_sum "$CHUNKLOG" gsum)
CHUNKS_OK=$(grep -c 'status=OK' "$CHUNKLOG" 2>/dev/null)
PART=$(grep -v 'status=OK' "$CHUNKLOG" 2>/dev/null | grep -c . )
log "  已确认块=$CHUNKS_OK 已确认点数=$OKROWS 全部块点数=$ALLROWS；未确认块=$PART"
if [ "${PART:-0}" -gt 0 ]; then
  w18_evidence "写入未全部完成（PARTIAL）"
  if grep -qE 'WRITE_PROCESS_REJECT|The write is rejected because the wal directory size|has reached the threshold' "$ART/w18_chunk.out" 2>/dev/null; then
    warn "  有块被阻写拒绝（WRITE_PROCESS_REJECT / wal directory size has reached the threshold）⇒ 文档 §7.2 允许的阻写表现，只 WARN；下面用「已确认点数」做数据面判据，并要求最终能继续写入"
    if [ "${CHUNKS_OK:-0}" -gt 0 ]; then pass "  阻写拒绝后仍能继续写入（已确认块=$CHUNKS_OK）⇒ 具备恢复能力"; else fail "  全程没有任何块成功（已确认块=0）⇒ 阻写拒绝后未能恢复"; fi
  else
    fail "  压力阶段出现**非阻写类**写入失败（真异常，见上面 chunk 输出与各 DN 日志尾部证据）"
  fi
else
  pass "  压力阶段所有块都正常完成（无异常/无超时）"
fi
if [ "${OKROWS:-0}" -ge $(( DEVS * PER * 2 )) ]; then pass "  场景有效性：压力期已确认点数 $OKROWS ≥ ${DEVS}×${PER}×2（写入确实发生）"
else fail "  场景无效：已确认点数 $OKROWS 太少（< ${DEVS}×${PER}×2）⇒ 压力没打上去，队列内存判据无从谈起"; fi

log "--- ⑤ 硬判据：无 OOM（wal_oom_cnt 必须 0）+ DN 进程存活 ---"
OOM=$(wal_oom_cnt); log "  wal_oom_cnt（跨全部 DN 的 OOM 相关日志行数）=$OOM"
assert_eq "  无 OutOfMemoryError（OOM 日志行数必须 0）" "${OOM:-0}" "0"
n_run=0; for h in "${DN[@]}"; do [ "$(dn_state "$h")" = "Running" ] && n_run=$(( n_run + 1 )); done
assert_eq "  压力后仍 Running 的 DataNode 个数" "$n_run" "${#DN[@]}"
if [ "$DN_DROP" = 1 ]; then warn "  采样期间观测到 DN 在线数下降（最少 ${MINUP}/${#DN[@]}）⇒ 场景受扰，请核对上面的逐副本证据（若确认是重启/OOM 导致，属真缺陷）"; fi
if [ "${MAXPCT:-0}" != "?" ] && awk -v a="$MAXPCT" -v b="$HEAP_WARN" 'BEGIN{exit !(a+0>=b+0)}'; then
  warn "  堆使用率峰值 ${MAXPCT} ≥ WAL_HEAP_WARN_RATIO=${HEAP_WARN}（绝对内存口径文档未给 ⇒ 只 WARN，不作门禁）"
else
  log "  堆使用率峰值=${MAXPCT:-?}（WARN 阈值 ${HEAP_WARN}；具体绝对值只作证据）"
fi
log "  采样峰值：队列当前内存=$MAXQC 队列峰值内存=$MAXQM 阻塞线程=$MAXBL（逐副本 cur/max：$(w18_q_per_node)）"
log "  队列内存绝对值的判据口径：文档只有「memtable 内存的 10%」（$KEY_PROP=$QUEUE_PROP）这一相对口径 ⇒ 本用例只记录"
log "  压力后阻塞线程（宽口径，消费后被唤醒应下降）：$(w18_blocked)"

log "--- ⑥ 数据面（硬）：已确认数据一条不丢 + 不凭空多出 + 总和在区间内 ---"
TARGET_VIS=$(( PRE_COUNT + OKROWS ))
w18_wait_ge "停写后可见点数（≥ 基线 + 已确认）" "select count(s1) from $DB.**;" "$TARGET_VIS" "$DRAIN_WIN"
CUR_COUNT=$(w18_total); CUR_SUM=$(w18_total_sum)
UPPER=$(( PRE_COUNT + ALLROWS ))
if [ "${CUR_COUNT:-0}" -le "$UPPER" ]; then pass "  可见点数未超上界（$CUR_COUNT ≤ 基线$PRE_COUNT + 全部块$ALLROWS）"
else fail "  可见点数超上界（$CUR_COUNT > $UPPER）——出现凭空多出的数据（需人工核查）"; fi
if [ "${CUR_COUNT:-0}" -ge "$TARGET_VIS" ]; then pass "  数据一条不丢：可见点数 $CUR_COUNT ≥ 已确认 $TARGET_VIS"
else fail "  数据丢失：可见点数 $CUR_COUNT < 已确认 $TARGET_VIS"; fi
if [ "${CUR_SUM:-0}" -ge "$(( PRE_SUM + OKSUM ))" ] && [ "${CUR_SUM:-0}" -le "$(( PRE_SUM + ALLSUM ))" ]; then
  pass "  值总和在区间内（$CUR_SUM ∈ [$(( PRE_SUM + OKSUM )), $(( PRE_SUM + ALLSUM ))]）"
else fail "  值总和越界（$CUR_SUM ∉ [$(( PRE_SUM + OKSUM )), $(( PRE_SUM + ALLSUM ))]）——需人工核查"; fi
if [ "${PART:-0}" -gt 0 ]; then warn "  有未确认块（${PART} 块）：可见点数落在 [${TARGET_VIS}, ${UPPER}] 属正常（未确认块的落库情况不可知），仅记录"; fi
w18_wal_report "压力后"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 再打一遍逐副本证据（便于定责）---"
  w18_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 失败类正则；队列阻塞/阻写拒绝属预期，已列入 benign）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|Connection reset by peer|Connection refused|Interrupted when waiting for (adding WALEntry to buffer|taking WALEntry from blocking queue)|Waiting too long for memTable flush to be done'
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
