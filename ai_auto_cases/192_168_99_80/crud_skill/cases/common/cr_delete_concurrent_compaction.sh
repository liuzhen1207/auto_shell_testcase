#!/bin/bash
# ============================================================================
# CR-06 删除 × 合并并发：合并**进行中**下发 DELETE 不得丢删除（N_Mod / C_Mod / cascade）
#       覆盖 R-23 / R-24 / R-25（出处：docs/REQ_MATRIX.md §3 CR-06 + §1 逐字原文）
#
# 语义（逐字对照需求）：
#   R-23「在合并开始时，合并线程会为所有目标文件分配一个相同的 Mod 文件…将该 Mod 文件记录为
#         所有合并源文件的 Compaction Mod 文件」；
#   R-24「为了保证在向一个 TsFile 的 Mod 写入时，可以感知到并发生成的 C_MOD，需要在开始写入前加锁，
#         避免中间生成 C_MOD 文件且完成合并」；
#   R-25「还有一种比较极端的情况是合并目标文件也在删除操作写入前被删除。…需要检查其存在性，
#         如果其已经被删除，就需要重新获取 TsFile 列表，并对列表中产生的新文件进行删除」。
#
# ⚠️ 本构建（RC7）`TsFileResource.useSharedModFile = false`（编译期常量）⇒ **不会**创建
#    `.compaction.mods2`，走的是 `CompactionUtils.prepareCompactionModFiles` 的 cascade 分支
#    （`setCascadeFile`：源文件 mod 写入时会级联写到合并目标文件的 mod 文件）。
#    因此判据只断「语义」——合并后目标文件仍受删除约束（被删行不复活、未删行不丢），
#    **不断言** `.compaction.mods2` 文件存在（见 REQ_MATRIX §4-B4）。
#
# 场景（两相：树 + 表，各 4 批 × 2500 行 × 1KB TEXT ⇒ 约 10MB/相；合并读/写限流 1MB/s ⇒ 窗口 ≈10s）：
#   ① 三类合并先关 → 写 N 批 + FLUSH 造 N 个 L0 seq TsFile（每批等 close 事件，布局可控）
#   ② 记基线（探针 starts/finishes/TsFile 数/mods2 数 + 存活集指纹 + 被删集行数）
#   ③ 热开 seq 合并 → **一次并行往返**探测「task starts 已出现 **且** 文件数尚未下降」⇒ 立刻 DELETE
#   ④ 删除后立刻再探一次（文件数是否已下降 / mods2 是否已生成）
#   ⑤ 等合并收敛（finishes 增 **且** 文件数降）→ 断言：被删范围为空、存活集指纹逐字节一致、
#      总行数 = 删除前 − 被删行数
#   ⑥ 目标再被合并相（表相后追加）：把上一轮合并产物当源文件再并一轮 ⇒ 目标文件消失、删除语义保持
#
# 判据（硬判 / 降级）：
#   硬判 1（场景有效性）：注入时机成立 + 被删集行数 == ROWS/2（证明删除确实覆盖了被合并源文件的数据）
#   硬判 2（场景有效性，权威）：**同节点时钟**证据 —— 日志里存在某次 DELETE 的时间戳落在
#          该节点某个 `InnerSpaceCompaction task starts` 与 `finishes successfully` 之间
#          （跨节点时钟可能有偏差，所以只在**同一节点自己的日志**里比）
#   硬判 3（双信号）：`InnerSpaceCompaction task finishes successfully` 行数增加 **且** 该库 TsFile 数下降
#   硬判 4（数据面）：DELETE 范围内行数 == 0（不得复活）；存活集（time > T）指纹与删除前**完全一致**
#          （不得丢失未删数据）；总行数 == 删除前 − 被删行数
#   硬判 5（目标再被合并）：第一轮合并产物文件名在第二轮合并后**消失**（确被再次吃掉），
#          且第二轮后被删范围仍为空、存活集指纹仍一致
#   硬判 6：无 `.mods2` 孤儿残留（无同名 tsfile 的 mods2）——WARN 级（合并清理有窗口，见"可能误判"）
#   降级 WARN：`.mods2` 计数（合并提交后源文件连同其 mods2 被删，计数为 0 属正常，不作硬判据）
#   降级 WARN（**RC8 首轮实跑后修正**，见下"harness 修复记录"）：
#           注入窗口没抓住（合并快于 DELETE 往返）⇒ 判「场景未成立」并**跳过**第 2~5 组并发判据，
#              不产生连带 FAIL；数据正确性判据仍然执行
#
# ★ harness 修复记录（RC8 首轮实跑暴露，全部是**用例侧**问题）：
#   ① `line 263: delsql: unbound variable`：DELETE 语句变量**从未定义**（set -u ⇒ 命令替换拿到空串、
#      DELETE 根本没发出去）⇒ 后面「被删范围行数 / 被删行不得复活 / 总行数」全部假 FAIL。
#      现在按方言显式生成 `delsql`（树必须带 `.**`），并且**无论注入时机是否命中都发出这次 DELETE**
#      ⇒ 删除的数据面断言（复活/丢失/总数）始终有效，不再随注入窗口一起丢失。
#   ② 两处"场景未成立"原本写的是 `fail`，与同一句里的"不计连带 FAIL"自相矛盾：
#      「45×2s 内未抓到合并进行中」与「同节点时钟证据未命中」都依赖 **合并窗口(~10s) vs ssh 探测往返**
#      的运气，属**不可稳定构造**；现按 README 规则改为 **WARN + 打印原始证据**
#      （`$ART/inflight_<db>.txt`、每次探测的 s/f/tsfile/mods2），功能判据不受影响。
#   ③ 表模型行数原用 `table_rows | wc -l`：CLI 超过一批（1000 行）会重复打表头 ⇒ 10000 行被数成
#      10009（与 CR-02 的 5000→5004 同源）。现按"表头原文"整行剔除后再数。
#
# 时长：约 14~18 分钟（两相写入各约 1~2 分钟 + 合并窗口各 ~10s + 收尾三件套 ~4 分钟）
# 规模与配置（顶部变量）：
CR06_BATCHES=${CR06_BATCHES:-4}     # 每相批数（= L0 文件数/副本）
CR06_ROWS=${CR06_ROWS:-2500}        # 每批行数（每行 1KB TEXT ⇒ 约 2.5MB/批）
CR06_PER=${CR06_PER:-250}           # 每条 INSERT 的行数（大 payload 必须走单会话 stdin）
CR06_WIN=${CR06_WIN:-120}           # 等合并收敛的窗口（秒）
CR06_INJ_WIN=${CR06_INJ_WIN:-45}    # 单次注入尝试内等「合并进行中」的窗口（秒）
CR06_INJ_TRY=${CR06_INJ_TRY:-2}     # 注入尝试次数（没抓住就补一批候选重试）
#
# 用法： bash cases/common/cr_delete_concurrent_compaction.sh [--consensus IoTConsensus|IoTConsensusV2]
#   ⚠ 本任务只做 `bash -n` 与本地纯桩验证，**未在集群实跑**。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_delete_concurrent_compaction_${DATA_CONSENSUS}"

DBT=root.cr06a          # 树模型
DBB=cr06t               # 表模型（表模型库名不带 root. 前缀）
TBT=tb                  # 表模型的表名（唯一，便于按 tableName 过滤日志）
DEV=d1

PAYLOAD=$(printf 'p%.0s' $(seq 1 1000))
BASE=$(( $(now_ms) - 600000 ))      # 10 分钟前 ⇒ 全部时间戳在过去、同一时间分区

# 合并限流：写/读各 1MB/s（int 键，最小正值）⇒ 10MB 文件 ⇒ 合并窗口 ≈10s，足够 DELETE 往返
CR06_EXTRA="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CR06_BATCHES},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,compaction_write_throughput_mb_per_sec=1,compaction_read_throughput_mb_per_sec=1"

# ---------------------------------------------------------------------------
# 观测 helper（`.mods2` 是 RC7 的删除标记文件后缀；lib 的 cmp_mods_* 按旧 `*.mods` 匹配 ⇒ 恒 0，不能用）
# ---------------------------------------------------------------------------
# 一次 ssh 往返并行探测：该库在单节点上的 starts / finishes / TsFile 数 / mods2 数
cr06_probe(){ sshx "$1" "L=\"$DB_DIR/logs/log_datanode_compaction.log $DB_DIR/logs/log_datanode_all.log\"
s=\$(cat \$L 2>/dev/null | grep -hF 'InnerSpaceCompaction task starts with' | grep -cE '(^|[- ])(root\.)?$2-[0-9]+')
f=\$(cat \$L 2>/dev/null | grep -hF 'InnerSpaceCompaction task finishes successfully' | grep -cE '(^|[- ])(root\.)?$2-[0-9]+')
t=\$(find $DB_DIR/data/datanode/data -path '*/$2/*' -name '*.tsfile' 2>/dev/null | wc -l)
m=\$(find $DB_DIR/data/datanode/data -path '*/$2/*' -name '*.mods2' 2>/dev/null | wc -l)
echo \"s=\${s:-0} f=\${f:-0} t=\${t:-0} m=\${m:-0}\"" 2>/dev/null | tr -d '\r'; }
# 3 个 DN **并行**探测（关键：串行 ssh 会把合并窗口耗光，CO-40 首跑就因此晚了 1s 错过窗口）
cr06_probe_all(){ local db=$1 i=0 h
  P_S=0; P_F=0; P_T=0; P_M=0
  rm -f "$ART"/.probe_*
  for h in "${DN[@]}"; do
    i=$(( i + 1 ))
    ( echo "$h $(cr06_probe "$h" "$db")" >"$ART/.probe_$i" 2>/dev/null ) &
  done
  wait
  P_RAW=$(cat "$ART"/.probe_* 2>/dev/null | tr '\n' '|')
  read -r P_S P_F P_T P_M <<<"$(printf '%s\n' "$P_RAW" | tr '|' '\n' | awk -F'[= ]' '{for(i=1;i<=NF;i++){if($i=="s")S+=$(i+1); if($i=="f")F+=$(i+1); if($i=="t")T+=$(i+1); if($i=="m")M+=$(i+1)}} END{print S+0, F+0, T+0, M+0}')"
  printf '    [注入探测] %s\n' "$P_RAW" >>"$OUT"; }
# mods2 计数（按库、多节点求和）
cr06_mods_cnt(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.mods2' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
cr06_mods_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cr06_mods_cnt "$h" "$1") )); done; echo "$s"; }
# 孤儿 mods2（没有同名兄弟 tsfile 的 mods2）
cr06_orphan_sum(){ local h s=0 n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$1/*' -name '*.mods2' 2>/dev/null | while read -r m; do [ -f \"\${m%.mods2}\" ] || echo x; done | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done; echo "$s"; }
# 树模型原始行数（聚合在设备级通配路径上会退化成 Empty set，必须用"原始查询数行"）
cr06_rows_tree(){ sq "$1" 2>&1 | strip_echo | data_rows | wc -l | tr -d ' '; }
# 表模型行数：**不能用 `table_rows | wc -l`** —— CLI 单条结果超过一批（实测 1000 行/批）会重复
#   打印表头，而 lib 的 table_rows 只丢第一行 ⇒ 多批行数虚高（RC8 实测：10000 行被数成 10009）。
#   这里按"表头原文"整行剔除后再数。
cr06_body_cnt(){ printf '%s\n' "$1" | grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' \
  | awk -F'|' 'NR==1{h=$2; next} {if ($2==h) next; c++} END{print c+0}'; }
cr06_rows_table(){ cr06_body_cnt "$(sqt "$1" 2>&1)"; }
# 轮询"原始查询行数"到期望值（DELETE 走共识，副本应用有延迟；用原始行数而不是聚合，
# 因为树方言在设备路径上聚合会返回 Empty set ⇒ wait_scalar_* 会"恒等于 0"地假 PASS）
cr06_wait_rows_tree(){ local sql=$1 want=$2 timeout=${3:-120} label=${4:-查询} got
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    got=$(cr06_rows_tree "$sql"); got=${got:-0}
    [ "$got" = "$want" ] && { pass "$label: $got"; return 0; }
    sleep 3
  done
  fail "$label: 实际=[${got:-?}] 期望=[$want]（等 ${timeout}s 仍未一致）"; return 1; }
cr06_wait_rows_table(){ local sql=$1 want=$2 timeout=${3:-120} label=${4:-查询} got
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    got=$(cr06_rows_table "$sql"); got=${got:-0}
    [ "$got" = "$want" ] && { pass "$label: $got"; return 0; }
    sleep 3
  done
  fail "$label: 实际=[${got:-?}] 期望=[$want]（等 ${timeout}s 仍未一致）"; return 1; }
# 「同节点时钟」权威证据：DELETE 时间戳是否落在某个合并任务的 [starts, finishes] 之间
#   做法：把该节点的 all+compaction 日志里相关的合并/删除行取出、按时间戳排序，再用 awk 判交集。
#   $2 = 删除行的过滤串（树：pathPattern=root.cr06a；表：tableName='tb'）——不用正则，避免转义地狱。
cr06_inflight(){ local db=$1 delpat=$2 h f
  : >"$ART/inflight_${db}.txt"
  for h in "${DN[@]}"; do
    f="$ART/ev_${db}_${h##*.}.txt"
    sshx "$h" "cat $DB_DIR/logs/log_datanode_all.log $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null | grep -hE 'InnerSpaceCompaction task (starts with|finishes successfully)|\[Deletion\]' | sort" 2>/dev/null | tr -d '\r' >"$f"
    awk -v db="$db" -v del="$delpat" -v node="${h##*.}" '
      { t = substr($0, 1, 23) }
      /InnerSpaceCompaction task starts with/     { if (index($0, db "-") > 0) st[++ns] = t; next }
      /InnerSpaceCompaction task finishes successfully/ { if (index($0, db "-") > 0) fi[++nf] = t; next }
      /\[Deletion\]/                              { if (index($0, del) > 0) de[++nd] = t }
      END {
        inflight = 0
        for (i = 1; i <= nd; i++) {
          d = de[i]
          for (j = 1; j <= ns; j++) {
            if (st[j] <= d) {
              ok = 1
              for (k = 1; k <= nf; k++) { if (fi[k] >= st[j] && fi[k] <= d) { ok = 0; break } }
              if (ok) inflight = 1
            }
          }
        }
        printf "node=%-14s del=%d starts=%d finishes=%d inflight=%d\n", node, nd, ns, nf, inflight
      }' "$f" >>"$ART/inflight_${db}.txt"
  done
  cat "$ART/inflight_${db}.txt"; }
cr06_inflight_nodes(){ printf '%s\n' "$1" | awk '{ if ($NF ~ /inflight=1/) c++ } END { print c + 0 }'; }
# 写入 1 批（树模型）：<db> <batch>；时间戳 = BASE + batch*1000000 + k*10（各批不重叠 ⇒ 落 sequence/）
cr06_write_tree(){ local db=$1 b=$2 i=0 k vals="" stmts="" ts
  for ((k=1; k<=CR06_ROWS; k++)); do
    ts=$(( BASE + b * 1000000 + k * 10 ))
    vals="$vals($ts,$(( k + b )),'$PAYLOAD'),"
    i=$(( i + 1 ))
    if [ $(( i % CR06_PER )) -eq 0 ]; then stmts="${stmts}insert into $db.$DEV(time,s1,s2) values ${vals%,};
"; vals=""; fi
  done
  [ -n "$vals" ] && stmts="${stmts}insert into $db.$DEV(time,s1,s2) values ${vals%,};
"
  printf '%s' "$stmts" | session_tree >/dev/null
  sq "flush;" >/dev/null; }
# 写入 1 批（表模型）：<db> <table> <batch>
cr06_write_table(){ local db=$1 tb=$2 b=$3 i=0 k vals="" stmts="" ts
  for ((k=1; k<=CR06_ROWS; k++)); do
    ts=$(( BASE + b * 1000000 + k * 10 ))
    vals="$vals($ts,'$DEV',$(( k + b ))),"
    i=$(( i + 1 ))
    if [ $(( i % CR06_PER )) -eq 0 ]; then stmts="${stmts}insert into $db.$tb (time, dev, v) values ${vals%,};
"; vals=""; fi
  done
  [ -n "$vals" ] && stmts="${stmts}insert into $db.$tb (time, dev, v) values ${vals%,};
"
  printf '%s' "$stmts" | session_table >/dev/null
  sqt "flush;" >/dev/null; }

# ===========================================================================
log "--- 集群准备：三类合并先关；candidate=${CR06_BATCHES}；读/写限流各 1MB/s（把合并窗口拉到 ~10s）---"
EXTRA_CONF="$CR06_EXTRA" cmp_cluster_prepare
log "  规模：每相 $CR06_BATCHES 批 × $CR06_ROWS 行 × 1KB ≈ $(( CR06_BATCHES * CR06_ROWS / 1024 ))MB"
log "  合并限流生效值：write=$(cmp_eff "${DN[0]}" compaction_write_throughput_mb_per_sec) read=$(cmp_eff "${DN[0]}" compaction_read_throughput_mb_per_sec)"
cmp_compaction_off

# ---------------------------------------------------------------------------
# 通用「写入 → 记基线 → 热开合并 → 合并中删 → 收敛 → 判据」的注入函数（两相共用）
#   <db> <dialect:tree|table> <delpat>
#     delpat = 该节点日志里用于识别"本次 DELETE"的固定子串（树：pathPattern=root.cr06a；
#              表：tableName='tb'）——用 `index()` 匹配，避免正则转义。
# ---------------------------------------------------------------------------
CR06_ADDED=0
cr06_phase(){
  local db=$1 dialect=$2 delpat=$3
  local del_t fin0 ts0 fin1 ts1 pre_total pre_del surv0 fp0 inj evid res infl_n delr delsql
  local ts0p start0p fin0p try dl ts_afd m_afd s_afd f_afd
  del_t=$(( BASE + 1 * 1000000 + (CR06_ROWS / 2) * 10 ))
  log "  [$db] 删除范围 time <= $del_t（第 1 批的中部：期望删掉该批 $(( CR06_ROWS / 2 )) 行）"
  # ---- 基线（探针口径 + cmp_* 口径分开记，避免混用）----
  cr06_probe_all "$db"; ts0p=$P_T; start0p=$P_S; fin0p=$P_F
  fin0=$(cmp_inner_finish "$db"); ts0=$(cmp_all_sum "$db")
  pre_total=$(row_sum "$(sq "select count(s1) from $db.**;")")
  if [ "$dialect" = table ]; then
    pre_total=$(cr06_rows_table "select v from $db.$TBT;")
    pre_del=$(cr06_rows_table "select v from $db.$TBT where time <= $del_t;")
    surv0=$(cr06_rows_table "select v from $db.$TBT where time > $del_t;")
    fp0=$(cmp_fingerprint table "select v from $db.$TBT where dev='$DEV' and time > $del_t order by time;")
  else
    pre_del=$(cr06_rows_tree "select s1 from $db.$DEV where time <= $del_t order by time;")
    surv0=$(cr06_rows_tree "select s1 from $db.$DEV where time > $del_t order by time;")
    fp0=$(cmp_fingerprint tree "select s1 from $db.$DEV where time > $del_t order by time")
  fi
  log "  [$db] 基线：文件数=$ts0（探针 $ts0p）starts=$start0p finishes=$fin0p mods2=$P_M 总行数=$pre_total 被删集=$pre_del 存活集=$surv0"
  [ "${pre_del:-0}" -gt 0 ] && pass "  [$db] 场景有效性：被删集确实有 $pre_del 行（删除会真实覆盖源文件数据）" \
    || fail "  [$db] 场景无效：被删集 0 行（DELETE 范围没落在被合并源文件上，并发语义无从体现）"
  [ "$(cmp_min_l0 "$db")" -ge 2 ] && pass "  [$db] 场景有效性：各副本 level-0 TsFile 最小 $(cmp_min_l0 "$db")（≥2，有合并候选）" \
    || fail "  [$db] 场景无效：min_l0=$(cmp_min_l0 "$db")（<2，造不出合并）"
  # ---- 热开合并 + 注入窗口 ----
  cmp_compaction_on true true false
  inj=0; evid="（未探测）"; try=1
  while [ "$try" -le "$CR06_INJ_TRY" ]; do
    dl=$(( $(date +%s) + CR06_INJ_WIN ))
    while (( $(date +%s) < dl )); do
      cr06_probe_all "$db"
      evid="try=$try s=$P_S(基线$start0p) f=$P_F(基线$fin0p) tsfile=$P_T(基线$ts0p) mods2=$P_M"
      log "  [$db 注入时机] $evid"
      if [ "${P_S:-0}" -gt "${start0p:-0}" ] && [ "${P_T:-0}" -ge "${ts0p:-0}" ]; then inj=1; break; fi
      [ "${P_F:-0}" -gt "${fin0p:-0}" ] && break          # 本轮任务已提交 ⇒ 换一轮候选
      sleep 0.5
    done
    [ "$inj" = 1 ] && break
    warn "  [$db] 第 $try 次未抓住「合并进行中」窗口（$evid）"
    [ "$try" -ge "$CR06_INJ_TRY" ] && break
    try=$(( try + 1 ))
    log "  [$db] 补写 1 批候选后重试注入"
    if [ "$dialect" = table ]; then cr06_write_table "$db" "$TBT" "$(( CR06_BATCHES + try ))"; else cr06_write_tree "$db" "$(( CR06_BATCHES + try ))"; fi
    CR06_ADDED=$(( CR06_ADDED + 1 ))
    pre_total=$(row_sum "$(sq "select count(s1) from $db.**;")")
    [ "$dialect" = table ] && pre_total=$(cr06_rows_table "select v from $db.$TBT;")
    if [ "$dialect" = table ]; then
      pre_del=$(cr06_rows_table "select v from $db.$TBT where time <= $del_t;")
      surv0=$(cr06_rows_table "select v from $db.$TBT where time > $del_t;")
      fp0=$(cmp_fingerprint table "select v from $db.$TBT where dev='$DEV' and time > $del_t order by time;")
    else
      pre_del=$(cr06_rows_tree "select s1 from $db.$DEV where time <= $del_t order by time;")
      surv0=$(cr06_rows_tree "select s1 from $db.$DEV where time > $del_t order by time;")
      fp0=$(cmp_fingerprint tree "select s1 from $db.$DEV where time > $del_t order by time")
    fi
    cr06_probe_all "$db"; ts0p=$P_T; start0p=$P_S; fin0p=$P_F
    ts0=$(cmp_all_sum "$db"); fin0=$(cmp_inner_finish "$db")
  done
  [ "$inj" = 1 ] && pass "  [$db] 场景有效性：注入时机成立（task starts 已出现 **且** TsFile 数尚未下降）[$evid]" \
    || warn "  [$db] 场景未成立（时序，**不可稳定构造**）：${CR06_INJ_WIN}s×${CR06_INJ_TRY} 次内未抓到「合并进行中」（$evid）。本环境合并窗口（~10s）与一次「3 节点并行 ssh 探测」往返同量级 ⇒ 抓窗口靠运气。⇒ 本相**并发时序类判据**（合并双信号/同节点时钟证据）跳过并如实记录，**删除类数据面判据照常硬判**（下面照样发 DELETE）"
  # ---- 下发 DELETE ----
  #   ⚠️ RC8 首轮这里写成 `sq "$delsql"`，而 `delsql` **从未定义** ⇒ set -u 直接报
  #      `line 263: delsql: unbound variable`，命令替换拿到空串 ⇒ **DELETE 根本没发出去**，
  #      于是后面「被删范围行数」「被删行不得复活」「总行数」三条硬判全部假 FAIL（两个相共 6~7 条）。
  #      现在按方言显式生成 SQL（树必须带 `.**`，否则删的是不存在的路径）。
  if [ "$dialect" = table ]; then
    delsql="delete from $db.$TBT where time <= $del_t;"
  else
    delsql="delete from $db.$DEV.** where time <= $del_t;"
  fi
  log "  [$db] 下发 DELETE（注入时机 inj=$inj）：$delsql"
  # 【RC8 第二轮修正（2026-10-20）】表模型必须用**表方言**执行：原来一律 `sq "$delsql"`
  #   走到表库时树解析器直接报 `700: … line 1:12 mismatched input cr06t expecting ROOT`
  #   ⇒ DELETE 根本没下发，随后「被删范围行数 / 被删行不得复活 / 总行数 / 合并推进」全部假 FAIL（f5）。
  if [ "$dialect" = table ]; then delr=$(sqt "$delsql" 2>&1); else delr=$(sq "$delsql" 2>&1); fi
  printf '%s\n' "$delr" | sed 's/^/    delete→ /' >>"$OUT"
  printf '%s' "$delr" | grep -qiE 'IoTDBSQLException|Exception|error' \
    && fail "  [$db] DELETE 报错：$(printf '%s' "$delr" | tr '\n' ' ' | cut -c1-200)"
  if [ "$inj" = 1 ]; then
    cr06_probe_all "$db"
    ts_afd=$P_T; m_afd=$P_M; s_afd=$P_S; f_afd=$P_F
    log "  [$db] 删除返回后立刻探测：tsfile=$ts_afd（注入前 $ts0p）mods2=$m_afd starts=$s_afd finishes=$f_afd"
    [ "${ts_afd:-0}" -ge "${ts0p:-0}" ] && pass "  [$db] 场景有效性：DELETE 返回时合并仍未提交（文件数 $ts_afd ≥ $ts0p）" \
      || warn "  [$db] DELETE 返回时文件数已下降（$ts0p → $ts_afd）：合并可能在 DELETE 之前就已提交（最终以同节点时钟证据为准）"
    [ "${m_afd:-0}" -gt 0 ] && pass "  [$db] 场景有效性：删除已落到 .mods2（$m_afd 个，源文件被删标记覆盖）" \
      || warn "  [$db] 删除后未见 .mods2（$m_afd）：可能已被合并清理，也可能是删除走了整文件删除路径（记录）"
  fi
  # ---- 等合并收敛（双信号；仅在确实抓到「合并进行中」时才是本相判据）----
  if res=$(cmp_wait_merge "$db" "$fin0" "$ts0" "$CR06_WIN"); then
    [ "$inj" = 1 ] && pass "  [$db] 合并已推进：$res" || log "  [$db] 合并已推进：$res（时序未命中，不作判据）"
  else
    if [ "$inj" = 1 ]; then fail "  [$db] 合并未在 ${CR06_WIN}s 内推进（$res）"
    else warn "  [$db] 合并未在 ${CR06_WIN}s 内推进（$res）——本相没抓到「合并进行中」，基线取自合并已完成的时刻 ⇒ 属场景时序问题，只记录"; fi
  fi
  fin1=$(cmp_inner_finish "$db"); ts1=$(cmp_all_sum "$db")
  log "  [$db] 收敛后：finishes $fin0 → $fin1；TsFile $ts0 → $ts1"
  if [ "$inj" = 1 ]; then
    [ "${fin1:-0}" -gt "${fin0:-0}" ] && pass "  [$db] 双信号①：InnerSpaceCompaction 完成记录 +$(( fin1 - fin0 ))" || fail "  [$db] 双信号①：无新的合并完成记录"
    [ "${ts1:-0}" -lt "${ts0:-0}" ] && pass "  [$db] 双信号②：TsFile 数下降（$ts0 → $ts1）" || fail "  [$db] 双信号②：TsFile 数未下降（$ts0）"
  else
    log "  [$db] 双信号（finishes $fin0→$fin1、TsFile $ts0→$ts1）不作判据：本相没抓到「合并进行中」"
  fi
  # ---- 权威并发证据（同节点时钟）：**只记录 + WARN**（依赖时序，属"不可稳定构造"）----
  infl=$(cr06_inflight "$db" "$delpat")
  printf '%s\n' "$infl" | sed 's/^/    /' >>"$OUT"
  infl_n=$(cr06_inflight_nodes "$infl")
  if [ "$inj" = 1 ] && [ "${infl_n:-0}" -ge 1 ]; then
    pass "  [$db] 场景有效性（权威）：$infl_n 个节点上「DELETE 时间戳落在合并任务 starts/finishes 之间」"
  else
    warn "  [$db] 同节点时钟证据未命中（inj=$inj，命中节点数=${infl_n:-0}；原始证据见 $ART/inflight_${db}.txt）⇒ 该组「权威并发证据」降级为记录，**不判 FAIL**；本相的删除数据面判据仍然硬判"
  fi
  # ---- 数据正确性（硬判；场景是否成立都必须成立）----
  local got_del got_surv got_total got_fp
  if [ "$dialect" = table ]; then
    cr06_wait_rows_table "select v from $db.$TBT where time <= $del_t;" "0" 120 "  [$db] 被删范围行数" || true
    got_del=$(cr06_rows_table "select v from $db.$TBT where time <= $del_t;")
    got_surv=$(cr06_rows_table "select v from $db.$TBT where time > $del_t;")
    got_total=$(cr06_rows_table "select v from $db.$TBT;")
    got_fp=$(cmp_fingerprint table "select v from $db.$TBT where dev='$DEV' and time > $del_t order by time;")
  else
    cr06_wait_rows_tree "select s1 from $db.$DEV where time <= $del_t order by time;" "0" 120 "  [$db] 被删范围行数" || true
    got_del=$(cr06_rows_tree "select s1 from $db.$DEV where time <= $del_t order by time;")
    got_surv=$(cr06_rows_tree "select s1 from $db.$DEV where time > $del_t order by time;")
    got_total=$(row_sum "$(sq "select count(s1) from $db.**;")")
    got_fp=$(cmp_fingerprint tree "select s1 from $db.$DEV where time > $del_t order by time")
  fi
  log "  [$db] 合并后：被删集=$got_del 存活集=$got_surv 总行数=$got_total（删除前 $pre_total − 被删 $pre_del）"
  assert_eq "  [$db] 被删行不得复活（time <= $del_t 的行数）" "${got_del:-?}" "0"
  assert_eq "  [$db] 未删数据不得丢失（存活集行数）" "${got_surv:-?}" "${surv0:-?}"
  cmp_assert_same "  [$db] 存活集（time > $del_t）删除前后指纹" "$fp0" "$got_fp"
  assert_eq "  [$db] 总行数 = 删除前 − 被删行数" "${got_total:-?}" "$(( pre_total - pre_del ))"
  local orph
  orph=$(cr06_orphan_sum "$db")
  [ "${orph:-0}" -eq 0 ] && pass "  [$db] 无孤儿 .mods2（引用它的 tsfile 都还在）" \
    || warn "  [$db] 有 $orph 个孤儿 .mods2（合并清理有窗口，记录待人工确认）"
  log "  [$db] .mods2 合计=$(cr06_mods_sum "$db")（合并提交后源文件连同其 mods2 被删 ⇒ 0 属正常，不作硬判据）"
  # 供第二轮使用：返回本轮 TsFile 名清单（判「目标再被合并」）
  cmp_names "$db"; }

# ===========================================================================
log "--- 相 A：树模型 $DBT（DELETE 覆盖第 1 批中部）---"
sq "create database $DBT;" >/dev/null
sq "create timeseries $DBT.$DEV.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null
sq "create timeseries $DBT.$DEV.s2 with datatype=TEXT, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
for b in $(seq 1 "$CR06_BATCHES"); do
  cr06_write_tree "$DBT" "$b"
  cmp_wait_close "$DBT" "$b" 120 >/dev/null || warn "  [$DBT] 批$b 的 close 事件未达 $b"
done
NAMES_A0=$(cmp_names "$DBT")
cr06_phase "$DBT" tree "pathPattern=root.cr06a"
NAMES_A1=$(cmp_names "$DBT")

# ===========================================================================
log "--- 相 B：表模型 $DBB.$TBT ---"
cmp_compaction_off                      # 上一相已热开合并；本相写入期必须先关（否则写入期间就被并掉）
sqt "create database $DBB;" >/dev/null
OUTB=$(sqt "create table $DBB.$TBT (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD);")
printf '%s' "$OUTB" | grep -q 'successfully' && pass "  建表成功：$DBB.$TBT" || fail "  场景无效：建表 $DBB.$TBT 失败"
for b in $(seq 1 "$CR06_BATCHES"); do
  cr06_write_table "$DBB" "$TBT" "$b"
  cmp_wait_close "$DBB" "$b" 120 >/dev/null || warn "  [$DBB] 批$b 的 close 事件未达 $b"
done
NAMES_B0=$(cmp_names "$DBB")
cr06_phase "$DBB" table "tableName='tb'"
NAMES_B1=$(cmp_names "$DBB")

# ---------------------------------------------------------------------------
# 相 C（目标再被合并）：把相 B 的合并产物当源文件再并一轮
#   R-25 的极端时序：合并目标在删除写入前又被删除/再被合并。
#   做法：先把相 B 产物记为待消失集合；再**热改 `max_level_gap_in_inner_compaction=1`**
#   （允许跨层级合并，CO-17 实测 gap=0 时 [L1,L0] 不会并、gap=1 才会），写入 2 批严格递增
#   （落 sequence/ ⇒ 新 L0），热开合并后断言：相 B 产物文件从文件集合消失（确被再次吃掉）、
#   被删范围仍为空、**相 C 之前的存活集指纹不变**（不得丢失未删数据）。
# ---------------------------------------------------------------------------
log "--- 相 C：目标再被合并（$DBB.$TBT 第一轮产物作为源文件）---"
DEL_T=$(( BASE + 1 * 1000000 + (CR06_ROWS / 2) * 10 ))
C_MAX=$(( BASE + 9 * 1000000 ))          # 相 C 新写批（b=10/11）之前的水位：指纹比较用它把新行排除掉
cmp_compaction_off                       # 写入期先关合并
cmp_set_hot max_level_gap_in_inner_compaction 1 >/dev/null 2>&1 || true
log "  max_level_gap_in_inner_compaction 生效值=$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction)（跨层级合并所需）"
FP_PRE_C=$(cmp_fingerprint table "select v from $DBB.$TBT where dev='$DEV' and time > $DEL_T and time < $C_MAX order by time;")
ROWS_PRE_C=$(cr06_rows_table "select v from $DBB.$TBT where time > $DEL_T and time < $C_MAX;")
# 相 B 的产物 = 相 B 结束时的文件集合（新写入的 L0 不在其中 ⇒ 该集合里的文件被并掉才算"目标再被合并"）
PROD_B=$(printf '%s\n' "$NAMES_B1" | tr ' ' '\n' | grep -E '\.tsfile$' | sort)
log "  相 B 结束时的文件集合（$DBB）：$(printf '%s' "$PROD_B" | tr '\n' ' ')"
for b in 10 11; do
  cr06_write_table "$DBB" "$TBT" "$b"
  cmp_wait_close "$DBB" "$b" 120 >/dev/null || warn "  [$DBB] 相C 批$b 的 close 事件未达 $b"
done
FIN_PRE_C=$(cmp_inner_finish "$DBB"); TS_PRE_C=$(cmp_all_sum "$DBB")
log "  相 C 写入后：文件数=$TS_PRE_C finishes=$FIN_PRE_C 布局=$(cmp_lay "$DBB")"
cmp_compaction_on true true false
if res_c=$(cmp_wait_merge "$DBB" "$FIN_PRE_C" "$TS_PRE_C" "$CR06_WIN"); then pass "  相 C 合并已推进：$res_c"; else warn "  相 C 合并未推进（$res_c，记录；场景未成立不计连带 FAIL）"; fi
sleep 15
NAMES_B2=$(cmp_names "$DBB")
GONE=0
while IFS= read -r n; do
  [ -n "$n" ] || continue
  printf '%s\n' "$NAMES_B2" | grep -qF "$n" || GONE=$(( GONE + 1 ))
done <<<"$PROD_B"
log "  相 C 后文件集合（$DBB）：$(printf '%s' "$NAMES_B2" | tr '\n' ' ')"
DEL_C=$(cr06_rows_table "select v from $DBB.$TBT where time <= $DEL_T;")
assert_eq "  相 C 后：被删行仍不得复活" "${DEL_C:-?}" "0"
if [ "${GONE:-0}" -ge 1 ]; then
  pass "  相 C「目标再被合并」成立：$GONE 个相 B 产物文件已被再次合并（从文件集合消失）"
  cmp_assert_same "  相 C 存活集（$DEL_T < time < $C_MAX）指纹" "$FP_PRE_C" "$(cmp_fingerprint table "select v from $DBB.$TBT where dev='$DEV' and time > $DEL_T and time < $C_MAX order by time;")"
  assert_eq "  相 C 存活集行数" "$(cr06_rows_table "select v from $DBB.$TBT where time > $DEL_T and time < $C_MAX;")" "$ROWS_PRE_C"
else
  warn "  相 C「目标再被合并」未构造出来（相 B 产物一个都没消失）⇒ 该组判据跳过（不计连带 FAIL；属构造/时序问题）"
fi

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死（TsFileResource.writeLock）"
log "  相 A 文件集合变化：$(printf '%s' "$NAMES_A0" | tr '\n' ' ') → $(printf '%s' "$NAMES_A1" | tr '\n' ' ')"
log "  注入重试补写批数：$CR06_ADDED"

log "--- 收尾三件套（以树模型存活集为一致性基准）---"
post_checks "select s1 from $DBT.$DEV where time > $(( BASE + 1 * 1000000 + (CR06_ROWS / 2) * 10 )) order by time;" tree
cmp_case_finish "" tree ""
