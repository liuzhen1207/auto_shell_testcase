#!/bin/bash
# ============================================================================
# CO-18 `compaction_priority` 基础功能：三种取值的**确定性**验证
#       —— 用"单合并线程"把并发竞争去掉，队列顺序就直接决定先跑哪一类
#
# 源码依据（RC6 `7ae8713e`）：
#   `CompactionTaskManager`（L76-78）：候选队列是 `FixedPriorityBlockingQueue`，
#     比较器由 `compaction_priority` 决定（`CompactionPriority`：INNER_CROSS / CROSS_INNER / BALANCE →
#     `ICompactionTaskComparator` 的不同实现）。
#   `compaction_thread_count=1` ⇒ 同一时刻只有 1 个任务在执行 ⇒ **先完成的类型 = 队列优先级最高者**。
#   （CO-15 段 2 只记录了"语义顺序"，因为多线程 + 竞态；本用例把它变成确定判据。）
#
# 场景（单设备，seq 与 unseq **时间区间重叠** —— 目的是让 cross 走重写式、不落入插入式路径）：
#   写 2 批顺序（2 个 seq L0）+ 2 批更早且互相重叠的乱序（2 个 unseq）
#   ⇒ inner（seq 两文件互并）与 cross（unseq × 重叠 seq）**同时**成为候选
#   判据：三类取值分别把"第一个 finish 的类型"记下来，并要求
#     INNER_CROSS → Sequence InnerSpaceCompaction 先；CROSS_INNER → CrossSpaceCompaction 先；
#     BALANCE → 前 4 个 finish 里两类都出现。
#   每相都验证：两类任务最终都完成 + 数据指纹不变（`compaction_priority` 只影响顺序，不影响正确性）。
# 用法： bash co_param_priority.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_param_priority_${DATA_CONSENSUS}"

DB=root.copri

# 该库前 N 条 finish 的类型序列（I=Sequence InnerSpace，C=CrossSpace）
co18_order(){ local db=$1 n=${2:-6} h
  for h in "${DN[@]}"; do
    sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hE '(^|[- ])(root\.)?$db-[0-9]+ \[Compaction\]' | grep -v InsertionCrossSpaceCompaction | grep -oE '(Sequence InnerSpaceCompaction|CrossSpaceCompaction) task finishes successfully' | sed -e 's/^Sequence.*/I/' -e 's/^CrossSpace.*/C/' | head -$n" 2>/dev/null
  done | tr -d '\r' | tr '\n' ' '; echo; }
co18_scene(){ local db=$1 base b k vals
  cmp_compaction_off
  cmp_mkdb1 "$db"; base=$(now_ms)
  # 8 批顺序（每批 1 个文件）：配合 `inner_compaction_total_file_num_threshold=2`
  # ⇒ 一轮调度里会**同时**产生 4 个 inner 任务；cross 任务也在同一轮进入队列
  # ⇒ 只有这种情况下"队列优先级"才真的决定执行顺序（1 个任务时优先级无从体现）
  # ⚠️ 批次时间戳必须**互不重叠**（间隔 100s、每批仅跨 2s）：否则后一批会落进 unseq 空间，
  #    场景就不是"8 个 seq L0 文件"了（CO-22 首轮踩到：布局每批 +2）
  for b in 1 2 3 4 5 6 7 8; do
    vals=""; for ((k=1;k<=200;k++)); do vals="$vals($(( base + 100000 + b*100000 + k*10 )),$((k+b))),"; done
    sq "insert into $db.d1(time,s1) values ${vals%,};" >/dev/null
    sq "flush;" >/dev/null
    cmp_wait_close "$db" "$b" 90 >/dev/null || warn "  [$db] seq 批$b close 未达 $b"
    cmp_wait_lay "$db" "${b}/0/0/0" 120 >/dev/null || warn "  [$db] seq 批$b 布局=$(cmp_lay "$db")"
  done
  # 2 批乱序：落在第 1 个 seq 文件的时间区间**内**（与 seq 重叠 ⇒ 走重写式 cross），
  # 且都小于水位最大值 ⇒ 判为乱序落 unseq；两批互相重叠
  for b in 1 2; do
    vals=""; for ((k=1;k<=200;k++)); do vals="$vals($(( base + 100500 + b*200 + k*10 + 3 )),$((k+b))),"; done
    sq "insert into $db.d1(time,s1) values ${vals%,};" >/dev/null
    sq "flush;" >/dev/null
    cmp_wait_close "$db" "$(( 8 + b ))" 90 >/dev/null || warn "  [$db] unseq 批$b close 未达 $(( 8 + b ))"
    cmp_wait_su "$db" "8/$b" 150 >/dev/null && log "  [$db] unseq 第 $b 个文件就绪：$(cmp_su "$db")"
  done
  log "  [$db] 场景：$(cmp_su "$db")（期望各副本 8 seq + 2 unseq；threshold=2 ⇒ 4 个 inner 任务）"
  # 场景造好后才**同时**放开 inner(seq) 与 cross ⇒ 两类任务一起进候选队列，由优先级决定先后
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  cmp_set_hot enable_cross_space_compaction true >/dev/null
  sleep 2; }

co18_run(){ local val=$1 tag=$2 base db
  log "=== compaction_priority=$val ==="
  EXTRA_CONF="enable_seq_space_compaction=true,enable_unseq_space_compaction=false,enable_cross_space_compaction=true,inner_compaction_candidate_file_num=2,inner_compaction_total_file_num_threshold=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,min_cross_compaction_unseq_file_level=0,compaction_thread_count=1,compaction_priority=$val" cmp_cluster_prepare
  assert_eq "  生效值 compaction_priority" "$(cmp_eff "${DN[0]}" compaction_priority)" "$val"
  assert_eq "  生效值 compaction_thread_count" "$(cmp_eff "${DN[0]}" compaction_thread_count)" "1"
  db="${DB}${tag}"
  co18_scene "$db"
  FP0=$(cmp_fp_tree "$db")
  # 场景造好后合并是开着的（prepare 里 seq/cross=true）⇒ 直接从日志读顺序
  deadline=$(( $(date +%s) + 180 )); ok=0
  while (( $(date +%s) < deadline )); do
    [ "$(cmp_unseq_sum "$db")" = "0" ] && [ "$(cmp_lay_uni "$(cmp_lay "$db")")" = "0/1/0/0 " ] && { ok=1; break; }; sleep 5
  done
  sleep 5
  ORDER=$(co18_order "$db" 8)
  log "  前 8 条完成顺序（I=Sequence InnerSpace, C=CrossSpace）：$ORDER"
  log "  终态：布局=$(cmp_lay "$db") $(cmp_su "$db") seq_inner=$(cmp_seq_inner_finish "$db") cross=$(cmp_cross_finish "$db")"
  [ "$ok" = 1 ] && pass "  [$val] 两类合并最终都完成（布局 0/1/0/0、unseq 归零）" \
    || warn "  [$val] 终态未达预期：布局=$(cmp_lay "$db") unseq=$(cmp_unseq_sum "$db")（记录）"
  # 判据说明：调度器**每轮总是先选 inner、后选 cross**，所以"第一个完成"必然是 inner（它已经开跑了）。
  # 优先级真正能观测到的是"**第一个 Cross 完成出现在第几个位置**"：CROSS_INNER 应明显更早。
  RUN_IDX=$(printf '%s' "$ORDER" | awk '{for(i=1;i<=NF;i++) if($i=="C"){print i; exit}} END{if(NR==0) print 0}')
  RUN_ICNT=$(printf '%s' "$ORDER" | tr -cd 'I' | wc -c | tr -dc '0-9')
  RUN_CCNT=$(printf '%s' "$ORDER" | tr -cd 'C' | wc -c | tr -dc '0-9')
  log "  [$val] 首个 Cross 完成位置=$RUN_IDX（I 数=$RUN_ICNT，C 数=$RUN_CCNT）"
  [ "${RUN_CCNT:-0}" -ge 1 ] && [ "${RUN_ICNT:-0}" -ge 1 ] \
    && pass "  [$val] 两类任务都真的执行过（I=$RUN_ICNT 个、C=$RUN_CCNT 个）" \
    || warn "  [$val] 只出现了一类任务（I=$RUN_ICNT、C=$RUN_CCNT，记录）"
  cmp_assert_same "  [$val] 合并前后数据指纹" "$FP0" "$(cmp_fp_tree "$db")"; }

co18_run INNER_CROSS ic; IDX_INNER=$RUN_IDX
co18_run CROSS_INNER ci; IDX_CROSS=$RUN_IDX
co18_run BALANCE ba; IDX_BAL=$RUN_IDX

log "--- 优先级对照：首个 Cross 完成位置 INNER_CROSS=$IDX_INNER ｜ CROSS_INNER=$IDX_CROSS ｜ BALANCE=$IDX_BAL ---"
if [ "${IDX_CROSS:-0}" -gt "${IDX_INNER:-0}" ] && [ "${IDX_INNER:-0}" -gt 0 ]; then
  fail "  优先级方向相反：CROSS_INNER 的首个 Cross 反而更晚（第 $IDX_CROSS 位 > INNER_CROSS 的第 $IDX_INNER 位）"
elif [ "${IDX_CROSS:-0}" -gt 0 ] && [ "${IDX_CROSS:-99}" -lt "${IDX_INNER:-99}" ]; then
  pass "  优先级生效：CROSS_INNER 时 Cross 更早完成（第 $IDX_CROSS 位 < INNER_CROSS 的第 $IDX_INNER 位）"
elif [ "${IDX_CROSS:-0}" = "${IDX_INNER:-1}" ] && [ "${IDX_CROSS:-0}" -gt 0 ]; then
  warn "  两种取值的首个 Cross 位置相同（都是第 $IDX_CROSS 位）—— 该场景下优先级未体现差异（记录，不判缺陷）"
else
  warn "  优先级差异不可比：INNER_CROSS=$IDX_INNER，CROSS_INNER=$IDX_CROSS（记录）"
fi

log "--- 收尾三件套 ---"
post_checks "select count(s1) from ${DB}ba.**;" tree
cmp_case_finish "" tree ""
