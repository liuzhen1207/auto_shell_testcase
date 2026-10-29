#!/bin/bash
# QS-06 查询超时中断（Sentinel 线程按 deadline 中止）
#   覆盖需求：REQ-06（query_timeout_threshold 生效，超时任务被 Abort）
#   判据：① query_timeout_threshold=2000ms 时长查询报超时错误；② 超时后集群仍可正常查询（资源释放）
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-06
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

qs_set_scheduler_conf 1 2000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
DEVS=$(qs_ensure_data)
assert_ge "①数据已就绪" "${DEVS:-0}" 100

log "=== 发起必然超时的长查询（阈值 2s）==="
# 先用全量扫描；数据量小的话它可能很快返回，再用"大范围 1ms 粒度 GROUP BY"兜底
TRY_SQLS=(
  "select * from $QS_LONG_DB.**;"
  "select count(*) from $QS_LONG_DB.** group by ([2018-08-30T00:00:00, 2018-08-31T00:00:00), 1ms);"
)
HIT=0
for SQL in "${TRY_SQLS[@]}"; do
  log "  尝试: ${SQL:0:70}..."
  QOUT=$(timeout 120 "$CLI" -h "${DN[0]}" -p "$DN_RPC_PORT" -u "$DB_USER" -pw "$ROOT_PW" -e "$SQL" 2>&1)
  RC=$?
  echo "$QOUT" | head -4 | sed 's/^/    /'
  log "  CLI rc=${RC}"
  if echo "$QOUT" | grep -qiE "timeout|timed out|超时|QueryTimeout"; then HIT=1; break; fi
done
if [ "$HIT" = "1" ]; then
  pass "②长查询被超时中断（返回超时错误）——REQ-06 生效"
else
  fail "②未观察到超时错误（最后一个 rc=${RC}）；实际输出见上"
fi

log "=== 超时后集群仍可用（资源释放）==="
sleep 3
RS=$(sq "select count(*) from $QS_LONG_DB.**;" 2>/dev/null | grep -cE '^\|')
assert_ge "③超时后仍可查询" "${RS:-0}" 1
assert_eq "④集群仍 8/8" "$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running.*ACTIVATED')" "8"
write_result 2>/dev/null || true

