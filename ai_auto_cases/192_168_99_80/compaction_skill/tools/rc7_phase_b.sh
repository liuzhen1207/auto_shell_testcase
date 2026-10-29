#!/bin/bash
# ============================================================================
# RC7 收尾编排（用户 2026-10-16 决定："按建议来"）
#   [0] 等哨兵 /tmp/fixes_installed（CO-11 / CO-14 修复装完才启动，防抢跑）
#   [A] 定向复跑，彻底给 CO-11 / CO-14 结案：
#       A1 CO-11 V1（IoTConsensus）
#       A2 CO-11 V2（IoTConsensusV2）
#       A3 CO-14 V2（IoTConsensusV2）
#       A4 CO-14 **RC6 V2 对照**（--ver v20121rc6_1010_7ae8713e，判「.77 全程不 close」是否 RC7 新引入）
#   [B] V2 长回归**从 CO-18 续跑**（前 17 条已完成的沿用），跑完归档
# 用法： setsid nohup bash tools/rc7_phase_b.sh > /tmp/rc7_phaseb.log 2>&1 &
# ============================================================================
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
VER=v20121rc7_1014_7c61428
RC6VER=v20121rc6_1010_7ae8713e
cd "$S" || exit 1
TS() { date '+%F %T'; }
CSV=results/test_result.csv
V2LIST="CO-18,CO-19,CO-20,CO-21,CO-22,CO-23,CO-24,CO-25,CO-26,CO-27,CO-28,CO-29,CO-30,CO-31,CO-32,CO-33,CO-34,CO-35,CO-36,CO-37,CO-38,CO-39,CO-40,CO-41,CO-42,CO-43"

echo "=== [0] 等修复装机哨兵（$(TS)）==="
for i in $(seq 1 240); do
  [ -f /tmp/fixes_installed ] && { echo "  哨兵已出现（等待 $((i-1)) 次）"; break; }
  sleep 30
done
[ -f /tmp/fixes_installed ] || { echo "  ！哨兵超时（2h），退出"; exit 1; }

stamp() { date +%Y%m%d_%H%M%S; }
rotate() { # rotate <名字>
  [ -f "$CSV" ] && mv -f "$CSV" "results/test_result_$1_$(stamp).csv"
  return 0
}

echo
echo "=== [A] 定向复跑（$(TS)）==="
rotate "before_targeted"

echo "--- A1 CO-11 / IoTConsensus ---"
bash tools/run_all.sh --set regression --only CO-11 --ver "$VER" --consensus IoTConsensus; echo "  A1 rc=$?"
cp -p "$CSV" "results/test_result_co11_v1_$(stamp).csv" 2>/dev/null; rotate "after_co11_v1"

echo "--- A2 CO-11 / IoTConsensusV2 ---"
bash tools/run_all.sh --set regression --only CO-11 --ver "$VER" --consensus IoTConsensusV2; echo "  A2 rc=$?"
cp -p "$CSV" "results/test_result_co11_v2_$(stamp).csv" 2>/dev/null; rotate "after_co11_v2"

echo "--- A3 CO-14 / IoTConsensusV2 ---"
bash tools/run_all.sh --set regression --only CO-14 --ver "$VER" --consensus IoTConsensusV2; echo "  A3 rc=$?"
cp -p "$CSV" "results/test_result_co14_v2_$(stamp).csv" 2>/dev/null; rotate "after_co14_v2"

echo "--- A4 CO-14 / RC6 + IoTConsensusV2（对照：判该现象是否 RC7 新引入）---"
bash tools/run_all.sh --set regression --only CO-14 --ver "$RC6VER" --consensus IoTConsensusV2; echo "  A4 rc=$?"
cp -p "$CSV" "results/test_result_co14_rc6v2_$(stamp).csv" 2>/dev/null; rotate "after_co14_rc6v2"

echo
echo "=== [B] IoTConsensusV2 从 CO-18 续跑（$(TS)）==="
bash tools/run_all.sh --set regression --only "$V2LIST" --ver "$VER" --consensus IoTConsensusV2; echo "  B rc=$?"
cp -p "$CSV" "results/test_result_rc7_v2_resume_$(stamp).csv" 2>/dev/null

echo
echo "=== 汇总（$(TS)）==="
for f in results/test_result_co11_v1_*.csv results/test_result_co11_v2_*.csv results/test_result_co14_v2_*.csv results/test_result_co14_rc6v2_*.csv results/test_result_rc7_v2_resume_*.csv; do
  [ -f "$f" ] || continue
  n=$(grep -acE ',(CO|DT)-[0-9]+,' "$f"); p=$(grep -a ,PASS, "$f" | grep -acE ',(CO|DT)-[0-9]+,' || true); fl=$(grep -a ,FAIL, "$f" | grep -acE ',(CO|DT)-[0-9]+,' || true)
  printf '  %-52s 用例=%s PASS=%s FAIL=%s\n' "${f##*/}" "$n" "$p" "$fl"
  grep -aE ',(CO|DT)-[0-9]+,' "$f" | awk -F, '{printf "      %-6s %-5s %5ss fail=%s\n", $4, $5, $6, $7}'
done
