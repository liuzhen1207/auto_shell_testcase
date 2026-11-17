#!/bin/bash
set -u
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
run(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | timeout 40 "$CLI" -h "$H" -u root -pw "$P" 2>&1 | grep -aE 'Msg:|Error:' | tail -1; }

echo "== 1) SET password_stale_warning_days=31 的返回（关键看有无 restart is required）=="
run "set configuration 'password_stale_warning_days'='31';"
echo
echo "== 2) 对照：SET 一个明确 restart-only 的键（failed_login_attempts）=="
run "set configuration 'failed_login_attempts'='5';"
echo
echo "== 3) 回查生效值（无需重启即可见）=="
printf 'set sql_dialect=table;\nshow configuration;\n' | timeout 30 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'password_stale_warning_days|failed_login_attempts' | cut -c1-120
echo
echo "== 4) 恢复 30 =="
run "set configuration 'password_stale_warning_days'='30';"
