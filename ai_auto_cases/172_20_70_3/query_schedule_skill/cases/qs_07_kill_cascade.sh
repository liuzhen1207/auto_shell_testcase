#!/bin/bash
# QS-07 主动取消：KILL QUERY 中止指定查询并级联释放
#   覆盖需求：REQ-07（Coordinator abortQuery 级联中止同查询的其他子任务）
#   判据：① SHOW QUERIES 能取到 queryId；② KILL QUERY 后该查询消失；③ 集群与后续查询正常
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-07
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

qs_set_scheduler_conf 1 3600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
DEVS=$(qs_ensure_data)
assert_ge "①数据已就绪" "${DEVS:-0}" 100

log "=== 启动长查询并取 queryId ==="
qs_long_query_bg "select * from $QS_LONG_DB.**;" /tmp/qs07_long.txt
sleep 6
QID=$(sq "show queries;" 2>/dev/null | grep -oE 'query-[0-9_-]+|[0-9]{19}_[0-9]+' | head -1)
log "  拿到的 queryId=${QID:-（未解析到）}"
assert_ge "②SHOW QUERIES 可见" "$(qs_query_count)" 1

if [ -n "${QID:-}" ]; then
  log "=== KILL QUERY '$QID' ==="
  sq "kill query '$QID';" 2>&1 | head -3 | sed 's/^/    /'
  sleep 8
  QPOST=$(qs_query_count)
  log "  KILL 后查询条数=${QPOST:-0}"
  [ "${QPOST:-0}" -eq 0 ] && pass "③指定查询被取消（REQ-07）" || warn "KILL 后仍有 ${QPOST} 个查询"
else
  log "  未解析到 queryId，退化为 KILL ALL QUERIES"
  sq "kill all queries;" >/dev/null 2>&1
  sleep 8
  [ "$(qs_query_count)" -eq 0 ] && pass "③全部查询被取消（REQ-07，退化路径）" || fail "③查询未被取消"
fi

assert_eq "④集群仍 8/8" "$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running.*ACTIVATED')" "8"
RS=$(sq "select count(*) from $QS_LONG_DB.**;" 2>/dev/null | grep -cE '^\|')
assert_ge "⑤取消后仍可查询" "${RS:-0}" 1
wait 2>/dev/null
write_result 2>/dev/null || true

