#!/bin/bash
# 3C4D 启动（预留 DN24 作为后续扩容节点）
# 与 cluster_ctl.sh reset 相同的 stop/wipe/start 流程，仅把 DN24 从启动列表移除
set -u
NEW=${NEW:-/data1/iotdb/v20131rc2_1110_83183d0}
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
CN_LIST="16 17 18"
DN_LIST="19 21 22 23"      # 4 个 DN，DN24 暂不启动
ALL_DN="19 24 21 22 23"
PAT='com[.]timecho[.]iotdb'
S="ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8"
log(){ echo "[$(date +%H:%M:%S)] $*"; }
count_procs(){ $S root@172.16.2.$1 "pgrep -f '$PAT' | wc -l" 2>/dev/null | tr -d ' '; }

log "停止全部实例"
for i in $CN_LIST $ALL_DN; do $S root@172.16.2.$i "pkill -9 -f '$PAT'" 2>/dev/null; done
for i in $CN_LIST $ALL_DN; do
  t0=$SECONDS
  while :; do c=$(count_procs $i); c=${c:-0}; [ "$c" = "0" ] && break; [ $((SECONDS-t0)) -ge 60 ] && { log "STOP FAILED node=$i"; exit 1; }; sleep 2; done
done
sleep 8
log "清空 data/logs（含 DN24）"
for i in $CN_LIST $ALL_DN; do $S root@172.16.2.$i "rm -rf $NEW/data $NEW/logs" 2>/dev/null; done

launch_cn(){ $S root@172.16.2.$1 "rm -f $NEW/logs/log_confignode_all.log; setsid bash $NEW/sbin/start-confignode.sh -d >/tmp/cn_start.log 2>&1 < /dev/null" 2>/dev/null; }
launch_dn(){ $S root@172.16.2.$1 "rm -f $NEW/logs/log_datanode_all.log; setsid bash $NEW/sbin/start-datanode.sh -d >/tmp/dn_start.log 2>&1 < /dev/null" 2>/dev/null; }

log "启动 3 个 CN（先 seed 16）"
launch_cn 16
for t in $(seq 1 60); do $S root@172.16.2.16 "grep -qE 'has successfully (re)?started and joined the cluster' $NEW/logs/log_confignode_all.log" 2>/dev/null && break; sleep 2; done
launch_cn 17; launch_cn 18
sleep 20

log "启动 4 个 DN：$DN_LIST"
for i in $DN_LIST; do launch_dn $i; done
for i in $DN_LIST; do
  for t in $(seq 1 60); do $S root@172.16.2.$i "grep -qE 'DataNode is set up successfully' $NEW/logs/log_datanode_all.log" 2>/dev/null && break; sleep 2; done
  log "dn $i ready"
done

log "等待 3C4D = 7/7 Running"
for t in $(seq 1 60); do
  n=$(bash $CLI -h 172.16.2.19 -p 6667 -u root -pw "$PW" -e "show cluster" 2>/dev/null | grep -c '|Running|')
  [ "${n:-0}" -ge 7 ] && { log "cluster=$n"; break; }
  sleep 5
done
bash $CLI -h 172.16.2.19 -p 6667 -u root -pw "$PW" -e "show cluster" 2>/dev/null | awk -F'|' '/Running/{print $3, $4}'
