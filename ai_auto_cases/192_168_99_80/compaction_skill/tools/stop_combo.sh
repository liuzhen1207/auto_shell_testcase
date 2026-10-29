#!/bin/bash
# 停掉正在跑的 combo 用例集（pgrep -f 的 pattern 里不要带括号，避免被 pgrep 自己的参数解析炸掉）
set -uo pipefail
for pat in "run_all.sh --set combo" "co_param_gate_matrix" "co_param_selector"; do
  pids=$(pgrep -f "$pat" 2>/dev/null | tr '\n' ' ')
  for p in $pids; do [ "$p" = "$$" ] || kill -9 "$p" 2>/dev/null; done
done
sleep 2
echo "剩余相关进程："
pgrep -af "co_param" | grep -v stop_combo | head -3
pgrep -af "run_all.sh" | head -3
echo "=== done $(date '+%T') ==="
