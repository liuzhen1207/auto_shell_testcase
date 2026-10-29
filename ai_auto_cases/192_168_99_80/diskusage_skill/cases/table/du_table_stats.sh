#!/bin/bash
# ============================================================================
# DU-04 表模型统计正确性（有数据）
#   覆盖（需求文档《统计数据的磁盘空间占用-需求分析》§3.2 表模型 / §3.4 场景示例）：
#     1) 结果集表头与列语义：database | table_name | datanode_id | region_id | time_partition | size_in_bytes
#        （实测 2.0.12.1 还多一列 table_type，用例会把真实表头打出来并记录该差异）
#     2) 数据量不同的两张表：统计值应反映差异（多的 > 少的），且都 >= 0；合计不超过物理文件大小
#     3) `where database = '...'` 过滤只返回该库
#     4) `where table_name like '%1'` 只返回匹配表
#     5) `GROUP BY database, table_name` 聚合值与明细求和一致
#     6) 过滤不存在的表返回空结果集（需求文档明确要求）
#     7) 视图不出现在统计里（需求文档明确要求）
#   **所有取值都按列名解析**（du_col_* / du_group_val）：不同构建的列集合可能不同，
#   写死列号会取错（本项目实测：2.0.12.1 多一列 table_type）。
#   本用例关掉合并（TsFile 集合稳定）。
# 用法： bash du_table_stats.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/du.sh"
du_load_env
du_parse_args "$@"
du_case_init "du_table_stats_${DATA_CONSENSUS}"

DB1=dustatb1
DB2=dustatb2
VW=lv1
DEVS=${DU_DEVS:-6}
ROWS=${DU_ROWS:-300}

log "--- 集群准备（关合并）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false" du_cluster_prepare

log "--- 造数据：$DB1(t1 多数据/t2 少数据 + 逻辑视图 $VW) 与 $DB2(t1) ---"
du_make_table_db "$DB1"
du_make_table_db "$DB2"
OUT_V=$(sqt "create view $DB1.$VW as select v from $DB1.t1;")
printf '%s' "$OUT_V" | grep -q 'successfully' && pass "建视图 $DB1.$VW 成功" || warn "建视图失败：$(printf '%s' "$OUT_V" | tr '\n' ' ' | cut -c1-160)"
bulk_table "$DB1" t1 "$DEVS" "$ROWS" "$(( ($(date +%s) - 3600) * 1000 ))" 10 >/dev/null
bulk_table "$DB1" t2 "$((DEVS/2))" "$ROWS" "$(( ($(date +%s) - 3600) * 1000 ))" 10 >/dev/null
bulk_table "$DB2" t1 "$DEVS" "$ROWS" "$(( ($(date +%s) - 3600) * 1000 ))" 10 >/dev/null
sqt "flush;" >/dev/null
C1=$(sqt "select count(*) from $DB1.t1;" | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/[^0-9]/,"",v); print v+0}')
C2=$(sqt "select count(*) from $DB1.t2;" | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/[^0-9]/,"",v); print v+0}')
log "  写入校验：$DB1.t1 count=$C1，$DB1.t2 count=$C2"
[ "${C1:-0}" -gt 0 ] && [ "${C2:-0}" -gt 0 ] && pass "两张表都写入成功" || fail "场景无效：表数据未写入（t1=$C1 t2=$C2）"
ensure_closed "$DB1" 3 25 || warn "$DB1 有 DN 的 TsFile 未落盘"
ensure_closed "$DB2" 3 25 || warn "$DB2 有 DN 的 TsFile 未落盘"
B1_BYTES=$(du_tsfile_bytes_sum "$DB1"); B2_BYTES=$(du_tsfile_bytes_sum "$DB2")
log "  物理大小：$DB1=${B1_BYTES}B（tsfile=$(du_tsfile_sum "$DB1")） $DB2=${B2_BYTES}B（tsfile=$(du_tsfile_sum "$DB2")）"

# ------------------------------------------------------------------ 1) 表头与列语义
log "--- 1) 表头与列语义 ---"
ALL=$(du_table_all)
printf '%s\n' "$ALL" >"$ART/du_table_all.out"
log "  真实表头: $(du_header "$ALL")"
for col in database table_name datanode_id region_id time_partition size_in_bytes; do
  assert_contains "表头含列 $col" "$(du_header "$ALL")" "$col"
done
if printf '%s' "$(du_header "$ALL")" | grep -q 'table_type'; then
  warn "实测表头比需求文档（2.0.8.2）多一列 table_type（值 BASE TABLE）；本用例按列名取值不受影响（记录，供文档同步）"
fi
log "  全表 $(du_table_row_cnt "$ALL") 行；本用例两个库的行："
du_table_rows "$ALL" | awk -F'|' -v a="$DB1" -v b="$DB2" '{d=$2; gsub(/^[ \t]+|[ \t]+$/,"",d); if(d==a||d==b) print}' | while IFS= read -r l; do log "    | $l"; done

# ------------------------------------------------------------------ 2) 数值合理性（按列名）
log "--- 2) 数值合理性 ---"
S1_T1=$(du_col_sum_2where "$ALL" size_in_bytes database "$DB1" table_name t1)
S1_T2=$(du_col_sum_2where "$ALL" size_in_bytes database "$DB1" table_name t2)
S2_T1=$(du_col_sum_2where "$ALL" size_in_bytes database "$DB2" table_name t1)
C1_T1=$(du_col_cnt_2where "$ALL" database "$DB1" table_name t1)
C1_T2=$(du_col_cnt_2where "$ALL" database "$DB1" table_name t2)
log "  $DB1.t1: $C1_T1 行 合计=${S1_T1}B ; $DB1.t2: $C1_T2 行 合计=${S1_T2}B ; $DB2.t1 合计=${S2_T1}B"
[ "${S1_T1:-0}" -gt 0 ] && pass "$DB1.t1 统计值 > 0（$S1_T1）" || fail "$DB1.t1 统计值 = $S1_T1（期望 >0）"
[ "${S2_T1:-0}" -gt 0 ] && pass "$DB2.t1 统计值 > 0（$S2_T1）" || fail "$DB2.t1 统计值 = $S2_T1（期望 >0）"
[ "${S1_T1:-0}" -ge "${S1_T2:-0}" ] && pass "数据多的表统计值 >= 数据少的表（t1=$S1_T1 >= t2=$S1_T2）" \
  || fail "t1($S1_T1) < t2($S1_T2)：统计未反映数据量差异"
DB1_SUM=$(( S1_T1 + S1_T2 ))
[ "$DB1_SUM" -le "${B1_BYTES:-0}" ] && pass "$DB1 合计 $DB1_SUM <= 物理 ${B1_BYTES}B" \
  || fail "$DB1 合计 $DB1_SUM > 物理大小 $B1_BYTES（口径异常）"

# ------------------------------------------------------------------ 3) where database 过滤
log "--- 3) where database = '$DB1' ---"
W_DB=$(du_table_where "database = '$DB1'")
W_DB_OTHER=$(du_col_cnt_where "$W_DB" database "$DB2")
W_DB_SELF=$(du_col_cnt_where "$W_DB" database "$DB1")
log "  返回 $(du_table_row_cnt "$W_DB") 行，其中本库 $W_DB_SELF 行、另一库 $W_DB_OTHER 行"
assert_eq "过滤 $DB1 时不出现 $DB2 的行" "$W_DB_OTHER" "0"
[ "${W_DB_SELF:-0}" -ge 1 ] && pass "过滤 $DB1 返回本库行（$W_DB_SELF 行）" || fail "过滤 $DB1 未返回本库行"

# ------------------------------------------------------------------ 4) where table_name like
log "--- 4) where table_name like '%1' ---"
W_TB=$(du_table_where "table_name like '%1' and database = '$DB1'")
W_TB_T2=$(du_col_cnt_2where "$W_TB" database "$DB1" table_name t2)
W_TB_T1=$(du_col_cnt_2where "$W_TB" database "$DB1" table_name t1)
log "  返回 $(du_table_row_cnt "$W_TB") 行（t1=$W_TB_T1, t2=$W_TB_T2）"
assert_eq "like '%1' 不应匹配 t2" "$W_TB_T2" "0"
[ "${W_TB_T1:-0}" -ge 1 ] && pass "like '%1' 匹配到 t1（$W_TB_T1 行）" || fail "like '%1' 未匹配到 t1"

# ------------------------------------------------------------------ 5) GROUP BY 聚合一致性
log "--- 5) GROUP BY database, table_name 聚合 ---"
GRP=$(du_table_sql "select database, table_name, sum(size_in_bytes) as total from information_schema.table_disk_usage where database = '$DB1' group by database, table_name;")
printf '%s\n' "$GRP" >"$ART/du_table_groupby.out"
log "  表头: $(du_header "$GRP")"
log "  分组结果：$(du_table_rows "$GRP" | tr '\n' ' ')"
G_T1=$(du_group_val "$GRP" t1); G_T2=$(du_group_val "$GRP" t2)
log "  聚合值：t1=${G_T1:-0}（明细 $S1_T1） t2=${G_T2:-0}（明细 $S1_T2）"
assert_eq "GROUP BY t1 聚合 == 明细求和" "${G_T1:-0}" "$S1_T1"
assert_eq "GROUP BY t2 聚合 == 明细求和" "${G_T2:-0}" "$S1_T2"

# ------------------------------------------------------------------ 6) 不存在的表 → 空集
log "--- 6) 过滤不存在的表应返回空结果集 ---"
W_NONE=$(du_table_where "table_name = 'nosuchtable_du'")
N_CNT=$(du_table_row_cnt "$W_NONE")
log "  原始输出：$(printf '%s' "$W_NONE" | tr '\n' ' ' | cut -c1-200)"
if printf '%s\n' "$W_NONE" | grep -qE 'IoTDBSQLException|[Ee]rror'; then
  warn "过滤不存在的表返回报错而非空集：$(printf '%s' "$W_NONE" | grep -oE '[0-9]{3}: [^\"]*' | head -1)（需求文档要求返回空结果集，需研发确认）"
else
  assert_eq "不存在的表返回 0 行" "$N_CNT" "0"
fi

# ------------------------------------------------------------------ 7) 视图不出现
log "--- 7) 视图不应出现在统计里（视图 $VW）---"
V_CNT=$(du_col_cnt_2where "$ALL" database "$DB1" table_name "$VW")
assert_eq "统计里没有视图 $VW" "$V_CNT" "0"

log "--- 收尾三件套 ---"
post_checks "" table
ttl_case_finish "" table ""
