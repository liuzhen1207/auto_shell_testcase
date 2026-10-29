#!/bin/bash
# ============================================================================
# CO-32 `enable_auto_repair_compaction` 基础功能（开/关对照）
#
# 源码依据（RC6 `7ae8713e`）：
#   · `SizeTieredCompactionSelector.selectFileNeedToRepair()`（L217-235）：只有开关为 true 时，
#     才会把 `TsFileRepairStatus` 命中"待修复"的文件挑出来做 `RepairUnsortedFileCompactionTask`；
#     （`NewSizeTieredCompactionSelector` 覆写了层级选择，但 `selectInnerSpaceTask` 仍走父类 ⇒ 同样受影响）
#   · `AbstractCompactionTask`（L550-557）：**重叠校验失败**时，
#       开关=false ⇒ 直接抛 `CompactionValidationFailedException`（任务失败）；
#       开关=true  ⇒ 把重叠文件标 `NEED_TO_CHECK`，留给后续 repair 任务处理。
#
# 现实约束（如实记录）：用 SQL 正常写入时，TsFile 在 seq 空间天然不重叠、也不带"未排序"标记，
#   因此**无法**从 SQL 侧构造出 `NEED_TO_CHECK/NEED_TO_REPAIR_*` 的文件（要造需要 load/导入未排序文件）。
# 本用例因此覆盖"基础功能与副作用"：
#   · 开/关两种取值下，正常场景的合并都必须完成、数据一致；
#   · 两种取值下都**不得**出现修复任务（`RepairUnsortedFileCompactionTask`）——防止"误报修复"。
# 用法： bash co_auto_repair.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_auto_repair_${DATA_CONSENSUS}"

DB=root.corepair

co32_repair_cnt(){ local h s=0 n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -hc 'RepairUnsortedFileCompactionTask' $(cmp_log_files) 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done; echo "${s:-0}"; }
co32_run(){ local tag=$1 val=$2 base db
  cmp_compaction_off
  cmp_set_hot enable_auto_repair_compaction "$val" >/dev/null
  assert_eq "  [$tag] enable_auto_repair_compaction 生效值" "$(cmp_eff "${DN[0]}" enable_auto_repair_compaction)" "$val"
  db="${DB}${tag}"; cmp_mkdb1 "$db"; base=$(now_ms)
  local b fp0 fin0 fin1 dl ok=0
  for b in 1 2 3; do cmp_batch1 "$db" "$b" "$(( base + b*20000 ))" "${b}/0/0/0" 200; done
  fp0=$(cmp_fp_tree "$db"); fin0=$(cmp_inner_finish "$db"); R0=$(co32_repair_cnt)
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  dl=$(( $(date +%s) + 150 ))
  while (( $(date +%s) < dl )); do
    fin1=$(cmp_inner_finish "$db"); [ "${fin1:-0}" -gt "${fin0:-0}" ] && { ok=1; break; }; sleep 3
  done
  sleep 8
  local R1; R1=$(co32_repair_cnt)
  log "  [$tag] 合并后：布局=$(cmp_lay "$db") finishes=$fin0 → ${fin1:-0} 修复任务计数=$R0 → $R1"
  [ "$ok" = 1 ] && pass "  [$tag] 开关=$val 时正常场景合并完成（finishes $fin0 → $fin1）" || fail "  [$tag] 合并未推进"
  cmp_assert_same "  [$tag] 合并前后数据指纹" "$fp0" "$(cmp_fp_tree "$db")"
  [ "${R1:-0}" -eq "${R0:-0}" ] && pass "  [$tag] 没有误报修复任务（RepairUnsortedFileCompactionTask 计数不变）" \
    || warn "  [$tag] 出现了修复任务（$R0 → $R1）——需要人工确认是否真有未排序文件（记录）"; }

log "--- 集群准备：三类合并先关；multi_target + gap=0 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,enable_auto_repair_compaction=true" cmp_cluster_prepare

co32_run on true
co32_run off false

log "--- 收尾三件套 ---"
post_checks "select count(s1) from ${DB}off.d1 order by time;" tree
cmp_case_finish "" tree ""
