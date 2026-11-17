#!/bin/bash
# 切回普通模式并确认 root 可修改四个键（含 security_admin 对照）
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%Y%m%d_%H%M%S')
OUT=$A/sec_skill/results/artifact_normal_priv_$TS
LOG=$A/rc2_regression_logs/repro_normal_priv.log
mkdir -p "$OUT"; : >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
cnt(){ local h n=0; for h in 77 78 79; do c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1); n=$(( n + ${c:-0} )); done; echo $n; }
q(){ printf 'set sql_dialect=tree;\n%s\n' "$2" | timeout 40 "$CLI" -h "$H" -u "$1" -pw "$3" 2>&1 | grep -aE 'Msg:|Error:' | tail -1 | cut -c1-220; }

say "1) 写 conf：separation=false（三节点）"
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    F=$D/conf/iotdb-system.properties
    sed -i '/^enable_separation_of_powers=/d' \$F
    echo 'enable_separation_of_powers=false' >> \$F
    grep -h '^enable_separation_of_powers=' \$F" 2>/dev/null | sed "s/^/  .$h /" | tee -a "$LOG"
done

say "2) 重启集群"
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 10
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 45); do n=$(cnt); [ "${n:-0}" -ge 6 ] && { say "  进程就绪 n=$n"; break; }; sleep 10; done
sleep 30

say "3) 模式确认（root 应可登录 = 普通模式）"
for i in 1 2 3; do
  r=$(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'Error|root' | head -1 | cut -c1-110)
  say "  第 $i 次: $r"
  printf '%s' "$r" | grep -q '803\|822' || break
  sleep 12
done

say "4) 普通模式权限矩阵：root 修改四个键"
{
  for k in failed_login_attempts failed_login_attempts_per_user password_lock_time_minutes password_stale_warning_days; do
    echo "### root SET $k=5"
    q root "set configuration '$k'='5';" "$P"
    echo
  done
} 2>&1 | tee "$OUT/root_matrix.txt" | sed 's/^/  /' | tee -a "$LOG"

say "5) 对照：普通模式下 security_admin 改锁定键"
say "  security_admin SET failed_login_attempts=5 → $(q security_admin "set configuration 'failed_login_attempts'='5';" "$P")"
say "  security_admin SET password_stale_warning_days=30 → $(q security_admin "set configuration 'password_stale_warning_days'='30';" "$P")"

say "6) 生效值回查（root）"
printf 'set sql_dialect=table;\nshow configuration;\n' | timeout 30 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'failed_login|lock_time|stale_warning' | cut -c1-120 | sed 's/^/  /' | tee -a "$LOG"

tar czf "$OUT/bundle.tgz" -C "$OUT" . 2>/dev/null
say "  产物目录: $OUT"
say "done"
