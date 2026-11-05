#!/bin/bash
SLOW_OF["RN-136"]="1"
# ============================================================================
# 来源缺陷单：PingCode V2-862（创建人：刘珍）
#   stop ConfigNode 过程中出现 NullPointerException
#   期望：优雅停止 CN 不产生 NPE
#   验证版本：2.0.13.1 / ab6d3de
#   说明：停非 Leader 的 CN（172.16.2.28），停完立即拉回
# ============================================================================
RN862_IP=172.16.2.28
RN862_LOG=/data/iotdb/$NEW/logs/log_confignode_all.log

case_RN136() {
  local before after npe
  before=$(ssh -o StrictHostKeyChecking=no root@$RN862_IP "wc -l < $RN862_LOG 2>/dev/null || echo 0" 2>/dev/null)
  before=${before:-0}

  echo "  优雅停止 CN $RN862_IP ..."
  ssh -o StrictHostKeyChecking=no root@$RN862_IP "bash /data/iotdb/$NEW/sbin/stop-confignode.sh > /tmp/rn862_stop.log 2>&1" 2>/dev/null
  sleep 15

  after=$(ssh -o StrictHostKeyChecking=no root@$RN862_IP "tail -n +$((before+1)) $RN862_LOG 2>/dev/null | grep -c 'NullPointerException' || true" 2>/dev/null)
  npe=${after:-0}
  echo "  stop 期间 CN 新增 NullPointerException 行数：$npe"
  if [ "$npe" -eq 0 ]; then
    ok "stop CN 未产生 NPE"
  else
    fail "stop CN 仍产生 $npe 行 NPE"
  fi

  echo "  重启 CN ..."
  ssh -o StrictHostKeyChecking=no root@$RN862_IP "cd /data/iotdb/$NEW && setsid /data/iotdb/$NEW/sbin/start-confignode.sh > /tmp/rn862_start.log 2>&1 < /dev/null &" 2>/dev/null
  wait_running 420 >/dev/null 2>&1 || true
  echo "  恢复后 Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"
}

CASES+=(
"RN-136|V2-862 停CN日志|可靠性|stop ConfigNode 不应产生 NullPointerException|case_RN136"
)
