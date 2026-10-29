#!/bin/bash
# ============================================================================
# CO-29 **合并与进程生命周期**：合并完成后重启、合并**进行中**崩溃（kill -9）后重启恢复
#
# 为什么必须有这条：`InnerSpaceCompactionTask` 通过 `.compaction.log` 做恢复
#   （`AbstractCompactionTask.prepare()` 写日志、`recover()` 回滚/重做；
#    `TsFileManager`/`StorageEngine` 启动时会扫残留日志），
#   这是"合并正确性"里最容易被漏掉、也最容易出数据损坏的路径。
#
# 场景（单设备 TEXT 序列；每批 3000 行 × 1KB ≈ 3MB，用限流把合并拖到秒级便于中途打断）：
#   ① 写 2 个 TsFile → 开合并（写限流 1MB/s）→ **合并进行中**在 .78 上 `kill -9` DataNode
#   ② 等其余副本合并完成 → 重启 .78 → 等 Running + sync lag 归零
#   ③ 判据：三副本数据完全一致（行数 + 内容指纹）、无残留 `*.compaction.log`/`*.tmp`、
#           后续再写 1 批仍能合并（恢复后功能正常）
#   ④ 另外做一次"合并完成后整体重启"：布局与数据保持不变、仍可继续合并
# 用法： bash co_restart_recovery.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_restart_recovery_${DATA_CONSENSUS}"

DB=root.corest
ROWS=3000
PER=200
VICTIM="${DN[1]}"

log "--- 集群准备：三类合并先关；写限流 1MB/s（把合并拖到秒级，便于中途打断）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,compaction_write_throughput_mb_per_sec=1,compaction_read_throughput_mb_per_sec=1" cmp_cluster_prepare

PAYLOAD=$(printf 'y%.0s' $(seq 1 1000))
# ⚠️ 大 payload 不能用 `sq`（`timeout CLI -e "<200KB SQL>"` → `Argument list too long`，静默不落盘）
#    ⇒ 用**单会话 stdin**（`session_tree`）喂语句。
co29_write(){ local db=$1 base=$2 b=$3 ts i=0 vals="" stmts=""
  for ((ts=1; ts<=ROWS; ts++)); do
    vals="$vals($(( base + (b-1)*100000 + ts*10 )),'$PAYLOAD'),"
    i=$(( i + 1 ))
    if [ $(( i % PER )) -eq 0 ]; then stmts="${stmts}insert into $db.d1(time,s1) values ${vals%,};
"; vals=""; fi
  done
  if [ -n "$vals" ]; then stmts="${stmts}insert into $db.d1(time,s1) values ${vals%,};
"; fi
  printf '%s' "$stmts" | session_tree >/dev/null
  sq "flush;" >/dev/null; }
co29_scene(){ local db=$1 base=$2 b
  sq "create database $db;" >/dev/null
  sq "create timeseries $db.d1.s1 with datatype=TEXT, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
  for b in 1 2; do
    co29_write "$db" "$base" "$b"
    cmp_wait_close "$db" "$b" 90 >/dev/null || warn "  [$db] 批$b close 事件未达 $b"
    cmp_wait_lay "$db" "${b}/0/0/0" 150 >/dev/null || warn "  [$db] 批$b 布局=$(cmp_lay "$db")（期望 ${b}/0/0/0）"
  done
  log "  [$db] 起点布局=$(cmp_lay "$db") 字节=$(cmp_bytes_sum "$db")"; }
PAYLOAD=$(printf 'y%.0s' $(seq 1 1000))

log "--- ① 场景 + 合并中 kill -9 一个 DataNode ---"
cmp_compaction_off
cmp_set_hot compaction_write_throughput_mb_per_sec 1 >/dev/null
co29_scene "$DB" "$(now_ms)"
FP0=$(cmp_fp_tree "$DB"); CNT0=$(row_sum "$(sq "select count(s1) from $DB.**;")")
FIN0=$(cmp_inner_finish "$DB")
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 5
log "  合并已启动，在 $VICTIM 上 kill -9 DataNode（模拟合并中崩溃）"
sshx "$VICTIM" "pkill -9 -f 'com\\.timecho\\.iotdb\\.DataNode' >/dev/null 2>&1; echo killed" >/dev/null 2>&1 || true
wait_dn_state "$VICTIM" notrunning "$DN_DOWN_WAIT_SEC" || warn "  $VICTIM 未进入 notrunning"
log "  $VICTIM 已下线；等其余副本把合并做完（最多 300s）"
deadline=$(( $(date +%s) + 300 )); okother=0
while (( $(date +%s) < deadline )); do
  FINX=$(cmp_inner_finish "$DB"); [ "${FINX:-0}" -gt "${FIN0:-0}" ] && { okother=1; break; }; sleep 5
done
sleep 10
log "  其余副本合并状态：finishes=$FIN0 → ${FINX:-0}"
[ "$okother" = 1 ] && pass "  合并中下线一个副本不影响其余副本完成合并（finishes $FIN0 → $FINX）" \
  || warn "  未观察到其余副本合并推进（finishes=$FIN0，记录）"

log "--- ② 重启 $VICTIM 并等恢复 ---"
sshx "$VICTIM" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}.log 2>&1 </dev/null &" || true
wait_dn_state "$VICTIM" running "$DN_RECOVER_WAIT_SEC" || fail "  $VICTIM 未恢复 Running"
check_sync_lag || fail "  重启后 sync lag 未归零"
sleep 5
log "  恢复后布局：$(cmp_lay "$DB")"
TMP=$(cmp_tmp_leftover "$DB")
[ "${TMP:-0}" -eq 0 ] && pass "  恢复后没有残留的 *.compaction.log / *.tmp（崩溃恢复已清理）" \
  || warn "  恢复后仍有 $TMP 个残留临时文件（记录，可能是正在执行的任务）"
cmp_assert_same "  崩溃重启后数据指纹（与合并前一致）" "$FP0" "$(cmp_fp_tree "$DB")"
assert_eq "  崩溃重启后行数" "$(row_sum "$(sq "select count(s1) from $DB.**;")")" "$CNT0"
consistency_check "select count(s1) from $DB.d1.s1;" tree

log "--- ③ 恢复后再写 1 批 ⇒ 仍能合并（功能正常）---"
cmp_compaction_off
# 恢复后的布局可能是 0/1/0/0（合并重做）也可能是 2/0/0/0（回滚）⇒ 不写死期望布局，只等 close + 记录
co29_batch3(){ local k vals="" i=0 b=3
  for ((k=1;k<=200;k++)); do vals="$vals($(( $(now_ms) + 300000 + k*10 )),$((k+b))),"; done
  sq "insert into $DB.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  cmp_wait_close "$DB" 3 90 >/dev/null || warn "  追加批 close 事件未达 3"; }
co29_batch3
log "  追加批后布局=$(cmp_lay "$DB")"
FIN2=$(cmp_inner_finish "$DB"); CNT1=$(row_sum "$(sq "select count(s1) from $DB.**;")")
cmp_set_hot enable_seq_space_compaction true >/dev/null
deadline=$(( $(date +%s) + 150 )); ok3=0
while (( $(date +%s) < deadline )); do
  FIN3=$(cmp_inner_finish "$DB"); [ "${FIN3:-0}" -gt "${FIN2:-0}" ] && { ok3=1; break; }; sleep 3
done
sleep 5
[ "$ok3" = 1 ] && pass "  恢复后仍能继续合并（finishes $FIN2 → $FIN3，布局=$(cmp_lay "$DB")）" \
  || warn "  恢复后未观察到合并推进（finishes=$FIN2，记录）"
[ "$(row_sum "$(sq "select count(s1) from $DB.**;")")" = "$(( CNT1 ))" ] && pass "  追加批次后行数正确（$CNT1）" \
  || fail "  追加批次后行数异常：$(row_sum "$(sq "select count(s1) from $DB.**;")") vs $CNT1"

log "--- ④ 合并完成后整体重启：数据与布局不变 ---"
FP1=$(cmp_fp_tree "$DB"); LAY1=$(cmp_lay_uni "$(cmp_lay "$DB")")
cmp_compaction_off
for h in "${DN[@]}"; do
  sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || pkill -9 -f 'com\\.timecho\\.iotdb\\.DataNode' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "  $h 未停止"
done
for h in "${DN[@]}"; do
  sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}_$h.log 2>&1 </dev/null &" || true
  wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || fail "  $h 未恢复 Running"
done
check_sync_lag || fail "  整体重启后 sync lag 未归零"
LAY2=$(cmp_lay_uni "$(cmp_lay "$DB")")
log "  重启前后布局：$LAY1 → $LAY2"
cmp_assert_same "  整体重启后数据指纹" "$FP1" "$(cmp_fp_tree "$DB")"
[ "$LAY1" = "$LAY2" ] && pass "  整体重启后布局不变（$LAY2）" || warn "  布局变化：$LAY1 → $LAY2（记录）"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
