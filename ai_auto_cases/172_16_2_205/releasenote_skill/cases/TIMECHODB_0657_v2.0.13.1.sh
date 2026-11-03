#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0657
#   【TIMECHODB-0657】 【V2.0.7.1_RC9】表模型中，拥有SECURITY权限的用户1，授予用户6关于__audit权限范围内INSERT或SELECT权限应该有个CHECK
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：表模型中，拥有SECURITY权限的用户1，授予用户6关于__audit权限范围内INSERT或SELECT权限应该有个CHECK，不应该授权成功  复现步骤 （1）safe包，默认开起三权分立，启动1C1D （2）内置
# ============================================================================
RN0657_SQL=(
"create user user1 'pass12345678'"
"grant security to user user1"
"create user user6 'pass12345678'"
"set sql_dialect=table"
"grant insert on database __audit to user user6"
"grant select on table __audit.audit_log to user user6"
)

case_RN0657() {
  local st out unexpected=0
  for st in "${RN0657_SQL[@]}"; do
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
"TIMECHODB-0657 自动抽取|TIMECHODB-0657|功能|V2.0.7.1_RC9】表模型中，拥有SECURITY权限的用户1，授予用户6关于__audit权限范围内INSE|case_RN0657"
)
