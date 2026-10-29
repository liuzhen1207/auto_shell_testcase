#!/bin/bash
# 诊断脚本：在 99.80 上运行，打印 3 个 DN 上某库的 TsFile 布局 + 压缩日志尾部 + 压缩线程状态
# 用法： bash /tmp/probe_lvl_inspect.sh [db_pattern] [ver]
set -u
DBPAT=${1:-probegap}
VER=${2:-v20121rc6_1010_7ae8713e}
V=/data/iotdb/$VER
for h in 77 78 79; do
  echo "===== node $h ====="
  ssh -o StrictHostKeyChecking=no root@192.168.99.$h "bash -s" <<EOF
V=$V
DBPAT=$DBPAT
date '+%F %T'
echo '-- files --'
find \$V/data/datanode/data -path "*\$DBPAT*" -name '*.tsfile' | sed 's|.*/data/||' | sort
echo '-- compaction log tail --'
tail -5 \$V/logs/log_datanode_compaction.log | cut -c1-170
echo '-- finishes total --'
grep -c 'finishes successfully' \$V/logs/log_datanode_compaction.log
echo '-- last ERROR/Exception in compaction log --'
grep -nE 'ERROR|Exception' \$V/logs/log_datanode_compaction.log | tail -4 | cut -c1-200
echo '-- compaction worker threads --'
PID=\$(pgrep -f 'DataNode' | head -1)
if [ -n "\$PID" ]; then
  jstack \$PID 2>/dev/null | grep -A6 'IoTDB-Compaction' | head -60
fi
EOF
done
