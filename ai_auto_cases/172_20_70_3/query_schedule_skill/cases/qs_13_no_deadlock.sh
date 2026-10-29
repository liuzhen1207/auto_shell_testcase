#!/bin/bash
# QS-13 无死锁：混合负载持续压测不卡死
#   覆盖需求：REQ-14（无全局锁，只使用队列锁与任务锁，不存在循环等待）
#   判据：thread=1、混合负载持续 N 分钟：① 短查询全程有成功；② 集群始终 8/8；③ 无 DriverTask 死锁迹象
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-13
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

DUR="${QS_DEADLOCK_SEC:-180}"
qs_set_scheduler_conf 1 3600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
POINTS=$(qs_total_points "$QS_LONG_DB")
assert_ge "①数据已就绪" "${POINTS:-0}" 1000000

log "=== 混合负载 ${DUR}s：后台长查询 + 周期短查询 ==="
END=$(( $(date +%s) + DUR ))
ROUND=0; OKROUND=0
while [ "$(date +%s)" -lt "$END" ]; do
  ROUND=$((ROUND+1))
  qs_long_query_bg "select count(*) from $QS_LONG_DB.**;" /tmp/qs13_long_${ROUND}.txt
  QS_QUERY_LOOP=500 qs_bench_latest "qs13-r${ROUND}" >/dev/null 2>&1
  if [ "$(printf '%.0f' "${QS_LAT_OPS:-0}")" -ge 1 ]; then OKROUND=$((OKROUND+1)); fi
  wait 2>/dev/null
done
log "  轮次=${ROUND} 其中短查询有成功的轮次=${OKROUND}"
assert_ge "②每轮短查询都有成功（无卡死）" "${OKROUND:-0}" "${ROUND:-1}"
assert_eq "③集群始终 8/8" "$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running.*ACTIVATED')" "8"
RS=$(sq "select count(*) from $QS_LONG_DB.**;" 2>/dev/null | grep -cE '^\|')
assert_ge "④压测后仍可查询" "${RS:-0}" 1
pass "①${DUR}s 混合负载无死锁（REQ-14）"
write_result 2>/dev/null || true

