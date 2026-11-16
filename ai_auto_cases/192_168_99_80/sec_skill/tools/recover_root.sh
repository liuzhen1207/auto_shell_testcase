#!/bin/bash
# 恢复：password_expiration_days=0，enforce_strong_password=true，重启集群
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
L=$A/rc2_regression_logs
LOG=$L/sec_recover.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }

say "1) 三节点写回安全默认配置"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    F=$D/conf/iotdb-system.properties
    for kv in 'enforce_strong_password=true' 'password_expiration_days=0' 'password_reuse_interval_days=0'; do
      k=\${kv%%=*}; sed -i \"/^\$k=/d\" \$F; echo \"\$kv\" >> \$F
    done
    grep -E '^(enforce_strong_password|password_expiration_days|password_reuse_interval_days)=' \$F | tr '\n' ' '; echo
  " 2>/dev/null | sed "s/^/  .$h /" | tee -a "$LOG"
done

say "2) 重启集群（清掉内存里的登录锁状态）"
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -TERM -f 'com\.timecho\.iotdb' || true" >/dev/null 2>&1; done
sleep 10
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 & )
for i in $(seq 1 40); do
  n=$($CLI -h 192.168.99.77 -u root -pw 'TimechoDB@2021' -e "show cluster;" 2>&1 | grep -c Running)
  [ "${n:-0}" -ge 6 ] && { say "集群就绪 Running=$n"; break; }
  sleep 10
done

say "3) 验证 root 可登录 + 三个键的值"
printf 'set sql_dialect=table;\nshow configuration;\n' | $CLI -h 192.168.99.77 -u root -pw 'TimechoDB@2021' 2>&1 \
  | grep -aiE 'enforce_strong_password|password_expiration_days|password_reuse_interval_days' | tee -a "$LOG"
echo "recover_done=$(date '+%F %T')" | tee -a "$LOG"
