#!/bin/bash
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
VER=v20121rc7_1014_7c61428
cd "$S" || exit 1
V2LIST="CO-18,CO-19,CO-20,CO-21,CO-22,CO-23,CO-24,CO-25,CO-26,CO-27,CO-28,CO-29,CO-30,CO-31,CO-32,CO-33,CO-34,CO-35,CO-36,CO-37,CO-38,CO-39,CO-40,CO-41,CO-42,CO-43"
echo "=== [B-restart] IoTConsensusV2 从 CO-18 续跑（$(date '+%F %T')）==="
rm -f results/test_result.csv
bash tools/run_all.sh --set regression --only "$V2LIST" --ver "$VER" --consensus IoTConsensusV2
echo "  [B] rc=$? $(date '+%F %T')"
cp -p results/test_result.csv "results/test_result_rc7_v2_resume_$(date +%Y%m%d_%H%M%S).csv" 2>/dev/null
echo "=== 汇总 ==="
grep -aE ',(CO|DT)-[0-9]+,' results/test_result.csv | awk -F, '{printf "  %-6s %-5s %5ss fail=%s\n", $4,$5,$6,$7}'
