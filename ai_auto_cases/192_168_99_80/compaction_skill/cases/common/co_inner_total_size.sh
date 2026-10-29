#!/bin/bash
# ============================================================================
# CO-21 `inner_compaction_total_file_size_threshold` 基础功能：**单个内部合并任务的总大小上限**
#
# 源码依据（RC6 `7ae8713e`，`NewSizeTieredCompactionSelector`）：
#   L86-89  totalFileSizeThreshold = min(inner_compaction_total_file_size_threshold,
#                                        availableDisk / compaction_thread_count)
#   L234-236 currentFileSizeSatisfied = 单文件大小 < totalFileSizeThreshold
#   L281-285 isTaskTooLarge = (本文件 + 已选总大小 > totalFileSizeThreshold)
#                             || 已选文件数 + 1 > inner_compaction_total_file_num_threshold
#   ⇒ 阈值压到"两个文件之和"以下时：每个任务只能收 1 个文件 ⇒ **永远不提交任务**（因为 <2 个文件）；
#     阈值放大到能装下全部文件 ⇒ 一个任务全收。
#   （注意：经典选择器 `size_tiered_single_target` 不读这个键，所以必须用默认的 multi_target）
#
# 场景（单设备、4 个 L0 文件、每个 TsFile ≈1.2~1.4KB ⇒ 任意两个之和 ≥2.4KB）：
#   · A：inner_compaction_total_file_size_threshold=2000（2KB）⇒ 45s 内 **不合并**（布局仍 4×L0）
#   · B：热改 10000（10KB）⇒ 一个任务收 4 个文件 ⇒ 产出 **1 个 L1**
#   两相都校验生效值；B 相校验指纹不变。
# 用法： bash co_inner_total_size.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_inner_total_size_${DATA_CONSENSUS}"

DB=root.cosize
WIN=${CO_COMBO_WIN:-45}

log "--- 集群准备：三类合并先关；multi_target + gap=0 + candidate=2 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,inner_compaction_total_file_size_threshold=2000" cmp_cluster_prepare
assert_eq "  生效值 inner_compaction_total_file_size_threshold" "$(cmp_eff "${DN[0]}" inner_compaction_total_file_size_threshold)" "2000"
assert_eq "  生效值 inner_seq_selector" "$(cmp_eff "${DN[0]}" inner_seq_selector)" "size_tiered_multi_target"

cmp_compaction_off
cmp_mkdb1 "$DB"
BASE=$(now_ms)
for b in 1 2 3 4; do cmp_batch1 "$DB" "$b" "$(( BASE + b*20000 ))" "${b}/0/0/0" 200; done
log "  起点：布局=$(cmp_lay "$DB") files=$(cmp_all_sum "$DB")（4 个 L0，单文件 ≈1.2~1.4KB）"
FP0=$(cmp_fp_tree "$DB"); FIN0=$(cmp_inner_finish "$DB")

log "--- A 相：阈值 2KB（装不下两个文件）⇒ 期望**不合并** ---"
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep "$WIN"
FINA=$(cmp_inner_finish "$DB"); LAYA=$(cmp_lay_uni "$(cmp_lay "$DB")")
log "  A 相后：布局=$(cmp_lay "$DB") finishes=$FIN0 → $FINA"
if [ "$FINA" = "$FIN0" ] && [ "${LAYA:-x}" = "4/0/0/0 " ]; then
  pass "  阈值=2000：单任务只能收 1 个文件 ⇒ 不提交任务、不合并（布局仍 4×L0）"
else
  fail "  阈值=2000：期望不合并，实际 finishes=$FIN0 → $FINA 布局=$(cmp_lay "$DB")"
fi

log "--- B 相：热改 10KB（装得下全部 4 个文件）⇒ 期望合并成 1 个 L1 ---"
cmp_set_hot inner_compaction_total_file_size_threshold 10000 >/dev/null
assert_eq "  生效值（热改后）" "$(cmp_eff "${DN[0]}" inner_compaction_total_file_size_threshold)" "10000"
deadline=$(( $(date +%s) + 120 )); ok=0; FINB=$FINA
while (( $(date +%s) < deadline )); do
  FINB=$(cmp_inner_finish "$DB"); [ "${FINB:-0}" -gt "${FINA:-0}" ] && { ok=1; break; }; sleep 3
done
sleep 8
LAYB=$(cmp_lay_uni "$(cmp_lay "$DB")")
log "  B 相后：布局=$(cmp_lay "$DB") finishes=$FINA → $FINB"
[ "$ok" = 1 ] && pass "  阈值=10000：合并发生（finishes $FINA → $FINB）" || fail "  阈值=10000：仍未合并"
[ "${LAYB:-x}" = "0/1/0/0 " ] && pass "  4 个 L0 → 1 个 L1（一个任务全收）" || warn "  布局=$(cmp_lay "$DB")（期望 0/1/0/0）"
cmp_assert_same "  合并前后数据指纹" "$FP0" "$(cmp_fp_tree "$DB")"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
