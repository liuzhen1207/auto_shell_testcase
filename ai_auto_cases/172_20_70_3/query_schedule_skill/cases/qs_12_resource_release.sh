#!/bin/bash
# QS-12 取消/超时后资源与对象释放（无残留任务、内存不持续增长）
#   覆盖需求：REQ-15（Aborted/Finished 必从三类容器移除，最终可被 GC）
#   判据：连续 10 次超时中止后：① 集群仍 8/8；② DN RSS 增幅 < 30%；③ SHOW QUERIES 无残留
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-12
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

qs_set_scheduler_conf 1 2000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
DEVS=$(qs_ensure_data)
assert_ge "①数据已就绪" "${DEVS:-0}" 100

RSS0=$(qs_dn_rss_kb "${DN[0]}")
log "  基线 RSS=${RSS0}KB"

log "=== 连续 10 次超时中止 ==="
for i in $(seq 1 10); do
  timeout 60 "$CLI" -h "${DN[0]}" -p "$DN_RPC_PORT" -u "$DB_USER" -pw "$ROOT_PW" \
    -e "select * from $QS_LONG_DB.**;" >/dev/null 2>&1
done
sleep 10
RSS1=$(qs_dn_rss_kb "${DN[0]}")
GROW=$(awk -v a="${RSS0:-0}" -v b="${RSS1:-0}" 'BEGIN{ if(a+0>0) printf "%.1f", (b-a)*100.0/a; else print "0" }')
log "  中止后 RSS=${RSS1}KB 增幅=${GROW}%"
assert_eq "②集群仍 8/8" "$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running.*ACTIVATED')" "8"
awk -v g="$GROW" 'BEGIN{exit !(g+0 < 30)}' \
  && pass "③连续中止后 DN RSS 增幅 ${GROW}% < 30%（无持续增长，REQ-15）" \
  || fail "③DN RSS 增幅 ${GROW}% 过大，疑似资源未释放"
assert_eq "④SHOW QUERIES 无残留" "$(qs_query_count)" "0"
write_result 2>/dev/null || true

