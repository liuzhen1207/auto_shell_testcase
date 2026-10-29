#!/bin/bash
# patch: parallel launch-then-wait start_all for cluster_ctl.sh
NEW=/data1/iotdb/v20121rc10_1021_c60ce63
CN_LIST="16 17 18"
DN_LIST="19 24 21 22 23"
S="ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8"
log(){ echo "[$(date +%H:%M:%S)] $*"; }
count_procs(){ $S root@172.16.2.$1 "pgrep -f '$NEW/.*[.](DataNode|ConfigNode)' | wc -l" 2>/dev/null | tr -d ' '; }
launch_cn(){ $S root@172.16.2.$1 "cd $NEW && rm -f logs/log_confignode_all.log && setsid bash sbin/start-confignode.sh -d >/tmp/rc10_cn_start.log 2>&1 < /dev/null" 2>/dev/null; }
launch_dn(){ $S root@172.16.2.$1 "cd $NEW && rm -f logs/log_datanode_all.log && setsid bash sbin/start-datanode.sh -d >/tmp/rc10_dn_start.log 2>&1 < /dev/null" 2>/dev/null; }
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
    $S root@172.16.2.16 "pkill -9 -f '$NEW/.*[.](DataNode|ConfigNode)'" 2>/dev/null
    sleep 25
  done
  return 1
}
start_rest(){
  local i rc a
  for i in 17 18; do launch_cn $i; done
  for i in 17 18; do
    for a in 1 2 3; do
      wait_role $i cn; rc=$?
      [ "$rc" -eq 0 ] && { log "cn $i ready"; break; }
      launch_cn $i; sleep 20; wait_role $i cn; rc=$?
      [ "$rc" -eq 0 ] && { log "cn $i ready(retry)"; break; }
    done
    [ "$rc" -eq 0 ] || { log "cn $i FAILED"; return 1; }
  done
  for i in $DN_LIST; do launch_dn $i; done
  for i in $DN_LIST; do
    for a in 1 2 3; do
      wait_role $i dn; rc=$?
      [ "$rc" -eq 0 ] && { log "dn $i ready"; break; }
      launch_dn $i; sleep 20; wait_role $i dn; rc=$?
      [ "$rc" -eq 0 ] && { log "dn $i ready(retry)"; break; }
    done
    [ "$rc" -eq 0 ] || { log "dn $i FAILED"; return 1; }
  done
  return 0
}
for i in $CN_LIST $DN_LIST; do
  if [ "$(count_procs $i)" != "0" ]; then log "PRESTART DIRTY node=$i"; exit 1; fi
done
start_seed || exit 1
start_rest || exit 1
log "start_all done"