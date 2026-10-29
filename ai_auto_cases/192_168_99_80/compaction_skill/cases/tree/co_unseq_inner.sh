#!/bin/bash
# ============================================================================
# CO-03 冒烟：unseq 内部合并（unsequence space compaction）
#   目的：乱序写入产生 unsequence TsFile → 只开 unseq 内部合并（关 seq / 关 cross，
#         把观测对象隔离到 unseq）→ unseq 文件数下降、数据完全不变。
#   做法：先写一批"新"数据形成 seq 文件（并把 flush 后的最大时间作为水位线），
#         再用**更早**的时间戳写两批 → 落进 unsequence；等待 unseq 内部合并。
#   判据：起点 unseq ≥2 → 窗口内 unseq 完成数增加且 unseq 文件数下降 → 数据指纹一致 →
#         无卡死线程 → 收尾三件套。
# 用法： bash co_unseq_inner.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_unseq_inner_${DATA_CONSENSUS}"

DB=root.counseq
DEVS=${CO_DEVS:-4}
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-120}

log "--- 集群准备（只开 unseq 内部合并，隔离观测对象）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}" cmp_cluster_prepare
log "  实际生效：$(cmp_eff_all "${DN[0]}")"

log "--- 造数据：先造 seq 水位线，再造两批更早的数据（落 unseq）---"
cmp_make_tree_db "$DB" "$DEVS"
NOW=$(( ($(date +%s) - 3600) * 1000 ))
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 1 "$NOW"
ensure_closed "$DB" 3 25 || warn "$DB seq 批次未全部落盘"
# 更早的时间戳 → unseq（每批再往前挪 1 小时，保证两批都早于已 flush 的水位线）
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 2 "$(( NOW - 7200000 ))"
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 3 "$(( NOW - 10800000 ))"
ensure_closed "$DB" 3 25 || warn "$DB unseq 批次未全部落盘"

u0=$(cmp_unseq_sum "$DB"); s0=$(cmp_seq_sum "$DB"); fin0=$(cmp_inner_finish "$DB")
log "  起点：seq=$s0 unseq=$u0（$(cmp_per_node cmp_unseq_cnt "$DB" | tr -d '\n')）inner finishes=$fin0"
log "  TsFile 清单：$(cmp_tsfile_list "${DN[0]}" "$DB" | tr '\n' ' ')"
[ "$u0" -ge 2 ] && pass "起点 unseq TsFile=$u0（≥2，具备 unseq 内部合并条件）" || fail "场景无效：起点 unseq=$u0（<2）"

fp0=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DB.**")
fpd0=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")

log "--- 打开 unseq 内部合并并等合并（窗口 ${WIN}s）---"
cmp_compaction_on false true false
deadline=$(( $(date +%s) + WIN )); ok=0
while (( $(date +%s) < deadline )); do
  sleep 5
  u=$(cmp_unseq_sum "$DB"); f=$(cmp_inner_finish "$DB")
  log "    等 unseq：unseq=$u(基线$u0) finishes=$f(基线$fin0)"
  if [ "$f" -gt "$fin0" ] && [ "$u" -lt "$u0" ]; then ok=1; break; fi
done
u1=$(cmp_unseq_sum "$DB"); fin1=$(cmp_inner_finish "$DB")
if [ "$ok" = 1 ]; then
  pass "unseq 内部合并已推进：unseq $u0 → $u1，finishes $fin0 → $fin1"
else
  fail "unseq 内部合并未推进：unseq=$u1（基线 $u0）finishes=$fin1（基线 $fin0），窗口 ${WIN}s"
fi
[ "$fin1" -gt "$fin0" ] && pass "出现 InnerSpaceCompaction 完成记录（+$((fin1-fin0))）" || fail "无合并完成记录"
cmp_assert_same "合并前后 count/sum" "$fp0" "$(cmp_fingerprint tree "select count(s1), sum(s1) from $DB.**")"
cmp_assert_same "合并前后 $DB.d1 全序列" "$fpd0" "$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")"
[ "$(cmp_seq_sum "$DB")" = "$s0" ] && pass "seq 文件数未变（$s0，已按要求关闭 seq 合并）" || warn "seq 文件数变化：$s0 → $(cmp_seq_sum "$DB")（seq 合并本应关闭）"

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"
for h in "${DN[@]}"; do log "  $h 合并日志尾部：$(cmp_log_tail "$h" "$DB" | tr '\n' ' ' | cut -c1-240)"; done

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
