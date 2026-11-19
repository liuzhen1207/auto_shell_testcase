#!/bin/bash
# B 段跑完 + CO-11 降级修复装好后，自动补跑一次 CO-11 / IoTConsensusV2 作为最终记录
#   [0] 等 rc7_phase_b.sh 退出（B 段 26 条跑完）
#   [1] 等修复哨兵 /tmp/co11_degrade_installed
#   [2] --only CO-11 --consensus IoTConsensusV2 → 归档 test_result_co11_v2_final_*.csv
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
VER=v20121rc7_1014_7c61428
cd "$S" || exit 1
TS() { date '+%F %T'; }

echo "=== [0] 等 B 段（rc7_phase_b.sh）结束（$(TS)）==="
for i in $(seq 1 900); do
  pgrep -f 'rc7_phase[_]b\.sh' >/dev/null 2>&1 || { echo "  B 段已结束（等待 $((i-1)) 分钟）"; break; }
  sleep 60
done

echo "=== [1] 等 CO-11 降级修复哨兵（$(TS)）==="
for i in $(seq 1 120); do
  [ -f /tmp/co11_degrade_installed ] && { echo "  哨兵已出现"; break; }
  sleep 30
done

echo "=== [2] 补跑 CO-11 / IoTConsensusV2（$(TS)）==="
bash tools/run_all.sh --set regression --only CO-11 --ver "$VER" --consensus IoTConsensusV2
echo "  rc=$? $(TS)"
cp -p results/test_result.csv "results/test_result_co11_v2_final_$(date +%Y%m%d_%H%M%S).csv" 2>/dev/null

echo
echo "=== CO-11 三次记录汇总（$(TS)）==="
for f in results/test_result_co11_v1_*.csv results/test_result_co11_v2_*.csv results/test_result_co11_v2_final_*.csv; do
  [ -f "$f" ] || continue
  printf '  %-50s ' "${f##*/}"
  grep -aE ',(CO|DT)-[0-9]+,' "$f" | awk -F, '{printf "%s %ss fail=%s | %s\n", $5, $6, $7, substr($9,1,90)}'
done
