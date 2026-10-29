#!/bin/bash
# ============================================================================
# CO-37 分组合并（对齐序列）的分组规则与 timestamp 保留
#   覆盖设计规则 D4-1 / D4-2 / D4-3（含 D4-6）/ D4-5；官方 MG-02-4、MG-11 的**模板形态**；
#   规格来源：`docs/OFFICIAL_COVERAGE.md` §4.2 CO-37 + §5「判据完备性」第 24~28 行（含 D4-7 反向约束）
#
#   场景：`root.cogrp` 一个库里放两个设备
#     · `root.cogrp.d1`：**对齐 + 12 列**（s1..s12），显式建序列；
#       其中 s1=PLAIN/SNAPPY、s4=RLE/SNAPPY、s5=TS_2DIFF/GZIP ⇒ 覆盖 D4-5「encoding/compression 不一致」；
#       写入时刻意制造空洞：不同列写不同的时间点子集；`s11` 只在第 2 批不写 ⇒ 整列在某批全 null；
#       另写一个"只落 s11"的时间点再 DELETE 掉它 ⇒ 制造「全部 value 列为 null 的 timestamp」（D4-3/4-6）。
#     · `root.cogrp.d2`：**模板形态**（`CREATE SCHEMA TEMPLATE … ALIGNED` + `SET … TO root.cogrp.d2`
#       + `CREATE TIMESERIES OF SCHEMA TEMPLATE ON root.cogrp.d2`）后写数据 ⇒ 顺带补官方 MG-02-4 的模板空白。
#   两相（逐相独立库；写入期三类合并全关，写完记基线后再热开、首轮完成即冻结）：
#     A `root.cogrp` ：`compaction_max_aligned_series_num_in_one_batch = 1`（12 列 ⇒ 12 组）
#     B `root.cogrp2`：同构造，阈值 = 8（12 列 ⇒ 2 组）⇒ 分组粒度不同、产物结构必须不同
#
#   判据：
#     ① 双信号：cmp_seq_inner_finish 增加 **且** cmp_all_sum 下降；
#     ② **timestamp 保留**：合并后 `select *` 的行数 == 合并前，且**逐列 null 计数逐个一致**（D4-3 直接判据），
#        且 `select *` 归一化指纹与 `cmp_fp_tree` 都不变（模板设备 d2 同样比对）；
#     ③ **分组真的发生**：A（阈值 1）与 B（阈值 8）的产物结构必须不同（文件数 / 总字节 / 逐产物字节任一不同）；
#     ④ **encoding 不匹配不得直搬**：产物字节与源字节必须存在差异（证明至少一列被解开重写）；
#        强判据（逐列 chunk 字节比对）需 TsFile 工具 ⇒ 本用例**显式降级并标注**；
#     ⑤ `show devices` 中 d1 仍为 ALIGNED、`select *` 表头仍是 12 列、模板仍挂在 d2 上且 d2 数据不变；
#     ⑥ 无 `CompactionTableSchemaNotMatchException`/`DataTypeInconsistentException`/NPE/overlap 异常；
#        `cmp_stuck_sum = 0` + 收尾三件套。
#
#   ⚠️ 注意（D4-7 反向判据 / 防误判）：产物里出现「只有 timestamp 没有非 null value」的点是**设计已知行为**，
#      本用例**不得**把它判成缺陷（所以②只断言"合并前后一致"，不断言"必须没有全 null 行"）。
#   用法： bash co_aligned_grouping.sh [--consensus IoTConsensus]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_aligned_grouping_${DATA_CONSENSUS}"

DB=root.cogrp            # A 相：阈值 1
DBB=root.cogrp2          # B 相：阈值 8
TPL=tpl_cogrp
COLS=12                  # 对齐设备 d1 的列数
TCOLS=8                  # 模板（d2）的列数
ROWS=${CO37_ROWS:-40}    # 每批每列点数（空洞列按规则取子集）
MINB=${CO37_BATCHES:-3}  # 至少写几批
MAXB=${CO37_MAXB:-5}     # 最多写几批（对齐+空洞场景每批不一定落新 TsFile）
WIN=${CO37_WIN:-150}     # 等首轮合并的窗口
# 选择间隔取 5s（而不是 1s）：首轮合并完成后到下一轮选择之间有 ~5s 空档，
# 让"检测到首个 finishes 就热关 seq 合并"的冻结动作来得及生效，避免产物被级联再并掉。
INTERVAL_MS=${CO37_INTERVAL_MS:-5000}
TH_A=1
TH_B=8

# ---------------------------------------------------------------------------
# 观测工具（仅本用例使用，不改动 lib/）
# ---------------------------------------------------------------------------
# 对齐设备一次 `select *` 的统计：列数 + 行数 + 全空行数 + 逐列 null 计数
co37_snap(){ local dev=$1 out
  out=$(sq "select * from $dev order by time;")
  printf '%s\n' "$out" | awk -F'|' '
    /^[[:space:]]*\|[[:space:]]*Time[[:space:]]*\|/ {
      for(i=2;i<NF;i++){h=$i; gsub(/^[ \t]+|[ \t]+$/,"",h); if(h!=""){col[i]=h; nc=i}}
      next }
    /^\|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ {
      rows++; an=1
      for(i=2;i<=nc;i++){v=$i; gsub(/^[ \t]+|[ \t]+$/,"",v); if(v=="null"||v==""){nu[i]++; nt++} else {an=0}}
      if(an==1) alln++ }
    END{ printf "cols=%d rows=%d allnull=%d null_total=%d", (nc>1?nc-1:0), rows+0, alln+0, nt+0
      for(i=2;i<=nc;i++) if(col[i]!="") printf " %s=%d", col[i], nu[i]+0
      printf "\n" }'; }
co37_rows_of(){ printf '%s\n' "$1" | sed -E 's/^cols=[0-9]+ rows=([0-9]+).*/\1/'; }
co37_cols_of(){ printf '%s\n' "$1" | sed -E 's/^cols=([0-9]+).*/\1/'; }
co37_allnull_of(){ printf '%s\n' "$1" | sed -E 's/^cols=[0-9]+ rows=[0-9]+ allnull=([0-9]+).*/\1/'; }
co37_nullkey(){ printf '%s\n' "$1" | sed -E 's/^cols=[0-9]+ rows=[0-9]+ allnull=[0-9]+ //'; }
# 逐产物字节（升序一行一个）
co37_sizes(){ local h=$1 db=$2
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%s\n' 2>/dev/null | sort -n" | tr -d '\r'; }
# 文件数稳定
co37_wait_stable(){ local db=$1 t=${2:-90} i=0 a b
  while [ "$i" -lt "$t" ]; do
    a=$(cmp_all_sum "$db"); sleep 6; b=$(cmp_all_sum "$db")
    [ "$a" = "$b" ] && { log "  文件数已稳定：$b"; return 0; }
    i=$(( i + 6 ))
  done
  warn "  文件数在 ${t}s 内未稳定（$a → $b）"; return 1; }

# ---------------------------------------------------------------------------
# 写一批（对齐 d1 的 12 列按不同密度写；模板设备 d2 写 8 列）
# ---------------------------------------------------------------------------
co37_lit(){ local c=$1 k=$2 b=$3
  case "$c" in
    2|5|8|10) printf '%s.%s' "$(( k + b ))" "$(( k % 10 ))" ;;
    3|6|11)   printf "'t%s_%s'" "$c" "$k" ;;
    *)        printf '%s' "$(( k * 100 + b ))" ;;
  esac; }
co37_ks_for(){ local c=$1
  case "$c" in
    12)   printf '1' ;;
    2|5)  printf '%s' "$(seq 1 2 "$ROWS")" ;;
    3|6)  printf '%s' "$(seq 3 3 "$ROWS")" ;;
    8|10) printf '%s' "$(seq 5 5 "$ROWS")" ;;
    *)    printf '%s' "$(seq 1 "$ROWS")" ;;
  esac; }
co37_write_batch(){ local db=$1 b=$2 base=$3 c k ks ts vals stmts=()
  for c in $(seq 1 "$COLS"); do
    [ "$c" = 11 ] && [ "$b" = 2 ] && continue          # s11 第 2 批不写 ⇒ 该批时间点上 s11 整列为 null
    ks=$(co37_ks_for "$c")
    vals=""
    for k in $ks; do
      ts=$(( base + b * 200000 + k * 10 ))
      vals="$vals($ts,$(co37_lit "$c" "$k" "$b")),"
    done
    [ -n "$vals" ] && stmts+=("insert into $db.d1(time,s$c) values ${vals%,};")
  done
  for c in $(seq 1 "$TCOLS"); do
    case "$c" in
      2|5) ks=$(seq 1 2 "$ROWS") ;;
      3|6) ks=$(seq 3 3 "$ROWS") ;;
      *)   ks=$(seq 1 "$ROWS") ;;
    esac
    vals=""
    for k in $ks; do
      ts=$(( base + b * 200000 + k * 10 ))
      vals="$vals($ts,$(co37_lit "$c" "$k" "$b")),"
    done
    [ -n "$vals" ] && stmts+=("insert into $db.d2(time,s$c) values ${vals%,};")
  done
  stmts+=("flush;")
  sql_lines_tree "${stmts[@]}" >/dev/null
  sleep 3; }

# ---------------------------------------------------------------------------
# 建库 + 挂模板 + 建 12 列对齐序列 + 写数据
# ---------------------------------------------------------------------------
co37_scene(){ local db=$1 i out b l0 base tsp ks
  cmp_compaction_off
  sq "create database $db;" >/dev/null
  # ① 模板形态（官方 MG-02-4 的空白点）：挂 ALIGNED 模板到 d2 + 用模板建设备
  #    d1 尚未显式创建 ⇒ 即使只能库级挂载也不会与显式 12 列 DDL 冲突
  out=$(sq "set schema template $TPL to $db.d2;")
  if ! printf '%s' "$out" | grep -q 'successfully'; then
    warn "  [$db] 设备级 SET SCHEMA TEMPLATE 未成功（$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)）⇒ 降级为库级挂载重试"
    out=$(sq "set schema template $TPL to $db;")
  fi
  assert_contains "  [$db] SET SCHEMA TEMPLATE $TPL TO $db(.d2)" "$out" 'successfully'
  out=$(sq "create timeseries of schema template on $db.d2;")
  assert_contains "  [$db] CREATE TIMESERIES OF SCHEMA TEMPLATE ON $db.d2" "$out" 'successfully'
  assert_contains "  [$db] 模板设备出现在 SHOW PATHS USING 里" "$(sq "show paths using schema template $TPL;")" "$db\.d2"
  # ② 显式 12 列对齐设备（3 列带不同 encoding/compression，覆盖 D4-5）
  out=$(sq "create aligned timeseries $db.d1(s1 INT64 ENCODING=PLAIN COMPRESSION=SNAPPY, s2 DOUBLE, s3 TEXT, s4 INT64 ENCODING=RLE COMPRESSION=SNAPPY, s5 DOUBLE ENCODING=TS_2DIFF COMPRESSION=GZIP, s6 TEXT, s7 INT64, s8 DOUBLE, s9 INT64, s10 DOUBLE, s11 TEXT, s12 INT64);")
  if ! printf '%s' "$out" | grep -q 'successfully'; then
    warn "  [$db] 带 encoding/compression 属性的对齐 DDL 未成功（$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)）⇒ 降级为无属性形式重试（D4-5 的④判据随之降级）"
    out=$(sq "create aligned timeseries $db.d1(s1 INT64, s2 DOUBLE, s3 TEXT, s4 INT64, s5 DOUBLE, s6 TEXT, s7 INT64, s8 DOUBLE, s9 INT64, s10 DOUBLE, s11 TEXT, s12 INT64);")
  fi
  if ! printf '%s' "$out" | grep -q 'successfully'; then
    # 若模板被降级挂到了库上，显式建序列可能被模板占用挡下 ⇒ 解除库级挂载后重试（d2 的模板序列已物化，不影响本用例）
    warn "  [$db] 显式建 12 列对齐序列失败（$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)）⇒ 尝试解除库级模板挂载后重试"
    sq "unset schema template $TPL from $db;" >/dev/null 2>&1
    out=$(sq "create aligned timeseries $db.d1(s1 INT64, s2 DOUBLE, s3 TEXT, s4 INT64, s5 DOUBLE, s6 TEXT, s7 INT64, s8 DOUBLE, s9 INT64, s10 DOUBLE, s11 TEXT, s12 INT64);")
  fi
  assert_contains "  [$db] 建 12 列对齐序列 $db.d1" "$out" 'successfully'
  # ③ 写数据（每批等 close 事件后再写下一批）
  base=$(( ($(date +%s) - 3600) * 1000 ))
  for ((b=1; b<=MAXB; b++)); do
    co37_write_batch "$db" "$b" "$base"
    cmp_wait_close "$db" "$b" 90 >/dev/null || warn "  [$db] 批$b：close 事件未达 $b（$(ttl_close_snapshot "$db")）"
    l0=$(cmp_min_l0 "$db")
    log "  [$db] 第 $b 批写完：min_l0=$l0 files=$(cmp_all_sum "$db")"
    [ "$b" -ge "$MINB" ] && [ "${l0:-0}" -ge 2 ] && break
    sleep 3
  done
  # ④ 制造"全部 value 列为 null 的 timestamp"：只写 s11 再删掉该点（D4-3/4-6）
  tsp=$(( base + MAXB * 200000 + 100000 ))
  sq "insert into $db.d1(time,s11) values ($tsp,'only');" >/dev/null
  sq "delete from $db.d1.s11 where time>=$tsp and time<=$tsp;" >/dev/null
  sq "flush;" >/dev/null
  l0=$(cmp_min_l0 "$db")
  log "  [$db] 场景就绪：布局=$(cmp_lay "$db") min_l0=$l0 files=$(cmp_all_sum "$db") 字节=$(cmp_bytes_sum "$db")"
  if [ "${l0:-0}" -ge 2 ]; then pass "  [$db] 场景有效：各副本 level-0 文件数 ≥ 2（min_l0=$l0）"
  else fail "  [$db] 场景未成立：min_l0=$l0 < 2（合并候选不足）"; fi; }

# ---------------------------------------------------------------------------
# 单相位：跑合并 + 判据 ①②④
# ---------------------------------------------------------------------------
P_FIN0=("" ""); P_FIN1=("" ""); P_OBS=("" ""); P_B1=("" ""); P_SIZES=("" "")
co37_phase(){ local db=$1 th=$2 tag=$3 idx=$4
  log "  --- [$tag] 造场景 $db（对齐 12 列 + 模板设备 8 列；$MINB~$MAXB 批）---"
  co37_scene "$db"
  # 基线：行数/逐列 null 计数 + 指纹 + 模板设备
  local s0 t0 fp0 ft0 ts0 by0 f0 cols
  s0=$(co37_snap "$db.d1"); t0=$(co37_snap "$db.d2"); ts0=$(cmp_all_sum "$db"); by0=$(cmp_bytes_sum "$db")
  fp0=$(cmp_fingerprint tree "select * from $db.d1 order by time;")
  ft0=$(cmp_fp_tree "$db")
  P_OBS[$idx]="$ts0"; P_B1[$idx]="$by0"
  log "  [$tag] 合并前基线：d1[$s0]；d2[$t0]；全库 files=$ts0 字节=$by0 fp_tree=$ft0"
  cols=$(co37_cols_of "$s0")
  [ "$cols" = "$(( COLS + 1 ))" ] && pass "  [$tag] 场景有效：对齐设备 d1 列数 $cols = $COLS" \
    || fail "  [$tag] 场景未成立：对齐设备 d1 列数 $cols ≠ $COLS"
  [ "$(co37_rows_of "$s0")" -gt 0 ] && pass "  [$tag] 场景有效：d1 行数 $(co37_rows_of "$s0") > 0" \
    || fail "  [$tag] 场景未成立：d1 行数为 0（写入失败）"
  local tcols; tcols=$(co37_cols_of "$t0")
  if [ "${tcols:-0}" = "$(( TCOLS + 1 ))" ]; then
    pass "  [$tag] 场景有效：模板设备 d2 列数 $tcols = $TCOLS（模板形态参与本次合并）"
  else
    warn "  [$tag] 模板设备 d2 列数 [$tcols] ≠ $TCOLS ⇒ 模板形态覆盖降级（仅记录，不影响主判据）"
  fi
  if [ "$(co37_allnull_of "$s0")" -ge 1 ]; then
    pass "  [$tag] 构造到「全部 value 列为 null 的 timestamp」$(co37_allnull_of "$s0") 个（D4-3/4-6 场景成立）"
  else
    warn "  [$tag] 未构造出全 value 列为 null 的 timestamp（记录：$s0）——②仍按'合并前后一致'判定（D4-7：不得据此判缺陷）"
  fi
  if [ "$cols" -gt "$th" ]; then pass "  [$tag] 场景有效：列数 $cols > 阈值 $th（至少 2 个分组）"
  else fail "  [$tag] 场景未成立：列数 $cols ≤ 阈值 $th（只会有 1 组，无法验证分组）"; fi
  # 设阈值 → 热开 seq 合并 → 首轮完成即冻结
  cmp_set_hot compaction_max_aligned_series_num_in_one_batch "$th" >/dev/null
  assert_eq "  [$tag] compaction_max_aligned_series_num_in_one_batch 生效值" \
    "$(cmp_eff "${DN[0]}" compaction_max_aligned_series_num_in_one_batch)" "$th"
  f0=$(cmp_seq_inner_finish "$db"); P_FIN0[$idx]="$f0"
  cmp_compaction_on true false false
  local hit=0 dl fin1
  dl=$(( $(date +%s) + WIN ))
  while (( $(date +%s) < dl )); do
    [ "$(cmp_seq_inner_finish "$db")" -gt "$f0" ] && { hit=1; break; }
    sleep 2
  done
  fin1=$(cmp_seq_inner_finish "$db"); P_FIN1[$idx]="$fin1"
  [ "$hit" = 1 ] && pass "  [$tag] 合并已推进：finishes $f0 → $fin1" || fail "  [$tag] ${WIN}s 内合并未推进（finishes 仍为 $f0）"
  cmp_set_hot enable_seq_space_compaction false >/dev/null 2>&1
  log "  [$tag] 已热关 seq 合并（冻结首轮产物；生效值 $(cmp_eff "${DN[0]}" enable_seq_space_compaction)）"
  sleep 5
  co37_wait_stable "$db" 90 >/dev/null
  local s1 t1 fp1 ft1 obs by1
  fin1=$(cmp_seq_inner_finish "$db")
  s1=$(co37_snap "$db.d1"); t1=$(co37_snap "$db.d2"); obs=$(cmp_all_sum "$db"); by1=$(cmp_bytes_sum "$db")
  fp1=$(cmp_fingerprint tree "select * from $db.d1 order by time;")
  ft1=$(cmp_fp_tree "$db")
  P_FIN1[$idx]="$fin1"; P_OBS[$idx]="$obs"; P_B1[$idx]="$by1"
  P_SIZES[$idx]=$(co37_sizes "${DN[0]}" "$db" | tr '\n' ' ')
  log "  [$tag] 终态：布局=$(cmp_lay "$db") files=$ts0→$obs 字节=$by0→$by1 finishes=$f0→$fin1"
  log "  [$tag] 合并后 d1[$s1]；d2[$t1]"
  # ① 双信号
  if [ "$hit" = 1 ] && [ "${obs:-0}" -lt "${ts0:-0}" ]; then
    pass "  [$tag] ① 双信号成立：finishes $f0→$fin1 且 TsFile $ts0→$obs"
  else
    fail "  [$tag] ① 双信号不成立：finishes $f0→$fin1，TsFile $ts0→$obs"
  fi
  # ② timestamp / null 保留（D4-3 直接判据）
  assert_eq "  [$tag] ② 合并前后 d1 行数（timestamp 个数）" "$(co37_rows_of "$s1")" "$(co37_rows_of "$s0")"
  assert_eq "  [$tag] ② 合并前后逐列 null 计数" "$(co37_nullkey "$s1")" "$(co37_nullkey "$s0")"
  cmp_assert_same "  [$tag] ② 合并前后 d1 select * 归一化指纹" "$fp0" "$fp1"
  cmp_assert_same "  [$tag] ② 合并前后全库 cmp_fp_tree" "$ft0" "$ft1"
  if [ "${tcols:-0}" = "$(( TCOLS + 1 ))" ]; then
    assert_eq "  [$tag] ② 合并前后模板设备 d2 行数" "$(co37_rows_of "$t1")" "$(co37_rows_of "$t0")"
    assert_eq "  [$tag] ② 合并前后模板设备 d2 逐列 null 计数" "$(co37_nullkey "$t1")" "$(co37_nullkey "$t0")"
  fi
  # ④ encoding/compression 不匹配不得直搬（降级判据，显式标注）
  if [ "${by1:-0}" != "${by0:-0}" ]; then
    pass "  [$tag] ④ 产物字节 $by0 → $by1（与源不同 ⇒ 至少有一列 chunk 被解开重写）；⚠️ 降级判据：逐列 chunk 字节比对需 TsFile 工具，本用例只做'字节存在差异 + 指纹一致'"
  else
    warn "  [$tag] ④ 产物字节与源字节相同（$by1）——无法据此判断是否重写；⚠️ 降级记录（需 TsFile 工具做逐列 chunk 比对）"
  fi; }

# ---------------------------------------------------------------------------
# 集群准备 + 模板（模板是集群级对象，只建一次）
# ---------------------------------------------------------------------------
log "--- 集群准备：三类合并先关；interval=${INTERVAL_MS}；candidate=${CMP_CANDIDATE_NUM} ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${INTERVAL_MS}" cmp_cluster_prepare

log "--- 建 ALIGNED SCHEMA TEMPLATE（官方 MG-02-4 的模板形态；集群级对象，只建一次）---"
TPLOUT=$(sq "create schema template $TPL ALIGNED (s1 INT64, s2 DOUBLE, s3 TEXT, s4 INT64, s5 DOUBLE, s6 TEXT, s7 INT64, s8 DOUBLE);")
assert_contains "  建 ALIGNED SCHEMA TEMPLATE $TPL" "$TPLOUT" 'successfully'
assert_contains "  SHOW SCHEMA TEMPLATES 含 $TPL" "$(sq "show schema templates;")" "$TPL"

# ---------------------------------------------------------------------------
# A 相（阈值 1）→ B 相（阈值 8）
# ---------------------------------------------------------------------------
log "--- A 相：$DB（compaction_max_aligned_series_num_in_one_batch=$TH_A）---"
co37_phase "$DB" "$TH_A" A 0
log "--- B 相：$DBB（compaction_max_aligned_series_num_in_one_batch=$TH_B）---"
co37_phase "$DBB" "$TH_B" B 1

# ③ 分组真的发生：A / B 的产物结构必须不同
SZ_A="${P_SIZES[0]}"; SZ_B="${P_SIZES[1]}"
log "  ③ 结构对照：A(阈值 $TH_A) files=${P_OBS[0]} 字节=${P_B1[0]} 逐产物=[$SZ_A]"
log "  ③ 结构对照：B(阈值 $TH_B) files=${P_OBS[1]} 字节=${P_B1[1]} 逐产物=[$SZ_B]"
if [ "${P_OBS[0]}" != "${P_OBS[1]}" ] || [ "${P_B1[0]}" != "${P_B1[1]}" ] || [ "$SZ_A" != "$SZ_B" ]; then
  pass "  ③ 分组生效：阈值 $TH_A 与 $TH_B 的产物结构不同（files ${P_OBS[0]} vs ${P_OBS[1]}；字节 ${P_B1[0]} vs ${P_B1[1]}）"
else
  fail "  ③ 未观察到分组差异：两相产物结构完全相同（files=${P_OBS[0]} 字节=${P_B1[0]} 逐产物=[$SZ_A]）⇒ D4-1/D4-2 的分组规则未生效或被参数忽略"
fi

# ⑤ 元数据面 / D4-7 反向约束
log "  --- ⑤ 元数据与 D4-7 校验 ---"
DEVOUT=$(sq "show devices $DB.d1;")
assert_contains "  ⑤ d1 仍为 ALIGNED（show devices 命中 d1 行）" "$DEVOUT" "$DB\.d1"
assert_contains "  ⑤ d1 的 IsAligned 列为 true" "$DEVOUT" "\|[[:space:]]*true[[:space:]]*\|"
assert_contains "  ⑤ 模板仍在（SHOW SCHEMA TEMPLATES）" "$(sq "show schema templates;")" "$TPL"
assert_contains "  ⑤ 模板设备 d2 仍挂在模板下（SHOW PATHS USING）" "$(sq "show paths using schema template $TPL;")" "$DB\.d2"
SN_END=$(co37_snap "$DB.d1")
assert_eq "  ⑤ 合并后 d1 列数仍为 $COLS" "$(co37_cols_of "$SN_END")" "$(( COLS + 1 ))"
log "  ⑤ 合并后 d1 统计：$SN_END"
log "  （D4-7 反向判据：产物里出现'只有 timestamp 没有非 null value'的点属设计已知行为，本用例不判缺陷；当前 allnull=$(co37_allnull_of "$SN_END")）"

# ⑥ 卡死线程
STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "⑥ 无合并线程卡死在 TsFileResource.writeLock"

# ---------------------------------------------------------------------------
# 收尾三件套（异常日志正则已含 CompactionTableSchemaNotMatchException / DataTypeInconsistentException / NPE / overlap）
# ---------------------------------------------------------------------------
log "--- 收尾三件套（基准库 $DB）---"
post_checks "select * from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
