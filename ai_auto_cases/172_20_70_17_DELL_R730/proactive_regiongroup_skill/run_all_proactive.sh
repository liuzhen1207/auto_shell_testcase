#!/bin/bash
# 全量回归驱动（分层执行；结果写入 result_<时间戳>/ 与 REPORT.md）
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
CONF="${PROACTIVE_CONF:-$ROOT/conf/cluster.pg_2011snap_iot.conf}"
TIER="${1:-smoke}"
RUN_ID="proactive_$(date +%Y%m%d_%H%M%S)"
bash "$ROOT/scripts/pg.sh" --conf "$CONF" doctor
bash "$ROOT/scripts/pg.sh" --conf "$CONF" prepare
bash "$ROOT/scripts/pg.sh" --conf "$CONF" matrix --tier "$TIER" --run-id "$RUN_ID"
bash "$ROOT/scripts/pg.sh" --conf "$CONF" report "results/$RUN_ID"
echo "结果：results/$RUN_ID/REPORT.md"
