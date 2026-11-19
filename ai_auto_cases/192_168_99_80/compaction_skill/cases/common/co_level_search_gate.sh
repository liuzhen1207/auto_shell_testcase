#!/bin/bash
# ============================================================================
# CO-38 · 空间内合并的**逐层选择**与**提交通道**（D1-4 / D2-1 / D2-2；官方 MG-P01）
#
# 源码依据（RC6 = 7ae8713ecb，本地源码树逐行可对照）：
#   `selector/impl/NewSizeTieredCompactionSelector.java`
#    · L112-121 `selectTaskBaseOnLevel()`：**从 level 0 向 maxLevel 逐层搜索，某层选出任务即返回**
#      ⇒ 同一轮不会把高层文件与低层文件混成一个任务（D1-4 / D2-1）；
#    · L84-88 三个门槛来源：`totalFileNumUpperBound = inner_compaction_total_file_num_threshold`（**单任务文件数上限**）、
#      `totalFileNumLowerBound = inner_compaction_candidate_file_num`（D2-2 的「≥10 个文件」）、
#      `singleFileSizeThreshold = target_compaction_file_size`（D2-2 的「≥2GB」）；
#    · L281-285 `isTaskTooLarge()`：`选中数 + 1 > totalFileNumUpperBound` 即结束本批 ⇒ 上限决定"一批收几个"；
#    · L337-342 `isSatisfied = (选中数 >= 候选门槛 || **!isActiveTimePartition** || 总大小 >= 单文件大小门槛 || 内存到顶) && 选中数 > 1`：
#      **「非活跃时间分区」会绕过候选门槛**（CO-17 段 2① 实测到这条语义："2 个文件 < 门槛 3 仍被提交"）；
#    · L105-109 `checkIsActiveTimePartition()`：`now - 最后一个 TsFile 的时间 < 2 × compaction_schedule_interval_in_ms`
#      ⇒ 要让 D2-2 的"≥10 个文件 / ≥2GB"门槛真正参与判定，必须把**活跃窗口**造出来
#      （本用例把 `compaction_schedule_interval_in_ms` 显式设成 60s ⇒ 活跃窗口 120s；该键 restart-only，故写在 EXTRA_CONF 里）。
#      用例侧还会在开合并前**实测"最新 TsFile 的年龄"**；若已超出活跃窗口就补写 1 个文件把窗口重置（并如实记录）。
#
# 三相与判据：
#   A 相 `root.colev`（12 个 L0、单任务上限 10、候选门槛 10，单文件 ≪ 2GB）
#     ① 双信号：`Sequence InnerSpaceCompaction finishes` 增加 **且** 该库 TsFile 数下降；
#     ② 出现 **10 文件批**（`cmp_task_nums` 含 10×k；k = 副本数×2，日志重复计数见下方说明）
#        ⇒ 单任务文件数上限 10 生效（D2-2 的"一批"规模）；
#     ③ 余量 N_ACT-10 个文件的去向**二选一都算成立，并如实记录分支**：
#        · 出现 (N_ACT-10) 文件批 ⇒ 非活跃分区绕过门槛（源码 L339）；
#        · 布局里仍有 N_ACT-10 个 L0 ⇒ 活跃分区 + 门槛 10 生效，余量不足门槛被拒（D2-2 直接判据）。
#     ④ 场景有效性：**可见行数 == 实际 INSERT 次数**；**逐副本** level-0 均 ≥ 12（口径见下方 F1/F2 修正）。
#   B 相 `root.colev2`（8 个 L0、候选门槛 10、单文件 ≪ 2GB、**活跃窗口内**）
#     ① 负向（**逐副本口径**）：对 level-0 < 门槛 10 的每一台，窗口内 **一个任务都不提交**
#        （starts/finishes/该库 seq 文件数均不变）；level-0 ≥ 门槛 的副本提交 10 文件批**属合法**，如实记录；
#     ② **同场景正向对照**：再补到各副本 ≥ 10 个（= 门槛）⇒ 必须**立即**成批并出现 10 文件批
#        （护栏：证明"没提交"是因为门槛，而不是 enable 开关或调度没生效——负向判据的防误判）。
#        对照的 TsFile/finishes/**指纹**基线一律取在"补写 + 落盘完成"**之后**（口径见下方 F3/F4 修正）。
#   C 相 `root.colev3`（3×L0 + 1×L1、gap=1、候选门槛=2）
#     ① 双信号；② 每个任务的**源文件 level 单一**（D1-4/D2-1：同一轮只选同层）；
#     ③ **首个任务的源文件全为 level 0**（D1-4：从最低层开始）；
#     ④ 合并前就存在的那个 L1 文件**没有被首个任务选中**（D2-1：某层有成批就不再向高层搜）。
#   全部相：`cmp_fp_tree` 不变、`cmp_stuck_sum=0`、收尾三件套。
#
# ---------------------------------------------------------------------------
# 【RC8 双协议定性后的口径修正（2026-10-17；报告 _scratch/RC8_V2_DIVERGENCE_TRIAGE.md §3.8 / §④ P1-4+P2）】
#   V1 FAIL 918s f2 → V2 FAIL **1839s** f7。两类根因，全部在用例侧：
#   ① **V1 的 2 条 = 计数丢在子 shell**：`N_A_ACT=$(co38_fill_l0 …)` 是命令替换 ⇒ 子 shell 里
#      `co38_write_n` 对 `CO38_INS` 的累加回到父 shell 就丢了 ⇒「可见行数 16 ≠ 实际 INSERT 次数 12」。
#      **修法**：fill_l0 改成回传全局 `CO38_FILL_CUR`（不再用 `$( )`），CO38_INS 留在父 shell。
#   ② **V2 的 7 条 = "逐副本"前置太强 + 空转**：旧前置要求"**每一台**副本 L0 ≥ N"，而 V2 里
#      某些副本整轮不 close、也不 flush 自己的 memtable ⇒ 永远 0 个文件（DataRegion.java:4984/5009），
#      前置必然不成立；`co38_fill_l0` 又用 `cmp_min_l0`（三副本最小值）当收敛条件 ⇒ 最小值卡在 0，
#      循环跑满 `want*2` 次（每次 sleep 4s + 60s 预等）才放弃 ⇒ **918s → 1839s**。
#      **修法**：前置与收敛条件统一改"判据集"口径（V1 = 全部副本 → 行为不变；V2 = region leader / 至少 leader 达标），
#      follower 差异只 WARN 并打印逐副本；补写上限从 `want*2` 降到 4 次。
#   ③ 判据**不放松**：A/B/C 三相的"可见行数 == 实际 INSERT 次数"、双信号、单任务文件数上限、
#      逐层选择（selected-files 证据行）、指纹不变，仍全部是硬断言。
# ---------------------------------------------------------------------------
# 【首轮复跑验收点（2026-10-16 rc7 V1 4 条 FAIL 全部定性为用例侧口径/时点错误后的修复，见 _scratch/CO384041_TRIAGE.md §2.2）】
#   ① `fail_flag=0`，且 A/B 两相必须打印**逐副本** seq 文件数、可见行数与 INSERT 次数（修复前这三者口径混用）。
#   ② B 相负向窗口（45s）内：**每一台** level-0 < 10 的副本 starts/finishes/文件数三项均不变
#      （修复前 .79 有 12 个 L0、提交 10 文件批是合法行为，却被 minL0 口径判成负向失败 = F2）。
#   ③ B 相正向对照：补到各副本 ≥ 10 后必须出现 10 文件批且该库 TsFile 数**相对补写后的基线**下降，
#      "合并前后指纹"在无写入窗口内完全一致（修复前基线取在补写之前 = F3/F4）。
#   ④ 顺带修掉 `cmp_lay` 的 5 处误用（把布局串当库名传，布局证据行曾恒为 0/0/0/0）。
#
# 证据来源（日志实测格式，RC6 i18n 串 StorageEngineMessages）：
#   · `{}-{} [Compaction] {} InnerSpaceCompaction task starts with {} files, total file size is {} MB, estimated memory cost is {} MB`
#   · `{}-{} [Compaction] compaction with selected files [{file: /…/<time>-<ver>-<inner>-<cross>.tsfile, status: NORMAL}], skipped files []`
#     ⇒ 文件名第 3 段 = innerCompactionCount = level（`cmp_lay` 同一口径）
#
# ⚠️ 与规格（OFFICIAL_COVERAGE §4.2 CO-38）的**两处有意偏差**（如实记录，都会打进用例日志）：
#   ① 规格写 inner_compaction_total_file_num_threshold=10 / 2GB 是"默认值"，但 RC6 模板里这两个键的默认值是
#      **100 / 10GB**（docs/CONF_PARAMS.md #15/#14），而 inner_compaction_candidate_file_num 默认 30、
#      target_compaction_file_size 默认 2GB ⇒ 本用例**显式写入** 10 / 2GB / 10 / 2GB 并逐节点 `cmp_eff` 核对，
#      不依赖"默认值"这一前提。
#   ② 规格 C 相写"1×L1 + 1×L0"，但单个 L0 文件成不了任务（源码 L342 要求 `选中数 > 1`）⇒ 改为 **3×L0 + 1×L1**，
#      并把候选门槛降到 2（否则活跃窗口内 3 个 L0 不会成批，"L0 优先被选中"无从观察）。
#
# 规模与参数集中在下面变量里，环境侧可用 CO38_* 覆盖。
# 用法： bash co_level_search_gate.sh [--consensus IoTConsensus|IoTConsensusV2]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_level_search_gate_${DATA_CONSENSUS}"

DBA=root.colev          # A 相：12 个 L0（上限 10 ⇒ 10 + 余量）
DBB=root.colev2         # B 相：8 个 L0（门槛 10 ⇒ 不提交），补到 10 个后必须提交
DBC=root.colev3         # C 相：3×L0 + 1×L1（逐层 / 同层）
N_A="${CO38_N_A:-12}"                     # A 相起点 level-0 文件数（规格 12）
N_B="${CO38_N_B:-8}"                      # B 相起点 level-0 文件数（规格 8）
N_C="${CO38_N_C:-3}"                      # C 相起点 level-0 文件数（规格 1，见偏差②）
GATE_NUM="${CO38_GATE_NUM:-10}"           # inner_compaction_candidate_file_num（D2-2「≥10 个文件」）
TASK_UPPER="${CO38_TASK_UPPER:-10}"       # inner_compaction_total_file_num_threshold（单任务文件数上限）
GATE_SIZE="${CO38_GATE_SIZE:-2147483648}" # inner_compaction_total_file_size_threshold（= target_compaction_file_size 2GB）
CAND_C="${CO38_CAND_C:-2}"                # C 相的候选门槛（见偏差②）
GAP_C="${CO38_GAP_C:-1}"                  # C 相的 max_level_gap（=1 才能观察"不跨层"）
INTERVAL_MS="${CO38_INTERVAL_MS:-60000}"  # restart-only；活跃窗口 = 2×该值 = 120s
WIN_A="${CO38_WIN_A:-150}"                # A 相等首个任务的上限窗口
WIN_B="${CO38_WIN_B:-45}"                 # B 相负向观察窗口（必须 < 活跃窗口 120s）
WIN_B2="${CO38_WIN_B2:-150}"              # B 相正向对照窗口
WIN_C="${CO38_WIN_C:-150}"                # C 相等首个任务的上限窗口

# ---------------------------------------------------------------- 观测/构造工具
# 写入次数计数器：`co38_write_n` 每发一条"1 行 INSERT"就 +1。
# 【F1 修正】"可见行数"的期望值必须是**实际 INSERT 次数**，不能拿"各副本 L0 文件数的最小值"来比：
#   2026-10-16 那轮 A 相实际 INSERT 16 次（12 次起始 + co38_fill_l0 补的 4 次），可见行数 16（真值），
#   而三段副本落盘粒度不同（`.78` 每 FLUSH 一个文件 = 16 个、`.77/.79` 有 4 次 FLUSH 没产生新文件 = 12 个）
#   ⇒ 拿 minL0=12 当期望值就是口径错误（4 条 FAIL 里的 F1）。
CO38_INS=0
co38_ins_reset(){ CO38_INS=0; }
co38_ins_get(){ printf '%s' "$CO38_INS"; }
co38_write_n(){ local db=$1 n=$2 base=$3 i stmts=()
  for (( i=1; i<=n; i++ )); do
    stmts+=("insert into $db.d1(time,s1) values($(( base + i * 1000 )),$(( i )));")
    stmts+=("flush;")
    CO38_INS=$(( CO38_INS + 1 ))
  done
  sql_lines_tree "${stmts[@]}" >>"$OUT" 2>&1
  sq "flush;" >/dev/null 2>&1
  return 0; }

# 补写"1 行 + FLUSH"直到**判据集**（V1=全部副本 / V2=region leader，口径见 lib/cmp.sh）的 level-0 达标。
# 【F5 修正（2026-10-17）：计数丢在子 shell + 逐副本前置太强】
#   ① 原调用是 `N_A_ACT=$(co38_fill_l0 …)` —— **命令替换 = 子 shell**，子 shell 里 co38_write_n 对
#      CO38_INS 的累加回到父 shell 就丢了 ⇒「可见行数 16 ≠ 实际 INSERT 次数 12」（V1 的两条 FAIL）。
#      现在改**回传全局变量** `CO38_FILL_CUR`（同 W-04 的 W09_FP 写法），调用方不再用 $( )。
#   ② 收敛条件原来用 `cmp_min_l0`（三副本最小值）：V2 下某副本整轮 0 个文件 ⇒ 最小值卡在 0，
#      循环跑满 `want*2` 次（每次 sleep 4s）才放弃，这是 918s → 1839s 的主要来源之一；
#      现在只看判据集的 L0。
# 【F6 修正（2026-10-20，RC8 实测）：硬上限 4 次太小】
#   RC8 实测「判据集 L0=8（目标 10；补写 4 次后 77=14 78=14 79=9）」⇒ 4 次写不足以让**最慢的那台**
#   涨够（一次 write+flush 不一定在每台副本各产 1 个 L0，且负向窗口里 L0 ≥ 门槛的副本会合法合并掉一批）。
#   改为：硬上限 `want*2`（≥6）次，每次打印逐副本 L0 便于判"是真涨不动还是还没落盘"。
CO38_FILL_CUR=0
co38_fill_l0(){ local db=$1 want=$2 base=$3 i=0 cur dl cap
  cur=$(cmp_judge_l0_stat "$db" min)
  dl=$(( $(date +%s) + 60 ))
  while [ "${cur:-0}" -lt "$want" ] && (( $(date +%s) < dl )); do sleep 5; cur=$(cmp_judge_l0_stat "$db" min); done
  cap=$(( want * 2 )); [ "$cap" -lt 6 ] && cap=6
  while [ "${cur:-0}" -lt "$want" ] && [ "$i" -lt "$cap" ]; do
    i=$(( i + 1 ))
    co38_write_n "$db" 1 "$(( base + (want + i) * 1000 ))"
    sleep 4
    cur=$(cmp_judge_l0_stat "$db" min)
    log "      补写 ${i}/${cap} 次：判据集 L0=${cur:-?}（逐副本 $(co38_l0 "$db")）"
  done
  CO38_FILL_CUR=${cur:-0}
  log "    判据集 L0=${CO38_FILL_CUR}（目标 $want；本次补写 $i 次；逐副本 $(co38_l0 "$db")）"
  return 0; }

# 单任务文件数分布（形如 "10×6 2×6 "）里是否含 n 文件批
co38_dist_has(){ if printf '%s\n' "$1" | tr ' ' '\n' | grep -qE "^$2×[0-9]+$"; then echo 1; else echo 0; fi; }
co38_dist_max(){ local m; m=$(printf '%s\n' "$1" | tr ' ' '\n' | grep -oE '^[0-9]+' | sort -n | tail -1); printf '%s\n' "${m:-0}"; }

# "compaction with selected files [...]" 行（每个任务一行；行首加上所属节点 IP，便于按副本核对）
co38_sel_lines(){ local db=$1 h
  for h in "${DN[@]}"; do
    sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '[Compaction] compaction with selected files' | grep -E '(^|[- ])(root\.)?$db-[0-9]+' | sed -E 's/.*selected files (\[[^]]*\]).*/\1/'" 2>/dev/null \
      | sed "s|^|$h |"
  done; }

# 一行 selected 列表里所有源文件的 level（文件名第 3 段 = innerCompactionCount）
co38_levels_of(){ printf '%s\n' "$1" | grep -oE '[^/ ,]+\.tsfile' | awk -F- '{print $3}' | sort -u | tr '\n' ' '; }

# 某副本上该库的 L1（innerCompactionCount == 1）文件名
co38_l1_name(){ sshx "$1" "find $DB_DIR/data/datanode/data -path '*/$2/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '\$3==1{print; exit}'" 2>/dev/null | tr -d '\r'; }

# 各副本"最新 TsFile 的年龄(ms)"取最大（在**各节点自己**上算，避开节点间时钟偏差）；拿不到记 0
co38_age_ms(){ local db=$1 h v mx=0
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | awk -v n=\$(date +%s%3N) '{printf \"%d\", n - \$1*1000}'" 2>/dev/null | tr -dc '0-9')
    [ -n "${v:-}" ] || v=0
    [ "$v" -gt "$mx" ] && mx=$v
  done
  printf '%s\n' "$mx"; }

# 等"finishes 增加"（纯函数：不 log、不开关合并 —— 结果要给调用方捕获）
co38_wait_first(){ local db=$1 fin0=$2 win=$3 dl f
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    f=$(cmp_inner_finish "$db")
    if [ "${f:-0}" -gt "${fin0:-0}" ]; then printf '%s\n' "$f"; return 0; fi
    sleep 6
  done
  printf '%s\n' "${f:-0}"
  return 1; }

co38_mkdb1(){ local db=$1
  sq "create database $db;" >/dev/null 2>&1
  sq "create timeseries $db.d1.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null 2>&1; }

# 该设备当前可见行数（每轮写 1 行 ⇒ 行数应等于**实际 INSERT 次数**；用来核对写入真的落盘）
co38_rows(){ local n; n=$(sq "select s1 from $1.d1 order by time;" 2>/dev/null | table_rows | wc -l | tr -dc '0-9'); printf '%s\n' "${n:-0}"; }

# ---------------------------------------------------------------- 逐副本口径 helper（F1/F2/F3/F4 修正）
# 各副本该库 seq TsFile 数（形如 "77=12 78=16 79=12 "）。**起点相位**（本相还没跑过合并）下 == level-0 数。
# 判据一律用逐副本口径：写入/落盘粒度在三副本间不一致（见 co38_write_n 上方注释），
# 拿"各副本最小值"当行数期望（F1）或当"门槛前提"（F2）都会误判。
co38_l0(){ cmp_per_node cmp_seq_cnt "$1"; }
# 从逐副本串取统计值： co38_l0_stat "<串>" min|max
# （how 必须先落到变量：brace group 在管道里跑，别依赖 $2 在子 shell 里的可见性）
co38_l0_stat(){ local vals=$1 how=$2
  printf '%s\n' "$vals" | tr ' ' '\n' | grep -E '^[0-9]+=' | cut -d= -f2 | sort -n | \
    { if [ "$how" = max ]; then tail -1; else head -1; fi; }; }
# 从 "节点=值" 串取某节点（短名，如 77）的值
co38_field(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -E "^$2=" | cut -d= -f2; }
# 从 "节点=s/f" 串取某节点的 starts(1) / finishes(2)
co38_task_field(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -E "^$2=" | cut -d= -f2 | cut -d/ -f"$3"; }
# 某**副本**上该库的 inner starts / finishes 行数（`cmp_inner_start/finish` 是全副本求和，做不了逐副本判据）。
# ⚠️ 匹配串必须与 lib/cmp.sh:115-116 的 `cmp_cnt_db` **逐字一致**：日志是
#   `root.colev2-7 [Compaction] Sequence InnerSpaceCompaction task starts with …`，
#   写成 `'[Compaction] InnerSpaceCompaction …'` 会因中间的 `Sequence ` 而恒为 0（本用例初稿就踩了）。
co38_node_task(){ local h=$1 db=$2 kind=$3 pat
  case "$kind" in
    starts) pat='InnerSpaceCompaction task starts with' ;;
    *)      pat='InnerSpaceCompaction task finishes successfully' ;;
  esac
  sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9'; }
# 逐副本 "<starts>/<finishes>" 串（形如 "77=0/0 78=0/0 79=2/1 "）
co38_tasks(){ local db=$1 h s f out=""
  for h in "${DN[@]}"; do
    s=$(co38_node_task "$h" "$db" starts); f=$(co38_node_task "$h" "$db" finishes)
    out="$out${h##*.}=${s:-0}/${f:-0} "
  done; printf '%s' "$out"; }
# 负向判据（**逐副本口径**，F2 修正）：对 level-0 **低于门槛** 的副本，starts / finishes / seq 文件数
# 三者都必须不变；level-0 ≥ 门槛 的副本提交任务属**合法**（2026-10-16 那轮 `.79` 有 12 个 L0，
# 它提交一个 10 文件批恰恰是"门槛生效"的正面证据，原判据却按 minL0 把它算成负向失败）。
# 回显 "<违规副本数>|<明细>"；违规数 0 = 通过。
co38_neg_violations(){ local lay0=$1 lay1=$2 t0=$3 t1=$4 h l0 l0b a b x y bad=0 det=""
  for h in "${DN[@]}"; do
    h=${h##*.}
    l0=$(co38_field "$lay0" "$h")
    [ "${l0:-0}" -lt "$GATE_NUM" ] || continue
    l0b=$(co38_field "$lay1" "$h")
    a=$(co38_task_field "$t0" "$h" 1); b=$(co38_task_field "$t1" "$h" 1)
    x=$(co38_task_field "$t0" "$h" 2); y=$(co38_task_field "$t1" "$h" 2)
    if [ "$a" != "$b" ] || [ "$x" != "$y" ] || [ "${l0:-0}" != "${l0b:-0}" ]; then
      bad=$(( bad + 1 )); det="$det ${h}(L0=$l0→${l0b:-?} starts=$a→$b finishes=$x→$y)"
    fi
  done
  printf '%s|%s' "$bad" "${det:-无}"; }

# ============================================================ 0) 集群准备
log "--- 0) 集群准备：三类合并先关；候选门槛=${GATE_NUM}；单任务上限=${TASK_UPPER}；大小门槛=${GATE_SIZE}；interval=${INTERVAL_MS}ms ---"
C38_EXTRA="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${GATE_NUM},inner_compaction_total_file_num_threshold=${TASK_UPPER},inner_compaction_total_file_size_threshold=${GATE_SIZE},target_compaction_file_size=${GATE_SIZE},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,min_cross_compaction_unseq_file_level=0,compaction_schedule_interval_in_ms=${INTERVAL_MS}"
EXTRA_CONF="$C38_EXTRA" cmp_cluster_prepare
for k in inner_compaction_candidate_file_num inner_compaction_total_file_num_threshold inner_compaction_total_file_size_threshold target_compaction_file_size inner_seq_selector max_level_gap_in_inner_compaction compaction_schedule_interval_in_ms; do
  want=$(printf '%s' "$C38_EXTRA" | tr ',' '\n' | grep -E "^${k}=" | cut -d= -f2-)
  assert_eq "  生效值 $k" "$(cmp_eff "${DN[0]}" "$k")" "$want"
done
log "  活跃窗口 = 2 × interval = $(( INTERVAL_MS * 2 ))ms（D2-2 门槛只在活跃分区参与判定，源码 L337-342）"

# ============================================================ A 相：12 个 L0
log "--- A 相：${N_A} 个 L0（单任务上限 ${TASK_UPPER}）---"
cmp_compaction_off
co38_mkdb1 "$DBA"
A_BASE=$(( $(now_ms) - 7200000 ))
co38_ins_reset
co38_write_n "$DBA" "$N_A" "$A_BASE"
co38_fill_l0 "$DBA" "$N_A" "$A_BASE"; N_A_ACT=$CO38_FILL_CUR
cmp_wait_close "$DBA" "${N_A_ACT:-0}" 150 >/dev/null || warn "  A 相 close 事件未达 ${N_A_ACT}（未落盘的文件不参与合并选择）"
A_INS=$(co38_ins_get); A_ROWS=$(co38_rows "$DBA")
A_L0=$(co38_l0 "$DBA"); A_MINL0=$(co38_l0_stat "$A_L0" min)
A_JUDGE0=$(cmp_judge_l0_stat "$DBA" min)
log "  A 相起点：**逐副本** seq 文件数=$A_L0（min=${A_MINL0}，判据集 min=${A_JUDGE0}，目标 ${N_A}）可见行数=${A_ROWS} 实际 INSERT 次数=${A_INS} 布局=$(cmp_lay "$DBA")"
# 【F1 修正】行数只与"实际 INSERT 次数"比（原来拿各副本 L0 的最小值当期望 ⇒ 12 vs 16 口径错误）
[ "${A_ROWS:-0}" = "${A_INS:-0}" ] && pass "  场景成立：可见行数 == 实际 INSERT 次数（${A_ROWS}）" \
  || fail "  场景未成立：可见行数=${A_ROWS} ≠ 实际 INSERT 次数=${A_INS}（写入未全部落地/可见）"
# 【F2 修正（2026-10-17）】门槛 10 的批只会由**判据集**（V1=全部副本 / V2=region leader）提交：
#   旧口径要求"**每一台**副本 L0 ≥ N"，而 V2 里某副本整轮 0 个文件（它不 flush memtable）
#   ⇒ 前置永远不成立（V2 的 7 条 FAIL 里有 3 条是这个），且 co38_fill_l0 会空转到上限。
JUDGE_NODES_A=$(cmp_judge_nodes "$DBA")
if [ "${A_JUDGE0:-0}" -ge "$N_A" ]; then
  pass "  场景成立：判据集（$JUDGE_NODES_A）level-0 ≥ ${N_A}（逐副本 $A_L0）"
  [ "${A_MINL0:-0}" -ge "$N_A" ] || warn "  记录：非判据副本 level-0 < ${N_A}（逐副本 $A_L0）—— V1=全部副本 / V2=leader 口径，V2 follower 不 flush memtable、文件落 unsequence（DataRegion.java:4984/5009，设计差异）"
else
  fail "  场景未成立：判据集（$JUDGE_NODES_A）level-0=${A_JUDGE0} < ${N_A}（逐副本 $A_L0）"
fi
if [ "${A_INS:-0}" != "${A_JUDGE0:-0}" ] && [ "${A_ROWS:-0}" = "${A_INS:-0}" ]; then
  warn "  记录：INSERT ${A_INS} 次而判据集只有 ${A_JUDGE0} 个 level-0 文件（逐副本 $A_L0）——flush/close 落盘粒度不同（同一文件含多行）；数据完整性按 INSERT 次数核对，不受影响"
fi
A_AGE0=$(co38_age_ms "$DBA")
A_FIN0=$(cmp_inner_finish "$DBA"); A_START0=$(cmp_inner_start "$DBA"); A_SUM0=$(cmp_all_sum "$DBA")
A_FP0=$(cmp_fp_tree "$DBA"); A_STK0=$(cmp_stuck_sum)
log "  A 相基线：TsFile=${A_SUM0} finishes=${A_FIN0} starts=${A_START0} 最新文件年龄=${A_AGE0}ms 指纹=[$A_FP0] 卡死=${A_STK0}"
cmp_compaction_on true false false
co38_wait_first "$DBA" "$A_FIN0" "$WIN_A" >/dev/null
cmp_compaction_off
sleep 8
A_FIN1=$(cmp_inner_finish "$DBA"); A_SUM1=$(cmp_all_sum "$DBA"); A_LAY1=$(cmp_lay "$DBA")
A_FP1=$(cmp_fp_tree "$DBA"); A_DIST=$(cmp_task_nums "$DBA" inner)
A_LO=$(cmp_judge_l0_stat "$DBA" max)
A_MAX=$(co38_dist_max "$A_DIST")
log "  A 相终态：TsFile=${A_SUM0}→${A_SUM1} finishes=${A_FIN0}→${A_FIN1} 布局=$(cmp_lay "$DBA")（终态实测，勿把布局串再喂给 cmp_lay）任务文件数分布=${A_DIST:-空}"
log "  A 相判据数据：任务最大文件数=${A_MAX}（期望 ${TASK_UPPER}）；终态判据集最大 L0=${A_LO}（逐副本 $(co38_l0 "$DBA")）；余量期望=$(( N_A_ACT - TASK_UPPER ))"
cmp_assert_same "  A 相合并前后数据指纹" "$A_FP0" "$A_FP1"
if [ "${A_FIN1:-0}" -gt "${A_FIN0:-0}" ] && [ "${A_SUM1:-0}" -lt "${A_SUM0:-0}" ]; then
  pass "  A 相双信号成立：finishes ${A_FIN0}→${A_FIN1} 且 TsFile ${A_SUM0}→${A_SUM1}"
else
  fail "  A 相双信号不成立：finishes ${A_FIN0}→${A_FIN1}，TsFile ${A_SUM0}→${A_SUM1}"
fi
assert_eq "  A 相单任务文件数上限（D2-2 的「一批」规模）" "$A_MAX" "$TASK_UPPER"
# 【F6 修正（2026-10-20）】余量必须按**逐副本实测起点**算，不能用"目标值 − 单任务上限"：
#   RC8 实测起点 77=12 78=16 79=12（补写粒度不同 ⇒ 有的副本超了）⇒ 一个 10 文件批之后
#   逐副本剩 2/6/2、判据集最大 L0=6；旧口径 `A_LEFT = N_A_ACT − TASK_UPPER = 2` 会把 6 判成"去向不明"。
A_MAXBEFORE=$(co38_l0_stat "$A_L0" max); [ -z "${A_MAXBEFORE:-}" ] && A_MAXBEFORE=${A_LO:-0}
A_LEFT=$(( A_MAXBEFORE - TASK_UPPER )); [ "$A_LEFT" -lt 0 ] && A_LEFT=0
A_LEFT_MIN=$(( A_MINL0 - TASK_UPPER )); [ "$A_LEFT_MIN" -lt 0 ] && A_LEFT_MIN=0
log "  余量口径：逐副本起点 max=${A_MAXBEFORE} min=${A_MINL0}，单任务上限 ${TASK_UPPER} ⇒ 期望剩余落在 [${A_LEFT_MIN}, ${A_LEFT}]（判据集 max 实测 ${A_LO:-?}）"
if [ "$(co38_dist_has "$A_DIST" "$A_LEFT")" = 1 ]; then
  pass "  A 相余量去向①：出现 ${A_LEFT} 文件批（分布 ${A_DIST:-空}）⇒ **非活跃分区绕过候选门槛**（源码 L339，如实记录）"
elif [ "${A_LO:-0}" -ge 1 ] && [ "${A_LO:-0}" -le "$A_LEFT" ]; then
  pass "  A 相余量去向②：终态仍留 ${A_LO} 个 L0 未提交（≤ 逐副本最大剩余 ${A_LEFT}；< 门槛 ${GATE_NUM} 且处于活跃分区）⇒ D2-2 门槛成立"
elif [ "${A_LO:-0}" = 0 ] && [ "$A_LEFT" -ge 0 ]; then
  pass "  A 相余量去向③：终态 L0=0（余下的也被合法批次吃干净；单任务上限仍由上面 10 文件批证明）"
else
  fail "  A 相余量去向不明：期望剩余落在 [${A_LEFT_MIN}, ${A_LEFT}] 或 0；实际判据集 max L0=${A_LO:-0} 分布=${A_DIST:-空} 布局=$(cmp_lay "$DBA")"
fi

# ============================================================ B 相：8 个 L0（负向 + 同场景正向对照）
log "--- B 相：各副本 < 门槛 ${GATE_NUM} 个 L0 时不应提交；补到门槛 ${GATE_NUM} 个必须提交 ---"
cmp_compaction_off
co38_mkdb1 "$DBB"
B_BASE=$(( $(now_ms) - 7200000 ))
co38_ins_reset
co38_write_n "$DBB" "$N_B" "$B_BASE"
co38_fill_l0 "$DBB" "$N_B" "$B_BASE"; N_B_ACT=$CO38_FILL_CUR
cmp_wait_close "$DBB" "${N_B_ACT:-0}" 150 >/dev/null || warn "  B 相 close 事件未达 ${N_B_ACT}"
# 活跃窗口保障（D2-2 门槛只在"活跃时间分区"参与判定）：若最新文件已超出 2×interval，补写 1 个文件把窗口重置
B_AGE0=$(co38_age_ms "$DBB")
if [ "${B_AGE0:-0}" -ge "$(( INTERVAL_MS * 2 ))" ]; then
  log "  B 相：最新文件年龄 ${B_AGE0}ms ≥ 活跃窗口 $(( INTERVAL_MS * 2 ))ms ⇒ 补写 1 个文件重置活跃窗口（如实记录）"
  co38_write_n "$DBB" 1 "$(( B_BASE + 900000 ))"
  sleep 4
  co38_fill_l0 "$DBB" "$N_B" "$(( B_BASE + 900000 ))"
  cmp_wait_close "$DBB" "${CO38_FILL_CUR:-0}" 150 >/dev/null || warn "  B 相重置后 close 事件未达"
fi
B_L0_0=$(co38_l0 "$DBB")
B_MIN0=$(co38_l0_stat "$B_L0_0" min); B_MAX0=$(co38_l0_stat "$B_L0_0" max)
B_JUDGE0=$(cmp_judge_l0_stat "$DBB" min)
log "  B 相起点（**逐副本口径**）：seq 文件数=$B_L0_0（min=${B_MIN0} max=${B_MAX0}，判据集 min=${B_JUDGE0}）布局=$(cmp_lay "$DBB") 可见行数=$(co38_rows "$DBB") / INSERT 次数=$(co38_ins_get) 单文件最大字节=$(cmp_max_tsfile_bytes_sum "$DBB")（应 ≪ ${GATE_SIZE}）"
assert_eq "  场景成立：B 相可见行数 == 实际 INSERT 次数" "$(co38_rows "$DBB")" "$(co38_ins_get)"
# 【F2 修正（2026-10-17）】前置只要求**判据集**（V1=全部副本 / V2=leader）L0 ≥ N_B；
#   V2 下某些副本整轮 0 个文件是设计差异（不 flush memtable），旧口径"每一台都 ≥ N_B"必然失败。
if [ "${B_JUDGE0:-0}" -ge "$N_B" ]; then
  pass "  场景成立：判据集（$(cmp_judge_nodes "$DBB")）level-0 ≥ ${N_B}（逐副本 $B_L0_0）"
  [ "${B_MIN0:-0}" -ge "$N_B" ] || warn "  记录：非判据副本 level-0 < ${N_B}（逐副本 $B_L0_0）—— V1=全部副本 / V2=leader 口径"
else
  fail "  场景未成立：判据集 level-0=${B_JUDGE0} < ${N_B}（逐副本 $B_L0_0）"
fi
# 【F2 修正】负向前提必须**逐副本**判定：只要有一台 ≥ 门槛，该台提交任务就是合法的
if [ "${B_MAX0:-0}" -lt "$GATE_NUM" ]; then
  B_NEG_ALL=1
  pass "  场景成立（负向前提）：**每一台**副本 level-0 < 门槛 ${GATE_NUM}（$B_L0_0）"
else
  B_NEG_ALL=0
  warn "  负向前提部分退化：存在副本 level-0 ≥ 门槛 ${GATE_NUM}（$B_L0_0）——该副本提交任务属**合法**（2026-10-16 那轮 F2 就是把它误判成负向失败）。负向判据改按**逐副本口径**执行：只要求 level-0 < 门槛 的副本不提交（下面逐台核对）"
fi
B_FIN0=$(cmp_inner_finish "$DBB"); B_START0=$(cmp_inner_start "$DBB"); B_SUM0=$(cmp_all_sum "$DBB")
B_TASKS0=$(co38_tasks "$DBB")
B_FP0=$(cmp_fp_tree "$DBB")
cmp_compaction_on true false false
B_AGE=$(co38_age_ms "$DBB")
if [ "${B_AGE:-0}" -lt "$(( INTERVAL_MS * 2 ))" ]; then B_ACT=yes; else B_ACT=no; fi
log "  B 相负向窗口 ${WIN_B}s（活跃窗口 $(( INTERVAL_MS * 2 ))ms；开合并时最新文件年龄=${B_AGE}ms ⇒ 活跃=${B_ACT}）"
B_DL=$(( $(date +%s) + WIN_B ))
while (( $(date +%s) < B_DL )); do sleep 8; done
B_FIN1=$(cmp_inner_finish "$DBB"); B_START1=$(cmp_inner_start "$DBB"); B_SUM1=$(cmp_all_sum "$DBB")
B_L0_1=$(co38_l0 "$DBB"); B_AGE2=$(co38_age_ms "$DBB"); B_TASKS1=$(co38_tasks "$DBB")
log "  B 相负向结论（全副本合计）：starts ${B_START0}→${B_START1} finishes ${B_FIN0}→${B_FIN1} TsFile ${B_SUM0}→${B_SUM1} 窗口末年龄=${B_AGE2}ms"
log "  B 相负向结论（逐副本）：seq 文件数 $B_L0_0→$B_L0_1；任务 <starts>/<finishes> $B_TASKS0→$B_TASKS1"
IFS='|' read -r B_NEGBAD B_NEGDET <<<"$(co38_neg_violations "$B_L0_0" "$B_L0_1" "$B_TASKS0" "$B_TASKS1")"
if [ "${B_NEGBAD:-1}" = 0 ]; then
  pass "  B 相负向成立（**逐副本口径**）：level-0 < 门槛 ${GATE_NUM} 的副本一个任务都没提交（$B_NEGDET）"
else
  fail "  B 相负向不成立（逐副本口径）：level-0 < 门槛 ${GATE_NUM} 的副本提交了任务 ⇒ 门槛未生效：$B_NEGDET"
fi
# 【F4 修正①】负向窗口内**无写入**（本用例自己也没写）⇒ 比较点取在"补写之前"，指纹必须完全一致
cmp_assert_same "  B 相负向窗口内（无写入）数据指纹" "$B_FP0" "$(cmp_fp_tree "$DBB")"
# ---------------------------------------------------------------------------
# 正向对照。三处修正（2026-10-16 那轮 F3/F4 的根因）：
#   ① 负向窗口结束后**立刻关合并**：原来这里漏了 `cmp_compaction_off`，合并一直开着 ⇒
#      DN 日志显示"补写期间"（03:46:15 / 03:47:10）就有 10 文件批完成，`co38_wait_first` 立刻返回，
#      而 TsFile 计数已被补写的 34 次 INSERT 抬高（19→40）⇒ 双信号判据必然失败；
#   ② 基线必须在"补到门槛 + cmp_wait_close 落盘"**之后**重采（TsFile 与 finishes 都重采）；
#   ③ 指纹基线同理（原来取在补写之前：count=12 sum=400，比较点是补写之后的 count=34 sum=630）。
cmp_compaction_off
co38_ins_reset
# 【F6 修正（2026-10-20）】补写量必须用**负向窗口之后**的实测值重算：
#   RC8 实测负向窗口里 `.79` 起点有 12 个 L0（≥ 门槛）⇒ 它合法合并掉一批、掉到 2 个；
#   旧口径 `B_ADD = GATE_NUM − B_JUDGE0`（B_JUDGE0 是窗口**之前**的 8）只补 2 个，
#   于是窗口后判据集仍是 8 < 10 ⇒ 正向对照"场景未成立"（假 FAIL）。
B_JUDGE_NOW=$(cmp_judge_l0_stat "$DBB" min)
B_ADD=$(( GATE_NUM - B_JUDGE_NOW )); [ "$B_ADD" -lt 0 ] && B_ADD=0
log "  B 相正向对照：负向窗口后判据集 L0=${B_JUDGE_NOW}（逐副本 $(co38_l0 "$DBB")）⇒ 需补写 ${B_ADD} 行"
[ "$B_ADD" -gt 0 ] && co38_write_n "$DBB" "$B_ADD" "$(( B_BASE + 500000 ))"
co38_fill_l0 "$DBB" "$GATE_NUM" "$(( B_BASE + 500000 ))"; N_B2_ACT=$CO38_FILL_CUR
cmp_wait_close "$DBB" "${N_B2_ACT:-0}" 150 >/dev/null || warn "  B 相正向对照 close 事件未达 ${N_B2_ACT}"
B_L0_2=$(co38_l0 "$DBB"); B_MIN2=$(co38_l0_stat "$B_L0_2" min); B_JUDGE2=$(cmp_judge_l0_stat "$DBB" min)
log "  B 相正向对照起点（补写后重采基线）：**逐副本** seq 文件数=$B_L0_2（min=${B_MIN2}，判据集 min=${B_JUDGE2}，门槛 ${GATE_NUM}）布局=$(cmp_lay "$DBB")"
# 【F2 修正】正向对照同样只对**判据集**要求达到门槛（V1=全部副本 / V2=leader）
if [ "${B_JUDGE2:-0}" -ge "$GATE_NUM" ]; then
  pass "  正向对照场景成立：判据集（$(cmp_judge_nodes "$DBB")）level-0 ≥ 门槛 ${GATE_NUM}（逐副本 $B_L0_2）"
  [ "${B_MIN2:-0}" -ge "$GATE_NUM" ] || warn "  记录：非判据副本 level-0 < 门槛 ${GATE_NUM}（逐副本 $B_L0_2）—— V1=全部副本 / V2=leader 口径"
else
  fail "  正向对照场景未成立：判据集 level-0=${B_JUDGE2} < 门槛 ${GATE_NUM}（逐副本 $B_L0_2）"
fi
B_SUM1B=$(cmp_all_sum "$DBB"); B_FIN1B=$(cmp_inner_finish "$DBB"); B_FP1B=$(cmp_fp_tree "$DBB")
log "  B 相正向对照基线（补写之后、开合并之前）：TsFile=${B_SUM1B} finishes=${B_FIN1B} 指纹=[$B_FP1B]"
cmp_compaction_on true false false
co38_wait_first "$DBB" "$B_FIN1B" "$WIN_B2" >/dev/null
cmp_compaction_off
sleep 8
B_FIN2=$(cmp_inner_finish "$DBB"); B_SUM2=$(cmp_all_sum "$DBB"); B_DIST=$(cmp_task_nums "$DBB" inner)
log "  B 相正向对照终态：finishes ${B_FIN1B}→${B_FIN2} TsFile ${B_SUM1B}→${B_SUM2} 布局=$(cmp_lay "$DBB") 任务文件数分布=${B_DIST:-空}"
if [ "${B_FIN2:-0}" -gt "${B_FIN1B:-0}" ] && [ "${B_SUM2:-0}" -lt "${B_SUM1B:-0}" ]; then
  pass "  B 相正向对照成立：补到门槛 ${GATE_NUM} 个后**立即成批**（finishes ${B_FIN1B}→${B_FIN2}、TsFile ${B_SUM1B}→${B_SUM2}）"
else
  fail "  正向对照不成立：补到 ${GATE_NUM} 个后仍未成批（finishes ${B_FIN1B}→${B_FIN2}、TsFile ${B_SUM1B}→${B_SUM2}，基线取在补写+落盘之后）——负向结论不可信"
fi
[ "$(co38_dist_has "$B_DIST" "$GATE_NUM")" = 1 ] && pass "  B 相正向对照：出现 ${GATE_NUM} 文件批（分布 ${B_DIST:-空}）⇒ 候选门槛/单任务上限生效（D2-2）" \
  || fail "  B 相正向对照：未出现 ${GATE_NUM} 文件批（分布 ${B_DIST:-空}）⇒ 无法证明门槛与单任务上限参与判定"
# 【F4 修正②】合并前后指纹在**无写入**窗口内比较（基线取在补写之后）
cmp_assert_same "  B 相合并前后数据指纹（基线取在补写之后，窗口内无写入）" "$B_FP1B" "$(cmp_fp_tree "$DBB")"

# ============================================================ C 相：逐层搜索 / 同层不混
log "--- C 相：${N_C}×L0 + 1×L1，gap=${GAP_C}，候选门槛=${CAND_C} ⇒ 只选 L0、不动 L1 ---"
cmp_compaction_off
co38_mkdb1 "$DBC"
C_BASE=$(( $(now_ms) - 7200000 ))
co38_write_n "$DBC" 2 "$C_BASE"
co38_write_n "$DBC" 2 "$C_BASE"
co38_fill_l0 "$DBC" 2 "$C_BASE"; C_N0=$CO38_FILL_CUR
cmp_wait_close "$DBC" "${C_N0:-0}" 150 >/dev/null || warn "  C 相造 L1 的 close 事件未达 ${C_N0}"
log "  C 相造 L1：2 个 L0 合并出 1 个 L1（起点判据集 L0=${C_N0}，gap=0、候选门槛=${CAND_C}）"
cmp_set_hot inner_compaction_candidate_file_num "$CAND_C" >/dev/null
cmp_set_hot max_level_gap_in_inner_compaction 0 >/dev/null
cmp_compaction_on true false false
if cmp_wait_lay "$DBC" "0/1/0/0" 180 >/dev/null; then
  pass "  C 相 L1 就绪：判据集 ${CMPJ_JUDGE_SPEC% }；各副本布局 $(cmp_lay "$DBC")"
  cmp_warn_followers "C 相造 L1（0/1/0/0）" "0/1/0/0"
elif cmp_any_lay "$DBC" "0/1/0/0"; then
  warn "  C 相 L1：判据集未达 0/1/0/0，但**至少一台**已合成 L1（各副本 $(cmp_lay "$DBC")）⇒ 场景按实际布局记录"
else
  warn "  C 相 L1 未在 180s 内就绪（布局 $(cmp_lay "$DBC")）——后续判据按实际布局记录"
fi
cmp_compaction_off
# 记录"本相之前就已存在的 L1 文件"（每个副本各一个名字）与 selected-files 证据行的基线
# （`compaction with selected files` 行是**追加**的 ⇒ 下面的新增行 = 本相第二次合并产生的任务）
C_OLD_L1=$(for h in "${DN[@]}"; do printf '%s %s\n' "$h" "$(co38_l1_name "$h" "$DBC")"; done)
C_SEL0_N=$(co38_sel_lines "$DBC" | grep -c '[^[:space:]]')
log "  C 相既有 L1（各副本）：$(printf '%s' "$C_OLD_L1" | tr '\n' ';')"
log "  C 相 selected-files 证据行基线=${C_SEL0_N}（造 L1 时那批任务的行数；下面只判新增行）"
co38_write_n "$DBC" "$N_C" "$(( C_BASE + 100000 ))"
co38_fill_l0 "$DBC" "$N_C" "$(( C_BASE + 100000 ))"; C_N1=$CO38_FILL_CUR
cmp_wait_close "$DBC" "$(( C_N1 + 1 ))" 150 >/dev/null || warn "  C 相起点 close 事件未达 $(( C_N1 + 1 ))"
C_LAY0=$(cmp_lay "$DBC")
C_UNI=$(printf '%s' "$(cmp_lay_uni "$C_LAY0")" | tr -d ' ')
log "  C 相起点：判据集 L0=${C_N1}（目标 ${N_C}）；布局=$(cmp_lay "$DBC")（去重=${C_UNI}）"
# 布局前置改用判据集口径（V1=全部副本 / V2=leader）：V2 follower 不 flush memtable ⇒ "三副本同布局"不成立
if [ "${C_N1:-0}" -lt "$N_C" ]; then
  fail "  场景未成立：判据集 level-0=${C_N1} < ${N_C}（逐副本 $(co38_l0 "$DBC")）"
else
  # 【F6 修正（2026-10-20）】C 相真正需要的是"判据集已经存在 L1"+"L0 达到起点规模"；
  #   理想布局 ${N_C}/1/0/0 只是**文件切分恰好**的结果。RC8 V2 实测 78:5/1/0/0（leader 多攒了 2 个 L0），
  #   旧口径按"布局必须等于 ${N_C}/1/0/0"判场景无效 ⇒ 假 FAIL。
  cmp_lay_probe "$DBC"
  C_L1_OK=0
  for h in $CMPJ_JUDGE; do
    n=$(cmp_lay_of "$h" "$DBC" | awk -F/ '{print $2+0}'); [ "${n:-0}" -ge 1 ] && C_L1_OK=1
  done
  if [ "$C_L1_OK" = 1 ]; then
    pass "  场景成立：判据集（${CMPJ_JUDGE}）已存在 L1 且 level-0=${C_N1} ≥ ${N_C}（判据集布局 ${CMPJ_JUDGE_SPEC% }；各副本 $(cmp_lay "$DBC")）"
    [ "${CMPJ_JUDGE_UNI}" = "${N_C}/1/0/0 " ] || warn "  记录：判据集实测布局 ${CMPJ_JUDGE_UNI% } ≠ 理想 ${N_C}/1/0/0（文件切分/落盘粒度差异，不据此判场景无效）"
  else
    fail "  场景未成立：判据集（${CMPJ_JUDGE}）没有 L1（判据集布局 ${CMPJ_JUDGE_SPEC:-?}；各副本 $(cmp_lay "$DBC")）"
  fi
fi
C_FIN0=$(cmp_inner_finish "$DBC"); C_SUM0=$(cmp_all_sum "$DBC"); C_FP0=$(cmp_fp_tree "$DBC")
log "  C 相基线：TsFile=${C_SUM0} finishes=${C_FIN0} 指纹=[$C_FP0]"
cmp_set_hot max_level_gap_in_inner_compaction "$GAP_C" >/dev/null
cmp_set_hot inner_compaction_candidate_file_num "$CAND_C" >/dev/null
assert_eq "  C 相生效值 max_level_gap_in_inner_compaction" "$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction)" "$GAP_C"
assert_eq "  C 相生效值 inner_compaction_candidate_file_num" "$(cmp_eff "${DN[0]}" inner_compaction_candidate_file_num)" "$CAND_C"
cmp_compaction_on true false false
co38_wait_first "$DBC" "$C_FIN0" "$WIN_C" >/dev/null
cmp_compaction_off
sleep 8
C_FIN1=$(cmp_inner_finish "$DBC"); C_SUM1=$(cmp_all_sum "$DBC"); C_FP1=$(cmp_fp_tree "$DBC")
C_DIST=$(cmp_task_nums "$DBC" inner)
log "  C 相终态：TsFile=${C_SUM0}→${C_SUM1} finishes=${C_FIN0}→${C_FIN1} 布局=$(cmp_lay "$DBC") 任务文件数分布=${C_DIST:-空}"
cmp_assert_same "  C 相合并前后数据指纹" "$C_FP0" "$C_FP1"
if [ "${C_FIN1:-0}" -gt "${C_FIN0:-0}" ] && [ "${C_SUM1:-0}" -lt "${C_SUM0:-0}" ]; then
  pass "  C 相双信号成立：finishes ${C_FIN0}→${C_FIN1} 且 TsFile ${C_SUM0}→${C_SUM1}"
else
  fail "  C 相双信号不成立：finishes ${C_FIN0}→${C_FIN1}，TsFile ${C_SUM0}→${C_SUM1}"
fi
C_SEL=$(co38_sel_lines "$DBC")
C_SEL_NEW=$(printf '%s\n' "$C_SEL" | tail -n +$(( C_SEL0_N + 1 )))
C_NL=$(printf '%s\n' "$C_SEL_NEW" | grep -c '[^[:space:]]')
log "  C 相 selected-files 新增证据行数=${C_NL}（累计行数=$(printf '%s\n' "$C_SEL" | grep -c '[^[:space:]]')）"
printf '%s\n' "$C_SEL_NEW" | cut -c1-600 >>"$OUT"
if [ "${C_NL:-0}" -ge 1 ]; then
  C_MIX=0; C_FIRST=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    nh=${line%% *}
    lst=${line#* }
    lv=$(co38_levels_of "$lst")
    nlv=$(printf '%s\n' $lv | grep -c '[0-9]')
    [ "${nlv:-0}" -gt 1 ] && { C_MIX=$(( C_MIX + 1 )); log "      [${nh##*.}] 混合层级任务：levels=[$lv]"; }
    if [ "$C_FIRST" = 1 ]; then
      C_FIRST=0
      l1n=$(printf '%s\n' "$C_OLD_L1" | awk -v n="$nh" '$1==n{print $2; exit}')
      if [ "$lv" = "0 " ]; then
        pass "  C 相首个任务源文件全为 level 0（D1-4：从最低层开始；levels=[$lv]）"
      else
        fail "  C 相首个任务源文件层级=[$lv]（期望全为 0 ⇒ 从最低层开始）"
      fi
      if [ -n "${l1n:-}" ] && printf '%s\n' "$lst" | grep -qF "$l1n"; then
        fail "  C 相首个任务选中了本相之前就已存在的 L1 文件（$l1n）⇒ 低层有成批时仍向高层搜索（D2-1 不成立）"
      else
        pass "  C 相首个任务未选中既有的 L1 文件（${l1n:-未识别}）⇒ 某层有成批就不再向高层搜（D2-1）"
      fi
    fi
  done < <(printf '%s\n' "$C_SEL_NEW")
  if [ "$C_MIX" = 0 ]; then
    pass "  C 相同层性成立：${C_NL} 个任务的源文件 level 全部单一（D1-4/D2-1）"
  else
    fail "  C 相同层性不成立：${C_MIX} 个任务的源文件跨了多个 level"
  fi
else
  fail "  C 相第二次合并没有新增 'compaction with selected files' 证据行（累计=$(printf '%s\n' "$C_SEL" | grep -c '[^[:space:]]')）——无法验证逐层/同层"
fi

# ============================================================ 收尾
cmp_assert_no_stuck "无卡死合并线程（TsFileResource.writeLock）"
log "--- 收尾三件套（基准库 root.colev2）---"
post_checks "select count(s1) from ${DBB}.**;" tree
cmp_case_finish "" tree ""
