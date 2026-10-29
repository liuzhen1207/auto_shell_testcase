#!/bin/bash
# ============================================================================
# CO-13 TTL 场景（树模型）：TTL 过期清理（settle 合并）与在线合并的组合
#   覆盖需求："也要有 TTL 场景"
#
#   场景编排（顺序很关键，来自源码语义，见下）：
#     ① 只写"过期设备"d1..d{DEVS}：时间戳 = 48 小时前
#     ② 设库 TTL=24h → 查询侧过滤（count=0）
#     ③ settle（TTL 触发的合并）把**整文件过期**的文件删掉（日志 + TsFile 数下降）
#     ④ 再写"新鲜设备"d{DEVS+1}..d{2*DEVS}：时间戳 = 当前，写 2 批
#        → 在线合并（seq 内部）在 TTL 生效状态下正常推进、指纹不变、过期数据不复活
#     ⑤ TTL 调到 30s → 新鲜数据（含**合并产物**）也被清理（count=0）
#     ⑥ UNSET TTL → count 仍为 0（已物理删除，合并没有复活）
#
#   ⚠️ 为什么必须"过期数据单独成文件"（前两版都栽在这里）：
#      `SettleSelectorImpl.selectFileBaseOnDirtyData()` L255~260 —— 对**设了 TTL**的文件，
#      只要文件里有**任何一个设备还有未过期数据**，整个文件直接 `NOT_SATISFIED`：
#          if (hasSetTTL) { if (!isDeleted) return NOT_SATISFIED; }
#      所以：
#        · 同一设备既写 48h 前的点又写当前点（且被内部合并进同一文件）⇒ 该设备 alive ⇒ 永不清理；
#        · 过期设备与新鲜设备的数据被内部合并进同一文件 ⇒ 同样永不清理（实测
#          `[TTL] … Totally select 0 all-outdated files and 0 partial-outdated files`）。
#      本用例因此**先写过期数据、等 settle 清完，再写新鲜数据**，两者不会同处一个文件。
#   ⚠️ 另：TTL 物理清理由 `enable_seq_space_compaction`/`enable_unseq_space_compaction` 门控
#      （`CompactionScheduler.tryToSubmitSettleCompactionTask` 开头就判），所以 seq 合并=true。
#
# 用法： bash co_ttl_settle.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_ttl_settle_${DATA_CONSENSUS}"

DB=root.cottl
DEVS=${CO_DEVS:-4}
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-90}
DAY_MS=$(( 24 * 3600 * 1000 ))
TTL_MS=${CO_TTL_MS:-$DAY_MS}           # 24h
TTL_SMALL_MS=${CO_TTL_SMALL_MS:-30000} # 30s
BATCH=$(( DEVS * ROWS ))
OLD_FIRST=1; OLD_LAST=$DEVS
NEW_FIRST=$(( DEVS + 1 )); NEW_LAST=$(( DEVS * 2 ))
FP_DEV=$NEW_FIRST

settle_any(){ local s=0 h n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -hc 'SettleCompaction task starts' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    if [ "${n:-0}" -eq 0 ]; then
      n=$(sshx "$h" "grep -hc 'SettleCompaction task starts' $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    fi
    s=$(( s + ${n:-0} ))
  done; echo "${s:-0}"; }
ts_all(){ row_sum "$(sq "select count(s1) from $DB.**;")"; }
# 写指定设备区间的一批数据：co13_write <d0> <d1> <batch> <base>
co13_write(){ local d0=$1 d1=$2 b=$3 base=$4 d k vals
  for ((d=d0; d<=d1; d++)); do
    vals=""
    for ((k=1;k<=ROWS;k++)); do
      vals="$vals($(( base + k * 10 )),$(( k + b ))),"
      if [ $(( k % 500 )) -eq 0 ]; then sq "insert into $DB.d$d(time,s1) values ${vals%,};" >/dev/null; vals=""; fi
    done
    [ -n "$vals" ] && sq "insert into $DB.d$d(time,s1) values ${vals%,};" >/dev/null
  done
  sq "flush;" >/dev/null; }

log "--- 集群准备（seq 合并=true 才做 TTL 物理清理；unseq/cross 关；TTL 检查 5s、ratio 极小）---"
# TTL 三个参数必须走环境变量（cluster_write_conf 用 env 值逐节点校验）
export TTL_CHECK_INTERVAL_MS=5000
export MAX_EXPIRED_TIME_MS=9223372036854775807
export EXPIRED_DATA_RATIO=0.000001
EXTRA_CONF="enable_seq_space_compaction=true,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}" cmp_cluster_prepare

log "--- 1) 先只写**过期设备** d$OLD_FIRST..d$OLD_LAST（48 小时前）---"
cmp_make_tree_db "$DB" "$NEW_LAST"
NOW=$(now_ms)
BASE_OLD=$(( NOW - 2 * DAY_MS ))
co13_write "$OLD_FIRST" "$OLD_LAST" 1 "$BASE_OLD"
ensure_closed "$DB" 3 25 || warn "$DB 过期批次未全部落盘"
C_BEFORE=$(ts_all); TS0=$(cmp_all_sum "$DB"); SET0=$(settle_any)
log "  设 TTL 前：count=$C_BEFORE（期望 $BATCH）TsFile=$TS0 settle=$SET0"
assert_eq "过期批次写入后可见（TTL 尚未设置）" "$C_BEFORE" "$BATCH"

log "--- 2) 设库级 TTL=${TTL_MS}ms（24h）→ 查询侧应全部不可见 ---"
out=$(sq "set ttl to $DB $TTL_MS;")
assert_contains "SET TTL 成功" "$out" "successfully"
sq "flush;" >/dev/null
sleep 12
assert_eq "TTL 生效后过期数据被查询过滤" "$(ts_all)" "0"

log "--- 3) 等 settle 合并物理清理过期文件（日志证据优先，TsFile 数下降为辅）---"
deadline=$(( $(date +%s) + CLEANUP_WAIT_SEC )); cleaned=0; cur_ts=$TS0; cur_set=$SET0
while (( $(date +%s) < deadline )); do
  cur_set=$(settle_any); cur_ts=$(cmp_all_sum "$DB")
  log "    等 settle：settle 任务=$SET0 → $cur_set；TsFile=$TS0 → $cur_ts"
  if [ "$cur_set" -gt "$SET0" ] || [ "$cur_ts" -lt "$TS0" ]; then cleaned=1; break; fi
  sleep 5
done
if [ "$cleaned" = 1 ]; then
  pass "TTL 触发的 settle 已动作：settle +$((cur_set-SET0))，TsFile $TS0 → $cur_ts"
else
  fail "等 ${CLEANUP_WAIT_SEC}s 未见 TTL 清理（settle +$((cur_set-SET0))，TsFile $TS0 → $cur_ts）"
fi
SET1=$cur_set; TS1=$cur_ts
for h in "${DN[@]}"; do log "  $h 日志尾部：$(sshx "$h" "grep -h '\[TTL\]\\|SettleCompaction' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -3" | tr '\n' ' ' | cut -c1-240)"; done

log "--- 4) 再写**新鲜设备** d$NEW_FIRST..d$NEW_LAST（当前时间，2 批）+ 在线合并 ---"
# 注意：时间戳必须是"过去但很近"（NOW-20s / NOW-10s）——写成 NOW+1000000 是**未来时间**，
# 未来数据永远不过期（now-ts<0<ttl），会让第 5 步"TTL=30s 后 count=0"永远不成立（第二版踩到）。
FIN_PRE=$(cmp_inner_finish "$DB")
co13_write "$NEW_FIRST" "$NEW_LAST" 2 "$(( NOW - 20000 ))"
co13_write "$NEW_FIRST" "$NEW_LAST" 3 "$(( NOW - 10000 ))"
ensure_closed "$DB" 3 25 || warn "$DB 新鲜批次未全部落盘"
FIN1=$(cmp_inner_finish "$DB"); TS2=$(cmp_all_sum "$DB"); C_MID=$(ts_all)
FP_PRE=$(cmp_fingerprint tree "select s1 from $DB.d$FP_DEV order by time;")
SUM_PRE=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
log "  新写 2 批后：count=$C_MID（期望 $(( BATCH * 2 ))，过期数据仍不可见）TsFile=$TS2 finishes=$FIN_PRE→$FIN1"
assert_eq "TTL 生效期间过期数据未复活" "$C_MID" "$(( BATCH * 2 ))"
# 合并可能在写入期间就完成了（candidate=2 很小）⇒ 先看"写入期间是否有推进"，再退回观察窗口
if [ "${FIN1:-0}" -gt "${FIN_PRE:-0}" ]; then
  pass "TTL 生效状态下在线合并已推进（写入期间 finishes $FIN_PRE → $FIN1）"
elif RES=$(cmp_wait_merge "$DB" "$FIN1" "$TS2" "$WIN"); then
  pass "TTL 生效状态下在线合并正常完成：$RES"
else
  fail "TTL 生效状态下合并未推进（$RES）"
fi
cmp_assert_same "合并前后新鲜设备 d$FP_DEV 全序列" "$FP_PRE" "$(cmp_fingerprint tree "select s1 from $DB.d$FP_DEV order by time;")"
assert_eq "合并前后新鲜数据 sum" "$SUM_PRE" "$(row_sum "$(sq "select sum(s1) from $DB.**;")")"

log "--- 5) 把 TTL 调到 ${TTL_SMALL_MS}ms（30s）→ 新鲜数据（含合并产物）也必须被清理 ---"
out=$(sq "set ttl to $DB $TTL_SMALL_MS;")
assert_contains "SET TTL(小值) 成功" "$out" "successfully"
sq "flush;" >/dev/null
sleep 20
assert_eq "合并产物同样被 TTL 过滤" "$(ts_all)" "0"
deadline=$(( $(date +%s) + CLEANUP_WAIT_SEC )); TS3=$(cmp_all_sum "$DB"); purged=0; cur_ts=$TS3; cur_set=$SET1
while (( $(date +%s) < deadline )); do
  cur_set=$(settle_any); cur_ts=$(cmp_all_sum "$DB")
  log "    等二轮 settle：settle=$SET1 → $cur_set；TsFile=$TS3 → $cur_ts"
  [ "$cur_ts" -lt "$TS3" ] && { purged=1; break; }
  sleep 5
done
if [ "$purged" = 1 ]; then pass "第二轮 settle 已清理合并产物：TsFile $TS3 → $cur_ts（settle +$((cur_set-SET1))）"
else warn "第二轮窗口内 TsFile 数未下降（$TS3 → $cur_ts），以第 6 步 UNSET 后的物理结果为准"; fi

log "--- 6) UNSET TTL → 不得复活（过期数据已物理删除）---"
out=$(sq "unset ttl from $DB;")
assert_contains "UNSET TTL 成功" "$out" "successfully"
sleep 5
C_FINAL=$(ts_all)
log "  UNSET 后 count=$C_FINAL（期望 0）；TsFile=$(cmp_all_sum "$DB")"
if [ "${C_FINAL:-0}" -le 0 ]; then
  pass "UNSET TTL 后无任何残留数据（过期数据已被物理删除，合并未复活）"
else
  fail "UNSET TTL 后仍有 $C_FINAL 行（期望 0：TTL 清理后应为空）"
fi

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"

log "--- 收尾三件套（本库已被 TTL 清空，一致性基准用原始查询）---"
# 注意别用 `count(s1) from db.dX.s1`：树方言里对"具体设备路径"做聚合会返回 Empty set（聚合被忽略）
post_checks "select s1 from $DB.d$FP_DEV.s1 order by time;" tree
cmp_case_finish "" tree ""
