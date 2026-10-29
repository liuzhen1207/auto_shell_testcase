#!/bin/bash
# ============================================================================
# W-11 WAL 压缩开关对照（enable_wal_compression false 相 vs true 相；树模型；库名 root.walcmp）
#
# 【用例】W-11（集合 compress；cases/cases.tsv W-11 行）
#   目标：同一数据量、同一轮转阈值下，未压缩相（false）与压缩相（true）对照 —— 压缩态 WAL 总字节更小
#         （压缩率低于 WAL_COMPRESS_RATIO_MIN 只 WARN）；两相数据面指纹完全一致（硬）。
#
# 【覆盖需求 / 源码依据】
#   · feature_extract.md A（WAL 压缩）：A.2 `ENABLE_WAL_COMPRESSION` 默认 **true**、**允许热加载**；
#     压缩粒度 = 每个 WALBuffer 在刷盘前压缩（"一个 WAL 文件中可能包含多个段，每段是压缩/解压的基本单位"）；
#     A.3/A.6：文档**没给压缩率阈值**（只有特定负载下"I/O 资源节约 30% 左右"），且**无日志关键字、无 metrics**
#     ⇒ 体积对比/压缩率只 WARN，过程证据用目录面 + 源码指标。
#   · source_grounding.md §4.1-4.3（**定案**）：算法 = **LZ4**（`IoTDBDescriptor.java:497-500` 把
#     enable_wal_compression 映射成 `CompressionType.LZ4` / `UNCOMPRESSED`）；压缩单元 = **一次 sync 批次的
#     buffer 段**（`LogWriter.java:110-135`）；`LogWriter.java:73-74 MIN_COMPRESSION_SIZE = 32 * 1024`
#     ⇒ **段 < 32KB 不压**；段头 1 字节标 compressionType（`LogWriter.java:136-152`）；
#     解压路径 `WALInputStream.java:487-504`（`wal_uncompress_cost` 在此记录）。
#   · source_grounding.md §1.2 第 17 项：`enable_wal_compression` = **hot_reload**（模板 :2028）。
#   · source_grounding.md §3.2/§3.4：`<dn_wal_dirs>/<identifier>/_<versionId>-<startSearchIndex>-<0|1>.wal`，
#     IoTConsensus 下 identifier = `<database>-<regionId>` ⇒ 本用例**按库隔离**统计 WAL（`*/<db>-*/*`）；
#     **文档口径分裂**：设计文档写的是 `_[version_id].wal`，源码是上面的三段式（`WALFileUtils.java:65-83`）
#     ⇒ 本用例按**源码形态**过滤/计数，文档差异只记 WARN。
#   · source_grounding.md §9：`wal_buffer{name="wal_compress_cost"}`（写入侧压缩耗时，`LogWriter.java:146`）/
#     `wal_buffer{name="wal_uncompress_cost"}`（读取侧解压耗时，`WALInputStream.java:525`）；
#     权威文件面指标 `file_count{name="wal"}` / `file_size{name="wal"}`。
#   · design_extract.md §8.1 TP-17（开启压缩相比关闭，WAL 总大小应减小；文档量级"30% 左右"不可当阈值）。
#
# 【判据（FAIL 只来自数据面 / 场景有效性）】
#   ① 场景有效性（硬）：
#      a) 两相"运行期生效值"必须一个 false、一个 true（读到相等或读不到 ⇒ 配置没生效 ⇒ FAIL，不许静默通过）；
#      b) 每相写入点数 == DEVS×ROWS×BATCHES、值总和 == 离线核算（写入丢失/被拒 ⇒ 场景无效）；
#      c) 每相**本库** WAL 增量 > 0（没有 WAL 落盘 ⇒ 文件面判据不可用）。
#   ② 数据面（硬）：两相指纹逐项相等 —— total count/sum/min/max + 每设备 count/sum/min/max +
#      d1 全序列 md5/数据行数。压缩开关**不得改变任何读数**（本用例唯一的功能判据）。
#   ③ 只 WARN：压缩态体积是否更小、压缩率是否达阈值、`wal_compress_cost` 缺失/为 0、
#      `wal_uncompress_cost`（本用例不重启 ⇒ 预期 0/缺失）、指标口径与目录口径不一致、
#      以及**单批段体积可能 < 32KB ⇒ 记"场景未成立（低于段压缩阈值）"**。
#
# 【关键口径：段 < 32KB 不压（LogWriter.java:73-74）】
#   LZ4 的压缩单元是"一次 sync 批次的 buffer 段"，小于 32KB 的段**不压**。所以本用例刻意把写入做成
#   **大语句**（每个设备每批一条 INSERT，行数 = W11_ROWS 默认 2000 ⇒ 单条语句文本数十 KB，
#   WAL Entry 序列化体积与它同量级），并额外打印"单条语句文本长度"作为现场标定证据。
#   若实测体积基本不变：判 `warn "场景未成立（低于段压缩阈值/数据不可压）"`，**不判 FAIL**
#   （不得把"没压到"当成产品缺陷）；可把 W11_ROWS 调大（如 8000）重跑。
#
# 【做法（单次集群准备 + 热切换开关，两相数据规模/时间戳/值完全相同 ⇒ 可比）】
#   相 NC（未压缩基线）：`enable_wal_compression=false` 启动 → 写库 `root.walcmpb`（**不 flush**）
#                        → 等 ASYNC fsync + 采样稳定 → 量本库 WAL 增量。
#   相 C （压缩态）    ：`SET CONFIGURATION 'enable_wal_compression'='true'`（源码印证 hot_reload；
#                        用例仍核对返回文案与生效值，必要时补一次 stop/start）→ DROP 基线库
#                        （避免基线库 WAL 变化污染对照）→ 写库 `root.walcmp`（同样不 flush）→ 量增量。
#   两相数据规模/时间戳基准/值公式**完全相同**，且两个库名互不前缀包含（root.walcmp 与 root.walcmpb
#   的 `-path '*/<db>-*/*'` 过滤不会互相命中）⇒ 库级 WAL 增量可直接比。
#
# 【刻意不做的事】
#   · 不 flush（flush 会把对应 WAL 置为无效并被删除线程清理，体积对照就失去意义）。
#   · 不判"压缩态体积未变小"为 FAIL（段 < 32KB / 数据不可压都可能）；不判压缩率倍数。
#   · 不断言 `WALNode.java:466-470` 的"删除过期 WAL 条数"文案（DEBUG 级、默认不落盘）。
#   · 不改 lib/、tools/、conf/、cases.tsv、docs/（只新增本文件）。
#
# 【时长大致】≈22~28 分钟（准备 ~4min + 未压缩相 ~6min + 热切换/清库 ~2min + 压缩相 ~6min
#   + 收尾三件套 ~4min）。可调：W11_DEVS/W11_ROWS/W11_BATCHES/W11_WAIT_SEC/W11_STABLE_WIN_SEC。
#
# 【⚠️ 首轮 watch list（先看这些才知道"场景真的成立了"）】
#   1) **单条 INSERT 的实际字符数与本库 WAL 增量**（文件头判据要用）：若 WAL 增量 < 32KB，
#      说明单批段低于压缩阈值 ⇒ 用例只记"场景未成立"+WARN，此时把 W11_ROWS 调到 8000 重跑。
#   2) **`enable_wal_compression` 的生效证据链**：`show configuration` 是否暴露该键（用例会回退读
#      properties），`SET CONFIGURATION` 返回文案里**有没有** "restart is required"（源码印证是 hot_reload，
#      若实测要求重启，用例会自动补一次 stop/start 并记录 ⇒ 这条要重点核对）。
#   3) **WALNode 目录名与库名过滤**：预期 `*/root.walcmp-<regionId>/`；若本库文件数恒 0（会以"场景无效"FAIL），
#      看日志里打印的 identifier 目录清单与文件清单，按现场标定修正过滤。
#   4) **两个压缩指标的真实导出形态**：`wal_buffer{name="wal_compress_cost"}` 在 Prometheus 里可能是
#      `wal_buffer_max{...}`/`wal_buffer_sum{...}`（histogram）。本用例同时用 lib helper（`^wal_buffer\{`）
#      与"原始行宽松匹配"两条路取数，并把命中样例打进产物 —— 首轮据此确认口径。
#   5) **DROP 基线库后 WAL 是否真的消失**（只影响逐副本证据的可读性，不影响判据，因为判据按库过滤）。
#
# 用法： bash cases/common/wal_compress_toggle.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 本文件**未在真实集群实跑过**（99.80 正在跑合并长回归，禁止任何集群启停/清库动作）；
#     只保证逻辑自洽 + `bash -n` 通过 + harness 自检不退化。
#
# 【RC8 首轮失败根因 + 修法（2026-10-18，均为用例侧取值/算术 bug，判据一条没动）】
#   ① `awk: backslash not last character on line` + `line 250/251: s +  : syntax error: operand expected`：
#      `w11_raw_val()` 里的 awk 程序写在**单引号**里却写成了 `{s+=\$NF}`（`\$` 只在本层双引号内才是"字面 $"），
#      awk 收到字面 `\$NF` 直接报错、取数返回空串；空串再进 `$(( s + ... ))` ⇒ 算术报 `s +  : operand expected`。
#      修法：单引号内改回 `{s+=$NF}`，并给所有参与求和的取数加 `w11_num()` 守卫（非数字/空一律记 0），
#      **只修取值与算术，`wal_compress_cost` 判据与"未变小只 WARN"的口径完全不变**。
#   ② 顺带把 w11_num() 的守卫口径写进注释（浮点只取整数部分；段压缩指标可能是 `wal_buffer_sum{...}`）。
# ----------------------------------------------------------------------------
#   ⚠ 本轮（RC8 第二轮，2026-10-20）修掉指纹的三处**取值路径** bug（判据一条没动）：
#     ① `total_min_sum`/`total_max_sum` 空（`select min(s1) from <db>.**` 在本版本报
#        701 `Error occurred during inferring UDF data type`）⇒ 改成**逐设备**取值再本地汇总；
#     ② `dev_dN` 的 `min=`/`max=` 空（`min`/`max` 不是本版本内建名，且 4 聚合混查报 701
#        hybrid）⇒ 改成一条查询只放一个聚合、用 `min_value`/`max_value`、只查设备路径；
#     ③ `d1_seq_md5` 两相不等（原始输出里的 `It costs 0.0xx s` 每相都不同）⇒ md5 前先
#        `data_rows`；**"md5 必须相等"仍是硬判据**，只是不再被统计行污染。
#   仍**未改**：① "值总和 实际=10×期望" 属期望值总和公式（由另一处修改负责）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"

# harness 侧防御：conf/env.conf 未定义这三个 TTL 键，而 lib/common.sh 的 cluster_set_conf 会引用它们
# （`set -u` 下未定义会让"写配置"这一步直接终止整个用例）
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"
export TTL_CHECK_INTERVAL_MS MAX_EXPIRED_TIME_MS EXPIRED_DATA_RATIO

cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_compress_toggle_${DATA_CONSENSUS}"

DB=root.walcmp                        # 压缩相（true）
DBNC=root.walcmpb                     # 未压缩基线相（false；库名仍在 root.wal* 约定内）
DEVS=${W11_DEVS:-${WAL_COMPRESS_DEVS:-10}}
ROWS=${W11_ROWS:-${WAL_COMPRESS_ROWS:-2000}}          # 同时是每条 INSERT 的行数（大语句 ⇒ 段体积 > 32KB）
BATCHES=${W11_BATCHES:-${WAL_COMPRESS_BATCHES:-4}}
WAIT=${W11_WAIT_SEC:-${WAL_KILL_WAIT_SEC:-60}}        # 等 ASYNC fsync 周期落盘（两相等时长）
STABLE_WIN=${W11_STABLE_WIN_SEC:-90}                  # WAL 观测量稳定的窗口
RATIO_MIN=${WAL_COMPRESS_RATIO_MIN:-1.2}              # 压缩后至少应缩小到这个倍数（低于只 WARN）
SEG_MIN=32768                                         # LogWriter.java:73-74 MIN_COMPRESSION_SIZE
WANT=$(( DEVS * ROWS * BATCHES ))
BASE_TS=$(( ($(date +%s) - 3600) * 1000 ))            # **两相共用**同一时间戳基准 ⇒ 指纹可直接比
STMT_CHARS=0                                          # 单条 INSERT 文本长度（现场标定证据）
W11_FILES=0; W11_BYTES=0

# 相 NC 的配置串（**显式列全所有键**，避免与 WAL_EXTRA_DEFAULT 同名键重复 ⇒ cluster_write_conf 假 FAIL）
W11_EXTRA_NC="wal_mode=${WAL_MODE},enable_wal_compression=false,wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_FILE_THRESHOLD_BYTES},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_DELETE_PERIOD_MS},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 写入（**不 flush**；大语句）-----------------------------------------
# 值/时间戳确定：设备 d 第 b 批第 k 行 ⇒ 值 = k + b，ts = BASE_TS + b*1000000 + k*10
w11_write_nf(){ local db=$1 base=$2 b d k vals ts logf n=0
  local -a S=()
  logf="$ART/w11_write_${db##*.}.log"; : >"$logf"
  for (( b=1; b<=BATCHES; b++ )); do
    S=()
    for (( d=1; d<=DEVS; d++ )); do
      vals=""
      for (( k=0; k<ROWS; k++ )); do
        ts=$(( base + b * 1000000 + k * 10 ))
        vals="$vals($ts,$(( k + b ))),"
      done
      S+=("insert into $db.d$d(time,s1) values ${vals%,};")
      n=$(( n + 1 ))
    done
    STMT_CHARS=${#S[0]}
    sql_lines_tree "${S[@]}" >>"$logf" 2>&1 || return 1
  done
  if grep -qiE 'IoTDBSQLException|Exception|ERROR' "$logf"; then
    fail "  [$db] 写入出现异常：$(grep -iE 'Exception|ERROR' "$logf" | head -2 | tr '\n' ' ' | cut -c1-200)"
    return 1
  fi
  log "  [$db] 写入完成：$n 条大语句 × $ROWS 行 = $(( DEVS * ROWS * BATCHES )) 点（**未 flush**；单条语句文本 ${STMT_CHARS} 字符）"
  return 0; }
w11_exp_count(){ echo $(( DEVS * ROWS * BATCHES )); }
w11_exp_sum(){ local s
  s=$(( BATCHES * ROWS * (ROWS - 1) / 2 + ROWS * BATCHES * (BATCHES + 1) / 2 ))
  echo $(( DEVS * s )); }

# ---- ② 指纹（两相必须逐项相等）---------------------------------------------
# 单设备四项一律走 lib/wal_ext.sh 的 `wal_dev_fp4`（RC8 第二轮修，见 wal_ext.sh ⑬）：
#   · **一条查询只放一个聚合**（`count,sum,min,max` 混在一条里报 701 hybrid query，
#     设备路径 `$dev` 与序列路径 `$dev.s1` 都报 ⇒ 旧代码的"报错才拆分"兜底永远走不到正路）；
#   · 只查**设备路径** `db.dN`；`min`/`max` 不是本版本内建名（要写 `min_value`/`max_value`）；
#   · 取不到值写 `ERR`，不再静默输出 `min= max=`。
w11_dev_agg(){ wal_dev_fp4 "$1"; }
w11_fp_dump(){ local db=$1 f=$2 i
  : >"$f"
  printf 'total_count=%s\n' "$(row_sum "$(sq "select count(s1) from $db.**;")")"  >>"$f"
  printf 'total_sum=%s\n'   "$(row_sum "$(sq "select sum(s1) from $db.**;")")"    >>"$f"
  # min/max 汇总**逐设备**取值再在本地相加（`select min(s1) from <db>.**` 在本版本 701
  # `Error occurred during inferring UDF data type` ⇒ 指纹曾经是 `total_min_sum=`（空））
  printf 'total_min_sum=%s\n' "$(wal_dev_sum_of min "$db" "$DEVS")"              >>"$f"
  printf 'total_max_sum=%s\n' "$(wal_dev_sum_of max "$db" "$DEVS")"              >>"$f"
  for (( i=1; i<=DEVS; i++ )); do printf 'dev_d%s=%s\n' "$i" "$(w11_dev_agg "$db.d$i")" >>"$f"; done
  # ⚠ 必须只取**数据行**（data_rows）再算 md5：CLI 的表头里含序列全路径
  #   （`|Time|root.walcmpb.d1.s1|`），原始输出里还有每相都不同的 `It costs 0.0xx s` 统计行
  #   ⇒ 直接喂 md5sum 会让指纹**必然**不一致（本项目踩过同类"表头/统计行污染指纹"的坑）。
  #   判据不变：两相 `d1_seq_md5` 必须相等（只修取值路径；见 wal_ext.sh 的 wal_seq_fp）。
  wal_seq_fp "$db" >>"$f"
  log "  指纹已落盘：$f（$(grep -c . "$f") 项）"
  sed 's/^/      /' "$f" >>"$OUT"
  grep -q '=ERR' "$f" && fail "  指纹查询报错（见上面 =ERR 项）：先确认设备路径写法在本版本可用"; }
w11_fp_compare(){ local label=$1 f0=$2 f1=$3 res same total
  res=$(awk 'NR==FNR{a[FNR]=$0; n=FNR; next}{ if($0==a[FNR]){c++} else {printf "  DIFF 第%d项: [%s] -> [%s]\n", FNR, a[FNR], $0} } END{printf "SAME=%d TOTAL=%d\n", c+0, n+0}' "$f0" "$f1")
  same=$(printf '%s\n' "$res" | grep -oE 'SAME=[0-9]+' | cut -d= -f2)
  total=$(printf '%s\n' "$res" | grep -oE 'TOTAL=[0-9]+' | cut -d= -f2)
  log "  指纹逐项比对（$label）：一致 ${same:-0} / 共 ${total:-0} 项"
  awk 'NR==FNR{a[FNR]=$0; next}{ printf "      [%s] %s -> %s\n", ($0==a[FNR] ? "一致" : "不一致"), a[FNR], $0 }' "$f0" "$f1" >>"$OUT"
  printf '%s\n' "$res" | grep 'DIFF' | sed 's/^/      /' >>"$OUT"
  assert_eq "  指纹逐项一致项数（$label）" "${same:-0}" "${total:-0}"
  assert_eq "  指纹项数（缺失/多余都不允许，$label）" "$(grep -c . "$f1")" "$(grep -c . "$f0")"
  # 【2026-10-23 加】指纹不一致时落盘**行级证据**：RC10 上实测 `d1_seq_md5` 两项不同，而
  # count=8000 / sum=8016000.0 / min=1 / max=2003 两相完全一致，且时间戳是确定性公式生成的
  # ⇒ 不是排序问题，疑似"丢一行 + 重复一行"或时间戳错位。只有把两相的行 dump 出来 diff 才能定位。
  if [ "${same:-0}" != "${total:-0}" ] && [ -n "${DBNC:-}" ] && [ -n "${DB:-}" ]; then
    # 用**指纹时刻**落盘的行做 diff（不要重新查询：实测重新查询时 NC 相已返回 EMPTY）
    local f_nc="$ART/d1_seq_${DBNC}.rows" f_c="$ART/d1_seq_${DB}.rows"
    log "  !! 指纹不一致 ⇒ 用指纹时刻的行做 diff：$(basename "$f_nc") vs $(basename "$f_c")"
    if [ -s "$f_nc" ] && [ -s "$f_c" ]; then
      log "    行数：NC=$(grep -c . "$f_nc") C=$(grep -c . "$f_c")"
      diff "$f_nc" "$f_c" | head -40 | sed 's/^/      /' >>"$OUT" 2>&1
    else
      warn "    指纹时刻的行文件缺失（NC=$(test -s "$f_nc" && echo yes || echo no)、C=$(test -s "$f_c" && echo yes || echo no)）⇒ 本次无法 diff"
    fi
  fi }
# 每设备点数（一行 N 列）
w11_check_devcounts(){ local line=$1 want=$2 n bad
  n=$(printf '%s' "$line" | awk -F'|' '{c=0; for(i=1;i<=NF;i++){v=$i; gsub(/[^0-9]/,"",v); if (v!="") c++} print c}')
  bad=$(printf '%s' "$line" | awk -F'|' -v w="$want" '{b=0; for(i=1;i<=NF;i++){v=$i; gsub(/[^0-9]/,"",v); if (v!="" && v+0 != w) b++}} END{print b+0}')
  if [ "${n:-0}" -eq "$DEVS" ] && [ "${bad:-1}" -eq 0 ]; then
    pass "  每设备点数正确：$n 个设备均为 $want 点"
  else
    fail "  每设备点数异常：设备列数=$n（期望 $DEVS），与期望 $want 不符的列数=${bad:-?}；原始首行=$(printf '%s' "$line" | cut -c1-200)"
  fi; }

# ---- ③ 库级 WAL 文件面（identifier = <database>-<regionId>，source_grounding §3.2）----
w11_db_files(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$db-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w11_db_bytes(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$db-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w11_ident_dirs(){ local h=$1 db=$2
  sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 2 -type d -name '$db-*' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w11_cnt(){ local f=$1 db=$2 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h" "$db") )); done; echo "$s"; }
w11_per_node(){ local db=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(w11_db_files "$h" "$db")f/$(w11_db_bytes "$h" "$db")B "; done; echo "$out"; }
# 取本库口径（identifier 目录存在）否则退回整目录口径（只改证据口径，不改判据方向）
w11_snap(){ local tag=$1 db=$2 dbf dbb alf alb
  dbf=$(w11_cnt w11_db_files "$db"); dbb=$(w11_cnt w11_db_bytes "$db")
  alf=$(wal_sum_over_dn wal_file_cnt); alb=$(wal_sum_over_dn wal_dir_bytes)
  if [ -n "$(w11_ident_dirs "${DN[0]}" "$db")" ]; then W11_SCOPE=db; W11_FILES=$dbf; W11_BYTES=$dbb
  else W11_SCOPE=all; W11_FILES=$alf; W11_BYTES=$alb; fi
  log "  [WAL 快照/$tag] 口径=$W11_SCOPE files=$W11_FILES bytes=$W11_BYTES（本库 ${dbf}f/${dbb}B；整目录 ${alf}f/${alb}B；逐副本 $(w11_per_node "$db")）"
  log "  [指标/$tag] file_count{wal}=$(wal_metric_sum_over_dn wal_metric_file_cnt) file_size{wal}=$(wal_metric_sum_over_dn wal_metric_file_bytes)"; }
w11_wait_stable(){ local tag=$1 db=$2 dl f0="" b0="" f b n=0
  dl=$(( $(date +%s) + STABLE_WIN ))
  while (( $(date +%s) < dl )); do
    w11_snap "$tag/稳定采样" "$db"
    f=$W11_FILES; b=$W11_BYTES
    if [ "$f" = "$f0" ] && [ "$b" = "$b0" ]; then
      n=$(( n + 1 )); [ "$n" -ge 2 ] && { log "  [$tag] WAL 观测已稳定（files=$f bytes=$b）"; return 0; }
    else
      n=0
    fi
    f0=$f; b0=$b
    sleep 5
  done
  warn "  [$tag] WAL 观测在 ${STABLE_WIN}s 内未稳定（files=$f bytes=$b）——继续，对照数值仅供记录"; return 0; }

# ---- ④ 压缩指标：lib helper + 原始行宽松匹配（首轮标定两口径）----------------
w11_raw_lines(){ local h=$1 rx=$2
  sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '$rx'" 2>/dev/null | tr -d '\r'; }
w11_raw_val(){ local h=$1 rx=$2; w11_raw_lines "$h" "$rx" | awk '{s+=$NF} END{print s+0}'; }
w11_raw_cnt(){ w11_raw_lines "$1" "$2" | grep -c . ; }
w11_mcost_one(){ local h=$1; wal_metric_buffer "$h" wal_compress_cost; }
w11_munc_one(){ local h=$1; wal_metric_buffer "$h" wal_uncompress_cost; }
# ⚠ 不用 lib 的 wal_metric_sum_over_dn 求这两个和：Prometheus 的 histogram 值可能是**浮点**
#   （如 `_max`/`_mean`），lib 内部用 `$(( ))` 求和会报 "invalid arithmetic operator" ⇒ 结果为空。
#   这里用 awk 求和（浮点安全），并把整数值打印成整数以便阅读。
w11_sum_metric(){ local f=$1 h v out=""
  for h in "${DN[@]}"; do
    v=$($f "$h")
    out="$out${v:-0}
"
  done
  printf '%s' "$out" | awk '{s+=$1} END{ if (s==int(s)) printf "%d", s; else printf "%.6f", s }'; }
w11_compress_cost(){ w11_sum_metric w11_mcost_one; }
w11_uncompress_cost(){ w11_sum_metric w11_munc_one; }
# ⚠ `$(( ))` 里绝不能塞空串/带小数点的指标值：RC8 首轮这两行报了
#   `s +  : syntax error: operand expected (error token is "+  ")`（上游 awk 取数失败返回空）。
#   ⇒ 所有参与求和的取数先过 w11_num() 守卫（只接受非负整数，其余一律记 0），再进算术。
w11_num(){ local v="${1:-}"; v="${v%%.*}"; v="${v//[!0-9]/}"; printf '%s' "${v:-0}"; }
w11_raw_cmp_cost(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(w11_num "$(w11_raw_val "$h" '^wal_buffer(_[a-z]+)?\{[^}]*name="wal_compress_cost"')") )); done; echo "$s"; }
w11_raw_unc_cost(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(w11_num "$(w11_raw_val "$h" '^wal_buffer(_[a-z]+)?\{[^}]*name="wal_uncompress_cost"')") )); done; echo "$s"; }
w11_raw_cmp_lines(){ local h n s=0; for h in "${DN[@]}"; do n=$(w11_raw_cnt "$h" '^wal_buffer(_[a-z]+)?\{[^}]*name="wal_compress_cost"'); s=$(( s + $(w11_num "${n:-0}") )); done; echo "$s"; }
w11_metric_evidence(){ local cc uc rcc ruc rl
  cc=$(w11_compress_cost); uc=$(w11_uncompress_cost)
  rcc=$(w11_raw_cmp_cost); ruc=$(w11_raw_unc_cost); rl=$(w11_raw_cmp_lines)
  log "  压缩指标：lib 口径 wal_compress_cost=$cc wal_uncompress_cost=$uc（逐副本 $(wal_metric_per_node w11_mcost_one)）"
  log "  压缩指标：原始行宽松口径 行数=$rl 值和 compress=$rcc uncompress=$ruc"
  log "  原始行样例（${DN[0]}，含 wal_buffer 的前 6 行）：$(w11_raw_lines "${DN[0]}" '^wal_buffer' | head -6 | tr '\n' ' ' | cut -c1-400)"
  W11_CC=$cc; W11_UC=$uc; W11_RCC=$rcc; W11_RL=$rl; }

# ---- ⑤ 一个阶段：写前快照 → 建库写入 → 可见性/点数 → 等落盘 → 稳定采样 ----------
w11_run_phase(){ local tag=$1 db=$2 base=$3 bf bb cnt sm devc
  bf=$(w11_cnt w11_db_files "$db"); bb=$(w11_cnt w11_db_bytes "$db")
  log "--- 阶段 $tag（库 $db）：写前本库 WAL = ${bf}f/${bb}B ---"
  cmp_make_tree_db "$db" "$DEVS"
  w11_write_nf "$db" "$base" || true
  wait_scalar_tree "select count(s1) from $db.d1;" "$(( ROWS * BATCHES ))" 120 "[$tag] 写入后可见性（$db.d1）"
  cnt=$(row_sum "$(sq "select count(s1) from $db.**;")")
  sm=$(row_sum "$(sq "select sum(s1) from $db.**;")")
  devc=$(sq "select count(s1) from $db.**;" | table_rows | head -1 | sed -E 's/[[:space:]]+/ /g')
  assert_eq "  [$tag] 写入点数（场景有效性）" "${cnt:-0}" "$WANT"
  assert_eq "  [$tag] 值总和（离线核算）" "${sm:-0}" "$(w11_exp_sum)"
  w11_check_devcounts "$devc" "$(( ROWS * BATCHES ))"
  w11_fp_dump "$db" "$ART/fp_${tag}.txt"
  log "  等 ${WAIT}s 让 ASYNC fsync 周期把 WAL 落到盘上（两相等时长 ⇒ 对照公平）"
  sleep "$WAIT"
  w11_wait_stable "$tag" "$db"
  PH_FILES=$W11_FILES; PH_BYTES=$W11_BYTES
  PH_DF=$(( PH_FILES - bf )); PH_DB=$(( PH_BYTES - bb ))
  log "  [$tag] 本库 WAL：写前 ${bf}f/${bb}B → 写后 ${PH_FILES}f/${PH_BYTES}B（增量 ${PH_DF}f/${PH_DB}B）"
  return 0; }

# ---- ⑥ 失败取证 -------------------------------------------------------------
w11_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(dn_state "$h")；WAL 根目录=$(wal_dir_roots "$h" | tr '\n' ' ')"
    log "  [$h] identifier 目录（$DB）：$(w11_ident_dirs "$h" "$DB" | tr '\n' ' ')"
    log "  [$h] identifier 目录（$DBNC）：$(w11_ident_dirs "$h" "$DBNC" | tr '\n' ' ')"
    log "  [$h] WAL 清单（含大小）："
    wal_ls "$h" | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] WAL 指标：files=$(wal_metric_file_cnt "$h") bytes=$(wal_metric_file_bytes "$h") compress_cost=$(w11_mcost_one "$h")"
    log "  [$h] WAL 相关日志尾部："
    wal_log_tail "$h" 15 | sed 's/^/        /' >>"$OUT" 2>&1
  done
  log "  show cluster："
  sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"
  log "=== 逐副本证据结束（$tag）==="; }

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-11 WAL 压缩开关对照：未压缩库=$DBNC / 压缩库=$DB；规模 ${DEVS} 设备 × ${ROWS} 点/批 × ${BATCHES} 批 = ${WANT} 点 ==="
log "  期望 count=$(w11_exp_count) sum=$(w11_exp_sum)（两相完全相同 ⇒ 指纹可直接比）"
log "  未压缩相配置：$W11_EXTRA_NC"
log "  段压缩阈值：${SEG_MIN}B（LogWriter.java:73-74；段 < 该值不压）"

log "--- ① 集群准备（先以 enable_wal_compression=false 起步，采未压缩基线）---"
EXTRA_CONF="$W11_EXTRA_NC" cmp_cluster_prepare
log "  合并参数生效值（抽查）：$(cmp_eff_all "${DN[0]}")"
NC_EFF=$(wal_eff "${DN[0]}" enable_wal_compression); [ -z "${NC_EFF:-}" ] && NC_EFF=$(wal_props_get "${DN[0]}" enable_wal_compression)
log "  运行期/配置值 enable_wal_compression=${NC_EFF:-<读不到>}"
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done

log "--- ② 相 NC（未压缩基线）：不 flush 写入 $DBNC ---"
w11_run_phase NC "$DBNC" "$BASE_TS"
NC_FILES=$PH_FILES; NC_BYTES=$PH_BYTES; NC_DF=$PH_DF; NC_DB=$PH_DB
w11_metric_evidence
NC_CC=$W11_CC; NC_UC=$W11_UC; NC_RCC=$W11_RCC; NC_RL=$W11_RL

log "--- ③ 热切换到 enable_wal_compression=true（源码印证 hot_reload；用例仍核对生效值）---"
RESP=$(wal_set enable_wal_compression true)
log "  SET CONFIGURATION 'enable_wal_compression'='true' → $(printf '%s' "$RESP" | cut -c1-200)"
NEED_RESTART=0
case "$RESP" in *"restart is required"*|*"Restart is required"*) NEED_RESTART=1 ;; esac
C_EFF=$(wal_eff "${DN[0]}" enable_wal_compression); [ -z "${C_EFF:-}" ] && C_EFF=$(wal_props_get "${DN[0]}" enable_wal_compression)
if [ "${C_EFF:-}" = "true" ] && [ "$NEED_RESTART" = 0 ]; then
  pass "  压缩开关已热生效（无需重启；生效值=true）"
else
  warn "  热改未直接生效（生效值='${C_EFF:-空}' 返回要求重启=$NEED_RESTART）⇒ 补一次 stop/start 让配置生效（不清 data）"
  cluster_stop; cluster_start
  C_EFF=$(wal_eff "${DN[0]}" enable_wal_compression); [ -z "${C_EFF:-}" ] && C_EFF=$(wal_props_get "${DN[0]}" enable_wal_compression)
fi

log "--- ④ 清掉基线库并等 WAL 观测量稳定（避免基线库的 WAL 变化污染压缩相增量）---"
sq "drop database $DBNC;" >/dev/null 2>&1 || warn "  DROP $DBNC 非 0（记录；仅影响证据可读性，判据按库过滤不受影响）"
sleep 10
w11_wait_stable "C/写前基线" "$DB"

log "--- ⑤ 相 C（压缩态）：**不 flush** 写入 $DB ---"
w11_run_phase C "$DB" "$BASE_TS"
C_FILES=$PH_FILES; C_BYTES=$PH_BYTES; C_DF=$PH_DF; C_DB=$PH_DB
w11_metric_evidence
C_CC=$W11_CC; C_UC=$W11_UC; C_RCC=$W11_RCC; C_RL=$W11_RL

log "--- 判据 ① 场景有效性（硬）---"
if [ -z "${NC_EFF:-}" ] || [ -z "${C_EFF:-}" ]; then
  fail "场景无效：读不到运行期生效的 enable_wal_compression（未压缩相='${NC_EFF:-}' 压缩相='${C_EFF:-}'）⇒ 无法证明两相开关不同"
elif [ "$NC_EFF" = "$C_EFF" ]; then
  fail "场景无效：两相生效值相同（都是 $NC_EFF）⇒ 压缩开关未生效，体积对照无意义"
else
  pass "两相生效值确实不同：未压缩相=$NC_EFF 压缩相=$C_EFF（hot_reload 返回要求重启=$NEED_RESTART）"
fi
[ "${NC_DB:-0}" -gt 0 ] && pass "未压缩相本库 WAL 增量=${NC_DB}B > 0（确有 WAL 落盘）" \
  || fail "场景无效：未压缩相本库 WAL 增量为 0（没有 WAL 落盘，体积对照不可用）"
[ "${C_DB:-0}" -gt 0 ] && pass "压缩相本库 WAL 增量=${C_DB}B > 0（确有 WAL 落盘）" \
  || fail "场景无效：压缩相本库 WAL 增量为 0（没有 WAL 落盘，体积对照不可用）"
log "  单批数据量证据：单条 INSERT 文本 ${STMT_CHARS} 字符（× ${DEVS} 设备/批）；"
log "  未压缩相 WAL 增量 ${NC_DB}B（${NC_DF} 文件）vs 压缩相 ${C_DB}B（${C_DF} 文件）"

log "--- 判据 ② 数据面：两相指纹逐项相等（硬；压缩开关不得改变任何读数）---"
w11_fp_compare "未压缩相 vs 压缩相" "$ART/fp_NC.txt" "$ART/fp_C.txt"

log "--- 判据 ③ 体积/压缩率对照（**软**：段 < 32KB 不压 ⇒ 未变小不判 FAIL）---"
if [ "${C_DB:-0}" -lt "${NC_DB:-0}" ]; then
  RATIO_TXT=$(awk -v a="$NC_DB" -v b="$C_DB" 'BEGIN{printf "%.2f", (b>0 ? a/b : 0)}')
  pass "对照成立：压缩态更小（未压缩 ${NC_DB}B → 压缩态 ${C_DB}B，压缩率约 ${RATIO_TXT}x；参考阈值 ${RATIO_MIN}x）"
  awk -v r="$RATIO_TXT" -v m="$RATIO_MIN" 'BEGIN{exit !(r+0 < m+0)}' \
    && warn "压缩率 ${RATIO_TXT}x 低于参考阈值 ${RATIO_MIN}x（数据可压性/段体积相关，只 WARN，不当门禁）"
else
  warn "场景未成立（低于压缩阈值/数据不可压）：压缩态体积没有变小（未压缩 ${NC_DB}B/${NC_DF}f，压缩态 ${C_DB}B/${C_DF}f）；源码口径为 LZ4 且**段 < ${SEG_MIN}B 不压**（LogWriter.java:73-74）⇒ 只 WARN，不判 FAIL；可把 W11_ROWS 调大（如 8000）重跑。当前单条语句文本 ${STMT_CHARS} 字符"
fi
if [ "${C_DB:-0}" -lt "$SEG_MIN" ] && [ "${NC_DB:-0}" -lt "$SEG_MIN" ]; then
  warn "单批 WAL 体积（未压缩 ${NC_DB}B / 压缩 ${C_DB}B）低于段压缩阈值 ${SEG_MIN}B ⇒ 记「场景未成立（低于段压缩阈值）」：本用例的压缩对照在本次数据量下不可判定"
fi
if [ "${C_RL:-0}" -gt 0 ] || [ "${C_CC:-0}" -gt 0 ]; then
  pass "正面证据：wal_buffer{name=\"wal_compress_cost\"} 命中（lib 口径值=${C_CC}，原始行数=${C_RL} 值和=${C_RCC}；未压缩相 lib 口径值=${NC_CC}）"
else
  warn "未取到 wal_buffer{name=\"wal_compress_cost\"}（lib 口径=${C_CC}，原始行匹配=${C_RL} 行）⇒ 只 WARN（指标导出形态/版本差异），压缩过程证据改用体积+数据面"
fi
log "  解压指标 wal_uncompress_cost：未压缩相 lib 口径=${NC_UC:-0} / 压缩相 lib 口径=${C_UC:-0}（本用例不重启 ⇒ 读取侧解压不发生，0/缺失属预期，不作判据）"
if [ "${NC_FILES:-0}" -gt 0 ] && [ "${C_FILES:-0}" -gt 0 ]; then
  log "  文件数对照（只记录）：未压缩相 ${NC_FILES}f vs 压缩相 ${C_FILES}f —— 轮转判据用**未压缩累计字节**（source_grounding §5.3），故两相文件数接近属正常"
fi

log "--- 过程证据（目录/指标口径逐副本）---"
for h in "${DN[@]}"; do
  log "  [$h] 未压缩库：$(w11_db_files "$h" "$DBNC")f/$(w11_db_bytes "$h" "$DBNC")B | 压缩库：$(w11_db_files "$h" "$DB")f/$(w11_db_bytes "$h" "$DB")B | 指标 file_count=$(wal_metric_file_cnt "$h") file_size=$(wal_metric_file_bytes "$h")"
done
OOM=$(wal_oom_cnt); assert_eq "  WAL 相关 OOM 日志行数（必须 0）" "${OOM:-0}" "0"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w11_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 专属异常正则）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat 'Failed to load WAL segment|Unexpected error when loading a wal segment|Fail to read WALEntry from wal file|Fail to roll wal|Fail to sync wal node|Fail to fsync wal node'
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader|Connection reset by peer'
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
