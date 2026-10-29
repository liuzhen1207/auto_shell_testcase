#!/bin/bash
# 等当前 RC7 param2/scene 官方 runner 跑完 → 接着跑 CO-33（repair）与 CO-34（scale）
# 让新用例在无人值守时也能跑完，结果追加进同一份 results/test_result.csv
# 用法： setsid nohup bash tools/rc7_chain_newcases.sh > /tmp/rc7_chain.log 2>&1 &
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
VER=v20121rc7_1014_7c61428
cd "$S" || exit 1
echo "=== 等待 run_rc7_sets.sh 结束（$(date '+%F %T')）==="
for i in $(seq 1 240); do
  if ! pgrep -f 'run_rc7_sets.sh' >/dev/null 2>&1; then echo "  已结束（等待 $((i-1)) 分钟）"; break; fi
  sleep 60
done
echo "=== [A] CO-33 未排序 TsFile 修复链路 $(date '+%F %T') ==="
bash tools/run_all.sh --set repair --ver "$VER" --consensus IoTConsensus
echo "  repair 集合 rc=$? $(date '+%F %T')"
echo "=== [B] CO-34 千级 TsFile 级联合并压力 $(date '+%F %T') ==="
bash tools/run_all.sh --set scale --ver "$VER" --consensus IoTConsensus
echo "  scale 集合 rc=$? $(date '+%F %T')"
echo "=== 汇总 $(date '+%F %T') ==="
awk -F, 'NR>1{printf "%-6s %-5s %6ss fail=%s\n", $4, $5, $6, $7}' results/test_result.csv | tail -20
echo "=== 全量 CSV ==="; wc -l results/test_result.csv; ls -l results/CO-33_*.out results/CO-34_*.out 2>/dev/null
