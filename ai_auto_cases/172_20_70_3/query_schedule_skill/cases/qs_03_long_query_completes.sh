#!/bin/bash
# QS-03 长查询在持续短查询压力下仍能完成（防饿死）
#   覆盖需求：REQ-02（长查询不会饿死，在有限时间内结束）
#   判据：query_thread_count=1；全量长查询运行期间持续打短查询；长查询 rc=0 且在 MAX_SEC 内结束
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-03
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

MAX_SEC="${QS_LONG_MAX_SEC:-1800}"
qs_set_scheduler_conf 1 3600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }

DEVS=$(qs_ensure_data)
log "  当前设备数=${DEVS:-?}"
assert_ge "①数据已就绪" "${DEVS:-0}" 100

log "=== 启动全量长查询 + 持续短查询 ==="
qs_long_query_bg "select * from $QS_LONG_DB.**;" /tmp/qs03_long.txt
sleep 3
QS_QUERY_LOOP="${QS_QUERY_LOOP:-2000}" qs_bench_latest "qs03-under-long"
assert_ge "②长查询期间短查询有成功操作" "$(printf '%.0f' "${QS_LAT_OPS:-0}")" 1

qs_long_query_wait /tmp/qs03_long.txt
SEC=$(( ${QS_LONG_MS:--1} / 1000 ))
log "  长查询 rc=${QS_LONG_RC:--1} 耗时=${SEC}s（上限 ${MAX_SEC}s）"

if [ "${QS_LONG_RC:--1}" = "0" ]; then
  pass "③长查询正常结束（rc=0，耗时 ${SEC}s）——未被短查询饿死（REQ-02）"
else
  fail "③长查询未正常结束（rc=${QS_LONG_RC:--1}，耗时 ${SEC}s）"
fi
if [ "${SEC:--1}" -gt 0 ] 2>/dev/null && [ "${SEC}" -le "${MAX_SEC}" ]; then
  pass "④长查询在有限时间（${SEC}s ≤ ${MAX_SEC}s）内完成"
else
  fail "④长查询耗时 ${SEC}s 超上限 ${MAX_SEC}s 或异常"
fi
write_result 2>/dev/null || true

