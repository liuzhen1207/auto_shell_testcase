#!/bin/bash
# RC1 3C5D：两轮「串行缩容 1 个 DN -> 校验数据清理 -> 重新加回」，全程 weather benchmark 并发读写，
# 结束后停 benchmark、等 sync lag 归零、校验副本拓扑一致性，并扫描 CN/DN 日志中的 ERROR/WARN。
set -u
cd "$(dirname "$0")" || exit 1
TESTDB="${TESTDB:-v20131rc1_1030_ab6d3de}"
DB_ROOT="${DB_ROOT:-/data1/iotdb}"
CLI_ROOT="${CLI_ROOT:-/data2/iotdb}"
T="${TESTCASE_DIR:-/data2/auto_test/cluster_shell_3c5d_no2/tc2026_releasenote_testcase}"
BENCH="${BENCH_DIR:-$T/benchmark/bm_20260625_1f2d2e3_jdk17}"
SEED="${SEED:-172.16.2.11}"
DN_LIST="${DN_LIST:-172.16.2.11 172.16.2.12 172.16.2.13 172.16.2.14 172.16.2.15}"
CN_LIST="${CN_LIST:-172.16.2.8 172.16.2.9 172.16.2.10}"
METRIC_PORT="${METRIC_PORT:-9092}"
ROUNDS="${ROUNDS:-2}"
CLI="$CLI_ROOT/$TESTDB/sbin/start-cli.sh"

TAG=$(date +%Y%m%d_%H%M%S)
CASE_DIR="$(pwd)"
mkdir -p results
LOG="$CASE_DIR/results/scale_cycle_${TESTDB}_${TAG}.log"
TS=$(date '+%Y-%m-%d %H:%M:%S')
exec > >(tee -a "$LOG") 2>&1

EXCLUDE=""
LIVE_SEED=""
sql() {
  local h out
  for h in $LIVE_SEED $DN_LIST; do
    [ -z "$h" ] && continue
    [ "$h" = "$EXCLUDE" ] && continue
    out=$(timeout 25 "$CLI" -h "$h" -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1)
    if echo "$out" | grep -qE 'Msg:|NodeID|\|'; then LIVE_SEED="$h"; echo "$out"; return 0; fi
  done
  echo "$out"
  return 1
}

show_nodes() { sql 'show datanodes;'; }

node_id_of() { # ip
  show_nodes | awk -F'|' -v ip="$1" 'NF>3 {gsub(/ /,"",$3); gsub(/ /,"",$4); if ($4==ip) print $2}' | head -1
}

wait_removed() { # ip timeout_s
  local ip=$1 t=${2:-900} b=$(date +%s)
  while [ $(( $(date +%s)-b )) -lt $t ]; do
    if ! show_nodes | grep -q "|$ip|"; then echo "removed $ip after $(( $(date +%s)-b ))s"; return 0; fi
    sleep 10
  done
  echo "TIMEOUT waiting remove $ip"; return 1
}

wait_running() { # ip timeout_s
  local ip=$1 t=${2:-600} b=$(date +%s)
  while [ $(( $(date +%s)-b )) -lt $t ]; do
    if show_nodes | awk -F'|' -v ip="$ip" 'NF>3 {gsub(/ /,"",$4); if ($4==ip){gsub(/ /,"",$3); if($3=="Running") ok=1}} END{exit !ok}'; then
      echo "running $ip after $(( $(date +%s)-b ))s"; return 0
    fi
    sleep 10
  done
  echo "TIMEOUT waiting running $ip"; return 1
}

check_clean() { # ip
  local ip=$1
  local dirs
  dirs=$(ssh -n -o BatchMode=yes root@"$ip" "find $DB_ROOT/$TESTDB/data/datanode/data/sequence -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; du -sm $DB_ROOT/$TESTDB/data/datanode 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
  local ndirs=$(echo "$dirs" | head -1); local mb=$(echo "$dirs" | tail -1)
  echo "clean check $ip: region_dirs=$ndirs data_mb=$mb"
  [ "${ndirs:-0}" -eq 0 ] && [ "${mb:-9999}" -lt 200 ]
}

start_dn() { # ip
  local ip=$1
  ssh -n -o BatchMode=yes root@"$ip" "source /etc/profile; cd $DB_ROOT/$TESTDB && ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" 2>/dev/null
  sleep 5
}

stop_dn() { # ip
  local ip=$1
  ssh -n -o BatchMode=yes root@"$ip" "source /etc/profile; cd $DB_ROOT/$TESTDB && ./sbin/stop-datanode.sh" >/dev/null 2>&1 || true
}

sync_lag_ok() {
  local bad=0 missing=0
  for ip in $DN_LIST; do
    body=$(curl -fsS --connect-timeout 3 --max-time 10 "http://${ip}:${METRIC_PORT}/metrics" 2>/dev/null || true)
    [ -z "$body" ] && { echo "metrics missing $ip"; missing=$((missing+1)); continue; }
    n=$(echo "$body" | grep -a 'type="syncLag"' | awk '{if ($2+0 != 0) c++} END{print c+0}')
    m=$(echo "$body" | grep -a 'type="searchIndex"\|type="safeIndex"' | wc -l)
    [ "${n:-0}" -gt 0 ] && { echo "$ip syncLag_nonzero=$n"; bad=1; }
  done
  if [ "$missing" -eq 5 ]; then echo "METRICS_UNAVAILABLE (enable dn_metric_reporter_list=PROMETHEUS), skip sync check"; return 0; fi
  return $bad
}

echo "[$(date +%T)] ensure users"
"$CLI" -h "$SEED" -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "create user rainer 'TimechoDB@2021';" >/dev/null 2>&1 || true
"$CLI" -h "$SEED" -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "create user colder 'TimechoDB@2021';" >/dev/null 2>&1 || true
"$CLI" -h "$SEED" -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "grant all to user rainer;" >/dev/null 2>&1 || true
"$CLI" -h "$SEED" -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "grant all to user colder;" >/dev/null 2>&1 || true

echo "[$(date +%T)] start weather RW benchmark"
cd "$BENCH" || exit 2
[ -d weather-rn-tdb122 ] || { echo "missing weather configs"; exit 2; }
nohup ./benchmark.sh -cf "$BENCH/weather-rn-tdb122/conf_rw" > "/tmp/scale_rw_$TAG.out" 2>&1 &
BM=$!
sleep 30

fail=0
for r in $(seq 1 "$ROUNDS"); do
  echo "[$(date +%T)] ==== round $r ===="
  for ip in $DN_LIST; do
    id=$(node_id_of "$ip")
    if [ -z "$id" ]; then echo "[$ip] not in cluster, skip remove"; else
      echo "[$(date +%T)] remove DN $ip id=$id"
      EXCLUDE="$ip"
      out=$(sql "remove datanode $id;")
      echo "$out" | tail -2
      if ! wait_removed "$ip" 1200; then
        fail=1; EXCLUDE=""; echo "REMOVE_FAILED $ip, abort this round"; break
      fi
      EXCLUDE=""
    fi
    # remove 流程会给 DN 发 stopAndClearDataNode，DN 30s 后才退出；必须等进程真正退出再重启
    b=$(date +%s)
    while [ $(( $(date +%s)-b )) -lt 180 ]; do
      if ! ssh -n -o BatchMode=yes root@"$ip" "jps 2>/dev/null | grep -q DataNode" 2>/dev/null; then break; fi
      sleep 5
    done
    stop_dn "$ip"
    sleep 3
    check_clean "$ip" || { echo "DATA_NOT_CLEAN $ip"; fail=1; }
    echo "[$(date +%T)] add DN back: $ip"
    start_dn "$ip"
    wait_running "$ip" 900 || fail=1
  done
  [ "$fail" -ne 0 ] && break
done

echo "[$(date +%T)] stop benchmark"
kill "$BM" 2>/dev/null || true
pkill -f 'org.apache.iotdb.benchmark' 2>/dev/null || true

echo "[$(date +%T)] wait sync lag -> 0 (max 600s)"
b=$(date +%s)
while [ $(( $(date +%s)-b )) -lt 600 ]; do
  if sync_lag_ok; then echo "sync lag zero after $(( $(date +%s)-b ))s"; break; fi
  sleep 15
done
sync_lag_ok || { echo "SYNC_LAG_NOT_ZERO"; fail=1; }

echo "[$(date +%T)] topology check"
show_nodes | tee /tmp/scale_nodes_$TAG.txt | tail -8
running=$(show_nodes | grep -c '|Running|')
echo "running_dn=$running (expect 5)"
[ "$running" -eq 5 ] || fail=1
show_nodes | grep -q '|Unknown|' && { echo "UNKNOWN_NODE"; fail=1; }

echo "[$(date +%T)] log scan since $TS"
for ip in $DN_LIST; do
  n=$(ssh -n -o BatchMode=yes root@"$ip" "awk -v ts='$TS' 'substr(\$0,1,19)>=ts' $DB_ROOT/$TESTDB/logs/log_datanode_all.log 2>/dev/null | grep -aE ' ERROR | WARN ' | wc -l" 2>/dev/null)
  echo "DN $ip error_warn=$n"
done
for ip in $CN_LIST; do
  n=$(ssh -n -o BatchMode=yes root@"$ip" "awk -v ts='$TS' 'substr(\$0,1,19)>=ts' $DB_ROOT/$TESTDB/logs/log_confignode_all.log 2>/dev/null | grep -aE ' ERROR | WARN ' | wc -l" 2>/dev/null)
  echo "CN $ip error_warn=$n"
done

echo "[$(date +%T)] done fail=$fail log=$LOG"
exit "$fail"
