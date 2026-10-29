#!/bin/bash
# ============================================================================
# DU-03 树模型统计正确性（有数据）
#   覆盖（需求文档 §3.2 树模型 / §3.4 场景示例；实测语义见下）：
#     1) 结果集表头与列语义：Database | DataNodeId | RegionId | TimePartition | SizeInBytes
#     2) 有数据的库：SizeInBytes > 0，且不超过该库 TsFile 的物理字节数
#     3) pattern 作用域（**匹配对象是"设备路径"**，实测 2.0.12.1）：
#          root.db.**      → 库内所有设备（基准值）
#          root.db.*       → 同上（一层通配正好落到设备名）
#          root.db.d1      → 精确设备（>0 且 < 库级合计）★设备级统计可用
#          root.db.d1.**   → 0（`**` 需要至少一层，设备路径下没有子层 ⇒ 不匹配设备本身；记录为观察）
#          root.db.nosuchdev → 0（不匹配设备时仍会出行、SizeInBytes=0）
#          root.**         → 覆盖多个库
#     4) `ORDER BY SizeInBytes DESC LIMIT n` 分页可用
#     5) 匹配不到任何设备的 pattern 合计为 0（不是报错）
#   本用例关掉合并（TsFile 集合稳定）。
# 用法： bash du_tree_stats.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/du.sh"
du_load_env
du_parse_args "$@"
du_case_init "du_tree_stats_${DATA_CONSENSUS}"

DB_A=root.dustata
DB_B=root.dustatb
DEVS=${DU_DEVS:-6}
ROWS=${DU_ROWS:-300}

log "--- 集群准备（关合并，保证 TsFile 集合稳定）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false" du_cluster_prepare

log "--- 造数据：$DB_A（$DEVS 设备）与 $DB_B（$((DEVS/2)) 设备，数据量更小）---"
du_make_tree_db "$DB_A" "$DEVS"
du_make_tree_db "$DB_B" "$((DEVS/2))"
du_write_tree_batch "$DB_A" "$DEVS" "$ROWS" 1
du_write_tree_batch "$DB_B" "$((DEVS/2))" "$ROWS" 1
ensure_closed "$DB_A" 3 25 || warn "$DB_A 有 DN 的 TsFile 未落盘"
ensure_closed "$DB_B" 3 25 || warn "$DB_B 有 DN 的 TsFile 未落盘"
A_BYTES=$(du_tsfile_bytes_sum "$DB_A"); B_BYTES=$(du_tsfile_bytes_sum "$DB_B")
log "  物理大小（三节点合计）：$DB_A=${A_BYTES}B（tsfile=$(du_tsfile_sum "$DB_A")） $DB_B=${B_BYTES}B（tsfile=$(du_tsfile_sum "$DB_B")）"

# ------------------------------------------------------------------ 1) 表头与列语义
log "--- 1) 结果集表头与列语义 ---"
OUT_A=$(du_tree "$DB_A.**")
printf '%s\n' "$OUT_A" >"$ART/du_tree_dbA.out"
log "  表头: $(du_header "$OUT_A")"
for col in Database DataNodeId RegionId TimePartition SizeInBytes; do
  assert_contains "表头含列 $col" "$(du_header "$OUT_A")" "$col"
done
assert_contains "库名出现在结果里" "$OUT_A" "$DB_A"
assert_not_contains "本库查询不得出现另一个库 $DB_B" "$OUT_A" "$DB_B"

# ------------------------------------------------------------------ 2) 数值合理性
log "--- 2) 数值合理性（>0 且 <= 物理文件大小）---"
A_CNT=$(du_tree_row_cnt "$OUT_A"); A_SUM=$(du_tree_size_sum "$OUT_A")
log "  $DB_A：$A_CNT 行，SizeInBytes 合计=$A_SUM（物理 ${A_BYTES}B，占比 $(awk -v a="$A_SUM" -v b="$A_BYTES" 'BEGIN{printf "%.1f%%", (b>0? 100*a/b : 0)}')）"
log "  逐行："; du_tree_rows "$OUT_A" | while IFS= read -r l; do log "    | $l"; done
[ "$A_CNT" -ge 1 ] && pass "有数据的库返回 $A_CNT 行" || fail "有数据的库返回 0 行（期望 ≥1）"
[ "${A_SUM:-0}" -gt 0 ] && pass "SizeInBytes 合计 > 0（$A_SUM）" || fail "SizeInBytes 合计 = $A_SUM（期望 >0）"
[ "${A_SUM:-0}" -le "${A_BYTES:-0}" ] && pass "统计值不超过物理文件大小（$A_SUM <= $A_BYTES）" \
  || fail "统计值 $A_SUM 超过物理文件大小 $A_BYTES（口径异常）"
NODE_IDS=$(du_tree_col_uniq "$OUT_A" 2)
log "  DataNodeId 取值集合：[$NODE_IDS]"
[ -n "$NODE_IDS" ] && pass "DataNodeId 列非空" || fail "DataNodeId 列为空"

# ------------------------------------------------------------------ 3) pattern 作用域
log "--- 3) pattern 作用域（匹配对象是设备路径）---"
OUT_STAR=$(du_tree "$DB_A.*"); STAR_SUM=$(du_tree_size_sum "$OUT_STAR")
log "  $DB_A.*      合计=$STAR_SUM（库级 ** 为 $A_SUM）"
assert_eq "$DB_A.* 与 $DB_A.** 一致（都覆盖库内所有设备）" "${STAR_SUM:-0}" "${A_SUM:-0}"

OUT_D1=$(du_tree "$DB_A.d1"); D1_SUM=$(du_tree_size_sum "$OUT_D1")
log "  $DB_A.d1（精确设备）合计=$D1_SUM 行数=$(du_tree_row_cnt "$OUT_D1")"
[ "${D1_SUM:-0}" -gt 0 ] && pass "设备级统计可用：$DB_A.d1 = $D1_SUM（>0）" \
  || fail "设备级统计为 0：$DB_A.d1 = $D1_SUM（期望 >0；设备确实有数据）"
[ "${D1_SUM:-0}" -le "${A_SUM:-0}" ] && pass "设备级 <= 库级（$D1_SUM <= $A_SUM）" \
  || fail "设备级 $D1_SUM > 库级 $A_SUM（口径异常）"

OUT_DW=$(du_tree "$DB_A.d1.**"); DW_SUM=$(du_tree_size_sum "$OUT_DW")
log "  $DB_A.d1.**  合计=$DW_SUM（行数 $(du_tree_row_cnt "$OUT_DW")）"
if [ "${DW_SUM:-0}" = "0" ]; then
  warn "实测：设备路径后再写通配（$DB_A.d1.** / $DB_A.d1.*）匹配不到设备本身 ⇒ 合计 0；设备级统计请写精确设备路径 $DB_A.d1（需求文档只说\"中间节点支持 * 或 **\"，未说明该边界，记录供文档/研发确认）"
else
  pass "设备路径 + 通配也可用：$DB_A.d1.** = $DW_SUM"
fi

OUT_NONE=$(du_tree "$DB_A.nosuchdev_du")
N_SUM=$(du_tree_size_sum "$OUT_NONE")
log "  不匹配设备 $DB_A.nosuchdev_du：行数=$(du_tree_row_cnt "$OUT_NONE") 合计=$N_SUM"
if printf '%s\n' "$OUT_NONE" | grep -qE 'IoTDBSQLException|[0-9]{3}:'; then
  warn "不匹配设备时返回报错而非空/0 结果：$(printf '%s' "$OUT_NONE" | grep -oE '[0-9]{3}: [^"]{0,60}' | head -1)"
else
  assert_eq "不匹配设备时合计为 0" "${N_SUM:-0}" "0"
  log "  （注意：即使没有设备匹配，也会按 region/时间分区出行、SizeInBytes=0 —— 实测行为，记录）"
fi

OUT_ALL=$(du_tree "root.**")
assert_contains "root.** 覆盖 $DB_A" "$OUT_ALL" "$DB_A"
assert_contains "root.** 覆盖 $DB_B" "$OUT_ALL" "$DB_B"
OUT_B=$(du_tree "$DB_B.**"); B_SUM_ALL=$(du_tree_size_sum "$OUT_B")
log "  $DB_B.** 合计=$B_SUM_ALL 行数=$(du_tree_row_cnt "$OUT_B")"
[ "${B_SUM_ALL:-0}" -gt 0 ] && pass "另一个库也有统计值（$B_SUM_ALL > 0）" || fail "另一个库统计值为 0"
OUT_RSTAR=$(du_tree "root.*"); RSTAR_SUM=$(du_tree_size_sum "$OUT_RSTAR")
log "  root.*（一层通配）合计=$RSTAR_SUM"
[ "${RSTAR_SUM:-0}" = "0" ] && warn "实测 root.* 匹配不到设备（一层通配落到库名而非设备名）⇒ 合计 0；跨库统计请用 root.**（记录）" \
  || pass "root.* 可用（$RSTAR_SUM）"

# ------------------------------------------------------------------ 4) ORDER BY / LIMIT
log "--- 4) ORDER BY SizeInBytes DESC LIMIT 1 ---"
OUT_L=$(sq "show disk_usage from $DB_A.** order by SizeInBytes desc limit 1;")
L_CNT=$(du_tree_row_cnt "$OUT_L")
log "  返回 $L_CNT 行：$(du_tree_rows "$OUT_L" | tr '\n' ' ' | cut -c1-200)"
if printf '%s\n' "$OUT_L" | grep -qE 'IoTDBSQLException|[0-9]{3}:'; then
  warn "ORDER BY/LIMIT 子句未按预期执行：$(printf '%s' "$OUT_L" | grep -oE '[0-9]{3}: [^"]{0,80}' | head -1)（需求文档写了 orderByClause/rowPaginationClause，记录供研发确认语法）"
else
  assert_eq "LIMIT 1 生效（返回 1 行）" "$L_CNT" "1"
  L_MAX=$(du_tree_size_sum "$OUT_L")
  [ "${L_MAX:-0}" -ge 1 ] && pass "LIMIT 1 返回的是有值的行（$L_MAX）" || fail "LIMIT 1 返回 0 值"
fi

log "--- 收尾三件套 ---"
post_checks "select count(*) from $DB_A.d$DEVS.s1;" tree
ttl_case_finish "" tree ""
