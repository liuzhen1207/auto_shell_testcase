#!/bin/bash
# ============================================================================
# W-12 **压缩态掉电恢复**：`enable_wal_compression=true` + 未 flush 写入 → kill -9 全部 DataNode → 重启 → 数据完整
#
# 一句话：压缩开启下写入（不 flush）→ 整机三个 DataNode 全部 SIGKILL → 重启 → 数据必须一条不少
#   （恢复走"先试解压、失败按未压缩读"的读取路径）；场景有效性：kill 前 WAL 文件存在，
#   且**压缩态体积小于未压缩基线**（基线用同规模数据在 `enable_wal_compression=false` 相采一次）。
#
# ---------------------------------------------------------------------------
# 【需求依据】
#   · feature_extract.md A（WAL 压缩）：A.2 参数 `ENABLE_WAL_COMPRESSION` 默认 **true**、**允许热加载**；
#     压缩粒度 = **每个 WALBuffer 在刷盘前压缩**（"一个 WAL 文件中可能就包含多个段，每个段都是压缩和解压缩的基本单位"），
#     算法 **LZ4**；A.5 兼容性：**WAL 内容里没有版本号标识** ⇒ 恢复时必须"先尝试解压缩，失败再按未压缩的方式读"。
#   · source_grounding.md：压缩单元 = **一次 sync 批次的 buffer 段**、**段 < 32KB 不压**、每段头 1 字节 compressionType；
#     正面证据可用 `wal_buffer{name="wal_compress_cost"}`（写入侧）/ `wal_uncompress_cost`（恢复读取侧）；
#     WAL 目录/文件名 = `<dn_wal_dirs>/<identifier>/_<versionId>-<startSearchIndex>-<statusCode>.wal`
#     （IoTConsensus 下 identifier = `<database>-<regionId>`）⇒ 用它做**库级**隔离；
#     权威指标 file_count{name="wal"} / file_size{name="wal"}。
#   · design_extract.md §4.3（恢复流程：读 checkpoint → 重放 WAL → 删除 WALNode 下的文件）、
#     §4.4（"恢复完成没有任何日志/指标信号" ⇒ 只能轮询查询）、§7.1-15（`enable_wal_compression` 标"热加载"）。
#
# 【⚠️ 关键口径修正：段 < 32KB 不压缩 ⇒ "体积更小"不是无条件成立的】
#   LZ4 的压缩单位是"一次 sync 批次的 buffer 段"，**小于 32KB 的段不压**。所以：
#   · 本用例刻意把写入做成**大语句**（每个设备每批一条 INSERT，行数由 W12_ROWS 控制，默认 2000 行 ⇒
#     单段远大于 32KB 的阈值量级），这样才能出现"压缩态更小"；
#   · 万一实测"体积基本不变"，那说明单段低于压缩阈值/数据不可压 ⇒ 用例判
#     `warn "场景未成立（低于压缩阈值）"`，**不判 FAIL**（不得把"没压到"当成产品缺陷）；
#   · 现场可调：把 W12_ROWS 调大（例如 8000）再跑一次，让单段体积上去。
#
# 【双相设计（同一次集群准备，两次写同一规模数据）】
#   相 NC（基线，未压缩）：`enable_wal_compression=false` 启动 → 写库 `root.walcmp9b`（不 flush）→
#                          等异步 fsync → 量 WAL 增量（字节/文件数）⇒ 未压缩基线。
#   相 C （压缩态）      ：`SET CONFIGURATION 'enable_wal_compression'='true'`（源码印证：**hot_reload**，
#                          不必重启；用例仍会核对返回文案与生效值，必要时才补一次 stop/start）→
#                          DROP 基线库并等 WAL 观测量稳定（避免基线库的 WAL 变化污染增量）→
#                          写库 `root.walcmp9`（不 flush）→ 等异步 fsync → 量 WAL 增量 ⇒ 与基线比。
#   之后：kill -9 **全部** DataNode → 重启 → 等 Running/等重放 → 数据面指纹逐项比对（硬判据）。
#   两相数据规模完全相同（同一个 DEVS×ROWS×BATCHES、同样的值/时间戳公式）⇒ 两个增量可比。
#
# 【判据结构（硬/软分明）】
#   ① 场景有效性（硬）：写入后数据可见且 count/sum 与离线核算一致（两相都要）；压缩相 kill 前 WAL **文件数 > 0**；
#      三个 DN 全部真的被 kill -9（进程消失）；重启后都 Running；`enable_wal_compression` 已生效（记录/核对）。
#   ② 数据面（硬）：压缩相 kill 前指纹 vs 重启后指纹逐项相等（总 count/sum/min/max + 每设备 4 聚合 +
#      单设备全序列 md5/行数）；任何缺失/多余都 fail。
#   ③ 过程证据（软）：压缩态 vs 未压缩态的 WAL 增量对照、`wal_compress_cost` / `wal_uncompress_cost` 指标、
#      目录/指标两组 WAL 口径、重启后 WAL 是否被消费、日志里恢复相关行数。
#
# 【刻意不做的事】
#   · 恢复相**绝不 flush / 绝不 ensure_closed**（会提前落盘，让"WAL 重放"失去意义）；只在写入后用 scalar 确认可见。
#   · 不把"压缩态体积未变小"判为 FAIL（见上：可能是段低于 32KB 阈值）。
#   · 不断言 `WALNode.java:466-470` 的"删除过期 WAL 条数"文案（DEBUG 级、默认不落盘）。
#   · 不改 lib/、tools/、conf/、cases.tsv、docs/（只新增本文件）。
#
# 【时长大致】≈25~30 分钟（集群准备 ~4min + 未压缩相 ~6min + 切换/稳定 ~2min + 压缩写入 ~5min
#   + 掉电/拉起/等重放 ~6min + 收尾三件套 ~4min）。可调：W12_DEVS/W12_ROWS/W12_BATCHES/W12_WAIT_SEC。
#
# 【⚠️ 首轮 watch list（先看这些才知道"场景真的成立了"）】
#   1) **未压缩相与压缩相的 WAL 增量**：压缩态是否更小、比例多少；同时看 `wal_compress_cost` 是否 >0。
#      若压缩态没更小 → 用例只 WARN，首轮记录"单批段体积/写入条数"，据此决定是否把 W12_ROWS 调大重跑。
#   2) **`enable_wal_compression` 的生效证据**：`show configuration` 可能不暴露该键（用例会回退读 properties），
#      以及 `SET CONFIGURATION` 的返回文案是否是"restart is required"（源码印证是 hot_reload，
#      若实测返回需要重启 ⇒ 用例会自动补一次 stop/start 并记录，这一条要重点核对）。
#   3) **DROP 基线库后 WAL 是否真的清理干净**（增量测量的前提）：看"压缩相写前基线"快照是否归零/稳定；
#      若不降，增量会被残余污染，需在产物里按库级口径重算。
#   4) **恢复路径是否走了"先试解压"**：文档/源码无日志关键字可断言，只能用 `wal_uncompress_cost` 指标
#      + 数据完整性间接证明；首轮看该指标在重启后是否有增量。
#   5) **全部 DN 掉电后能否重新拉起**（同 W-04）：CN 在跑，DN 重新加入要过注册/选主；失败时用例打印逐副本证据。
#
# 用法： bash cases/common/wal_compress_recovery.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 本文件**未在真实集群实跑过**（99.80 正在跑长回归，禁止任何集群动作）；只保证逻辑自洽 + 静态检查通过。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_compress_recovery_${DATA_CONSENSUS}"

# 环境兜底：conf/env.conf 未定义这三个 TTL 键，而 lib/common.sh 的 cluster_set_conf 会引用它们（set -u 下会中断准备）
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"

DB=root.walcmp9                     # 压缩态（本用例主角）
DBNC=root.walcmp9b                  # 未压缩基线（为体积对照采一次同规模数据；库名仍在 root.wal* 约定内）
DEVS=${W12_DEVS:-$WAL_COMPRESS_DEVS}
ROWS=${W12_ROWS:-$WAL_COMPRESS_ROWS}          # 同时是每条 INSERT 的行数（大语句 ⇒ 单段体积 > 32KB 阈值量级）
BATCHES=${W12_BATCHES:-$WAL_COMPRESS_BATCHES}
WAIT=${W12_WAIT_SEC:-${WAL_KILL_WAIT_SEC:-60}}
STABLE_WIN=${W12_STABLE_WIN_SEC:-90}
REPLAY_WIN=${W12_REPLAY_WIN_SEC:-${WAL_REPLAY_WIN_SEC:-300}}
EVID_WIN=${W12_EVID_WIN_SEC:-60}
START_WIN=${W12_START_WIN_SEC:-300}
RATIO_MIN=${WAL_COMPRESS_RATIO_MIN:-1.2}       # 压缩后至少应缩小到这个倍数（低于此只 WARN，不当门禁）
BASE_TS=$(( ($(date +%s) - 3600) * 1000 ))
BASE_TS_NC=$(( BASE_TS - 5000000 ))            # 基线相用更早的时间戳区间（两相互不干扰，便于比对时区分）

W12_EXTRA_NC="wal_mode=${WAL_MODE},enable_wal_compression=false,wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_FILE_THRESHOLD_BYTES},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 写入（**不 flush**；大语句）-----------------------------------------
# 值/时间戳确定：设备 d 第 b 批第 k 行 ⇒ 值 = k + b，ts = base + b*1000000 + k*10
# 每个设备每批**一条** INSERT（ROWS 行）⇒ 单条 WAL Entry 体积 ≈ ROWS×16B，明显大于"段 < 32KB 不压"的阈值量级
w12_write_nf(){ local db=$1 base=$2 d b k vals ts
  local -a S=()
  for (( b=1; b<=BATCHES; b++ )); do
    for (( d=1; d<=DEVS; d++ )); do
      vals=""
      for (( k=0; k<ROWS; k++ )); do
        ts=$(( base + b * 1000000 + k * 10 ))
        vals="$vals($ts,$(( k + b ))),"
      done
      S=("insert into $db.d$d(time,s1) values ${vals%,};")
      # 单会话 stdin 喂语句（一条 INSERT 可能上百 KB，走 stdin 避免超长命令行）
      printf '%s\n' "${S[@]}" | session_tree >/dev/null || return 1
    done
  done
  return 0
}
w12_exp_count(){ echo $(( DEVS * ROWS * BATCHES )); }
w12_exp_sum(){ local b s=0
  for (( b=1; b<=BATCHES; b++ )); do s=$(( s + ROWS * (ROWS - 1) / 2 + ROWS * b )); done
  echo $(( DEVS * s )); }

# ---- ② 指纹（压缩相用：数据必须完整）--------------------------------------
# 单设备四项一律走 lib/wal_ext.sh 的 `wal_dev_fp4`（RC8 第二轮修，见 wal_ext.sh ⑬）：
#   · **一条查询只放一个聚合**（混查 `count/sum/min/max` 报 701 hybrid query）；
#   · 只查**设备路径** `db.dN`（序列路径 `db.dN.s1` 在本版本落到空结果 ⇒ 曾经静默输出
#     `dev_dN=count= sum= min= max=`）；
#   · `min`/`max` 不是本版本内建名（要写 `min_value`/`max_value`），取不到值写 `ERR`。
w12_dev_agg(){ wal_dev_fp4 "$1"; }
w12_q_sum(){ local sql=$1 out
  out=$(sq "$sql")
  if printf '%s\n' "$out" | grep -qE 'Exception'; then printf 'ERR'; return 1; fi
  printf '%s' "$(row_sum "$out")"; }
w12_fp_dump(){ local db=$1 f=$2 i
  : >"$f"
  printf 'total_count=%s\n'   "$(w12_q_sum "select count(s1) from $db.**;")" >>"$f"
  printf 'total_sum=%s\n'     "$(w12_q_sum "select sum(s1) from $db.**;")"   >>"$f"
  # min/max 汇总**逐设备**取值再在本地相加（`select min(s1) from <db>.**` 在本版本 701
  # `Error occurred during inferring UDF data type` ⇒ 指纹曾经是 `total_min_sum=ERR`）
  printf 'total_min_sum=%s\n' "$(wal_dev_sum_of min "$db" "$DEVS")"          >>"$f"
  printf 'total_max_sum=%s\n' "$(wal_dev_sum_of max "$db" "$DEVS")"          >>"$f"
  for (( i=1; i<=DEVS; i++ )); do printf 'dev_d%s=%s\n' "$i" "$(w12_dev_agg "$db.d$i")" >>"$f"; done
  # d1 全序列：md5 前先 `data_rows`（丢表头与 `It costs …` 统计行），判据仍是"两相必须相等"
  wal_seq_fp "$db" >>"$f"
  log "  指纹已落盘：$f（$(grep -c . "$f") 项）"
  sed 's/^/      /' "$f" >>"$OUT"
  grep -q '=ERR' "$f" && fail "  指纹查询报错（见上面 =ERR 的项）——先确认查询语法/通配聚合是否被该版本支持" ; }
w12_fp_compare(){ local label=$1 f0=$2 f1=$3 res same total
  res=$(awk 'NR==FNR{a[FNR]=$0; n=FNR; next}{ if($0==a[FNR]){c++} else {printf "  DIFF 第%d项: [%s] -> [%s]\n", FNR, a[FNR], $0} } END{printf "SAME=%d TOTAL=%d LINES2=%d\n", c+0, n+0, FNR}' "$f0" "$f1")
  same=$(printf '%s\n' "$res" | grep -oE 'SAME=[0-9]+' | cut -d= -f2)
  total=$(printf '%s\n' "$res" | grep -oE 'TOTAL=[0-9]+' | cut -d= -f2)
  log "  指纹逐项比对（$label）：一致 ${same:-0} / 共 ${total:-0} 项"
  awk 'NR==FNR{a[FNR]=$0; next}{ printf "      [%s] %s -> %s\n", ($0==a[FNR] ? "一致" : "不一致"), a[FNR], $0 }' "$f0" "$f1" >>"$OUT"
  printf '%s\n' "$res" | grep 'DIFF' | sed 's/^/      /' >>"$OUT"
  assert_eq "  指纹逐项一致项数（$label）" "${same:-0}" "${total:-0}"
  assert_eq "  重启后指纹项数（缺失/多余都不允许，$label）" "$(grep -c . "$f1")" "$(grep -c . "$f0")"; }
w12_wait_total(){ local label=$1 sql=$2 want=$3 win=$4 dl got
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(row_sum "$(sq "$sql")")
    [ "${got:-0}" = "$want" ] && { pass "  $label: $got"; return 0; }
    log "    等 $label: 实际=${got:-?} 期望=$want（$(date '+%T')）"
    sleep 5
  done
  fail "  $label: 实际=${got:-?} 期望=$want（等 ${win}s 仍不一致）"
  return 1; }

# ---- ③ WAL 面（库级隔离 + 指标口径 + 压缩正证据）---------------------------
w12_ident_dirs(){ local h=$1 db=$2
  sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 2 -type d -name '$db-*' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w12_db_files(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$db-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w12_db_bytes(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$db-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w12_cnt(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h" "$W12_DB") )); done; echo "$s"; }
w12_per_node(){ local h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(w12_db_files "$h" "$W12_DB")f/$(w12_db_bytes "$h" "$W12_DB")B "; done; echo "$out"; }
# 压缩正证据：wal_buffer{name="wal_compress_cost"} / wal_uncompress_cost（跨 DN 求和 + 逐副本）
#   ⚠️ 这里曾写成 `wal_metric_sum_over_dn wal_metric_buffer_c`，而 **`wal_metric_buffer_c` 这个函数
#      根本不存在**（lib/wal_ext.sh 里只有带 2 个参数的 `wal_metric_buffer <h> <name>`；真正的
#      单参包装是下面的 `w12_metric_buffer_c`）⇒ 运行期报
#        `lib/wal_ext.sh: line 293: wal_metric_buffer_c: command not found`
#        `lib/wal_ext.sh: line 293: s +  : syntax error: operand expected`
#      结果 `wal_compress_cost` 恒为空、压缩正证据恒显示"读不到或为 0"（RC8 首轮 W-12 实际输出）。
#   ⚠️ 另外 `wal_metric_sum_over_dn` 用 `$(( ))` 做**整数**求和，而这里的指标值是 Prometheus
#      浮点（可能是 `12.5`）⇒ 用 awk 做浮点安全求和（与 w15_rv / w11_sum_metric 同口径），
#      整数值仍按整数输出，便于与字符串断言比较。
w12_sum_metric(){ local f=$1 h out=""
  for h in "${DN[@]}"; do out="$out$($f "$h")
"; done
  printf '%s' "$out" | awk '{ s += ($1 + 0) } END{ if (s == int(s)) printf "%d", s; else printf "%.6f", s }'; }
w12_compress_cost(){ w12_sum_metric w12_metric_buffer_c; }
w12_metric_buffer_c(){ local h=$1; wal_metric_buffer "$h" wal_compress_cost; }
w12_uncompress_cost(){ w12_sum_metric w12_metric_buffer_u; }
w12_metric_buffer_u(){ local h=$1; wal_metric_buffer "$h" wal_uncompress_cost; }
w12_snap(){ local tag=$1 dbf dbb alf alb cc uc
  dbf=$(w12_cnt w12_db_files); dbb=$(w12_cnt w12_db_bytes)
  alf=$(wal_sum_over_dn wal_file_cnt); alb=$(wal_sum_over_dn wal_dir_bytes)
  cc=$(w12_compress_cost); uc=$(w12_uncompress_cost)
  if [ -n "$(w12_ident_dirs "${DN[0]}" "$W12_DB")" ]; then W12_SCOPE=db; else W12_SCOPE=all; fi
  if [ "$W12_SCOPE" = db ]; then W12_FILES=$dbf; W12_BYTES=$dbb; else W12_FILES=$alf; W12_BYTES=$alb; fi
  log "  [WAL 快照/$tag] 口径=$W12_SCOPE files=$W12_FILES bytes=$W12_BYTES（本库 ${dbf}f/${dbb}B；整目录 ${alf}f/${alb}B；逐副本 $(w12_per_node)）"
  log "  [WAL 指标/$tag] file_count{wal}=$(wal_metric_sum_over_dn wal_metric_file_cnt) file_size{wal}=$(wal_metric_sum_over_dn wal_metric_file_bytes) wal_compress_cost=$cc wal_uncompress_cost=$uc"; }
w12_wait_stable(){ local label=$1 dl f0="" b0="" f b n=0
  dl=$(( $(date +%s) + STABLE_WIN ))
  while (( $(date +%s) < dl )); do
    w12_snap "$label/稳定采样"
    f=$W12_FILES; b=$W12_BYTES
    if [ "$f" = "$f0" ] && [ "$b" = "$b0" ]; then
      n=$(( n + 1 )); [ "$n" -ge 2 ] && { log "  [$label] WAL 观测已稳定（files=$f bytes=$b）"; return 0; }
    else
      n=0
    fi
    f0=$f; b0=$b
    sleep 5
  done
  warn "  [$label] WAL 观测在 ${STABLE_WIN}s 内未稳定（files=$f bytes=$b）——继续，对照数值仅供记录"; return 0; }

# ---- ④ 掉电 / 拉起 ---------------------------------------------------------
w12_kill_all(){ local h n=0 gone=0 pid pids=""
  log "--- 掉电注入：逐个 kill -9 **全部** DataNode（压缩态数据只可能在 WAL 里）---"
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
w12_fire_dn(){ local h=$1
  log "  启动 DataNode @ $h"
  sshx "$h" "cd $DB_DIR && nohup ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" || warn "  启动 $h 失败"; }
w12_proc_up(){ local h=$1
  [ -n "$(wal_dn_pid "$h")" ]; }
w12_dn_state_any(){ local want=$1 h out st
  for h in "${DN[@]}"; do
    out=$(sq_node "$h" 'show cluster;' 2>/dev/null)
    st=$(printf '%s\n' "$out" | awk -F'|' -v ip="$want" '{gsub(/[ \t]/,"",$3);gsub(/[ \t]/,"",$4);gsub(/[ \t]/,"",$5)} $3=="DataNode" && $5==ip {print $4; exit}')
    [ -n "${st:-}" ] && { printf '%s' "$st"; return 0; }
  done
  printf ''; return 1; }
w12_start_all(){ local h n dl
  log "--- 拉起全部 DataNode（先全部点火，再等进程；全部 DN 掉电时 CLI 直连 DN，逐个等会空转到超时）---"
  for h in "${DN[@]}"; do w12_fire_dn "$h"; done
  dl=$(( $(date +%s) + START_WIN ))
  while (( $(date +%s) < dl )); do
    n=0; for h in "${DN[@]}"; do w12_proc_up "$h" && n=$(( n + 1 )); done
    log "  DataNode 进程数：$n/${#DN[@]}"
    [ "$n" -ge "${#DN[@]}" ] && { pass "  三个 DataNode 进程都已启动"; return 0; }
    sleep 5
  done
  fail "  有 DataNode 进程未在 ${START_WIN}s 内启动"
  return 1; }
w12_wait_running(){ local h n dl st
  dl=$(( $(date +%s) + REPLAY_WIN ))
  while (( $(date +%s) < dl )); do
    n=0
    for h in "${DN[@]}"; do st=$(w12_dn_state_any "$h"); [ "$st" = "Running" ] && n=$(( n + 1 )); done
    log "  重启后 DataNode Running 计数：$n/${#DN[@]}"
    [ "$n" -ge "${#DN[@]}" ] && { pass "  三个 DataNode 都已 Running（重启完成）"; return 0; }
    sleep 5
  done
  fail "  有 DataNode 未在 ${REPLAY_WIN}s 内回到 Running"
  return 1; }
w12_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(w12_dn_state_any "$h") 进程：$(sshx "$h" "pgrep -af com.timecho.iotdb.DataNode | head -2" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-160)"
    log "  [$h] WAL 根目录：$(wal_dir_roots "$h" | tr '\n' ' ')；identifier 目录：$(w12_ident_dirs "$h" "$DB" | tr '\n' ' ')"
    log "  [$h] 压缩态库 TsFile 数：$(cmp_seq_cnt "$h" "$DB"):$(cmp_unseq_cnt "$h" "$DB")"
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
log "=== W-12 压缩态掉电恢复：压缩库=$DB 基线库=$DBNC 规模=${DEVS}设备×${ROWS}点×${BATCHES}批 ==="
log "  期望 count=$(w12_exp_count) sum=$(w12_exp_sum)（两相相同 ⇒ WAL 增量可比）；每条 INSERT $ROWS 行（大语句，撑起单段体积）"
log "  未压缩相参数：$W12_EXTRA_NC"

log "--- ① 集群准备（先以 enable_wal_compression=false 起步，采未压缩基线）---"
EXTRA_CONF="$W12_EXTRA_NC" cmp_cluster_prepare
log "  合并参数生效值（抽查）：$(cmp_eff_all "${DN[0]}")"
CMP_NC=$(cmp_eff "${DN[0]}" enable_wal_compression); [ -z "${CMP_NC:-}" ] && CMP_NC=$(wal_props_get "${DN[0]}" enable_wal_compression)
log "  当前 enable_wal_compression（生效值/配置值）=${CMP_NC:-（读不到）}"
[ "${CMP_NC:-false}" = "false" ] && pass "  未压缩相就绪：enable_wal_compression=false" \
  || warn "  未压缩相配置读到 '${CMP_NC:-空}'（不是 false）⇒ 基线可能不是未压缩，记录（不影响后续压缩相的数据完整性判据）"
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done

log "--- ② 相 NC（未压缩基线）：不 flush 写入 $DBNC ---"
W12_DB="$DBNC"
w12_snap "NC/写前基线"
NC_BF=$W12_FILES; NC_BB=$W12_BYTES
cmp_make_tree_db "$DBNC" "$DEVS"
if w12_write_nf "$DBNC" "$BASE_TS_NC"; then pass "  [NC] 写入完成"; else fail "  [NC] 写入失败"; fi
wait_scalar_tree "select count(s1) from $DBNC.d1;" "$(( ROWS * BATCHES ))" 120 "[NC] 写入后可见性（$DBNC.d1 设备路径）"
assert_eq "  [NC] 写入后总点数（基线可比性）" "$(row_sum "$(sq "select count(s1) from $DBNC.**;")")" "$(w12_exp_count)"
assert_eq "  [NC] 写入后值总和（基线可比性）" "$(row_sum "$(sq "select sum(s1) from $DBNC.**;")")" "$(w12_exp_sum)"
log "  等 ${WAIT}s 让 ASYNC 的 fsync 周期把 WAL 落到盘上（两相都等同样时长 ⇒ 对照公平）"
sleep "$WAIT"
w12_wait_stable "NC"
NC_AF=$W12_FILES; NC_AB=$W12_BYTES
NC_DF=$(( NC_AF - NC_BF )); NC_DB=$(( NC_AB - NC_BB ))
log "  [NC] **未压缩基线**：增量=${NC_DF}f/${NC_DB}B（kill 前绝对=${NC_AF}f/${NC_AB}B）"
[ "${NC_AF:-0}" -gt 0 ] && pass "  场景有效性：[NC] WAL 非空（files=$NC_AF）" || fail "  场景无效：[NC] WAL 为空 ⇒ 基线不可比"

log "--- ③ 切换到 enable_wal_compression=true（源码印证：hot_reload，不必重启；用例仍核对生效值）---"
RESP=$(wal_set enable_wal_compression true)
log "  SET CONFIGURATION 'enable_wal_compression'='true' → $(printf '%s' "$RESP" | cut -c1-200)"
case "$RESP" in
  *"restart is required"*|*"Restart is required"*) NEED_RESTART=1 ;;
  *) NEED_RESTART=0 ;;
esac
CMP_C=$(cmp_eff "${DN[0]}" enable_wal_compression); [ -z "${CMP_C:-}" ] && CMP_C=$(wal_props_get "${DN[0]}" enable_wal_compression)
if [ "${CMP_C:-}" = "true" ] && [ "$NEED_RESTART" = 0 ]; then
  pass "  压缩已生效（hot_reload，无需重启；生效值=true）"
else
  warn "  热改未直接生效（生效值='${CMP_C:-空}'，返回文案要求重启=$NEED_RESTART）⇒ 补一次 stop/start 让配置生效（不清 data）"
  cluster_stop; cluster_start
  CMP_C=$(cmp_eff "${DN[0]}" enable_wal_compression); [ -z "${CMP_C:-}" ] && CMP_C=$(wal_props_get "${DN[0]}" enable_wal_compression)
  if [ "${CMP_C:-}" = "true" ]; then pass "  重启后 enable_wal_compression=true 生效"; else warn "  重启后仍读不到 enable_wal_compression=true（生效值='${CMP_C:-空}'）⇒ 记录：若体积也没变小则场景未成立"; fi
fi

log "--- ④ 清掉基线库并等 WAL 观测量稳定（避免基线库的 WAL 变化污染压缩相增量）---"
sq "drop database $DBNC;" >/dev/null 2>&1 || warn "  DROP $DBNC 非 0（记录；仅影响对照精度）"
W12_DB="$DB"     # 之后所有快照都看压缩相
sleep 10
w12_wait_stable "C/写前基线"
C_BF=$W12_FILES; C_BB=$W12_BYTES
log "  [C] 压缩相写前基线：files=$C_BF bytes=$C_BB"

log "--- ⑤ 相 C（压缩态）：**不 flush** 写入 $DB（数据只落在 MemTable + WAL）---"
cmp_make_tree_db "$DB" "$DEVS"
if w12_write_nf "$DB" "$BASE_TS"; then pass "  [C] 写入完成"; else fail "  [C] 写入失败"; fi
wait_scalar_tree "select count(s1) from $DB.d1;" "$(( ROWS * BATCHES ))" 120 "[C] 写入后可见性（scalar，$DB.d1 设备路径；可见性来自 MemTable+WAL）"
C0=$(row_sum "$(sq "select count(s1) from $DB.**;")"); S0=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
assert_eq "  [C] 写入后总点数（DEVS×ROWS×BATCHES）" "${C0:-0}" "$(w12_exp_count)"
assert_eq "  [C] 写入后值总和（可离线核算）" "${S0:-0}" "$(w12_exp_sum)"
log "  等 ${WAIT}s 让 ASYNC 的 fsync 周期把 WAL 落到盘上（与 NC 相同口径）"
sleep "$WAIT"
w12_wait_stable "C/kill前"
C_AF=$W12_FILES; C_AB=$W12_BYTES
C_DF=$(( C_AF - C_BF )); C_DB=$(( C_AB - C_BB ))
log "  [C] **压缩态**：增量=${C_DF}f/${C_DB}B（kill 前绝对=${C_AF}f/${C_AB}B）"

log "--- ⑥ 场景有效性 + 压缩对照（**软判据**：段 < 32KB 不压 ⇒ 体积不变不代表缺陷）---"
if [ "${C_AF:-0}" -gt 0 ] || [ "${C_AB:-0}" -gt 0 ]; then
  pass "  场景有效性：[C] kill 前 WAL 存在（files=$C_AF bytes=$C_AB）"
else
  fail "  场景无效：[C] kill 前 WAL 为空（files=$C_AF bytes=$C_AB）——没有可重放/可解压的内容"
fi
CC_COST=$(w12_compress_cost); UC_COST=$(w12_uncompress_cost)
log "  压缩指标（跨 DN）：wal_compress_cost=$CC_COST wal_uncompress_cost=$UC_COST（逐副本：$(wal_metric_per_node w12_metric_buffer_c)）"
[ "${CC_COST:-0}" -gt 0 ] && pass "  正面证据：wal_buffer{name=wal_compress_cost}=$CC_COST（>0 ⇒ 压缩确实在跑）" \
  || warn "  wal_buffer{name=wal_compress_cost}=$CC_COST（读不到或为 0）⇒ 该指标仅作佐证，不判 FAIL"
log "  WAL 体积对照：未压缩基线=${NC_DB}B/${NC_DF}f vs 压缩态=${C_DB}B/${C_DF}f"
if [ "${C_DB:-0}" -lt "${NC_DB:-0}" ]; then
  RATIO_TXT=$(( NC_DB / (C_DB > 0 ? C_DB : 1) ))
  pass "  对照成立：压缩态更小（未压缩 ${NC_DB}B → 压缩态 ${C_DB}B，约 ${RATIO_TXT}x；阈值参考 ${RATIO_MIN}x，低于阈值只作记录）"
else
  warn "  场景未成立（低于压缩阈值）：压缩态体积没有变小（未压缩=${NC_DB}B/${NC_DF}f 压缩态=${C_DB}B/${C_DF}f）——源码口径为 LZ4 且**段 < 32KB 不压**，数据量偏小时体积基本不变属预期 ⇒ 只 WARN，不判 FAIL；可把 W12_ROWS 调大（如 8000）重跑"
fi

log "--- ⑦ 记录 kill 前指纹（压缩态数据必须完整恢复）---"
w12_fp_dump "$DB" "$ART/fp_pre.txt"

log "--- ⑧ 掉电：kill -9 全部 DataNode → 拉起 → 等 Running ---"
w12_kill_all
if w12_start_all; then w12_wait_running || w12_evidence "重启后 DN 未 Running"; else w12_evidence "DN 进程未启动"; fi
sq 'show cluster;' >>"$OUT" 2>&1

log "--- ⑨ 等 WAL 重放 + 等数据可见（压缩态恢复走先试解压、失败按未压缩读的路径；无日志信号 ⇒ 只能轮询查询）---"
wal_wait_replay "$DB" "$EVID_WIN"
wait_scalar_tree "select count(s1) from $DB.d1;" "$(( ROWS * BATCHES ))" "$REPLAY_WIN" "[C] 重启后可见性（$DB.d1 设备路径）"
w12_wait_total "[C] 重启后总点数" "select count(s1) from $DB.**;" "$(w12_exp_count)" "$REPLAY_WIN"

log "--- ⑩ 数据面硬断言：指纹逐项相等（任何缺失/多余都 fail）---"
w12_fp_dump "$DB" "$ART/fp_post.txt"
w12_fp_compare "压缩态掉电重启后" "$ART/fp_pre.txt" "$ART/fp_post.txt"
R_POST=$(grep -m1 '^d1_seq_rows=' "$ART/fp_post.txt" | cut -d= -f2)
assert_eq "  重启后 d1 全序列的数据行数（逐条数据行）" "${R_POST:-0}" "$(( ROWS * BATCHES ))"
S_POST=$(grep -m1 '^total_sum=' "$ART/fp_post.txt" | cut -d= -f2)
assert_eq "  重启后值总和（离线核算值）" "${S_POST:-0}" "$(w12_exp_sum)"

log "--- ⑪ 过程证据（只作证据）：WAL 消费 + 解压指标 + OOM ---"
w12_snap "重启后"
UC_POST=$(w12_uncompress_cost)
log "  恢复后 wal_uncompress_cost=$UC_POST（读取侧解压累计；比 kill 前 $UC_COST 有增量即说明恢复走了（试）解压路径）"
OOM=$(wal_oom_cnt); assert_eq "  WAL 相关 OOM 日志行数（必须 0）" "${OOM:-0}" "0"
RF=$(wal_sum_over_dn wal_file_cnt); log "  重启后整目录 WAL：${RF}f/$(wal_sum_over_dn wal_dir_bytes)B（恢复末步会删除 WALNode 下的文件）"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w12_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 专属异常正则已安装）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|Connection reset by peer|Connection refused'
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
