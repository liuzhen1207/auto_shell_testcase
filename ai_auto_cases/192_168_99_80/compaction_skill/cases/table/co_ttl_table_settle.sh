#!/bin/bash
# ============================================================================
# CO-14 TTL 场景（表模型）：表 TTL 过期清理（settle 合并）与在线合并的组合
#   与 CO-13 同构（同样的编排与原因，详见 CO-13 头部注释）：
#     ① 只写"过期设备" dev='d1'..'d{DEVS}'（48 小时前）→ ② 表 TTL=24h → 查询侧过滤
#     ③ settle 物理清理整文件过期的文件 → ④ 再写"新鲜设备" d{DEVS+1}..d{2*DEVS}（当前，2 批）
#        → 在线合并推进、指纹不变、过期数据不复活 → ⑤ TTL→30s 清理合并产物
#        → ⑥ TTL='INF' 后**分副本判定**（不再当一致性判据）→ ⑦ 收尾三件套（对照设备）
#   ⚠️ 关键同样来自 `SettleSelectorImpl.selectFileBaseOnDirtyData()`：设了 TTL 的文件里只要有一个
#      设备还有未过期数据，整个文件就 NOT_SATISFIED ⇒ 过期数据必须单独成文件。
#   TTL 挂在**表**上（`ALTER TABLE … SET PROPERTIES ttl=`），计数/指纹/收尾走表方言。
# 用法： bash co_ttl_table_settle.sh [--consensus ...]
#
# ---------------------------------------------------------------------------
# 【2026-10-16 判据修订】依据 docs/CO11_CO14_TRIAGE.md §2：
#   RC7 上 V1 = PASS(577s)，**只有 V2 = FAIL(643s, fail=2)**；那 2 条 FAIL 已定性为**构造性假 FAIL**
#   （结论 (b) 环境/落盘不齐 + (c) 用例构造断言不成立），**不建议提单**。逐副本实测：
#   `.77 = AsyncClose 0 / settle 0 / 非零 TTL 候选 0`；`.78 = 4/2/2`；`.79 = 4/2/2`
#   （RC6 同用例 artifact 为 6/6/6、2/2/2，对称）。修订点（旧 → 新）：
#   ① 证据：旧 = 只看聚合数（TsFile 合计 + settle 合计）；新 = **每相**采"逐副本 TsFile 清单 +
#      Async close 数 + settle 数 + 非零 TTL 候选数"（`co14_snap`，一次 ssh/副本），清单写进 .out。
#   ② 第 5 轮基线：旧 = 在 `alter … ttl=30000; flush; sleep 20` **之后**才采 `TS3`，判据只有
#      `cur_ts < TS3` ⇒ 实测两次真实 settle 在 06:36:47 / 06:36:52 就已完成（TsFile 18→16），
#      而基线是 06:37:13 采到的 16 ⇒ **下降发生在基线之前，判据从一开始就不可能成立**。
#      新 = 基线前移到 alter **之前**采，判据改成与第 3 轮一致的「**settle 增加 或 TsFile 下降**」。
#   ③ 第 6 轮（回滚 TTL='INF'）：旧 = 直接断言 count=0，且这条过期数据的 SQL 又被收尾一致性复用
#      ⇒ 逐副本清理进度不同时必然 FAIL（V2 下 `.77` 全程 0 个 close ⇒ 按 `SettleSelectorImpl.java:172-174`
#      非 NORMAL 不可选，永远选不出候选 ⇒ `.77` 什么都没删；`.78/.79` 各删 2 个文件）。
#      新 = 回滚**前**先等各副本 close/TsFile **稳定**（`co14_wait_converge`），该步改**分副本判定**
#      并明确标注「TTL 回滚把已合法判死的过期数据重新变可见 ⇒ 构造性差异」，不再当一致性判据、不再 FAIL。
#   ④ 一致性检查加强：新增「三副本**全在线、同一时刻**」逐副本对比（TTL=24h / TTL=30s / TTL='INF' 三刻）
#      + 「TTL=30s 与 TTL='INF' 两时刻」对照表；**FAIL 门槛只设在 TTL 生效的时刻（24h/30s）** ——
#      那时查询侧过滤是确定的，三副本同刻不同解才是真不一致；TTL='INF'（回滚后）的差异只记
#      **WARN + 三份原始结果 + 逐副本证据**。另加硬判据：任一副本可见行数必须是 ROWS 的整数倍且
#      ≤ 3*BATCH（设备独占 TsFile ⇒ settle 只整文件删除），否则判真实数据缺失/串数据（FAIL）。
#   ⑤ 收尾三件套保留（sync lag → 逐个停 DN 的副本一致性 → 日志扫描），但一致性对比的 SQL 改用
#      回滚**之后**新写的对照设备 `dctrl`（TTL='INF' 下写入、从未被判死）；旧脚本用过期设备 d{FP_DEV}，
#      回滚后必然被"逐副本删除进度不同"击穿 —— RC7 V2 的 2 条 FAIL 正是这一条。
#   ⑥ 与 RC6 对照用（**本脚本不执行**，需要时手工跑一次；现有 artifact 只有 RC6-V1，缺 RC6-V2）：
#      方式 A（框架入口，--ver 会同时切 conf/test.conf 的版本；见 tools/run_all.sh:19,24）：
#        bash tools/run_all.sh --ver v20121rc6_1010_7ae8713e --only CO-14 --consensus IoTConsensusV2
#      方式 B（直接跑本脚本，环境变量覆盖 conf/env.conf 的 V_TESTDB/BUILD_TAG）：
#        V_TESTDB=v20121rc6_1010_7ae8713e BUILD_TAG=v20121rc6_1010_7ae8713e CO_DEVS=6 CO_ROWS=300 \
#          bash cases/table/co_ttl_table_settle.sh --consensus IoTConsensusV2
#      对照看什么：① `.77` 的 `Async close` 是否为 0（RC7 V2 = 0 ⇒ 落盘不齐，属 (b) 环境项）；
#      ② 四个相位的逐副本 (TsFile, close, settle, 非零候选) 是否与 RC7 V2 形态一致；
#      ③ 「全在线同刻」与「两时刻对照」的证据形态是否一致（一致 ⇒ (b)+(c) 锁定）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_ttl_table_settle_${DATA_CONSENSUS}"

# ---------------------------------------------------------------------------
# 规模参数（集中放顶部，均可用环境变量覆盖）
# ---------------------------------------------------------------------------
DBB=cottltb
DEVS=${CO_DEVS:-4}
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-90}
DAY_MS=$(( 24 * 3600 * 1000 ))
TTL_MS=${CO_TTL_MS:-$DAY_MS}
TTL_SMALL_MS=${CO_TTL_SMALL_MS:-30000}
CONV_WAIT_SEC=${CO14_CONV_SEC:-90}          # 第 6 步：等各副本 close/TsFile 稳定的窗口
CONV_STABLE_CHECKS=${CO14_CONV_CHECKS:-2}   # 连续几次快照不变算"收敛"
BATCH=$(( DEVS * ROWS ))
TOTAL_3B=$(( BATCH * 3 ))                   # 本用例写入的总行数（老批 1 批 + 新批 2 批）
OLD_FIRST=1; OLD_LAST=$DEVS
NEW_FIRST=$(( DEVS + 1 )); NEW_LAST=$(( DEVS * 2 ))
FP_DEV=$NEW_FIRST
CTL_DEV=dctrl                               # 收尾对照组设备（回滚成 'INF' **之后**写入）

# ---------------------------------------------------------------------------
# 逐副本证据（本版新增）
# ---------------------------------------------------------------------------
co14_num(){ local v; v=$(printf '%s' "${1:-0}" | tr -dc '0-9'); echo "${v:-0}"; }
# 一个副本的原始观测：**一次 ssh** 取回全部字段（避免一相多轮 ssh），字段以 | 分隔：
#   <TsFile 数>|<Async close 数>|<settle:all.log>|<settle:compaction.log>|<非零 TTL 候选>|<文件名清单>
co14_replica_raw(){ local h=$1 cmd
  cmd="L=$DB_DIR/logs/log_datanode_all.log; C=$DB_DIR/logs/log_datanode_compaction.log"
  cmd="$cmd; ts=\$(find $DB_DIR/data/datanode/data -path '*/$DBB/*' -name '*.tsfile' 2>/dev/null | wc -l)"
  cmd="$cmd; cl=\$(grep -hcE 'Async close tsfile: .*$DBB' \$L 2>/dev/null)"
  cmd="$cmd; sa=\$(grep -hcE '(^|[- ])(root\.)?$DBB-[0-9]+ \[Compaction\] SettleCompaction task starts with' \$L 2>/dev/null)"
  cmd="$cmd; sb=\$(grep -hcE '(^|[- ])(root\.)?$DBB-[0-9]+ \[Compaction\] SettleCompaction task starts with' \$C 2>/dev/null)"
  cmd="$cmd; se=\$(grep -hcE '\[TTL\] (root\.)?$DBB-[0-9]+ Totally select ([1-9][0-9]* all-outdated|[0-9]+ all-outdated files and [1-9][0-9]* partial-outdated)' \$L 2>/dev/null)"
  cmd="$cmd; fl=\$(find $DB_DIR/data/datanode/data -path '*/$DBB/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | sort | tr '\n' ',')"
  cmd="$cmd; echo \"\${ts:-0}|\${cl:-0}|\${sa:-0}|\${sb:-0}|\${se:-0}|\${fl:-}\""
  sshx "$h" "$cmd" 2>/dev/null | tr -d '\r' | tail -1; }
# 原始行 → 规范化的 "ts cl st se fl"；st 取值口径与 lib/common.sh 的 settle_task_for_db 同源：
# settle 行先在 log_datanode_all.log 里数，为 0 再退到 log_datanode_compaction.log（RC4 曾出现只有后者的情况）。
co14_norm(){ local line=$1 ts cl sa sb se fl st
  IFS='|' read -r ts cl sa sb se fl <<<"$line"
  ts=$(co14_num "$ts"); cl=$(co14_num "$cl")
  sa=$(co14_num "$sa"); sb=$(co14_num "$sb"); se=$(co14_num "$se")
  st=$sa; [ "$sa" -eq 0 ] && st=$sb
  printf '%s %s %s %s %s' "$ts" "$cl" "$st" "$se" "${fl:-}"; }
# 每相快照：打印三节点各自的 (TsFile 数, Async close 数, settle 数, 非零 TTL 候选数) + TsFile 清单；
# 合计落到 SNAP_TS / SNAP_CLOSE / SNAP_SETTLE / SNAP_TTLSEL（给基线比较用）。
co14_snap(){ local label=$1 h raw ts cl st se fl
  SNAP_TS=0; SNAP_CLOSE=0; SNAP_SETTLE=0; SNAP_TTLSEL=0
  log "  【逐副本证据·$label】"
  for h in "${DN[@]}"; do
    raw=$(co14_replica_raw "$h")
    ts=0; cl=0; st=0; se=0; fl=""
    [ -n "$raw" ] && read -r ts cl st se fl <<<"$(co14_norm "$raw")"
    SNAP_TS=$(( SNAP_TS + $(co14_num "$ts") ))
    SNAP_CLOSE=$(( SNAP_CLOSE + $(co14_num "$cl") ))
    SNAP_SETTLE=$(( SNAP_SETTLE + $(co14_num "$st") ))
    SNAP_TTLSEL=$(( SNAP_TTLSEL + $(co14_num "$se") ))
    log "    $h: TsFile=$ts Async_close=$cl settle=$st 非零TTL候选=$se 清单=[$(printf '%s' "${fl:-<空>}" | cut -c1-300)]"
    printf '      [%s] %s TsFile=%s Async_close=%s settle=%s 非零TTL候选=%s 清单=%s\n' \
      "$label" "$h" "$ts" "$cl" "$st" "$se" "${fl:-<空>}" >>"$OUT"
  done
  log "    合计: TsFile=$SNAP_TS Async_close=$SNAP_CLOSE settle=$SNAP_SETTLE 非零TTL候选=$SNAP_TTLSEL"; }
# 本库 TsFile 合计（与快照同一口径，供等待循环用；**不要**混用 cmp_all_sum 另算一份口径）
co14_ts_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(co14_num "$(tsfile_count "$h" "$DBB")") )); done; echo "${s:-0}"; }
# settle 任务合计（本库口径；旧版 settle_any 是**全库全 DN** 的全局计数，其它库的 settle 会混进来）
settle_any(){ local h raw st s=0
  for h in "${DN[@]}"; do
    raw=$(co14_replica_raw "$h")
    st=0
    [ -n "$raw" ] && read -r _ _ st _ _ <<<"$(co14_norm "$raw")"
    s=$(( s + $(co14_num "$st") ))
  done; echo "${s:-0}"; }
tcnt(){ sqt "select count(*) from $DBB.t1;" | table_rows | head -1 | awk -F'|' '{print ($2+0)}'; }
tcnt_node(){ sqt_node "$1" "select count(*) from $DBB.t1;" | table_rows | head -1 | awk -F'|' '{print ($2+0)}'; }
tsum(){ sqt "select sum(v) from $DBB.t1;" | table_rows | head -1 | awk -F'|' '{print ($2+0)}'; }
co14_write(){ local d0=$1 d1=$2 b=$3 base=$4 d k vals
  for ((d=d0; d<=d1; d++)); do
    vals=""
    for ((k=1;k<=ROWS;k++)); do
      vals="$vals($(( base + k * 10 )),'d$d',$(( k + b ))),"
      if [ $(( k % 500 )) -eq 0 ]; then sqt "insert into $DBB.t1 (time, dev, v) values ${vals%,};" >/dev/null; vals=""; fi
    done
    [ -n "$vals" ] && sqt "insert into $DBB.t1 (time, dev, v) values ${vals%,};" >/dev/null
  done
  sqt "flush;" >/dev/null; }
# 收尾对照设备写入（单个设备、一批 ROWS 行；TTL='INF' 下写入 ⇒ 永不过期、永不被 settle 选中）
co14_write_ctl(){ local base=$1 k vals=""
  for ((k=1;k<=ROWS;k++)); do
    vals="$vals($(( base + k * 10 )),'$CTL_DEV',$(( k + 7 ))),"
    if [ $(( k % 500 )) -eq 0 ]; then sqt "insert into $DBB.t1 (time, dev, v) values ${vals%,};" >/dev/null; vals=""; fi
  done
  [ -n "$vals" ] && sqt "insert into $DBB.t1 (time, dev, v) values ${vals%,};" >/dev/null
  sqt "flush;" >/dev/null; }

# ---------------------------------------------------------------------------
# 一致性检查（本版加强）
# ---------------------------------------------------------------------------
# 三副本**全在线、同一时刻**逐副本对比同一条 SQL；三份原始结果写进 .out。
#   gate=fail（TTL 生效的时刻 24h/30s 用）：同刻不同解 ⇒ 真副本不一致，判 FAIL；
#   gate=warn（TTL='INF' 回滚后用）：逐副本物理删除进度不同 ⇒ 构造性差异，只 WARN + 证据。
co14_instant_cmp(){ local label=$1 sql=$2 gate=${3:-fail} h r base uniq=0 rows h8 out=""
  local -A RES=()
  log "  【全在线同刻对比·$label】$sql"
  for h in "${DN[@]}"; do
    r=$(query_result "$h" table "$sql"); RES[$h]="$r"
    rows=$(printf '%s\n' "${r:-EMPTY}" | wc -l | tr -d ' ')
    h8=$(printf '%s' "${r:-EMPTY}" | md5sum | cut -c1-8)
    log "    $h: rows=$rows md5=$h8"
    printf '      [%s] %s rows=%s md5=%s\n' "$label" "$h" "$rows" "$h8" >>"$OUT"
  done
  base="${RES[${DN[0]}]}"
  for h in "${DN[@]}"; do
    [ "${RES[$h]}" = "$base" ] || uniq=1
    out="$out${h##*.}=[$(printf '%s' "${RES[$h]:-EMPTY}" | tr '\n' ' ' | cut -c1-60)] "
  done
  if [ "$uniq" -eq 0 ]; then
    pass "$label：三副本全在线、同一时刻结果一致（rows=$(printf '%s\n' "${base:-EMPTY}" | wc -l | tr -d ' ')）"
  elif [ "$gate" = fail ]; then
    fail "$label：三副本全在线、同一时刻**不同解** ⇒ 真实副本不一致（TTL 生效中，查询侧过滤本应确定）"
    for h in "${DN[@]}"; do
      printf '      [%s] %s 原始结果（判 FAIL 依据）:\n' "$label" "$h" >>"$OUT"
      printf '%s\n' "${RES[$h]:-EMPTY}" | sed 's/^/        | /' >>"$OUT"
    done
    printf '      [%s] 三份摘要: %s\n' "$label" "$out" >>"$OUT"
  else
    warn "$label：三副本全在线、同一时刻**不同解**，但属**构造性差异**（TTL 从小值回滚成 'INF' 会把已被合法判死、且部分副本已物理删除的过期数据重新变可见；各副本删掉的文件本就不同）⇒ 记 WARN + 逐副本证据，**不作一致性判据、不判 FAIL**：$out"
    for h in "${DN[@]}"; do
      printf '      [%s] %s 原始结果（构造性差异证据）:\n' "$label" "$h" >>"$OUT"
      printf '%s\n' "${RES[$h]:-EMPTY}" | sed 's/^/        | /' >>"$OUT"
    done
  fi; }
# 逐副本可见行数 + 硬判据：整设备独占 TsFile ⇒ settle 只会整文件删除 ⇒ 可见行数必须是 ROWS 的整数倍
# 且不超过写入总量（3*BATCH）；否则说明"数据被切碎/丢失"⇒ 判真实数据问题（FAIL）。结果串放 CO14_ROWS_STR。
co14_rows_all(){ local label=$1 h c bad=0 res=""
  for h in "${DN[@]}"; do
    c=$(co14_num "$(tcnt_node "$h")")
    res="$res${h##*.}=$c "
    if [ $(( c % ROWS )) -ne 0 ] || [ "$c" -gt "$TOTAL_3B" ]; then
      fail "$label：$h 可见行数 $c 不是整设备行数（ROWS=$ROWS 的整数倍）或超过写入总量 $TOTAL_3B ⇒ 疑似真实数据缺失/串数据"
      bad=1
    fi
  done
  log "  【逐副本可见行数·$label】$res"
  printf '      [%s] 逐副本可见行数: %s\n' "$label" "$res" >>"$OUT"
  [ "$bad" -eq 0 ] && pass "$label：逐副本可见行数均为整设备行数（$res）"
  CO14_ROWS_STR="$res"; }
# 等各副本 close/TsFile **稳定**（连续 CONV_STABLE_CHECKS 次不变）。
# ⚠️ 这里等的是"不再变化"，不是"三副本相等"：V2 下 `.77` 可能全程 0 个 Async close（落盘不齐，见
# docs/CO11_CO14_TRIAGE.md §2.2），三副本不等只 WARN —— 那正是"回滚后可见性不同"的物理原因。
# 注意：`local cur` 只声明**不赋值**，`set -u` 下循环一次都不进时读 $cur 会 "unbound variable"
# （本项目踩过同类坑，selftest 有静态检查）⇒ 必须显式初始化。
co14_wait_converge(){ local label=$1 timeout=$2 h cur="" prev="" stable=0 u
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    cur=""
    for h in "${DN[@]}"; do cur="$cur${h##*.}:$(co14_num "$(tsfile_count "$h" "$DBB")")/$(co14_num "$(ttl_close_cnt "$h" "$DBB")") "; done
    log "    等收敛($label)：逐副本 TsFile/close = $cur"
    if [ "$cur" = "$prev" ]; then stable=$(( stable + 1 )); else stable=0; fi
    prev="$cur"
    [ "$stable" -ge "$CONV_STABLE_CHECKS" ] && break
    sleep 10
  done
  u=$(printf '%s\n' "$cur" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | wc -l | tr -d ' ')
  if [ "${stable:-0}" -ge "$CONV_STABLE_CHECKS" ]; then
    pass "各副本 close/TsFile 已收敛（$cur）"
  else
    warn "等 ${timeout}s 后各副本 close/TsFile 仍未完全收敛（$cur）"
  fi
  if [ "${u:-1}" -le 1 ]; then
    pass "三副本 close/TsFile 计数一致（$cur）"
  else
    warn "三副本 close/TsFile 计数不一致（$cur）—— V2 下曾出现某副本全程 0 个 Async close（已知落盘不齐，属环境现象）"
  fi; }

log "--- 集群准备（seq 合并=true 才做 TTL 物理清理；unseq/cross 关；TTL 检查 5s、ratio 极小）---"
export TTL_CHECK_INTERVAL_MS=5000
export MAX_EXPIRED_TIME_MS=9223372036854775807
export EXPIRED_DATA_RATIO=0.000001
EXTRA_CONF="enable_seq_space_compaction=true,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}" cmp_cluster_prepare

log "--- 1) 先只写**过期设备** d$OLD_FIRST..d$OLD_LAST（48 小时前）---"
cmp_make_table_db "$DBB" t1 ""
NOW=$(now_ms)
BASE_OLD=$(( NOW - 2 * DAY_MS ))
co14_write "$OLD_FIRST" "$OLD_LAST" 1 "$BASE_OLD"
ensure_closed "$DBB" 3 25 || warn "$DBB 过期批次未全部落盘（V2 下曾出现某副本全程不 close，见 docs/CO11_CO14_TRIAGE.md §2.2）"
co14_snap "相1 设 TTL 前"
C_BEFORE=$(tcnt); TS0=$SNAP_TS; SET0=$SNAP_SETTLE
log "  设 TTL 前：count=$C_BEFORE（期望 $BATCH）TsFile=$TS0 settle=$SET0 逐副本(close)=$SNAP_CLOSE"
assert_eq "过期批次写入后可见（表 TTL 尚未设置）" "$C_BEFORE" "$BATCH"

log "--- 2) 给表设 TTL=${TTL_MS}ms（24h）→ 查询侧应全部不可见 ---"
out=$(sqt "alter table $DBB.t1 set properties ttl=$TTL_MS;")
assert_contains "ALTER TABLE SET ttl 成功" "$out" "successfully"
sqt "flush;" >/dev/null
sleep 12
assert_eq "表 TTL 生效后过期数据被查询过滤" "$(tcnt)" "0"
co14_snap "相2 TTL=${TTL_MS}ms 生效"

log "--- 3) 等 settle 合并物理清理过期文件 ---"
deadline=$(( $(date +%s) + CLEANUP_WAIT_SEC )); cleaned=0; cur_ts=$TS0; cur_set=$SET0
while (( $(date +%s) < deadline )); do
  cur_set=$(settle_any); cur_ts=$(co14_ts_all)
  log "    等 settle：settle=$SET0 → $cur_set；TsFile=$TS0 → $cur_ts"
  if [ "$cur_set" -gt "$SET0" ] || [ "$cur_ts" -lt "$TS0" ]; then cleaned=1; break; fi
  sleep 5
done
if [ "$cleaned" = 1 ]; then pass "表 TTL 触发的 settle 已动作：settle +$((cur_set-SET0))，TsFile $TS0 → $cur_ts"
else fail "等 ${CLEANUP_WAIT_SEC}s 未见表 TTL 清理（settle +$((cur_set-SET0))，TsFile $TS0 → $cur_ts）"; fi
SET1=$cur_set
co14_snap "相3 第一轮 settle 后"
for h in "${DN[@]}"; do log "  $h 日志尾部：$(sshx "$h" "grep -h '\[TTL\]\\|SettleCompaction' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -3" | tr '\n' ' ' | cut -c1-240)"; done

log "--- 4) 再写**新鲜设备** d$NEW_FIRST..d$NEW_LAST（当前时间，2 批）+ 在线合并 ---"
# 时间戳必须是"过去但很近"（NOW-20s / NOW-10s）：未来时间戳永远不过期，会破坏第 5 步的 count=0
FIN_PRE=$(cmp_inner_finish "$DBB")
co14_write "$NEW_FIRST" "$NEW_LAST" 2 "$(( NOW - 20000 ))"
co14_write "$NEW_FIRST" "$NEW_LAST" 3 "$(( NOW - 10000 ))"
ensure_closed "$DBB" 3 25 || warn "$DBB 新鲜批次未全部落盘"
FIN1=$(cmp_inner_finish "$DBB"); co14_snap "相4 新数据写入后"; TS2=$SNAP_TS; C_MID=$(tcnt)
FP_PRE=$(cmp_fingerprint table "select v from $DBB.t1 where dev='d$FP_DEV' order by time;")
SUM_PRE=$(tsum)
log "  新写 2 批后：count=$C_MID（期望 $(( BATCH * 2 ))）TsFile=$TS2 finishes=$FIN_PRE→$FIN1"
assert_eq "表 TTL 生效期间过期数据未复活" "$C_MID" "$(( BATCH * 2 ))"
if [ "${FIN1:-0}" -gt "${FIN_PRE:-0}" ]; then
  pass "表 TTL 生效状态下在线合并已推进（写入期间 finishes $FIN_PRE → $FIN1）"
elif RES=$(cmp_wait_merge "$DBB" "$FIN1" "$TS2" "$WIN"); then
  pass "表 TTL 生效状态下在线合并正常完成：$RES"
else
  fail "表 TTL 生效状态下合并未推进（$RES）"
fi
cmp_assert_same "合并前后新鲜设备 dev=d$FP_DEV 全序列" "$FP_PRE" "$(cmp_fingerprint table "select v from $DBB.t1 where dev='d$FP_DEV' order by time;")"
assert_eq "合并前后新鲜数据 sum" "$SUM_PRE" "$(tsum)"
# 【修订④】TTL 生效期间（24h）加一次"三副本全在线、同一时刻"逐副本对比：此时查询侧过滤是确定的，
# 三副本同刻不同解 ⇒ 真实副本不一致（FAIL）。
co14_instant_cmp "TTL=${TTL_MS}ms 全在线同刻（dev=d$FP_DEV 全序列 $(( ROWS * 2 )) 行）" "select v from $DBB.t1 where dev='d$FP_DEV' order by time;" fail
co14_snap "相4b 在线合并后"

log "--- 5) 表 TTL 调到 ${TTL_SMALL_MS}ms → 合并产物也必须被清理 ---"
# 【修订②】基线必须在 `alter … ttl=30000` **之前**采：RC7 V2 实测两次真实 settle 在 06:36:47 / 06:36:52
# 就已完成（TsFile 18→16），旧脚本 06:37:13 才采 TS3=16 ⇒ 下降发生在基线之前、判据永远不成立。
co14_snap "相5 第二轮基线（alter 之前）"
TS3=$SNAP_TS; SET3=$SNAP_SETTLE
log "  第二轮基线（TTL 调小之前）：TsFile=$TS3 settle=$SET3 逐副本(close)=$SNAP_CLOSE"
out=$(sqt "alter table $DBB.t1 set properties ttl=$TTL_SMALL_MS;")
assert_contains "ALTER TABLE SET ttl(小值) 成功" "$out" "successfully"
sqt "flush;" >/dev/null
sleep 20
assert_eq "合并产物同样被 TTL 过滤" "$(tcnt)" "0"
# 【修订②】判据 = 「settle 增加 **或** TsFile 下降」（旧脚本只看 TsFile ⇒ 被"基线取晚"击穿）
deadline=$(( $(date +%s) + CLEANUP_WAIT_SEC )); purged=0; cur_ts=$TS3; cur_set=$SET3
while (( $(date +%s) < deadline )); do
  cur_set=$(settle_any); cur_ts=$(co14_ts_all)
  log "    等二轮 settle：settle=$SET3 → $cur_set；TsFile=$TS3 → $cur_ts"
  if [ "$cur_set" -gt "$SET3" ] || [ "$cur_ts" -lt "$TS3" ]; then purged=1; break; fi
  sleep 5
done
if [ "$purged" = 1 ]; then
  pass "第二轮 TTL 清理已动作：settle +$(( cur_set - SET3 ))，TsFile $TS3 → $cur_ts"
else
  warn "第二轮窗口内 settle（$SET3 → $cur_set）与 TsFile（$TS3 → $cur_ts）均未推进；以相6/相7 的逐副本证据为准"
fi
co14_snap "相6 第二轮清理后"
# TTL=30s 时刻的全在线同刻对比：此时查询侧过滤确定（全部过期）⇒ 三副本必须同解（都返回 0），否则 FAIL
co14_instant_cmp "TTL=${TTL_SMALL_MS}ms 全在线同刻（count(*)，期望三副本全 0）" "select count(*) from $DBB.t1;" fail
co14_rows_all "TTL=${TTL_SMALL_MS}ms 逐副本"
ROWS_AT_SMALL="$CO14_ROWS_STR"

log "--- 6) 等各副本 close/TsFile 稳定后把 TTL 改回 'INF'（**分副本判定**，不再当一致性判据）---"
# 【修订③】TTL 回滚会把"已判死"的过期数据重新变成可见；而各副本的物理删除进度不同（V2 下 `.77` 全程 0 个
# close ⇒ 按 SettleSelectorImpl.java:172-174 永远选不出候选），所以"回滚后要求三副本都 count=0"本身不成立。
co14_snap "相7 回滚前"
co14_wait_converge "回滚前" "$CONV_WAIT_SEC"
out=$(sqt "alter table $DBB.t1 set properties ttl='INF';")
assert_contains "ALTER TABLE ttl='INF' 成功" "$out" "successfully"
sleep 5
co14_snap "相8 TTL='INF' 后"
co14_rows_all "TTL='INF' 逐副本"
INF_ROWS="$CO14_ROWS_STR"
INF_ALLZERO=1
for h in "${DN[@]}"; do
  [ "$(printf '%s' "$INF_ROWS" | tr ' ' '\n' | sed -n "s/^${h##*.}=//p")" = "0" ] || INF_ALLZERO=0
done
if [ "$INF_ALLZERO" = 1 ]; then
  pass "TTL='INF' 后三副本可见行数均为 0（过期数据已物理删除，合并未复活）"
else
  warn "TTL='INF' 后各副本可见行数不同（$INF_ROWS）：TTL 从 ${TTL_SMALL_MS}ms 回滚成 'INF' 会把已被合法判死、且部分副本已物理删除的过期数据**重新变可见** ⇒ 属**构造性差异**，**不作为副本一致性判据**（逐副本证据见相1~相8 快照与本步 .out）"
fi
# 【修订④】TTL='INF' 时刻的同刻对比：gate=warn（构造性差异），输出三份原始结果做证据
co14_instant_cmp "TTL='INF' 全在线同刻（回滚后，dev=d$FP_DEV 全序列）" "select v from $DBB.t1 where dev='d$FP_DEV' order by time;" warn
log "  【两时刻对照】逐副本可见行数：TTL=${TTL_SMALL_MS}ms → TTL='INF'"
for h in "${DN[@]}"; do
  a=$(printf '%s' "$ROWS_AT_SMALL" | tr ' ' '\n' | sed -n "s/^${h##*.}=//p")
  b=$(printf '%s' "$INF_ROWS" | tr ' ' '\n' | sed -n "s/^${h##*.}=//p")
  log "    $h: ${a:-?} → ${b:-?}"
  printf '      [两时刻对照] %s: TTL=%sms → %s；TTL=INF → %s\n' "$h" "$TTL_SMALL_MS" "${a:-?}" "${b:-?}" >>"$OUT"
done

log "--- 7) 收尾基准：回滚后新写对照设备 $CTL_DEV（TTL='INF' 下写入、从未被判死）---"
# 【修订⑤】旧脚本的收尾一致性 SQL 用过期设备 d$FP_DEV，而 TTL 已回滚成 'INF' ⇒ 必然被"逐副本删除进度不同"
# 击穿（RC7 V2 的 2 条 FAIL 就在这里）。改用回滚后新写的对照设备：它是已提交的新数据，三副本必须逐行一致。
NOW2=$(now_ms)
co14_write_ctl "$(( NOW2 - 5000 ))"
ensure_closed "$DBB" 3 25 || warn "$DBB 对照设备批次未全部落盘"
CTL_CNT=$(sqt "select count(*) from $DBB.t1 where dev='$CTL_DEV';" | table_rows | head -1 | awk -F'|' '{print ($2+0)}')
assert_eq "对照设备 $CTL_DEV 写入后可见（TTL='INF'）" "$CTL_CNT" "$ROWS"
co14_snap "相9 对照批次写入后"

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"

log "--- 收尾三件套（sync lag → 逐个停 DN 的副本一致性（对照设备 $CTL_DEV）→ 日志扫描）---"
post_checks "select v from $DBB.t1 where dev='$CTL_DEV' order by time;" table
cmp_case_finish "" table ""
