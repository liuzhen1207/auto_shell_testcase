#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0299
#   【TIMECHODB-0299】 StreamAggOperator 处理 Empty Block 时发生异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：查询 1 正常执行，查询结果为 image.png  查询 2 正常执行，查询结果为 image.png  复现步骤 创建数据，同【TIMECHODB-0298】 UDAF  group by 查询执行异常 执行查询  
# ============================================================================
RN0299_SQL=(
"select avg(s1) from table1 where s1 + 1 < 1 group by device_id,s1"
"select avg(s1) from table1 where s1 + 1 < 1 group by device_id"
)

case_RN0299() {
  local st out unexpected=0
  for st in "${RN0299_SQL[@]}"; do
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
"TIMECHODB-0299 自动抽取|TIMECHODB-0299|功能|StreamAggOperator 处理 Empty Block 时发生异常|case_RN0299"
)
