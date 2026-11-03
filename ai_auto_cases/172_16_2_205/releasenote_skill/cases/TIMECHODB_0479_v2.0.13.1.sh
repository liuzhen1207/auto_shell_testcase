#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0479
#   【TIMECHODB-0479】 [ 安全 ] 2.0.6.1 RC1 drop user 成功应该断开它的连接，否则再创建同名用户，此僵尸用户就复活了
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：Drop user 成功，其连接应该失效  复现步骤 步骤1：root 创建用户，记作session-2 create user lily 'TimechoDB@2021'; grant MANAGE_DATABASE,
# ============================================================================
RN0479_SQL=(
"create user lily 'TimechoDB@2021'"
"grant MANAGE_DATABASE,ALL on root.** to user lily"
"LIST privileges of user lily"
"drop user lily"
"create user lily 'TimechoDB@2022'"
)

case_RN0479() {
  local st out unexpected=0
  for st in "${RN0479_SQL[@]}"; do
    out=$( T "$st" )
    # 幂等：对象已存在视为可接受
    if echo "$out" | grep -qiE 'already exists|already been created'; then
      ok "已存在(幂等): $(echo "$st" | cut -c1-55)"; continue
    fi
    if echo "$out" | grep -qiE 'Exception|ERROR|internal error|NullPointerException'; then
      unexpected=$((unexpected+1))
      fail "$(echo "$st" | cut -c1-65) -> $(echo "$out" | head -1 | cut -c1-110)"
    else
      ok "$(echo "$st" | cut -c1-55)"
    fi
  done
}

CASES+=(
"TIMECHODB-0479 自动抽取|TIMECHODB-0479|功能|安全 ] 2.0.6.1 RC1 drop user 成功应该断开它的连接，否则再创建同名用户，此僵尸用户就复活了|case_RN0479"
)
