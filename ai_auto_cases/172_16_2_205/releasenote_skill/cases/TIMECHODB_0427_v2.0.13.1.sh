#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0427
#   【TIMECHODB-0427】 高精度时间戳取余结果不符合预期
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：取模结果为 3  复现步骤  1. 设置时间精度为ns，启动 1C1D  2. 执行以下语句 insert into root.sg.d1(time,s1,s2) values(1752034017179000003,1
# ============================================================================
RN0427_SQL=(
"insert into root.sg.d1(time,s1,s2) values(1752034017179000003,1,1)"
"select time%10 from root.sg.d1"
)

case_RN0427() {
  local st out unexpected=0
  for st in "${RN0427_SQL[@]}"; do
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
"TIMECHODB-0427 自动抽取|TIMECHODB-0427|功能|高精度时间戳取余结果不符合预期|case_RN0427"
)
