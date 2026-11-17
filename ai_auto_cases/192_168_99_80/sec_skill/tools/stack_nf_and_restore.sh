#!/bin/bash
# 抓场景 C 的完整堆栈，然后恢复配置并重启
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
OUT=$(ls -d $A/sec_skill/results/artifact_invalidcfg_* 2>/dev/null | tail -1)
LOG=$A/rc2_regression_logs/repro_invalidcfg.log
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
cnt(){ local h n=0; for h in 77 78 79; do c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1); n=$(( n + ${c:-0} )); done; echo $n; }
setconf(){ local k=$1 v=$2; for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "F=$D/conf/iotdb-system.properties; sed -i '/^$k=/d' \$F; echo '$k=$v' >> \$F" 2>/dev/null
done; }

say "1) 抓场景 C 的 NumberFormatException 完整堆栈（.77 DN 日志）"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "
  L=\$(grep -an 'NumberFormatException' $D/logs/log_datanode_all.log 2>/dev/null | head -1 | cut -d: -f1)
  echo \"  行号=\$L\"
  if [ -n \"\$L\" ]; then
    S=\$((L>40 ? L-40 : 1)); E=\$((L+40))
    sed -n \"\${S},\${E}p\" $D/logs/log_datanode_all.log
  fi" 2>/dev/null | tee "$OUT/stack_numberformat.txt" | sed 's/^/  /' | head -60

say "2) 三节点是否都出现该异常"
for h in 77 78 79; do
  echo -n "  .$h NumberFormatException 计数: " | tee -a "$LOG"
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -ac 'NumberFormatException' $D/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tee -a "$LOG"
done

say "3) 恢复配置并重启集群"
setconf failed_login_attempts 5
setconf failed_login_attempts_per_user 1000
setconf password_lock_time_minutes 10
setconf password_stale_warning_days 30
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 10
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 45); do n=$(cnt); [ "${n:-0}" -ge 6 ] && { say "  就绪 n=$n"; break; }; sleep 10; done
sleep 25
say "4) 恢复后 root 登录与生效值"
printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'Error|root' | head -1 | cut -c1-110 | sed 's/^/  /' | tee -a "$LOG"
printf 'set sql_dialect=table;\nshow configuration;\n' | timeout 30 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'failed_login|lock_time' | cut -c1-120 | sed 's/^/  /' | tee -a "$LOG"
say "done"
