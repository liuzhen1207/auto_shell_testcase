#!/bin/bash
# ============================================================================
# CR-10 DELETE 阻塞写入的量化：单次删除耗时随 TsFile 数变化 + 关/开合并机制对照
#       覆盖 R-38 / R-39 / R-40 / R-41（出处：docs/REQ_MATRIX.md §3 CR-10 + §1 逐字原文）
#
# 语义（逐字对照需求）：
#   R-38「在 delete 操作记录 mods 文件时，其操作耗时与 tsfile 文件数量成正比，且该阶段会一直持有
#         RegionWriteValidationRWLock().writeLock()，而写入也会拿这把锁，所以 delete 会阻塞实时写入。」
#        「单个 region 的单次 delete 操作的耗时 = region 内 tsfile 文件数量 * 单次写 mods 文件的耗时」
#   R-39「中冶赛迪的场景，单个 region 内包含大约 800 多个 tsfile，单次写 mods 文件的耗时为 5-10ms，
#         所以 单个 region 的单次 delete 操作的耗时在 4-8 s，这 4-8s 内，是阻塞该 region 的」
#   R-40「Delete 命令在 ConfigNode 的 DeleteTimeseriesProcedure 中被发向所有副本，每个副本又会将
#         delete 记到 log 中，并向其他副本同步。」／「一条 delete 命令被记录多次」
#   R-41「加快删除序列操作的效率，使其对 IoTDB 实时写入影响尽量小。」
#
# 【量化口径（本环境的现实约束，务必先读）】
#   · 耗时**不**用 CLI 的 wall-clock：每次 `sqt` 都新起 JVM（进程启动 2~4s）会把毫秒级删除淹没，
#     且 DELETE 属非查询语句、CLI **不打印** "It costs"（源码 `AbstractCli.executeQuery`:627 只在
#     `hasResultSet` 分支打印）。⇒ 用**服务端日志、同一节点时钟**的两个标记差：
#       起点 `[Deletion] Executing table deletion …`（`DataRegion.deleteByTable`:3316，加写锁前）
#       终点 `[Deletion] Deletion … is written into N mod files`（`deleteDataInSealedFiles` 收尾:4056）
#     两者同文件同节点 ⇒ 相减即"删除记录 mods 文件"阶段的耗时（R-38 的那个量）。
#     解析失败时退化为 wall-clock − CLI 基线开销，并 WARN 标注"含进程开销"。
#   · **硬判据不是耗时**（原文 800 tsfile / 5-10ms / 4-8s 来自客户现场，本环境不设绝对阈值）：
#       硬判 1（场景有效性）：每个 tier 的真实 TsFile 数按预期分层（打印实际值）
#       硬判 2：删除可见（`time <= T` 行数 == 0）
#       硬判 3：未被删除的数据可见且逐值不变（`T < time < WBASE` 指纹 == 删除前）
#       硬判 4：并发写入的行一条不少（`time >= WBASE` 行数 == 成功语句数 × 每语句行数）
#       硬判 5：删除语句本身无报错
#     降级 WARN：耗时趋势（tier 递增 ⇒ 耗时不减）、关/开合并对照（开相耗时应 ≤ 关相）、
#              删除期间写入是否推进/停顿、分辨率不足（<100ms）、`is written into N mod files` 取不到 N
#   · R-40/R-45 只做**证据面**（记录一次 DELETE 在各节点产生的 `[Deletion]` 行数与 `N mod files`），
#     **不判**"优化是否落地"（REQ_MATRIX §4-B9：不可判）。
#
# 布局构造（关键）：每个 tier 用**独立库**，库内"每批一个 TsFile、每批一个设备、所有批时间范围相同"：
#   · 每批一个设备（不同 tag 值）⇒ 行不重复、可精确计数；
#   · 所有批时间范围相同 ⇒ 所有 TsFile 都与删除区间重叠（`canSkipDelete` 按时间区间判:3814）
#     ⇒ 删除会走到**全部** TsFile（这才是"耗时 ∝ TsFile 数"的前提）；
#   · 删除区间取时间范围中点 ⇒ 没有 TsFile 因"时间全匹配"而走 deleteTsFileCompletely。
#
# 时长：约 14~18 分钟（3 个 tier + 1 个机制对照相 + 4 段并发写入 + 收尾三件套）
# 规模与配置（顶部变量）：
CR10_T1=${CR10_T1:-8}               # tier1 批数（= 每副本 TsFile 数）
CR10_T2=${CR10_T2:-24}              # tier2
CR10_T3=${CR10_T3:-48}              # tier3（原文 800 级太慢；按要求降到可观察趋势的量级并如实记录实际值）
CR10_CTL=${CR10_CTL:-24}            # 机制对照相批数（与 tier2 同规模，但删除前热开合并）
CR10_ROWS=${CR10_ROWS:-200}         # 每批每设备行数（时间戳 BASE + i*10）
CR10_WROW=${CR10_WROW:-40}          # 并发写入线程每条 INSERT 行数
CR10_WSTMT=${CR10_WSTMT:-250}       # 并发写入线程语句数（上限行数 = CR10_WROW × CR10_WSTMT）
CR10_BASE_WIN=${CR10_BASE_WIN:-5}   # 基线观察窗口（秒）
CR10_WIN=${CR10_WIN:-180}           # 等落盘/可见的窗口（秒）
CR10_RES_MS=${CR10_RES_MS:-100}     # 耗时分辨率下限（低于此值判"分辨率不足"，不判"未阻塞"）
CR10_MERGE_WIN=${CR10_MERGE_WIN:-120}  # 对照相等合并推进的窗口（秒）
#
# 预期报错：无
# 用法： bash cases/common/cr_delete_block_write.sh [--consensus IoTConsensus|IoTConsensusV2]
#
# ★ harness 修复记录（RC8 首轮实跑暴露，用例侧）：`并发写入的行全可见` 与 `硬判：并发写入一条不少`
#   报 `实际=[10009] 期望=[10000]`。原因**不是**基线取早/取晚，而是**数行口径**：
#   CLI 单条查询结果超过一批（实测 1000 行/批）会**重复打印表头**，lib 的 `table_rows` 只丢第一行
#   ⇒ 10000 行（10 批）= 10000 + 9 个重复表头 = 10009。现改为按"表头原文"整行剔除后计数
#   （`cr10_body_cnt`），期望值 10000 **不变**（不是把期望改成实际值）。
#   同一机制影响 CR-02（5000→5004）与 CR-06 表模型行数，均已各自修。
#   ⚠ 本任务只做 `bash -n` 与本地纯桩验证，**未在集群实跑**。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_delete_block_write_${DATA_CONSENSUS}"

BASE=$(( $(now_ms) - 3600000 ))          # 1 小时前：全部时间戳在过去、同一时间分区
DEL_T=$(( BASE + (CR10_ROWS / 2) * 10 )) # 删除时间范围的中点
WBASE=$(( BASE + 1000000 ))              # 并发写入线程时间戳起点（> 全部被测数据 ⇒ 永不被删）
TIERS="$CR10_T1 $CR10_T2 $CR10_T3"
N_ARR=(); DUR_ARR=(); MODS_ARR=(); LINE_ARR=(); WOK_ARR=()
DB_T1=cr10t1; DB_T2=cr10t2; DB_T3=cr10t3; DB_CTL=cr10ctl
TB_T1=t1; TB_T2=t2; TB_T3=t3; TB_CTL=tc

# ---------------------------------------------------------------------------
# 观测/计时 helper
# ---------------------------------------------------------------------------
# 行数口径（表方言）：**不能用 `table_rows | wc -l`** —— CLI 单条结果超过一批（实测 1000 行/批）
#   会**重复打印表头**，lib 的 table_rows 只丢第一行 ⇒ 多批时行数虚高（RC8 实测：
#   10000 行被数成 **10009** = 10000 + 9 个重复表头；CR-02 的 5000→5004 同一原因）。
#   这里按"表头原文"整行剔除后再数。
cr10_rows_table(){ cr10_body_cnt "$(sqt "$1" 2>&1)"; }
cr10_body_cnt(){ printf '%s\n' "$1" | grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' \
  | awk -F'|' 'NR==1{h=$2; next} {if ($2==h) next; c++} END{print c+0}'; }
cr10_fp(){ cmp_fingerprint table "select v from $1 where time > $DEL_T and time < $WBASE order by time;"; }
# 该库在各副本/两空间的 TsFile 总数（只读观测）
cr10_files_dn(){ local v; v=$(sshx "$1" "find $DB_DIR/data/datanode/data -path '*/$2/*' -name '*.tsfile' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
cr10_files_snapshot(){ local h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(cr10_files_dn "$h" "$1") "; done; echo "$out"; }
cr10_files_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cr10_files_dn "$h" "$1") )); done; echo "$s"; }
# 时间戳（日志前缀 `YYYY-MM-DD HH:MM:SS,mmm`）→ epoch ms（GNU date；失败退化到秒级）
cr10_ts_ms(){ local t=$1 v
  v=$(date -d "$(printf '%s' "$t" | tr ',' '.')" +%s%3N 2>/dev/null)
  [ -n "$v" ] && { echo "$v"; return; }
  v=$(date -d "$(printf '%s' "$t" | cut -c1-19)" +%s 2>/dev/null)
  [ -n "$v" ] && { echo $(( v * 1000 )); return; }
  echo ""; }
# 某节点上该表的全部 `[Deletion]` 行（远端用双引号包 tableName='x' ⇒ 单引号原样传到远端）
cr10_del_lines(){ sshx "$1" "cat $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -hE '\\[Deletion\\]' | grep -hF \"tableName='$2'\"" 2>/dev/null | tr -d '\r'; }
# 由"本次删除新增的 [Deletion] 行"算服务端耗时与覆盖的 mod 文件数；回显 "start end dur_ms mods lines"
cr10_measure(){ local f=$1 start="" end="" mods=0 l ts n dur="-"
  if [ ! -s "$f" ]; then echo "- - - 0 0"; return; fi
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    ts=$(cr10_ts_ms "$(printf '%s' "$l" | cut -c1-23)")
    [ -z "$ts" ] && continue
    printf '%s' "$l" | grep -q 'Executing table deletion' && [ -z "$start" ] && start=$ts
    end=$ts
    n=$(printf '%s' "$l" | sed -nE 's/.*is written into ([0-9]+) mod files.*/\1/p')
    if [ -n "$n" ] && [ "$n" -gt "$mods" ]; then mods=$n; fi
  done <"$f"
  if [ -n "$start" ] && [ -n "$end" ]; then dur=$(( end - start )); fi
  echo "$start $end $dur $mods $(grep -c . "$f")"; }
cr10_prog(){ local v; v=$(grep -c 'successfully' "$1" 2>/dev/null); echo "${v:-0}"; }
# 采样序列（sample_ms count）在 [a,b] 窗口内的"最大无进展间隔"（ms）；样本 <2 返回 -1
cr10_max_stall(){ awk -v a="$1" -v b="$2" '
    { if ($1+0 >= a+0 && $1+0 <= b+0) { n++; t[n]=$1+0; c[n]=$2+0 } }
    END {
      if (n < 2) { print -1; exit }
      max = 0; last = t[1]; lastc = c[1]
      for (i = 2; i <= n; i++) { if (c[i] > lastc) { if (t[i] - last > max) max = t[i] - last; last = t[i]; lastc = c[i] } }
      if (t[n] - last > max) max = t[n] - last
      print max
    }' "$3"; }
cr10_wait_rows_table(){ local sql=$1 want=$2 timeout=${3:-$CR10_WIN} label=${4:-查询} got
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    got=$(cr10_rows_table "$sql"); got=${got:-0}
    [ "$got" = "$want" ] && { pass "$label: $got"; return 0; }
    sleep 3
  done
  fail "$label: 实际=[${got:-?}] 期望=[$want]（等 ${timeout}s 仍未一致）"; return 1; }
# 每副本 TsFile 数都 ≥ want（文件在 close 时才注册进 manager ⇒ 文件数就是"已落盘"的代理）
cr10_wait_files(){ local db=$1 want=$2 timeout=${3:-120} dl h n ok
  dl=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < dl )); do
    ok=1
    for h in "${DN[@]}"; do n=$(cr10_files_dn "$h" "$db"); [ "${n:-0}" -ge "$want" ] || ok=0; done
    [ "$ok" = 1 ] && return 0
    sqt "flush;" >/dev/null 2>&1
    sleep 3
  done
  return 1; }

# ---------------------------------------------------------------------------
# 场景构造
# ---------------------------------------------------------------------------
cr10_mkdb(){ local db=$1 tb=$2 out t
  sqt "create database $db;" >/dev/null
  out=$(sqt "create table $db.$tb (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD);")
  printf '%s' "$out" | grep -q 'successfully' && pass "  建表成功：$db.$tb" || fail "  场景无效：建表 $db.$tb 失败（$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)）"
  t=$(sqt "show tables from $db;")
  printf '%s' "$t" | grep -q "$tb" && pass "  show tables 确认 $db.$tb" || fail "  场景无效：show tables 里没有 $db.$tb"; }
cr10_fill(){ local db=$1 tb=$2 n=$3 b i vals="" r
  for ((b=1; b<=n; b++)); do
    vals=""
    for ((i=1; i<=CR10_ROWS; i++)); do vals="$vals($(( BASE + i * 10 )),'d$b',$(( i % 1000 ))),"; done
    r=$(sqt "insert into $db.$tb (time, dev, v) values ${vals%,};" 2>&1)
    printf '%s' "$r" | grep -q 'successfully' || warn "  [$db] 批$b 写入未确认成功：$(printf '%s' "$r" | tr '\n' ' ' | cut -c1-120)"
    sqt "flush;" >/dev/null 2>&1
    cr10_wait_files "$db" "$b" "$CR10_WIN" || warn "  [$db] 批$b 落盘后各副本 TsFile 未达 $b（$(cr10_files_snapshot "$db")）"
  done; }
# 并发写入线程：语句预生成到文件、单会话喂（避免每条语句新起 JVM 把并发窗口变成 3s 级）
cr10_writer_prepare(){ local db=$1 tb=$2 f=$3 i k vals
  : >"$f"
  for ((i=1; i<=CR10_WSTMT; i++)); do
    vals=""
    for ((k=0; k<CR10_WROW; k++)); do vals="$vals($(( WBASE + i * 1000 + k * 10 )),'dw',$(( k + 1 ))),"; done
    printf 'insert into %s.%s (time, dev, v) values %s;\n' "$db" "$tb" "${vals%,}" >>"$f"
  done; }

# ---------------------------------------------------------------------------
# 单个 tier：cr10_tier <db> <table> <批数> <off|on>
#   结果写到全局：T_DUR / T_MODS / T_LINES / T_WOK / T_FILES
#   ⚠ 不能靠 `echo` 回传：本文件里 log/pass/fail 都会往 stdout 打日志，会污染命令替换的结果
#     （CO-40 的经验：函数内既有日志又有回传值时，用全局变量）
# ---------------------------------------------------------------------------
T_DUR="-"; T_MODS=0; T_LINES=0; T_WOK=0; T_FILES=""
cr10_tier(){ local db=$1 tb=$2 n=$3 mode=$4
  local files del_base wstmt wout t0 t1 dur start end mods lines delout
  local wok pre_surv fp0 stall_base stall_del got_del got_surv got_w
  local dur_n mods_n lines_n ps f0 t0f dl h bf nf n0 allf delpid wpid dw
  T_DUR="-"; T_MODS=0; T_LINES=0; T_WOK=0
  log "--- [$db] tier：$n 批 / 每批 $CR10_ROWS 行 / 机制=$mode ---"
  cr10_mkdb "$db" "$tb"
  cmp_compaction_off
  cr10_fill "$db" "$tb" "$n"
  T_FILES=$(cr10_files_snapshot "$db")
  files=$(cr10_files_sum "$db")
  log "  [$db] 实际 TsFile 数（各副本）：$T_FILES（合计 $files）"
  [ "$(cmp_min_l0 "$db")" -ge 2 ] && pass "  [$db] 场景有效性：各副本 level-0 文件数最小 $(cmp_min_l0 "$db")（≥2）" \
    || fail "  [$db] 场景无效：min_l0=$(cmp_min_l0 "$db")（<2：攒不出「耗时 ∝ 文件数」的前提）"
  if [ "$mode" = on ]; then
    f0=$(cr10_files_sum "$db")
    cmp_compaction_on true true false
    dl=$(( $(date +%s) + CR10_MERGE_WIN ))
    while (( $(date +%s) < dl )); do
      t0f=$(cr10_files_sum "$db")
      [ "${t0f:-0}" -lt "${f0:-0}" ] && break
      sleep 5
    done
    log "  [$db] 对照相（机制开）：TsFile 合计 $f0 → $(cr10_files_sum "$db")（各副本 $(cr10_files_snapshot "$db")）"
    T_FILES=$(cr10_files_snapshot "$db")
    sleep 5
  fi
  pre_surv=$(cr10_rows_table "select v from $db.$tb where time > $DEL_T and time < $WBASE;")
  fp0=$(cr10_fp "$db.$tb")
  log "  [$db] 删除前：存活集行数=$pre_surv 指纹长度=${#fp0} 被删集行数=$(cr10_rows_table "select v from $db.$tb where time <= $DEL_T;")"
  for h in "${DN[@]}"; do cr10_del_lines "$h" "$tb" >"$ART/cr10_del_${db}_${h##*.}.base" 2>/dev/null; done
  # 并发写入线程（单会话，语句来自预生成文件）
  wstmt="$ART/cr10_w_${db}.sql"; wout="$ART/cr10_w_${db}.out"
  cr10_writer_prepare "$db" "$tb" "$wstmt"
  : >"$wout"
  session_table <"$wstmt" >"$wout" 2>&1 &
  wpid=$!
  dw=$(( $(date +%s) + 90 ))
  while (( $(date +%s) < dw )); do [ "$(cr10_prog "$wout")" -gt 0 ] && break; sleep 1; done
  [ "$(cr10_prog "$wout")" -gt 0 ] && pass "  [$db] 场景有效性：并发写入线程已产生成功语句（$(cr10_prog "$wout") 条）" \
    || warn "  [$db] 并发写入线程未产生成功语句 ⇒ 阻塞观察无从体现（记录）"
  ps="$ART/cr10_prog_${db}.txt"; : >"$ps"
  t0=$(now_ms)
  local end_base=$(( t0 + CR10_BASE_WIN * 1000 ))
  while (( $(now_ms) < end_base )); do printf '%s %s\n' "$(now_ms)" "$(cr10_prog "$wout")" >>"$ps"; sleep 0.2; done
  # 删除：后台发起 ⇒ 前台继续采样并发写入进度
  t0=$(now_ms)
  ( delout=$(sqt "delete from $db.$tb where time <= $DEL_T;" 2>&1); printf '%s' "$delout" >"$ART/cr10_delout_${db}.txt"; now_ms >"$ART/cr10_delt1_${db}.txt" ) &
  delpid=$!
  while kill -0 "$delpid" 2>/dev/null; do printf '%s %s\n' "$(now_ms)" "$(cr10_prog "$wout")" >>"$ps"; sleep 0.2; done
  wait "$delpid" 2>/dev/null || true
  t1=$(cat "$ART/cr10_delt1_${db}.txt" 2>/dev/null | tr -dc '0-9'); t1=${t1:-$(now_ms)}
  delout=$(cat "$ART/cr10_delout_${db}.txt" 2>/dev/null)
  printf '%s\n' "$delout" | sed 's/^/    delete→ /' >>"$OUT"
  assert_not_contains "  [$db] 删除未报错" "$(printf '%s' "$delout" | strip_echo)" 'Exception|Error|error|Failed|failed'
  log "  [$db] 删除 wall-clock 窗口：$(( t1 - t0 ))ms（含 CLI 往返，仅交叉校验）"
  # 等并发写入会话自然结束（语句确定 ⇒ 行数可精确核对），再算服务端耗时
  wait "$wpid" 2>/dev/null || true
  wok=$(cr10_prog "$wout"); T_WOK=$wok
  dur="-"; mods=0; lines=0
  for h in "${DN[@]}"; do
    bf="$ART/cr10_del_${db}_${h##*.}.base"; nf="$ART/cr10_del_${db}_${h##*.}.new"; allf="$ART/cr10_del_${db}_${h##*.}.all"
    n0=$(grep -c . "$bf" 2>/dev/null); n0=${n0:-0}
    cr10_del_lines "$h" "$tb" >"$allf" 2>/dev/null
    tail -n +$(( n0 + 1 )) "$allf" >"$nf" 2>/dev/null
    read -r start end dur_n mods_n lines_n <<<"$(cr10_measure "$nf")"
    log "  [$db] ${h##*.}：本次删除新增 [Deletion] 行=$lines_n 起点=$start 终点=$end 服务端耗时=${dur_n}ms 覆盖 mod 文件数=$mods_n"
    if [ "${dur_n:-"-"}" != "-" ]; then
      if [ "$dur" = "-" ]; then dur=$dur_n
      elif [ "$dur_n" -gt "$dur" ]; then dur=$dur_n
      fi
    fi
    [ "${mods_n:-0}" -gt "$mods" ] && mods=$mods_n
    lines=$(( lines + ${lines_n:-0} ))
  done
  if [ "${dur:-"-"}" = "-" ]; then
    local cli0 cli1 cli_ovh
    cli0=$(now_ms); sqt "show tables from $db;" >/dev/null 2>&1; cli1=$(now_ms)
    cli_ovh=$(( cli1 - cli0 ))
    dur=$(( t1 - t0 - cli_ovh )); [ "$dur" -lt 0 ] && dur=0
    warn "  [$db] 未能从日志解析服务端耗时（本表无 [Deletion] 行）⇒ 退化为 wall-clock − CLI 基线(${cli_ovh}ms) = ${dur}ms（含进程开销，只 WARN）"
  fi
  T_DUR=$dur; T_MODS=$mods; T_LINES=$lines
  # ---- 硬判 ----
  cr10_wait_rows_table "select v from $db.$tb where time <= $DEL_T;" "0" "$CR10_WIN" "  [$db] 被删范围为 0 行" || true
  got_del=$(cr10_rows_table "select v from $db.$tb where time <= $DEL_T;")
  got_surv=$(cr10_rows_table "select v from $db.$tb where time > $DEL_T and time < $WBASE;")
  assert_eq "  [$db] 硬判：删除可见（time <= $DEL_T 行数）" "${got_del:-?}" "0"
  assert_eq "  [$db] 硬判：未删数据行数不变" "${got_surv:-?}" "${pre_surv:-?}"
  cmp_assert_same "  [$db] 硬判：未删数据（$DEL_T < time < $WBASE）指纹" "$fp0" "$(cr10_fp "$db.$tb")"
  cr10_wait_rows_table "select v from $db.$tb where time >= $WBASE;" "$(( wok * CR10_WROW ))" "$CR10_WIN" "  [$db] 并发写入的行全可见" || true
  got_w=$(cr10_rows_table "select v from $db.$tb where time >= $WBASE;")
  assert_eq "  [$db] 硬判：并发写入一条不少（$wok 条语句 × $CR10_WROW 行）" "${got_w:-?}" "$(( wok * CR10_WROW ))"
  [ "${mods:-0}" -gt 0 ] && pass "  [$db] 场景有效性：删除确实写入 mod 文件（覆盖 $mods 个 TsFile；[Deletion] 新增 $lines 行）" \
    || warn "  [$db] 未从日志拿到 'is written into N mod files' 的 N（mods 判据降级为记录）"
  # ---- WARN 级量化 ----
  stall_base=$(cr10_max_stall "$(( t0 - CR10_BASE_WIN * 1000 ))" "$t0" "$ps")
  stall_del=$(cr10_max_stall "$t0" "$t1" "$ps")
  local prog_at_del prog_after_del
  prog_at_del=$(awk -v a="$t0" '$1+0 <= a+0 {c=$2+0} END{print c+0}' "$ps")
  prog_after_del=$(awk -v b="$t1" '$1+0 <= b+0 {c=$2+0} END{print c+0}' "$ps")
  log "  [$db] 并发写入进度：删除开始前累计=$prog_at_del 删除返回时累计=$prog_after_del 最终成功语句=$wok"
  if [ "${prog_after_del:-0}" -le "${prog_at_del:-0}" ]; then
    warn "  [$db] 删除窗口内未观测到并发写入语句增量（可能真的被 delete 的写锁挡住，也可能是 CLI 输出缓冲导致进度滞后）⇒ 只记录，不作硬判据"
  else
    pass "  [$db] 删除窗口内并发写入仍在推进（+$(( prog_after_del - prog_at_del )) 条语句）"
  fi
  log "  [$db] 并发写入最大无进展间隔：基线=${stall_base}ms 删除窗口=${stall_del}ms"
  if [ "${stall_del:-0}" -gt "${stall_base:-0}" ] && [ "${stall_del:-0}" -gt 1000 ]; then
    warn "  [$db] 删除窗口内写入停顿 ${stall_del}ms > 基线 ${stall_base}ms 且 >1s ⇒ 支持 R-38「delete 阻塞写入」（只 WARN）"
  else
    pass "  [$db] 信息：删除窗口内写入停顿未显著高于基线（基线 ${stall_base}ms / 删除 ${stall_del}ms）"
  fi
  if [ "${dur:-0}" != "-" ] && [ "${dur:-0}" -lt "$CR10_RES_MS" ]; then
    warn "  [$db] 服务端耗时 ${dur}ms < 分辨率下限 ${CR10_RES_MS}ms ⇒ 该 tier 耗时趋势不作判断（不据此判「未阻塞」）"
  fi
  echo "" >>"$OUT"; }

# ===========================================================================
log "--- 集群准备：三类合并先关（隔离变量），candidate=2 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}" cmp_cluster_prepare
cmp_compaction_off

i=0
for n in $TIERS; do
  i=$(( i + 1 ))
  case "$i" in
    1) db=$DB_T1; tb=$TB_T1 ;;
    2) db=$DB_T2; tb=$TB_T2 ;;
    *) db=$DB_T3; tb=$TB_T3 ;;
  esac
  cr10_tier "$db" "$tb" "$n" off
  N_ARR+=("$n"); DUR_ARR+=("$T_DUR"); MODS_ARR+=("$T_MODS"); LINE_ARR+=("$T_LINES"); WOK_ARR+=("$T_WOK")
  log "  >> tier$i：批数=$n TsFile(各副本)=$T_FILES 服务端删除耗时=${T_DUR}ms 覆盖 mod 文件数=$T_MODS [Deletion]行数=$T_LINES 并发成功语句=$T_WOK"
done
cr10_tier "$DB_CTL" "$TB_CTL" "$CR10_CTL" on
CDUR=$T_DUR; CMODS=$T_MODS; CLINES=$T_LINES

log "--- 量化汇总（耗时一律只 WARN）---"
log "  tier 表：$(for idx in 0 1 2; do printf '[%s批: %sms/%smods] ' "${N_ARR[$idx]}" "${DUR_ARR[$idx]}" "${MODS_ARR[$idx]}"; done)"
log "  机制对照：关相（tier2，${N_ARR[1]} 批）=${DUR_ARR[1]}ms/${MODS_ARR[1]}mods  开相（${CR10_CTL} 批，删除前已合并）=${CDUR}ms/${CMODS}mods"
D1=${DUR_ARR[0]}; D2=${DUR_ARR[1]}; D3=${DUR_ARR[2]}
if [ "$D1" != "-" ] && [ "$D2" != "-" ] && [ "$D3" != "-" ] && [ "$D1" -ge "$CR10_RES_MS" ]; then
  if [ "$D3" -ge "$D2" ] && [ "$D2" -ge "$D1" ]; then
    pass "  耗时趋势与 R-38 一致（单调不减：${D1}ms ≤ ${D2}ms ≤ ${D3}ms，对应 ${N_ARR[0]}/${N_ARR[1]}/${N_ARR[2]} 个 TsFile）"
  else
    warn "  耗时趋势不单调（${D1}/${D2}/${D3}ms）：本环境文件小、写 mod 耗时接近噪声 ⇒ **不判产品缺陷**（记录供跨版本对比）"
  fi
else
  warn "  tier 耗时低于分辨率下限（${D1}/${D2}/${D3}ms）⇒ 趋势判据跳过（分辨率不足，不判「未阻塞」）"
fi
if [ "${CDUR:-"-"}" != "-" ] && [ "${D2:-"-"}" != "-" ]; then
  [ "$CDUR" -le "$D2" ] && pass "  机制对照方向一致：开合并后删除耗时 ${CDUR}ms ≤ 关合并 ${D2}ms（覆盖 mod 文件数 ${CMODS} vs ${MODS_ARR[1]}）" \
    || warn "  机制对照方向相反（开 ${CDUR}ms > 关 ${D2}ms）：合并/CLI 噪声，只记录"
fi
log "  R-40 证据面：单次 DELETE 在各节点各产生一条 [Deletion] 记录（tier3 合计 ${LINE_ARR[2]} 行；每条带 'written into N mod files'）⇒「一条 delete 命令被记录多次」可直接观测"
log "  R-45 证据面：「只往 leader 发、IO 减半」属内部行为计数，本环境**不判**（REQ_MATRIX §4-B9）"

log "--- 收尾三件套（tier1 库的未删数据作一致性基准）---"
post_checks "select v from $DB_T1.$TB_T1 where time > $DEL_T order by time;" table
cmp_case_finish "" table ""
