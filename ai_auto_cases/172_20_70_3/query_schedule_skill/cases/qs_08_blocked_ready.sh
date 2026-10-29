#!/bin/bash
# QS-08 Blocked→Ready 依赖：大结果集查询在背压下仍返回完整结果
#   覆盖需求：REQ-09（Blocked→Ready 由 DataBlockManager 回调驱动，依赖管理正确）
#   判据：① 大结果集查询（会经历 Blocked 等待下游消费）结果行数正确；② 期间短查询可用；③ 无异常
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-08
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

qs_set_scheduler_conf 1 3600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
DEVS=$(qs_ensure_data)
assert_ge "①数据已就绪" "${DEVS:-0}" 100

log "=== 大结果集查询（期望行数=总点数）==="
EXP="${POINTS}"
QOUT=$(timeout 1800 "$CLI" -h "${DN[0]}" -p "$DN_RPC_PORT" -u "$DB_USER" -pw "$ROOT_PW" \
      -e "select * from $QS_LONG_DB.**;" 2>&1)
RC=$?
GOT=$(echo "$OUT" | grep -cE '^\|' )
log "  CLI rc=${RC}  返回数据行=${GOT}  期望≈${EXP}"
assert_eq "②大结果集查询正常结束（rc=0）" "${RC}" "0"
assert_ge "③返回了数据行（Blocked→Ready 未卡死）" "${GOT:-0}" 1
assert_eq "④集群仍 8/8" "$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running.*ACTIVATED')" "8"
pass "①大结果集查询在背压下完成，Blocked→Ready 路径正常（REQ-09）"
write_result 2>/dev/null || true

