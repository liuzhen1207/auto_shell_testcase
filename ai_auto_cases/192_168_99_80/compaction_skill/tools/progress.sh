#!/bin/bash
# ============================================================================
# 查看无人值守全量跑（tools/run_full_chain.sh）的进度
#   bash tools/progress.sh [logfile]        # 默认 /tmp/co_full.log
#   输出：各阶段/各用例的 PASS/FAIL 汇总 + 当前用例最近几行
# ============================================================================
set -uo pipefail
L="${1:-/tmp/co_full.log}"
[ -f "$L" ] || { echo "找不到日志：$L"; exit 1; }

echo "=== 阶段 ==="
grep -aE '^=== .*(开始|DONE)' "$L" | tail -n 12

echo
echo "=== 用例结果 ==="
grep -aE '^##########|^  -> rc=' "$L" | sed 's/ *—— 20[0-9-]* [0-9:]* ##########//' | tail -n 60

echo
echo "=== 最近 15 行 ==="
tail -n 15 "$L"

echo
echo "=== 当前用例输出（run_all 只把结果行写进套件日志，明细在 results/） ==="
CUR=$(ls -t "$(dirname "$0")"/../results/CO-*.out 2>/dev/null | head -n 1)
if [ -n "$CUR" ]; then
  echo "-> $CUR（tail 20）"
  tail -n 20 "$CUR"
else
  echo "（还没有 CO-*.out）"
fi

echo
echo "=== 进程 ==="
pgrep -af 'run_full_chain|run_all.sh' | grep -v progress.sh | head -n 5
