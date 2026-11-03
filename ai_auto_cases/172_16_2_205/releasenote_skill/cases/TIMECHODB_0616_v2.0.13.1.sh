#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0616】不存在的用户名通过 CLI 登录，DN 打 NPE 日志：
#   Cannot invoke "String.contains(...)" because IClientSession.getUsername() is null
#   验证版本：2.0.13.1 / ab6d3de
#   判据：用不存在用户登录后，DN 新增日志中不出现 handleClientExit 相关 NPE
# ============================================================================
RN0616_USER=user_is_not_exist_rn0616

case_RN119() {
  local ip before after hits out
  ip=172.16.2.2
  before=$(ssh -o StrictHostKeyChecking=no root@$ip "wc -l < /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null || echo 0" 2>/dev/null)
  before=${before:-0}

  # 用不存在的用户登录（带 -pw，避免交互卡住）
  out=$(timeout 40 $CLI -h "$HOST" -p 6667 -u "$RN0616_USER" -pw 'Whatever@123456' -e "show databases" 2>&1)
  echo "  登录返回：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-180)"

  if echo "$out" | grep -qiE 'error|exception|failed|不存在|认证'; then
    ok "不存在用户登录被拒绝（预期行为）"
  else
    fail "不存在用户竟然登录成功"
  fi

  sleep 3
  after=$(ssh -o StrictHostKeyChecking=no root@$ip "tail -n +$((before+1)) /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null | grep -c 'handleClientExit' || true" 2>/dev/null)
  hits=${after:-0}
  echo "  新增日志中 handleClientExit NPE 行数：$hits"
  if [ "$hits" -eq 0 ]; then
    ok "DN 未打印 handleClientExit NPE"
  else
    fail "DN 仍打印 $hits 行 handleClientExit 相关异常"
  fi
}

CASES+=(
"RN-119|TIMECHODB-0616 登录健壮性|负向|不存在用户登录不应导致 DN handleClientExit NPE|case_RN119"
)
