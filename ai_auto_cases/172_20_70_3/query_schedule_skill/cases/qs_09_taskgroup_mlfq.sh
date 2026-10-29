#!/bin/bash
# QS-09 查询任务组 + 多级反馈队列累计执行时间（防队列饿死）
#   覆盖需求：REQ-10（同查询子任务按组累计执行时间定优先级）、REQ-11（MLFQ 累计执行时间，k=2）
#   判据：① 两个长查询并发时都能推进并完成（不互相饿死）；② 期间短查询仍有成功操作
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-09
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

qs_set_scheduler_conf 1 3600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
POINTS=$(qs_total_points "$QS_LONG_DB")
assert_ge "①数据已就绪" "${POINTS:-0}" 1000000

log "=== 两个长查询并发 + 短查询 ==="
qs_long_query_bg "select * from $QS_LONG_DB.**;" /tmp/qs09_a.txt
sleep 2
( timeout 1800 "$CLI" -h "${DN[0]}" -p "$DN_RPC_PORT" -u "$DB_USER" -pw "$ROOT_PW" \
    -e "select count(*) from $QS_LONG_DB.**;" >/tmp/qs09_b.out 2>&1; echo $? > /tmp/qs09_b.rc ) &
BPID=$!
sleep 3
QS_QUERY_LOOP="${QS_QUERY_LOOP:-1500}" qs_bench_latest "qs09-under-two-long"
assert_ge "②两个长查询期间短查询有成功操作（MLFQ 未被长查询独占）" "$(printf '%.0f' "${QS_LAT_OPS:-0}")" 1

wait $BPID 2>/dev/null
RCB=$(cat /tmp/qs09_b.rc 2>/dev/null)
qs_long_query_wait /tmp/qs09_a.txt
log "  长查询A rc=${QS_LONG_RC:--1} 耗时=$(( ${QS_LONG_MS:--1} / 1000 ))s；长查询B rc=${RCB:-?}"
[ "${QS_LONG_RC:--1}" = "0" ] && [ "${RCB:-1}" = "0" ] \
  && pass "③两个长查询都完成（均不被饿死，REQ-10/REQ-11）" \
  || fail "③存在未完成的长查询（A rc=${QS_LONG_RC:--1}, B rc=${RCB:-?}）"
write_result 2>/dev/null || true

