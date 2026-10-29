#!/bin/bash
# RC10 3C5D cluster control: verified stop / wipe / retrying parallel start
NEW=/data1/iotdb/v20121rc10_1021_c60ce63
CLI=/data2/iotdb/v20121rc10_1021_c60ce63/timechodb-2.0.12.1-bin/sbin/start-cli.sh
CN_LIST="16 17 18"
DN_LIST="19 24 21 22 23"
PAT='com[.]timecho[.]iotdb'
S="ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8"
log(){ echo "[$(date +%H:%M:%S)] $*"; }

count_procs(){ $S root@172.16.2.$1 "pgrep -f '$PAT' | wc -l" 2>/dev/null | tr -d ' '; }

stop_all(){
  local i c t0
  for i in $CN_LIST $DN_LIST; do $S root@172.16.2.$i "pkill -9 -f '$PAT'" 2>/dev/null; done
  for i in $CN_LIST $DN_LIST; do
    t0=$SECONDS
    while :; do
      c=$(count_procs $i); c=${c:-0}
      [ "$c" = "0" ] && break
      if [ $((SECONDS-t0)) -ge 60 ]; then log "STOP FAILED node=$i remaining=$c"; return 1; fi
      sleep 2
    done
  done
  log "all iotdb processes stopped (all instances)"
  sleep 8
  return 0
}

wipe_all(){
  local i
  for i in $CN_LIST $DN_LIST; do $S root@172.16.2.$i "rm -rf $NEW/data $NEW/logs" 2>/dev/null; done
  for i in $CN_LIST $DN_LIST; do
    if $S root@172.16.2.$i "[ -d $NEW/data ] || [ -d $NEW/logs ]" 2>/dev/null; then log "WIPE FAILED node=$i"; return 1; fi
  done
  log "rc10 data+logs wiped"
  return 0
}

launch_cn(){ $S root@172.16.2.$1 "rm -f $NEW/logs/log_confignode_all.log; setsid bash $NEW/sbin/start-confignode.sh -d >/tmp/rc10_cn_start.log 2>&1 < /dev/null" 2>/dev/null; }
launch_dn(){ $S root@172.16.2.$1 "rm -f $NEW/logs/log_datanode_all.log; setsid bash $NEW/sbin/start-datanode.sh -d >/tmp/rc10_dn_start.log 2>&1 < /dev/null" 2>/dev/null; }

wait_role(){
  local i=$1 role=$2 logf t0=$SECONDS okpat
  if [ "$role" = "cn" ]; then logf="$NEW/logs/log_confignode_all.log"; okpat='has successfully (re)?started and joined the cluster'
  else logf="$NEW/logs/log_datanode_all.log"; okpat='DataNode is set up successfully'; fi
  while [ $((SECONDS-t0)) -lt 150 ]; do
    $S root@172.16.2.$i "grep -qE '$okpat' $logf" 2>/dev/null && return 0
    $S root@172.16.2.$i "grep -qE 'Address already in use|Failed to bind' $logf" 2>/dev/null && return 1
    sleep 2
  done
  return 2
}

start_seed(){
  local a rc
  for a in 1 2 3; do
    launch_cn 16; wait_role 16 cn; rc=$?
    [ "$rc" -eq 0 ] && { log "seed cn 16 ready"; return 0; }
    log "seed attempt $a rc=$rc; retry 25s"
    $S root@172.16.2.16 "pkill -9 -f '$PAT'" 2>/dev/null
    sleep 25
  done
  return 1
}

start_rest(){
  local i rc a
  for i in 17 18; do launch_cn $i; done
  for i in 17 18; do
    wait_role $i cn; rc=$?
    if [ "$rc" -ne 0 ]; then launch_cn $i; sleep 20; wait_role $i cn; rc=$?; fi
    [ "$rc" -eq 0 ] && log "cn $i ready" || { log "cn $i FAILED"; return 1; }
  done
  for i in $DN_LIST; do launch_dn $i; done
  for i in $DN_LIST; do
    wait_role $i dn; rc=$?
    if [ "$rc" -ne 0 ]; then launch_dn $i; sleep 20; wait_role $i dn; rc=$?; fi
    [ "$rc" -eq 0 ] && log "dn $i ready" || { log "dn $i FAILED"; return 1; }
  done
  return 0
}

start_all(){
  local i
  for i in $CN_LIST $DN_LIST; do
    if [ "$(count_procs $i)" != "0" ]; then log "PRESTART DIRTY node=$i"; return 1; fi
  done
  start_seed || return 1
  start_rest || return 1
  log "start_all done"
}

show8(){ bash "$CLI" -h 172.16.2.19 -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>/dev/null | grep -c '|Running|'; }

case "${1:-}" in
  stop) stop_all ;;
  wipe) wipe_all ;;
  start) start_all ;;
  reset) stop_all && wipe_all && start_all ;;
  count) echo "running=$(show8)" ;;
  *) echo "usage: $0 {start|stop|wipe|reset|count}" ;;
esac