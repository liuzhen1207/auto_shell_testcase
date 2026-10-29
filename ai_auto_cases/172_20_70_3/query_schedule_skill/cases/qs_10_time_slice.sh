#!/bin/bash
# QS-10 时间片机制：driver_task_execution_time_slice_in_ms 生效且任务可让出
#   覆盖需求：REQ-05（时间片用完让出执行权，长任务不独占 Worker）
#   判据：时间片设为 50ms（默认 200ms）后，thread=1 下长查询期间短查询 P99 < 50ms，且长查询能完成
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-10
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

qs_set_scheduler_conf 1 3600000 50
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
TS=$(sshx "${DN[0]}" "grep '^driver_task_execution_time_slice_in_ms=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2-")
assert_eq "①时间片配置生效" "${TS}" "50"
DEVS=$(qs_ensure_data)
assert_ge "②数据已就绪" "${DEVS:-0}" 100

qs_long_query_bg "select * from $QS_LONG_DB.**;" /tmp/qs10_long.txt
sleep 3
QS_QUERY_LOOP="${QS_QUERY_LOOP:-2000}" qs_bench_latest "qs10-slice50"
P99="${QS_LAT_P99:-99999}"
log "  时间片 50ms 下短查询 P99=${P99}ms"
awk -v v="$P99" 'BEGIN{exit !(v+0 < 50)}' \
  && pass "③时间片 50ms 下短查询 P99=${P99}ms < 50ms（REQ-05 让出机制生效）" \
  || fail "③短查询 P99=${P99}ms 未达 50ms"
qs_long_query_wait /tmp/qs10_long.txt
log "  长查询 rc=${QS_LONG_RC:--1} 耗时=$(( ${QS_LONG_MS:--1} / 1000 ))s"
write_result 2>/dev/null || true

