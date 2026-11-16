#!/bin/bash
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
L=$A/rc2_regression_logs
say(){ echo "[$(date '+%T')] $*"; }

say "1) 统一校时到 .80 当前时间"
NOW=$(date '+%Y-%m-%d %H:%M:%S')
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "date -s '$NOW' >/dev/null 2>&1; date '+%F %T'" 2>/dev/null | sed "s/^/  .$h /"
done
echo "  .80 $NOW"
sleep 5

say "2) 重启集群"
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -TERM -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 10
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$L/sec_clockfix.log" 2>&1 & )
for i in $(seq 1 40); do
  n=$(printf 'set sql_dialect=table;\nshow cluster;\n' | $CLI -h 192.168.99.77 -u security_admin -pw 'TimechoDB@2021' 2>&1 | grep -c Running)
  [ "${n:-0}" -ge 6 ] && { say "  Running=$n（$((i*10))s）"; break; }
  sleep 10
done

say "3) 密码历史 timeseries 与数据"
printf 'set sql_dialect=tree;\nshow timeseries root.__audit.**;\n' | $CLI -h 192.168.99.77 -u security_admin -pw 'TimechoDB@2021' 2>&1 | grep -aE '^\|' | head -8
printf 'set sql_dialect=tree;\nselect * from root.__audit.password_history._0 limit 5;\n' | $CLI -h 192.168.99.77 -u security_admin -pw 'TimechoDB@2021' 2>&1 | grep -aE '^\|' | head -10
