#!/bin/bash
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
LOG=$A/rc2_regression_logs/sec_clean_restart.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }

say "1) 杀掉所有用例进程"
pkill -f 'cases/replica/sec_replica' 2>/dev/null || true
pkill -f 'cases/password/sec_' 2>/dev/null || true
pkill -f 'cases/config/sec_' 2>/dev/null || true
pkill -f 'cases/audit/sec_' 2>/dev/null || true
pkill -f 'final_run.sh' 2>/dev/null || true
pkill -f 'run_all.sh --set' 2>/dev/null || true
sleep 3
ps -eo cmd | grep -E 'sec_(replica|password|config|audit)|run_all.sh' | grep -v grep | head -3

say "2) 停所有 CN/DN（三节点）"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -TERM -f 'com.timecho.iotdb' || true; sleep 3; pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1
done
sleep 10
for h in 77 78 79; do
  echo -n "  .$h 残留: "; ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null
done | tee -a "$LOG"

say "3) 框架启动集群"
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 40); do
  n=0
  for h in 77 78 79; do
    c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1)
    n=$(( n + ${c:-0} ))
  done
  say "  轮 $i 进程数=$n"
  [ "${n:-0}" -ge 6 ] && break
  sleep 10
done

say "4) 登录验证（当前应仍是三权分立）"
printf 'set sql_dialect=tree;\nlist user;\n' | timeout 40 /data/iotdb/testdb/$V/sbin/start-cli.sh -h 192.168.99.77 -u security_admin -pw 'TimechoDB@2021' 2>&1 | grep -aE 'Error|security_admin|sys_admin' | head -4 | tee -a "$LOG"
say "done"
