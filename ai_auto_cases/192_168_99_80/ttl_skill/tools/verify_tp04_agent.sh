#!/bin/bash
# TP-04 复跑（带 agent 佐证 + 诊断日志）：确认
#   ① 比值判据命中 TDB-610（root.regdup_tgt=2.00、对照=1.00）
#   ② 若节点上有只读 agent，则列表级佐证也生效（dataRegionList 里同一 region 两份）
# 产物：/tmp/ttl_tp04b.log、/tmp/ttl_tp04b.done
set -uo pipefail
LOG=/tmp/ttl_tp04b.log
MARK=/tmp/ttl_tp04b.done
SKILL=/data/iotdb/autotest/ttl_skill
export V_TESTDB="${V_TESTDB:-v20121rc5_1003_aaf460d}"
export V_COMMIT="${V_COMMIT:-aaf460d}"
rm -f "$MARK" "$LOG"
cd "$SKILL" || exit 1
{
  echo "===== TP-04 复跑（agent 佐证）开始 $(date '+%F %T') ====="
  SKIP_LIFECYCLE=0 bash "$SKILL/cases/common/ttl_dup_region_register.sh" --consensus IoTConsensus --framework 1
  echo "---- 结束 rc=$? $(date '+%F %T')"
  echo "===== 关键结论 ====="
  grep -e RESULT -e "最大比值" -e "命中 TDB-610" -e "对照组" -e "agent" "$SKILL/results/ttl_dup_region_register_IoTConsensus_$(date +%Y%m%d)_"*.out 2>/dev/null | tail -12 | cut -c1-220
  echo done > "$MARK"
} >> "$LOG" 2>&1
