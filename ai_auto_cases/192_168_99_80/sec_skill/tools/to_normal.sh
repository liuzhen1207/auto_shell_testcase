#!/bin/bash
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
LOG=$A/rc2_regression_logs/sec_to_normal.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
try_root(){ printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h 192.168.99.77 -u root -pw 'TimechoDB@2021' 2>&1 | grep -aE 'Error|root' | head -2; }

say "1) 停用例与集群"
pkill -f 'final_run.sh' 2>/dev/null || true
pkill -f 'run_all.sh --set' 2>/dev/null || true
pkill -f 'cases/.*/sec_' 2>/dev/null || true
sleep 2
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -TERM -f 'com.timecho.iotdb' || true; sleep 3; pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 8

say "2) 三节点写 enable_separation_of_powers=false（conf 与 conf_orig 都写）"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    for F in $D/conf/iotdb-system.properties $D/conf_orig/iotdb-system.properties; do
      [ -f \"\$F\" ] || continue
      sed -i '/^enable_separation_of_powers=/d' \"\$F\"
      echo 'enable_separation_of_powers=false' >> \"\$F\"
    done
    grep -h '^enable_separation_of_powers=' $D/conf/iotdb-system.properties" 2>/dev/null | sed "s/^/  .$h /" | tee -a "$LOG"
done

say "3) 起集群（按进程计数等就绪）"
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 40); do
  n=0
  for h in 77 78 79; do
    c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1)
    n=$(( n + ${c:-0} ))
  done
  [ "${n:-0}" -ge 6 ] && { say "  进程就绪 n=$n"; break; }
  sleep 10
done
sleep 20

say "4) root 登录尝试"
for i in 1 2 3; do
  out=$(try_root)
  echo "  第 $i 次: $out" | tee -a "$LOG"
  printf '%s' "$out" | grep -q '803' || break
  sleep 10
done

say "5) 如仍 803，检查 conf 实际内容与 ConfigNode 是否读到"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "grep -n 'enable_separation_of_powers' $D/conf/iotdb-system.properties; grep -rn 'separation' $D/logs/log_confignode_all.log 2>/dev/null | tail -3" 2>/dev/null | sed 's/^/  /' | tee -a "$LOG"
say "done"
