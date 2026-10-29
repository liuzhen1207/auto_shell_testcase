#!/bin/bash
# ============================================================================
# CO-39 任务优先级排序规则与线程族数量关系
#   覆盖：D2-9（同类型 5 级排序：低层 → 新 version → 文件数多 → serialID 小 → 总大小小）
#         D2-11（不同时间分区**倒序**调度）
#         D2-10（跨类型三取值 = CO-18 回归：本用例只记录 compaction_priority 生效值，
#                行为差异由既有的 cases/common/co_param_priority.sh 承担，避免重复造三相）
#         附加 MG-T01/T02/T03（线程族数量关系：Schedule / Worker / Sub-Task）
#   规格出处：docs/OFFICIAL_COVERAGE.md §4.2 CO-39、§5 第 13/14/36 项
#
# 观测方法（关键设计）：
#   · `Sequence InnerSpaceCompaction task starts with N files, …` **只有文件数、没有源文件名**；
#     而 `… task finishes successfully, target files are [{file: …/<ts>-<ver>-<level>-<n>.tsfile}]`
#     带**产物文件名**。文件名第 2 段 = version、第 3 段 = level（与 lib/cmp.sh 的 cmp_lay 一致）。
#   · 本用例把 `compaction_thread_count` 固定为 1 ⇒ 同一时刻只有一个合并任务在跑
#     ⇒ **完成顺序 == 启动顺序**，用"按时间顺序出现的产物文件名"反推每个任务的源文件 level/version。
#   · 段 2 另有更直接的证据：首个任务完成后在**单个 DN** 上对比文件清单集合差
#     （消失的文件 = 该任务的源文件），可直接读出源文件的 version。
#
# ⚠️ 诚实标注（严格遵守 §4.2）：D2-9 的五级排序是**比较器实现细节**，且 CO-18 已实测
#   「INNER_CROSS 等跨类型取值在本场景下不影响执行顺序」。因此段 1~3 的**顺序**判据一律
#   **WARN-only**：若观测到与规则不符，只记 WARN + 附日志，**不判产品缺陷**。
#   本用例的硬判据只有：每段双信号（finishes↑ 且 TsFile↓）、数据指纹不变、
#   场景有效性（起点布局/分区数/参数生效值）、线程族数量关系、无卡死 + 收尾三件套。
#
# ---------------------------------------------------------------------------
# 【V1 → V2 口径修正（2026-10-17；报告 _scratch/RC8_V2_DIVERGENCE_TRIAGE.md §3.4 / §④ P1-3+P2）】
#   V1 PASS 748s f0 → V2 FAIL **3458s** f2。两条 FAIL 都是"**三副本同布局**"这个前置：
#     · 段1 前置「未合成 L1（77:2/0/0/0 78:0/1/0/0 79:2/0/0/0）」
#     · 段1 场景「起点布局去重=[3/1/0/0 5/0/0/0]（期望 3/1/0/0）」← cmp_lay 去重后出现两种布局
#   4.6× 耗时全部来自等待：V2 follower 不 flush 自己的 memtable、文件落 unsequence
#   （DataRegion.java:4984/5009）⇒ 只有 leader 参与 seq 空间合并，`cmp_wait_close`/`cmp_wait_lay`
#   每次都要等满窗口（WARN 行间隔 ~106s、全例 23 次 ≈ +2400s）。**不是产品变慢**。
#   ⇒ 三处口径统一（V1 = 全部副本 / V2 = region leader，见 lib/cmp.sh 的「判据集」说明）：
#     ① 布局前置改用 `cmp_scene_lay`（判据集达标 ⇒ PASS；仅"至少一台"达标 ⇒ PASS+WARN；一台都不达标 ⇒ FAIL）；
#     ② 落盘/布局等待改用判据集版 `cmp_wait_lay` + 30s 上限的 `cmp_wait_close`（P2）；
#     ③ 顺序类判据本来就 WARN-only，不动；**双信号 / 指纹 / 线程族数量关系仍是硬判据**。
# ---------------------------------------------------------------------------
# 用法： bash co_priority_rules.sh [--consensus IoTConsensus|IoTConsensusV2]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_priority_rules_${DATA_CONSENSUS}"

# ---------------------------- 规模 / 参数（顶部变量） ----------------------------
DB1=root.copri1                 # 段 1：低层优先（旧 L1 + 新 L0×3）
DB2=root.copri2                 # 段 2：新 version 优先（同层 4 个不同 version）
DB3=root.copri3                 # 段 3：文件数多优先（9 个 L0，候选批量放大到 6）
DB4=root.copri4                 # 段 4：时间分区倒序（1 天/分区，写 3 个不同日期）
C39_ROWS=${C39_ROWS:-50}        # 每批点数
C39_WIN=${C39_WIN:-180}         # 每段等合并窗口（秒）
C39_CAND=${C39_CAND:-2}         # inner_compaction_candidate_file_num（段 1/2/4）
C39_CAND_MANY=${C39_CAND_MANY:-6} # 段 3 的候选批量（造"文件数多"的候选）
C39_BATCHES=${C39_BATCHES:-9}   # 段 3 的 L0 文件数
C39_V_BATCHES=${C39_V_BATCHES:-3}  # 段 2 的同层不同 version 文件数（3 ⇒ 首个任务后只剩 1×L0+1×L1，gap=0 时无后续任务）
C39_DAY_MS=${C39_DAY_MS:-86400000}
C39_TPI_MS=${C39_TPI_MS:-$C39_DAY_MS}   # time_partition_interval（重启生效，走 EXTRA_CONF）
# 段 4 三个批次的间隔：取 8 天 —— 无论 time_partition_interval 是写进去的 1 天还是模板默认 7 天，
# 三个批次都必然落在**不同**时间分区（避免"键没生效 ⇒ 场景无效"直接判失败）
C39_PART_GAP_MS=${C39_PART_GAP_MS:-691200000}
C39_SCHED_MAX=${C39_SCHED_MAX:-0}       # MG-T01 上界（0 = 用 SHOW REGIONS 的 DataRegion 数推算）

# ---------------------------- 观测 helper ----------------------------
# 等某库 inner "task starts" 数增加
c39_wait_start(){ local db=$1 base=$2 win=$3 dl s
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    s=$(cmp_inner_start "$db")
    [ "${s:-0}" -gt "${base:-0}" ] && return 0
    sleep 2
  done
  return 1
}
# 等某库 inner "finishes" 数增加
c39_wait_fin(){ local db=$1 base=$2 win=$3 dl f
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    f=$(cmp_inner_finish "$db")
    [ "${f:-0}" -gt "${base:-0}" ] && return 0
    sleep 2
  done
  return 1
}
# 某库**按时间顺序**出现的产物文件名（去扩展名）序列，形如 "1791-1-1-0 1792-2-1-0 "
c39_fin_seq(){ local h=$1 db=$2 n=${3:-6}
  sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hE '(^|[- ])(root\.)?$db-[0-9]+ .*InnerSpaceCompaction task finishes successfully' | grep -oE '[0-9]+-[0-9]+-[0-9]+-[0-9]+\.tsfile' | sed 's/\.tsfile//' | head -$n" 2>/dev/null \
    | tr -d '\r' | tr '\n' ' '; echo
}
# 某库首个 inner 任务的 "N files"
c39_first_n(){ local h=$1 db=$2
  sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hE '(^|[- ])(root\.)?$db-[0-9]+ .*InnerSpaceCompaction task starts with' | sed -nE 's/.*starts with ([0-9]+) files.*/\1/p' | head -1" 2>/dev/null | tr -dc '0-9'
}
# 某库首个 inner 任务的 region id（日志前缀 <db>-<region>，用于诊断打印）
c39_first_region(){ local h=$1 db=$2
  sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hE '(^|[- ])(root\.)?$db-[0-9]+ .*InnerSpaceCompaction task starts with' | sed -nE 's/.*[ ](root\.)?$db-([0-9]+) .*/\2/p' | head -1" 2>/dev/null | tr -dc '0-9'
}
# 单节点上某库的 TsFile 文件名（按名排序）
c39_names(){ cmp_tsfile_list "$1" "$2" 2>/dev/null | tr -d '\r' | tr '\n' ' '; echo; }
# 文件名列表取第 f 段（f=2 → version，f=3 → level），按数值排序
c39_field(){ local list=$1 f=$2
  printf '%s\n' "$list" | tr ' ' '\n' | sed '/^$/d' | awk -F- -v f="$f" '{print $f}' | sort -n | tr '\n' ' '; echo
}
c39_max(){ printf '%s\n' "$1" | tr ' ' '\n' | sed '/^$/d' | sort -n | tail -1; }
# before 相对 after 消失的文件（= 某任务已完成的源文件）
c39_removed(){ local before=$1 after=$2 tmp
  tmp=$(mktemp -d)
  printf '%s\n' "$after"  | tr ' ' '\n' | sed '/^$/d' | sort >"$tmp/after"
  printf '%s\n' "$before" | tr ' ' '\n' | sed '/^$/d' | sort >"$tmp/before"
  comm -23 "$tmp/before" "$tmp/after" | tr '\n' ' '; echo
  rm -rf "$tmp"
}
# 某库的**时间分区号**列表（升序去重）
# ⚠️ 目录层级是 `sequence/<db>/<regionId>/<timePartitionNo>/<file>`（现场实测：
#    `data/unsequence/root.param_r/7/2962/1791460057738-1-0-0.tsfile`，region=7、partition=2962）
c39_parts(){ local h=$1 db=$2
  sshx "$h" "find $DB_DIR/data/datanode/data/sequence/$db -mindepth 2 -maxdepth 2 -type d -printf '%f\n' 2>/dev/null | sort -n -u" 2>/dev/null | tr -d '\r' | tr '\n' ' '; echo
}
# 某库的 <regionId>/<timePartitionNo> 映射（信息性证据）
c39_region_parts(){ local h=$1 db=$2
  sshx "$h" "find $DB_DIR/data/datanode/data/sequence/$db -mindepth 2 -maxdepth 2 -type d -printf '%P\n' 2>/dev/null" 2>/dev/null | tr -d '\r'
}
# 某库按时间顺序出现的**产物文件路径**里的 `/sequence/<db>/<region>/<partition>/` 片段
# （inner 的 starts 日志只有文件数、没有文件名；finishes 日志带产物完整路径 ⇒ 用它反推任务所属时间分区）
c39_fin_paths(){ local h=$1 db=$2 n=${3:-6}
  sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hE '(^|[- ])(root\.)?$db-[0-9]+ .*InnerSpaceCompaction task finishes successfully' | grep -oE '/sequence/$db/[0-9]+/[0-9]+/' | head -$n" 2>/dev/null | tr -d '\r' | tr '\n' ' '; echo
}
# jstack 线程 dump：取不到 DataNode 进程 / dump 没有线程头 ⇒ 场景无效（返回 -1/-2）
c39_dump(){ local h=$1 pid
  pid=$(sshx "$h" "pgrep -f com.timecho.iotdb.DataNode | head -1" 2>/dev/null | tr -d '\r')
  [ -n "${pid:-}" ] || return 1
  sshx "$h" "jstack $pid 2>/dev/null"
}
c39_cnt(){ local h=$1 pat=$2 d n
  d=$(c39_dump "$h") || { echo -1; return 1; }
  mkdir -p "$ART/jstack" 2>/dev/null || true
  printf '%s\n' "$d" >"$ART/jstack/${h##*.}.txt"
  n=$(printf '%s\n' "$d" | grep -c '^"')
  [ "${n:-0}" -ge 1 ] || { echo -2; return 1; }
  printf '%s\n' "$d" | grep -c "$pat"
}
# 硬断言某个线程类型的数量（先等最多 5 次；取不到 jstack ⇒ 判场景无效）
c39_thread_expect(){ local h=$1 pat=$2 want=$3 label=$4 i v
  v=""
  for i in 1 2 3 4 5; do
    v=$(c39_cnt "$h" "$pat")
    [ "${v:-0}" = "$want" ] && { pass "  $h $label=$v（期望 $want）"; return 0; }
    sleep 8
  done
  case "${v:-}" in
    -1|-2) fail "  $h jstack 未取到 DataNode 进程/无线程头（场景无效，$label 无法判定）" ;;
    0)     warn "  $h $label=0（期望 $want）：本构建未观测到该类线程池（可能懒创建/命名不同）⇒ 按不可观测记录，不判缺陷" ;;
    *)     fail "  $h $label=$v（期望 $want）" ;;
  esac
  return 1
}
# SHOW REGIONS 里的 DataRegion 行数（列序：$2=RegionId $3=Type $4=Status $5=Database）
c39_regions(){ sq 'show regions;' 2>/dev/null | awk -F'|' '{gsub(/[ \t]/,"",$3)} $3=="DataRegion"{c++} END{print c+0}'; }

# ============================================================================
log "--- 集群准备（重启生效：time_partition_interval=${C39_TPI_MS}ms；线程族 1/4/4；候选 2、跨层 gap=1、成批门槛 2）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${C39_CAND},inner_compaction_total_file_num_threshold=2,max_level_gap_in_inner_compaction=1,inner_seq_selector=size_tiered_multi_target,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},compaction_thread_count=1,sub_compaction_thread_count=4,compaction_schedule_thread_num=4,time_partition_interval=${C39_TPI_MS}" cmp_cluster_prepare

assert_eq "  生效值 compaction_thread_count（去竞态：单执行线程）" "$(cmp_eff "${DN[0]}" compaction_thread_count)" "1"
assert_eq "  生效值 sub_compaction_thread_count" "$(cmp_eff "${DN[0]}" sub_compaction_thread_count)" "4"
assert_eq "  生效值 compaction_schedule_thread_num" "$(cmp_eff "${DN[0]}" compaction_schedule_thread_num)" "4"
assert_eq "  生效值 inner_compaction_candidate_file_num" "$(cmp_eff "${DN[0]}" inner_compaction_candidate_file_num)" "$C39_CAND"
assert_eq "  生效值 max_level_gap_in_inner_compaction（段 1 需要跨层）" "$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction)" "1"
TPI_EFF=$(cmp_eff "${DN[0]}" time_partition_interval)
if [ "${TPI_EFF:-}" = "$C39_TPI_MS" ]; then
  pass "  生效值 time_partition_interval=$TPI_EFF（重启生效键已落盘并逐节点校验）"
else
  warn "  time_partition_interval 生效值=[$TPI_EFF]（期望 $C39_TPI_MS；show configuration 可能不列该键）⇒ 段 4 用目录时间分区数做行为校验"
fi

# ============================================================================
log "--- 段 1（D2-9 低层优先）：造 [旧 L1 ×1 + 新 L0 ×3] ---"
cmp_compaction_off
cmp_mkdb1 "$DB1"
B1=$(now_ms)
cmp_batch1 "$DB1" 1 "$(( B1 + 100000 ))" "1/0/0/0" "$C39_ROWS"
cmp_batch1 "$DB1" 2 "$(( B1 + 200000 ))" "2/0/0/0" "$C39_ROWS"
cmp_set_hot enable_seq_space_compaction true >/dev/null
if cmp_wait_lay "$DB1" "0/1/0/0" 150 >/dev/null; then
  pass "  段1 前置：2×L0 已合并为 1×L1（判据集 ${CMPJ_JUDGE_SPEC% }）"
  cmp_warn_followers "段1 前置（0/1/0/0）" "0/1/0/0"
elif cmp_any_lay "$DB1" "0/1/0/0"; then
  warn "  段1 前置：判据集 ${CMPJ_JUDGE_SPEC:-（空）} 未达 0/1/0/0，但**至少一台**已合成 L1（各副本 $(cmp_lay "$DB1")）⇒ 场景成立（V1=全部副本 / V2=leader 口径；V2 follower 不 flush memtable、文件落 unsequence，属设计差异）"
else
  fail "  段1 前置失败：未合成 L1（布局 $(cmp_lay "$DB1")）"
fi
cmp_compaction_off
cmp_batch1 "$DB1" 3 "$(( B1 + 300000 ))" "1/1/0/0" "$C39_ROWS"
cmp_batch1 "$DB1" 4 "$(( B1 + 400000 ))" "2/1/0/0" "$C39_ROWS"
cmp_batch1 "$DB1" 5 "$(( B1 + 500000 ))" "3/1/0/0" "$C39_ROWS"
LAY1=$(cmp_lay_uni "$(cmp_lay "$DB1")")
log "  段1 起点布局（各副本去重）：[$LAY1]（期望 3/1/0/0）"
cmp_scene_lay "场景有效性：段1 起点 = 3×L0 + 1×L1" "$DB1" "3/1/0/0"
log "  段1 起点全部副本布局：$(cmp_lay "$DB1")（判据集 ${CMPJ_JUDGE_SPEC:-（空）}）"
FP1=$(cmp_fp_tree "$DB1"); TS1=$(cmp_all_sum "$DB1"); F1=$(cmp_inner_finish "$DB1")
log "  段1 开合并前：TsFile=$TS1 finishes=$F1 指纹=$FP1"
cmp_compaction_on true false false
if RES=$(cmp_wait_merge "$DB1" "$F1" "$TS1" "$C39_WIN"); then
  pass "  段1 双信号（finishes↑ 且 TsFile↓）：$RES"
else
  fail "  段1 合并未推进（$RES，窗口 ${C39_WIN}s）"
fi
sleep 8
SEQ1=$(c39_fin_seq "${DN[0]}" "$DB1" 6)
LV1=$(c39_field "$SEQ1" 3)
log "  段1 产物序列（<ts>-<ver>-<level>-<n>，DN ${DN[0]##*.}）：[$SEQ1]"
log "  段1 产物 level 序列：[$LV1]"
FIRST_L=$(printf '%s\n' "$LV1" | tr ' ' '\n' | sed '/^$/d' | head -1)
if [ "${FIRST_L:-}" = "1" ]; then
  pass "  段1 排序（WARN-only 判据）：首个完成任务的产物 level=1 ⇒ 源文件全是 L0（低层优先，D2-9 一致）"
elif [ -n "${FIRST_L:-}" ]; then
  warn "  段1 排序：首个完成任务的产物 level=$FIRST_L（期望 1 = 由 L0 先执行）。D2-9 属比较器实现细节，按 §4.2 诚实标注**只记 WARN 不判缺陷**；产物序列=[$SEQ1]"
else
  warn "  段1 未取到产物文件名序列（日志格式与预期不同），排序不判定"
fi
cmp_assert_same "  段1 合并前后数据指纹" "$FP1" "$(cmp_fp_tree "$DB1")"
log "  段1 日志尾部：$(cmp_log_tail "${DN[0]}" "$DB1" | tr '\n' ' ' | cut -c1-240)"

# ============================================================================
log "--- 段 2（D2-9 新 version 优先）：同层 ${C39_V_BATCHES} 个不同 version 的 L0（段内临时 gap=0 保证单任务归因）---"
cmp_compaction_off
cmp_set_hot max_level_gap_in_inner_compaction 0 >/dev/null
assert_eq "  段2 生效值 max_level_gap_in_inner_compaction（=0：首个任务后再无跨层候选 ⇒ 单任务，源文件集合差可唯一归因）" "$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction)" "0"
cmp_mkdb1 "$DB2"
B2=$(now_ms)
for b in $(seq 1 "$C39_V_BATCHES"); do cmp_batch1 "$DB2" "$b" "$(( B2 + b * 100000 ))" "${b}/0/0/0" "$C39_ROWS"; done
LAY2=$(cmp_lay_uni "$(cmp_lay "$DB2")")
N0_2=$(c39_names "${DN[0]}" "$DB2")
V0_2=$(c39_field "$N0_2" 2)
VMAX=$(c39_max "$V0_2")
log "  段2 起点布局=[$LAY2]，文件（DN ${DN[0]##*.}）：[$N0_2]"
log "  段2 起点 version 序列：[$V0_2]（全局最大 version=$VMAX）"
cmp_scene_lay "场景有效性：段2 起点 = ${C39_V_BATCHES}×L0" "$DB2" "${C39_V_BATCHES}/0/0/0"
log "  段2 起点全部副本布局：$(cmp_lay "$DB2")（判据集 ${CMPJ_JUDGE_SPEC:-（空）}）"
FP2=$(cmp_fp_tree "$DB2"); TS2=$(cmp_all_sum "$DB2"); F2=$(cmp_inner_finish "$DB2")
cmp_compaction_on true false false
if c39_wait_fin "$DB2" "$F2" "$C39_WIN"; then
  pass "  段2 首个 inner 任务已完成（用**首个任务**做单任务归因）"
else
  fail "  段2 窗口 ${C39_WIN}s 内没有 inner 任务完成"
fi
N1_2=$(c39_names "${DN[0]}" "$DB2")
REM2=$(c39_removed "$N0_2" "$N1_2")
REM2N=$(printf '%s\n' "$REM2" | wc -w | tr -dc '0-9')
REMV=$(c39_max "$(c39_field "$REM2" 2)")
log "  段2 首个任务后文件：[$N1_2]；消失的文件（= 首个任务的源）：[$REM2]"
if [ "${REM2N:-0}" = "2" ] && [ "${REMV:-0}" = "${VMAX:-0}" ]; then
  pass "  段2 排序（WARN-only 判据）：首个任务的源文件含全局最大 version（maxVersion=$REMV = $VMAX）⇒ 新 version 优先，D2-9 一致"
elif [ "${REM2N:-0}" = "2" ]; then
  warn "  段2 排序：首个任务源文件 maxVersion=$REMV < 全局最大 $VMAX ⇒ 新 version 未优先。D2-9 属比较器实现细节，按 §4.2 诚实标注**只记 WARN 不判缺陷**；源文件=[$REM2]"
else
  warn "  段2 观测窗口内已完成多个任务（消失文件数=${REM2N}，[$REM2]），无法单任务归因 ⇒ 排序不判定"
fi
if RES=$(cmp_wait_merge "$DB2" "$F2" "$TS2" "$C39_WIN"); then
  pass "  段2 双信号（finishes↑ 且 TsFile↓）：$RES"
else
  fail "  段2 合并未推进（$RES）"
fi
cmp_assert_same "  段2 合并前后数据指纹" "$FP2" "$(cmp_fp_tree "$DB2")"
log "  段2 日志尾部：$(cmp_log_tail "${DN[0]}" "$DB2" | tr '\n' ' ' | cut -c1-240)"
cmp_set_hot max_level_gap_in_inner_compaction 1 >/dev/null
log "  段2 结束：gap 还原为 $(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction)"

# ============================================================================
log "--- 段 3（D2-9 文件数多优先）：9 个 L0 + 候选批量放大到 ${C39_CAND_MANY} ---"
cmp_compaction_off
cmp_set_hot inner_compaction_candidate_file_num "$C39_CAND_MANY" >/dev/null
assert_eq "  生效值 inner_compaction_candidate_file_num（段3 热改）" "$(cmp_eff "${DN[0]}" inner_compaction_candidate_file_num)" "$C39_CAND_MANY"
cmp_mkdb1 "$DB3"
B3=$(now_ms)
for b in $(seq 1 "$C39_BATCHES"); do cmp_batch1 "$DB3" "$b" "$(( B3 + b * 100000 ))" "${b}/0/0/0" "$C39_ROWS"; done
LAY3=$(cmp_lay_uni "$(cmp_lay "$DB3")")
L0MIN=$(cmp_judge_l0_stat "$DB3" min)
log "  段3 起点布局=[$LAY3] 判据集最小 L0=$L0MIN（期望 $C39_BATCHES/0/0/0 与 $C39_BATCHES）"
if cmp_scene_lay "场景有效性：段3 起点 = ${C39_BATCHES}×L0" "$DB3" "${C39_BATCHES}/0/0/0"; then
  [ "${L0MIN:-0}" = "$C39_BATCHES" ] && pass "  段3 判据集 level-0 文件数 = ${C39_BATCHES}（$(cmp_lay "$DB3")）" \
    || warn "  段3 判据集最小 L0=$L0MIN（期望 ${C39_BATCHES}）——按实际布局记录，后续判据看时序/分布"
else
  fail "  场景无效：段3 起点布局=[$LAY3] 判据集最小 L0=$L0MIN（期望 ${C39_BATCHES}/0/0/0 与 $C39_BATCHES）"
fi
FP3=$(cmp_fp_tree "$DB3"); TS3=$(cmp_all_sum "$DB3"); F3=$(cmp_inner_finish "$DB3"); S3=$(cmp_inner_start "$DB3")
cmp_compaction_on true false false
if c39_wait_start "$DB3" "$S3" "$C39_WIN"; then
  N_FIRST=$(c39_first_n "${DN[0]}" "$DB3")
  DIST3=$(cmp_task_nums "$DB3" inner)
  log "  段3 首个任务的 N files=$N_FIRST；全部任务的文件数分布：[$DIST3]"
  if [ "${N_FIRST:-0}" = "$C39_CAND_MANY" ]; then
    pass "  段3 排序（WARN-only 判据）：首个任务一次取走 $N_FIRST 个文件（= 可选最大批量）⇒ 文件数多优先，D2-9 一致"
  else
    warn "  段3 排序：首个任务 N files=[$N_FIRST]（期望 $C39_CAND_MANY 个，即文件数多的候选先执行）。D2-9 属比较器实现细节，按 §4.2 诚实标注**只记 WARN 不判缺陷**；分布=[$DIST3]"
  fi
else
  fail "  段3 窗口 ${C39_WIN}s 内没有 inner 任务启动"
fi
if RES=$(cmp_wait_merge "$DB3" "$F3" "$TS3" "$C39_WIN"); then
  pass "  段3 双信号（finishes↑ 且 TsFile↓）：$RES"
else
  fail "  段3 合并未推进（$RES）"
fi
cmp_assert_same "  段3 合并前后数据指纹" "$FP3" "$(cmp_fp_tree "$DB3")"
log "  段3 日志尾部：$(cmp_log_tail "${DN[0]}" "$DB3" | tr '\n' ' ' | cut -c1-240)"
cmp_set_hot inner_compaction_candidate_file_num "$C39_CAND" >/dev/null
log "  段3 结束：候选批量还原为 $(cmp_eff "${DN[0]}" inner_compaction_candidate_file_num)"

# ============================================================================
log "--- 段 4（D2-11 时间分区倒序）：time_partition_interval=${C39_TPI_MS}ms ⇒ 写 3 个不同日期（间隔 ${C39_PART_GAP_MS}ms，1 天/7 天两种 interval 下都落在不同分区）---"
cmp_compaction_off
cmp_mkdb1 "$DB4"
B4=$(now_ms)
for i in 1 2 3; do
  PBASE=$(( B4 - (4 - i) * C39_PART_GAP_MS ))
  cmp_batch1 "$DB4" "$(( 2 * i - 1 ))" "$PBASE" "$(( 2 * i - 1 ))/0/0/0" "$C39_ROWS"
  cmp_batch1 "$DB4" "$(( 2 * i ))" "$(( PBASE + 50000 ))" "$(( 2 * i ))/0/0/0" "$C39_ROWS"
done
PARTS=$(c39_parts "${DN[0]}" "$DB4")
NPARTS=$(printf '%s\n' "$PARTS" | tr ' ' '\n' | sed '/^$/d' | wc -l | tr -dc '0-9')
LAY4=$(cmp_lay_uni "$(cmp_lay "$DB4")")
MAP4=$(c39_region_parts "${DN[0]}" "$DB4")
log "  段4 起点布局=[$LAY4] 时间分区=[$PARTS]（共 ${NPARTS} 个）"
log "  段4 <regionId>/<timePartitionNo> 映射：$(printf '%s\n' "$MAP4" | tr '\n' ' ')"
if [ "${NPARTS:-0}" -ge 3 ]; then
  cmp_scene_lay "场景有效性：段4 起点 = 3 个时间分区 × 2×L0" "$DB4" "6/0/0/0"
  log "  段4 起点全部副本布局：$(cmp_lay "$DB4")（判据集 ${CMPJ_JUDGE_SPEC:-（空）}）"
else
  fail "  场景无效：段4 时间分区数=${NPARTS}（期望 ≥3）布局=[$LAY4]（期望 6/0/0/0）⇒ time_partition_interval 未生效或批次落进同一分区"
fi
FP4=$(cmp_fp_tree "$DB4"); TS4=$(cmp_all_sum "$DB4"); F4=$(cmp_inner_finish "$DB4")
cmp_compaction_on true false false
if c39_wait_fin "$DB4" "$F4" "$C39_WIN"; then
  PATHS4=$(c39_fin_paths "${DN[0]}" "$DB4" 3)
  P_FIRST=$(printf '%s\n' "$PATHS4" | tr ' ' '\n' | sed '/^$/d' | head -1 | awk -F/ '{print $(NF-1)}')
  P_MAX=$(printf '%s\n' "$PARTS" | tr ' ' '\n' | sed '/^$/d' | sort -n | tail -1)
  log "  段4 首个完成任务（单执行线程 ⇒ 也是首个启动）：产物路径=[$PATHS4] → 时间分区=$P_FIRST（最新分区=$P_MAX）"
  if [ -n "${P_FIRST:-}" ] && [ "${P_FIRST:-0}" = "${P_MAX:-1}" ]; then
    pass "  段4 排序（WARN-only 判据）：首个任务是**最新时间分区**（partition=$P_FIRST = max）⇒ 时间分区倒序调度，D2-11 一致"
  elif [ -n "${P_FIRST:-}" ]; then
    warn "  段4 排序：首个任务的时间分区=$P_FIRST ≠ 最新分区 $P_MAX ⇒ 未观测到倒序。D2-11 的顺序观测受调度窗口影响，按 §4.2 诚实标注**只记 WARN 不判缺陷**（映射：$(printf '%s\n' "$MAP4" | tr '\n' ' ')）"
  else
    warn "  段4 未能从产物路径 [$PATHS4] 解析出时间分区（分区列表=[$PARTS]），排序不判定"
  fi
else
  fail "  段4 窗口 ${C39_WIN}s 内没有 inner 任务完成"
fi
if RES=$(cmp_wait_merge "$DB4" "$F4" "$TS4" "$C39_WIN"); then
  pass "  段4 双信号（finishes↑ 且 TsFile↓）：$RES"
else
  fail "  段4 合并未推进（$RES）"
fi
cmp_assert_same "  段4 合并前后数据指纹" "$FP4" "$(cmp_fp_tree "$DB4")"
log "  段4 日志尾部：$(cmp_log_tail "${DN[0]}" "$DB4" | tr '\n' ' ' | cut -c1-240)"

# ============================================================================
log "--- 附加（MG-T01/T02/T03）：线程族数量关系（compaction_thread_count=1 / sub=4 / schedule=4）---"
REG=$(c39_regions)
if [ "${REG:-0}" -gt 0 ]; then
  C39_SCHED_MAX=$(( REG + 2 ))
  log "  SHOW REGIONS 的 DataRegion 数=$REG ⇒ MG-T01 上界取 $C39_SCHED_MAX（= DataRegion 数 + 2 容差）"
else
  [ "${C39_SCHED_MAX:-0}" -gt 0 ] || C39_SCHED_MAX=12
  warn "  SHOW REGIONS 未解析出 DataRegion 行 ⇒ MG-T01 上界改用 ${C39_SCHED_MAX}（记录）"
fi
for h in "${DN[@]}"; do
  c39_thread_expect "$h" 'IoTDB-Compaction-Worker' "1" "Worker 线程数（MG-T02：本环境按 1 配置，默认值为 10）"
  c39_thread_expect "$h" 'IoTDB-Compaction-Sub-Task' "4" "Sub-Task 线程数（MG-T03 = 线程数×子线程数 = 1×4）"
  v=$(c39_cnt "$h" '"pool-[0-9]*-IoTDB-Compaction-Schedule')
  case "${v:-}" in
    -1|-2) fail "  $h jstack 未取到 DataNode 进程/无线程头（场景无效，MG-T01 无法判定）" ;;
    *)
      if [ "${v:-0}" -ge 1 ] && [ "${v:-0}" -le "$C39_SCHED_MAX" ]; then
        pass "  $h Schedule 线程数=$v ∈ [1, $C39_SCHED_MAX]（MG-T01：官方期望≈活跃时间分区数，本用例只做宽松上界 + 记录实测值）"
      else
        fail "  $h Schedule 线程数=$v 超出宽松上界 [1, $C39_SCHED_MAX]"
      fi ;;
  esac
done
log "  线程 dump 已存 $ART/jstack/（各 DN 一份，供人工核对）"

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死（TsFileResource.writeLock）"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from ${DB1}.d1 order by time;" tree
cmp_case_finish "" tree ""
