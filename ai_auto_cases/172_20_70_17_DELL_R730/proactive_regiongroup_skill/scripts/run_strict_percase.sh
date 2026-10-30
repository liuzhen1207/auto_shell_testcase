#!/usr/bin/env bash
# 严格口径：**每个用例**都先走一遍"停集群→清 data/logs→设 conf→启集群"（prepare），再跑该用例。
# 用于需要字面满足"每用例从干净集群开始"的场合；代价 = 每例多一次完整启停 + sync lag 归零，
# 比默认的"每轮干净集群 + 每例清库"慢约 5~10 倍（217 例预计 1~2 天）。
#
# 用法: bash scripts/run_strict_percase.sh <conf> [case-id ...]
#   不带 case-id 时按当前注册表顺序跑全部；支持 PG_TIER=smoke|core|full 过滤。
set -u
cd "$(dirname "$0")/.."
CONF="${1:?用法: run_strict_percase.sh <conf> [case-id ...]}"; shift || true
IDS=("$@")
if [ "${#IDS[@]}" -eq 0 ]; then
  mapfile -t IDS < <(bash scripts/pg.sh --conf "$CONF" list-cases ${PG_TIER:+--tier "$PG_TIER"} | awk '{print $1}' | grep -E '^PG-')
fi
RUN_ID="${RUN_ID:-strict_$(date +%m%d_%H%M)}"
echo "严格逐例口径：${#IDS[@]} 个用例，run-id=$RUN_ID"
for id in "${IDS[@]}"; do
  echo "=== [$(date '+%H:%M:%S')] prepare（停→清 data/logs→设 conf→启） + run $id"
  bash scripts/pg.sh --conf "$CONF" prepare >/dev/null 2>&1 || { echo "  prepare 失败，跳过 $id"; continue; }
  bash scripts/pg.sh --conf "$CONF" run --case "$id" --run-id "$RUN_ID"
done
bash scripts/pg.sh --conf "$CONF" report "results/$RUN_ID" 2>/dev/null || true
