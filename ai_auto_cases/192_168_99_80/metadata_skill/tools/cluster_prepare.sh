#!/bin/bash
# 仅准备集群（停 -> 清 -> 写配置 -> 启动），不跑用例。
#   bash tools/cluster_prepare.sh [--consensus IoTConsensus|IoTConsensusV2] [--keep-data]
#   EXTRA_CONF="k1=v1,k2=v2" 可追加集群参数
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"
CLUSTER_NAME="${CLUSTER_NAME:-timecho}"
mkdir -p "$MD_SKILL_DIR/results"
md_case_init "cluster_prepare"
log "准备集群：version=$V_TESTDB consensus=$CONSENSUS_CLASS extra_conf=${EXTRA_CONF:-<none>}"
md_cluster_prepare
log "--- show cluster ---"
sq 'show cluster;' | tee -a "$OUT"
log "--- show databases ---"
sq 'show databases;' | tee -a "$OUT"
log "准备完成（用例可用 SKIP_LIFECYCLE=1 直接跑）"
write_result
