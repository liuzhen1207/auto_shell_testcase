#!/bin/bash
# QS-04 无需用户手动指定优先级
#   覆盖需求：REQ-03（调度自动生效，用户不配置任何优先级）
#   判据：① 配置里不存在任何优先级相关项；② 不设优先级时，thread=1 下长查询期间短查询 P99 < 50ms
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-04
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

qs_set_scheduler_conf 1 3600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }

log "=== ① 确认没有任何优先级配置项 ==="
PRIO=$(sshx "${DN[0]}" "grep -icE '^[a-z_.]*(priority|priority_level|query_priority)[a-z_.]*=' $DB_DIR/conf/iotdb-system.properties")
log "  优先级相关配置项条数=${PRIO:-?}"
assert_eq "①配置中无手动优先级项" "${PRIO:-0}" "0"

POINTS=$(qs_total_points "$QS_LONG_DB")
assert_ge "②数据已就绪" "${POINTS:-0}" 1000000

log "=== ② 不设优先级，验证调度自动生效 ==="
qs_long_query_bg "select * from $QS_LONG_DB.**;" /tmp/qs04_long.txt
sleep 3
QS_QUERY_LOOP="${QS_QUERY_LOOP:-2000}" qs_bench_latest "qs04-under-long"
P99="${QS_LAT_P99:-99999}"
log "  短查询 P99=${P99}ms（目标 < 50ms）"
awk -v v="$P99" 'BEGIN{exit !(v+0 < 50)}' \
  && pass "③未手动指定优先级，短查询 P99=${P99}ms < 50ms（REQ-03 自动调度生效）" \
  || fail "③短查询 P99=${P99}ms 未达 50ms"
qs_long_query_wait /tmp/qs04_long.txt
log "  长查询 rc=${QS_LONG_RC:--1} 耗时=$(( ${QS_LONG_MS:--1} / 1000 ))s"
write_result 2>/dev/null || true

