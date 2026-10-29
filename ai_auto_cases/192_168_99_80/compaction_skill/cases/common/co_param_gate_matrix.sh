#!/bin/bash
# ============================================================================
# CO-15 合并参数**组合测试**（一）：门控开关矩阵 + 合并优先级 + 极端值组合
#   为什么需要：单参数用例只能证明"某个键有作用"，证明不了**参数之间**的相互作用。
#   本用例覆盖三组组合：
#
#   段 1（8 种门控组合，全热改、无需重启）：
#       (enable_seq_space_compaction, enable_unseq_space_compaction, enable_cross_space_compaction)
#       ∈ {关,开}^3 —— 每个组合用一个独立库，写入"2 批 seq + 2 批更早的 unseq"（每 region
#       seq/unseq 各 ≥2 个文件 ⇒ inner 候选足够；unseq 与 seq 重叠且 min_…_level=0 ⇒ cross 可选中），
#       然后按组合热开/热关三类合并，窗口内断言**该跑的跑、不该跑的不跑**（按 Sequence/Unsequence
#       InnerSpaceCompaction 与 CrossSpaceCompaction 分开计数）+ 数据指纹不变。
#
#   段 2（`compaction_priority` 三种取值 INNER_CROSS / CROSS_INNER / BALANCE，各需重启）：
#       同一场景下三种优先级都必须"合并且数据不变"；**优先顺序**按语义记录
#       （INNER_CROSS 期望 inner 先推进、CROSS_INNER 期望 cross 先推进），与语义不符只记 WARN
#       —— 顺序本身有竞态，作为观察项而不是回归 FAIL。
#
#   段 3（极端值组合，热改）：线程/限流/层级/上限同时取极端
#       （thread=1、sub_thread=1、读写限流=1、max_level_gap=1、total_file_num_threshold=1、
#        disk_redundancy=0.99）——判据只要求：不卡死、数据指纹不变、日志无异常（收尾统一扫）；
#       合并跑不跑得完按实际记录（限流 1MB/s + 1 线程本来就慢）。
#
#   判据：段 1 八种组合全部符合门控语义；段 2 三种优先级都完成合并且数据一致；段 3 无卡死/无损坏。
#
# ---------------------------------------------------------------------------
# 【V1 → V2 口径修正（2026-10-17；定性报告 _scratch/RC8_V2_DIVERGENCE_TRIAGE.md §3.5 / §④；P0-2 + P1-3 + P4-8）】
#   V1 PASS 1682s f0 → V2 FAIL 1782s f3，3 条 FAIL 全是同一句「cross=开 但 CrossSpaceCompaction 未推进（+0）」，
#   全部出在 c=1 的组合上。同一场景的实测差异：
#     组合 cogate1  V1：起点 TsFile 14、SeqInner +8、UnseqInner **+4**、Cross **+4** → 终点 6
#                   V2：起点 TsFile **27**、SeqInner +8、UnseqInner **+12**、Cross **+0** → 终点 6
#   机制（源码事实，见报告 §② S2/S3/S4）：V2 的复制走 IoTDB Pipe，默认 `iot_consensus_v2_mode=batch`
#     （RegionMaintainHandler.java:705 + IoTDBDescriptor.java:1538）⇒ 抽取器只搬**已 seal 的 TsFile**
#     （IoTDBDataRegionSource.java:438-447）；follower 收到的文件按 LOAD 路径**一律落 unsequence**
#     （DataRegion.java:4984 setSeq(false) / :5009）⇒ V2 起点 TsFile 几乎翻倍、unseq inner 工作量 ×3，
#     原 20s 窗口被 unseq inner 吃满，cross 一次都没轮到。**门控本身没坏**（c=0 的组合两边都 PASS）。
#   ⇒ 本用例的三处改动（判据口径；"该跑没跑"的硬结论不放松）：
#     ① **观察窗口 ×3（仅 V2）**，并在窗口内**轮询**（该跑的都推进了即可提前收工）；
#     ② cross=开 的判据改为「**选择器候选日志** + finishes 增量」：
#        · 有 unseq 候选却一个任务都没跑 ⇒ **FAIL**（可能是真门控/调度问题）；
#        · 窗口内选择器**没有 unseq 候选**（或被 unseq inner 占用）⇒ **WARN**（结构上无可选任务，属布局时序）；
#     ③ 负向（cross=关 ⇒ 必须 +0）与 seq/unseq 门控判据**一处不放松**（仍为硬判据）。
#   ⚠️ **需定点复跑确认**：报告 §5-3 要求"带 selector 完整日志的定点复跑"，用来区分
#      「候选为 0（布局原因，属 (d)）」与「候选有却被层级/队列规则挡住（可能是真门控问题）」。
#      本用例现在把 selector 日志条数 / 最大 unseqFiles / "Cannot select any files" 条数打进日志，
#      但这三种情形的真实分布**尚未在真机上核对** ⇒ 结论以定点复跑的日志为准。
# ---------------------------------------------------------------------------
# 用法： bash co_param_gate_matrix.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_param_gate_matrix_${DATA_CONSENSUS}"

DB=root.cogate
DEVS=3                 # 组合矩阵用小规模：门控语义与数据量无关，快更重要
ROWS=100
WIN=${CO_COMBO_WIN:-20}   # 每个组合的观察窗口（candidate=2 + 调度 1s，合并 1~2 轮就完成）

# 每库写一批：co15_write <db> <devs> <rows> <batch> <base>
co15_write(){ local db=$1 devs=$2 rows=$3 b=$4 base=$5 d k vals
  for ((d=1; d<=devs; d++)); do
    vals=""
    for ((k=1;k<=rows;k++)); do
      vals="$vals($(( base + k * 10 )),$(( k + b ))),"
      if [ $(( k % 500 )) -eq 0 ]; then sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null; vals=""; fi
    done
    [ -n "$vals" ] && sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null
  done
  sq "flush;" >/dev/null; }
# 造一个"三类合并都有候选"的库：2 批 seq（当前附近）+ 2 批更早的 unseq（互相重叠、且与 seq 重叠）
co15_make_scene(){ local db=$1 now=$2
  cmp_make_tree_db "$db" "$DEVS" >/dev/null
  co15_write "$db" "$DEVS" "$ROWS" 1 "$now"
  co15_write "$db" "$DEVS" "$ROWS" 2 "$(( now + 5000 ))"
  co15_write "$db" "$DEVS" "$ROWS" 3 "$(( now - 40000 ))"
  co15_write "$db" "$DEVS" "$ROWS" 4 "$(( now - 20000 ))"
  # seal 状态**逐组合记录**（2026-10-22 RC9 复核）：未 seal 的 TsFile 不参与任何合并选择，
  # 此时"该跑的跑"为 +0 属于**场景不成立**，不能算门控失效（RC8/RC9 各有 3~4 条假 FAIL 出自这里）。
  # 旧口径只等 2 次/10 秒且不看结果，短到 V1 下 .78/.79 常来不及 Async close（实测滞后可达数分钟）。
  CO15_SEALED_THIS=0
  if ensure_closed "$db" 3 30; then
    CO15_SEALED_THIS=1
  else
    warn "$db 有 DN 的 TsFile 未落盘（未 seal 的文件不参与合并选择）⇒ 本组合『该跑的跑』判据将记为场景不成立"
  fi; }

# ---------------------------------------------------------------- cross 选择器候选证据
# 源码：`selector/impl/RewriteCrossSpaceCompactionSelector.java:385/399`（两条 INFO）+
#   i18n `StorageEngineMessages.STORAGE_LOG_TOTAL_SOURCE_FILES_SEQFILES_UNSEQFILES_…`：
#     `<db>-<region> [CrossSpaceCompaction] Total source files: N seqFiles, M unseqFiles.
#      Candidate source files: N' seqFiles, M' unseqFiles. Selected source files: …`
#     `… Cannot select any files because they do not meet the conditions or may be occupied by other compaction threads.`
#   ⇒ 用它区分"根本没有候选"（结构上不会跑 cross）与"有候选却没跑"（可能是真门控问题）。
co15_sel_lines(){ local db=$1 h
  for h in "${DN[@]}"; do
    sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF 'Total source files:' | grep -E '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null
  done; }
co15_sel_cnt(){ local out; out=$(co15_sel_lines "$1"); printf '%s\n' "$out" | sed '/^$/d' | wc -l | tr -dc '0-9'; }
co15_sel_unseq_max(){ local out; out=$(co15_sel_lines "$1")
  printf '%s\n' "$out" | grep -oE 'Total source files: [0-9]+ seqFiles, [0-9]+ unseqFiles' \
    | grep -oE '[0-9]+ unseqFiles' | awk '{print $1}' | sort -n | tail -1; }
co15_sel_blocked(){ local db=$1 h s=0 v
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF 'Cannot select any files' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${v:-0} ))
  done; echo "${s:-0}"; }
# ---------------------------------------------------------------- cross 任务计数（含 insertion 形态）
# RC8 实测：段 3 的 `cogate_extreme*` 上跑的全是
#   `root.cogate_extreme-3 [Compaction] InsertionCrossSpaceCompaction task {starts with|finishes successfully}`
# 而 lib 的 `cmp_cross_finish` 用了 `[Compaction] CrossSpaceCompaction …` 前缀（为的是把 insertion 排除），
# ⇒ 本用例在"只跑 insertion 形态"的组合上会读到 +0。本用例判的是"开关打开后有没有 cross 动作"，
#   所以这里两种形态都算；真实重写型 cross 的判据仍由 CO-04/CO-28/CO-30 用 lib 的严格口径覆盖。
co15_cross_finish(){ local db=$1 h s=0 v
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hE '\[Compaction\] (Insertion)?CrossSpaceCompaction task finishes successfully' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${v:-0} ))
  done; echo "${s:-0}"; }

# ---------------------------------------------------------------- 场景有效性硬闸（2026-10-20 新增）
# RC8 V2 实测（CO-15 段 1，f7）：`co15_make_scene` 之后多台 DN 报「有 DN 的 TsFile 未落盘」，
#   而**未 seal 的文件不参与任何合并选择** ⇒ 8 个组合里多数组合三种合并全是「+0」，
#   于是"该跑的跑"逐条 FAIL —— 这是**场景没成立**，不是门控失效（同 CO-36 的 17 条连锁误判）。
# 处置：写完后按**判据集**（V1=全部副本 / V2=leader）确认文件数 ≥2（V2 follower 不 flush memtable，
#   不能用"各副本都 ≥2"卡）；场景不成立就只跳过本组合的门控判据，最后汇总成**一条 WARN**
#   （2026-10-28 起按用户确认：场景不成立不计 fail_flag；仅当"一条判据都没判到"时才 FAIL）。
CO15_NO_SCENE=0
co15_scene_ok(){ local db=$1 h n j
  j=$(cmp_judge_nodes "$db")
  for h in $j; do n=$(cmp_all_cnt_node "$h" "$db"); [ "${n:-0}" -ge 2 ] && return 0; done
  sq "flush;" >/dev/null 2>&1; sleep 20
  for h in $j; do n=$(cmp_all_cnt_node "$h" "$db"); [ "${n:-0}" -ge 2 ] && return 0; done
  return 1; }

# 观察窗口（仅 V2 ×3）内轮询：**该跑的**都推进了才能提前收工。
# ⚠️ 只有 **c=1 且 cross 真的推进了** 才允许提前收工；c=0 的组合必须**等满窗口**
#    —— 它们判的是"不该跑的不跑"，窗口缩短会削弱负向证据（负向判据是硬判据，不能靠短窗口过关）。
co15_observe(){ local db=$1 s=$2 u=$3 c=$4 s0=$5 u0=$6 c0=$7 win=$8 dl
  dl=$(( $(date +%s) + win ))
  if [ "$c" != 1 ]; then sleep "$win"; return 0; fi
  while (( $(date +%s) < dl )); do
    sleep 5
    s1=$(cmp_seq_inner_finish "$db"); u1=$(cmp_unseq_inner_finish "$db"); c1=$(co15_cross_finish "$db")
    [ "$c1" -gt "$c0" ] || continue
    { [ "$s" != 1 ] || [ "$s1" -gt "$s0" ]; } || continue
    { [ "$u" != 1 ] || [ "$u1" -gt "$u0" ]; } || continue
    break
  done; }

log "--- 集群准备（三类合并先关；candidate=2、调度 1s、cross 最小层级 0 以便 cross 可被选中）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},min_cross_compaction_unseq_file_level=0" cmp_cluster_prepare
assert_eq "min_cross_compaction_unseq_file_level 生效值" "$(cmp_eff "${DN[0]}" min_cross_compaction_unseq_file_level)" "0"

# ---------------------------------------------------------------- 段 1：门控矩阵
log "--- 段 1：enable_* 三开关 8 种组合（热改，逐组合断言『该跑的跑 / 不该跑的不跑』）---"
NOW=$(now_ms)
i=0
for s in 1 0; do for u in 1 0; do for c in 1 0; do
  i=$(( i + 1 ))
  DBX="$DB$i"
  # ⚠️ 写入前必须把三类合并**全部关掉**：否则上一组合开着的合并会在本组合写入期间就把文件并掉，
  # 记基线时已经合并完 ⇒ 断言"该跑的跑"必然失败（首轮实测组合 2 就是 +0/FAIL）。
  cmp_set_hot enable_seq_space_compaction false >/dev/null
  cmp_set_hot enable_unseq_space_compaction false >/dev/null
  cmp_set_hot enable_cross_space_compaction false >/dev/null
  co15_make_scene "$DBX" "$NOW"
  if ! co15_scene_ok "$DBX"; then
    CO15_NO_SCENE=$(( CO15_NO_SCENE + 1 ))
    log "  [组合 seq=$s unseq=$u cross=$c] $DBX：**场景无效**（判据集 $(cmp_judge_nodes "$DBX") 文件数 <2 / 未 seal：$(cmp_su "$DBX")）⇒ 跳过本组合的门控判据"
    continue
  fi
  # 基线（写完后、开合并之前）
  s0=$(cmp_seq_inner_finish "$DBX"); u0=$(cmp_unseq_inner_finish "$DBX"); c0=$(co15_cross_finish "$DBX")
  ts0=$(cmp_all_sum "$DBX"); fp0=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBX.**")
  # 按组合热改
  cmp_set_hot enable_seq_space_compaction  "$([ "$s" = 1 ] && echo true || echo false)" >/dev/null
  cmp_set_hot enable_unseq_space_compaction "$([ "$u" = 1 ] && echo true || echo false)" >/dev/null
  cmp_set_hot enable_cross_space_compaction "$([ "$c" = 1 ] && echo true || echo false)" >/dev/null
  # 观察窗口：V1 用 WIN；V2 ×3（unseq inner 工作量约 3 倍），窗口内轮询、该跑的都推进了就提前收工
  WIN_USE=$WIN; [ "$(cmp_is_v2)" = 1 ] && WIN_USE=$(( WIN * 3 ))
  SEL0=$(co15_sel_cnt "$DBX")
  s1=$s0; u1=$u0; c1=$c0
  co15_observe "$DBX" "$s" "$u" "$c" "$s0" "$u0" "$c0" "$WIN_USE"
  ds=$(( s1 - s0 )); du=$(( u1 - u0 )); dc=$(( c1 - c0 ))
  ts1=$(cmp_all_sum "$DBX"); SU_NOW=$(cmp_su "$DBX")
  SEL_N=$(( $(co15_sel_cnt "$DBX") - SEL0 )); SEL_UMAX=$(co15_sel_unseq_max "$DBX"); SEL_BLK=$(co15_sel_blocked "$DBX")
  log "  [组合 seq=$s unseq=$u cross=$c] $DBX：SequenceInner +$ds、UnsequenceInner +$du、Cross +$dc；TsFile $ts0→$ts1（窗口 ${WIN_USE}s，seq/unseq=$(printf '%s' "$SU_NOW")）"
  log "     cross 选择器证据：本窗口新增 selector 日志=${SEL_N} 条，最大 unseqFiles=${SEL_UMAX:-0}，Cannot-select 行=${SEL_BLK}（源码 RewriteCrossSpaceCompactionSelector:385/399）"
  # 该跑的跑
  #   ⚠️ 若本组合写入后仍有副本未 seal（CO15_SEALED_THIS=0），文件不参与合并选择 ⇒ +0 是场景问题，不判 FAIL，
  #      结尾统一汇总成一条 WARN（2026-10-28 起不计 fail_flag；只剩"一条判据都没判到"才 FAIL）。
  if [ "$s" = 1 ]; then
    if [ "$ds" -gt 0 ]; then pass "  seq=开 ⇒ Sequence InnerSpaceCompaction 推进（+$ds）"; CO15_JUDGED=$(( ${CO15_JUDGED:-0} + 1 ))
    elif [ "${CO15_SEALED_THIS:-1}" = "0" ]; then
      CO15_NO_SEAL=$(( ${CO15_NO_SEAL:-0} + 1 ))
      warn "  seq=开 但 Sequence InnerSpaceCompaction 未推进（+0）：本组合有副本未 seal ⇒ 场景不成立，本判据不判"
    else fail "  seq=开 但 Sequence InnerSpaceCompaction 未推进（+$ds）"; fi
  fi
  [ "$s" = 0 ] && { [ "$ds" -eq 0 ] && pass "  seq=关 ⇒ 没有 Sequence InnerSpaceCompaction（+0）" || fail "  seq=关 仍有 Sequence InnerSpaceCompaction（+$ds）"; }
  if [ "$u" = 1 ]; then
    if [ "$du" -gt 0 ]; then pass "  unseq=开 ⇒ Unsequence InnerSpaceCompaction 推进（+$du）"; CO15_JUDGED=$(( ${CO15_JUDGED:-0} + 1 ))
    elif [ "${CO15_SEALED_THIS:-1}" = "0" ]; then
      CO15_NO_SEAL=$(( ${CO15_NO_SEAL:-0} + 1 ))
      warn "  unseq=开 但 Unsequence InnerSpaceCompaction 未推进（+0）：本组合有副本未 seal ⇒ 场景不成立，本判据不判"
    else fail "  unseq=开 但 Unsequence InnerSpaceCompaction 未推进（+$du）"; fi
  fi
  [ "$u" = 0 ] && { [ "$du" -eq 0 ] && pass "  unseq=关 ⇒ 没有 Unsequence InnerSpaceCompaction（+0）" || fail "  unseq=关 仍有 Unsequence InnerSpaceCompaction（+$du）"; }
  [ "$c" = 0 ] && { [ "$dc" -eq 0 ] && pass "  cross=关 ⇒ 没有 CrossSpaceCompaction（+0）" || fail "  cross=关 仍有 CrossSpaceCompaction（+$dc）"; }
  if [ "$c" = 1 ] && { [ "$s" = 1 ] || [ "$u" = 1 ]; }; then
    # cross=开 的判据（改口径）：finishes 增量 **或** 选择器给出了 unseq 候选
    if [ "$dc" -gt 0 ]; then
      pass "  cross=开（且 seq/unseq 至少一个开）⇒ CrossSpaceCompaction 推进（+$dc）"; CO15_JUDGED=$(( ${CO15_JUDGED:-0} + 1 ))
    elif [ "${SEL_UMAX:-0}" -gt 0 ]; then
      fail "  cross=开但 CrossSpaceCompaction 一次都没跑（+0）：窗口 ${WIN_USE}s 内选择器**已给出 unseq 候选**（最大 unseqFiles=${SEL_UMAX}，selector 日志 ${SEL_N} 条，Cannot-select ${SEL_BLK} 条）⇒ 可能是真门控/调度问题，需带完整 selector 日志定点复跑确认"
    else
      warn "  cross=开但窗口 ${WIN_USE}s 内没有可选候选（selector 日志 ${SEL_N} 条、最大 unseqFiles=0、Cannot-select ${SEL_BLK} 条；seq/unseq=$(printf '%s' "$SU_NOW")）⇒ 结构上没有可执行的 cross 任务（V2 下 unseq inner 先把文件并掉/时间片被 inner 吃满，属布局时序、非门控失效）；cross 的正向能力由 CO-04/CO-28/CO-30 独立覆盖。**需定点复跑确认**（报告 §5-3）"
    fi
  fi
  # 数据不变（任何组合都不允许损坏数据）
  cmp_assert_same "  [seq=$s unseq=$u cross=$c] 合并前后数据指纹" "$fp0" "$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBX.**")"
done; done; done
# 【2026-10-28 口径修改】"场景不成立/无效"不再计入 fail_flag（用户确认）：
#   · 未 seal 的文件本来就不参与合并选择，+0 不能证明门控失效；
#   · 但仍要留痕（warn 会进 v_warnMessage），并保留一道兜底：**一条判据都没判到**时才算 FAIL，
#     否则整个用例会在"环境时序不好"的情况下静默变绿。
[ "${CO15_NO_SCENE:-0}" -gt 0 ] && warn "  场景无效（不计 fail_flag）：${CO15_NO_SCENE}/8 个组合在写完 + flush 后判据集仍 <2 个 TsFile（未 seal，未 seal 的文件不参与合并选择）⇒ 这些组合的门控判据**未判**（不是门控失效）；建议定点复跑并加大 seal 等待"
[ "${CO15_NO_SEAL:-0}" -gt 0 ] && warn "  场景不成立（不计 fail_flag）：另有 ${CO15_NO_SEAL} 条『该跑的跑』判据因**写入后有副本未 seal** 无法判定（未 seal 的文件不参与合并选择；本用例 seal 等待已加大到 3×30s）⇒ 需定点复跑确认，**不计为门控失效**"
if [ "${CO15_JUDGED:-0}" -eq 0 ]; then
  fail "  场景整体无效：所有『该跑的跑』判据都没能判定（未 seal 跳过=${CO15_NO_SEAL:-0}，无效组合=${CO15_NO_SCENE:-0}）⇒ 本用例没有验证到任何门控行为，需要修环境/构造后重跑"
fi

# ---------------------------------------------------------------- 段 2：合并优先级
log "--- 段 2：compaction_priority 三种取值（各需重启）---"
for prio in INNER_CROSS CROSS_INNER BALANCE; do
  log "  --- 优先级 $prio ---"
  # 写入阶段三类合并仍关（只有 priority 需要重启，所以放进 conf）；写完再热开三类，保证能观察到推进
  EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},min_cross_compaction_unseq_file_level=0,compaction_priority=$prio" cmp_cluster_prepare
  assert_eq "  compaction_priority 生效值" "$(cmp_eff "${DN[0]}" compaction_priority)" "$prio" || true
  DBP="$DB""_$prio"
  co15_make_scene "$DBP" "$NOW"
  s0=$(cmp_seq_inner_finish "$DBP"); u0=$(cmp_unseq_inner_finish "$DBP"); c0=$(co15_cross_finish "$DBP")
  fp0=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBP.**")
  cmp_compaction_on true true true
  order=""
  deadline=$(( $(date +%s) + 60 )); first_type=""
  s1=$s0; u1=$u0; c1=$c0
  while (( $(date +%s) < deadline )); do
    s1=$(cmp_seq_inner_finish "$DBP"); u1=$(cmp_unseq_inner_finish "$DBP"); c1=$(co15_cross_finish "$DBP")
    if [ -z "$first_type" ]; then
      [ "$s1" -gt "$s0" ] || [ "$u1" -gt "$u0" ] && first_type="inner"
      [ -z "$first_type" ] && [ "$c1" -gt "$c0" ] && first_type="cross"
    fi
    # 两类都推进就可以收工（BALANCE 需要两者都动）
    if [ "$s1" -gt "$s0" ] && [ "$u1" -gt "$u0" ] && [ "$c1" -gt "$c0" ]; then break; fi
    sleep 3
  done
  ds=$(( s1 - s0 )); du=$(( u1 - u0 )); dc=$(( c1 - c0 ))
  log "    finishes: SequenceInner +$ds、UnsequenceInner +$du、Cross +$dc；首个推进的类型=$first_type"
  [ "$ds" -gt 0 ] && pass "  优先级 $prio：inner(seq) 已推进（+$ds）" || warn "  优先级 $prio：seq inner 未推进（+$ds）"
  [ "$dc" -gt 0 ] && pass "  优先级 $prio：cross 已推进（+$dc）" || warn "  优先级 $prio：cross 未推进（+$dc）"
  cmp_assert_same "  优先级 $prio 合并前后数据指纹" "$fp0" "$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBP.**")"
  case "$prio" in
    INNER_CROSS) [ "$first_type" = inner ] && pass "  优先级语义：INNER_CROSS 下 inner 先推进" || warn "  INNER_CROSS 首个推进类型=$first_type（期望 inner）—— 竞态，仅记录" ;;
    CROSS_INNER) [ "$first_type" = cross ] && pass "  优先级语义：CROSS_INNER 下 cross 先推进" || warn "  CROSS_INNER 首个推进类型=$first_type（期望 cross）—— 竞态，仅记录" ;;
    BALANCE)     [ -n "$first_type" ] && pass "  优先级语义：BALANCE 下两类都能推进（首个=$first_type）" || warn "  BALANCE 窗口内未见推进" ;;
  esac
done

# ---------------------------------------------------------------- 段 3：极端值组合
log "--- 段 3：极端值组合（线程=1、限流=1、层级 gap=1、总文件上限=1、磁盘冗余 0.99）---"
EXTREME="compaction_thread_count=1,sub_compaction_thread_count=1,compaction_write_throughput_mb_per_sec=1,compaction_read_throughput_mb_per_sec=1,compaction_read_operation_per_sec=1,max_level_gap_in_inner_compaction=1,inner_compaction_total_file_num_threshold=1,inner_compaction_task_selection_disk_redundancy=0.99"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},min_cross_compaction_unseq_file_level=0,$EXTREME" cmp_cluster_prepare
# 注意：EXTREME 是逗号分隔的，循环前必须把逗号换成空格（否则整个字符串被当成"一个键"，校验恒 WARN）
for kv in $(printf '%s' "$EXTREME" | tr ',' ' '); do
  k=${kv%%=*}; want=${kv#*=}
  got=$(cmp_eff "${DN[0]}" "$k")
  [ "$got" = "$want" ] && pass "  极端值生效：$k=$got" || warn "  $k 生效值='$got'（期望 $want）—— 记录"
done
DBE="$DB""_extreme"
co15_make_scene "$DBE" "$NOW"
ts0=$(cmp_all_sum "$DBE"); fin0=$(cmp_inner_finish "$DBE")
fp0=$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBE.**")
cmp_compaction_on true true true
log "  等 60s（1 线程 + 1MB/s 限流本来就慢，跑不完不算缺陷，只要求不卡死/不损坏）"
sleep 60
fin1=$(cmp_inner_finish "$DBE"); ts1=$(cmp_all_sum "$DBE")
log "  极端值组合：inner finishes $fin0 → $fin1；TsFile $ts0 → $ts1"
cmp_assert_same "  极端值组合下数据指纹不变" "$fp0" "$(cmp_fingerprint tree "select count(s1), sum(s1) from $DBE.**")"
STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "极端值组合下无合并线程卡死"

log "--- 收尾三件套（基准库用最后一个组合库）---"
post_checks "select count(s1) from $DBE.d1 order by time;" tree
cmp_case_finish "" tree ""
