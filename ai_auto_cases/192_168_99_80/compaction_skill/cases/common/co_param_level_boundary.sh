#!/bin/bash
# ============================================================================
# CO-17 参数组合**边界**测试（三）：层级 gap / 任务文件数上限 / cross 候选上限
#   CO-15/CO-16 只证明这些键"改了就生效"，本用例用精细场景验证**边界行为**是否符合源码语义。
#
#   源码依据（RC6 = 本地源码树 commit 7ae8713ecb，逐行可对照）：
#     · **选择器枚举 → 实现类**（`compaction/selector/constant/InnerSequenceCompactionSelector.java:52-60`）：
#         size_tiered_multi_target（**模板默认值**）→ `NewSizeTieredCompactionSelector`
#         size_tiered_single_target              → `SizeTieredCompactionSelector`（经典实现）
#       只有 `NewSizeTieredCompactionSelector` 才读 `max_level_gap_in_inner_compaction` 与
#       `inner_compaction_total_file_num_threshold`；经典选择器只用
#       `inner_compaction_candidate_file_num` + `target_compaction_file_size`。
#       ⇒ **测这两个键必须用默认的 multi_target**（第一版 CO-17 设成 single_target，
#         等于把被测参数摘掉了，判据必然失败——教训见 SKILL.md）。
#     · `NewSizeTieredCompactionSelector#selectTasksByLevel`：
#         扫描 level 0→maxLevel，某层选出任务即返回；任务**首个文件的层级必须正好等于扫描层级**；
#         后续文件 `isFileLevelSatisfied(lvl) = |lvl - 扫描层级| <= max_level_gap_in_inner_compaction`；
#         任务文件数上限 = `inner_compaction_total_file_num_threshold`（`isTaskTooLarge`）；
#         提交门槛 = `selectedNum >= inner_compaction_candidate_file_num`
#                   **或** 该时间分区不是"活跃分区"（活跃窗口 = 2 × compaction_schedule_interval_in_ms）。
#     · `RewriteCrossSpaceCompactionSelector#canAddToTaskResource`：
#         第一个 unseq 文件**无条件**入选（"至少保留 1 个 unseq"）；之后每个 unseq 需同时满足
#         `已选文件数 + 1 + 本 unseq 的 seq 重叠文件数 <= max_cross_compaction_candidate_file_num`
#         且 `已选总大小 + 本文件总大小 <= max_cross_compaction_candidate_file_size`。
#
#   场景构造（本用例能稳定复现的关键，踩过坑才定下来）：
#     ① **单设备**（只落一个 data region）⇒ 每个副本上该库只有一个 region，文件数可控；
#     ② 每批时间戳**递增**（写 in-order）⇒ 全部落 `sequence/` 空间；
#        比已落盘数据更早的批次才落 `unsequence/`（段 3 造 unseq 用这个）。
#     ③ 每批写完后**逐节点 `flush;` 并等"判据集"的文件布局达标**（判据集见下面 §V2 口径：
#        V1 = 各副本、V2 = region leader）：IoTConsensus 下写请求在 leader 即时应用、follower
#        异步应用，只发给 CLI 连的那台会得到 "77:1 个文件 / 78:2 个文件" 的不可控布局
#        （follower 的数据还在 memtable 里）。
#
#   §V2 口径（2026-10-16 定性：本轮 V2 的 5 条 FAIL 全部源于"要求三副本同布局"，**不是缺陷**）：
#     · V2 的 follower **不 flush 自己的 memtable**：共识管道收到的 TsFile 一律进 **unsequence 空间**
#       （`IoTConsensusV2Receiver.java:734` → `DataRegion.loadNewTsFile(...)`
#        → `DataRegion.java:4984 setSeq(false)` + `:5009 loadTsFileToUnSequence`，
#        即 LOAD 路径的既定语义被 V2 接收侧复用）；只有 region leader 会 flush 自己的 memtable，
#       因而**只有 leader 持有 sequence 文件**（实测 `Async close tsfile` 归属：colevelg 上 78:4 / 77:0 / 79:0）。
#     · 段 1 / 段 2 只开 `enable_seq_space_compaction` ⇒ **只有 leader 会参与 seq 空间的内部合并**，
#       "三副本同布局 / 三副本都出 L1..L3" 在 V2 下**结构性不成立**（follower 的层级布局永远不跟随
#       leader）⇒ 旧口径必然 FAIL。**属设计差异，非缺陷**；leader 上每一步都精确符合预期
#       （0/1/0/0、1/1/0/0、0/0/1/0、1/0/1/0、0/0/0/1）。
#     · 判据集（judge set）按**副本角色**动态确定，不依赖固定 IP：
#         - V1：三副本都 flush memtable ⇒ 判据集 = **全部副本**（与改动前口径**完全一致**，不放松）；
#         - V2：判据集 = **本相 leader**（动态识别）：优先取"该库有 `Async close tsfile`
#           （= flush 过自己的 memtable）的副本"，取不到再退到"持有该库 sequence 文件的副本"；
#           follower 的布局差异**只打 WARN** 并打印逐副本布局作证据（保留证据、不判 FAIL）。
#     · **硬判据一处不放松**：判据集侧的 finishes 增量、level 递进（1/1/0/0 → 0/0/1/0 → 0/0/0/1）、
#       数据指纹/行数，以及收尾三件套（sync lag / 副本一致性 / 日志扫描）仍按原口径判定。
#
#   段 1：`max_level_gap_in_inner_compaction` 的层级边界
#     A) 造 [L1(旧), L0(新)]：写 2 批 → 合并出 L1 → 关合并 → 再写 1 批
#        · gap=0：|0-1| = 1 > 0 ⇒ **不合并**（布局保持 L1×1 + L0×1，finishes 不增）
#        · gap=1（热改）：|0-1| = 1 ≤ 1 ⇒ 合并，产出 **L2**
#     B) 再写 1 批 → 造 [L2(旧), L0(新)]
#        · gap=1：|0-2| = 2 > 1 ⇒ **不合并**
#        · gap=2（热改）：|0-2| = 2 ≤ 2 ⇒ 合并，产出 **L3**
#     ⇒ 同一个键两处"卡边界"，既证明生效、又证明边界值精确（不是"越大越合"）
#   段 2：`inner_compaction_total_file_num_threshold`（单任务文件数上限）
#         × `inner_compaction_candidate_file_num`（提交门槛）
#     · threshold=2 + candidate=3 + 3 个 L0 ⇒ 任务最多 2 个文件（日志 `starts with 2 files`），
#       3 → 2 个文件（L1×1 + L0×1）；2 < 门槛 3 仍被提交 ⇒ **非活跃分区绕过门槛**（源码语义）
#     · threshold=100 + candidate=2 + 3 个 L0 ⇒ 一个任务收 3 个文件（`starts with 3 files`），3 → 1
#   段 3：`max_cross_compaction_candidate_file_num` / `_file_size` 的截断
#     每库：1 个 seq 水位 + 3 个**落在水位时间区间内、互相重叠**的更早 unseq 文件（关 seq/unseq 内部合并）。
#     ⚠️ 必须重叠：不重叠时选择器走 `getLatestSealedSeqFile()` 特殊路径，一个任务最多只收 2 个 unseq
#        （实测上限给 500 也收不满 3 个），"上限放大就能一次收完"的语义就测不出来。
#     · Run A（num=2）  ：每任务 1 unseq + 1 seq ⇒ 每副本 3 个任务（任务数 副本数×3）
#     · Run B（num=500）：一个任务收下全部 3 个 unseq ⇒ 每副本 1 个任务（证明"上限大就多收"）
#     · Run C（num=500, size=1B）：size 立刻超限 ⇒ 退化成"每任务 1 unseq"（证明 size 上限也在截断）
#     判据用"每任务 unseq 数"的分布（日志 `[Compaction] CrossSpaceCompaction task starts with
#     N seq files and M unsequence files`；`cmp_log_files` 同时含 all 日志 ⇒ 绝对条数按 2 倍记，
#     所以断言只看分布的最大值与任务数相对大小，不看绝对值）
#
#   用法： bash co_param_level_boundary.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_param_level_boundary_${DATA_CONSENSUS}"

DB=root.colevel
DEVS=1                 # 单设备：只落一个 region（布局可预测）
ROWS=200
WIN=${CO_COMBO_WIN:-45}

# ---------------------------------------------------------------- 场景/观测工具
# 单个副本的 TsFile 层级计数（L0/L1/L2/L3），形如 "1/1/0/0"
co17_lay_of(){ sshx "$1" "find $DB_DIR/data/datanode/data -path '*/$2/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '{c[\$3]++} END{printf \"%d/%d/%d/%d\", c[0]+0, c[1]+0, c[2]+0, c[3]+0}'" 2>/dev/null; }
# 各副本（**全部**）的 TsFile 层级计数，形如 "77:1/0/0/0 78:1/0/0/0 79:1/0/0/0"（证据/失败信息用）
co17_lay(){ local db=$1 h spec=""
  for h in "${DN[@]}"; do spec="$spec${h##*.}:$(co17_lay_of "$h" "$db") "; done
  printf '%s' "$spec"; }
# 布局串去重（一致时只有一个值，形如 "1/0/0/0 "）——只作"各副本是否一致"的旁证
co17_lay_uni(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' '; }
# 各副本 seq/unseq 文件数，形如 "77:1/3 78:1/3 79:1/3"
co17_su(){ local db=$1 h spec=""
  for h in "${DN[@]}"; do spec="$spec${h##*.}:$(cmp_seq_cnt "$h" "$db")/$(cmp_unseq_cnt "$h" "$db") "; done
  printf '%s' "$spec"; }
# ---------------- 判据集（judge set）= 真正可能参与 seq 空间合并的副本 ----------------
# V1：三副本都 flush 自己的 memtable ⇒ 判据集 = 全部副本（口径与改动前完全一致）；
# V2：follower 不 flush 自己的 memtable（TsFile 走 LOAD 路径强制落 unsequence）
#     ⇒ 判据集 = **本相 leader**：① 优先"该库有 close 事件"的副本，② 退到"持有该库 sequence 文件的副本"，
#     ③ 都还没有（刚建库/刚写入未落盘）时退回全部副本——动态识别，不依赖固定 IP，也不会"判据集为空"。
co17_is_v2(){ case "${DATA_CONSENSUS:-}" in *IoTConsensusV2*) echo 1 ;; *) echo 0 ;; esac; }
co17_judge_nodes(){ local db=$1 h out=""
  if [ "$(co17_is_v2)" = 0 ]; then printf '%s' "${DN[*]}"; return; fi
  # ① 优先"该库有 close 事件"的副本（= flush 过自己的 memtable = writer/leader；follower 全程 0 条）
  for h in "${DN[@]}"; do [ "$(ttl_close_cnt "$h" "$db")" -gt 0 ] && out="$out $h"; done
  # ② 退一步："持有该库 sequence 文件"的副本（leader 落 seq；follower 走 LOAD 路径只落 unseq）
  if [ -z "$out" ]; then for h in "${DN[@]}"; do [ "$(cmp_seq_cnt "$h" "$db")" -gt 0 ] && out="$out $h"; done; fi
  # ③ 都还没有 ⇒ 退回全部副本（否则"判据集为空"会被静默算过）
  [ -z "$out" ] && out=" ${DN[*]}"
  printf '%s' "${out# }"; }
# 探一次判据集布局，结果放进全局（一个判据内不重复 ssh）：
#   CO17_JUDGE      判据集节点；CO17_JUDGE_SPEC 判据集逐副本布局（"78:1/1/0/0 "）
#   CO17_JUDGE_UNI  判据集布局去重串（"1/1/0/0 "）；CO17_OTHER_SPEC/UNI 非判据副本（V2 follower，证据）
co17_lay_probe(){ local db=$1 h lay judge
  judge=$(co17_judge_nodes "$db")
  CO17_JUDGE="$judge"; CO17_JUDGE_SPEC=""; CO17_OTHER_SPEC=""
  for h in $judge; do lay=$(co17_lay_of "$h" "$db"); CO17_JUDGE_SPEC="$CO17_JUDGE_SPEC${h##*.}:$lay "; done
  for h in "${DN[@]}"; do case " $judge " in *" $h "*) continue ;; esac
    CO17_OTHER_SPEC="$CO17_OTHER_SPEC${h##*.}:$(co17_lay_of "$h" "$db") "; done
  CO17_JUDGE_UNI=$(printf '%s\n' "$CO17_JUDGE_SPEC" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' ')
  CO17_OTHER_UNI=$(printf '%s\n' "$CO17_OTHER_SPEC" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' ')
}
# 判据：判据集布局是否全 == want（**用返回码**：0=达标；同时刷新上面那组 CO17_* 证据变量）
co17_lay_verdict(){ local db=$1 want=$2; co17_lay_probe "$db"; [ "$CO17_JUDGE_UNI" = "$want " ]; }
# follower 证据：非判据副本布局与 want 不同 ⇒ 只 WARN + 打印逐副本布局（V2 设计差异，不判 FAIL）
co17_warn_followers(){ local tag=$1 want=$2
  [ -n "${CO17_OTHER_SPEC:-}" ] || return 0
  [ "${CO17_OTHER_UNI:-}" = "$want " ] && return 0
  warn "  $tag：非判据副本布局 ${CO17_OTHER_SPEC% } 与判据集（${CO17_JUDGE_SPEC:-（未探测）}）不同 —— V2 follower 的 TsFile 落 unsequence（IoTConsensusV2Receiver.java:734 → DataRegion.java:4984/5009，设计差异、非缺陷），判据只看 leader"; }
# 统一的布局判据入口：co17_check_lay <tag> <db> <want>（判据集达标 ⇒ pass；否则 fail，并附全部副本布局）
co17_check_lay(){ local tag=$1 db=$2 want=$3
  if co17_lay_verdict "$db" "$want"; then
    pass "  $tag（判据集 ${CO17_JUDGE_SPEC% } = $want）"
    co17_warn_followers "$tag" "$want"
  else
    fail "  $tag 未成立：判据集 ${CO17_JUDGE_SPEC:-（空）} 未达 $want（各副本 $(co17_lay "$db")）"
  fi; }
# 判据集的 seq/unseq 计数（去重串），等待用
co17_su_judge(){ local db=$1 h spec=""
  for h in $(co17_judge_nodes "$db"); do spec="$spec${h##*.}:$(cmp_seq_cnt "$h" "$db")/$(cmp_unseq_cnt "$h" "$db") "; done
  printf '%s' "$spec"; }
co17_su_judge_uni(){ co17_su_judge "$1" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' '; }
# 逐节点 flush + 等**判据集**的 seq/unseq 计数统一 == want（V1=全部副本 / V2=leader）；
# 0=达成，1=超时。输出循环次数。（改前是"各副本都达标" ⇒ V2 下永远等不到、每次白等满窗口）
co17_wait_su(){ local db=$1 want=$2 t=${3:-150} dl h i=0
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 ))
    [ "$(co17_su_judge_uni "$db")" = "$want " ] && { echo "$i"; return 0; }
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i"; return 1; }
# 等**判据集**的层级布局（L0..L3）== want（如 1/1/0/0）；0=达成，1=超时
co17_wait_lay(){ local db=$1 want=$2 t=${3:-150} dl h i=0
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 ))
    co17_lay_verdict "$db" "$want" && { echo "$i"; return 0; }
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i"; return 1; }
co17_mkdb(){ local db=$1
  sq "create database $db;" >/dev/null
  sq "create timeseries $db.d1.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null; }
# 等**判据集**每台副本"该库的 close 事件数" >= min（绝对门槛）。
# 改动前要求"三副本都达标"：V2 的 follower 不 flush memtable ⇒ 它整轮 `Async close tsfile` = 0 条
#   （实测 colevelg：78:4 / 77:0 / 79:0）⇒ 每批都要白等满 90s；现在只对判据集（V1=全部副本 /
#   V2=leader，动态识别）设硬门槛，follower 的 close 数仍由 co17_batch 的 WARN 打印作证据。
# 不用 `ensure_closed`：它要求"比快照**增加**"，而 flush 常常在取快照前就已完成 ⇒ 假报未落盘。
co17_wait_close(){ local db=$1 min=$2 t=${3:-90} dl h n ok i=0 nodes
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 )); ok=1; nodes=$(co17_judge_nodes "$db")
    for h in $nodes; do n=$(ttl_close_cnt "$h" "$db"); [ "${n:-0}" -ge "$min" ] || ok=0; done
    [ "$ok" = 1 ] && { echo "$i"; return 0; }
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i"; return 1; }
# 写一批（单设备 d1，ROWS 个点，时间戳递增），并等各副本文件布局达到 want
# **必须先等 close 事件**：`flush;` 返回后 TsFile 仍是 UNCLOSED/appendable，此时写下一批会被
# "追加进同一个文件"（实测 78 得到 2 个文件、77/79 只有 1 个——数据都在、但布局不可控）。
co17_batch(){ local db=$1 b=$2 base=$3 want=$4 k vals=""
  for ((k=1;k<=ROWS;k++)); do vals="$vals($(( base + k*10 )),$((k+b))),"; done
  sq "insert into $db.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  co17_wait_close "$db" "$b" 90 >/dev/null || warn "    批$b：close 事件未达 $b（$(ttl_close_snapshot "$db")）"
  if co17_wait_lay "$db" "$want" 120 >/dev/null; then log "    批$b 就绪：布局=$(co17_lay "$db")（各副本去重 $(co17_lay_uni "$(co17_lay "$db")")）"
  else warn "    批$b 未达预期布局 $want（各副本 $(co17_lay "$db")）——后续判据按判据集实际情况记录"; fi
  sleep 3
  return 0; }
# 某库 inner/cross 任务的"单任务文件数"分布，形如 "2×3 4×1 "
# ⚠️ cross 分支必须带 `[Compaction] ` 前缀：`[Compaction] InsertionCrossSpaceCompaction task
#    starts with unseq file …` 含 `CrossSpaceCompaction task starts with` 子串（同 co17_cross_unseq_nums）。
co17_task_nums(){ local db=$1 kind=$2 h pat
  case "$kind" in
    cross) pat='[Compaction] CrossSpaceCompaction task starts with' ;;
    *)     pat='InnerSpaceCompaction task starts with' ;;
  esac
  for h in "${DN[@]}"; do
    sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -E '(^|[- ])(root\.)?$db-[0-9]+' | sed -E 's/.*starts with ([0-9]+) files.*/\1/'" 2>/dev/null
  done | grep -E '^[0-9]+$' | sort -n | uniq -c | awk '{printf "%s×%s ", $2, $1}'; echo; }
co17_task_cnt(){ local db=$1 kind=$2 h pat n s=0
  case "$kind" in
    cross) pat='[Compaction] CrossSpaceCompaction task starts with' ;;
    *)     pat='InnerSpaceCompaction task starts with' ;;
  esac
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done; echo "${s:-0}"; }
# cross 任务里**每个任务收了几个 unseq 文件**的分布，形如 "1×9 3×3 "。
# 日志格式（`CrossSpaceCompactionTask:158`）：`… [Compaction] CrossSpaceCompaction task starts with N seq files and M unsequence files.`
# ⚠️ 两个坑：① 数量词是 "N seq files and M unsequence files"，不是 "N files"（第一版正则写错 ⇒ 分布恒空）；
#           ② 前缀必须带 `[Compaction] CrossSpaceCompaction`，否则会连
#              `InsertionCrossSpaceCompaction task starts with unseq file …`（把 unseq 挪进 seq 的任务）一起匹配。
co17_cross_unseq_nums(){ local db=$1 h
  for h in "${DN[@]}"; do
    sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '[Compaction] CrossSpaceCompaction task starts with' | grep -E '(^|[- ])(root\.)?$db-[0-9]+' | sed -E 's/.*and ([0-9]+) unsequence files.*/\1/'" 2>/dev/null
  done | grep -E '^[0-9]+$' | sort -n | uniq -c | awk '{printf "%s×%s ", $2, $1}'; echo; }
co17_task_max(){ printf '%s\n' "$1" | awk '{for(i=1;i<=NF;i++){split($i,a,"×"); if(a[1]+0>m) m=a[1]+0}} END{print m+0}'; }

# ============================================================ 集群准备（全程只重启一次）
# 关键：`inner_seq_selector` 用**默认的 size_tiered_multi_target**（= NewSizeTieredCompactionSelector），
#       否则 max_level_gap_in_inner_compaction / inner_compaction_total_file_num_threshold 不参与选择。
log "--- 集群准备：三类合并先关；selector=默认 multi_target；candidate=2；interval=${CMP_INTERVAL_MS}；gap=0 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,min_cross_compaction_unseq_file_level=0" cmp_cluster_prepare
for kv in inner_seq_selector=size_tiered_multi_target max_level_gap_in_inner_compaction=0 inner_compaction_candidate_file_num=2; do
  k=${kv%%=*}; want=${kv#*=}; got=$(cmp_eff "${DN[0]}" "$k")
  assert_eq "  生效值 $k" "$got" "$want"
done

# ============================================================ 段 1：层级 gap 边界
log "--- 段 1：max_level_gap_in_inner_compaction 边界（[L1,L0] 与 [L2,L0]）---"
DBG="${DB}g"
cmp_compaction_off
co17_mkdb "$DBG"
NOW=$(now_ms)
co17_batch "$DBG" 1 "$NOW" "1/0/0/0"
co17_batch "$DBG" 2 "$(( NOW + 20000 ))" "2/0/0/0"
log "  两批 L0 → 开合并（gap=0）造 L1"
cmp_set_hot enable_seq_space_compaction true >/dev/null
co17_wait_lay "$DBG" "0/1/0/0" 150 >/dev/null
co17_check_lay "两批 L0 合并为 L1" "$DBG" "0/1/0/0"
cmp_set_hot enable_seq_space_compaction false >/dev/null
co17_batch "$DBG" 3 "$(( NOW + 40000 ))" "1/1/0/0"
FP0=$(cmp_fp_tree "$DBG")
log "  场景 A 就绪：[L1(旧), L0(新)]，布局=$(co17_lay "$DBG")"
if co17_lay_verdict "$DBG" "1/1/0/0"; then
  pass "  场景 A 有效：判据集（${CO17_JUDGE_SPEC% }）均为 L1×1 + L0×1"
  co17_warn_followers "场景 A（[L1, L0] 就绪）" "1/1/0/0"
else warn "  场景 A 在判据集上不完全一致（${CO17_JUDGE_SPEC:-（空）}；各副本 $(co17_lay "$DBG")）——结论按判据集实际情况记录"; fi

# A-1：gap=0 不应合并
FIN_A0=$(cmp_inner_finish "$DBG")
log "  A-1 gap=0 开合并，等 ${WIN}s（层级差 1 > gap=0 ⇒ 期望不合并）"
cmp_set_hot max_level_gap_in_inner_compaction 0 >/dev/null
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep "$WIN"
FIN_A1=$(cmp_inner_finish "$DBG"); co17_lay_verdict "$DBG" "1/1/0/0"; LAY_A=$?
log "    布局=$(co17_lay "$DBG") finishes=$FIN_A0 → $FIN_A1"
if [ "$FIN_A1" = "$FIN_A0" ] && [ "$LAY_A" = 0 ]; then
  pass "  A-1 gap=0：|0-1| = 1 > 0 ⇒ L1 与 L0 未合并（finishes 不增、判据集 ${CO17_JUDGE_SPEC% } 仍 1/1/0/0）"
  co17_warn_followers "A-1（gap=0 期望不合并）" "1/1/0/0"
else
  fail "  A-1 gap=0：期望不合并，实际 finishes=$FIN_A0 → $FIN_A1，判据集 ${CO17_JUDGE_SPEC:-（空）}（各副本 $(co17_lay "$DBG")）"
fi

# A-2：gap=1 应合并出 L2
log "  A-2 热改 gap=1（层级差 1 <= 1 ⇒ 期望合并出 L2）"
cmp_set_hot max_level_gap_in_inner_compaction 1 >/dev/null
assert_eq "    热改后 gap 生效值" "$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction)" "1"
co17_wait_lay "$DBG" "0/0/1/0" 150 >/dev/null
co17_check_lay "A-2 gap=1：[L1, L0] 被合并，产出 L2" "$DBG" "0/0/1/0"
cmp_assert_same "  A 合并前后数据指纹" "$FP0" "$(cmp_fp_tree "$DBG")"

# B：造 [L2, L0]，gap 边界 1 → 2
cmp_set_hot enable_seq_space_compaction false >/dev/null
co17_batch "$DBG" 4 "$(( NOW + 60000 ))" "1/0/1/0"
FP1=$(cmp_fp_tree "$DBG")
log "  场景 B 就绪：[L2(旧), L0(新)]，布局=$(co17_lay "$DBG")"
FIN_B0=$(cmp_inner_finish "$DBG")
log "  B-1 gap=1 开合并，等 ${WIN}s（层级差 2 > gap=1 ⇒ 期望不合并）"
cmp_set_hot max_level_gap_in_inner_compaction 1 >/dev/null
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep "$WIN"
FIN_B1=$(cmp_inner_finish "$DBG"); co17_lay_verdict "$DBG" "1/0/1/0"; LAY_B=$?
log "    布局=$(co17_lay "$DBG") finishes=$FIN_B0 → $FIN_B1"
if [ "$FIN_B1" = "$FIN_B0" ] && [ "$LAY_B" = 0 ]; then
  pass "  B-1 gap=1：|0-2| = 2 > 1 ⇒ L2 与 L0 未合并（finishes 不增、判据集 ${CO17_JUDGE_SPEC% } 仍 1/0/1/0）"
  co17_warn_followers "B-1（gap=1 期望不合并）" "1/0/1/0"
else
  fail "  B-1 gap=1：期望不合并，实际 finishes=$FIN_B0 → $FIN_B1，判据集 ${CO17_JUDGE_SPEC:-（空）}（各副本 $(co17_lay "$DBG")）"
fi
log "  B-2 热改 gap=2（层级差 2 <= 2 ⇒ 期望合并出 L3）"
cmp_set_hot max_level_gap_in_inner_compaction 2 >/dev/null
co17_wait_lay "$DBG" "0/0/0/1" 150 >/dev/null
co17_check_lay "B-2 gap=2：[L2, L0] 被合并，产出 L3" "$DBG" "0/0/0/1"
cmp_assert_same "  B 合并前后数据指纹" "$FP1" "$(cmp_fp_tree "$DBG")"

# ============================================================ 段 2：文件数上限 × 候选门槛
log "--- 段 2：inner_compaction_total_file_num_threshold × inner_compaction_candidate_file_num ---"
co17_thr_run(){ local db=$1 thr=$2 cand=$3 n=$4 base b k dl ok=0
  cmp_compaction_off
  cmp_set_hot max_level_gap_in_inner_compaction 0 >/dev/null
  cmp_set_hot inner_compaction_total_file_num_threshold "$thr" >/dev/null
  cmp_set_hot inner_compaction_candidate_file_num "$cand" >/dev/null
  log "  [$db] threshold=$thr candidate=$cand：生效值 thr=$(cmp_eff "${DN[0]}" inner_compaction_total_file_num_threshold) cand=$(cmp_eff "${DN[0]}" inner_compaction_candidate_file_num)"
  co17_mkdb "$db"; base=$(now_ms)
  for ((b=1;b<=n;b++)); do co17_batch "$db" "$b" "$(( base + b*20000 ))" "${b}/0/0/0"; done
  log "    [$db] 起点：布局=$(co17_lay "$db") files=$(cmp_all_sum "$db")"
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  local fin0 fin1; fin0=$(cmp_inner_finish "$db"); dl=$(( $(date +%s) + 120 ))
  while (( $(date +%s) < dl )); do
    fin1=$(cmp_inner_finish "$db"); [ "${fin1:-0}" -gt "${fin0:-0}" ] && { ok=1; break; }; sleep 3
  done
  sleep 10
  local dist; dist=$(co17_task_nums "$db" inner)
  log "    [$db] 合并后：布局=$(co17_lay "$db") files=$(cmp_all_sum "$db") finishes=$fin0→$fin1 任务文件数分布=$dist"
  [ "$ok" = 1 ] || fail "    [$db] 合并未推进（finishes=$fin0）"
  echo "$dist"; }
DIST_SMALL=$(co17_thr_run "${DB}thr2" 2 3 3 | tail -1)
co17_task_max "$DIST_SMALL" | grep -qx 2 && pass "  段2① threshold=2：任务最多 2 个文件（分布 ${DIST_SMALL:-空}）⇒ 单任务文件数上限生效" \
  || fail "  段2① threshold=2：出现 >2 文件的任务或没有任务（分布 ${DIST_SMALL:-空}）"
if co17_lay_verdict "${DB}thr2" "1/1/0/0"; then
  pass "  段2① 3 个 L0 → 合并掉 2 个，剩 L1×1 + L0×1（判据集 ${CO17_JUDGE_SPEC% }；2 个文件 < 门槛 3 仍被提交 ⇒ 非活跃分区绕过 candidate 门槛）"
  co17_warn_followers "段2①（threshold=2）" "1/1/0/0"
else warn "  段2① 合并后判据集布局=${CO17_JUDGE_SPEC:-（空）}（期望 1/1/0/0；各副本 $(co17_lay "${DB}thr2")）"; fi
DIST_BIG=$(co17_thr_run "${DB}thr100" 100 2 3 | tail -1)
co17_task_max "$DIST_BIG" | grep -qx 3 && pass "  段2② threshold=100：一个任务收 3 个文件（分布 ${DIST_BIG:-空}）⇒ 上限随配置放大" \
  || fail "  段2② threshold=100：未出现 3 文件任务（分布 ${DIST_BIG:-空}）"
if co17_lay_verdict "${DB}thr100" "0/1/0/0"; then
  pass "  段2② 3 个 L0 → 全部合并为 L1×1（判据集 ${CO17_JUDGE_SPEC% }）"
  co17_warn_followers "段2②（threshold=100）" "0/1/0/0"
else warn "  段2② 合并后判据集布局=${CO17_JUDGE_SPEC:-（空）}（期望 0/1/0/0；各副本 $(co17_lay "${DB}thr100")）"; fi

# ============================================================ 段 3：cross 候选上限截断
log "--- 段 3：max_cross_compaction_candidate_file_num / _file_size 截断 ---"
co17_cross_scene(){ local db=$1 base=$2 b k vals
  cmp_compaction_off
  co17_mkdb "$db"
  # seq 水位：把时间范围**拉宽**（[base+102000, base+500000]），并让后面的乱序批次落在它的区间**内**。
  # 为什么要重叠：`RewriteCrossSpaceCompactionSelector` 对"与 seq 不重叠"的 unseq 会走
  # `getLatestSealedSeqFile()` 特殊路径（每任务最多只收 2 个 unseq，实测），
  # 只有重叠路径才是常规语义（上限放大后一个任务能收下全部 unseq）。
  vals=""; for ((k=1;k<=ROWS;k++)); do vals="$vals($(( base + 100000 + k*2000 )),$((k+9))),"; done
  sq "insert into $db.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  co17_wait_close "$db" 1 90 >/dev/null || warn "    [$db] seq 水位：close 事件未达 1"
  co17_wait_su "$db" "1/0" 120 >/dev/null
  for b in 1 2 3; do
    # 落 unseq（时间戳在 seq 水位区间内、但都小于水位最大值 ⇒ 判定为乱序），三批互相重叠
    vals=""; for ((k=1;k<=ROWS;k++)); do vals="$vals($(( base + 100000 + b*300 + k*1500 + 7 )),$((k+b))),"; done
    sq "insert into $db.d1(time,s1) values ${vals%,};" >/dev/null
    sq "flush;" >/dev/null
    co17_wait_close "$db" "$(( 1 + b ))" 90 >/dev/null || warn "    unseq 第 $b 批：close 事件未达 $(( 1 + b ))"
    co17_wait_su "$db" "1/$b" 150 >/dev/null && log "    unseq 第 $b 个文件就绪：$(co17_su "$db")"
  done
  log "    [$db] cross 场景：$(co17_su "$db")（每副本 1 seq + 3 unseq，且时间区间互相重叠）"; }
co17_cross_run(){ local db=$1 num=$2 size=$3 tag=$4 u0 ts0 fp0 dl ok=0
  co17_cross_scene "$db" "$(( $(now_ms) - 3600000 ))"
  u0=$(cmp_unseq_sum "$db"); ts0=$(cmp_all_sum "$db"); fp0=$(cmp_fp_tree "$db")
  cmp_set_hot min_cross_compaction_unseq_file_level 0 >/dev/null
  cmp_set_hot max_cross_compaction_candidate_file_num "$num" >/dev/null
  cmp_set_hot max_cross_compaction_candidate_file_size "$size" >/dev/null
  log "  [$tag] 起点 unseq=$u0 files=$ts0；上限 num=$num size=$size（生效值 num=$(cmp_eff "${DN[0]}" max_cross_compaction_candidate_file_num) size=$(cmp_eff "${DN[0]}" max_cross_compaction_candidate_file_size)）"
  cmp_set_hot enable_cross_space_compaction true >/dev/null
  dl=$(( $(date +%s) + 180 ))
  while (( $(date +%s) < dl )); do
    [ "$(cmp_unseq_sum "$db")" = "0" ] && { ok=1; break; }; sleep 3
  done
  sleep 5
  local dist cnt mx
  dist=$(co17_cross_unseq_nums "$db"); cnt=$(co17_task_cnt "$db" cross); mx=$(co17_task_max "$dist")
  log "  [$tag] unseq $u0 → $(cmp_unseq_sum "$db")；cross 任务数=$cnt 每任务 unseq 数分布=$dist 最大值=$mx"
  [ "$ok" = 1 ] && pass "  [$tag] 跨空间合并完成（unseq 归零）" || fail "  [$tag] unseq 未归零（$(cmp_unseq_sum "$db")）"
  cmp_assert_same "  [$tag] 合并前后数据指纹" "$fp0" "$(cmp_fp_tree "$db")"
  echo "$dist|$cnt|$mx"; }
RES_A=$(co17_cross_run "${DB}x1" 2 5368709120 "num=2" | tail -1)
DIST_A=${RES_A%%|*}; rest=${RES_A#*|}; CNT_A=${rest%%|*}; MAX_A=${rest##*|}
RES_B=$(co17_cross_run "${DB}x2" 500 5368709120 "num=500（默认）" | tail -1)
DIST_B=${RES_B%%|*}; rest=${RES_B#*|}; CNT_B=${rest%%|*}; MAX_B=${rest##*|}
RES_C=$(co17_cross_run "${DB}x3" 500 1 "num=500+size=1B" | tail -1)
DIST_C=${RES_C%%|*}; rest=${RES_C#*|}; CNT_C=${rest%%|*}; MAX_C=${rest##*|}
log "  对照：A(num=2) 任务数=$CNT_A 单任务最多 $MAX_A 个 unseq ｜ B(num=500) 任务数=$CNT_B 最多 $MAX_B ｜ C(size=1B) 任务数=$CNT_C 最多 $MAX_C"
[ "${MAX_A:-0}" = 1 ] && pass "  文件数上限截断：num=2 时每个 cross 任务只收 1 个 unseq（分布 ${DIST_A:-空}）" \
  || fail "  文件数上限未截断：num=2 时单个任务最多收 $MAX_A 个 unseq（分布 ${DIST_A:-空}）"
[ "${MAX_B:-0}" = 3 ] && pass "  上限放大后可多收：num=500 时一个任务收下全部 3 个 unseq（分布 ${DIST_B:-空}）" \
  || fail "  num=500 时未收下 3 个 unseq：最多=$MAX_B（分布 ${DIST_B:-空}）"
[ "${CNT_B:-0}" -lt "${CNT_A:-0}" ] && pass "  任务数随上限下降：num=2 任务数=$CNT_A > num=500 任务数=$CNT_B" \
  || warn "  任务数：num=2 → $CNT_A，num=500 → $CNT_B（未下降，记录）"
[ "${MAX_C:-0}" = 1 ] && pass "  文件大小上限截断：num=500 但 size=1B 时每个任务仍只收 1 个 unseq（分布 ${DIST_C:-空}）" \
  || fail "  文件大小上限未截断：size=1B 时单个任务最多收 $MAX_C 个 unseq（分布 ${DIST_C:-空}）"

log "--- 收尾三件套（基准库用段 3 的 Run B 库）---"
post_checks "select count(s1) from ${DB}x2.d1 order by time;" tree
cmp_case_finish "" tree ""
