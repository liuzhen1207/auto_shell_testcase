#!/bin/bash
# run_round.sh <PROTO> <CASE> — one protocol round with full gates (v3)
set -u
PROTO=$1; CASE=$2
NEW=/data1/iotdb/v20121rc10_1021_c60ce63
BASE=/data2/iotdb/rc10_matrix
CLI=/data2/iotdb/v20121rc10_1021_c60ce63/timechodb-2.0.12.1-bin/sbin/start-cli.sh
CONF=/data2/auto_test/cluster_shell_3c5d_no3/tc2026_releasenote_testcase/conf/test.conf
PW=$(awk -F= '$1=="root_pw"{print substr($0,index($0,"=")+1)}' "$CONF")
DNS="19 21 22 23 24"
ART=$BASE/artifacts/$PROTO/$CASE
LAG_SAMPLES=${LAG_SAMPLES:-31}
LAG_INTERVAL=${LAG_INTERVAL:-10}
CONVERGE_MAX=${CONVERGE_MAX:-600}
RESTART_MAX=${RESTART_MAX:-360}
SQL_TIMEOUT=${SQL_TIMEOUT:-180}
SSH="ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8"
PAT='com[.]timecho[.]iotdb'
mkdir -p "$ART"
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$ART/round.log"; }

case "$PROTO" in
  IoTConsensus) METRIC=iot_consensus; CLASS=org.apache.iotdb.consensus.iot.IoTConsensus ;;
  IoTV2) METRIC=iot_consensus_v2; CLASS=org.apache.iotdb.consensus.iot.IoTConsensusV2 ;;
  *) echo "bad proto"; exit 2 ;;
esac

port_up(){ timeout 2 bash -c "</dev/tcp/172.16.2.$1/6667" 2>/dev/null; }
live_dn(){ local n; for n in $DNS; do port_up "$n" && { echo "$n"; return; }; done; echo 19; }
proc_count(){ $SSH root@172.16.2.$1 "pgrep -f '$PAT[.]DataNode' | wc -l" 2>/dev/null | tr -d ' '; }
get_db(){ grep -oE 'del_rc10_[a-z0-9_]+' "$BASE/cases/$CASE/run.sql" 2>/dev/null | head -1; }

reset_cluster(){
  bash "$BASE/scripts/cluster_ctl.sh" stop >> "$ART/reset.out" 2>&1 || return 1
  local i
  for i in 16 17 18 19 21 22 23 24; do
    $SSH root@172.16.2.$i "rm -rf $NEW/data $NEW/logs; sed -i '/^data_region_consensus_protocol_class=/d' $NEW/conf/iotdb-system.properties; echo 'data_region_consensus_protocol_class=$CLASS' >> $NEW/conf/iotdb-system.properties" 2>/dev/null
  done
  bash "$BASE/scripts/cluster_ctl.sh" start >> "$ART/reset.out" 2>&1 || return 1
  return 0
}

wait8(){
  local t0=$SECONDS out n d
  while [ $((SECONDS-t0)) -lt 300 ]; do
    d=$(live_dn)
    out=$("$CLI" -h 172.16.2."$d" -p 6667 -u root -pw "$PW" -e "show cluster" 2>/dev/null)
    n=$(printf '%s\n' "$out" | grep -c '|Running|')
    if [ "${n:-0}" -eq 8 ]; then printf '%s\n' "$out" > "$ART/show-cluster-ready.out"; return 0; fi
    sleep 5
  done
  printf '%s\n' "$out" > "$ART/show-cluster-ready.out"; return 1
}

find_regions(){
  local db=$1 d
  d=$(live_dn)
  if [ "${TREE:-0}" = "1" ]; then
    "$CLI" -h 172.16.2."$d" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; SHOW REGIONS;" > "$ART/regions.out" 2>&1
  else
    "$CLI" -h 172.16.2."$d" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; USE $db; SHOW REGIONS;" > "$ART/regions.out" 2>&1
  fi
  awk -F'|' '/\| *DataRegion *\|/ {gsub(/[ \t]/,"",$2); print $2}' "$ART/regions.out" | sort -un | tr '\n' ' '
}

# 兜底：直接从 5 台 DN 的 syncLag 指标里收集当前全部 DataRegion
regions_from_metrics(){
  local n raw out
  out=""
  for n in $DNS; do
    raw=$(curl -fsS --max-time 5 "http://172.16.2.$n:9092/metrics" 2>/dev/null)
    [ -z "$raw" ] && continue
    out="$out$(printf '%s\n' "$raw" | grep 'type="syncLag"' | sed -E 's/.*region="DataRegion\[([0-9]+)\]".*/\1/' | grep -E '^[0-9]+$')"$'\n'
  done
  printf '%s\n' "$out" | sort -un | tr '\n' ' '
}

# one raw pass over the 5 DNs for relevant DataRegions: echoes "<region>,<value>" lines
one_pass(){
  local n raw sel line region val
  for n in $DNS; do
    raw=$(curl -fsS --max-time 5 "http://172.16.2.$n:9092/metrics" 2>/dev/null)
    [ -z "$raw" ] && { echo "$n,NO_METRICS,-"; continue; }
    sel=$(printf '%s\n' "$raw" | grep 'type="syncLag"' | awk -v m="$METRIC{" 'index($0,m)==1' | grep -E "$REGEX")
    [ -z "$sel" ] && continue
    while IFS= read -r line; do
      region=$(printf '%s' "$line" | sed -E 's/.*region="DataRegion\[([0-9]+)\]".*/\1/')
      val=$(printf '%s' "$line" | awk '{print $NF}')
      echo "$n,$region,$val"
    done <<< "$sel"
  done
}

# wait until every relevant region shows >=2 zero-lag series across DNs
wait_converged(){
  local label=$1 t0=$SECONDS pass out r c bad
  while [ $((SECONDS-t0)) -lt "$CONVERGE_MAX" ]; do
    pass=$(one_pass); bad=0
    for r in $RELEVANT; do
      c=$(printf '%s\n' "$pass" | awk -F, -v r="$r" '$2==r && $3+0==0 {n++} END{print n+0}')
      [ "${c:-0}" -lt 2 ] && bad=1
    done
    printf '%s\n' "$pass" | grep -q 'NO_METRICS' && bad=1
    if [ "$bad" -eq 0 ]; then
      printf '%s\n' "$pass" > "$ART/converged-$label.out"
      echo "converged_after=$((SECONDS-t0))s" >> "$ART/converged-$label.out"
      return 0
    fi
    sleep 5
  done
  printf '%s\n' "$pass" > "$ART/converged-$label.out"
  echo "converge_timeout" >> "$ART/converged-$label.out"
  return 1
}

sample_lag(){
  local label=$1 out=$ART/lag-$1.csv bad=0 i r c pass
  : > "$out"
  for i in $(seq 1 "$LAG_SAMPLES"); do
    pass=$(one_pass)
    printf '%s\n' "$pass" | sed "s/^/$i,/" >> "$out"
    printf '%s\n' "$pass" | grep -q 'NO_METRICS' && bad=$((bad+1))
    printf '%s\n' "$pass" | awk -F, '$3+0!=0' | grep -q . && bad=$((bad+1))
    for r in $RELEVANT; do
      c=$(printf '%s\n' "$pass" | awk -F, -v r="$r" '$2==r && $3+0==0 {n++} END{print n+0}')
      [ "${c:-0}" -lt 2 ] && bad=$((bad+1))
    done
    [ "$i" -lt "$LAG_SAMPLES" ] && sleep "$LAG_INTERVAL"
  done
  echo "$bad"
}

build_query(){
  local f=$BASE/cases/$CASE/run.sql src=$ART/run.sanitized.sql ld fs
  # 去掉首行 BOM：带 BOM 会让首条 SET SQL_DIALECT 解析出隐藏字符
  sed '1s/^\xEF\xBB\xBF//' "$f" > "$src"
  ld=$(grep -n -i '^DELETE' "$src" | tail -1 | cut -d: -f1)
  if [ -n "${ld:-}" ]; then fs=$(grep -n -i '^SELECT' "$src" | awk -F: -v d="$ld" '$1>d{print $1; exit}'); else fs=$(grep -n -i '^SELECT' "$src" | head -1 | cut -d: -f1); fi
  : > "$ART/query.sql"
  if [ -n "${fs:-}" ]; then tail -n +"$fs" "$src" | grep -i '^SELECT' >> "$ART/query.sql"; fi
  [ -s "$ART/query.sql" ] || grep -i '^SELECT' "$src" >> "$ART/query.sql"
  [ -s "$ART/query.sql" ] || echo "SELECT 1;" > "$ART/query.sql"
  { echo "SET SQL_DIALECT=$( [ "${TREE:-0}" = "1" ] && echo TREE || echo TABLE );"; cat "$ART/query.sql"; } > "$ART/query.sql.tmp" && mv "$ART/query.sql.tmp" "$ART/query.sql"
}

query_dn(){ timeout 120 "$CLI" -h 172.16.2."$1" -p 6667 -u root -pw "$PW" < "$ART/query.sql" > "$2" 2>&1; }
norm(){ grep -vE '^(It costs|Total line number|TimechoDB|Msg:|-+$|Starting|Successfully login)' "$1" | grep -v '^[[:space:]]*$'; }

restart_dn(){
  local dn=$1 t0=$SECONDS
  $SSH root@172.16.2."$dn" "setsid bash $NEW/sbin/start-datanode.sh -d >/tmp/rc10_dn_restart_$dn.log 2>&1 < /dev/null" >/dev/null 2>&1
  while [ $((SECONDS-t0)) -lt "$RESTART_MAX" ]; do
    if [ "$(proc_count "$dn")" -ge 1 ] && port_up "$dn"; then
      echo "ready_after=$((SECONDS-t0))s" > "$ART/restart-dn$dn.out"
      return 0
    fi
    sleep 5
  done
  echo "restart_timeout_after=$((SECONDS-t0))s procs=$(proc_count $dn) port=$(port_up $dn && echo up || echo down)" > "$ART/restart-dn$dn.out"
  return 1
}

outage_gate(){
  local dn=$1 pid t0
  $SSH root@172.16.2."$dn" "pgrep -f '$PAT[.]DataNode'" > "$ART/pid-dn$dn.out" 2>/dev/null
  pid=$(head -1 "$ART/pid-dn$dn.out")
  if [ -z "${pid:-}" ]; then echo "no-pid" > "$ART/stop-dn$dn.out"; return 1; fi
  $SSH root@172.16.2."$dn" "kill -9 $pid" > "$ART/stop-dn$dn.out" 2>&1
  t0=$SECONDS
  while [ "$(proc_count "$dn")" != "0" ]; do [ $((SECONDS-t0)) -ge 60 ] && break; sleep 2; done
  { echo "procs_after_kill=$(proc_count $dn)"; echo "port_after_kill=$(port_up $dn && echo up || echo down)"; } > "$ART/down-state-dn$dn.out"
  query_dn "$(live_dn)" "$ART/outage-dn$dn.out"
  sleep 10
  restart_dn "$dn" || return 1
  query_dn "$dn" "$ART/recovered-query-dn$dn.out"
  wait_converged "recover-dn$dn" || return 1
  local bad; bad=$(sample_lag "recover-dn$dn"); echo "$bad" > "$ART/lag-recover-dn$dn.bad"
  [ "$bad" -eq 0 ]
}

T0=$(date +%s); T0H=$(date -Is)
log "ROUND START proto=$PROTO case=$CASE"
RESULT=PASS
reset_cluster || RESULT=FAIL_RESET
if [ "$RESULT" = "PASS" ] && ! wait8; then RESULT=FAIL_CLUSTER; fi

if [ "$RESULT" = "PASS" ]; then
  DB=$(get_db); echo "$DB" > "$ART/db.txt"
  TREE=0; grep -q '^SET SQL_DIALECT=TREE' "$BASE/cases/$CASE/run.sql" && TREE=1
  echo "$TREE" > "$ART/tree-mode.txt"
  build_query
  MEMLEAK=0; case "$CASE" in DEL-MEMLEAK*) MEMLEAK=1;; esac
  if [ "$MEMLEAK" = "1" ]; then
    SQL_TIMEOUT=${SQL_TIMEOUT:-900}
    (
      for k in $(seq 1 180); do
        ts=$(date +%s)
        for n in $DNS; do
          rss=$($SSH root@172.16.2."$n" "ps -o rss= -p \$(pgrep -f '$PAT[.]DataNode' | head -1) 2>/dev/null" 2>/dev/null | tr -d ' ')
          echo "$ts,$n,${rss:-NA}" >> "$ART/memory.csv"
        done
        sleep 10
      done
    ) &
    SAMP_PID=$!
  fi
  timeout "$SQL_TIMEOUT" "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" < "$ART/run.sanitized.sql" > "$ART/run.out" 2>&1
  echo "$?" > "$ART/sql-exit.txt"
  if [ "$MEMLEAK" = "1" ]; then
    kill "$SAMP_PID" 2>/dev/null
    for n in $DNS; do
      awk -F, -v N="$n" '$2==N && $3!="NA"{c++; v[c]=$3} END{if(c>0) printf "%s first=%sKB last=%sKB delta=%sKB samples=%s\n", N, v[1], v[c], v[c]-v[1], c}' "$ART/memory.csv" 2>/dev/null
    done > "$ART/memory-summary.txt"
  fi
  grep -c 'Msg: The statement is executed successfully' "$ART/run.out" > "$ART/sql-ok-count.txt" 2>/dev/null || true
  RELEVANT=""
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    RELEVANT=$(find_regions "$DB")
    [ -n "${RELEVANT// /}" ] && break
    sleep 2
  done
  echo "show_regions" > "$ART/relevant-regions-source.txt"
  if [ -z "${RELEVANT// /}" ]; then RELEVANT=$(regions_from_metrics); echo "fallback_metrics" > "$ART/relevant-regions-source.txt"; fi
  echo "$RELEVANT" > "$ART/relevant-regions.txt"
  if [ -z "${RELEVANT// /}" ]; then
    echo "no-region-discovered" > "$ART/lag-baseline.bad"
    RESULT=FAIL_REGION
  fi
  if [ -z "${RELEVANT// /}" ]; then REGEX='region="DataRegion\['; else REGEX="region=\"DataRegion\[($(echo "$RELEVANT" | tr -s ' ' '|' | sed 's/|$//'))\]\""; fi
  echo "$REGEX" > "$ART/region-regex.txt"
  if [ "$RESULT" = "PASS" ]; then
  if wait_converged baseline; then
    bad0=$(sample_lag baseline); echo "$bad0" > "$ART/lag-baseline.bad"
    [ "${bad0:-1}" -eq 0 ] || RESULT=FAIL_LAG
  else
    echo "baseline-converge-timeout" > "$ART/lag-baseline.bad"; RESULT=FAIL_LAG_CONVERGE
  fi
  for n in $DNS; do query_dn "$n" "$ART/final-query-dn$n.out"; done
  for n in $DNS; do
    if ! outage_gate "$n"; then log "outage gate FAILED on DN$n"; RESULT=FAIL_OUTAGE; fi
  done
  for n in $DNS; do query_dn "$n" "$ART/final-after-query-dn$n.out"; done
  for n in 21 22 23 24; do
    if ! diff <(norm "$ART/final-query-dn19.out") <(norm "$ART/final-after-query-dn$n.out") > "$ART/diff-dn$n.out" 2>&1; then RESULT=FAIL_DN_DIFF; fi
  done
  if [ -s "$BASE/cases/$CASE/post.sh" ]; then
    CLI="$CLI" PW="$PW" ART="$ART" DB="$DB" bash "$BASE/cases/$CASE/post.sh" > "$ART/post.log" 2>&1
    echo "$?" > "$ART/post-exit.txt"
    [ "$(cat "$ART/post-exit.txt" 2>/dev/null)" = "0" ] || { log "post.sh FAILED (权限负向/附加断言)"; RESULT=FAIL_POST; }
  fi
  d=$(live_dn)
  "$CLI" -h 172.16.2."$d" -p 6667 -u root -pw "$PW" -e "show cluster" > "$ART/final-show-cluster.out" 2>&1 || true
  grep -c '|Running|' "$ART/final-show-cluster.out" > "$ART/final-running-count.txt" 2>/dev/null || true
  [ "$(cat "$ART/final-running-count.txt" 2>/dev/null || echo 0)" = "8" ] || { [ "$RESULT" = "PASS" ] && RESULT=FAIL_FINAL_CLUSTER; }
  fi
fi

T1=$(date +%s); DUR=$((T1-T0)); T1H=$(date -Is)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PROTO" "$CASE" "$T0H" "$T1H" "$DUR" "$RESULT" "$(cat "$ART/sql-ok-count.txt" 2>/dev/null || echo NA)" >> "$BASE/results/results.tsv"
log "ROUND END result=$RESULT duration=${DUR}s"
