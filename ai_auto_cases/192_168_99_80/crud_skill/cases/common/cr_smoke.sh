#!/bin/bash
# ============================================================================
# CR-01 冒烟：树模型 seq 内部合并 + 读数一致性（CRUD 专项 skill 的骨架门禁）
#   来源：按"合并专项 skill"的 cases/tree/co_tree_inner_smoke.sh 照搬改写
#         （CRUD skill 的 harness 就是复制它来的；本用例保证 harness 端到端可用）。
#   语义：多批 flush 造出多个 TsFile → 热开合并 → 文件数下降 + 指纹一致 + 收尾三件套。
#   库名：root.crsmoke（CRUD 约定：库名一律 root.cr…，不与其它 skill / 长回归互相干扰）
#   判据：
#     1) 起点 TsFile ≥ 2（否则场景无效——硬断言，不许静默跳过）
#     2) 窗口内出现 `InnerSpaceCompaction task finishes successfully` 且该库 TsFile 数下降（双信号）
#     3) 合并前后数据指纹完全一致（count/sum/min/max + 单设备全序列）
#     4) 无线程卡在 TsFileResource.writeLock
#     5) 收尾三件套：sync lag 归零 / 逐个停 DN 副本一致 / 日志无 NPE/越界/OOM/overlap 等 ERROR
# 用法： bash cases/common/cr_smoke.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 骨架阶段**未实跑**（99.80 上正在跑合并长回归，禁止启停集群）；只保证 selftest 与 bash -n 通过。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_smoke_${DATA_CONSENSUS}"

DB=root.crsmoke
DEVS=${CO_DEVS:-6}
ROWS=${CO_ROWS:-300}
BATCHES=${CO_BATCHES:-3}
WIN=${CO_WIN_SEC:-90}

log "--- 集群准备（CRUD 冒烟；合并参数：$CMP_EXTRA_CONF）---"
EXTRA_CONF="$CMP_EXTRA_CONF" cmp_cluster_prepare
log "  实际生效：$(cmp_eff_all "${DN[0]}")"
cmp_compaction_off   # 写入阶段先关三类合并：保证"写完 → 开合并 → 观察"的确定性（否则合并会在写入期间就发生）

log "--- 造数据：$DB（$DEVS 设备 × $ROWS 点 × $BATCHES 批 → 每批一个 TsFile）---"
cmp_make_tree_db "$DB" "$DEVS"
for b in $(seq 1 "$BATCHES"); do cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" "$b"; done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"

ts0=$(cmp_all_sum "$DB"); fin0=$(cmp_inner_finish "$DB"); stuck0=$(cmp_stuck_sum)
log "  起点：TsFile=$ts0（$(cmp_per_node cmp_seq_cnt "$DB" | tr -d '\n')）inner finishes=$fin0 卡死线程=$stuck0"
log "  TsFile 清单（${DN[0]}）：$(cmp_tsfile_list "${DN[0]}" "$DB" | tr '\n' ' ')"
[ "$ts0" -ge 2 ] && pass "起点 TsFile=$ts0（≥2，具备合并条件）" || fail "场景无效：起点 TsFile=$ts0（<2）"

fp0=$(cmp_fp_tree "$DB")
fpd0=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
log "  合并前指纹：$fp0"

log "--- 打开 seq 合并并等合并（窗口 ${WIN}s）---"
cmp_compaction_on true true false
if RES=$(cmp_wait_merge "$DB" "$fin0" "$ts0" "$WIN"); then
  pass "合并已推进：$RES"
else
  fail "合并未推进（$RES，窗口 ${WIN}s）——基本功能异常"
fi

ts1=$(cmp_all_sum "$DB"); fin1=$(cmp_inner_finish "$DB")
log "  结果：TsFile $ts0 → $ts1；inner finishes $fin0 → $fin1"
[ "$fin1" -gt "$fin0" ] && pass "出现 InnerSpaceCompaction 完成记录（+$((fin1-fin0))）" || fail "无合并完成记录"
[ "$ts1" -lt "$ts0" ] && pass "TsFile 数下降（$ts0 → $ts1）" || fail "TsFile 数未下降（$ts0）"
cmp_assert_same "合并前后 count/sum" "$fp0" "$(cmp_fp_tree "$DB")"
cmp_assert_same "合并前后 $DB.d1 全序列" "$fpd0" "$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")"

STUCK=$(cmp_stuck_sum)
log "  卡在 TsFileResource.writeLock 的线程数：$STUCK（-1 = 不可观测）"
cmp_assert_no_stuck "无合并线程卡死"
for h in "${DN[@]}"; do log "  $h 合并日志尾部：$(cmp_log_tail "$h" "$DB" | tr '\n' ' ' | cut -c1-240)"; done

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
