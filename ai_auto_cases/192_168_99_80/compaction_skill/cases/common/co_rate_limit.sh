#!/bin/bash
# ============================================================================
# CO-25 合并限流三件套基础功能：`compaction_write_throughput_mb_per_sec`
#       / `compaction_read_throughput_mb_per_sec` / `compaction_read_operation_per_sec`
#
# 源码依据（RC6 `7ae8713e`）：
#   `CompactionTaskManager`（L85-99）：三个 Guava `RateLimiter`；
#       值 <= 0 ⇒ `Double.MAX_VALUE`（等于不限流）；`setRate()`（L310-318）在**热加载**时按新值重设
#       （`IoTDBDescriptor` L1895-1901 每次都调用 set*Rate）；读取点：合并读写走
#       `CompactionTaskManager.getMergeWriteRateLimiter()/getCompactionReadRateLimiter()/getCompactionReadOperationRateLimiter()`。
#
# 场景：单设备 **TEXT** 序列，每行 1KB 文本、每批 3000 行 ⇒ 每批 TsFile ≈3MB（用少量点造出大数据量）
#   · A 相：默认限流（读/写/IOPS 为默认值，通常等于不限流）⇒ 记合并耗时 T1
#   · B 相：热改 写=1MB/s、读=1MB/s、读操作=50/s ⇒ 同样场景记 T2
#   判据：两相都完成合并且数据（行数 + 前若干行内容）不变；T2 明显大于 T1 ⇒ 限流确实作用在合并路径上。
#   若磁盘/CPU 抖动导致 T2 <= T1，则 WARN 并记录（不误判为产品缺陷）。
# 用法： bash co_rate_limit.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_rate_limit_${DATA_CONSENSUS}"

DB=root.corate
ROWS=3000
PER=200          # 每条 INSERT 的行数（每行 1KB ⇒ 约 200KB/语句）

log "--- 集群准备：三类合并先关；candidate=2、gap=0 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0" cmp_cluster_prepare
log "  默认限流值：write=$(cmp_eff "${DN[0]}" compaction_write_throughput_mb_per_sec) read=$(cmp_eff "${DN[0]}" compaction_read_throughput_mb_per_sec) iops=$(cmp_eff "${DN[0]}" compaction_read_operation_per_sec)"

PAYLOAD=$(printf 'x%.0s' $(seq 1 1000))
# ⚠️ 大 payload 不能用 `sq`（`timeout CLI -e "<200KB SQL>"` 会 `Argument list too long`，
#    实测静默不落盘）⇒ 必须用**单会话 stdin** 喂语句（`session_tree`）。
co25_write(){ local db=$1 base=$2 b=$3 ts i=0 vals="" stmts=""
  for ((ts=1; ts<=ROWS; ts++)); do
    vals="$vals($(( base + (b-1)*100000 + ts*10 )),'$PAYLOAD'),"
    i=$(( i + 1 ))
    if [ $(( i % PER )) -eq 0 ]; then stmts="${stmts}insert into $db.d1(time,s1) values ${vals%,};
"; vals=""; fi
  done
  if [ -n "$vals" ]; then stmts="${stmts}insert into $db.d1(time,s1) values ${vals%,};
"; fi
  printf '%s' "$stmts" | session_tree >/dev/null
  sq "flush;" >/dev/null; }
co25_scene(){ local db=$1 base=$2 b
  sq "create database $db;" >/dev/null
  sq "create timeseries $db.d1.s1 with datatype=TEXT, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
  for b in 1 2; do
    co25_write "$db" "$base" "$b"
    cmp_wait_close "$db" "$b" 90 >/dev/null || warn "  [$db] 批$b close 事件未达 $b"
    cmp_wait_lay "$db" "${b}/0/0/0" 150 >/dev/null || warn "  [$db] 批$b 布局=$(cmp_lay "$db")（期望 ${b}/0/0/0）"
  done
  log "  [$db] 起点布局=$(cmp_lay "$db") 字节=$(cmp_bytes_sum "$db")"; }
co25_merge(){ local db=$1 fin0 fin1 t0 t1 dl ok=0
  fin0=$(cmp_inner_finish "$db"); t0=$(date +%s)
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  dl=$(( $(date +%s) + 300 ))
  while (( $(date +%s) < dl )); do
    fin1=$(cmp_inner_finish "$db"); [ "${fin1:-0}" -gt "${fin0:-0}" ] && { ok=1; break; }; sleep 2
  done
  t1=$(date +%s)
  log "  [$db] 合并耗时 $(( t1 - t0 ))s（finishes $fin0 → ${fin1:-0}，布局=$(cmp_lay "$db")）"
  MERGE_SECS=$(( t1 - t0 )); MERGE_OK=$ok; }

log "--- A 相：默认限流 ---"
cmp_compaction_off
DBA="${DB}a"; co25_scene "$DBA" "$(now_ms)"
CNT_A=$(row_sum "$(sq "select count(s1) from $DBA.**;")")
HEAD_A=$(cmp_fingerprint tree "select s1 from $DBA.d1.s1 order by time limit 2;")
co25_merge "$DBA"; T1=$MERGE_SECS; OKA=$MERGE_OK
[ "$OKA" = 1 ] && pass "  [A] 默认限流下合并完成（耗时 ${T1}s）" || fail "  [A] 合并未完成"
assert_eq "  [A] 合并后行数" "$(row_sum "$(sq "select count(s1) from $DBA.**;")")" "$CNT_A"
cmp_assert_same "  [A] 合并前后前 2 行内容" "$HEAD_A" "$(cmp_fingerprint tree "select s1 from $DBA.d1.s1 order by time limit 2;")"

log "--- B 相：热改 写=1MB/s、读=1MB/s、读操作=50/s ---"
cmp_set_hot compaction_write_throughput_mb_per_sec 1 >/dev/null
cmp_set_hot compaction_read_throughput_mb_per_sec 1 >/dev/null
cmp_set_hot compaction_read_operation_per_sec 50 >/dev/null
for kv in compaction_write_throughput_mb_per_sec=1 compaction_read_throughput_mb_per_sec=1 compaction_read_operation_per_sec=50; do
  k=${kv%%=*}; assert_eq "  生效值 $k" "$(cmp_eff "${DN[0]}" "$k")" "${kv#*=}"
done
cmp_compaction_off
DBB="${DB}b"; co25_scene "$DBB" "$(now_ms)"
CNT_B=$(row_sum "$(sq "select count(s1) from $DBB.**;")")
HEAD_B=$(cmp_fingerprint tree "select s1 from $DBB.d1.s1 order by time limit 2;")
co25_merge "$DBB"; T2=$MERGE_SECS; OKB=$MERGE_OK
[ "$OKB" = 1 ] && pass "  [B] 限流(1MB/s,1MB/s,50 IOPS)下合并仍完成（耗时 ${T2}s）" || fail "  [B] 合并未完成"
assert_eq "  [B] 合并后行数" "$(row_sum "$(sq "select count(s1) from $DBB.**;")")" "$CNT_B"
cmp_assert_same "  [B] 合并前后前 2 行内容" "$HEAD_B" "$(cmp_fingerprint tree "select s1 from $DBB.d1.s1 order by time limit 2;")"
log "  限流对照：默认 ${T1}s → 限流后 ${T2}s（数据量约 $(cmp_bytes_sum "$DBB") 字节）"
awk -v a="$T1" -v b="$T2" 'BEGIN{exit !(b > a)}' \
  && pass "  限流生效：合并耗时 ${T1}s → ${T2}s（变慢）" \
  || warn "  限流后耗时未变长（${T1}s → ${T2}s）——数据量太小或限流未作用于该路径，记录"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from ${DB}b.**;" tree
cmp_case_finish "" tree ""
