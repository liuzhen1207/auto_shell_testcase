#!/bin/bash
set -u
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
sec(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | $CLI -h "$H" -u security_admin -pw 'TimechoDB@2021' 2>&1; }
say(){ echo; echo "===== $* ====="; }

say "1) 清理探针遗留用户"
sec "list user;" | grep -aE '^\| *[0-9]+\|' | awk -F'|' '{gsub(/ /,"",$3); print $3}' | while read -r u; do
  case "$u" in
    ''|root|sys_admin|security_admin|audit_admin|UserId) continue ;;
  esac
  echo -n "  drop $u: "; sec "drop user $u;" | grep -aE 'successfully|Error' | head -1
done

say "2) 清理后用户列表"
sec "list user;" | tail -8

say "3) 三个管理员的权限画像（SECURITY / SYSTEM / AUDIT）"
for u in sys_admin security_admin audit_admin; do
  echo -n "  $u 的权限: "
  printf 'set sql_dialect=tree;\nlist privileges of user %s;\n' "$u" | $CLI -h "$H" -u security_admin -pw 'TimechoDB@2021' 2>&1 | tail -3 | tr '\n' ' ' | cut -c1-160
  echo
done
