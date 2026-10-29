#!/bin/bash
# ============================================================================
# DU-01 缺陷门禁（TDB-629）：执行磁盘占用统计后，被统计扫描过的 TsFile 必须仍能被合并
#
#   缺陷现象：只要用 `show disk_usage`，被扫过的 TsFile 就永远无法被合并，合并线程也会被卡住，
#             后续 TsFile 一直堆积。
#   根因（源码）：统计在采集阶段用 `TsFileResource.readLock()` 加锁，却与
#             `FileReaderManager` 的引用计数不配平；已"消费"的文件又被 `iterator.remove()`
#             从待释放队列里移除 ⇒ **每个被打开的 TsFile 永久泄漏一把读锁**；
#             合并执行阶段要 `TsFileResource.writeLock()`（CompactionUtils / AbstractCompactionTask）
#             ⇒ 写锁永久等不到 ⇒ 该文件再也不被合并、合并线程阻塞。
#             修复提交：e46c4b7a7d / 849f98444f「Fix read lock leak in disk usage statistics (#18807)」
#             （把 readLock/readUnlock 换成 FileReaderManager.increase/decreaseFileReaderReference）
#
#   本用例（树模型接口 `SHOW DISK_USAGE FROM <path>`）：
#     阶段 A 正向对照：合并开启时连写 DU_FILES 批数据 → 窗口内必须出现"合并完成"（证明配置有效）
#     阶段 B 缺陷触发：关合并 → 连写 DU_FILES 批 → **执行统计查询** → 开合并 → 观察窗口内
#                      必须出现"合并完成行数增加 + 该库 TsFile 数下降"
#   判据：
#     PASS = 阶段 A 合并推进 且 统计查询成功 且 阶段 B 合并推进
#     FAIL = 阶段 B 统计查询后合并毫无推进（命中 TDB-629）
#   佐证（只记录、不作判据）：jstack 里卡在 TsFileResource.writeLock 的线程数、合并日志尾部
#
# 用法： bash du_tree_merge_after_stats.sh [--consensus ...] [--framework 0|1]
# 参数： DU_DEVS=6 DU_ROWS=300 DU_FILES=2 DU_WIN_SEC=90 DU_MERGE_WAIT_SEC=90
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/du.sh"
du_load_env
du_parse_args "$@"
du_case_init "du_tree_merge_after_stats_${DATA_CONSENSUS}"

DB=root.dumergt
DEVS=${DU_DEVS:-6}
ROWS=${DU_ROWS:-300}
FILES=${DU_FILES:-2}
WIN=${DU_WIN_SEC:-90}
WAIT=${DU_MERGE_WAIT_SEC:-90}

log "--- 集群准备（合并参数：$DU_CMP_EXTRA_CONF）---"
EXTRA_CONF="$DU_CMP_EXTRA_CONF" du_cluster_prepare
log "  实际生效的合并参数（${DN[0]}）：$(du_cmp_conf "${DN[0]}")"

log "--- 造场景：建库 $DB（$DEVS 设备）---"
du_make_tree_db "$DB" "$DEVS"

# ---------------------------------------------------------------- 阶段 A
log "--- 阶段 A（正向对照）：连写 $FILES 批数据，期望合并发生 ---"
a_fin0=$(du_cmp_finish_sum "$DB")
for b in $(seq 1 "$FILES"); do du_write_tree_batch "$DB" "$DEVS" "$ROWS" "$b"; done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"
a_ts_after=$(du_tsfile_sum "$DB")
log "  阶段 A 写入后：tsfile=$a_ts_after（逐节点 $(du_tsfile_all "$DB")）"
a_fin_last=$(du_cmp_finish_sum "$DB")
local_deadline=$(( $(date +%s) + WAIT ))
while [ "$a_fin_last" -le "$a_fin0" ] && [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 5; a_fin_last=$(du_cmp_finish_sum "$DB")
done
if [ "$a_fin_last" -gt "$a_fin0" ]; then
  pass "阶段 A 正向对照：合并正常推进（finish $a_fin0 → $a_fin_last，tsfile=$(du_tsfile_sum "$DB")）"
  A_OK=1
else
  fail "阶段 A 场景无效：合并已开启且等 ${WAIT}s，仍无 \"InnerSpaceCompaction task finishes\" 增长（finish=$a_fin_last）——合并参数/落盘有问题，无法判定 TDB-629"
  A_OK=0
fi
log "  合并参数复核：$(du_cmp_conf "${DN[0]}")"

# ---------------------------------------------------------------- 阶段 B
log "--- 阶段 B：关合并 → 造 $FILES 个未合并 TsFile → 执行统计查询 → 开合并 → 观察 ---"
du_set_hot enable_seq_space_compaction false >/dev/null
du_set_hot enable_unseq_space_compaction false >/dev/null
B_CONF=$(du_cmp_conf "${DN[0]}")
log "  关合并后参数：$B_CONF"
if printf '%s' "$B_CONF" | grep -q 'enable_seq_space_compaction=false'; then
  pass "合并开关可热加载：enable_seq_space_compaction 已置 false"
else
  fail "场景无效：enable_seq_space_compaction 未按要求变为 false（本构建不支持热改？需改造用例）"
fi

b_fin0=$(du_cmp_finish_sum "$DB")
for b in $(seq 1 "$FILES"); do du_write_tree_batch "$DB" "$DEVS" "$ROWS" "$((10 + b))"; done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"
b_ts0=$(du_tsfile_sum "$DB")
log "  阶段 B 起点：tsfile=$b_ts0（逐节点 $(du_tsfile_all "$DB")）finish=$b_fin0"
log "  该库 TsFile：$(du_tsfile_list "${DN[0]}" "$DB" | tr '\n' ' ')"
if [ "$b_ts0" -lt 2 ]; then
  warn "阶段 B 起点该库 TsFile 数=$b_ts0（<2），合成本来也不会被触发，判定意义有限"
fi

log "--- 关键动作：执行磁盘占用统计（树模型 show disk_usage from $DB.**）---"
DUE=$(du_tree "$DB.**")
printf '%s\n' "$DUE" >"$ART/du_tree_after_stats.out"
if printf '%s\n' "$DUE" | grep -qE 'IoTDBSQLException|[Ee]rror'; then
  fail "统计查询本身失败（无法验证 TDB-629）：$(printf '%s' "$DUE" | head -3 | tr '\n' ' ')"
else
  pass "统计查询执行成功：$(du_tree_row_cnt "$DUE") 行，SizeInBytes 合计=$(du_tree_size_sum "$DUE")"
  printf '%s\n' "$DUE" | table_rows | while IFS= read -r l; do log "    | $l"; done
fi
DUE2=$(du_tree "$DB.**")
log "  第二次统计查询：$(du_tree_row_cnt "$DUE2") 行（模拟用户反复查询）"

du_set_hot enable_seq_space_compaction true >/dev/null
du_set_hot enable_unseq_space_compaction true >/dev/null
log "  重新开启合并后参数：$(du_cmp_conf "${DN[0]}")"

log "--- 观察窗口 ${WIN}s：统计查询之后合并是否还能推进 ---"
if RES=$(du_wait_merge "$DB" "$b_fin0" "$b_ts0" "$WIN"); then
  pass "TDB-629 未复现：统计查询后合并仍正常推进（$RES）"
  B_OK=1
else
  fail "命中 TDB-629：执行磁盘占用统计后，$DB 的合并毫无推进（$RES，窗口 ${WIN}s）——被统计扫过的 TsFile 永久持有读锁，合并拿不到写锁"
  B_OK=0
fi

log "--- 佐证证据 ---"
STUCK=$(du_stuck_writelock_sum)
log "  卡在 TsFileResource.writeLock 的线程数（三节点合计）：$STUCK"
if [ "${STUCK:-0}" -gt 0 ]; then
  log "  线程栈片段（${DN[0]}）："
  du_stuck_stack "${DN[0]}" | while IFS= read -r l; do log "    $l"; done
fi
for h in "${DN[@]}"; do
  log "  $h 合并日志尾部：$(du_cmp_log_tail "$h" "$DB" | tr '\n' ' ' | cut -c1-300)"
done

log "--- 收尾三件套 ---"
post_checks "select count(*) from $DB.d$DEVS.s1;" tree
ttl_case_finish "" tree ""
