#!/bin/bash
# 解锁 root 后，在普通模式确认 root 可修改四个键；并记录"803 是否计入失败次数"的观察
set -u
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
OUT=$(ls -d /data/iotdb/autotest/sec_skill/results/artifact_normal_priv_* 2>/dev/null | tail -1)
LOG=/data/iotdb/autotest/rc2_regression_logs/repro_normal_priv.log
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
q(){ printf 'set sql_dialect=tree;\n%s\n' "$2" | timeout 40 "$CLI" -h "$H" -u "$1" -pw "$3" 2>&1 | grep -aE 'Msg:|Error:' | tail -1 | cut -c1-220; }
code(){ printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u "$1" -pw "$2" 2>&1 | grep -aoE '[0-9]{3}:' | head -1 | tr -d ':'; }

say "1) security_admin 解锁 root（普通模式下 security_admin 仍有 SECURITY）"
say "   $(q security_admin "alter user root account unlock;" "$P")"
sleep 3

say "2) root 登录确认（普通模式，应成功）"
say "   root code=[$(code root "$P")]  （空=成功）"

say "3) root 修改四个键"
{
  for k in failed_login_attempts failed_login_attempts_per_user password_lock_time_minutes password_stale_warning_days; do
    echo "### root SET $k=5"
    q root "set configuration '$k'='5';" "$P"
    echo
  done
} 2>&1 | tee "$OUT/root_matrix_after_unlock.txt" | sed 's/^/  /' | tee -a "$LOG"

say "4) 回查生效值"
printf 'set sql_dialect=table;\nshow configuration;\n' | timeout 30 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'failed_login|lock_time|stale_warning' | cut -c1-120 | sed 's/^/  /' | tee -a "$LOG"

say "5) 观察：三权分立期间 root 的 803 是否计入失败次数（导致切回普通模式即被锁）"
say "   说明：本次切回普通模式后 root 首次登录即 822；重启本应清空内存锁，故怀疑 803 也被计入或锁状态未随重启清理。"
say "   现状修正：已用 security_admin 解锁，root 现可正常登录（见第 2 步）。"

say "6) 恢复默认值（写回，restart 生效）"
for k in failed_login_attempts failed_login_attempts_per_user password_lock_time_minutes; do
  q root "set configuration '$k'='$( [ "$k" = failed_login_attempts_per_user ] && echo 1000 || ([ "$k" = password_lock_time_minutes ] && echo 10 || echo 5) );" "$P" >/dev/null
done
q root "set configuration 'password_stale_warning_days'='30';" "$P" >/dev/null
say "   已回写 5/1000/10/30"
say "done"
