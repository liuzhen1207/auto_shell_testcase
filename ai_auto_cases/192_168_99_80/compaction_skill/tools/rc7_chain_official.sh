#!/bin/bash
# 等 RC7 前置套件（run_rc7_sets.sh + rc7_chain_newcases.sh）全部结束后，
# 跑"按官方软件测试文档补齐"的新用例集合（--set official）。
# 用法： setsid nohup bash tools/rc7_chain_official.sh > /tmp/rc7_official.log 2>&1 &
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
VER=v20121rc7_1014_7c61428
cd "$S" || exit 1
echo "=== 等待前置套件结束（$(date '+%F %T')）==="
for i in $(seq 1 480); do
  busy=0
  pgrep -f 'tools/run_rc7_sets\.sh'      >/dev/null 2>&1 && busy=1
  pgrep -f 'tools/rc7_chain_newcases\.sh' >/dev/null 2>&1 && busy=1
  pgrep -f 'bash tools/run_all\.sh'      >/dev/null 2>&1 && busy=1
  if [ "$busy" = 0 ]; then echo "  前置已结束（等待 $((i-1)) 分钟）"; break; fi
  sleep 60
done
echo "=== [official] 官方覆盖度补齐用例 $(date '+%F %T') ==="
bash tools/run_all.sh --set official --ver "$VER" --consensus IoTConsensus
echo "  official 集合 rc=$? $(date '+%F %T')"
echo "=== 汇总 $(date '+%F %T') ==="
awk -F, 'NR>1{printf "%-6s %-5s %6ss fail=%s\n", $4, $5, $6, $7}' results/test_result.csv | tail -30
echo "=== CSV 总行数 ==="; wc -l results/test_result.csv
ls -l results/SUITE_official_*.out 2>/dev/null | tail -2
