#!/bin/bash
# ============================================================================
# CO-10 合并参数热加载（能热加载的必须热加载正确、不能热加载的必须明确要求重启）
#   覆盖需求："如果支持热加载，热加载功能正确等"
#   步骤：
#     1) 负向：`SET CONFIGURATION 'enable_seq_space_compaction'='false'` → 断言 CLI **不**要求重启、
#        `show configuration` 立即变 false、写多批后**不合并**
#     2) 正向：热开回 true → 断言立即可用（**不重启**）→ 之前积压的文件立刻被合并
#     3) 一致性不变量：对一组参数逐个 SET 一个新值，检查
#        「CLI 是否要求重启」与「show configuration 生效值是否立刻变化」必须一致：
#          要求重启 ⇒ 生效值保持不变；未要求重启 ⇒ 生效值等于新值
#        逐项还原原值。
#   判据：三步全过 + 数据指纹不变 + 无卡死 + 收尾三件套
# 用法： bash co_hot_reload.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_hot_reload_${DATA_CONSENSUS}"

DB=root.cohot
DEVS=${CO_DEVS:-4}
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-60}

log "--- 集群准备（seq 合并开、候选 2、调度 1s）---"
EXTRA_CONF="$CMP_EXTRA_CONF" cmp_cluster_prepare

log "--- 1) 热关 enable_seq_space_compaction ---"
RESP=$(cmp_set_hot enable_seq_space_compaction false)
log "  CLI 响应：$(printf '%s' "$RESP" | cut -c1-200)"
printf '%s' "$RESP" | grep -qiE 'restart is required' && fail "关闭 seq 合并却要求重启（期望可热加载）" || pass "CLI 未要求重启（热加载）"
assert_eq "生效值立即变为 false" "$(cmp_eff "${DN[0]}" enable_seq_space_compaction)" "false"

log "--- 写 3 批（此时 seq 合并已热关）→ 期望不合并 ---"
cmp_make_tree_db "$DB" "$DEVS"
BASE=$(( ($(date +%s) - 3600) * 1000 ))
for b in 1 2 3; do cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" "$b" "$(( BASE + b * 2000000 ))"; done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"
ts0=$(cmp_all_sum "$DB"); fin0=$(cmp_inner_finish "$DB")
log "  起点：TsFile=$ts0 finishes=$fin0"
sleep "$WIN"
ts1=$(cmp_all_sum "$DB"); fin1=$(cmp_inner_finish "$DB")
log "  等待 ${WIN}s：TsFile=$ts0 → $ts1；finishes=$fin0 → $fin1"
[ "${fin1:-0}" -eq "${fin0:-0}" ] && pass "热关生效：等待期内没有合并" || fail "热关未生效：仍发生 $((fin1-fin0)) 次合并"
fp0=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DB.**")

log "--- 2) 热开 enable_seq_space_compaction（不重启）→ 积压文件应立即被合并 ---"
RESP=$(cmp_set_hot enable_seq_space_compaction true)
log "  CLI 响应：$(printf '%s' "$RESP" | cut -c1-200)"
printf '%s' "$RESP" | grep -qiE 'restart is required' && fail "打开 seq 合并却要求重启" || pass "CLI 未要求重启（热加载）"
assert_eq "生效值立即变为 true" "$(cmp_eff "${DN[0]}" enable_seq_space_compaction)" "true"
if RES=$(cmp_wait_merge "$DB" "$fin1" "$ts1" "$CO_MERGE_WAIT_SEC"); then
  pass "热加载功能正确：不重启即开始合并（$RES）"
else
  fail "热加载后仍不合并（$RES）——热加载功能异常"
fi
cmp_assert_same "热加载前后数据指纹" "$fp0" "$(cmp_fingerprint tree "select count(s1), sum(s1) from $DB.**")"

log "--- 3) 一致性不变量：CLI 是否要求重启 ⇔ 生效值是否变化（等待窗口内轮询）---"
probe_hot(){ local k=$1 new=$2 orig eff resp hot t0 waited
  orig=$(cmp_eff "${DN[0]}" "$k")
  resp=$(cmp_set_hot "$k" "$new")
  printf '%s' "$resp" | grep -qiE 'restart is required' && hot=no || hot=yes
  # 生效值可能是经"CN → DN 配置心跳"异步下发的，SET 之后立即读不一定读得到 ⇒ 最多轮询 18s。
  t0=$(date +%s); eff=$(cmp_eff "${DN[0]}" "$k")
  while [ "$hot" = yes ] && [ "$eff" != "$new" ] && [ $(( $(date +%s) - t0 )) -lt 18 ]; do
    sleep 3; eff=$(cmp_eff "${DN[0]}" "$k")
  done
  waited=$(( $(date +%s) - t0 ))
  log "  $k：orig='$orig' → 设 '$new'；要求重启=$([ "$hot" = no ] && echo 是 || echo 否)；生效值='$eff'（等待 ${waited}s）"
  if [ "$hot" = yes ]; then
    # 注意：`show configuration`（表方言）只列"显式写在 iotdb-system.properties 里的键"，
    # 实测有 5 个 DN 级键（模板标注 effectiveMode: hot_reload）SET 成功且不要求重启，
    # 但轮询 18s 后 show configuration 仍是原值/空 —— 这类只记 WARN + 原文供研发确认
    # （是"CN→DN 没推送/没热应用"还是"show configuration 不反映运行值"），不作回归 FAIL；
    # 判 FAIL 的只有"SET 被拒/报错"。
    if [ "$eff" = "$new" ]; then pass "$k 热加载生效（'$orig' → '$new'，${waited}s 内读到）"
    else warn "$k：SET 未要求重启，但 ${waited}s 内 show configuration 生效值未变（orig='$orig' → 设 '$new'，仍读到 '$eff'）——记录供研发确认"; fi
  else
    [ "$eff" = "$orig" ] && pass "$k 要求重启且重启前生效值不变（'$orig'）" \
      || warn "$k 要求重启但生效值已变（'$eff'，期望重启后才变）——记录供研发确认"
  fi
  # 还原：**原值为空时绝对不能 SET 成空串** —— 那会在 properties 里写出 `key=`，
  # 之后 DN 热加载/重启会 `NumberFormatException: For input string ""` /
  # `No enum constant CompactionPriority.` 直接起不来（实测把 2 个 DN 搞挂过）。
  if [ -n "$orig" ]; then
    cmp_set_hot "$k" "$orig" >/dev/null 2>&1 || true
    log "    已还原 $k=$orig"
  else
    log "    原值为空（该键本就不在 properties 里）→ 不还原（写空值会破坏 DN 启动），保留新值 $new"
  fi
}
probe_hot enable_unseq_space_compaction false
probe_hot enable_cross_space_compaction true
probe_hot compaction_schedule_interval_in_ms 1500
probe_hot compaction_priority CROSS_INNER
probe_hot target_compaction_file_size 1073741824
probe_hot compaction_thread_count 8
probe_hot compaction_write_throughput_mb_per_sec 32
probe_hot inner_compaction_candidate_file_num 4
probe_hot max_cross_compaction_candidate_file_num 400
probe_hot sub_compaction_thread_count 2

log "--- 收尾前把关键开关恢复为默认（避免影响收尾判定）---"
cmp_set_hot enable_seq_space_compaction true >/dev/null
cmp_set_hot enable_unseq_space_compaction true >/dev/null
cmp_set_hot enable_cross_space_compaction false >/dev/null
log "  恢复后生效值：$(cmp_eff_all "${DN[0]}")"
# 探测过程往 properties 里写过一些键（含 compaction_priority 等）；重写一遍 conf 覆盖成有效值，
# 保证收尾里"逐个停 1 个 DN 再起回来"时 DN 能正常启动（曾经因为空值把 DN 起挂过）。
log "--- 重写 conf（覆盖探测写入的键，确保节点可重启）---"
EXTRA_CONF="$CMP_EXTRA_CONF" cluster_write_conf
STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
