#!/bin/bash
cd /data/iotdb/autotest/metadata_skill || exit 1
export MD_NO_STOP_AFTER=1
for c in tree/md_tree_database tree/md_tree_view_ttl; do
  n=$(basename "$c")
  echo "##### $n $(date '+%F %T')"
  bash "cases/$c.sh" --skip-lifecycle </dev/null >"results/FIX_${n}.out" 2>&1
  grep -E 'RESULT (PASS|FAIL)' "results/FIX_${n}.out" | tail -1 | sed -E 's/^\[[^]]*\] //'
  grep -E '^\[.*\] FAIL' "results/FIX_${n}.out" | sed -E 's/^\[[^]]*\] //' | head -6
done
echo "FIX DONE $(date '+%F %T')"
