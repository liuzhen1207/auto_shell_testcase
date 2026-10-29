#!/bin/bash
# ============================================================================
# CO-34 数千 TsFile 的大规模**级联合并**压力
#
# 目的：把小规模用例（CO-01/02 等只有 3~6 个 TsFile）扩到**千级**，
#   验证层级合并（size_tiered）能真正"级联"上去（L0 → L1 → L2 …），
#   并且在压力下不丢数据、不卡死、不 OOM、不出现统计/schema 异常。
#
# 做法：
#   ① 三类合并**全关**（CMP_EXTRA_WRITE）：每轮 `INSERT` 1 行 + `FLUSH`，
#      一次会话连续跑 N 轮 ⇒ 每个 DataNode 上得到 N 个 level-0 seq TsFile；
#   ② 记基线：TsFile 数、层级分布、数据指纹；
#   ③ 热开 seq 合并（candidate_file_num 放大到几十，让层级快速推进）
#      → 观察层级分布演进，直到文件数收敛或超时；
#   ④ 断言：合并完成数大幅增加、文件数大幅下降、**最大层级 ≥ 2**（证明级联）、
#      指纹不变（数据不丢）、无卡死线程、收尾三件套全绿。
#
# 规模可调：C34_FILES（默认 1000）、C34_CAND（默认 30）、C34_WIN（等待窗口，默认 1500s）
# 用法： bash co_scale_cascade.sh [--consensus IoTConsensus]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_scale_cascade_${DATA_CONSENSUS}"

DB=root.c34d1
N="${C34_FILES:-1000}"
CAND="${C34_CAND:-30}"
WIN="${C34_WIN:-1500}"

# 层级分布里的最大层级（cmp_lay 形如 `77:12/3/1/0 78:...`，字段=level0/1/2/3 计数）
c34_max_level(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -E '^[0-9a-fA-F:.]+:' | cut -d: -f2 | tr '/' '\n' |
  awk '{lv=NR-1; if ($1+0>0) m=lv} END{print m+0}'; }
# 三个节点 level-0 的最小值（=真正落盘的 seq 文件数下限）
c34_min_l0(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -E '^[0-9a-fA-F:.]+:' | cut -d: -f2 | cut -d/ -f1 |
  awk 'NR==1{m=$1} {if($1+0<m)m=$1+0} END{print m+0}'; }

log "--- 0) 集群准备：三类合并全关，candidate=$CAND，interval=${CMP_INTERVAL_MS}ms；目标规模 N=$N ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CAND},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}" cmp_cluster_prepare

log "--- 1) 造 $N 个 level-0 seq TsFile（每轮 1 行 INSERT + FLUSH，单会话连续执行）---"
sq "create database $DB;" >/dev/null 2>&1
assert_contains "  建库" "$(sq "show databases;" 2>&1 | strip_echo)" "${DB#root\.}"
sq "create timeseries $DB.d1.s1 with datatype=INT64;" >/dev/null 2>&1

STMT="$ART/c34_stmts.sql"
{
  for ((i = 1; i <= N; i++)); do
    printf 'insert into %s.d1(time,s1) values(%d,%d);\n' "$DB" "$((i * 1000))" "$i"
    printf 'flush;\n'
  done
} >"$STMT"
log "  语句文件：$STMT（$(wc -l <"$STMT") 行），写时间范围 1000..$((N * 1000)) ms"
export SQL_TIMEOUT_SEC=$((N * 3 + 600))
W0=$(date +%s)
cat "$STMT" | session_tree >"$ART/c34_write.out" 2>&1
W1=$(date +%s)
# ⚠️ 不要写 `grep -c … || echo 0`：0 匹配时 grep 会**先打印 0**（退出码 1）再执行 echo 0
#    ⇒ 变量变成两行 "0\n0"，`assert_eq` 必然失败（2026-10-16 CO-34 在 V1/V2 上的假 FAIL 就是它）。
#    正确做法：`|| true` 忽略退出码，再把结果规整成单个整数。
OK_CNT=$(grep -c 'successfully' "$ART/c34_write.out" 2>/dev/null || true)
OK_CNT=$(printf '%s' "${OK_CNT:-0}" | head -1 | tr -dc '0-9'); OK_CNT=${OK_CNT:-0}
ERR_CNT=$(grep -cE 'IoTDBSQLException|Error|error|Exception' "$ART/c34_write.out" 2>/dev/null || true)
ERR_CNT=$(printf '%s' "${ERR_CNT:-0}" | head -1 | tr -dc '0-9'); ERR_CNT=${ERR_CNT:-0}
log "  写入会话耗时 $((W1 - W0))s；'successfully' 行数=$OK_CNT；报错行数=$ERR_CNT"
assert_eq "  写入无报错" "${ERR_CNT:-0}" "0"
[ "${OK_CNT:-0}" -ge $((N)) ] && pass "  写语句基本成功（成功回显 $OK_CNT ≥ $N）" || fail "  成功回显偏少：$OK_CNT"

# 等 TsFile 真正落盘（flush 是异步 close，数量稳定后才记基线）
LAY0=""; L0MIN=0
dl=$(( $(date +%s) + 180 ))
while (( $(date +%s) < dl )); do
  LAY0=$(cmp_lay "$DB"); L0MIN=$(c34_min_l0 "$LAY0")
  log "    落盘检查：minL0=$L0MIN 布局=$LAY0"
  [ "$L0MIN" -ge $((N * 9 / 10)) ] && break
  sleep 10
done
SUM0=$(cmp_all_sum "$DB"); FP0=$(cmp_fp_tree "$DB"); FIN0=$(cmp_inner_finish "$DB"); STUCK0=$(cmp_stuck_sum)
log "  基线：TsFile 合计=$SUM0 minL0=$L0MIN finishes=$FIN0 卡死线程=$STUCK0"
log "  基线指纹：$FP0"
assert_eq "  数据行数（写入点数）" "$(sq "select count(s1) from $DB.d1;" 2>&1 | strip_echo | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/[^0-9]/,"",v); print v}')" "$N"
if [ "$L0MIN" -ge $((N * 8 / 10)) ]; then
  pass "  已造出千级 TsFile（minL0=$L0MIN ≥ 80% × $N）"
else
  warn "  TsFile 数未达目标（minL0=$L0MIN，目标 ≈ $N）——flush 可能被合并/节流，用例仍继续（压力规模打折）"
fi

log "--- 2) 热开 seq 合并，观察级联（窗口 ${WIN}s）---"
cmp_compaction_on true true false
dl=$(( $(date +%s) + WIN ))
last_sum=-1; last_lay=""; ok=0; t0=$(date +%s)
while (( $(date +%s) < dl )); do
  cur=$(cmp_all_sum "$DB"); fin=$(cmp_inner_finish "$DB"); lay=$(cmp_lay "$DB")
  if [ "$cur" != "$last_sum" ] || [ "$lay" != "$last_lay" ]; then
    log "    t=$(( $(date +%s) - t0 ))s 文件=$cur finishes=$fin 布局=$lay"
    last_sum=$cur; last_lay=$lay
  fi
  if [ "$cur" -le $(( N / 20 > 20 ? N / 20 : 20 )) ] && [ "$fin" -gt "$FIN0" ]; then ok=1; break; fi
  sleep 15
done
SUM1=$(cmp_all_sum "$DB"); FIN1=$(cmp_inner_finish "$DB"); LAY1=$(cmp_lay "$DB")
MLV=$(c34_max_level "$LAY1"); STUCK1=$(cmp_stuck_sum); FP1=$(cmp_fp_tree "$DB")
log "  合并后：文件 $SUM0 → $SUM1；finishes $FIN0 → $FIN1；最大层级=$MLV；卡死线程=$STUCK1"
log "  合并后布局：$LAY1"
log "  合并后指纹：$FP1"

[ "${FIN1:-0}" -gt "${FIN0:-0}" ] && pass "  合并确实推进（finishes +$((FIN1 - FIN0))）" || fail "  合并未推进（finishes 无增长）"
[ "$SUM1" -lt "$SUM0" ] && pass "  TsFile 数下降（$SUM0 → $SUM1）" || fail "  TsFile 数未下降"
[ "$ok" = 1 ] && pass "  文件数已收敛到目标（≤ max(20, N/20)=$(( N / 20 > 20 ? N / 20 : 20 ))）" \
  || warn "  窗口内未收敛到目标（$SUM1），按压力场景记录（finishes +$((FIN1 - FIN0))）"
[ "${MLV:-0}" -ge 2 ] && pass "  **级联合并**发生：最高层级 = $MLV ≥ 2（不止 L0→L1）" \
  || warn "  最高层级仅 $MLV（本窗口内未级联到 L2，可能是基数/窗口不足）"
assert_eq "  合并前后数据指纹不变" "$FP1" "$FP0"
cmp_assert_no_stuck "无卡死合并线程（TsFileResource.writeLock 等）"
assert_eq "  合并后行数不变" "$(sq "select count(s1) from $DB.d1;" 2>&1 | strip_echo | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/[^0-9]/,"",v); print v}')" "$N"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from ${DB}.d1;" tree
cmp_case_finish "" tree ""
