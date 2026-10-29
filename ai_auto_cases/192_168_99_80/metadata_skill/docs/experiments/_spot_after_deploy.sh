#!/bin/bash
# 从交付目录重新部署后的定点复跑（含一条 P4 用例）
cd /data/iotdb/autotest/metadata_skill || exit 1
export MD_NO_STOP_AFTER=1
for c in tree/md_tree_database common/md_privilege_matrix common/md_udf_trigger; do
  n=$(basename "$c")
  echo "########## $n $(date '+%F %T') ##########"
  bash "cases/$c.sh" --skip-lifecycle </dev/null >"results/SPOT_${n}.out" 2>&1
  grep -E 'RESULT (PASS|FAIL)' "results/SPOT_${n}.out" | tail -1 | sed -E 's/^\[[^]]*\] //'
  grep -E '^\[.*\] FAIL' "results/SPOT_${n}.out" | sed -E 's/^\[[^]]*\] //' | head -5
done
echo "SPOT DONE $(date '+%F %T')"
