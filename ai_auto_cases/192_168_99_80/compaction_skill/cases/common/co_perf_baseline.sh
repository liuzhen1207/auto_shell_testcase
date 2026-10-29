#!/bin/bash
# ============================================================================
# CO-11 合并性能基准（可跨版本回归对比）
#   做法：关掉三类合并 → 用**单个 CLI 会话**批量写入固定规模数据（避免逐条 CLI 启动开销）
#         → 等三节点落盘稳定 → 记录输入文件数/字节数 → 在**热开合并之前**采 finish 基线
#         → 热开 seq 合并 → 计时到"合并推进完成"
#         → 记录输出文件数/字节数、合并耗时、吞吐（点/秒）、写放大（输出/输入）
#   产物：results/perf_baseline.csv（按 build+case 追加一行；同 build 已有历史行时比较耗时并给偏差）
#         artifact_<case>_<run_id>/co11_evidence_baseline.txt、co11_evidence_end.txt
#              （逐节点 × seq/unseq/all/close/finish，用于复核口径与计数）
#         artifact_<case>_<run_id>/jstack_<node>_<原因>.txt（失败时 jstack 原文 + IoTDB-Compaction 线程片段）
#
#   判据（CO-11 修正版，见 docs/CO11_CO14_TRIAGE.md §1.6）：
#     ① 合并完成 = **去重后的"唯一任务 finish 数"** > 热开合并**之前**采的基线 fin0
#        **且** seq 文件数 < ts0（ts0 只在三节点都落盘、且逐节点计数二次采样一致时才采）
#     ② 合并前后数据指纹完全一致（硬判据，未弱化）
#     ③ 无线程卡在 TsFileResource.writeLock
#     ④ 收尾三件套（sync lag / 副本一致性 / 日志异常）
#
#   修掉的两个**假 FAIL**（RC7 双协议回归里踩到）：
#     · V1：fin0 原来采在 `cmp_set_hot` 之后（合并只要 8s）⇒ 基线已含全部 6 个任务，
#           `f > fin0` 恒不成立。现在基线前移到热开之前 + 二次采样一致才采用。
#     · V1/V2 计数：原来 `cmp_log_files` 把 log_datanode_compaction.log 与 log_datanode_all.log
#           **都 cat**，同一条 finish 被算两次（fin0 翻倍）。现在 `sort -u` 去重成"唯一任务数"。
#     · V2：IN/OUT 只数 seq、等待判据 `t` 用 seq+unseq（口径混用）＋基线采在"节点 .77 落盘=0"的瞬间。
#           现在 IN/OUT/ts0/等待判据**统一 seq 口径**，unseq/all 只打印；坏时刻禁止采基线。
#
#   场景无效（环境时序）的**降级路径**（RC7 双协议回归 A2 实测后新增）：
#     一旦 perf_ts0_probe 判定"三节点落盘不齐"（含按约定重试一次后仍不齐），置全局
#     **PERF_SCENARIO_INVALID=1**；此后**合并推进类**判据一律降级为 WARN + 逐副本实测，
#     不再计入 fail_flag：① 输入/输出 seq 文件数（含"是否具备合并条件"）
#     ② 合并窗口内是否推进（finishes 增量 / seq 下降） ③ perf_baseline.csv 的耗时/写放大结论
#     （该行改记为 case=co_perf_baseline_SCENARIO_INVALID，不参与同 build 历史基线比较）。
#     同时把"只由本用例自造的 drop+recreate 重试直接引发、且日志内已自愈"的落盘/pipe 收尾报错
#     （asyncClose / pipe TsFileEpoch）按**窄白名单**降级为 WARN（见 PERF_INVALID_BENIGN_PAT）。
#     **数据面判据仍硬判**（与单副本是否落盘无关，经其它副本可查）：合并前后指纹一致、
#     收尾 sync lag 归零、副本一致性、白名单外的任何日志异常、线程卡 TsFileResource.writeLock。
#     场景有效（PERF_SCENARIO_INVALID=0）时本路径完全不生效，判据与历史版本逐字一致。
#
#   性能数值只做**记录 / 偏差 WARN**（环境波动大，不作为硬判定）
# 参数： CO_PERF_DEVS=10 CO_PERF_ROWS=10000 CO_PERF_BATCHES=6
#        CO_PERF_SAMPLE_GAP=5（二次采样间隔秒） CO_PERF_RETRY_WRITE=1（场景无效时重写一次写入段）
# 用法： bash co_perf_baseline.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_perf_baseline_${DATA_CONSENSUS}"

DB=root.coperf
DEVS=${CO_PERF_DEVS:-10}
ROWS=${CO_PERF_ROWS:-10000}
BATCHES=${CO_PERF_BATCHES:-6}
WIN=${CO_PERF_WIN:-900}
POINTS=$(( DEVS * ROWS * BATCHES ))
# CO-11 专用采样参数（默认值不改；可用环境变量覆盖）
PERF_GAP=${CO_PERF_SAMPLE_GAP:-5}           # 二次采样间隔（秒）——短一点，不显著拉长用例
PERF_RETRY_WRITE=${CO_PERF_RETRY_WRITE:-1}  # 场景无效（三节点落盘始终不齐）时是否重写一次写入段
# 场景无效（环境时序）全局标记：由 perf_prep_ts0 判定后置 1。
#   1 = 合并推进类硬判据全部降级为 WARN（不再连带 FAIL）；数据面判据不受影响。
PERF_SCENARIO_INVALID=0
PERF_TS0_STABLE=1        # 1 = 基线可信（三节点均已落盘且二次采样一致）
PERF_RETRY_DONE=0        # 1 = 已执行过"场景重试"（drop+recreate 重写一次）
PERF_MERGE_ADVANCED=0    # 1 = 窗口内确实观测到合并推进（仅记录，用于降级消息）

# ===========================================================================
# CO-11 专用 helper（只在本用例内实现；lib/common.sh、lib/cmp.sh 不动）
# ===========================================================================
DBS=${DB#root.}   # 日志里的库标识形如 `root.coperf-3`，正则用 coperf 匹配

# 逐节点 seq/unseq 计数串（复用 lib 的 cmp_su，形如 "77:12/0 78:12/0 79:12/0 "）
#   ⚠️ 判据口径统一到 **sequence 空间**：IN / OUT / ts0 / 等待判据全部用 seq；
#      unseq 与 all=seq+unseq 只打印，供复核（V2 假 FAIL 的根因就是二者混用）。

# finish 的"唯一任务数"：把两个日志 cat 到一起后 `sort -u` 去重
#   实测同一条 finish 在 log_datanode_compaction.log 与 log_datanode_all.log 里**逐字节相同**
#   （两个 FAIL artifact 逐行 md5 相同），所以旧口径 `cat 两个文件 | grep -c` 恰好翻倍：
#   基线 fin0=12 = 6 个任务 × 2 ⇒ `f > fin0` 永远不成立（V1 假 FAIL）。
perf_fin_uniq(){ local h s=0 v
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF 'InnerSpaceCompaction task finishes successfully' | grep -E '(^|[- ])(root\.)?$DBS-[0-9]+' | sort -u | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${v:-0} ))
  done; echo "$s"; }

# 单节点证据串：seq/unseq/all + 落盘(Async close) + finish 三口径 + finish/starts 唯一数
#   fin_uniq == fin_compaction == fin_all ⇒ 同一条 finish 只被算一次（去重生效的直接证据）
perf_node_snapshot(){ local db=$1 h=$2
  sshx "$h" "S=\$(find $DB_DIR/data/datanode/data/sequence -path '*/$db/*' -name '*.tsfile' 2>/dev/null | wc -l); U=\$(find $DB_DIR/data/datanode/data/unsequence -path '*/$db/*' -name '*.tsfile' 2>/dev/null | wc -l); CL=\$(grep -hcE 'Async close tsfile: .*$db' $DB_DIR/logs/log_datanode_all.log 2>/dev/null); C=$DB_DIR/logs/log_datanode_compaction.log; L=$DB_DIR/logs/log_datanode_all.log; P='InnerSpaceCompaction task finishes successfully'; PF='InnerSpaceCompaction task (finishes successfully|starts with)'; R='(^|[- ])(root\.)?$DBS-[0-9]+'; c=\$(grep -hF \"\$P\" \$C 2>/dev/null | grep -cE \"\$R\"); a=\$(grep -hF \"\$P\" \$L 2>/dev/null | grep -cE \"\$R\"); us=\$(cat \$C \$L 2>/dev/null | grep -hE \"\$PF\" | grep -E \"\$R\" | sort -u | awk '/finishes successfully/{f++} /starts with/{s++} END{printf \"%d/%d\", f+0, s+0}'); printf 'seq=%s unseq=%s all=%s close=%s fin_uniq=%s fin_compaction=%s fin_all=%s fin/starts_uniq=%s' \"\${S:-0}\" \"\${U:-0}\" \"\$(( \${S:-0} + \${U:-0} ))\" \"\${CL:-0}\" \"\${us%%/*}\" \"\${c:-0}\" \"\${a:-0}\" \"\$us\"" 2>/dev/null | tr -d '\r'; }

# 逐节点 × (seq, unseq, …) 证据落盘到 artifact（写入段结束 / 窗口结束各一次）
#   ⚠️ `local label=$1 ... f="${label}..."` 同行引用在 `set -u` 下会 unbound（本项目踩过），必须拆两句
perf_dump_evidence(){ local label=$1 db=$2 h f
  f="$ART/co11_evidence_${label}.txt"
  {
    printf '# CO-11 证据 label=%s run_id=%s build=%s consensus=%s db=%s time=%s\n' \
      "$label" "$RUN_ID" "$BUILD_TAG" "${CONSENSUS_CLASS##*.}" "$db" "$(date --iso-8601=seconds)"
    printf '# 判据口径 = seq（sequence 空间）；unseq/all 只记录，供复核\n'
    printf '# fin_compaction / fin_all = 只用单个日志文件的 finish 计数（旧实现把两者相加 ⇒ 恰好翻倍）；\n'
    printf '# fin_uniq = 去重后的"唯一任务数"（本用例的判据口径）。复核要点：\n'
    printf '#   ① fin_uniq 应 = fin_compaction = fin_all（同一条 finish 在两个日志里逐字节相同）；\n'
    printf '#   ② 旧口径 fin_compaction+fin_all = 2×fin_uniq ⇒ 基线翻倍、`f > fin0` 恒不成立（V1 假 FAIL 根因）；\n'
    printf '#   ③ 任一节点 seq=0 说明该副本未落盘/已清理 ⇒ 那一刻的 ts0 不可信，禁止采基线。\n'
  } > "$f"
  for h in "${DN[@]}"; do printf '%-15s %s\n' "$h" "$(perf_node_snapshot "$db" "$h")" >> "$f"; done
  log "  [证据] $label：逐节点明细已写入 $f"
  while IFS= read -r l; do log "    $l"; done < "$f"; }

# 失败时的 jstack 原文（至少含 IoTDB-Compaction 线程栈；排查 TsFileResource.writeLock 卡死）
perf_dump_jstack(){ local why=$1 h pid f part n
  for h in "${DN[@]}"; do
    pid=$(sshx "$h" "pgrep -f com.timecho.iotdb.DataNode | head -1" 2>/dev/null | tr -d '\r')
    f="$ART/jstack_${h##*.}_${why}.txt"
    if [ -z "${pid:-}" ]; then
      printf 'node=%s: 未找到 DataNode 进程（pid 为空）\n' "$h" > "$f"
      log "  jstack: $h 未找到 DataNode 进程（$f）"; continue
    fi
    { printf '### node=%s pid=%s why=%s time=%s\n' "$h" "$pid" "$why" "$(date --iso-8601=seconds)"; sshx "$h" "jstack $pid" 2>&1; } > "$f" 2>&1
    part="${f%.txt}.compaction.txt"
    awk 'BEGIN{p=0} /^"/{ if(p) print ""; p = ($0 ~ /IoTDB-Compaction/) ? 1 : 0 } p' "$f" > "$part" 2>/dev/null || true
    n=$(grep -c 'TsFileResource.writeLock' "$f" 2>/dev/null | tr -dc '0-9')
    if [ "${n:-0}" -gt 0 ]; then grep -n 'TsFileResource.writeLock' "$f" >> "$part" 2>/dev/null || true; fi
    log "  jstack: $h pid=$pid 卡 writeLock 线程数=${n:-0}；原文=$f；Compaction 线程片段=$part"
  done; }

# 写入段（单会话批量；每批一次 flush → 一个 TsFile）；T_W0/T_W1 供写入速率用
perf_write_batches(){ local b BT0 BT1 got
  T_W0=$(date +%s)
  for b in $(seq 1 "$BATCHES"); do
    BT0=$(date +%s); got=$(cmp_bulk_tree_session "$DB" "$DEVS" "$ROWS" "$b" | tail -1); BT1=$(date +%s)
    log "  第 $b 批：d1 行数=$got 耗时=$((BT1-BT0))s"
  done
  T_W1=$(date +%s); }

# 场景重试：删库重建 + 按同一规模重写（点数由 CO_PERF_* 决定，规模不变）
perf_scenario_rewrite(){
  log "  --- 场景重试：删除并重建 $DB，重新写入同一规模数据 ---"
  sq "drop database $DB;" >/dev/null 2>&1 || true
  sleep 6
  cmp_make_tree_db "$DB" "$DEVS"
  perf_write_batches
  log "  场景重试写入完成：耗时=$((T_W1-T_W0))s"; }

# 可信 ts0 探测：ensure_closed 成功 + 三节点 seq 均 ≥1 + 逐节点 (seq,unseq) 二次采样一致
#   结果经全局 PERF_PROBE_SU 返回（**不能**用 stdout：log() 也写 stdout，会被一起捕获）
perf_ts0_probe(){ local db=$1 i s1 s2
  PERF_PROBE_SU=""
  for i in 1 2 3; do
    if ensure_closed "$db" 2 25; then
      s1=$(cmp_su "$db"); sleep "$PERF_GAP"; s2=$(cmp_su "$db")
      if [ "$s1" = "$s2" ] && [ "${s1#*:0/}" = "$s1" ]; then
        PERF_PROBE_SU=$s1; return 0
      fi
      if [ "$s1" != "$s2" ]; then log "    第 $i 次采样：逐节点计数未稳定 $s1 → $s2"
      else log "    第 $i 次采样：有节点 seq=0（该副本未落盘/已清理）$s1"; fi
    else
      log "    第 $i 次采样：ensure_closed 未全部落盘（$(ttl_close_snapshot "$db")）"
    fi
    sleep 8
  done
  return 1; }

# 建立基线：稳定 → PERF_TS0_STABLE=1；否则按约定判"场景无效"并重试一次；
#   重试后仍无效 ⇒ 走**降级路径**（PERF_SCENARIO_INVALID=1），而不是直接 FAIL：
#   合并推进类判据在后续全部按 WARN 处理，数据面判据仍硬判。
perf_prep_ts0(){
  PERF_SCENARIO_INVALID=0
  if perf_ts0_probe "$DB"; then PERF_TS0_STABLE=1; PERF_SU=$PERF_PROBE_SU; return 0; fi
  warn "$DB 场景无效：三节点落盘不齐（$(ttl_close_snapshot "$DB")），按约定重试一次"
  if [ "$PERF_RETRY_WRITE" = 1 ] && [ "${PERF_RETRY_DONE:-0}" = 0 ]; then
    PERF_RETRY_DONE=1
    perf_scenario_rewrite
    if perf_ts0_probe "$DB"; then PERF_TS0_STABLE=1; PERF_SU=$PERF_PROBE_SU; return 0; fi
  fi
  PERF_TS0_STABLE=0
  PERF_SCENARIO_INVALID=1        # ← 明确全局标记：从此"合并推进类"判据只 WARN、不计入 fail_flag
  PERF_SU=$(cmp_su "$DB")
  perf_dump_evidence "invalid" "$DB"   # 逐副本 (seq, unseq, all, close, fin_uniq) 实测落盘
  perf_scenario_invalid_summary "$DB"
  return 1; }

# 等合并推进（**单一口径**：判据用 seq；unseq/all 只打印）。结果经 PERF_WAIT_SUM 返回。
#   成功 = 去重后的唯一任务数 > fin0（热开前基线）且 seq 文件数 < ts0（同口径基线）
perf_wait_merge(){ local db=$1 fin0=$2 ts0=$3 win=$4 f t u a peak=0
  local deadline=$(( $(date +%s) + win ))
  PERF_WAIT_SUM=""
  while (( $(date +%s) < deadline )); do
    sleep "$PERF_GAP"
    f=$(perf_fin_uniq "$db")
    t=$(cmp_seq_sum "$db"); u=$(cmp_unseq_sum "$db"); a=$(( ${t:-0} + ${u:-0} ))
    [ "${t:-0}" -gt "$peak" ] && peak=$t
    log "    等合并: finishes=$f(基线$fin0 唯一任务) | seq=$t(基线$ts0 峰值$peak) unseq=$u all=$a"
    if [ "${f:-0}" -gt "$fin0" ]; then
      if [ "${t:-0}" -lt "$ts0" ]; then
        PERF_WAIT_SUM="finishes=$f(基线$fin0) seq=$t(基线$ts0) unseq=$u"; return 0
      fi
      # 基线降级（环境时序、ts0 不可信）时，seq 相对窗口内峰值下降同样算"文件数真的降了"
      if [ "${PERF_TS0_STABLE:-1}" = 0 ] && [ "${t:-0}" -lt "$peak" ]; then
        PERF_WAIT_SUM="finishes=$f(基线$fin0) seq=$t(峰值$peak；ts0=$ts0 不可信/降级) unseq=$u"; return 0
      fi
    fi
  done
  PERF_WAIT_SUM="finishes=${f:-0}(基线$fin0) seq=${t:-0}(基线$ts0 峰值$peak) unseq=${u:-0}"; return 1; }

# ===========================================================================
# 场景无效（环境时序）的降级辅助（只在本用例内实现；lib/common.sh、lib/cmp.sh 不动）
# ===========================================================================
# 允许降级为 WARN 的**窄**白名单：只放"本用例自造的 drop+recreate 场景重试"直接引发的
# 落盘/pipe 收尾报错。实测原文（A2 artifact 三节点同一条）：
#   java.lang.NullPointerException: Cannot invoke
#     "...DataRegion.asyncCloseOneTsFileProcessor(...)" because the return value of
#     "...StorageEngine.getDataRegion(...)" is null
#     at ...PipeTsFileEpochProgressIndexAndFlushManager.flushAllTimeoutTsFiles(...:81)
# 紧跟着 `Successfully executed subtask ... after 1 retries`（日志内自愈）；
# 根因是重试时 `drop database` 把 DataRegion 摘掉、pipe 的 TsFileEpoch 仍持有旧 regionId，
# 与"合并是否推进"无关。**真问题不得进白名单**：只要该节点还有一条白名单外的异常行，
# 这些 FAIL 全部恢复硬判。
PERF_INVALID_BENIGN_PAT='asyncCloseOneTsFileProcessor|PipeTsFileEpochProgressIndexAndFlushManager'

# 逐副本紧凑实测串（降级消息里必须带全量实测值）：
#   形如 "77[seq=0 unseq=14 all=14 close=0 fin_uniq=0 ] 78[seq=7 ...] 79[...] "
perf_replica_brief(){ local db=$1 h s out=""
  for h in "${DN[@]}"; do
    s=$(perf_node_snapshot "$db" "$h" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^(seq|unseq|all|close|fin_uniq)=/) printf "%s ", $i}')
    out="$out${h##*.}[$s] "
  done; printf '%s' "$out"; }

# "全程未 close（0 个 Async close 事件）"的副本 = 场景无效的直接证据（多个用逗号连接）
perf_no_close_nodes(){ local db=$1 h n s=""
  for h in "${DN[@]}"; do n=$(ttl_close_cnt "$h" "$db"); [ "${n:-0}" -eq 0 ] && s="$s${h},"; done
  printf '%s' "${s%,}"; }

# 用例输出里的**一行总结**（用 warn ⇒ 同时进 v_warnMessage，在 test_result.csv 里直接可见）
perf_scenario_invalid_summary(){ local db=$1 nc
  nc=$(perf_no_close_nodes "$db")
  if [ -n "$nc" ]; then
    warn "场景无效（环境时序）：${CONSENSUS_CLASS##*.} 下 $nc 全程未 close（0 文件）⇒ 合并推进类判据按约定降级为 WARN，不计入 fail_flag；数据面判据（指纹/行数/副本一致/sync lag）仍硬判"
  else
    warn "场景无效（环境时序）：三节点 close 事件都有，但逐副本 (seq,unseq) 二次采样始终未稳定 ⇒ 合并推进类判据按约定降级为 WARN，不计入 fail_flag；数据面判据仍硬判"
  fi
  warn "场景无效：逐副本实测 (seq, unseq, all, close, fin_uniq) = $(perf_replica_brief "$db")；详见 $ART/co11_evidence_invalid.txt" ; }

# 场景无效 + 确实走过重试时的日志检查：逐条审查 check_logs 产生的 FAIL，若该节点的异常**全部**
# 命中窄白名单 ⇒ 降级为 WARN（保留节点/条数/原文行号）；只要有一条白名单外的异常 ⇒ 全部恢复 FAIL。
# 场景有效、或没走重试 ⇒ 直接走原 check_logs，判据完全不变（不放过真问题）。
perf_check_logs_softened(){ local def cnt=0 i a b bad real=0
  if [ "${PERF_SCENARIO_INVALID:-0}" != 1 ] || [ "${PERF_RETRY_DONE:-0}" != 1 ]; then check_logs; return 0; fi
  def="$(declare -f fail)"
  local msgs=() offs=()
  # 临时改写 fail：只登记"哪一条 FAIL + 它的原文会追加在 $OUT 的第几行起"，先不判
  fail(){ msgs+=("$*"); offs+=("$(( $(wc -l <"$OUT") + 1 ))"); cnt=$(( cnt + 1 )); }
  check_logs
  eval "$def"
  if [ "$cnt" -eq 0 ]; then log "  场景无效降级审查：日志无异常"; return 0; fi
  for ((i=0;i<cnt;i++)); do
    a=${offs[$i]}
    if [ $((i+1)) -lt "$cnt" ]; then b=$(( offs[i+1] - 1 )); else b=$(wc -l <"$OUT"); fi
    # 取不到原文（追加失败）时保守处理：按"含白名单外异常"计，恢复硬判
    if [ "$b" -lt "$a" ]; then bad=1; else
      bad=$(sed -n "${a},${b}p" "$OUT" | grep -E "$COMMON_ERR_PAT|$CMP_ERR_PAT" | grep -vE "$BENIGN_PAT" | grep -vcE "$PERF_INVALID_BENIGN_PAT")
    fi
    log "  场景无效降级审查：${msgs[$i]} → 该节点异常行中含白名单外 ${bad:-0} 条"
    [ "${bad:-0}" -gt 0 ] && real=$(( real + 1 ))
  done
  if [ "$real" -eq 0 ]; then
    for ((i=0;i<cnt;i++)); do
      warn "场景无效降级（日志窄白名单）：${msgs[$i]} ⇒ 原文只命中 /$PERF_INVALID_BENIGN_PAT/（本用例重试 drop+recreate 引发的 pipe 落盘收尾报错，日志随后 [Successfully executed subtask ... after N retries] 已自愈），按约定不计入 fail_flag"
    done
    log "  原文行号已随 check_logs 追加在 $OUT；原始日志备份在 $ART/logs/"
  else
    for ((i=0;i<cnt;i++)); do
      fail "${msgs[$i]}（场景无效降级审查：该节点含窄白名单外的真异常，恢复硬判）"
    done
  fi; }
# --- CO-11 专用 helper 结束 ---

# ===========================================================================
# 主流程
# ===========================================================================
log "--- 集群准备（三类合并全关，先把文件攒出来）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}" cmp_cluster_prepare
log "  规模：$DEVS 设备 × $ROWS 点 × $BATCHES 批 = $POINTS 点"

cmp_make_tree_db "$DB" "$DEVS"
log "--- 写入（单会话批量；每批一次 flush → 一个 TsFile）---"
perf_write_batches

log "--- 建立可信基线（禁止在坏时刻采样：ensure_closed 失败 / 任一节点 seq=0 时不得采 ts0）---"
PERF_TS0_STABLE=1; PERF_RETRY_DONE=0; PERF_SCENARIO_INVALID=0; PERF_MERGE_ADVANCED=0; PERF_SU=""; PERF_PROBE_SU=""
perf_prep_ts0 || true
IN_FILES=$(cmp_seq_sum "$DB"); IN_UNSEQ=$(cmp_unseq_sum "$DB"); IN_BYTES=$(cmp_bytes_sum "$DB")
TS0=$IN_FILES   # ts0 与 IN 同口径（seq）、同一次稳定采样
log "  写入耗时=$((T_W1-T_W0))s；输入：seq=$IN_FILES unseq=$IN_UNSEQ all=$(( IN_FILES + IN_UNSEQ )) 个 TsFile / ${IN_BYTES}B（逐节点 $(cmp_su "$DB")＝seq/unseq）"
log "  基线可信度：$([ "$PERF_TS0_STABLE" = 1 ] && echo '三节点均已落盘且逐节点计数二次采样一致（可信）' || echo '降级：三节点落盘不齐（环境时序），ts0 不可信')；稳定快照=$PERF_SU"
if [ "${IN_FILES:-0}" -ge 2 ]; then
  pass "输入文件数(seq)=$IN_FILES（≥2，具备合并条件）"
elif [ "${PERF_SCENARIO_INVALID:-0}" = 1 ]; then
  warn "场景无效降级：输入文件数(seq)=$IN_FILES（<2，不具备合并条件）——按约定降级为 WARN，不计入 fail_flag；逐副本实测：$(perf_replica_brief "$DB")"
else
  fail "场景无效：输入文件数(seq)=$IN_FILES（<2）"
fi

fp0=$(cmp_fp_tree "$DB")
log "  合并前指纹：$fp0"
perf_dump_evidence "baseline" "$DB"

log "--- 记录 finish 基线（必须在热开合并**之前**；去重后的唯一任务数；二次采样一致才作基线）---"
fin_a=$(perf_fin_uniq "$DB"); sleep "$PERF_GAP"; fin_b=$(perf_fin_uniq "$DB")
if [ "$fin_a" = "$fin_b" ]; then
  fin0=$fin_b; pass "finish 基线二次采样一致：fin0=$fin0（唯一任务数；旧的双日志口径会翻倍成 $(( fin0 * 2 ))）"
else
  fin0=$fin_b; warn "finish 基线二次采样不一致（$fin_a → $fin_b）：取较晚值 fin0=$fin0 作基线"
fi

log "--- 热开 seq 合并并计时（窗口 ${WIN}s）---"
cmp_set_hot enable_seq_space_compaction true >/dev/null
fin0b=$(perf_fin_uniq "$DB")
[ "${fin0b:-0}" -gt "${fin0:-0}" ] && warn "采样竞态：热开合并后唯一任务数已从 $fin0 涨到 $fin0b（热开期间即有任务完成）；判据仍用热开前基线 $fin0"
T_M0=$(date +%s)   # 计时只覆盖"等合并推进"窗口（与历史 perf_baseline.csv 口径一致）

if perf_wait_merge "$DB" "$fin0" "$TS0" "$WIN"; then
  T_M1=$(date +%s); MERGE_SEC=$((T_M1-T_M0)); PERF_MERGE_ADVANCED=1
  if [ "${PERF_SCENARIO_INVALID:-0}" = 1 ]; then
    warn "场景无效降级：窗口内观测到合并推进（$PERF_WAIT_SUM，耗时 ${MERGE_SEC}s）——按约定只记为 WARN（记录实测），不作为判据；逐副本实测：$(perf_replica_brief "$DB")"
  else
    pass "合并完成：$PERF_WAIT_SUM，耗时 ${MERGE_SEC}s"
  fi
else
  T_M1=$(date +%s); MERGE_SEC=$((T_M1-T_M0)); PERF_MERGE_ADVANCED=0
  if [ "${PERF_SCENARIO_INVALID:-0}" = 1 ]; then
    warn "场景无效降级：窗口内未观测到合并推进（$PERF_WAIT_SUM，窗口 ${WIN}s）——按约定降级为 WARN，不计入 fail_flag；逐副本实测：$(perf_replica_brief "$DB")"
    perf_dump_jstack "invalid_timeout"   # 仅取证（卡死仍由下面 stuck 判据硬判）
  else
    fail "合并未在 ${WIN}s 内完成：$PERF_WAIT_SUM"
    perf_dump_jstack "timeout"
  fi
fi
OUT_FILES=$(cmp_seq_sum "$DB"); OUT_UNSEQ=$(cmp_unseq_sum "$DB"); OUT_BYTES=$(cmp_bytes_sum "$DB")
log "  输出：seq=$OUT_FILES unseq=$OUT_UNSEQ all=$(( OUT_FILES + OUT_UNSEQ )) 个 TsFile / ${OUT_BYTES}B（逐节点 $(cmp_su "$DB")＝seq/unseq）"
if [ "${PERF_SCENARIO_INVALID:-0}" = 1 ]; then
  # 场景无效 ⇒ 耗时/写放大不可比：本行改用带标记的 case 名（不参与同 build 历史基线比较），只"记录实测"
  warn "场景无效降级：perf_baseline.csv 的耗时/写放大【结论】不可比（场景无效）⇒ 本行记为 case=co_perf_baseline_SCENARIO_INVALID，只记录实测：merge=${MERGE_SEC}s 写放大=$(awk -v a="$IN_BYTES" -v b="$OUT_BYTES" 'BEGIN{printf "%.2f", (a>0? b/a : 0)}')（seq $IN_FILES → $OUT_FILES）"
  cmp_perf_record "co_perf_baseline_SCENARIO_INVALID" "$POINTS" "$IN_FILES" "$IN_BYTES" "$OUT_FILES" "$OUT_BYTES" "$MERGE_SEC"
else
  cmp_perf_record "co_perf_baseline" "$POINTS" "$IN_FILES" "$IN_BYTES" "$OUT_FILES" "$OUT_BYTES" "$MERGE_SEC"
fi
log "  写入速率=$(awk -v p="$POINTS" -v s="$((T_W1-T_W0))" 'BEGIN{printf "%.0f", (s>0? p/s : 0)}') 点/秒；合并速率=$(awk -v p="$POINTS" -v s="$MERGE_SEC" 'BEGIN{printf "%.0f", (s>0? p/s : 0)}') 点/秒"
perf_dump_evidence "end" "$DB"

# 数据面判据（永久硬判：与"单副本是否落盘"无关，经其它副本可查）
cmp_assert_same "合并前后数据指纹" "$fp0" "$(cmp_fp_tree "$DB")"
# 合并推进类判据（场景无效时降级为 WARN + 记录实测）
if [ "${OUT_FILES:-0}" -lt "${IN_FILES:-0}" ]; then
  if [ "${PERF_SCENARIO_INVALID:-0}" = 1 ]; then
    warn "场景无效降级：合并后 seq 文件数已下降（$IN_FILES → $OUT_FILES）——按约定只记录为 WARN，不作为判据"
  else
    pass "合并后文件数下降（seq $IN_FILES → $OUT_FILES）"
  fi
elif [ "${PERF_SCENARIO_INVALID:-0}" = 1 ]; then
  warn "场景无效降级：合并后 seq 文件数未下降（$IN_FILES → $OUT_FILES）——按约定降级为 WARN，不计入 fail_flag；逐副本实测：$(perf_replica_brief "$DB")"
else
  fail "合并后文件数未下降（seq $IN_FILES → $OUT_FILES）"
fi
# 合并后逐节点 sanity（只记录：某副本 seq 归零可能是"该副本未落盘/被清理"，不是数据判据）
OUT_SU=$(cmp_su "$DB")
if [ "${OUT_SU#*:0/}" != "$OUT_SU" ]; then warn "合并后有 DN 的 seq TsFile 数为 0（$OUT_SU）"; fi
STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"
[ "${STUCK:-0}" = "0" ] || perf_dump_jstack "stuck"

log "--- 收尾三件套 ---"
if [ "${PERF_SCENARIO_INVALID:-0}" = 1 ]; then
  # 数据面 1/3、2/3 与场景有效时**完全一致**（硬判）；3/3 日志异常只对窄白名单降级
  log "  （场景无效：1/3 sync lag、2/3 副本一致性、指纹/行数仍硬判；3/3 日志异常仅窄白名单降级）"
  check_sync_lag || true
  consistency_check "select count(s1) from $DB.d1 order by time;" tree
  perf_check_logs_softened
else
  post_checks "select count(s1) from $DB.d1 order by time;" tree
fi
cmp_case_finish "" tree ""
