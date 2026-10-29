#!/bin/bash
# ============================================================================
# CO-19 **乱序空间**的选择参数：`inner_unseq_selector`（multi_target）
#       × `inner_compaction_total_file_num_threshold` × `max_level_gap_in_inner_compaction`
#
# 为什么单独一条：CO-16 段 2 只验证了 unseq 的 selector×performer 能合并，CO-17 只在
# **顺序空间**验证了"文件数上限 / 层级 gap"的边界。unseq 空间的合并要求文件**时间区间重叠**，
# 场景构造不同、且 `inner_unseq_selector` 与 seq 是两套独立的枚举 → 必须单独覆盖。
#
# 源码依据（RC6 `7ae8713e`）：`InnerUnsequenceCompactionSelector.createInstance()`（L46-61 同构于 seq）
#   multi_target → `NewSizeTieredCompactionSelector`（读 gap / 文件数上限）；single_target → 经典实现。
#
# 场景（单设备；先写 1 批"水位"（当前时间）落 seq 空间，再写 3 批**互相重叠**的更早数据落 unseq）：
#   · ① `inner_compaction_total_file_num_threshold=2` ⇒ unseq 内部合并每个任务最多 2 个文件
#        （3 个 unseq L0 → 1 个 L1 + 1 个 L0）
#   · ② 热改 `max_level_gap_in_inner_compaction=1` ⇒ unseq 空间的 [L1(旧), L0(新)] 合并出 **L2**
#   · 全程 seq 内部合并关闭 ⇒ 顺带证明"两个空间各自独立选择"
# 用法： bash co_unseq_select.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_unseq_select_${DATA_CONSENSUS}"

DB=root.counsel

log "--- 集群准备：seq/cross 关、unseq 关（写入阶段）；unseq selector=multi_target、文件数上限=2、gap=0 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_unseq_selector=size_tiered_multi_target,inner_compaction_total_file_num_threshold=2,max_level_gap_in_inner_compaction=0" cmp_cluster_prepare
for kv in inner_unseq_selector=size_tiered_multi_target inner_compaction_total_file_num_threshold=2 max_level_gap_in_inner_compaction=0; do
  k=${kv%%=*}; assert_eq "  生效值 $k" "$(cmp_eff "${DN[0]}" "$k")" "${kv#*=}"
done

cmp_mkdb1 "$DB"
BASE=$(now_ms)
# ① 水位（seq 空间）：时间范围拉宽，让后面的乱序批次落在区间内且更早
co19_water(){ local k vals=""
  for ((k=1;k<=200;k++)); do vals="$vals($(( $1 + 100000 + k*2000 )),$((k+9))),"; done
  sq "insert into $DB.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  cmp_wait_close "$DB" 1 90 >/dev/null || warn "  水位批 close 事件未达 1"
  cmp_wait_su "$DB" "1/0" 120 >/dev/null; }
# ② 3 批互相重叠的乱序数据（落 unseq）：时间戳都在水位区间内、且小于水位最大值
co19_unseq(){ local b=$1 k vals=""
  for ((k=1;k<=200;k++)); do vals="$vals($(( BASE + 100000 + b*300 + k*1500 + 7 )),$((k+b))),"; done
  sq "insert into $DB.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  cmp_wait_close "$DB" "$(( 1 + b ))" 90 >/dev/null || warn "  第 $b 批 unseq close 事件未达 $(( 1 + b ))"
  cmp_wait_su "$DB" "1/$b" 150 >/dev/null && log "  unseq 第 $b 个文件就绪：$(cmp_su "$DB")"; }

co19_water "$BASE"
for b in 1 2 3; do co19_unseq "$b"; done
# 水位批也可能被判成 unseq（首写无水位）⇒ 兼容两种落点，只要求 unseq >= 3
log "  场景：$(cmp_su "$DB")（各副本 seq/unseq 文件数）"
U0=$(cmp_unseq_sum "$DB")
[ "${U0:-0}" -ge 3 ] && pass "  场景有效：unseq 文件数=$U0（≥3）" || fail "  场景无效：unseq=$U0（<3）"
FP0=$(cmp_fp_tree "$DB")

log "--- ① 文件数上限=2：unseq 内部合并每个任务最多 2 个文件 ---"
FIN0=$(cmp_unseq_inner_finish "$DB")
cmp_set_hot enable_unseq_space_compaction true >/dev/null
deadline=$(( $(date +%s) + 150 )); ok1=0
while (( $(date +%s) < deadline )); do
  FIN1=$(cmp_unseq_inner_finish "$DB"); [ "${FIN1:-0}" -gt "${FIN0:-0}" ] && { ok1=1; break; }; sleep 3
done
sleep 8
DIST=$(cmp_task_nums "$DB" inner); MAXN=$(cmp_task_max "$DIST")
log "  unseq 合并后：布局=$(cmp_lay "$DB") $(cmp_su "$DB") finishes=$FIN0→$FIN1 任务文件数分布=$DIST"
[ "$ok1" = 1 ] && pass "  unseq 内部合并推进（finishes $FIN0 → $FIN1）" || fail "  unseq 内部合并未推进"
[ "${MAXN:-0}" = 2 ] && pass "  文件数上限=2 生效：单任务最多 2 个文件（分布 ${DIST:-空}）" \
  || fail "  单任务文件数=$MAXN（期望 2，分布 ${DIST:-空}）"

log "--- ② 热改 gap=1：unseq 空间 [L1, L0] 应合并出 L2 ---"
FIN2=$(cmp_unseq_inner_finish "$DB")
cmp_set_hot max_level_gap_in_inner_compaction 1 >/dev/null
assert_eq "  生效值（热改后）" "$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction)" "1"
deadline=$(( $(date +%s) + 150 )); ok2=0
while (( $(date +%s) < deadline )); do
  FIN3=$(cmp_unseq_inner_finish "$DB"); [ "${FIN3:-0}" -gt "${FIN2:-0}" ] && { ok2=1; break; }; sleep 3
done
sleep 8
LAY=$(cmp_lay "$DB")
log "  gap=1 后：布局=$(cmp_lay "$DB") $(cmp_su "$DB") finishes=$FIN2→${FIN3:-0}"
[ "$ok2" = 1 ] && pass "  gap=1：unseq 空间的 [L1, L0] 被合并（finishes $FIN2 → $FIN3，布局 $LAY）" \
  || fail "  gap=1 未触发合并（布局=$LAY）"
cmp_assert_same "  unseq 空间合并前后数据指纹" "$FP0" "$(cmp_fp_tree "$DB")"
SEQ_FIN=$(cmp_seq_inner_finish "$DB")
[ "${SEQ_FIN:-0}" -eq 0 ] && pass "  顺带证明空间隔离：seq 内部合并全程关闭 ⇒ Sequence 内部合并 0 次" \
  || warn "  Sequence 内部合并计数=$SEQ_FIN（期望 0，记录）"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
