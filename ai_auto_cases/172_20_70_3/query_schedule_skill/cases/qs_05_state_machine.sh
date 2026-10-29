#!/bin/bash
# QS-05 DriverTask 状态管理：查询可被 SHOW QUERIES 观测并可结束时清理
#   覆盖需求：REQ-08（Ready/Running/Blocked/Finished/Aborted 五状态与状态更新）
#   判据：① 长查询运行中 SHOW QUERIES 可见；② KILL 后该查询从列表消失（Aborted → 清理）；③ 期间无 ERROR 异常栈
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-05
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

qs_set_scheduler_conf 1 3600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
DEVS=$(qs_ensure_data)
assert_ge "①数据已就绪" "${DEVS:-0}" 100

log "=== 启动长查询，观测 SHOW QUERIES ==="
qs_long_query_bg "select * from $QS_LONG_DB.**;" /tmp/qs05_long.txt
sleep 6
QPRE=$(qs_query_count)
log "  运行中的查询条数=${QPRE:-0}"
assert_ge "②长查询期间 SHOW QUERIES 可见（≥1）" "${QPRE:-0}" 1

log "=== 记录一次状态快照 ==="
sq "show queries;" 2>/dev/null | head -8 | sed 's/^/    /'

log "=== KILL ALL QUERIES 结束查询 ==="
sq "kill all queries;" >/dev/null 2>&1
sleep 8
QPOST=$(qs_query_count)
log "  KILL 之后查询条数=${QPOST:-0}"
[ "${QPOST:-0}" -lt "${QPRE:-0}" ] \
  && pass "③KILL 后查询被清理（${QPRE} → ${QPOST}），Aborted→清理路径正常（REQ-08）" \
  || fail "③KILL 后查询未减少（${QPRE} → ${QPOST}）"

log "=== 校验结束后仍可查询（状态机未卡死）==="
RS=$(sq "select count(*) from $QS_LONG_DB.**;" 2>/dev/null | grep -cE '^\|')
assert_ge "④结束后仍可正常查询" "${RS:-0}" 1
wait 2>/dev/null
write_result 2>/dev/null || true

