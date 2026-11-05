#!/bin/bash
SLOW_OF["RN-134"]="1"
# ============================================================================
# 来源缺陷单：PingCode V2-883（创建人：刘珍）
#   stop DN 时 TableDiskUsageIndex 短时间刷上万条 WARN
#   （日志类型名还被混淆成 AapaterPattern，且服务停止顺序不对）
#   期望：stop DN 过程中该 WARN 不成灾（<200 行），且不出现混淆类型名
#   验证版本：2.0.13.1 / ab6d3de
#   说明：原缺陷是 12 秒 14345 条，此处缩短为单次 stop 观测
# ============================================================================
RN883_IP=172.16.2.6

case_RN134() {
  local before after warn garbled
  before=$(ssh -o StrictHostKeyChecking=no root@$RN883_IP "wc -l < /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null || echo 0" 2>/dev/null)
  before=${before:-0}

  echo "  优雅停止 DN $RN883_IP ..."
  ssh -o StrictHostKeyChecking=no root@$RN883_IP "bash /data1/iotdb/$NEW/sbin/stop-datanode.sh > /tmp/rn883_stop.log 2>&1" 2>/dev/null
  sleep 20

  after=$(ssh -o StrictHostKeyChecking=no root@$RN883_IP "tail -n +$((before+1)) /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null | grep -c 'TableDiskUsageIndex' || true" 2>/dev/null)
  warn=${after:-0}
  garbled=$(ssh -o StrictHostKeyChecking=no root@$RN883_IP "tail -n +$((before+1)) /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null | grep -c 'AapaterPattern' || true" 2>/dev/null)
  garbled=${garbled:-0}
  echo "  stop 期间 TableDiskUsageIndex WARN 行数：$warn；混淆类型名出现：$garbled"

  if [ "$warn" -lt 200 ]; then
    ok "stop 期间 WARN 未成灾（$warn < 200）"
  else
    fail "stop 期间仍刷 $warn 行 TableDiskUsageIndex WARN"
  fi
  if [ "$garbled" -eq 0 ]; then
    ok "未出现混淆类型名 AapaterPattern"
  else
    fail "仍出现混淆类型名 $garbled 次"
  fi

  echo "  重启 DN $RN883_IP ..."
  start_dn $RN883_IP >/dev/null 2>&1
  wait_running 360 >/dev/null 2>&1 || true
  echo "  恢复后 Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"
}

CASES+=(
"RN-134|V2-883 停DN日志|日志|stop DN 时 TableDiskUsageIndex WARN 不应成灾且无混淆类型名|case_RN134"
)
