#!/bin/bash
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
VER=v20121rc7_1014_7c61428
cd "$S" || exit 1
echo "=== 等 CO-11 降级修复哨兵（$(date '+%F %T')）==="
for i in $(seq 1 240); do [ -f /tmp/co11_degrade_installed ] && break; sleep 30; done
echo "=== 等 B 段结束 ==="
for i in $(seq 1 900); do pgrep -f 'rc7_v2_resume[_]b\.sh' >/dev/null 2>&1 || break; sleep 60; done
echo "=== 补跑 CO-11 / IoTConsensusV2（$(date '+%F %T')）==="
bash tools/run_all.sh --set regression --only CO-11 --ver "$VER" --consensus IoTConsensusV2
cp -p results/test_result.csv "results/test_result_co11_v2_final_$(date +%Y%m%d_%H%M%S).csv" 2>/dev/null
grep -aE ',CO-11,' results/test_result.csv | awk -F, '{printf "  CO-11 %s %ss fail=%s | %s\n", $5,$6,$7,substr($9,1,100)}'
