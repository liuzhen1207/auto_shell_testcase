#!/bin/bash
set -u
V=v20131rc2_1110_83183d0
CLI=/data/iotdb/testdb/$V/sbin/start-cli.sh
H=192.168.99.77
P=TimechoDB@2021
echo "== 1) 解除 root 的登录锁定（security_admin 有 SECURITY）=="
printf 'set sql_dialect=tree;\nalter user root account unlock;\n' | timeout 40 "$CLI" -h $H -u security_admin -pw "$P" 2>&1 | grep -aE 'Msg|Error' | tail -1 | cut -c1-140
echo "== 2) root 登录（三权分立应为 803）=="
printf 'set sql_dialect=tree;\nlist user;\n' | timeout 30 "$CLI" -h $H -u root -pw "$P" 2>&1 | grep -aE 'Error|root' | head -1 | cut -c1-120
echo "== 3) 复核：普通用户解锁仍是 803、日志无新增 NPE =="
printf 'set sql_dialect=tree;\ndrop user sfin;\ncreate user sfin %s;\n' "'Abcdefgh123!'" | timeout 40 "$CLI" -h $H -u security_admin -pw "$P" >/dev/null 2>&1
printf 'set sql_dialect=tree;\nalter user sfin account unlock;\n' | timeout 40 "$CLI" -h $H -u sfin -pw 'Abcdefgh123!' 2>&1 | grep -aE 'Msg|Error' | tail -1 | cut -c1-160
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "grep -ac 'Cannot read the array length' /data/iotdb/$V/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | sed 's/^/  NPE 计数: /'
printf 'set sql_dialect=tree;\ndrop user sfin;\n' | timeout 40 "$CLI" -h $H -u security_admin -pw "$P" >/dev/null 2>&1
echo "done"
