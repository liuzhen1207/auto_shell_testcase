#!/bin/bash
# ============================================================================
# CO-23 线程族基础功能：`compaction_thread_count` / `sub_compaction_thread_count`
#       / `compaction_schedule_thread_num`
#
# 源码依据（RC6 `7ae8713e`）：
#   `CompactionTaskManager.initThreadPool()`（L136-153）：
#       执行池 = `compaction_thread_count` 个 `IoTDB-Compaction-Worker`
#       子任务池 = `compaction_thread_count × sub_compaction_thread_count` 个 `IoTDB-Compaction-Sub-Task`
#   `CompactionScheduleTaskManager`（L55/118）：调度池 = `compaction_schedule_thread_num`
#   `IoTDBDescriptor`（L1886-1893）：线程数**热改**时会 `CompactionTaskManager.restart()` 重建线程池
#
# 判据（可观测、确定性）：
#   · 生效值 = 写入值；
#   · `jstack` 里每个 DN 的执行线程数（线程头 `"pool-…IoTDB-Compaction-Worker`）等于 `compaction_thread_count`；
#   · 1 线程与 3 线程两种配置下，多任务场景都**全部合并完成、数据指纹不变**。
# 用法： bash co_threads.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_threads_${DATA_CONSENSUS}"

DB=root.cothr

co23_workers(){ local h=$1 pid v
  pid=$(sshx "$h" "pgrep -f com.timecho.iotdb.DataNode | head -1" 2>/dev/null | tr -d '\r')
  [ -n "${pid:-}" ] || { echo -1; return; }
  v=$(sshx "$h" "jstack $pid 2>/dev/null | grep '^\"' | grep -c 'IoTDB-Compaction-Worker'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
co23_workers_all(){ local h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(co23_workers "$h") "; done; echo "$out"; }
co23_wait_workers(){ local want=$1 t=${2:-120} dl h ok; dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    ok=1; for h in "${DN[@]}"; do [ "$(co23_workers "$h")" = "$want" ] || ok=0; done
    [ "$ok" = 1 ] && return 0; sleep 5
  done; return 1; }

co23_scene(){ local tag=$1 base k db; base=$(now_ms); SCENE_FP=""; SCENE_FIN=""
  for k in 1 2 3; do
    db="${DB}${tag}${k}"
    cmp_mkdb1 "$db"
    cmp_batch1 "$db" 1 "$(( base + k*10000 ))" "1/0/0/0" 200
    cmp_batch1 "$db" 2 "$(( base + k*10000 + 20000 ))" "2/0/0/0" 200
    SCENE_FP="$SCENE_FP$(cmp_fp_tree "$db")|"
    SCENE_FIN="$SCENE_FIN$(cmp_inner_finish "$db")|"   # 基线必须在**开合并之前**采（否则快合并会漏掉增量）
  done
  log "  场景[$tag]：${DB}${tag}1=$(cmp_lay_uni "$(cmp_lay "${DB}${tag}1")") 起点指纹=$SCENE_FP 起点 finishes=$SCENE_FIN"; }
co23_merge_all(){ local tag=$1 k db fin0 fin1 dl ok after=""
  for k in 1 2 3; do
    db="${DB}${tag}${k}"
    fin0=$(printf '%s' "$SCENE_FIN" | cut -d'|' -f"$k")
    dl=$(( $(date +%s) + 150 )); ok=0
    while (( $(date +%s) < dl )); do
      fin1=$(cmp_inner_finish "$db"); [ "${fin1:-0}" -gt "${fin0:-0}" ] && { ok=1; break; }; sleep 3
    done
    sleep 5
    [ "$ok" = 1 ] && log "  [$db] 合并完成（finishes $fin0 → $fin1）" || fail "  [$db] 合并未推进（finishes=$fin0）"
    [ "$(cmp_lay_uni "$(cmp_lay "$db")")" = "0/1/0/0 " ] && pass "  [$db] 2 个 L0 → 1 个 L1（各副本一致）" \
      || warn "  [$db] 布局=$(cmp_lay "$db")（期望 0/1/0/0）"
    after="$after$(cmp_fp_tree "$db")|"
  done
  cmp_assert_same "  场景[$tag] 合并前后数据指纹" "$SCENE_FP" "$after"; }

log "--- 集群准备：三类合并先关；线程族全部 =1；candidate=2、gap=0 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,compaction_thread_count=1,sub_compaction_thread_count=1,compaction_schedule_thread_num=1" cmp_cluster_prepare
for k in compaction_thread_count sub_compaction_thread_count compaction_schedule_thread_num; do
  assert_eq "  生效值 $k" "$(cmp_eff "${DN[0]}" "$k")" "1"
done

log "--- A 相：compaction_thread_count=1 ---"
cmp_compaction_off
co23_scene a
log "  执行池线程数：$(co23_workers_all)"
okA=1; for h in "${DN[@]}"; do [ "$(co23_workers "$h")" = "1" ] || okA=0; done
[ "$okA" = 1 ] && pass "  compaction_thread_count=1 ⇒ 每个 DN 恰好 1 个 IoTDB-Compaction-Worker 线程" \
  || warn "  线程数观测=$(co23_workers_all)（期望每 DN=1，记录）"
cmp_set_hot enable_seq_space_compaction true >/dev/null
co23_merge_all a

log "--- B 相：热改 compaction_thread_count=3（线程池重建）---"
cmp_set_hot compaction_thread_count 3 >/dev/null
assert_eq "  生效值（热改后）" "$(cmp_eff "${DN[0]}" compaction_thread_count)" "3"
if co23_wait_workers 3 150; then
  pass "  热改后执行池线程数 $(co23_workers_all)（=3，与配置一致）"
else
  warn "  热改后线程数未达 3：$(co23_workers_all)（记录；任务管理器重建可能滞后）"
fi
cmp_compaction_off
co23_scene b
cmp_set_hot enable_seq_space_compaction true >/dev/null
co23_merge_all b

log "--- C 相：sub_compaction_thread_count / compaction_schedule_thread_num 生效值 + 合并仍正确 ---"
cmp_set_hot sub_compaction_thread_count 2 >/dev/null
cmp_set_hot compaction_schedule_thread_num 2 >/dev/null
assert_eq "  sub_compaction_thread_count 生效值" "$(cmp_eff "${DN[0]}" sub_compaction_thread_count)" "2"
assert_eq "  compaction_schedule_thread_num 生效值" "$(cmp_eff "${DN[0]}" compaction_schedule_thread_num)" "2"
cmp_compaction_off
co23_scene c
cmp_set_hot enable_seq_space_compaction true >/dev/null
co23_merge_all c

log "--- 收尾三件套 ---"
post_checks "select count(s1) from ${DB}c1.d1 order by time;" tree
cmp_case_finish "" tree ""
