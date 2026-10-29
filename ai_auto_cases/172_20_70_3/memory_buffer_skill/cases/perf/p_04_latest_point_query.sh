#!/bin/bash
# P-04 最新点查询性能（对应《软件测试文档》的「1 万点最新值查询 (Table mode)」）
#
# 文档依据：《V1.1.0.1-内存缓冲区-软件测试文档》§测试内容及过程记录：
#   「1万点最新值查询 Table mode 查询耗时上升 536s → 818s (52.61%) → 修复后 501s」
#   —— 说明 TVList 的 indices/null-bitmap 改动曾显著拖慢最新点查询，是多点合并/扫描路径的敏感项。
#
# 本环境的适配说明：
#   文档是 1 万个设备的最新值查询；本环境 3C5D + 客户端单机，直接 1 万设备会跑很久，
#   因此默认用 PERF_DEVICES_QUERY（1000）设备 × 10 传感器，其余口径（LATEST_POINT 查询占比 90%）保持一致。
#   需要完全对齐文档时用：PERF_DEVICES_QUERY=10000 PERF_LOOP=200 bash ...
#
# 判据：
#   ① 两个变体都产生 LATEST_POINT 成功查询（okOperation>0）；
#   ② 以 tvlist_sort_algorithm=TIM（默认）为基线，QUICK / BACKWARD 的 LATEST_POINT
#      P99 延迟不恶化超过 PERF_LATENCY_TOL_PCT；吞吐下降不超过 PERF_TOLERANCE_PCT；
#   ③ 收尾。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
source "$HERE/../../lib/perf.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init P-04
perf_check || { write_result; exit 1; }

# 查询场景：设备多、循环少，写 1% + 最新点查询 90%
PERF_DEVICES="${PERF_DEVICES_QUERY:-1000}"
PERF_SENSORS="${PERF_SENSORS_QUERY:-10}"
PERF_LOOP="${PERF_LOOP_QUERY:-300}"
export PERF_DEVICES PERF_SENSORS PERF_LOOP

MB_MEM_PROPORTION="1:5:1:1:1:1"
MB_FLUSH_PROPORTION="0.4"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION

run_query_variant(){ local tag=$1 desc=$2; shift 2
  perf_variant "$tag" "$desc" "$PERF_OP_MIX_QUERY" "$@"
  local dir="$PERF_WORK_DIR/$tag" okq tpq p99q
  okq=$(perf_get "$dir" LATEST_POINT okop); tpq=$(perf_get "$dir" LATEST_POINT tp)
  p99q=$(perf_get "$dir" LATEST_POINT p99)
  log "  【$tag】LATEST_POINT: okOp=$okq 吞吐=$tpq op/s P99=${p99q}ms"
  eval "${tag}_OKOP=${okq:-0}"; eval "${tag}_TP=${tpq:-0}"; eval "${tag}_P99=${p99q:-0}"
}

BASE_TP=0; BASE_P99=0

run_query_variant "q_tim" "tvlist_sort_algorithm=TIM（默认）" "tvlist_sort_algorithm=TIM"
BASE_TP=${q_tim_TP:-0}; BASE_P99=${q_tim_P99:-0}
assert_ge "①TIM 有 LATEST_POINT 成功查询" "${q_tim_OKOP:-0}" 1

run_query_variant "q_quick" "tvlist_sort_algorithm=QUICK" "tvlist_sort_algorithm=QUICK"
assert_ge "①QUICK 有 LATEST_POINT 成功查询" "${q_quick_OKOP:-0}" 1
perf_cmp_tags "$CASE" "q_tim" "q_quick" "最新点查询: QUICK vs TIM"

run_query_variant "q_backward" "tvlist_sort_algorithm=BACKWARD" "tvlist_sort_algorithm=BACKWARD"
assert_ge "①BACKWARD 有 LATEST_POINT 成功查询" "${q_backward_OKOP:-0}" 1
perf_cmp_tags "$CASE" "q_tim" "q_backward" "最新点查询: BACKWARD vs TIM"

log "=== P-04 汇总 ==="
tail -5 "$OUTDIR/perf_${CASE}.csv" 2>/dev/null >>"$OUT" 2>/dev/null || true
mb_case_finish "" tree
