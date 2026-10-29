#!/bin/bash
# ============================================================================
# CO-05 冒烟：DELETE 数据后合并（树模型 + 表模型）
#   目的：删除过的数据在合并后**不得复活**（历史上出过"合并把删除行带回来"的问题），
#         且带 mods 的文件能被正常合并。
#   做法：树/表各造一个库 → 写入 → DELETE 一半时间范围 → 等副本应用 → 再写一批
#         （让 mods 文件成为合并候选）→ 合并 → 断言合并前后查询指纹一致、删除行未复活、
#         合并完成、无卡死线程。
#   判据：删除后行数下降 → 合并完成且文件数下降 → 合并前后指纹一致（= 删除结果被保留）
#         → 收尾三件套。
# 用法： bash co_delete_data.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_delete_data_${DATA_CONSENSUS}"

DBT=root.codelete
DBB=codeletetb
DEVS=${CO_DEVS:-4}
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-120}
HALF=$(( ROWS / 2 ))

log "--- 集群准备（合并参数：$CMP_EXTRA_CONF）---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

# ------------------------------------------------------------------ 树模型
log "--- 树模型：$DBT ---"
cmp_make_tree_db "$DBT" "$DEVS"
BASE=$(( ($(date +%s) - 3600) * 1000 ))
cmp_write_tree_batch "$DBT" "$DEVS" "$ROWS" 1 "$BASE"
ensure_closed "$DBT" 3 25 || warn "$DBT 第 1 批未全部落盘"
CNT0=$(row_sum "$(sq "select count(s1) from $DBT.**;")")
log "  写入后总行数=$CNT0（$DEVS 设备 × $ROWS）"
# 删掉每设备前一半（时间严格小于 BASE + HALF*10）：
# 注意写入是从 k=0 开始（ts = BASE + k*10），所以用 `<=` 会多删一行 → 每设备剩 ROWS-HALF-1 行。
DEL_UNTIL=$(( BASE + HALF * 10 ))
sq "delete from $DBT.** where time < $DEL_UNTIL;" >/dev/null
sq "flush;" >/dev/null
WANT=$(( DEVS * (ROWS - HALF) ))
# 单设备行数必须用"原始查询 + 数行"：树方言里 `select count(s1) from db.d1.s1`（或 `db.d1.**`）
# 会返回 `|Time| Empty set.`（把聚合当原始查询，聚合被忽略，实测踩到），只有 `db.**` 通配才给聚合结果。
WANTD=$(( ROWS - HALF ))
d1_rows(){ printf '%s\n' "$(sq "select s1 from $DBT.d1 order by time;")" | table_rows | wc -l | tr -d ' '; }
deadline=$(( $(date +%s) + 120 )); d1n=$(d1_rows); d1ok=0
while (( $(date +%s) < deadline )); do
  d1n=$(d1_rows)
  [ "${d1n:-0}" = "$WANTD" ] && { d1ok=1; break; }
  sleep 3
done
[ "$d1ok" = 1 ] && pass "树模型删除后 d1 行数=$d1n（期望 $WANTD）" \
  || fail "树模型删除后 d1 行数: 实际=[$d1n] 期望=[$WANTD]（等 120s 仍未一致）"
CNT1=$(row_sum "$(sq "select count(s1) from $DBT.**;")")
log "  删除后总行数=$CNT1（期望 $WANT）"
[ "${CNT1:-0}" -lt "$CNT0" ] && pass "DELETE 生效：$CNT0 → $CNT1" || fail "DELETE 未生效（$CNT0 → $CNT1）"
[ "${CNT1:-0}" = "$WANT" ] && pass "删除后行数与期望一致（$WANT）" || fail "删除后行数 $CNT1 ≠ 期望 $WANT"
# 再写一批（不同时间区间），让带 mods 的文件进入合并候选
cmp_write_tree_batch "$DBT" "$DEVS" "$ROWS" 5 "$(( BASE + 2000000 ))"
ensure_closed "$DBT" 3 25 || warn "$DBT 第 2 批未全部落盘"
fp0=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBT.**")
fpd0=$(cmp_fingerprint tree "select s1 from $DBT.d1 order by time")
ts0=$(cmp_all_sum "$DBT"); fin0=$(cmp_inner_finish "$DBT")
CNT_PRE=$(row_sum "$(sq "select count(s1) from $DBT.**;")")
log "  合并前：TsFile=$ts0 finishes=$fin0 行数=$CNT_PRE"
cmp_compaction_on true true false
if RES=$(cmp_wait_merge "$DBT" "$fin0" "$ts0" "$WIN"); then pass "树模型带 mods 文件已合并：$RES"; else fail "树模型合并未推进（$RES）"; fi
cmp_assert_same "树模型合并前后指纹（删除行未复活）" "$fp0" "$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBT.**")"
cmp_assert_same "树模型合并前后 $DBT.d1 全序列" "$fpd0" "$(cmp_fingerprint tree "select s1 from $DBT.d1 order by time")"
CNT2=$(row_sum "$(sq "select count(s1) from $DBT.**;")")
# 注意：合并前**已经又写了一批**（第 2 批 1800 行），所以这里要比较"合并前 vs 合并后"的行数，
# 而不是"删除后 vs 合并后"（第一版这么写 ⇒ 永远是 894 → 2694 的假 FAIL）。
[ "${CNT2:-0}" = "${CNT_PRE:-0}" ] && pass "合并前后总行数不变（$CNT_PRE，删除结果被保留）" \
  || fail "合并前后行数变化：$CNT_PRE → $CNT2（删除行可能复活）"

# ------------------------------------------------------------------ 表模型
log "--- 表模型：$DBB ---"
# 上一相已经把合并热开了，这里必须先关掉：否则表模型这一批数据在写入期间就被合并完，
# 记完基线之后不会再有推进 ⇒ 误判"合并未推进"（第一版踩到）。
cmp_compaction_off
cmp_make_table_db "$DBB"
BASEB=$(( ($(date +%s) - 3600) * 1000 ))
cmp_write_table_batch "$DBB" t1 "$DEVS" "$ROWS" 1 "$BASEB"
ensure_closed "$DBB" 3 25 || warn "$DBB 第 1 批未全部落盘"
TCNT0=$(sqt "select count(*) from $DBB.t1;" | table_rows | head -1 | awk -F'|' '{print ($2+0)}')
DEL_UNTILB=$(( BASEB + HALF * 10 ))
sqt "delete from $DBB.t1 where time < $DEL_UNTILB;" >/dev/null
sqt "flush;" >/dev/null
TWANT=$(( DEVS * (ROWS - HALF) ))
wait_scalar_table "select count(*) from $DBB.t1;" "$TWANT" 120 "表模型删除后行数" || true
TCNT1=$(sqt "select count(*) from $DBB.t1;" | table_rows | head -1 | awk -F'|' '{print ($2+0)}')
log "  写入 $TCNT0 → 删除后 $TCNT1（期望 $TWANT）"
[ "${TCNT1:-0}" -lt "$TCNT0" ] && pass "表模型 DELETE 生效：$TCNT0 → $TCNT1" || fail "表模型 DELETE 未生效"
cmp_write_table_batch "$DBB" t1 "$DEVS" "$ROWS" 5 "$(( BASEB + 2000000 ))"
ensure_closed "$DBB" 3 25 || warn "$DBB 第 2 批未全部落盘"
tfp0=$(cmp_fingerprint table "select count(v), sum(v) from $DBB.t1;")
tfp_d0=$(cmp_fingerprint table "select v from $DBB.t1 where dev='d1' order by time;")
tts0=$(cmp_all_sum "$DBB"); tfin0=$(cmp_inner_finish "$DBB")
cmp_compaction_on true true false
if TRES=$(cmp_wait_merge "$DBB" "$tfin0" "$tts0" "$WIN"); then pass "表模型合并已推进：$TRES"; else fail "表模型合并未推进（$TRES）"; fi
cmp_assert_same "表模型合并前后指纹（删除行未复活）" "$tfp0" "$(cmp_fingerprint table "select count(v), sum(v) from $DBB.t1;")"
cmp_assert_same "表模型合并前后 dev=d1 全序列" "$tfp_d0" "$(cmp_fingerprint table "select v from $DBB.t1 where dev='d1' order by time;")"

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"

log "--- 收尾三件套（树模型 SQL 作为一致性基准）---"
post_checks "select count(s1) from $DBT.d1 order by time;" tree
cmp_case_finish "" tree ""
