#!/bin/bash
# 重建为普通模式：停集群 → 清 data（保留 conf/activation）→ 起集群 → 验证 root → 跑普通模式全量
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
LOG=$A/rc2_regression_logs/sec_normal_rebuild.log
: >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
count(){ local h n=0; for h in 77 78 79; do
  c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1)
  n=$(( n + ${c:-0} )); done; echo $n; }

say "1) 停用例与集群"
pkill -f 'run_all.sh --set' 2>/dev/null || true
pkill -f 'cases/.*/sec_' 2>/dev/null || true
sleep 2
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -TERM -f 'com.timecho.iotdb' || true; sleep 3; pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 8
say "  残留进程=$(count)"

say "2) 清 data（保留 conf 与 activation）"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "rm -rf $D/data $D/logs; mkdir -p $D/logs" 2>/dev/null
  echo "  .$h 已清 data" | tee -a "$LOG"
done

say "3) conf 强制 separation=false + 安全默认"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    F=$D/conf/iotdb-system.properties
    for kv in 'enable_separation_of_powers=false' 'enforce_strong_password=true' 'password_expiration_days=0' 'password_reuse_interval_days=0'; do
      k=\${kv%%=*}; sed -i \"/^\$k=/d\" \$F; echo \"\$kv\" >> \$F
    done" 2>/dev/null
done

say "4) 起集群"
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 45); do
  n=$(count); say "  轮 $i 进程数=$n"
  [ "${n:-0}" -ge 6 ] && break
  sleep 10
done
sleep 25

say "5) root 登录验证"
for i in 1 2 3; do
  out=$(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h 192.168.99.77 -u root -pw 'TimechoDB@2021' 2>&1 | grep -aE 'Error|root' | head -2)
  echo "  第 $i 次: $out" | tee -a "$LOG"
  printf '%s' "$out" | grep -q 803 || break
  sleep 15
done

say "6) 普通模式全量"
( cd "$A/sec_skill" && bash tools/run_all.sh --set all --mode normal ) >>"$LOG" 2>&1
say "  完成"
grep -a 'RESULT ' "$LOG" | tail -12 | cut -c1-140 | tee -a "$LOG"
say "rebuild_done"
