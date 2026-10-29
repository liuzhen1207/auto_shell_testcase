#!/bin/bash
# ============================================================================
# CO-28 **表模型**的乱序内部合并 + 跨空间合并（当前用例集只有表模型 seq 内部合并）
#
# 覆盖缺口：CO-02 只测了表模型顺序空间内部合并；CO-03/CO-04 的 unseq/cross 只测了树模型。
# 表模型的写入路径、分区规则（`dev` TAG）、以及 `information_schema` 观测面都不同 ⇒ 必须单独覆盖。
#
# 源码依据：unseq/cross 的选择与执行与模型无关（`CompactionScheduler` 按 `timePartition` 调度，
# 只区分 sequence/unsequence 两个 TsFileManager），但**判定"乱序"的水位**、以及
# `RewriteCrossSpaceCompactionSelector` 的重叠判断都基于设备时间索引 ⇒ 表模型要重新构造场景。
#
# 场景（单表 t1、2 个 TAG 设备 d1/d2）：
#   ① 写 2 批顺序数据（更早的水位）→ 2 个 seq TsFile
#   ② 写 2 批**互相重叠**的更早数据 → 落 unseq
#   ③ 开 unseq 内部合并 ⇒ Unsequence InnerSpaceCompaction 推进、unseq 文件数下降
#   ④ 关 unseq 内部合并、开 cross（`min_cross_compaction_unseq_file_level=0`）⇒ unseq 归零、Cross 任务完成
#   判据：每步的数据指纹（表模型 count/sum）不变、`select *` 归一化结果不变。
# 用法： bash co_table_unseq_cross.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_table_unseq_cross_${DATA_CONSENSUS}"

DB=cotblux
DEVS=2
ROWS=300

log "--- 集群准备：三类合并先关；candidate=2、min_cross_unseq_level=0 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},min_cross_compaction_unseq_file_level=0" cmp_cluster_prepare

cmp_make_table_db "$DB" t1 ""
BASE=$(( ($(date +%s) - 3600) * 1000 ))
# ① 顺序水位（更早的时间段）
cmp_write_table_batch "$DB" t1 "$DEVS" "$ROWS" 1 "$BASE" || fail "写水位批失败"
sqt "flush;" >/dev/null
cmp_wait_close "$DB" 1 90 >/dev/null || warn "水位批 close 事件未达 1"
log "  ① 顺序水位后：seq=$(cmp_seq_sum "$DB") unseq=$(cmp_unseq_sum "$DB")"
# ② 2 批互相重叠的更早数据（落到 unseq）
b=0
for off in 1000 1200; do
  b=$(( b + 1 ))
  cmp_write_table_batch "$DB" t1 "$DEVS" "$ROWS" "$(( b + 5 ))" "$(( BASE - 20000 + off ))" || fail "写乱序批$b 失败"
  sqt "flush;" >/dev/null
  sleep 6
done
cmp_wait_su "$DB" "2/2" 150 >/dev/null || warn "  期望各副本 2 seq / 2 unseq，实际 $(cmp_su "$DB")"
log "  ② 乱序批后：$(cmp_su "$DB")"
U0=$(cmp_unseq_sum "$DB")
[ "${U0:-0}" -ge 2 ] && pass "场景有效：unseq 文件数=$U0（≥2）" || fail "场景无效：unseq=$U0"
FP0=$(cmp_fp_table "$DB.t1"); ROWS0=$(sqt "select count(v) from $DB.t1;" | table_rows | head -1 | awk -F'|' '{print $2+0}')
log "  指纹=$FP0 行数=$ROWS0"

log "--- ③ unseq 内部合并（表模型）---"
FIN0=$(cmp_unseq_inner_finish "$DB")
cmp_set_hot enable_unseq_space_compaction true >/dev/null
deadline=$(( $(date +%s) + 150 )); ok3=0
while (( $(date +%s) < deadline )); do
  FIN1=$(cmp_unseq_inner_finish "$DB"); [ "${FIN1:-0}" -gt "${FIN0:-0}" ] && { ok3=1; break; }; sleep 3
done
sleep 6
U1=$(cmp_unseq_sum "$DB")
log "  ③ unseq 内部合并后：unseq=$U0 → $U1 finishes=$FIN0 → ${FIN1:-0}"
[ "$ok3" = 1 ] && pass "  ③ 表模型 unseq 内部合并推进（finishes $FIN0 → $FIN1）" || warn "  ③ 未观察到 unseq 内部合并推进（记录）"
cmp_assert_same "  ③ unseq 内部合并前后指纹" "$FP0" "$(cmp_fp_table "$DB.t1")"

log "--- ④ 跨空间合并（表模型）---"
cmp_set_hot enable_unseq_space_compaction false >/dev/null
C0=$(cmp_cross_finish "$DB")
cmp_set_hot enable_cross_space_compaction true >/dev/null
deadline=$(( $(date +%s) + 180 )); ok4=0
while (( $(date +%s) < deadline )); do
  [ "$(cmp_unseq_sum "$DB")" = "0" ] && { ok4=1; break; }; sleep 3
done
sleep 6
C1=$(cmp_cross_finish "$DB")
log "  ④ cross 后：unseq=$U1 → $(cmp_unseq_sum "$DB") cross finishes=$C0 → $C1 布局=$(cmp_su "$DB")"
[ "$ok4" = 1 ] && pass "  ④ 表模型跨空间合并完成（unseq 归零）" || fail "  ④ unseq 未归零（$(cmp_unseq_sum "$DB")）"
cmp_assert_same "  ④ 跨空间合并前后指纹" "$FP0" "$(cmp_fp_table "$DB.t1")"
assert_eq "  ④ 跨空间合并前后行数" "$(sqt "select count(v) from $DB.t1;" | table_rows | head -1 | awk -F'|' '{print $2+0}')" "$ROWS0"

log "--- 收尾三件套 ---"
post_checks "select count(v) from $DB.t1;" table
cmp_case_finish "" table ""
