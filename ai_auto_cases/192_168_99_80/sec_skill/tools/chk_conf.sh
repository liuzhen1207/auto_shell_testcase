#!/bin/bash
set -u
V=v20131rc2_1110_83183d0
D=/data/iotdb/$V
for h in 77 78 79; do
  echo "== .$h =="
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "grep -n 'enable_separation_of_powers' $D/conf/iotdb-system.properties; echo '-- 出现次数:'; grep -c '^enable_separation_of_powers=' $D/conf/iotdb-system.properties; echo '-- 其它 conf 文件:'; grep -rln 'enable_separation_of_powers' $D/conf/ 2>/dev/null" 2>/dev/null | sed 's/^/  /'
done
echo
echo "== .77 进程 =="
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null
