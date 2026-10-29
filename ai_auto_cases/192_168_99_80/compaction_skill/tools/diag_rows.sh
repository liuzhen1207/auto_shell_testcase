#!/bin/bash
# 诊断：各副本可见行数 / seq-unseq 文件数 / sync lag
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd $S || exit 1
. $S/lib/common.sh; . $S/lib/cmp.sh
cmp_load_env
DB=${1:-root.colevelg}
for h in "${DN[@]}"; do
  echo "=== $h ==="
  echo "  rows=$(row_sum "$(sq_node "$h" "select count(s1) from $DB.**;")")"
  echo "  seq=$(cmp_seq_cnt "$h" "$DB") unseq=$(cmp_unseq_cnt "$h" "$DB")"
done
echo "=== sync lag ==="
sync_lag_scan | tail -8
