#!/bin/bash
# RC7 两协议完整回归（三段式，自动接力）：
#   [0] 等前置（param2/scene、CO-33/34、official 集合）全部结束
#   [1] IoTConsensus 补齐：CO-01~17 + DT-01~09（26 条）⇒ 52 条 V1 齐全
#   [1.5] IoTConsensus **重跑清单** cases/rerun_v1.txt（首跑失败的用例修好后重跑；清单可在 [1] 期间随时追加）
#   [2] IoTConsensusV2：全部 52 条（--set regression）
# 阶段间轮转 CSV，保证各阶段结果可分离。
# 用法： setsid nohup bash tools/rc7_chain_v2_full.sh > /tmp/rc7_v2.log 2>&1 &
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
VER=v20121rc7_1014_7c61428
cd "$S" || exit 1
TS() { date '+%F %T'; }
TODO="CO-01,CO-02,CO-03,CO-04,CO-05,CO-06,CO-07,CO-08,CO-09,CO-10,CO-11,CO-12,CO-13,CO-14,CO-15,CO-16,CO-17,DT-01,DT-02,DT-03,DT-04,DT-05,DT-06,DT-07,DT-08,DT-09"

echo "=== [0] 等待前置套件结束（$(TS)）==="
for i in $(seq 1 720); do
  busy=0
  pgrep -f 'tools/run_rc7_sets\.sh'       >/dev/null 2>&1 && busy=1
  pgrep -f 'tools/rc7_chain_newcases\.sh' >/dev/null 2>&1 && busy=1
  pgrep -f 'tools/rc7_chain_official\.sh' >/dev/null 2>&1 && busy=1
  pgrep -f 'bash tools/run_all\.sh'       >/dev/null 2>&1 && busy=1
  if [ "$busy" = 0 ]; then echo "  前置已结束（等待 $((i-1)) 分钟）"; break; fi
  sleep 60
done

echo
echo "=== [1] IoTConsensus 补齐 CO-01~17 + DT-01~09（26 条）（$(TS)）==="
cp -p results/test_result.csv "results/test_result_rc7_v1_partial_$(date +%Y%m%d_%H%M%S).csv" 2>/dev/null || true
bash tools/run_all.sh --set regression --only "$TODO" --ver "$VER" --consensus IoTConsensus
echo "  [1] rc=$? $(TS)"
cp -p results/test_result.csv "results/test_result_rc7_v1_full_$(date +%Y%m%d_%H%M%S).csv"

echo
echo "=== [1.5] IoTConsensus 重跑首跑失败项（清单 cases/rerun_v1.txt）（$(TS)）==="
if [ -s cases/rerun_v1.txt ]; then
  LIST=$(grep -v '^[[:space:]]*$' cases/rerun_v1.txt | paste -sd, -)
  echo "  重跑清单：$LIST"
  bash tools/run_all.sh --set regression --only "$LIST" --ver "$VER" --consensus IoTConsensus
  echo "  [1.5] rc=$? $(TS)"
  cp -p results/test_result.csv "results/test_result_rc7_v1_rerun_$(date +%Y%m%d_%H%M%S).csv"
else
  echo "  （清单为空，跳过）"
fi
mv -f results/test_result.csv "results/test_result_rc7_v1_archived_$(date +%Y%m%d_%H%M%S).csv"

echo
echo "=== [2] IoTConsensusV2：全部 52 条（$(TS)）==="
bash tools/run_all.sh --set regression --ver "$VER" --consensus IoTConsensusV2
echo "  [2] rc=$? $(TS)"
cp -p results/test_result.csv "results/test_result_rc7_v2_full_$(date +%Y%m%d_%H%M%S).csv"

echo
echo "=== 汇总 $(TS) ==="
for f in results/test_result_rc7_v1_rerun_*.csv results/test_result_rc7_v2_full_*.csv; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  awk -F, 'NR>1{n++; if($5=="PASS")p++; else if($5=="FAIL")f++} END{printf "  共%d  PASS=%d FAIL=%d\n", n, p, f}' "$f"
  awk -F, 'NR>1 && $5=="FAIL"{printf "  FAIL %-6s fail=%s %s\n", $4, $7, substr($9,1,90)}' "$f"
done
ls -l results/test_result_rc7_*.csv | tail -8
