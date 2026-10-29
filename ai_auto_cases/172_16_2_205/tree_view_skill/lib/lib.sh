
cnt_rows() {
  echo "$1" | grep -E '^\|[[:space:]]*[0-9]+' | head -1 | tr -dc '0-9'
}

# Shared helpers for the tree-view auto-sync-schema suite. Sourced by every case group.
# Requires: NEW, CLI, T(), Q() defined by suite.sh before sourcing.

# ---------- SQL helpers ----------
T() { $CLI -h ${SQL_HOST:-172.16.2.2} -p 6667 -u root -pw ${PW:-TimechoDB@2021} -sql_dialect tree -e "$1" 2>&1; }
Q() { $CLI -h ${SQL_HOST:-172.16.2.2} -p 6667 -u root -pw ${PW:-TimechoDB@2021} -sql_dialect table -e "$1" 2>&1; }
Tn() { $CLI -h "$1" -p 6667 -u root -pw ${PW:-TimechoDB@2021} -sql_dialect tree -e "$2" 2>&1; }
Qn() { $CLI -h "$1" -p 6667 -u root -pw ${PW:-TimechoDB@2021} -sql_dialect table -e "$2" 2>&1; }

# ---------- assertions (accumulate into CASE_FAILS / CASE_MSGS) ----------
CASE_FAILS=0
CASE_MSGS=""
fail() { CASE_FAILS=$((CASE_FAILS + 1)); CASE_MSGS="${CASE_MSGS}[FAIL] $* ; "; }

assert_ok() {   # $1=output  $2=desc
  if echo "$1" | grep -qE "Msg: org.apache.iotdb.jdbc|Exception|Error:"; then
    fail "$2: unexpected error -> $(echo "$1" | grep -m1 -E 'Msg:|Exception' | cut -c1-160)"
  fi
}
assert_error() { # $1=output $2=expected substring $3=desc
  if ! echo "$1" | grep -qF -- "$2"; then
    fail "$3: expected error containing [$2] -> $(echo "$1" | head -2 | cut -c1-160)"
  fi
}
assert_contains() { # $1=output $2=text $3=desc
  if ! echo "$1" | grep -qF -- "$2"; then
    fail "$3: missing [$2]"
  fi
}
assert_not_contains() {
  if echo "$1" | grep -qF -- "$2"; then
    fail "$3: unexpected [$2]"
  fi
}
assert_rows() { # $1=output $2=n $3=desc
  local n
  n=$(echo "$1" | grep -c '^|')
  n=$((n > 0 ? n - 1 : 0))
  if [ "$n" != "$2" ]; then fail "$3: rows got=$n want=$2"; fi
}

# column list of a view as "name:type" lines
view_cols() {  # $1=db $2=view
  Q "DESC $1.$2" | awk -F'|' 'NF>2 {gsub(/ /,"",$2); gsub(/ /,"",$3); if ($2!="ColumnName") print $2":"$3}'
}
assert_col() {  # $1=db $2=view $3=col $4=type $5=desc
  local out
  out=$(view_cols "$1" "$2")
  if ! echo "$out" | grep -qx "$3:$4"; then
    fail "$5: column $3:$4 absent, got [$(echo $out | tr '\n' ' ')]"
  fi
}
assert_no_col() {
  local out
  out=$(view_cols "$1" "$2")
  if echo "$out" | grep -q "^$3:"; then
    fail "$4: column $3 should be absent, got [$(echo $out | tr '\n' ' ')]"
  fi
}

# ---------- environment helpers ----------
wait_running() {  # $1=seconds  -> waits until 8 nodes Running
  local max=${1:-180} i out n
  for i in $(seq 1 $((max / 5))); do
    out=$(Qn 172.16.2.2 "show cluster;" 2>/dev/null || Qn 172.16.2.3 "show cluster;" 2>/dev/null)
    n=$(echo "$out" | grep -cE "Running")
    [ "$n" -ge 8 ] && return 0
    sleep 5
  done
  return 1
}

stop_dn() {  # graceful stop, then hard kill if needed; waits until the process is gone
  local ip=$1 i
  ssh -o StrictHostKeyChecking=no root@$ip "bash /data1/iotdb/$NEW/sbin/stop-datanode.sh >/dev/null 2>&1" 2>/dev/null
  for i in $(seq 1 30); do
    n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.DataNode'" 2>/dev/null)
    [ "${n:-0}" = "0" ] && return 0
    sleep 2
  done
  ssh -o StrictHostKeyChecking=no root@$ip "pkill -9 -f 'com.timecho.iotdb'" 2>/dev/null
  sleep 5
}

start_dn() {  # wait for the rpc port to be free, start, verify the process survives 25s; retry up to 3 times
  local ip=$1 attempt n i
  for attempt in 1 2 3; do
    n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.DataNode'" 2>/dev/null)
    [ "${n:-0}" != "0" ] && return 0
    for i in $(seq 1 30); do
      b=$(ssh -o StrictHostKeyChecking=no root@$ip "ss -lnt 2>/dev/null | grep -c ':6667'" 2>/dev/null)
      [ "${b:-0}" = "0" ] && break
      sleep 2
    done
    ssh -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd /data1/iotdb/$NEW; nohup /data1/iotdb/$NEW/sbin/start-datanode.sh -H /data1/iotdb/$NEW/dn.hprof > /data1/iotdb/$NEW/start_dn.log 2>&1 &" 2>/dev/null
    sleep 25
    n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.DataNode'" 2>/dev/null)
    [ "${n:-0}" != "0" ] && return 0
    echo "  start_dn $ip attempt $attempt failed, retrying"
    sleep 5
  done
  echo "  start_dn $ip FAILED after 3 attempts"
  return 1
}

start_dn_fast() {  # start without long verification (used inside the per-case consistency check)
  local ip=$1 n
  n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.DataNode'" 2>/dev/null)
  [ "${n:-0}" != "0" ] && return 0
  ssh -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd /data1/iotdb/$NEW; nohup /data1/iotdb/$NEW/sbin/start-datanode.sh -H /data1/iotdb/$NEW/dn.hprof > /data1/iotdb/$NEW/start_dn.log 2>&1 &" 2>/dev/null
  sleep 6
}

verify_dns() {  # ensure every DN node has a live process, then wait for 8 Running
  local ip n
  for ip in 172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6; do
    n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.DataNode'" 2>/dev/null)
    if [ "${n:-0}" = "0" ]; then
      echo "  verify_dns: starting DN $ip"
      start_dn $ip
    fi
  done
  wait_running 240 >/dev/null 2>&1
}

repair_dns() {  # make sure every DN node has a process; start the missing ones
  local ip n
  for ip in 172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6; do
    n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.DataNode'" 2>/dev/null)
    [ "${n:-0}" = "0" ] && { echo "  repair: starting DN $ip"; start_dn $ip; }
  done
}

stop_cn()  { ssh -o StrictHostKeyChecking=no root@$1 "bash /data/iotdb/$NEW/sbin/stop-confignode.sh >/dev/null 2>&1" 2>/dev/null; sleep 6; ssh -o StrictHostKeyChecking=no root@$1 "pkill -9 -f 'com.timecho.iotdb.service.ConfigNode' 2>/dev/null; true" 2>/dev/null; sleep 4; }
start_cn() {
  local ip=$1 attempt n
  for attempt in 1 2 3; do
    ssh -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd /data/iotdb/$NEW; nohup /data/iotdb/$NEW/sbin/start-confignode.sh -H /data/iotdb/$NEW/cn.hprof > /data/iotdb/$NEW/start_cn.log 2>&1 &" 2>/dev/null
    sleep 20
    n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.service.ConfigNode'" 2>/dev/null)
    [ "${n:-0}" != "0" ] && return 0
  done
  return 1
}

# wait until all DNs report syncLag == 0 (metric iot_consensus{type="syncLag"})
wait_sync_lag_zero() {  # $1=timeout sec
  local max=${1:-180} i ip v bad
  for i in $(seq 1 $((max / 5))); do
    bad=0
    for ip in 172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6; do
      v=$(curl -s -m 3 "http://$ip:9092/metrics" 2>/dev/null | awk -F'[ }]' '/type="syncLag"/{for(j=1;j<=NF;j++) if($j ~ /^-?[0-9.]+$/) last=$j; print last}' | sort -rn | head -1)
      [ -z "$v" ] && v=0
      awk -v x="$v" 'BEGIN{exit !(x>0)}' && bad=1
    done
    [ "$bad" = "0" ] && { echo "  syncLag=0 after $((i * 5))s"; return 0; }
    sleep 5
  done
  echo "  syncLag NOT zero after ${max}s"
  return 1
}

# baseline query output, normalized (drop cost line and separators)
norm_sql_out() { echo "$1" | sed '/^It costs /d' | sed '/^+[-+]*+$/d' | sed '/^Total line number/d'; }

replica_consistency() {  # $1=dns-to-stop(csv, 2 items) $2=sql $3=query-host
  local dns=$1 sql=$2 qh=${3:-172.16.2.2} base out
  base=$(norm_sql_out "$(Qn $qh "$sql")")
  if [ -z "$base" ]; then echo "  consistency: baseline empty (skipped compare)"; return 0; fi
  local d rc=0
  for d in $(echo $dns | tr ',' ' '); do
    stop_dn "$d"
    sleep 6
    out=$(norm_sql_out "$(Qn 172.16.2.3 "$sql")")
    if [ "$out" != "$base" ]; then
      rc=1
      echo "  consistency: MISMATCH after stopping $d"
      echo "$out" > /tmp/consistency_diff_$d.txt
    else
      echo "  consistency: OK with $d down"
    fi
    start_dn_fast "$d"
    sleep 2
  done
  verify_dns
  return $rc
}

# ---------- log helpers ----------
log_files() {  # $1=ip  -> prints the all-log path
  local ip=$1
  ssh -o StrictHostKeyChecking=no root@$ip "ls /data/iotdb/$NEW/logs/log_confignode_all.log 2>/dev/null; ls /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null"
}

log_size() { ssh -o StrictHostKeyChecking=no root@$1 "stat -c%s $2 2>/dev/null || echo 0"; }

log_mark_all() {  # writes /tmp/logmarks/<ip> = size
  local ip
  mkdir -p /tmp/logmarks
  for ip in 172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6 172.16.2.26 172.16.2.27 172.16.2.28; do
    local f
    f=$(log_files $ip | head -1)
    if [ -n "$f" ]; then log_size $ip "$f" > /tmp/logmarks/$ip; else echo 0 > /tmp/logmarks/$ip; fi
  done
}

log_scan_delta() {  # $1=outdir  -> writes new ERROR/WARN lines per node; returns unexpected ERROR count
  local outdir=$1 ip f mark errs=0
  local benign='GrpcLogAppender|Failed requestVote|Failed appendEntries|ServerNotReady|LeaderElection|RetryImmediately|Connection refused|Connection reset|is interrupted|TimeoutException|LeaderState|readIndex|DataNodeAuthUtils|Fail to check password expiration|Cannot pull system configurations|Fail to start server|shutdown failed|current node leader may have been down'
  mkdir -p "$outdir"
  : > "$outdir/logdelta.txt"
  for ip in 172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6 172.16.2.26 172.16.2.27 172.16.2.28; do
    f=$(log_files $ip | head -1)
    [ -z "$f" ] && continue
    mark=$(cat /tmp/logmarks/$ip 2>/dev/null || echo 0)
    ssh -o StrictHostKeyChecking=no root@$ip "tail -c +$((mark + 1)) '$f' 2>/dev/null | grep -E ' (ERROR|WARN) ' | cut -c1-260" > "$outdir/new_$ip.txt" 2>/dev/null
    local raw unexp
    raw=$(grep -c ' ERROR ' "$outdir/new_$ip.txt" 2>/dev/null || echo 0)
    unexp=$(grep ' ERROR ' "$outdir/new_$ip.txt" 2>/dev/null | grep -vcE "$benign" || true)
    [ -z "$unexp" ] && unexp=0
    errs=$((errs + unexp))
    echo "### $ip  ERROR=$raw unexpected=$unexp WARN=$(grep -c ' WARN ' "$outdir/new_$ip.txt" 2>/dev/null || echo 0)" >> "$outdir/logdelta.txt"
    cat "$outdir/new_$ip.txt" >> "$outdir/logdelta.txt"
  done
  return $errs
}

backup_logs() {  # $1=case_id
  local id=$1 out=/data2/auto_test/treeview_suite/results/fail_logs/$id
  mkdir -p "$out"
  local ip f
  for ip in 172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6 172.16.2.26 172.16.2.27 172.16.2.28; do
    f=$(log_files $ip | head -1)
    [ -z "$f" ] && continue
    ssh -o StrictHostKeyChecking=no root@$ip "mkdir -p $out/$ip && cp '$f' $out/$ip/ 2>/dev/null; ls -l $out/$ip | tail -1" >/dev/null 2>&1
  done
  echo "  logs backed up to $out"
}
