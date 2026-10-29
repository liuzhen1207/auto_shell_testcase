#!/bin/bash
# ============================================================================
# W-23 WAL 可观测性（指标存在性 + 写入前后变化方向；树模型；库名 root.walmet）
#
# 【用例】W-23（集合 observe；cases/cases.tsv W-23 行）
#   目标：把源码里**已确认的 WAL 指标名**逐个在真实 DN `/metrics` 上核对：
#     ① 指标**存在性**（同一时间序列名 + 标签）；② **写入前后变化方向**（写入 → 值应增加 / 至少出现非 0）；
#     ③ 保留**动态发现**作兜底：打印本 DN 上所有含 `wal` 的时间序列名（首轮现场标定用）。
#   缺失一律只 WARN（版本差异），方向异常（写入后反而下降）才 FAIL。
#
# 【覆盖需求 / 源码依据】
#   · design_extract.md §6.2（关键缺口）：「并在 WritePerformance 监控面板下新增监控项：」其后紧接图片，
#     **正文无指标名** ⇒ 三份文档**零 metrics 名**（§6.1/§6.2/§9.1 第 1、3 项）；
#     所以本用例的指标名**全部来自源码印证**，文档只提供"应该有监控项"这一要求。
#   · DECISIONS.md §2：**"指标名/指标是否存在"只 WARN**（文档零 metrics 名 ⇒ 动态发现，缺了只 WARN）；
#     §4 第 1 项：首轮跑 W-23 时采集 DN metrics 里含 `wal` 的全部时间序列名（本用例的核心交付物之一）。
#   · source_grounding.md §9（源码定案，逐条绑定处/上报处）：
#       `Metric.java:80-85`：`WAL_NODE_NUM("wal_node_num")`、`WAL_NODE_INFO("wal_node_info")`、
#                             `WAL_BUFFER("wal_buffer")`、`WAL_COST("wal_cost")`、
#                             `WAL_QUEUE_MEM_COST("wal_queue_mem_cost")`；
#       `Metric.java:156-157`：`FILE_SIZE("file_size")`、`FILE_COUNT("file_count")`（CORE 级）。
#     标签取值：`wal_queue_mem_cost{name="wal_queue_current_mem_cost"|"wal_queue_max_mem_cost"}`；
#       `wal_buffer{name="used_ratio"|"entries_count"|"wal_entry_num_for_one_tsfile"|
#                    "serialized_wal_buffer_size"|"wrote_wal_buffer_size"|"wal_compress_cost"|
#                    "wal_uncompress_cost"|"read_wal_buffer_size"|"read_wal_buffer_cost"|
#                    "write_wal_buffer_cost"}`；
#       `wal_cost{stage="make_checkpoint"|"serialize_wal_entry"|"sync_wal_buffer"}`；
#       `wal_node_num{name="wal_nodes_num"}`；
#       `wal_node_info{name="effective_ratio_info"|"oldest_mem_table_ram_when_cause_snapshot"|
#                      "oldest_mem_table_ram_when_cause_flush", type=<walNodeId>}`；
#       `flush_memtable_count{type="wal_flush_memtable_count"}`（Counter）；
#       文件面：`file_count{name="wal"}`/`file_size{name="wal"}`（`WalFileMetrics.java:35-48`，AutoGauge/CORE）。
#   · source_grounding.md §9 末（**监控缺口**）：源码中**没有**"每 WALNode 的文件数""快照次数""被删除文件数"
#     等指标 ⇒ 本用例不发明这些名字，只核对上面这一份清单。
#
# 【判据（硬/软分明）】
#   ① 场景有效性（硬）：写入点数/值总和 == 离线核算；写入后 WAL 目录非空（否则"指标不动"不可解释）。
#   ② 数据面（硬）：flush 前后 count/sum 与 d1 全序列指纹完全一致。
#   ③ 指标存在性（软，只 WARN）：清单里每个指标在 A（写入前）/B（写入后）/C（flush 后）/D（触发快照/刷盘后）
#      四个快照的**任一** DN 上出现 ⇒ PASS；四个快照都没有 ⇒ `warn "指标缺失（版本差异）"`。
#   ④ 指标方向（硬/软分开）：
#      · `up` 类（写入驱动必然累积：文件数/字节、buffer entries/serialized/wrote/compress 耗时、
#        `wal_cost{serialize_wal_entry|sync_wal_buffer}`、队列内存峰值）⇒ 要求 **B > A**（干净集群 A≈0）；
#        B == A ⇒ WARN（可能是指标形态/采样差异）；B < A ⇒ FAIL（写入后反而下降，属真异常）。
#      · `seen` 类（瞬时 gauge 或需要特定触发/重启才有的：`used_ratio`、`wal_queue_current_mem_cost`、
#        `wal_uncompress_cost`、`read_wal_buffer_*`、`make_checkpoint`、`wal_node_info` 三个、
#        `flush_memtable_count`、`wal_node_num`）⇒ 只要"出现过且任意快照 > 0"即 PASS，全 0 ⇒ WARN。
#   ⑤ 只 WARN：本版本是否导出 histogram 的 `_count/_sum/_max` 形态（本用例用宽松正则同时覆盖
#      `name{...}` 与 `name_xxx{...}` 两种形态）；`wal_uncompress_cost` 需重启恢复才有值；
#      **文件面双口径**（目录口径 vs `file_count{name="wal"}`/`file_size{name="wal"}`）的一致性 ——
#      两个指标绑的是 `WALManager::getTotalFileNum/getTotalDiskUsage`，是**全局**口径，
#      用例把"整目录"与"本库"两种目录口径都和它并列打印，V1/V2 下是否一致属首轮标定项。
#
# 【刻意不做的事】
#   · 不把"指标缺失"判 FAIL（DECISIONS §2 明确只 WARN）。
#   · 不发明文档里没有的指标名；不用"面板/图表"这类不可编程的观测面。
#   · 不断言 `WALNode.java:466-470` 的 DEBUG 文案（§10.8：默认不落盘）。
#   · 不改 lib/、tools/、conf/、cases.tsv、docs/（只新增本文件）。
#
# 【做法（一次集群准备，四个快照）】
#   A 写入前（干净集群：多数 WAL 指标应为 0/不存在）→ 建库写数据（**不 flush**）
#   → B 写入后（`up` 类方向判据就取 A→B）→ `flush` + `ensure_closed` → C flush 后
#   → 把 `wal_min_effective_info_ratio` 热改到 0.99 并等一个窗口（尝试触发 WAL 删除线程的
#     快照/刷盘分支，让 `wal_node_info{name=oldest_mem_table_ram_when_cause_*}` 与
#     `flush_memtable_count` 出现；不判 FAIL）→ D 触发后。
#   每个快照只抓 **3 次 ssh**（每 DN 一次 curl 全量 /metrics 落到本地文件，再在本地 grep），
#   避免逐指标 ssh 的开销。
#
# 【时长大致】≈16~22 分钟（准备 ~4min + 写入 ~2min + flush/落盘 ~2min + 触发窗口 ≤${W23_WIN_SEC}s
#   + 收尾三件套 ~4min）。可调：W23_DEVS/W23_ROWS1/W23_BATCHES/W23_ROWS2/W23_WIN_SEC。
#
# 【⚠️ 首轮 watch list（先看这些才知道"场景真的成立了"）】
#   1) **含 `wal` 的全量时间序列名**（产物 `$ART/w23_names_*.txt` 与日志里打印的清单）：
#      这是本用例最重要的现场标定产物；若某个清单指标没出现，先在这里看它是否以别的名字导出。
#   2) **`flush_memtable_count`/`wal_node_info{...cause_snapshot|flush}` 是否出现**：
#      它们只在"WAL 删除线程真的执行了快照/刷盘"时才有样本；本用例的 D 相是**尝试触发**
#      （ratio=0.99 + 已 flush 的大批数据 + 小批未 flush 数据），触发不到只 WARN。
#   3) **`wal_buffer{name="wal_compress_cost"}` 的形态**：histogram 可能导出为 `wal_buffer_max{...}` 等
#      后缀形态（本用例的宽松正则已覆盖，日志里会打印命中样例）。
#   4) **A 相是否真的干净**：`prepare` 会清 data，若 A 相已有非 0 的 WAL 指标（残留 WALNode），
#      `up` 类的"B > A"判据会变得不敏感（日志会打印 A/B 的实际值，便于人工确认）。
#   5) **`wal_node_num` 的标签形态**：源码给的是 `name="wal_nodes_num"`（§9），本用例同时接受无标签形态。
#
# 用法： bash cases/common/wal_metrics.sh [--consensus IoTConsensus|IoTConsensusV2]
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
cmp_case_init "wal_metrics_${DATA_CONSENSUS}"

DB=root.walmet                        # 库名（root.wal* 约定）
DEVS=${W23_DEVS:-${WAL_COMPRESS_DEVS:-10}}
ROWS1=${W23_ROWS1:-${WAL_COMPRESS_ROWS:-2000}}    # 第一批（写完 flush ⇒ 制造"无效 WAL"）
B1=${W23_BATCHES:-${WAL_COMPRESS_BATCHES:-2}}
ROWS2=${W23_ROWS2:-200}                           # 第二批（不 flush ⇒ 给删除线程留活跃 MemTable）
WIN=${W23_WIN_SEC:-90}                            # 触发窗口（尝试让快照/刷盘指标出现）
STEP=${W23_STEP_SEC:-15}
STABLE_WIN=${W23_STABLE_WIN_SEC:-60}
CLOSE_WIN=${WAL_CLOSE_WIN_SEC:-60}
LO=${W15_LO_RATIO:-0.000001}
HI=${W23_HI_RATIO:-0.99}
N1=$(( DEVS * ROWS1 * B1 ))
N2=$(( DEVS * ROWS2 ))
WANT=$(( N1 + N2 ))
BASE_TS=$(( ($(date +%s) - 3600) * 1000 ))
W23_FILES=0; W23_BYTES=0
EXP_SUM=$(( DEVS * ( B1 * ROWS1 * (ROWS1 - 1) / 2 + ROWS1 * B1 * (B1 + 1) / 2 ) + DEVS * ( ROWS2 * 101 + ROWS2 * (ROWS2 - 1) / 2 ) ))

# 配置串（**显式列全所有键**，避免与 WAL_EXTRA_DEFAULT 同名键重复 ⇒ cluster_write_conf 假 FAIL）
W23_EXTRA="wal_mode=${WAL_MODE},enable_wal_compression=${WAL_COMPRESSION},wal_async_mode_fsync_delay_in_ms=${WAL_ASYNC_FSYNC_MS},wal_sync_mode_fsync_delay_in_ms=${WAL_SYNC_FSYNC_MS},wal_file_size_threshold_in_byte=${WAL_ROTATE_THRESHOLD_SMALL},wal_buffer_size_in_byte=${WAL_BUFFER_BYTES},delete_wal_files_period_in_ms=${WAL_CLEAN_PERIOD_SMALL_MS},wal_min_effective_info_ratio=${LO},max_wal_nodes_num=${WAL_MAX_NODES},${CMP_EXTRA_WRITE}"

# ===========================================================================
# 本用例自带 helper（只在本文件内定义，不动 lib/）
# ===========================================================================
# ---- ① 指标清单（label|kind|regex）----------------------------------------
#   正则同时覆盖 gauge 形态 `name{...}` 与 histogram/timer 形态 `name_count{...}`/`name_sum{...}`
#   （GNU grep -E 里 `\{` 是字面量花括号）；标签只要出现在同一行即可（不约束顺序）。
w23_table(){ cat <<'EOF'
file_count{name="wal"}|up|^file_count(_[a-z]+)?\{[^}]*name="wal"
file_size{name="wal"}|up|^file_size(_[a-z]+)?\{[^}]*name="wal"
wal_queue_mem_cost{name="wal_queue_current_mem_cost"}|seen|^wal_queue_mem_cost(_[a-z]+)?\{[^}]*name="wal_queue_current_mem_cost"
wal_queue_mem_cost{name="wal_queue_max_mem_cost"}|up|^wal_queue_mem_cost(_[a-z]+)?\{[^}]*name="wal_queue_max_mem_cost"
wal_buffer{name="used_ratio"}|seen|^wal_buffer(_[a-z]+)?\{[^}]*name="used_ratio"
wal_buffer{name="entries_count"}|up|^wal_buffer(_[a-z]+)?\{[^}]*name="entries_count"
wal_buffer{name="wal_entry_num_for_one_tsfile"}|seen|^wal_buffer(_[a-z]+)?\{[^}]*name="wal_entry_num_for_one_tsfile"
wal_buffer{name="serialized_wal_buffer_size"}|up|^wal_buffer(_[a-z]+)?\{[^}]*name="serialized_wal_buffer_size"
wal_buffer{name="wrote_wal_buffer_size"}|up|^wal_buffer(_[a-z]+)?\{[^}]*name="wrote_wal_buffer_size"
wal_buffer{name="wal_compress_cost"}|up|^wal_buffer(_[a-z]+)?\{[^}]*name="wal_compress_cost"
wal_buffer{name="wal_uncompress_cost"}|seen|^wal_buffer(_[a-z]+)?\{[^}]*name="wal_uncompress_cost"
wal_buffer{name="read_wal_buffer_size"}|seen|^wal_buffer(_[a-z]+)?\{[^}]*name="read_wal_buffer_size"
wal_buffer{name="read_wal_buffer_cost"}|seen|^wal_buffer(_[a-z]+)?\{[^}]*name="read_wal_buffer_cost"
wal_buffer{name="write_wal_buffer_cost"}|up|^wal_buffer(_[a-z]+)?\{[^}]*name="write_wal_buffer_cost"
wal_cost{stage="make_checkpoint"}|seen|^wal_cost(_[a-z]+)?\{[^}]*stage="make_checkpoint"
wal_cost{stage="serialize_wal_entry"}|up|^wal_cost(_[a-z]+)?\{[^}]*stage="serialize_wal_entry"
wal_cost{stage="sync_wal_buffer"}|up|^wal_cost(_[a-z]+)?\{[^}]*stage="sync_wal_buffer"
wal_node_num{name="wal_nodes_num"}|seen|^wal_node_num(_[a-z]+)?(\{[^}]*name="wal_nodes_num"|\{| )
wal_node_info{name="effective_ratio_info"}|seen|^wal_node_info(_[a-z]+)?\{[^}]*name="effective_ratio_info"
wal_node_info{name="oldest_mem_table_ram_when_cause_snapshot"}|seen|^wal_node_info(_[a-z]+)?\{[^}]*name="oldest_mem_table_ram_when_cause_snapshot"
wal_node_info{name="oldest_mem_table_ram_when_cause_flush"}|seen|^wal_node_info(_[a-z]+)?\{[^}]*name="oldest_mem_table_ram_when_cause_flush"
flush_memtable_count{type="wal_flush_memtable_count"}|seen|^flush_memtable_count(_[a-z]+)?\{[^}]*type="wal_flush_memtable_count"
EOF
}

# ---- ② 抓取 /metrics（每个快照只 3 次 ssh：每 DN 一次 curl）------------------
w23_fetch(){ local tag=$1 h f
  for h in "${DN[@]}"; do
    f="$ART/w23_metrics_${tag}_${h##*.}.txt"
    sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null" 2>/dev/null | tr -d '\r' >"$f"
    if [ -s "$f" ]; then
      log "  [$tag] 抓取 $h 的 /metrics：$(grep -c . "$f") 行（含 wal 的行 $(grep -icE 'wal' "$f") 行）"
    else
      warn "  [$tag] 抓取 $h 的 /metrics 为空（指标端口 $DN_METRIC_PORT 未开或 exporter 未启动）"
    fi
  done; }

# ---- ③ 一个快照：对清单逐条汇总（跨 DN 求和）--------------------------------
w23_snapshot(){ local tag=$1 label kind rx l v c s f h
  : >"$ART/w23_${tag}.txt"
  while IFS='|' read -r label kind rx; do
    [ -n "$label" ] || continue
    l=0; v=0
    for h in "${DN[@]}"; do
      f="$ART/w23_metrics_${tag}_${h##*.}.txt"
      c=$(grep -cE "$rx" "$f" 2>/dev/null)
      s=$(grep -E "$rx" "$f" 2>/dev/null | awk '{x+=$NF} END{ if (x==int(x)) printf "%d", x; else printf "%.6f", x }')
      l=$(( l + ${c:-0} ))
      v=$(awk -v a="$v" -v b="${s:-0}" 'BEGIN{ printf "%.6f", a+b }')
    done
    printf '%s\t%s\t%s\t%s\n' "$label" "$kind" "$l" "$v" >>"$ART/w23_${tag}.txt"
  done < <(w23_table)
  log "  [$tag] 清单已汇总：$ART/w23_${tag}.txt（$(grep -c . "$ART/w23_${tag}.txt") 条）"; }

# ---- ④ 动态发现：本 DN 上所有含 wal 的时间序列名 + 全量指标名清单 -----------
w23_discover(){ local tag=$1 h f n
  for h in "${DN[@]}"; do
    f="$ART/w23_metrics_${tag}_${h##*.}.txt"
    n=$(grep -iE 'wal' "$f" 2>/dev/null | grep -c .)
    log "  [$h] 含 'wal' 的导出行数=$n；时间序列名（去标签、去重）："
    grep -iE 'wal' "$f" 2>/dev/null | sed -E 's/[ {].*//' | sort -u | tr '\n' ' ' | sed 's/^/        /' >>"$OUT"
    grep -iE 'wal' "$f" 2>/dev/null | head -6 | sed 's/^/        样例| /' >>"$OUT"
    grep -oE '^[a-zA-Z_:][a-zA-Z0-9_:]*' "$f" 2>/dev/null | sort -u >"$ART/w23_names_${h##*.}.txt"
    log "  [$h] 本 DN 全量时间序列名清单（标定用）：$ART/w23_names_${h##*.}.txt（$(grep -c . "$ART/w23_names_${h##*.}.txt") 个）"
    log "       前 40 个：$(head -40 "$ART/w23_names_${h##*.}.txt" | tr '\n' ' ' | cut -c1-900)"
  done
  log "  lib helper wal_metric_names 的动态发现（各 DN）："
  for h in "${DN[@]}"; do log "    [$h] $(wal_metric_names "$h" | tr '\n' ' ')"; done; }

# ---- ⑤ 指标路径触发尝试（不判 FAIL）----------------------------------------
w23_trigger_metric(){ local rx=$1 h s=0 f v
  for h in "${DN[@]}"; do
    f="$ART/w23_metrics_TRIG_${h##*.}.txt"
    v=$(grep -E "$rx" "$f" 2>/dev/null | awk '{x+=$NF} END{print x+0}')
    s=$(awk -v a="$s" -v b="${v:-0}" 'BEGIN{ printf "%.6f", a+b }')
  done
  printf '%s' "$s"; }
w23_trigger_any(){ local a b c n
  n=0
  for a in '^wal_node_info(_[a-z]+)?\{[^}]*name="oldest_mem_table_ram_when_cause_snapshot"' \
           '^wal_node_info(_[a-z]+)?\{[^}]*name="oldest_mem_table_ram_when_cause_flush"' \
           '^flush_memtable_count(_[a-z]+)?\{[^}]*type="wal_flush_memtable_count"'; do
    b=$(w23_trigger_metric "$a")
    awk -v x="$b" 'BEGIN{exit !(x+0 > 0)}' && n=$(( n + 1 ))
  done
  c=$(w23_trigger_metric '^wal_node_info(_[a-z]+)?\{[^}]*name="effective_ratio_info"')
  log "    触发窗口采样：WAL 路径非零系列数=$n eff_ratio 值=$c"
  echo "$n"; }

# ---- ⑥ 写入（大语句；flush 由调用方决定）-----------------------------------
w23_write(){ local db=$1 base=$2 batches=$3 rows=$4 voff=$5 b d k vals ts logf n=0
  local -a S=()
  logf="$ART/w23_write_b${batches}_${rows}.log"; : >"$logf"
  for (( b=1; b<=batches; b++ )); do
    S=()
    for (( d=1; d<=DEVS; d++ )); do
      vals=""
      for (( k=0; k<rows; k++ )); do
        ts=$(( base + b * 1000000 + k * 10 ))
        vals="$vals($ts,$(( voff + k + b ))),"
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
  log "  [$db] 写入完成：$n 条大语句 × $rows 行（base=$base voff=$voff）"
  return 0; }

# ---- ⑦ WAL 文件面 ----------------------------------------------------------
w23_db_files(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
w23_db_bytes(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -path '*/$DB-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
w23_cnt(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h") )); done; echo "$s"; }
w23_ident_dirs(){ local h=$1
  sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 2 -type d -name '$DB-*' 2>/dev/null | sort" 2>/dev/null | tr -d '\r'; }
w23_close_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(ttl_close_cnt "$h" "$DB") )); done; echo "$s"; }
w23_wait_stable(){ local label=$1 dl f0="" b0="" f b n=0
  dl=$(( $(date +%s) + STABLE_WIN ))
  while (( $(date +%s) < dl )); do
    f=$(w23_cnt w23_db_files); b=$(w23_cnt w23_db_bytes)
    if [ "$f" = "$f0" ] && [ "$b" = "$b0" ]; then
      n=$(( n + 1 )); [ "$n" -ge 2 ] && { log "  [$label] WAL 观测量已稳定（本库 files=$f bytes=$b）"; return 0; }
    else
      n=0
    fi
    f0=$f; b0=$b
    sleep 5
  done
  warn "  [$label] WAL 观测量在 ${STABLE_WIN}s 内未稳定（files=$f bytes=$b）——继续，数值仅供记录"; return 0; }
w23_eff(){ local h=$1 k=$2 v; v=$(wal_eff "$h" "$k"); [ -n "$v" ] || v=$(wal_props_get "$h" "$k"); printf '%s' "$v"; }

# ---- ⑦ 文件面：**目录口径与指标口径并列打印**（首轮标定两者在 V1/V2 下是否一致）----
#   说明：`file_count{name="wal"}` / `file_size{name="wal"}` 绑的是 `WALManager::getTotalFileNum`
#   / `getTotalDiskUsage`（WalFileMetrics.java:35-48）⇒ 是**全局**（整 DN、所有库）口径；
#   所以与它并列比较的目录口径必须是"整目录"（`wal_file_cnt`/`wal_dir_bytes`），
#   本库口径（按 `<db>-<regionId>` 过滤）只作参考列出。
w23_fileface(){ local tag=$1 dball bball dbf dbb mfc mfs h hd=""
  dball=$(wal_sum_over_dn wal_file_cnt); bball=$(wal_sum_over_dn wal_dir_bytes)
  dbf=$(w23_cnt w23_db_files); dbb=$(w23_cnt w23_db_bytes)
  mfc=$(wal_metric_sum_over_dn wal_metric_file_cnt 2>/dev/null)
  mfs=$(wal_metric_sum_over_dn wal_metric_file_bytes 2>/dev/null)
  for h in "${DN[@]}"; do hd="$hd${h##*.}=$(w23_db_files "$h")f/$(wal_metric_file_cnt "$h")m "; done
  log "  [文件面双口径/$tag] 目录（整目录）=${dball}f/${bball}B ｜ 指标 file_count{name=\"wal\"}=${mfc:-<空>} file_size{name=\"wal\"}=${mfs:-<空>}"
  log "  [文件面双口径/$tag] 目录（本库 ${DB}）=${dbf}f/${dbb}B ｜ 逐副本 本库文件数/该 DN 指标 file_count：$hd"
  if [ "${mfc:-0}" -gt 0 ] || [ "${dball:-0}" -gt 0 ]; then
    if [ "${mfc:-0}" = "${dball:-0}" ]; then
      pass "  [$tag] 指标口径与目录（整目录）口径一致：file_count=${mfc}（本库 ${dbf}f）"
    else
      warn "  [$tag] 指标口径 file_count=${mfc:-空} 与目录（整目录）口径 ${dball}f 不一致（file_size ${mfs:-空} vs ${bball}B）—— 只 WARN：两者都是全局口径，不一致说明 exporter 上报时机/形态有差异，**V1/V2 下是否一致属首轮标定项**"
    fi
  else
    warn "  [$tag] file_count{name=\"wal\"}/file_size{name=\"wal\"} 缺失或恒为 0（指标端口未开/exporter 形态差异）⇒ 文件面只能按目录口径记录"
  fi; }

# ---- ⑧ 失败取证 -------------------------------------------------------------
w23_evidence(){ local tag=$1 h
  log "=== 逐副本证据（$tag）==="
  for h in "${DN[@]}"; do
    log "  [$h] DataNode 状态=$(dn_state "$h")；WAL 根目录=$(wal_dir_roots "$h" | tr '\n' ' ')"
    log "  [$h] identifier 目录：$(w23_ident_dirs "$h" | tr '\n' ' ')"
    log "  [$h] WAL 文件=$(w23_db_files "$h")f/$(w23_db_bytes "$h")B；TsFile=$(cmp_seq_cnt "$h" "$DB"):$(cmp_unseq_cnt "$h" "$DB")"
    wal_metrics_dump "$h"
    log "  [$h] WAL 相关日志尾部："
    wal_log_tail "$h" 15 | sed 's/^/        /' >>"$OUT" 2>&1
  done
  log "  show cluster："
  sq 'show cluster;' 2>&1 | sed 's/^/      /' >>"$OUT"
  log "=== 逐副本证据结束（$tag）==="; }

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-23 WAL 可观测性：库=$DB；第一批 ${DEVS}×${ROWS1}×${B1}=${N1} 点（写后 flush）+ 第二批 ${DEVS}×${ROWS2}=${N2} 点（不 flush）==="
log "  期望 count=${WANT}；期望值总和=${EXP_SUM}"
log "  配置串：$W23_EXTRA"
log "  指标清单来源：source_grounding.md §9（Metric.java:80-85,156-157 等）——共 $(w23_table | grep -c .) 条"

log "--- ① 集群准备（清 data ⇒ A 快照应基本干净）---"
EXTRA_CONF="$W23_EXTRA" cmp_cluster_prepare
log "  运行期生效：recip(${DN[0]}) ratio=$(w23_eff "${DN[0]}" wal_min_effective_info_ratio) 删除周期=$(w23_eff "${DN[0]}" delete_wal_files_period_in_ms)ms 压缩=$(w23_eff "${DN[0]}" enable_wal_compression)"

log "--- ② 快照 A（写入前）+ 动态发现 ---"
w23_fetch A; w23_snapshot A; w23_discover A; w23_fileface A
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done

log "--- ③ 建库 + 第一批数据（**不 flush**）→ 快照 B（写入后）---"
cmp_make_tree_db "$DB" "$DEVS"
w23_write "$DB" "$BASE_TS" "$B1" "$ROWS1" 0 || true
# ⚠️ 口径：这条 SQL 查的是**单个设备** `$DB.d1` ⇒ 期望值必须是**单设备**点数
#    `ROWS1*B1`（=8000），不能写 `$N1`（=DEVS×ROWS1×B1=80000，全设备总数）。
#    RC8 首轮写成 `$N1` ⇒ 日志 `实际=[8000] 期望=[80000]` 假 FAIL（同一批问题的第 3 类口径错）。
wait_scalar_tree "select count(s1) from $DB.d1;" "$(( ROWS1 * B1 ))" 180 "[第一批] 写入后可见性（单设备 $DB.d1）"
C1=$(row_sum "$(sq "select count(s1) from $DB.**;")")
assert_eq "  [第一批] 点数（场景有效性）" "${C1:-0}" "$N1"
w23_wait_stable "第一批写入后"
W23_FILES=$(w23_cnt w23_db_files); W23_BYTES=$(w23_cnt w23_db_bytes)
log "  场景有效性：写入后本库 WAL = ${W23_FILES}f/${W23_BYTES}B"
[ "${W23_FILES:-0}" -ge 1 ] && pass "场景有效性：写入后 WAL 目录非空（${W23_FILES} 个文件 / ${W23_BYTES}B）" \
  || fail "场景无效：写入后本库 WAL 为空 ⇒ 指标不动无法解释（先看目录/库名过滤与上面的 identifier 目录清单）"
w23_fetch B; w23_snapshot B; w23_fileface B
log "  写入后指标抽查：files=$(wal_metric_sum_over_dn wal_metric_file_cnt 2>/dev/null) bytes=$(wal_metric_sum_over_dn wal_metric_file_bytes 2>/dev/null) queue_max=$(wal_metric_queue_max "${DN[0]}") compress_cost(仅 ${DN[0]})=$(wal_metric_buffer "${DN[0]}" wal_compress_cost)"

log "--- ④ flush + ensure_closed → 快照 C（flush 后）---"
CLOSE0=$(w23_close_sum)
sq "flush;" >/dev/null
if ensure_closed "$DB" 3 "$CLOSE_WIN"; then
  pass "  各 DN 都出现了新的 'Async close tsfile' 事件（数据确实落盘）"
else
  warn "  有 DN 未在 ${CLOSE_WIN}s 内出现新的 Async close（只影响'已落盘'这一过程证据）"
fi
log "  落盘证据：close 事件 ${CLOSE0} → $(w23_close_sum)；TsFile=$(cmp_all_sum "$DB")"
w23_fetch C; w23_snapshot C; w23_fileface C

log "--- ⑤ 第二批数据（**不 flush**）+ 触发尝试（ratio→${HI}）→ 快照 D ---"
w23_write "$DB" "$(( BASE_TS + 9000000 ))" 1 "$ROWS2" 100 || true
wait_scalar_tree "select count(s1) from $DB.d1;" "$(( ROWS1 * B1 + ROWS2 ))" 180 "[第二批] 写入后可见性"
C_ALL=$(row_sum "$(sq "select count(s1) from $DB.**;")")
S_ALL=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
assert_eq "  [两批合计] 点数（场景有效性）" "${C_ALL:-0}" "$WANT"
assert_eq "  [两批合计] 值总和（离线核算）" "${S_ALL:-0}" "$EXP_SUM"
RESP=$(wal_set wal_min_effective_info_ratio "$HI")
log "  SET CONFIGURATION 'wal_min_effective_info_ratio'='${HI}' → $(printf '%s' "$RESP" | cut -c1-160)"
TRIG=0; TD=$(date +%s)
while [ $(( $(date +%s) - TD )) -lt "$WIN" ]; do
  sleep "$STEP"
  w23_fetch TRIG
  N=$(w23_trigger_any)
  [ "${N:-0}" -gt 0 ] && { TRIG=1; log "  已观测到 WAL 路径指标（快照/刷盘）非零 ⇒ 提前结束触发窗口"; break; }
done
if [ "$TRIG" = 1 ]; then
  pass "触发尝试成功：WAL 删除线程的快照/刷盘指标已出现（用于核对 wal_node_info{name=oldest_mem_table_ram_when_cause_*} 与 flush_memtable_count）"
else
  warn "触发尝试未成功（${WIN}s 内 wal_node_info{...cause_snapshot|flush}/flush_memtable_count 仍全为 0）⇒ 只记录，不判 FAIL（这些指标需要删除线程真的执行快照/刷盘才有样本）"
fi
w23_fetch D; w23_snapshot D; w23_fileface D

log "--- 判据 ③④ 清单逐条核对（存在性 + 方向）---"
paste "$ART/w23_A.txt" "$ART/w23_B.txt" "$ART/w23_C.txt" "$ART/w23_D.txt" >"$ART/w23_eval.txt"
n_missing=0; n_dir_bad=0
while IFS=$'\t' read -r lab kind al av lab2 kind2 bl bv lab3 kind3 cl cv lab4 kind4 dl dv; do
  [ -n "$lab" ] || continue
  exist=0
  if [ "${al:-0}" -gt 0 ] || [ "${bl:-0}" -gt 0 ] || [ "${cl:-0}" -gt 0 ] || [ "${dl:-0}" -gt 0 ]; then exist=1; fi
  printf '  %-70s A=%s/%s B=%s/%s C=%s/%s D=%s/%s\n' "$lab" "$al" "$av" "$bl" "$bv" "$cl" "$cv" "$dl" "$dv" >>"$OUT"
  if [ "$exist" = 0 ]; then
    warn "指标缺失（版本差异，只 WARN）：$lab —— 四个快照在所有 DN 上都没有匹配的时间序列（首轮请看 w23_names_*.txt 里该指标的真实导出名）"
    n_missing=$(( n_missing + 1 ))
    continue
  fi
  case "$kind" in
    up)
      if awk -v a="$av" -v b="$bv" 'BEGIN{exit !(b+0 > a+0)}'; then
        pass "指标存在且写入后增加：$lab（A=$av → B=$bv；C=$cv D=$dv）"
      elif awk -v a="$av" -v b="$bv" 'BEGIN{exit !(b+0 == a+0)}'; then
        warn "指标存在但写入前后未见增量：$lab（A=$av B=$bv C=$cv D=$dv）——可能是 gauge/采样形态差异，首轮人工核对"
      else
        fail "指标方向异常（写入后**下降**）：$lab（A=$av B=$bv C=$cv D=$dv）"
        n_dir_bad=$(( n_dir_bad + 1 ))
      fi ;;
    *)
      if awk -v b="$bv" -v c="$cv" -v d="$dv" 'BEGIN{exit !((b+0>0)||(c+0>0)||(d+0>0))}'; then
        pass "指标存在且有非零取值：$lab（B=$bv C=$cv D=$dv）"
      else
        warn "指标存在但四个快照的值均为 0：$lab（A=$av B=$bv C=$cv D=$dv）——按'缺失只 WARN'处理，首轮人工核对触发条件"
      fi ;;
  esac
done <"$ART/w23_eval.txt"
log "  清单核对汇总：缺失（只 WARN）=${n_missing} 条；方向异常（FAIL）=${n_dir_bad} 条；清单总长=$(grep -c . "$ART/w23_eval.txt") 条"
log "  明细已落盘：$ART/w23_eval.txt（label/kind/lines/value × A/B/C/D）"

log "--- 判据 ② 数据面：flush 前后读数一致（硬）---"
C_END=$(row_sum "$(sq "select count(s1) from $DB.**;")")
S_END=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
assert_eq "  全流程结束后点数" "${C_END:-0}" "${C_ALL:-0}"
assert_eq "  全流程结束后值总和" "${S_END:-0}" "${S_ALL:-0}"
FP=$(cmp_fp_tree "$DB"); SEQ=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
sq "flush;" >/dev/null
FP2=$(cmp_fp_tree "$DB"); SEQ2=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")
if [ "$FP" = "$FP2" ]; then pass "  flush 前后 count/sum 指纹一致：$FP"; else fail "  flush 前后 count/sum 指纹不一致：[$FP2] vs [$FP]"; fi
if [ "$SEQ" = "$SEQ2" ]; then pass "  flush 前后 d1 全序列指纹一致"; else fail "  flush 前后 d1 全序列指纹不一致"; fi
OOM=$(wal_oom_cnt); assert_eq "  WAL 相关 OOM 日志行数（必须 0）" "${OOM:-0}" "0"

if [ "$fail_flag" -gt 0 ]; then
  log "--- 有失败项 ⇒ 打印逐副本证据（便于定责）---"
  w23_evidence "失败取证"
fi

log "--- 收尾三件套（WAL 正证据 + WAL 专属异常正则）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
wal_install_err_pat 'Fail to snapshot memTable|Fail to delete outdated wal file|Fail to roll wal|Fail to sync wal node|Fail to fsync wal node|Failed to load WAL segment'
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader|Connection reset by peer'
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
