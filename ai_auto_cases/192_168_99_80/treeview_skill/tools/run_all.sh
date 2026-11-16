#!/bin/bash
# ============================================================================
# treeview_skill / tools/run_all.sh
#   bash run_all.sh [--set smoke|create|ddl|query|ttl|security|align|perf|ha|sync|autosync|log|client|real|realall|all]
#                   [--only TV-01,TV-02] [--consensus IoTConsensus|IoTConsensusV2]
#                   [--keep-cluster]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
. "$SKILL/lib/common.sh"
tv_load_env

SET=smoke
ONLY=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --set) SET="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --consensus) CONSENSUS_CLASS="$2"; DATA_CONSENSUS="${2##*.}"; shift 2 ;;
    --keep-cluster) KEEP=1; shift ;;
    *) shift ;;
  esac
done

case "$SET" in
  smoke)    CASES=("cases/treeview/tv_create_basic.sh") ;;
  create)   CASES=("cases/treeview/tv_create_basic.sh" "cases/treeview/tv_create_negative.sh" "cases/treeview/tv_create_restrict.sh") ;;
  ddl)      CASES=("cases/treeview/tv_alter.sh" "cases/treeview/tv_show.sh") ;;
  query)    CASES=("cases/treeview/tv_query.sh" "cases/treeview/tv_query_align.sh") ;;
  ttl)      CASES=("cases/treeview/tv_ttl.sh") ;;
  security) CASES=("cases/treeview/tv_security.sh") ;;
  align)    CASES=("cases/treeview/tv_align.sh") ;;
  perf)     CASES=("cases/treeview/tv_perf.sh") ;;
  ha)       CASES=("cases/treeview/tv_ha.sh") ;;
  sync)     CASES=("cases/treeview/tv_sync.sh") ;;
  real)     CASES=("cases/treeview/tv_realdata.sh") ;;
  autosync) CASES=("cases/treeview/tv_autosync_fail.sh" "cases/treeview/tv_autosync_1000.sh") ;;
  log)      CASES=("cases/treeview/tv_log_noise.sh") ;;
  client)   CASES=("cases/treeview/tv_client_iface.sh") ;;
  realall)  CASES=("cases/treeview/tv_realdata.sh" "cases/treeview/tv_real_views.sh" \
                   "cases/treeview/tv_real_query.sh" "cases/treeview/tv_real_alter.sh" \
                   "cases/treeview/tv_real_ttl.sh" "cases/treeview/tv_real_ha.sh") ;;
  all)      CASES=("cases/treeview/tv_create_basic.sh" "cases/treeview/tv_create_negative.sh" \
                   "cases/treeview/tv_create_restrict.sh" "cases/treeview/tv_alter.sh" \
                   "cases/treeview/tv_show.sh" "cases/treeview/tv_query.sh" \
                   "cases/treeview/tv_query_align.sh" "cases/treeview/tv_ttl.sh" \
                   "cases/treeview/tv_security.sh" "cases/treeview/tv_ha.sh" \
                   "cases/treeview/tv_log_noise.sh" "cases/treeview/tv_client_iface.sh" \
                   "cases/treeview/tv_realdata.sh") ;;
  *) echo "未知 --set: $SET"; exit 2 ;;
esac

if [ -n "$ONLY" ]; then
  IFS=',' read -ra WANT <<<"$ONLY"
  SEL=()
  for c in "${CASES[@]}"; do
    for w in "${WANT[@]}"; do
      case "$(basename "$c")" in *"$w"*) SEL+=("$c") ;; esac
    done
  done
  CASES=("${SEL[@]}")
fi

echo "########## treeview_skill set=$SET consensus=$DATA_CONSENSUS 共 ${#CASES[@]} 条 ##########"
rc_all=0
for c in "${CASES[@]}"; do
  [ -f "$SKILL/$c" ] || { echo "!! 缺用例 $c"; continue; }
  echo "===== 运行 $(basename "$c") ====="
  ( cd "$SKILL" && V_TESTDB="$V_TESTDB" BUILD_TAG="$BUILD_TAG" bash "$c" --consensus "$CONSENSUS_CLASS" ) || true
done
if [ "$KEEP" = 0 ]; then tv_cluster_stop; fi
echo "########## 完成（结果见 results/）##########"
