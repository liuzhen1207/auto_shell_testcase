#!/bin/bash
# P-05 IoTConsensusV2 下的写入吞吐（与 V1 基线对照）
#
# 需求依据：本次测试要求「默认优先 IoTConsensus，其次 IoTConsensusV2」，性能侧同样两种协议都要看。
#
# 做法：
#   v1 : data_region_consensus_protocol_class=IoTConsensus   （默认）
#   v2 : …=org.apache.iotdb.consensus.iot.IoTConsensusV2（规范值，不能用 pipe.）
# 同一负载（写为主），都从干净集群起。
# 判据：
#   ① 两种协议都跑出写入（点数>0）；
#   ② V2 相对 V1 吞吐下降不超过容忍度（V2 走 pipe 复制，batch 模式下未 seal 的尾部不计入同步，
#      写入吞吐通常不低于 V1；若显著低于，是值得研发关注的信号）；
#   ③ 协议配置逐节点回读确认；
#   ④ 收尾。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
source "$HERE/../../lib/perf.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init P-05
perf_check || { write_result; exit 1; }

MB_MEM_PROPORTION="1:5:1:1:1:1"
MB_FLUSH_PROPORTION="0.4"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION

V1_BASE_TP=0; V1_BASE_P99=0

# ---------- V1 ----------
DATA_CONSENSUS="IoTConsensus"; mb_consensus_class
log "  协议: $CONS_TAG ($CONSENSUS_CLASS)"
perf_variant "v1" "IoTConsensus" "$PERF_OP_MIX_WRITE" "flush_proportion=0.4"
V1_BASE_TP=$PERF_INGEST_TP; V1_BASE_P99=$PERF_INGEST_P99_MS
assert_ge "①V1 有写入" "${PERF_OK_POINTS:-0}" 1
for h in "${DN[@]}"; do
  got=$(sshx "$h" "grep -E '^data_region_consensus_protocol_class=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2-" | tr -d '\r')
  assert_eq "③$h V1 协议配置" "$got" "org.apache.iotdb.consensus.iot.IoTConsensus"
done

# ---------- V2 ----------
DATA_CONSENSUS="IoTConsensusV2"; mb_consensus_class
log "  协议: $CONS_TAG ($CONSENSUS_CLASS)"
perf_variant "v2" "IoTConsensusV2" "$PERF_OP_MIX_WRITE" "flush_proportion=0.4"
assert_ge "①V2 有写入" "${PERF_OK_POINTS:-0}" 1
for h in "${DN[@]}"; do
  got=$(sshx "$h" "grep -E '^data_region_consensus_protocol_class=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2-" | tr -d '\r')
  assert_eq "③$h V2 协议配置" "$got" "org.apache.iotdb.consensus.iot.IoTConsensusV2"
done
perf_cmp_tags "$CASE" "v1" "v2" "V2 vs V1 写入吞吐"

log "=== P-05 汇总 ==="
tail -4 "$OUTDIR/perf_${CASE}.csv" 2>/dev/null >>"$OUT" 2>/dev/null || true
mb_case_finish "" tree
