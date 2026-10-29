#!/bin/bash
# ============================================================================
# DU-02 缺陷门禁（TDB-629，表模型接口）：执行 table_disk_usage 统计后，被扫描的 TsFile 必须仍能被合并
#
#   与 DU-01 同一缺陷、同一根因（统计采集阶段 readLock 泄漏），只是走**表模型**接口：
#     `select * from information_schema.table_disk_usage`
#   表模型多一层"大小索引"快路径（TableDiskUsageStatisticUtil.calculateWithoutOpenFile）：
#     · 该 TsFile 的大小已在索引里            → 直接读索引（不打开文件，不泄漏）
#     · 库内不止一张表、或存在 mods           → 必须打开文件（**泄漏读锁**）
#   因此本用例**必须让库内有多张表**，并且统计查询要发生在"这些 TsFile 还没进索引"的时候
#   （集群刚起、库刚建、此前没有任何统计查询）。
#
#   判据与 DU-01 相同：
#     阶段 A 正向对照（合并开启连写 → 必须出现合并完成）
#     阶段 B：关合并 → 连写 → 执行 table_disk_usage 统计 → 开合并 → 窗口内必须出现合并完成 + TsFile 数下降
#
# 用法： bash du_table_merge_after_stats.sh [--consensus ...] [--framework 0|1]
# 参数： DU_DEVS=6 DU_ROWS=300 DU_FILES=2 DU_WIN_SEC=90
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/du.sh"
du_load_env
du_parse_args "$@"
du_case_init "du_table_merge_after_stats_${DATA_CONSENSUS}"

DB=dumergtb
TB=t1
DEVS=${DU_DEVS:-6}
ROWS=${DU_ROWS:-300}
FILES=${DU_FILES:-2}
WIN=${DU_WIN_SEC:-90}
WAIT=${DU_MERGE_WAIT_SEC:-90}

log "--- 集群准备（合并参数：$DU_CMP_EXTRA_CONF）---"
EXTRA_CONF="$DU_CMP_EXTRA_CONF" du_cluster_prepare
log "  实际生效的合并参数（${DN[0]}）：$(du_cmp_conf "${DN[0]}")"

log "--- 造场景：建库 $DB（两张表 t1/t2，保证表模型统计必须打开文件）---"
du_make_table_db "$DB"
log "  表清单：$(sqt "show tables from $DB;" | strip_echo | table_rows | tr '\n' ' ')"
log "  （说明）表模型统计走\"打开文件\"分支的条件是 **库内不止一张表**（或存在 mods），与数据写在哪个表无关"

# ---------------------------------------------------------------- 阶段 A
log "--- 阶段 A（正向对照）：连写 $FILES 批数据，期望合并发生 ---"
a_fin0=$(du_cmp_finish_sum "$DB")
for b in $(seq 1 "$FILES"); do du_write_table_batch "$DB" "$TB" "$DEVS" "$ROWS" "$b"; done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"
log "  阶段 A 写入后：tsfile=$(du_tsfile_sum "$DB")（逐节点 $(du_tsfile_all "$DB")）"
a_fin_last=$(du_cmp_finish_sum "$DB")
deadline=$(( $(date +%s) + WAIT ))
while [ "$a_fin_last" -le "$a_fin0" ] && [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 5; a_fin_last=$(du_cmp_finish_sum "$DB")
done
if [ "$a_fin_last" -gt "$a_fin0" ]; then
  pass "阶段 A 正向对照：合并正常推进（finish $a_fin0 → $a_fin_last，tsfile=$(du_tsfile_sum "$DB")）"
else
  fail "阶段 A 场景无效：合并已开启且等 ${WAIT}s，仍无 InnerSpaceCompaction 完成行（finish=$a_fin_last）"
fi
A_TS=$(du_tsfile_sum "$DB")
if [ "${A_TS:-0}" -lt 2 ]; then
  fail "阶段 A 场景无效：写入后该库 TsFile 数=$A_TS（<2）——表模型 DDL/写入有问题，无法验证合并"
  SCENARIO_OK=0
else
  SCENARIO_OK=1
fi

# ---------------------------------------------------------------- 阶段 B
log "--- 阶段 B：关合并 → 造 $FILES 个未合并 TsFile → 执行 table_disk_usage 统计 → 开合并 → 观察 ---"
du_set_hot enable_seq_space_compaction false >/dev/null
du_set_hot enable_unseq_space_compaction false >/dev/null
B_CONF=$(du_cmp_conf "${DN[0]}")
log "  关合并后参数：$B_CONF"
printf '%s' "$B_CONF" | grep -q 'enable_seq_space_compaction=false' \
  && pass "合并开关可热加载：enable_seq_space_compaction=false" \
  || fail "场景无效：合并开关未生效为 false"

b_fin0=$(du_cmp_finish_sum "$DB")
for b in $(seq 1 "$FILES"); do du_write_table_batch "$DB" "$TB" "$DEVS" "$ROWS" "$((10 + b))"; done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"
b_ts0=$(du_tsfile_sum "$DB")
log "  阶段 B 起点：tsfile=$b_ts0（逐节点 $(du_tsfile_all "$DB")）finish=$b_fin0"
log "  该库 TsFile：$(du_tsfile_list "${DN[0]}" "$DB" | tr '\n' ' ')"
[ "$b_ts0" -lt 2 ] && warn "阶段 B 起点该库 TsFile 数=$b_ts0（<2），合成本来也不会被触发"

log "--- 关键动作：执行表模型磁盘占用统计（information_schema.table_disk_usage）---"
DUT=$(du_table_all)
printf '%s\n' "$DUT" >"$ART/du_table_after_stats.out"
if printf '%s\n' "$DUT" | grep -qE 'IoTDBSQLException|[Ee]rror'; then
  fail "统计查询本身失败（无法验证 TDB-629）：$(printf '%s' "$DUT" | head -3 | tr '\n' ' ')"
else
  ROWS_MINE=$(du_table_rows "$DUT" | awk -F'|' -v db="$DB" '{d=$2; gsub(/^[ \t]+|[ \t]+$/,"",d); if (d==db) print}' | wc -l | tr -d ' ')
  pass "统计查询执行成功：全表 $(du_table_row_cnt "$DUT") 行，其中本库 $ROWS_MINE 行，本库 SizeInBytes 合计=$(du_table_rows "$DUT" | awk -F'|' -v db="$DB" '{d=$2; gsub(/^[ \t]+|[ \t]+$/,"",d); if(d==db){v=$7; gsub(/[^0-9-]/,"",v); s+=v}} END{print s+0}')"
  du_table_rows "$DUT" | awk -F'|' -v db="$DB" '{d=$2; gsub(/^[ \t]+|[ \t]+$/,"",d); if (d==db) print}' | while IFS= read -r l; do log "    | $l"; done
fi
DUT2=$(du_table_all)
log "  第二次统计查询：全表 $(du_table_row_cnt "$DUT2") 行"

du_set_hot enable_seq_space_compaction true >/dev/null
du_set_hot enable_unseq_space_compaction true >/dev/null
log "  重新开启合并后参数：$(du_cmp_conf "${DN[0]}")"

log "--- 观察窗口 ${WIN}s：统计查询之后合并是否还能推进 ---"
if RES=$(du_wait_merge "$DB" "$b_fin0" "$b_ts0" "$WIN"); then
  pass "TDB-629 未复现（表模型接口）：统计查询后合并仍正常推进（$RES）"
else
  fail "命中 TDB-629（表模型接口）：执行 table_disk_usage 统计后，$DB 的合并毫无推进（$RES，窗口 ${WIN}s）"
fi

log "--- 佐证证据 ---"
STUCK=$(du_stuck_writelock_sum)
log "  卡在 TsFileResource.writeLock 的线程数（三节点合计）：$STUCK"
for h in "${DN[@]}"; do
  log "  $h 合并日志尾部：$(du_cmp_log_tail "$h" "$DB" | tr '\n' ' ' | cut -c1-300)"
done

log "--- 收尾三件套 ---"
post_checks "" tree
ttl_case_finish "" tree ""
