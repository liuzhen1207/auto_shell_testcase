#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0187
#   【TIMECHODB-0187】 insert null 值 不会覆盖当前值
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：需讨论预期，当客户主动插入null时的执行结果 和 返回结果。  复现步骤 # 插入1个测点，并记录时间戳 insert into root.g1.d1(s1) values(1)  select s1 from roo
# ============================================================================
RN0187_SQL=(
"insert into root.g1.d1(s1) values(1)"
"select s1 from root.g1.d1"
"insert into root.g1.d1(time,s1) values(【上一步的时间戳】， null)"
)

case_RN0187() {
  local st out unexpected=0
  for st in "${RN0187_SQL[@]}"; do
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
"TIMECHODB-0187 自动抽取|TIMECHODB-0187|功能|insert null 值 不会覆盖当前值|case_RN0187"
)
