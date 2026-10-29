#!/bin/bash
# ============================================================================
# W-08 WAL 文件轮转阈值（wal_file_size_threshold_in_byte）
#
# 需求 / 源码依据
#   · design_extract.md §2.4：轮转条件 =「当前文件及其待写入的 buffer 的数据量超过
#     wal_file_size_threshold_in_byte」；§2.5 参数条目（默认 10MB，标"热加载"）；
#     design_extract.md §8.1 TP-06：把阈值调小后持续写入应产生多个 WAL 文件。
#   · feature_extract.md A.1#背景：Buffer 落盘后检查 WAL 文件大小，超过阈值（默认 30MB，
#     参数 walFileSizeThresholdInByte）就封口当前文件并切到下一个 ⇒ **文档间 10M/30M 矛盾**，
#     故本用例一律以「运行期生效值」为准（cmp_eff 读 show configuration + properties 兜底）。
#   · source_grounding.md §5.3：轮转判据是 `currentWALFileWriter.originalSize() >=
#     wal_file_size_threshold_in_byte`，而 **originalSize 是"未压缩累计写入字节"**，
#     不是磁盘文件长度（压缩开启时磁盘文件更小）。
#   · source_grounding.md §3.4：文件名 `_<versionId>-<startSearchIndex>-<0|1>.wal`；
#     §3.2：WALNode 目录名 = `<database>-<regionId>`（IoTConsensus 的 FirstCreateStrategy）
#     ⇒ 本用例**按库过滤** WAL 文件（`*/root.walrot-*/*`），比全局计数更干净。
#
# 判据（**硬** = FAIL；压缩率/耗时/指标口径一律只 WARN）
#   ① 场景有效性（硬）：小阈值相写入后本库 WAL 文件数 ≥ WAL_ROTATE_MIN_FILES 且字节 > 0；
#      两相"运行期生效阈值"必须确实不同（否则配置没生效 ⇒ 场景无效，不许静默通过）。
#   ② 轮转效果（硬）：同写入量下 小阈值相文件数 > 默认阈值相文件数；单文件字节 ≤ 生效阈值
#      + 生效 wal_buffer_size_in_byte（余量口径见下）。"是否达到 2 倍"只 WARN。
#   ③ 数据面（硬）：两相 每设备点数 / count / sum / 单设备 count+sum 指纹完全一致，且等于预期
#      点数 —— 轮转不得丢数据。这是本用例唯一的功能判据。
#
# 余量口径（为什么是"阈值 + buffer"）：轮转在"把这一批 buffer 写进文件之后"才判定，
#   所以 单文件磁盘字节 ≤ originalSize ≤ 阈值 + 单批写入量；而单批写入量 ≤ 1/3 buffer × 0.95
#   （source_grounding.md §5.1：`ONE_THIRD_WAL_BUFFER_SIZE` + `FSYNC_BUFFER_RATIO=0.95`）
#   ⇒ 取 `阈值 + wal_buffer_size_in_byte` 是**安全的宽松界**。更紧的界需要"单次 flush 批量"，
#   黑盒取不到；默认 buffer 32MB 时该界很宽，只用于兜住"阈值完全没生效"的失控轮转。
#
# ⚠ **本脚本未实跑**（2026-10-16：99.80 正在跑合并长回归，禁止对集群做任何启停/远端动作）。
#   本机沙箱禁止 msys/cygwin 创建命名管道 ⇒ 无法在本机执行真 `bash -n`；
#   已完成：bashlex（bash 自身文法的 Python 实现）整文件解析 + 静态坑检查（详见交付说明）。
#
# 首轮 watch list（实跑时优先确认这 5 项）
#   1) WAL 目录 / 库名过滤：`dn_wal_dirs` 默认 `data/datanode/wal`，WALNode 子目录 =
#      `<database>-<regionId>`。本用例按 `*/root.walrot-*/*` 过滤；若实测目录名规则不同，
#      本库文件数恒 0 ⇒ 直接 FAIL"场景无效"，此时看日志里打印的 WALNode 目录清单 / 文件清单。
#   2) 写入量：1MB 阈值下要有 > 1MB 的未压缩 WAL 才出多文件，默认 10 设备 × 4000 行 × 4 批
#      ≈ 16 万点；若单点序列化字节远小于预估 ⇒ 调大 WAL_ROTATE_ROWS（会以"场景无效"FAIL 提示）。
#   3) 刷盘节奏：WAL Buffer 按 wal_async_mode_fsync_delay_in_ms≈1s 刷盘，写完立刻统计会漏掉
#      内存 buffer 里的部分 ⇒ 本用例用 wrot_stable_bytes 轮询到"连续两次采样相同"再取数。
#   4) 压缩：两相都只用默认 enable_wal_compression=true（**只变阈值，不变其它参数**），
#      所以磁盘字节比 1MB 阈值小是正常的——文件数看 originalSize 口径，不要按磁盘字节推断。
#   5) 指标口径：`file_count{name="wal"}`（AutoGauge / CORE，WalFileMetrics）与目录口径若不一致
#      只 WARN（metric reporter / 导出形态差异），不判产品。
#
# 库名：root.walrot
# 用法：bash cases/common/wal_file_rotate.sh [--consensus IoTConsensus|IoTConsensusV2]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_file_rotate_${DATA_CONSENSUS}"

DB=root.walrot
DEVS=${WAL_ROTATE_DEVS:-10}                       # 设备数
ROWS=${WAL_ROTATE_ROWS:-4000}                     # 每设备每批点数
BATCHES=${WAL_ROTATE_BATCHES:-4}                  # 批数（全部不 flush，纯累积 WAL）
SMALL=${WAL_ROTATE_THRESHOLD_SMALL:-1048576}      # 1MB：让 WAL 快速轮转
BIG=${WAL_FILE_THRESHOLD_BYTES:-31457280}         # 对照相（WAL_EXTRA_DEFAULT 里的默认阈值）
MINF=${WAL_ROTATE_MIN_FILES:-2}                   # 场景有效性：至少几个 WAL 文件
STABLE_WIN=${WAL_ROTATE_STABLE_WIN_SEC:-45}       # 等 WAL 字节稳定的窗口
WANT=$(( DEVS * ROWS * BATCHES ))
WROT_NAME_RE='^_[0-9]+-[0-9]+-[01]\.wal$'         # source_grounding.md §3.4

# ---------------------------------------------------------------------------
# ① 本库 WAL 文件面（按 WALNode 目录名 `<database>-<regionId>` 过滤）
#    ⚠ wal_sum_over_dn / wal_per_node 只往函数里传"节点"，所以这几个本地 helper
#      固定使用全局 $DB（库名在用例里是常量，不会变）。
# ---------------------------------------------------------------------------
wrot_db_find(){ local h=$1 kind=$2
  case "$kind" in
    files) sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9' ;;
    bytes) sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9' ;;
    maxf)  sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | sort -n | tail -1" 2>/dev/null | tr -dc '0-9' ;;
    names) sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' -printf '%f\n' 2>/dev/null | sort" 2>/dev/null | tr -d '\r' ;;
  esac; }
wrot_db_files(){ local v; v=$(wrot_db_find "$1" files); echo "${v:-0}"; }
wrot_db_bytes(){ local v; v=$(wrot_db_find "$1" bytes); echo "${v:-0}"; }
wrot_db_max_file(){ local v; v=$(wrot_db_find "$1" maxf); echo "${v:-0}"; }
wrot_db_names(){ wrot_db_find "$1" names; }
# 逐副本证据串（本库口径）：`77=3f/1234B 78=… `
wrot_db_per_node(){ local h o=""; for h in "${DN[@]}"; do o="$o${h##*.}=$(wrot_db_files "$h")f/$(wrot_db_bytes "$h")B "; done; echo "$o"; }
# 跨 DN 取最大值（比求和更抗"某副本还没落盘"的抖动）
wrot_max_over_dn(){ local f=$1 h v m=0; for h in "${DN[@]}"; do v=$($f "$h"); [ "${v:-0}" -gt "$m" ] && m=$v; done; echo "$m"; }

# ---------------------------------------------------------------------------
# ② 写入（**不 flush**）
#    lib/cmp.sh 的 cmp_write_tree_batch 结尾会 `flush;`，而 flush 会把对应 WAL 置为无效
#    并被 WAL-Delete 线程删除 ⇒ 文件面观测必须自己写。
#    一个 CLI 会话里批量喂语句（每次 sq 都会新起 JVM，逐条调用测出来的是 CLI 启动开销）。
# ---------------------------------------------------------------------------
wrot_write_no_flush(){ local db=$1 devs=$2 rows=$3 b=$4
  local base d k vals stmts=() logf
  base=$(( ($(date +%s) - 7200) * 1000 + (b - 1) * rows * 10 + 1000 ))
  for ((d=1; d<=devs; d++)); do
    vals=""
    for ((k=0; k<rows; k++)); do
      vals="$vals($(( base + k * 10 )),$(( k + b ))),"
      if [ $(( (k + 1) % 500 )) -eq 0 ]; then
        stmts+=("insert into $db.d$d(time,s1) values ${vals%,};"); vals=""
      fi
    done
    [ -n "$vals" ] && stmts+=("insert into $db.d$d(time,s1) values ${vals%,};")
  done
  [ "${#stmts[@]}" -gt 0 ] || { fail "场景无效：第 $b 批没有生成任何 INSERT 语句（检查 WAL_ROTATE_DEVS/ROWS）"; return 1; }
  logf="$ART/wrot_write_b${b}.log"
  sql_lines_tree "${stmts[@]}" >"$logf" 2>&1
  if grep -qiE 'IoTDBSQLException|Exception' "$logf"; then
    fail "第 $b 批写入出现异常：$(grep -iE 'Exception' "$logf" | head -2 | tr '\n' ' ' | cut -c1-200)"
    return 1
  fi
  log "  第 $b 批写入完成：$(( devs * rows )) 点 / ${#stmts[@]} 条语句（**未 flush**）"
  return 0; }

# 等 WAL 字节稳定（async fsync delay ≈1s，写完立刻取数会漏掉还在内存 buffer 里的那部分）
wrot_stable_bytes(){ local win=${1:-45} i=0 c="" p=""
  while [ $(( i * 4 )) -lt "$win" ]; do
    sleep 4; i=$(( i + 1 ))
    c=$(wal_sum_over_dn wal_dir_bytes)
    if [ -n "$p" ] && [ "$c" = "$p" ]; then log "  WAL 字节连续两次采样相同：${c}B（第 $i 次采样）"; echo "$c"; return 0; fi
    p=$c
  done
  log "  WAL 字节在 ${win}s 内未稳定，取末次采样 ${c:-0}B（继续按证据判定）"
  echo "${c:-0}"; return 1; }

# 生效值：运行期 show configuration 优先，读不到退回 properties 文件值
wrot_eff(){ local h=$1 k=$2 v; v=$(wal_eff "$h" "$k"); [ -n "$v" ] || v=$(wal_props_get "$h" "$k"); printf '%s' "$v"; }

# ---------------------------------------------------------------------------
# ③ 证据 / 指纹
# ---------------------------------------------------------------------------
wrot_evidence(){ local tag=$1 h names mg
  log "  [$tag] 逐副本（本库 文件数/字节/单文件最大 B | 全局 文件数/字节 B | 指标 file_count{name=wal} / wal_node_num）"
  for h in "${DN[@]}"; do
    log "    ${h##*.}: db=$(wrot_db_files "$h")f/$(wrot_db_bytes "$h")B maxfile=$(wrot_db_max_file "$h")B | all=$(wal_file_cnt "$h")f/$(wal_dir_bytes "$h")B | metric_files=$(wal_metric_file_cnt "$h") nodes=$(wal_metric_node_num "$h")"
  done
  h="${DN[0]}"
  names=$(wrot_db_names "$h")
  log "  [$tag] ${h##*.} 本库 WAL 文件清单（前 12）：$(printf '%s' "$names" | head -12 | tr '\n' ' ')"
  log "  [$tag] ${h##*.} versionId 列表：$(printf '%s\n' "$names" | sed -nE 's/^_([0-9]+)-.*/\1/p' | sort -n | tr '\n' ' ')"
  log "  [$tag] WALNode 目录（${h##*.}，前 8）：$(sshx "$h" "ls -1 $(wal_roots_arg "$h") 2>/dev/null | head -8" 2>/dev/null | tr '\n' ' ')"
  mg=$(wal_sum_over_dn wal_magic_cnt)
  log "  [$tag] 魔数证据：跨 DN 'WAL-V2' 命中=$mg（helper 用的是设计文档口径 'WAL-V2'；源码真实 magic 是 WAL/V2-WAL/V3-WAL，见 source_grounding §4.4 ⇒ 0 不代表异常，只作证据）"
}

# 数据面指纹：全局 count/sum + 单设备 count/sum + 每设备点数（一行 N 列，紧凑且有强度）
wrot_fp(){ local dc
  dc=$(sq "select count(s1) from $DB.**;" | table_rows | head -1 | sed -E 's/[[:space:]]+/ /g')
  printf 'all[%s] d1[%s] devcounts[%s]' "$(cmp_fp_tree "$DB")" "$(cmp_fp_tree_dev "$DB.d1")" "$dc"; }

wrot_check_devcounts(){ local line=$1 want=$2 n bad
  n=$(printf '%s' "$line" | awk -F'|' '{c=0; for(i=1;i<=NF;i++){v=$i; gsub(/[^0-9]/,"",v); if (v!="") c++} print c}')
  bad=$(printf '%s' "$line" | awk -F'|' -v w="$want" '{for(i=1;i<=NF;i++){v=$i; gsub(/[^0-9]/,"",v); if (v!="" && v+0 != w) b++}} END{print b+0}')
  if [ "${n:-0}" -eq "$DEVS" ] && [ "${bad:-1}" -eq 0 ]; then
    pass "每设备点数正确：$n 个设备均为 $want 点"
  else
    fail "每设备点数异常：设备列数=$n（期望 $DEVS），与期望 $want 不符的列数=${bad:-?}；原始首行=$(printf '%s' "$line" | cut -c1-200)"
  fi; }

wrot_assert_same(){ local label=$1 a=$2 b=$3
  if [ "$a" = "$b" ]; then pass "$label：一致"; else
    fail "$label：不一致"
    printf '  A: %s\n  B: %s\n' "$(printf '%s' "$a" | cut -c1-300)" "$(printf '%s' "$b" | cut -c1-300)" >>"$OUT"
  fi; }

# 单文件 ≤ 阈值 + buffer 上限（余量口径见文件头）
wrot_margin_check(){ local tag=$1 thr=$2 buf=$3 maxf=$4 lim
  if ! [[ "${thr:-}" =~ ^[0-9]+$ ]] || ! [[ "${buf:-}" =~ ^[0-9]+$ ]]; then
    warn "[$tag] 无法做\"单文件 ≤ 阈值 + buffer\"断言：生效阈值='${thr:-}' buffer='${buf:-}'（运行期读不到）"
    return 0
  fi
  lim=$(( thr + buf ))
  if [ "${maxf:-0}" -le "$lim" ]; then
    pass "[$tag] 单文件最大 ${maxf}B ≤ 阈值 ${thr}B + buffer 上限 ${buf}B = ${lim}B"
  else
    fail "[$tag] 单文件最大 ${maxf}B > 阈值+buffer 上限 ${lim}B（轮转余量失控）"
  fi; }

# ---------------------------------------------------------------------------
# ④ 一个阶段：写配置 → 启动 → 同量写入（不 flush）→ 取文件面 + 数据面
#    结果写进 PH_* 全局变量，由调用方抄成 A_*/B_*。
# ---------------------------------------------------------------------------
wrot_run_phase(){ local tag=$1 threshold=$2 b cnt devc
  log "--- 阶段 $tag：EXTRA_CONF 前缀追加 wal_file_size_threshold_in_byte=$threshold ---"
  # ⚠ EXTRA_CONF 必须是**单条命令的前缀环境变量**（先赋值再在别的命令里用会产生假 FAIL）
  EXTRA_CONF="$WAL_EXTRA_DEFAULT,wal_file_size_threshold_in_byte=$threshold" cmp_cluster_prepare
  PH_THRESH=$(wrot_eff "${DN[0]}" wal_file_size_threshold_in_byte)
  PH_BUF=$(wrot_eff "${DN[0]}" wal_buffer_size_in_byte)
  PH_COMP=$(wrot_eff "${DN[0]}" enable_wal_compression)
  PH_PERIOD=$(wrot_eff "${DN[0]}" delete_wal_files_period_in_ms)
  log "  [$tag] 运行期生效：threshold=${PH_THRESH:-<读不到>} buffer=${PH_BUF:-<读不到>} compression=${PH_COMP:-<读不到>} delete_period=${PH_PERIOD:-<读不到>}ms"
  cmp_make_tree_db "$DB" "$DEVS"
  for b in $(seq 1 "$BATCHES"); do wrot_write_no_flush "$DB" "$DEVS" "$ROWS" "$b" || true; done
  wrot_stable_bytes "$STABLE_WIN" >/dev/null
  cnt=$(row_sum "$(sq "select count(s1) from $DB.**;")")
  devc=$(sq "select count(s1) from $DB.**;" | table_rows | head -1 | sed -E 's/[[:space:]]+/ /g')
  PH_COUNT=$cnt
  PH_FILES_DB=$(wal_sum_over_dn wrot_db_files)
  PH_BYTES_DB=$(wal_sum_over_dn wrot_db_bytes)
  PH_FILES_ALL=$(wal_sum_over_dn wal_file_cnt)
  PH_BYTES_ALL=$(wal_sum_over_dn wal_dir_bytes)
  PH_MAXFILE=$(wrot_max_over_dn wrot_db_max_file)
  PH_METRIC_FILES=$(wal_metric_sum_over_dn wal_metric_file_cnt)
  PH_PER_NODE=$(wal_per_node)
  PH_DB_PER_NODE=$(wrot_db_per_node)
  PH_FP=$(wrot_fp)
  wrot_evidence "$tag"
  log "  [$tag] 汇总：count=$cnt（预期 $WANT）本库文件=${PH_FILES_DB} 本库字节=${PH_BYTES_DB}B 全局文件=${PH_FILES_ALL} 全局字节=${PH_BYTES_ALL}B 单文件最大=${PH_MAXFILE}B"
  log "  [$tag] 指纹：$PH_FP"
  wrot_check_devcounts "$devc" "$(( ROWS * BATCHES ))"
  [ "${cnt:-0}" -eq "$WANT" ] && pass "[$tag] 写入点数正确（$cnt）" || fail "[$tag] 写入点数异常：count=$cnt 期望 $WANT（写入丢失/被拒 ⇒ 场景无效）"
  # 文件名格式（source_grounding §3.4）只 WARN：加密后缀等情况下正则会不匹配，不属本轮判据
  local names bad
  names=$(wrot_db_names "${DN[0]}")
  bad=$(printf '%s\n' "$names" | grep -vE "$WROT_NAME_RE" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "${bad:-0}" -gt 0 ]; then
    warn "[$tag] 有 $bad 个 WAL 文件名不匹配 $WROT_NAME_RE：$(printf '%s\n' "$names" | grep -vE "$WROT_NAME_RE" | head -5 | tr '\n' ' ')"
  else
    pass "[$tag] WAL 文件名全部匹配 _<versionId>-<startSearchIndex>-<0|1>.wal（source_grounding §3.4）"
  fi
}

# ---------------------------------------------------------------------------
# ⑤ 主流程
# ---------------------------------------------------------------------------
log "=== W-08 开始：库=$DB；两相**同写入量** ${DEVS} 设备 × ${ROWS} 行 × ${BATCHES} 批 = ${WANT} 点（全部不 flush）==="
log "  WAL_EXTRA_DEFAULT=$WAL_EXTRA_DEFAULT"
log "  阈值口径：小阈值相 $SMALL B；对照相 $BIG B（文档间 10M/30M 矛盾 ⇒ 以运行期生效值为准）"

wrot_run_phase A "$SMALL"
A_THRESH=$PH_THRESH; A_BUF=$PH_BUF; A_COMP=$PH_COMP
A_FILES_DB=$PH_FILES_DB; A_BYTES_DB=$PH_BYTES_DB
A_FILES_ALL=$PH_FILES_ALL; A_BYTES_ALL=$PH_BYTES_ALL
A_MAXFILE=$PH_MAXFILE; A_FP=$PH_FP; A_METRIC_FILES=$PH_METRIC_FILES
A_PER_NODE=$PH_PER_NODE; A_DB_PER_NODE=$PH_DB_PER_NODE

# 安装包模板默认值（静态口径；与运行期生效值一起"如实记录"）
WROT_TPL=$(sshx "${DN[0]}" "grep -E '^wal_file_size_threshold_in_byte=' $DB_DIR/conf/iotdb-system.properties.template 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r')
log "  安装包模板默认（静态）：wal_file_size_threshold_in_byte=${WROT_TPL:-<未找到>}"

wrot_run_phase B "$BIG"
B_THRESH=$PH_THRESH; B_BUF=$PH_BUF; B_COMP=$PH_COMP
B_FILES_DB=$PH_FILES_DB; B_BYTES_DB=$PH_BYTES_DB
B_FILES_ALL=$PH_FILES_ALL; B_BYTES_ALL=$PH_BYTES_ALL
B_MAXFILE=$PH_MAXFILE; B_FP=$PH_FP; B_METRIC_FILES=$PH_METRIC_FILES
B_PER_NODE=$PH_PER_NODE; B_DB_PER_NODE=$PH_DB_PER_NODE

log "--- 判据 ① 场景有效性（硬）---"
if [ -z "${A_THRESH:-}" ] || [ -z "${B_THRESH:-}" ]; then
  fail "场景无效：读不到运行期生效的 wal_file_size_threshold_in_byte（A='${A_THRESH:-}' B='${B_THRESH:-}'）⇒ 无法证明两相阈值不同"
elif [ "$A_THRESH" = "$B_THRESH" ]; then
  fail "场景无效：两相运行期生效阈值相同（都是 $A_THRESH）⇒ 配置未生效，文件数对照无意义"
else
  pass "两相生效阈值确实不同：A=$A_THRESH B=$B_THRESH（请求 A=$SMALL B=$BIG；模板默认=${WROT_TPL:-?}）"
fi
if [ "${A_FILES_DB:-0}" -ge "$MINF" ]; then
  pass "小阈值相本库 WAL 文件数=${A_FILES_DB} ≥ ${MINF}（轮转确实发生）"
else
  fail "场景无效：小阈值相本库 WAL 文件数=${A_FILES_DB}（< ${MINF}）⇒ 写入量不足，或 WAL 目录/库名过滤不对（看上面的目录清单）"
fi
[ "${A_BYTES_DB:-0}" -gt 0 ] && pass "小阈值相本库 WAL 字节=${A_BYTES_DB}B > 0（确有 WAL 落盘）" \
  || fail "场景无效：小阈值相本库 WAL 字节为 0（没有 WAL 落盘，文件面判据不可用）"

log "--- 判据 ② 轮转效果：同写入量下小阈值 ⇒ 更多文件（硬）---"
if [ "${A_FILES_DB:-0}" -gt "${B_FILES_DB:-0}" ]; then
  pass "文件数随阈值变小而增加：A(阈值 ${A_THRESH:-?})=${A_FILES_DB} > B(阈值 ${B_THRESH:-?})=${B_FILES_DB}"
else
  fail "同写入量下小阈值未产生更多 WAL 文件：A=${A_FILES_DB} B=${B_FILES_DB}（阈值 ${A_THRESH:-?} vs ${B_THRESH:-?}，写入 ${WANT} 点）⇒ 轮转阈值未生效或写入量不足以触发轮转"
fi
if [ "${A_FILES_DB:-0}" -ge $(( ${B_FILES_DB:-0} * 2 )) ]; then
  pass "小阈值相文件数达到对照相的 2 倍以上（${A_FILES_DB} vs ${B_FILES_DB}）"
else
  warn "小阈值相文件数未达对照相的 2 倍（${A_FILES_DB} vs ${B_FILES_DB}）；阈值比 $(awk -v a="$BIG" -v b="$SMALL" 'BEGIN{printf "%.0f", (b>0? a/b : 0)}') 倍，但写入量只够少量轮转，属可接受"
fi
log "  逐副本对照（本库 文件数/字节）：A相[阈值 ${A_THRESH:-?}] ${A_DB_PER_NODE:-<空>}"
log "  逐副本对照（本库 文件数/字节）：B相[阈值 ${B_THRESH:-?}] ${B_DB_PER_NODE:-<空>}"
log "  逐副本对照（全局 文件数/字节）：A相 ${A_PER_NODE:-<空>} | B相 ${B_PER_NODE:-<空>}"
wrot_margin_check "A相(阈值 $SMALL)" "$A_THRESH" "$A_BUF" "$A_MAXFILE"
wrot_margin_check "B相(阈值 $BIG)" "$B_THRESH" "$B_BUF" "$B_MAXFILE"

log "--- 判据 ③ 数据面：轮转不得丢数据（硬）---"
wrot_assert_same "两相数据面指纹（全局 count/sum + 单设备 count/sum + 每设备点数）" "$A_FP" "$B_FP"
log "  A 相：$A_FP"
log "  B 相：$B_FP"

log "--- 指标口径交叉核对（只 WARN）---"
if [ "${A_METRIC_FILES:-0}" -gt 0 ] || [ "${B_METRIC_FILES:-0}" -gt 0 ]; then
  if [ "${A_METRIC_FILES:-0}" = "${A_FILES_ALL:-0}" ]; then
    pass "指标 file_count{name=\"wal\"}=${A_METRIC_FILES} 与目录口径全局文件数一致（A 相）"
  else
    warn "指标口径与目录口径不一致（A 相）：metric=${A_METRIC_FILES} dir=${A_FILES_ALL}（只作证据，不判产品）"
  fi
else
  warn "未取到 file_count{name=\"wal\"} 指标（metric reporter / 导出形态差异）⇒ 文件数只按目录口径判定，首轮请人工核对 /metrics"
fi

log "--- 收尾三件套 ---"
export WAL_EVIDENCE_DB="$DB"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
# WAL 异常面：只装**源码里逐条核对过的轮转/刷盘失败文案**（source_grounding §10.2）
#   Fail to roll wal log writer. / Fail to trigger rolling wal node-{}'s wal file log writer.
#   Fail to roll wal node-{}'s log writer, change system mode to error.
#   Fail to sync wal node-{}'s buffer, change system mode to error.
#   Fail to fsync wal node-{}'s log writer, change system mode to error.
#   Fail to close wal node-{}'s log writer.
wal_install_err_pat 'Fail to roll wal|Fail to trigger rolling wal|Fail to sync wal node|Fail to fsync wal node|Fail to close wal node'
post_checks "select count(s1) from $DB.d1.**;" tree
cmp_case_finish "" tree ""
