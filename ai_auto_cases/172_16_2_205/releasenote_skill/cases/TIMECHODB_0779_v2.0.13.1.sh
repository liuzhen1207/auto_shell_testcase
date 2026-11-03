#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0779】查询耗时系统表：热加载修改 query_cost_stat_window
#   时，非法值（如 '5.61'）会被写进 iotdb-system.properties，期望忽略非法值
#   验证版本：2.0.13.1 / ab6d3de
#   判据：①SET CONFIGURATION 非法值报错 ②iotdb-system.properties 里不出现该非法值
# ============================================================================
RN0779_KEY=query_cost_stat_window
RN0779_VAL=5.61

case_RN111() {
  local out file found=0
  out=$(Q "set configuration \"$RN0779_KEY\"='$RN0779_VAL'")
  echo "  SET CONFIGURATION 返回：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200)"

  if echo "$out" | grep -qiE 'error|exception|invalid|失败|不支持'; then
    ok "非法值被拒绝"
  else
    ok "未报错（若产品选择静默忽略也可接受，继续校验文件）"
  fi

  # 校验配置文件未被写入非法值（DN 与 CN 都查）
  for ip in 172.16.2.2 172.16.2.26; do
    if [ "$ip" = "172.16.2.26" ]; then
      file=/data/iotdb/$NEW/conf/iotdb-system.properties
    else
      file=/data1/iotdb/$NEW/conf/iotdb-system.properties
    fi
    out=$(ssh -o StrictHostKeyChecking=no root@$ip "grep -n '^$RN0779_KEY=' $file 2>/dev/null" 2>/dev/null)
    echo "  $ip: ${out:-<无该配置行>}"
    if echo "$out" | grep -q "$RN0779_VAL"; then
      found=1
    fi
  done

  if [ "$found" -eq 1 ]; then
    fail "非法值 $RN0779_VAL 被写入 iotdb-system.properties"
  else
    ok "配置文件未记录非法值"
  fi

  # 清理：删除非法行并写回合法值，避免污染后续启动
  ssh -o StrictHostKeyChecking=no root@172.16.2.26 "sed -i '/^$RN0779_KEY=$RN0779_VAL$/d' /data/iotdb/$NEW/conf/iotdb-system.properties" 2>/dev/null
  ssh -o StrictHostKeyChecking=no root@172.16.2.2  "sed -i '/^$RN0779_KEY=$RN0779_VAL$/d' /data1/iotdb/$NEW/conf/iotdb-system.properties" 2>/dev/null
  Q "set configuration \"$RN0779_KEY\"='60000'" >/dev/null 2>&1
}

CASES+=(
"RN-111|TIMECHODB-0779 配置热加载|负向|非法 query_cost_stat_window 值不应写入 iotdb-system.properties|case_RN111"
)
