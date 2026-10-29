#!/bin/bash
# ============================================================================
# 无人值守串行跑完整套：冒烟(CO-01..08) → 参数(CO-09/10) → 性能(CO-11) → 缩容(CO-12)
#   必须在同一个 run_all 进程里串行跑；run_all 自带 flock，第二个实例会直接退出。
#   用法：setsid nohup bash tools/run_full_chain.sh /tmp/co_full.log >/dev/null 2>&1 &
#   进度：tail -f <log>；或 bash tools/progress.sh <log>
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
L="${1:-/tmp/co_full.log}"

{
  echo "=== smoke  开始 $(date '+%F %T') ==="
  bash tools/run_all.sh --set smoke
  echo "=== param  开始 $(date '+%F %T') ==="
  bash tools/run_all.sh --set param
  echo "=== perf   开始 $(date '+%F %T') ==="
  # 首轮验证先用较小规模；完整回归时去掉这三行（默认 10 dev ×10000 行 ×6 批）
  export CO_PERF_DEVS=10 CO_PERF_ROWS=3000 CO_PERF_BATCHES=6
  bash tools/run_all.sh --set perf
  echo "=== remove 开始 $(date '+%F %T') ==="
  bash tools/run_all.sh --set remove
  echo "=== ALL DONE $(date '+%F %T') ==="
} >>"$L" 2>&1
