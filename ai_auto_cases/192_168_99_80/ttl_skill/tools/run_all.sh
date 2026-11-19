#!/bin/bash
# ============================================================================
# 顺序执行 TTL 用例集并汇总结果
#   bash run_all.sh [--consensus IoTConsensus[,IoTConsensusV2]] [--set all|tree|table|quick|dml|param|threshold|defect]
#                   [--framework 0|1] [--env <env.conf>]
# 环境变量 SKIP_LIFECYCLE=1 时复用当前已运行集群（调试用，快很多）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
. "$SKILL/lib/common.sh"
ttl_load_env

SET=all
CONS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --consensus) CONS="$2"; shift 2 ;;
    --set)       SET="$2";  shift 2 ;;
    --framework) USE_FRAMEWORK="$2"; shift 2 ;;
    --env)       . "$2"; shift 2 ;;
    *) echo "未知参数 $1"; exit 2 ;;
  esac
done
[ -n "$CONS" ] || CONS="${CONSENSUS_LIST:-IoTConsensus}"
CONS="${CONS//,/ }"

case "$SET" in
  tree)  CASES=("cases/tree/ttl_tree_basic.sh" "cases/tree/ttl_tree_expire.sh" "cases/tree/ttl_tree_scope.sh" "cases/tree/ttl_show_ttl_scope.sh" "cases/tree/ttl_tree_dml.sh") ;;
  table) CASES=("cases/table/ttl_table_basic.sh" "cases/table/ttl_table_expire.sh" "cases/table/ttl_table_cleanup.sh" "cases/table/ttl_table_object.sh" "cases/table/ttl_table_dml.sh") ;;
  dml)   CASES=("cases/tree/ttl_tree_dml.sh" "cases/table/ttl_table_dml.sh") ;;
  param) CASES=("cases/common/ttl_param_effect.sh" "cases/common/ttl_param_effect_mode.sh") ;;
  threshold) CASES=("cases/common/ttl_cleanup_threshold.sh") ;;
  # 缺陷门禁集合：已登记缺陷对应的全部回归门禁用例（RC5 上 TDB-444/TDB-452 应为 PASS，TDB-610/TDB-611 修复前为 FAIL）
  defect) CASES=("cases/tree/ttl_show_ttl_scope.sh" "cases/common/ttl_param_effect.sh" \
                 "cases/common/ttl_cleanup_threshold.sh" "cases/table/ttl_table_cleanup.sh" \
                 "cases/common/ttl_dup_region_register.sh" "cases/common/ttl_tier_warn_key.sh") ;;
  quick) CASES=("cases/tree/ttl_tree_basic.sh" "cases/table/ttl_table_basic.sh") ;;
  all)   CASES=("cases/tree/ttl_tree_basic.sh" "cases/tree/ttl_tree_expire.sh" "cases/tree/ttl_tree_scope.sh" \
                "cases/tree/ttl_show_ttl_scope.sh" "cases/tree/ttl_tree_dml.sh" \
                "cases/table/ttl_table_basic.sh" "cases/table/ttl_table_expire.sh" "cases/table/ttl_table_cleanup.sh" \
                "cases/table/ttl_table_object.sh" "cases/table/ttl_table_dml.sh" \
                "cases/common/ttl_param_effect.sh" "cases/common/ttl_cleanup_threshold.sh" \
                "cases/common/ttl_param_effect_mode.sh" \
                "cases/common/ttl_dup_region_register.sh" "cases/common/ttl_tier_warn_key.sh") ;;
  *) echo "未知 --set $SET"; exit 2 ;;
esac

mkdir -p "$SKILL/results"
echo "==== TTL 用例集开始 $(date '+%F %T')  consensus=[$CONS] set=$SET framework=$USE_FRAMEWORK ===="
rc_all=0
for c in $CONS; do
  for f in "${CASES[@]}"; do
    echo "---- 运行 $f --consensus $c"
    SKIP_LIFECYCLE="${SKIP_LIFECYCLE:-0}" bash "$SKILL/$f" --consensus "$c" --framework "$USE_FRAMEWORK" || rc_all=1
  done
done
echo
echo "==== 汇总 ($SKILL/results/test_result.csv) ===="
if [ -f "$SKILL/results/test_result.csv" ]; then
  column -s, -t "$SKILL/results/test_result.csv" 2>/dev/null || cat "$SKILL/results/test_result.csv"
fi
echo "==== 结束 $(date '+%F %T') exit=$rc_all ===="
exit $rc_all
