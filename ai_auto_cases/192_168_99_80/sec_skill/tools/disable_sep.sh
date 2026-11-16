#!/bin/bash
set -u
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
run(){ printf 'set sql_dialect=tree;\n%s\n' "$2" | timeout 40 "$CLI" -h "$H" -u "$1" -pw 'TimechoDB@2021' 2>&1 | grep -aE 'Msg:|Error:' | tail -1; }
say(){ echo; echo "===== $* ====="; }

say "1) security_admin 关闭"
run security_admin "set configuration 'enable_separation_of_powers'='false';"
say "2) sys_admin 关闭"
run sys_admin "set configuration 'enable_separation_of_powers'='false';"
say "3) audit_admin 关闭"
run audit_admin "set configuration 'enable_separation_of_powers'='false';"

say "4) root 是否恢复"
run root "list user;"
printf 'set sql_dialect=tree;\nlist user;\n' | timeout 40 "$CLI" -h "$H" -u root -pw 'TimechoDB@2021' 2>&1 | grep -aE 'Error|root|sys_admin' | head -4

say "5) 读回该配置（security_admin）"
printf 'set sql_dialect=table;\nshow configuration;\n' | timeout 40 "$CLI" -h "$H" -u security_admin -pw 'TimechoDB@2021' 2>&1 | grep -aiE 'separation_of_powers' | cut -c1-140
