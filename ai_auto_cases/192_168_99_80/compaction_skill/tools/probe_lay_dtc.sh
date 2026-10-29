#!/bin/bash
# 打印各 DN 上 root.dtc 的 TsFile 文件名（判断 level/seq-unseq 命名与布局），以及按库的 seq/unseq 目录
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
. "$HERE/../lib/cmp.sh"
cmp_load_env
DB=${1:-root.dtc}
for h in "${DN[@]}"; do
  echo "=== $h ==="
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile' | sort" 2>/dev/null | sed 's|.*/data/datanode/data/||' | sed 's/^/  /'
  echo "  --- seq/unseq 计数 ---"
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$DB/sequential/*' -name '*.tsfile' | wc -l; find $DB_DIR/data/datanode/data -path '*/$DB/unsequence/*' -name '*.tsfile' | wc -l" 2>/dev/null | sed 's/^/  /'
done
echo "=== 该库 inner compaction 最近日志（每节点 5 条）==="
for h in "${DN[@]}"; do
  echo "--- $h ---"
  sshx "$h" "grep -a 'root.dtc' $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null | tail -5" 2>/dev/null | cut -c1-200 | sed 's/^/  /'
done
