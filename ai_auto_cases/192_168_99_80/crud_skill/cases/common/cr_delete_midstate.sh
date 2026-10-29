#!/bin/bash
# ============================================================================
# CR-07 删除写入流程的中间态：未落盘 memtable / 正在 flush 的文件也被删除覆盖
#       覆盖 R-26 / R-33（出处：docs/REQ_MATRIX.md §3 CR-07 + §1 逐字原文）
#
# 语义（逐字对照需求）：
#   R-26 删除写入流程：「…将 e 加入到 f 的内存删除缓冲 flushingMods 中；」「刷出中写出 Mod 文件时
#        会对 f 的 flushQueryLock 加写锁；」「如果 anyTsFileRemoved 为 true，将从上次执行第 4 步到
#        现在产生的已关闭 TsFile 记为 files，然后回到第4步。」
#   R-33「为了避免一个 Mod 文件在被分配给一个 TsFile 的同时被删除，判断 Mod 文件是否包含
#        TsFileResource 与向其中加入 TsFileResource 的过程需要加锁。…如果…已经发现该 Mod 文件
#        不存在任何对应的 TsFileResource，则取消这一次分配，尝试分配一个新的 Mod 文件」
#
# 源码证据链（RC7 `iotdb-core/datanode/.../dataregion/memtable/TsFileProcessor.java`）：
#   · `deleteDataInMemory(ModEntry)`（:1549）先删 workMemTable（`logger.info(... in workMemTable,
#     {} points deleted)`，:1556-1560），再把删除记到**正在 flush 的不可变 memtable**（
#     `DELETION_IN_FLUSHING_MEMTABLE` = `[Deletion] Deletion with {} in flushingMemTable`，:1565-1566）；
#   · flush 收尾（:1935-1942）把 `modsToMemtable` 里的删除写进该 TsFile 的 mod 文件并打
#     `[Deletion] Deletion : {} written when flush memtable`（:1942）——**这就是"正在 flush 的文件
#     也被删除覆盖"的直接证据**；`getModFileForWrite()` 即 R-19「首次删除才分配 Mod 文件」。
#   · `DataRegion.deleteByDevice`（:3241-3301）持 `writeLock("delete")` → `logDeletionInWAL` →
#     `deleteDataInUnsealedFiles`（:3854）→ 释放写锁 → `deleteDataInSealedFiles`（:3889）；
#     unsealed 文件的 `fileEndTime = Long.MAX_VALUE`（`canSkipDelete`:3817）⇒ 未落盘文件不会被时间范围跳过。
#
# 相位设计（两模型）：
#   相 A（树 root.cr07a）：**memtable 相** —— 写数据不 flush → 删除 → 立刻查询 → 再 FLUSH
#        硬判 1（场景有效性）：删除前「SELECT 能查到全部行」且「该库 TsFile 数 = 0」（数据只在 memtable）
#        硬判 2：删除后立刻查询，被删范围 0 行、存活集行数精确（memtable 里的行已被删）
#        硬判 3：FLUSH 后（落盘）行数不变（被删行不因落盘复活）+ 双信号（`Async close tsfile` 行数 +1 且文件数 0→≥1）
#        日志判据：`in workMemTable, N points deleted`（N>0）——存在即硬判；本构建若无该文案 ⇒ 降级 WARN
#   相 B（树 root.cr07b，必要时重试 root.cr07c）：**flushing 相** —— 写 12MB 大 payload 不 flush
#        → 后台 `flush` 与前台**同一会话内的 DELETE 突发**并发 → 抓 `in flushingMemTable` /
#        `written when flush memtable` 标记（命中即硬判；未命中判「场景未成立」并跳过该组判据）
#        硬判：删除响应无报错、FLUSH 完成后被删范围 0 行、存活集行数 == FROWS/2（逐值可校验）
#   相 C（树 root.cr07d）：**R-33 合并交织环** —— 热开合并 + 4 轮「写小批 → flush → 删该批前半」
#        硬判：每轮删除后该轮被删范围 0 行、该轮存活行数精确；累计总行数 == 各轮留存之和
#        证据：`[Deletion] … is written into N mod files` 行数增量；孤儿 `.mods2` 为 WARN（合并清理有窗口）
#   相 D（表 cr07t）：**memtable 相**（同相 A 的表模型口径）
#   相 E（表 cr07t 第二张表 tk）：**合并交织环**（同相 C 的表模型口径）
#   ⚠️ 已知偏差（如实记录）：表模型**不做** flushing 相（长 payload 写入代价高），
#      `TsFileProcessor.deleteDataInMemory` 是两模型共用路径 ⇒ 该分支由树模型覆盖。
#
# 时长：约 14~18 分钟（含一次 12MB 大 payload 写入 + 两模型收尾三件套）
# 规模与配置（顶部变量）：
CR07_ROWS=${CR07_ROWS:-400}         # 相 A 的行数（memtable 相）
CR07_FROWS=${CR07_FROWS:-12000}     # 相 B 的行数（每行 1KB TEXT ⇒ 约 12MB，把 flush 拉到秒级）
CR07_PER=${CR07_PER:-250}           # 每条 INSERT 的行数（大 payload 必须走单会话 stdin）
CR07_LROWS=${CR07_LROWS:-400}       # 交织环每轮行数
CR07_LROUNDS=${CR07_LROUNDS:-4}     # 交织环轮数
CR07_BURST=${CR07_BURST:-40}        # flushing 相每轮 DELETE 突发条数（同一会话内连发）
CR07_BURSTS=${CR07_BURSTS:-3}       # flushing 相突发轮数
CR07_TRY=${CR07_TRY:-2}             # flushing 相尝试次数（第二次换库重试）
CR07_WIN=${CR07_WIN:-150}           # 等落盘/收敛的窗口（秒）
#
# 预期报错：无（删除在并发/中间态下不得报错；出现 Error/Exception 即 FAIL）
# 已知噪声白名单：合并任务在"删除把源/目标文件吃掉"时被取消属本场景预期（R-25 的重取列表），
#   只屏蔽 killed/aborted 措辞，**不**屏蔽 `Compaction … failed`。
#
# ★ harness 修复记录（RC8 首轮实跑暴露，全部是**用例侧**问题）：
#   ① 结果 UNKNOWN：`cr07_merge_loop` 的 `base0` 是第 4 个位置参数，而两个调用点只传 3 个
#      ⇒ `set -u` 报 `line 355: base0: unbound variable`，脚本当场中断、连 CSV 都没写。
#      现给默认值 `base0=${4:-$BASE}`。
#   ② 场景有效性断言写反/写死："数据目录尚无 TsFile（期望 0）" 在新库上实测读到 1 / 4 / 7 个
#      TsFile（同一断言两次运行结果都不同）——库里"本来就有文件"与"本批数据是否已落盘"无关。
#      现改为**相对判据**：写入**没有让文件数增加** ⇒ 数据仍在 memtable；命中不了就 WARN 记录
#      （并把库里已有文件名打出来），不判 FAIL。
#   ③ 相 C/E 合并交织环的删除**只带 `time <= del_t`**：每轮 base 递增 ⇒ 上一轮的留存行也 ≤ 本轮
#      del_t，会被一起删掉，"累计留存 = 200×轮数"永不成立。现删除带下界
#      `time >= base and time <= del_t`（只删本轮前半），并补一条"本轮未删部分仍在"的硬判。
#
# 用法： bash cases/common/cr_delete_midstate.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 本任务只做 `bash -n` 与本地纯桩验证，**未在集群实跑**。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_delete_midstate_${DATA_CONSENSUS}"

DBA=root.cr07a          # 相 A：树 memtable
DBB=root.cr07b          # 相 B：树 flushing（第一次尝试）
DBC=root.cr07c          # 相 B：树 flushing（重试）
DBD=root.cr07d          # 相 C：树 合并交织环
DBT=cr07t               # 相 D/E：表模型
TT=tt                   # 相 D 的表名
TK=tk                   # 相 E 的表名
DEV=d1

PAYLOAD=$(printf 'q%.0s' $(seq 1 1000))
BASE=$(( $(now_ms) - 1200000 ))     # 20 分钟前 ⇒ 全部时间戳在过去、同一时间分区

# 合并任务被取消（删除吃掉了合并源/目标文件）是本场景的预期路径（R-25），只屏蔽该措辞
export CMP_LOG_BENIGN_EXTRA='Compaction task (is )?killed|compaction task is killed|abort compaction task|Abort compaction task'

# ---------------------------------------------------------------------------
# 观测量 helper（⚠️ lib 的 cmp_mods_* 按旧 `*.mods` 匹配，RC7 是 `*.mods2` ⇒ 恒 0，不能用）
#   远程 grep 的 pattern 一律**不含单引号**（避免 ssh 双引号内嵌单引号的转义地狱）：
#     树模型 → pathPattern=root.cr07x ；表模型 → predicate=DeletionPredicate
# ---------------------------------------------------------------------------
cr07_seq_cnt(){ local v; v=$(cmp_seq_cnt "$1" "$2"); echo "${v:-0}"; }
# `[Deletion] …` 计数（按节点 / 全节点求和）。$1 = 库/表过滤串（不含单引号），$2 = 可选附加标记串
#   ⚠️ 必须分两次 grep：日志里 `pathPattern=root.cr07a.d1.**` 与 `in workMemTable` 之间还隔着
#      `, timeRange=[…]}`，拼成一整串 `-F` 是匹配不到的。
cr07_del_cnt(){ local h=$1 pat=$2 mark=${3:-} v
  if [ -n "$mark" ]; then
    v=$(sshx "$h" "cat $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -hE '\\[Deletion\\]' | grep -F '$pat' | grep -cF '$mark'" 2>/dev/null | tr -dc '0-9')
  else
    v=$(sshx "$h" "cat $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -hE '\\[Deletion\\]' | grep -cF '$pat'" 2>/dev/null | tr -dc '0-9')
  fi
  echo "${v:-0}"; }
cr07_del_cnt_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cr07_del_cnt "$h" "$1" "${2:-}") )); done; echo "${s:-0}"; }
# 全库范围（不限本用例）某文案是否存在 —— 用于区分"场景没造出来"与"本构建没有该文案"
cr07_global_cnt(){ local h s=0 v
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "cat $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -cF '$1'" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${v:-0} ))
  done; echo "${s:-0}"; }
# `in workMemTable, N points deleted` 里 N 的最大值（$1 = 库过滤串）
cr07_points_max(){ local h v m=0
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "cat $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -hF 'points deleted' | grep -F '$1' | sed -E 's/.*in workMemTable, ([0-9]+) points deleted.*/\\1/' | sort -n | tail -1" 2>/dev/null | tr -dc '0-9')
    [ -n "${v:-}" ] && [ "$v" -gt "$m" ] && m=$v
  done; echo "${m:-0}"; }
cr07_mods2_sum(){ local h s=0 v
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$1/*' -name '*.mods2' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${v:-0} ))
  done; echo "${s:-0}"; }
cr07_orphan_mods2(){ local h s=0 n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$1/*' -name '*.mods2' 2>/dev/null | while read -r m; do [ -f \"\${m%.mods2}\" ] || echo x; done | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done; echo "${s:-0}"; }
# 原始行数（树：原始查询数行——设备路径上的聚合会退化成 Empty set；表：按行数，见下）
cr07_rows_tree(){ sq "$1" 2>&1 | strip_echo | data_rows | wc -l | tr -d ' '; }
# ⚠️ 表模型**不能**用 `table_rows | wc -l`：CLI 单条结果超过一批（实测 1000 行/批）会重复打印表头，
#   而 lib 的 table_rows 只丢第一行 ⇒ 12000 行会被数成 12009（与 CR-02/CR-10 的 5004/10009 同源）。
cr07_body_cnt(){ printf '%s\n' "$1" | grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' \
  | awk -F'|' 'NR==1{h=$2; next} {if ($2==h) next; c++} END{print c+0}'; }
cr07_rows_table(){ cr07_body_cnt "$(sqt "$1" 2>&1)"; }
# 落盘事件数（Async close tsfile，按库；双信号的文件侧 + 日志侧）
cr07_close_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(ttl_close_cnt "$h" "$1") )); done; echo "${s:-0}"; }
# 等各副本该库 TsFile 数 ≥ want（用文件数当"已落盘"的代理：TsFileResource 在 close 时才注册进 manager）
cr07_wait_files(){ local db=$1 want=$2 timeout=${3:-120} dl t
  dl=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < dl )); do
    t=$(cmp_all_sum "$db")
    [ "${t:-0}" -ge "$want" ] && return 0
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 3
  done
  return 1; }

# ---------------------------------------------------------------------------
# 写入 helper
# ---------------------------------------------------------------------------
# 树：写 ROWS 行（可选 1KB payload）—— 不 flush（调用方决定何时 flush）
#   ⚠️ 必须按 CR07_PER 行/语句分批累积：逐行拼一个 12MB 的大字符串在 bash 里是 O(n²) 拷贝（会跑成分钟级）
cr07_ins_tree(){ local db=$1 rows=$2 base=$3 pay=${4:-no} i=0 k vals="" stmts="" ts v
  for ((k=1; k<=rows; k++)); do
    ts=$(( base + k * 10 )); v=$(( k % 1000 ))
    if [ "$pay" = yes ]; then vals="$vals($ts,$v,'$PAYLOAD'),"; else vals="$vals($ts,$v),"; fi
    i=$(( i + 1 ))
    if [ $(( i % CR07_PER )) -eq 0 ]; then
      if [ "$pay" = yes ]; then stmts="${stmts}insert into $db.$DEV(time,s1,s2) values ${vals%,};
"
      else stmts="${stmts}insert into $db.$DEV(time,s1) values ${vals%,};
"; fi
      vals=""
    fi
  done
  if [ -n "$vals" ]; then
    if [ "$pay" = yes ]; then stmts="${stmts}insert into $db.$DEV(time,s1,s2) values ${vals%,};
"
    else stmts="${stmts}insert into $db.$DEV(time,s1) values ${vals%,};
"; fi
  fi
  printf '%s' "$stmts" | session_tree >/dev/null; }
# 树：建库（s1 INT64；相 B 另加 s2 TEXT 1KB）
cr07_mkdb_tree(){ local db=$1 with_text=${2:-no}
  sq "create database $db;" >/dev/null
  sq "create timeseries $db.$DEV.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null
  [ "$with_text" = yes ] && sq "create timeseries $db.$DEV.s2 with datatype=TEXT, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null; }
# 表：建库 + 建表（列约束必须写 TIME/TAG/FIELD，否则静默失败）
cr07_mkdb_table(){ local db=$1 tb=$2 out
  sqt "create database $db;" >/dev/null
  out=$(sqt "create table $db.$tb (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD);")
  printf '%s' "$out" | grep -q 'successfully' && pass "  建表成功：$db.$tb" || fail "  场景无效：建表 $db.$tb 失败（$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)）"
  local t; t=$(sqt "show tables from $db;")
  printf '%s' "$t" | grep -q "$tb" && pass "  show tables 确认 $db.$tb 存在" || fail "  场景无效：show tables 里没有 $db.$tb"
  sqt "flush;" >/dev/null; }
# 表：写 ROWS 行（不 flush）
cr07_ins_table(){ local db=$1 tb=$2 rows=$3 base=$4 i=0 k vals="" stmts="" ts
  for ((k=1; k<=rows; k++)); do
    ts=$(( base + k * 10 ))
    vals="$vals($ts,'$DEV',$(( k % 1000 ))),"
    i=$(( i + 1 ))
    if [ $(( i % CR07_PER )) -eq 0 ]; then stmts="${stmts}insert into $db.$tb (time, dev, v) values ${vals%,};
"; vals=""; fi
  done
  [ -n "$vals" ] && stmts="${stmts}insert into $db.$tb (time, dev, v) values ${vals%,};
"
  printf '%s' "$stmts" | session_table >/dev/null; }

# ===========================================================================
log "--- 集群准备：三类合并先关（相 A/B/D 的中间态隔离变量；相 C/E 再热开），candidate=2 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}" cmp_cluster_prepare
cmp_compaction_off

# ---------------------------------------------------------------------------
# 相 A：memtable 中间态（树）
# ---------------------------------------------------------------------------
cr07_memtable_phase(){ local db=$1 dialect=$2 pat=$3
  local base del_t total del0 surv0 file_pre file0 grow close0 del_now surv_now file1 close1 pts m out
  base=$(( BASE + 1 ))
  del_t=$(( base + (CR07_ROWS / 2) * 10 ))
  log "--- [$db] memtable 相：写 $CR07_ROWS 行**不 flush** → 删除 time <= $del_t → 再 FLUSH ---"
  if [ "$dialect" = table ]; then cr07_mkdb_table "$db" "$TT"; else cr07_mkdb_tree "$db" no; fi
  # ⚠️ 判据用"**本批写入没有新增 TsFile**"，而不是"TsFile 数 == 0"：
  #    RC8 首轮实测同一条断言在新库上分别读到 1 / 4 / 7 个 TsFile（同一个库在两次运行里还不一样），
  #    说明"库里文件数恒为 0"这个前提**并不成立**（region 初始化/别处已有落盘文件），
  #    但它与"本批数据是否已落盘"无关。场景真正要成立的条件是：写入**没有让文件数增加** ⇒ 数据在 memtable。
  file_pre=$(cmp_all_sum "$db")
  [ "${file_pre:-0}" -gt 0 ] && log "  写入前该库已有 $file_pre 个 TsFile（$(cmp_tsfile_list "${DN[0]}" "$db" | tr '\n' ' ')）⇒ 本相只判『本批未新增』"
  if [ "$dialect" = table ]; then cr07_ins_table "$db" "$TT" "$CR07_ROWS" "$base"
  else cr07_ins_tree "$db" "$CR07_ROWS" "$base" no; fi
  sleep 3
  if [ "$dialect" = table ]; then total=$(cr07_rows_table "select v from $db.$TT;"); else total=$(cr07_rows_tree "select s1 from $db.$DEV order by time;"); fi
  file0=$(cmp_all_sum "$db")
  grow=$(( ${file0:-0} - ${file_pre:-0} ))
  log "  [$db] 写入后（未 flush）：可查行数=$total 期望=$CR07_ROWS；该库 TsFile 数=$file_pre → $file0（本批新增 $grow，期望 0）"
  assert_eq "  [$db] 场景有效性：数据确实只在 memtable（可查到全部行）" "${total:-?}" "$CR07_ROWS"
  if [ "${grow:-1}" = "0" ]; then
    pass "  [$db] 场景有效性：本批写入未落盘（TsFile 数相对写入前不变，仍为 $file0）"
  else
    warn "  [$db] 场景有效性：本批写入已落盘（TsFile 数 $file_pre → $file0）⇒ 「memtable 中间态」这个前提没造出来；本相改为**只验证删除语义**（数据面判据仍然硬判），并把文件清单记进证据：$(cmp_tsfile_list "${DN[0]}" "$db" | tr '\n' ' ')"
  fi
  del0=$(cr07_del_cnt_all "$pat" "in workMemTable")
  if [ "$dialect" = table ]; then
    out=$(sqt "delete from $db.$TT where time <= $del_t;")
  else
    out=$(sq "delete from $db.$DEV.** where time <= $del_t;")
  fi
  printf '%s\n' "$out" | sed 's/^/    delete→ /' >>"$OUT"
  assert_not_contains "  [$db] 删除未报错" "$(printf '%s' "$out" | strip_echo)" 'Exception|Error|error|Failed|failed'
  sleep 3
  if [ "$dialect" = table ]; then
    del_now=$(cr07_rows_table "select v from $db.$TT where time <= $del_t;")
    surv_now=$(cr07_rows_table "select v from $db.$TT where time > $del_t;")
  else
    del_now=$(cr07_rows_tree "select s1 from $db.$DEV where time <= $del_t order by time;")
    surv_now=$(cr07_rows_tree "select s1 from $db.$DEV where time > $del_t order by time;")
  fi
  log "  [$db] 删除后立刻查询（未 flush）：被删集=$del_now 存活集=$surv_now（期望 0 / $(( CR07_ROWS - CR07_ROWS / 2 ))）"
  assert_eq "  [$db] 被删行在 memtable 中已消失（time <= $del_t）" "${del_now:-?}" "0"
  assert_eq "  [$db] 未删行仍在 memtable 中可见（time > $del_t）" "${surv_now:-?}" "$(( CR07_ROWS - CR07_ROWS / 2 ))"
  # 日志判据（文案存在即硬判；不存在则降级 WARN —— 见 REQ_MATRIX CR-07 场景有效性 ③）
  pts=$(cr07_points_max "$pat")
  m=$(cr07_del_cnt_all "$pat" "in workMemTable")
  if [ "${m:-0}" -gt 0 ]; then
    [ "${pts:-0}" -gt 0 ] && pass "  [$db] 日志证据：memtable 删除 $m 条，最大删除点数=$pts（>0）" \
      || fail "  [$db] 日志证据：有 $m 条 memtable 删除记录但删除点数=0（未真正删到 memtable 数据）"
  else
    g=$(cr07_global_cnt "in workMemTable")
    [ "${g:-0}" -gt 0 ] && fail "  [$db] 日志证据：全库有 $g 条 memtable 删除记录，但本库 0 条（本相未走 memtable 分支）" \
      || warn "  [$db] 本构建日志中无 'in workMemTable' 文案 ⇒ 该日志判据降级（以数据面为准，见 REQ_MATRIX CR-07 ③）"
  fi
  log "  [$db] memtable 删除记录：本库=$m 条（基线 $del0）"
  # FLUSH → 落盘后语义不变（双信号）
  close0=$(cr07_close_sum "$db")
  sq "flush;" >/dev/null 2>&1
  [ "$dialect" = table ] && sqt "flush;" >/dev/null 2>&1
  cr07_wait_files "$db" 1 "$CR07_WIN" || warn "  [$db] FLUSH 后该库 TsFile 数未达 1（$(cmp_per_node cmp_seq_cnt "$db")）"
  sleep 5
  file1=$(cmp_all_sum "$db"); close1=$(cr07_close_sum "$db")
  if [ "$dialect" = table ]; then
    del_now=$(cr07_rows_table "select v from $db.$TT where time <= $del_t;")
    surv_now=$(cr07_rows_table "select v from $db.$TT where time > $del_t;")
  else
    del_now=$(cr07_rows_tree "select s1 from $db.$DEV where time <= $del_t order by time;")
    surv_now=$(cr07_rows_tree "select s1 from $db.$DEV where time > $del_t order by time;")
  fi
  log "  [$db] FLUSH 后：TsFile $file0 → $file1；Async close $close0 → $close1；被删集=$del_now 存活集=$surv_now"
  [ "${file1:-0}" -ge 1 ] && pass "  [$db] 双信号①：落盘后该库 TsFile 数 $file0 → $file1" || fail "  [$db] 双信号①：FLUSH 后仍无 TsFile（$file1）"
  [ "${close1:-0}" -gt "${close0:-0}" ] && pass "  [$db] 双信号②：Async close 事件 +$(( close1 - close0 ))（文件确实落盘）" \
    || warn "  [$db] 双信号②：未见新的 Async close 事件（$close0 → $close1，记录）"
  assert_eq "  [$db] 落盘后被删行不得复活" "${del_now:-?}" "0"
  assert_eq "  [$db] 落盘后未删行不得丢失" "${surv_now:-?}" "$(( CR07_ROWS - CR07_ROWS / 2 ))"
  log "  [$db] .mods2 合计=$(cr07_mods2_sum "$db")（源文件/合并产物被清理后为 0 属正常，不作硬判据）"; }

cr07_memtable_phase "$DBA" tree "pathPattern=root.cr07a"
cmp_compaction_off

# ---------------------------------------------------------------------------
# 相 B：flushing 中间态（树，12MB 大 payload ⇒ flush 窗口秒级）
#   并发：后台 `flush;` 与**同一会话内的 DELETE 突发**同时进行；突发内多轮（cover 整个 flush 窗口）
# ---------------------------------------------------------------------------
cr07_delete_burst(){ local db=$1 del_t=$2 n=$3 i stmts=""
  for ((i=1; i<=n; i++)); do stmts="${stmts}delete from $db.$DEV.** where time <= $del_t;
"; done
  printf '%s' "$stmts" | session_tree 2>&1; }
cr07_flush_phase(){ local db=$1
  local base del_t rows file_pre file0 grow fpm wpm hit pid b out del_now surv_now tot_now m2 g gw
  base=$(( BASE + 10000000 ))
  del_t=$(( base + (CR07_FROWS / 2) * 10 ))
  log "--- [$db] flushing 相：写 $CR07_FROWS 行 × 1KB（约 $(( CR07_FROWS / 1024 ))MB，不 flush）---"
  cr07_mkdb_tree "$db" yes
  file_pre=$(cmp_all_sum "$db")
  [ "${file_pre:-0}" -gt 0 ] && log "  写入前该库已有 $file_pre 个 TsFile ⇒ 本相只判『本批未新增』"
  cr07_ins_tree "$db" "$CR07_FROWS" "$base" yes
  sleep 5
  rows=$(cr07_rows_tree "select s1 from $db.$DEV order by time;")
  file0=$(cmp_all_sum "$db")
  grow=$(( ${file0:-0} - ${file_pre:-0} ))
  log "  [$db] 写入后：可查行数=$rows 期望=$CR07_FROWS；TsFile 数=$file_pre → $file0（本批新增 $grow，期望 0）"
  assert_eq "  [$db] 场景有效性：大 payload 全部可查（数据在 memtable）" "${rows:-?}" "$CR07_FROWS"
  # 同相 A：判"本批未新增 TsFile"。若写入已自动落盘（本构建按内存压力触发 flush），
  #   "删除撞上**正在 flush**的文件"这一前提就造不出来 ⇒ 如实 WARN + 换库重试，不判 FAIL。
  if [ "${grow:-1}" = "0" ]; then
    pass "  [$db] 场景有效性：本批写入未落盘（TsFile 数相对写入前不变，仍为 $file0）"
  else
    warn "  [$db] flushing 相场景未成立（行数=$rows/$CR07_FROWS，TsFile 新增 $grow）⇒ 写入过程中已被自动 flush（本构建按内存压力触发），本相只记录"
    return 1
  fi
  fpm=$(cr07_del_cnt_all "$db" "in flushingMemTable")
  wpm=$(cr07_del_cnt_all "$db" "written when flush memtable")
  log "  [$db] 基线：in flushingMemTable=$fpm written when flush memtable=$wpm"
  # 后台 flush + 前台删除突发（每轮一个会话、轮间 sleep ⇒ 覆盖整个 flush 窗口）
  printf 'flush;\n' | session_tree >/dev/null 2>&1 &
  pid=$!
  out=""
  for ((b=1; b<=CR07_BURSTS; b++)); do
    out="${out}$(cr07_delete_burst "$db" "$del_t" "$CR07_BURST")"
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  printf '%s' "$out" | strip_echo | grep -nE 'Exception|Error|Failed|failed' | head -5 >>"$OUT" 2>&1
  assert_not_contains "  [$db] flushing 相：并发删除全程无报错（$(( CR07_BURSTS * CR07_BURST )) 条 DELETE）" \
    "$(printf '%s' "$out" | strip_echo)" 'Exception|Failed|failed'
  cr07_wait_files "$db" 1 "$CR07_WIN" || warn "  [$db] 大 payload FLUSH 后 TsFile 数未达 1"
  sleep 5
  fpm=$(cr07_del_cnt_all "$db" "in flushingMemTable"); wpm=$(cr07_del_cnt_all "$db" "written when flush memtable")
  hit=$(( fpm + wpm ))
  log "  [$db] flushing 相标记：in flushingMemTable=$fpm written when flush memtable=$wpm（命中合计 $hit）"
  if [ "$hit" -gt 0 ]; then
    pass "  [$db] 场景有效性：删除确实覆盖了**正在 flush** 的文件（$hit 条标记，R-26 flushingMods 路径）"
  else
    g=$(cr07_global_cnt "in flushingMemTable")
    gw=$(cr07_global_cnt "written when flush memtable")
    if [ $(( g + gw )) -gt 0 ]; then
      fail "  [$db] 场景未成立：全库有 flushing 标记（$g/$gw）但本库 0 条 ⇒ 突发未落在 flush 窗口内，本组判据跳过（不计连带 FAIL）"
    else
      warn "  [$db] 本构建日志中无 flushing 标记文案（$g/$gw）⇒ 判据降级为「数据面 + 落盘无异常」"
    fi
  fi
  # 数据面（不论场景是否成立都必须成立）
  del_now=$(cr07_rows_tree "select s1 from $db.$DEV where time <= $del_t order by time;")
  surv_now=$(cr07_rows_tree "select s1 from $db.$DEV where time > $del_t order by time;")
  tot_now=$(row_sum "$(sq "select count(s1) from $db.**;")")
  log "  [$db] FLUSH 后：被删集=$del_now 存活集=$surv_now 总行数=$tot_now（期望 0 / $(( CR07_FROWS - CR07_FROWS / 2 ))）"
  assert_eq "  [$db] 被删行不得因 flush 复活" "${del_now:-?}" "0"
  assert_eq "  [$db] 未删行不得因 flush 丢失" "${surv_now:-?}" "$(( CR07_FROWS - CR07_FROWS / 2 ))"
  assert_eq "  [$db] 总行数 = 写入 − 被删" "${tot_now:-?}" "$(( CR07_FROWS - CR07_FROWS / 2 ))"
  m2=$(cr07_mods2_sum "$db")
  [ "${m2:-0}" -gt 0 ] && pass "  [$db] 删除已落到 .mods2（$m2 个：正在 flush 的文件也被删除覆盖）" \
    || warn "  [$db] FLUSH 后未见 .mods2（$m2）：可能被 flush 后清理或走了整文件删除路径（记录）"
  [ "$hit" -gt 0 ] && return 0 || return 1; }

cr07_flush_phase "$DBB" || {
  warn "  相 B 第一次（$DBB）未命中 flushing 窗口 ⇒ 换库 $DBC 重试一次"
  cmp_compaction_off
  cr07_flush_phase "$DBC" || warn "  相 B 第二次（$DBC）仍未命中 flushing 窗口 —— 如实记「未构造成功」（WARN，不判 FAIL）"
}

# ---------------------------------------------------------------------------
# 相 C / 相 E：R-33 合并交织环（树 A 库 + 表模型库）
#   热开合并并反复「写小批 → flush → 删本批前半」⇒ 删除与合并目标/Mod 文件分配交织
# ---------------------------------------------------------------------------
cr07_merge_loop(){ local db=$1 dialect=$2 pat=$3 base0 round base del_t exp_total got_del got_surv tot mod0 mod1 orph out
  # ⚠️ RC8 首轮：`base0` 是第 4 个位置参数，但两个调用点都只传了 3 个
  #    ⇒ `set -u` 报 `line 355: base0: unbound variable`，脚本当场中断、连 CSV 都没写（结果 UNKNOWN）。
  #    这里给默认值（整库轮次都从 $BASE 起算即可）。
  base0=${4:-$BASE}
  cmp_compaction_off
  mod0=$(cr07_del_cnt_all "$pat" "is written into")
  exp_total=0
  for ((round=1; round<=CR07_LROUNDS; round++)); do
    base=$(( base0 + round * 100000 ))
    del_t=$(( base + (CR07_LROWS / 2) * 10 ))
    if [ "$dialect" = table ]; then cr07_ins_table "$db" "$TK" "$CR07_LROWS" "$base"; else cr07_ins_tree "$db" "$CR07_LROWS" "$base" no; fi
    sq "flush;" >/dev/null 2>&1; [ "$dialect" = table ] && sqt "flush;" >/dev/null 2>&1
    cr07_wait_files "$db" "$round" "$CR07_WIN" >/dev/null || true
    cmp_compaction_on true true false          # 热开合并（与删除交织）
    # ⚠️ 删除必须带**下界**：只按 `time <= del_t` 会把前几轮留存的行一起删掉
    #    （每轮 base 递增 ⇒ 上一轮的留存行 < 本轮 del_t），那样"累计留存 = 200×轮数"永不成立。
    if [ "$dialect" = table ]; then
      out=$(sqt "delete from $db.$TK where time >= $base and time <= $del_t;")
      sleep 3
      got_del=$(cr07_rows_table "select v from $db.$TK where time >= $base and time <= $del_t;")
      got_surv=$(cr07_rows_table "select v from $db.$TK where time > $del_t and time < $(( base + 100000 ));")
    else
      out=$(sq "delete from $db.$DEV.** where time >= $base and time <= $del_t;")
      sleep 3
      got_del=$(cr07_rows_tree "select s1 from $db.$DEV where time >= $base and time <= $del_t order by time;")
      got_surv=$(cr07_rows_tree "select s1 from $db.$DEV where time > $del_t and time < $(( base + 100000 )) order by time;")
    fi
    assert_not_contains "  [$db] 第 $round 轮删除未报错" "$(printf '%s' "$out" | strip_echo)" 'Exception|Failed|failed'
    assert_eq "  [$db] 第 $round 轮：本批被删范围 0 行" "${got_del:-?}" "0"
    assert_eq "  [$db] 第 $round 轮：本批未删部分仍在（$(( CR07_LROWS / 2 )) 行）" "${got_surv:-?}" "$(( CR07_LROWS - CR07_LROWS / 2 ))"
    exp_total=$(( exp_total + CR07_LROWS - CR07_LROWS / 2 ))
    if [ "$dialect" = table ]; then tot=$(cr07_rows_table "select v from $db.$TK;"); else tot=$(row_sum "$(sq "select count(s1) from $db.**;")"); fi
    assert_eq "  [$db] 第 $round 轮：累计留存行数（含本轮未删部分；本库仅本表）" "${tot:-?}" "$exp_total"
    log "  [$db] 第 $round 轮：布局=$(cmp_lay "$db") 累计留存=$tot 期望=$exp_total"
  done
  mod1=$(cr07_del_cnt_all "$pat" "is written into")
  [ "${mod1:-0}" -gt "${mod0:-0}" ] && pass "  [$db] 合并交织期删除写入 Mod 文件（'is written into N mod files' +$(( mod1 - mod0 )) 条）" \
    || warn "  [$db] 未见 'is written into N mod files' 增量（$mod0 → $mod1，记录；可能全走 memtable/整文件路径）"
  orph=$(cr07_orphan_mods2 "$db")
  [ "${orph:-0}" -eq 0 ] && pass "  [$db] 无孤儿 .mods2（R-33 的 Mod 文件分配竞争未留残骸）" \
    || warn "  [$db] 有 $orph 个孤儿 .mods2（合并清理有窗口，记录待人工确认，不判 FAIL）"
  STUCK=$(cmp_stuck_sum)
  cmp_assert_no_stuck "[$db] 无合并线程卡死"; }

cr07_mkdb_tree "$DBD" no
cr07_merge_loop "$DBD" tree "pathPattern=root.cr07d"

cr07_memtable_phase "$DBT" table "predicate=DeletionPredicate"    # 内部会建库建表 $TT
cmp_compaction_off
cr07_mkdb_table "$DBT" "$TK"
cr07_merge_loop "$DBT" table "predicate=DeletionPredicate"

log "--- 收尾三件套（树模型相 D 的数据作一致性基准）---"
post_checks "select s1 from $DBD.$DEV order by time;" tree
cmp_case_finish "" tree ""
