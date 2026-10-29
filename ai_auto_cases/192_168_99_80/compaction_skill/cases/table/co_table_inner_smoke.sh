#!/bin/bash
# ============================================================================
# CO-02 冒烟：表模型 seq 内部合并（inner space compaction）
#   与 CO-01 同判据，走表模型接口（`create table`/`insert`/`select`）。
#   判据：起点 TsFile ≥2 → 窗口内合并完成且 TsFile 数下降 → 数据指纹完全一致 →
#         无卡死线程 → 收尾三件套（sync lag / 逐 DN 副本一致性 / 日志异常）。
# 用法： bash co_table_inner_smoke.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_table_inner_smoke_${DATA_CONSENSUS}"

DB=cosmoketb
T1=t1
DEVS=${CO_DEVS:-6}
ROWS=${CO_ROWS:-300}
BATCHES=${CO_BATCHES:-3}
WIN=${CO_WIN_SEC:-90}

log "--- 集群准备（合并参数：$CMP_EXTRA_CONF）---"
EXTRA_CONF="$CMP_EXTRA_CONF" cmp_cluster_prepare
log "  实际生效：$(cmp_eff_all "${DN[0]}")"
cmp_compaction_off   # 写入阶段先关三类合并（确定性）

log "--- 造数据：$DB.$T1（$DEVS 设备 × $ROWS 点 × $BATCHES 批）---"
cmp_make_table_db "$DB"
for b in $(seq 1 "$BATCHES"); do cmp_write_table_batch "$DB" "$T1" "$DEVS" "$ROWS" "$b"; done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"
CNT=$(sqt "select count(*) from $DB.$T1;" | table_rows | head -1 | awk -F'|' '{print ($2+0)}')
log "  写入校验：count=$CNT"
[ "${CNT:-0}" -gt 0 ] && pass "表模型数据已写入（count=$CNT）" || fail "场景无效：表模型数据未写入"

ts0=$(cmp_all_sum "$DB"); fin0=$(cmp_inner_finish "$DB"); stuck0=$(cmp_stuck_sum)
log "  起点：TsFile=$ts0（$(cmp_per_node cmp_seq_cnt "$DB" | tr -d '\n')）inner finishes=$fin0 卡死线程=$stuck0"
[ "$ts0" -ge 2 ] && pass "起点 TsFile=$ts0（≥2）" || fail "场景无效：起点 TsFile=$ts0（<2）"

fp0=$(cmp_fp_table "$DB.$T1")
fpd0=$(cmp_fingerprint table "select v from $DB.$T1 where dev = 'd1' order by time;")
log "  合并前指纹：$fp0"

log "--- 打开 seq 合并并等合并（窗口 ${WIN}s）---"
cmp_compaction_on true true false
if RES=$(cmp_wait_merge "$DB" "$fin0" "$ts0" "$WIN"); then pass "合并已推进：$RES"; else fail "合并未推进（$RES）——基本功能异常"; fi
ts1=$(cmp_all_sum "$DB"); fin1=$(cmp_inner_finish "$DB")
log "  结果：TsFile $ts0 → $ts1；inner finishes $fin0 → $fin1"
[ "$fin1" -gt "$fin0" ] && pass "出现 InnerSpaceCompaction 完成记录（+$((fin1-fin0))）" || fail "无合并完成记录"
[ "$ts1" -lt "$ts0" ] && pass "TsFile 数下降（$ts0 → $ts1）" || fail "TsFile 数未下降（$ts0）"
cmp_assert_same "合并前后 count/sum" "$fp0" "$(cmp_fp_table "$DB.$T1")"
cmp_assert_same "合并前后 dev=d1 全序列" "$fpd0" "$(cmp_fingerprint table "select v from $DB.$T1 where dev = 'd1' order by time;")"

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"
for h in "${DN[@]}"; do log "  $h 合并日志尾部：$(cmp_log_tail "$h" "$DB" | tr '\n' ' ' | cut -c1-240)"; done

log "--- 收尾三件套 ---"
post_checks "select count(*) from $DB.$T1;" table
cmp_case_finish "" table ""
