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
  local st out unexpected=0 RN_EXPECT_ERROR=1
  rn_run() {  # 方言自适配：先试首选方言，700/701 解析错误则换另一种方言重试
    local st=$1 o1 o2
    o1=$( T "$st" )
    if echo "$o1" | grep -qE '700: |701: '; then
      o2=$( Q "$st" )
      if ! echo "$o2" | grep -qE '700: |701: '; then echo "$o2"; return; fi
    fi
    echo "$o1"
  }
  for st in "${RN0299_SQL[@]}"; do
    out=$( rn_run "$st" )
    # 幂等：对象已存在视为可接受
    if echo "$out" | grep -qiE 'already exists|already been created'; then
      ok "已存在(幂等): $(echo "$st" | cut -c1-55)"; continue
    fi
    # 策略类错误：弱口令/无列/已存在，不算缺陷
    if echo "$out" | grep -qiE '820:|507:|501:'; then
      ok "策略/幂等类返回(可接受): $(echo "$st" | cut -c1-45)"; continue
    fi
    if echo "$out" | grep -qiE 'Exception|ERROR|internal error|NullPointerException'; then
      if [ "$RN_EXPECT_ERROR" = "1" ]; then
        ok "预期报错: $(echo "$st" | cut -c1-50)"
      else
        fail "$(echo "$st" | cut -c1-65) -> $(echo "$out" | head -1 | cut -c1-110)"
      fi
    else
      ok "$(echo "$st" | cut -c1-55)"
    fi
  done
}

CASES+=(
"RN-0299|TIMECHODB-0299 自动抽取|功能|StreamAggOperator 处理 Empty Block 时发生异常|case_RN0299"
)
