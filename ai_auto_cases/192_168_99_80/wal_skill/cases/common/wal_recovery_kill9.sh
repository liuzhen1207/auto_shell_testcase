#!/bin/bash
# ============================================================================
# W-04 WAL 掉电恢复（核心）：**未 flush 写入 → kill -9 全部 DataNode → 重启 → 数据一条不少**
#
# 一句话：这条用例才是真正验证"WAL 保数据不丢"的门禁——数据只在 MemTable + WAL 里
#   （没 flush、没有 TsFile），把**整机三个 DataNode 进程全部 SIGKILL**（等于整机掉电），
#   再拉起来，已确认写入的数据必须一条不少。
#
# ---------------------------------------------------------------------------
# 【为什么必须杀"全部 DN"而不是 1 个】
#   只杀 1 个 DN 验证的是**共识补齐**（另两副本还在，IoTConsensus 把落后的副本补上），
#   数据从来不在"只靠 WAL"的状态；只有三副本全部掉电，"数据能不能回来"才只由各自的
#   WAL + checkpoint 决定（design_extract.md §4.3「WAL 重启恢复」/§1.3「每个 DataRegion 拥有一个 WAL Node」）。
#
# 【需求依据】
#   · design_extract.md §4 持久化与恢复：§4.1 wal_mode/fsync 时机、§4.3 重启恢复流程
#     （读 checkpoint → 读 WAL Entry 交给 UnsealedTsFileRecoverPerformer → 删除 WALNode 下的文件）、
#     §4.4「恢复完成的判定信号：文档没有给任何日志关键字/指标/SQL」⇒ 本用例**只能**用
#     "轮询查询等数据可见"（等重放）作权威信号，目录/日志/指标只作过程证据。
#   · design_extract.md §8 可测点：TP-29（未刷盘数据重启后应被重放且可查）、TP-30（恢复粒度为
#     WALNode、恢复后直接刷盘、末步删除 WALNode 下的文件）。
#   · feature_extract.md B（队列/内存）与本用例无关；WAL 压缩走 W-12。
#   · source_grounding.md：WAL 目录/文件名 = `<dn_wal_dirs>/<identifier>/_<versionId>-<startSearchIndex>-<statusCode>.wal`，
#     IoTConsensus 下 `identifier = <database>-<regionId>` ⇒ 本用例用它把"本库的 WAL"从整目录里隔离出来；
#     权威指标 `file_count{name="wal"}` / `file_size{name="wal"}`（helper：wal_metric_file_cnt / wal_metric_file_bytes）。
#   ⚠️ 不要拿 WALNode.java 里"删除过期 WAL 条数"的结论文案当判据（DEBUG 级、默认不落盘）。
#
# 【判据结构（三层，硬/软分明）】
#   ① 场景有效性（硬）：写入后数据可见且总数/总和与离线核算一致；WAL 文件数 > 0（本库 identifier
#      目录口径优先，回退整目录口径）；**三个 DN 全部真的被 kill -9**（进程消失）；重启后三个 DN 都 Running。
#   ② 数据面（硬）：kill 前落指纹（总 count/sum/min/max + 每设备 count/sum/min/max + 单设备全序列 md5/行数），
#      重启后逐项相等；任何缺失/多余都 fail（含指纹项数比对）。
#   ③ WAL 消费证据（软，只作证据、不作通过条件）：WAL 文件数/字节下降、wal_wait_replay 的观测、
#      指标口径（file_count/file_size{name="wal"}）、日志里 recovery/wal 相关行数。
#
# 【ASYNC 与"写入已确认"的口径（重要，直接关系到误判）】
#   conf/env.conf 默认 `wal_mode=ASYNC`：文档口径是"写入不等待 WAL 刷盘，成功后立即返回"，
#   design_extract.md TP-11 明确"ASYNC 下**不能**断言丢或不丢"。因此本用例在写入后等
#   `WAL_KILL_WAIT_SEC`（默认 60s，> wal_async_mode_fsync_delay_in_ms=1000ms）让异步 fsync
#   周期把 WAL 落到盘上，再 kill -9 ⇒ 此时"已确认写入的数据"在盘上是 WAL 的契约内容，
#   丢掉才是缺陷。等待前后的 WAL 字节数都会打印（否则无法证明"确实写了 WAL"）。
#   （要测"写完立刻掉电"的 SYNC 语义见 W-05 的 A 相，那里显式把 wal_mode 设为 SYNC。）
#
# 【刻意不做的事】
#   · 恢复相**绝不 flush / 绝不 ensure_closed**：那会让数据提前落盘，"WAL 重放"就失去意义；
#     写入后只用 scalar 查询确认"当前可见"（可见性来自 MemTable+WAL）。
#   · 不改 lib/、tools/、conf/、cases.tsv、docs/（只新增本文件）。
#
# 【时长大致】≈18~22 分钟（集群准备 ~4min + 写入/等待 ~2min + 掉电/拉起 ~4min + 等重放 ~3min
#   + 收尾三件套（逐个停/起 DN）~4min）。可调：W04_DEVS/W04_ROWS/W04_BATCHES/W04_WAIT_SEC/W04_START_WIN_SEC。
#
# 【⚠️ 首轮 watch list（先看这些才知道"场景真的成立了"）】
#   1) **"全部 DN 掉电后能不能拉起来"**：kill -9 三个 DN 后，CN 仍在运行，DN 重新加入要过
#      "集群未激活/注册/共识选主"这几关（元数据 skill 踩过：clean 掉 data 后 DN 会在未激活窗口
#      注册被拒而直接退出）。首轮先看 `w04_wait_all_running` 的 Running 计数与 DN 日志尾部；
#      起不来时用例会给逐副本证据（本文件末尾的 w04_evidence），先判断是**产品不允许**还是环境残留。
#   2) **等待 60s 后本库 WAL 是否非空**：若为 0（说明数据在等待期间已自行落盘/被清理），
#      重放路径根本没被走到 ⇒ 场景无效（用例会 fail 并打印两组口径的 WAL 证据）。
#   3) **重启后数据可见要多久**：`WAL_REPLAY_WIN_SEC`（默认 300s）是否够；恢复期没有任何
#      "恢复完成"日志信号（design_extract §4.4），只能靠轮询查询——首轮记录实际收敛耗时。
#   4) **`wal_wait_replay` 的"文件数下降"往往观察不到**（恢复流程末步直接删 WALNode 下的文件，
#      或者我们第一次采样时已经删完）⇒ 它只是软证据，不要因为"没下降"改判 FAIL。
#   5) **WAL 专属异常正则的误报**：本用例调用 `wal_install_err_pat`（WAL 失败类正则）。
#      首轮看收尾 `check_logs` 是否有 "WAL…failed / Failed to recover WAL" 命中：
#      若命中但数据完整，先核对是不是恢复期的正常 INFO，再决定加进 CMP_LOG_BENIGN_EXTRA（不要直接改 lib）。
#
# 用法： bash cases/common/wal_recovery_kill9.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 本文件**未在真实集群实跑过**（99.80 正在跑长回归，禁止任何集群动作）；只保证 bash -n 与逻辑自洽。
#
# 【RC8 首轮失败根因 + 修法（2026-10-18，均为用例侧 bug，判据一条没动）】
#   ① `line 91: 批数（默认: command not found` + `line 289: BATCHES: unbound variable`（瞬时失败 0s）：
#      赋值行与行尾注释**粘连**（`BATCHES=${W04_BATCHES:-$WAL_BATCHES}# 批数（默认 3）` 少了一个空格），
#      `#批数（默认` 被当成命令执行 ⇒ BATCHES 从未赋值 ⇒ `set -u` 下第 289 行引用即中断。
#      修法：补空格让注释独立成注释（写成 `VAR=... # 注释`，与 compaction/CRUD 里的写法一致）。
#   ② 顺带修同类未爆的取值 bug：`w04_name_fmt(){ local h v` 只声明不接参 ⇒ 函数体里的 `$h`
#      在 `set -u` 下就是 unbound（且即使不报错也会 ssh 到空主机名）。修法：`local h=$1 v`。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_recovery_kill9_${DATA_CONSENSUS}"

# ---------------------------------------------------------------------------
# 环境兜底：wal_skill/conf/env.conf 目前**没有**这三个 TTL 键，而 lib/common.sh 的
# cluster_set_conf 会在未加引号的 heredoc 里引用它们（`set_prop ttl_check_interval $TTL_CHECK_INTERVAL_MS`）
# ⇒ `set -u` 下会直接中断"集群准备"。本用例只兜底赋值（取值与 CRUD skill 一致），不改 lib/conf。
# ---------------------------------------------------------------------------
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"

DB=root.walkill                     # 用例约定的库名（本库 WAL 的 identifier 目录 = root.walkill-<regionId>）
DEVS=${W04_DEVS:-$WAL_DEVS}         # 设备数（默认 6）
ROWS=${W04_ROWS:-$WAL_ROWS}         # 每设备每批点数（默认 300）
BATCHES=${W04_BATCHES:-$WAL_BATCHES} # 批数（默认 3）  ← RC8 首轮：这里少一个空格，`#批数` 被当成命令 ⇒ BATCHES 未赋值
PER=${W04_PER:-500}                 # 每条 INSERT 的行数（500 行/语句，避免超长 SQL）
WAIT=${W04_WAIT_SEC:-${WAL_KILL_WAIT_SEC:-60}}   # kill -9 前的异步 WAL 落盘等待（秒）
REPLAY_WIN=${W04_REPLAY_WIN_SEC:-${WAL_REPLAY_WIN_SEC:-300}}  # 重启后等数据可见
START_WIN=${W04_START_WIN_SEC:-300} # 重启后等 DataNode 进程/状态
EVID_WIN=${W04_EVID_WIN_SEC:-90}    # wal_wait_replay 的观测窗口（软证据，取小一点别空转）
BASE_TS=$(( ($(date +%s) - 3600) * 1000 ))   # 时间戳基准（所有批都落在同一个时间分区）

# 写入的 WAL 参数逐项显式写出（便于在产物里核对；取值与 conf/env.conf 的默认值一致）
W04_EXTRA="wal_mode=${WAL_MODE},enable_wal_compression=${WAL_COMPRESSION},wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_FILE_THRESHOLD_BYTES},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 写入（**不 flush**）------------------------------------------------
# 值与时间戳都是确定性的，便于离线核算：
#   设备 d 的第 b 批（b 从 1 起）第 k 行（k 从 0 起）：值 = k + b，时间戳 = BASE_TS + b*1000000 + k*10
#   ⇒ 单设备单批 count = ROWS，sum = ROWS*(ROWS-1)/2 + ROWS*b
w04_write_nf(){ local d b k vals ts
  local -a S=()
  for (( b=1; b<=BATCHES; b++ )); do
    for (( d=1; d<=DEVS; d++ )); do
      S=(); vals=""
      for (( k=0; k<ROWS; k++ )); do
        ts=$(( BASE_TS + b * 1000000 + k * 10 ))
        vals="$vals($ts,$(( k + b ))),"
        if [ $(( (k + 1) % PER )) -eq 0 ]; then
          S+=("insert into $DB.d$d(time,s1) values ${vals%,};"); vals=""
        fi
      done
      [ -n "$vals" ] && S+=("insert into $DB.d$d(time,s1) values ${vals%,};")
      [ "${#S[@]}" -gt 0 ] || continue
      # 单会话 stdin 喂语句（同一连接；也避免 `sq -e` 的超长命令行；不用多行字符串，免得被"整行化"事故坑到）
      printf '%s\n' "${S[@]}" | session_tree >/dev/null || return 1
    done
  done
  return 0
}
w04_exp_count(){ echo $(( DEVS * ROWS * BATCHES )); }
w04_exp_sum(){ local b s=0
  for (( b=1; b<=BATCHES; b++ )); do s=$(( s + ROWS * (ROWS - 1) / 2 + ROWS * b )); done
  echo $(( DEVS * s )); }

# ---- ② 数据面指纹（逐项可比，缺失/多余都能发现）----------------------------
# 单设备四项一律走 lib/wal_ext.sh 的 `wal_dev_fp4`（RC8 第二轮修，见 wal_ext.sh ⑬）：
#   · **一条查询只放一个聚合**（混查 `count/sum/min/max` 报 701 hybrid query）；
#   · 只查**设备路径** `db.dN`（序列路径 `db.dN.s1` 在本版本落到空结果）；
#   · `min`/`max` 不是本版本内建名（要写 `min_value`/`max_value`），取不到值写 `ERR`。
w04_dev_agg(){ wal_dev_fp4 "$1"; }
# 指纹落文件（每行 key=value）；`**` 上的聚合是"每序列一列"⇒ 总数/总和必须用 row_sum 求和
# 查询报错时写 ERR（而不是静默的 0）——否则"两边都是 0"会假装一致（假通过）。
w04_q_sum(){ local sql=$1 out
  out=$(sq "$sql")
  if printf '%s\n' "$out" | grep -qE 'Exception'; then printf 'ERR'; return 1; fi
  printf '%s' "$(row_sum "$out")"; }
w04_fp_dump(){ local db=$1 f=$2 i
  : >"$f"
  printf 'total_count=%s\n' "$(w04_q_sum "select count(s1) from $db.**;")" >>"$f"
  printf 'total_sum=%s\n'   "$(w04_q_sum "select sum(s1) from $db.**;")"   >>"$f"
  # min/max 汇总**逐设备**取值再在本地相加（`select min(s1) from <db>.**` 在本版本 701）
  printf 'total_min_sum=%s\n' "$(wal_dev_sum_of min "$db" "$DEVS")"        >>"$f"
  printf 'total_max_sum=%s\n' "$(wal_dev_sum_of max "$db" "$DEVS")"        >>"$f"
  for (( i=1; i<=DEVS; i++ )); do printf 'dev_d%s=%s\n' "$i" "$(w04_dev_agg "$db.d$i")" >>"$f"; done
  # d1 全序列：md5 前先 `data_rows`（丢表头与 `It costs …` 统计行），判据仍是"两相必须相等"
  wal_seq_fp "$db" >>"$f"
  log "  指纹已落盘：$f（$(grep -c . "$f") 项）"
  sed 's/^/      /' "$f" >>"$OUT"
  grep -q '=ERR' "$f" && fail "  指纹查询报错（见上面 =ERR 的项）——先确认查询语法/通配聚合是否被该版本支持，勿把它当成数据比对结果" ; }
# 逐项比对（按位置比；行数不等＝缺失/多余 ⇒ fail，并逐项打印 before → after 便于定责）
w04_fp_compare(){ local label=$1 f0=$2 f1=$3 res same total
  res=$(awk 'NR==FNR{a[FNR]=$0; n=FNR; next}{ if($0==a[FNR]){c++} else {printf "  DIFF 第%d项: [%s] -> [%s]\n", FNR, a[FNR], $0} } END{printf "SAME=%d TOTAL=%d LINES2=%d\n", c+0, n+0, FNR}' "$f0" "$f1")
  same=$(printf '%s\n' "$res" | grep -oE 'SAME=[0-9]+' | cut -d= -f2)
  total=$(printf '%s\n' "$res" | grep -oE 'TOTAL=[0-9]+' | cut -d= -f2)
  log "  指纹逐项比对（$label）：一致 ${same:-0} / 共 ${total:-0} 项"
  awk 'NR==FNR{a[FNR]=$0; next}{ printf "      [%s] %s -> %s\n", ($0==a[FNR] ? "一致" : "不一致"), a[FNR], $0 }' "$f0" "$f1" >>"$OUT"
  printf '%s\n' "$res" | grep 'DIFF' | sed 's/^/      /' >>"$OUT"
  assert_eq "  指纹逐项一致项数（$label）" "${same:-0}" "${total:-0}"
  assert_eq "  重启后指纹项数（缺失/多余都不允许）" "$(grep -c . "$f1")" "$(grep -c . "$f0")"; }
# 等 `**` 口径的标量（row_sum）达到期望（wait_scalar_tree 只取第一列，不适合 `**`）
w04_wait_total(){ local label=$1 sql=$2 want=$3 win=$4 dl got
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(row_sum "$(sq "$sql")")
    [ "${got:-0}" = "$want" ] && { pass "  $label: $got"; return 0; }
    log "    等 $label: 实际=${got:-?} 期望=$want（$(date '+%T')）"
    sleep 5
  done
  fail "  $label: 实际=${got:-?} 期望=$want（等 ${win}s 仍不一致）"
  return 1; }

# ---- ③ WAL 面观测（目录口径 + 指标口径）------------------------------------
# 本库 identifier 目录（IoTConsensus：identifier = <database>-<regionId>）
w04_ident_dirs(){ local h=$1
  sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 2 -type d -name '$DB-*' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w04_db_files(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w04_db_bytes(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w04_db_sum(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h") )); done; echo "$s"; }
w04_db_per_node(){ local h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(w04_db_files "$h")f/$(w04_db_bytes "$h")B "; done; echo "$out"; }
# 文件名格式证据（`_<versionId>-<startSearchIndex>-<statusCode>.wal`），只作证据：格式不符只 WARN
w04_name_fmt(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -name '*.wal' -printf '%f\n' 2>/dev/null | grep -cE '^_[0-9]+-[0-9]+-[0-9]+\\.wal\$'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w04_wal_report(){ local tag=$1
  log "  [WAL/$tag] 目录口径：本库=$(w04_db_sum w04_db_files)f/$(w04_db_sum w04_db_bytes)B（逐副本：$(w04_db_per_node)）；整目录=$(wal_sum_over_dn wal_file_cnt)f/$(wal_sum_over_dn wal_dir_bytes)B"
  log "  [WAL/$tag] 指标口径（file_count/file_size{name=wal}）：files=$(wal_metric_sum_over_dn wal_metric_file_cnt) bytes=$(wal_metric_sum_over_dn wal_metric_file_bytes)"
  log "  [WAL/$tag] 文件名格式命中（_ver-idx-status.wal）：$(wal_sum_over_dn w04_name_fmt) 个；样例：$(w04_ident_dirs "${DN[0]}" | head -3 | tr '\n' ' ')" ; }

# ---- ④ 掉电注入 / 拉起 -----------------------------------------------------
w04_kill_all(){ local h n=0 pids="" pid gone=0
  log "--- 掉电注入：逐个 kill -9 **全部** DataNode（只杀 1 个只验证共识补齐，不是掉电语义）---"
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
  assert_eq "  场景有效性：进程确实消失的 DN 个数（掉电语义成立）" "$gone" "${#DN[@]}"; }
# 点火动作与 lib/wal_ext.sh 的 wal_start_dn 中的启动命令逐字一致，只是把"启动/等状态"拆开：
# 三个 DN 全掉电时 CLI 直连 DN，逐个"起一个等一个"会在第一个 DN 就绪前空转到超时。
w04_fire_dn(){ local h=$1
  log "  启动 DataNode @ $h"
  sshx "$h" "cd $DB_DIR && nohup ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" || warn "  启动 $h 失败"; }
w04_proc_up(){ local h=$1
  [ -n "$(wal_dn_pid "$h")" ]; }
# 用"任一在线 DN"查 show cluster（DN[0] 没起来时换下一个；dn_state 固定经 QDN 会误判）
w04_dn_state_any(){ local want=$1 h out st
  for h in "${DN[@]}"; do
    out=$(sq_node "$h" 'show cluster;' 2>/dev/null)
    st=$(printf '%s\n' "$out" | awk -F'|' -v ip="$want" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$4);gsub(/[ \t]/,"",$5)} $3=="DataNode" && $5==ip {print $4; exit}')
    [ -n "${st:-}" ] && { printf '%s' "$st"; return 0; }
  done
  printf ''; return 1; }
w04_start_all(){ local h n dl
  log "--- 拉起全部 DataNode（先全部点火，再等进程/状态）---"
  for h in "${DN[@]}"; do w04_fire_dn "$h"; done
  dl=$(( $(date +%s) + START_WIN ))
  while (( $(date +%s) < dl )); do
    n=0; for h in "${DN[@]}"; do w04_proc_up "$h" && n=$(( n + 1 )); done
    log "  DataNode 进程数：$n/${#DN[@]}"
    [ "$n" -ge "${#DN[@]}" ] && { pass "  三个 DataNode 进程都已启动"; return 0; }
    sleep 5
  done
  fail "  有 DataNode 进程未在 ${START_WIN}s 内启动"
  return 1; }
w04_wait_running(){ local h n dl st
  dl=$(( $(date +%s) + REPLAY_WIN ))
  while (( $(date +%s) < dl )); do
    n=0
    for h in "${DN[@]}"; do st=$(w04_dn_state_any "$h"); [ "$st" = "Running" ] && n=$(( n + 1 )); done
    log "  重启后 DataNode Running 计数：$n/${#DN[@]}"
    [ "$n" -ge "${#DN[@]}" ] && { pass "  三个 DataNode 都已 Running（重启完成）"; return 0; }
    sleep 5
  done
  fail "  有 DataNode 未在 ${REPLAY_WIN}s 内回到 Running"
  return 1; }
# 失败时的逐副本证据（WAL 目录清单 + 日志尾部 20 行 + show cluster）
w04_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(w04_dn_state_any "$h") 进程：$(sshx "$h" "pgrep -af com.timecho.iotdb.DataNode | head -2" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-160)"
    log "  [$h] WAL 根目录：$(wal_dir_roots "$h" | tr '\n' ' ')"
    log "  [$h] identifier 目录（本库）：$(w04_ident_dirs "$h" | tr '\n' ' ')"
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
# 主流程
# ===========================================================================
log "=== W-04 掉电恢复：库=$DB 规模=${DEVS}设备×${ROWS}点×${BATCHES}批（期望 count=$(w04_exp_count) sum=$(w04_exp_sum)）==="
log "  参数：wal_mode=${WAL_MODE} compression=${WAL_COMPRESSION} kill 前等待=${WAIT}s 等重放=${REPLAY_WIN}s"
log "  WAL 参数组合：$W04_EXTRA"

log "--- ① 集群准备（清集群 → 写 WAL 参数 → 启动；写入期关三类合并，避免合并把 WAL 变无效干扰观测）---"
EXTRA_CONF="$W04_EXTRA" cmp_cluster_prepare
log "  合并参数生效值（抽查）：$(cmp_eff_all "${DN[0]}")"
WM=$(cmp_eff "${DN[0]}" wal_mode)
if [ -z "${WM:-}" ]; then WM=$(wal_props_get "${DN[0]}" wal_mode); log "  show configuration 无 wal_mode ⇒ 用配置文件值：${WM:-（空）}"; fi
case "${WM:-}" in
  DISABLE) fail "  wal_mode 为 DISABLE（WAL 未开启，本用例的 WAL 重放场景不成立）" ;;
  "")      warn "  无法读取生效 wal_mode（show configuration 与 properties 都为空）⇒ 记录，继续" ;;
  *)       pass "  生效 wal_mode=$WM（WAL 开启，具备重放语义）" ;;
esac
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done

log "--- ② 造库 + 建序列（${DEVS} 个设备，单序列 s1 INT64）---"
cmp_make_tree_db "$DB" "$DEVS"

log "--- ③ **不 flush** 写入（数据只落在 MemTable + WAL 上；本轮绝不 flush/ensure_closed）---"
T_WRITE0=$(date +%s)
if w04_write_nf; then pass "  写入完成（${DEVS}×${ROWS}×${BATCHES} 点，耗时 $(( $(date +%s) - T_WRITE0 ))s）"; else fail "  写入失败"; fi

log "--- ④ 场景有效性：当前可见性（scalar，可见性来自 MemTable+WAL）+ 总数/总和离线核算 ---"
wait_scalar_tree "select count(s1) from $DB.d1;" "$(( ROWS * BATCHES ))" 90 "写入后可见性（$DB.d1 设备路径）"
C0=$(row_sum "$(sq "select count(s1) from $DB.**;")")
S0=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
assert_eq "  场景有效性：写入后总点数（DEVS×ROWS×BATCHES）" "${C0:-0}" "$(w04_exp_count)"
assert_eq "  场景有效性：写入后值总和（可离线核算）" "${S0:-0}" "$(w04_exp_sum)"

log "--- ⑤ 场景有效性：WAL 必须非空（本库 identifier 口径优先，回退整目录口径）---"
for h in "${DN[@]}"; do log "  [$h] 本库 WAL 目录：$(w04_ident_dirs "$h" | tr '\n' ' ')"; done
w04_wal_report "写入后"
DBF0=$(w04_db_sum w04_db_files); ALLF0=$(wal_sum_over_dn wal_file_cnt)
if [ "${DBF0:-0}" -gt 0 ]; then
  pass "  场景有效性：本库 WAL 文件数=$DBF0（>0，数据确实只在 WAL+MemTable 上）"
elif [ "${ALLF0:-0}" -gt 0 ]; then
  warn "  本库 identifier 目录下未找到 WAL（回退整目录口径：$ALLF0 个）⇒ 场景仍成立，但库级隔离口径不可用（记录）"
else
  fail "  场景无效：写入没有产生 WAL（本库=$DBF0，整目录=$ALLF0）——WAL 重放无从验证"
fi
MAGIC=$(wal_sum_over_dn wal_magic_cnt); log "  WAL 文件尾魔数 WAL-V2 命中：$MAGIC 个（确认这些确实是 WAL 文件）"

log "--- ⑥ 等 ${WAIT}s：ASYNC 下写入返回≠已 fsync，等异步 fsync 周期把 WAL 落到盘上（否则丢的是文档允许的缓冲窗口）---"
w04_wal_report "等待前"
sleep "$WAIT"
w04_wal_report "等待后"
DBF1=$(w04_db_sum w04_db_files); ALLF1=$(wal_sum_over_dn wal_file_cnt)
if [ "${DBF1:-0}" -gt 0 ] || [ "${ALLF1:-0}" -gt 0 ]; then
  pass "  场景有效性：等待后 WAL 仍非空（本库=$DBF1 整目录=$ALLF1）"
else
  fail "  场景无效：等待后 WAL 为空（本库=$DBF1 整目录=$ALLF1）——数据可能已自行落盘，重放路径未被走到"
fi

log "--- ⑦ 记录 kill 前指纹（总 count/sum/min/max + 每设备 4 聚合 + d1 全序列 md5/行数）---"
w04_fp_dump "$DB" "$ART/fp_pre.txt"

log "--- ⑧ 掉电注入：kill -9 全部 DataNode ---"
w04_kill_all

log "--- ⑨ 拉起 + 等全部 DN Running ---"
if w04_start_all; then w04_wait_running || w04_evidence "重启后 DN 未 Running"; else w04_evidence "DN 进程未启动"; fi
sq 'show cluster;' >>"$OUT" 2>&1

log "--- ⑩ 等 WAL 重放 + 等数据可见（恢复完成没有任何日志/指标信号 ⇒ 只能轮询查询）---"
wal_wait_replay "$DB" "$EVID_WIN"
wait_scalar_tree "select count(s1) from $DB.d1;" "$(( ROWS * BATCHES ))" "$REPLAY_WIN" "重启后可见性（$DB.d1 设备路径，等重放）"
w04_wait_total "重启后总点数（等重放）" "select count(s1) from $DB.**;" "$(w04_exp_count)" "$REPLAY_WIN"

log "--- ⑪ 数据面硬断言：指纹逐项相等（任何缺失/多余都 fail）---"
w04_fp_dump "$DB" "$ART/fp_post.txt"
w04_fp_compare "掉电重启后" "$ART/fp_pre.txt" "$ART/fp_post.txt"
R_POST=$(grep -m1 '^d1_seq_rows=' "$ART/fp_post.txt" | cut -d= -f2)
assert_eq "  重启后 d1 全序列的数据行数（逐条数据行）" "${R_POST:-0}" "$(( ROWS * BATCHES ))"
S_POST=$(grep -m1 '^total_sum=' "$ART/fp_post.txt" | cut -d= -f2)
assert_eq "  重启后值总和（离线核算值）" "${S_POST:-0}" "$(w04_exp_sum)"

log "--- ⑫ WAL 消费证据（**只作证据，不作为通过条件**）---"
w04_wal_report "重启后"
DBF2=$(w04_db_sum w04_db_files); ALLF2=$(wal_sum_over_dn wal_file_cnt)
if [ "${DBF2:-0}" -lt "${DBF1:-0}" ] || [ "${ALLF2:-0}" -lt "${ALLF1:-0}" ]; then
  pass "  WAL 被消费（本库 $DBF1→$DBF2，整目录 $ALLF1→$ALLF2；恢复末步会删除 WALNode 下的文件）"
else
  warn "  WAL 文件数未下降（本库 $DBF1→$DBF2，整目录 $ALLF1→$ALLF2）——恢复后可能已重刷盘（design_extract §4.3），仅记录"
fi
OOM=$(wal_oom_cnt); assert_eq "  WAL 相关 OOM 日志行数（必须 0）" "${OOM:-0}" "0"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w04_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 专属异常正则已安装）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|Connection reset by peer|Connection refused'
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
