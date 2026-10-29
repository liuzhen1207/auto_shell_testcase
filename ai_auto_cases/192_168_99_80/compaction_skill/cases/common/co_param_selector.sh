#!/bin/bash
# ============================================================================
# CO-16 合并参数**组合测试**（二）：selector × performer 组合、chunk 组合、非法值门禁
#   CO-15 覆盖"开关矩阵 + 优先级 + 极端值"，本用例覆盖"实现类选择"这一类组合：
#
#   段 1（inner seq：selector × performer = 4 组合，全热改）
#       selector ∈ {size_tiered_single_target, size_tiered_multi_target}
#       performer ∈ {read_chunk, fast}
#       每个组合：写 2 批 seq（2 个文件/region）→ 开 seq 合并 → 断言合并推进 + 数据指纹不变
#   段 2（inner unseq：selector × performer = 4 组合，全热改）
#       写 2 批更早的乱序批次 → 同理
#   段 3（cross performer ∈ {read_point, fast}，配 min_cross_compaction_unseq_file_level=0）
#       同一份 seq+unseq 数据 → 断言 cross 推进 + **重叠区间的取值正确**（指纹不变）
#   段 4（chunk 组合，需重启）：target_chunk_size=4096、target_chunk_point_num=10、
#       chunk_size_lower_bound_in_compaction=8192、chunk_point_num_lower_bound_in_compaction=1000、
#       chunk_metadata_size_proportion=0.9 —— 这组"小目标 chunk + 大反序列化门槛"会让合并走
#       "把 chunk 反序列化成点再写"的路径；断言合并仍完成、数据一致、无异常
#   段 5（非法值门禁，只做 SET 探针 + 立刻重写 conf，绝不带非法值重启）：
#       `compaction_priority=BOGUS` / `inner_seq_selector=bogus` / `compaction_thread_count=abc`
#       —— 记录 CLI 原始响应：被拒绝（报错）为 PASS；若"成功"则 WARN 并确认 conf 被重写回合法值
#       （空值/非法值留在 properties 里会把 DN 起挂，见 CO-10 事故）
# 用法： bash co_param_selector.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_param_selector_${DATA_CONSENSUS}"

DB=root.cosel
DEVS=3
ROWS=100
WIN=${CO_COMBO_WIN:-20}

co16_write(){ local db=$1 b=$2 base=$3 d k vals
  for ((d=1; d<=DEVS; d++)); do
    vals=""
    for ((k=1;k<=ROWS;k++)); do
      vals="$vals($(( base + k * 10 )),$(( k + b ))),"
      if [ $(( k % 500 )) -eq 0 ]; then sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null; vals=""; fi
    done
    [ -n "$vals" ] && sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null
  done
  sq "flush;" >/dev/null; }
# 写入前把三类合并全关（否则上一轮开着的合并在写入期间就把文件并掉，基线之后不再推进 ⇒ 假 FAIL）
co16_gates_off(){ cmp_set_hot enable_seq_space_compaction false >/dev/null
  cmp_set_hot enable_unseq_space_compaction false >/dev/null
  cmp_set_hot enable_cross_space_compaction false >/dev/null; }
co16_scene_seq(){   # 2 批 seq（2 文件/region）
  local db=$1 now=$2
  cmp_make_tree_db "$db" "$DEVS" >/dev/null
  co16_write "$db" 1 "$now"; co16_write "$db" 2 "$(( now + 5000 ))"
  ensure_closed "$db" 2 10 || warn "$db 有 DN 的 TsFile 未落盘"; }
co16_scene_unseq(){ # 水位 seq + 2 批**互相重叠**的更早数据（落 unseq；unseq 内部合并要求文件时间区间重叠）
  local db=$1 now=$2
  cmp_make_tree_db "$db" "$DEVS" >/dev/null
  co16_write "$db" 1 "$now"
  co16_write "$db" 2 "$(( now - 20000 ))"
  co16_write "$db" 3 "$(( now - 19500 ))"
  ensure_closed "$db" 2 10 || warn "$db 有 DN 的 TsFile 未落盘"; }
co16_scene_both(){ # 水位 seq ×2 + 1 批与之**重叠**的更早数据（unseq）→ 标准 cross 场景
  local db=$1 now=$2
  cmp_make_tree_db "$db" "$DEVS" >/dev/null
  co16_write "$db" 1 "$now"; co16_write "$db" 2 "$(( now + 5000 ))"
  co16_write "$db" 3 "$(( now - 500 ))"
  ensure_closed "$db" 2 10 || warn "$db 有 DN 的 TsFile 未落盘"; }

log "--- 集群准备（三类合并先关，单独热开被测的那一类；cross 最小层级 0）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},min_cross_compaction_unseq_file_level=0" cmp_cluster_prepare
NOW=$(now_ms)

log "--- 段 1：inner seq selector × performer（热改，4 组合）---"
i=0
for sel in size_tiered_single_target size_tiered_multi_target; do for perf in read_chunk fast; do
  i=$(( i + 1 )); DBX="$DB""_s$i"
  co16_gates_off
  co16_scene_seq "$DBX" "$NOW"
  s0=$(cmp_seq_inner_finish "$DBX"); ts0=$(cmp_all_sum "$DBX")
  fp0=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBX.**")
  cmp_set_hot inner_seq_selector "$sel" >/dev/null
  cmp_set_hot inner_seq_performer "$perf" >/dev/null
  log "  [$sel/$perf] 生效值：selector=$(cmp_eff "${DN[0]}" inner_seq_selector) performer=$(cmp_eff "${DN[0]}" inner_seq_performer)"
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  deadline=$(( $(date +%s) + 60 )); ok=0
  while (( $(date +%s) < deadline )); do
    s1=$(cmp_seq_inner_finish "$DBX"); [ "${s1:-0}" -gt "${s0:-0}" ] && { ok=1; break; }; sleep 3
  done
  [ "$ok" = 1 ] && pass "  [$sel/$perf] seq 合并推进（finishes $s0 → $s1，TsFile $ts0 → $(cmp_all_sum "$DBX")）" \
    || fail "  [$sel/$perf] seq 合并未推进（finishes $s0 → $s1）"
  cmp_assert_same "  [$sel/$perf] 合并前后数据指纹" "$fp0" "$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBX.**")"
done; done

log "--- 段 2：inner unseq selector × performer（热改，4 组合）---"
i=0
for sel in size_tiered_single_target size_tiered_multi_target; do for perf in read_point fast; do
  i=$(( i + 1 )); DBX="$DB""_u$i"
  co16_gates_off
  co16_scene_unseq "$DBX" "$NOW"
  cmp_set_hot enable_unseq_space_compaction false >/dev/null
  u0=$(cmp_unseq_inner_finish "$DBX")
  fp0=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBX.**")
  cmp_set_hot inner_unseq_selector "$sel" >/dev/null
  cmp_set_hot inner_unseq_performer "$perf" >/dev/null
  log "  [$sel/$perf] 生效值：selector=$(cmp_eff "${DN[0]}" inner_unseq_selector) performer=$(cmp_eff "${DN[0]}" inner_unseq_performer)"
  cmp_set_hot enable_unseq_space_compaction true >/dev/null
  deadline=$(( $(date +%s) + 60 )); ok=0
  while (( $(date +%s) < deadline )); do
    u1=$(cmp_unseq_inner_finish "$DBX"); [ "${u1:-0}" -gt "${u0:-0}" ] && { ok=1; break; }; sleep 3
  done
  [ "$ok" = 1 ] && pass "  [$sel/$perf] unseq 合并推进（finishes $u0 → $u1）" || fail "  [$sel/$perf] unseq 合并未推进（finishes $u0 → $u1）"
  cmp_assert_same "  [$sel/$perf] 合并前后数据指纹" "$fp0" "$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBX.**")"
done; done

log "--- 段 3：cross performer ∈ {read_point, fast}（热改）---"
i=0
for perf in read_point fast; do
  i=$(( i + 1 )); DBX="$DB""_c$i"
  co16_gates_off
  co16_scene_both "$DBX" "$NOW"
  cmp_set_hot enable_cross_space_compaction false >/dev/null
  c0=$(cmp_cross_finish "$DBX"); u0=$(cmp_unseq_sum "$DBX"); ts0=$(cmp_all_sum "$DBX")
  fp0=$(cmp_fingerprint tree "select s1 from $DBX.d1 order by time;")
  cnt0=$(row_sum "$(sq "select count(s1) from $DBX.**;")")
  cmp_set_hot cross_performer "$perf" >/dev/null
  log "  [cross_performer=$perf] 生效值=$(cmp_eff "${DN[0]}" cross_performer)"
  cmp_set_hot enable_cross_space_compaction true >/dev/null
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  cmp_set_hot enable_unseq_space_compaction true >/dev/null
  deadline=$(( $(date +%s) + 60 )); ok=0
  while (( $(date +%s) < deadline )); do
    c1=$(cmp_cross_finish "$DBX"); [ "${c1:-0}" -gt "${c0:-0}" ] && { ok=1; break; }; sleep 3
  done
  [ "$ok" = 1 ] && pass "  [cross_performer=$perf] cross 合并推进（finishes $c0 → $c1，unseq $u0 → $(cmp_unseq_sum "$DBX")）" \
    || fail "  [cross_performer=$perf] cross 合并未推进（finishes $c0 → $c1）"
  cmp_assert_same "  [cross_performer=$perf] 合并前后 d1 全序列（重叠区间取值）" "$fp0" "$(cmp_fingerprint tree "select s1 from $DBX.d1 order by time;")"
  assert_eq "  [cross_performer=$perf] 合并前后总行数" "$(row_sum "$(sq "select count(s1) from $DBX.**;")")" "$cnt0"
done

log "--- 段 4：chunk 组合（需重启：小目标 chunk + 大反序列化门槛）---"
CHUNK="target_chunk_size=4096,target_chunk_point_num=10,chunk_size_lower_bound_in_compaction=8192,chunk_point_num_lower_bound_in_compaction=1000,chunk_metadata_size_proportion=0.9"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},min_cross_compaction_unseq_file_level=0,$CHUNK" cmp_cluster_prepare
for kv in $(printf '%s' "$CHUNK" | tr ',' ' '); do
  k=${kv%%=*}; want=${kv#*=}; got=$(cmp_eff "${DN[0]}" "$k")
  [ "$got" = "$want" ] && pass "  chunk 组合生效：$k=$got" || warn "  $k 生效值='$got'（期望 $want）—— 记录"
done
DBK="$DB""_chunk"
co16_gates_off
co16_scene_seq "$DBK" "$NOW"
s0=$(cmp_seq_inner_finish "$DBK"); fp0=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBK.**")
C0=$(row_sum "$(sq "select count(s1) from $DBK.**;")")
cmp_set_hot enable_seq_space_compaction true >/dev/null
deadline=$(( $(date +%s) + 90 )); ok=0
while (( $(date +%s) < deadline )); do
  s1=$(cmp_seq_inner_finish "$DBK"); [ "${s1:-0}" -gt "${s0:-0}" ] && { ok=1; break; }; sleep 3
done
[ "$ok" = 1 ] && pass "  chunk 组合下合并推进（finishes $s0 → $s1）" || fail "  chunk 组合下合并未推进（finishes $s0 → $s1）"
cmp_assert_same "  chunk 组合下数据指纹不变" "$fp0" "$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBK.**")"
assert_eq "  chunk 组合下总行数不变" "$(row_sum "$(sq "select count(s1) from $DBK.**;")")" "$C0"

log "--- 段 5：非法值门禁（**SET 不做取值校验是研发确认的设计行为**，本段只记录实际返回 + 强制自清理）---"
# 目的：① 把 CLI 原始返回打进日志（跨版本对比行为是否变化）；
#       ② 保证用例不留脏数据 —— 非法值会写进 properties 并让 DN 下次重启起不来（详见
#          docs/NOTE_set_configuration_value_validation.md：研发已确认，设计如此，不按缺陷跟踪）。
# 本段会**故意**触发产品侧的非法值处理路径（热加载报错、旧行被注释掉的 properties 变更）：
# 这些异常是本用例自己制造的预期噪声，收尾日志扫描时按 benign 排除（否则用例会被自己的探针判 FAIL）。
export CMP_LOG_BENIGN_EXTRA='IllegalCompactionSelectorNameException|NumberFormatException|No enum constant|Fail to reload configuration'
# ⚠️ 实测结论：`SET CONFIGURATION` 对非法值（枚举名不存在 / 数值非数字）**返回成功并写进 properties**，
#    之后 DN 重启会 `No enum constant …` / `NumberFormatException` 直接起不来（本用例第一次跑就把 2 个 DN 搞挂）。
#    所以：① 每个探针记录原值 → 探针 → **立刻 SET 回原值（原值为空则写成模板默认的合法值）**；
#          ② 段末再逐节点 grep 校验，确保 properties 里没有残留非法值。
for kv in "compaction_priority=BOGUS:INNER_CROSS" "inner_seq_selector=bogus:size_tiered_multi_target" "compaction_thread_count=abc:10" "inner_compaction_candidate_file_num=-5:30"; do
  rest=${kv##*:}; kv2=${kv%:*}; k=${kv2%%=*}; bad=${kv2#*=}
  orig=$(cmp_eff "${DN[0]}" "$k")
  resp=$(cmp_set_hot "$k" "$bad")
  short=$(printf '%s' "$resp" | tr '\n' ' ' | cut -c1-200)
  log "  SET $k=$bad → $short"
  if printf '%s' "$resp" | grep -qiE 'error|exception|invalid|cannot|failed'; then
    pass "  非法值被拒绝：$k=$bad（按预期快速失败）"
  else
    warn "  非法值未被拒绝：$k=$bad —— **研发已确认：SET CONFIGURATION 设计上不校验取值**（见 docs/NOTE_set_configuration_value_validation.md）"
  fi
  # 立刻覆盖回合法值（原值为空时用模板默认值，绝不写空值）
  if [ -n "$orig" ] && [ "$orig" != "$bad" ]; then cmp_set_hot "$k" "$orig" >/dev/null 2>&1 || true; log "    已恢复 $k=$orig"
  else cmp_set_hot "$k" "$rest" >/dev/null 2>&1 || true; log "    已写回合法值 $k=$rest"; fi
done
BAD_LEFT=""
for h in $(printf '%s\n' "${DN[@]}" "${CN[@]}" | sort -u); do
  # 注意只看**未注释**的行：SET 覆盖旧值时会把旧行 `#` 注释掉再追加新行，
  # 注释里的历史非法值无害（第一版没排除注释 ⇒ 假 FAIL）
  n=$(sshx "$h" "grep -cE '^[a-z_]+=(BOGUS|bogus|abc|-5)\$' $DB_DIR/conf/iotdb-system.properties 2>/dev/null" 2>/dev/null | tr -dc '0-9')
  [ "${n:-0}" -gt 0 ] && BAD_LEFT="$BAD_LEFT $h($n)"
done
if [ -z "$BAD_LEFT" ]; then
  pass "  段末校验：properties 里没有残留非法值（不会把 DN 起挂）"
else
  fail "  properties 里仍有非法值，收尾会重启 DN ⇒ 立刻重写 conf：$BAD_LEFT"
fi
log "  重写 conf 覆盖探针写入的键（双保险）"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},min_cross_compaction_unseq_file_level=0" cluster_write_conf
log "  重写后：$(cmp_eff_all "${DN[0]}")"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DBK.d1 order by time;" tree
cmp_case_finish "" tree ""
