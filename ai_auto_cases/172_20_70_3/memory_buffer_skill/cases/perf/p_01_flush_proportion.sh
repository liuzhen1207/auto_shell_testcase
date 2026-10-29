#!/bin/bash
# P-01 写入吞吐基线 vs flush_proportion（0.4 默认 / 0.5）
#
# 文档依据：《V1.1.0.1-内存缓冲区-软件测试文档》§测试内容及过程记录：
#   「flush_proportion 比例从 0.4 提高到 0.5。因为 TVList 的内存 cost 新增了 indices 和 null bitmap 部分，
#     稍微提高此比例，避免频繁刷盘」——说明这个参数被真实调过，且直接影响刷盘频率与写入性能。
#
# 做法：3C5D 集群，同一份 benchmark 负载（写为主 91%），只改 flush_proportion：
#   base  : 0.4（本版本默认）
#   fp05  : 0.5（文档建议值）
# 每个变体都从干净集群起（gb_cluster_prepare 口径一致）。
# 判据：
#   ① 两个变体都产生有效的 benchmark 结果（INGESTION 成功点数 > 0）；
#   ② fp05 相对 base：吞吐下降不超过 PERF_TOLERANCE_PCT（默认 30%）；
#   ③ P99 延迟不恶化超过 PERF_LATENCY_TOL_PCT（默认 50%）；
#   ④ 证据：flush 累计计数（0.5 阈值更高 ⇒ 同样数据量下刷盘次数应更少或持平）。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
source "$HERE/../../lib/perf.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init P-01
perf_check || { write_result; exit 1; }

MB_MEM_PROPORTION="1:5:1:1:1:1"
MB_TIMED_FLUSH_SEQ="false"
MB_TIMED_FLUSH_UNSEQ="false"
export MB_MEM_PROPORTION MB_TIMED_FLUSH_SEQ MB_TIMED_FLUSH_UNSEQ

BASE_TP=0; BASE_P99=0

# ---------- 基线：flush_proportion=0.4 ----------
MB_FLUSH_PROPORTION="0.4"
export MB_FLUSH_PROPORTION
perf_variant "base_fp04" "flush_proportion=0.4（默认）" "$PERF_OP_MIX_WRITE" \
  "flush_proportion=0.4" "reject_proportion=0.8"
BASE_TP=$PERF_INGEST_TP; BASE_P99=$PERF_INGEST_P99_MS
FLUSH_BASE=$(mb_flush_all)
perf_evidence
assert_ge "①base 变体有写入（点数>0）" "${PERF_OK_POINTS:-0}" 1

# ---------- 变体：flush_proportion=0.5 ----------
MB_FLUSH_PROPORTION="0.5"
export MB_FLUSH_PROPORTION
perf_variant "fp05" "flush_proportion=0.5（文档建议）" "$PERF_OP_MIX_WRITE" \
  "flush_proportion=0.5" "reject_proportion=0.8"
perf_evidence
assert_ge "①fp05 变体有写入（点数>0）" "${PERF_OK_POINTS:-0}" 1
# 从 CSV 回读基线再比较（不依赖脚本变量传递，见 lib/perf.sh 里 perf_from_csv 的说明）
perf_cmp_tags "$CASE" "base_fp04" "fp05" "flush_proportion 0.5 vs 0.4"
FLUSH_05=$(mb_flush_all)
log "④刷盘累计: 0.4 → $FLUSH_BASE，0.5 → $FLUSH_05（0.5 阈值更高，同等数据量下应更少或持平）"

# 结果汇总
log "=== P-01 汇总 ==="
cat "$OUTDIR/perf_${CASE}.csv" 2>/dev/null | tail -4 >>"$OUT" 2>/dev/null || true
mb_case_finish "" tree
