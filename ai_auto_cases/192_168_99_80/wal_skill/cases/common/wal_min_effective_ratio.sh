#!/bin/bash
# ============================================================================
# W-15 wal_min_effective_info_ratio 的门控方向（MemTable 快照 vs 刷盘；树模型；库名 root.walratio）
#
# 【用例】W-15（集合 cleanup；cases/cases.tsv W-15 行）
#   目标：`wal_min_effective_info_ratio`（**hot_reload**）调大/调小后，"WAL 删除线程"是否真的按有效信息比
#   去快照/刷盘 MemTable —— 用**指标方向性 + 文件面**判定，数据面必须始终一致。
#   构造：先写一大批并 flush（制造"WAL 里大量记录已无效"），再写一小批**不 flush**
#   （活跃 MemTable 的 RAM 很小，而无效 WAL 的磁盘量很大 ⇒ 有效信息比很低）⇒
#   调大阈值（0.99）应触发快照/刷盘；调小阈值（1e-6）不应触发。
#
# 【覆盖需求 / 源码依据】
#   · design_extract.md §5.3（原文）：「WAL 文件的最小有效信息比（即其中未刷盘的 MemTable 所对应的 WAL
#     的比例），有效信息比小于该值后会触发 memTable 快照或刷盘并删除无效 WAL 文件；默认为 0.1；（热加载）」；
#     §5.4/§6.3.1 的删除线程流程图：先判「WAL 文件有效信息占比低于阈值或 WAL 文件总大小达到上限？」
#     → 是则「版本号最小的 MemTable 快照 or 刷盘」→ 等待 `delete_wal_files_period_in_ms`。
#   · source_grounding.md §1.2 第 10 项：`wal_min_effective_info_ratio` 默认 0.1、**hot_reload**
#     （模板 :1989，`IoTDBDescriptor.java:2216-2224`）；§1.3：解析处 `if (walMinEffectiveInfoRatio > 0)`
#     ⇒ 设 0 或负数**不生效**（仍为 0.1），所以本用例两相都取正数（1e-6 与 0.99）。
#   · source_grounding.md §6.3（**定案**）：`WALNode.java:506-510 shouldSnapshotOrFlush()` =
#     `effectiveInfoRatio < getWalMinEffectiveInfoRatio() || WALManager.getInstance().shouldThrottle()`；
#     ratio 定义 `WALNode.java:438-455`：`ratio = costOfActiveMemTables / totalCost`，
#     `totalCost = (currentWALFileVersion - oldestUnpinnedMemTableInfo.firstFileVersionId) * avgFileSize`，
#     且 `costOfActiveMemTables == 0 || totalCost == 0` 时**直接置 1.0**（⇒ 无活跃 MemTable 时永不触发）。
#   · source_grounding.md §6.4 快照 vs flush 的选择（`WALNode.java:546-559`）：时间分区更旧、
#     累计快照数 ≥ `max_wal_memtable_snapshot_num`、MemTable RAM > `wal_memtable_snapshot_threshold_in_byte`
#     ⇒ `flushMemTable` + `recordWalFlushMemTableCount(1)` + `recordMemTableRamWhenCauseFlush`；
#     否则 `snapshotMemTable` + `recordMemTableRamWhenCauseSnapshot`。
#   · source_grounding.md §9 指标（**判据来源**）：
#     `wal_node_info{name="effective_ratio_info"}`（值 = ratio×100，`WritingMetrics.java:768-778`）、
#     `wal_node_info{name="oldest_mem_table_ram_when_cause_snapshot"}`（`WALNode.java:649-650`）、
#     `wal_node_info{name="oldest_mem_table_ram_when_cause_flush"}`（`WALNode.java:556`）、
#     `flush_memtable_count{type="wal_flush_memtable_count"}`（Counter，`WALNode.java:555`）。
#     这三个"WAL 路径"指标**只在删除线程的快照/刷盘分支被记录**，所以用它们判方向不受
#     "内存压力触发的普通 flush"干扰。
#
# 【判据（硬/软分明）】
#   ① 场景有效性（硬）：写入点数/值总和 == 离线核算；写入后**本目录 WAL 非空** 且发生了轮转
#      （≥WAL_CLEAN_MIN_FILES 个文件，否则"有效信息比"的 totalCost 几乎为 0）；两相阈值**热改后生效值**
#      分别等于设定值（读不到/没变 ⇒ 配置没生效 ⇒ FAIL）；"无效 WAL"前提成立：
#      第一批数据确实落盘（出现新的 `Async close tsfile` 事件）。
#   ② 门控负向（硬，本用例最强的判据）：阈值调到 **1e-6**（几乎不该触发）的观察窗口内，
#      WAL 路径动作增量必须为 **0** —— `flush_memtable_count` 值增量、快照/刷盘两个 `wal_node_info`
#      系列的增量都为 0（用 WAL 路径专属指标，避免被普通 flush 污染）。出现任何一次 ⇒ FAIL「门控未生效」。
#   ③ 方向性（软）：阈值调到 0.99 的窗口内应出现 WAL 路径动作（上面三个指标任一增量 > 0），
#      或 TsFile 数增加（刷盘）/WAL 文件面下降（快照，design_extract TP-25：快照后旧 version_id 被删且**不新增 TsFile**）。
#      观测不到 ⇒ `warn "场景未成立（触发条件未构造）"` + 调参建议，**不判 FAIL**
#      （触发依赖内部 effectiveInfoRatio 的绝对量级，黑盒不可控；且文档对比较符自相矛盾，见下）。
#   ④ 数据面（硬）：全部窗口前后 count/sum/min/max + d1 全序列指纹完全一致、且等于期望值
#      （快照/刷盘不得丢数据、不得凭空多数据）。
#   ⑤ 只 WARN：指标缺失（lib 口径在 histogram/float 形态下取不到值）、
#      调小阈值后仍在动作（可能是上一窗口在途的刷盘）、快照/刷盘的具体归属（时间分区/阈值/次数三者耦合）。
#
# 【刻意不做的事（口径纪律）】
#   · **不判边界等号**：文档 §5.3 参数条目写「小于该值」（`<`），而 "MemTable 快照" 章节写「占比 ≤」
#     （`≤`）—— 矛盾未澄清 ⇒ 本用例只判"变更阈值后行为方向"，绝不构造 ratio 恰等于阈值来断言等号归属。
#   · **不用快照内部状态作判据**：`WALNode.java:116-118 memTableSnapshotCount` 是内存 Map、不落盘、
#     无对外指标（source_grounding §6.4、DECISIONS §3.1 第 6 条）⇒ 黑盒不可观测。
#   · 不用 `WALNode.java:466-470` 的 DEBUG 文案（默认不落盘）。
#   · 不改 lib/、tools/、conf/、cases.tsv、docs/（只新增本文件）。
#
# 【为什么关掉 WAL 压缩】ratio 的分母 `totalCost` 用的是 **WAL 磁盘字节**（`getDiskUsage()`），
#   压缩会把磁盘字节压小、把 ratio 抬高（更难触发）⇒ 本用例显式 `enable_wal_compression=false`，
#   让"无效 WAL 的磁盘量"真实反映数据量。（压缩本身是 W-11 的题目。）
#
# 【时长大致】≈28~36 分钟（准备 ~4min + 第一批写入/flush ~7min + 小批 ~2min
#   + 三个观察窗口 ≤${W15_WIN_SEC}s×2 + ${W15_WIN2_SEC}s + 收尾三件套 ~4min）。
#
# 【⚠️ 首轮 watch list（先看这些才知道"场景真的成立了"）】
#   1) **ratio 与三个 WAL 路径指标的真实数值**：产物里每次采样都会打印原始值（raw 与 lib 两种口径）。
#      若两相都看不到任何动作 ⇒ 看 `effective_ratio_info` 的量级（它记录的是 ratio×100），
#      据此决定是把 W15_HI_RATIO 再抬高（上限 < 1）、还是加大"第一批 + flush"的规模
#      （构造更多无效 WAL ⇒ ratio 更小）。
#   2) **`wal_node_info`/`flush_memtable_count` 的导出形态**：Prometheus 里 histogram 可能导出成
#      `wal_node_info_count{...}`/`_max{...}`；本用例用宽松正则同时覆盖 gauge 与 histogram 形态，
#      并把命中行数一起打印 —— 首轮据此确认口径（lib helper 只匹配 `^wal_buffer\{`/`^wal_node_info\{`
#      的**基础**形态，可能全为 0，属"只 WARN"项）。
#   3) **第一批 flush 是否真的落盘**（`Async close tsfile: .*<db>` 增量）：这是"无效 WAL"的前提；
#      若某副本迟迟不 close，窗口内的判定会偏向"本来就没东西可清"。
#   4) **删除周期**：本用例把 `delete_wal_files_period_in_ms` 设为 ${WAL_CLEAN_PERIOD_SMALL_MS}ms
#      （hot_reload）以便窗口内能观察到若干轮；若现场该键不生效，会看到 `Reboot wal delete thread` 缺失。
#   5) **调小阈值后的残留动作**：LO2 窗口若仍有动作，先确认是不是上一窗口在途的刷盘
#      （只记 WARN，不判 FAIL）。
#
# 用法： bash cases/common/wal_min_effective_ratio.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 本文件**未在真实集群实跑过**（99.80 正在跑合并长回归，禁止任何集群启停/清库动作）；
#     只保证逻辑自洽 + `bash -n` 通过 + harness 自检不退化。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"

# harness 侧防御：conf/env.conf 未定义这三个 TTL 键，而 lib/common.sh 的 cluster_set_conf 会引用它们
TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
MAX_EXPIRED_TIME_MS="${MAX_EXPIRED_TIME_MS:-9223372036854775807}"
EXPIRED_DATA_RATIO="${EXPIRED_DATA_RATIO:-1.0}"
export TTL_CHECK_INTERVAL_MS MAX_EXPIRED_TIME_MS EXPIRED_DATA_RATIO

cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_min_effective_ratio_${DATA_CONSENSUS}"

DB=root.walratio                       # 库名（root.wal* 约定）
DEVS=${W15_DEVS:-${WAL_ROTATE_DEVS:-10}}
ROWS1=${W15_ROWS1:-${WAL_ROTATE_ROWS:-4000}}      # 第一批（写完就 flush ⇒ 制造"无效 WAL"）
B1=${W15_BATCHES1:-2}
ROWS2=${W15_ROWS2:-200}                           # 第二批（**不 flush** ⇒ 活跃 MemTable 的 RAM 很小）
LO=${W15_LO_RATIO:-0.000001}                      # 调小（几乎不该触发；>0 才生效，见 §1.3）
HI=${W15_HI_RATIO:-0.99}                          # 调大（应触发；< 1）
THRESH=${W15_WAL_THRESHOLD:-262144}               # 256KB：让 WAL 快速轮转（否则 totalCost 几乎为 0）
PERIOD=${WAL_CLEAN_PERIOD_SMALL_MS:-2000}         # 删除线程周期（hot_reload）：窗口内多跑几轮
MINF=${WAL_CLEAN_MIN_FILES:-2}
WIN=${W15_WIN_SEC:-120}                           # LO / HI 两个观察窗口
WIN2=${W15_WIN2_SEC:-60}                          # 调回小阈值后的观察窗口（第四相，只作证据）
STEP=${W15_STEP_SEC:-15}                          # 采样间隔（指标抓取有 ssh 开销，15s 足够）
STABLE_WIN=${W15_STABLE_WIN_SEC:-60}
CLOSE_WIN=${WAL_CLOSE_WIN_SEC:-60}
N1=$(( DEVS * ROWS1 * B1 ))
N2=$(( DEVS * ROWS2 ))
WANT=$(( N1 + N2 ))
BASE_TS=$(( ($(date +%s) - 3600) * 1000 ))
W15_FILES=0; W15_BYTES=0
SAMPLES="$ART/w15_samples.txt"

# 配置串（**显式列全所有键**，避免与 WAL_EXTRA_DEFAULT 同名键重复 ⇒ cluster_write_conf 假 FAIL）
W15_EXTRA="wal_mode=${WAL_MODE},enable_wal_compression=false,wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${THRESH},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${PERIOD},wal_min_effective_info_ratio=${LO},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 写入（大语句；flush 由调用方决定）-----------------------------------
w15_write(){ local db=$1 base=$2 b d k vals ts logf n=0 batches=$4 rows=$5
  local -a S=()
  logf="$ART/w15_write_${db##*.}_b${3}.log"; : >"$logf"
  for (( b=1; b<=batches; b++ )); do
    S=()
    for (( d=1; d<=DEVS; d++ )); do
      vals=""
      for (( k=0; k<rows; k++ )); do
        ts=$(( base + b * 1000000 + k * 10 ))
        vals="$vals($ts,$(( base % 7 + k + b ))),"
      done
      S+=("insert into $db.d$d(time,s1) values ${vals%,};")
      n=$(( n + 1 ))
    done
    sql_lines_tree "${S[@]}" >>"$logf" 2>&1 || return 1
  done
  if grep -qiE 'IoTDBSQLException|Exception|ERROR' "$logf"; then
    fail "  [$db] 写入出现异常：$(grep -iE 'Exception|ERROR' "$logf" | head -2 | tr '\n' ' ' | cut -c1-200)"
    return 1
  fi
  log "  [$db] 写入完成：$n 条大语句 × $rows 行（base=$base）"
  return 0; }
# 第一批（会 flush）的每设备点数与值总和：值 = (base%7) + k + b
w15_bsum(){ local base=$1 s=0 b k
  for (( b=1; b<=B1; b++ )); do for (( k=0; k<ROWS1; k++ )); do s=$(( s + (base % 7) + k + b )); done; done
  echo $(( DEVS * s )); }
# 第二批（不 flush）的每设备点数与值总和：值 = (base%7) + k + 1
w15_sum2(){ local base=$1 s=0 k
  for (( k=0; k<ROWS2; k++ )); do s=$(( s + (base % 7) + k + 1 )); done
  echo $(( DEVS * s )); }

# ---- ② 指标（**awk 求和**：Prometheus 的 histogram/mean 可能是浮点，lib 的 `$(( ))` 求和会报错）----
W15_RX_FC='^flush_memtable_count(_[a-z]+)?\{[^}]*type="wal_flush_memtable_count"'
W15_RX_SNAP='^wal_node_info(_[a-z]+)?\{[^}]*name="oldest_mem_table_ram_when_cause_snapshot"'
W15_RX_FLUSH='^wal_node_info(_[a-z]+)?\{[^}]*name="oldest_mem_table_ram_when_cause_flush"'
W15_RX_EFF='^wal_node_info(_[a-z]+)?\{[^}]*name="effective_ratio_info"'
# 跨 DN 的"匹配行最后一列之和"（浮点安全）
w15_rv(){ local rx=$1 h v out=""
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '$rx' | awk '{s+=\$NF} END{print s+0}'" 2>/dev/null | tr -dc '0-9.\-')
    out="$out${v:-0}
"
  done
  printf '%s' "$out" | awk '{s+=$1} END{ if (s==int(s)) printf "%d", s; else printf "%.6f", s }'; }
# 跨 DN 的"匹配行数"（存在性）
w15_rl(){ local rx=$1 h v s=0
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -cE '$rx'" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${v:-0} ))
  done
  echo "$s"; }
# 一次采样：把 WAL 路径的三个指标 + WAL 文件面 + TsFile 数记进 WR_* 全局
w15_capture(){ local tag=$1
  WR_FC=$(w15_rv "$W15_RX_FC");     WR_FC_RAW=$(w15_rl "$W15_RX_FC")
  WR_SNAP=$(w15_rv "$W15_RX_SNAP"); WR_SNAP_RAW=$(w15_rl "$W15_RX_SNAP")
  WR_FL=$(w15_rv "$W15_RX_FLUSH");  WR_FL_RAW=$(w15_rl "$W15_RX_FLUSH")
  WR_EFF=$(w15_rv "$W15_RX_EFF");   WR_EFF_RAW=$(w15_rl "$W15_RX_EFF")
  WR_FC_LIB=$(wal_metric_sum_over_dn wal_metric_flush_memtable_cnt 2>/dev/null)
  WR_EFF_LIB=$(wal_metric_sum_over_dn wal_metric_eff_ratio 2>/dev/null)
  WR_FILES=$(wal_sum_over_dn wal_file_cnt); WR_BYTES=$(wal_sum_over_dn wal_dir_bytes)
  WR_TS=$(cmp_all_sum "$DB")
  log "  [采样/$tag] WAL 路径指标 raw：flush_cnt=$WR_FC(series=$WR_FC_RAW) snapshot=$WR_SNAP(series=$WR_SNAP_RAW) flush_ram=$WR_FL(series=$WR_FL_RAW) eff_ratio=$WR_EFF(series=$WR_EFF_RAW)"
  log "  [采样/$tag] lib helper 口径（histogram 基础形态才取得到，取不到只 WARN）：flush_cnt=${WR_FC_LIB:-<空>} eff_ratio=${WR_EFF_LIB:-<空>} | WAL=${WR_FILES}f/${WR_BYTES}B TsFile=$WR_TS"
  printf 'tag=%s flush_cnt=%s snapshot=%s flush_ram=%s eff_ratio=%s WAL=%sf/%sB TsFile=%s\n' \
    "$tag" "$WR_FC" "$WR_SNAP" "$WR_FL" "$WR_EFF" "$WR_FILES" "$WR_BYTES" "$WR_TS" >>"$SAMPLES"; }
# 把当前 WR_* 存成 <前缀>_* （用 printf -v 动态命名，避免 eval）
w15_keep(){ local p=$1
  printf -v "${p}_FC"    '%s' "$WR_FC"
  printf -v "${p}_SNAP"  '%s' "$WR_SNAP"
  printf -v "${p}_FL"    '%s' "$WR_FL"
  printf -v "${p}_EFF"   '%s' "$WR_EFF"
  printf -v "${p}_FILES" '%s' "$WR_FILES"
  printf -v "${p}_BYTES" '%s' "$WR_BYTES"
  printf -v "${p}_TS"    '%s' "$WR_TS"; }
w15_get(){ local n="${1}_${2}"; printf '%s' "${!n}"; }
# WAL 路径动作增量（快照/刷盘）：>0 表示删除线程真的动手了（WAL 路径专属指标，不受普通 flush 干扰）
w15_act(){ local b=$1 a=$2
  awk -v f0="$(w15_get "$b" FC)"   -v f1="$(w15_get "$a" FC)" \
      -v s0="$(w15_get "$b" SNAP)" -v s1="$(w15_get "$a" SNAP)" \
      -v l0="$(w15_get "$b" FL)"   -v l1="$(w15_get "$a" FL)" \
    'BEGIN{ d=(f1-f0)+(s1-s0)+(l1-l0); if (d<0) d=0; if (d==int(d)) printf "%d", d; else printf "%.6f", d }'; }
# 数值比较（阈值回读可能是 0.990000 / 1.0E-6 等形态）
w15_num_eq(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 == b+0)}'; }
w15_metric_lines(){ local s=0; s=$(( $(w15_rl "$W15_RX_FC") + $(w15_rl "$W15_RX_SNAP") + $(w15_rl "$W15_RX_FLUSH") )); echo "$s"; }

# ---- ③ WAL 文件面 + 落盘证据 -----------------------------------------------
w15_db_files(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
w15_db_bytes(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
w15_cnt(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h") )); done; echo "$s"; }
w15_ident_dirs(){ local h=$1
  sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 2 -type d -name '$DB-*' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w15_close_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(ttl_close_cnt "$h" "$DB") )); done; echo "$s"; }
w15_wait_stable(){ local label=$1 dl b0="" f0="" f b n=0
  dl=$(( $(date +%s) + STABLE_WIN ))
  while (( $(date +%s) < dl )); do
    f=$(w15_cnt w15_db_files); b=$(w15_cnt w15_db_bytes)
    if [ "$f" = "$f0" ] && [ "$b" = "$b0" ]; then
      n=$(( n + 1 )); [ "$n" -ge 2 ] && { log "  [$label] WAL 观测量已稳定（本库 files=$f bytes=$b）"; return 0; }
    else
      n=0
    fi
    f0=$f; b0=$b
    sleep 5
  done
  warn "  [$label] WAL 观测量在 ${STABLE_WIN}s 内未稳定（files=$f bytes=$b）——继续，数值仅供记录"; return 0; }
# 阈值生效值（运行期优先，读不到退回 properties）
w15_eff(){ local h=$1 k=$2 v; v=$(wal_eff "$h" "$k"); [ -n "$v" ] || v=$(wal_props_get "$h" "$k"); printf '%s' "$v"; }
w15_set_ratio(){ local v=$1 resp eff
  resp=$(wal_set wal_min_effective_info_ratio "$v")
  log "  SET CONFIGURATION 'wal_min_effective_info_ratio'='$v' → $(printf '%s' "$resp" | cut -c1-200)"
  W15_NEED_RESTART=0
  case "$resp" in *"restart is required"*|*"Restart is required"*) W15_NEED_RESTART=1 ;; esac
  eff=$(w15_eff "${DN[0]}" wal_min_effective_info_ratio)
  if w15_num_eq "${eff:-x}" "$v" && [ "$W15_NEED_RESTART" = 0 ]; then
    pass "  阈值已热改生效：wal_min_effective_info_ratio=$eff（目标 $v，无需重启）"
  elif w15_num_eq "${eff:-x}" "$v"; then
    pass "  阈值已生效（生效值=$eff，目标 $v；返回文案要求重启=$W15_NEED_RESTART —— 记录）"
  else
    warn "  热改未直接生效（生效值='${eff:-空}'，目标 $v，返回要求重启=$W15_NEED_RESTART）⇒ 补一次 stop/start（不清 data）"
    cluster_stop; cluster_start
    eff=$(w15_eff "${DN[0]}" wal_min_effective_info_ratio)
    if w15_num_eq "${eff:-x}" "$v"; then pass "  重启后阈值生效：$eff"; else fail "场景无效：wal_min_effective_info_ratio 未生效（实测 '${eff:-空}'，目标 $v）"; fi
  fi
  W15_EFF=$eff; }

# ---- ④ 失败取证 -------------------------------------------------------------
w15_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(dn_state "$h")；WAL 根目录=$(wal_dir_roots "$h" | tr '\n' ' ')"
    log "  [$h] identifier 目录：$(w15_ident_dirs "$h" | tr '\n' ' ')"
    log "  [$h] WAL 文件=$(w15_db_files "$h")f/$(w15_db_bytes "$h")B；TsFile=$(cmp_seq_cnt "$h" "$DB"):$(cmp_unseq_cnt "$h" "$DB")"
    log "  [$h] WAL 清单（含大小，前 20）："
    wal_ls "$h" | head -20 | sed 's/^/        /' >>"$OUT" 2>&1
    log "  [$h] WAL 相关日志尾部："
    wal_log_tail "$h" 20 | sed 's/^/        /' >>"$OUT" 2>&1
  done
  log "  show cluster："
  sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"
  log "=== 逐副本证据结束（$tag）==="; }

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-15 有效信息比门控：库=$DB；第一批 ${DEVS}×${ROWS1}×${B1}=${N1} 点（写后 flush ⇒ 制造无效 WAL）+ 第二批 ${DEVS}×${ROWS2}=${N2} 点（不 flush ⇒ 小 RAM 活跃 MemTable）==="
log "  阈值方向：小=${LO}（不该触发）→ 大=${HI}（应触发）→ 再回小=${LO}"
log "  配置串：$W15_EXTRA"
log "  期望 count=${WANT}；说明：文档对比较符 < / ≤ 自相矛盾，本用例**只判方向、不判边界等号**"

log "--- ① 集群准备（ratio=小值起步；关 WAL 压缩让 WAL 磁盘量与数据量成正比；关三类合并）---"
EXTRA_CONF="$W15_EXTRA" cmp_cluster_prepare
E0=$(w15_eff "${DN[0]}" wal_min_effective_info_ratio)
T0E=$(w15_eff "${DN[0]}" wal_file_size_threshold_in_byte)
P0=$(w15_eff "${DN[0]}" delete_wal_files_period_in_ms)
log "  运行期生效：ratio=${E0:-<读不到>} threshold=${T0E:-<读不到>} delete_period=${P0:-<读不到>}ms"
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done
: >"$SAMPLES"

log "--- ② 先把阈值热改到小值 ${LO}（源码印证 hot_reload；§1.3：必须 > 0 才生效）---"
w15_set_ratio "$LO"
w15_capture "准备/基线"; w15_keep PRE
log "  WAL 路径指标存在性（三个系列匹配行数合计）= $(w15_metric_lines)（0 ⇒ 本版本不导出这些指标 ⇒ 方向判定降级为文件面，只 WARN）"

log "--- ③ 第一批数据：写入后 flush（数据落盘 ⇒ 其 WAL 记录变无效，作为 ratio 分母）---"
cmp_make_tree_db "$DB" "$DEVS"
w15_write "$DB" "$BASE_TS" 1 "$B1" "$ROWS1" || true
# ⚠️ 口径：这条 SQL 查的是**单个设备** `$DB.d1` ⇒ 期望值必须是**单设备**点数
#    `ROWS1*B1`（=8000），不能写 `${N1}`（=DEVS×ROWS1×B1=80000，全设备总数）。
#    RC8 首轮写成 `${N1}` ⇒ 日志 `实际=[8000] 期望=[80000]` 假 FAIL（同一批问题的第 3 类口径错）。
#    另外一律查**设备路径**：树方言把测量名写成序列路径（`… from <db>.d1.s1`）会恒返回 Empty set。
wait_scalar_tree "select count(s1) from $DB.d1;" "$(( ROWS1 * B1 ))" 180 "[第一批] 写入后可见性（单设备 $DB.d1）"
C1=$(row_sum "$(sq "select count(s1) from $DB.**;")")
S1=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
assert_eq "  [第一批] 点数（场景有效性）" "${C1:-0}" "$N1"
assert_eq "  [第一批] 值总和（离线核算）" "${S1:-0}" "$(w15_bsum "$BASE_TS")"
CLOSE0=$(w15_close_sum)
sq "flush;" >/dev/null
if ensure_closed "$DB" 3 "$CLOSE_WIN"; then
  pass "  第一批已落盘（出现新的 'Async close tsfile' 事件 ⇒ '无效 WAL' 前提成立）"
else
  warn "  有 DN 未在 ${CLOSE_WIN}s 内出现新的 Async close（第一批可能未完全落盘 ⇒ ratio 分母偏小，记录）"
fi
log "  落盘证据：close 事件 ${CLOSE0} → $(w15_close_sum)；TsFile=$(cmp_all_sum "$DB")"

log "--- ④ 第二批数据（**不 flush**，小批量）：活跃 MemTable 的 RAM 很小而无效 WAL 的磁盘量很大 ---"
w15_write "$DB" "$(( BASE_TS + 9000000 ))" 2 1 "$ROWS2" || true
wait_scalar_tree "select count(s1) from $DB.d1;" "$(( ROWS1 * B1 + ROWS2 ))" 180 "[第二批] 写入后可见性"
C_ALL=$(row_sum "$(sq "select count(s1) from $DB.**;")")
S_ALL=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
assert_eq "  [两批合计] 点数（场景有效性）" "${C_ALL:-0}" "$WANT"
assert_eq "  [两批合计] 值总和（离线核算）" "${S_ALL:-0}" "$(( $(w15_bsum "$BASE_TS") + $(w15_sum2 "$(( BASE_TS + 9000000 ))") ))"
FP0=$(cmp_fp_tree "$DB"); SEQ0=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
w15_wait_stable "第二批写入后"
F_FILES0=$(w15_cnt w15_db_files); F_BYTES0=$(w15_cnt w15_db_bytes)
log "  场景有效性：本库 WAL = ${F_FILES0}f/${F_BYTES0}B"
if [ "${F_FILES0:-0}" -ge "$MINF" ] && [ "${F_BYTES0:-0}" -gt 0 ]; then
  pass "场景有效性：WAL 已轮转出 ${F_FILES0} 个文件、共 ${F_BYTES0}B（≥${MINF} ⇒ totalCost 不会退化成 0）"
else
  fail "场景无效：本库 WAL = ${F_FILES0}f/${F_BYTES0}B（要求 ≥${MINF} 文件且字节 > 0）⇒ 未轮转或目录/库名过滤不对，ratio 的分母会退化为 0（WALNode.java:438-455 直接置 1.0）"
fi
w15_capture "LO 窗口前"; w15_keep LO0

log "--- ⑤ 相 LO（阈值 ${LO}）：观察窗口 ${WIN}s，**不得**出现任何 WAL 路径动作（硬判据）---"
LO_ACT=0; TA=$(date +%s)
while [ $(( $(date +%s) - TA )) -lt "$WIN" ]; do
  sleep "$STEP"
  w15_capture "LO t=$(( $(date +%s) - TA ))s"; w15_keep LOT
  D=$(w15_act LO0 LOT)
  log "    LO 窗口动作增量（flush_cnt+snapshot+flush_ram）= $D"
  if awk -v d="$D" 'BEGIN{exit !(d+0 > 0)}'; then
    LO_ACT=1; fail "门控未生效：阈值调小到 ${LO} 后仍观测到 WAL 路径快照/刷盘动作（增量 $D）—— 见上面 raw 指标与 TsFile 变化"
    break
  fi
done
w15_capture "LO 窗口后"; w15_keep LO1
[ "$LO_ACT" = 0 ] && pass "门控生效（负向）：阈值 ${LO} 的 ${WIN}s 窗口内 WAL 路径动作增量为 0（flush_memtable_count / 快照 / 刷盘 三个系列都没动）"
log "  LO 窗口 WAL 文件面：${F_FILES0}f/${F_BYTES0}B → $(w15_get LO1 FILES)f/$(w15_get LO1 BYTES)B；TsFile $(w15_get LO0 TS) → $(w15_get LO1 TS)"

log "--- ⑥ 相 HI（阈值调到 ${HI}）：观察窗口 ${WIN}s，应出现 WAL 路径动作（软判据）---"
w15_set_ratio "$HI"
w15_capture "HI 窗口前"; w15_keep HI0
HI_ACT=0; TB=$(date +%s)
while [ $(( $(date +%s) - TB )) -lt "$WIN" ]; do
  sleep "$STEP"
  w15_capture "HI t=$(( $(date +%s) - TB ))s"; w15_keep HIT
  D=$(w15_act HI0 HIT)
  log "    HI 窗口动作增量（flush_cnt+snapshot+flush_ram）= $D"
  if awk -v d="$D" 'BEGIN{exit !(d+0 > 0)}'; then HI_ACT=1; log "    已观测到 WAL 路径动作 ⇒ 提前结束窗口"; break; fi
done
w15_capture "HI 窗口后"; w15_keep HI1
HI_TS_DELTA=$(( $(w15_get HI1 TS) - $(w15_get HI0 TS) ))
HI_WAL_DELTA=$(( $(w15_get HI0 FILES) - $(w15_get HI1 FILES) ))
HI_WAL_BDELTA=$(( $(w15_get HI0 BYTES) - $(w15_get HI1 BYTES) ))
log "  HI 窗口：TsFile 增量=$HI_TS_DELTA；WAL 文件数下降=$HI_WAL_DELTA 字节下降=${HI_WAL_BDELTA}B"

log "--- 判据 ③ 方向性（软：观测不到只 WARN，不判 FAIL）---"
if [ "$HI_ACT" = 1 ]; then
  pass "方向成立：阈值调大（${LO}→${HI}）后 WAL 路径出现快照/刷盘动作（增量为 $(w15_act HI0 HI1)）；放宽到文件面看：TsFile 增量=$HI_TS_DELTA，WAL 文件数下降=$HI_WAL_DELTA"
  if [ "${HI_TS_DELTA:-0}" -gt 0 ] && [ "${HI_TS_DELTA:-0}" -ge "${HI_WAL_DELTA:-0}" ]; then
    log "  证据（倾向刷盘）：TsFile 数增加 ⇒ 走的是 flushMemTable 分支（WALNode.java:546-559 的 flush 条件）"
  elif [ "${HI_WAL_DELTA:-0}" -gt 0 ] && [ "${HI_TS_DELTA:-0}" -le 0 ]; then
    log "  证据（倾向快照）：WAL 文件数下降且 TsFile 未增加 ⇒ 符合 design_extract TP-25「快照后旧 version_id 被删且不新增 TsFile」"
  fi
else
  warn "场景未成立（触发条件未构造）：阈值调大到 ${HI} 后 ${WIN}s 内未观测到 WAL 路径快照/刷盘动作（增量为 0），文件面 TsFile 增量=$HI_TS_DELTA、WAL 文件数下降=$HI_WAL_DELTA ⇒ 只 WARN，不判 FAIL；首轮请据产物里 eff_ratio 的量级决定调大 W15_HI_RATIO（<1）或加大"第一批+flush"规模使无效 WAL 占比更高"
fi

log "--- ⑦ 相 LO2（阈值调回 ${LO}）：第四相只作证据（可能有上一窗口在途的刷盘，只 WARN）---"
w15_set_ratio "$LO"
w15_capture "LO2 窗口前"; w15_keep LO20
LO2_ACT=0; TC=$(date +%s)
while [ $(( $(date +%s) - TC )) -lt "$WIN2" ]; do
  sleep "$STEP"
  w15_capture "LO2 t=$(( $(date +%s) - TC ))s"; w15_keep LO2T
  D2=$(w15_act LO20 LO2T)
  log "    LO2 窗口动作增量 = $D2"
  awk -v d="$D2" 'BEGIN{exit !(d+0 > 0)}' && { LO2_ACT=1; break; }
done
w15_capture "LO2 窗口后"; w15_keep LO21
if [ "$LO2_ACT" = 1 ]; then
  warn "调回小阈值（${LO}）后仍在动作（增量 $(w15_act LO20 LO21)）—— 可能是上一窗口在途的刷盘；只记 WARN（源码语义：ratio 小 ⇒ shouldSnapshotOrFlush() 为假）"
else
  pass "调回小阈值后 ${WIN2}s 窗口内无新的 WAL 路径动作（与 §6.3 的 shouldSnapshotOrFlush() 语义一致）"
fi

log "--- 判据 ④ 数据面：快照/刷盘不得动数据（硬）---"
C_END=$(row_sum "$(sq "select count(s1) from $DB.**;")")
S_END=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
assert_eq "  全流程结束后点数" "${C_END:-0}" "${C_ALL:-0}"
assert_eq "  全流程结束后值总和" "${S_END:-0}" "${S_ALL:-0}"
assert_eq "  全流程结束后点数（离线核算）" "${C_END:-0}" "$WANT"
if [ "$(cmp_fp_tree "$DB")" = "$FP0" ]; then
  pass "  全流程前后 count/sum 指纹一致：$FP0"
else
  fail "  全流程前后 count/sum 指纹不一致：[$(cmp_fp_tree "$DB")] vs [$FP0]"
fi
if [ "$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")" = "$SEQ0" ]; then
  pass "  全流程前后 d1 全序列指纹一致"
else
  fail "  全流程前后 d1 全序列指纹不一致（快照/刷盘不得改变读数）"
fi
log "  最终 WAL 文件面：$(w15_get LO21 FILES)f/$(w15_get LO21 BYTES)B；TsFile=$(cmp_all_sum "$DB")；close 事件=$(w15_close_sum)"
if [ "${WR_FC_RAW:-0}" -eq 0 ] && [ "${WR_SNAP_RAW:-0}" -eq 0 ] && [ "${WR_FL_RAW:-0}" -eq 0 ]; then
  warn "本版本 metrics 里没有 flush_memtable_count{type=\"wal_flush_memtable_count\"}/wal_node_info{name=...} 三个系列（匹配行数 0）⇒ 方向判定只能靠文件面，首轮请人工核对 /metrics 原始文本"
fi
OOM=$(wal_oom_cnt); assert_eq "  WAL 相关 OOM 日志行数（必须 0）" "${OOM:-0}" "0"

log "--- 采样序列（$SAMPLES）---"
sed 's/^/      /' "$SAMPLES" >>"$OUT"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w15_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 专属异常正则）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat 'Fail to snapshot memTable|Fail to delete outdated wal file|Fail to trigger rolling wal node|Fail to roll wal|Fail to sync wal node|Fail to fsync wal node'
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader|Connection reset by peer'
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
