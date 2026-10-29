#!/bin/bash
# ============================================================================
# CO-22 `candidate_compaction_task_queue_size` 基础功能：候选队列**极小**时也不能丢任务/丢数据
#
# 源码依据（RC6 `7ae8713e`）：
#   `CompactionTaskManager`（L76-78）：候选队列 = `CompactionTaskQueue(candidate_compaction_task_queue_size, comparator)`
#     · `addTaskToWaitingQueue()`（L266-277）：队列满时按优先级**淘汰**最低优先级任务
#       （`FixedPriorityBlockingQueue` 的 poll-last 钩子 → `resetCompactionCandidateStatusForAllSourceFiles` + `handleTaskCleanup`）；
#     · `shouldSelectCrossSpaceCompactionTask()`（L247-253）：`5*(max-size) >= size`，
#       队列占用超过 1/6 就不选 cross 任务 ⇒ 小队列会把 cross 选择推迟。
#   ⇒ 小队列是"任务被丢弃/延后"的高压场景：**必须最终都能合并完、数据不丢、不卡死**。
#
# 场景：4 个 seq L0（inner 候选）+ 2 个与 seq 重叠的更早 unseq（cross 候选），`compaction_thread_count=1`
#   · A 相：`candidate_compaction_task_queue_size=1`
#   · B 相：重启成 64（该键只在初始化时读，属于"重启生效"）⇒ 同样场景对照
#   判据：两相都 unseq 归零、布局收敛、指纹不变、`jstack` 无写锁卡死；耗时/任务数只记录（不判死）。
# 用法： bash co_task_queue.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_task_queue_${DATA_CONSENSUS}"

DB=root.coqueue

co22_scene(){ local db=$1 base b k vals
  cmp_compaction_off
  cmp_mkdb1 "$db"; base=$(now_ms)
  # ⚠️ 批次时间戳互不重叠（间隔 100s、每批仅跨 2s）：否则后一批落进 unseq ⇒ 布局每批 +2（首轮踩到）
  for b in 1 2 3 4; do
    vals=""; for ((k=1;k<=200;k++)); do vals="$vals($(( base + 100000 + b*100000 + k*10 )),$((k+b))),"; done
    sq "insert into $db.d1(time,s1) values ${vals%,};" >/dev/null
    sq "flush;" >/dev/null
    cmp_wait_close "$db" "$b" 90 >/dev/null || warn "  [$db] seq 批$b close 未达 $b"
    cmp_wait_lay "$db" "${b}/0/0/0" 120 >/dev/null || warn "  [$db] seq 批$b 布局=$(cmp_lay "$db")"
  done
  # 2 批乱序：落在第 1 个 seq 文件区间内（与 seq 重叠 ⇒ 重写式 cross），互相重叠
  for b in 1 2; do
    vals=""; for ((k=1;k<=200;k++)); do vals="$vals($(( base + 100500 + b*200 + k*10 + 3 )),$((k+b))),"; done
    sq "insert into $db.d1(time,s1) values ${vals%,};" >/dev/null
    sq "flush;" >/dev/null
    cmp_wait_close "$db" "$(( 4 + b ))" 90 >/dev/null || warn "  [$db] unseq 批$b close 未达 $(( 4 + b ))"
    cmp_wait_su "$db" "4/$b" 150 >/dev/null && log "  [$db] unseq 第 $b 个文件就绪：$(cmp_su "$db")"
  done
  log "  [$db] 场景：$(cmp_su "$db")（期望各副本 4 seq + 2 unseq，共 6 个候选文件）"; }

co22_run(){ local tag=$1 db
  db="${DB}${tag}"
  co22_scene "$db"
  local fp0 t0 t1 dl ok=0 f0 f1
  fp0=$(cmp_fp_tree "$db"); t0=$(date +%s); f0=$(cmp_all_sum "$db")
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  cmp_set_hot enable_cross_space_compaction true >/dev/null
  dl=$(( $(date +%s) + 300 ))
  while (( $(date +%s) < dl )); do
    f1=$(cmp_all_sum "$db")
    [ "$(cmp_unseq_sum "$db")" = "0" ] && [ "$f1" -lt "$f0" ] && { ok=1; break; }
    sleep 5
  done
  t1=$(date +%s)
  local dist; dist=$(cmp_task_nums "$db" inner)
  local stuck; stuck=$(cmp_stuck_sum)
  log "  [$tag] 终态：布局=$(cmp_lay "$db") $(cmp_su "$db") 文件 $f0→$(cmp_all_sum "$db") 耗时=$(( t1 - t0 ))s inner 任务分布=$dist 写锁卡死线程=$stuck"
  # 判据只看"功能收敛"（unseq 归零 + 文件数下降）；具体层级分布取决于 cross 产物层级，不做硬性断言
  [ "$ok" = 1 ] && pass "  [$tag] 队列高压下合并完成（unseq 归零、TsFile 数 $f0 → $(cmp_all_sum "$db")）" \
    || fail "  [$tag] 未收敛：布局=$(cmp_lay "$db") $(cmp_su "$db") unseq=$(cmp_unseq_sum "$db")"
  cmp_assert_no_stuck "[$tag] 无卡在 TsFileResource.writeLock 的合并线程"
  cmp_assert_same "  [$tag] 合并前后数据指纹" "$fp0" "$(cmp_fp_tree "$db")"
  RUN_SECS=$(( t1 - t0 )); }

log "--- A 相：候选队列 = 1（队列极小的压力场景，1 个合并线程）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,min_cross_compaction_unseq_file_level=0,compaction_thread_count=1,candidate_compaction_task_queue_size=1" cmp_cluster_prepare
assert_eq "  生效值 candidate_compaction_task_queue_size" "$(cmp_eff "${DN[0]}" candidate_compaction_task_queue_size)" "1"
co22_run a; TA=$RUN_SECS

log "--- B 相：重启成候选队列 = 64 对照 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,min_cross_compaction_unseq_file_level=0,compaction_thread_count=1,candidate_compaction_task_queue_size=64" cmp_cluster_prepare
assert_eq "  生效值 candidate_compaction_task_queue_size" "$(cmp_eff "${DN[0]}" candidate_compaction_task_queue_size)" "64"
co22_run b; TB=$RUN_SECS
log "  队列大小对照：queue=1 耗时 ${TA}s；queue=64 耗时 ${TB}s（只记录，不判死）"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from ${DB}b.**;" tree
cmp_case_finish "" tree ""
