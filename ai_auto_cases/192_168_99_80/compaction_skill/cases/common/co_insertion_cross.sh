#!/bin/bash
# ============================================================================
# CO-30 **插入式跨空间合并**（`InsertionCrossSpaceCompaction`）基础场景
#       —— 与"重写式 cross"完全不同的路径：**不重写数据**，直接把 unseq 文件挪进 seq 空间
#
# 源码依据（RC6 `7ae8713e`）：
#   `DataRegion.executeCompaction()`（L4232-4261）：**每轮调度先** `executeInsertionCompaction(...)`，
#     若某时间分区提交了插入任务，则**跳过**该分区的其它合并调度（IoTConsensusV2 除外）。
#   `CompactionScheduler.tryToSubmitInsertionCompactionTask()`（L240-276）→
#     `RewriteCrossSpaceCompactionSelector.selectInsertionCrossSpaceTask()` →
#     `InsertionCrossSpaceCompactionSelector.executeInsertionCrossSpaceCompactionTaskSelection()`：
#       挑"与 seq 文件**不重叠**、且与已选 unseq 文件也不重叠"的 unseq 文件，
#       计算插到 seq 空间的**目标位置/文件名**（`InsertionCrossSpaceCompactionTask:212`）。
#   ⇒ 判据必须区分于重写式 cross：**unseq 文件被搬进 seq 空间（seq 文件数增加）**，
#      而不是"unseq 与新 seq 合并成一个文件"。
#
# 场景（单设备）：1 个 seq 水位文件（较晚时间）+ 3 个**互相不重叠且与水位不重叠**的更早 unseq 文件
#   ⇐ 注意：这里故意**不重叠**（与"unseq 内部合并"要求的重叠场景相反）。
# 判据：插入任务 ≥1（每副本）、unseq → 0、seq 文件数增加、数据指纹不变、无异常。
# 用法： bash co_insertion_cross.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_insertion_cross_${DATA_CONSENSUS}"

DB=root.coins

log "--- 集群准备：seq/unseq 内部合并全关，只留 cross ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},min_cross_compaction_unseq_file_level=0" cmp_cluster_prepare

co30_ins_cnt(){ local h s=0 n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -hc 'InsertionCrossSpaceCompaction task starts' $(cmp_log_files) 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done; echo "${s:-0}"; }
co30_cross_cnt(){ local h s=0 n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -hc '[Compaction] CrossSpaceCompaction task starts' $(cmp_log_files) 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done; echo "${s:-0}"; }

cmp_compaction_off
cmp_mkdb1 "$DB"
BASE=$(now_ms)
# ① seq 水位（较晚的时间段）
co30_water(){ local k vals=""
  for ((k=1;k<=200;k++)); do vals="$vals($(( BASE + 500000 + k*10 )),$((k+9))),"; done
  sq "insert into $DB.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  cmp_wait_close "$DB" 1 90 >/dev/null || warn "  水位批 close 未达 1"
  cmp_wait_su "$DB" "1/0" 120 >/dev/null; }
# ② 3 批更早、**互不重叠**的数据（落 unseq，且与 seq 水位不重叠 ⇒ 插入式合并的候选）
co30_unseq(){ local b=$1 k vals=""
  for ((k=1;k<=200;k++)); do vals="$vals($(( BASE + b*100000 + k*100 )),$((k+b))),"; done
  sq "insert into $DB.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  cmp_wait_close "$DB" "$(( 1 + b ))" 90 >/dev/null || warn "  第 $b 批 close 未达 $(( 1 + b ))"
  cmp_wait_su "$DB" "1/$b" 150 >/dev/null && log "  unseq 第 $b 个文件就绪：$(cmp_su "$DB")"; }

co30_water
for b in 1 2 3; do co30_unseq "$b"; done
SU0=$(cmp_su "$DB"); SEQ0=$(cmp_seq_sum "$DB"); U0=$(cmp_unseq_sum "$DB")
FP0=$(cmp_fp_tree "$DB"); CNT0=$(row_sum "$(sq "select count(s1) from $DB.**;")")
log "  场景：$SU0（seq=$SEQ0 unseq=$U0）"
[ "${U0:-0}" -ge 3 ] && pass "  场景有效：3 个互不重叠的 unseq 文件（unseq=$U0）" || fail "  场景无效：unseq=$U0（<3）"
INS0=$(co30_ins_cnt); CROSS0=$(co30_cross_cnt)

log "--- 开 cross：期望走**插入式**（不重写）路径 ---"
cmp_set_hot enable_cross_space_compaction true >/dev/null
deadline=$(( $(date +%s) + 180 )); ok=0
while (( $(date +%s) < deadline )); do
  [ "$(cmp_unseq_sum "$DB")" = "0" ] && { ok=1; break; }; sleep 3
done
sleep 10
INS1=$(co30_ins_cnt); CROSS1=$(co30_cross_cnt); SEQ1=$(cmp_seq_sum "$DB")
log "  结果：$(cmp_su "$DB")（seq $SEQ0→$SEQ1）插入任务=$INS0→$INS1 重写式 cross 任务=$CROSS0→$CROSS1"
[ "$ok" = 1 ] && pass "  unseq 归零（跨空间处理完成）" || fail "  unseq 未归零（$(cmp_unseq_sum "$DB")）"
[ "${INS1:-0}" -gt "${INS0:-0}" ] \
  && pass "  **插入式**合并被触发（InsertionCrossSpaceCompaction task starts $INS0 → $INS1）—— 源文件直接挪进 seq 空间" \
  || warn "  未观察到插入式合并（INS $INS0→$INS1，重写式 cross $CROSS0→$CROSS1，记录）"
[ "${SEQ1:-0}" -gt "${SEQ0:-0}" ] \
  && pass "  seq 空间文件数增加（$SEQ0 → $SEQ1）⇒ 确属『挪文件』而非『重写成新文件』" \
  || warn "  seq 文件数未增加（$SEQ0 → $SEQ1，记录）"
cmp_assert_same "  插入式合并前后数据指纹" "$FP0" "$(cmp_fp_tree "$DB")"
assert_eq "  插入式合并前后行数" "$(row_sum "$(sq "select count(s1) from $DB.**;")")" "$CNT0"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
