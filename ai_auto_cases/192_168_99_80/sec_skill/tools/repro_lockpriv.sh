#!/bin/bash
# 干净环境：三权分立下"安全管理员改不了锁定配置"复现 + 取证
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
TS=$(date '+%Y%m%d_%H%M%S')
OUT=$A/sec_skill/results/artifact_lockpriv_$TS
LOG=$A/rc2_regression_logs/repro_lockpriv.log
mkdir -p "$OUT"; : >"$LOG"
say(){ echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
q(){ printf 'set sql_dialect=tree;\n%s\n' "$2" | timeout 40 "$CLI" -h "$H" -u "$1" -pw "$3" 2>&1 | grep -aE 'Msg:|Error:' | tail -1 | cut -c1-230; }
qraw(){ printf 'set sql_dialect=tree;\n%s\n' "$2" | timeout 40 "$CLI" -h "$H" -u "$1" -pw "$3" 2>&1; }

say "0) 当前模式（root 803 表示 sep）"
say "   root: $(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aoE '803' | head -1)"
say "1) 若为普通模式，用 root 热开三权分立"
if ! printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -q 803; then
  say "   set sep: $(q root "set configuration 'enable_separation_of_powers'='true';" "$P")"
  sleep 8
fi
say "   root 现在: $(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 25 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aoE '803' | head -1)"

say "2) 权限矩阵（三权分立）"
for k in failed_login_attempts failed_login_attempts_per_user password_lock_time_minutes password_stale_warning_days; do
  say "  2.1 security_admin SET $k=5  → $(q security_admin "set configuration '$k'='5';" "$P")"
done
say "  2.2 sys_admin SET failed_login_attempts=5        → $(q sys_admin "set configuration 'failed_login_attempts'='5';" "$P")"
say "  2.3 sys_admin SET password_stale_warning_days=30 → $(q sys_admin "set configuration 'password_stale_warning_days'='30';" "$P")"
say "  2.4 audit_admin SET failed_login_attempts=5      → $(q audit_admin "set configuration 'failed_login_attempts'='5';" "$P")"

say "3) show configuration 是否也受 SYSTEM 限制"
say "  3.1 security_admin show configuration → $(printf 'set sql_dialect=table;\nshow configuration;\n' | timeout 30 "$CLI" -h $H -u security_admin -pw "$P" 2>&1 | grep -aE 'Error|failed_login|password_stale' | head -2 | cut -c1-200 | tr '\n' ' ')"
say "  3.2 sys_admin show configuration      → $(printf 'set sql_dialect=table;\nshow configuration;\n' | timeout 30 "$CLI" -h $H -u sys_admin -pw "$P" 2>&1 | grep -aE 'failed_login|password_stale' | head -2 | cut -c1-120 | tr '\n' ' ')"

say "4) 保存原始输出与日志取证"
{
  echo "=== security_admin: set failed_login_attempts ==="
  qraw security_admin "set configuration 'failed_login_attempts'='5';" "$P"
  echo
  echo "=== security_admin: set password_stale_warning_days（对照，有 Privilege: SECURITY）==="
  qraw security_admin "set configuration 'password_stale_warning_days'='30';" "$P"
  echo
  echo "=== sys_admin: set failed_login_attempts ==="
  qraw sys_admin "set configuration 'failed_login_attempts'='5';" "$P"
} > "$OUT/cli_matrix.txt" 2>&1
say "  已保存 $OUT/cli_matrix.txt"

say "5) DN/CN 日志中与权限拒绝相关的行（近 5 分钟）"
for h in 77 78 79; do
  for f in log_datanode_all.log log_confignode_all.log; do
    ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "
      grep -aE 'No permissions for this operation|privilege SYSTEM|checkUserMissingSystemPermissions|CONFIG' $D/logs/$f 2>/dev/null | tail -6 | cut -c1-200" 2>/dev/null | sed "s#^#  .$h/$f: #" | tee -a "$OUT/logs_hits.txt" | head -12
  done
done
say "  已保存 $OUT/logs_hits.txt（若有内容）"

say "6) 模板注解取证（判定依据）"
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "
  echo '--- failed_login_attempts 注解块 ---'
  L=\$(grep -n '^failed_login_attempts=' $D/conf/iotdb-system.properties.template | cut -d: -f1); sed -n \"\$((L-7)),\${L}p\" $D/conf/iotdb-system.properties.template
  echo '--- password_stale_warning_days 注解块 ---'
  L=\$(grep -n '^password_stale_warning_days=' $D/conf/iotdb-system.properties.template | cut -d: -f1); sed -n \"\$((L-6)),\${L}p\" $D/conf/iotdb-system.properties.template" 2>/dev/null | tee "$OUT/template_annot.txt" | sed 's/^/  /' | tee -a "$LOG"

tar czf "$OUT/bundle_lockpriv.tgz" -C "$OUT" . 2>/dev/null
say "  产物目录: $OUT"
say "done"
