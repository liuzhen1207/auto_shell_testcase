#!/bin/bash
# P-02 Chunk 切分参数对写入吞吐的影响（target_chunk_point_num 10k / 100k 默认，另加 target_chunk_size）
#
# 文档依据：《V2.0.5.1-…flush 时按序列点数和大小进行切分 Chunk-需求分析》与
#   《V1.1.0.1-…软件测试文档》§测试内容及过程记录「针对不同 target_chunk_point_num 进行性能比较测试」。
#   文档给出的结论是：该机制对普通（含模板）时间序列多为负面影响，仅乱序 Records 写入有正收益，
#   且"文件数和数据文件夹都比之前变大"。
#
# 做法：3C5D，同一负载，只改 chunk 参数：
#   c10k  : target_chunk_point_num=10000  （文档对比的小值）
#   c100k : target_chunk_point_num=100000 （本版本默认）
#   csize : target_chunk_point_num=100000 + target_chunk_size=8000000（调大 chunk 大小）
# 判据：
#   ① 三个变体都有写入；
#   ② 以 c100k 为基线，c10k 与 csize 的吞吐下降不超过容忍度；
#   ③ **文件数证据**：c10k 切得更碎，TsFile 总字节数应明显小于 csize（记录并对比，不硬判）；
#   ④ 收尾。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
source "$HERE/../../lib/perf.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init P-02
perf_check || { write_result; exit 1; }

MB_MEM_PROPORTION="1:5:1:1:1:1"
MB_FLUSH_PROPORTION="0.4"
MB_TIMED_FLUSH_SEQ="false"
MB_TIMED_FLUSH_UNSEQ="false"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_TIMED_FLUSH_SEQ MB_TIMED_FLUSH_UNSEQ

DB=root.perf02
BASE_TP=0; BASE_P99=0

run_and_measure(){ local tag=$1 desc=$2 varname=$3
  perf_variant "$tag" "$desc" "$PERF_OP_MIX_WRITE" \
    "flush_proportion=0.4" "reject_proportion=0.8" "$varname"
  assert_ge "①$tag 变体有写入（点数>0）" "${PERF_OK_POINTS:-0}" 1
  local f b
  f=$(mb_tsfile_cnt_all "$DB"); b=$(mb_tsfile_bytes_all "$DB")
  log "  【$tag】TsFile 数=$f 总字节=$b"
  eval "${tag}_BYTES=$b"
}

# c100k 先跑，作为基线
run_and_measure "c100k" "target_chunk_point_num=100000（默认）" "target_chunk_point_num=100000"
BASE_TP=$PERF_INGEST_TP; BASE_P99=$PERF_INGEST_P99_MS
BASE_BYTES=$c100k_BYTES

run_and_measure "c10k" "target_chunk_point_num=10000" "target_chunk_point_num=10000"
perf_cmp_tags "$CASE" "c100k" "c10k" "chunk_point_num 10k vs 100k"

run_and_measure "csize" "target_chunk_point_num=100000 + target_chunk_size=8MB" \
  "target_chunk_point_num=100000,target_chunk_size=8000000"
perf_cmp_tags "$CASE" "c100k" "csize" "chunk_size 8MB vs 默认 1.6MB"

log "③文件字节量证据（同一负载）: c10k=${c10k_BYTES:-0} c100k=${BASE_BYTES:-0} csize=${csize_BYTES:-0}"
log "=== P-02 汇总 ==="
tail -5 "$OUTDIR/perf_${CASE}.csv" 2>/dev/null >>"$OUT" 2>/dev/null || true
mb_case_finish "" tree
