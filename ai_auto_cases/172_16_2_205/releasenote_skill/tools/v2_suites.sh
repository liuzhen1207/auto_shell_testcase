#!/bin/bash
# 在当前 IoTConsensusV2 集群上跑三段回归（不再切协议）
NEW=${1:-v20131rc2_1110_83183d0}
TS=$(date +%Y%m%d_%H%M%S)
OUT=/data2/auto_test/v2_results_$TS
MAIN=/tmp/v2_suites_$TS.log
mkdir -p "$OUT"
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
T() { timeout 40 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }
Q() { timeout 40 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "$1" 2>&1; }
log() { echo "[$(date +%T)] $*" | tee -a "$MAIN"; }

# 启动前确保没有残留测试进程（避免两套并发互杀节点）
pkill -9 -f 'tools/suite.sh' 2>/dev/null
pkill -9 -f 'tools/suite_rn.sh' 2>/dev/null
pkill -9 -f 'tools/run_regression.sh' 2>/dev/null
sleep 2
left=$(ps -eo args | grep -E 'tools/suite\.sh|tools/suite_rn\.sh|tools/run_regression\.sh' | grep -v grep | wc -l)
if [ "$left" != "0" ]; then echo "仍有 $left 个残留测试进程，退出"; exit 9; fi

log "===== V2 回归开始 $TS，输出=$OUT ====="
log "协议：$(Q 'show variables' 2>/dev/null | grep -i DataRegionConsensusProtocolClass | sed 's/.*|//;s/|//')"
log "集群：$(T 'show cluster;' 2>/dev/null | grep -c Running)/8"

# 清理残留测试库
for db in $(Q "show databases" 2>/dev/null | awk -F'|' 'NF>2 && $2 !~ /Database|information_schema/ {gsub(/ /,"",$2); print $2}'); do
  Q "DROP DATABASE IF EXISTS $db" >/dev/null 2>&1
  T "DROP DATABASE $db" >/dev/null 2>&1
done
log "清理后数据库：$(Q 'show databases' 2>/dev/null | awk -F'|' 'NF>2 && $2 !~ /Database/ {gsub(/ /,"",$2); printf "%s ", $2}')"

run_one() {
  local name=$1 dir=$2 cmd=$3 t0 t1 rc
  log "===== START $name ====="
  t0=$(date +%s)
  ( cd "$dir" && NEW="$NEW" timeout 14400 bash -c "$cmd" > "$OUT/$name.log" 2>&1 )
  rc=$?
  t1=$(date +%s)
  log "===== DONE $name rc=$rc dur=$((t1 - t0))s ====="
  tail -6 "$OUT/$name.log" | tee -a "$MAIN"
  mkdir -p "$OUT/$name-results"; cp -a "$dir"/results/. "$OUT/$name-results"/ 2>/dev/null
}

run_one tree_view /data2/auto_test/treeview_suite "bash tools/suite.sh"
run_one releasenote /data2/auto_test/releasenote_skill "bash tools/suite_rn.sh"
run_one auth /data2/auto_test/auth_skill "bash tools/run_regression.sh"

log "===== 汇总 ====="
for n in tree_view releasenote auth; do
  f=$OUT/$n.log
  [ -f "$f" ] || continue
  log "$n: PASS=$(grep -c -- '-> PASS' "$f") FAIL=$(grep -c -- '-> FAIL' "$f") KNOWN=$(grep -c -- '-> KNOWN' "$f") SKIP=$(grep -c -- '-> SKIP' "$f")"
done
log "终态：$(T 'show cluster;' 2>/dev/null | grep -c Running)/8；协议：$(Q 'show variables' 2>/dev/null | grep -i DataRegionConsensusProtocolClass | head -1)"
log "完成，输出=$OUT"
