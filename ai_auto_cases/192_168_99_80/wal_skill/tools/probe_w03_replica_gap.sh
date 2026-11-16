#!/bin/bash
# ============================================================================
# probe_w03_replica_gap.sh —— W-03「停一个 DN 后读数少一个批次」决定性探针（v2）
#
# v1 的教训：造数依赖 cmp_write_tree_batch 的 DEVS 语义，实际每批只写进 1 个设备
#   （可见 100/200/300 而不是 300/600/900）⇒ 基准只有 300，"NOT_REPRO" 无效。
# v2 改为**自包含显式写入**：自己建库建序列、自己按 设备×行 生成 INSERT，不再依赖外部函数。
#
# 判据：
#   baseline = 三副本全在线时，**逐 DN 直连** count
#   stop .78 → 经 .77、.79 各测 3 次（间隔 5s）
#   · 任一 < baseline ⇒ REPRO（记录差值；若为每批行数的整数倍 ⇒ 与 W-03 同源）
#   · 恢复 .78 → 三副本复测，判断是"滞后可见"还是"真丢"
#
# 用法：V_TESTDB=<版本> BUILD_TAG=<commit> bash tools/probe_w03_replica_gap.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
. "$SKILL/lib/common.sh"
. "$SKILL/lib/cmp.sh"
. "$SKILL/lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "probe_w03_replica_gap_${DATA_CONSENSUS}"

DB=root.w03gap
P_DEVS=${W03_DEVS:-3}
P_ROWS=${W03_ROWS:-100}
P_BATCHES=${W03_BATCHES:-3}
P_BATCH=$(( P_DEVS * P_ROWS ))
P_TARGET=$(( P_BATCH * P_BATCHES ))
VICTIM=${W03_VICTIM:-192.168.99.78}
P_ROUNDS=${W03_ROUNDS:-3}
REPRO=0; TOTAL_DELTA=0

# 注意：树模型下 `count(s1) from db.**` 是**每序列一行**（多设备多行），必须把行里的数字全部累加，
# 不能 `tail -1`（v2 首次运行就栽在这里：3 设备各 100 行只取到最后一行 = 100）。
qcount(){ local h=$1; query_result "$h" tree "select count(s1) from $DB.**;" 2>/dev/null | awk '/^\|/{n=split($0,a,/[^0-9]+/); for(i=1;i<=n;i++) s+=a[i]} END{print s+0}'; }
qcount_qdn(){ query_result "$QDN" tree "select count(s1) from $DB.**;" 2>/dev/null | awk '/^\|/{n=split($0,a,/[^0-9]+/); for(i=1;i<=n;i++) s+=a[i]} END{print s+0}'; }
allcnt(){ local h out=""; for h in "${DN[@]}"; do out="$out$h=$(qcount "$h") "; done; printf '%s' "$out"; }

# ---------------------------------------------------------------------------
_pre=$(sq 'show cluster;' 2>&1)
if ! printf '%s' "$_pre" | grep -q 'DataNode'; then
  log "!! 集群未就绪 ⇒ cmp_cluster_prepare 起一套干净集群"
  cmp_cluster_prepare || { log "集群准备失败，终止"; exit 2; }
else
  log "前置检查：集群已在线"
fi

# ---------------------------------------------------------------------------
# 1) 自包含造数：DEVS 个设备 × ROWS 行 × BATCHES 批，批间时间戳不重叠
# ---------------------------------------------------------------------------
log "=== 1) 建库 ${DB}，写 ${P_BATCHES} 批（每批 ${P_DEVS} 设备 × ${P_ROWS} 行 = ${P_BATCH}，共 ${P_TARGET}）==="
out=$(sq "create database $DB;")
d=1
while [ "$d" -le "$P_DEVS" ]; do
  out=$(sq "create timeseries $DB.d$d.s1 with datatype=INT64;")
  printf '%s' "$out" | grep -qiE 'successfully|already' || { log "建序列 d$d 失败：$out"; exit 2; }
  d=$(( d + 1 ))
done

BASE_MS=$(( ($(date +%s) - 3600) * 1000 ))
b=1
while [ "$b" -le "$P_BATCHES" ]; do
  d=1
  while [ "$d" -le "$P_DEVS" ]; do
    vals=""; k=0
    while [ "$k" -lt "$P_ROWS" ]; do
      ts=$(( BASE_MS + b * 1000000 + k * 10 ))
      vals="$vals($ts,$(( k + b ))),"
      k=$(( k + 1 ))
    done
    out=$(sq "insert into $DB.d$d(time,s1) values ${vals%,};")
    printf '%s' "$out" | grep -qi 'successfully' || { log "第 $b 批 d$d 写入失败：$out"; exit 2; }
    d=$(( d + 1 ))
  done
  sq "flush;" >/dev/null 2>&1
  log "  第 $b 批写完（每批 ${P_BATCH} 行），当前经 ${QDN} 可见=$(qcount_qdn)"
  b=$(( b + 1 ))
done

# 等三副本都补齐
_got=0
_t0=$(date +%s)
while [ "$(( $(date +%s) - _t0 ))" -lt "${WAL_REPLAY_WIN_SEC:-120}" ]; do
  _got=$(allcnt); _n=0
  for h in "${DN[@]}"; do
    c=$(qcount "$h"); [ "${c:-0}" -ge "$P_TARGET" ] && _n=$(( _n + 1 ))
  done
  [ "$_n" -ge "${#DN[@]}" ] && break
  sleep 5
done
check_sync_lag || true
log "=== 2) 基准（三副本全在线，逐 DN 直连）: $(allcnt) ==="
BASE_SUM=$(qcount_qdn)
log "  经 ${QDN} 聚合查询 = $BASE_SUM（每批 ${P_BATCH} 行）"
if [ "${BASE_SUM:-0}" -lt "$P_TARGET" ]; then
  log "!! 场景不成立：可见 ${BASE_SUM} < 目标 ${P_TARGET} ⇒ 本探针结论无效"
  exit 2
fi

# ---------------------------------------------------------------------------
r=1
while [ "$r" -le "$P_ROUNDS" ]; do
  log "=== 3.${r}) 第 ${r} 轮：stop ${VICTIM} ==="
  sshx "$VICTIM" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true; pkill -f 'com\\.timecho\\.iotdb\\.DataNode' >/dev/null 2>&1 || true" || true
  wait_dn_state "$VICTIM" notrunning "${DN_DOWN_WAIT_SEC:-120}" || log "  警告：停 $VICTIM 后集群仍显示 Running"
  for on in "${DN[@]}"; do
    [ "$on" = "$VICTIM" ] && continue
    k=1
    while [ "$k" -le 3 ]; do
      c=$(qcount "$on"); d=$(( BASE_SUM - ${c:-0} ))
      log "    经 $on 第 ${k} 次查询 = ${c:-?}（基准 ${BASE_SUM}，差 ${d}）"
      [ "${d:-0}" -gt 0 ] && { REPRO=$(( REPRO + 1 )); TOTAL_DELTA=$(( TOTAL_DELTA + d )); }
      sleep 5
      k=$(( k + 1 ))
    done
  done
  log "  恢复 ${VICTIM}"
  sshx "$VICTIM" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}.log 2>&1 </dev/null &" || true
  wait_dn_state "$VICTIM" running "${DN_RECOVER_WAIT_SEC:-180}" || log "  警告：$VICTIM 未恢复 Running"
  sleep 10
  log "  恢复后：$(allcnt)（经 ${QDN}=$(qcount_qdn)）"
  r=$(( r + 1 ))
done

log "=== 4) 结论 ==="
log "  基准=${BASE_SUM}（每批 ${P_BATCH} 行）；异常读数次数=${REPRO}；累计差值=${TOTAL_DELTA}"
if [ "$REPRO" -gt 0 ]; then
  log "  ⇒ **REPRO**：停副本后其余副本读数低于基准（累计差 ${TOTAL_DELTA} 行）"
  fail "PROBE_REPRO：停副本后读数低于基准（${REPRO} 次，累计差 ${TOTAL_DELTA} 行；每批 ${P_BATCH}）"
else
  log "  ⇒ **NOT_REPRO**：三轮共 ${P_ROUNDS} 次停副本，其余副本读数始终等于基准"
fi
cmp_case_finish "" tree ""
