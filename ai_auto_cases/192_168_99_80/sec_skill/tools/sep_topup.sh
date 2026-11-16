#!/bin/bash
# 1) 热开三权分立 → 跑 SEC-01/SEC-09(sep) → 2) 重建回普通模式
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
S=$A/sec_skill
LOG=$A/rc2_regression_logs/sec_sep_topup.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
count(){ local h n=0; for h in 77 78 79; do
  c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1)
  n=$(( n + ${c:-0} )); done; echo $n; }

say "1) 热开三权分立（root SET CONFIGURATION）"
printf 'set sql_dialect=tree;\nset configuration %s=%s;\n' "'enable_separation_of_powers'" "'true'" \
  | timeout 60 "$CLI" -h 192.168.99.77 -u root -pw 'TimechoDB@2021' 2>&1 | grep -aE 'Msg|Error' | tail -1 | tee -a "$LOG"
sleep 8
say "  security_admin 可用性: $(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 30 "$CLI" -h 192.168.99.77 -u security_admin -pw 'TimechoDB@2021' 2>&1 | grep -ac security_admin)"

say "2) 跑 SEC-01 / SEC-09（sep）"
( cd "$S" && bash tools/run_all.sh --only SEC-01,SEC-09 --mode sep ) >>"$LOG" 2>&1
grep -a 'RESULT ' "$LOG" | tail -4 | cut -c1-150 | tee -a "$LOG"

say "3) 重建回普通模式（清 data）"
pkill -f 'run_all.sh' 2>/dev/null || true
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -TERM -f 'com.timecho.iotdb' || true; sleep 3; pkill -9 -f 'com.timecho.iotdb' || true; rm -rf $D/data $D/logs; mkdir -p $D/logs
  F=$D/conf/iotdb-system.properties
  sed -i '/^enable_separation_of_powers=/d' \$F; echo 'enable_separation_of_powers=false' >> \$F" >/dev/null 2>&1; done
sleep 8
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 40); do n=$(count); [ "${n:-0}" -ge 6 ] && break; sleep 10; done
sleep 20
say "  root 登录: $(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 30 "$CLI" -h 192.168.99.77 -u root -pw 'TimechoDB@2021' 2>&1 | grep -aE 'Error|root' | head -1)"
say "topup_done"
