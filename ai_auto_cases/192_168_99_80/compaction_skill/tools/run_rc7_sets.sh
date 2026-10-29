#!/bin/bash
# RC7：用**官方 runner** 跑 --set param2 与 --set scene，留一份自包含的全量 CSV
#   - 先把既有 test_result.csv（RC6 + DT 批历史）归档为 test_result_rc6_plus_dt.csv
#   - 再让 run_all.sh 写一份**只含 RC7 这两个集合**的新 CSV
# 用法（99.80）： setsid nohup bash tools/run_rc7_sets.sh > /tmp/rc7_sets.log 2>&1 &
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
VER=v20121rc7_1014_7c61428
cd "$S" || exit 1
CSV=results/test_result.csv
STAMP=$(date +%Y%m%d_%H%M%S)

echo "=== [1] 归档既有 CSV（$(date '+%F %T')）==="
if [ -f "$CSV" ]; then
  cp -p "$CSV" "results/test_result_rc6_plus_dt_${STAMP}.csv"
  mv -f "$CSV" "results/test_result_rc6_plus_dt_latest.csv"
  echo "  已归档：results/test_result_rc6_plus_dt_latest.csv（$(wc -l <results/test_result_rc6_plus_dt_latest.csv) 行）"
fi

echo
echo "=== [2] --set param2（CO-18..26, CO-32）build=$VER $(date '+%F %T') ==="
bash tools/run_all.sh --set param2 --ver "$VER" --consensus IoTConsensus
echo "  param2 rc=$? $(date '+%F %T')"

echo
echo "=== [3] --set scene（CO-27..31）build=$VER $(date '+%F %T') ==="
bash tools/run_all.sh --set scene --ver "$VER" --consensus IoTConsensus
echo "  scene rc=$? $(date '+%F %T')"

echo
echo "=== [4] 汇总（$(date '+%F %T')）==="
cp -p "$CSV" "results/test_result_rc7_param2_scene_${STAMP}.csv" 2>/dev/null || true
echo "--- RC7 param2+scene 结果行 ---"
awk -F, 'NR>1{printf "%-6s %-5s %6s s  fail=%s\n", $4, $5, $6, $7}' "$CSV" 2>/dev/null
echo "--- PASS/FAIL 统计 ---"
awk -F, 'NR>1{n++; if($5=="PASS")p++; else f++} END{printf "PASS=%d FAIL=%d 共%d\n", p, f, n}' "$CSV" 2>/dev/null
echo "--- 新 CSV ---"; ls -l results/test_result_rc7_param2_scene_${STAMP}.csv
echo "=== 完成 $(date '+%F %T') ==="
