#!/bin/bash
# ============================================================================
# W-05 **flush 边界对照**：写完立刻掉电（只能靠 WAL 重放） vs 写完 + flush + TsFile 落盘后掉电
#
# 一句话：同一个数据规模写两遍，**A 相**不 flush 就 kill -9 全部 DataNode（数据只可能在 WAL 里），
#   **B 相**先 flush + `ensure_closed` 等 TsFile 真的落盘，再 kill -9 全部 DataNode
#   （此时数据在 TsFile、对应 WAL 已失效）⇒ **两相数据都必须完整**；
#   同时把两相"kill 前的 WAL 规模"做对照（B 相应更小或已被清理）。
#
# ---------------------------------------------------------------------------
# 【需求依据】
#   · design_extract.md §4.1（wal_mode 语义：SYNC=写入等待 WAL 刷盘后才返回；ASYNC=不等待）、
#     §4.3（重启恢复流程：读 checkpoint → 重放 WAL → 删除 WALNode 下的文件）、
#     §5.1（无效的定义：数据成功落盘后，其对应的 WAL 记录就是无效的）、
#     §5.4（WAL 文件没法被删除的三种原因：MemTable 未刷盘 / 被 pipe pin / 已刷盘但未被 IoTConsensus 消费完）、
#     §8 TP-10（SYNC 时写入成功返回即已刷盘 → 立刻 kill -9 数据不丢）、TP-19（刷盘后 WAL 可被删）、TP-29（未刷盘数据重启后重放可查）。
#   · source_grounding.md：WAL 目录/文件名 = `<dn_wal_dirs>/<identifier>/_<versionId>-<startSearchIndex>-<statusCode>.wal`，
#     IoTConsensus 下 identifier = `<database>-<regionId>` ⇒ 用它做**库级** WAL 隔离（否则系统库的 WAL 会混进 A/B 对照）；
#     权威指标 file_count{name="wal"} / file_size{name="wal"}。
#
# 【为什么 A 相用 SYNC 而不是默认的 ASYNC（关系到会不会误判）】
#   本用例 A 相的动作是"写完**立刻** kill -9"。ASYNC 的口径是"写入不等待 WAL 刷盘，成功后立即返回"，
#   TP-11 明确"ASYNC 下不能断言丢或不丢"——立刻掉电丢掉缓冲里的部分是**文档允许**的，
#   拿它判 FAIL 就是误判。所以 A 相显式把 `wal_mode=SYNC`（写入返回＝WAL 已刷盘），
#   "立刻掉电不丢"才是这条用例真正要守的契约（TP-10）。B 相同一份配置，两相可比。
#   （ASYNC 下"等一个 fsync 周期再掉电"的核心掉电用例见 W-04。）
#
# 【为什么 A/B 两相共用一次集群准备（而不是各起一次集群）】
#   `cmp_cluster_prepare` 会清空 data（连 WAL 目录），一次准备 ≈4 分钟。本用例用"**相内增量**"做对照：
#   每相在写入前量一次基线（A 相基线时该库还不存在 ⇒ 库级基线=0），写完再量一次，
#   增量 delta = kill前 - 写前。两相数据规模完全相同 ⇒ 两个增量可比；
#   且 A 相重启后其 WAL 已被恢复流程清掉，不会污染 B 相的基线（这一点也在产物里打印出来）。
#
# 【判据结构（硬/软分明）】
#   ① 场景有效性（硬）：
#      · A 相：kill 前该库 WAL **非空**（本库 identifier 口径，回退整目录口径）；数据可见且 count/sum 与离线核算一致。
#      · B 相：flush + `ensure_closed` 后该库 **TsFile 数 > 0**（数据真的在 TsFile 里，B 相语义才成立）。
#      · 两相：三个 DN 全部真的被 kill -9（进程消失）、重启后都 Running、写入后总数/总和与离线核算一致。
#   ② 数据面（硬）：两相各自"kill 前指纹 vs 重启后指纹"逐项相等（总 count/sum/min/max + 每设备 4 聚合 + 单设备全序列 md5/行数）；缺失/多余都 fail。
#   ③ 对照与消费证据（软，不作通过条件）：两相 kill 前的 WAL 文件数/字节增量对照、重启后 WAL 是否被消费、
#      A 相 kill 前 TsFile 数是否 0、指标口径（file_count/file_size{name="wal"}）。
#      ⚠️ **B 相 WAL 体积不一定立刻下降**：design_extract §5.4 明确"已刷盘但未被 IoTConsensus 消费完"的 WAL 文件
#      **不能被删除**；所以"B 相更小"只是期望值，观测不到时只 WARN + 记录，**不判 FAIL**（B 相真正的硬证据是 TsFile>0 + 重启后数据完整）。
#
# 【刻意不做的事】
#   · A 相**绝不 flush / 绝不 ensure_closed**（否则"必须靠 WAL 重放"就不成立）；B 相则必须 flush + ensure_closed。
#   · 不断言 `WALNode.java:466-470` 那条"删除过期 WAL 条数"文案（DEBUG 级、默认不落盘）。
#   · 不改 lib/、tools/、conf/、cases.tsv、docs/（只新增本文件）。
#
# 【时长大致】≈20~24 分钟（集群准备 ~4min + A 相 ~8min + B 相 ~8min + 收尾三件套 ~4min）。
#   可调：W05_DEVS/W05_ROWS/W05_BATCHES/W05_STABLE_WIN_SEC/W05_REPLAY_WIN_SEC。
#
# 【⚠️ 首轮 watch list（先看这些才知道"场景真的成立了"）】
#   1) **A 相 kill 前该库 TsFile 是否为 0、WAL 是否非空**：这是"A 相只能靠 WAL 重放"的立论基础。
#      若 TsFile>0（用例会 WARN 记录），先看是不是插件/自动刷盘把数据落了盘；若 WAL=0 → 直接 fail（场景无效）。
#   2) **B 相 flush 后 WAL 体积有没有降**：按 design_extract §5.4，"已刷盘但未被 IoTConsensus 消费完"的 WAL
#      不可删 ⇒ 增量可能和 A 相相当甚至更大。首轮记录两相增量与 `delete_wal_files_period_in_ms`（默认 20s）
#      窗口内的变化；只有"体积下降"才算拿到正面证据，没降到**不要**改判 FAIL。
#   3) **`ensure_closed` 是否真的等到 Async close**：flush 不保证三副本及时封口 TsFile（本项目踩过：
#      同一库某副本晚了 5 分钟）。B 相的 TsFile>0 断言按"任一副本可见"判定（cmp_all_sum 跨 DN 求和），
#      首轮看逐副本分布决定是否需要收紧。
#   4) **A 相 SYNC 是否真的生效**（`show configuration` 可能不暴露 wal_mode）⇒ 用例会回退读 properties；
#      首轮核对产物里的"生效 wal_mode"一行，别让 A 相实际跑成 ASYNC（那样"立刻掉电不丢"的判据就站不住）。
#   5) **两相各自 kill 掉全部 DN 后能否重新拉起来**（同 W-04 的同一风险：CN 在跑、DN 重新加入要过注册/选主）。
#      用例失败时会打印逐副本证据（WAL 清单 + 日志尾部 20 行 + show cluster）。
#
# 用法： bash cases/common/wal_recovery_flush_boundary.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 本文件**未在真实集群实跑过**（99.80 正在跑长回归，禁止任何集群动作）；只保证逻辑自洽 + 静态检查通过。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_recovery_flush_boundary_${DATA_CONSENSUS}"

# 环境兜底：conf/env.conf 未定义这三个 TTL 键，而 lib/common.sh 的 cluster_set_conf 会引用它们（set -u 下会中断准备）
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"

DB=root.walflush                    # A 相：写完不 flush 直接掉电
DB2=root.walflushb                  # B 相：写完 + flush + ensure_closed 后掉电（库名仍在 root.wal* 约定内）
DEVS=${W05_DEVS:-$WAL_DEVS}
ROWS=${W05_ROWS:-$WAL_ROWS}
BATCHES=${W05_BATCHES:-$WAL_BATCHES}
PER=${W05_PER:-500}
STABLE_WIN=${W05_STABLE_WIN_SEC:-90}          # 等 WAL 文件数/字节稳定的窗口（异步 fsync / 失效清理）
REPLAY_WIN=${W05_REPLAY_WIN_SEC:-${WAL_REPLAY_WIN_SEC:-300}}
EVID_WIN=${W05_EVID_WIN_SEC:-60}
START_WIN=${W05_START_WIN_SEC:-300}
CLOSE_WIN=${W05_CLOSE_WIN_SEC:-${WAL_CLOSE_WIN_SEC:-60}}
BASE_TS=$(( ($(date +%s) - 3600) * 1000 ))

# A/B 相共用一份 WAL 配置：**A 相必须是 SYNC**（写入返回＝WAL 已刷盘），否则"写完立刻掉电不丢"无契约依据
W05_EXTRA="wal_mode=SYNC,enable_wal_compression=${WAL_COMPRESSION},wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_FILE_THRESHOLD_BYTES},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"
W05_SCOPE=db                        # WAL 对照口径：db=按 identifier 目录隔离本库；all=整个 WAL 目录（回退）

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 写入（可选择是否 flush）---------------------------------------------
# 与 W-04 相同的确定性值：设备 d 第 b 批第 k 行 ⇒ 值 = k + b，ts = BASE_TS + b*1000000 + k*10
w05_write_nf(){ local db=$1 d b k vals ts
  local -a S=()
  for (( b=1; b<=BATCHES; b++ )); do
    for (( d=1; d<=DEVS; d++ )); do
      S=(); vals=""
      for (( k=0; k<ROWS; k++ )); do
        ts=$(( BASE_TS + b * 1000000 + k * 10 ))
        vals="$vals($ts,$(( k + b ))),"
        if [ $(( (k + 1) % PER )) -eq 0 ]; then
          S+=("insert into $db.d$d(time,s1) values ${vals%,};"); vals=""
        fi
      done
      [ -n "$vals" ] && S+=("insert into $db.d$d(time,s1) values ${vals%,};")
      [ "${#S[@]}" -gt 0 ] || continue
      printf '%s\n' "${S[@]}" | session_tree >/dev/null || return 1
    done
  done
  return 0
}
w05_exp_count(){ echo $(( DEVS * ROWS * BATCHES )); }
w05_exp_sum(){ local b s=0
  for (( b=1; b<=BATCHES; b++ )); do s=$(( s + ROWS * (ROWS - 1) / 2 + ROWS * b )); done
  echo $(( DEVS * s )); }

# ---- ② 指纹（同 W-04 的口径，逐项可比、缺失/多余都能发现）------------------
# 单设备四项一律走 lib/wal_ext.sh 的 `wal_dev_fp4`（RC8 第二轮修，见 wal_ext.sh ⑬）：
#   · **一条查询只放一个聚合**（混查 `count/sum/min/max` 报 701 hybrid query）；
#   · 只查**设备路径** `db.dN`（写序列路径 `db.dN.s1` 在本版本会落到空结果）；
#   · `min`/`max` 不是本版本内建名（要写 `min_value`/`max_value`），取不到值写 `ERR`，
#     不再静默输出 `count= sum= min= max=`。
w05_dev_agg(){ wal_dev_fp4 "$1"; }
w05_q_sum(){ local sql=$1 out
  out=$(sq "$sql")
  if printf '%s\n' "$out" | grep -qE 'Exception'; then printf 'ERR'; return 1; fi
  printf '%s' "$(row_sum "$out")"; }
w05_fp_dump(){ local db=$1 f=$2 i
  : >"$f"
  printf 'total_count=%s\n'   "$(w05_q_sum "select count(s1) from $db.**;")" >>"$f"
  printf 'total_sum=%s\n'     "$(w05_q_sum "select sum(s1) from $db.**;")"   >>"$f"
  # min/max 汇总**逐设备**取值再在本地相加（`select min(s1) from <db>.**` 在本版本 701）
  printf 'total_min_sum=%s\n' "$(wal_dev_sum_of min "$db" "$DEVS")"          >>"$f"
  printf 'total_max_sum=%s\n' "$(wal_dev_sum_of max "$db" "$DEVS")"          >>"$f"
  for (( i=1; i<=DEVS; i++ )); do printf 'dev_d%s=%s\n' "$i" "$(w05_dev_agg "$db.d$i")" >>"$f"; done
  # d1 全序列：md5 前先 `data_rows`（丢表头与 `It costs …` 统计行），判据仍是"两相必须相等"
  wal_seq_fp "$db" >>"$f"
  log "  指纹已落盘：$f（$(grep -c . "$f") 项）"
  sed 's/^/      /' "$f" >>"$OUT"
  grep -q '=ERR' "$f" && fail "  指纹查询报错（见上面 =ERR 的项）——先确认查询语法/通配聚合是否被该版本支持" ; }
w05_fp_compare(){ local label=$1 f0=$2 f1=$3 res same total
  res=$(awk 'NR==FNR{a[FNR]=$0; n=FNR; next}{ if($0==a[FNR]){c++} else {printf "  DIFF 第%d项: [%s] -> [%s]\n", FNR, a[FNR], $0} } END{printf "SAME=%d TOTAL=%d LINES2=%d\n", c+0, n+0, FNR}' "$f0" "$f1")
  same=$(printf '%s\n' "$res" | grep -oE 'SAME=[0-9]+' | cut -d= -f2)
  total=$(printf '%s\n' "$res" | grep -oE 'TOTAL=[0-9]+' | cut -d= -f2)
  log "  指纹逐项比对（$label）：一致 ${same:-0} / 共 ${total:-0} 项"
  awk 'NR==FNR{a[FNR]=$0; next}{ printf "      [%s] %s -> %s\n", ($0==a[FNR] ? "一致" : "不一致"), a[FNR], $0 }' "$f0" "$f1" >>"$OUT"
  printf '%s\n' "$res" | grep 'DIFF' | sed 's/^/      /' >>"$OUT"
  assert_eq "  指纹逐项一致项数（$label）" "${same:-0}" "${total:-0}"
  assert_eq "  重启后指纹项数（缺失/多余都不允许，$label）" "$(grep -c . "$f1")" "$(grep -c . "$f0")"; }
w05_wait_total(){ local label=$1 sql=$2 want=$3 win=$4 dl got
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(row_sum "$(sq "$sql")")
    [ "${got:-0}" = "$want" ] && { pass "  $label: $got"; return 0; }
    log "    等 $label: 实际=${got:-?} 期望=$want（$(date '+%T')）"
    sleep 5
  done
  fail "  $label: 实际=${got:-?} 期望=$want（等 ${win}s 仍不一致）"
  return 1; }

# ---- ③ WAL 面：库级隔离 + 指标口径 -----------------------------------------
w05_ident_dirs(){ local h=$1 db=$2
  sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 2 -type d -name '$db-*' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w05_db_files(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$db-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w05_db_bytes(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$db-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 当前相关注的库（A 相 = DB，B 相 = DB2）
w05_cnt(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h" "$W05_DB") )); done; echo "$s"; }
w05_per_node(){ local h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(w05_db_files "$h" "$W05_DB")f/$(w05_db_bytes "$h" "$W05_DB")B "; done; echo "$out"; }
w05_scope_decide(){ local h n=0
  W05_DB="$DB"
  for h in "${DN[@]}"; do [ -n "$(w05_ident_dirs "$h" "$DB")" ] && n=$(( n + 1 )); done
  if [ "$n" -gt 0 ]; then W05_SCOPE=db; else W05_SCOPE=all; fi
  log "  WAL 对照口径=$W05_SCOPE（db=按 <库>-<regionId> identifier 目录隔离；all=整个 WAL 目录，含系统库 ⇒ 回退口径）"; }
w05_snap(){ local tag=$1 dbf dbb alf alb
  dbf=$(w05_cnt w05_db_files); dbb=$(w05_cnt w05_db_bytes)
  alf=$(wal_sum_over_dn wal_file_cnt); alb=$(wal_sum_over_dn wal_dir_bytes)
  if [ "$W05_SCOPE" = db ]; then W05_FILES=$dbf; W05_BYTES=$dbb; else W05_FILES=$alf; W05_BYTES=$alb; fi
  log "  [WAL 快照/$tag] 口径=$W05_SCOPE files=$W05_FILES bytes=$W05_BYTES（本库 ${dbf}f/${dbb}B；整目录 ${alf}f/${alb}B；逐副本 $(w05_per_node)）"
  log "  [WAL 指标/$tag] file_count{name=wal}=$(wal_metric_sum_over_dn wal_metric_file_cnt) file_size{name=wal}=$(wal_metric_sum_over_dn wal_metric_file_bytes)"; }
# 等 WAL 观测稳定（连续两次采样一致）：异步 fsync 落盘 / 刷盘后失效 WAL 被删都需要时间
w05_wait_wal_stable(){ local label=$1 dl f0="" b0="" f b n=0
  dl=$(( $(date +%s) + STABLE_WIN ))
  while (( $(date +%s) < dl )); do
    w05_snap "$label/稳定采样"
    f=$W05_FILES; b=$W05_BYTES
    if [ "$f" = "$f0" ] && [ "$b" = "$b0" ]; then
      n=$(( n + 1 )); [ "$n" -ge 2 ] && { log "  [$label] WAL 观测已稳定（files=$f bytes=$b）"; return 0; }
    else
      n=0
    fi
    f0=$f; b0=$b
    sleep 5
  done
  warn "  [$label] WAL 观测在 ${STABLE_WIN}s 内未稳定（取值可能仍在变：files=$f bytes=$b）——继续，但对照数值仅供记录"; return 0; }

# ---- ④ 掉电注入 / 拉起 -----------------------------------------------------
w05_kill_all(){ local h n=0 gone=0 pid pids=""
  log "--- 掉电注入：逐个 kill -9 **全部** DataNode（掉电语义；A 相数据只在 WAL，B 相数据已在 TsFile）---"
  for h in "${DN[@]}"; do
    pid=$(wal_dn_pid "$h")
    pids="$pids${h##*.}=${pid:-none} "
  done
  log "  kill 前各 DN 进程号：$pids"
  for h in "${DN[@]}"; do
    if wal_kill9_dn "$h"; then n=$(( n + 1 )); pass "  kill -9 成功：$h"; else fail "  kill -9 失败：$h"; fi
  done
  assert_eq "  场景有效性：被 kill -9 的 DN 个数（必须=全部副本）" "$n" "${#DN[@]}"
  for h in "${DN[@]}"; do
    if [ -z "$(wal_dn_pid "$h")" ]; then
      gone=$(( gone + 1 ))
    else
      fail "  $h 的 DataNode 进程仍在（kill -9 未生效）"
    fi
  done
  assert_eq "  场景有效性：进程确实消失的 DN 个数" "$gone" "${#DN[@]}"; }
w05_fire_dn(){ local h=$1
  log "  启动 DataNode @ $h"
  sshx "$h" "cd $DB_DIR && nohup ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" || warn "  启动 $h 失败"; }
w05_proc_up(){ local h=$1
  [ -n "$(wal_dn_pid "$h")" ]; }
w05_dn_state_any(){ local want=$1 h out st
  for h in "${DN[@]}"; do
    out=$(sq_node "$h" 'show cluster;' 2>/dev/null)
    st=$(printf '%s\n' "$out" | awk -F'|' -v ip="$want" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$4);gsub(/[ \t]/,"",$5)} $3=="DataNode" && $5==ip {print $4; exit}')
    [ -n "${st:-}" ] && { printf '%s' "$st"; return 0; }
  done
  printf ''; return 1; }
w05_start_all(){ local h n dl
  log "--- 拉起全部 DataNode（先全部点火，再等进程；全部 DN 掉电时 CLI 直连 DN，逐个等会空转到超时）---"
  for h in "${DN[@]}"; do w05_fire_dn "$h"; done
  dl=$(( $(date +%s) + START_WIN ))
  while (( $(date +%s) < dl )); do
    n=0; for h in "${DN[@]}"; do w05_proc_up "$h" && n=$(( n + 1 )); done
    log "  DataNode 进程数：$n/${#DN[@]}"
    [ "$n" -ge "${#DN[@]}" ] && { pass "  三个 DataNode 进程都已启动"; return 0; }
    sleep 5
  done
  fail "  有 DataNode 进程未在 ${START_WIN}s 内启动"
  return 1; }
w05_wait_running(){ local h n dl st
  dl=$(( $(date +%s) + REPLAY_WIN ))
  while (( $(date +%s) < dl )); do
    n=0
    for h in "${DN[@]}"; do st=$(w05_dn_state_any "$h"); [ "$st" = "Running" ] && n=$(( n + 1 )); done
    log "  重启后 DataNode Running 计数：$n/${#DN[@]}"
    [ "$n" -ge "${#DN[@]}" ] && { pass "  三个 DataNode 都已 Running（重启完成）"; return 0; }
    sleep 5
  done
  fail "  有 DataNode 未在 ${REPLAY_WIN}s 内回到 Running"
  return 1; }
w05_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(w05_dn_state_any "$h") 进程：$(sshx "$h" "pgrep -af com.timecho.iotdb.DataNode | head -2" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-160)"
    log "  [$h] WAL 根目录：$(wal_dir_roots "$h" | tr '\n' ' ')；identifier 目录：$(w05_ident_dirs "$h" "$DB" | tr '\n' ' ') $(w05_ident_dirs "$h" "$DB2" | tr '\n' ' ')"
    log "  [$h] 该库 TsFile 数（A/B）= $(cmp_seq_cnt "$h" "$DB"):$(cmp_unseq_cnt "$h" "$DB") / $(cmp_seq_cnt "$h" "$DB2"):$(cmp_unseq_cnt "$h" "$DB2")"
    log "  [$h] WAL 清单（含大小）："
    wal_ls "$h" | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] WAL 相关日志尾部："
    wal_log_tail "$h" 20 | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] log_datanode_all.log 尾部 20 行："
    sshx "$h" "tail -20 $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | sed 's/^/        /' >>"$OUT" 2>&1
  done
  log "  show cluster："
  sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"
  log "=== 逐副本证据结束（$tag）==="; }

# ===========================================================================
# 单相执行：<标签> <库> <nf|flush>
#   nf    = 写完**不 flush**（数据只在 MemTable+WAL ⇒ 必须靠 WAL 重放）
#   flush = 写完 + flush + ensure_closed（数据在 TsFile、对应 WAL 已失效 ⇒ 不应再依赖重放）
# ===========================================================================
w05_run_phase(){ local label=$1 db=$2 mode=$3 bf bb c s ts
  W05_DB="$db"
  log ""
  log "================= W-05 $label 相：库=$db 模式=$mode ================="
  w05_snap "$label/写前基线"
  bf=$W05_FILES; bb=$W05_BYTES
  cmp_make_tree_db "$db" "$DEVS"
  if w05_write_nf "$db"; then pass "  [$label] 写入完成（${DEVS}×${ROWS}×${BATCHES} 点，模式=$mode）"; else fail "  [$label] 写入失败"; fi

  log "  --- [$label] 场景有效性：可见性 + 离线核算 ---"
  wait_scalar_tree "select count(s1) from $db.d1;" "$(( ROWS * BATCHES ))" 90 "[$label] 写入后可见性（$db.d1 设备路径）"
  c=$(row_sum "$(sq "select count(s1) from $db.**;")"); s=$(row_sum "$(sq "select sum(s1) from $db.**;")")
  assert_eq "  [$label] 写入后总点数（DEVS×ROWS×BATCHES）" "${c:-0}" "$(w05_exp_count)"
  assert_eq "  [$label] 写入后值总和（可离线核算）" "${s:-0}" "$(w05_exp_sum)"

  if [ "$mode" = flush ]; then
    log "  --- [$label] B 相：flush + ensure_closed（数据落到 TsFile；对应 WAL 记录应变无效）---"
    sq "flush;" >/dev/null
    ensure_closed "$db" 2 "$CLOSE_WIN" || warn "  [$label] ensure_closed 未在窗口内观察到新的 Async close（TsFile 封口可能不齐）"
    ts=$(cmp_all_sum "$db")
    log "  [$label] flush+ensure_closed 后该库 TsFile 数=$ts（逐副本 $(cmp_per_node cmp_seq_cnt "$db")）"
    if [ "${ts:-0}" -gt 0 ]; then
      pass "  场景有效性：[$label] 数据已在 TsFile（TsFile=$ts ⇒ B 相语义成立）"
    else
      fail "  场景无效：[$label] flush 后该库 TsFile 数=$ts（0 ⇒ 数据没落盘，B 相语义不成立）"
    fi
  else
    log "  --- [$label] A 相：**刻意不 flush、不 ensure_closed**（数据只在 MemTable + WAL 上）---"
    ts=$(cmp_all_sum "$db")
    if [ "${ts:-0}" -eq 0 ]; then
      pass "  场景有效性：[$label] kill 前该库 TsFile=0（数据只能靠 WAL 重放）"
    else
      warn "  [$label] kill 前该库已有 TsFile=$ts（数据可能部分落盘 ⇒ WAL 重放语义被削弱，记录）"
    fi
  fi

  log "  --- [$label] 等 WAL 观测量稳定，然后记录 kill 前的 WAL 规模 ---"
  w05_wait_wal_stable "$label"
  w05_snap "$label/kill前"
  W05_LAST_DFILES=$(( W05_FILES - bf )); W05_LAST_DBYTES=$(( W05_BYTES - bb ))
  log "  [$label] **WAL 对照量**：kill 前 绝对=${W05_FILES}f/${W05_BYTES}B；写前基线=${bf}f/${bb}B；增量=${W05_LAST_DFILES}f/${W05_LAST_DBYTES}B"
  if [ "$mode" = nf ]; then
    if [ "${W05_FILES:-0}" -gt 0 ]; then
      pass "  场景有效性：[$label] kill 前 WAL 非空（files=$W05_FILES bytes=$W05_BYTES）"
    else
      fail "  场景无效：[$label] kill 前 WAL 为空（files=0）——A 相没有可重放的内容"
    fi
  fi

  log "  --- [$label] 记录 kill 前指纹 ---"
  w05_fp_dump "$db" "$ART/fp_${label}_pre.txt"

  log "  --- [$label] 掉电：kill -9 全部 DataNode → 拉起 → 等 Running ---"
  w05_kill_all
  if w05_start_all; then w05_wait_running || w05_evidence "[$label] 重启后未 Running"; else w05_evidence "[$label] DN 进程未启动"; fi
  sq 'show cluster;' >>"$OUT" 2>&1

  log "  --- [$label] 等重放 + 等数据可见 ---"
  wal_wait_replay "$db" "$EVID_WIN"
  wait_scalar_tree "select count(s1) from $db.d1;" "$(( ROWS * BATCHES ))" "$REPLAY_WIN" "[$label] 重启后可见性（$db.d1 设备路径）"
  w05_wait_total "[$label] 重启后总点数" "select count(s1) from $db.**;" "$(w05_exp_count)" "$REPLAY_WIN"

  log "  --- [$label] 数据面硬断言：指纹逐项相等 ---"
  w05_fp_dump "$db" "$ART/fp_${label}_post.txt"
  w05_fp_compare "$label 相掉电重启后" "$ART/fp_${label}_pre.txt" "$ART/fp_${label}_post.txt"
  w05_snap "$label/重启后"
}

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-05 flush 边界对照：A=$DB（写完不 flush 直接掉电） B=$DB2（flush + TsFile 落盘后掉电）==="
log "  规模：${DEVS}设备×${ROWS}点×${BATCHES}批（期望 count=$(w05_exp_count) sum=$(w05_exp_sum)）；A/B 完全相同 ⇒ 两相可比"
log "  A 相必须 SYNC（写入返回＝WAL 已刷盘），故两相统一用：$W05_EXTRA"

log "--- ① 集群准备（一次准备，两相共用；写入期关三类合并）---"
EXTRA_CONF="$W05_EXTRA" cmp_cluster_prepare
log "  合并参数生效值（抽查）：$(cmp_eff_all "${DN[0]}")"
WM=$(cmp_eff "${DN[0]}" wal_mode)
if [ -z "${WM:-}" ]; then WM=$(wal_props_get "${DN[0]}" wal_mode); log "  show configuration 无 wal_mode ⇒ 用配置文件值：${WM:-（空）}"; fi
case "${WM:-}" in
  SYNC)    pass "  生效 wal_mode=SYNC（写入返回＝WAL 已刷盘 ⇒ A 相立刻掉电的判据有契约依据）" ;;
  "")      warn "  无法读取生效 wal_mode（show configuration 与 properties 都为空）⇒ 记录；若实际是 ASYNC，A 相立刻掉电丢数据不构成缺陷" ;;
  *)       warn "  生效 wal_mode=$WM（不是 SYNC）⇒ A 相立刻掉电的持久性判据按 ASYNC/该模式的口径理解，记录" ;;
esac
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done
w05_scope_decide

log "--- ② A 相：写完**不 flush** 直接掉电（必须靠 WAL 重放）---"
w05_run_phase "A" "$DB" nf
A_DFILES=$W05_LAST_DFILES; A_DBYTES=$W05_LAST_DBYTES
log "  A 相完成：kill 前 WAL 增量=${A_DFILES}f/${A_DBYTES}B"

log "--- ③ B 相：写完 + flush + ensure_closed（数据在 TsFile、对应 WAL 已失效）后掉电 ---"
w05_run_phase "B" "$DB2" flush
B_DFILES=$W05_LAST_DFILES; B_DBYTES=$W05_LAST_DBYTES
log "  B 相完成：kill 前 WAL 增量=${B_DFILES}f/${B_DBYTES}B"

log "--- ④ 两相 WAL 对照（**软证据**；B 相不下降不一定异常，见 design_extract §5.4）---"
log "  A 相（不 flush）：增量 ${A_DFILES}f / ${A_DBYTES}B"
log "  B 相（flush+落盘）：增量 ${B_DFILES}f / ${B_DBYTES}B"
if [ "${B_DBYTES:-0}" -lt "${A_DBYTES:-0}" ]; then
  pass "  对照成立：B 相 kill 前 WAL 更小或已被清理（$A_DBYTES → $B_DBYTES 字节；$A_DFILES → $B_DFILES 个文件）"
else
  warn "  对照未观测到 B 相 WAL 更小（A=${A_DBYTES}B/${A_DFILES}f vs B=${B_DBYTES}B/${B_DFILES}f）——按 design_extract §5.4，已刷盘但未被 IoTConsensus 消费完的 WAL 文件不可删，故不判 FAIL（B 相的硬证据是 TsFile>0 + 重启后数据完整）"
fi
if [ "${B_DFILES:-0}" -le "${A_DFILES:-0}" ] && [ "${B_DBYTES:-0}" -le "${A_DBYTES:-0}" ]; then
  pass "  两相文件数/字节数均：B ≤ A"
else
  warn "  文件数与字节数的方向不一致（A=${A_DFILES}f/${A_DBYTES}B B=${B_DFILES}f/${B_DBYTES}B）——记录，供研发判断 WAL 清理时机"
fi
log "  说明：A 相数据只在 WAL（kill 前 TsFile=0），B 相数据已在 TsFile（TsFile>0）——两相各自的重启后数据完整性已在上面的硬断言里逐项校验"

log "--- ⑤ WAL 消费证据（只作证据）---"
OOM=$(wal_oom_cnt); assert_eq "  WAL 相关 OOM 日志行数（必须 0）" "${OOM:-0}" "0"
log "  重启后 WAL（A 相口径/整目录）：$(wal_sum_over_dn wal_file_cnt)f/$(wal_sum_over_dn wal_dir_bytes)B；指标口径 file_count=$(wal_metric_sum_over_dn wal_metric_file_cnt) file_size=$(wal_metric_sum_over_dn wal_metric_file_bytes)"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w05_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 专属异常正则已安装）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|Connection reset by peer|Connection refused'
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
