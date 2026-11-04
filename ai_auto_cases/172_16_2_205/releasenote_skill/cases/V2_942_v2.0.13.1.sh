#!/bin/bash
# ============================================================================
# 来源缺陷单：PingCode V2-942（创建人：刘珍）
#   load balance to datanode 缺少语义检查：1C1D 指定不存在的 DN ID(999)
#   返回成功；期望应报错（目标 DN 不存在/未运行）
#   验证版本：2.0.13.1 / ab6d3de
# ============================================================================
case_RN128() {
  local out
  out=$(T "load balance to datanode 999")
  echo "  返回：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200)"

  if echo "$out" | grep -qiE 'success|执行成功'; then
    fail "指定不存在的 DN(999) 仍返回成功（缺陷未修复）"
  else
    ok "指定不存在的 DN 未返回成功"
  fi
  if echo "$out" | grep -qE '1004|do not exist|not exist|不存在'; then
    ok "给出目标 DN 不存在/未运行的明确错误"
  else
    fail "错误信息不明确（$(echo "$out" | head -1 | cut -c1-140)）"
  fi
}

CASES+=(
"RN-128|V2-942 load balance 校验|负向|load balance to datanode 指定不存在 DN 应报错而非成功|case_RN128"
)
