#!/bin/bash
# ============================================================================
# 首轮全量之后的**定点复跑**链（单进程串行）：
#   1) TTL 场景（CO-13/CO-14，本轮新加）
#   2) 冒烟里被用例 bug 打掉的几条（CO-04/05/06/07/08，已修）
#   3) 参数/热加载（CO-09/10，已修：写前重新热关合并、不变量判定改为"SET 被拒才 FAIL"）
# 用法： setsid nohup bash tools/run_rerun_chain.sh /tmp/co_rerun.log >/dev/null 2>&1 &
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
L="${1:-/tmp/co_rerun.log}"

{
  echo "=== ttl    开始 $(date '+%F %T') ==="
  bash tools/run_all.sh --set ttl
  echo "=== smoke  复跑 CO-04/05/06/07/08 开始 $(date '+%F %T') ==="
  bash tools/run_all.sh --set smoke --only CO-04,CO-05,CO-06,CO-07,CO-08
  echo "=== param  复跑 CO-09/10 开始 $(date '+%F %T') ==="
  bash tools/run_all.sh --set param
  echo "=== remove 复跑 CO-12 开始 $(date '+%F %T') ==="
  bash tools/run_all.sh --set remove
  echo "=== RERUN DONE $(date '+%F %T') ==="
} >>"$L" 2>&1
