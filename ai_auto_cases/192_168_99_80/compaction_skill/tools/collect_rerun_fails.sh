#!/bin/bash
# 自动收集"需要在 V1 重跑"的失败用例：每 10 分钟把当前 CSV 里的 FAIL 用例 ID 并入 cases/rerun_v1.txt（去重排序）。
# 一旦接力链进入 [2] IoTConsensusV2 阶段（或超过 8 小时）就自动退出，避免把 V2 的失败混进 V1 清单。
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
C=$S/results/test_result.csv
L=$S/cases/rerun_v1.txt
for i in $(seq 1 48); do
  if grep -q '^=== \[2\]' /tmp/rc7_v2.log 2>/dev/null; then echo "[$(date '+%F %T')] 已进入 V2 阶段，停止收集"; break; fi
  [ -f "$C" ] || { sleep 600; continue; }
  # 当前 CSV 里所有 FAIL 的用例 ID（含正在累积的多阶段结果）
  grep -a ,FAIL, "$C" | grep -aoE ',(CO|DT)-[0-9]+,' | tr -d ',' > /tmp/fail_ids.now 2>/dev/null || true
  # 与既有清单合并去重排序
  { cat "$L" 2>/dev/null; cat /tmp/fail_ids.now; } | grep -E '^(CO|DT)-[0-9]+$' | sort -u > /tmp/rerun.new
  if ! cmp -s /tmp/rerun.new "$L" 2>/dev/null; then
    cp -f /tmp/rerun.new "$L"
    echo "[$(date '+%F %T')] 重跑清单已更新（$(grep -c . "$L") 条）: $(paste -sd, "$L")"
  fi
  sleep 600
done
