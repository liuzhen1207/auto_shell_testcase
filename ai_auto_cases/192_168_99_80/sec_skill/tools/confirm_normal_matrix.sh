#!/bin/bash
# 清库重建 → 普通模式 → root 修改四个键的确认矩阵
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%Y%m%d_%H%M%S')
OUT=$A/sec_skill/results/artifact_normal_confirm_$TS
LOG=$A/rc2_regression_logs/confirm_normal_matrix.log
mkdir -p "$OUT"; : >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
cnt(){ local h n=0; for h in 77 78 79; do c=$(ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null | tr -dc '0-9' | head -1); n=$(( n + ${c:-0} )); done; echo $n; }
q(){ printf 'set sql_dialect=tree;\n%s\n' "$2" | timeout 40 "$CLI" -h "$H" -u "$1" -pw "$3" 2>&1 | grep -aE 'Msg:|Error:' | tail -1 | cut -c1-220; }

say "1) 停集群 + 清 data/logs + 写普通模式默认配置"
for h in 77 78 79; do ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "pkill -9 -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done
sleep 12
for h in 77 78 79; do
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
    rm -rf $D/data $D/logs; mkdir -p $D/logs
    F=$D/conf/iotdb-system.properties
    for kv in 'enable_separation_of_powers=false' 'failed_login_attempts=5' 'failed_login_attempts_per_user=1000' 'password_lock_time_minutes=10' 'password_stale_warning_days=30'; do
      k=\${kv%%=*}; sed -i \"/^\$k=/d\" \$F; echo \"\$kv\" >> \$F
    done" 2>/dev/null
done
say "  已清库"

say "2) 启动"
( cd "$A" && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$LOG" 2>&1 </dev/null & )
for i in $(seq 1 45); do n=$(cnt); [ "${n:-0}" -ge 6 ] && { say "  就绪 n=$n"; break; }; sleep 10; done
sleep 30

say "3) root 登录确认（普通模式）"
for i in 1 2 3; do
  r=$(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'Error|root' | head -1 | cut -c1-110)
  say "  第 $i 次: $r"
  printf '%s' "$r" | grep -qE '803|822' || break
  sleep 12
done

say "4) 确认矩阵：root 修改四个键（普通模式）"
{
  for k in failed_login_attempts failed_login_attempts_per_user password_lock_time_minutes password_stale_warning_days; do
    echo "### root SET $k=5"
    q root "set configuration '$k'='5';" "$P"
    echo
  done
} 2>&1 | tee "$OUT/root_matrix.txt" | sed 's/^/  /' | tee -a "$LOG"

say "5) 对照：security_admin / sys_admin / audit_admin（普通模式下）"
for u in security_admin sys_admin audit_admin; do
  say "  $u SET failed_login_attempts=5 → $(q "$u" "set configuration 'failed_login_attempts'='5';" "$P")"
done
for u in security_admin sys_admin audit_admin; do
  say "  $u SET password_stale_warning_days=30 → $(q "$u" "set configuration 'password_stale_warning_days'='30';" "$P")"
done

say "6) 生效值回查"
printf 'set sql_dialect=table;\nshow configuration;\n' | timeout 30 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'failed_login|lock_time|stale_warning' | cut -c1-120 | sed 's/^/  /' | tee -a "$LOG"

say "7) 恢复默认值"
q root "set configuration 'failed_login_attempts'='5';" "$P" >/dev/null
q root "set configuration 'failed_login_attempts_per_user'='1000';" "$P" >/dev/null
q root "set configuration 'password_lock_time_minutes'='10';" "$P" >/dev/null
q root "set configuration 'password_stale_warning_days'='30';" "$P" >/dev/null
say "  已回写 5/1000/10/30"
tar czf "$OUT/bundle.tgz" -C "$OUT" . 2>/dev/null
say "  产物: $OUT"
say "done"
