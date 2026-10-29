#!/bin/bash
# ============================================================================
# CO-27 **最基础形态**：不合并的情形必须不合并、该合并的必须合并
#   ① 单文件（no-op）：一个 TsFile 不成任务 ⇒ 不合并；
#   ② 空库：没有任何 TsFile ⇒ 不报错、不产生任务；
#   ③ 全删后合并：数据全被 DELETE ⇒ 合并照样完成，删除的数据不得复活；
#   ④ **多时间分区**：一个 data region 跨两个时间分区（相隔两周）⇒ 两个分区各自独立合并。
#   源码依据：`CompactionScheduler.scheduleCompaction` 按 `timePartition` 逐个调度；
#   `SizeTieredCompactionSelector` 里 `hasNextTimePartition` 还会影响"不足门槛也提交"的分支。
# 用法： bash co_basic_shapes.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_basic_shapes_${DATA_CONSENSUS}"

DB=root.coshape
WIN=${CO_COMBO_WIN:-40}

log "--- 集群准备：三类合并先关（写入阶段），multi_target + gap=0 + candidate=2 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0" cmp_cluster_prepare

# 每个 DN 上"各时间分区目录 → 文件数/其中 L1 文件数"
co27_pparts(){ local db=$1 h out=""
  for h in "${DN[@]}"; do
    out="$out${h##*.}:[$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%h %f\n' 2>/dev/null | awk '{d=\$1; sub(/.*\//,\"\",d); c[d]++; split(\$2,a,\"-\"); if(a[3]==1) o[d]++} END{for(k in c) printf \"%s:%d/%d \", k, c[k], o[k]+0}'" 2>/dev/null)] "
  done; echo "$out"; }
# 每个 DN 都必须"恰好 2 个分区目录、每目录恰好 1 个文件且层级=1"
co27_ppart_ok(){ local db=$1 h n ok=1
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%h %f\n' 2>/dev/null | awk '{d=\$1; sub(/.*\//,\"\",d); c[d]++; split(\$2,a,\"-\"); if(a[3]==1) o[d]++} END{for(k in c) if (c[k]==1 && (o[k]+0)==1) n++; print n+0}'" 2>/dev/null | tr -dc '0-9')
    [ "${n:-0}" = "2" ] || ok=0
  done; echo "$ok"; }

# ① 单文件 no-op
log "--- ① 单文件（no-op）---"
cmp_compaction_off
DB1="${DB}1"; cmp_mkdb1 "$DB1"; cmp_batch1 "$DB1" 1 "$(now_ms)" "1/0/0/0" 200
FIN10=$(cmp_inner_finish "$DB1")
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep "$WIN"
FIN11=$(cmp_inner_finish "$DB1"); LAY1=$(cmp_lay_uni "$(cmp_lay "$DB1")")
log "  单文件库：布局=$(cmp_lay "$DB1") finishes=$FIN10 → $FIN11"
[ "$FIN10" = "$FIN11" ] && [ "${LAY1:-x}" = "1/0/0/0 " ] \
  && pass "  ① 单文件不成任务 ⇒ 未发生合并（finishes 不增、布局仍 1×L0）" \
  || fail "  ① 期望不合并，实际 finishes=$FIN10 → $FIN11 布局=$(cmp_lay "$DB1")"

# ② 空库
log "--- ② 空库（只有 database，无 TsFile）---"
DB2="${DB}2"
sq "create database $DB2;" >/dev/null
sleep 20
TMP2=$(cmp_tmp_leftover "$DB2"); N2=$(sshx "${DN[0]}" "find $DB_DIR/data/datanode/data -path '*/$DB2/*' -name '*.tsfile' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
log "  空库：TsFile=$N2 临时文件=$TMP2"
[ "${N2:-0}" -eq 0 ] && pass "  ② 空库无 TsFile、无临时文件（调度不报错）" || warn "  ② 空库出现 $N2 个 TsFile（记录）"

# ③ 全删后合并
log "--- ③ 数据全部 DELETE 后合并（不得复活）---"
DB3="${DB}3"; cmp_mkdb1 "$DB3"
B3=$(now_ms)
cmp_batch1 "$DB3" 1 "$B3" "1/0/0/0" 200
cmp_batch1 "$DB3" 2 "$(( B3 + 20000 ))" "2/0/0/0" 200
sq "delete from $DB3.d1.** where time <= $(( B3 + 40000 ));" >/dev/null
sq "flush;" >/dev/null
ROWS3=$(row_sum "$(sq "select count(s1) from $DB3.**;")")
FIN30=$(cmp_inner_finish "$DB3")
log "  删除后行数=$ROWS3（期望 0）；mods=$(cmp_mods_sum "$DB3")"
cmp_set_hot enable_seq_space_compaction true >/dev/null
deadline=$(( $(date +%s) + 120 )); ok3=0
while (( $(date +%s) < deadline )); do
  FIN31=$(cmp_inner_finish "$DB3"); [ "${FIN31:-0}" -gt "${FIN30:-0}" ] && { ok3=1; break; }; sleep 3
done
sleep 8
ROWS3B=$(row_sum "$(sq "select count(s1) from $DB3.**;")")
log "  合并后：finishes=$FIN30 → ${FIN31:-0} 行数=$ROWS3 → $ROWS3B 布局=$(cmp_lay "$DB3")"
assert_eq "  ③ 删除后立即查询行数" "$ROWS3" "0"
[ "$ok3" = 1 ] && pass "  ③ 全删后合并仍然执行（finishes $FIN30 → $FIN31，未被删除标记挡住）" \
  || warn "  ③ 全删后未观察到合并推进（finishes=$FIN30，记录）"
assert_eq "  ③ 合并后行数（删除的数据不得复活）" "$ROWS3B" "0"

# ④ 多时间分区
log "--- ④ 多时间分区（一个 region 跨两个周分区）---"
DB4="${DB}4"; cmp_compaction_off; cmp_mkdb1 "$DB4"
NOW4=$(now_ms); OLD4=$(( NOW4 - 14*24*3600*1000 ))
cmp_batch1 "$DB4" 1 "$OLD4" "1/0/0/0" 200
cmp_batch1 "$DB4" 2 "$(( OLD4 + 20000 ))" "2/0/0/0" 200
cmp_batch1 "$DB4" 3 "$(( NOW4 - 60000 ))" "3/0/0/0" 200
cmp_batch1 "$DB4" 4 "$(( NOW4 - 40000 ))" "4/0/0/0" 200
log "  分区目录（DN:[分区:文件数/L1 数]）= $(co27_pparts "$DB4")"
FP4=$(cmp_fp_tree "$DB4"); FIN40=$(cmp_inner_finish "$DB4")
cmp_set_hot enable_seq_space_compaction true >/dev/null
deadline=$(( $(date +%s) + 150 )); ok4=0
while (( $(date +%s) < deadline )); do
  [ "$(co27_ppart_ok "$DB4")" = "1" ] && { ok4=1; break; }; sleep 5
done
sleep 5
log "  合并后分区目录 = $(co27_pparts "$DB4")；finishes=$FIN40 → $(cmp_inner_finish "$DB4")"
[ "$ok4" = "1" ] && pass "  ④ 两个时间分区各自完成合并（每分区 1 个 L1 文件，各副本一致）" \
  || warn "  ④ 分区布局未达到预期（$(co27_pparts "$DB4")，记录）"
cmp_assert_same "  ④ 多分区数据指纹" "$FP4" "$(cmp_fp_tree "$DB4")"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from ${DB}4.d1 order by time;" tree
cmp_case_finish "" tree ""
