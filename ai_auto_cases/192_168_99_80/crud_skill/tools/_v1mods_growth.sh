#!/bin/bash
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
LOG=/data/iotdb/autotest/rc2_regression_logs/v1mods_growth.log
A=/data/iotdb/autotest
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
cnt(){ local h n=0; for h in 77 78 79; do c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1); n=$(( n + ${c:-0} )); done; echo $n; }
sz(){ ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "find $D/data -path '*moddup*' -name '*.mods2' -printf '%f %s\n' 2>/dev/null | sort" 2>/dev/null; }
restart(){
  for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
  sleep 12
  ( cd $A && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
  for i in $(seq 1 40); do n=$(cnt); [ "${n:-0}" -ge 6 ] && { say "  就绪 n=$n"; break; }; sleep 10; done
  sleep 25
}
say "重启前："; sz | sed 's/^/  /' | tee -a "$LOG"
for k in 1 2; do
  say "第 $k 次重启"
  restart
  say "重启后："; sz | sed 's/^/  /' | tee -a "$LOG"
done
say "done"
