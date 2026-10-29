#!/bin/bash
# MB-07 刷盘限流下并发读写（io_task_queue_size_for_flushing / check_period_when_insert_blocked）
#   做法：io_task_queue_size_for_flushing=2、flush_proportion 很小（刷得很勤），
#         3 个写会话并发写 + 1 个查询会话持续 count，观察是否出现查询报错/写入错乱。
#   判据：① 写入会话都返回（不死锁、不超时）；
#         ② 查询会话全程无 SQL 异常（允许"reject"类写入拒绝，不允许查询侧异常）；
#         ③ 账号内可查点数 == 成功语句数 × 每语句行数；
#         ④ 刷盘累计计数增加（确实发生了刷盘）。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-07
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="1:1000:1:1:1:1"
MB_FLUSH_PROPORTION="0.05"
MB_REJECT_PROPORTION="0.8"
MB_IO_TASK_QUEUE_SIZE="2"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_REJECT_PROPORTION MB_IO_TASK_QUEUE_SIZE
DB=root.mb07
ROWS=${MB07_ROWS:-3000}
export EXTRA_CONF=""

mb_cluster_prepare
mb_make_tree_db "$DB" 3 int64
flush0=$(mb_flush_all)

log "--- 3 写会话并发 + 1 查询会话 ---"
( for i in 1 2 3; do mb_bulk_int "$DB" "d$i" "$ROWS" "$i"; done >/tmp/mb07_w.res 2>&1 ) &
pw=$!
: >/tmp/mb07_q.err
( for i in $(seq 1 30); do
    out=$(sq "select s1 from $DB.d1 order by time;" 2>&1)
    printf '%s' "$out" | grep -qiE 'Exception|ERROR' && printf '%s\n' "$out" >>/tmp/mb07_q.err
    sleep 2
  done ) &
pq=$!
wait $pw; wait $pq
cat /tmp/mb07_w.res

ok_total=0
while read -r a b; do ok_total=$(( ok_total + ${a:-0} )); done < <(grep -E '^[0-9]+ [0-9]+$' /tmp/mb07_w.res || true)
[ "$ok_total" -eq 0 ] && { ok_total=$(awk '{s+=$1} END{print s+0}' /tmp/mb07_w.res); }
log "  写入成功语句合计=$ok_total"

qerr=$(wc -l < /tmp/mb07_q.err | tr -d ' ')
assert_eq "②并发查询全程无 SQL 异常" "${qerr:-0}" "0"
assert_ge "①写入会话有成功语句" "$ok_total" 1

sq 'flush;' >/dev/null 2>&1
sleep 5
tot=0
tot=$(mb_count_all "$DB")
log "  实际可查点数=$tot"
assert_eq "③可查点数 == 成功语句数 × 每语句行数" "$tot" "$(( ok_total * MB_ROWS_PER_STMT ))"
assert_ge "④刷盘确实发生" "$(mb_flush_all)" "$(( flush0 + 1 ))"

mb_case_finish "$(mb_data_sql "$DB" d1)" tree
