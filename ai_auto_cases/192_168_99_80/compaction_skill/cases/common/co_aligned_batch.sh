#!/bin/bash
# ============================================================================
# CO-24 `compaction_max_aligned_series_num_in_one_batch` 基础功能
#       —— 对齐序列合并时的"一批处理多少条序列"必须不影响结果正确性
#
# 源码依据（RC6 `7ae8713e`）：
#   `BatchedFastAlignedSeriesCompactionExecutor:80`、`BatchedReadChunkAlignedSeriesCompactionExecutor:70`、
#   `FastCompactionPerformerSubTask:182` 用该值对**对齐序列**分批读写；
#   三个 estimator（`FastCompactionInnerCompactionEstimator:64/97`、
#   `ReadChunkInnerCompactionEstimator:61/85`、`FastCrossSpaceCompactionEstimator:65/100`）里
#   `<= 0` 表示"不分批"。
#   ⇒ 用 1（每条序列一批）、8（全部一批）、0（不分批）三种取值合并同一份对齐数据，结果必须完全一致。
#
# 场景：一个**对齐设备** d1 挂 8 条序列（s1..s8，int64），写 3 批（每批 flush）⇒ 3 个 TsFile
#   判据：每相合并完成 + 8 条序列的 count/sum/内容指纹与合并前完全一致。
# 用法： bash co_aligned_batch.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_aligned_batch_${DATA_CONSENSUS}"

DB=root.coalignb
NSER=8
ROWS=200

co24_mkdb(){ local db=$1 spec=""
  sq "create database $db;" >/dev/null
  local i; for ((i=1;i<=NSER;i++)); do spec="$spec,s$i int64"; done
  sq "create aligned timeseries $db.d1(${spec#,});" >/dev/null; }
co24_batch(){ local db=$1 b=$2 base=$3 want=$4 k vals i ts
  vals=""; i=0
  for ((k=1;k<=ROWS;k++)); do
    vals="$vals($(( base + k*10 ))"
    for ((i=1;i<=NSER;i++)); do vals="$vals,$(( k + b + i ))"; done
    vals="$vals),"
  done
  sq "insert into $db.d1(time$(printf ',s%d' $(seq 1 $NSER))) aligned values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  cmp_wait_close "$db" "$b" 90 >/dev/null || warn "  [$db] 批$b close 事件未达 $b"
  cmp_wait_lay "$db" "$want" 150 >/dev/null || warn "  [$db] 批$b 布局=$(cmp_lay "$db")（期望 $want）"; }
co24_fp(){ local db=$1 cols
  # 树方言在"具体设备路径"上做聚合会返回空集 ⇒ 指纹一律用**原始查询**的归一化结果 + 全库行数
  cols=$(seq -s, 1 "$NSER" | sed 's/[0-9]\+/s&/g')
  { row_sum "$(sq "select count(s1) from $db.**;")"
    cmp_fingerprint tree "select $cols from $db.d1 order by time;"; } | md5sum | cut -c1-16; }
co24_run(){ local tag=$1 val=$2 base db
  cmp_compaction_off
  cmp_set_hot compaction_max_aligned_series_num_in_one_batch "$val" >/dev/null
  db="${DB}${tag}"; co24_mkdb "$db"; base=$(now_ms)
  for b in 1 2 3; do co24_batch "$db" "$b" "$(( base + b*20000 ))" "${b}/0/0/0"; done
  local fp0 fin0 fin1 dl ok=0
  fp0=$(co24_fp "$db"); fin0=$(cmp_inner_finish "$db")
  log "  [$tag] max_aligned_series_num_in_one_batch=$val：起点布局=$(cmp_lay "$db") 指纹=$fp0"
  assert_eq "    [$tag] 生效值" "$(cmp_eff "${DN[0]}" compaction_max_aligned_series_num_in_one_batch)" "$val"
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  dl=$(( $(date +%s) + 150 ))
  while (( $(date +%s) < dl )); do
    fin1=$(cmp_inner_finish "$db"); [ "${fin1:-0}" -gt "${fin0:-0}" ] && { ok=1; break; }; sleep 3
  done
  sleep 6
  [ "$ok" = 1 ] && pass "    [$tag] 合并完成（finishes $fin0 → $fin1，布局=$(cmp_lay "$db")）" \
    || fail "    [$tag] 合并未推进（finishes=$fin0）"
  cmp_assert_same "    [$tag] 8 条对齐序列合并前后指纹" "$fp0" "$(co24_fp "$db")"; }

log "--- 集群准备：三类合并先关；multi_target + gap=0 + candidate=2 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,inner_seq_performer=fast,compaction_max_aligned_series_num_in_one_batch=1" cmp_cluster_prepare

co24_run s1 1
co24_run s8 8
co24_run s0 0

log "--- 收尾三件套 ---"
post_checks "select count(s1) from ${DB}s0.**;" tree
cmp_case_finish "" tree ""
