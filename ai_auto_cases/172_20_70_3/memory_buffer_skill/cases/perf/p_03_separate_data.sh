#!/bin/bash
# P-03 顺乱序分离存储对读写性能的影响（enable_separate_data true / false）
#
# 文档依据：《顺乱序分离存储-需求分析》§自测与测试场景建议：
#   「在分别打开和关闭顺乱序分离的情况下，测试不同乱序率数据下的读写性能。」
#   非功能要求：「打开顺乱序分离后，在绝大多数的场景下系统将获得不低于关闭时的读写性能。」
#
# 做法（4 个变体，全部 3C5D）：
#   sep_on_seq   : separate=true  + 顺序负载
#   sep_off_seq  : separate=false + 顺序负载
#   sep_on_ooo   : separate=true  + 乱序负载（IS_OUT_OF_ORDER=true, OUT_OF_ORDER_RATIO=0.5）
#   sep_off_ooo  : separate=false + 乱序负载
# 判据：
#   ① 四个变体都有写入；
#   ② 顺序负载下 true 相对 false 吞吐不低于容忍度（文档要求"不低于"）；
#   ③ 乱序负载下 true 相对 false 吞吐不低于容忍度；
#   ④ 收尾。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
source "$HERE/../../lib/perf.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init P-03
perf_check || { write_result; exit 1; }

MB_MEM_PROPORTION="1:5:1:1:1:1"
MB_FLUSH_PROPORTION="0.4"
MB_TIMED_FLUSH_SEQ="false"
MB_TIMED_FLUSH_UNSEQ="false"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_TIMED_FLUSH_SEQ MB_TIMED_FLUSH_UNSEQ

SEQ_BASE_TP=0; SEQ_BASE_P99=0; OOO_BASE_TP=0; OOO_BASE_P99=0

# ---------- 顺序负载：先 false 做基线，再 true ----------
perf_variant "sep_off_seq" "separate=false + 顺序" "$PERF_OP_MIX_WRITE" \
  "enable_separate_data=false" "IS_OUT_OF_ORDER=false"
SEQ_BASE_TP=$PERF_INGEST_TP; SEQ_BASE_P99=$PERF_INGEST_P99_MS
assert_ge "①sep_off_seq 有写入" "${PERF_OK_POINTS:-0}" 1

perf_variant "sep_on_seq" "separate=true + 顺序" "$PERF_OP_MIX_WRITE" \
  "enable_separate_data=true" "IS_OUT_OF_ORDER=false"
assert_ge "①sep_on_seq 有写入" "${PERF_OK_POINTS:-0}" 1
perf_cmp_tags "$CASE" "sep_off_seq" "sep_on_seq" "顺序负载: separate=true vs false"

# ---------- 乱序负载：先 false 做基线，再 true ----------
perf_variant "sep_off_ooo" "separate=false + 乱序50%" "$PERF_OP_MIX_WRITE" \
  "enable_separate_data=false" "IS_OUT_OF_ORDER=true" "OUT_OF_ORDER_RATIO=0.5"
OOO_BASE_TP=$PERF_INGEST_TP; OOO_BASE_P99=$PERF_INGEST_P99_MS
assert_ge "①sep_off_ooo 有写入" "${PERF_OK_POINTS:-0}" 1

perf_variant "sep_on_ooo" "separate=true + 乱序50%" "$PERF_OP_MIX_WRITE" \
  "enable_separate_data=true" "IS_OUT_OF_ORDER=true" "OUT_OF_ORDER_RATIO=0.5"
assert_ge "①sep_on_ooo 有写入" "${PERF_OK_POINTS:-0}" 1
perf_cmp_tags "$CASE" "sep_off_ooo" "sep_on_ooo" "乱序负载: separate=true vs false"

log "=== P-03 汇总 ==="
tail -6 "$OUTDIR/perf_${CASE}.csv" 2>/dev/null >>"$OUT" 2>/dev/null || true
mb_case_finish "" tree
