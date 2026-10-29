#!/bin/bash
# probe_prometheus.sh —— 指标源自检（Prometheus HTTP API 与直连 /metrics 两条路都验一遍）
#
# 用法（任一 skill 根目录）：
#   bash tools/probe_prometheus.sh               # 用 conf/env.conf 里的配置
#   PROMETHEUS_URL=http://1.2.3.4:9090 bash tools/probe_prometheus.sh
#
# 只读：不发 DDL/DML，不启停集群。任何时候都可以跑。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
[ -f "$SKILL/conf/env.conf" ] && . "$SKILL/conf/env.conf"
. "$SKILL/lib/common.sh"

echo "== 配置"
echo "   PROMETHEUS_URL       = ${PROMETHEUS_URL:-<空 ⇒ 只用直连>}"
echo "   PROMETHEUS_USER      = ${PROMETHEUS_USER:-<无>}"
echo "   PROMETHEUS_CLUSTER   = ${PROMETHEUS_CLUSTER:-timecho}"
echo "   PROM_SCRAPE_INTERVAL = ${PROM_SCRAPE_INTERVAL:-10}"
echo "   SYNC_LAG_SOURCE      = ${SYNC_LAG_SOURCE:-auto}"
echo "   DN_METRIC_PORT=${DN_METRIC_PORT:-9092}  DN=[${DN[*]:-${DN_NODES:-}}]"

if [ -n "${PROMETHEUS_URL:-}" ]; then
  echo "== Prometheus 可达性"
  if prom_healthy; then echo "   OK $PROMETHEUS_URL/-/healthy"; else echo "   FAIL 不可达（$PROMETHEUS_URL）"; fi
  echo "== syncLag（Prometheus，V1+V2 合并选）"
  q=$(sync_lag_promql); echo "   promql: $q"
  prom_series "$q" | head -5 | sed 's/^/   /'
  echo "   series=$(prom_series "$q" | wc -l | tr -dc '0-9')  非零=$(prom_count_nonzero "$q")"
  if prom_all_zero "$q"; then echo "   prom_all_zero: 非空且全 0 ✅"; else echo "   prom_all_zero: 存在非 0 或无数据（rc=$?）"; fi
  echo "== replicateMode（V2 才有，2=BATCH / 1=STREAM|LOG）"
  m=$(prom_series 'iot_consensus_v2_mode{type="replicateMode"}' 2>/dev/null | head -1)
  if [ -n "${m:-}" ]; then echo "   $m"; else echo "   无该指标（当前大概率是 V1 或未启用 V2）"; fi
  echo "== 示例：thrift_connections ClientRPC（Prometheus 单查询）"
  prom_series 'thrift_connections{cluster="'"${PROMETHEUS_CLUSTER:-timecho}"'",name="ClientRPC",nodeType="DATANODE"}' 2>/dev/null | sed 's/^/   /' || echo "   查询失败"
fi

echo "== 直连各 DN 的 /metrics（回退路径）"
for h in ${DN:-${DN_NODES:-}}; do
  body=$(curl -s -m 8 "http://$h:${DN_METRIC_PORT:-9092}/metrics" 2>/dev/null | grep 'type="syncLag"')
  n=$(printf '%s' "$body" | grep -c 'syncLag')
  nz=$(printf '%s\n' "$body" | awk '$NF+0 > 0.0001' | wc -l | tr -dc '0-9')
  echo "   $h: series=${n:-0} 非零=${nz:-0}"
done

echo "== 汇总"
echo "   sync_lag_scan（${SYNC_LAG_SOURCE:-auto} 源） = $(sync_lag_scan)   # 期望 \"<series> 0\""
