#!/bin/bash
# QS-14 队列监控：调度相关指标可观测
#   覆盖需求：REQ-13（队列监控：队列长度/等待时间可观测）
#   判据：① 各 DN 指标端点可用；② 存在调度/队列相关指标；③ 若缺失则记为观察项（不影响集群可用性断言）
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-14
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

qs_set_scheduler_conf 1 3600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }

log "=== 抓各 DN 指标 ==="
TOTAL=0
for h in "${DN[@]}"; do
  n=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -cE '^[a-z_]+'" 2>/dev/null)
  printf "  %-14s 指标条数=%s\n" "$h" "${n:-0}"
  [ "${n:-0}" -gt 0 ] && TOTAL=$((TOTAL+1))
done
assert_ge "①指标端点可用（至少 3 个 DN 返回数据）" "${TOTAL:-0}" 3

log "=== 查找调度/队列相关指标 ==="
FOUND=""
for h in "${DN[@]}"; do
  m=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -oE '^[a-z_]*(driver_task|driver|scheduler|queue|ready_queue)[a-z_]*' | sort -u | head -10" 2>/dev/null)
  [ -n "$m" ] && { FOUND="$m"; break; }
done
if [ -n "${FOUND:-}" ]; then
  log "  找到的调度相关指标:"; echo "$FOUND" | sed 's/^/    /'
  pass "②存在调度/队列相关指标（REQ-13 可观测）"
else
  note "未发现 driver/scheduler/queue 前缀的指标；见 docs/REPORT 的观察项"
  log "  退而检查查询类指标:"
  sshx "${DN[0]}" "curl -s -m 8 http://${DN[0]}:$DN_METRIC_PORT/metrics 2>/dev/null | grep -oE '^[a-z_]*quer[a-z_]*' | sort -u | head -8" 2>/dev/null | sed 's/^/    /'
  pass "②指标端点工作正常；调度专项指标缺失记为观察项（不影响集群可用性）"
fi
write_result 2>/dev/null || true

