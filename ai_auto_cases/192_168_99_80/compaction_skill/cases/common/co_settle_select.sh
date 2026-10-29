#!/bin/bash
# ============================================================================
# CO-26 `inner_compaction_task_selection_mods_file_threshold`
#       × `inner_compaction_task_selection_disk_redundancy` 基础功能
#       —— **带删除标记（mods）的文件何时被 settle 重写**
#
# 源码依据（RC6 `7ae8713e`）：
#   `SettleSelectorImpl.selectFileBaseOnModSize()`（L224-234，**非 heavy** 选择路径，每个调度周期都跑）：
#       totalModSize <= 0                              → NOT_SATISFIED（无删除标记，不选）
#       totalModSize >  inner_compaction_task_selection_mods_file_threshold
#         || !isDiskHasSpace(inner_compaction_task_selection_disk_redundancy)
#                                                      → PARTIALLY_DIRTY（选中、重写该文件）
#   `CompactionUtils.isDiskHasSpace(red)`（L495-518）= `available/total > diskSpaceWarningThreshold(默认 0.05) + red`
#   `CompactionScheduler.tryToSubmitSettleCompactionTask(..., heavySelect=false)` 每 `compaction_schedule_interval_in_ms` 调一次；
#   且要求 `enable_seq_space_compaction || enable_unseq_space_compaction` 至少一个为 true。
#
# 三个子场景（各一个独立库，都是"1 个 TsFile + DELETE 掉一部分行 ⇒ 产生 .mods"）：
#   A：mods 阈值=默认 128KB、disk_redundancy=0（磁盘充足）⇒ 45s 内**不应重写**（.mods 仍在、无 settle 任务）
#   B：热改 mods 阈值=1 字节                     ⇒ **应重写**（出现 partially_dirty 的 settle 任务、.mods 消失）
#   C：mods 阈值改回 128KB、disk_redundancy=0.999 ⇒ **应重写**（磁盘冗余分支；available/total > 1.049 恒不成立）
#   三个子场景都校验：删除后的行数在重写前后不变（删除的数据不得复活）。
# 用法： bash co_settle_select.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_settle_select_${DATA_CONSENSUS}"

DB=root.cosettle
WIN=${CO_COMBO_WIN:-45}

log "--- 集群准备：只开 seq（settle 的前置条件），关 unseq/cross；mods 阈值默认、磁盘冗余 0 ---"
EXTRA_CONF="enable_seq_space_compaction=true,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_compaction_task_selection_mods_file_threshold=131072,inner_compaction_task_selection_disk_redundancy=0" cmp_cluster_prepare
for kv in inner_compaction_task_selection_mods_file_threshold=131072 inner_compaction_task_selection_disk_redundancy=0; do
  k=${kv%%=*}; want=${kv#*=}; assert_eq "  生效值 $k" "$(cmp_eff "${DN[0]}" "$k")" "$want"
done

# 造场景：1 批数据 → flush → 删掉前一半行（产生 mods 文件）→ flush
co26_scene(){ local db=$1 base; base=$(now_ms)
  cmp_mkdb1 "$db"
  cmp_batch1 "$db" 1 "$base" "1/0/0/0" 200
  sq "delete from $db.d1.** where time <= $(( base + 1000 ));" >/dev/null
  sq "flush;" >/dev/null
  cmp_wait_close "$db" 2 60 >/dev/null || true
  log "  [$db] 场景：布局=$(cmp_lay "$db") mods=$(cmp_mods_sum "$db") 删除后行数=$(row_sum "$(sq "select count(s1) from $db.**;")")"; }
co26_settle(){ local db=$1 h s=0 n
  for h in "${DN[@]}"; do n=$(settle_partial_task_for_db "$h" "$db"); s=$(( s + ${n:-0} )); done; echo "${s:-0}"; }
co26_wait_settle(){ local db=$1 t=${2:-90} dl fin; dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    fin=$(co26_settle "$db"); [ "${fin:-0}" -ge 1 ] && { echo "$fin"; return 0; }
    sleep 5
  done
  echo "${fin:-0}"; return 1; }

log "--- A 相：mods 阈值=默认 128KB、磁盘冗余=0 ⇒ 期望不重写 ---"
DBA="${DB}a"; co26_scene "$DBA"
ROWS_A=$(row_sum "$(sq "select count(s1) from $DBA.**;")")
MODS_A0=$(cmp_mods_sum "$DBA")
sleep "$WIN"
SA=$(co26_settle "$DBA"); MODS_A1=$(cmp_mods_sum "$DBA")
log "  [A] ${WIN}s 后：partially_dirty settle 任务=$SA mods=$MODS_A0→$MODS_A1"
[ "${SA:-0}" -eq 0 ] && [ "${MODS_A1:-0}" -ge 1 ] \
  && pass "  [A] mods(${MODS_A0} 个文件) 未超阈值且磁盘充足 ⇒ **不重写**（无 settle 任务、.mods 仍在）" \
  || warn "  [A] 期望不重写，实际 settle=$SA mods=$MODS_A0→$MODS_A1（记录）"

log "--- B 相：热改 mods 阈值=1 字节 ⇒ 期望重写并清理 .mods ---"
cmp_set_hot inner_compaction_task_selection_mods_file_threshold 1 >/dev/null
assert_eq "  生效值（热改后）" "$(cmp_eff "${DN[0]}" inner_compaction_task_selection_mods_file_threshold)" "1"
DBB="${DB}b"; co26_scene "$DBB"
ROWS_B=$(row_sum "$(sq "select count(s1) from $DBB.**;")"); MODS_B0=$(cmp_mods_sum "$DBB")
FP_B=$(cmp_fp_tree "$DBB")
SB=$(co26_wait_settle "$DBB" 120); MODS_B1=$(cmp_mods_sum "$DBB")
log "  [B] 重写后：partially_dirty settle 任务=$SB mods=$MODS_B0→$MODS_B1 行数=$ROWS_B"
[ "${SB:-0}" -ge 1 ] && pass "  [B] mods 超过阈值(1B) ⇒ 被 settle 选中重写（partially_dirty 任务 $SB 个）" \
  || fail "  [B] 期望被 settle 重写，实际 settle=$SB"
[ "${MODS_B1:-0}" -eq 0 ] && pass "  [B] 重写后 .mods 消失（删除标记已物理应用，mods $MODS_B0→0）" \
  || warn "  [B] 重写后仍有 $MODS_B1 个 .mods（记录）"
cmp_assert_same "  [B] 重写前后数据指纹" "$FP_B" "$(cmp_fp_tree "$DBB")"
assert_eq "  [B] 删除行数不变" "$(row_sum "$(sq "select count(s1) from $DBB.**;")")" "$ROWS_B"

log "--- C 相：mods 阈值=128KB、磁盘冗余=0.999 ⇒ 期望走『磁盘不足』分支重写 ---"
cmp_set_hot inner_compaction_task_selection_mods_file_threshold 131072 >/dev/null
cmp_set_hot inner_compaction_task_selection_disk_redundancy 0.999 >/dev/null
assert_eq "  生效值（热改后）" "$(cmp_eff "${DN[0]}" inner_compaction_task_selection_disk_redundancy)" "0.999"
DBC="${DB}c"; co26_scene "$DBC"
ROWS_C=$(row_sum "$(sq "select count(s1) from $DBC.**;")"); MODS_C0=$(cmp_mods_sum "$DBC")
FP_C=$(cmp_fp_tree "$DBC")
SC=$(co26_wait_settle "$DBC" 120); MODS_C1=$(cmp_mods_sum "$DBC")
log "  [C] 重写后：partially_dirty settle 任务=$SC mods=$MODS_C0→$MODS_C1 行数=$ROWS_C"
[ "${SC:-0}" -ge 1 ] && pass "  [C] disk_redundancy=0.999 ⇒ isDiskHasSpace=false ⇒ 有 mods 的文件被重写（任务 $SC 个）" \
  || fail "  [C] 期望走磁盘冗余分支重写，实际 settle=$SC"
[ "${MODS_C1:-0}" -eq 0 ] && pass "  [C] 重写后 .mods 消失（$MODS_C0→0）" || warn "  [C] 仍有 $MODS_C1 个 .mods（记录）"
cmp_assert_same "  [C] 重写前后数据指纹" "$FP_C" "$(cmp_fp_tree "$DBC")"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from ${DB}a.d1 order by time;" tree
cmp_case_finish "" tree ""
