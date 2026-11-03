#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0679】日志优化：创建已存在用户时，WARN 日志不应打印详细堆栈
#   现象：WARN o.a.i.d.q.p.e.c.ConfigExecution - Failures happened ... 
#         后跟 IoTDBException: User xxx already exists 的整段堆栈
#   期望：仍返回明确错误，但日志只打一行，不带 "at org.apache..." 堆栈
#   验证版本：2.0.13.1 / ab6d3de
# ============================================================================
RN0679_USER=rn0679_u
RN0679_PW='Rn0679@123456'

case_RN105() {
  local out before after n_stack
  T "drop user $RN0679_USER" >/dev/null 2>&1
  out=$(T "create user $RN0679_USER '$RN_PW'")
  assert_ok "$out" "首次创建用户成功"

  # 记录 DN 日志当前位置
  local ip=172.16.2.2
  before=$(ssh -o StrictHostKeyChecking=no root@$ip "wc -l < /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null || echo 0" 2>/dev/null)
  before=${before:-0}

  # 重复创建 → 应失败
  out=$(T "create user $RN0679_USER '$RN_PW'")
  echo "  重复创建返回：$(echo "$out" | head -1 | cut -c1-160)"
  if echo "$out" | grep -qiE 'already exists|已存在|error|exception'; then
    ok "重复创建被拒绝（预期行为）"
  else
    fail "重复创建居然成功"
  fi

  sleep 2
  # 取新增日志里该错误的堆栈行数
  after=$(ssh -o StrictHostKeyChecking=no root@$ip "tail -n +$((before+1)) /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null | grep -A3 -i 'already exists' | grep -c 'at org.apache' || true" 2>/dev/null)
  n_stack=${after:-0}
  echo "  新增日志中 'already exists' 之后的堆栈行数：$n_stack"
  if [ "$n_stack" -eq 0 ]; then
    ok "WARN 未打印详细堆栈（日志优化生效）"
  else
    fail "WARN 仍打印了 $n_stack 行堆栈（日志优化未生效）"
  fi

  T "drop user $RN0679_USER" >/dev/null 2>&1
}

CASES+=(
"RN-105|TIMECHODB-0679 日志规范|日志|重复创建用户时 WARN 不应输出完整堆栈|case_RN105"
)
