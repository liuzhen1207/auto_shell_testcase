#!/bin/bash
# 诊断：某库在各副本上的文件与 close 事件、以及各副本可见行数
V=/data/iotdb/v20121rc6_1010_7ae8713e
DB=${1:-root.colevelg}
CLI=$V/sbin/start-cli.sh
for h in 77 78 79; do
  echo "===== node $h ====="
  ssh -o StrictHostKeyChecking=no root@192.168.99.$h "grep 'Async close tsfile' $V/logs/log_datanode_all.log | grep $DB | tail -3 | cut -c1-190; echo '  files:'; find $V/data/datanode/data -path '*$DB*' -name '*.tsfile' -printf '    %f %s\n' | sort"
  echo -n "  rows via $h: "
  $CLI -h 192.168.99.$h -u root -pw 'TimechoDB@2021' -e "select count(s1) from $DB.**;" 2>/dev/null | grep -E '^\|' | tail -1 | cut -c1-70
done
