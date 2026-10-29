#!/bin/bash
# 串行跑一批用例（每条用例独立进程、各自 prepare 集群；结果同时写各自的 canonical out）
# 用法： bash tools/run_new_chain.sh <脚本名1> [脚本名2 ...]     # 脚本名相对 cases/common/
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd "$S" || exit 1
CHAIN="$S/results/NEWCHAIN_$(date +%Y%m%d_%H%M%S).out"
: >"$CHAIN"
echo "=== 批次开始 $(date '+%F %T')：$*" | tee -a "$CHAIN"
for c in "$@"; do
  echo "=== $(date '+%F %T') 开始 $c ===" | tee -a "$CHAIN"
  bash "$S/cases/common/$c" </dev/null >>"$CHAIN" 2>&1
  rc=$?
  echo "=== $(date '+%F %T') 结束 $c rc=$rc ===" | tee -a "$CHAIN"
  grep -aE '^\[[^]]*\] RESULT ' "$CHAIN" | tail -1
done
echo "=== 批次结束 $(date '+%F %T') ===" | tee -a "$CHAIN"
grep -aE '^\[[^]]*\] RESULT ' "$CHAIN"
