#!/bin/bash
# ============================================================================
# 第 3 轮（最终定点复跑）：只跑"最后一轮修复"影响的用例
#   - ttl   ：CO-13/CO-14（TTL 场景，按 SettleSelectorImpl 语义重新编排 + 修 count SQL/未来时间戳）
#   - smoke ：CO-04（cross 基线取在重启前）、CO-05（单设备行数用原始查询数行）、
#             CO-06（删库重建相写 2 批，保证 inner 合并候选足够）
# 用法： setsid nohup bash tools/run_rerun2_chain.sh /tmp/co_rerun2.log >/dev/null 2>&1 &
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
L="${1:-/tmp/co_rerun2.log}"

{
  echo "=== ttl   复跑 CO-13/CO-14 开始 $(date '+%F %T') ==="
  bash tools/run_all.sh --set ttl
  echo "=== smoke 复跑 CO-04/05/06 开始 $(date '+%F %T') ==="
  bash tools/run_all.sh --set smoke --only CO-04,CO-05,CO-06
  echo "=== remove 复跑 CO-12 开始 $(date '+%F %T') ==="
  bash tools/run_all.sh --set remove
  echo "=== RERUN2 DONE $(date '+%F %T') ==="
} >>"$L" 2>&1
