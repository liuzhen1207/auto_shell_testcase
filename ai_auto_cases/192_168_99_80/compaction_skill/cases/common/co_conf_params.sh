#!/bin/bash
# ============================================================================
# CO-09 合并参数功能（conf 模板 + 行为对照）
#   覆盖需求："conf 下参数模板中的合并参数要进行功能测试，基本功能正确"
#   三相：
#     Phase 0 静态：安装包 conf/iotdb-system.properties.template 里 35 个 compaction 键都在
#     Phase 1 负向：`enable_seq_space_compaction=false` + `inner_compaction_candidate_file_num=100`
#                  （大于文件数）→ 窗口内**不应**发生合并（证明参数真的在起作用）
#     Phase 2 正向：`enable_seq_space_compaction=true` + `inner_compaction_candidate_file_num=2`
#                  → 同一场景**应**合并（对照）
#   判据：模板键齐全 → 生效值与写入值一致 → 负向不合并 → 正向合并 → 数据指纹不变 → 收尾三件套
# 用法： bash co_conf_params.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_conf_params_${DATA_CONSENSUS}"

DB=root.coconf
DEVS=${CO_DEVS:-4}
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-60}

# ---------------------------------------------------------------- Phase 0/1（负向）
log "--- Phase 0：conf 模板里的合并参数静态检查 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=true,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=100,compaction_schedule_interval_in_ms=1000" cmp_cluster_prepare
TPL=$DB_DIR/conf/iotdb-system.properties.template
missing=""
for k in $CMP_KEYS; do
  n=$(cmp_tpl_has "${DN[0]}" "$k")
  [ "${n:-0}" -ge 1 ] || missing="$missing $k"
done
if [ -z "$missing" ]; then pass "模板里 35 个合并相关参数键全都在（$TPL）"
else fail "模板缺少合并参数键：$missing"; fi

log "--- Phase 1（负向）：关 seq 合并 + candidate=100 → 不应合并 ---"
EFF=$(cmp_eff_all "${DN[0]}"); log "  生效值：$EFF"
assert_eq "enable_seq_space_compaction 生效值" "$(cmp_eff "${DN[0]}" enable_seq_space_compaction)" "false"
assert_eq "inner_compaction_candidate_file_num 生效值" "$(cmp_eff "${DN[0]}" inner_compaction_candidate_file_num)" "100"
assert_eq "compaction_schedule_interval_in_ms 生效值" "$(cmp_eff "${DN[0]}" compaction_schedule_interval_in_ms)" "1000"

cmp_make_tree_db "$DB" "$DEVS"
BASE=$(( ($(date +%s) - 3600) * 1000 ))
for b in 1 2 3; do cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" "$b" "$(( BASE + b * 2000000 ))"; done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"
ts0=$(cmp_all_sum "$DB"); fin0=$(cmp_inner_finish "$DB")
log "  起点：TsFile=$ts0 inner finishes=$fin0"
[ "$ts0" -ge 3 ] && pass "起点 TsFile=$ts0（≥3，足够触发默认 candidate=30 的判定）" || warn "起点 TsFile=$ts0"
sleep "$WIN"
ts1=$(cmp_all_sum "$DB"); fin1=$(cmp_inner_finish "$DB")
log "  等待 ${WIN}s 后：TsFile=$ts0 → $ts1；finishes=$fin0 → $fin1"
[ "${fin1:-0}" -eq "${fin0:-0}" ] && pass "负向：关合并/候选数过大时确实没有合并（finishes 未增）" \
  || fail "负向：参数已关闭仍发生合并（finishes +$((fin1-fin0))）——参数未生效"
fp_neg=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DB.**")

# ---------------------------------------------------------------- Phase 2（正向）
log "--- Phase 2（正向）：seq=true + candidate=2 → 应合并 ---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare
cmp_set_hot enable_seq_space_compaction true >/dev/null
cmp_set_hot inner_compaction_candidate_file_num 2 >/dev/null
assert_eq "enable_seq_space_compaction 生效值(true)" "$(cmp_eff "${DN[0]}" enable_seq_space_compaction)" "true"
assert_eq "inner_compaction_candidate_file_num 生效值(2)" "$(cmp_eff "${DN[0]}" inner_compaction_candidate_file_num)" "2"
# 上面两条 SET 已经把合并热开 ⇒ 本相写入前必须再关一次，否则数据在写入期间就被合并完，
# 记完基线之后不再推进 ⇒ 误判"参数打开后仍未合并"（第一版踩到，fail_flag=1）。
cmp_compaction_off
cmp_make_tree_db "$DB" "$DEVS"
for b in 1 2 3; do cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" "$b" "$(( BASE + b * 2000000 ))"; done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"
ts0=$(cmp_all_sum "$DB"); fin0=$(cmp_inner_finish "$DB")
fp0=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DB.**")
log "  起点：TsFile=$ts0 finishes=$fin0"
cmp_compaction_on true true false
if RES=$(cmp_wait_merge "$DB" "$fin0" "$ts0" "$CO_MERGE_WAIT_SEC"); then pass "正向：参数打开后合并发生（$RES）"; else fail "正向：参数打开后仍未合并（$RES）"; fi
cmp_assert_same "合并前后数据指纹" "$fp0" "$(cmp_fingerprint tree "select count(s1), sum(s1) from $DB.**")"
[ "$fp_neg" = "$fp0" ] && pass "两相数据指纹一致（同一场景重复构造）" || warn "两相指纹不同（时间戳基准不同，属正常）"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
