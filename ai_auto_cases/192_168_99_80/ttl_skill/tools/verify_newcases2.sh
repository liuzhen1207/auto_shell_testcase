#!/bin/bash
# 复跑修正后的两条门禁用例（RC5，IoTConsensus）：
#   TP-04 ttl_dup_region_register（TDB-610）—— 修正"命令替换把日志文本一起吃进去"的判定 bug
#   TP-05 ttl_tier_warn_key      （TDB-611）—— 修正收尾一致性查询（本用例无数据 → 跳过该项）
# 期望：两条都 FAIL 且 fail_flag 只来自各自的门禁断言（TP-04=1、TP-05=2）
# 产物：/tmp/ttl_newcases2.log、/tmp/ttl_newcases2.done
set -uo pipefail
LOG=/tmp/ttl_newcases2.log
MARK=/tmp/ttl_newcases2.done
SKILL=/data/iotdb/autotest/ttl_skill
export V_TESTDB="${V_TESTDB:-v20121rc5_1003_aaf460d}"
export V_COMMIT="${V_COMMIT:-aaf460d}"
rm -f "$MARK" "$LOG"
cd "$SKILL" || exit 1
{
  echo "===== 新增门禁用例复跑开始 $(date '+%F %T') ====="
  for c in cases/common/ttl_dup_region_register.sh cases/common/ttl_tier_warn_key.sh; do
    echo
    echo "########## $(date '+%F %T') 运行 $c ##########"
    SKIP_LIFECYCLE=0 bash "$SKILL/$c" --consensus IoTConsensus --framework 1
    echo "########## $(date '+%F %T') 结束 $c rc=$? ##########"
  done
  echo
  echo "===== 结束 $(date '+%F %T') ====="
  tail -n 3 results/test_result.csv | cut -c1-260
  echo done > "$MARK"
} >> "$LOG" 2>&1
