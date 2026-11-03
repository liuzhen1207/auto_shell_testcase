#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0732】监控面板 "IoTConsensus Used Memory" 显示负值
#   期望：内存类指标不得为负
#   验证版本：2.0.13.1 / ab6d3de
#   判据：5 台 DN 的 /metrics 中，IoTConsensus 相关内存指标不存在负值
# ============================================================================
case_RN116() {
  local ip out neg total=0
  for ip in $DN_LIST; do
    out=$(ssh -o StrictHostKeyChecking=no root@$ip "curl -s --max-time 6 http://127.0.0.1:9092/metrics 2>/dev/null | grep -i 'iotconsensus' | grep -vi '^#'" 2>/dev/null)
    neg=$(echo "$out" | grep -cE '\} -[0-9]' 2>/dev/null)
    total=$(echo "$out" | grep -c . 2>/dev/null)
    echo "  $ip: IoTConsensus 指标行=$total 负值行=${neg:-0}"
    if [ "${neg:-0}" -gt 0 ]; then
      echo "$out" | grep -E '\} -[0-9]' | head -3 | sed 's/^/    /'
    fi
    if [ "${neg:-0}" -gt 0 ]; then
      fail "$ip: 存在 ${neg} 个负值 IoTConsensus 指标"
    else
      ok "$ip: 无负值"
    fi
  done
}

CASES+=(
"RN-116|TIMECHODB-0732 监控指标|功能|IoTConsensus 内存类指标不得为负值|case_RN116"
)
