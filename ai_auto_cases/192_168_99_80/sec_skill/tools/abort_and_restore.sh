#!/bin/bash
# 中止当前 suite，回退时钟，重启集群，恢复 expiry=0
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
L=$A/rc2_regression_logs
: >"$L/sec_abort.log"
say(){ echo "[$(date '+%T')] $*" | tee -a "$L/sec_abort.log"; }

say "1) 杀掉正在跑的 suite 与用例"
pkill -f 'tools/run_all.sh --set all' 2>/dev/null || true
pkill -f 'sec_password_expire.sh' 2>/dev/null || true
sleep 3

say "2) 检查并回退时钟（若已前移）"
for h in 77 78 79; do
  echo -n "  .$h 当前: "; ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "date '+%F %T'" 2>/dev/null
done
echo -n "  .80 当前: "; date '+%F %T'
# 若节点时间比 .80 快 2 天以上，则回退 3 天
ref=$(date +%s)
for h in 77 78 79; do
  t=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "date +%s" 2>/dev/null | tr -dc '0-9')
  diff=$(( (${t:-$ref} - ref) / 86400 ))
  if [ "$diff" -ge 2 ]; then
    say "  .$h 快 ${diff} 天 → 回退 3 天"
    ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "date -s \"\$(date -d '-3 days' '+%Y-%m-%d %H:%M:%S')\" >/dev/null 2>&1; date '+%F %T'" 2>/dev/null | sed "s/^/    /"
  fi
done

say "3) 恢复 expiry=0 并重启集群"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    F=$D/conf/iotdb-system.properties
    for kv in 'password_expiration_days=0' 'password_reuse_interval_days=0' 'enforce_strong_password=true'; do
      k=\${kv%%=*}; sed -i \"/^\$k=/d\" \$F; echo \"\$kv\" >> \$F
    done" 2>/dev/null
done
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -TERM -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 10
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$L/sec_abort.log" 2>&1 & )
for i in $(seq 1 40); do
  n=$(printf 'set sql_dialect=table;\nshow cluster;\n' | $CLI -h 192.168.99.77 -u security_admin -pw 'TimechoDB@2021' 2>&1 | grep -c Running)
  [ "${n:-0}" -ge 6 ] && { say "集群就绪 Running=$n"; break; }
  sleep 10
done
say "abort_done"
