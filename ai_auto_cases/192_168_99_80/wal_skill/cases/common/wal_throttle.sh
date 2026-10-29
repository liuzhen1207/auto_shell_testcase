#!/bin/bash
# ============================================================================
# W-17 **WAL 阻写（throttle / 背压）**：阈值调小 + 高速写入 → 出现阻写迹象；
#       阻写 = **阻塞写入线程**（消费后被唤醒、**不报错**）；解除后数据一条不丢
#
# 一句话：把 WAL 总大小阈值调小，然后猛写。期望看到"写入变慢 / 写入线程阻塞在
#   `nonFullCondition.wait()` / 队列内存顶到上限"这类阻写迹象；并且**写入不能报错**
#   （阻写是阻塞不是拒绝），消费线程 notifyAll 后写入继续，最终**数据一条不丢**。
#
# ---------------------------------------------------------------------------
# 【需求依据（含键名定案）】
#   · source_grounding.md（源码印证，**定案**）：真实键是 **`wal_throttle_threshold_in_byte`**，
#     且它是 **hot_reload**（可 `SET CONFIGURATION` 热改，**不必重启**）；
#     `iot_consensus_throttle_threshold_in_byte`（design_extract.md §5.5 里那个键）**源码已废弃** ⇒
#     本用例只用 `wal_throttle_threshold_in_byte` 做主键，另一个键**只打印一次作为"已废弃键"的旁证**。
#   · feature_extract.md B（WAL 队列内存控制）：入队时先算内存大小，超过最大值就
#     `while (SystemInfo.getInstance().cannotReserveMemoryForWalEntry(elementSize)) { nonFullCondition.wait(); }`
#     ⇒ **阻塞写入线程**、不是报错、不是拒绝；出队后 `notifyAll()` 唤醒；
#     旧实现按"元素个数"（默认 500）控制、新实现按**内存占比**（`wal_buffer_queue_proportion` 默认 0.1）控制。
#   · design_extract.md §7.1-4（写入阻塞上限：达到阈值的处理）、§8 TP-15（超限时应"不 OOM、写入变慢"）、
#     TP-32（达到阈值时的两种行为：IoTConsensus 导致 ⇒ 阻止写入；非 IoTConsensus 导致 ⇒ 快照/刷盘且不阻塞）。
#   ⚠️ 源码复核补充（REQ_MATRIX §6-7/§6-8）：阻写**不是单一机制** ——
#      · WALManager 侧（按 WAL 磁盘占用）：不阻塞，只删文件 / 触发快照，超水位打 WARN；
#      · IoTConsensus 侧：阻塞写入线程约 30s 后返回 `WRITE_PROCESS_REJECT`（拒绝）。
#      · 旧键 `iot_consensus_throttle_threshold_in_byte` **优先级更高**且读到即打废弃 WARN，
#        而文档只写了旧键 ⇒ 判据必须「任一键 / 任一机制出现即场景成立」。
#   · 相关指标（source_grounding.md）：`wal_queue_mem_cost{name="wal_queue_current_mem_cost"|"wal_queue_max_mem_cost"}`、
#     `wal_buffer{name="used_ratio"|"entries_count"}`（helper：wal_metric_queue_cur / wal_metric_queue_max / wal_metric_buffer）。
#
# 【为什么关掉 WAL 压缩（否则阈值几乎压不到）】
#   本用例的目标是让 WAL **文件总大小**尽快顶到阈值 ⇒ 必须让 WAL 体积与写入量成正比。
#   若 `enable_wal_compression=true`（默认），高度重复的 payload 会被 LZ4 压掉一两个数量级，
#   想顶到 10MB 阈值就得写几百 MB 数据 ⇒ 本用例显式 `enable_wal_compression=false`（并逐节点核对生效值）。
#
# 【判据结构（硬/软分明）】
#   ① 场景有效性（软/硬分开）：
#      · **软**：阈值键是否存在/是否能热改生效、是否观测到阻写迹象（写入变慢 / 阻塞线程 >0 / 队列内存顶格 /
#        相关日志）。**观测不到阻写只 WARN**（cases.tsv 明确：小规模压不出阻写时"如实记场景未成立 + WARN"）。
#      · **硬**：阈值键在本版本**完全不存在** ⇒ `warn "本版本无该键，场景不可构造"`，**不判 FAIL**（按需求）；
#        压力阶段的写入**不得报错/异常/超时**；三个 DN 在压力后仍 Running。
#   ② 数据面（硬）：以"写入器自己记账的**已确认批次数**"为准——
#      `可见点数 ≥ 基线 + 已确认点数`（一条不丢）、`可见点数 ≤ 基线 + 已确认 + 最后未确认块的量`（不得凭空多出）；
#      总和同口径校验。阻写解除后必须在窗口内把已确认数据全部应用（否则"消费后唤醒"不成立 ⇒ FAIL）。
#   ③ 过程证据（软）：写入耗时序列（变慢）、阻塞线程数峰值（jstack 片段）、队列内存 cur/max、
#      WAL 字节/文件数曲线（目录口径 + 指标口径）、阻塞相关日志行数、OOM 行数（**OOM 是硬判据 = 0**）。
#
# 【刻意不做的事】
#   · 不用已废弃的 `iot_consensus_throttle_threshold_in_byte` 做主键（只打印一次旁证）。
#   · 不把"没观测到阻写"判为 FAIL（阈值/规模/环境都可能导致压不出来）。
#   · 不断言 `WALNode.java:466-470` 的"删除过期 WAL 条数"文案（DEBUG 级、默认不落盘）。
#   · 不改 lib/、tools/、conf/、cases.tsv、docs/（只新增本文件）。
#
# 【时长大致】≈22~30 分钟（集群准备 ~4min + 建库/基线 ~3min + 压力写入 ≤${WAL_PRESSURE_WIN_SEC}s 默认 300s
#   + 排空/唤醒等待 ≤~5min + 收尾三件套 ~4min）。可调：W17_DEVS/W17_PER/W17_STMT_PER_DEV/W17_MAX_CHUNKS/
#   W17_WIN_SEC/W17_THROTTLE_BYTES/W17_DRAIN_WIN_SEC。
#
# 【⚠️ 首轮 watch list（先看这些才知道"场景真的成立了"）】
#   1) **两个候选键的探测结果**：`wal_throttle_threshold_in_byte` 在 `show configuration` / properties /
#      template 三处哪一处能读到；`SET CONFIGURATION` 的返回文案里**有没有** "restart is required"
#      （源码印证是 hot_reload，若实测要求重启，用例会自动补一次 stop/start 并记录 ⇒ 这条要核对）。
#   2) **阻写迹象到底来自哪个闸门**：字节阈值（本用例设置的键）还是**队列内存占比**
#      （`wal_buffer_queue_proportion`，默认 memtable 内存的 10%）。首轮看 `wal_queue_current_mem_cost`
#      与 `wal_queue_max_mem_cost` 的比值、以及 jstack 里 `nonFullCondition.wait()` 的线程数，
#      判断"顶格的是内存配额而不是字节阈值"（这是很可能的，属正常实现）。
#   3) **压力规模是否够**：如果全程无任何阻写迹象（WARN），先看单块数据量与 WAL 增速
#      （10MB 阈值在健康集群上可能被 MemTable flush/快照迅速释放 ⇒ 永远顶不到），据此调 W17_MAX_CHUNKS /
#      W17_THROTTLE_BYTES 重跑；**不要**据此判缺陷。
#   4) **"不报错"的证据链**：写入器把每个块的 CLI 退出码与异常计数写进产物（`w17_chunks.txt`），
#      首轮确认没有把"被 timeout 杀掉（rc=124）"误当成产品报错（那是阻塞太久 ⇒ 反而是"未被唤醒"的证据）。
#   5) **排空耗时**：压力结束后要把已确认数据全部应用（可见点数达标）需要多久；首轮记录，
#      据此决定 W17_DRAIN_WIN_SEC（默认 300s）是否要加大。
#
# 用法： bash cases/common/wal_throttle.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 本文件**未在真实集群实跑过**（99.80 正在跑长回归，禁止任何集群动作）；只保证逻辑自洽 + 静态检查通过。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_throttle_${DATA_CONSENSUS}"

# 环境兜底：conf/env.conf 未定义这三个 TTL 键，而 lib/common.sh 的 cluster_set_conf 会引用它们（set -u 下会中断准备）
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"

DB=root.walthr                        # 用例约定的库名
DEVS=${W17_DEVS:-$WAL_PRESSURE_DEVS}          # 压测设备数（默认 20）
PER=${W17_PER:-200}                           # 每条 INSERT 的行数
STMTS_PER_DEV=${W17_STMT_PER_DEV:-5}          # 每设备每块的语句数 ⇒ 每块行数 = DEVS×STMTS×PER
MAXCH=${W17_MAX_CHUNKS:-8}                    # 最多写几块（配合窗口做硬上限，避免无限写）
THR=${W17_THROTTLE_BYTES:-$WAL_THROTTLE_SMALL} # 调小的阈值（默认 10MB）
WIN=${W17_WIN_SEC:-${WAL_PRESSURE_WIN_SEC:-300}}   # 压力写入窗口（秒）
GRACE=${W17_GRACE_SEC:-180}                   # 窗口之外再给写入器多久收尾
DRAIN_WIN=${W17_DRAIN_WIN_SEC:-300}           # 压力结束后等"已确认数据全部可见"的窗口
SLOW_RATIO=${W17_SLOW_RATIO:-3}               # 变慢判据：最慢块 / 前 3 块中位数 ≥ 该倍数
PAYLOAD_LEN=${W17_PAYLOAD_LEN:-500}
Q_RATIO=${W17_QUEUE_RATIO:-0.9}               # 队列内存 cur/max ≥ 该比例算"顶格"迹象
ROWS_PER_CHUNK=$(( DEVS * STMTS_PER_DEV * PER ))
PAYLOAD=$(printf 'z%.0s' $(seq 1 "$PAYLOAD_LEN"))
BASE0=$(( ($(date +%s) - 3600) * 1000 ))      # 基线小批的时间戳基准（比压力批更早）
BASE_SUM=$(( 200 * 201 / 2 * DEVS ))          # 基线小批：每设备 200 行、值 1..200
BASE_ROWS=$(( 200 * DEVS ))

# 压力阶段：关 WAL 压缩（让 WAL 体积与写入量成正比，否则 10MB 阈值压不到）+ 关三类合并
W17_EXTRA="wal_mode=${WAL_MODE},enable_wal_compression=false,wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_FILE_THRESHOLD_BYTES},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"

KEY_MAIN="wal_throttle_threshold_in_byte"          # 真实键（source_grounding.md 定案；hot_reload）
KEY_DEPRECATED="iot_consensus_throttle_threshold_in_byte"  # 已废弃键（只作旁证打印）

# 产物内的工作文件
STOPF="$ART/w17_stop"
CHUNKLOG="$ART/w17_chunks.txt"
SAMPLELOG="$ART/w17_samples.txt"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 键探测 --------------------------------------------------------------
# 在 conf / conf_orig / template 三处找键；回显 "文件路径=值"（找到第一个非空即停）
w17_probe_key(){ local h=$1 k=$2 p v
  for p in "$DB_DIR/conf/iotdb-system.properties" "$DB_DIR/conf_orig/iotdb-system.properties" "$DB_DIR/conf/iotdb-system.properties.template"; do
    v=$(sshx "$h" "grep -hE '^[[:space:]]*$k[[:space:]]*=' $p 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r')
    [ -n "${v:-}" ] && { printf '%s=%s' "${p##*/}" "$v"; return 0; }
  done
  printf ''; return 1; }
# 运行期生效值（show configuration）+ 配置文件值 的合成探测结论
w17_key_state(){ local h=$1 k=$2 eff props
  eff=$(wal_eff "$h" "$k"); props=$(wal_props_get "$h" "$k")
  log "    [键探测] $k：show configuration='${eff:-（无）}' properties='${props:-（无）}' 文件/template='$(w17_probe_key "$h" "$k")'"
  [ -n "${eff:-}" ] && { printf 'RUN'; return 0; }
  [ -n "${props:-}" ] && { printf 'FILE'; return 0; }
  printf ''; return 1; }

# ---- ② 写入器（后台跑；按块记账，便于"一条不丢"的硬判据）--------------------
# 每块：DEVS 设备 × STMTS_PER_DEV 条语句 × PER 行；每条语句的值是全局自增 g（用于总和校验）
# 块完成后往 $CHUNKLOG 追加一行：`chunk=N rows=R gsum=G ms=M status=OK|PARTIAL ...`
w17_writer(){ local db=$1 stopf=$2 logf=$3 maxch=$4 win=$5 t0=$6
  local c=0 d s k g=0 rows gs ts vals rc ms0 ms1 errs
  local base=$(( ($(date +%s) - 3600) * 1000 ))
  while :; do
    [ -f "$stopf" ] && { printf 'stop=stopfile\n' >>"$logf"; break; }
    [ "$c" -ge "$maxch" ] && { printf 'stop=maxchunks\n' >>"$logf"; break; }
    [ $(( $(date +%s) - t0 )) -ge "$win" ] && { printf 'stop=window\n' >>"$logf"; break; }
    c=$(( c + 1 )); rows=0; gs=0
    local -a ST=()
    for (( d=1; d<=DEVS; d++ )); do
      for (( s=1; s<=STMTS_PER_DEV; s++ )); do
        vals=""
        for (( k=0; k<PER; k++ )); do
          g=$(( g + 1 )); rows=$(( rows + 1 )); gs=$(( gs + g ))
          ts=$(( base + g * 10 ))
          vals="$vals($ts,$g,'$PAYLOAD'),"
        done
        ST+=("insert into $db.d$d(time,s1,s2) values ${vals%,};")
      done
    done
    ms0=$(date +%s%3N)
    printf '%s\n' "${ST[@]}" | session_tree >"$ART/w17_chunk.out" 2>&1; rc=$?
    ms1=$(date +%s%3N)
    errs=$(grep -cE 'Exception|ERROR' "$ART/w17_chunk.out" 2>/dev/null)
    if [ "${rc:-0}" != "0" ] || [ "${errs:-0}" -gt 0 ]; then
      printf 'chunk=%s rows=%s gsum=%s ms=%s status=PARTIAL rc=%s errs=%s\n' "$c" "$rows" "$gs" "$(( ms1 - ms0 ))" "$rc" "$errs" >>"$logf"
      grep -E 'Exception|ERROR' "$ART/w17_chunk.out" 2>/dev/null | head -3 >>"$logf"
      break
    fi
    printf 'chunk=%s rows=%s gsum=%s ms=%s status=OK\n' "$c" "$rows" "$gs" "$(( ms1 - ms0 ))" >>"$logf"
  done }

# ---- ③ 阻写观测 ------------------------------------------------------------
# 阻塞写入线程（sharp 口径：`nonFullCondition` / `MemoryControlledWALEntryQueue` 出现在线程栈里）
w17_blocked(){ local h=$1 pid v
  pid=$(wal_dn_pid "$h")
  [ -n "${pid:-}" ] || { echo 0; return; }
  v=$(sshx "$h" "jstack $pid 2>/dev/null | grep -cE 'nonFullCondition|MemoryControlledWALEntryQueue'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 阻塞现场片段（证据；只在观测到阻塞时抓一次）
w17_blocked_snippet(){ local h=$1 pid
  pid=$(wal_dn_pid "$h")
  [ -n "${pid:-}" ] || return 0
  sshx "$h" "jstack $pid 2>/dev/null | grep -B3 -A8 'nonFullCondition' | head -40" 2>/dev/null | tr -d '\r'; }
# 队列内存 cur/max（跨 DN 求和）+ 最大比值
w17_queue_cur(){ wal_metric_sum_over_dn wal_metric_queue_cur; }
w17_queue_max(){ wal_metric_sum_over_dn wal_metric_queue_max; }
w17_max_q_ratio(){ printf '%s\n' "$1" | awk -v c="$2" -v m="$3" 'BEGIN{ if (m+0 > 0) { r = (c+0)/(m+0); printf "%.3f", r } else printf "0" }'; }
# 逐节点快照串（证据）
w17_per_node_blocked(){ local h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(w17_blocked "$h") "; done; echo "$out"; }
w17_per_node_q(){ local h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(wal_metric_queue_cur "$h")/$(wal_metric_queue_max "$h") "; done; echo "$out"; }

# ---- ④ WAL 面（目录 + 指标口径）--------------------------------------------
w17_ident_dirs(){ local h=$1
  sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 2 -type d -name '$DB-*' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w17_db_files(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w17_db_bytes(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w17_db_sum(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h") )); done; echo "$s"; }
w17_wal_report(){ local tag=$1
  log "  [WAL/$tag] 本库=$(w17_db_sum w17_db_files)f/$(w17_db_sum w17_db_bytes)B 整目录=$(wal_sum_over_dn wal_file_cnt)f/$(wal_sum_over_dn wal_dir_bytes)B；指标口径 file_count=$(wal_metric_sum_over_dn wal_metric_file_cnt) file_size=$(wal_metric_sum_over_dn wal_metric_file_bytes)"; }

# ---- ⑤ 完成度等待（`**` 口径要用 row_sum，wait_scalar_tree 只取第一列）-----
w17_wait_ge(){ local label=$1 sql=$2 want=$3 win=$4 dl got
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(row_sum "$(sq "$sql")")
    [ "${got:-0}" -ge "$want" ] && { pass "  $label: $got（≥ $want）"; return 0; }
    log "    等 $label: 实际=${got:-?} 目标≥$want（$(date '+%T')）"
    sleep 5
  done
  fail "  $label: 实际=${got:-?} 目标≥$want（等 ${win}s 仍未达标）"
  return 1; }
w17_total(){ row_sum "$(sq "select count(s1) from $DB.**;")"; }
w17_total_sum(){ row_sum "$(sq "select sum(s1) from $DB.**;")"; }

# ---- ⑥ 证据 / 行数解析 -----------------------------------------------------
w17_field_sum(){ local f=$1 key=$2 fst=$3
  grep -F "status=$fst" "$f" 2>/dev/null | sed -n "s/.* $key=\([0-9]*\) .*/\1/p" | awk '{s+=$1} END{print s+0}'; }
w17_part_rows(){ grep -v 'status=OK' "$CHUNKLOG" 2>/dev/null | sed -n 's/^chunk=.* rows=\([0-9]*\) .*/\1/p' | awk '{s+=$1} END{print s+0}'; }
w17_part_gsum(){ grep -v 'status=OK' "$CHUNKLOG" 2>/dev/null | sed -n 's/^chunk=.* gsum=\([0-9]*\) .*/\1/p' | awk '{s+=$1} END{print s+0}'; }
w17_median_first(){ local n=${1:-3}
  grep -F 'status=OK' "$CHUNKLOG" 2>/dev/null | head -"$n" | sed -n 's/.* ms=\([0-9]*\) .*/\1/p' | sort -n | awk '{a[NR]=$1} END{ if (NR==0) {print 0; exit} if (NR%2) print a[(NR+1)/2]; else printf "%d", (a[NR/2]+a[NR/2+1])/2 }'; }
w17_max_ms(){ grep -F 'status=OK' "$CHUNKLOG" 2>/dev/null | sed -n 's/.* ms=\([0-9]*\) .*/\1/p' | sort -n | tail -1 | awk '{print $1+0}'; }
w17_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(dn_state "$h") 进程：$(sshx "$h" "pgrep -af com.timecho.iotdb.DataNode | head -2" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-160)"
    log "  [$h] 阻塞线程(sharp)=$(w17_blocked "$h") 队列内存 cur/max=$(wal_metric_queue_cur "$h")/$(wal_metric_queue_max "$h")"
    log "  [$h] identifier 目录：$(w17_ident_dirs "$h" | tr '\n' ' ')"
    log "  [$h] WAL 清单（含大小）："
    wal_ls "$h" | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] WAL 相关日志尾部："
    wal_log_tail "$h" 20 | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] log_datanode_all.log 尾部 20 行："
    sshx "$h" "tail -20 $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | sed 's/^/        /' >>"$OUT" 2>&1
  done
  log "  show cluster："
  sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"
  log "=== 逐副本证据结束（$tag）==="; }

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-17 WAL 阻写：库=$DB 阈值=${THR}B（调小）设备=${DEVS} 每块行数=${ROWS_PER_CHUNK} 窗口=${WIN}s ==="
log "  主键（真实键，hot_reload）：$KEY_MAIN；旁证（已废弃键，不使用）：$KEY_DEPRECATED"
log "  WAL 参数组合（关掉 WAL 压缩，让体积与写入量成正比）：$W17_EXTRA"

log "--- ① 集群准备 ---"
EXTRA_CONF="$W17_EXTRA" cmp_cluster_prepare
log "  合并参数生效值（抽查）：$(cmp_eff_all "${DN[0]}")"
CMPCONF=$(cmp_eff "${DN[0]}" enable_wal_compression); [ -z "${CMPCONF:-}" ] && CMPCONF=$(wal_props_get "${DN[0]}" enable_wal_compression)
[ "${CMPCONF:-}" = "false" ] && pass "  enable_wal_compression=false 已生效（WAL 体积与写入量成正比）" \
  || warn "  enable_wal_compression 读到 '${CMPCONF:-空}'（不是 false）⇒ 压缩会把 WAL 压小，可能压不出阈值（记录，不判 FAIL）"
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done

log "--- ② 键探测：先确认本版本用的是哪个键（源码定案：$KEY_MAIN；$KEY_DEPRECATED 已废弃）---"
KEY_STATE_MAIN=""; KEY_STATE_DEP=""
for h in "${DN[@]}"; do
  st=$(w17_key_state "$h" "$KEY_MAIN"); [ -n "${st:-}" ] && KEY_STATE_MAIN="$st"
done
log "  ---- 旁证（已废弃键，只打印，不用它做场景）----"
for h in "${DN[@]}"; do w17_key_state "$h" "$KEY_DEPRECATED" >/dev/null; done
DEP_PROBE=$(w17_probe_key "${DN[0]}" "$KEY_DEPRECATED")
log "  已废弃键 $KEY_DEPRECATED 的遗留痕迹：${DEP_PROBE:-（无）}（源码已废弃 ⇒ 即使存在也不作为本用例的闸门）"

if [ -n "${KEY_STATE_MAIN:-}" ]; then
  pass "  场景有效性：本版本存在 $KEY_MAIN（探测来源=$KEY_STATE_MAIN）"
  log "  热改阈值：SET CONFIGURATION '$KEY_MAIN'='$THR'（源码印证 hot_reload，不必重启）"
  RESP=$(wal_set "$KEY_MAIN" "$THR")
  log "    返回：$(printf '%s' "$RESP" | cut -c1-200)"
  NEED_RESTART=0
  case "$RESP" in *"restart is required"*|*"Restart is required"*) NEED_RESTART=1 ;; esac
  EFF=$(wal_eff "${DN[0]}" "$KEY_MAIN"); [ -z "${EFF:-}" ] && EFF=$(wal_props_get "${DN[0]}" "$KEY_MAIN")
  if [ "${EFF:-}" = "$THR" ] && [ "$NEED_RESTART" = 0 ]; then
    pass "  场景有效性：阈值已热改生效（$KEY_MAIN=$EFF）"
  else
    warn "  热改未直接生效（生效值='${EFF:-空}' 返回要求重启=$NEED_RESTART）⇒ 补一次 stop/start（不清 data）"
    cluster_stop; cluster_start
    EFF=$(wal_eff "${DN[0]}" "$KEY_MAIN"); [ -z "${EFF:-}" ] && EFF=$(wal_props_get "${DN[0]}" "$KEY_MAIN")
    if [ "${EFF:-}" = "$THR" ]; then pass "  重启后阈值已生效（$KEY_MAIN=$EFF）"; else warn "  重启后仍读不到阈值=$THR（生效值='${EFF:-空}'）⇒ 记录：阈值可能未按预期生效，阻写迹象将不可解释"; fi
  fi
  SCENE_KEY=1
else
  warn "  **本版本无该键，场景不可构造**：$KEY_MAIN 在 show configuration / properties / template 三处都读不到 ⇒ 不做阈值设置、不判 FAIL；下面仍会做压力写入 + 数据完整性校验（负向友好）"
  SCENE_KEY=0
fi
log "  当前队列内存口径（阻写真正的闸门很可能是"队列内存占比"，见 feature_extract B）：逐副本 cur/max=$(w17_per_node_q)"

log "--- ③ 建库/建序列（s1 INT64 用于核对总和；s2 TEXT 大 payload 用于堆 WAL 体积）---"
{
  printf 'create database %s;\n' "$DB"
  for (( d=1; d<=DEVS; d++ )); do
    printf 'create timeseries %s.d%s.s1 with datatype=INT64 encoding=PLAIN compression=SNAPPY;\n' "$DB" "$d"
    printf 'create timeseries %s.d%s.s2 with datatype=TEXT encoding=PLAIN compression=UNCOMPRESSED;\n' "$DB" "$d"
  done
} >"$ART/w17_ddl.sql"
session_tree <"$ART/w17_ddl.sql" >"$ART/w17_ddl.out" 2>&1
if grep -qE 'Exception|ERROR' "$ART/w17_ddl.out"; then
  fail "  建库/建序列报错（见 $ART/w17_ddl.out）"
else
  pass "  建库/建序列完成（${DEVS} 设备 × 2 序列）"
fi

log "--- ④ 基线小批（不 flush；只为数据完整性判据提供 PRE_COUNT/PRE_SUM）---"
{
  for (( d=1; d<=DEVS; d++ )); do
    vals=""
    for (( k=0; k<200; k++ )); do vals="$vals($(( BASE0 + k * 10 )),$(( k + 1 ))),"; done
    printf 'insert into %s.d%s(time,s1) values %s;\n' "$DB" "$d" "${vals%,}"
  done
} >"$ART/w17_base.sql"
session_tree <"$ART/w17_base.sql" >"$ART/w17_base.out" 2>&1
if grep -qE 'Exception|ERROR' "$ART/w17_base.out"; then fail "  基线小批写入报错"; else pass "  基线小批写入完成（$BASE_ROWS 点）"; fi
wait_scalar_tree "select count(s1) from $DB.d1;" "200" 90 "基线小批可见性（$DB.d1 设备路径）"
PRE_COUNT=$(w17_total); PRE_SUM=$(w17_total_sum)
assert_eq "  场景有效性：基线点数" "${PRE_COUNT:-0}" "$BASE_ROWS"
assert_eq "  场景有效性：基线值总和" "${PRE_SUM:-0}" "$BASE_SUM"
w17_wal_report "压力前基线"

log "--- ⑤ 压力写入（后台写入器 + 前台采样：阻塞线程 / 队列内存 / WAL 曲线）---"
: >"$CHUNKLOG"; : >"$SAMPLELOG"; rm -f "$STOPF"
W17_T0=$(date +%s)
export DEVS PER STMTS_PER_DEV PAYLOAD
( w17_writer "$DB" "$STOPF" "$CHUNKLOG" "$MAXCH" "$WIN" "$W17_T0" ) &
WRITER_PID=$!
log "  写入器已启动（pid=$WRITER_PID；每块 ${ROWS_PER_CHUNK} 点、最多 ${MAXCH} 块、窗口 ${WIN}s）"
MAXBLOCK=0; MAXBLOCK_LIB=0; MAXQR="0.000"; SNIP_DONE=0
while kill -0 "$WRITER_PID" 2>/dev/null; do
  sleep 5
  b=0; for h in "${DN[@]}"; do b=$(( b + $(w17_blocked "$h") )); done
  bl=$(wal_sum_over_dn wal_blocked_writers)
  qc=$(w17_queue_cur); qm=$(w17_queue_max); qr=$(w17_max_q_ratio "" "$qc" "$qm")
  [ "${b:-0}" -gt "$MAXBLOCK" ] && MAXBLOCK=$b
  [ "${bl:-0}" -gt "$MAXBLOCK_LIB" ] && MAXBLOCK_LIB=$bl
  awk -v a="$qr" -v b="$MAXQR" 'BEGIN{exit !(a+0 > b+0)}' && MAXQR=$qr
  wf=$(wal_sum_over_dn wal_file_cnt); wb=$(wal_sum_over_dn wal_dir_bytes)
  done_ch=$(grep -c '.' "$CHUNKLOG" 2>/dev/null)
  printf 't=%s chunks=%s blocked=%s blocked_lib=%s q=%s/%s(qr=%s) wal=%sf/%sB\n' \
    "$(( $(date +%s) - W17_T0 ))" "${done_ch:-0}" "${b:-0}" "${bl:-0}" "${qc:-0}" "${qm:-0}" "${qr:-0}" "${wf:-0}" "${wb:-0}" >>"$SAMPLELOG"
  log "    [采样 t=$(( $(date +%s) - W17_T0 ))s] 块=${done_ch:-0} 阻塞sharp=${b:-0}(峰值$MAXBLOCK) 阻塞宽口径=${bl:-0} 队列内存=${qc:-0}/${qm:-0}(峰值比$MAXQR) WAL=${wf:-0}f/${wb:-0}B"
  if [ "${b:-0}" -gt 0 ] && [ "$SNIP_DONE" = 0 ]; then
    log "    [阻写现场 jstack 片段（$h）]"
    w17_blocked_snippet "${DN[0]}" | sed 's/^/        /' >>"$OUT" 2>&1
    SNIP_DONE=1
  fi
  if [ $(( $(date +%s) - W17_T0 )) -ge $(( WIN + GRACE )) ]; then
    log "  达到总窗口上限（${WIN}+${GRACE}s）⇒ 通知写入器停止"
    : >"$STOPF"
    break
  fi
done
: >"$STOPF"
wait "$WRITER_PID" 2>/dev/null
STOP_REASON=$(grep -m1 '^stop=' "$CHUNKLOG" 2>/dev/null)
log "  写入器结束（$STOP_REASON）；块记录："
sed 's/^/      /' "$CHUNKLOG" >>"$OUT"

log "--- ⑥ 阻写迹象判定（**软**：观测不到只 WARN，不判 FAIL）---"
OKROWS=$(w17_field_sum "$CHUNKLOG" rows OK); OKSUM=$(w17_field_sum "$CHUNKLOG" gsum OK)
PARTROWS=$(w17_part_rows); PARTGSUM=$(w17_part_gsum)
CHUNKS_OK=$(grep -c 'status=OK' "$CHUNKLOG" 2>/dev/null)
MED=$(w17_median_first 3); MAXMS=$(w17_max_ms)
SLOWX=0; [ "${MED:-0}" -gt 0 ] && SLOWX=$(( MAXMS / MED ))
LOG_THR=$(wal_log_sum 'throttl|Throttl'); LOG_NORES=$(wal_log_sum 'cannotReserveMemoryForWalEntry|cannot reserve memory')
log "  已确认（status=OK）块数=${CHUNKS_OK:-0} 点数=$OKROWS 值总和=$OKSUM；未确认块点数=${PARTROWS:-0}（可能部分落库）"
log "  耗时：前 3 块中位数=${MED:-0}ms 最慢块=${MAXMS:-0}ms ⇒ 变慢倍数=${SLOWX}x（判据 ≥${SLOW_RATIO}x）"
log "  阻塞线程峰值：sharp=$MAXBLOCK 宽口径=$MAXBLOCK_LIB；队列内存峰值比(cur/max)=$MAXQR（判据 ≥$Q_RATIO）"
log "  相关日志行数（累计）：含 throttl=${LOG_THR:-0} 含 cannotReserveMemory=${LOG_NORES:-0}"
SCENE_THROTTLE=0
[ "${MAXBLOCK:-0}" -gt 0 ] && SCENE_THROTTLE=1
[ "${SLOWX:-0}" -ge "$SLOW_RATIO" ] && SCENE_THROTTLE=1
awk -v a="$MAXQR" -v b="$Q_RATIO" 'BEGIN{exit !(a+0 >= b+0)}' && SCENE_THROTTLE=1
[ "${LOG_THR:-0}" -gt 0 ] && SCENE_THROTTLE=1
if [ "${SCENE_THROTTLE:-0}" = 1 ]; then
  pass "  场景有效性：观测到阻写迹象（变慢 ${SLOWX}x / 阻塞线程峰值 ${MAXBLOCK} / 队列内存峰值比 ${MAXQR} / throttl 日志 ${LOG_THR}）"
else
  if [ "${SCENE_KEY:-0}" = 1 ]; then
    warn "  场景未成立（小规模未压出阻写）：阈值已设为 ${THR}B，但未观测到写入变慢/阻塞线程/队列顶格/相关日志 ⇒ 只 WARN，不判 FAIL（可调大 W17_MAX_CHUNKS 或调小 W17_THROTTLE_BYTES 重跑）"
  else
    warn "  场景未成立（本版本无 $KEY_MAIN 键，场景不可构造）⇒ 只 WARN，不判 FAIL；压力写入与数据完整性仍按硬判据校验"
  fi
fi

log "--- ⑦ 硬判据：异常分类 + 数据一条不丢 + 阻写解除后已确认数据全部可见 ---"
# 阻写有**两套机制**（REQ_MATRIX §6-7/§6-8 源码复核）：
#   ① WALManager 侧（按 WAL 磁盘占用）：**不阻塞**，只删文件 / 触发快照，超水位打 WARN；
#   ② IoTConsensus 侧：**阻塞写入线程约 30s**，超时后返回 `WRITE_PROCESS_REJECT`（即「拒绝」）。
# ⇒ 压力阶段出现「被拒绝」是**预期行为**（不能当 FAIL）；只有「非阻写类异常」才 FAIL。
REJECT_HITS=$(grep -ahcE 'WRITE_PROCESS_REJECT|write process reject|throttl' "$CHUNKLOG" $ART/w17_chunk*.out 2>/dev/null | awk '{s+=$1} END{print s+0}')
REJECT_HITS=${REJECT_HITS:-0}
OTHER_PARTIAL=$(grep -a 'status=PARTIAL' "$CHUNKLOG" 2>/dev/null | grep -avcE 'WRITE_PROCESS_REJECT|write process reject|throttl' | tr -dc '0-9')
OTHER_PARTIAL=${OTHER_PARTIAL:-0}
if [ "${OTHER_PARTIAL}" -gt 0 ]; then
  fail "  压力阶段有 ${OTHER_PARTIAL} 个块以**非阻写类**异常结束（明细见 $CHUNKLOG 与 $ART/w17_chunk.out）"
else
  pass "  压力阶段无非阻写类异常（其中阻写/拒绝类证据 ${REJECT_HITS} 处，属预期）"
fi
if [ "${REJECT_HITS}" -gt 0 ]; then
  warn "  阻写以「拒绝」形式出现（WRITE_PROCESS_REJECT / throttle 文案，${REJECT_HITS} 处）：与源码「IoTConsensus 侧阻塞约 30s 后拒绝」一致 ⇒ 记为证据，不判 FAIL"
fi
TARGET=$(( PRE_COUNT + OKROWS ))
w17_wait_ge "阻写解除后可见点数（≥ 基线 + 已确认）" "select count(s1) from $DB.**;" "$TARGET" "$DRAIN_WIN"
CUR_COUNT=$(w17_total); CUR_SUM=$(w17_total_sum)
UPPER=$(( PRE_COUNT + OKROWS + PARTROWS ))
if [ "${CUR_COUNT:-0}" -le "$UPPER" ]; then
  pass "  可见点数未超过上界（$CUR_COUNT ≤ 基线$PRE_COUNT + 已确认$OKROWS + 未确认上界$PARTROWS）"
else
  fail "  可见点数超过上界（$CUR_COUNT > $UPPER）——出现凭空多出的数据（需人工核查）"
fi
if [ "${CUR_COUNT:-0}" -lt "$TARGET" ]; then
  fail "  数据丢失：可见点数 $CUR_COUNT < 已确认上界 $TARGET"
else
  pass "  数据一条不丢：可见点数 $CUR_COUNT ≥ 已确认 $TARGET"
fi
SUM_LOW=$(( PRE_SUM + OKSUM )); SUM_UP=$(( PRE_SUM + OKSUM + PARTGSUM ))
if [ "${CUR_SUM:-0}" -ge "$SUM_LOW" ] && [ "${CUR_SUM:-0}" -le "$SUM_UP" ]; then
  pass "  值总和在区间内（$CUR_SUM ∈ [$SUM_LOW, $SUM_UP]）"
else
  fail "  值总和越界（$CUR_SUM ∉ [$SUM_LOW, $SUM_UP]）——需人工核查"
fi
if [ "${PARTROWS:-0}" -gt 0 ]; then
  warn "  有未确认块（${PARTROWS} 点可能部分落库）：可见点数 $CUR_COUNT 落在 [$(w17_field_sum "$CHUNKLOG" rows OK 2>/dev/null)$(( PRE_COUNT + OKROWS )), ${UPPER}] 区间内属正常，仅记录"
fi

log "--- ⑧ 收尾前的硬检查：DN 存活 / 阻塞已解除 / 无 OOM ---"
n_run=0; for h in "${DN[@]}"; do [ "$(dn_state "$h")" = "Running" ] && n_run=$(( n_run + 1 )); done
assert_eq "  压力后仍 Running 的 DataNode 个数" "$n_run" "${#DN[@]}"
BLK_END=0; for h in "${DN[@]}"; do BLK_END=$(( BLK_END + $(w17_blocked "$h") )); done
log "  压力结束后阻塞线程（sharp 口径，跨 DN）：$BLK_END  （宽口径：$(wal_sum_over_dn wal_blocked_writers)）"
if [ "$BLK_END" -eq 0 ]; then pass "  阻塞线程已归零（消费后被唤醒）"; else warn "  仍有 $BLK_END 个线程落在 WAL 队列代码里（口径较宽，仅记录；数据可见性已在上面的硬判据里校验）"; fi
OOM=$(wal_oom_cnt); assert_eq "  WAL 相关 OOM 日志行数（必须 0）" "${OOM:-0}" "0"
w17_wal_report "压力后"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w17_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据；本用例不安装 WAL 失败正则：阻写场景的预期告警会被广谱正则误判）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
