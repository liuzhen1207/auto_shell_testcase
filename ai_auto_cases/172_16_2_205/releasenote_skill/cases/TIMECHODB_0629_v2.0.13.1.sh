#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0629】表模型解锁用户 IP 锁语法解析失败
#   （树模型成功，表模型报 700 mismatched input '@'）
#   期望：表模型与树模型语法一致，均可解析执行
#   验证版本：2.0.13.1 / ab6d3de
# ============================================================================
RN0629_USER=rn0629_u
RN0629_PW='Rn0629@123456'

case_RN123() {
  local out
  T "drop user $RN0629_USER" >/dev/null 2>&1
  assert_ok "$(T "create user $RN0629_USER '$RN0629_PW'")" "创建用户"

  out=$(Q "alter user $RN0629_USER @ '172.16.2.205' ACCOUNT unlock")
  echo "  表模型返回：$(echo "$out" | head -1 | cut -c1-160)"
  if echo "$out" | grep -q '700'; then
    fail "表模型仍报 700 语法错误（缺陷未修复）"
  else
    ok "表模型语法解析通过"
  fi

  out=$(T "alter user $RN0629_USER @ '172.16.2.205' ACCOUNT unlock")
  echo "  树模型返回：$(echo "$out" | head -1 | cut -c1-160)"
  if echo "$out" | grep -q '700'; then
    fail "树模型报 700（基线异常）"
  else
    ok "树模型语法解析通过（基线）"
  fi

  T "drop user $RN0629_USER" >/dev/null 2>&1
}

CASES+=(
"RN-123|TIMECHODB-0629 解锁语法|功能|表模型 alter user ... @ 'ip' ACCOUNT unlock 应与树模型一致可解析|case_RN123"
)
