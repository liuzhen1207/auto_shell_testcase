#!/bin/bash
# 用**文档里的正式入口**跑 DT 批（dtype + ha），产出原生 DT-xx 结果行
#   用法（99.80）： setsid nohup bash tools/run_dt_suite.sh > /tmp/dt_suite.log 2>&1 &
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd "$S" || exit 1
echo "=== DT 套件开始 $(date '+%F %T') ==="
for set in dtype ha; do
  echo ""
  echo "########## --set $set  $(date '+%F %T') ##########"
  bash tools/run_all.sh --set "$set" --consensus IoTConsensus
  echo "########## --set $set 结束 rc=$? $(date '+%F %T') ##########"
done
echo ""
echo "=== DT 套件结束 $(date '+%F %T') ==="
echo "--- 本次产生的 DT 结果行 ---"
grep -aE '^[^,]*,[^,]*,[^,]*,DT-0[0-9],' results/test_result.csv | tail -12
echo "--- SUITE 汇总 ---"
ls -t results/SUITE_*_*.out | head -3
for f in $(ls -t results/SUITE_*_*.out | head -2); do echo "== $f"; tail -3 "$f"; done
