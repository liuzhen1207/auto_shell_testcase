#!/bin/bash
# ============================================================================
# 合并（compaction）专项 skill —— 专用 helper（在 lib/common.sh 之上）
#   ① 造数据（树/表模型，可按批次控制时间戳 → 造 seq / unseq 文件）
#   ② TsFile 观测（seq/unseq 文件数、字节数、文件清单、最大文件）
#   ③ 合并观测（starts/finishes/类型、等合并、写放大、卡死线程 jstack）
#   ④ 合并参数（模板键、实际生效值、热改）
#   ⑤ REMOVE DATANODE / CONFIGNODE（节点 id 解析、移除、集群节点查询）
# ============================================================================

# ---------------------------------------------------------------------------
# ① 造数据
# ---------------------------------------------------------------------------
# 树模型建库 + 建设备时序：cmp_make_tree_db <db> <devs> [类型] [编码]
cmp_make_tree_db(){ local db=$1 devs=$2 dtype=${3:-int64} enc=${4:-} d
  sq "create database $db;" >/dev/null
  for ((d=1; d<=devs; d++)); do
    if [ -n "$enc" ]; then sq "create timeseries $db.d$d.s1 with datatype=$dtype encoding=$enc;" >/dev/null
    else sq "create timeseries $db.d$d.s1 with datatype=$dtype;" >/dev/null; fi
  done; }
# 任意一条建时序语句（多类型/多编码用例用）
cmp_add_series(){ sq "create timeseries $1;" >/dev/null; }
# 写一批树模型数据：cmp_write_tree_batch <db> <devs> <rows> <batch_no> [时间戳基准ms] [是否降序]
#   时间戳基准决定数据落在哪个时间分区；batch_no 让各批不同（默认递增 → seq）
#   传 base 且用 --desc 可以让本批时间戳整体早于上一批 → 落到 unseq 文件
cmp_write_tree_batch(){ local db=$1 devs=$2 rows=$3 b=${4:-1} base=${5:-} desc=${6:-no}
  local start
  if [ -n "$base" ]; then start=$base; else start=$(( ($(date +%s) - 3600) * 1000 + b * 1000000 )); fi
  local d i
  for ((d=1; d<=devs; d++)); do
    local vals="" k off ts
    for ((k=0;k<rows;k++)); do
      off=$k; [ "$desc" = yes ] && off=$(( rows-1-k ))
      ts=$(( start + off * 10 ))
      vals="$vals($ts,$((k+b))),"
      # 500 行/语句
      if [ $(( (k+1) % 500 )) -eq 0 ]; then sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null || return 1; vals=""; fi
    done
    [ -n "$vals" ] && { sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null || return 1; }
  done
  sq "flush;" >/dev/null; }
# 表模型建库 + 两张表（t1/t2）：cmp_make_table_db <db>
cmp_make_table_db(){ local db=$1 t1=${2:-t1} t2=${3:-t2} out
  sql_lines_table "create database $db;" >/dev/null
  out=$(sqt "create table $db.$t1 (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD);")
  printf '%s' "$out" | grep -q 'successfully' || warn "建表 $db.$t1 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  if [ -n "$t2" ]; then
    out=$(sqt "create table $db.$t2 (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD);")
    printf '%s' "$out" | grep -q 'successfully' || warn "建表 $db.$t2 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  fi
  local tbls; tbls=$(sqt "show tables from $db;")
  printf '%s' "$tbls" | grep -q "$t1" && pass "建表成功：$db.$t1" || fail "场景无效：$db.$t1 未建成"
  [ -n "$t2" ] && { printf '%s' "$tbls" | grep -q "$t2" && pass "建表成功：$db.$t2" || fail "场景无效：$db.$t2 未建成"; }
}
# 写一批表模型数据：cmp_write_table_batch <db> <table> <devs> <rows> <batch_no> [base] [desc]
cmp_write_table_batch(){ local db=$1 tb=$2 devs=$3 rows=$4 b=${5:-1} base=${6:-} desc=${7:-no}
  local start
  if [ -n "$base" ]; then start=$base; else start=$(( ($(date +%s) - 3600) * 1000 + b * 1000000 )); fi
  local d k vals="" off ts
  for ((d=1; d<=devs; d++)); do
    vals=""
    for ((k=0;k<rows;k++)); do
      off=$k; [ "$desc" = yes ] && off=$(( rows-1-k ))
      ts=$(( start + off * 10 ))
      vals="$vals($ts,'d$d',$((k+b))),"
      if [ $(( (k+1) % 500 )) -eq 0 ]; then sqt "insert into $db.$tb (time, dev, v) values ${vals%,};" >/dev/null || return 1; vals=""; fi
    done
    [ -n "$vals" ] && { sqt "insert into $db.$tb (time, dev, v) values ${vals%,};" >/dev/null || return 1; }
  done
  sqt "flush;" >/dev/null; }

# ---------------------------------------------------------------------------
# ② TsFile 观测（数据目录：data/datanode/data/{sequence,unsequence}/<db>/<partition>/<region>/）
# ---------------------------------------------------------------------------
cmp_tsfile_cnt_dir(){ local h=$1 db=$2 kind=$3 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data/$kind -path '*/$db/*' -name '*.tsfile' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
cmp_seq_cnt(){ cmp_tsfile_cnt_dir "$1" "$2" sequence; }
cmp_unseq_cnt(){ cmp_tsfile_cnt_dir "$1" "$2" unsequence; }
cmp_sum_over_dn(){ local f=$1 db=$2 h s=0; for h in "${DN[@]}"; do s=$((s + $($f "$h" "$db"))); done; echo "$s"; }
cmp_seq_sum(){ cmp_sum_over_dn cmp_seq_cnt "$1"; }
cmp_unseq_sum(){ cmp_sum_over_dn cmp_unseq_cnt "$1"; }
# ⚠️ cmp_all_sum = **seq + unseq** 之和。它可以用来判"合并推进 / 文件数**下降**"，
#   **不要**用它判"归零（== 0）"：V2 下 follower 收到的复制文件全部落在 **unsequence**
#   （DataRegion.java:4984 setSeq(false) / :5009 loadTsFileToUnSequence）⇒
#   seq 已归零而 unseq 还有残留时 all_sum 永远不会是 0。
#   CO-41 C 相 `FAIL C 相 TsFile 数未归零（2，各副本 77=0 78=0 79=0）` 就是
#   "判据用 all_sum、回显用 seq_cnt" 造成自相矛盾（2026-10-17 定性）。
#   ⇒ **"归零"一律用 cmp_seq_sum**（或逐副本 cmp_seq_cnt）；all_sum 只用于"下降/变更"类判据。
cmp_all_sum(){ echo $(( $(cmp_seq_sum "$1") + $(cmp_unseq_sum "$1") )); }
# 单副本该库 TsFile 总数（seq + unseq）—— 逐副本"文件数不增加"类判据用
cmp_all_cnt_node(){ echo $(( $(cmp_seq_cnt "$1" "$2") + $(cmp_unseq_cnt "$1" "$2") )); }
cmp_per_node(){ local f=$1 db=$2 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$($f "$h" "$db") "; done; echo "$out"; }
# 该库 TsFile 的物理字节数（seq / unseq 合计）
cmp_bytes(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
cmp_bytes_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_bytes "$h" "$db"))); done; echo "$s"; }
# 该库 TsFile 名字（证据）
cmp_tsfile_list(){ local h=$1 db=$2; sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%p\n' 2>/dev/null | sed 's#.*/##' | sort"; }
# 该库最大 TsFile 字节数（验证 target_compaction_file_size 效果时用）
cmp_max_tsfile_bytes(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%s\n' 2>/dev/null | sort -n | tail -1" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
cmp_max_tsfile_bytes_sum(){ local db=$1 h m=0 v; for h in "${DN[@]}"; do v=$(cmp_max_tsfile_bytes "$h" "$db"); [ "${v:-0}" -gt "$m" ] && m=$v; done; echo "$m"; }

# ---------------------------------------------------------------------------
# ③ 合并观测
# ---------------------------------------------------------------------------
# 合并日志文件列表。**必须用函数而不是变量**：写成单引号变量时 `$DB_DIR` 不会被展开，
# 插进 ssh 命令后远端再展开（远端没有 DB_DIR）⇒ 匹配恒为 0（本项目踩过）。
cmp_log_files(){ echo "$DB_DIR/logs/log_datanode_compaction.log $DB_DIR/logs/log_datanode_all.log"; }
# 全部 DN 上所有库的 starts / finishes（check_logs 的正证据用）
cmp_start_cnt_all(){ local h s=0; for h in "${DN[@]}"; do s=$((s + $(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hcF 'Compaction task starts'" 2>/dev/null | tr -dc '0-9'))); done; echo "$s"; }
cmp_finish_cnt_all(){ local h s=0; for h in "${DN[@]}"; do s=$((s + $(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hcF 'Compaction task finishes successfully'" 2>/dev/null | tr -dc '0-9'))); done; echo "$s"; }
# 某库的 inner / cross 完成行数（单调递增）
cmp_cnt_db(){ local h=$1 db=$2 pat=$3 v
  v=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 某库的 inner / cross 完成行数（单调递增）
cmp_cnt_db(){ local h=$1 db=$2 pat=$3 v
  v=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
cmp_inner_finish(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'InnerSpaceCompaction task finishes successfully'))); done; echo "$s"; }
cmp_inner_start(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'InnerSpaceCompaction task starts with'))); done; echo "$s"; }
# ⚠️ cross 的 pattern **必须**带 `[Compaction] ` 前缀（与同文件 cmp_task_nums / cmp_task_cnt /
#   cmp_cross_unseq_nums 的 cross 分支口径一致）。日志里两条"完成行"分别是
#     `… [Compaction] CrossSpaceCompaction task finishes successfully`
#     `… [Compaction] InsertionCrossSpaceCompaction task finishes successfully`
#   子串口径（不带前缀）会把 **Insertion（把 unseq 文件直接搬进 seq 空间）** 那条一起数进来。
#   IoTConsensusV2 下 follower 收到的 TsFile 全在 unseq 空间（IoTConsensusV2Receiver.java:734 →
#   DataRegion.java:4984 setSeq(false)/:5009），Insertion 任务频繁出现 ⇒ CO-04 的负向相
#   （窗口内不应出现跨空间合并完成）会被误判成"min_cross_compaction_unseq_file_level 门控失效"。
#   注：cmp_inner_finish / cmp_inner_start **故意不加**前缀——它们就是要合计
#   `[Compaction] Sequence|Unsequence InnerSpaceCompaction …` 两种段名（加前缀反而不匹配）。
cmp_cross_finish(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" '[Compaction] CrossSpaceCompaction task finishes successfully'))); done; echo "$s"; }
# 按"顺序空间 / 乱序空间"分开数（组合矩阵用例要用：开关矩阵要能区分是哪一类 inner 合并跑了）
# 日志形如：`root.db-3 [Compaction] Sequence InnerSpaceCompaction task finishes successfully`
# 口径审查（2026-10-16，整族 helper 一次过）：这四个是**精确段名**（Sequence/Unsequence 互不为子串，
#   也不被 SettleCompaction/InsertionCrossSpaceCompaction 命中）⇒ 不需要前缀；
#   只有"以 CrossSpace 开头的段名"会被 `InsertionCrossSpace…` 子串命中 ⇒ 已在上面收紧。
cmp_seq_inner_finish(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'Sequence InnerSpaceCompaction task finishes successfully'))); done; echo "$s"; }
cmp_unseq_inner_finish(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'Unsequence InnerSpaceCompaction task finishes successfully'))); done; echo "$s"; }
cmp_seq_inner_start(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'Sequence InnerSpaceCompaction task starts with'))); done; echo "$s"; }
cmp_unseq_inner_start(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(cmp_cnt_db "$h" "$db" 'Unsequence InnerSpaceCompaction task starts with'))); done; echo "$s"; }
cmp_log_tail(){ local h=$1 db=$2
  sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hE '(root\.)?$db-[0-9]+ \[Compaction\]' | tail -5" 2>/dev/null; }
# ---------------------------------------------------------------------------
# DataNode 的**真实** JVM pid（远端解析 /proc/<pid>/exe）
#   坑（P0 级，2026-10-20 由 WAL 侧实测确认）：`pgrep -f com.timecho.iotdb.DataNode` 会匹配到
#   **这条检查命令自己的 `bash -c` 包装 shell**（它的命令行里就含该字符串）⇒ 取到的 pid 是 shell
#   而不是 DataNode JVM ⇒ `jstack` 打空 ⇒ `cmp_stuck_sum` 恒 0 ⇒ "无合并线程卡死"变成**假 PASS**
#   （CO-01…CO-11、DT-04、CO-15/39/41 等用例的"卡死线程=0"都靠这条）。
# 做法（照 WAL 侧已验证的 `wal_dn_pid`）：扫远端 `/proc/*/cmdline`，只认**可执行文件是 java**
#   （`${c%% *}` 以 java 结尾）且命令行含 `DataNode` 的进程 ⇒ bash/sh/grep/pgrep/启动脚本天然被排除；
#   找不到就回显空串（调用方按"不可观测"处理，不要当成 0）。
cmp_dn_pid(){ sshx "$1" 'for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null) || continue
    x=${c%% *}
    case "$x" in *java) ;; *) continue ;; esac
    case "$c" in *DataNode*) echo "${p#/proc/}"; break ;; esac
  done' 2>/dev/null | tr -d '\r' | head -1; }
# 卡在 TsFileResource.writeLock 的线程数（合并卡死类问题的直接证据）
#   回显 **-1 = 不可观测**（拿不到 DataNode 的 JVM pid，或 jstack 里没有线程头）。
#   调用方必须把 -1 当 WARN，**不允许**当成 0（否则"无卡死线程"是假 PASS）。
cmp_stuck_cnt(){ local h=$1 pid d n
  pid=$(cmp_dn_pid "$h")
  [ -n "${pid:-}" ] || { echo -1; return; }
  d=$(sshx "$h" "jstack $pid 2>/dev/null" 2>/dev/null)
  n=$(printf '%s\n' "$d" | grep -c '^"'); n=${n:-0}
  [ "$n" -ge 1 ] || { echo -1; return; }
  printf '%s\n' "$d" | grep -c 'TsFileResource.writeLock' | tr -dc '0-9'; }
# 全部 DN 求和；任一节点不可观测(-1) ⇒ 回显 -1（调用方打 WARN，不判 PASS）
cmp_stuck_sum(){ local h v s=0
  for h in "${DN[@]}"; do v=$(cmp_stuck_cnt "$h"); v=${v:--1}
    [ "$v" = "-1" ] && { echo -1; return; }
    s=$(( s + v ))
  done; echo "$s"; }
# 统一断言"无合并线程卡死"：0 ⇒ PASS；-1 ⇒ WARN（不可观测，**不判 PASS**）；>0 ⇒ FAIL。
# 用例里不要再写 `[ "$(cmp_stuck_sum)" -eq 0 ] && pass ...`（那会把 -1 也算成 0）。
cmp_assert_no_stuck(){ local label=${1:-无合并线程卡死} v
  v=$(cmp_stuck_sum); v=${v:--1}
  case "$v" in
    0)  pass "  $label（TsFileResource.writeLock 线程数=0）" ;;
    -1) warn "  $label：**不可观测**（取不到 DataNode 的 JVM pid 或 jstack 无线程头）⇒ 本项不判 PASS，仅记录（Pgrep 自匹配曾被当 0 = 假 PASS）" ;;
    *)  fail "  $label：有 $v 个线程卡在 TsFileResource.writeLock" ;;
  esac; }
# 等合并推进：<db> <finish 基线> <tsfile 基线> <窗口秒>；0=推进 / 1=超时
cmp_wait_merge(){ local db=$1 fin0=$2 ts0=$3 win=$4 f t first_ts=""
  local deadline=$(( $(date +%s) + win ))
  while (( $(date +%s) < deadline )); do
    sleep 5
    f=$(cmp_inner_finish "$db"); t=$(cmp_all_sum "$db")
    [ -z "$first_ts" ] && first_ts=$t
    log "    等合并: finishes=$f(基线$fin0) tsfile=$t(基线$ts0 首次$first_ts)"
    if [ "$f" -gt "$fin0" ] && { [ "$t" -lt "$ts0" ] || [ "$t" -lt "$first_ts" ]; }; then
      echo "finishes:$f tsfile:$t"; return 0; fi
  done
  echo "finishes:${f:-0} tsfile:${t:-0}"; return 1; }
# 等 unseq 文件数降到 want 以下（cross space compaction 的判据）
cmp_wait_unseq(){ local db=$1 want=$2 win=$3 u
  local deadline=$(( $(date +%s) + win ))
  while (( $(date +%s) < deadline )); do
    sleep 5; u=$(cmp_unseq_sum "$db")
    log "    等 unseq：unseq=$u（目标 <=$want）"
    [ "${u:-0}" -le "$want" ] && { echo "$u"; return 0; }
  done
  echo "${u:-0}"; return 1; }
# 数据指纹：某 SQL 的归一化结果（用于"合并前后数据完全一致"的断言）
cmp_fingerprint(){ local dialect=$1 sql=$2
  if [ "$dialect" = table ]; then norm_result "$(sqt "$sql")"; else norm_result "$(sq "$sql")"; fi; }
# 树模型指纹：count 与 sum **分开查**——`select count(s1), sum(s1), min(s1), max(s1) from db.**`
# 在通配路径上会报 `701: Raw data and aggregation hybrid query is not supported`（实测踩到）。
cmp_fp_tree(){ local db=$1 c s
  c=$(row_sum "$(sq "select count(s1) from $db.**;")")
  s=$(row_sum "$(sq "select sum(s1) from $db.**;")")
  echo "count=$c sum=$s"; }
# 单序列/单设备的树模型指纹
cmp_fp_tree_dev(){ local path=$1 c s
  c=$(row_sum "$(sq "select count(s1) from $path.**;")")
  s=$(row_sum "$(sq "select sum(s1) from $path.**;")")
  echo "count=$c sum=$s"; }
# 表模型指纹
cmp_fp_table(){ local tbl=$1 c s
  c=$(sqt "select count(v) from $tbl;" | table_rows | head -1 | awk -F'|' '{print ($2+0)}')
  s=$(sqt "select sum(v) from $tbl;" | table_rows | head -1 | awk -F'|' '{print ($2+0)}')
  echo "count=$c sum=$s"; }
# 写入阶段关掉三类合并（保证"写完再开合并"可复现；顺带避免合并在写入期间就把文件并掉）
cmp_compaction_off(){ local k
  for k in enable_seq_space_compaction enable_unseq_space_compaction enable_cross_space_compaction; do
    cmp_set_hot "$k" false >/dev/null 2>&1 || true
  done
  log "  已热关三类合并：seq=$(cmp_eff "${DN[0]}" enable_seq_space_compaction) unseq=$(cmp_eff "${DN[0]}" enable_unseq_space_compaction) cross=$(cmp_eff "${DN[0]}" enable_cross_space_compaction)"
}
# 写入后打开需要的合并类型：cmp_compaction_on [seq] [unseq] [cross]
cmp_compaction_on(){ local seq=${1:-true} unseq=${2:-true} cross=${3:-false}
  cmp_set_hot enable_seq_space_compaction "$seq" >/dev/null 2>&1 || true
  cmp_set_hot enable_unseq_space_compaction "$unseq" >/dev/null 2>&1 || true
  cmp_set_hot enable_cross_space_compaction "$cross" >/dev/null 2>&1 || true
  log "  已热开合并：seq=$(cmp_eff "${DN[0]}" enable_seq_space_compaction) unseq=$(cmp_eff "${DN[0]}" enable_unseq_space_compaction) cross=$(cmp_eff "${DN[0]}" enable_cross_space_compaction)"
}
# 指定节点上执行并归一化（REMOVE 场景：经剩余节点校验）
cmp_fingerprint_on(){ local node=$1 dialect=$2 sql=$3
  if [ "$dialect" = table ]; then norm_result "$(sqt_node "$node" "$sql")"; else norm_result "$(sq_node "$node" "$sql")"; fi; }
# 经一组节点查询并断言都与基准一致
cmp_assert_nodes_same(){ local label=$1 base=$2 dialect=$3 sql=$4 nodes_str=$5 h cur
  local nodes=(); read -ra nodes <<<"$nodes_str"
  for h in "${nodes[@]}"; do
    cur=$(cmp_fingerprint_on "$h" "$dialect" "$sql")
    [ "$cur" = "$base" ] && pass "$label：经 $h 与基准一致" \
      || fail "$label：经 $h 与基准不一致 [$(printf '%s' "$cur" | tr '\n' ' ' | cut -c1-160)] vs [$(printf '%s' "$base" | tr '\n' ' ' | cut -c1-160)]"
  done; }
cmp_assert_same(){ local label=$1 a=$2 b=$3
  if [ "$a" = "$b" ]; then pass "$label：与合并前完全一致"; else
    fail "$label：与合并前不一致"; printf '  合并前: %s\n  合并后: %s\n' "$(printf '%s' "$a" | tr '\n' ' ' | cut -c1-300)" "$(printf '%s' "$b" | tr '\n' ' ' | cut -c1-300)" >>"$OUT"
  fi; }

# ---------------------------------------------------------------------------
# ④ 合并参数（模板 / 生效值 / 热改）
# ---------------------------------------------------------------------------
CMP_KEYS='enable_seq_space_compaction enable_unseq_space_compaction enable_cross_space_compaction enable_auto_repair_compaction cross_selector cross_performer inner_seq_selector inner_seq_performer inner_unseq_selector inner_unseq_performer compaction_priority candidate_compaction_task_queue_size target_compaction_file_size inner_compaction_total_file_size_threshold inner_compaction_total_file_num_threshold max_level_gap_in_inner_compaction chunk_size_lower_bound_in_compaction chunk_point_num_lower_bound_in_compaction inner_compaction_candidate_file_num max_cross_compaction_candidate_file_num max_cross_compaction_candidate_file_size min_cross_compaction_unseq_file_level compaction_thread_count compaction_max_aligned_series_num_in_one_batch compaction_schedule_interval_in_ms compaction_write_throughput_mb_per_sec compaction_read_throughput_mb_per_sec compaction_read_operation_per_sec sub_compaction_thread_count inner_compaction_task_selection_disk_redundancy inner_compaction_task_selection_mods_file_threshold compaction_schedule_thread_num target_chunk_point_num target_chunk_size chunk_metadata_size_proportion'
# 安装包配置模板里的键（静态检查）
cmp_tpl_has(){ local h=$1 k=$2 n; n=$(sshx "$h" "grep -cE '^$k=' $DB_DIR/conf/iotdb-system.properties.template 2>/dev/null" 2>/dev/null | tr -dc '0-9'); echo "${n:-0}"; }
# 某键实际生效值（表方言 show configuration 第 3 列 = 当前值）
cmp_eff(){ local h=$1 k=$2 out; out=$(sqt_node "$h" 'show configuration;' 2>/dev/null)
  printf '%s\n' "$out" | awk -F'|' -v k="$k" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3)} $2==k{print $3; exit}'; }
cmp_eff_all(){ local h=$1 k out=""; out=$(sqt_node "$h" 'show configuration;' 2>/dev/null)
  for k in $CMP_KEYS; do printf '%s=%s ' "$k" "$(printf '%s\n' "$out" | awk -F'|' -v k="$k" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3)} $2==k{print $3; exit}')"; done; echo; }
# 热改并返回 CLI 的原始响应（用于判断是否需要重启）
cmp_set_hot(){ sq "set configuration '$1'='$2';" 2>&1 | tr '\n' ' '; }
# 判定某个键是否是热加载：回显响应，hot→yes / 需要重启→no
cmp_is_hot_key(){ local resp; resp=$(cmp_set_hot "$1" "$2"); log "    SET $1=$2 → $(printf '%s' "$resp" | cut -c1-160)"
  printf '%s' "$resp" | grep -qiE 'restart is required' && echo no || echo yes; }

# ---------------------------------------------------------------------------
# ⑤ REMOVE DATANODE / CONFIGNODE
# ---------------------------------------------------------------------------
# show cluster 解析（列序：$1='' $2=NodeID $3=NodeType $4=Status $5=InternalAddress ...）
# cmp_node_ids <DataNode|ConfigNode> → "<ip>=<id> ..."
cmp_node_ids(){ local kind=$1
  sq 'show cluster;' 2>/dev/null | awk -F'|' -v k="$kind" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$5)} $3==k{printf "%s=%s ", $5, $2}'; echo; }
cmp_node_id_of(){ local kind=$1 ip=$2
  sq 'show cluster;' 2>/dev/null | awk -F'|' -v k="$kind" -v ip="$ip" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$5)} $3==k && $5==ip{print $2; exit}'; }
cmp_running_cnt(){ sq 'show cluster;' 2>/dev/null | grep -cE 'Running|ReadOnly'; }
cmp_remove_dn(){ local id=$1; sq "remove datanode $id;"; }
cmp_remove_cn(){ local id=$1; sq "remove confignode $id;"; }
# 等某个节点（任意类型）从 show cluster 里消失
cmp_wait_node_gone(){ local kind=$1 ip=$2 win=${3:-240} st
  local deadline=$(( $(date +%s) + win ))
  while (( $(date +%s) < deadline )); do
    st=$(sq 'show cluster;' 2>/dev/null | awk -F'|' -v k="$kind" -v ip="$ip" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$5)} $3==k && $5==ip{print "yes"; exit}')
    [ -z "$st" ] && return 0
    sleep 5
  done
  return 1; }
cmp_node_cnt(){ local kind=$1; sq 'show cluster;' 2>/dev/null | awk -F'|' -v k="$kind" '{gsub(/[ \t]/,"",$3)} $3==k{c++} END{print c+0}'; }

# ---------------------------------------------------------------------------
# ⑥ 性能基准
# ---------------------------------------------------------------------------
# 单个 CLI 会话里批量写入（性能用例必须用这个：`sq` 每次都会新起一个 CLI/JVM，
# 逐条调用时写入耗时被进程启动开销主导，测出来的是 CLI 而不是存储引擎）。
# 用法： cmp_bulk_tree_session <db> <devs> <rows> <batch_no> [base] [batch_size]
cmp_bulk_tree_session(){ local db=$1 devs=$2 rows=$3 b=${4:-1} base=${5:-} bs=${6:-500}
  local start stmts=() d k vals=""
  if [ -n "$base" ]; then start=$base; else start=$(( ($(date +%s) - 3600) * 1000 + b * 100000000 )); fi
  for ((d=1; d<=devs; d++)); do
    vals=""
    for ((k=0;k<rows;k++)); do
      vals="$vals($(( start + k * 10 )),$((k+b))),"
      if [ $(( (k+1) % bs )) -eq 0 ]; then stmts+=("insert into $db.d$d(time,s1) values ${vals%,};"); vals=""; fi
    done
    [ -n "$vals" ] && stmts+=("insert into $db.d$d(time,s1) values ${vals%,};")
  done
  stmts+=("flush;")
  sql_lines_tree "${stmts[@]}" >/dev/null
  # 校验写入（用一次 count 查询，避免"写了但没进去"）
  local want=$(( devs * rows )) got
  got=$(row_sum "$(sq "select count(s1) from $db.d1.**;")")
  echo "$got"; }
# 子集节点上的 sync lag 检查（REMOVE DATANODE 之后集群只剩 2 个 DN）
check_sync_lag_on(){ local nodes_str=$1 h line n bad v
  local nodes=(); read -ra nodes <<<"$nodes_str"
  local deadline=$(( $(date +%s) + SYNC_TIMEOUT_SEC )) stable=0
  while (( $(date +%s) < deadline )); do
    n=0; bad=0
    for h in "${nodes[@]}"; do
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        v=${line##* }; n=$((n+1))
        awk -v x="$v" 'BEGIN{exit !(x+0>0.0001)}' && bad=$((bad+1))
      done < <(curl -s -m 8 "http://$h:$DN_METRIC_PORT/metrics" 2>/dev/null | grep 'type="syncLag"')
    done
    log "  syncLag(子集) series=$n nonzero=$bad"
    if [ "${n:-0}" -gt 0 ] && [ "${bad:-1}" -eq 0 ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge "$SYNC_STABLE_CHECKS" ] && { pass "sync lag 已归零（子集节点，series=$n）"; return 0; }
    sleep 10
  done
  fail "子集节点 sync lag 未在 ${SYNC_TIMEOUT_SEC}s 内归零 (series=$n nonzero=$bad)"; return 1; }
# 指定节点子集的 CN/DN 日志异常扫描（REMOVE 场景用：被移除节点自身的日志噪声不计入）
cmp_check_logs_on(){ local nodes_str=$1 role h files n
  local nodes=(); read -ra nodes <<<"$nodes_str"
  log "=== CN/DN 异常日志分析（子集：$nodes_str）==="
  for role in confignode datanode; do
    for h in "${nodes[@]}"; do
      files=$(sshx "$h" "ls $DB_DIR/logs/*${role}*all*.log $DB_DIR/logs/*${role}*error*.log 2>/dev/null" 2>/dev/null | tr '\n' ' ')
      [ -z "$files" ] && { warn "$role $h 无日志文件"; continue; }
      n=$(sshx "$h" "grep -hE '$COMMON_ERR_PAT|$CMP_ERR_PAT' $files 2>/dev/null | grep -vcE '$BENIGN_PAT'" 2>/dev/null | tr -dc '0-9')
      if [ "${n:-0}" -gt 0 ]; then
        fail "$role $h 日志出现 $n 条异常"
        sshx "$h" "grep -nE '$COMMON_ERR_PAT|$CMP_ERR_PAT' $files 2>/dev/null | grep -vE '$BENIGN_PAT' | head -10 | cut -c1-240" >>"$OUT" 2>&1
      else
        pass "$role $h 日志无异常"
      fi
    done
  done; }
# 性能基准记录
# 用法：cmp_perf_record <case> <points> <in_files> <in_bytes> <out_files> <out_bytes> <seconds>
cmp_perf_record(){ local case=$1 pts=$2 inf=$3 inb=$4 outf=$5 outb=$6 secs=$7 csv="$OUTDIR/perf_baseline.csv" prev ratio
  [ -f "$csv" ] || echo 'Time,build,consensus,case,points,in_files,in_bytes,out_files,out_bytes,merge_seconds,points_per_sec,write_amp' >>"$csv"
  prev=$(grep -F ",$case," "$csv" 2>/dev/null | grep -F ",$BUILD_TAG," | tail -1 | awk -F, '{print $10}')
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date --iso-8601=seconds)" "$BUILD_TAG" "${CONSENSUS_CLASS##*.}" "$case" \
    "$pts" "$inf" "$inb" "$outf" "$outb" "$secs" \
    "$(awk -v p="$pts" -v s="$secs" 'BEGIN{printf "%.1f", (s>0? p/s : 0)}')" \
    "$(awk -v a="$inb" -v b="$outb" 'BEGIN{printf "%.2f", (a>0? b/a : 0)}')" >>"$csv"
  log "  性能已记录到 $csv：points=$pts in=${inb}B($inf 文件) out=${outb}B($outf 文件) 合并耗时=${secs}s"
  if [ -n "${prev:-}" ]; then
    ratio=$(awk -v a="$secs" -v b="$prev" 'BEGIN{printf "%.2f", (b>0? a/b : 0)}')
    log "  与同构建历史基线（${prev}s）比：本次 ${secs}s，比值 $ratio"
    awk -v r="$ratio" -v lim="$CO_PERF_WARN_RATIO" 'BEGIN{exit !(r+0 > lim+0)}' && warn "合并耗时是历史基线的 ${ratio} 倍（阈值 ${CO_PERF_WARN_RATIO}）"
  fi; }

# ---------------------------------------------------------------------------
# 基础场景构件（CO-18 起共用；CO-17 内有一份等价的局部实现，为保持"已验证脚本不动"未合并）
#   设计要点（CO-17 的血泪教训，见 SKILL.md §4）：
#     ① 单设备 ⇒ 每个副本只落 1 个 data region，文件数可控；
#     ② 批次时间戳严格递增 ⇒ 落 sequence/；要 unseq 就写"在 seq 水位区间内且更早"的批次；
#     ③ 每批写完必须等各副本 **close 事件**达标再写下一批（`flush;` 返回后 TsFile 仍可追加）；
#     ④ 判据一律用"各副本布局是否一致"（`cmp_lay_uni`）而不是聚合计数。
# ---------------------------------------------------------------------------
# 各副本 TsFile 层级计数（L0..L3），形如 "77:1/0/0/0 78:1/0/0/0 79:1/0/0/0 "
cmp_lay(){ local h spec=""
  for h in "${DN[@]}"; do
    spec="$spec${h##*.}:$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$1/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '{c[\$3]++} END{printf \"%d/%d/%d/%d\", c[0]+0, c[1]+0, c[2]+0, c[3]+0}'" 2>/dev/null) "
  done; printf '%s' "$spec"; }
# 各副本布局去重串（一致时只有一个值，形如 "1/0/0/0 "）
cmp_lay_uni(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' '; }

# ---------------------------------------------------------------------------
# 判据集（judge set）口径 —— **V1 = 全部副本 / V2 = region leader**
#   依据（2026-10-17 定性，逐条证据见 _scratch/RC8_V2_DIVERGENCE_TRIAGE.md §② 与 §3.4/§3.5/§3.6/§3.8）：
#     · V2 的 follower **不 flush 自己的 memtable**：共识管道收到的 TsFile 一律按 LOAD 路径落
#       **unsequence**（DataRegion.java:4984 `setSeq(false)` / :5009 `loadTsFileToUnSequence`），
#       只有 region leader 会 flush 自己的 memtable ⇒ **只有 leader 持有 sequence 文件**。
#     · 因此"三副本同布局 / 各副本文件数相等 / 三副本都出 L1..L3"在 V2 下**结构性不成立**
#       （设计差异，非产品缺陷）；CO-15/CO-39/CO-41/CO-38/DT-08 的旧判据全部栽在这一点上。
#     · 判据集按副本角色**动态**确定（不依赖固定 IP、不会为空）：
#         V1 → 全部副本（与改动前的口径**完全一致，一处不放松**）；
#         V2 → 本相 leader：① 优先"该库有 `Async close tsfile` 事件"的副本（= flush 过自己的 memtable），
#              ② 退到"持有该库 sequence 文件"的副本，③ 都还没有（刚建库/刚写入未落盘）⇒ 退回全部副本。
#     · 非判据副本（follower）的差异**只 WARN + 打印逐副本布局**作证据，不判 FAIL；
#       **硬判据一处不放松**：判据集侧的 finishes 增量、数据指纹/行数、收尾三件套（sync lag /
#       副本一致性 / 日志扫描）仍按原口径判定。
# ---------------------------------------------------------------------------
cmp_is_v2(){ case "${DATA_CONSENSUS:-}${CONSENSUS_CLASS:-}" in *IoTConsensusV2*) echo 1 ;; *) echo 0 ;; esac; }
# 单副本的 TsFile 层级计数（L0/L1/L2/L3），形如 "1/1/0/0"
cmp_lay_of(){ sshx "$1" "find $DB_DIR/data/datanode/data -path '*/$2/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '{c[\$3]++} END{printf \"%d/%d/%d/%d\", c[0]+0, c[1]+0, c[2]+0, c[3]+0}'" 2>/dev/null; }
# 判据集节点（空格分隔）
cmp_judge_nodes(){ local db=$1 h out=""
  [ "$(cmp_is_v2)" = 0 ] && { printf '%s' "${DN[*]}"; return; }
  for h in "${DN[@]}"; do [ "$(ttl_close_cnt "$h" "$db")" -gt 0 ] && out="$out $h"; done
  if [ -z "$out" ]; then for h in "${DN[@]}"; do [ "$(cmp_seq_cnt "$h" "$db")" -gt 0 ] && out="$out $h"; done; fi
  [ -z "$out" ] && out=" ${DN[*]}"
  printf '%s' "${out# }"; }
# 探一次判据集布局（结果放全局，避免一个判据里重复 ssh）：
#   CMPJ_JUDGE 判据集节点；CMPJ_JUDGE_SPEC 判据集逐副本布局；CMPJ_JUDGE_UNI 判据集去重布局
#   CMPJ_OTHER_SPEC / CMPJ_OTHER_UNI 非判据副本（V2 follower）的布局，仅作证据
CMPJ_JUDGE=""; CMPJ_JUDGE_SPEC=""; CMPJ_JUDGE_UNI=""; CMPJ_OTHER_SPEC=""; CMPJ_OTHER_UNI=""
cmp_lay_probe(){ local db=$1 h lay judge
  judge=$(cmp_judge_nodes "$db")
  CMPJ_JUDGE="$judge"; CMPJ_JUDGE_SPEC=""; CMPJ_OTHER_SPEC=""
  for h in $judge; do lay=$(cmp_lay_of "$h" "$db"); CMPJ_JUDGE_SPEC="$CMPJ_JUDGE_SPEC${h##*.}:$lay "; done
  for h in "${DN[@]}"; do case " $judge " in *" $h "*) continue ;; esac
    CMPJ_OTHER_SPEC="$CMPJ_OTHER_SPEC${h##*.}:$(cmp_lay_of "$h" "$db") "; done
  CMPJ_JUDGE_UNI=$(printf '%s\n' "$CMPJ_JUDGE_SPEC" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' ')
  CMPJ_OTHER_UNI=$(printf '%s\n' "$CMPJ_OTHER_SPEC" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' '); }
# 判据：判据集布局是否全 == want（用返回码；同时刷新 CMPJ_* 证据变量）
cmp_lay_ok(){ local db=$1 want=$2; cmp_lay_probe "$db"; [ "$CMPJ_JUDGE_UNI" = "$want " ]; }
# 是否**至少一台**副本的布局 == want（V2 的"场景是否存在"类前置用；V1 下等价于全部副本都达到）
cmp_any_lay(){ local db=$1 want=$2 h; for h in "${DN[@]}"; do [ "$(cmp_lay_of "$h" "$db")" = "$want" ] && return 0; done; return 1; }
# follower 证据：非判据副本布局与 want 不同 ⇒ 只 WARN + 打印逐副本布局（V2 设计差异，不判 FAIL）
cmp_warn_followers(){ local tag=$1 want=$2
  [ -n "${CMPJ_OTHER_SPEC:-}" ] || return 0
  [ "${CMPJ_OTHER_UNI:-}" = "$want " ] && return 0
  warn "  $tag：非判据副本布局 ${CMPJ_OTHER_SPEC% } 与判据集（${CMPJ_JUDGE_SPEC:-未探测}）不同 —— V2 follower 的 TsFile 落 unsequence（DataRegion.java:4984/5009，设计差异、非缺陷），判据只看 leader"
  return 0; }
# 统一布局判据入口：cmp_check_lay <tag> <db> <want>
#   判据集达标 ⇒ PASS（并对 follower 差异 WARN）；不达标 ⇒ FAIL 并附**逐副本**布局。返回 0/1。
cmp_check_lay(){ local tag=$1 db=$2 want=$3
  if cmp_lay_ok "$db" "$want"; then
    pass "  $tag（判据集 ${CMPJ_JUDGE_SPEC% } = $want）"
    cmp_warn_followers "$tag" "$want"
    return 0
  fi
  fail "  $tag 未成立：判据集 ${CMPJ_JUDGE_SPEC:-（空）} 未达 $want（各副本 $(cmp_lay "$db")）"
  return 1; }
# 场景有效性类布局前置：判据集达标 ⇒ PASS；仅"至少一台"达标 ⇒ PASS + WARN（V2 follower 差异是常态）；
# 一台都不达标 ⇒ FAIL（**不放松**：场景必须真的存在于某个副本上）。返回 0=场景成立 / 1=不成立。
cmp_scene_lay(){ local tag=$1 db=$2 want=$3
  if cmp_lay_ok "$db" "$want"; then
    pass "  $tag（判据集 ${CMPJ_JUDGE_SPEC% } = $want）"
    cmp_warn_followers "$tag" "$want"
    return 0
  fi
  if cmp_any_lay "$db" "$want"; then
    warn "  $tag：判据集 ${CMPJ_JUDGE_SPEC:-（空）} 未达 $want，但**至少一台**副本达到（各副本 $(cmp_lay "$db")）⇒ 场景成立（V1=全部副本 / V2=leader 口径；V2 follower 不 flush memtable、文件落 unsequence，属设计差异）"
    return 0
  fi
  fail "  $tag 未成立：判据集 ${CMPJ_JUDGE_SPEC:-（空）} 与全部副本都未达到 $want（各副本 $(cmp_lay "$db")）"
  return 1; }
# 判据集上的 level-0 文件数统计（cmp_scene_lay 的数值版本，CO-38 之类的"L0 是否够数"前置用）
cmp_judge_l0_stat(){ local db=$1 how=$2 h out="" n
  for h in $(cmp_judge_nodes "$db"); do n=$(cmp_lay_of "$h" "$db"); n=${n%%/*}; out="$out ${n:-0}"; done
  out=$(printf '%s\n' $out | sed '/^$/d' | sort -n)
  [ -z "$out" ] && { echo 0; return; }
  if [ "$how" = max ]; then printf '%s\n' "$out" | tail -1; else printf '%s\n' "$out" | head -1; fi; }
# 判据集的 seq/unseq 计数去重串（等待用，形如 "1/2 "）
cmp_su_judge_uni(){ local db=$1 h spec=""
  for h in $(cmp_judge_nodes "$db"); do spec="$spec${h##*.}:$(cmp_seq_cnt "$h" "$db")/$(cmp_unseq_cnt "$h" "$db") "; done
  printf '%s\n' "$spec" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' '; }
# 各副本 seq/unseq 文件数，形如 "77:1/3 78:1/3 "
cmp_su(){ local h spec=""
  for h in "${DN[@]}"; do spec="$spec${h##*.}:$(cmp_seq_cnt "$h" "$1")/$(cmp_unseq_cnt "$h" "$1") "; done
  printf '%s' "$spec"; }
# ---------------------------------------------------------------------------
# 等待窗口口径（协议感知）—— 判据集见上（V1=全部副本 / V2=leader）
#   P2 依据（CO-39 实测）：V2 下 follower 整轮不 `Async close`、也不 flush 自己的 memtable
#   ⇒ 旧的"三副本全部达标才放行"会每次都白等满窗口（23 次 × ~106s ≈ +2400s，748s → 3458s）。
#   · 放行条件①（严格）：**判据集**每台都达标（V1 下等价于"全部副本都达标"，与旧口径一致）；
#   · 放行条件②（quorum，**仅 V2**）：已有 ≥ CMP_CLOSE_QUORUM 台判据集副本达标，
#     且已等 ≥ CMP_CLOSE_MIN_WAIT_SEC 秒（这两个变量在 conf/env.conf 里已有说明，V1 不启用）；
#   · close 等待窗口上限 CMP_WAIT_CLOSE_WIN（默认 30s；callers 传更大的值也会被压到该上限）。
#     一个副本都没达标 ⇒ 仍等满窗口并 WARN"场景未成立"（不静默放过）。
# ---------------------------------------------------------------------------
CMP_WAIT_CLOSE_WIN=${CMP_WAIT_CLOSE_WIN:-30}
CMP_CLOSE_QUORUM=${CMP_CLOSE_QUORUM:-1}
CMP_CLOSE_MIN_WAIT_SEC=${CMP_CLOSE_MIN_WAIT_SEC:-10}
# 等判据集副本"该库 close 事件数" >= min；0=达成 1=超时。回显 "循环次数|strict|quorum|timeout|<逐副本实测>"
cmp_wait_close(){ local db=$1 min=$2 t=${3:-$CMP_WAIT_CLOSE_WIN} dl h n ok got spec judge t0 i=0
  t=${t:-$CMP_WAIT_CLOSE_WIN}; [ "$t" -gt "$CMP_WAIT_CLOSE_WIN" ] && t=$CMP_WAIT_CLOSE_WIN
  t0=$(date +%s); dl=$(( t0 + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 )); ok=1; got=0; spec=""; judge=$(cmp_judge_nodes "$db")
    for h in $judge; do n=$(ttl_close_cnt "$h" "$db"); n=${n:-0}; spec="$spec${h##*.}:$n "
      if [ "$n" -ge "$min" ]; then got=$(( got + 1 )); else ok=0; fi; done
    [ "$ok" = 1 ] && { echo "$i|strict|$spec"; return 0; }
    if [ "$(cmp_is_v2)" = 1 ] && [ "$got" -ge "$CMP_CLOSE_QUORUM" ] && [ $(( $(date +%s) - t0 )) -ge "$CMP_CLOSE_MIN_WAIT_SEC" ]; then
      echo "$i|quorum|$spec"; return 0
    fi
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i|timeout|$spec"; return 1; }
# 等**判据集**的层级布局统一 == want（如 1/1/0/0）；0=达成 1=超时（回显循环次数）
cmp_wait_lay(){ local db=$1 want=$2 t=${3:-150} dl i=0
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 ))
    cmp_lay_ok "$db" "$want" && { echo "$i"; return 0; }
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i"; return 1; }
# 等**至少一台**副本的布局 == want（V2 的"场景是否存在"类前置；CO-39 段 1 用）
cmp_wait_any_lay(){ local db=$1 want=$2 t=${3:-150} dl i=0
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 ))
    cmp_any_lay "$db" "$want" && { echo "$i"; return 0; }
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i"; return 1; }
# 等**判据集**的 seq/unseq 计数统一 == want（如 1/3）；0=达成 1=超时
cmp_wait_su(){ local db=$1 want=$2 t=${3:-150} dl i=0
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    i=$(( i + 1 ))
    [ "$(cmp_su_judge_uni "$db")" = "$want " ] && { echo "$i"; return 0; }
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done
  echo "$i"; return 1; }
# 建库 + 单设备 d1 的 INT64 序列（单 region 场景）
cmp_mkdb1(){ local db=$1
  sq "create database $db;" >/dev/null
  sq "create timeseries $db.d1.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null; }
# 写一批（单设备 d1；rows 行；时间戳 base+k*10 递增）+ 等 close + 等布局达到 want
cmp_batch1(){ local db=$1 b=$2 base=$3 want=$4 rows=${5:-200} k vals=""
  for ((k=1;k<=rows;k++)); do vals="$vals($(( base + k*10 )),$((k+b))),"; done
  sq "insert into $db.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  cmp_wait_close "$db" "$b" 90 >/dev/null || warn "    批$b：close 事件未达 $b（$(ttl_close_snapshot "$db")）"
  if cmp_wait_lay "$db" "$want" 120 >/dev/null; then log "    批$b 就绪：布局=$(cmp_lay "$db")"
  else warn "    批$b 未达预期布局 $want（实际 $(cmp_lay "$db")）"; fi
  sleep 3; }
# inner/cross 任务的"单任务文件数"分布（inner 用 `N files`，cross 见 cmp_cross_unseq_nums）
cmp_task_nums(){ local db=$1 kind=$2 h pat
  case "$kind" in
    cross) pat='[Compaction] CrossSpaceCompaction task starts with' ;;
    *)     pat='InnerSpaceCompaction task starts with' ;;
  esac
  for h in "${DN[@]}"; do
    sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -E '(^|[- ])(root\.)?$db-[0-9]+' | sed -E 's/.*starts with ([0-9]+) files.*/\1/'" 2>/dev/null
  done | grep -E '^[0-9]+$' | sort -n | uniq -c | awk '{printf "%s×%s ", $2, $1}'; echo; }
# cross 任务"每任务 unseq 数"分布（日志格式：`[Compaction] CrossSpaceCompaction task starts with N seq files and M unsequence files`）
cmp_cross_unseq_nums(){ local db=$1 h
  for h in "${DN[@]}"; do
    sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '[Compaction] CrossSpaceCompaction task starts with' | grep -E '(^|[- ])(root\.)?$db-[0-9]+' | sed -E 's/.*and ([0-9]+) unsequence files.*/\1/'" 2>/dev/null
  done | grep -E '^[0-9]+$' | sort -n | uniq -c | awk '{printf "%s×%s ", $2, $1}'; echo; }
cmp_task_cnt(){ local db=$1 kind=$2 h pat n s=0
  case "$kind" in
    cross) pat='[Compaction] CrossSpaceCompaction task starts with' ;;
    *)     pat='InnerSpaceCompaction task starts with' ;;
  esac
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done; echo "${s:-0}"; }
cmp_task_max(){ printf '%s\n' "$1" | awk '{for(i=1;i<=NF;i++){split($i,a,"×"); if(a[1]+0>m) m=a[1]+0}} END{print m+0}'; }
# 某库的删除标记文件数
#   ⚠️ 2.0.12.1 默认后缀是 **`.mods2`**（`ModificationFile.java:64` `FILE_SUFFIX = ".mods2"`），
#      `.mods` 是旧版 v1 的（`ModificationFileV1.java:56`）。只按 `*.mods` 数会**恒为 0**（RC8 实测踩到）。
#      合并过程中的临时文件 `*.compaction.mods2`（`ModificationFile.java:65`）不算"真删除标记"，排除掉。
cmp_mods_cnt(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' \( -name '*.mods' -o -name '*.mods2' \) ! -name '*.compaction.mods2' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
cmp_mods_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cmp_mods_cnt "$h" "$1") )); done; echo "$s"; }
# 该库的 TsFile 名列表（判"文件是否被重写/改名"）
cmp_names(){ local h; for h in "${DN[@]}"; do sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$1/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | sort" 2>/dev/null; done | sort | tr '\n' ' '; echo; }
# 残留临时文件（合并中断/恢复后不应留下 *.compaction.log / *.tmp）
cmp_tmp_leftover(){ local h n s=0
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$1/*' \( -name '*.compaction.log' -o -name '*.tmp' -o -name '*.merge' \) 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} )); done; echo "$s"; }

# ---------------------------------------------------------------------------
# 修改数据类型（DT-xx 用例共用）
# ---------------------------------------------------------------------------
# 树模型某序列当前的数据类型（按 `show timeseries` 表头定位 DataType 列，避免列序变化导致误判）
# 用法：cmp_series_type <path> [node]   不给 node 就用 CLI 默认节点
cmp_series_type(){ local p=$1 node=${2:-} out idx
  if [ -n "$node" ]; then out=$(sq_node "$node" "show timeseries $p;" 2>/dev/null); else out=$(sq "show timeseries $p;" 2>/dev/null); fi
  idx=$(printf '%s\n' "$out" | awk -F'|' '/Timeseries/{for(i=1;i<=NF;i++){gsub(/ /,"",$i); if($i=="DataType"){print i; exit}}}')
  [ -z "${idx:-}" ] && { echo "?"; return; }
  printf '%s\n' "$out" | awk -F'|' -v i="$idx" -v p="$p" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); if($2==p){v=$i; gsub(/[ \t]/,"",v); print v; exit}}'; }
# 某序列在**所有副本**上的类型是否都等于期望值（1=一致/0=不一致；不一致时打印差异）
cmp_type_same_all(){ local p=$1 want=$2 h v ok=1
  for h in "${DN[@]}"; do v=$(cmp_series_type "$p" "$h"); [ "$v" = "$want" ] || { ok=0; log "      副本 $h 类型=$v（期望 $want）"; }; done
  echo "$ok"; }
# 单序列数据指纹（任意类型可用；混合类型库不能用 cmp_fp_tree —— sum 会 701）
# ⚠️ 树方言的 FROM 要写**设备路径**：`select s1 from root.db.dev` ✅；写成序列路径 `root.db.dev.s1` 会返回 Empty set
cmp_fp_series(){ local p=$1 dev meas; dev="${p%.*}"; meas="${p##*.}"
  cmp_fingerprint tree "select $meas from $dev order by time;"; }
# 单序列前 N 行的值（`|` 分隔），便于人工核对类型转换（同样用设备路径）
cmp_vals_series(){ local p=$1 n=${2:-5} dev meas; dev="${p%.*}"; meas="${p##*.}"
  sq "select $meas from $dev order by time limit $n;" 2>&1 | grep -E '^\|' | tail -n +2 \
    | awk -F'|' '{v=$3; gsub(/^[ \t]+|[ \t]+$/,"",v); printf "%s|", v}'; echo; }
# 设备路径下的行数（树方言）
cmp_rows_series(){ local p=$1 dev meas; dev="${p%.*}"; meas="${p##*.}"
  sq "select $meas from $dev order by time;" 2>&1 | data_rows | wc -l | tr -dc '0-9'; }
# ---- 表模型结果集：**按列名**取值/数行 -------------------------------------
# 坑（本轮实测）：表模型 `SELECT` **只返回投影列**（不像树模型那样自动带 Time 列），
# `select v from t order by time` 的结果每行只有 1 列（`|11|`），所以**不能**硬编码列序号
# （曾把 c 写成 3 ⇒ 取到空串，断言"值可读"变成空判据）。这里统一按**表头**定位列号。
cmp_tbl_col_vals(){ local sql=$1 col=$2 node=${3:-} out idx
  if [ -n "$node" ]; then out=$(sqt_node "$node" "$sql" 2>&1); else out=$(sqt "$sql" 2>&1); fi
  idx=$(printf '%s\n' "$out" | grep -E '^\|' | head -1 | awk -F'|' -v c="$col" '{for(i=2;i<NF;i++){v=$i; gsub(/^[ \t]+|[ \t]+$/,"",v); if(v==c){print i; exit}}}')
  if [ -z "$idx" ]; then echo "NOCOL:$col"; return; fi
  printf '%s\n' "$out" | table_rows | sed -E 's/[[:space:]]+/ /g' \
    | awk -F'|' -v i="$idx" '{v=$i; gsub(/^[ \t]+|[ \t]+$/,"",v); printf "%s|", v}'; echo; }
# 表模型结果集的**数据行**数（table_rows 已剔除表头与分隔线）
cmp_tbl_rows(){ local sql=$1 node=${2:-} out
  if [ -n "$node" ]; then out=$(sqt_node "$node" "$sql" 2>&1); else out=$(sqt "$sql" 2>&1); fi
  printf '%s\n' "$out" | table_rows | wc -l | tr -dc '0-9'; }
# 各副本 level-0 TsFile 数的**最小值**（cmp_lay 布局串第 1 段）；>=2 才说明"确有文件可合并"
cmp_min_l0(){ local db=$1 lay h n min=999
  lay=$(cmp_lay "$db")
  for h in "${DN[@]}"; do
    n=$(printf '%s\n' "$lay" | tr ' ' '\n' | grep -E "^${h##*.}:" | cut -d: -f2 | cut -d/ -f1)
    [ -n "$n" ] && [ "$n" -lt "$min" ] && min=$n
  done; echo "$min"; }
# 表模型某列的当前类型（`desc` 里 ColumnName→DataType）
cmp_tbl_coltype(){ local tbl=$1 col=$2
  sqt "desc $tbl;" 2>/dev/null | awk -F'|' -v c="$col" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3); if($2==c){print $3; exit}}'; }
# 一条 ALTER TIMESERIES 的响应（去掉表头/耗时行）
cmp_alter_ts(){ sq "alter timeseries $1 set data type $2;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' '; }
# 一条表模型 ALTER COLUMN 的响应
cmp_alter_col(){ sqt "$1" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' '; }
