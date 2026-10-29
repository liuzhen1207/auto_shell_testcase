#!/bin/bash
# 跑新增的两条门禁用例（RC5，IoTConsensus）：
#   TP-04 ttl_dup_region_register（TDB-610）—— 修复前应 FAIL（每周期检查 2 次）
#   TP-05 ttl_tier_warn_key      （TDB-611）—— 修复前应 FAIL（告警仍写 default_ttl_in_ms）
# 产物：/tmp/ttl_newcases.log、/tmp/ttl_newcases.done
set -uo pipefail
LOG=/tmp/ttl_newcases.log
MARK=/tmp/ttl_newcases.done
SKILL=/data/iotdb/autotest/ttl_skill
export V_TESTDB="${V_TESTDB:-v20121rc5_1003_aaf460d}"
export V_COMMIT="${V_COMMIT:-aaf460d}"
rm -f "$MARK" "$LOG"
cd "$SKILL" || exit 1
{
  echo "===== 新增门禁用例验证开始 $(date '+%F %T') ====="
  for c in cases/common/ttl_dup_region_register.sh cases/common/ttl_tier_warn_key.sh; do
    echo
    echo "########## $(date '+%F %T') 运行 $c ##########"
    SKIP_LIFECYCLE=0 bash "$SKILL/$c" --consensus IoTConsensus --framework 1
    echo "########## $(date '+%F %T') 结束 $c rc=$? ##########"
  done
  echo
  echo "===== 结束 $(date '+%F %T') ====="
  tail -n 4 results/test_result.csv | cut -c1-260
  echo done > "$MARK"
} >> "$LOG" 2>&1
